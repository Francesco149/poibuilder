## PBMeshData — Core editable mesh data container for ProBuilder.
##
## Stores vertex positions, per-vertex attributes (UV0, colors, tangents),
## faces (PBFace), and shared vertex/texture topological groups.
@tool
class_name PBMeshData
extends Resource

# ==============================================================================
# Serialized / Exported Properties
# ==============================================================================

## Vertex positions in local space.
@export var positions: PackedVector3Array = PackedVector3Array()

## Per-vertex UV channel 0.
@export var textures0: PackedVector2Array = PackedVector2Array()

## Per-vertex colors.
@export var colors: PackedColorArray = PackedColorArray()

## Per-vertex tangents (packed as groups of 4 floats: x,y,z,w per vertex).
@export var tangents: PackedFloat32Array = PackedFloat32Array()

## Polygon faces — stored as an Array of PBFace resources.
@export var faces: Array[PBFace] = []

## Shared vertex groups — groups of vertex indices that share the same spatial position.
@export var shared_vertices: Array[PBSharedVertex] = []

## Shared texture groups — groups of vertex indices that share continuous UV coordinates.
@export var shared_textures: Array[PBSharedVertex] = []

# ==============================================================================
# Non-Serialized / Cached Fields
# ==============================================================================

## Cached: vertex_index -> shared_vertex_group_index
var _shared_vertex_lookup: Dictionary = {}
var _shared_vertex_lookup_valid: bool = false

## Cached: vertex_index -> shared_texture_group_index
var _shared_texture_lookup: Dictionary = {}
var _shared_texture_lookup_valid: bool = false

## Cached normals (calculated on demand, not serialized)
var _normals: PackedVector3Array = PackedVector3Array()

# ==============================================================================
# Property Accessors (Computed, Read-Only)
# ==============================================================================

## Total number of vertex positions.
func vertex_count() -> int:
	return positions.size()

## Total number of faces.
func face_count() -> int:
	return faces.size()

## Total number of triangles across all faces.
func triangle_count() -> int:
	var count: int = 0
	for face in faces:
		if face != null:
			count += face.get_indexes().size() / 3
	return count

## Total number of vertex indices across all faces.
func index_count() -> int:
	var count: int = 0
	for face in faces:
		if face != null:
			count += face.get_indexes().size()
	return count

## Total number of perimeter edges across all faces.
func edge_count() -> int:
	var count: int = 0
	for face in faces:
		if face != null:
			count += face.get_edges().size()
	return count

# ==============================================================================
# Shared Vertex Lookup & Cache Management
# ==============================================================================

## Returns the shared vertex lookup dictionary (vertex_index -> group_index).
## Lazy-cached; rebuilt when invalidated.
func get_shared_vertex_lookup() -> Dictionary:
	if not _shared_vertex_lookup_valid:
		_shared_vertex_lookup = PBSharedVertex.build_lookup(shared_vertices)
		_shared_vertex_lookup_valid = true
	return _shared_vertex_lookup

## Returns the shared texture lookup dictionary (vertex_index -> group_index).
## Lazy-cached; rebuilt when invalidated.
func get_shared_texture_lookup() -> Dictionary:
	if not _shared_texture_lookup_valid:
		_shared_texture_lookup = PBSharedVertex.build_lookup(shared_textures)
		_shared_texture_lookup_valid = true
	return _shared_texture_lookup

## Invalidates the shared vertex lookup cache.
func invalidate_shared_vertex_lookup() -> void:
	_shared_vertex_lookup_valid = false

## Invalidates the shared texture lookup cache.
func invalidate_shared_texture_lookup() -> void:
	_shared_texture_lookup_valid = false

## Invalidates all caches.
func invalidate_caches() -> void:
	invalidate_shared_vertex_lookup()
	invalidate_shared_texture_lookup()

# ==============================================================================
# Data Setters
# ==============================================================================

## Sets positions, must match the total distinct vertex count referenced by faces.
func set_positions(p_positions: PackedVector3Array) -> void:
	positions = p_positions

## Sets faces and invalidates caches.
func set_faces(p_faces: Array[PBFace]) -> void:
	faces = p_faces
	invalidate_caches()

## Sets shared vertices and invalidates the shared vertex lookup cache.
func set_shared_vertices(p_shared: Array[PBSharedVertex]) -> void:
	shared_vertices = p_shared
	invalidate_shared_vertex_lookup()

## Sets shared textures and invalidates the shared texture lookup cache.
func set_shared_textures(p_shared: Array[PBSharedVertex]) -> void:
	shared_textures = p_shared
	invalidate_shared_texture_lookup()

# ==============================================================================
# Validation
# ==============================================================================

