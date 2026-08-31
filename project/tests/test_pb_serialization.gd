## Test: PBMeshData Serialization Round-Trip
##
## Verifies that PBMeshData and its child resources (PBFace, PBSharedVertex)
## can be saved to and loaded from .tres resource files with complete data fidelity.
extends GutTest

const TEMP_CUBE_PATH: String = "res://tests/temp_test_cube.tres"
const TEMP_MODIFIED_PATH: String = "res://tests/temp_test_modified.tres"
const TEMP_ATTRIBUTES_PATH: String = "res://tests/temp_test_attributes.tres"
const TEMP_EMPTY_PATH: String = "res://tests/temp_test_empty.tres"
const TEMP_CUSTOM_PATH: String = "res://tests/temp_test_custom.tres"

var _temp_files: Array[String] = [
	TEMP_CUBE_PATH,
	TEMP_MODIFIED_PATH,
	TEMP_ATTRIBUTES_PATH,
	TEMP_EMPTY_PATH,
	TEMP_CUSTOM_PATH,
]

func before_each() -> void:
	_cleanup_temp_files()

func after_each() -> void:
	_cleanup_temp_files()

func after_all() -> void:
	_cleanup_temp_files()

func _cleanup_temp_files() -> void:
	for path in _temp_files:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

## Helper to save a PBMeshData and reload it cleanly from disk without memory cache
func _save_and_load(mesh_data: PBMeshData, path: String) -> PBMeshData:
	var save_err: Error = ResourceSaver.save(mesh_data, path)
	assert_eq(save_err, OK, "ResourceSaver.save should succeed for %s" % path)
	if save_err != OK:
		return null

	# Load with CACHE_MODE_IGNORE to ensure a freshly parsed instance is constructed
	var loaded_res: Resource = ResourceLoader.load(path, "PBMeshData", ResourceLoader.CACHE_MODE_IGNORE)
	assert_not_null(loaded_res, "ResourceLoader.load should return a valid resource for %s" % path)
	assert_true(loaded_res is PBMeshData, "Loaded resource should be an instance of PBMeshData")
	return loaded_res as PBMeshData

# ==============================================================================
# 1. Basic Round-Trip (Cube)
# ==============================================================================

