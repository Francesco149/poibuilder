extends GutTest

## Tests for PBShapeTrim: architectural moulding profiles and path sweep generation.

func test_profile_points_generation() -> void:
	for p_type in [PBShapeTrim.ProfileType.FLAT, PBShapeTrim.ProfileType.CHAMFER,
			PBShapeTrim.ProfileType.ROUND, PBShapeTrim.ProfileType.COVE,
			PBShapeTrim.ProfileType.OGEE, PBShapeTrim.ProfileType.STEPPED]:
		var pts := PBShapeTrim.get_profile_points(p_type, 0.1, 0.2)
		assert_gte(pts.size(), 4, "Profile %d should have at least 4 points" % p_type)
		# Verify bounding box
		for p in pts:
			assert_gte(p.x, 0.0, "Profile x depth should be >= 0")
			assert_lte(p.x, 0.1001, "Profile x depth should be <= width")
			assert_gte(p.y, 0.0, "Profile y height should be >= 0")
			assert_lte(p.y, 0.2001, "Profile y height should be <= height")

func test_extrude_profile_straight_wall() -> void:
	var path := PackedVector3Array([
		Vector3(0.0, 0.0, 0.0),
		Vector3(4.0, 0.0, 0.0)
	])
	var md := PBShapeTrim.create_wall_trim(path, PBShapeTrim.ProfileType.CHAMFER, 0.1, 0.2, false)
	assert_not_null(md, "Wall trim mesh data should not be null")
	assert_gt(md.faces.size(), 0, "Wall trim should have faces")
	assert_gt(md.positions.size(), 0, "Wall trim should have vertices")

	# Open path with 5 profile segments has 5 side quads + 2 caps = 7 faces
	assert_eq(md.faces.size(), 7, "Chamfer trim with 5 profile quads + 2 caps = 7 faces")

func test_extrude_profile_closed_room_perimeter() -> void:
	var path := PackedVector3Array([
		Vector3(0.0, 0.0, 0.0),
		Vector3(5.0, 0.0, 0.0),
		Vector3(5.0, 0.0, 5.0),
		Vector3(0.0, 0.0, 5.0)
	])
	var md := PBShapeTrim.create_wall_trim(path, PBShapeTrim.ProfileType.ROUND, 0.1, 0.2, true)
	assert_not_null(md, "Closed room perimeter trim should not be null")
	assert_gt(md.faces.size(), 0, "Closed room perimeter trim should have faces")

	# Closed room perimeter should be a continuous tube / loop with 0 open boundary edges
	var boundaries := PBSelectionOps.select_boundary_edges(md)
	assert_eq(boundaries.size(), 0, "Closed wall trim loop should be watertight/manifold with no boundary edges")