## Checks if the mesh data is valid and internally consistent.
## Returns an empty string if valid, or an error description if not.
func validate() -> String:
	if positions.is_empty():
		return "No positions"
	if faces.is_empty():
		return "No faces"
	var vc: int = positions.size()
	for i in range(faces.size()):
		var face: PBFace = faces[i]
		if face == null:
			return "Null face at index %d" % i
		var idxs: PackedInt32Array = face.get_indexes()
		if idxs.size() % 3 != 0:
			return "Face %d has %d indices (not multiple of 3)" % [i, idxs.size()]
		for idx in idxs:
			if idx < 0 or idx >= vc:
				return "Face %d references vertex %d (out of range 0..%d)" % [i, idx, vc - 1]
	# Check textures0 size if present
	if not textures0.is_empty() and textures0.size() != vc:
		return "textures0 size %d != vertex count %d" % [textures0.size(), vc]
	# Check colors size if present
	if not colors.is_empty() and colors.size() != vc:
		return "colors size %d != vertex count %d" % [colors.size(), vc]
	# Check tangents size if present (4 floats per vertex)
	if not tangents.is_empty() and tangents.size() != vc * 4:
		return "tangents size %d != vertex count * 4 (%d)" % [tangents.size(), vc * 4]
	return ""

# ==============================================================================
# Utility: Clear
# ==============================================================================

## Clears all mesh data and invalidates caches.
func clear() -> void:
	positions.clear()
	textures0.clear()
	colors.clear()
	tangents.clear()
	faces.clear()
	shared_vertices.clear()
	shared_textures.clear()
	_normals.clear()
	invalidate_caches()

# ==============================================================================
# Utility: Cube Builder
# ==============================================================================

## Creates a PBMeshData representing a unit cube centered at origin.
## 8 shared vertex positions, 6 faces (quads, each as 2 triangles = 6 indices per face).
## Total: 24 distinct vertices (4 per face), 36 indices, 6 faces.
static func create_cube(size: float = 1.0) -> PBMeshData:
	var mesh_data := PBMeshData.new()
	var h: float = size * 0.5

	# 24 vertex positions (4 per face, 6 faces)
	# Right-handed Y-up coordinates, CCW winding looking from outside at face:
	mesh_data.positions = PackedVector3Array([
		# Face 0: Front (Z = -h)
		Vector3(h, -h, -h), Vector3(-h, -h, -h), Vector3(-h, h, -h), Vector3(h, h, -h),
		# Face 1: Back (Z = +h)
		Vector3(-h, -h, h), Vector3(h, -h, h), Vector3(h, h, h), Vector3(-h, h, h),
		# Face 2: Left (X = -h)
		Vector3(-h, -h, -h), Vector3(-h, -h, h), Vector3(-h, h, h), Vector3(-h, h, -h),
		# Face 3: Right (X = +h)
		Vector3(h, -h, h), Vector3(h, -h, -h), Vector3(h, h, -h), Vector3(h, h, h),
		# Face 4: Top (Y = +h)
		Vector3(-h, h, -h), Vector3(-h, h, h), Vector3(h, h, h), Vector3(h, h, -h),
		# Face 5: Bottom (Y = -h)
		Vector3(-h, -h, h), Vector3(-h, -h, -h), Vector3(h, -h, -h), Vector3(h, -h, h),
	])

	# 24 UVs (4 per face, matching 0..3 local quad vertex order)
	var face_uvs: PackedVector2Array = PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(1.0, 0.0),
		Vector2(1.0, 1.0),
		Vector2(0.0, 1.0),
	])
	mesh_data.textures0 = PackedVector2Array()
	for _f in range(6):
		mesh_data.textures0.append_array(face_uvs)

	# 6 Faces (each 2 triangles = 6 indices)
	mesh_data.faces = []
	for i in range(6):
		var base: int = i * 4
		var face := PBFace.new(PackedInt32Array([
			base + 0, base + 1, base + 2,
			base + 2, base + 3, base + 0
		]))
		mesh_data.faces.append(face)

	# 8 Shared vertex groups (one per 3D corner, each containing 3 vertices from adjacent faces)
	mesh_data.shared_vertices = [
		PBSharedVertex.new(PackedInt32Array([1, 8, 21])),   # Corner (-h, -h, -h)
		PBSharedVertex.new(PackedInt32Array([0, 13, 22])),  # Corner (+h, -h, -h)
		PBSharedVertex.new(PackedInt32Array([2, 11, 16])),  # Corner (-h, +h, -h)
		PBSharedVertex.new(PackedInt32Array([3, 14, 19])),  # Corner (+h, +h, -h)
		PBSharedVertex.new(PackedInt32Array([4, 9, 20])),   # Corner (-h, -h, +h)
		PBSharedVertex.new(PackedInt32Array([5, 12, 23])),  # Corner (+h, -h, +h)
		PBSharedVertex.new(PackedInt32Array([7, 10, 17])),  # Corner (-h, +h, +h)
		PBSharedVertex.new(PackedInt32Array([6, 15, 18])),  # Corner (+h, +h, +h)
	]

	mesh_data.shared_textures = []
	mesh_data.invalidate_caches()
	return mesh_data