func test_cube_roundtrip():
	var cube: PBMeshData = PBMeshData.create_cube(2.0)
	var loaded: PBMeshData = _save_and_load(cube, TEMP_CUBE_PATH)
	assert_not_null(loaded, "Loaded cube should not be null")
	if loaded == null:
		return

	# Verification that loaded object is a separate instance, not same reference
	assert_ne(loaded, cube, "Loaded instance must be a distinct object")

	# Validation check
	assert_eq(loaded.validate(), "", "Loaded cube should be valid")

	# Vertex and face counts
	assert_eq(loaded.vertex_count(), cube.vertex_count(), "Vertex count must match")
	assert_eq(loaded.face_count(), cube.face_count(), "Face count must match")
	assert_eq(loaded.triangle_count(), cube.triangle_count(), "Triangle count must match")
	assert_eq(loaded.index_count(), cube.index_count(), "Index count must match")
	assert_eq(loaded.edge_count(), cube.edge_count(), "Edge count must match")

	# Positions comparison
	assert_eq(loaded.positions.size(), cube.positions.size(), "Positions array size must match")
	for i in range(cube.positions.size()):
		assert_almost_eq(loaded.positions[i].x, cube.positions[i].x, 0.0001, "Position[%d].x must match" % i)
		assert_almost_eq(loaded.positions[i].y, cube.positions[i].y, 0.0001, "Position[%d].y must match" % i)
		assert_almost_eq(loaded.positions[i].z, cube.positions[i].z, 0.0001, "Position[%d].z must match" % i)

	# Textures0 (UV0) comparison
	assert_eq(loaded.textures0.size(), cube.textures0.size(), "Textures0 array size must match")
	for i in range(cube.textures0.size()):
		assert_almost_eq(loaded.textures0[i].x, cube.textures0[i].x, 0.0001, "UV0[%d].x must match" % i)
		assert_almost_eq(loaded.textures0[i].y, cube.textures0[i].y, 0.0001, "UV0[%d].y must match" % i)

	# Faces comparison
	assert_eq(loaded.faces.size(), cube.faces.size(), "Faces array size must match")
	for i in range(cube.faces.size()):
		var orig_face: PBFace = cube.faces[i]
		var load_face: PBFace = loaded.faces[i]
		assert_not_null(load_face, "Loaded face[%d] should not be null" % i)
		if load_face == null:
			continue

		# Face indices
		var orig_idxs: PackedInt32Array = orig_face.get_indexes()
		var load_idxs: PackedInt32Array = load_face.get_indexes()
		assert_eq(load_idxs.size(), orig_idxs.size(), "Face[%d] indexes size must match" % i)
		for j in range(orig_idxs.size()):
			assert_eq(load_idxs[j], orig_idxs[j], "Face[%d] index[%d] must match" % [i, j])

		# Distinct indices & edges lazy-cached behavior
		assert_eq(load_face.get_distinct_indexes(), orig_face.get_distinct_indexes(), "Face[%d] distinct indexes must match" % i)
		assert_eq(load_face.get_edges().size(), orig_face.get_edges().size(), "Face[%d] edge count must match" % i)
		assert_eq(load_face.is_quad(), orig_face.is_quad(), "Face[%d] is_quad must match" % i)
		assert_eq(load_face.to_quad(), orig_face.to_quad(), "Face[%d] to_quad must match" % i)

		# Face properties
		assert_eq(load_face.smoothing_group, orig_face.smoothing_group, "Face[%d] smoothing_group must match" % i)
		assert_eq(load_face.submesh_index, orig_face.submesh_index, "Face[%d] submesh_index must match" % i)
		assert_eq(load_face.manual_uv, orig_face.manual_uv, "Face[%d] manual_uv must match" % i)
		assert_eq(load_face.texture_group, orig_face.texture_group, "Face[%d] texture_group must match" % i)
		assert_eq(load_face.element_group, orig_face.element_group, "Face[%d] element_group must match" % i)

		# Auto-UV settings
		assert_almost_eq(load_face.uv_offset.x, orig_face.uv_offset.x, 0.0001, "Face[%d] uv_offset.x must match" % i)
		assert_almost_eq(load_face.uv_offset.y, orig_face.uv_offset.y, 0.0001, "Face[%d] uv_offset.y must match" % i)
		assert_almost_eq(load_face.uv_rotation, orig_face.uv_rotation, 0.0001, "Face[%d] uv_rotation must match" % i)
		assert_almost_eq(load_face.uv_scale.x, orig_face.uv_scale.x, 0.0001, "Face[%d] uv_scale.x must match" % i)
		assert_almost_eq(load_face.uv_scale.y, orig_face.uv_scale.y, 0.0001, "Face[%d] uv_scale.y must match" % i)
		assert_eq(load_face.uv_use_world_space, orig_face.uv_use_world_space, "Face[%d] uv_use_world_space must match" % i)
		assert_eq(load_face.uv_flip_u, orig_face.uv_flip_u, "Face[%d] uv_flip_u must match" % i)
		assert_eq(load_face.uv_flip_v, orig_face.uv_flip_v, "Face[%d] uv_flip_v must match" % i)
		assert_eq(load_face.uv_swap_uv, orig_face.uv_swap_uv, "Face[%d] uv_swap_uv must match" % i)
		assert_eq(load_face.uv_fill, orig_face.uv_fill, "Face[%d] uv_fill must match" % i)
		assert_eq(load_face.uv_anchor, orig_face.uv_anchor, "Face[%d] uv_anchor must match" % i)

	# Shared vertices comparison
	assert_eq(loaded.shared_vertices.size(), cube.shared_vertices.size(), "Shared vertices count must match")
	for i in range(cube.shared_vertices.size()):
		var orig_sv: PBSharedVertex = cube.shared_vertices[i]
		var load_sv: PBSharedVertex = loaded.shared_vertices[i]
		assert_not_null(load_sv, "Loaded shared_vertex[%d] should not be null" % i)
		if load_sv == null:
			continue
		assert_eq(load_sv.indices.size(), orig_sv.indices.size(), "Shared vertex[%d] size must match" % i)
		for j in range(orig_sv.indices.size()):
			assert_eq(load_sv.indices[j], orig_sv.indices[j], "Shared vertex[%d] index[%d] must match" % [i, j])

	# Shared vertex lookup comparison
	var orig_lookup: Dictionary = cube.get_shared_vertex_lookup()
	var load_lookup: Dictionary = loaded.get_shared_vertex_lookup()
	assert_eq(load_lookup.size(), orig_lookup.size(), "Shared vertex lookup size must match")
	for k in orig_lookup.keys():
		assert_true(load_lookup.has(k), "Loaded lookup should contain vertex key %s" % str(k))
		assert_eq(load_lookup[k], orig_lookup[k], "Lookup value for key %s must match" % str(k))

