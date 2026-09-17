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

# ==============================================================================
# Dense-geometry picking (v0.9.137 regressions)
# ==============================================================================

func test_ray_intersects_tiny_triangles():
	# Sculpt-scale triangle (~1 mm² → Möller–Trumbore det ≈ 2e-6). The old
	# 1e-4 determinant gate classified it as "ray parallel to plane" and
	# dense sculpt faces were unpickable everywhere.
	var a := Vector3(0.0, 0.0, 0.0)
	var b := Vector3(0.03, 0.001, 0.0)
	var c := Vector3(0.0, 0.001, 0.03)
	var n := (b - a).cross(c - a).normalized()
	var centroid := (a + b + c) / 3.0
	var origin := centroid + n * 0.01
	var hit := PBMath.ray_intersects_triangle(origin, -n, a, b, c)
	assert_true(hit.get("hit", false), "A ~1 mm² triangle must be ray-pickable")

	# Meter-scale triangle still picks (the common case)
	var big_hit := PBMath.ray_intersects_triangle(
			Vector3(0, 5, 0), Vector3(0, -1, 0),
			Vector3(-1, 0, -1), Vector3(1, 0, -1), Vector3(0, 0, 1))
	assert_true(big_hit.get("hit", false), "Meter-scale triangle must stay pickable")

func test_plain_mesh_surface_pick_budget_and_early_out():
	# Scene: a small mesh near the ray, an over-budget giant behind it.
	var root := Node3D.new()
	add_child_autofree(root)

	var small_img_mesh := PlaneMesh.new()
	small_img_mesh.size = Vector2(1, 1)
	var small := MeshInstance3D.new()
	small.mesh = small_img_mesh
	root.add_child(small)

	var big_mesh := PlaneMesh.new()
	big_mesh.size = Vector2(200, 200)
	big_mesh.subdivide_width = 300
	big_mesh.subdivide_depth = 300
	var big := MeshInstance3D.new()
	big.mesh = big_mesh
	root.add_child(big)

	# The big plane is 300x300x2 = 180k triangles — over budget, so its very
	# first cache entry is the empty (excluded) marker.
	assert_gt(big_mesh.get_faces().size() / 3, PBPicking.PLAIN_MESH_PICK_TRI_BUDGET,
			"Sanity: the big mesh really is over budget")
	assert_true(PBPicking.plain_mesh_pick_faces(big_mesh).is_empty(),
			"A %d+ triangle mesh must be budget-excluded from hover picking" % PBPicking.PLAIN_MESH_PICK_TRI_BUDGET)
	assert_false(PBPicking.plain_mesh_pick_faces(small_img_mesh).is_empty(),
			"Small meshes must stay pickable")

	# Ray down the +Y axis: both AABBs are entered, but the small mesh is hit
	# first (y=0 plane of both is the same height, so use max_t early-out to
	# prove the gate, and AABB miss to prove culling).
	var miss := PBPicking.pick_plain_mesh_surface(root, Vector3(5, 5, 5), Vector3(0, -1, 0), INF)
	assert_true(miss.is_empty(), "Ray outside all AABBs must pick nothing")

	var early := PBPicking.pick_plain_mesh_surface(root, Vector3(0, 5, 0), Vector3(0, -1, 0), 2.0)
	assert_true(early.is_empty(), "max_t shorter than the surface must return nothing (early-out)")

	var hit := PBPicking.pick_plain_mesh_surface(root, Vector3(0.2, 5, 0.2), Vector3(0, -1, 0), INF)
	assert_false(hit.is_empty(), "Ray through the small mesh must pick it")
	if not hit.is_empty():
		assert_almost_eq(hit["point"].y, 0.0, 0.001, "Pick point must sit on the plane")

func test_ray_aabb_span():
	# Hit through the box center
	var box := AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))
	var span := PBPicking.ray_aabb_span(Vector3(0, 0, 5), Vector3(0, 0, -1), box)
	assert_almost_eq(span.x, 4.0, 0.001, "Entry t must be 4 for a 5-unit standoff")
	assert_almost_eq(span.y, 6.0, 0.001, "Exit t must be 6 for a 2-unit box")
	# Miss
	var miss := PBPicking.ray_aabb_span(Vector3(5, 5, 5), Vector3(0, 0, -1), box)
	assert_true(miss.x < 0.0, "Parallel ray outside the slab must miss")
	# Box entirely behind
	var behind := PBPicking.ray_aabb_span(Vector3(0, 0, 5), Vector3(0, 0, 1), box)
	assert_true(behind.x < 0.0, "Box behind the ray origin must miss")
