## PBOverlay — Wireframe and element highlight rendering for PBMesh nodes.
##
## Creates overlay MeshInstance3D children on the active PBMesh to draw:
## - Wireframe edges (always, when editing)
## - Vertex dots with per-vertex colors (in Vertex mode, selected=cyan, unselected=gray)
## - Edge highlights (in Edge mode, selected edges drawn in cyan on top)
## - Face highlights (in Face mode, selected faces drawn as semi-transparent cyan triangles)
##
## Uses unshaded materials with depth-test LessEqual to render on top
## of the mesh geometry without Z-fighting.
@tool
class_name PBOverlay
extends RefCounted

# ==============================================================================
# Constants — Colors matching ProBuilder defaults
# ==============================================================================

## Wireframe line color (dark gray)
const WIREFRAME_COLOR := Color(0.172, 0.172, 0.172, 1.0)

## Unselected vertex color
const VERTEX_UNSELECTED_COLOR := Color(0.5, 0.5, 0.5, 1.0)

## Selected vertex color (cyan)
const VERTEX_SELECTED_COLOR := Color(0.0, 0.824, 0.937, 1.0)

## Unselected edge color (same as wireframe)
const EDGE_UNSELECTED_COLOR := Color(0.172, 0.172, 0.172, 1.0)

## Selected edge color (cyan)
const EDGE_SELECTED_COLOR := Color(0.0, 0.824, 0.937, 1.0)

## Selected face color (cyan semi-transparent)
const FACE_SELECTED_COLOR := Color(0.0, 0.824, 0.937, 0.33)

## Hover/preselection face color (lighter cyan)
const FACE_HOVER_COLOR := Color(0.0, 0.824, 0.937, 0.15)

## Vertex point size in pixels
const VERTEX_SIZE: float = 5.0

## Selected vertex point size (slightly larger)
const VERTEX_SELECTED_SIZE: float = 7.0

# ==============================================================================
# Internal overlay nodes
# ==============================================================================

## Wireframe edge lines
var _wireframe_instance: MeshInstance3D = null

## Vertex dots (Vertex mode only)
var _vertex_instance: MeshInstance3D = null

## Selection highlight (selected edges in Edge mode, selected faces in Face mode)
var _selection_instance: MeshInstance3D = null

## Selected vertex dots (Vertex mode only — drawn larger on top)
var _selected_vertex_instance: MeshInstance3D = null

# ==============================================================================
# Materials (shared across overlays)
# ==============================================================================

var _wire_material: StandardMaterial3D = null
var _vertex_material: StandardMaterial3D = null
var _selected_vertex_material: StandardMaterial3D = null
var _selected_edge_material: StandardMaterial3D = null
var _face_material: StandardMaterial3D = null

## Current mesh being overlaid
var _current_mesh: PBMesh = null

## Logger
var logger: PBLogger = null

# ==============================================================================
# Lifecycle
# ==============================================================================

func _init() -> void:
	_create_materials()

func _create_materials() -> void:
	# Wireframe material — unshaded lines
	_wire_material = StandardMaterial3D.new()
	_wire_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_wire_material.albedo_color = WIREFRAME_COLOR
	_wire_material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	_wire_material.no_depth_test = false
	_wire_material.render_priority = 1
	_wire_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS

	# Vertex material — unshaded points (unselected)
	_vertex_material = StandardMaterial3D.new()
	_vertex_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_vertex_material.albedo_color = VERTEX_UNSELECTED_COLOR
	_vertex_material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	_vertex_material.no_depth_test = false
	_vertex_material.render_priority = 2
	_vertex_material.point_size = VERTEX_SIZE
	_vertex_material.use_point_size = true

	# Selected vertex material — unshaded points (cyan, larger)
	_selected_vertex_material = StandardMaterial3D.new()
	_selected_vertex_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_selected_vertex_material.albedo_color = VERTEX_SELECTED_COLOR
	_selected_vertex_material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	_selected_vertex_material.no_depth_test = false
	_selected_vertex_material.render_priority = 3
	_selected_vertex_material.point_size = VERTEX_SELECTED_SIZE
	_selected_vertex_material.use_point_size = true

	# Selected edge material — cyan lines
	_selected_edge_material = StandardMaterial3D.new()
	_selected_edge_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_selected_edge_material.albedo_color = EDGE_SELECTED_COLOR
	_selected_edge_material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	_selected_edge_material.no_depth_test = false
	_selected_edge_material.render_priority = 2

	# Face material — semi-transparent unshaded triangles
	_face_material = StandardMaterial3D.new()
	_face_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_face_material.albedo_color = FACE_SELECTED_COLOR
	_face_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_face_material.no_depth_test = false
	_face_material.render_priority = 1
	_face_material.cull_mode = BaseMaterial3D.CULL_DISABLED

# ==============================================================================
# Attach / Detach
# ==============================================================================

