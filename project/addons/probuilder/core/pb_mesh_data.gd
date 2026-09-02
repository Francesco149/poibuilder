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

## Cached: deduplicated common edges in stable face-scan order
var _common_edges: Array[PBEdge] = []
var _common_edges_valid: bool = false

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
	_common_edges_valid = false
	_normals.clear()

## Returns all unique edges as common (coincident-welded) PBEdges, deduplicated
## by shared vertex group pair, in stable face-scan order. Lazy-cached.
## Subgizmo IDs for edge mode index into this list.
func get_common_edges() -> Array[PBEdge]:
	if not _common_edges_valid:
		_common_edges.clear()
		var seen: Dictionary = {}
		var lookup := get_shared_vertex_lookup()
		for face in faces:
			if face == null:
				continue
			for edge in face.get_edges():
				var ca: int = lookup.get(edge.a, -1)
				var cb: int = lookup.get(edge.b, -1)
				var key := Vector2i(mini(ca, cb), maxi(ca, cb))
				if seen.has(key):
					continue
				seen[key] = true
				var common: PBEdge = get_common_edge(edge)
				_common_edges.append(common if common != null else edge)
		_common_edges_valid = true
	return _common_edges

# ==============================================================================
# Coincident Vertex Queries & Common Index Lookups
# ==============================================================================

## Given a single vertex index, find its shared vertex group and return all vertex
## indices in that group (including the input vertex itself).
## If the vertex is not in any shared group, returns [vertex].
func get_coincident_vertices(vertex: int) -> PackedInt32Array:
	var lookup := get_shared_vertex_lookup()
	if not lookup.has(vertex):
		return PackedInt32Array([vertex])
	var group_idx: int = lookup[vertex]
	if group_idx < 0 or group_idx >= shared_vertices.size():
		return PackedInt32Array([vertex])
	return shared_vertices[group_idx].indices

## Given multiple vertex indices, find all coincident vertices across all their
## shared vertex groups. Deduplicates by group — if two input vertices belong to
## the same group, the group's indices appear only once.
func get_coincident_vertices_multi(vertices: PackedInt32Array) -> PackedInt32Array:
	var result := PackedInt32Array()
	var seen_groups: Dictionary = {}
	var lookup := get_shared_vertex_lookup()
	for v in vertices:
		if not lookup.has(v):
			continue
		var group_idx: int = lookup[v]
		if seen_groups.has(group_idx):
			continue
		seen_groups[group_idx] = true
		if group_idx >= 0 and group_idx < shared_vertices.size():
			result.append_array(shared_vertices[group_idx].indices)
	return result

## Given a set of edges, find all coincident vertices for all edge endpoints.
func get_coincident_vertices_from_edges(edges: Array[PBEdge]) -> PackedInt32Array:
	var verts := PackedInt32Array()
	for edge in edges:
		if edge == null:
			continue
		verts.append(edge.a)
		verts.append(edge.b)
	return get_coincident_vertices_multi(verts)

## Given face indices (indices into the faces array), collect all distinct vertex
## indices from those faces, then return all coincident vertices.
func get_coincident_vertices_from_faces(face_indices: PackedInt32Array) -> PackedInt32Array:
	var verts := PackedInt32Array()
	for fi in face_indices:
		if fi < 0 or fi >= faces.size():
			continue
		var face: PBFace = faces[fi]
		if face == null:
			continue
		verts.append_array(face.get_distinct_indexes())
	return get_coincident_vertices_multi(verts)

## Returns the shared vertex group index for a given local vertex index.
## Returns -1 if not found.
func get_common_vertex(vertex: int) -> int:
	var lookup := get_shared_vertex_lookup()
	return lookup.get(vertex, -1)

## Converts a local edge to a "common" edge (both endpoints mapped to their
## shared vertex group indices). Returns null if edge is null.
func get_common_edge(edge: PBEdge) -> PBEdge:
	if edge == null:
		return null
	var lookup := get_shared_vertex_lookup()
	var ca: int = lookup.get(edge.a, -1)
	var cb: int = lookup.get(edge.b, -1)
	return PBEdge.new(ca, cb)

# ==============================================================================
# Weld Integrity
# ==============================================================================

## Ensures shared vertex groups exist and cover every position referenced by
## the faces. Missing or partial welds make edge/vertex element ids resolve to
## raw position pairs — drags then tear corners apart ("moved those 2 verts").
## Rebuilds welds from coincident positions when damaged; returns true if the
## groups were rebuilt. Never merges groups that already exist (explicit
## unwelds are preserved) — it only heals ABSENT coverage.
func ensure_welds(tolerance: float = 0.0001) -> bool:
	var referenced := {}
	for face in faces:
		if face == null:
			continue
		for idx in face.get_indexes():
			if idx >= 0 and idx < positions.size():
				referenced[idx] = true
	if referenced.is_empty():
		return false

	if shared_vertices.is_empty():
		shared_vertices = PBMeshData.build_welds_from_positions(positions, tolerance)
		invalidate_caches()
		return true

	var lookup := get_shared_vertex_lookup()
	for idx in referenced.keys():
		if not lookup.has(idx):
			shared_vertices = PBMeshData.build_welds_from_positions(positions, tolerance)
			invalidate_caches()
			return true
	return false

