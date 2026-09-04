## PBGizmoPlugin — Native editor integration via EditorNode3DGizmoPlugin subgizmos.
##
## This is THE integration layer between PoiBuilder and the Godot 3D editor.
## Instead of hand-rolling viewport input (which fights the editor's own
## selection, transform gizmo, and rubber-band handling), this plugin exposes
## each mesh element (vertex group / edge / face) as a native editor SUBGIZMO:
##
## - Click picking, shift-toggle, and rubber-band multi-select are handled by
##   the editor itself (it calls _subgizmos_intersect_ray/_frustum).
## - The editor's own transform gizmo (Q/W/E/R toolbar modes, snapping) is
##   repositioned onto the selected elements and drives _set_subgizmo_transform
##   during drags.
## - On release the editor calls _commit_subgizmos; undo goes through
##   EditorUndoRedoManager so Ctrl+Z behaves like any native editor action.
##
## Pattern reference: engine-internal Path3D / Skeleton3D /
## NavigationObstacle3D gizmo plugins (all use exactly this mechanism).
##
## All element math, drag state, and undo payload logic lives in
## PBElementEditor (runtime-safe, headless-testable). This class only adapts
## between the editor's gizmo API and that logic, plus does the rendering.
##
## NOTE: gizmo parameters are intentionally UNTYPED (duck-typed): the editor
## passes real EditorNode3DGizmo instances; tests pass stand-ins, and typing
## them would break headless testing of the whole behavior suite.
@tool
class_name PBGizmoPlugin
extends EditorNode3DGizmoPlugin

# ==============================================================================
# Constants
# ==============================================================================

const WIREFRAME_COLOR := Color(0.28, 0.28, 0.28, 1.0)
## EDGE-mode base wireframe: cyan, drawn slightly thinner than hover/select
## strokes (half offset, one stack pair instead of two).
const EDGE_MODE_WIREFRAME_COLOR := Color(0.2, 0.9, 1.0, 0.8)
## Selection is YELLOW (thick strokes for edges / solid-ish fills for faces).
const SELECTED_COLOR := Color(1.0, 0.9, 0.2, 0.85)
const FACE_FILL_COLOR := Color(1.0, 0.9, 0.2, 0.32)
## Hover highlight: CYAN — the same language ProBuilder uses to say "this is
## under your cursor, not selected". Selected stays yellow.
const HOVER_COLOR := Color(0.2, 0.9, 1.0, 0.75)
const HOVER_FACE_FILL_COLOR := Color(0.2, 0.9, 1.0, 0.22)
const VERTEX_COLOR := Color(0.05, 0.05, 0.05, 1.0)
const VERTEX_DOT_SIZE: float = 7.0
const VERTEX_DOT_SELECTED_SIZE: float = 11.0
const VERTEX_DOT_HOVER_SIZE: float = 9.0

## World-space offset between the sub-lines of a "thick" edge. Godot lines are
## always 1px; stacking parallel lines fakes ProBuilder-style thickness.
const THICK_LINE_OFFSET: float = 0.006

## Shape-creation language: cyan everywhere (same cyan as hover — creation
## highlights and hovers share the "cursor preview" meaning), orange for the
## facing arrow. Bounds/arrow draw ON TOP (show through the object); the
## hovered face fill is depth-tested at the selection opacity.
const CREATION_COLOR := Color(0.2, 0.9, 1.0, 1.0)
const CREATION_FILL_COLOR := Color(0.2, 0.9, 1.0, 0.32)
const CREATION_ARROW_COLOR := Color(1.0, 0.55, 0.1, 1.0)

# ==============================================================================
# Wiring (set by PoiBuilderPlugin on registration)
# ==============================================================================

## Shared editor state (active mesh, select mode, orientation space, selection).
var editor: PBEditor = null

## Runtime-safe element logic (drag state, math, undo payload).
var element_editor: PBElementEditor = PBElementEditor.new()

## Shape-creation session (ARMED/BASE/HEIGHT/PARAMS) — while active, the
## plugin pauses element interaction and this plugin draws the creation
## overlays instead. May be null (creation never started).
var shape_creator: PBShapeCreator = null

## The face currently hovered during shape creation (cyan highlight).
var creation_hover_node: PBMesh = null
var creation_hover_face: int = -1

## The surface point under the cursor during creation (for the ARMED-stage
## vertex square under the mouse).
var creation_hover_point: Vector3 = Vector3.ZERO

## Verification counter (GUI harness): how many times the creation BASE
## outline branch actually drew lines.
var creation_outline_draws: int = 0

## Verification counter (GUI harness): subgizmo ray-cast invocations.
var intersect_ray_calls: int = 0

## Direct overlay materials for the creation outlines/arrow. The plugin-API
## create_material() variants are NOT usable here: get_material() picks the
## variant by the NODE's selected state, and the unselected variant draws at
## 30% alpha with depth test ON — the outline came out faint and hidden
## behind geometry. These are unshaded, full-alpha, depth-test-off, high
## render priority: thicker-than-geometry overlays visible through anything.
var _creation_edge_material: StandardMaterial3D
var _creation_arrow_material: StandardMaterial3D
## Yellow square vertex gizmos for the creation drag corners (points render
## as squares — same language as the element-mode vertex dots).
var _creation_vert_material: StandardMaterial3D

## Logger for diagnostics.
var logger: PBLogger = null:
	set = set_logger

# Point materials for vertex dots (need point size; plugin-created materials
# cannot express it).
var _vertex_dot_material: StandardMaterial3D
var _vertex_dot_selected_material: StandardMaterial3D
var _vertex_dot_hover_material: StandardMaterial3D