# ==============================================================================
# 2. Modified Face Properties Round-Trip
# ==============================================================================

func test_modified_face_properties_roundtrip():
	var cube: PBMeshData = PBMeshData.create_cube(1.0)

	# Modify face 0
	var f0: PBFace = cube.faces[0]
	f0.smoothing_group = 5
	f0.submesh_index = 2
	f0.manual_uv = true
	f0.texture_group = 3
	f0.element_group = 7
	f0.uv_offset = Vector2(0.35, 0.75)
	f0.uv_rotation = 45.0
	f0.uv_scale = Vector2(2.0, 3.0)
	f0.uv_use_world_space = true
	f0.uv_flip_u = true
	f0.uv_flip_v = false
	f0.uv_swap_uv = true
	f0.uv_fill = 2 # Stretch
	f0.uv_anchor = 4 # Center

	# Modify face 1 with different settings
	var f1: PBFace = cube.faces[1]
	f1.smoothing_group = 12
	f1.submesh_index = 1
	f1.manual_uv = false
	f1.texture_group = -1
	f1.element_group = 2
	f1.uv_offset = Vector2(-1.5, 2.5)
	f1.uv_rotation = 90.0
	f1.uv_scale = Vector2(0.5, 0.5)
	f1.uv_use_world_space = false
	f1.uv_flip_u = false
	f1.uv_flip_v = true
	f1.uv_swap_uv = false
	f1.uv_fill = 0 # Fit
	f1.uv_anchor = 0 # UpperLeft

	var loaded: PBMeshData = _save_and_load(cube, TEMP_MODIFIED_PATH)
	assert_not_null(loaded, "Loaded modified mesh should not be null")
	if loaded == null:
		return

	assert_eq(loaded.validate(), "", "Loaded modified mesh should validate")

	# Verify face 0
	var lf0: PBFace = loaded.faces[0]
	assert_eq(lf0.smoothing_group, 5)
	assert_eq(lf0.submesh_index, 2)
	assert_eq(lf0.manual_uv, true)
	assert_eq(lf0.texture_group, 3)
	assert_eq(lf0.element_group, 7)
	assert_almost_eq(lf0.uv_offset.x, 0.35, 0.0001)
	assert_almost_eq(lf0.uv_offset.y, 0.75, 0.0001)
	assert_almost_eq(lf0.uv_rotation, 45.0, 0.0001)
	assert_almost_eq(lf0.uv_scale.x, 2.0, 0.0001)
	assert_almost_eq(lf0.uv_scale.y, 3.0, 0.0001)
	assert_eq(lf0.uv_use_world_space, true)
	assert_eq(lf0.uv_flip_u, true)
	assert_eq(lf0.uv_flip_v, false)
	assert_eq(lf0.uv_swap_uv, true)
	assert_eq(lf0.uv_fill, 2)
	assert_eq(lf0.uv_anchor, 4)

	# Verify face 1
	var lf1: PBFace = loaded.faces[1]
	assert_eq(lf1.smoothing_group, 12)
	assert_eq(lf1.submesh_index, 1)
	assert_eq(lf1.manual_uv, false)
	assert_eq(lf1.texture_group, -1)
	assert_eq(lf1.element_group, 2)
	assert_almost_eq(lf1.uv_offset.x, -1.5, 0.0001)
	assert_almost_eq(lf1.uv_offset.y, 2.5, 0.0001)
	assert_almost_eq(lf1.uv_rotation, 90.0, 0.0001)
	assert_almost_eq(lf1.uv_scale.x, 0.5, 0.0001)
	assert_almost_eq(lf1.uv_scale.y, 0.5, 0.0001)
	assert_eq(lf1.uv_use_world_space, false)
	assert_eq(lf1.uv_flip_u, false)
	assert_eq(lf1.uv_flip_v, true)
	assert_eq(lf1.uv_swap_uv, false)
	assert_eq(lf1.uv_fill, 0)
	assert_eq(lf1.uv_anchor, 0)

# ==============================================================================
# 3. With Colors, Tangents, and Shared Textures
# ==============================================================================

