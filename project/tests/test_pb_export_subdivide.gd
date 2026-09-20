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

## A poibuilderized-style face: one triangle with an authored unwrap pointing
## into a sub-rect of a pack atlas (the reported barrel-hoops case). Its
## fragments must sample the AUTHORED unwrap — the old behaviour rebuilt every
## fragment UV from the planar metres projection, which is what mangled
## converted props on the retro target while they looked right in the editor.
func test_manual_uv_face_subdivides_with_authored_uvs() -> void:
	var mesh_data := PBMeshData.new()
	var hw := 2.0
	# A 4m x 4m vertical quad in the X-Y plane, two triangles (CCW from +Z).
	mesh_data.positions = PackedVector3Array([
		Vector3(-hw, -hw, 0), Vector3(-hw, hw, 0), Vector3(hw, hw, 0),
		Vector3(-hw, -hw, 0), Vector3(hw, hw, 0), Vector3(hw, -hw, 0),
	])
	# Authored UVs sample the atlas rect u [0.25, 0.5], v [0.5, 0.75].
	var uv_a := Vector2(0.25, 0.5)
	var uv_b := Vector2(0.25, 0.75)
	var uv_c := Vector2(0.5, 0.75)
	var uv_d := Vector2(0.5, 0.5)
	mesh_data.textures0 = PackedVector2Array([uv_a, uv_b, uv_c, uv_a, uv_c, uv_d])
	var face := PBFace.new(PackedInt32Array([0, 1, 2, 3, 4, 5]))
	face.manual_uv = true
	mesh_data.faces = [face]
	mesh_data.invalidate_caches()

	var frags := PBFaceSubdivider.subdivide_face(mesh_data, face, 0, true, 1.0)
	assert_gt(frags.size(), 0, "A 4m manual-UV face must subdivide on the 1m grid")
	for frag in frags:
		for uv in frag.uvs:
			assert_between(uv.x, 0.25 - 0.001, 0.5 + 0.001,
				"Fragment UVs must stay inside the authored atlas rect (got %s)" % [uv])
			assert_between(uv.y, 0.5 - 0.001, 0.75 + 0.001,
				"Fragment UVs must stay inside the authored atlas rect (got %s)" % [uv])

	# The quad's original corners survive as fragment vertices carrying their
	# EXACT authored UVs (planar projection would read metres here).
	var wanted := [uv_a, uv_b, uv_c, uv_d]
	var found := {}
	for frag in frags:
		for i in range(frag.positions.size()):
			for w in wanted:
				if frag.uvs[i].distance_to(w) < 0.0001:
					found[w] = true
	assert_eq(found.size(), 4, "All four authored corner UVs must survive subdivision")

func test_non_manual_face_keeps_planar_uvs() -> void:
	# Control: a native (non-manual) face still gets the planar projection —
	# for a 4m face those coordinates reach metres, not the 0..1 rect.
	var mesh_data: PBMeshData = PBMeshData.create_cube(4.0)
	var face: PBFace = mesh_data.faces[0]
	assert_false(face.manual_uv, "Cube faces are auto-UV")
	var frags := PBFaceSubdivider.subdivide_face(mesh_data, face, 0, true, 1.0)
	assert_gt(frags.size(), 0)
	var max_coord := -INF
	for frag in frags:
		for uv in frag.uvs:
			max_coord = maxf(max_coord, maxf(uv.x, uv.y))
	assert_gt(max_coord, 1.0, "Auto-UV faces keep their planar (tiled) coordinates")
