## PBGizmo — Draws interactive XYZ axis lines at the selection centroid.
##
## Renders three axis lines (red=X, green=Y, blue=Z) at the centroid of the
## current element selection. The gizmo orientation follows the active
## OrientationSpace setting (Element/Object/World).
##
## Axis lines are drawn as MeshInstance3D children of the active PBMesh node,
## using unshaded materials with no depth test so they're always visible.
## Each axis handle is pickable by screen-space proximity for axis-constrained drags.
@tool
class_name PBGizmo
extends RefCounted

# ==============================================================================
# Constants
# ==============================================================================

## Length of each axis line in world-space units.
const AXIS_LENGTH: float = 1.2

## Radius for screen-space axis picking (pixels).
const AXIS_PICK_RADIUS: float = 12.0

## Colors matching standard 3D gizmo conventions.
const COLOR_X := Color(1.0, 0.2, 0.2, 1.0)
const COLOR_Y := Color(0.2, 1.0, 0.2, 1.0)
const COLOR_Z := Color(0.3, 0.4, 1.0, 1.0)

## Highlighted colors when hovering over an axis.
const COLOR_X_HIGHLIGHT := Color(1.0, 0.6, 0.4, 1.0)
const COLOR_Y_HIGHLIGHT := Color(0.6, 1.0, 0.4, 1.0)
const COLOR_Z_HIGHLIGHT := Color(0.5, 0.7, 1.0, 1.0)

## Axis identifiers.
enum Axis { NONE, X, Y, Z }

# ==============================================================================
# Internal State
# ==============================================================================

## The mesh node this gizmo is attached to.
var _current_mesh: PBMesh = null

## MeshInstance3D node drawing the axis lines.
var _axis_instance: MeshInstance3D = null

## Materials for each axis.
var _mat_x: StandardMaterial3D = null
var _mat_y: StandardMaterial3D = null
var _mat_z: StandardMaterial3D = null

## Cached gizmo basis (columns = axis directions in local space).
var _gizmo_basis: Basis = Basis.IDENTITY

## Cached centroid in LOCAL mesh coordinates.
var _local_centroid: Vector3 = Vector3.ZERO

## Whether the gizmo is currently visible (has valid selection).
var _visible: bool = false

## Logger reference.
var logger: PBLogger = null

# ==============================================================================
# Lifecycle
# ==============================================================================

func _init() -> void:
	_create_materials()

func _create_materials() -> void:
	_mat_x = _make_axis_material(COLOR_X)
	_mat_y = _make_axis_material(COLOR_Y)
	_mat_z = _make_axis_material(COLOR_Z)

static func _make_axis_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	mat.no_depth_test = true
	mat.render_priority = 10
	return mat

# ==============================================================================
# Attach / Detach
# ==============================================================================

## Attach gizmo rendering to a PBMesh node.
func attach(pb_mesh: PBMesh) -> void:
	if _current_mesh == pb_mesh:
		return
	detach()
	_current_mesh = pb_mesh

## Remove all gizmo nodes.
func detach() -> void:
	_destroy_nodes()
	_current_mesh = null
	_visible = false

# ==============================================================================
# Rebuild
# ==============================================================================

## Rebuilds the gizmo for the current selection and orientation space.
## Call this whenever selection, mode, or orientation space changes.
func rebuild(editor: PBEditor) -> void:
	if _current_mesh == null or editor == null:
		_destroy_nodes()
		_visible = false
		return

	if editor.selection == null or editor.selection.is_empty():
		_destroy_nodes()
		_visible = false
		return

	if editor.active_tool == null:
		_destroy_nodes()
		_visible = false
		return

	var mesh_data: PBMeshData = _current_mesh.pb_mesh_data
	if mesh_data == null or mesh_data.positions.is_empty():
		_destroy_nodes()
		_visible = false
		return

	# Compute selected local vertex indices
	var local_indices: PackedInt32Array = _get_selected_indices(editor, mesh_data)
	if local_indices.is_empty():
		_destroy_nodes()
		_visible = false
		return

	# Centroid in local space
	_local_centroid = PBMath.average(mesh_data.positions, local_indices)

	# Compute gizmo basis from orientation space
	_gizmo_basis = _compute_basis(editor, mesh_data, local_indices)

	# Build or rebuild the axis line mesh
	_build_axis_mesh()
	_visible = true

