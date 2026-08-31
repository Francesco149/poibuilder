extends GutTest

# ==============================================================================
# Sphere (Icosphere) Tests
# ==============================================================================

func test_sphere_default():
	var md = PBShapeComplex.create_sphere()
	assert_eq(md.validate(), "", "Sphere should validate")
	# 2 subdivisions: 20 × 4^2 = 320 faces, 960 vertices
	assert_eq(md.face_count(), 320, "Sphere: 320 faces")
	assert_eq(md.vertex_count(), 960, "Sphere: 960 vertices")

func test_sphere_0_subdivision():
	var md = PBShapeComplex.create_sphere(0.5, 0)
	assert_eq(md.validate(), "")
	assert_eq(md.face_count(), 20)
	assert_eq(md.vertex_count(), 60)

func test_sphere_1_subdivision():
	var md = PBShapeComplex.create_sphere(0.5, 1)
	assert_eq(md.validate(), "")
	assert_eq(md.face_count(), 80)
	assert_eq(md.vertex_count(), 240)

func test_sphere_positions_on_surface():
	var md = PBShapeComplex.create_sphere(1.0, 1)
	for i in range(md.vertex_count()):
		var r = md.positions[i].length()
		assert_almost_eq(r, 1.0, 0.01, "Vertex should be on sphere surface")

func test_sphere_compiles():
	var md = PBShapeComplex.create_sphere(0.5, 1)
	var mesh = md.to_array_mesh()
	assert_not_null(mesh)
	assert_gt(mesh.get_surface_count(), 0)

func test_sphere_normals():
	var md = PBShapeComplex.create_sphere(1.0, 1)
	var normals = md.calculate_normals()
	assert_eq(normals.size(), md.vertex_count())
	for i in range(md.vertex_count()):
		var n: Vector3 = normals[i]
		var p: Vector3 = md.positions[i]
		# Outward normal should have positive dot product with vertex position
		assert_gt(n.dot(p), 0.0, "Icosphere normals should face outward")

func test_sphere_smoothing_groups():
	var md_smooth = PBShapeComplex.create_sphere(0.5, 1, true)
	for f in md_smooth.faces:
		assert_eq(f.smoothing_group, 1)

	var md_flat = PBShapeComplex.create_sphere(0.5, 1, false)
	for f in md_flat.faces:
		assert_eq(f.smoothing_group, 0)

# ==============================================================================
# Torus Tests
# ==============================================================================

func test_torus_default():
	var md = PBShapeComplex.create_torus()
	assert_eq(md.validate(), "", "Torus should validate")
	# 12 rows × 16 columns = 192 faces, 768 vertices
	assert_eq(md.face_count(), 192)
	assert_eq(md.vertex_count(), 768)

func test_torus_small():
	var md = PBShapeComplex.create_torus(0.5, 0.1, 4, 6)
	assert_eq(md.validate(), "")
	assert_eq(md.face_count(), 24)
	assert_eq(md.vertex_count(), 96)

func test_torus_compiles():
	var md = PBShapeComplex.create_torus(0.5, 0.1, 4, 6)
	var mesh = md.to_array_mesh()
	assert_not_null(mesh)

func test_torus_normals():
	var md = PBShapeComplex.create_torus(0.5, 0.1, 4, 6)
	var normals = md.calculate_normals()
	assert_eq(normals.size(), md.vertex_count())
	for n in normals:
		assert_almost_eq(n.length(), 1.0, 0.01)

func test_torus_smoothing_groups():
	var md_smooth = PBShapeComplex.create_torus(0.5, 0.1, 4, 6, true)
	for f in md_smooth.faces:
		assert_eq(f.smoothing_group, 1)

	var md_flat = PBShapeComplex.create_torus(0.5, 0.1, 4, 6, false)
	for f in md_flat.faces:
		assert_eq(f.smoothing_group, 0)

# ==============================================================================
# Arch Tests
# ==============================================================================