## Cached depth-tested face fill materials (built lazily).
var _face_fill_material: StandardMaterial3D
var _face_hover_fill_material: StandardMaterial3D
var _creation_fill_material: StandardMaterial3D

# ==============================================================================
# Lifecycle
# ==============================================================================

func _init() -> void:
	create_material("pb_wireframe", WIREFRAME_COLOR, false, false)
	create_material("pb_wireframe_edge", EDGE_MODE_WIREFRAME_COLOR, false, false)
	create_material("pb_selected_edge", SELECTED_COLOR, false, true)
	create_material("pb_hover_edge", HOVER_COLOR, false, true)
	create_handle_material("pb_center_handle")
	create_material("pb_collider_debug", Color(0.1, 1.0, 0.4, 0.95), false, true, true)
	_vertex_dot_material = _make_point_material(VERTEX_COLOR, VERTEX_DOT_SIZE)
	_vertex_dot_selected_material = _make_point_material(SELECTED_COLOR, VERTEX_DOT_SELECTED_SIZE)
	_vertex_dot_hover_material = _make_point_material(HOVER_COLOR, VERTEX_DOT_HOVER_SIZE)

func set_logger(value: PBLogger) -> void:
	logger = value
	element_editor.logger = value

static func _make_point_material(color: Color, point_size: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	# Translucent variants (hover) need alpha transparency; opaque colors are
	# unaffected by enabling it.
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = false
	mat.use_point_size = true
	mat.point_size = point_size
	return mat

## On-top overlay line material: unshaded, full alpha, depth test disabled.
static func _make_overlay_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.render_priority = RenderingServer.MATERIAL_RENDER_PRIORITY_MAX
	return mat

func _make_face_fill_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = false
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat

# ==============================================================================
# GizmoPlugin identity
# ==============================================================================

func _has_gizmo(for_node_3d: Node3D) -> bool:
	return for_node_3d is PBMesh

func _get_gizmo_name() -> String:
	return "PoiBuilderMesh"

func _get_priority() -> int:
	return 1

func _can_be_hidden() -> bool:
	return true

func _is_selectable_when_hidden() -> bool:
	return false

# ==============================================================================
# State queries
# ==============================================================================

## Returns this plugin's gizmo instance attached to `node`, if any.
func gizmo_for_node(node: Node3D) -> EditorNode3DGizmo:
	for g in node.get_gizmos():
		if g.get_plugin() == self:
			return g
	return null

## True when the gizmo's node is the active mesh in an element mode.
## All element picking/dragging is gated on this so native object-level
## behavior takes over otherwise.
func is_editing_node(node: PBMesh) -> bool:
	return element_editor.is_editing_node(node)

## Returns mesh data for a gizmo's node, or null when not editable.
func _mesh_data_of(gizmo) -> PBMeshData:
	var node := gizmo.get_node_3d() as PBMesh
	if node == null:
		return null
	return node.pb_mesh_data

# ==============================================================================
# Subgizmo picking (called by the editor's own click / rubber-band handling)
# ==============================================================================

func _subgizmos_intersect_ray(gizmo, camera: Camera3D, screen_pos: Vector2) -> int:
	intersect_ray_calls += 1
	var node := gizmo.get_node_3d() as PBMesh
	if node == null or camera == null or not is_editing_node(node):
		return -1
	var id := element_editor.pick_ray(node.pb_mesh_data, node.global_transform, camera, screen_pos)
	# SHIFT+press on an ALREADY-SELECTED element must not reach the engine's
	# toggle (it would erase the selection and kill the shift+drag extrude
	# gesture). Returning -1 keeps the selection; the following drag then
	# translates/extrudes it, exactly like ProBuilder's shift+face-drag.
	if id >= 0 and Input.is_key_pressed(KEY_SHIFT) and gizmo.is_subgizmo_selected(id):
		if logger != null:
			logger.info("pick", "shift-press on selected %s id=%d suppressed (kept selection for the drag; toggle-off is disabled)" % [
				PBEditor.SelectMode.keys()[editor.select_mode], id])
		return -1
	# Alt+click / double-click on an edge selects its whole loop (the engine
	# selection stays the single seed id; dragging/highlighting expand it).
	if id >= 0 and editor != null and editor.select_mode == PBEditor.SelectMode.EDGE:
		element_editor.record_edge_click(node.pb_mesh_data, id, Input.is_key_pressed(KEY_ALT))
	return id

func _subgizmos_intersect_frustum(gizmo, camera: Camera3D, frustum_planes: Array) -> PackedInt32Array:
	var node := gizmo.get_node_3d() as PBMesh
	if node == null or camera == null or not is_editing_node(node):
		return PackedInt32Array()
	return element_editor.pick_frustum(node.pb_mesh_data, node.global_transform, frustum_planes, camera)

# ==============================================================================
# Subgizmo transforms (called by the editor during native gizmo drags)
# ==============================================================================

func _get_subgizmo_transform(gizmo, subgizmo_id: int) -> Transform3D:
	var node := gizmo.get_node_3d() as PBMesh
	var mesh_data: PBMeshData = _mesh_data_of(gizmo)
	if node == null or mesh_data == null or subgizmo_id < 0:
		return Transform3D.IDENTITY
	return element_editor.get_subgizmo_transform(mesh_data, node, subgizmo_id)

func _set_subgizmo_transform(gizmo, subgizmo_id: int, transform: Transform3D) -> void:
	var node := gizmo.get_node_3d() as PBMesh
	if node == null:
		return
	if element_editor.set_subgizmo_transform(node, gizmo.get_subgizmo_selection(), subgizmo_id, transform):
		node.update_gizmos()
## Commit (drag released) or cancel (Escape) — called by the editor.
## `restores` are the start transforms the engine snapshotted (informational
## here; PBElementEditor keeps its own snapshot). On cancel the engine does
## NOT revert anything itself, so restoring is our job.
func _commit_subgizmos(gizmo, ids: PackedInt32Array, _restores: Array, cancel: bool) -> void:
	var node := gizmo.get_node_3d() as PBMesh
	if node == null:
		return
	element_editor.commit_subgizmos(node, ids, cancel)
	node.update_gizmos()

# ==============================================================================
# Rendering
# ==============================================================================

func _redraw(gizmo) -> void:
	gizmo.clear()
	_center_handle_drawn = false
	var node := gizmo.get_node_3d() as PBMesh
	if node == null:
		return
	var mesh_data: PBMeshData = node.pb_mesh_data
	if mesh_data == null or mesh_data.positions.is_empty():
		return

	# The engine's viewport click/rubber-band picking runs through GIZMO
	# collision meshes only (_select_ray has no mesh raycast fallback), and
	# the stock MeshInstance3D gizmo's triangles go stale because PBMesh
	# never emits property-change notifications for its rebuilt ArrayMesh.
	# Without this, every PBMesh except the initially-selected one is
	# unpickable by clicking. Skipped mid-drag: picking is irrelevant there
	# and the rebuild cost would land on every motion event. The TriangleMesh
	# is cached per mesh instance (hover redraws must not rebuild it).
	if not element_editor.drag_active and node.mesh != null:
		var mesh_id: int = node.mesh.get_instance_id()
		if int(node.get_meta("_pb_pick_mesh_id", -1)) != mesh_id:
			node.set_meta("_pb_pick_mesh_id", mesh_id)
			node.set_meta("_pb_pick_tmesh", node.mesh.generate_triangle_mesh())
		gizmo.add_collision_triangles(node.get_meta("_pb_pick_tmesh"))

	# Shape-creation overlays: the live preview's cyan bounds + facing arrow,
	# and the cyan hover highlight on the surface under the cursor. Checked
	# BEFORE the selected-node early-out (preview/hover nodes are usually not
	# in the editor selection at all).
	if shape_creator != null and shape_creator.is_active():
		if shape_creator.preview_node == node:
			_draw_creation_preview(gizmo, mesh_data, shape_creator)
			return
		if creation_hover_node == node and creation_hover_face >= 0 \
				and creation_hover_face < mesh_data.faces.size():
			_draw_creation_hover(gizmo, mesh_data, creation_hover_face)
			return

	if not _node_selected(node):
		if node.show_collider and node.collider_type != PBMesh.ColliderType.OFF:
			_draw_collider_debug(gizmo, node)
		return

	if node.show_collider and node.collider_type != PBMesh.ColliderType.OFF:
		_draw_collider_debug(gizmo, node)

	_mirror_engine_selection(gizmo, node, mesh_data)

	# Wireframe (depth-tested). In EDGE mode ProBuilder renders edges as bold
	# black strokes — thicker via stacked parallel lines — with the selection
	# highlighted on top; VERTEX mode uses bolder dark dots; FACE mode keeps
	# the subtle gray wireframe under the translucent face fill.
	var edge_indices := mesh_data.get_common_edge_indices()
	var n_indices: int = edge_indices.size()
	var positions := mesh_data.positions
	var pos_size: int = positions.size()
	var wire_points := PackedVector3Array()
	wire_points.resize(n_indices)
	var write_idx: int = 0
	for i in range(0, n_indices, 2):
		var a: int = edge_indices[i]
		var b: int = edge_indices[i + 1]
		if a >= 0 and a < pos_size and b >= 0 and b < pos_size:
			wire_points[write_idx] = positions[a]
			wire_points[write_idx + 1] = positions[b]
			write_idx += 2
	if write_idx < n_indices:
		wire_points.resize(write_idx)
	if wire_points.size() >= 2:
		if editor != null and editor.select_mode == PBEditor.SelectMode.EDGE \
				and is_editing_node(node):
			# EDGE mode base wireframe: slightly thinner cyan (hover/select
			# strokes drawn on top stay full-thick).
			_add_thick_lines(gizmo, wire_points, get_material("pb_wireframe_edge", gizmo),
				THICK_LINE_OFFSET * 0.5, 1)
		else:
			gizmo.add_lines(wire_points, get_material("pb_wireframe", gizmo))

	if not is_editing_node(node):
		return

	match editor.select_mode:
		PBEditor.SelectMode.FACE:
			_draw_selected_faces(gizmo, mesh_data)
			_draw_hover_face(gizmo, mesh_data)
		PBEditor.SelectMode.EDGE:
			_draw_selected_edges(gizmo, mesh_data)
			_draw_hover_edge(gizmo, mesh_data)
		PBEditor.SelectMode.VERTEX:
			_draw_vertex_dots(gizmo, mesh_data)

	_draw_center_scale_handle(gizmo, mesh_data)

## Draws the ProBuilder-style CENTER square handle while the scale tool is
## active over a selection: dragging it scales all axes together; with Shift
## on a face selection it insets uniformly (aspect fixed). Godot's own scale
## gizmo has no uniform center — this is ours.
func _draw_center_scale_handle(gizmo, mesh_data: PBMeshData) -> void:
	if editor == null or editor.tool_mode != PBEditor.ToolMode.SCALE:
		return
	if not is_editing_node(gizmo.get_node_3d()):
		return
	var selected: PackedInt32Array = gizmo.get_subgizmo_selection()
	if selected.is_empty():
		return
	# Pivot = the average origin of the selected elements (node-local).
	var acc := Vector3.ZERO
	var count := 0
	for id in selected:
		acc += element_editor.element_origin(mesh_data, id)
		count += 1
	if count == 0:
		return
	var pivot := acc / float(count)
	# billboard=false is REQUIRED: with the billboard flag the engine rotates
	# the handle's LOCAL offset around the NODE ORIGIN toward the camera
	# (both the drawn point and the hit test), which displaces the handle
	# away from the true element pivot whenever the node origin is not the
	# pivot itself (a face/edge/vertex on a moved or created mesh). A plain
	# transform puts the grab point exactly on the gizmo center.
	gizmo.add_handles(PackedVector3Array([pivot]),
		get_material("pb_center_handle", gizmo), PackedInt32Array([0]), false)
	# Track for the GUI harness + debug logging (did the handle exist, where).
	var node := gizmo.get_node_3d() as Node3D
	var world: Vector3 = node.global_transform * pivot if node != null else pivot
	if logger != null and PBLogger.verbose and node != null:
		logger.debug("handle", "center handle pivot world=%s (node origin %s)" % [
			str(world), str(node.global_position)])
	if not _center_handle_drawn or _center_handle_world.distance_to(world) > 0.001:
		if logger != null and PBLogger.verbose:
			logger.debug("handle", "center handle drawn at world %s (tool=%s selection=%d)"
				% [str(world), PBEditor.ToolMode.keys()[editor.tool_mode], selected.size()])
	_center_handle_drawn = true
	_center_handle_world = world

## Whether the center scale handle was drawn in the last _redraw, and where.
var _center_handle_drawn: bool = false
var _center_handle_world: Vector3 = Vector3.ZERO

## The center handle's id in our gizmo (single handle, id 0).
const CENTER_HANDLE_ID := 0

func _get_handle_name(gizmo, handle_id: int, secondary: bool) -> String:
	if handle_id == CENTER_HANDLE_ID and editor != null \
			and editor.tool_mode == PBEditor.ToolMode.SCALE:
		return "Uniform Scale (Shift: Inset faces)"
	return ""

func _get_handle_value(gizmo, handle_id: int, secondary: bool):
	var node := gizmo.get_node_3d() as PBMesh
	if node == null or node.pb_mesh_data == null:
		return null
	return {"pivot": element_editor.center_pivot(node.pb_mesh_data,
		gizmo.get_subgizmo_selection()), "factor": 1.0}

func _set_handle(gizmo, handle_id: int, secondary: bool, camera: Camera3D,
		screen_pos: Vector2) -> void:
	if handle_id != CENTER_HANDLE_ID or camera == null:
		return
	var node := gizmo.get_node_3d() as PBMesh
	if node == null or editor == null or not is_editing_node(node):
		return
	var selected: PackedInt32Array = gizmo.get_subgizmo_selection()
	if selected.is_empty():
		return
	if logger != null and not element_editor.center_drag_active():
		logger.info("handle", "center handle GRABbed at screen %s shift=%s mode=%s" % [
			str(screen_pos), str(Input.is_key_pressed(KEY_SHIFT)),
			PBEditor.SelectMode.keys()[editor.select_mode]])

	if not element_editor.center_drag_active():
		# First motion of the gesture: decide uniform scale vs inset.
		var inset: bool = Input.is_key_pressed(KEY_SHIFT) \
			and editor.select_mode == PBEditor.SelectMode.FACE
		var pivot := element_editor.center_pivot(node.pb_mesh_data, selected)
		if not element_editor.begin_center_drag(node, selected, inset, pivot, screen_pos):
			return

	element_editor.apply_center_drag(node, camera, screen_pos)
	node.update_gizmos()

func _commit_handle(gizmo, handle_id: int, secondary: bool, restore: Variant,
		cancel: bool) -> void:
	if handle_id != CENTER_HANDLE_ID:
		return
	var node := gizmo.get_node_3d() as PBMesh
	if node == null:
		return
	var selected: PackedInt32Array = gizmo.get_subgizmo_selection()
	if logger != null:
		logger.info("handle", "center handle %s (factor was %.3f)" % [
			"CANCELLED" if cancel else "COMMITTED", element_editor._center_factor])
	element_editor.commit_center_drag(node, selected, cancel)
	node.update_gizmos()

## Draws each input line (a pair of points) as a crisp, solid 3D stroke using
## filled cross-quads (plus a center line for guaranteed subpixel visibility at
## distance). This eliminates the fuzzy, multi-line "wire comb" artifact when
## zoomed in, maintaining a solid, clean beam at any zoom level.
static func _add_thick_lines(gizmo, pairs: PackedVector3Array, material: Material,
		offset: float = THICK_LINE_OFFSET, stacks: int = 2) -> void:
	var n: int = pairs.size()
	if n < 2:
		return

	# 1. Center hardware lines: guaranteed min 1px visibility at any distance
	gizmo.add_lines(pairs, material)

	# 2. Solid crossed quads: fills the stroke volume with unshaded triangles
	# so it stays completely solid and never splits into fuzzy parallel wires when zoomed in.
	var o := offset
	var quads_per_seg: int = 2 if stacks >= 2 else 1
	var num_segs: int = n / 2
	var verts := PackedVector3Array()
	var indices := PackedInt32Array()
	verts.resize(num_segs * quads_per_seg * 4)
	indices.resize(num_segs * quads_per_seg * 6)

	var v_idx: int = 0
	var i_idx: int = 0
	var i: int = 0
	while i + 1 < n:
		var a: Vector3 = pairs[i]
		var b: Vector3 = pairs[i + 1]
		var dir := b - a
		if dir.length_squared() > 0.000000001:
			dir = dir.normalized()
			var perp1 := dir.cross(Vector3.UP)
			if perp1.length_squared() < 0.25:
				perp1 = dir.cross(Vector3.RIGHT)
			perp1 = perp1.normalized() * o

			# Quad 1 (along perp1)
			var base_v := v_idx
			verts[v_idx]     = a - perp1
			verts[v_idx + 1] = a + perp1
			verts[v_idx + 2] = b + perp1
			verts[v_idx + 3] = b - perp1
			v_idx += 4

			indices[i_idx]     = base_v
			indices[i_idx + 1] = base_v + 1
			indices[i_idx + 2] = base_v + 2
			indices[i_idx + 3] = base_v
			indices[i_idx + 4] = base_v + 2
			indices[i_idx + 5] = base_v + 3
			i_idx += 6

			if stacks >= 2:
				var perp2 := dir.cross(perp1.normalized()).normalized() * o
				var base_v2 := v_idx
				verts[v_idx]     = a - perp2
				verts[v_idx + 1] = a + perp2
				verts[v_idx + 2] = b + perp2
				verts[v_idx + 3] = b - perp2
				v_idx += 4

				indices[i_idx]     = base_v2
				indices[i_idx + 1] = base_v2 + 1
				indices[i_idx + 2] = base_v2 + 2
				indices[i_idx + 3] = base_v2
				indices[i_idx + 4] = base_v2 + 2
				indices[i_idx + 5] = base_v2 + 3
				i_idx += 6
		i += 2

	if v_idx > 0:
		if v_idx < verts.size():
			verts.resize(v_idx)
			indices.resize(i_idx)
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_INDEX] = indices
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		gizmo.add_mesh(mesh, material)
## True when the node is in the editor's selection. EditorNode3DGizmo's own
## is_selected() is not script-bound on all supported engine versions (4.8
## added it), so query the EditorSelection directly.
func _node_selected(node: Node3D) -> bool:
	var sel := EditorInterface.get_selection()
	if sel == null:
		return false
	return node in sel.get_selected_nodes()