## Returns the selected local vertex indices for the current mode.
func _get_selected_indices(editor: PBEditor, mesh_data: PBMeshData) -> PackedInt32Array:
	var sel: PBSelection = editor.selection
	match editor.select_mode:
		PBEditor.SelectMode.VERTEX:
			return sel.get_selected_vertex_indices()
		PBEditor.SelectMode.EDGE:
			var indices := PackedInt32Array()
			for edge in sel.selected_edges:
				if edge != null:
					indices.append(edge.a)
					indices.append(edge.b)
			return mesh_data.get_coincident_vertices_multi(indices)
		PBEditor.SelectMode.FACE:
			return mesh_data.get_coincident_vertices_from_faces(sel.selected_faces)
		_:
			return PackedInt32Array()

## Computes the gizmo basis (three axis directions) in LOCAL mesh space
## based on the active orientation space.
func _compute_basis(editor: PBEditor, mesh_data: PBMeshData, local_indices: PackedInt32Array) -> Basis:
	var global_xform: Transform3D = _current_mesh.global_transform if _current_mesh != null else Transform3D.IDENTITY

	match editor.orientation_space:
		PBEditor.OrientationSpace.WORLD:
			# World axes, transformed into local space of the mesh node
			if not is_zero_approx(global_xform.basis.determinant()):
				return global_xform.basis.inverse()
			return Basis.IDENTITY

		PBEditor.OrientationSpace.OBJECT:
			# Object local axes = identity in local space
			return Basis.IDENTITY

		PBEditor.OrientationSpace.ELEMENT:
			# Derive from selected element's normal
			return _compute_element_basis(editor, mesh_data, local_indices)
		_:
			return Basis.IDENTITY

