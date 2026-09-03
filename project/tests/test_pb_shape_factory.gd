extends GutTest

# = get_shape_ids =

func test_shape_ids_not_empty():
	var ids := PBShapeFactory.get_shape_ids()
	assert_gt(ids.size(), 0, "Must have at least one shape")
	assert_eq(ids.size(), 13, "Factory exposes 13 shape types")

func test_shape_ids_unique():
	var ids := PBShapeFactory.get_shape_ids()
	var seen: Dictionary = {}
	for id in ids:
		assert_false(seen.has(id), "Duplicate shape ID: %s" % id)
		seen[id] = true

func test_shape_ids_contain_all_types():
	var ids := PBShapeFactory.get_shape_ids()
	for expected in [&"cube", &"prism", &"plane", &"sprite",
		&"cylinder", &"cone", &"pipe",
		&"sphere", &"torus", &"arch", &"stair", &"curved_stair", &"door"]:
		assert_true(ids.has(expected), "Missing shape: %s" % expected)

# = is_valid_shape =

func test_is_valid_shape_known():
	for id in PBShapeFactory.get_shape_ids():
		assert_true(PBShapeFactory.is_valid_shape(id), "%s should be valid" % id)

func test_is_valid_shape_unknown():
	assert_false(PBShapeFactory.is_valid_shape(&"unknown_shape"))
	assert_false(PBShapeFactory.is_valid_shape(&""))

# = create_shape dispatch =

func test_create_cube():
	var md := PBShapeFactory.create_shape(&"cube")
	assert_not_null(md)
	assert_eq(md.validate(), "", "Cube validates")
	assert_eq(md.vertex_count(), 24)

func test_create_plane():
	var md := PBShapeFactory.create_shape(&"plane")
	assert_not_null(md)
	assert_eq(md.validate(), "")
	assert_eq(md.face_count(), 1)

func test_create_prism():
	var md := PBShapeFactory.create_shape(&"prism")
	assert_not_null(md)
	assert_eq(md.validate(), "")
	assert_eq(md.vertex_count(), 18)
	assert_eq(md.face_count(), 5)

func test_create_sprite():
	var md := PBShapeFactory.create_shape(&"sprite")
	assert_not_null(md)
	assert_eq(md.validate(), "")
	assert_eq(md.vertex_count(), 4)
	assert_eq(md.face_count(), 1)

func test_create_cylinder():
	var md := PBShapeFactory.create_shape(&"cylinder")
	assert_not_null(md)
	assert_eq(md.validate(), "")
	assert_gt(md.vertex_count(), 0)
	assert_gt(md.face_count(), 0)

func test_create_cone():
	var md := PBShapeFactory.create_shape(&"cone")
	assert_not_null(md)
	assert_eq(md.validate(), "")
	assert_gt(md.vertex_count(), 0)
	assert_gt(md.face_count(), 0)

func test_create_pipe():
	var md := PBShapeFactory.create_shape(&"pipe")
	assert_not_null(md)
	assert_eq(md.validate(), "")
	assert_gt(md.vertex_count(), 0)
	assert_gt(md.face_count(), 0)

func test_create_sphere():
	var md := PBShapeFactory.create_shape(&"sphere")
	assert_not_null(md)
	assert_eq(md.validate(), "")
	assert_gt(md.face_count(), 0)
	# All vertices on sphere surface
	var r := 0.5
	for i in range(md.vertex_count()):
		var len := md.positions[i].length()
		assert_almost_eq(len, r, 0.01, "Sphere vertex at radius")

func test_create_torus():
	var md := PBShapeFactory.create_shape(&"torus")
	assert_not_null(md)
	assert_eq(md.validate(), "")
	assert_gt(md.vertex_count(), 0)
	assert_gt(md.face_count(), 0)

func test_create_arch():
	var md := PBShapeFactory.create_shape(&"arch")
	assert_not_null(md)
	assert_eq(md.validate(), "")
	assert_gt(md.face_count(), 0)

func test_create_stairs():
	var md := PBShapeFactory.create_shape(&"stair")
	assert_not_null(md)
	assert_eq(md.validate(), "")
	assert_gt(md.face_count(), 0)

func test_create_curved_stair():
	var md := PBShapeFactory.create_shape(&"curved_stair")
	assert_not_null(md)
	assert_eq(md.validate(), "")
	assert_gt(md.face_count(), 0)

func test_create_door():
	var md := PBShapeFactory.create_shape(&"door")
	assert_not_null(md)
	assert_eq(md.validate(), "")
	# Factory door: arched default with 6 segments → 6+7 = 13 faces
	# (v0.9.17 welded shell: one ear-clipped n-gon per side).
	assert_eq(md.vertex_count(), 70)
	assert_eq(md.face_count(), 13)

func test_create_unknown():
	var md := PBShapeFactory.create_shape(&"nonexistent")
	assert_null(md, "Unknown shape returns null")

# = integration =

func test_all_shapes_compile_to_array_mesh():
	for id in PBShapeFactory.get_shape_ids():
		var md := PBShapeFactory.create_shape(id)
		assert_not_null(md, "Shape %s generates mesh data" % id)
		var mesh := md.to_array_mesh()
		assert_not_null(mesh, "Shape %s compiles to ArrayMesh" % id)
		assert_gt(mesh.get_surface_count(), 0, "Shape %s has at least 1 surface" % id)

func test_all_shapes_produce_valid_normals():
	for id in PBShapeFactory.get_shape_ids():
		var md := PBShapeFactory.create_shape(id)
		var normals := md.calculate_normals()
		assert_eq(normals.size(), md.vertex_count(),
			"Shape %s has %d normals for %d verts" % [id, normals.size(), md.vertex_count()])
		for i in range(normals.size()):
			assert_almost_eq(normals[i].length(), 1.0, 0.01,
				"Shape %s normal[%d] is unit" % [id, i])