func test_colors_tangents_and_shared_textures_roundtrip():
	var cube: PBMeshData = PBMeshData.create_cube(1.0)
	var vc: int = cube.vertex_count()

	# Assign distinct vertex colors
	var colors := PackedColorArray()
	colors.resize(vc)
	for i in range(vc):
		colors[i] = Color(float(i) / float(vc), 1.0 - float(i) / float(vc), 0.5, 1.0)
	cube.colors = colors

	# Assign tangents (4 floats per vertex: x, y, z, w)
	var tangents := PackedFloat32Array()
	tangents.resize(vc * 4)
	for i in range(vc):
		tangents[i * 4 + 0] = 1.0
		tangents[i * 4 + 1] = 0.0
		tangents[i * 4 + 2] = 0.0
		tangents[i * 4 + 3] = -1.0 if (i % 2 == 0) else 1.0
	cube.tangents = tangents

	# Assign shared textures
	cube.shared_textures = [
		PBSharedVertex.new(PackedInt32Array([0, 4, 8])),
		PBSharedVertex.new(PackedInt32Array([1, 5, 9])),
		PBSharedVertex.new(PackedInt32Array([2, 6, 10])),
	]
	cube.invalidate_caches()

	var loaded: PBMeshData = _save_and_load(cube, TEMP_ATTRIBUTES_PATH)
	assert_not_null(loaded, "Loaded mesh with attributes should not be null")
	if loaded == null:
		return

	assert_eq(loaded.validate(), "", "Loaded mesh with attributes should validate")

	# Verify colors
	assert_eq(loaded.colors.size(), vc, "Colors array size must match")
	for i in range(vc):
		assert_almost_eq(loaded.colors[i].r, cube.colors[i].r, 0.001, "Color[%d].r must match" % i)
		assert_almost_eq(loaded.colors[i].g, cube.colors[i].g, 0.001, "Color[%d].g must match" % i)
		assert_almost_eq(loaded.colors[i].b, cube.colors[i].b, 0.001, "Color[%d].b must match" % i)
		assert_almost_eq(loaded.colors[i].a, cube.colors[i].a, 0.001, "Color[%d].a must match" % i)

	# Verify tangents
	assert_eq(loaded.tangents.size(), vc * 4, "Tangents array size must match")
	for i in range(vc * 4):
		assert_almost_eq(loaded.tangents[i], cube.tangents[i], 0.0001, "Tangent[%d] must match" % i)

	# Verify shared textures
	assert_eq(loaded.shared_textures.size(), cube.shared_textures.size(), "Shared textures count must match")
	for i in range(cube.shared_textures.size()):
		var orig_st: PBSharedVertex = cube.shared_textures[i]
		var load_st: PBSharedVertex = loaded.shared_textures[i]
		assert_not_null(load_st, "Loaded shared_texture[%d] should not be null" % i)
		if load_st == null:
			continue
		assert_eq(load_st.indices.size(), orig_st.indices.size())
		for j in range(orig_st.indices.size()):
			assert_eq(load_st.indices[j], orig_st.indices[j])

	# Verify shared texture lookup rebuilt
	var st_lookup: Dictionary = loaded.get_shared_texture_lookup()
	assert_eq(st_lookup.size(), 9, "Shared texture lookup should contain 9 vertices")
	assert_eq(st_lookup[0], 0)
	assert_eq(st_lookup[4], 0)
	assert_eq(st_lookup[8], 0)
	assert_eq(st_lookup[1], 1)
	assert_eq(st_lookup[5], 1)
	assert_eq(st_lookup[9], 1)
	assert_eq(st_lookup[2], 2)
	assert_eq(st_lookup[6], 2)
	assert_eq(st_lookup[10], 2)

# ==============================================================================
# 4. Empty Mesh Data Round-Trip
# ==============================================================================

