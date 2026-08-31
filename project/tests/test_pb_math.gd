## Test: PBMath Utility Functions
##
## Verifies normal calculation, area, centroid, ray-triangle intersection,
## distance to line segment, line segment intersection, point in polygon,
## best-fit plane, projection axes, planar projection, and snapping.
extends GutTest

# ==============================================================================
# Constants & Helpers
# ==============================================================================

const EPSILON: float = 0.001

func assert_vec3_approx_eq(actual: Vector3, expected: Vector3, msg: String = "") -> void:
	assert_almost_eq(actual.x, expected.x, EPSILON, "%s (X component)" % msg)
	assert_almost_eq(actual.y, expected.y, EPSILON, "%s (Y component)" % msg)
	assert_almost_eq(actual.z, expected.z, EPSILON, "%s (Z component)" % msg)

func assert_vec2_approx_eq(actual: Vector2, expected: Vector2, msg: String = "") -> void:
	assert_almost_eq(actual.x, expected.x, EPSILON, "%s (X component)" % msg)
	assert_almost_eq(actual.y, expected.y, EPSILON, "%s (Y component)" % msg)

# ==============================================================================
# P2-01: Normal Calculation, Area, Centroid
# ==============================================================================

func test_constants():
	assert_almost_eq(PBMath.PHI, 1.618033988749895, 0.000001, "PHI constant must match golden ratio")
	assert_almost_eq(PBMath.FLT_EPSILON, 0.0001, 0.00001, "FLT_EPSILON must be 0.0001")
	assert_eq(PBMath.PROJECTION_X, 0, "PROJECTION_X must be 0")
	assert_eq(PBMath.PROJECTION_X_NEG, 1, "PROJECTION_X_NEG must be 1")
	assert_eq(PBMath.PROJECTION_Y, 2, "PROJECTION_Y must be 2")
	assert_eq(PBMath.PROJECTION_Y_NEG, 3, "PROJECTION_Y_NEG must be 3")
	assert_eq(PBMath.PROJECTION_Z, 4, "PROJECTION_Z must be 4")
	assert_eq(PBMath.PROJECTION_Z_NEG, 5, "PROJECTION_Z_NEG must be 5")

func test_normal_xy_plane():
	# CCW triangle on XY plane facing +Z
	var p0 := Vector3(0.0, 0.0, 0.0)
	var p1 := Vector3(1.0, 0.0, 0.0)
	var p2 := Vector3(0.0, 1.0, 0.0)
	var n: Vector3 = PBMath.normal(p0, p1, p2)
	assert_vec3_approx_eq(n, Vector3(0.0, 0.0, 1.0), "CCW XY triangle should have +Z normal")

	# CW triangle on XY plane facing -Z
	var n_cw: Vector3 = PBMath.normal(p0, p2, p1)
	assert_vec3_approx_eq(n_cw, Vector3(0.0, 0.0, -1.0), "CW XY triangle should have -Z normal")

func test_normal_xz_plane():
	# CCW triangle on XZ plane facing +Y
	var p0 := Vector3(0.0, 0.0, 0.0)
	var p1 := Vector3(1.0, 0.0, 0.0)
	var p2 := Vector3(0.0, 0.0, -1.0)
	var n: Vector3 = PBMath.normal(p0, p1, p2)
	assert_vec3_approx_eq(n, Vector3(0.0, 1.0, 0.0), "CCW XZ triangle should have +Y normal")

func test_normal_yz_plane():
	# CCW triangle on YZ plane facing +X
	var p0 := Vector3(0.0, 0.0, 0.0)
	var p1 := Vector3(0.0, 1.0, 0.0)
	var p2 := Vector3(0.0, 0.0, 1.0)
	var n: Vector3 = PBMath.normal(p0, p1, p2)
	assert_vec3_approx_eq(n, Vector3(1.0, 0.0, 0.0), "CCW YZ triangle should have +X normal")