## Mirrors the engine's subgizmo selection into PBSelection so the dock,
## toolbar, and commands agree with what the transform gizmo will move.
## PBSelection.selection_changed → editor.element_selection_changed refreshes
## the dock. Do NOT update gizmos here — this runs inside _redraw and would
## loop.
func _mirror_engine_selection(gizmo, node: PBMesh, mesh_data: PBMeshData) -> void:
	if editor == null or editor.active_mesh != node:
		return
	element_editor.mirror_engine_selection(editor.selection, mesh_data, gizmo.get_subgizmo_selection())

## Selected faces as a translucent n-gon fill, slightly offset along the face
## normal and DEPTH-TESTED so it never draws through the mesh (a depth-test-off
## fill pokes its triangle boundary through non-planar faces, reading as a
## phantom "diagonal edge" where no edge exists).
func _draw_selected_faces(gizmo, mesh_data: PBMeshData) -> void:
	var selected: PackedInt32Array = gizmo.get_subgizmo_selection()
	if selected.is_empty():
		return
	var fill := element_editor.build_face_fill_mesh_multi(mesh_data, selected)
	if fill == null:
		return
	if _face_fill_material == null:
		_face_fill_material = _make_face_fill_material(FACE_FILL_COLOR)
	gizmo.add_mesh(fill, _face_fill_material)

