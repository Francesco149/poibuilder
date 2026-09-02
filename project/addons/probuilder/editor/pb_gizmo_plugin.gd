## PBGizmoPlugin — Native editor integration via EditorNode3DGizmoPlugin subgizmos.
##
## This is THE integration layer between ProBuilder and the Godot 3D editor.
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
const EDGE_MODE_WIREFRAME_COLOR := Color(0.02, 0.02, 0.02, 1.0)
const SELECTED_COLOR := Color(0.0, 0.824, 0.937, 1.0)
const FACE_FILL_COLOR := Color(0.0, 0.824, 0.937, 0.35)
const VERTEX_COLOR := Color(0.05, 0.05, 0.05, 1.0)
const VERTEX_DOT_SIZE: float = 7.0
const VERTEX_DOT_SELECTED_SIZE: float = 11.0

## World-space offset between the sub-lines of a "thick" edge. Godot lines are
## always 1px; stacking parallel lines fakes ProBuilder-style thickness.
const THICK_LINE_OFFSET: float = 0.006

# ==============================================================================
# Wiring (set by ProBuilderPlugin on registration)
# ==============================================================================

## Shared editor state (active mesh, select mode, orientation space, selection).
var editor: PBEditor = null

## Runtime-safe element logic (drag state, math, undo payload).
var element_editor: PBElementEditor = PBElementEditor.new()

## Logger for diagnostics.
var logger: PBLogger = null:
	set = set_logger

# Point materials for vertex dots (need point size; plugin-created materials
# cannot express it).
var _vertex_dot_material: StandardMaterial3D
var _vertex_dot_selected_material: StandardMaterial3D

## Cached depth-tested face fill material (built lazily).
var _face_fill_material: StandardMaterial3D

# ==============================================================================
# Lifecycle
# ==============================================================================

func _init() -> void:
	create_material("pb_wireframe", WIREFRAME_COLOR, false, false)
	create_material("pb_wireframe_edge", EDGE_MODE_WIREFRAME_COLOR, false, false)
	create_material("pb_selected_edge", SELECTED_COLOR, false, true)
	_vertex_dot_material = _make_point_material(VERTEX_COLOR, VERTEX_DOT_SIZE)
	_vertex_dot_selected_material = _make_point_material(SELECTED_COLOR, VERTEX_DOT_SELECTED_SIZE)

func set_logger(value: PBLogger) -> void:
	logger = value
	element_editor.logger = value

static func _make_point_material(color: Color, point_size: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	mat.no_depth_test = false
	mat.use_point_size = true
	mat.point_size = point_size
	return mat

func _make_face_fill_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = FACE_FILL_COLOR
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
	return "ProBuilderMesh"

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
	return element_editor.pick_ray(node.pb_mesh_data, node.global_transform, camera, screen_pos)

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
			_add_thick_lines(gizmo, wire_points, get_material("pb_wireframe_edge", gizmo))
		else:
			gizmo.add_lines(wire_points, get_material("pb_wireframe", gizmo))

	if not is_editing_node(node):
		return

	match editor.select_mode:
		PBEditor.SelectMode.FACE:
			_draw_selected_faces(gizmo, mesh_data)
		PBEditor.SelectMode.EDGE:
			_draw_selected_edges(gizmo, mesh_data)
		PBEditor.SelectMode.VERTEX:
			_draw_vertex_dots(gizmo, mesh_data)

## Draws each input line (a pair of points) as a center line plus four
## parallel offset lines, approximating a thick stroke from any angle.
static func _add_thick_lines(gizmo, pairs: PackedVector3Array, material: Material) -> void:
	var o := THICK_LINE_OFFSET
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
		_face_fill_material = _make_face_fill_material()
	for fill in fill_meshes:
		gizmo.add_mesh(fill, _face_fill_material)

## Selected edges as bright on-top strokes (thick in EDGE mode).
func _draw_selected_edges(gizmo, mesh_data: PBMeshData) -> void:
	var positions := mesh_data.positions
	var edges := mesh_data.get_common_edges()
	var lines := PackedVector3Array()
	var selected_any: bool = false
	for ei in range(edges.size()):
		if not gizmo.is_subgizmo_selected(ei):
			continue
		selected_any = true
		var edge: PBEdge = edges[ei]
		if edge.a >= 0 and edge.a < positions.size() and edge.b >= 0 and edge.b < positions.size():
			lines.append(positions[edge.a])
			lines.append(positions[edge.b])
	if selected_any and lines.size() >= 2:
		_add_thick_lines(gizmo, lines, get_material("pb_selected_edge", gizmo))

## All shared vertices as gray dots, selected ones as cyan dots.
func _draw_vertex_dots(gizmo, mesh_data: PBMeshData) -> void:
	var positions := mesh_data.positions
	var unselected := PackedVector3Array()
	var selected := PackedVector3Array()
	for sv_idx in range(mesh_data.shared_vertices.size()):
		var sv: PBSharedVertex = mesh_data.shared_vertices[sv_idx]
		if sv == null or sv.indices.is_empty():
			continue
		var idx: int = sv.indices[0]
		if idx < 0 or idx >= positions.size():
			continue
		if gizmo.is_subgizmo_selected(sv_idx):
			selected.append(positions[idx])
		else:
			unselected.append(positions[idx])

	_add_points_mesh(gizmo, unselected, _vertex_dot_material)
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
