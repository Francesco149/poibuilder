## Test: PB Cylindrical Shape Generators
##
## Tests procedural mesh generation primitives for cylindrical shapes:
## - Cylinder Generator (with cuts and smoothing)
## - Cone Generator (with smoothing)
## - Pipe Generator (hollow cylinder with thickness and cuts)
extends GutTest


# ==============================================================================
# 1. Cylinder Tests
# ==============================================================================

func test_cylinder_default():
	var md = PBShapeCylinder.create_cylinder()
	assert_eq(md.validate(), "", "Cylinder should validate")
	# 8 sides, 0 height cuts:
	# Wall: 8 × 1 × 4 = 32 verts, 8 faces
	# Caps: 8 × 6 = 48 verts, 16 faces
	# Total: 80 verts, 24 faces
	assert_eq(md.vertex_count(), 80, "Default cylinder: 80 vertices")
	assert_eq(md.face_count(), 24, "Default cylinder: 24 faces")
	assert_eq(md.textures0.size(), 80, "UV count matches vertex count")

func test_cylinder_with_height_cuts():
	var md = PBShapeCylinder.create_cylinder(0.5, 1.0, 6, 2)
	assert_eq(md.validate(), "", "Cylinder with cuts should validate")
	# Wall: 6 × 3 × 4 = 72, Caps: 6 × 6 = 36. Total: 108 verts
	# Wall: 6 × 3 = 18, Caps: 12. Total: 30 faces
	assert_eq(md.vertex_count(), 108)
	assert_eq(md.face_count(), 30)

func test_cylinder_min_sides():
	var md = PBShapeCylinder.create_cylinder(0.5, 1.0, 3)
	assert_eq(md.validate(), "", "3-sided cylinder should validate")
	assert_eq(md.face_count(), 9)  # 3 wall + 6 cap
	assert_eq(md.vertex_count(), 30) # 3*4 + 3*6 = 30

func test_cylinder_normals():
	var md = PBShapeCylinder.create_cylinder()
	var normals = md.calculate_normals()
	assert_eq(normals.size(), md.vertex_count())
	for n in normals:
		assert_almost_eq(n.length(), 1.0, 0.01, "Normal should be unit")

func test_cylinder_smoothing():
	var md_smooth = PBShapeCylinder.create_cylinder(0.5, 1.0, 8, 0, true)
	var md_flat = PBShapeCylinder.create_cylinder(0.5, 1.0, 8, 0, false)
	# First 8 faces are walls, remaining 16 are caps
	for i in range(8):
		assert_eq(md_smooth.faces[i].smoothing_group, 1, "Smooth wall face has smoothing_group = 1")
		assert_eq(md_flat.faces[i].smoothing_group, 0, "Flat wall face has smoothing_group = 0")
	for i in range(8, 24):
		assert_eq(md_smooth.faces[i].smoothing_group, 0, "Cap face has smoothing_group = 0")
		assert_eq(md_flat.faces[i].smoothing_group, 0, "Cap face has smoothing_group = 0")

func test_cylinder_shared_vertices():
	var md = PBShapeCylinder.create_cylinder(0.5, 1.0, 8, 0)
	# 8 divisions, 1 segment (2 rings of 8 + 2 centers = 18 shared groups)
	assert_eq(md.shared_vertices.size(), 18, "Cylinder has 18 shared vertex groups")

func test_cylinder_compiles():
	var md = PBShapeCylinder.create_cylinder()
	var mesh = md.to_array_mesh()
	assert_not_null(mesh)
	assert_gt(mesh.get_surface_count(), 0)


# ==============================================================================
# 2. Cone Tests
# ==============================================================================

func test_cone_default():
	var md = PBShapeCylinder.create_cone()
	assert_eq(md.validate(), "", "Cone should validate")
	# 8 sides × 6 verts = 48, 8 × 2 = 16 faces
	assert_eq(md.vertex_count(), 48)
	assert_eq(md.face_count(), 16)
	assert_eq(md.textures0.size(), 48)

func test_cone_3_sides():
	var md = PBShapeCylinder.create_cone(0.5, 1.0, 3)
	assert_eq(md.validate(), "")
	assert_eq(md.vertex_count(), 18)
	assert_eq(md.face_count(), 6)

func test_cone_normals():
	var md = PBShapeCylinder.create_cone()
	var normals = md.calculate_normals()
	assert_eq(normals.size(), md.vertex_count())
	for n in normals:
		assert_almost_eq(n.length(), 1.0, 0.01)