## The hovered (not selected) face as a translucent yellow fill — same yellow
## as the selection, just slightly more transparent.
func _draw_hover_face(gizmo, mesh_data: PBMeshData) -> void:
	var hover_id: int = editor.hover_id
	if hover_id < 0 or hover_id >= mesh_data.faces.size():
		return
	if gizmo.is_subgizmo_selected(hover_id):
		return
	var fill := element_editor.build_face_fill_mesh(mesh_data, hover_id)
	if fill == null:
		return
	if _face_hover_fill_material == null:
		_face_hover_fill_material = _make_face_fill_material(HOVER_FACE_FILL_COLOR)
	gizmo.add_mesh(fill, _face_hover_fill_material)

## Selected edges as bright on-top strokes (thick in EDGE mode). Loop
## selections (alt+click) highlight their whole ring.
func _draw_selected_edges(gizmo, mesh_data: PBMeshData) -> void:
	var selected_ids: PackedInt32Array = gizmo.get_subgizmo_selection()
	if selected_ids.is_empty():
		return
	var expanded := element_editor.expand_edge_ids(mesh_data, selected_ids)
	if expanded.is_empty():
		return
	var positions := mesh_data.positions
	var pos_count: int = positions.size()
	var edges := mesh_data.get_common_edges()
	var edges_count: int = edges.size()
	var lines := PackedVector3Array()
	lines.resize(expanded.size() * 2)
	var write_idx: int = 0
	for eid in expanded:
		if eid >= 0 and eid < edges_count:
			var edge: PBEdge = edges[eid]
			if edge.a >= 0 and edge.a < pos_count and edge.b >= 0 and edge.b < pos_count:
				lines[write_idx] = positions[edge.a]
				lines[write_idx + 1] = positions[edge.b]
				write_idx += 2
	if write_idx < lines.size():
		lines.resize(write_idx)
	if lines.size() >= 2:
		_add_thick_lines(gizmo, lines, get_material("pb_selected_edge", gizmo))