func test_normal_degenerate():
	# Identical points
	var p := Vector3(1.0, 2.0, 3.0)
	var n_same: Vector3 = PBMath.normal(p, p, p)
	assert_eq(n_same, Vector3.ZERO, "Degenerate triangle with identical points should return ZERO")

	# Collinear points
	var p0 := Vector3(0.0, 0.0, 0.0)
	var p1 := Vector3(1.0, 1.0, 1.0)
	var p2 := Vector3(2.0, 2.0, 2.0)
	var n_collinear: Vector3 = PBMath.normal(p0, p1, p2)
	assert_eq(n_collinear, Vector3.ZERO, "Collinear points should return ZERO normal")

func test_normal_from_positions_single_triangle():
	var positions := PackedVector3Array([
		Vector3(0.0, 0.0, 0.0),
		Vector3(1.0, 0.0, 0.0),
		Vector3(0.0, 1.0, 0.0)
	])
	# Empty indexes should use first 3 positions
	var n_no_idx: Vector3 = PBMath.normal_from_positions(positions)
	assert_vec3_approx_eq(n_no_idx, Vector3(0.0, 0.0, 1.0), "Default indices should compute first 3 positions")

	# With explicit indices
	var indexes := PackedInt32Array([0, 1, 2])
	var n_idx: Vector3 = PBMath.normal_from_positions(positions, indexes)
	assert_vec3_approx_eq(n_idx, Vector3(0.0, 0.0, 1.0), "Explicit indices should compute triangle normal")

func test_normal_from_positions_multiple_triangles():
	# Quad with two triangles in XY plane facing +Z
	var positions := PackedVector3Array([
		Vector3(0.0, 0.0, 0.0),
		Vector3(1.0, 0.0, 0.0),
		Vector3(1.0, 1.0, 0.0),
		Vector3(0.0, 1.0, 0.0)
	])
	var indexes := PackedInt32Array([
		0, 1, 2,
		0, 2, 3
	])
	var n: Vector3 = PBMath.normal_from_positions(positions, indexes)
	assert_vec3_approx_eq(n, Vector3(0.0, 0.0, 1.0), "Two coplanar triangles should average to +Z normal")

func test_normal_from_positions_cube():
	var cube: PBMeshData = PBMeshData.create_cube(1.0)
	# Face 0 is Front (Z = -0.5), normal is (0, 0, -1)
	var face0_indexes: PackedInt32Array = cube.faces[0].get_indexes()
	var n0: Vector3 = PBMath.normal_from_positions(cube.positions, face0_indexes)
	assert_vec3_approx_eq(n0, Vector3(0.0, 0.0, -1.0), "Front face normal should be (0, 0, -1)")

	# Face 4 is Top (Y = +0.5), normal is (0, 1, 0)
	var face4_indexes: PackedInt32Array = cube.faces[4].get_indexes()
	var n4: Vector3 = PBMath.normal_from_positions(cube.positions, face4_indexes)
	assert_vec3_approx_eq(n4, Vector3(0.0, 1.0, 0.0), "Top face normal should be (0, 1, 0)")

func test_triangle_area():
	# Unit right triangle (base=1, height=1) -> area = 0.5
	var a := Vector3(0.0, 0.0, 0.0)
	var b := Vector3(1.0, 0.0, 0.0)
	var c := Vector3(0.0, 1.0, 0.0)
	var area: float = PBMath.triangle_area(a, b, c)
	assert_almost_eq(area, 0.5, EPSILON, "Unit right triangle area should be 0.5")

	# 3-4-5 right triangle -> area = 0.5 * 3 * 4 = 6.0
	var a345 := Vector3(0.0, 0.0, 0.0)
	var b345 := Vector3(3.0, 0.0, 0.0)
	var c345 := Vector3(0.0, 4.0, 0.0)
	assert_almost_eq(PBMath.triangle_area(a345, b345, c345), 6.0, EPSILON, "3-4-5 triangle area should be 6.0")

	# Equilateral triangle with side length 2.0 -> area = sqrt(3) / 4 * 4 = sqrt(3) ~= 1.73205
	var eq_a := Vector3(0.0, 0.0, 0.0)
	var eq_b := Vector3(2.0, 0.0, 0.0)
	var eq_c := Vector3(1.0, sqrt(3.0), 0.0)
	assert_almost_eq(PBMath.triangle_area(eq_a, eq_b, eq_c), sqrt(3.0), EPSILON, "Equilateral triangle area should be sqrt(3)")

	# Degenerate collinear triangle -> area = 0.0
	var deg_a := Vector3(0.0, 0.0, 0.0)
	var deg_b := Vector3(1.0, 1.0, 1.0)
	var deg_c := Vector3(2.0, 2.0, 2.0)
	assert_almost_eq(PBMath.triangle_area(deg_a, deg_b, deg_c), 0.0, EPSILON, "Degenerate triangle area should be 0.0")