## Attach overlay rendering to a PBMesh node.
func attach(pb_mesh: PBMesh) -> void:
	if _current_mesh == pb_mesh:
		return
	detach()
	_current_mesh = pb_mesh
	if _current_mesh == null:
		return
	_create_overlay_nodes()
	if logger:
		logger.debug("render", "Overlay attached to %s" % pb_mesh.name)

## Remove all overlay nodes.
func detach() -> void:
	_destroy_overlay_nodes()
	_current_mesh = null

## Rebuild overlay meshes for the current mode and selection.
func rebuild(mode: PBEditor.SelectMode, selection: PBSelection = null) -> void:
	if _current_mesh == null or _current_mesh.pb_mesh_data == null:
		_destroy_overlay_nodes()
		return
	if not is_instance_valid(_wireframe_instance):
		_create_overlay_nodes()
	_rebuild_wireframe()
	_rebuild_element_overlay(mode, selection)

# ==============================================================================
# Overlay Node Management
# ==============================================================================

func _create_overlay_nodes() -> void:
	if _current_mesh == null:
		return

	# Wireframe overlay
	_wireframe_instance = MeshInstance3D.new()
	_wireframe_instance.name = "_pb_wireframe_overlay"
	_wireframe_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_wireframe_instance.extra_cull_margin = 10.0
	_current_mesh.add_child(_wireframe_instance)
	_wireframe_instance.owner = null

	# Vertex overlay (unselected dots)
	_vertex_instance = MeshInstance3D.new()
	_vertex_instance.name = "_pb_vertex_overlay"
	_vertex_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_vertex_instance.extra_cull_margin = 10.0
	_current_mesh.add_child(_vertex_instance)
	_vertex_instance.owner = null

	# Selected vertex overlay (selected dots, drawn on top)
	_selected_vertex_instance = MeshInstance3D.new()
	_selected_vertex_instance.name = "_pb_selected_vertex_overlay"
	_selected_vertex_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_selected_vertex_instance.extra_cull_margin = 10.0
	_current_mesh.add_child(_selected_vertex_instance)
	_selected_vertex_instance.owner = null

	# Selection highlight overlay (edges or face tris)
	_selection_instance = MeshInstance3D.new()
	_selection_instance.name = "_pb_selection_overlay"
	_selection_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_selection_instance.extra_cull_margin = 10.0
	_current_mesh.add_child(_selection_instance)
	_selection_instance.owner = null

func _destroy_overlay_nodes() -> void:
	if _wireframe_instance != null and is_instance_valid(_wireframe_instance):
		_wireframe_instance.queue_free()
	_wireframe_instance = null

	if _vertex_instance != null and is_instance_valid(_vertex_instance):
		_vertex_instance.queue_free()
	_vertex_instance = null

	if _selected_vertex_instance != null and is_instance_valid(_selected_vertex_instance):
		_selected_vertex_instance.queue_free()
	_selected_vertex_instance = null

	if _selection_instance != null and is_instance_valid(_selection_instance):
		_selection_instance.queue_free()
	_selection_instance = null

# ==============================================================================
# Wireframe Rebuild
# ==============================================================================

func _rebuild_wireframe() -> void:
	if _wireframe_instance == null or _current_mesh == null:
		return
	var data: PBMeshData = _current_mesh.pb_mesh_data
	if data == null:
		_wireframe_instance.mesh = null
		return

	var positions: PackedVector3Array = data.positions
	if positions.is_empty():
		_wireframe_instance.mesh = null
		return

	# Collect all edge line segments from all faces
	var line_vertices := PackedVector3Array()
	for face in data.faces:
		if face == null:
			continue
		var edges: Array[PBEdge] = face.get_edges()
		for edge in edges:
			if edge.a >= 0 and edge.a < positions.size() and edge.b >= 0 and edge.b < positions.size():
				line_vertices.append(positions[edge.a])
				line_vertices.append(positions[edge.b])

	if line_vertices.is_empty():
		_wireframe_instance.mesh = null
		return

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = line_vertices

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	arr_mesh.surface_set_material(0, _wire_material)

	_wireframe_instance.mesh = arr_mesh

# ==============================================================================
# Element Overlay Rebuild (Vertex / Edge / Face with Selection)
# ==============================================================================

func _rebuild_element_overlay(mode: PBEditor.SelectMode, selection: PBSelection) -> void:
	match mode:
		PBEditor.SelectMode.VERTEX:
			_build_vertex_points_with_selection(selection)
			_clear_selection_overlay()
		PBEditor.SelectMode.EDGE:
			_clear_vertex_overlay()
			_clear_selected_vertex_overlay()
			_build_selected_edges(selection)
		PBEditor.SelectMode.FACE:
			_clear_vertex_overlay()
			_clear_selected_vertex_overlay()
			_build_selected_faces(selection)
		_:
			_clear_vertex_overlay()
			_clear_selected_vertex_overlay()
			_clear_selection_overlay()