## The hovered (not selected) edge as a translucent yellow on-top stroke.
func _draw_hover_edge(gizmo, mesh_data: PBMeshData) -> void:
	var hover_id: int = editor.hover_id
	var edges := mesh_data.get_common_edges()
	if hover_id < 0 or hover_id >= edges.size():
		return
	if gizmo.is_subgizmo_selected(hover_id):
		return
	var positions := mesh_data.positions
	var edge: PBEdge = edges[hover_id]
	if edge.a < 0 or edge.a >= positions.size() or edge.b < 0 or edge.b >= positions.size():
		return
	_add_thick_lines(gizmo, PackedVector3Array([positions[edge.a], positions[edge.b]]),
		get_material("pb_hover_edge", gizmo))

## All shared vertices as gray dots, selected ones as opaque yellow dots, the
## hovered one (when not selected) as a slightly more transparent yellow dot.
func _draw_vertex_dots(gizmo, mesh_data: PBMeshData) -> void:
	var positions := mesh_data.positions
	var pos_count: int = positions.size()
	var unselected := PackedVector3Array()
	var selected := PackedVector3Array()
	var hovered := PackedVector3Array()
	var hover_id: int = editor.hover_id
	var sub_selected: PackedInt32Array = gizmo.get_subgizmo_selection()
	var sel_set := {}
	for s in sub_selected:
		sel_set[s] = true
	var sv_count: int = mesh_data.shared_vertices.size()
	for sv_idx in range(sv_count):
		var sv: PBSharedVertex = mesh_data.shared_vertices[sv_idx]
		if sv == null or sv.indices.is_empty():
			continue
		var idx: int = sv.indices[0]
		if idx < 0 or idx >= pos_count:
			continue
		if sel_set.has(sv_idx):
			selected.append(positions[idx])
		elif sv_idx == hover_id:
			hovered.append(positions[idx])
		else:
			unselected.append(positions[idx])

	_add_points_mesh(gizmo, unselected, _vertex_dot_material)
	_add_points_mesh(gizmo, hovered, _vertex_dot_hover_material)
	_add_points_mesh(gizmo, selected, _vertex_dot_selected_material)