## Groups position indices whose coordinates coincide within tolerance.
static func build_welds_from_positions(positions: PackedVector3Array,
		tolerance: float = 0.0001) -> Array[PBSharedVertex]:
	var tol_sq: float = tolerance * tolerance
	var representatives: PackedVector3Array = PackedVector3Array()
	var groups: Array[PackedInt32Array] = []
	for i in range(positions.size()):
		var assigned: int = -1
		for g in range(representatives.size()):
			if representatives[g].distance_squared_to(positions[i]) <= tol_sq:
				assigned = g
				break
		if assigned == -1:
			representatives.append(positions[i])
			groups.append(PackedInt32Array([i]))
		else:
			groups[assigned].append(i)
	var result: Array[PBSharedVertex] = []
	for g in groups:
		result.append(PBSharedVertex.new(g))
	return result

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
# Mesh Compilation & Normals (ToMesh)
# ==============================================================================

## Calculates flat normals for all vertices across all faces.
## Returns a PackedVector3Array of the same size as positions.
func calculate_normals() -> PackedVector3Array:
	var normals := PackedVector3Array()
	normals.resize(positions.size())
	for i in range(normals.size()):
		normals[i] = Vector3.ZERO

	var pos_count: int = positions.size()
	for face in faces:
		if face == null:
			continue
		var idxs := face.get_indexes()
		for tri_i in range(0, idxs.size() - 2, 3):
			var i0: int = idxs[tri_i]
			var i1: int = idxs[tri_i + 1]
			var i2: int = idxs[tri_i + 2]
			if i0 < 0 or i0 >= pos_count or i1 < 0 or i1 >= pos_count or i2 < 0 or i2 >= pos_count:
				continue
			var edge1: Vector3 = positions[i1] - positions[i0]
			var edge2: Vector3 = positions[i2] - positions[i0]
			# Internal data is CCW-from-outside (Unity convention) —
			# normal = edge1 × edge2 points outward
			var cross_prod: Vector3 = edge1.cross(edge2)
			var normal: Vector3 = cross_prod.normalized() if not cross_prod.is_zero_approx() else Vector3.ZERO
			normals[i0] = normal
			normals[i1] = normal
			normals[i2] = normal

	_normals = normals
	return normals

## Returns cached normals, calculating them on demand if empty or size mismatch.
func get_normals() -> PackedVector3Array:
	if _normals.is_empty() or _normals.size() != positions.size():
		calculate_normals()
	return _normals

## Compiles this PBMeshData into a Godot ArrayMesh.
## If existing is provided, clears its surfaces and reuses it; otherwise instantiates a new ArrayMesh.
## Faces are grouped by submesh_index into distinct surfaces.
func to_array_mesh(existing: ArrayMesh = null) -> ArrayMesh:
	var mesh: ArrayMesh = existing if existing != null else ArrayMesh.new()
	mesh.clear_surfaces()

	if positions.is_empty() or faces.is_empty():
		return mesh

	# Internal data is CCW-from-outside (Unity/ProBuilder convention), so
	# calculate_normals() cross products point OUTWARD. Godot front faces are
	# CW-from-outside (see ArrayMesh docs), hence the index reversal below.
	# The reversal only flips which side is culled — the outward direction is
	# a property of the geometry, so normals must NOT be negated.
	# Ground truth: Godot's own BoxMesh stores CW tris whose cross(v1-v0,
	# v2-v0) points inward, with attribute normals pointing outward.
	var normals: PackedVector3Array = calculate_normals()

	# Group faces by submesh_index
	var submesh_faces: Dictionary = {}
	var submesh_indices: Array[int] = []

	for face in faces:
		if face == null:
			continue
		var s_idx: int = face.submesh_index
		if not submesh_faces.has(s_idx):
			submesh_faces[s_idx] = [] as Array[PBFace]
			submesh_indices.append(s_idx)
		submesh_faces[s_idx].append(face)

	submesh_indices.sort()

	var vc: int = positions.size()
	for s_idx in submesh_indices:
		var group_faces: Array = submesh_faces[s_idx]
		var indices := PackedInt32Array()
		for face in group_faces:
			if face != null:
				var fi: PackedInt32Array = face.get_indexes()
				# Reverse each triangle's winding: internal data is CCW-from-outside
				# (Unity convention), Godot front faces are CW-from-outside.
				for tri_i in range(0, fi.size() - 2, 3):
					indices.append(fi[tri_i + 2])
					indices.append(fi[tri_i + 1])
					indices.append(fi[tri_i])

		if indices.is_empty():
			continue

		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = positions
		arrays[Mesh.ARRAY_NORMAL] = normals

		if not textures0.is_empty() and textures0.size() == vc:
			arrays[Mesh.ARRAY_TEX_UV] = textures0

		if not colors.is_empty() and colors.size() == vc:
			arrays[Mesh.ARRAY_COLOR] = colors

		if not tangents.is_empty() and tangents.size() == vc * 4:
			arrays[Mesh.ARRAY_TANGENT] = tangents

		arrays[Mesh.ARRAY_INDEX] = indices

		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	return mesh

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
