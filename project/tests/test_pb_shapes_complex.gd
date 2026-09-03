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

func test_torus_normals_face_away_from_the_tube():
	# Winding regression: the quad order used to produce INWARD normals
	# (the classic inside-out torus — every face culled from outside).
	var major := 0.5
	var minor := 0.1
	var md = PBShapeComplex.create_torus(major, minor, 8, 10)
	var normals = md.calculate_normals()
	for f in md.faces:
		var idxs: PackedInt32Array = f.get_indexes()
		var c := Vector3.ZERO
		for j in idxs:
			c += md.positions[j]
		c /= float(idxs.size())
		# Closest point on the ring's center circle (the tube's spine).
		var flat := Vector2(c.x, c.z).normalized() * major
		var spine := Vector3(flat.x, 0.0, flat.y)
		assert_gt(normals[idxs[0]].dot(c - spine), 0.0,
			"Torus faces must point away from the tube's spine (outward)")

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
	# Arched default (6 segments): 5+6 front + 5+6 back + 2 jambs + 6 tunnel
	# + 3 outer walls = 33 faces (apex spandrels are triangles, still 1 face
	# per arc segment).
	assert_eq(md.face_count(), 33, "Door: 33 faces")

func test_door_flat_lintel_has_closed_outer_shell():
	# v0.9.13: the legs' OUTER walls (±X) and the lintel's top (+Y) used to
	# be missing — the frame was hollow when seen from the side/above.
	var md = PBShapeComplex.create_door(3.0, 2.5, 2.0, 0.5, 1.0, false)
	assert_eq(md.validate(), "")
	# 5+5 front/back + 2 jambs + 1 lintel + 3 outer walls = 16 quads.
	assert_eq(md.face_count(), 16, "Flat door: 16 faces")
	assert_eq(md.vertex_count(), 64, "Flat door: 64 vertices")

	var left_faces: Array = []
	var right_faces: Array = []
	var top_faces: Array = []
	for fi in range(md.faces.size()):
		var idxs: PackedInt32Array = md.faces[fi].get_indexes()
		var all_left := true
		var all_right := true
		var all_top := true
		for j in idxs:
			var p: Vector3 = md.positions[j]
			all_left = all_left and absf(p.x + 1.5) < 0.001
			all_right = all_right and absf(p.x - 1.5) < 0.001
			all_top = all_top and absf(p.y - 1.25) < 0.001
		if all_left:
			left_faces.append(fi)
		if all_right:
			right_faces.append(fi)
		if all_top:
			top_faces.append(fi)
	assert_eq(left_faces.size(), 1, "Exactly one left outer wall quad")
	assert_eq(right_faces.size(), 1, "Exactly one right outer wall quad")
	assert_eq(top_faces.size(), 1, "Exactly one top wall quad")

	# And they must face OUTWARD (normals agree with the geometry).
	var normals = md.calculate_normals()
	assert_lt(normals[md.faces[left_faces[0]].get_indexes()[0]].x, 0.0,
		"Left outer wall faces -X")
	assert_gt(normals[md.faces[right_faces[0]].get_indexes()[0]].x, 0.0,
		"Right outer wall faces +X")
	assert_gt(normals[md.faces[top_faces[0]].get_indexes()[0]].y, 0.0,
		"Top wall faces +Y")

func test_door_opening_height_measured_from_the_bottom():
	# v0.9.13 semantics: opening_height is the opening's height above the
	# bottom edge (it used to be the lintel height — a 2m opening_height on
	# a 2.5m door left a 0.5m slot).
	var md = PBShapeComplex.create_door(3.0, 2.5, 2.0, 0.5, 1.0, false)
	var opening_top := -1.25 + 2.0
	var found_jamb_top := false
	for p in md.positions:
		if absf(p.x + 1.0) < 0.001 and absf(p.y - opening_top) < 0.001:
			found_jamb_top = true
	assert_true(found_jamb_top, "The jamb tops sit at bottom + opening_height")

func test_door_arch_reaches_the_opening_top():
	var md = PBShapeComplex.create_door(3.0, 2.5, 2.0, 0.5, 1.0, true, 6)
	var found_apex := false
	for p in md.positions:
		if absf(p.x) < 0.001 and absf(p.y - 0.75) < 0.001 and absf(absf(p.z) - 0.5) < 0.001:
			found_apex = true
	assert_true(found_apex, "The arch's apex touches the opening top on both faces")

func test_door_arch_segments_param_changes_topology():
	var three = PBShapeComplex.create_door(3.0, 2.5, 2.0, 0.5, 1.0, true, 3)
	var eight = PBShapeComplex.create_door(3.0, 2.5, 2.0, 0.5, 1.0, true, 8)
	assert_eq(three.validate(), "")
	assert_eq(eight.validate(), "")
	assert_eq(three.face_count(), 15 + 3 * 3, "3 segments: 24 faces")
	assert_eq(eight.face_count(), 15 + 3 * 8, "8 segments: 39 faces")

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