static func _add_points_mesh(gizmo, points: PackedVector3Array, material: StandardMaterial3D) -> void:
	if points.is_empty():
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	var points_mesh := ArrayMesh.new()
	points_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	gizmo.add_mesh(points_mesh, material)

# ==============================================================================
# Shape-creation overlays
# ==============================================================================

## Lazily builds the direct creation overlay materials (see the field docs).
func _creation_materials() -> void:
	if _creation_edge_material == null:
		_creation_edge_material = _make_overlay_material(CREATION_COLOR)
	if _creation_arrow_material == null:
		_creation_arrow_material = _make_overlay_material(CREATION_ARROW_COLOR)
	if _creation_vert_material == null:
		_creation_vert_material = _make_point_material(SELECTED_COLOR, 11.0)
		_creation_vert_material.render_priority = RenderingServer.MATERIAL_RENDER_PRIORITY_MAX

## Adds the orange facing arrow as a crisp, solid 3D arrow: a solid rectangular
## shaft along `dir` plus a solid triangular arrowhead at the tip, lying in the
## dragged surface plane with perpendicular finning for all-angle visibility.
## Crisp and solid at any zoom level, avoiding the fuzzy multi-line artifact.
func _add_creation_arrow(gizmo, to_local: Transform3D, base: Vector3, dir: Vector3,
		length: float, plane_normal: Vector3) -> void:
	if length < 0.001:
		return
	var norm_dir := dir.normalized()
	var tip := base + norm_dir * length
	var side := norm_dir.cross(plane_normal).normalized()
	if side.length_squared() < 0.5:
		side = norm_dir.cross(Vector3.UP)
		if side.length_squared() < 0.5:
			side = norm_dir.cross(Vector3.RIGHT)
	side = side.normalized()
	var up := side.cross(norm_dir).normalized()

	var barb_len: float = length * 0.30
	var head_half_width: float = length * 0.20
	var head_base := tip - norm_dir * barb_len
	var left_barb := head_base + side * head_half_width
	var right_barb := head_base - side * head_half_width
	var shaft_half_width: float = maxf(length * 0.035, 0.01)

	# Transform all key points to local space
	var l_base := to_local * base
	var l_tip := to_local * tip
	var l_head_base := to_local * head_base
	var l_left_barb := to_local * left_barb
	var l_right_barb := to_local * right_barb

	var l_side := to_local.basis * (side * shaft_half_width)

	# 1. Solid mesh: flat arrowhead triangle + shaft quad lying strictly in the plane
	var verts := PackedVector3Array()
	var indices := PackedInt32Array()

	# Arrowhead: solid triangle in the plane (tip, left_barb, right_barb)
	verts.append(l_tip)                            # 0
	verts.append(l_left_barb)                     # 1
	verts.append(l_right_barb)                    # 2
	indices.append_array([0, 1, 2])

	# Shaft: flat quad in the plane
	var s_idx := verts.size()
	verts.append(l_base - l_side)                 # s_idx + 0
	verts.append(l_base + l_side)                 # s_idx + 1
	verts.append(l_head_base + l_side)            # s_idx + 2
	verts.append(l_head_base - l_side)            # s_idx + 3
	indices.append_array([
		s_idx, s_idx + 1, s_idx + 2,
		s_idx, s_idx + 2, s_idx + 3
	])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	gizmo.add_mesh(mesh, _creation_arrow_material)

	# 2. Crisp 1px outline lines for guaranteed subpixel visibility
	var outline := PackedVector3Array([
		l_base, l_head_base,
		l_head_base, l_left_barb,
		l_left_barb, l_tip,
		l_tip, l_right_barb,
		l_right_barb, l_head_base
	])
	gizmo.add_lines(outline, _creation_arrow_material)
