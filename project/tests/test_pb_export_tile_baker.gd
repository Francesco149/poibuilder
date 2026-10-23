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


# ==============================================================================
# Bake resolution & mask upsampling
# ==============================================================================

## The modern per-face bake must recover the texel density the uniform LIVE
## mask gave up. The live mask is a fixed 256 square (so per-dab paint cost
## cannot scale with face size), and the bake is the only place a large face
## can be resolved finely — it runs once per export, not once per dab.
##
## This is the reported "very low res splat mask on large faces": the bake used
## to size itself from the live mask (and the exporter's cap clamped it to the
## retro tile size), so a 60 m floor composited at 8.5 texels/m = 11.7 cm per
## texel. Upstream reached ~34 texels/m.
func test_bake_resolution_carries_density_on_large_faces() -> void:
	var floor_mesh := PBMesh.create_cube(60.0)
	autofree(floor_mesh)
	var data: PBMeshData = floor_mesh.pb_mesh_data
	var face: PBFace = data.faces[0]

	# The live mask is CAPPED (it may not grow with the face) …
	var live := PBSplat.live_mask_resolution_for(data, face)
	assert_eq(live, Vector2i(PBSplat.MASK_RESOLUTION, PBSplat.MASK_RESOLUTION),
			"the live mask must be capped at MASK_RESOLUTION on a 60 m face")
	# … while the BAKE opts into density, up to its own ceiling.
	var bake := PBSplat.bake_resolution(data, face)
	assert_eq(bake.x, PBSplat.MAX_RESOLUTION,
			"a 60 m face must bake at the ceiling (%d), got %d" % [PBSplat.MAX_RESOLUTION, bake.x])
	var texels_per_m := float(bake.x) / 60.0
	assert_true(texels_per_m > 30.0,
			"a 60 m face must bake at >30 texels/m (got %.1f = %.1f cm/texel)" % [
					texels_per_m, 100.0 / texels_per_m])

	# The export's own texture budget may only cap it DOWN, never silently
	# impose the retro tile size on the modern bake.
	var capped := PBSplat.bake_resolution(data, face, 512)
	assert_true(capped.x <= 512, "an explicit cap must be honoured (%d)" % capped.x)

## A low-res live mask must be interpolated UP to the bake's resolution, not
## point-sampled: nearest sampling prints the mask's texel blocks across the
## baked blend edge (measured 13 distinct levels and ~984-px flat runs on a
## 6-texel ramp upsampled 8x), while bilinear yields a smooth ramp.
func test_baked_blend_edge_is_smooth_not_blocky() -> void:
	var data: PBMeshData = PBShapeGenerators.create_plane(20.0, 20.0, 1, 1)
	PBUv.refresh_mesh_uvs(data, true)
	var face := data.faces[0]
	var base := StandardMaterial3D.new()
	var base_img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	base_img.fill(Color(0.05, 0.05, 0.05, 1.0))
	base.albedo_texture = ImageTexture.create_from_image(base_img)
	var mat := PBSplat.create_splat_material(base)
	data.set_face_material(face, mat)
	PBSplat.ensure_face_splat_bounds(data, face)
	var layer_tex := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	layer_tex.fill(Color(1.0, 1.0, 1.0, 1.0))
	var layer := PBSplat.add_layer(mat, ImageTexture.create_from_image(layer_tex))

	# A SOFT dab: its mask ramp is what the blend edge is made of.
	var bounds := PBSplat.get_face_planar_bounds(data, face)
	var u_ax: Vector3 = bounds["u"]
	var v_ax: Vector3 = bounds["v"]
	var centre: Vector3 = u_ax * ((bounds["min_u"] + bounds["max_u"]) * 0.5) \
			+ v_ax * ((bounds["min_v"] + bounds["max_v"]) * 0.5)
	PBSplat.paint_face_splat(data, face, mat, layer, centre, 5.0, 0.9, 1.0, false, {})

	var baked := PBTileBaker.bake_face_composite(data, face, 2048)
	assert_not_null(baked, "Fixture: the painted face must bake")
	if baked == null:
		return
	assert_eq(baked.get_width(), 2048, "Fixture: the 20 m face must bake at 2048")

	# Count DISTINCT values along the centre row: the blend is a smoothstep of
	# the mask, so a smooth bake shows many levels; point-sampling the 256 mask
	# across 2048 px shows only a handful of wide steps.
	var levels := {}
	var mid := baked.get_height() / 2
	for x in range(baked.get_width()):
		levels[snappedf(baked.get_pixel(x, mid).r, 0.001)] = true
	assert_true(levels.size() > 40,
			"the baked blend edge must be a smooth ramp, not mask texel blocks (only %d levels)" % levels.size())