func test_polygon_area():
	var cube: PBMeshData = PBMeshData.create_cube(1.0)
	# Each face of a unit cube is a 1x1 quad composed of 2 triangles -> area = 1.0
	for i in range(6):
		var face_area: float = PBMath.polygon_area(cube.positions, cube.faces[i].get_indexes())
		assert_almost_eq(face_area, 1.0, EPSILON, "Unit cube face %d area should be 1.0" % i)

	# Total surface area of unit cube = 6.0
	var all_indexes: PackedInt32Array = PBFace.get_all_indexes(cube.faces)
	var total_area: float = PBMath.polygon_area(cube.positions, all_indexes)
	assert_almost_eq(total_area, 6.0, EPSILON, "Total cube surface area should be 6.0")

func test_centroid_average():
	var cube: PBMeshData = PBMeshData.create_cube(1.0)
	# Centroid of all vertices of a cube centered at origin should be ZERO
	var center: Vector3 = PBMath.average(cube.positions)
	assert_vec3_approx_eq(center, Vector3.ZERO, "Centered cube centroid should be Vector3.ZERO")

	# Top face (face 4) centroid should be (0, 0.5, 0)
	var top_indexes: PackedInt32Array = cube.faces[4].get_indexes()
	var top_center: Vector3 = PBMath.average(cube.positions, top_indexes)
	assert_vec3_approx_eq(top_center, Vector3(0.0, 0.5, 0.0), "Top face centroid should be (0, 0.5, 0)")

	# Bottom face (face 5) centroid should be (0, -0.5, 0)
	var bottom_indexes: PackedInt32Array = cube.faces[5].get_indexes()
	var bottom_center: Vector3 = PBMath.average(cube.positions, bottom_indexes)
	assert_vec3_approx_eq(bottom_center, Vector3(0.0, -0.5, 0.0), "Bottom face centroid should be (0, -0.5, 0)")

	# Specific 3 points average
	var pts := PackedVector3Array([
		Vector3(1.0, 2.0, 3.0),
		Vector3(4.0, 5.0, 6.0),
		Vector3(7.0, 8.0, 9.0)
	])
	assert_vec3_approx_eq(PBMath.average(pts), Vector3(4.0, 5.0, 6.0), "Average of 3 collinear points")

# ==============================================================================
# P2-02: Ray-Triangle, Line Segments, Point-in-Polygon, Distances
# ==============================================================================

func test_ray_intersects_triangle_hit():
	var v0 := Vector3(0.0, 0.0, 0.0)
	var v1 := Vector3(1.0, 0.0, 0.0)
	var v2 := Vector3(0.0, 1.0, 0.0)

	# Ray pointing at center of triangle (0.25, 0.25, 0.0) from Z=1
	var origin := Vector3(0.25, 0.25, 1.0)
	var dir := Vector3(0.0, 0.0, -1.0)

	var hit_res: Dictionary = PBMath.ray_intersects_triangle(origin, dir, v0, v1, v2)
	assert_true(hit_res.get("hit", false), "Ray should hit triangle")
	assert_almost_eq(hit_res.get("distance", 0.0), 1.0, EPSILON, "Hit distance should be 1.0")
	assert_vec3_approx_eq(hit_res.get("point", Vector3.ZERO), Vector3(0.25, 0.25, 0.0), "Hit point should be (0.25, 0.25, 0)")