## Adds yellow square vertex gizmos (GL points) at the world-space points.
func _add_vert_squares(gizmo, to_local: Transform3D, world_points: PackedVector3Array) -> void:
	if world_points.is_empty():
		return
	var local := PackedVector3Array()
	for p in world_points:
		local.append(to_local * p)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = local
	var points_mesh := ArrayMesh.new()
	points_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	gizmo.add_mesh(points_mesh, _creation_vert_material)

## Creation overlays for the preview node. BASE: the cyan base-rect outline
## (mesh still hidden) plus the orange facing arrow ON THE PLANE and yellow
## vertex squares at the drag's start/end corners. HEIGHT/PARAMS: the cyan
## 3D box bounds, the arrow (local +Z — the basis orients it along `facing`)
## and squares at the drag start, drag end, and the lifted end corner. All
## overlays draw thick and on top (visible through geometry).
func _draw_creation_preview(gizmo, mesh_data: PBMeshData, creator: PBShapeCreator) -> void:
	_creation_materials()
	var node := gizmo.get_node_3d() as Node3D
	if node == null:
		return
	var to_local := node.global_transform.affine_inverse()
	var creation_offset: float = THICK_LINE_OFFSET * 1.5

	if creator.state == PBShapeCreator.State.BASE:
		var corners := creator.base_rect_corners()
		var lines := PackedVector3Array()
		for i in range(corners.size()):
			lines.append(to_local * corners[i])
			lines.append(to_local * corners[(i + 1) % corners.size()])
		_add_thick_lines(gizmo, lines, _creation_edge_material, creation_offset)
		creation_outline_draws += 1
		# Facing arrow on the base plane — ONLY for shapes with a meaningful
		# facing (stairs' high side, door's front); a symmetric shape would
		# make it noise.
		if creator.facing_direction() != Vector3.ZERO:
			var arrow_len: float = clampf(maxf(creator.u_size, creator.v_size) * 0.6, 0.35, 2.0)
			_add_creation_arrow(gizmo, to_local, creator.rect_center, creator.arrow_direction(),
				arrow_len, creator.plane_normal)
		_add_vert_squares(gizmo, to_local,
			PackedVector3Array([creator.base_start, creator.base_end]))
		return

	# HEIGHT / PARAMS: box bounds around the live preview mesh.
	var aabb := PBShapeCreator._aabb_of(mesh_data)
	var p0 := aabb.position
	var p1 := aabb.end
	var c := [p0.x, p1.x]
	var d := [p0.y, p1.y]
	var e := [p0.z, p1.z]
	var corners: Array[Vector3] = []
	for xi in c:
		for yi in d:
			for zi in e:
				corners.append(Vector3(xi, yi, zi))
	# Corner order above: index bits (x:4, y:2, z:1). The 12 box edges join
	# pairs differing in exactly one axis bit.
	var edges := [[0, 1], [0, 2], [0, 4], [1, 3], [1, 5], [2, 3],
		[2, 6], [3, 7], [4, 5], [4, 6], [5, 7], [6, 7]]
	var lines := PackedVector3Array()
	for edge in edges:
		lines.append(corners[edge[0]])
		lines.append(corners[edge[1]])
	_add_thick_lines(gizmo, lines, _creation_edge_material, creation_offset)
	creation_outline_draws += 1

	# Facing arrow from the base center along local +Z (the placement basis
	# points +Z along the creator's facing heuristic) — only for shapes with
	# a meaningful facing; symmetric shapes get no arrow.
	if creator.facing_direction() != Vector3.ZERO:
		var base_center := Vector3(aabb.get_center().x, p0.y, aabb.get_center().z)
		var arrow_len: float = clampf(aabb.get_longest_axis_size() * 0.5, 0.3, 2.0)
		_add_creation_arrow(gizmo, Transform3D(), base_center, Vector3(0, 0, 1),
			arrow_len, Vector3(0, 1, 0))

	# Vertex squares: drag start, drag end, and the extruded end corner.
	var lifted := creator.base_end + creator.plane_normal * creator.height
	_add_vert_squares(gizmo, to_local,
		PackedVector3Array([creator.base_start, creator.base_end, lifted]))

