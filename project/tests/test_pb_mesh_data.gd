## Test: PBMeshData
##
## Verifies PBMeshData Resource data container, property accessors,
## shared vertex/texture lookup lazy-caching and invalidation, validation rules,
## clear(), and create_cube() primitive helper.
extends GutTest

# ==============================================================================
# 1. Default Construction
# ==============================================================================

func test_default_construction():
	var mesh_data := PBMeshData.new()

	assert_eq(mesh_data.vertex_count(), 0, "Default vertex count should be 0")
	assert_eq(mesh_data.face_count(), 0, "Default face count should be 0")
	assert_eq(mesh_data.triangle_count(), 0, "Default triangle count should be 0")
	assert_eq(mesh_data.index_count(), 0, "Default index count should be 0")
	assert_eq(mesh_data.edge_count(), 0, "Default edge count should be 0")

	assert_true(mesh_data.positions.is_empty(), "Positions should be empty")
	assert_true(mesh_data.textures0.is_empty(), "Textures0 should be empty")
	assert_true(mesh_data.colors.is_empty(), "Colors should be empty")
	assert_true(mesh_data.tangents.is_empty(), "Tangents should be empty")
	assert_true(mesh_data.faces.is_empty(), "Faces should be empty")
	assert_true(mesh_data.shared_vertices.is_empty(), "Shared vertices should be empty")
	assert_true(mesh_data.shared_textures.is_empty(), "Shared textures should be empty")

	var sv_lookup := mesh_data.get_shared_vertex_lookup()
	assert_true(sv_lookup.is_empty(), "Shared vertex lookup should be empty for default mesh")

	var st_lookup := mesh_data.get_shared_texture_lookup()
	assert_true(st_lookup.is_empty(), "Shared texture lookup should be empty for default mesh")

# ==============================================================================
# 2. Manual Construction
# ==============================================================================

func test_manual_construction_single_triangle():
	var mesh_data := PBMeshData.new()
	mesh_data.positions = PackedVector3Array([
		Vector3(0, 0, 0),
		Vector3(1, 0, 0),
		Vector3(0, 1, 0)
	])
	mesh_data.textures0 = PackedVector2Array([
		Vector2(0, 0),
		Vector2(1, 0),
		Vector2(0, 1)
	])
	mesh_data.colors = PackedColorArray([
		Color.RED,
		Color.GREEN,
		Color.BLUE
	])
	mesh_data.tangents = PackedFloat32Array([
		1.0, 0.0, 0.0, 1.0,
		1.0, 0.0, 0.0, 1.0,
		1.0, 0.0, 0.0, 1.0
	])
	mesh_data.faces = [
		PBFace.new(PackedInt32Array([0, 1, 2]))
	]

	assert_eq(mesh_data.vertex_count(), 3, "Vertex count should be 3")
	assert_eq(mesh_data.face_count(), 1, "Face count should be 1")
	assert_eq(mesh_data.triangle_count(), 1, "Triangle count should be 1")
	assert_eq(mesh_data.index_count(), 3, "Index count should be 3")
	assert_eq(mesh_data.edge_count(), 3, "Edge count should be 3")
	assert_eq(mesh_data.validate(), "", "Single triangle mesh should be valid")

func test_manual_construction_multi_face():
	var mesh_data := PBMeshData.new()
	# Two disconnected triangles: 6 vertices, 2 faces
	mesh_data.positions = PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0),
		Vector3(2, 0, 0), Vector3(3, 0, 0), Vector3(2, 1, 0)
	])
	var f1 := PBFace.new(PackedInt32Array([0, 1, 2]))
	var f2 := PBFace.new(PackedInt32Array([3, 4, 5]))
	mesh_data.faces = [f1, f2]

	assert_eq(mesh_data.vertex_count(), 6)
	assert_eq(mesh_data.face_count(), 2)
	assert_eq(mesh_data.triangle_count(), 2)
	assert_eq(mesh_data.index_count(), 6)
	assert_eq(mesh_data.edge_count(), 6)
	assert_eq(mesh_data.validate(), "")