func test_ray_intersects_triangle_non_culling_back_face():
	var v0 := Vector3(0.0, 0.0, 0.0)
	var v1 := Vector3(1.0, 0.0, 0.0)
	var v2 := Vector3(0.0, 1.0, 0.0)

	# Ray from behind Z=-1 pointing along +Z towards triangle
	var origin := Vector3(0.25, 0.25, -1.0)
	var dir := Vector3(0.0, 0.0, 1.0)

	var hit_res: Dictionary = PBMath.ray_intersects_triangle(origin, dir, v0, v1, v2)
	assert_true(hit_res.get("hit", false), "Non-culling ray should hit back face of triangle")
	assert_almost_eq(hit_res.get("distance", 0.0), 1.0, EPSILON, "Hit distance should be 1.0")
	assert_vec3_approx_eq(hit_res.get("point", Vector3.ZERO), Vector3(0.25, 0.25, 0.0), "Hit point should be (0.25, 0.25, 0)")

func test_ray_intersects_triangle_miss():
	var v0 := Vector3(0.0, 0.0, 0.0)
	var v1 := Vector3(1.0, 0.0, 0.0)
	var v2 := Vector3(0.0, 1.0, 0.0)

	# Ray outside triangle
	var origin := Vector3(2.0, 2.0, 1.0)
	var dir := Vector3(0.0, 0.0, -1.0)

	var hit_res: Dictionary = PBMath.ray_intersects_triangle(origin, dir, v0, v1, v2)
	assert_false(hit_res.get("hit", false), "Ray outside triangle should not hit")

func test_ray_intersects_triangle_parallel():
	var v0 := Vector3(0.0, 0.0, 0.0)
	var v1 := Vector3(1.0, 0.0, 0.0)
	var v2 := Vector3(0.0, 1.0, 0.0)

	# Ray parallel to triangle plane (along +X)
	var origin := Vector3(0.25, 0.25, 1.0)
	var dir := Vector3(1.0, 0.0, 0.0)

	var hit_res: Dictionary = PBMath.ray_intersects_triangle(origin, dir, v0, v1, v2)
	assert_false(hit_res.get("hit", false), "Parallel ray should not hit triangle")

func test_ray_intersects_triangle_behind_ray():
	var v0 := Vector3(0.0, 0.0, 0.0)
	var v1 := Vector3(1.0, 0.0, 0.0)
	var v2 := Vector3(0.0, 1.0, 0.0)

	# Ray pointing away from triangle
	var origin := Vector3(0.25, 0.25, 1.0)
	var dir := Vector3(0.0, 0.0, 1.0)

	var hit_res: Dictionary = PBMath.ray_intersects_triangle(origin, dir, v0, v1, v2)
	assert_false(hit_res.get("hit", false), "Ray pointing away from triangle should not hit")