## Computes element-local basis from the selected element's face normal.
func _compute_element_basis(editor: PBEditor, mesh_data: PBMeshData, local_indices: PackedInt32Array) -> Basis:
	var face_normal: Vector3 = Vector3.ZERO

	match editor.select_mode:
		PBEditor.SelectMode.FACE:
			# Average normal of selected faces
			var count: int = 0
			for fi in editor.selection.selected_faces:
				if fi >= 0 and fi < mesh_data.faces.size():
					var face: PBFace = mesh_data.faces[fi]
					if face != null:
						var n: Vector3 = PBMath.normal_from_positions(mesh_data.positions, face.get_indexes())
						face_normal += n
						count += 1
			if count > 0:
				face_normal /= float(count)

		PBEditor.SelectMode.EDGE:
			# Average normal of faces adjacent to selected edges
			var lookup: Dictionary = mesh_data.get_shared_vertex_lookup()
			var face_set: Dictionary = {}
			for edge in editor.selection.selected_edges:
				if edge == null:
					continue
				var ce: PBEdge = mesh_data.get_common_edge(edge)
				if ce == null:
					continue
				for fi in range(mesh_data.faces.size()):
					if face_set.has(fi):
						continue
					var face: PBFace = mesh_data.faces[fi]
					if face == null:
						continue
					for fe in face.get_edges():
						var cfe: PBEdge = mesh_data.get_common_edge(fe)
						if cfe != null and cfe.equals(ce):
							face_set[fi] = true
							break
			for fi in face_set:
				var face: PBFace = mesh_data.faces[fi]
				if face != null:
					face_normal += PBMath.normal_from_positions(mesh_data.positions, face.get_indexes())
			if not face_set.is_empty():
				face_normal /= float(face_set.size())

		PBEditor.SelectMode.VERTEX:
			# Average normal of all faces touching selected vertices
			var common_set: Dictionary = {}
			for sv_idx in editor.selection.selected_vertices:
				common_set[sv_idx] = true
			var face_set: Dictionary = {}
			var lookup: Dictionary = mesh_data.get_shared_vertex_lookup()
			for fi in range(mesh_data.faces.size()):
				var face: PBFace = mesh_data.faces[fi]
				if face == null:
					continue
				for idx in face.get_distinct_indexes():
					var cvi: int = lookup.get(idx, -1)
					if common_set.has(cvi):
						face_set[fi] = true
						break
			for fi in face_set:
				var face: PBFace = mesh_data.faces[fi]
				if face != null:
					face_normal += PBMath.normal_from_positions(mesh_data.positions, face.get_indexes())
			if not face_set.is_empty():
				face_normal /= float(face_set.size())

	if face_normal.length_squared() < PBMath.FLT_EPSILON:
		return Basis.IDENTITY

	face_normal = face_normal.normalized()

	# Build a right-handed basis from the face normal (as Y-up-like axis)
	# Normal = Z axis of the gizmo; compute X and Y perpendicular to it
	var up: Vector3 = Vector3.UP if absf(face_normal.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var right: Vector3 = face_normal.cross(up).normalized()
	var forward: Vector3 = right.cross(face_normal).normalized()

	# Basis columns: X=right, Y=forward, Z=normal (so Z is the face normal axis)
	return Basis(right, forward, face_normal)

# ==============================================================================
# Mesh Construction
# ==============================================================================

func _build_axis_mesh() -> void:
	if _current_mesh == null:
		return

	if _axis_instance == null or not is_instance_valid(_axis_instance):
		_axis_instance = MeshInstance3D.new()
		_axis_instance.name = "_pb_gizmo_overlay"
		_axis_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_axis_instance.extra_cull_margin = 100.0
		_current_mesh.add_child(_axis_instance)
		_axis_instance.owner = null

	var arr_mesh := ArrayMesh.new()

	# Build each axis as a separate surface with its own material
	var axes: Array[Dictionary] = [
		{"dir": _gizmo_basis.x, "mat": _mat_x},
		{"dir": _gizmo_basis.y, "mat": _mat_y},
		{"dir": _gizmo_basis.z, "mat": _mat_z},
	]

	for axis_data in axes:
		var dir: Vector3 = axis_data["dir"].normalized()
		var end: Vector3 = _local_centroid + dir * AXIS_LENGTH

		var verts := PackedVector3Array([_local_centroid, end])
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts

		var surface_idx: int = arr_mesh.get_surface_count()
		arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
		arr_mesh.surface_set_material(surface_idx, axis_data["mat"])

	_axis_instance.mesh = arr_mesh

func _destroy_nodes() -> void:
	if _axis_instance != null and is_instance_valid(_axis_instance):
		_axis_instance.queue_free()
	_axis_instance = null

# ==============================================================================
# Axis Picking (Screen-Space Hit Test)
# ==============================================================================

## Tests which axis (if any) the screen position is closest to.
## Returns Axis.X, Y, Z, or NONE if no axis is within AXIS_PICK_RADIUS.
func pick_axis(screen_pos: Vector2, camera: Camera3D) -> Axis:
	if not _visible or _current_mesh == null or camera == null:
		return Axis.NONE

	var global_xform: Transform3D = _current_mesh.global_transform
	var world_centroid: Vector3 = global_xform * _local_centroid

	var cam_pos: Vector3 = camera.global_position
	var cam_fwd: Vector3 = -camera.global_basis.z
	if (world_centroid - cam_pos).dot(cam_fwd) < 0:
		return Axis.NONE

	var best_axis: Axis = Axis.NONE
	var best_dist: float = AXIS_PICK_RADIUS

	var dirs: Array[Vector3] = [_gizmo_basis.x, _gizmo_basis.y, _gizmo_basis.z]
	var axes: Array[Axis] = [Axis.X, Axis.Y, Axis.Z]

	for i in range(3):
		var dir: Vector3 = dirs[i].normalized()
		var world_end: Vector3 = global_xform * (_local_centroid + dir * AXIS_LENGTH)

		var screen_start: Vector2 = camera.unproject_position(world_centroid)
		var screen_end: Vector2 = camera.unproject_position(world_end)

		var dist: float = PBMath.distance_point_line_segment_2d(screen_pos, screen_start, screen_end)
		if dist < best_dist:
			best_dist = dist
			best_axis = axes[i]

	return best_axis

## Returns the world-space direction for the given axis, accounting for
## the current gizmo basis and mesh transform.
func get_axis_direction_world(axis: Axis) -> Vector3:
	if _current_mesh == null:
		return Vector3.ZERO
	var local_dir: Vector3 = Vector3.ZERO
	match axis:
		Axis.X: local_dir = _gizmo_basis.x.normalized()
		Axis.Y: local_dir = _gizmo_basis.y.normalized()
		Axis.Z: local_dir = _gizmo_basis.z.normalized()
		_: return Vector3.ZERO
	return (_current_mesh.global_transform.basis * local_dir).normalized()

## Returns the world-space centroid of the gizmo.
func get_world_centroid() -> Vector3:
	if _current_mesh == null:
		return Vector3.ZERO
	return _current_mesh.global_transform * _local_centroid

## Returns the local basis being used by the gizmo.
func get_basis() -> Basis:
	return _gizmo_basis

## Returns true if the gizmo is currently visible.
func is_visible() -> bool:
	return _visible