# ==============================================================================
# 3. Cube Creation & Geometric Properties
# ==============================================================================

func test_create_cube_defaults_and_counts():
	var cube := PBMeshData.create_cube(1.0)

	assert_not_null(cube, "create_cube should return non-null PBMeshData")
	assert_eq(cube.vertex_count(), 24, "Cube must have 24 vertices (4 per face x 6 faces)")
	assert_eq(cube.face_count(), 6, "Cube must have 6 faces")
	assert_eq(cube.triangle_count(), 12, "Cube must have 12 triangles (2 per quad face)")
	assert_eq(cube.index_count(), 36, "Cube must have 36 indices (6 per face x 6 faces)")
	assert_eq(cube.edge_count(), 24, "Cube must have 24 perimeter edges (4 per face x 6 faces)")
	assert_eq(cube.textures0.size(), 24, "Cube must have 24 UV coordinates")
	assert_eq(cube.shared_vertices.size(), 8, "Cube must have 8 shared vertex corner groups")

func test_create_cube_custom_size():
	var cube := PBMeshData.create_cube(4.0)

	assert_eq(cube.vertex_count(), 24)
	assert_eq(cube.face_count(), 6)

	# Verify bounding coordinates reach +/- 2.0
	var min_pos := Vector3(INF, INF, INF)
	var max_pos := Vector3(-INF, -INF, -INF)
	for p in cube.positions:
		min_pos.x = minf(min_pos.x, p.x)
		min_pos.y = minf(min_pos.y, p.y)
		min_pos.z = minf(min_pos.z, p.z)
		max_pos.x = maxf(max_pos.x, p.x)
		max_pos.y = maxf(max_pos.y, p.y)
		max_pos.z = maxf(max_pos.z, p.z)

	assert_almost_eq(min_pos.x, -2.0, 0.001)
	assert_almost_eq(min_pos.y, -2.0, 0.001)
	assert_almost_eq(min_pos.z, -2.0, 0.001)
	assert_almost_eq(max_pos.x, 2.0, 0.001)
	assert_almost_eq(max_pos.y, 2.0, 0.001)
	assert_almost_eq(max_pos.z, 2.0, 0.001)

func test_create_cube_validation():
	var cube := PBMeshData.create_cube(1.0)
	var err := cube.validate()
	assert_eq(err, "", "Generated cube must pass validation without errors")

func test_create_cube_face_quads():
	var cube := PBMeshData.create_cube(1.0)
	for i in range(cube.faces.size()):
		var face: PBFace = cube.faces[i]
		assert_true(face.is_quad(), "Face %d of cube must be a quad" % i)
		var quad_indices := face.to_quad()
		assert_eq(quad_indices.size(), 4, "Face %d to_quad() must return 4 vertices" % i)

# ==============================================================================
# 4. Shared Vertex & Shared Texture Lookups
# ==============================================================================

func test_cube_shared_vertex_lookup():
	var cube := PBMeshData.create_cube(1.0)
	var lookup := cube.get_shared_vertex_lookup()

	assert_eq(lookup.size(), 24, "Shared vertex lookup should contain all 24 local vertex indices")

	# Group 0 is corner (-h, -h, -h): vertices [1, 8, 21]
	assert_eq(lookup[1], 0)
	assert_eq(lookup[8], 0)
	assert_eq(lookup[21], 0)

	# Group 1 is corner (+h, -h, -h): vertices [0, 13, 22]
	assert_eq(lookup[0], 1)
	assert_eq(lookup[13], 1)
	assert_eq(lookup[22], 1)

	# Verify every group has exactly 3 vertices in the cube
	var counts := {}
	for v in lookup.keys():
		var g: int = lookup[v]
		counts[g] = counts.get(g, 0) + 1

	assert_eq(counts.size(), 8, "Must have exactly 8 shared vertex groups")
	for g in counts.keys():
		assert_eq(counts[g], 3, "Group %d should have 3 coincident vertices" % g)

