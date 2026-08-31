## Test: PB Coincident Vertices
##
## Verifies coincident vertex queries and common vertex/edge lookups on PBMeshData:
## 1. Single vertex coincident query
## 2. All coincident groups query
## 3. Position sharing across coincident groups
## 4. Multi-vertex query across multiple groups
## 5. Same-group deduplication in multi-vertex query
## 6. Coincident vertices from edges
## 7. Coincident vertices from faces
## 8. Common vertex lookup
## 9. Common edge conversion
## 10. Unknown / out-of-range vertex queries
## 11. Edge cases (empty inputs, mesh with no shared vertices)
extends GutTest

# ==============================================================================
# 1. Single Vertex Coincident Query
# ==============================================================================

func test_single_vertex_coincident():
	var cube := PBMeshData.create_cube(1.0)
	var coinc := cube.get_coincident_vertices(0)

	assert_eq(coinc.size(), 3, "Vertex 0 of cube must have 3 coincident vertices (3 adjacent faces meeting at corner)")
	assert_true(coinc.has(0), "Coincident list must contain queried vertex 0")
	assert_true(coinc.has(13), "Coincident list must contain vertex 13 (right face corner)")
	assert_true(coinc.has(22), "Coincident list must contain vertex 22 (bottom face corner)")

# ==============================================================================
# 2. All Coincident Groups
# ==============================================================================

func test_all_coincident_groups_have_expected_size():
	var cube := PBMeshData.create_cube(1.0)

	assert_eq(cube.shared_vertices.size(), 8, "Cube must have 8 shared vertex corner groups")
	for group_idx in range(cube.shared_vertices.size()):
		var sv: PBSharedVertex = cube.shared_vertices[group_idx]
		assert_eq(sv.size(), 3, "Group %d must have exactly 3 vertices" % group_idx)

		for v in sv.indices:
			var coinc := cube.get_coincident_vertices(v)
			assert_eq(coinc.size(), 3, "get_coincident_vertices(%d) must return 3 vertices" % v)
			for member in sv.indices:
				assert_true(coinc.has(member), "Coincident list for %d must contain group member %d" % [v, member])

# ==============================================================================
# 3. Position Sharing Across Coincident Groups
# ==============================================================================

func test_coincident_vertices_share_same_spatial_position():
	var cube := PBMeshData.create_cube(1.0)

	for group_idx in range(cube.shared_vertices.size()):
		var sv: PBSharedVertex = cube.shared_vertices[group_idx]
		var first_v: int = sv.indices[0]
		var expected_pos: Vector3 = cube.positions[first_v]

		for v in sv.indices:
			var pos: Vector3 = cube.positions[v]
			assert_almost_eq(pos.x, expected_pos.x, 0.0001, "Vertex %d pos.x in group %d must match corner" % [v, group_idx])
			assert_almost_eq(pos.y, expected_pos.y, 0.0001, "Vertex %d pos.y in group %d must match corner" % [v, group_idx])
			assert_almost_eq(pos.z, expected_pos.z, 0.0001, "Vertex %d pos.z in group %d must match corner" % [v, group_idx])

# ==============================================================================
# 4. Multi-Vertex Query Across Different Groups
# ==============================================================================

func test_multi_vertex_query_two_distinct_corners():
	var cube := PBMeshData.create_cube(1.0)

	# Vertex 0 is in Corner (+h, -h, -h): [0, 13, 22]
	# Vertex 1 is in Corner (-h, -h, -h): [1, 8, 21]
	var multi := cube.get_coincident_vertices_multi(PackedInt32Array([0, 1]))

	assert_eq(multi.size(), 6, "Two distinct corners must return 6 coincident vertices total")
	# Check all vertices from group 1
	assert_true(multi.has(0))
	assert_true(multi.has(13))
	assert_true(multi.has(22))
	# Check all vertices from group 0
	assert_true(multi.has(1))
	assert_true(multi.has(8))
	assert_true(multi.has(21))

# ==============================================================================
# 5. Same-Group Deduplication in Multi-Vertex Query
# ==============================================================================

