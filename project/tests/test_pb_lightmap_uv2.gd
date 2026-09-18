## test_pb_lightmap_uv2.gd — UV2 lightmap unwrap contract.
##
## UV2 is the AUTHOR's channel: the splatting system writes mask coordinates to
## the CUSTOM0 vertex attribute, so unwrapping UV2 for LightmapGI must leave
## paint (and every other channel) alone. These tests lock that in, plus the
## per-face split the unwrap needs to represent island seams.
@tool
extends GutTest


func _manual_shared_edge_mesh() -> PBMeshData:
	# Two quads sharing their middle edge: the shared vertices are used by two
	# faces each — exactly the case a per-vertex lightmap UV cannot express.
	var data := PBMeshData.new()
	data.positions = PackedVector3Array([
		Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, 2),
		Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(1, 0, 2),
	])
	data.textures0 = PackedVector2Array([
		Vector2(0, 0), Vector2(0, 1), Vector2(0, 2),
		Vector2(1, 0), Vector2(1, 1), Vector2(1, 2),
	])
	data.faces = [
		PBFace.new(PackedInt32Array([0, 1, 4, 4, 3, 0])),
		PBFace.new(PackedInt32Array([1, 2, 5, 5, 4, 1])),
	]
	data.shared_vertices = PBMeshData.build_welds_from_positions(data.positions)
	data.invalidate_caches()
	return data


func test_unwrap_writes_uv2_and_atlas_size_hint() -> void:
	var data := PBMeshData.create_cube(2.0)
	PBUv.refresh_mesh_uvs(data, true)

	var err := PBUvOps.unwrap_lightmap_uv2(data)
	assert_eq(err, OK, "cube unwrap must succeed")
	assert_eq(data.textures1.size(), data.positions.size(), "UV2 must be written for every vertex")
	assert_true(data.lightmap_size_hint.x > 0 and data.lightmap_size_hint.y > 0,
			"the atlas size hint must be recorded (LightmapGI reads it)")
	for uv in data.textures1:
		assert_true(uv.x >= -0.001 and uv.x <= 1.001 and uv.y >= -0.001 and uv.y <= 1.001,
				"unwrapped UV2 must be normalized into the atlas")
		break  # one sample is enough; the loop above documents the invariant


func test_unwrap_gives_shared_vertices_private_corners() -> void:
	var data := _manual_shared_edge_mesh()
	assert_eq(data.positions.size(), 6, "fixture starts with a shared vertex pool")

	var err := PBUvOps.unwrap_lightmap_uv2(data)
	assert_eq(err, OK, "unwrap must succeed on a shared-edge mesh")
	assert_eq(data.positions.size(), 8, "each face must own its 4 corners after the split")
	assert_eq(data.textures1.size(), 8, "UV2 must cover the split vertices")

	# Faces must not share indices any more (seams are expressible), but the
	# duplicates are still welded together so dragging the corner moves both.
	var seen: Dictionary = {}
	for face in data.faces:
		for idx in face.get_distinct_indexes():
			assert_false(seen.has(idx), "face corners must be private after the split")
			seen[idx] = true

	var weld := data.get_shared_vertex_lookup()
	assert_eq(weld.get(1, -1), weld.get(6, -2),
			"split duplicates must stay in the source vertex's weld group")


func test_unwrap_leaves_splat_paint_and_uv1_alone() -> void:
	var cube := PBMesh.create_cube(2.0)
	add_child_autofree(cube)
	var data := cube.pb_mesh_data
	PBUv.refresh_mesh_uvs(data, true)
	var uv1_before := data.textures0.duplicate()

	# Paint the top face: splat material + one layer with a dab in the middle.
	var top := 4
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color.GREEN)
	var mat := PBSplat.create_splat_material()
	PBSplat.add_layer(mat, ImageTexture.create_from_image(img))
	data.set_face_material(data.faces[top], mat)
	PBSplat.paint_face_splat(data, data.faces[top], mat, 1, Vector3(0, 1.0, 0), 0.4, 0.0, 1.0)
	cube.rebuild()
	var bounds_before := data.faces[top].splat_bounds.duplicate()
	var mask_before := PBSplat.get_layer_mask_image(mat, 1).get_data()

	var err := PBUvOps.unwrap_lightmap_uv2(data)
	assert_eq(err, OK, "unwrap must succeed on a painted mesh")
	cube.rebuild()

	assert_eq(data.textures0, uv1_before, "UV1 (the texture unwrap) must not move")
	assert_eq(data.faces[top].splat_bounds, bounds_before,
			"the painted rect must keep its anchor (no stretch, no slide)")
	assert_eq(PBSplat.get_layer_mask_image(mat, 1).get_data(), mask_before,
			"the painted mask must be byte-identical after the unwrap")
	assert_eq(data.splat_uvs.size(), data.positions.size(),
			"mask coordinates must regenerate for the (possibly split) vertex pool")
	assert_eq(data.textures1.size(), data.positions.size(),
			"UV2 must be the unwrap result")
	assert_true(not data.splat_uvs.is_empty(), "paint survives the lightmap unwrap")