func test_shared_texture_lookup():
	var mesh_data := PBMeshData.new()
	mesh_data.shared_textures = [
		PBSharedVertex.new(PackedInt32Array([0, 4])),
		PBSharedVertex.new(PackedInt32Array([1, 5]))
	]

	var lookup := mesh_data.get_shared_texture_lookup()
	assert_eq(lookup.size(), 4)
	assert_eq(lookup[0], 0)
	assert_eq(lookup[4], 0)
	assert_eq(lookup[1], 1)
	assert_eq(lookup[5], 1)

func test_cache_invalidation_shared_vertex():
	var mesh_data := PBMeshData.new()
	mesh_data.shared_vertices = [
		PBSharedVertex.new(PackedInt32Array([0, 1]))
	]

	var lookup1 := mesh_data.get_shared_vertex_lookup()
	assert_eq(lookup1.size(), 2)
	assert_eq(lookup1[0], 0)

	# Modify shared vertices and invalidate
	mesh_data.shared_vertices = [
		PBSharedVertex.new(PackedInt32Array([0, 1, 2]))
	]
	mesh_data.invalidate_shared_vertex_lookup()

	var lookup2 := mesh_data.get_shared_vertex_lookup()
	assert_eq(lookup2.size(), 3)
	assert_eq(lookup2[2], 0)

func test_cache_invalidation_shared_texture():
	var mesh_data := PBMeshData.new()
	mesh_data.shared_textures = [
		PBSharedVertex.new(PackedInt32Array([0, 2]))
	]

	var lookup1 := mesh_data.get_shared_texture_lookup()
	assert_eq(lookup1.size(), 2)

	mesh_data.set_shared_textures([
		PBSharedVertex.new(PackedInt32Array([0, 2, 4]))
	])

	var lookup2 := mesh_data.get_shared_texture_lookup()
	assert_eq(lookup2.size(), 3)
	assert_eq(lookup2[4], 0)

func test_invalidate_caches_all():
	var cube := PBMeshData.create_cube(1.0)
	var sv_lookup := cube.get_shared_vertex_lookup()
	assert_eq(sv_lookup.size(), 24)

	# Change shared vertices via setter
	cube.set_shared_vertices([
		PBSharedVertex.new(PackedInt32Array([0, 1]))
	])

	var new_lookup := cube.get_shared_vertex_lookup()
	assert_eq(new_lookup.size(), 2)

# ==============================================================================
# 5. Validation Errors
# ==============================================================================

func test_validation_empty_positions():
	var mesh_data := PBMeshData.new()
	assert_eq(mesh_data.validate(), "No positions")

func test_validation_empty_faces():
	var mesh_data := PBMeshData.new()
	mesh_data.positions = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	assert_eq(mesh_data.validate(), "No faces")

func test_validation_null_face():
	var mesh_data := PBMeshData.new()
	mesh_data.positions = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	mesh_data.faces = [null]
	assert_eq(mesh_data.validate(), "Null face at index 0")

func test_validation_out_of_range_index():
	var mesh_data := PBMeshData.new()
	mesh_data.positions = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	mesh_data.faces = [PBFace.new(PackedInt32Array([0, 1, 5]))]
	var err := mesh_data.validate()
	assert_true(err.begins_with("Face 0 references vertex 5"), "Error should report out of range index: %s" % err)

func test_validation_negative_index():
	var mesh_data := PBMeshData.new()
	mesh_data.positions = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	mesh_data.faces = [PBFace.new(PackedInt32Array([0, 1, -1]))]
	var err := mesh_data.validate()
	assert_true(err.begins_with("Face 0 references vertex -1"), "Error should report negative index: %s" % err)