func test_cone_smoothing():
	var md_smooth = PBShapeCylinder.create_cone(0.5, 1.0, 8, true)
	var md_flat = PBShapeCylinder.create_cone(0.5, 1.0, 8, false)
	# First 8 faces are side faces, last 8 are bottom faces
	for i in range(8):
		assert_eq(md_smooth.faces[i].smoothing_group, 1, "Side face smoothing = 1")
		assert_eq(md_flat.faces[i].smoothing_group, 0, "Flat side face smoothing = 0")
	for i in range(8, 16):
		assert_eq(md_smooth.faces[i].smoothing_group, 0, "Bottom face smoothing = 0")
		assert_eq(md_flat.faces[i].smoothing_group, 0, "Bottom face smoothing = 0")

func test_cone_shared_vertices():
	var md = PBShapeCylinder.create_cone(0.5, 1.0, 8)
	# Apex (1) + bottom center (1) + base ring (8) = 10 shared groups
	assert_eq(md.shared_vertices.size(), 10, "Cone has 10 shared vertex groups")

func test_cone_compiles():
	var md = PBShapeCylinder.create_cone()
	var mesh = md.to_array_mesh()
	assert_not_null(mesh)
	assert_gt(mesh.get_surface_count(), 0)


# ==============================================================================
# 3. Pipe Tests
# ==============================================================================

func test_pipe_default():
	var md = PBShapeCylinder.create_pipe()
	assert_eq(md.validate(), "", "Pipe should validate")
	# 8 sides, 0 height cuts:
	# Wall: 8 × 1 × 8 = 64, Rim: 8 × 8 = 64. Total: 128 verts
	# Wall: 8 × 1 × 2 = 16, Rim: 16. Total: 32 faces
	assert_eq(md.vertex_count(), 128)
	assert_eq(md.face_count(), 32)
	assert_eq(md.textures0.size(), 128)

func test_pipe_with_cuts():
	var md = PBShapeCylinder.create_pipe(0.5, 1.0, 0.15, 6, 2)
	assert_eq(md.validate(), "")
	# Wall: 6 × 3 × 8 = 144, Rim: 6 × 8 = 48. Total: 192
	# Wall: 6 × 3 × 2 = 36, Rim: 12. Total: 48
	assert_eq(md.vertex_count(), 192)
	assert_eq(md.face_count(), 48)

func test_pipe_hollow():
	var md = PBShapeCylinder.create_pipe(1.0, 2.0, 0.2, 6)
	assert_eq(md.validate(), "")
	# Verify inner radius < outer radius
	var outer_r = 0.0
	var inner_r = INF
	for i in range(md.vertex_count()):
		var p = md.positions[i]
		var r = sqrt(p.x * p.x + p.z * p.z)
		if r > outer_r:
			outer_r = r
		if r > 0.01 and r < inner_r:
			inner_r = r
	assert_almost_eq(outer_r, 1.0, 0.01, "Outer radius")
	assert_true(inner_r < outer_r, "Inner < outer")

func test_pipe_normals():
	var md = PBShapeCylinder.create_pipe()
	var normals = md.calculate_normals()
	assert_eq(normals.size(), md.vertex_count())
	for n in normals:
		assert_almost_eq(n.length(), 1.0, 0.01)

func test_pipe_smoothing():
	var md_smooth = PBShapeCylinder.create_pipe(0.5, 1.0, 0.15, 8, 0, true)
	var md_flat = PBShapeCylinder.create_pipe(0.5, 1.0, 0.15, 8, 0, false)
	# 8 outer walls + 8 inner walls = 16 wall faces; 8 top rims + 8 bottom rims = 16 rim faces
	for i in range(16):
		assert_eq(md_smooth.faces[i].smoothing_group, 1, "Wall face smoothing = 1")
		assert_eq(md_flat.faces[i].smoothing_group, 0, "Flat wall face smoothing = 0")
	for i in range(16, 32):
		assert_eq(md_smooth.faces[i].smoothing_group, 0, "Rim face smoothing = 0")
		assert_eq(md_flat.faces[i].smoothing_group, 0, "Rim face smoothing = 0")

func test_pipe_shared_vertices():
	var md = PBShapeCylinder.create_pipe(0.5, 1.0, 0.15, 8, 0)
	# 8 sides, 1 segment: 4 rings of 8 (outer-top, outer-bottom, inner-top, inner-bottom) = 32 shared groups
	assert_eq(md.shared_vertices.size(), 32, "Pipe has 32 shared vertex groups")

func test_pipe_compiles():
	var md = PBShapeCylinder.create_pipe()
	var mesh = md.to_array_mesh()
	assert_not_null(mesh)
	assert_gt(mesh.get_surface_count(), 0)
