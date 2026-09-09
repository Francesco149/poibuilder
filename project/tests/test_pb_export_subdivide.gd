## Unit tests for PBFaceSubdivider
extends GutTest

func test_subdivide_disabled_returns_single_fragment() -> void:
	var mesh_data: PBMeshData = PBMeshData.create_cube(1.0)
	var face: PBFace = mesh_data.faces[0]
	var frags := PBFaceSubdivider.subdivide_face(mesh_data, face, 0, false, 1.0)
	assert_eq(frags.size(), 1, "Subdivide false should return exactly 1 fragment")
	assert_eq(frags[0].indices.size(), face.get_indexes().size(), "Index count should match original face")

func test_subdivide_2x2_cube_face_yields_4_tiles() -> void:
	var mesh_data: PBMeshData = PBShapeGenerators.create_box(Vector3(2.0, 2.0, 2.0))
	var face: PBFace = mesh_data.faces[0]
	var frags := PBFaceSubdivider.subdivide_face(mesh_data, face, 0, true, 1.0)
	assert_eq(frags.size(), 4, "A 2m x 2m face on a 1.0m grid should produce 4 tile fragments")

	for frag in frags:
		assert_gt(frag.positions.size(), 0, "Each tile must have vertex positions")
		assert_gt(frag.indices.size(), 0, "Each tile must have triangle indices")
		assert_eq(frag.indices.size() % 3, 0, "Triangle indices must be multiples of 3")
		for tuv in frag.tile_uvs:
			assert_between(tuv.x, -0.01, 1.01, "Local tile UV X should be normalized [0, 1]")
			assert_between(tuv.y, -0.01, 1.01, "Local tile UV Y should be normalized [0, 1]")

func test_subdivide_triangular_face() -> void:
	var mesh_data: PBMeshData = PBShapeGenerators.create_prism(Vector3(2.0, 2.0, 2.0))
	var tri_face: PBFace = null
	var tri_idx := -1
	for i in range(mesh_data.faces.size()):
		if mesh_data.faces[i].get_indexes().size() == 3:
			tri_face = mesh_data.faces[i]
			tri_idx = i
			break
	assert_not_null(tri_face, "Prism should have a triangular face")
	var frags := PBFaceSubdivider.subdivide_face(mesh_data, tri_face, tri_idx, true, 1.0)
	assert_gt(frags.size(), 0, "Prism triangular face should subdivide into tile fragments")
	for frag in frags:
		assert_eq(frag.indices.size() % 3, 0, "Clipped triangle fragments must be valid triangles")
