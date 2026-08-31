## Test: PB Simple Shape Generators
##
## Tests procedural mesh generation primitives:
## - Cube/Box Generator (segmented)
## - Plane Generator
## - Sprite Generator
## - Prism Generator
extends GutTest

# ==============================================================================
# 1. Cube / Box Tests
# ==============================================================================

func test_box_default():
	var md = PBShapeGenerators.create_box()
	assert_eq(md.validate(), "", "Box should validate")
	assert_eq(md.vertex_count(), 24, "Default box: 24 vertices")
	assert_eq(md.face_count(), 6, "Default box: 6 faces")
	assert_eq(md.index_count(), 36, "Default box: 36 indices")
	assert_eq(md.shared_vertices.size(), 8, "Default box: 8 shared groups")

func test_box_segmented():
	var md = PBShapeGenerators.create_box(Vector3.ONE, 2, 2, 2)
	assert_eq(md.validate(), "", "Segmented box should validate")
	# 2x2 segments per face pair: each face pair has 2*2=4 quads, 6 face pairs -> 24 quads
	# But actually: 3 pairs of opposite faces, each pair has 2 faces
	# Front/Back: w_seg × h_seg = 2×2 = 4 quads per face, ×2 = 8
	# Left/Right: d_seg × h_seg = 2×2 = 4 quads per face, ×2 = 8
	# Top/Bottom: w_seg × d_seg = 2×2 = 4 quads per face, ×2 = 8
	# Total: 24 faces, 96 vertices
	assert_eq(md.face_count(), 24, "2-seg box: 24 faces")
	assert_eq(md.vertex_count(), 96, "2-seg box: 96 vertices")

func test_box_asymmetric_segments():
	var md = PBShapeGenerators.create_box(Vector3(2, 3, 4), 3, 2, 1)
	assert_eq(md.validate(), "", "Asymmetric box should validate")
	# Front/Back: 3×2 = 6 quads ×2 = 12
	# Left/Right: 1×2 = 2 quads ×2 = 4
	# Top/Bottom: 3×1 = 3 quads ×2 = 6
	# Total: 22 faces, 88 vertices
	assert_eq(md.face_count(), 22)
	assert_eq(md.vertex_count(), 88)

func test_box_normals():
	var md = PBShapeGenerators.create_box()
	var normals = md.calculate_normals()
	assert_eq(normals.size(), 24)
	# All normals should be unit length
	for n in normals:
		assert_almost_eq(n.length(), 1.0, 0.01, "Normal should be unit")

func test_box_compiles_to_array_mesh():
	var md = PBShapeGenerators.create_box()
	var mesh = md.to_array_mesh()
	assert_not_null(mesh, "ArrayMesh created")
	assert_eq(mesh.get_surface_count(), 1, "Single surface")

# ==============================================================================
# 2. Plane Tests
# ==============================================================================

func test_plane_default():
	var md = PBShapeGenerators.create_plane()
	assert_eq(md.validate(), "", "Plane should validate")
	assert_eq(md.vertex_count(), 4, "Default plane: 4 vertices")
	assert_eq(md.face_count(), 1, "Default plane: 1 face")

func test_plane_subdivided():
	var md = PBShapeGenerators.create_plane(2.0, 2.0, 3, 3)
	assert_eq(md.validate(), "", "Subdivided plane should validate")
	assert_eq(md.face_count(), 9, "3x3 plane: 9 faces")
	assert_eq(md.vertex_count(), 36, "3x3 plane: 36 vertices")
	# All Y positions should be 0
	for i in range(md.vertex_count()):
		assert_almost_eq(md.positions[i].y, 0.0, 0.001, "Plane Y=0")

func test_plane_uvs():
	var md = PBShapeGenerators.create_plane(1.0, 1.0, 2, 2)
	assert_eq(md.textures0.size(), md.vertex_count(), "UV count matches vertex count")
	# Check UV range is 0..1
	for uv in md.textures0:
		assert_true(uv.x >= -0.001 and uv.x <= 1.001, "UV.x in range")
		assert_true(uv.y >= -0.001 and uv.y <= 1.001, "UV.y in range")

func test_plane_normals():
	var md = PBShapeGenerators.create_plane(2.0, 2.0, 2, 2)
	var normals = md.calculate_normals()
	assert_eq(normals.size(), 16)
	for n in normals:
		assert_almost_eq(n.x, 0.0, 0.01)
		assert_almost_eq(n.y, 1.0, 0.01)
		assert_almost_eq(n.z, 0.0, 0.01)

func test_plane_compiles_to_array_mesh():
	var md = PBShapeGenerators.create_plane()
	var mesh = md.to_array_mesh()
	assert_not_null(mesh, "ArrayMesh created")
	assert_eq(mesh.get_surface_count(), 1, "Single surface")

# ==============================================================================
# 3. Sprite Tests
# ==============================================================================

func test_sprite():
	var md = PBShapeGenerators.create_sprite()
	assert_eq(md.validate(), "", "Sprite should validate")
	assert_eq(md.vertex_count(), 4, "Sprite: 4 vertices")
	assert_eq(md.face_count(), 1, "Sprite: 1 face")
	assert_eq(md.index_count(), 6, "Sprite: 6 indices")

func test_sprite_compiles_to_array_mesh():
	var md = PBShapeGenerators.create_sprite()
	var mesh = md.to_array_mesh()
	assert_not_null(mesh, "ArrayMesh created")
	assert_eq(mesh.get_surface_count(), 1, "Single surface")

# ==============================================================================
# 4. Prism Tests
# ==============================================================================

func test_prism():
	var md = PBShapeGenerators.create_prism()
	assert_eq(md.validate(), "", "Prism should validate")
	assert_eq(md.vertex_count(), 18, "Prism: 18 vertices")
	assert_eq(md.face_count(), 5, "Prism: 5 faces")
	assert_eq(md.shared_vertices.size(), 6, "Prism: 6 shared groups")

func test_prism_sized():
	var md = PBShapeGenerators.create_prism(Vector3(2, 3, 4))
	assert_eq(md.validate(), "", "Sized prism should validate")
	assert_eq(md.face_count(), 5)
	assert_eq(md.vertex_count(), 18)
	assert_eq(md.shared_vertices.size(), 6)

func test_prism_normals():
	var md = PBShapeGenerators.create_prism()
	var normals = md.calculate_normals()
	assert_eq(normals.size(), 18)
	for n in normals:
		assert_almost_eq(n.length(), 1.0, 0.01, "Normal should be unit")

func test_prism_compiles_to_array_mesh():
	var md = PBShapeGenerators.create_prism()
	var mesh = md.to_array_mesh()
	assert_not_null(mesh, "ArrayMesh created")
	assert_eq(mesh.get_surface_count(), 1, "Single surface")