# ── The raw-byte bake is the per-pixel bake, byte for byte (v0.9.182) ───────

## The ORACLE: the face composite written the straightforward way —
## get_pixel() reads, set_pixel() writes — which is what bake_face_composite
## computed before it moved onto raw byte buffers (22.7 s -> 8.9 s for an 8 m
## face). Any drift in the fast path's conversions shows up as a byte diff.
func _oracle_bake(data: PBMeshData, face: PBFace) -> Image:
	var state := PBSplat.collect_face_paint_state(data, face)
	var res := PBSplat.bake_resolution(data, face, 2048)
	var base_img: Image = null
	var bt = (data.get_face_material(face) as ShaderMaterial).get_shader_parameter("base_texture")
	if bt is Texture2D:
		base_img = (bt as Texture2D).get_image()
	var base_col: Color = state["base_color"]
	var b := PBSplat.get_face_planar_bounds(data, face)
	var out := Image.create(res.x, res.y, false, Image.FORMAT_RGBA8)
	var idx := face.get_indexes()
	for y in range(res.y):
		var mv := (float(y) + 0.5) / float(res.y)
		for x in range(res.x):
			var mu := (float(x) + 0.5) / float(res.x)
			# UV1 by solving barycentrics directly (the reference definition).
			var uv1 := Vector2(NAN, NAN)
			for t in range(0, idx.size(), 3):
				var pu := PackedFloat32Array()
				var pv := PackedFloat32Array()
				for k in range(3):
					var p := data.positions[idx[t + k]]
					pu.append(((b["u"] as Vector3).dot(p) - float(b["min_u"])) / float(b["range_u"]))
					pv.append(((b["v"] as Vector3).dot(p) - float(b["min_v"])) / float(b["range_v"]))
				var w := PBTileBaker._bake_weights(pu, pv, mu, mv)
				var wa := 1.0 - w.x - w.y
				if w.x >= -0.001 and w.y >= -0.001 and wa >= -0.001:
					uv1 = data.textures0[idx[t]] * wa + data.textures0[idx[t + 1]] * w.x + data.textures0[idx[t + 2]] * w.y
					break
			var c := base_col
			var base_alpha := 1.0
			if base_img != null:
				if uv1.x == uv1.x:
					c = PBTileBaker._sample_image_repeat(base_img, uv1.x, uv1.y) * base_col
					base_alpha = c.a
				else:
					base_alpha = base_col.a
			for L in state["layers"]:
				var mask: Image = L["mask_image"]
				var weight := PBTileBaker._sample_mask_bilinear(mask, mu, mv)
				var edge_w: float = lerpf(maxf(1.5 / float(mask.get_width()) * 2.0, 0.02), 0.48, float(L["roughness"]))
				var blend := smoothstep(0.5 - edge_w, 0.5 + edge_w, weight)
				if blend <= 0.0:
					continue
				var lc := PBTileBaker._sample_image_repeat((L["texture"] as Texture2D).get_image(), uv1.x, uv1.y) * (L["color"] as Color)
				var a: float = blend * lc.a
				c = Color(c.r + (lc.r - c.r) * a, c.g + (lc.g - c.g) * a, c.b + (lc.b - c.b) * a, c.a)
			var dimg: Image = state["decal_layer_image"]
			var win: Rect2 = state["decal_window"]
			if dimg != null:
				var du := (mu - win.position.x) / win.size.x
				var dv := (mv - win.position.y) / win.size.y
				if du >= 0.0 and du <= 1.0 and dv >= 0.0 and dv <= 1.0:
					var d := PBTileBaker._sample_image_clamp(dimg, du, dv)
					if d.a > 0.001:
						c = Color(c.r + (d.r - c.r) * d.a, c.g + (d.g - c.g) * d.a, c.b + (d.b - c.b) * d.a, maxf(c.a, d.a))
			c.a = maxf(c.a, base_alpha)
			out.set_pixel(x, y, c)
	return out

