## Unit tests for PBTileBaker
extends GutTest

func test_unpainted_face_reuses_base_material() -> void:
	var mesh_node := PBMesh.create_cube(2.0)
	autofree(mesh_node)
	var mesh_data: PBMeshData = mesh_node.pb_mesh_data
	var face: PBFace = mesh_data.faces[0]

	var frags := PBFaceSubdivider.subdivide_face(mesh_data, face, 0, true, 1.0)
	assert_eq(frags.size(), 4, "2m x 2m face subdivided at 1m should have 4 fragments")

	var cache := {}
	var baked := PBTileBaker.bake_face_tiles(mesh_node, mesh_data, face, 0, frags, true, 64, cache)
	assert_eq(baked.baked_textures.size(), 0, "Unpainted face should generate 0 baked textures")
	assert_eq(baked.tile_materials.size(), 4, "All 4 fragments must have a material")

	# All 4 fragments must share the exact same base material instance
	var first_mat: Material = baked.tile_materials[frags[0]]
	assert_not_null(first_mat)
	for i in range(1, 4):
		assert_eq(baked.tile_materials[frags[i]], first_mat, "Unpainted tiles must share base material")

func test_decal_face_bakes_only_touched_tile() -> void:
	var mesh_node := PBMesh.create_cube(2.0)
	autofree(mesh_node)
	var mesh_data: PBMeshData = mesh_node.pb_mesh_data
	var face: PBFace = mesh_data.faces[4] # top face (normal +Y)

	# Paste a decal in one corner of the face's planar rect (the decal layer is
	# the same pixels a stamp writes, so the bake path is identical).
	var patch := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	patch.fill(Color(0.9, 0.2, 0.2, 1.0))
	var center := Vector3.ZERO
	for idx in face.get_distinct_indexes():
		center += mesh_data.positions[idx]
	center /= float(face.get_distinct_indexes().size())
	# 0.4 m across, offset to one corner of the 2 m face.
	var painted := PBSplat.paste_decal(mesh_data, center + Vector3(0.7, 0, 0.7), Vector3.UP, 0.0, 0.4, 1.0, patch)
	assert_eq(painted, 1, "Fixture: the decal must land on the face")

	var frags := PBFaceSubdivider.subdivide_face(mesh_data, face, 4, true, 1.0)
	assert_eq(frags.size(), 4)

	var cache := {}
	var baked := PBTileBaker.bake_face_tiles(mesh_node, mesh_data, face, 4, frags, true, 64, cache)

	assert_eq(baked.baked_textures.size(), 1, "Only the 1 decal tile should generate a baked texture")

	var baked_count := 0
	var base_count := 0
	for frag in frags:
		var mat: Material = baked.tile_materials[frag]
		if mat.resource_name.begins_with("BakedTile"):
			baked_count += 1
		else:
			base_count += 1

	assert_eq(baked_count, 1, "Exactly 1 fragment must use the BakedTile material")
	assert_eq(base_count, 3, "The other 3 fragments must reuse the unpainted base material")