## The hovered surface face during creation: cyan translucent fill at the
## selection opacity + its outline as thick on-top cyan strokes. While the
## session is still ARMED (no drag yet), also draws the yellow vertex square
## under the cursor.
func _draw_creation_hover(gizmo, mesh_data: PBMeshData, face_index: int) -> void:
	_creation_materials()
	var fill := element_editor.build_face_fill_mesh(mesh_data, face_index)
	if fill != null:
		if _creation_fill_material == null:
			_creation_fill_material = _make_face_fill_material(CREATION_FILL_COLOR)
		gizmo.add_mesh(fill, _creation_fill_material)

	var face := mesh_data.faces[face_index]
	if face == null:
		return
	var positions := mesh_data.positions
	var loop := face.get_distinct_indexes()
	var lines := PackedVector3Array()
	var n := loop.size()
	for i in range(n):
		var a: int = loop[i]
		var b: int = loop[(i + 1) % n]
		if a >= 0 and a < positions.size() and b >= 0 and b < positions.size():
			lines.append(positions[a])
			lines.append(positions[b])
	if lines.size() >= 2:
		_add_thick_lines(gizmo, lines, _creation_edge_material, THICK_LINE_OFFSET * 1.5)

	# ARMED: one square under the cursor (on the hovered surface point).
	if shape_creator != null and shape_creator.state == PBShapeCreator.State.ARMED:
		var node := gizmo.get_node_3d() as Node3D
		if node != null:
			var to_local := node.global_transform.affine_inverse()
			_add_vert_squares(gizmo, to_local, PackedVector3Array([creation_hover_point]))

## Collider inspection overlay over the node's ACTIVE physics shape.
##
## Two layers:
## 1. Bright green x-ray wireframe of the exact collision triangles the
##    physics server holds (raw concave faces / engine debug hull via
##    PBColliderAudit.shape_faces) — shows the collider that EXISTS, never
##    the mesh that "should" produce it.
## 2. A depth-tested solid "contact skin": every triangle INFLATED 3 cm along
##    its FRONT normal (the side Godot physics collides with) and drawn twice
##    — as-is in translucent GREEN, reversed in RED, both back-culled. Read
##    from OUTSIDE the collider:
##      green skin wrapping the mesh  = faces wound correctly;
##      a RED patch                   = that face's collidable side points
##    					INWARD (bodies would tunnel in and be trapped);
##      a patch of skin MISSING       = the face's front points into the mesh
##                                     (inflated into the geometry).
##    The inflation keeps the skin reading outside the render mesh; depth
##    testing keeps far-side backs (the interior views of a sound shell) from
##    bleeding through and reading as false red — an x-ray solid pass cannot
##    distinguish "inverted face" from "far side of a correct shell".
const COLLIDER_SKIN_INFLATE := 0.03

var _collider_front_material: StandardMaterial3D
var _collider_back_material: StandardMaterial3D

func _draw_collider_debug(gizmo, node: PBMesh) -> void:
	var body := node.get_collider_body()
	if body == null:
		return
	var col_shape := body.get_node_or_null(NodePath(PBMesh.COLLIDER_SHAPE_NAME)) as CollisionShape3D
	if col_shape == null or col_shape.shape == null:
		return

	var tris := PBColliderAudit.shape_faces(col_shape.shape)
	if tris.size() < 3:
		return

	# Vertex normals welded by position: corner-sharing triangles get the SAME
	# offset, so the inflated skin stays connected across creases instead of
	# opening rim gaps (through which far-side backs read as false red).
	var vnormal_sums := {}
	for i in range(0, tris.size() - 2, 3):
		var fn := PBColliderAudit.tri_front_normal(tris[i], tris[i + 1], tris[i + 2])
		if fn == Vector3.ZERO:
			continue
		for k in range(3):
			var key := _collider_vert_key(tris[i + k])
			vnormal_sums[key] = vnormal_sums.get(key, Vector3.ZERO) + fn

	var lines := PackedVector3Array()
	var front_tris := PackedVector3Array()
	var back_tris := PackedVector3Array()
	front_tris.resize(tris.size())
	back_tris.resize(tris.size())
	for i in range(0, tris.size() - 2, 3):
		var a := tris[i]
		var b := tris[i + 1]
		var c := tris[i + 2]
		lines.append(a)
		lines.append(b)
		lines.append(b)
		lines.append(c)
		lines.append(c)
		lines.append(a)
		var oa := _collider_skin_offset(a, vnormal_sums)
		var ob := _collider_skin_offset(b, vnormal_sums)
		var oc := _collider_skin_offset(c, vnormal_sums)
		front_tris[i] = a + oa
		front_tris[i + 1] = b + ob
		front_tris[i + 2] = c + oc
		back_tris[i] = a + oa
		back_tris[i + 1] = c + oc
		back_tris[i + 2] = b + ob

	gizmo.add_lines(lines, get_material("pb_collider_debug", gizmo))
	if _collider_front_material == null:
		_collider_front_material = _make_collider_side_material(Color(0.1, 1.0, 0.4, 0.30))
	if _collider_back_material == null:
		_collider_back_material = _make_collider_side_material(Color(1.0, 0.12, 0.1, 0.45))
	gizmo.add_mesh(_tris_to_mesh(front_tris), _collider_front_material)
	gizmo.add_mesh(_tris_to_mesh(back_tris), _collider_back_material)

static func _tris_to_mesh(tris: PackedVector3Array) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = tris
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

static func _collider_vert_key(v: Vector3) -> String:
	return "%d,%d,%d" % [int(round(v.x * 10000.0)), int(round(v.y * 10000.0)), int(round(v.z * 10000.0))]

func _collider_skin_offset(v: Vector3, vnormal_sums: Dictionary) -> Vector3:
	var sum: Vector3 = vnormal_sums.get(_collider_vert_key(v), Vector3.ZERO)
	if sum == Vector3.ZERO:
		return Vector3.ZERO
	return sum.normalized() * COLLIDER_SKIN_INFLATE

## Unshaded translucent material for the collider skin passes. DEPTH-TESTED
## (the skin must be occluded by geometry in front of it — far-side backs
## must not bleed through); CULL_BACK is what makes front vs back winding
## visible per viewpoint.
func _make_collider_side_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = false
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	return mat