func test_distance_point_line_segment_2d():
	var start := Vector2(0.0, 0.0)
	var end := Vector2(2.0, 0.0)

	# Point projecting onto interior of segment
	var p_mid := Vector2(1.0, 1.5)
	assert_almost_eq(PBMath.distance_point_line_segment_2d(p_mid, start, end), 1.5, EPSILON, "Distance to interior of segment")

	# Point beyond start endpoint
	var p_before := Vector2(-1.0, 0.0)
	assert_almost_eq(PBMath.distance_point_line_segment_2d(p_before, start, end), 1.0, EPSILON, "Distance beyond start")

	# Point beyond end endpoint
	var p_after := Vector2(3.0, 0.0)
	assert_almost_eq(PBMath.distance_point_line_segment_2d(p_after, start, end), 1.0, EPSILON, "Distance beyond end")

	# Point at endpoint
	assert_almost_eq(PBMath.distance_point_line_segment_2d(start, start, end), 0.0, EPSILON, "Distance at start endpoint")
	assert_almost_eq(PBMath.distance_point_line_segment_2d(end, start, end), 0.0, EPSILON, "Distance at end endpoint")

	# Point directly on segment
	var p_on := Vector2(1.0, 0.0)
	assert_almost_eq(PBMath.distance_point_line_segment_2d(p_on, start, end), 0.0, EPSILON, "Distance on segment")

	# Degenerate zero-length segment
	var p_deg := Vector2(3.0, 4.0)
	assert_almost_eq(PBMath.distance_point_line_segment_2d(p_deg, Vector2.ZERO, Vector2.ZERO), 5.0, EPSILON, "Distance to point-segment")

func test_distance_point_line_segment_3d():
	var start := Vector3(0.0, 0.0, 0.0)
	var end := Vector3(0.0, 0.0, 4.0)

	# Point projecting onto interior
	var p_mid := Vector3(3.0, 0.0, 2.0)
	assert_almost_eq(PBMath.distance_point_line_segment_3d(p_mid, start, end), 3.0, EPSILON, "3D distance to interior")

	# Point beyond start
	var p_before := Vector3(0.0, 0.0, -2.0)
	assert_almost_eq(PBMath.distance_point_line_segment_3d(p_before, start, end), 2.0, EPSILON, "3D distance beyond start")

	# Point beyond end
	var p_after := Vector3(0.0, 0.0, 6.0)
	assert_almost_eq(PBMath.distance_point_line_segment_3d(p_after, start, end), 2.0, EPSILON, "3D distance beyond end")

func test_line_segment_intersect():
	# Crossing perpendicular segments
	var p0 := Vector2(0.0, -1.0)
	var p1 := Vector2(0.0, 1.0)
	var p2 := Vector2(-1.0, 0.0)
	var p3 := Vector2(1.0, 0.0)

	var res: Dictionary = PBMath.get_line_segment_intersect(p0, p1, p2, p3)
	assert_true(res.get("intersects", false), "Crossing segments should intersect")
	assert_vec2_approx_eq(res.get("point", Vector2.ZERO), Vector2(0.0, 0.0), "Intersection should be (0, 0)")

	# Parallel segments
	var res_par: Dictionary = PBMath.get_line_segment_intersect(
		Vector2(0.0, 0.0), Vector2(1.0, 0.0),
		Vector2(0.0, 1.0), Vector2(1.0, 1.0)
	)
	assert_false(res_par.get("intersects", false), "Parallel segments should not intersect")

	# T-junction (intersection at endpoint)
	var res_t: Dictionary = PBMath.get_line_segment_intersect(
		Vector2(0.0, 0.0), Vector2(2.0, 0.0),
		Vector2(1.0, 0.0), Vector2(1.0, 2.0)
	)
	assert_true(res_t.get("intersects", false), "T-junction should intersect")
	assert_vec2_approx_eq(res_t.get("point", Vector2.ZERO), Vector2(1.0, 0.0), "T-junction intersection point")

	# Non-intersecting disjoint segments
	var res_disjoint: Dictionary = PBMath.get_line_segment_intersect(
		Vector2(0.0, 0.0), Vector2(1.0, 0.0),
		Vector2(2.0, 2.0), Vector2(3.0, 2.0)
	)
	assert_false(res_disjoint.get("intersects", false), "Disjoint segments should not intersect")