## Baked tile texels must be sampled at TEXEL CENTERS, not endpoints. The old
## endpoint mapping put the cell's edge coordinates exactly on the first/last
## texel columns, duplicating the boundary content into BOTH adjacent tiles —
## visible as a dark 1-texel grid line at every tile boundary around splats
## and stamps (the stamp's navy border smeared across the whole bake grid).
## A horizontal ramp base makes the artifact unmissable: with endpoint
## sampling the last column of every tile lands on the wrap boundary (black),
## with texel centers it samples 0.5 texel short of the boundary (bright).
func test_baked_tile_samples_texel_centers_not_endpoints() -> void:
	var ramp := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	for x in range(256):
		var v := float(x) / 255.0
		for y in range(256):
			ramp.set_pixel(x, y, Color(v, v, v, 1.0))
	var base_mat := StandardMaterial3D.new()
	base_mat.albedo_texture = ImageTexture.create_from_image(ramp)

	var mesh_node := PBMesh.create_cube(2.0)
	autofree(mesh_node)
	var mesh_data: PBMeshData = mesh_node.pb_mesh_data
	var face: PBFace = mesh_data.faces[0]
	mesh_data.set_face_material(face, base_mat)

	# A near-transparent decal across the whole face: every tile has paint
	# (so every tile bakes) while the base ramp still sets the color.
	var faint := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	faint.fill(Color(0.5, 0.5, 0.5, 0.02))
	var face_center := Vector3.ZERO
	for idx in face.get_distinct_indexes():
		face_center += mesh_data.positions[idx]
	face_center /= float(face.get_distinct_indexes().size())
	var face_normal := PBMath.normal_from_positions(mesh_data.positions, face.get_indexes())
	assert_gt(PBSplat.paste_decal(mesh_data, face_center, face_normal, 0.0, 4.0, 1.0, faint), 0,
			"Fixture: the faint decal must cover the face")

	var frags := PBFaceSubdivider.subdivide_face(mesh_data, face, 0, true, 1.0)
	assert_eq(frags.size(), 4)
	var cache := {}
	var baked := PBTileBaker.bake_face_tiles(mesh_node, mesh_data, face, 0, frags, true, 64, cache)
	assert_eq(baked.baked_textures.size(), 4, "All 4 tiles must bake")

	var dark_edge_columns := 0
	for tex in baked.baked_textures:
		# The retro engine's GU_CLAMP wrap + pinned-mip detail policy key off
		# the texture name; without it every tile edge blends its own opposite
		# edge (dark/white fringes at every tile boundary on the device).
		assert_true(tex.resource_name.begins_with("TileAtlas"),
				"Baked tile texture must carry the TileAtlas name convention")
		var img := tex.get_image()
		assert_eq(img.get_width(), 64)
		assert_eq(img.get_height(), 64)
		# Last column center = 63.5/64 of the cell -> ramp ~0.992 (byte ~253).
		# Endpoint sampling wrapped to 0 (byte ~0): the old grid-line bug.
		assert_gt(_column_mean_r(img, 63), 200.0,
				"Tile's last column must sample half a texel short of the cell edge, not the wrapped boundary")
		assert_lt(_column_mean_r(img, 0), 30.0,
				"Tile's first column must sample half a texel past the cell edge")
		# The ramp's own dark START legitimately covers the first few columns
		# (column x samples byte 4x+2, so bytes 2..30 = columns 0..6); a wrapped
		# boundary column would show up as a dark column anywhere ELSE.
		for x in range(8, 64):
			assert_gt(_column_mean_r(img, x), 32.0,
					"Dark column at x=%d: content past the ramp's dark start must never wrap (old endpoint mapping)" % x)
		var dark_in_tile := 0
		for x in range(64):
			if _column_mean_r(img, x) < 32.0:
				dark_in_tile += 1
		assert_lte(dark_in_tile, 8, "Dark columns must be confined to the ramp's leading edge")

func _column_mean_r(img: Image, x: int) -> float:
	var sum := 0.0
	for y in range(img.get_height()):
		sum += img.get_pixel(x, y).r * 255.0
	return sum / float(img.get_height())

func test_enforce_pot_image_clamps_to_max_size() -> void:
	var img := Image.create(1024, 768, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	var out := PBTileBaker.enforce_pot_image(img, 256)
	assert_not_null(out)
	assert_lte(out.get_width(), 256)
	assert_lte(out.get_height(), 256)
	assert_eq(out.get_width() & (out.get_width() - 1), 0, "width must be power-of-two")
	assert_eq(out.get_height() & (out.get_height() - 1), 0, "height must be power-of-two")

func test_enforce_pot_image_lifts_npot() -> void:
	var img := Image.create(300, 180, false, Image.FORMAT_RGBA8)
	img.fill(Color.RED)
	var out := PBTileBaker.enforce_pot_image(img, 512)
	assert_ne(out.get_width(), 300)
	assert_ne(out.get_height(), 180)
	assert_eq(out.get_width() & (out.get_width() - 1), 0)
	assert_eq(out.get_height() & (out.get_height() - 1), 0)
	assert_lte(out.get_width(), 512)
	assert_lte(out.get_height(), 512)