func test_raw_byte_bake_matches_the_per_pixel_oracle_byte_for_byte() -> void:
	var data: PBMeshData = PBShapeGenerators.create_plane(1.0, 1.0, 1, 1)
	PBUv.refresh_mesh_uvs(data, true)
	var face := data.faces[0]
	var base := StandardMaterial3D.new()
	var base_img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	for y in range(16):
		for x in range(16):
			base_img.set_pixel(x, y, Color(float(x) / 15.0, float(y) / 15.0, 0.3, 1.0))
	base.albedo_texture = ImageTexture.create_from_image(base_img)
	base.albedo_color = Color(0.9, 0.95, 1.0, 1.0)
	var mat := PBSplat.create_splat_material(base)
	data.set_face_material(face, mat)
	PBSplat.ensure_face_splat_bounds(data, face)
	var l1_img := Image.create(8, 8, false, Image.FORMAT_RGB8)  # a non-RGBA8 layer texture
	l1_img.fill(Color(0.2, 0.8, 0.4))
	var l1 := PBSplat.add_layer(mat, ImageTexture.create_from_image(l1_img), Color(1, 1, 1, 0.9), 0.3, 256)
	var l2_img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	l2_img.fill(Color(0.9, 0.1, 0.1, 0.7))
	var l2 := PBSplat.add_layer(mat, ImageTexture.create_from_image(l2_img), Color.WHITE, 0.8, 256)
	PBSplat.paint_face_splat(data, face, mat, l1, Vector3(-0.2, 0, -0.1), 0.25, 0.7, 1.0, false, {})
	PBSplat.paint_face_splat(data, face, mat, l2, Vector3(0.25, 0, 0.2), 0.15, 0.0, 0.8, false, {})
	var stamp := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	stamp.fill(Color(0.1, 0.2, 0.9, 0.6))
	PBSplat.paste_decal(data, Vector3(0.0, 0, 0.3), Vector3.UP, 0.0, 0.2, 1.0, stamp)
	var fast := PBTileBaker.bake_face_composite(data, face, 2048)
	var oracle := _oracle_bake(data, face)
	assert_eq(fast.get_size(), oracle.get_size())
	assert_true(fast.get_data() == oracle.get_data(),
			"the raw-byte composite is byte-identical to the per-pixel one")

func test_bake_edge_width_follows_the_layer_roughness() -> void:
	# The bake dropped each layer's roughness and blended every edge at 0.8.
	var widths: Array = []
	for rough in [0.1, 0.9]:
		var data: PBMeshData = PBShapeGenerators.create_plane(1.0, 1.0, 1, 1)
		PBUv.refresh_mesh_uvs(data, true)
		var face := data.faces[0]
		var mat := PBSplat.create_splat_material()
		data.set_face_material(face, mat)
		PBSplat.ensure_face_splat_bounds(data, face)
		var white := Image.create(4, 4, false, Image.FORMAT_RGBA8)
		white.fill(Color.WHITE)
		var layer := PBSplat.add_layer(mat, ImageTexture.create_from_image(white), Color.WHITE, rough, 256)
		PBSplat.paint_face_splat(data, face, mat, layer, Vector3.ZERO, 0.3, 1.0, 1.0, false, {})
		var baked := PBTileBaker.bake_face_composite(data, face, 2048)
		var partial := 0
		var mid := baked.get_height() / 2
		for x in range(baked.get_width()):
			var r := baked.get_pixel(x, mid).r
			var base_r := baked.get_pixel(0, mid).r
			if absf(r - base_r) > 0.02 and r < 0.98:
				partial += 1
		widths.append(partial)
	assert_gt(int(widths[1]), int(widths[0]), "a rougher layer bakes a wider blend edge (%s)" % str(widths))