func test_multi_vertex_query_same_group_deduplication():
	var cube := PBMeshData.create_cube(1.0)

	# Vertices 0, 13, 22 all belong to the same corner group
	var multi_pair := cube.get_coincident_vertices_multi(PackedInt32Array([0, 13]))
	assert_eq(multi_pair.size(), 3, "Querying 2 vertices in the same group must deduplicate to 3 results")

	var multi_all_three := cube.get_coincident_vertices_multi(PackedInt32Array([0, 13, 22]))
	assert_eq(multi_all_three.size(), 3, "Querying all 3 vertices in the same group must return 3 results")

	# Mix duplicate group vertices with another group: [0, 13, 1] -> groups 1 and 0 -> 6 vertices
	var multi_mixed := cube.get_coincident_vertices_multi(PackedInt32Array([0, 13, 1]))
	assert_eq(multi_mixed.size(), 6, "Two vertices in group 1 + one vertex in group 0 should yield 6 results")

# ==============================================================================
# 6. Coincident Vertices from Edges
# ==============================================================================

func test_coincident_vertices_from_edges():
	var cube := PBMeshData.create_cube(1.0)

	# Local edge (0, 1) connects corner (+h, -h, -h) to corner (-h, -h, -h)
	var edge := PBEdge.new(0, 1)
	var coinc := cube.get_coincident_vertices_from_edges([edge])

	assert_eq(coinc.size(), 6, "Edge spanning two corners should return 6 coincident vertices")
	assert_true(coinc.has(0))
	assert_true(coinc.has(13))
	assert_true(coinc.has(22))
	assert_true(coinc.has(1))
	assert_true(coinc.has(8))
	assert_true(coinc.has(21))

func test_coincident_vertices_from_multiple_edges_with_shared_endpoint():
	var cube := PBMeshData.create_cube(1.0)

	# Two edges sharing vertex 0: (0, 1) and (0, 3)
	# Vertex 0: group 1 [0, 13, 22]
	# Vertex 1: group 0 [1, 8, 21]
	# Vertex 3: group 3 [3, 14, 19]
	var e1 := PBEdge.new(0, 1)
	var e2 := PBEdge.new(0, 3)
	var coinc := cube.get_coincident_vertices_from_edges([e1, e2])

	assert_eq(coinc.size(), 9, "Two edges covering 3 unique corners must return 9 coincident vertices")

func test_coincident_vertices_from_edges_with_null_edge():
	var cube := PBMeshData.create_cube(1.0)
	var e1 := PBEdge.new(0, 1)
	var coinc := cube.get_coincident_vertices_from_edges([null, e1, null])

	assert_eq(coinc.size(), 6, "Null edges in array should be ignored safely")

# ==============================================================================
# 7. Coincident Vertices from Faces
# ==============================================================================

func test_coincident_vertices_from_single_face():
	var cube := PBMeshData.create_cube(1.0)

	# Face 0 of cube has 4 distinct vertices (0, 1, 2, 3), representing 4 corners
	var coinc := cube.get_coincident_vertices_from_faces(PackedInt32Array([0]))

	# 4 corners * 3 vertices per corner = 12 vertices
	assert_eq(coinc.size(), 12, "Face 0 with 4 corners must return 12 coincident vertices")

	# Check presence of all 4 corners' vertices
	for v in [0, 13, 22, 1, 8, 21, 2, 11, 16, 3, 14, 19]:
		assert_true(coinc.has(v), "Result should contain vertex %d" % v)

func test_coincident_vertices_from_all_faces():
	var cube := PBMeshData.create_cube(1.0)

	# All 6 faces together cover all 8 corners = 24 vertices
	var coinc := cube.get_coincident_vertices_from_faces(PackedInt32Array([0, 1, 2, 3, 4, 5]))
	assert_eq(coinc.size(), 24, "All 6 faces should return all 24 coincident vertices")

func test_coincident_vertices_from_faces_out_of_bounds():
	var cube := PBMeshData.create_cube(1.0)

	var coinc := cube.get_coincident_vertices_from_faces(PackedInt32Array([-1, 0, 999]))
	assert_eq(coinc.size(), 12, "Out of bounds face indices should be ignored, returning face 0's 12 vertices")

# ==============================================================================
# 8. Common Vertex Lookup
# ==============================================================================