func test_validation_wrong_textures0_size():
	var mesh_data := PBMeshData.new()
	mesh_data.positions = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	mesh_data.faces = [PBFace.new(PackedInt32Array([0, 1, 2]))]
	mesh_data.textures0 = PackedVector2Array([Vector2.ZERO, Vector2.ONE]) # 2 instead of 3
	var err := mesh_data.validate()
	assert_eq(err, "textures0 size 2 != vertex count 3")

func test_validation_wrong_colors_size():
	var mesh_data := PBMeshData.new()
	mesh_data.positions = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	mesh_data.faces = [PBFace.new(PackedInt32Array([0, 1, 2]))]
	mesh_data.colors = PackedColorArray([Color.RED]) # 1 instead of 3
	var err := mesh_data.validate()
	assert_eq(err, "colors size 1 != vertex count 3")

func test_validation_wrong_tangents_size():
	var mesh_data := PBMeshData.new()
	mesh_data.positions = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	mesh_data.faces = [PBFace.new(PackedInt32Array([0, 1, 2]))]
	mesh_data.tangents = PackedFloat32Array([1.0, 0.0, 0.0, 1.0, 1.0]) # 5 instead of 12 (3 * 4)
	var err := mesh_data.validate()
	assert_eq(err, "tangents size 5 != vertex count * 4 (12)")

# ==============================================================================
# 6. Clear & Setters
# ==============================================================================

func test_clear():
	var cube := PBMeshData.create_cube(1.0)
	cube.colors = PackedColorArray([Color.WHITE])
	cube.tangents = PackedFloat32Array([1.0, 0.0, 0.0, 1.0])
	# Build lookup cache
	var _lk = cube.get_shared_vertex_lookup()

	cube.clear()

	assert_eq(cube.vertex_count(), 0)
	assert_eq(cube.face_count(), 0)
	assert_eq(cube.triangle_count(), 0)
	assert_eq(cube.index_count(), 0)
	assert_eq(cube.edge_count(), 0)

	assert_true(cube.positions.is_empty())
	assert_true(cube.textures0.is_empty())
	assert_true(cube.colors.is_empty())
	assert_true(cube.tangents.is_empty())
	assert_true(cube.faces.is_empty())
	assert_true(cube.shared_vertices.is_empty())
	assert_true(cube.shared_textures.is_empty())

	assert_true(cube.get_shared_vertex_lookup().is_empty())
	assert_true(cube.get_shared_texture_lookup().is_empty())

func test_setters():
	var mesh_data := PBMeshData.new()

	var pos := PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)])
	mesh_data.set_positions(pos)
	assert_eq(mesh_data.positions, pos)

	var f := PBFace.new(PackedInt32Array([0, 1, 2]))
	var faces_arr: Array[PBFace] = [f]
	mesh_data.set_faces(faces_arr)
	assert_eq(mesh_data.faces, faces_arr)

	var sv: Array[PBSharedVertex] = [PBSharedVertex.new(PackedInt32Array([0, 1]))]
	mesh_data.set_shared_vertices(sv)
	assert_eq(mesh_data.shared_vertices, sv)

	var st: Array[PBSharedVertex] = [PBSharedVertex.new(PackedInt32Array([1, 2]))]
	mesh_data.set_shared_textures(st)

func test_common_edge_indices_matches_common_edges():
	var cube := PBMeshData.create_cube(1.0)
	var edges := cube.get_common_edges()
	var flat_indices := cube.get_common_edge_indices()
	assert_eq(flat_indices.size(), edges.size() * 2)
	for i in range(edges.size()):
		assert_eq(flat_indices[i * 2], edges[i].a)
		assert_eq(flat_indices[i * 2 + 1], edges[i].b)

	# Invalidation clears both and recomputes correctly
	cube.invalidate_caches()
	var flat2 := cube.get_common_edge_indices()
	assert_eq(flat2.size(), edges.size() * 2)
	for i in range(edges.size()):
		assert_eq(flat2[i * 2], edges[i].a)
		assert_eq(flat2[i * 2 + 1], edges[i].b)
