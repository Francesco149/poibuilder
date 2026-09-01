## PBOverlay — Wireframe and element highlight rendering for PBMesh nodes.
##
## Creates overlay MeshInstance3D children on the active PBMesh to draw:
## - Wireframe edges (always, when editing)
## - Vertex dots (in Vertex mode)
## - Edge highlights (in Edge mode)
## - Face highlights (in Face mode)
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

# ==============================================================================
# Internal overlay nodes
# ==============================================================================

## Wireframe edge lines
var _wireframe_instance: MeshInstance3D = null

## Vertex dots (Vertex mode only)
var _vertex_instance: MeshInstance3D = null

# ==============================================================================
# Materials (shared across overlays)
# ==============================================================================

var _wire_material: StandardMaterial3D = null
var _vertex_material: StandardMaterial3D = null
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
	# Slight depth bias to prevent z-fighting with the mesh surface
	_wire_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS

	# Vertex material — unshaded points
	_vertex_material = StandardMaterial3D.new()
	_vertex_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_vertex_material.albedo_color = VERTEX_UNSELECTED_COLOR
	_vertex_material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	_vertex_material.no_depth_test = false
	_vertex_material.render_priority = 2
	_vertex_material.point_size = VERTEX_SIZE
	_vertex_material.use_point_size = true

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

## Rebuild overlay meshes for the current mode.
func rebuild(mode: PBEditor.SelectMode) -> void:
	if _current_mesh == null or _current_mesh.pb_mesh_data == null:
		_destroy_overlay_nodes()
		return
	if not is_instance_valid(_wireframe_instance):
		_create_overlay_nodes()
	_rebuild_wireframe()
	_rebuild_vertex_overlay(mode)

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
	# Extra cull margin so overlay isn't culled prematurely
	_wireframe_instance.extra_cull_margin = 10.0
	_current_mesh.add_child(_wireframe_instance)
	# Don't persist in scene
	_wireframe_instance.owner = null

	# Vertex overlay (used for vertex dots)
	_vertex_instance = MeshInstance3D.new()
	_vertex_instance.name = "_pb_vertex_overlay"
	_vertex_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_vertex_instance.extra_cull_margin = 10.0
	_current_mesh.add_child(_vertex_instance)
	_vertex_instance.owner = null

func _destroy_overlay_nodes() -> void:
	if _wireframe_instance != null and is_instance_valid(_wireframe_instance):
		_wireframe_instance.queue_free()
	_wireframe_instance = null

	if _vertex_instance != null and is_instance_valid(_vertex_instance):
		_vertex_instance.queue_free()
	_vertex_instance = null

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

	# Build an ArrayMesh with PRIMITIVE_LINES
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = line_vertices

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	arr_mesh.surface_set_material(0, _wire_material)

	_wireframe_instance.mesh = arr_mesh

# ==============================================================================
# Vertex / Edge / Face Overlay Rebuild
# ==============================================================================

func _rebuild_vertex_overlay(mode: PBEditor.SelectMode) -> void:
	if _vertex_instance == null or _current_mesh == null:
		_clear_vertex_overlay()
		return
	var data: PBMeshData = _current_mesh.pb_mesh_data
	if data == null:
		_clear_vertex_overlay()
		return

	match mode:
		PBEditor.SelectMode.VERTEX:
			_build_vertex_points(data)
		PBEditor.SelectMode.FACE:
			# In face mode, we don't show vertex dots — wireframe only.
			# Selected face highlights will come in Phase 5 (selection rendering).
			_clear_vertex_overlay()
		PBEditor.SelectMode.EDGE:
			# In edge mode, the wireframe already shows all edges.
			# Selected edge highlights will come in Phase 5.
			_clear_vertex_overlay()
		_:
			_clear_vertex_overlay()

func _build_vertex_points(data: PBMeshData) -> void:
	if _vertex_instance == null:
		return
	var positions: PackedVector3Array = data.positions
	if positions.is_empty():
		_vertex_instance.mesh = null
		return

	# Collect unique vertex positions using shared vertices
	# (one dot per shared vertex group, at the first vertex's position)
	var point_positions := PackedVector3Array()

	if data.shared_vertices.is_empty():
		# No shared vertex groups — show all positions
		point_positions = positions
	else:
		# Show one point per shared vertex group
		for sv in data.shared_vertices:
			if sv != null and sv.indices.size() > 0:
				var idx: int = sv.indices[0]
				if idx >= 0 and idx < positions.size():
					point_positions.append(positions[idx])

	if point_positions.is_empty():
		_vertex_instance.mesh = null
		return

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = point_positions

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	arr_mesh.surface_set_material(0, _vertex_material)

	_vertex_instance.mesh = arr_mesh

func _clear_vertex_overlay() -> void:
	if _vertex_instance != null and is_instance_valid(_vertex_instance):
		_vertex_instance.mesh = null
