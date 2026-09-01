extends GutTest

## Tests for PBPicking — raycast-based element picking.
## Uses synthetic rays against a unit cube centered at origin to test
## face, edge, and vertex picking in headless mode.

var data: PBMeshData
var transform: Transform3D


func before_each() -> void:
	data = PBMeshData.create_cube(1.0)
	transform = Transform3D.IDENTITY


# ==============================================================================
# Face Picking
# ==============================================================================

func test_pick_face_front_hit() -> void:
	# Ray along -Z hitting the front face of a unit cube
	var origin := Vector3(0, 0, 5)
	var direction := Vector3(0, 0, -1)
	var result := PBPicking.pick_face(data, transform, origin, direction)
	assert_gte(result.face_index, 0, "Should hit a face")
	assert_lt(result.distance, INF)


func test_pick_face_miss() -> void:
	# Ray parallel to a face, missing entirely
	var origin := Vector3(10, 0, 0)
	var direction := Vector3(0, 0, -1)
	var result := PBPicking.pick_face(data, transform, origin, direction)
	assert_eq(result.face_index, -1, "Should miss all faces")


func test_pick_face_picks_nearest() -> void:
	# Ray along -Z should hit front face, not back face
	var origin := Vector3(0, 0, 5)
	var direction := Vector3(0, 0, -1)
	var result := PBPicking.pick_face(data, transform, origin, direction)
	assert_gte(result.face_index, 0)
	# The front face of a unit cube centered at origin has z = 0.5
	assert_almost_eq(result.hit_point.z, 0.5, 0.01, "Should hit front face at z=0.5")


func test_pick_face_back_hit() -> void:
	# Ray along +Z hitting the back face
	var origin := Vector3(0, 0, -5)
	var direction := Vector3(0, 0, 1)
	var result := PBPicking.pick_face(data, transform, origin, direction)
	assert_gte(result.face_index, 0)
	assert_almost_eq(result.hit_point.z, -0.5, 0.01, "Should hit back face at z=-0.5")


func test_pick_face_with_transform() -> void:
	# Translate mesh to (2, 0, 0), ray should still hit
	var xform := Transform3D(Basis.IDENTITY, Vector3(2, 0, 0))
	var origin := Vector3(2, 0, 5)
	var direction := Vector3(0, 0, -1)
	var result := PBPicking.pick_face(data, xform, origin, direction)
	assert_gte(result.face_index, 0, "Should hit translated mesh")
	assert_almost_eq(result.hit_point.x, 2.0, 0.01)


func test_pick_face_with_transform_miss() -> void:
	# Translated mesh, ray at origin should miss
	var xform := Transform3D(Basis.IDENTITY, Vector3(5, 0, 0))
	var origin := Vector3(0, 0, 5)
	var direction := Vector3(0, 0, -1)
	var result := PBPicking.pick_face(data, xform, origin, direction)
	assert_eq(result.face_index, -1, "Should miss offset mesh")


func test_pick_faces_all_returns_multiple() -> void:
	# Ray through cube center should hit exactly 2 faces (front and back)
	var origin := Vector3(0, 0, 5)
	var direction := Vector3(0, 0, -1)
	var results := PBPicking.pick_faces_all(data, transform, origin, direction)
	assert_eq(results.size(), 2, "Should hit front and back faces")
	assert_lt(results[0].distance, results[1].distance, "First result should be nearer")


func test_pick_faces_all_sorted() -> void:
	var origin := Vector3(0, 0, 5)
	var direction := Vector3(0, 0, -1)
	var results := PBPicking.pick_faces_all(data, transform, origin, direction)
	for i in range(1, results.size()):
		assert_lte(results[i - 1].distance, results[i].distance, "Results should be sorted by distance")


func test_pick_face_null_data() -> void:
	var result := PBPicking.pick_face(null, transform, Vector3.ZERO, Vector3.FORWARD)
	assert_eq(result.face_index, -1)


# ==============================================================================
# Edge Picking (requires Camera3D)
# ==============================================================================

func test_edge_pick_result_creation() -> void:
	# Just test that EdgePickResult can be created
	var result := PBPicking.EdgePickResult.new()
	assert_null(result.edge)
	assert_eq(result.face_index, -1)
	assert_eq(result.screen_distance, INF)


func test_edge_pick_with_custom_edge() -> void:
	var edge := PBEdge.new(0, 1)
	var result := PBPicking.EdgePickResult.new(edge, 0, 5.0)
	assert_not_null(result.edge)
	assert_eq(result.face_index, 0)
	assert_almost_eq(result.screen_distance, 5.0, 0.001)


# ==============================================================================
# Vertex Picking (requires Camera3D)
# ==============================================================================

func test_vertex_pick_result_creation() -> void:
	var result := PBPicking.VertexPickResult.new()
	assert_eq(result.common_index, -1)
	assert_eq(result.vertex_index, -1)
	assert_eq(result.screen_distance, INF)


func test_vertex_pick_with_values() -> void:
	var result := PBPicking.VertexPickResult.new(3, 7, 10.5)
	assert_eq(result.common_index, 3)
	assert_eq(result.vertex_index, 7)
	assert_almost_eq(result.screen_distance, 10.5, 0.001)


# ==============================================================================
# Face Picking — Correctness on different axes
# ==============================================================================

func test_pick_face_top() -> void:
	# Ray along -Y hitting the top face
	var origin := Vector3(0, 5, 0)
	var direction := Vector3(0, -1, 0)
	var result := PBPicking.pick_face(data, transform, origin, direction)
	assert_gte(result.face_index, 0, "Should hit top face")
	assert_almost_eq(result.hit_point.y, 0.5, 0.01)


func test_pick_face_right() -> void:
	# Ray along -X hitting the right face
	var origin := Vector3(5, 0, 0)
	var direction := Vector3(-1, 0, 0)
	var result := PBPicking.pick_face(data, transform, origin, direction)
	assert_gte(result.face_index, 0, "Should hit right face")
	assert_almost_eq(result.hit_point.x, 0.5, 0.01)


func test_pick_face_corner_ray() -> void:
	# Ray aimed at cube corner — should still hit a face
	var origin := Vector3(5, 5, 5)
	var direction := (Vector3(0.5, 0.5, 0.5) - origin).normalized()
	var result := PBPicking.pick_face(data, transform, origin, direction)
	assert_gte(result.face_index, 0, "Should hit a face near the corner")


# ==============================================================================
# Edge count verification (cube topology)
# ==============================================================================

func test_cube_has_12_unique_edges() -> void:
	var lookup: Dictionary = data.get_shared_vertex_lookup()
	var seen: Dictionary = {}
	for face in data.faces:
		if face == null:
			continue
		for edge in face.get_edges():
			var ca: int = lookup.get(edge.a, -1)
			var cb: int = lookup.get(edge.b, -1)
			var key := Vector2i(mini(ca, cb), maxi(ca, cb))
			seen[key] = true
	assert_eq(seen.size(), 12, "Cube should have 12 unique edges")


func test_cube_has_8_shared_vertices() -> void:
	assert_eq(data.shared_vertices.size(), 8, "Cube should have 8 shared vertex groups")
