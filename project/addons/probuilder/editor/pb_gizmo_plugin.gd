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

## Verification counter (GUI harness): how many times the creation BASE
## outline branch actually drew lines.
var creation_outline_draws: int = 0

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
	create_material("pb_creation_edge", CREATION_COLOR, false, true)
	create_material("pb_creation_arrow", CREATION_ARROW_COLOR, false, true)
	create_handle_material("pb_center_handle")
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
	var node := gizmo.get_node_3d() as PBMesh
	if node == null or camera == null or not is_editing_node(node):
		return -1
	var id := element_editor.pick_ray(node.pb_mesh_data, node.global_transform, camera, screen_pos)
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
	element_editor.set_subgizmo_transform(node, gizmo.get_subgizmo_selection(), subgizmo_id, transform)
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
		return

	_mirror_engine_selection(gizmo, node, mesh_data)

	# Wireframe (depth-tested). In EDGE mode ProBuilder renders edges as bold
	# black strokes — thicker via stacked parallel lines — with the selection
	# highlighted on top; VERTEX mode uses bolder dark dots; FACE mode keeps
	# the subtle gray wireframe under the translucent face fill.
	var wire_points := PackedVector3Array()
	for edge in mesh_data.get_common_edges():
		if edge.a >= 0 and edge.a < mesh_data.positions.size() \
				and edge.b >= 0 and edge.b < mesh_data.positions.size():
			wire_points.append(mesh_data.positions[edge.a])
			wire_points.append(mesh_data.positions[edge.b])
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
	gizmo.add_handles(PackedVector3Array([acc / float(count)]),
		get_material("pb_center_handle", gizmo), PackedInt32Array([0]), true)

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
	element_editor.commit_center_drag(node, selected, cancel)
	node.update_gizmos()

## Draws each input line (a pair of points) as a center line plus parallel
## offset lines, approximating a thick stroke from any angle. `offset` is the
## world-space distance between sub-lines; `stacks` is how many offset
## directions are drawn (2 = the full five-line stroke, 1 = a thinner
## center+±perp1 stroke).
static func _add_thick_lines(gizmo, pairs: PackedVector3Array, material: Material,
		offset: float = THICK_LINE_OFFSET, stacks: int = 2) -> void:
	var o := offset
	var i: int = 0
	while i + 1 < pairs.size():
		var a: Vector3 = pairs[i]
		var b: Vector3 = pairs[i + 1]
		var dir := (b - a)
		if dir.length_squared() > 0.000000001:
			dir = dir.normalized()
			var perp1 := dir.cross(Vector3.UP)
			if perp1.length_squared() < 0.25:
				perp1 = dir.cross(Vector3.RIGHT)
			perp1 = perp1.normalized() * o
			var perp2 := dir.cross(perp1.normalized()).normalized() * o
			gizmo.add_lines(PackedVector3Array([a, b]), material)
			gizmo.add_lines(PackedVector3Array([a + perp1, b + perp1]), material)
			gizmo.add_lines(PackedVector3Array([a - perp1, b - perp1]), material)
			if stacks >= 2:
				gizmo.add_lines(PackedVector3Array([a + perp2, b + perp2]), material)
				gizmo.add_lines(PackedVector3Array([a - perp2, b - perp2]), material)
		else:
			gizmo.add_lines(PackedVector3Array([a, b]), material)
		i += 2

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
	var fill_meshes: Array[Mesh] = []
	var selected_any: bool = false
	for fi in range(mesh_data.faces.size()):
		if not gizmo.is_subgizmo_selected(fi):
			continue
		selected_any = true
		var fill := element_editor.build_face_fill_mesh(mesh_data, fi)
		if fill != null:
			fill_meshes.append(fill)

	if not selected_any:
		return

	if _face_fill_material == null:
		_face_fill_material = _make_face_fill_material(FACE_FILL_COLOR)
	for fill in fill_meshes:
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
	var positions := mesh_data.positions
	var edges := mesh_data.get_common_edges()
	var selected := {}
	for eid in element_editor.expand_edge_ids(mesh_data, gizmo.get_subgizmo_selection()):
		selected[eid] = true
	var lines := PackedVector3Array()
	var selected_any: bool = false
	for ei in range(edges.size()):
		if not selected.has(ei):
			continue
		selected_any = true
		var edge: PBEdge = edges[ei]
		if edge.a >= 0 and edge.a < positions.size() and edge.b >= 0 and edge.b < positions.size():
			lines.append(positions[edge.a])
			lines.append(positions[edge.b])
	if selected_any and lines.size() >= 2:
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
	var unselected := PackedVector3Array()
	var selected := PackedVector3Array()
	var hovered := PackedVector3Array()
	var hover_id: int = editor.hover_id
	for sv_idx in range(mesh_data.shared_vertices.size()):
		var sv: PBSharedVertex = mesh_data.shared_vertices[sv_idx]
		if sv == null or sv.indices.is_empty():
			continue
		var idx: int = sv.indices[0]
		if idx < 0 or idx >= positions.size():
			continue
		if gizmo.is_subgizmo_selected(sv_idx):
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

## Creation overlays for the preview node: during BASE only the cyan base
## rect outline shows (the mesh itself is hidden — nothing solid appears
## before the height stage); from HEIGHT on, the cyan 3D box bounds (drawn
## on top — visible through the object itself) plus the orange facing arrow
## when the shape has a facing direction.
func _draw_creation_preview(gizmo, mesh_data: PBMeshData, creator: PBShapeCreator) -> void:
	var node := gizmo.get_node_3d() as Node3D
	if creator.state == PBShapeCreator.State.BASE:
		if node == null:
			return
		var to_local := node.global_transform.affine_inverse()
		var corners := creator.base_rect_corners()
		var lines := PackedVector3Array()
		for i in range(corners.size()):
			lines.append(to_local * corners[i])
			lines.append(to_local * corners[(i + 1) % corners.size()])
		gizmo.add_lines(lines, get_material("pb_creation_edge", gizmo))
		creation_outline_draws += 1
		return

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
	gizmo.add_lines(lines, get_material("pb_creation_edge", gizmo))

	var facing := creator.facing_direction()
	if facing == Vector3.ZERO:
		return
	var length: float = clampf(aabb.get_longest_axis_size() * 0.5, 0.3, 2.0)
	var base_center := Vector3(aabb.get_center().x, p0.y, aabb.get_center().z)
	var tip := base_center + facing.normalized() * length
	var arrow := PackedVector3Array([base_center, tip])
	# Arrowhead: two barbs perpendicular to the facing dir in the base plane.
	var side := facing.normalized().cross(Vector3.UP)
	if side.length_squared() < 0.25:
		side = facing.normalized().cross(Vector3.RIGHT)
	side = side.normalized() * length * 0.25
	var up := facing.normalized().cross(side).normalized() * length * 0.25
	arrow.append(tip)
	arrow.append(tip - side - up)
	arrow.append(tip)
	arrow.append(tip + side - up)
	gizmo.add_lines(arrow, get_material("pb_creation_arrow", gizmo))

## The hovered surface face during creation: cyan translucent fill at the
## selection opacity + its outline as thick cyan strokes (edge-mode select
## language, cyan).
func _draw_creation_hover(gizmo, mesh_data: PBMeshData, face_index: int) -> void:
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
		_add_thick_lines(gizmo, lines, get_material("pb_creation_edge", gizmo))