## Builds vertex dots: all unselected in gray, selected in cyan (separate mesh).
func _build_vertex_points_with_selection(selection: PBSelection) -> void:
	if _vertex_instance == null or _current_mesh == null:
		return
	var data: PBMeshData = _current_mesh.pb_mesh_data
	if data == null:
		_clear_vertex_overlay()
		_clear_selected_vertex_overlay()
		return

	var positions: PackedVector3Array = data.positions
	if positions.is_empty():
		_clear_vertex_overlay()
		_clear_selected_vertex_overlay()
		return

	var unselected_points := PackedVector3Array()
	var selected_points := PackedVector3Array()

	if data.shared_vertices.is_empty():
		# No shared vertex groups — show all as unselected
		unselected_points = positions
	else:
		for sv_idx in range(data.shared_vertices.size()):
			var sv: PBSharedVertex = data.shared_vertices[sv_idx]
			if sv == null or sv.indices.is_empty():
				continue
			var idx: int = sv.indices[0]
			if idx < 0 or idx >= positions.size():
				continue
			if selection != null and selection.is_vertex_selected(sv_idx):
				selected_points.append(positions[idx])
			else:
				unselected_points.append(positions[idx])

	# Unselected vertex dots
	if unselected_points.is_empty():
		_vertex_instance.mesh = null
	else:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = unselected_points
		var arr_mesh := ArrayMesh.new()
		arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
		arr_mesh.surface_set_material(0, _vertex_material)
		_vertex_instance.mesh = arr_mesh

	# Selected vertex dots (larger, cyan)
	if selected_points.is_empty() or _selected_vertex_instance == null:
		_clear_selected_vertex_overlay()
	else:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = selected_points
		var arr_mesh := ArrayMesh.new()
		arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
		arr_mesh.surface_set_material(0, _selected_vertex_material)
		_selected_vertex_instance.mesh = arr_mesh

## Builds highlighted edge lines for selected edges.
func _build_selected_edges(selection: PBSelection) -> void:
	if _selection_instance == null or _current_mesh == null:
		_clear_selection_overlay()
		return
	var data: PBMeshData = _current_mesh.pb_mesh_data
	if data == null or selection == null or selection.selected_edges.is_empty():
		_clear_selection_overlay()
		return

	var positions := data.positions
	var line_vertices := PackedVector3Array()

	for edge in selection.selected_edges:
		if edge == null:
			continue
		if edge.a >= 0 and edge.a < positions.size() and edge.b >= 0 and edge.b < positions.size():
			line_vertices.append(positions[edge.a])
			line_vertices.append(positions[edge.b])

	if line_vertices.is_empty():
		_clear_selection_overlay()
		return

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = line_vertices

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	arr_mesh.surface_set_material(0, _selected_edge_material)

	_selection_instance.mesh = arr_mesh

## Builds highlighted face triangles for selected faces.
func _build_selected_faces(selection: PBSelection) -> void:
	if _selection_instance == null or _current_mesh == null:
		_clear_selection_overlay()
		return
	var data: PBMeshData = _current_mesh.pb_mesh_data
	if data == null or selection == null or selection.selected_faces.is_empty():
		_clear_selection_overlay()
		return

	var positions := data.positions
	var tri_vertices := PackedVector3Array()

	for fi in selection.selected_faces:
		if fi < 0 or fi >= data.faces.size():
			continue
		var face: PBFace = data.faces[fi]
		if face == null:
			continue
		var indexes := face.get_indexes()
		for tri_i in range(0, indexes.size() - 2, 3):
			var i0: int = indexes[tri_i]
			var i1: int = indexes[tri_i + 1]
			var i2: int = indexes[tri_i + 2]
			if i0 >= 0 and i0 < positions.size() and i1 >= 0 and i1 < positions.size() and i2 >= 0 and i2 < positions.size():
				tri_vertices.append(positions[i0])
				tri_vertices.append(positions[i1])
				tri_vertices.append(positions[i2])

	if tri_vertices.is_empty():
		_clear_selection_overlay()
		return

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = tri_vertices

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	arr_mesh.surface_set_material(0, _face_material)

	_selection_instance.mesh = arr_mesh

# ==============================================================================
# Clear Helpers
# ==============================================================================

func _clear_vertex_overlay() -> void:
	if _vertex_instance != null and is_instance_valid(_vertex_instance):
		_vertex_instance.mesh = null

func _clear_selected_vertex_overlay() -> void:
	if _selected_vertex_instance != null and is_instance_valid(_selected_vertex_instance):
		_selected_vertex_instance.mesh = null

func _clear_selection_overlay() -> void:
	if _selection_instance != null and is_instance_valid(_selection_instance):
		_selection_instance.mesh = null