func test_empty_mesh_roundtrip():
	var empty_mesh := PBMeshData.new()
	var loaded: PBMeshData = _save_and_load(empty_mesh, TEMP_EMPTY_PATH)
	assert_not_null(loaded, "Loaded empty mesh should not be null")
	if loaded == null:
		return

	assert_eq(loaded.vertex_count(), 0, "Empty mesh vertex count should be 0")
	assert_eq(loaded.face_count(), 0, "Empty mesh face count should be 0")
	assert_eq(loaded.triangle_count(), 0, "Empty mesh triangle count should be 0")
	assert_eq(loaded.index_count(), 0, "Empty mesh index count should be 0")
	assert_eq(loaded.edge_count(), 0, "Empty mesh edge count should be 0")

	assert_true(loaded.positions.is_empty(), "Positions should be empty")
	assert_true(loaded.textures0.is_empty(), "Textures0 should be empty")
	assert_true(loaded.colors.is_empty(), "Colors should be empty")
	assert_true(loaded.tangents.is_empty(), "Tangents should be empty")
	assert_true(loaded.faces.is_empty(), "Faces should be empty")
	assert_true(loaded.shared_vertices.is_empty(), "Shared vertices should be empty")
	assert_true(loaded.shared_textures.is_empty(), "Shared textures should be empty")

	var sv_lookup := loaded.get_shared_vertex_lookup()
	assert_true(sv_lookup.is_empty(), "Shared vertex lookup should be empty")

	var st_lookup := loaded.get_shared_texture_lookup()
	assert_true(st_lookup.is_empty(), "Shared texture lookup should be empty")

# ==============================================================================
# 5. Custom Non-Cube Geometry Round-Trip
# ==============================================================================

func test_custom_geometry_roundtrip():
	var mesh_data := PBMeshData.new()
	mesh_data.positions = PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0),
		Vector3(2, 0, 0), Vector3(3, 0, 0), Vector3(2, 1, 0)
	])
	mesh_data.textures0 = PackedVector2Array([
		Vector2(0, 0), Vector2(1, 0), Vector2(0, 1),
		Vector2(0, 0), Vector2(1, 0), Vector2(0, 1)
	])
	var f1 := PBFace.new(PackedInt32Array([0, 1, 2]))
	f1.submesh_index = 0
	f1.smoothing_group = 1

	var f2 := PBFace.new(PackedInt32Array([3, 4, 5]))
	f2.submesh_index = 1
	f2.smoothing_group = 2

	mesh_data.faces = [f1, f2]
	mesh_data.shared_vertices = [
		PBSharedVertex.new(PackedInt32Array([0])),
		PBSharedVertex.new(PackedInt32Array([1])),
		PBSharedVertex.new(PackedInt32Array([2])),
		PBSharedVertex.new(PackedInt32Array([3])),
		PBSharedVertex.new(PackedInt32Array([4])),
		PBSharedVertex.new(PackedInt32Array([5]))
	]

	var loaded: PBMeshData = _save_and_load(mesh_data, TEMP_CUSTOM_PATH)
	assert_not_null(loaded, "Loaded custom mesh should not be null")
	if loaded == null:
		return

	assert_eq(loaded.validate(), "", "Loaded custom mesh should validate")
	assert_eq(loaded.vertex_count(), 6)
	assert_eq(loaded.face_count(), 2)
	assert_eq(loaded.faces[0].submesh_index, 0)
	assert_eq(loaded.faces[0].smoothing_group, 1)
	assert_eq(loaded.faces[1].submesh_index, 1)
	assert_eq(loaded.faces[1].smoothing_group, 2)

# ==============================================================================
# 6. ArrayMesh Compilation on Deserialized Mesh
# ==============================================================================

func test_array_mesh_compilation_from_loaded():
	var cube: PBMeshData = PBMeshData.create_cube(1.0)
	cube.faces[0].submesh_index = 0
	cube.faces[1].submesh_index = 1
	var loaded: PBMeshData = _save_and_load(cube, TEMP_CUBE_PATH)
	assert_not_null(loaded, "Loaded cube should not be null")
	if loaded == null:
		return

	var array_mesh: ArrayMesh = loaded.to_array_mesh()
	assert_not_null(array_mesh, "to_array_mesh() on loaded mesh should succeed")
	assert_eq(array_mesh.get_surface_count(), 2, "Compiled ArrayMesh should have 2 surfaces")

	var surf0_arrays: Array = array_mesh.surface_get_arrays(0)
	assert_eq(surf0_arrays[Mesh.ARRAY_VERTEX].size(), 24)
	assert_eq(surf0_arrays[Mesh.ARRAY_INDEX].size(), 30) # 5 faces on submesh 0 = 30 indices

	var surf1_arrays: Array = array_mesh.surface_get_arrays(1)
	assert_eq(surf1_arrays[Mesh.ARRAY_VERTEX].size(), 24)
	assert_eq(surf1_arrays[Mesh.ARRAY_INDEX].size(), 6) # 1 face on submesh 1 = 6 indices