func test_get_common_vertex():
	var cube := PBMeshData.create_cube(1.0)

	# Vertex 0 is in group 1
	var common_0 := cube.get_common_vertex(0)
	assert_eq(common_0, 1, "Vertex 0 common vertex index should be group 1")

	# All vertices in group 1 ([0, 13, 22]) must return common vertex 1
	assert_eq(cube.get_common_vertex(13), 1, "Vertex 13 should map to group 1")
	assert_eq(cube.get_common_vertex(22), 1, "Vertex 22 should map to group 1")

	# Vertex 1 is in group 0 ([1, 8, 21])
	assert_eq(cube.get_common_vertex(1), 0, "Vertex 1 should map to group 0")
	assert_eq(cube.get_common_vertex(8), 0, "Vertex 8 should map to group 0")
	assert_eq(cube.get_common_vertex(21), 0, "Vertex 21 should map to group 0")

# ==============================================================================
# 9. Common Edge
# ==============================================================================

func test_get_common_edge():
	var cube := PBMeshData.create_cube(1.0)

	# Local edge (0, 1): vertex 0 is in group 1, vertex 1 is in group 0
	var local_edge := PBEdge.new(0, 1)
	var common_edge := cube.get_common_edge(local_edge)

	assert_not_null(common_edge, "get_common_edge should return a PBEdge")
	assert_eq(common_edge.a, 1, "Endpoint a should map to group 1")
	assert_eq(common_edge.b, 0, "Endpoint b should map to group 0")

	# Another edge from adjacent face sharing same corner: (13, 8) -> (group 1, group 0)
	var equivalent_local_edge := PBEdge.new(13, 8)
	var eq_common_edge := cube.get_common_edge(equivalent_local_edge)

	assert_true(common_edge.equals(eq_common_edge), "Both local edges sharing corners must produce equivalent common edges")

func test_get_common_edge_null():
	var cube := PBMeshData.create_cube(1.0)
	var result := cube.get_common_edge(null)
	assert_null(result, "get_common_edge(null) should return null")

# ==============================================================================
# 10. Unknown / Out-of-Range Vertex Queries
# ==============================================================================

func test_unknown_vertex_queries():
	var cube := PBMeshData.create_cube(1.0)

	# Single vertex not in shared vertex groups returns [vertex]
	var coinc := cube.get_coincident_vertices(999)
	assert_eq(coinc.size(), 1, "Unknown vertex coincident query should return array of size 1")
	assert_eq(coinc[0], 999, "Unknown vertex coincident query should return [999]")

	# Common vertex for unknown vertex returns -1
	assert_eq(cube.get_common_vertex(999), -1, "Common vertex for unknown vertex should be -1")

	# Multi-vertex query with unknown vertices
	var multi := cube.get_coincident_vertices_multi(PackedInt32Array([999, 998]))
	assert_true(multi.is_empty(), "Multi query with only unknown vertices should return empty array")

	# Common edge with unknown vertex endpoints
	var unk_edge := PBEdge.new(999, 998)
	var common_unk := cube.get_common_edge(unk_edge)
	assert_not_null(common_unk)
	assert_eq(common_unk.a, -1)
	assert_eq(common_unk.b, -1)

# ==============================================================================
# 11. Edge Cases & Empty Inputs
# ==============================================================================

func test_empty_inputs():
	var cube := PBMeshData.create_cube(1.0)

	var empty_multi := cube.get_coincident_vertices_multi(PackedInt32Array())
	assert_true(empty_multi.is_empty(), "Empty vertices array should return empty result")

	var empty_edges := cube.get_coincident_vertices_from_edges([])
	assert_true(empty_edges.is_empty(), "Empty edges array should return empty result")

	var empty_faces := cube.get_coincident_vertices_from_faces(PackedInt32Array())
	assert_true(empty_faces.is_empty(), "Empty faces array should return empty result")

func test_mesh_without_shared_vertices():
	var mesh_data := PBMeshData.new()
	mesh_data.positions = PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)])
	mesh_data.faces = [PBFace.new(PackedInt32Array([0, 1, 2]))]
	# shared_vertices is empty

	var coinc := mesh_data.get_coincident_vertices(0)
	assert_eq(coinc.size(), 1)
	assert_eq(coinc[0], 0)

	assert_eq(mesh_data.get_common_vertex(0), -1)

	var ce := mesh_data.get_common_edge(PBEdge.new(0, 1))
	assert_eq(ce.a, -1)
	assert_eq(ce.b, -1)
