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
	# Caps: (1 + 8) × 2 = 18 verts, 2 n-gon faces (1 top, 1 bottom)
	# Total: 50 verts, 10 faces
	assert_eq(md.vertex_count(), 50, "Default cylinder: 50 vertices")
	assert_eq(md.face_count(), 10, "Default cylinder: 10 faces (8 wall + 1 top n-gon + 1 bottom n-gon)")
	assert_eq(md.textures0.size(), 50, "UV count matches vertex count")
	assert_eq(md.faces[8].get_edges().size(), 8, "Top cap has 8 perimeter edges (single n-gon)")
	assert_eq(md.faces[9].get_edges().size(), 8, "Bottom cap has 8 perimeter edges (single n-gon)")

func test_cylinder_with_height_cuts():
	var md = PBShapeCylinder.create_cylinder(0.5, 1.0, 6, 2)
	assert_eq(md.validate(), "", "Cylinder with cuts should validate")
	# Wall: 6 × 3 × 4 = 72, Caps: (1 + 6) × 2 = 14. Total: 86 verts
	# Wall: 6 × 3 = 18, Caps: 2. Total: 20 faces
	assert_eq(md.vertex_count(), 86)
	assert_eq(md.face_count(), 20)

func test_cylinder_min_sides():
	var md = PBShapeCylinder.create_cylinder(0.5, 1.0, 3)
	assert_eq(md.validate(), "", "3-sided cylinder should validate")
	assert_eq(md.face_count(), 5)  # 3 wall + 2 cap
	assert_eq(md.vertex_count(), 20) # 3*4 + (1+3)*2 = 20

func test_cylinder_normals():
	var md = PBShapeCylinder.create_cylinder()
	var normals = md.calculate_normals()
	assert_eq(normals.size(), md.vertex_count())
	for n in normals:
		assert_almost_eq(n.length(), 1.0, 0.01, "Normal should be unit")

func test_cylinder_smoothing():
	var md_smooth = PBShapeCylinder.create_cylinder(0.5, 1.0, 8, 0, true)
	var md_flat = PBShapeCylinder.create_cylinder(0.5, 1.0, 8, 0, false)
	# First 8 faces are walls, remaining 2 are n-gon caps
	for i in range(8):
		assert_eq(md_smooth.faces[i].smoothing_group, 1, "Smooth wall face has smoothing_group = 1")
		assert_eq(md_flat.faces[i].smoothing_group, 0, "Flat wall face has smoothing_group = 0")
	for i in range(8, 10):
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
	# Wall: 8 × 1 × 8 = 64 verts, 16 faces
	# Rims: 8 × 2 × 2 = 32 verts, 2 n-gon annular faces
	# Total: 96 verts, 18 faces
	assert_eq(md.vertex_count(), 96)
	assert_eq(md.face_count(), 18)
	assert_eq(md.textures0.size(), 96)
	assert_eq(md.faces[16].get_edges().size(), 16, "Top rim has 16 perimeter edges (8 outer + 8 inner)")
	assert_eq(md.faces[17].get_edges().size(), 16, "Bottom rim has 16 perimeter edges (8 outer + 8 inner)")

func test_pipe_with_cuts():
	var md = PBShapeCylinder.create_pipe(0.5, 1.0, 0.15, 6, 2)
	assert_eq(md.validate(), "")
	# Wall: 6 × 3 × 8 = 144, Rim: 6 × 2 × 2 = 24. Total: 168 verts
	# Wall: 6 × 3 × 2 = 36, Rim: 2. Total: 38 faces
	assert_eq(md.vertex_count(), 168)
	assert_eq(md.face_count(), 38)

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
	# 8 outer walls + 8 inner walls = 16 wall faces; 1 top rim + 1 bottom rim = 2 rim faces
	for i in range(16):
		assert_eq(md_smooth.faces[i].smoothing_group, 1, "Wall face smoothing = 1")
		assert_eq(md_flat.faces[i].smoothing_group, 0, "Flat wall face smoothing = 0")
	for i in range(16, 18):
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