func test_point_in_polygon_square():
	var square := PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(2.0, 0.0),
		Vector2(2.0, 2.0),
		Vector2(0.0, 2.0)
	])

	# Inside
	assert_true(PBMath.point_in_polygon(square, Vector2(1.0, 1.0)), "Center of square should be inside")
	assert_true(PBMath.point_in_polygon(square, Vector2(0.1, 0.1)), "Near corner should be inside")

	# Outside
	assert_false(PBMath.point_in_polygon(square, Vector2(3.0, 3.0)), "Outside square should be false")
	assert_false(PBMath.point_in_polygon(square, Vector2(-0.5, 1.0)), "Outside left should be false")

	# On edge
	assert_true(PBMath.point_in_polygon(square, Vector2(1.0, 0.0)), "Point on bottom edge should be inside/true")
	assert_true(PBMath.point_in_polygon(square, Vector2(2.0, 1.0)), "Point on right edge should be inside/true")

	# On vertex
	assert_true(PBMath.point_in_polygon(square, Vector2(0.0, 0.0)), "Point on vertex should be inside/true")

func test_point_in_polygon_concave_l_shape():
	# L-shaped polygon
	var l_shape := PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(2.0, 0.0),
		Vector2(2.0, 1.0),
		Vector2(1.0, 1.0),
		Vector2(1.0, 2.0),
		Vector2(0.0, 2.0)
	])

	# Inside bottom arm
	assert_true(PBMath.point_in_polygon(l_shape, Vector2(1.5, 0.5)), "Bottom arm interior should be inside")
	# Inside vertical arm
	assert_true(PBMath.point_in_polygon(l_shape, Vector2(0.5, 1.5)), "Vertical arm interior should be inside")
	# Inside common corner
	assert_true(PBMath.point_in_polygon(l_shape, Vector2(0.5, 0.5)), "Corner interior should be inside")
	# Outside the cutout (reflex region)
	assert_false(PBMath.point_in_polygon(l_shape, Vector2(1.5, 1.5)), "Cutout region should be outside")

func test_sqr_distance():
	var a := Vector3(0.0, 0.0, 0.0)
	var b := Vector3(1.0, 2.0, 2.0)
	assert_almost_eq(PBMath.sqr_distance(a, b), 9.0, EPSILON, "Sqr distance of (1,2,2) should be 9.0")
	assert_almost_eq(PBMath.sqr_distance(a, a), 0.0, EPSILON, "Sqr distance to self should be 0.0")

	var c := Vector3(-1.0, -2.0, -3.0)
	var d := Vector3(1.0, 2.0, 3.0)
	assert_almost_eq(PBMath.sqr_distance(c, d), 56.0, EPSILON, "Sqr distance between (-1,-2,-3) and (1,2,3) should be 56.0")

# ==============================================================================
# P2-03: Projection Utilities
# ==============================================================================

func test_find_best_plane_coplanar_xy():
	var pts := PackedVector3Array([
		Vector3(0.0, 0.0, 5.0),
		Vector3(1.0, 0.0, 5.0),
		Vector3(1.0, 1.0, 5.0),
		Vector3(0.0, 1.0, 5.0)
	])
	var plane: Plane = PBMath.find_best_plane(pts)
	assert_almost_eq(absf(plane.normal.z), 1.0, EPSILON, "XY plane normal should have Z magnitude 1.0")
	assert_almost_eq(plane.normal.x, 0.0, EPSILON, "XY plane normal.x should be 0.0")
	assert_almost_eq(plane.normal.y, 0.0, EPSILON, "XY plane normal.y should be 0.0")

func test_find_best_plane_coplanar_xz():
	var pts := PackedVector3Array([
		Vector3(0.0, 3.0, 0.0),
		Vector3(2.0, 3.0, 0.0),
		Vector3(2.0, 3.0, 2.0),
		Vector3(0.0, 3.0, 2.0)
	])
	var plane: Plane = PBMath.find_best_plane(pts)
	assert_almost_eq(absf(plane.normal.y), 1.0, EPSILON, "XZ plane normal should have Y magnitude 1.0")
	assert_almost_eq(plane.normal.x, 0.0, EPSILON, "XZ plane normal.x should be 0.0")
	assert_almost_eq(plane.normal.z, 0.0, EPSILON, "XZ plane normal.z should be 0.0")