func test_arch_default():
	var md = PBShapeComplex.create_arch()
	assert_eq(md.validate(), "", "Arch should validate")
	assert_gt(md.face_count(), 0)
	assert_gt(md.vertex_count(), 0)
	# 8 sides × 4 faces (outer, inner, front, back) + 2 end caps = 34 faces
	assert_eq(md.face_count(), 34)
	assert_eq(md.vertex_count(), 136)

func test_arch_compiles():
	var md = PBShapeComplex.create_arch()
	var mesh = md.to_array_mesh()
	assert_not_null(mesh)

func test_arch_full_circle():
	var md = PBShapeComplex.create_arch(1.0, 0.5, 0.25, 8, 360.0, false)
	assert_eq(md.validate(), "")
	# 8 sides × 4 faces = 32 faces (no end caps on 360)
	assert_eq(md.face_count(), 32)
	assert_eq(md.vertex_count(), 128)

func test_arch_no_end_caps():
	var md = PBShapeComplex.create_arch(1.0, 0.5, 0.25, 6, 180.0, false)
	assert_eq(md.validate(), "")
	# 6 sides × 4 faces = 24 faces
	assert_eq(md.face_count(), 24)
	assert_eq(md.vertex_count(), 96)

func test_arch_normals():
	var md = PBShapeComplex.create_arch()
	var normals = md.calculate_normals()
	assert_eq(normals.size(), md.vertex_count())
	for n in normals:
		assert_almost_eq(n.length(), 1.0, 0.01)

# ==============================================================================
# Stairs Tests
# ==============================================================================

func test_stairs_default():
	var md = PBShapeComplex.create_stairs()
	assert_eq(md.validate(), "", "Stairs should validate")
	assert_gt(md.face_count(), 0)
	assert_gt(md.vertex_count(), 0)
	# 6 steps × 2 (riser+tread) + 6 left + 6 right + 1 back = 25 faces
	assert_eq(md.face_count(), 25)
	assert_eq(md.vertex_count(), 100)

func test_stairs_step_count():
	var md = PBShapeComplex.create_stairs(Vector3(1, 1, 2), 4, false)
	assert_eq(md.validate(), "")
	# 4 steps × 2 faces (riser + tread) = 8 faces (no sides, no back)
	assert_eq(md.face_count(), 8, "4 steps without sides: 8 faces")
	assert_eq(md.vertex_count(), 32)

func test_stairs_with_sides():
	var md = PBShapeComplex.create_stairs(Vector3(1, 1, 2), 4, true)
	assert_eq(md.validate(), "")
	assert_gt(md.face_count(), 8, "With sides should have more faces")
	# 4 × 2 + 4 + 4 + 1 = 17 faces
	assert_eq(md.face_count(), 17)
	assert_eq(md.vertex_count(), 68)

func test_stairs_compiles():
	var md = PBShapeComplex.create_stairs()
	var mesh = md.to_array_mesh()
	assert_not_null(mesh)

func test_stairs_normals():
	var md = PBShapeComplex.create_stairs()
	var normals = md.calculate_normals()
	assert_eq(normals.size(), md.vertex_count())
	for n in normals:
		assert_almost_eq(n.length(), 1.0, 0.01)

# ==============================================================================
# Door Tests
# ==============================================================================

func test_door_default():
	var md = PBShapeComplex.create_door()
	assert_eq(md.validate(), "", "Door should validate")
	assert_eq(md.face_count(), 13, "Door: 13 faces")
	assert_eq(md.vertex_count(), 52, "Door: 52 vertices")

func test_door_compiles():
	var md = PBShapeComplex.create_door()
	var mesh = md.to_array_mesh()
	assert_not_null(mesh)

func test_door_normals():
	var md = PBShapeComplex.create_door()
	var normals = md.calculate_normals()
	assert_eq(normals.size(), md.vertex_count())
	for n in normals:
		assert_almost_eq(n.length(), 1.0, 0.01)

func test_door_shared_vertices():
	var md = PBShapeComplex.create_door()
	assert_gt(md.shared_vertices.size(), 0)
	# Coincident lookup should find sharing vertices
	var lookup = md.get_shared_vertex_lookup()
	assert_eq(lookup.size(), md.vertex_count())