func test_find_best_plane_tilted():
	# Points satisfying x + y + z = 1 -> normal (1, 1, 1).normalized()
	var pts := PackedVector3Array([
		Vector3(1.0, 0.0, 0.0),
		Vector3(0.0, 1.0, 0.0),
		Vector3(0.0, 0.0, 1.0)
	])
	var plane: Plane = PBMath.find_best_plane(pts)
	var expected_n: Vector3 = Vector3(1.0, 1.0, 1.0).normalized()
	assert_vec3_approx_eq(plane.normal, expected_n, "Tilted plane normal should be (1,1,1).normalized()")

func test_find_best_plane_with_indexes():
	var pts := PackedVector3Array([
		Vector3(99.0, 99.0, 99.0), # Unused outlier
		Vector3(0.0, 0.0, 0.0),
		Vector3(1.0, 0.0, 0.0),
		Vector3(0.0, 1.0, 0.0)
	])
	var indexes := PackedInt32Array([1, 2, 3])
	var plane: Plane = PBMath.find_best_plane(pts, indexes)
	assert_almost_eq(absf(plane.normal.z), 1.0, EPSILON, "Indexed best-fit plane should ignore outlier")

func test_vector_to_projection_axis():
	assert_eq(PBMath.vector_to_projection_axis(Vector3(1.0, 0.0, 0.0)), PBMath.PROJECTION_X, "+X axis")
	assert_eq(PBMath.vector_to_projection_axis(Vector3(-1.0, 0.0, 0.0)), PBMath.PROJECTION_X_NEG, "-X axis")
	assert_eq(PBMath.vector_to_projection_axis(Vector3(0.0, 1.0, 0.0)), PBMath.PROJECTION_Y, "+Y axis")
	assert_eq(PBMath.vector_to_projection_axis(Vector3(0.0, -1.0, 0.0)), PBMath.PROJECTION_Y_NEG, "-Y axis")
	assert_eq(PBMath.vector_to_projection_axis(Vector3(0.0, 0.0, 1.0)), PBMath.PROJECTION_Z, "+Z axis")
	assert_eq(PBMath.vector_to_projection_axis(Vector3(0.0, 0.0, -1.0)), PBMath.PROJECTION_Z_NEG, "-Z axis")

	# Dominant non-axis-aligned vectors
	assert_eq(PBMath.vector_to_projection_axis(Vector3(0.9, 0.1, 0.1)), PBMath.PROJECTION_X, "Dominant +X")
	assert_eq(PBMath.vector_to_projection_axis(Vector3(0.1, -0.9, 0.1)), PBMath.PROJECTION_Y_NEG, "Dominant -Y")
	assert_eq(PBMath.vector_to_projection_axis(Vector3(0.1, 0.1, -0.9)), PBMath.PROJECTION_Z_NEG, "Dominant -Z")

func test_get_tangent_to_axis():
	assert_vec3_approx_eq(PBMath.get_tangent_to_axis(PBMath.PROJECTION_X), Vector3.UP, "X tangent is UP")
	assert_vec3_approx_eq(PBMath.get_tangent_to_axis(PBMath.PROJECTION_X_NEG), Vector3.UP, "-X tangent is UP")
	assert_vec3_approx_eq(PBMath.get_tangent_to_axis(PBMath.PROJECTION_Y), Vector3.FORWARD, "Y tangent is FORWARD")
	assert_vec3_approx_eq(PBMath.get_tangent_to_axis(PBMath.PROJECTION_Y_NEG), Vector3.FORWARD, "-Y tangent is FORWARD")
	assert_vec3_approx_eq(PBMath.get_tangent_to_axis(PBMath.PROJECTION_Z), Vector3.UP, "Z tangent is UP")
	assert_vec3_approx_eq(PBMath.get_tangent_to_axis(PBMath.PROJECTION_Z_NEG), Vector3.UP, "-Z tangent is UP")

func test_planar_project_cube_front_face():
	var cube: PBMeshData = PBMeshData.create_cube(1.0)
	# Face 0: Front face vertices at Z = -0.5
	var face0: PBFace = cube.faces[0]
	var distinct_idxs: PackedInt32Array = face0.get_distinct_indexes()

	var uvs: PackedVector2Array = PBMath.planar_project(cube.positions, distinct_idxs)
	assert_eq(uvs.size(), distinct_idxs.size(), "Projected UVs size must match indexed count")

	# Check bounding size of projected UVs is 1.0 x 1.0 (quad size)
	var min_u: float = uvs[0].x
	var max_u: float = uvs[0].x
	var min_v: float = uvs[0].y
	var max_v: float = uvs[0].y
	for uv in uvs:
		min_u = minf(min_u, uv.x)
		max_u = maxf(max_u, uv.x)
		min_v = minf(min_v, uv.y)
		max_v = maxf(max_v, uv.y)

	assert_almost_eq(max_u - min_u, 1.0, EPSILON, "Front face projected U span should be 1.0")
	assert_almost_eq(max_v - min_v, 1.0, EPSILON, "Front face projected V span should be 1.0")

func test_planar_project_with_direction():
	var positions := PackedVector3Array([
		Vector3(0.0, 0.0, 0.0),
		Vector3(2.0, 0.0, 0.0),
		Vector3(2.0, 3.0, 0.0),
		Vector3(0.0, 3.0, 0.0)
	])
	var uvs: PackedVector2Array = PBMath.planar_project(positions, PackedInt32Array(), Vector3(0.0, 0.0, 1.0))
	assert_eq(uvs.size(), 4, "Should project all 4 vertices")

	var width: float = absf(uvs[1].x - uvs[0].x)
	var height: float = absf(uvs[2].y - uvs[1].y)
	assert_almost_eq(width, 2.0, EPSILON, "Projected width should be 2.0")
	assert_almost_eq(height, 3.0, EPSILON, "Projected height should be 3.0")

# ==============================================================================
# P2-06: Snapping
# ==============================================================================

func test_snap_value():
	assert_almost_eq(PBMath.snap_value(0.74, 0.25), 0.75, EPSILON, "0.74 snapped to 0.25 is 0.75")
	assert_almost_eq(PBMath.snap_value(0.62, 0.25), 0.50, EPSILON, "0.62 snapped to 0.25 is 0.50")
	assert_almost_eq(PBMath.snap_value(1.2, 0.5), 1.0, EPSILON, "1.2 snapped to 0.5 is 1.0")
	assert_almost_eq(PBMath.snap_value(1.4, 0.5), 1.5, EPSILON, "1.4 snapped to 0.5 is 1.5")
	assert_almost_eq(PBMath.snap_value(-0.74, 0.25), -0.75, EPSILON, "-0.74 snapped to 0.25 is -0.75")

	# Zero snap size returns original value
	assert_almost_eq(PBMath.snap_value(3.1415, 0.0), 3.1415, EPSILON, "Zero snap size returns value")

func test_snap_vector3():
	var v := Vector3(1.23, 4.56, -7.89)
	var snap_size := Vector3(0.5, 1.0, 0.25)
	var snapped: Vector3 = PBMath.snap_vector3(v, snap_size)
	assert_vec3_approx_eq(snapped, Vector3(1.0, 5.0, -8.0), "Component-wise snap of Vector3")

func test_snap_angle():
	assert_almost_eq(PBMath.snap_angle(43.0, 15.0), 45.0, EPSILON, "43 deg snapped to 15 deg is 45 deg")
	assert_almost_eq(PBMath.snap_angle(92.0, 90.0), 90.0, EPSILON, "92 deg snapped to 90 deg is 90 deg")
	assert_almost_eq(PBMath.snap_angle(-44.0, 45.0), -45.0, EPSILON, "-44 deg snapped to 45 deg is -45 deg")
	assert_almost_eq(PBMath.snap_angle(37.5, 0.0), 37.5, EPSILON, "Zero snap angle returns angle")
