## test_pb_splat_and_stamp.gd — Unit tests for Texture Splatting, Stamping, and UI integration.
@tool
extends GutTest

var _test_cube: PBMesh = null
var _test_splat_mat: ShaderMaterial = null

func before_each() -> void:
	_test_cube = PBMesh.create_cube(2.0)
	add_child_autofree(_test_cube)
	_test_splat_mat = PBSplat.create_splat_material()

func after_each() -> void:
	_test_cube = null
	_test_splat_mat = null

# ==============================================================================
# 1. Splat Shader & Material Creation Tests
# ==============================================================================

func test_splat_shader_compilation_and_material_creation() -> void:
	var shader := PBSplat.get_splat_shader()
	assert_not_null(shader, "Splat shader should load successfully")

	var mat := PBSplat.create_splat_material()
	assert_not_null(mat, "Splat material should be created")
	assert_true(PBSplat.is_splat_material(mat), "PBSplat.is_splat_material should identify splat materials")
	assert_false(PBSplat.is_splat_material(StandardMaterial3D.new()), "StandardMaterial3D is not a splat material")

func test_create_splat_material_inherits_base_properties() -> void:
	var base_mat := StandardMaterial3D.new()
	base_mat.albedo_color = Color(0.8, 0.4, 0.2, 1.0)
	base_mat.roughness = 0.45

	var splat_mat := PBSplat.create_splat_material(base_mat)
	assert_not_null(splat_mat)
	assert_eq(splat_mat.get_shader_parameter("base_color"), Color(0.8, 0.4, 0.2, 1.0))
	assert_almost_eq(float(splat_mat.get_shader_parameter("roughness")), 0.45, 0.001)

# ==============================================================================
# 2. Splat Layer Management Tests
# ==============================================================================

func test_layer_addition_removal_and_clearing() -> void:
	var mat := PBSplat.create_splat_material()
	assert_eq(PBSplat.get_layer_count(mat), 0, "Initial layer count should be 0")

	# Create dummy layer texture
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color.RED)
	var tex := ImageTexture.create_from_image(img)

	# Add layer 1
	var l1 := PBSplat.add_layer(mat, tex, Color.WHITE, 0.5)
	assert_eq(l1, 1, "First layer index should be 1")
	assert_eq(PBSplat.get_layer_count(mat), 1, "Layer count should be 1")
	assert_eq(PBSplat.get_layer_texture(mat, 1), tex)

	var mask_img := PBSplat.get_layer_mask_image(mat, 1)
	assert_not_null(mask_img, "Mask image should exist for active layer")
	assert_eq(mask_img.get_pixel(0, 0), Color(0, 0, 0, 1), "Initial mask should be black")

	# Modify mask and clear
	mask_img.set_pixel(0, 0, Color(1, 1, 1, 1))
	PBSplat.clear_layer(mat, 1)
	assert_eq(mask_img.get_pixel(0, 0), Color(0, 0, 0, 1), "Cleared mask should be black")

	# Remove layer
	PBSplat.remove_layer(mat, 1)
	assert_eq(PBSplat.get_layer_count(mat), 0, "Layer count after removal should be 0")

func test_layer_capacity_up_to_max_layers() -> void:
	var mat := PBSplat.create_splat_material()
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	var tex := ImageTexture.create_from_image(img)

	for i in range(1, PBSplat.MAX_LAYERS + 1):
		var slot := PBSplat.add_layer(mat, tex)
		assert_eq(slot, i, "Should allocate sequential slot %d" % i)

	assert_eq(PBSplat.get_layer_count(mat), PBSplat.MAX_LAYERS)
	# Attempt to add past max
	var overflow := PBSplat.add_layer(mat, tex)
	assert_eq(overflow, -1, "Adding past MAX_LAYERS should return -1")

# ==============================================================================
# 3. Splat mask coordinates (CUSTOM0) — never UV2
# ==============================================================================

func test_ensure_mesh_splat_uv_mapping() -> void:
	var data := _test_cube.pb_mesh_data
	assert_not_null(data)

	PBSplat.ensure_mesh_splat_uv(data)
	assert_eq(data.splat_uvs.size(), data.positions.size(), "splat_uvs should match vertex count")

	for i in range(data.splat_uvs.size()):
		var uv := data.splat_uvs[i]
		assert_true(uv.x >= -0.001 and uv.x <= 1.001, "splat u (%f) should be in [0, 1]" % uv.x)
		assert_true(uv.y >= -0.001 and uv.y <= 1.001, "splat v (%f) should be in [0, 1]" % uv.y)

func test_to_array_mesh_emits_splat_custom_attribute() -> void:
	var data := _test_cube.pb_mesh_data
	# Splat evidence (a splat material on any face) is what makes the build
	# regenerate and emit the mask attribute — same trigger as before.
	data.set_face_material(data.faces[0], PBSplat.create_splat_material())

	var arr_mesh := data.to_array_mesh()
	assert_not_null(arr_mesh)
	assert_true(arr_mesh.get_surface_count() > 0)
	assert_true((arr_mesh.surface_get_format(0) & Mesh.ARRAY_FORMAT_CUSTOM0) != 0,
			"splat masks must travel in the CUSTOM0 vertex attribute")

	var arrays := arr_mesh.surface_get_arrays(0)
	var custom: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
	assert_eq(custom.size(), data.splat_uvs.size() * 2, "RG_FLOAT custom attribute holds 2 floats per vertex")
	for i in range(data.splat_uvs.size()):
		assert_almost_eq(custom[i * 2], data.splat_uvs[i].x, 0.0001)
		assert_almost_eq(custom[i * 2 + 1], data.splat_uvs[i].y, 0.0001)
	assert_true((arr_mesh.surface_get_format(0) & Mesh.ARRAY_FORMAT_TEX_UV2) == 0,
			"a mesh with no authored UV2 must not get one from the splat system")

## The headline contract: live splat paint and an authored UV2 lightmap
## unwrap coexist on one mesh. Paint writes mask coordinates into CUSTOM0 and
## leaves UV2 alone, and the compiled surface carries BOTH channels.
func test_paint_coexists_with_authored_uv2_lightmap_unwrap() -> void:
	var cube := PBMesh.create_cube(2.0)
	add_child_autofree(cube)
	var data := cube.pb_mesh_data

	# Authored UV2: stands in for a LightmapGI unwrap (per-vertex island UVs)
	var authored := PackedVector2Array()
	authored.resize(data.positions.size())
	for i in range(authored.size()):
		authored[i] = Vector2(fposmod(0.31 * i, 1.0), fposmod(0.17 * i, 1.0))
	data.textures1 = authored
	data.lightmap_size_hint = Vector2i(128, 128)

	var ctrl := PBPaintController.new()
	ctrl.set_mode(PBPaintController.Mode.PAINT)
	ctrl.paint_texture = ImageTexture.create_from_image(_solid_image(Color.GREEN))
	ctrl.update_cursor(Vector3(0, 1.0, 0), Vector3.UP, cube, 4)
	ctrl.begin_stroke()
	ctrl.end_stroke()

	var am: ArrayMesh = data.to_array_mesh()
	var painted_surface := -1
	for s in range(am.get_surface_count()):
		if PBSplat.is_splat_material(am.surface_get_material(s)):
			painted_surface = s
			break
	assert_true(painted_surface >= 0, "the painted face must own a splat-material surface")
	if painted_surface < 0:
		return
	var fmt: int = am.surface_get_format(painted_surface)
	assert_true((fmt & Mesh.ARRAY_CUSTOM0) != 0, "painted surface must carry the splat mask attribute")
	assert_true((fmt & Mesh.ARRAY_TEX_UV2) != 0, "painted surface must keep its authored UV2 (lightmap)")
	assert_eq(am.lightmap_size_hint, Vector2i(128, 128), "lightmap size hint must reach the built mesh")

	# ... and the unwrap values are untouched by the paint
	for i in range(authored.size()):
		if data.textures1[i].distance_squared_to(authored[i]) > 0.000001:
			assert_true(false, "paint must never rewrite UV2 (vertex %d)" % i)
			return

func test_decal_layer_default_resolution_scales_with_face_size() -> void:
	# Uniform texel density: mask resolution must track the face's world size at
	# 256 texels/m (both for splat masks and for the decal layer), clamped.
	var small := PBMeshData.create_cube(1.0)
	var big := PBMeshData.create_cube(8.0)
	var small_res := PBSplat.calculate_uniform_face_resolution(small, small.faces[0])
	var big_res := PBSplat.calculate_uniform_face_resolution(big, big.faces[0])
	assert_true(big_res.x > small_res.x,
			"a larger face must get a larger mask (%d vs %d) so paint never looks blurrier" % [big_res.x, small_res.x])
	assert_eq(clampi(small_res.x, PBSplat.MIN_RESOLUTION, PBSplat.MAX_RESOLUTION), small_res.x,
			"mask resolution stays inside the documented clamp window")

## Byte-array equality without GUT formatting megabyte arrays into the report
## (mono aborts on the resulting string).
func _same_bytes(a: PackedByteArray, b: PackedByteArray) -> bool:
	return a == b

func _solid_image(col: Color) -> Image:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(col)
	return img

# ==============================================================================
# 4. Brush Painting Performance & Falloff Tests
# ==============================================================================

func test_brush_painting_hit_inside_and_outside_radius() -> void:
	var data := _test_cube.pb_mesh_data
	var face := data.faces[0] # top face or front face
	PBSplat.ensure_mesh_splat_uv(data)

	var mat := PBSplat.create_splat_material()
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	var tex := ImageTexture.create_from_image(img)
	var layer_idx := PBSplat.add_layer(mat, tex)

	var center_local := Vector3.ZERO
	var idxs := face.get_distinct_indexes()
	for idx in idxs:
		center_local += data.positions[idx]
	center_local /= float(idxs.size())

	# Paint with hard brush (softness 0.0) and radius 0.4m
	var painted := PBSplat.paint_face_splat(data, face, mat, layer_idx, center_local, 0.4, 0.0, 1.0, false)
	assert_true(painted, "paint_face_splat should return true on modification")

	var mask := PBSplat.get_layer_mask_image(mat, layer_idx)
	assert_not_null(mask)

	# Center pixel should have high alpha
	var center_pixel := mask.get_pixel(mask.get_width() / 2, mask.get_height() / 2)
	assert_almost_eq(center_pixel.r, 1.0, 0.05, "Center pixel should have alpha ~1.0")

	# Corner pixel (far outside radius 0.4m on a 2m cube) should remain 0.0
	var corner_pixel := mask.get_pixel(0, 0)
	assert_eq(corner_pixel.r, 0.0, "Far corner pixel should remain 0.0")

func test_brush_erase_mode_subtracts_alpha() -> void:
	var data := _test_cube.pb_mesh_data
	var face := data.faces[0]
	PBSplat.ensure_mesh_splat_uv(data)

	var mat := PBSplat.create_splat_material()
	var tex := ImageTexture.create_from_image(Image.create(8, 8, false, Image.FORMAT_RGBA8))
	var layer_idx := PBSplat.add_layer(mat, tex)
	var center_local := Vector3.ZERO
	var idxs := face.get_distinct_indexes()
	for idx in idxs:
		center_local += data.positions[idx]
	center_local /= float(idxs.size())
	# Paint 1.0
	PBSplat.paint_face_splat(data, face, mat, layer_idx, center_local, 0.5, 0.0, 1.0, false)
	var mask := PBSplat.get_layer_mask_image(mat, layer_idx)
	var mid := mask.get_width() / 2
	assert_almost_eq(mask.get_pixel(mid, mid).r, 1.0, 0.05)

	# Erase with 0.6 opacity
	PBSplat.paint_face_splat(data, face, mat, layer_idx, center_local, 0.5, 0.0, 0.6, true)
	assert_almost_eq(mask.get_pixel(mid, mid).r, 0.4, 0.05, "After erasing 0.6 from 1.0, alpha should be ~0.4")

func test_brush_painting_zero_lag_benchmark() -> void:
	var data := _test_cube.pb_mesh_data
	var face := data.faces[0]
	PBSplat.ensure_mesh_splat_uv(data)

	var mat := PBSplat.create_splat_material()
	var tex := ImageTexture.create_from_image(Image.create(8, 8, false, Image.FORMAT_RGBA8))
	var layer_idx := PBSplat.add_layer(mat, tex)
	var center_local := Vector3.ZERO
	var idxs := face.get_distinct_indexes()
	for idx in idxs:
		center_local += data.positions[idx]
	center_local /= float(idxs.size())
	var start_msec: int = Time.get_ticks_msec()
	for i in range(100):
		var offset := Vector3(sin(i * 0.1) * 0.1, 0, cos(i * 0.1) * 0.1)
		PBSplat.paint_face_splat(data, face, mat, layer_idx, center_local + offset, 0.3, 0.5, 0.2, false)
	var elapsed_msec := Time.get_ticks_msec() - start_msec

	# 100 strokes on a 512x512 uniform resolution face: the byte-buffer + LUT
	# inner loop runs ~6-8ms/dab worst-case (~600ms here); the pre-v0.9.50
	# Color get/set loop was ~12ms/dab (~1200ms — decisively fails this).
	assert_true(elapsed_msec < 1200, "100 brush stroke applications should take < 1200ms (took %d ms)" % elapsed_msec)

# ==============================================================================
# 5. Stamp Pasting Tests
# ==============================================================================

func test_paste_decal_paints_pixels_with_rotation_and_scale() -> void:
	var data: PBMeshData = PBShapeGenerators.create_plane(2.0, 2.0, 1, 1)
	PBUv.refresh_mesh_uvs(data, true)
	var face := data.faces[0]
	PBSplat.ensure_mesh_splat_uv(data)

	var stamp_img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	stamp_img.fill(Color(0.2, 0.6, 0.9, 1.0)) # Rich blue stamp

	var center_local := _face_center_local(data, face)
	var painted := PBSplat.paste_decal(data, center_local, Vector3.UP, 45.0, 1.0, 1.0, stamp_img)
	assert_eq(painted, 1, "The paste must land on the face under the cursor")

	var mat := data.get_face_material(face) as ShaderMaterial
	assert_true(PBSplat.has_decal_layer(mat), "A paste must create the decal layer")
	assert_eq(face.splat_bounds.size(), 4, "The paste must anchor the face's mask rect")

	var decal := PBSplat.get_decal_layer_image(mat)
	assert_not_null(decal)
	var mid := decal.get_width() / 2
	var px := decal.get_pixel(mid, mid)
	assert_almost_eq(px.b, 0.9, 0.05, "Decal pixel must keep the stamp's own color (1:1 copy)")
	assert_almost_eq(px.a, 1.0, 0.05, "Decal pixel must be opaque at the stamp center")

## Stamp opacity must reach the PAINTED pixels on every write path. The
## aligned fast path (rotation 0, axis-aligned face) and the oriented-sprite
## path (rotated) both used to composite at full source alpha — only the
## rarely-reached pixel-walk fallback respected the setting — so the dock's
## opacity spinner visibly did nothing while the preview obeyed it.
func test_stamp_opacity_applies_on_every_paste_path() -> void:
	for rot: float in [0.0, 45.0]:
		var data: PBMeshData = PBShapeGenerators.create_plane(2.0, 2.0, 1, 1)
		PBUv.refresh_mesh_uvs(data, true)
		var face := data.faces[0]
		PBSplat.ensure_mesh_splat_uv(data)
		var stamp := Image.create(16, 16, false, Image.FORMAT_RGBA8)
		stamp.fill(Color(1.0, 0.0, 0.0, 1.0))
		var painted := PBSplat.paste_decal(data, _face_center_local(data, face),
				Vector3.UP, rot, 1.0, 0.5, stamp)
		assert_eq(painted, 1, "Fixture: the stamp must land (rot=%.1f)" % rot)
		var mat := data.get_face_material(face) as ShaderMaterial
		var decal := PBSplat.get_decal_layer_image(mat)
		assert_not_null(decal, "A paste must create the decal layer (rot=%.1f)" % rot)
		var px := decal.get_pixel(decal.get_width() / 2, decal.get_height() / 2)
		assert_almost_eq(px.a, 0.5, 0.06,
				"Opacity 0.5 must halve the painted alpha (rot=%.1f, got %.2f)" % [rot, px.a])

## A wide stamp must LAND wide: the footprint follows the image's aspect ratio.
## (The old decal system pasted onto a square quad, so a 4:1 banner like the
## hello-world one came out horizontally squished.)
func test_wide_stamp_keeps_its_aspect_ratio() -> void:
	var data: PBMeshData = PBShapeGenerators.create_plane(4.0, 4.0, 1, 1)
	PBUv.refresh_mesh_uvs(data, true)
	var face := data.faces[0]
	var banner := Image.create(64, 16, false, Image.FORMAT_RGBA8)
	banner.fill(Color.WHITE)

	var painted := PBSplat.paste_decal(data, _face_center_local(data, face), Vector3.UP, 0.0, 2.0, 1.0, banner)
	assert_eq(painted, 1, "Fixture: the banner must land on the face")

	var mat := data.get_face_material(face) as ShaderMaterial
	var decal := PBSplat.get_decal_layer_image(mat)
	var min_x := decal.get_width()
	var max_x := -1
	var min_y := decal.get_height()
	var max_y := -1
	for y in range(decal.get_height()):
		for x in range(decal.get_width()):
			if decal.get_pixel(x, y).a > 0.5:
				min_x = mini(min_x, x)
				max_x = maxi(max_x, x)
				min_y = mini(min_y, y)
				max_y = maxi(max_y, y)
	assert_true(max_x > min_x and max_y > min_y, "The banner must have painted pixels")
	if max_x <= min_x or max_y <= min_y:
		return
	var ratio := float(max_x - min_x + 1) / float(max_y - min_y + 1)
	assert_almost_eq(ratio, 4.0, 0.15, "A 4:1 source must paint a 4:1 footprint (got %.2f)" % ratio)

func test_stamp_basis_upright_on_all_surfaces() -> void:
	for norm in [Vector3.RIGHT, Vector3.LEFT, Vector3.FORWARD, Vector3.BACK]:
		var basis := PBSplat.get_stamp_basis(norm)
		var v_up: Vector3 = basis["up"]
		var u_right: Vector3 = basis["right"]
		var n: Vector3 = basis["normal"]
		assert_almost_eq(v_up.x, 0.0, 0.001, "Wall up vector X should be 0")
		assert_almost_eq(v_up.y, 1.0, 0.001, "Wall up vector Y should point straight UP")
		assert_almost_eq(v_up.z, 0.0, 0.001, "Wall up vector Z should be 0")
		var det := u_right.cross(v_up).dot(n)
		assert_almost_eq(det, 1.0, 0.001, "Stamp basis determinant should be +1.0 (right-handed)")

	# Floor test
	var floor_basis := PBSplat.get_stamp_basis(Vector3.UP)
	assert_almost_eq(floor_basis["right"].x, 1.0, 0.001)
	assert_almost_eq(floor_basis["up"].z, -1.0, 0.001)

func test_paste_decal_handles_compressed_source_images() -> void:
	var data := _test_cube.pb_mesh_data
	var face := data.faces[4]
	PBSplat.ensure_mesh_splat_uv(data)

	var raw_img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	raw_img.fill(Color.WHITE)
	var center_local := _face_center_local(data, face)

	# A source with an alpha channel: the paste must read pixels without the
	# "Can't get_pixel() on compressed image" failure mode.
	var compressed := raw_img.duplicate()
	compressed.compress(Image.COMPRESS_ETC2, Image.COMPRESS_SOURCE_GENERIC)
	var painted := PBSplat.paste_decal(data, center_local, Vector3.UP, 0.0, 1.0, 1.0, compressed)
	assert_eq(painted, 1, "A compressed source must still paste")

	var mat := data.get_face_material(face) as ShaderMaterial
	var target_img := PBSplat.get_decal_layer_image(mat)
	assert_not_null(target_img)
	assert_gt(target_img.get_width(), 0, "Decal layer must exist after the paste")

func test_clone_splat_material_deep_copies_masks() -> void:
	var mat := PBSplat.create_splat_material()
	var tex := ImageTexture.create_from_image(Image.create(8, 8, false, Image.FORMAT_RGBA8))
	var layer_idx := PBSplat.add_layer(mat, tex)

	var mask_orig := PBSplat.get_layer_mask_image(mat, layer_idx)
	mask_orig.set_pixel(10, 10, Color(0.75, 0.75, 0.75, 1.0))

	var clone := PBSplat.clone_splat_material(mat)
	assert_not_null(clone)
	assert_true(PBSplat.is_splat_material(clone))
	assert_eq(PBSplat.get_layer_count(clone), 1)

	var mask_clone := PBSplat.get_layer_mask_image(clone, layer_idx)
	assert_almost_eq(mask_clone.get_pixel(10, 10).r, 0.75, 0.01)

	# Modifying clone should not mutate original
	mask_clone.set_pixel(10, 10, Color(0.1, 0.1, 0.1, 1.0))
	# Also test decal layer cloning (window rect included: a clone that lost
	# the mapping would draw the pixels across the whole face)
	var stamp_img := PBSplat.ensure_decal_window(mat, Rect2(0.2, 0.3, 0.1, 0.1), Vector2(2.0, 2.0))
	assert_not_null(stamp_img)
	stamp_img.set_pixel(20, 20, Color(0.3, 0.7, 0.1, 0.9))
	var clone2 := PBSplat.clone_splat_material(mat)
	assert_true(PBSplat.has_decal_layer(clone2))
	var clone2_stamp_img := PBSplat.get_decal_layer_image(clone2)
	assert_almost_eq(clone2_stamp_img.get_pixel(20, 20).r, 0.3, 0.01)
	assert_almost_eq(clone2_stamp_img.get_pixel(20, 20).a, 0.9, 0.01)
	assert_eq(PBSplat.get_decal_window(clone2), PBSplat.get_decal_window(mat),
			"The clone must keep the decal window mapping")
# ==============================================================================
# 7. Paint Controller Mode & Property Tests
# ==============================================================================

func test_paint_controller_modes_and_properties() -> void:
	var ctrl := PBPaintController.new()
	assert_eq(ctrl.mode, PBPaintController.Mode.NONE)
	assert_false(ctrl.is_active())

	ctrl.set_mode(PBPaintController.Mode.PAINT)
	assert_eq(ctrl.mode, PBPaintController.Mode.PAINT)
	assert_true(ctrl.is_active())

	ctrl.brush_radius = 1.2
	assert_almost_eq(ctrl.brush_radius, 1.2, 0.01)

	ctrl.brush_softness = 0.8
	assert_almost_eq(ctrl.brush_softness, 0.8, 0.01)

	ctrl.set_mode(PBPaintController.Mode.STAMP)
	assert_eq(ctrl.mode, PBPaintController.Mode.STAMP)
	assert_true(ctrl.is_active())

	ctrl.stamp_scale = 2.5
	assert_almost_eq(ctrl.stamp_scale, 2.5, 0.01)

	ctrl.stamp_rotation = 90.0
	assert_almost_eq(ctrl.stamp_rotation, 90.0, 0.01)

	ctrl.reset()
	assert_eq(ctrl.mode, PBPaintController.Mode.NONE)
	assert_false(ctrl.is_active())

func test_uniform_resolution_calculation() -> void:
	var cube_2m := PBMeshData.create_cube(2.0)
	var res_2m := PBSplat.calculate_uniform_face_resolution(cube_2m, cube_2m.faces[0])
	# 2m * 256 texels/m = 512 texels
	assert_eq(res_2m.x, 512, "2m face width should be 512 pixels")
	assert_eq(res_2m.y, 512, "2m face height should be 512 pixels")

	var cube_8m := PBMeshData.create_cube(8.0)
	var res_8m := PBSplat.calculate_uniform_face_resolution(cube_8m, cube_8m.faces[0])
	# 8m * 256 texels/m = 2048 texels
	assert_eq(res_8m.x, 2048, "8m face width should be 2048 pixels")
	assert_eq(res_8m.y, 2048, "8m face height should be 2048 pixels")

## The decal layer is a WINDOW cropped to the painted area, not a whole-face
## image: that is what keeps its texels/m uniform on a large face (a 32 m floor
## used to get a 2048 px layer = 64 texels/m, which read as a pixelated stamp).
func test_decal_window_crops_to_the_paint_and_keeps_density() -> void:
	var data := PBShapeGenerators.create_plane(32.0, 32.0, 1, 1)
	PBUv.refresh_mesh_uvs(data, true)
	var face := data.faces[0]
	var stamp := Image.create(64, 32, false, Image.FORMAT_RGBA8)
	stamp.fill(Color.WHITE)

	assert_eq(PBSplat.paste_decal(data, Vector3.ZERO, Vector3.UP, 0.0, 1.0, 1.0, stamp), 1,
			"Fixture: the stamp must land on the 32 m face")

	var mat := data.get_face_material(face) as ShaderMaterial
	var win := PBSplat.get_decal_window(mat)
	var img := PBSplat.get_decal_layer_image(mat)
	assert_true(win.size.x < 0.1 and win.size.y < 0.1,
			"The window must cover the ~1 m stamp, not the 32 m face (got %s)" % win)
	var density := float(img.get_width()) / maxf(win.size.x * 32.0, 0.001)
	assert_almost_eq(density, PBSplat.DECAL_TEXELS_PER_M, PBSplat.DECAL_TEXELS_PER_M * 0.05,
			"The window must hold 256 texels/m — the same density the splat masks use")
	assert_true(img.get_width() < 1024,
			"A 1 m stamp must not allocate a whole-face-sized layer (got %d px)" % img.get_width())

	# Paint far away: the window grows and the first stamp's pixels survive.
	var before := PBSplat.get_decal_layer_image(mat).get_data()
	assert_eq(PBSplat.paste_decal(data, Vector3(12.0, 0.0, 0.0), Vector3.UP, 0.0, 1.0, 1.0, stamp), 1,
			"Fixture: the second stamp must land")
	var grown := PBSplat.get_decal_window(mat)
	assert_true(grown.size.x > win.size.x, "The window must grow to hold paint at both spots")
	assert_true(grown.encloses(win), "Growing must keep the original window inside")
	var pixels := PBSplat.get_decal_layer_image(mat).get_data()
	assert_eq(pixels.size(), PBSplat.get_decal_layer_image(mat).get_width()
			* PBSplat.get_decal_layer_image(mat).get_height() * 4)
	assert_true(pixels.size() != before.size() or pixels != before,
			"The grown window must hold the new paint")

func test_stamp_mode_paints_the_decal_layer_without_scene_nodes() -> void:
	var cube := PBMesh.create_cube(2.0)
	add_child_autofree(cube)
	var ctrl := PBPaintController.new()
	ctrl.set_mode(PBPaintController.Mode.STAMP)
	var stamp_tex := ImageTexture.create_from_image(_solid_image(Color(0.9, 0.3, 0.2)))
	ctrl.stamp_texture = stamp_tex
	ctrl.stamp_scale = 1.0
	ctrl.update_cursor(Vector3(0, 1.0, 0.2), Vector3.UP, cube, 4)
	ctrl.apply_stamp()

	assert_null(cube.get_node_or_null("PBStamps"),
			"Stamps are pixels now — no decal nodes are created")
	var data := cube.pb_mesh_data
	var mat := data.get_face_material(data.faces[4]) as ShaderMaterial
	assert_true(PBSplat.is_splat_material(mat), "The stamped face must carry a splat material")
	assert_true(PBSplat.has_decal_layer(mat), "The stamp must land in the decal layer")
	var decal := PBSplat.get_decal_layer_image(mat)
	var mid := decal.get_width() / 2
	assert_almost_eq(decal.get_pixel(mid, mid).a, 1.0, 0.05, "Stamp pixels must be in the middle of the layer")

	# A second stamp at another spot composites into the SAME layer: the window
	# may grow to hold both, but the face must not end up with two layers, and
	# the first stamp's pixels must survive the growth.
	ctrl.update_cursor(Vector3(0.4, 1.0, 0.0), Vector3.UP, cube, 4)
	ctrl.apply_stamp()
	var decal_layers := 0
	for m in data.materials:
		if PBSplat.is_splat_material(m) and PBSplat.has_decal_layer(m as ShaderMaterial):
			decal_layers += 1
	assert_eq(decal_layers, 1, "Both stamps live in one per-face decal layer")
	for spot in [Vector3(0, 1.0, 0.2), Vector3(0.4, 1.0, 0.0)]:
		assert_gt(_decal_alpha_at(data, mat, face_under(data), spot), 0.5,
				"Stamp at %s must be painted after the window grew" % spot)

	# Clearing wipes the layer
	ctrl.clear_decal_layer(cube)
	assert_almost_eq(PBSplat.get_decal_layer_image(mat).get_pixel(mid, mid).a, 0.0, 0.01,
			"Clear Decal Layer must erase the painted pixels")

## The decal brush's own cost: a colour dab walks the LUT + byte buffer over
## the window's pixels only (a window is a fraction of a whole-face image on a
## large face, so this is the cheap path), and an image dab must hit the cached
## resampled source instead of re-copying it per dab.
func test_decal_brush_dab_cost_is_bounded() -> void:
	var data := PBShapeGenerators.create_plane(8.0, 8.0, 1, 1)
	PBUv.refresh_mesh_uvs(data, true)
	var face := data.faces[0]
	var centre := Vector3.ZERO
	var start := Time.get_ticks_msec()
	for i in range(100):
		var offset := Vector3(sin(i * 0.4) * 0.9, 0.0, cos(i * 0.4) * 0.9)
		PBSplat.paint_decal_dab(data, centre + offset, Vector3.UP, 0.0, 0.35, 0.5, 0.4,
				false, null, Color(0.2, 0.4, 0.8, 1.0))
	var colour_msec: int = Time.get_ticks_msec() - start
	assert_true(colour_msec < 1200,
			"100 colour dabs (0.35 m radius) should take < 1200ms (took %d ms)" % colour_msec)

	var src := Image.create(256, 128, false, Image.FORMAT_RGBA8)
	src.fill(Color(0.9, 0.5, 0.2, 1.0))
	start = Time.get_ticks_msec()
	for i in range(100):
		var offset := Vector3(sin(i * 0.4) * 0.9, 0.0, cos(i * 0.4) * 0.9)
		PBSplat.paint_decal_dab(data, centre + offset, Vector3.UP, 0.0, 0.35, 0.5, 0.4,
				false, src)
	var image_msec: int = Time.get_ticks_msec() - start
	assert_true(image_msec < 1200,
			"100 image dabs should take < 1200ms (took %d ms)" % image_msec)

## A stamp is ONE click, so its paste may not walk the footprint in GDScript
## when the stamp lines up with the face (the axis-aligned case: the sprite is a
## crop + resize in C++ and the paste is one blend). Measured 8-64 ms for 1-4.32
## m stamps; the pixel walk it replaced took 79-1221 ms.
func test_aligned_stamp_paste_is_a_single_click() -> void:
	var data := PBShapeGenerators.create_plane(12.0, 12.0, 1, 1)
	PBUv.refresh_mesh_uvs(data, true)
	var src := Image.create(256, 128, false, Image.FORMAT_RGBA8)
	src.fill(Color(0.9, 0.5, 0.2, 1.0))
	var start := Time.get_ticks_msec()
	assert_eq(PBSplat.paste_decal(data, Vector3.ZERO, Vector3.UP, 0.0, 4.32, 1.0, src), 1,
			"Fixture: the banner must land")
	var stamp_msec: int = Time.get_ticks_msec() - start
	assert_true(stamp_msec < 400,
			"a 4.32 m aligned stamp must land in one click (< 400 ms, took %d ms)" % stamp_msec)

## The reported "very pixelated" stamp: a source SMALLER than its footprint
## must be resampled smoothly. Nearest-neighbour (the old paste) duplicated
## source texels into hard blocks, which is what the pixelation was.
func test_paste_upsamples_the_source_smoothly() -> void:
	var data := PBShapeGenerators.create_plane(4.0, 4.0, 1, 1)
	PBUv.refresh_mesh_uvs(data, true)
	var face := data.faces[0]
	# A 2x1 source: one black texel, one white one. Painted 4 m wide it lands
	# on 1024 layer texels, so the transition must be a gradient, not a step.
	var src := Image.create(2, 1, false, Image.FORMAT_RGBA8)
	src.set_pixel(0, 0, Color.BLACK)
	src.set_pixel(1, 0, Color.WHITE)

	assert_eq(PBSplat.paste_decal(data, Vector3.ZERO, Vector3.UP, 0.0, 4.0, 1.0, src), 1,
			"Fixture: the two-texel source must land on the 4 m face")
	var mat := data.get_face_material(face) as ShaderMaterial
	var img := PBSplat.get_decal_layer_image(mat)
	var mid_y := img.get_height() / 2
	var distinct := {}
	for x in range(img.get_width()):
		var c := img.get_pixel(x, mid_y)
		if c.a > 0.5:
			distinct[snappedf(c.r, 0.01)] = true
	assert_gt(distinct.size(), 8,
			"An upscaled source must be interpolated (got %d distinct values)" % distinct.size())

## The reported "completely broken on the wall": a stamp on the floor used to
## project onto a perpendicular wall as a smear of the image's middle rows.
func test_stamp_does_not_smear_onto_perpendicular_faces() -> void:
	var data := PBShapeGenerators.create_plane(8.0, 8.0, 1, 1)
	var wall := PBShapeGenerators.create_plane(8.0, 3.0, 1, 1)
	# Stand the second plane up at the floor's +Z edge and merge both into one
	# mesh data (a floor meeting a wall, the exact reported scene).
	for i in range(wall.positions.size()):
		var p: Vector3 = wall.positions[i]
		wall.positions[i] = Vector3(p.x, p.z + 1.5, 4.0)
	var floor_face_count := data.faces.size()
	var wall_offset := data.positions.size()
	for i in range(wall.positions.size()):
		data.positions.append(wall.positions[i])
	for f in wall.faces:
		var remapped := PackedInt32Array()
		for idx in f.get_indexes():
			remapped.append(idx + wall_offset)
		var nf := PBFace.new(remapped)
		nf.submesh_index = f.submesh_index
		data.faces.append(nf)
	PBUv.refresh_mesh_uvs(data, true)

	var stamp := Image.create(32, 16, false, Image.FORMAT_RGBA8)
	stamp.fill(Color.WHITE)
	# 1 m from the wall: the footprint's circumscribed box overlaps it.
	assert_eq(PBSplat.paste_decal(data, Vector3(0.0, 0.0, 3.0), Vector3.UP, 0.0, 2.0, 1.0, stamp), 1,
			"Fixture: the stamp must land on the floor only")
	var wall_faces := 0
	for fi in range(floor_face_count, data.faces.size()):
		var mat := data.get_face_material(data.faces[fi])
		if PBSplat.is_splat_material(mat) and PBSplat.has_decal_layer(mat as ShaderMaterial):
			wall_faces += 1
	assert_eq(wall_faces, 0, "A floor stamp must not bleed onto a perpendicular wall")

## A decal write happens in the mesh's LOCAL space, but the pick ray hands the
## brush a WORLD normal. Mixing the two (the controller used to) puts the decal
## basis outside the face's plane: on a rotated node every stamp smeared into a
## band. This drives the real controller path on a rotated mesh.
func test_stamp_on_a_rotated_mesh_keeps_the_source_aspect() -> void:
	var cube := PBMesh.create_cube(2.0)
	add_child_autofree(cube)
	cube.rotation = Vector3(PI * 0.5, 0.0, 0.35)
	var ctrl := PBPaintController.new()
	ctrl.set_mode(PBPaintController.Mode.STAMP)
	var src := Image.create(64, 16, false, Image.FORMAT_RGBA8)
	src.fill(Color.WHITE)
	ctrl.stamp_texture = ImageTexture.create_from_image(src)
	# 1.5 m wide: the 4:1 source gives a 0.375 m tall footprint.
	ctrl.stamp_scale = 1.5

	var data := cube.pb_mesh_data
	var face: PBFace = data.faces[4]
	var local_centre := _face_center_local(data, face)
	var world_hit: Vector3 = cube.global_transform * local_centre
	var world_normal: Vector3 = (cube.global_transform.basis * Vector3.UP).normalized()
	ctrl.update_cursor(world_hit, world_normal, cube, 4)
	ctrl.apply_stamp()

	var mat := data.get_face_material(face) as ShaderMaterial
	assert_true(PBSplat.is_splat_material(mat) and PBSplat.has_decal_layer(mat),
			"Fixture: the stamp must land on the rotated mesh's top face")
	if mat == null or not PBSplat.has_decal_layer(mat):
		return
	var img := PBSplat.get_decal_layer_image(mat)
	var min_x := img.get_width()
	var max_x := -1
	var min_y := img.get_height()
	var max_y := -1
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			if img.get_pixel(x, y).a > 0.5:
				min_x = mini(min_x, x)
				max_x = maxi(max_x, x)
				min_y = mini(min_y, y)
				max_y = maxi(max_y, y)
	assert_true(max_x > min_x and max_y > min_y, "The stamp must paint a 2D footprint")
	var ratio := float(max_x - min_x + 1) / float(max_y - min_y + 1)
	assert_almost_eq(ratio, 4.0, 0.3,
			"A 4:1 source must stay 4:1 on a rotated mesh (got %.2f)" % ratio)

## A stamp whose axes do not line up with the face's — a rotated stamp, or a
## face whose planar basis differs (a tilted ramp) — used to be sized by its
## UNROTATED extents, so the content was clipped inside the sprite and read as a
## horizontally squashed stamp.
func test_rotated_stamp_keeps_its_footprint() -> void:
	var data := PBShapeGenerators.create_plane(8.0, 8.0, 1, 1)
	PBUv.refresh_mesh_uvs(data, true)
	var src := Image.create(64, 32, false, Image.FORMAT_RGBA8)
	src.fill(Color.WHITE)  # an opaque 2:1 plate, so the painted bbox IS the stamp

	assert_eq(PBSplat.paste_decal(data, Vector3.ZERO, Vector3.UP, 90.0, 2.0, 1.0, src), 1,
			"Fixture: the rotated stamp must land")
	var mat := data.get_face_material(data.faces[0]) as ShaderMaterial
	var img := PBSplat.get_decal_layer_image(mat)
	var win := PBSplat.get_decal_window(mat)
	var bounds := PBSplat.get_face_planar_bounds(data, data.faces[0])
	var bytes := img.get_data()
	var w := img.get_width()
	var h := img.get_height()
	var min_x := w
	var max_x := -1
	var min_y := h
	var max_y := -1
	for y in range(h):
		for x in range(w):
			if bytes[(y * w + x) * 4 + 3] > 25:
				min_x = mini(min_x, x)
				max_x = maxi(max_x, x)
				min_y = mini(min_y, y)
				max_y = maxi(max_y, y)
	var m_u: float = float(max_x - min_x + 1) * win.size.x * bounds["range_u"] / float(w - 1)
	var m_v: float = float(max_y - min_y + 1) * win.size.y * bounds["range_v"] / float(h - 1)
	# A 2:1 stamp turned 90 degrees is 1 m wide and 2 m tall.
	assert_almost_eq(m_u, 1.0, 0.12, "A 90-degree 2x1 m stamp must be 1 m wide (got %.2f)" % m_u)
	assert_almost_eq(m_v, 2.0, 0.12, "A 90-degree 2x1 m stamp must be 2 m tall (got %.2f)" % m_v)

## The basic brush: a solid colour dab, no palette image involved.
func test_colour_brush_paints_and_erases_decal_pixels() -> void:
	var data := PBShapeGenerators.create_plane(4.0, 4.0, 1, 1)
	PBUv.refresh_mesh_uvs(data, true)
	var face := data.faces[0]
	var hit := Vector3(0.5, 0.0, 0.5)
	assert_gt(PBSplat.paint_decal_dab(data, hit, Vector3.UP, 0.0, 0.5, 0.0, 1.0,
			false, null, Color(0.1, 0.8, 0.2, 1.0)), 0,
			"A colour dab must paint without any source image")
	var mat := data.get_face_material(face) as ShaderMaterial
	var alpha := _decal_alpha_at(data, mat, face, hit)
	assert_almost_eq(alpha, 1.0, 0.02, "The dab must be opaque at its centre")
	var bounds := PBSplat.get_face_planar_bounds(data, face)
	var mask_uv := Vector2(
		((bounds["u"] as Vector3).dot(hit) - bounds["min_u"]) / bounds["range_u"],
		((bounds["v"] as Vector3).dot(hit) - bounds["min_v"]) / bounds["range_v"])
	var duv := PBSplat.decal_uv_from_mask_uv(mat, mask_uv)
	var img := PBSplat.get_decal_layer_image(mat)
	var px := clampi(int(duv.x * img.get_width()), 0, img.get_width() - 1)
	var py := clampi(int(duv.y * img.get_height()), 0, img.get_height() - 1)
	var col := img.get_pixel(px, py)
	assert_almost_eq(col.g, 0.8, 0.05, "The dab must carry the brush colour")

	assert_gt(PBSplat.paint_decal_dab(data, hit, Vector3.UP, 0.0, 0.5, 0.0, 1.0,
			true, null, Color(0, 0, 0, 0)), 0,
			"An erase dab needs no source at all")
	assert_almost_eq(_decal_alpha_at(data, mat, face, hit), 0.0, 0.02,
			"Erase must fade the painted pixels back out")

## A window that grows must carry the earlier paint with it, texel for texel.
func test_decal_window_growth_preserves_existing_pixels() -> void:
	var data := PBShapeGenerators.create_plane(16.0, 16.0, 1, 1)
	PBUv.refresh_mesh_uvs(data, true)
	var face := data.faces[0]
	var stamp := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	stamp.fill(Color(0.2, 0.4, 0.9, 1.0))
	var first_hit := Vector3(-4.0, 0.0, -4.0)
	PBSplat.paste_decal(data, first_hit, Vector3.UP, 0.0, 1.0, 1.0, stamp)
	var mat := data.get_face_material(face) as ShaderMaterial
	var before_col := _decal_colour_at(data, mat, face, first_hit)
	PBSplat.paste_decal(data, Vector3(5.0, 0.0, 5.0), Vector3.UP, 0.0, 1.0, 1.0, stamp)
	var after_col := _decal_colour_at(data, mat, face, first_hit)
	assert_almost_eq(after_col.b, before_col.b, 0.02,
			"The first stamp must survive the window growing for the second")
	assert_almost_eq(after_col.a, before_col.a, 0.02,
			"The first stamp must stay opaque after the window grows")

## Decal alpha at a point on a face, sampled the way the shader does (face
## planar rect -> mask uv -> decal window uv).
func _decal_alpha_at(data: PBMeshData, mat: ShaderMaterial, face: PBFace, p_local: Vector3) -> float:
	var bounds := PBSplat.get_face_planar_bounds(data, face)
	if bounds.is_empty():
		return -1.0
	var mask_uv := Vector2(
		((bounds["u"] as Vector3).dot(p_local) - bounds["min_u"]) / bounds["range_u"],
		((bounds["v"] as Vector3).dot(p_local) - bounds["min_v"]) / bounds["range_v"])
	var duv := PBSplat.decal_uv_from_mask_uv(mat, mask_uv)
	if duv.x < 0.0 or duv.x > 1.0 or duv.y < 0.0 or duv.y > 1.0:
		return -1.0
	var img := PBSplat.get_decal_layer_image(mat)
	var px := clampi(int(duv.x * img.get_width()), 0, img.get_width() - 1)
	var py := clampi(int(duv.y * img.get_height()), 0, img.get_height() - 1)
	return img.get_pixel(px, py).a

## Decal colour at a point on a face (the same mapping the shader uses).
func _decal_colour_at(data: PBMeshData, mat: ShaderMaterial, face: PBFace, p_local: Vector3) -> Color:
	var bounds := PBSplat.get_face_planar_bounds(data, face)
	if bounds.is_empty():
		return Color(0, 0, 0, -1)
	var mask_uv := Vector2(
		((bounds["u"] as Vector3).dot(p_local) - bounds["min_u"]) / bounds["range_u"],
		((bounds["v"] as Vector3).dot(p_local) - bounds["min_v"]) / bounds["range_v"])
	var duv := PBSplat.decal_uv_from_mask_uv(mat, mask_uv)
	if duv.x < 0.0 or duv.x > 1.0 or duv.y < 0.0 or duv.y > 1.0:
		return Color(0, 0, 0, -1)
	var img := PBSplat.get_decal_layer_image(mat)
	var px := clampi(int(duv.x * img.get_width()), 0, img.get_width() - 1)
	var py := clampi(int(duv.y * img.get_height()), 0, img.get_height() - 1)
	return img.get_pixel(px, py)

func face_under(data: PBMeshData) -> PBFace:
	return data.faces[4]

func test_material_dock_modes_and_sections() -> void:
	var dock := PBMaterialDock.new()
	add_child_autofree(dock)
	var ctrl := PBPaintController.new()
	dock.set_paint_controller(ctrl)

	assert_eq(dock.dock_mode, PBMaterialDock.DockMode.MATERIAL)

	# Switch to PAINT mode
	dock._set_dock_mode(PBMaterialDock.DockMode.PAINT)
	assert_eq(dock.dock_mode, PBMaterialDock.DockMode.PAINT)
	assert_eq(ctrl.mode, PBPaintController.Mode.PAINT)

	# Switch to STAMP mode
	dock._set_dock_mode(PBMaterialDock.DockMode.STAMP)
	assert_eq(dock.dock_mode, PBMaterialDock.DockMode.STAMP)
	assert_eq(ctrl.mode, PBPaintController.Mode.STAMP)

	# Switch back to MATERIAL mode
	dock._set_dock_mode(PBMaterialDock.DockMode.MATERIAL)
	assert_eq(dock.dock_mode, PBMaterialDock.DockMode.MATERIAL)
	assert_eq(ctrl.mode, PBPaintController.Mode.NONE)

func test_palette_collapse_is_order_independent() -> void:
	# A texture wrapper scanned BEFORE the saved material referencing the same
	# image must collapse into it — the user-visible duplicate was the default
	# material's checkerboard appearing twice (once as the .tres, once as the
	# bundled-scan wrapper).
	var dock := PBMaterialDock.new()
	add_child_autofree(dock)

	var checker: Texture2D = load("res://addons/poibuilder/materials/textures/checkerboard_2x2.png")
	var wrapper := StandardMaterial3D.new()
	wrapper.set_meta("source_texture_path", "res://addons/poibuilder/materials/textures/checkerboard_2x2.png")
	wrapper.albedo_texture = checker
	var saved: Material = load("res://addons/poibuilder/materials/pb_default_material.tres")
	assert_not_null(saved)
	assert_not_null(checker)

	# Wrapper FIRST (the scan-vs-setting order the bug needed):
	dock._project_materials = [wrapper, saved]
	dock._collapse_duplicate_materials()
	assert_eq(dock._project_materials.size(), 1,
		"Wrapper + saved material of the same texture collapse to one entry")
	assert_eq(dock._project_materials[0].resource_path,
		"res://addons/poibuilder/materials/pb_default_material.tres",
		"The saved .tres wins over the wrapper")

	# And the saved-first order stays a single entry too:
	dock._project_materials = [saved, wrapper]
	dock._collapse_duplicate_materials()
	assert_eq(dock._project_materials.size(), 1,
		"Collapse works in the saved-first order as well")

	# Two saved materials never collapse against each other:
	dock._project_materials = [saved, saved]
	dock._collapse_duplicate_materials()
	assert_eq(dock._project_materials.size(), 2,
		"Saved materials are never dropped by the collapse")

func test_placeholder_textures_discovered_in_materials() -> void:
	var dock := PBMaterialDock.new()
	add_child_autofree(dock)
	dock.refresh_materials()

	var has_pattern := false
	var has_tapestry := false

	for mat in dock._project_materials:
		if mat != null:
			var tex: Texture2D = dock._extract_texture(mat)
			if tex != null and not tex.resource_path.is_empty():
				if "circular_square_pattern" in tex.resource_path:
					has_pattern = true
				if "tapestry" in tex.resource_path:
					has_tapestry = true

	assert_true(has_pattern, "Palette should include circular_square_pattern texture")
	assert_true(has_tapestry, "Palette should include tapestry texture")

# ==============================================================================
# 9. Replace-Mode Paint Semantics, Erase-Once, Face-Anchored Stamps (v0.9.50)
# ==============================================================================

func _face_center_local(data: PBMeshData, face: PBFace) -> Vector3:
	var c := Vector3.ZERO
	var idxs := face.get_distinct_indexes()
	for idx in idxs:
		c += data.positions[idx]
	return c / float(idxs.size())

## A later stroke with LOWER opacity REPLACES a stronger earlier stroke
## (single-layer replace semantics), and repeated dabs of the same stroke do
## not accumulate beyond the stroke's own target.
func test_paint_lower_opacity_stroke_overwrites_stronger_one() -> void:
	var data := _test_cube.pb_mesh_data
	var face := data.faces[0]
	PBSplat.ensure_mesh_splat_uv(data)
	var mat := PBSplat.create_splat_material()
	var tex := ImageTexture.create_from_image(Image.create(8, 8, false, Image.FORMAT_RGBA8))
	var layer_idx := PBSplat.add_layer(mat, tex)
	var center := _face_center_local(data, face)

	# Stroke A: full opacity.
	var stroke_a := {}
	PBSplat.paint_face_splat(data, face, mat, layer_idx, center, 0.4, 0.0, 1.0, false, stroke_a)
	var mask := PBSplat.get_layer_mask_image(mat, layer_idx)
	var mid := mask.get_width() / 2
	assert_almost_eq(mask.get_pixel(mid, mid).r, 1.0, 0.05, "Full-opacity stroke paints to ~1.0")
	# Re-dabbing the same stroke must not change anything (idempotent, no buildup).
	PBSplat.paint_face_splat(data, face, mat, layer_idx, center, 0.4, 0.0, 1.0, false, stroke_a)
	assert_almost_eq(mask.get_pixel(mid, mid).r, 1.0, 0.05, "Same-stroke re-dab is idempotent")

	# Stroke B: NEW stroke at 0.3 opacity overwrites down to ~0.3.
	var stroke_b := {}
	PBSplat.paint_face_splat(data, face, mat, layer_idx, center, 0.4, 0.0, 0.3, false, stroke_b)
	assert_almost_eq(mask.get_pixel(mid, mid).r, 0.3, 0.05, "Lower-opacity stroke overwrites the stronger one")


## Soft brush over higher-opacity filled area erases towards brush opacity without empty halo.
func test_paint_soft_brush_over_filled_area_has_no_halo_and_erases_towards_opacity() -> void:
	var data := _test_cube.pb_mesh_data
	var face := data.faces[0]
	PBSplat.ensure_mesh_splat_uv(data)
	var mat := PBSplat.create_splat_material()
	var tex := ImageTexture.create_from_image(Image.create(8, 8, false, Image.FORMAT_RGBA8))
	var layer_idx := PBSplat.add_layer(mat, tex)
	var center := _face_center_local(data, face)

	# 1. Fill area with 1.0 opacity
	PBSplat.paint_face_splat(data, face, mat, layer_idx, center, 0.8, 0.0, 1.0, false, {})
	var mask := PBSplat.get_layer_mask_image(mat, layer_idx)
	var mid_x := mask.get_width() / 2
	var mid_y := mask.get_height() / 2
	assert_almost_eq(mask.get_pixel(mid_x, mid_y).r, 1.0, 0.05, "Canvas is initially filled with 1.0")

	# 2. Paint over center with smaller soft brush (radius 0.3m, softness 0.6) at lower opacity 0.4
	var stroke := {}
	PBSplat.paint_face_splat(data, face, mat, layer_idx, center, 0.3, 0.6, 0.4, false, stroke)

	# Center of brush is overwritten to lower opacity (~0.4)
	var center_val: float = mask.get_pixel(mid_x, mid_y).r
	assert_almost_eq(center_val, 0.4, 0.05, "Center is overwritten to lower opacity 0.4")

	# Outside the brush radius (e.g. at 0.5m, pixel offset ~120px): still filled at 1.0 (NO HALO!)
	var edge_offset := int(float(mask.get_width()) * (0.5 / 2.0))
	var outside_val: float = mask.get_pixel(mid_x + edge_offset, mid_y).r
	assert_almost_eq(outside_val, 1.0, 0.05, "Outside brush radius remains 1.0 with no empty halo")

	# At the brush fringe: pixel is between 0.4 and 1.0, never 0.0
	var fringe_offset := int(float(mask.get_width()) * (0.25 / 2.0))
	var fringe_val: float = mask.get_pixel(mid_x + fringe_offset, mid_y).r
	assert_true(fringe_val >= 0.4 and fringe_val <= 1.0, "Fringe smoothly transitions between 0.4 and 1.0")
	assert_true(fringe_val > 0.4, "Fringe is greater than center opacity")
## Within one stroke, the pixel keeps the stroke's MAX target (fringe-then-
## center dabbing paints the bright center, not the dim fringe).
func test_paint_within_stroke_keeps_max() -> void:
	var data := _test_cube.pb_mesh_data
	var face := data.faces[0]
	PBSplat.ensure_mesh_splat_uv(data)
	var mat := PBSplat.create_splat_material()
	var tex := ImageTexture.create_from_image(Image.create(8, 8, false, Image.FORMAT_RGBA8))
	var layer_idx := PBSplat.add_layer(mat, tex)
	var center := _face_center_local(data, face)

	# One stroke, dabs at increasing weight order (fringe weight 0.3 first via
	# low opacity? no — same opacity, different weight: simulate by softness=0
	# where weight is 1 everywhere; instead assert same-stroke monotonicity via
	# two dabs of the SAME stroke with the stronger dab second).
	var stroke := {}
	PBSplat.paint_face_splat(data, face, mat, layer_idx, center, 0.4, 0.5, 0.5, false, stroke)
	var mask := PBSplat.get_layer_mask_image(mat, layer_idx)
	var mid := mask.get_width() / 2
	var after_first: float = mask.get_pixel(mid, mid).r
	# Stronger second dab of the SAME stroke raises the pixel.
	PBSplat.paint_face_splat(data, face, mat, layer_idx, center, 0.4, 0.0, 0.9, false, stroke)
	var after_second: float = mask.get_pixel(mid, mid).r
	assert_true(after_second > after_first, "Within-stroke dab may raise the pixel (max semantics)")
	# A weaker dab of the SAME stroke must NOT dim it back down.
	PBSplat.paint_face_splat(data, face, mat, layer_idx, center, 0.4, 0.0, 0.1, false, stroke)
	assert_almost_eq(mask.get_pixel(mid, mid).r, after_second, 0.02, "Within-stroke weak dab does not dim the stroke's max")

## The eraser applies its opacity exactly ONCE per pixel per stroke: slow
## re-tracing within one stroke cannot drain the pixel further, but a NEW
## stroke erases another step.
func test_erase_applies_opacity_once_per_stroke() -> void:
	var data := _test_cube.pb_mesh_data
	var face := data.faces[0]
	PBSplat.ensure_mesh_splat_uv(data)
	var mat := PBSplat.create_splat_material()
	var tex := ImageTexture.create_from_image(Image.create(8, 8, false, Image.FORMAT_RGBA8))
	var layer_idx := PBSplat.add_layer(mat, tex)
	var center := _face_center_local(data, face)

	PBSplat.paint_face_splat(data, face, mat, layer_idx, center, 0.4, 0.0, 1.0, false, {})
	var mask := PBSplat.get_layer_mask_image(mat, layer_idx)
	var mid := mask.get_width() / 2
	assert_almost_eq(mask.get_pixel(mid, mid).r, 1.0, 0.05)

	var erase_stroke := {}
	for i in range(5):
		PBSplat.paint_face_splat(data, face, mat, layer_idx, center, 0.4, 0.0, 0.25, true, erase_stroke)
	assert_almost_eq(mask.get_pixel(mid, mid).r, 0.75, 0.05,
		"0.25-opacity erase applied 5x within ONE stroke subtracts exactly once")

	PBSplat.paint_face_splat(data, face, mat, layer_idx, center, 0.4, 0.0, 0.25, true, {})
	assert_almost_eq(mask.get_pixel(mid, mid).r, 0.5, 0.05,
		"A NEW stroke erases another 0.25 step")

## A stamp is projected onto EVERY face its oriented footprint touches: it can
## overhang an edge or wrap a corner, which a node-based decal could not do.
func test_stamp_wraps_across_faces() -> void:
	var data: PBMeshData = PBShapeGenerators.create_plane(4.0, 4.0, 2, 1)
	PBUv.refresh_mesh_uvs(data, true)
	assert_eq(data.faces.size(), 2, "Fixture: two coplanar faces sharing an edge")

	# Stamp centered on the shared edge (x = 0), 2 m across.
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 1.0, 1.0, 1.0))
	var painted := PBSplat.paste_decal(data, Vector3(0, 0, 0), Vector3.UP, 0.0, 2.0, 1.0, img)
	assert_eq(painted, 2, "A stamp straddling the edge must paint BOTH faces")

	for face in data.faces:
		var mat := data.get_face_material(face) as ShaderMaterial
		assert_true(PBSplat.has_decal_layer(mat), "Each touched face gets its own decal layer")
		assert_true(PBSplat.get_decal_layer_image(mat).get_width() > 0, "…with pixels in it")

## Resizing the face must NOT stretch or slide decal pixels: the layer maps to
## the object-space rect recorded at paste time, so pixels stay put and new
## geometry simply clips them.
func test_decal_does_not_stretch_or_slide_when_face_resized() -> void:
	var cube := PBMesh.create_cube(2.0)
	add_child_autofree(cube)
	var data := cube.pb_mesh_data
	var face := data.faces[4]
	var ctrl := PBPaintController.new()
	ctrl.set_mode(PBPaintController.Mode.STAMP)
	ctrl.stamp_texture = ImageTexture.create_from_image(_solid_image(Color(0.9, 0.4, 0.1)))
	ctrl.stamp_scale = 0.6
	ctrl.stamp_rotation = 0.0
	ctrl.update_cursor(Vector3(0, 1.0, 0), Vector3.UP, cube, 4)
	ctrl.apply_stamp()

	var mat := data.get_face_material(face) as ShaderMaterial
	var decal := PBSplat.get_decal_layer_image(mat)
	var mid := decal.get_width() / 2
	assert_almost_eq(decal.get_pixel(mid, mid).a, 1.0, 0.05, "Precondition: the stamp is in the middle")
	var bounds_before := face.splat_bounds.duplicate()

	# Stretch the face 3x along X.
	for idx in face.get_distinct_indexes():
		var p: Vector3 = data.positions[idx]
		data.positions[idx] = Vector3(p.x * 3.0, p.y, p.z)
	cube.rebuild()

	assert_eq(face.splat_bounds, bounds_before,
			"The painted rect must keep its anchor across a resize")
	assert_true(_same_bytes(PBSplat.get_decal_layer_image(mat).get_data(), decal.get_data()),
			"Decal pixels must be byte-identical after the resize (no resample, no stretch)")
	assert_almost_eq(PBSplat.get_decal_layer_image(mat).get_pixel(mid, mid).a, 1.0, 0.05,
			"…and the painted pixel is still where it was")
	var live_bounds := PBSplat.get_face_planar_bounds(data, face, true)
	assert_true(live_bounds["range_u"] > absf(bounds_before[1] - bounds_before[0]),
			"…while the geometry itself did grow (precondition for the clip case)")

## Resizing geometry does NOT stretch or slide painted texture layers (UV2 tracks object space).
func test_splat_texture_does_not_stretch_or_slide_when_face_resized() -> void:
	var cube := PBMesh.create_cube(2.0)
	add_child_autofree(cube)
	var data := cube.pb_mesh_data
	var face := data.faces[0] # front face, z = 1.0 or -1.0
	var mat := PBSplat.create_splat_material()
	var tex := ImageTexture.create_from_image(Image.create(8, 8, false, Image.FORMAT_RGBA8))
	var layer_idx := PBSplat.add_layer(mat, tex)
	data.set_face_material(face, mat)

	# Paint face to establish splat_bounds
	var center := _face_center_local(data, face)
	PBSplat.paint_face_splat(data, face, mat, layer_idx, center, 0.5, 0.0, 1.0, false)
	assert_eq(face.splat_bounds.size(), 4, "Splat bounds established on first paint")
	var orig_bounds := [face.splat_bounds[0], face.splat_bounds[1], face.splat_bounds[2], face.splat_bounds[3]]

	# Rebuild mesh and check initial mask coordinates
	cube.rebuild()
	var orig_uv := data.splat_uvs.duplicate()
	assert_eq(orig_uv.size(), data.positions.size())

	# Resize face: move right vertices +2m outward along u
	var bounds := PBSplat.get_face_planar_bounds(data, face)
	var u_axis: Vector3 = bounds["u"]
	for idx in face.get_distinct_indexes():
		var p: Vector3 = data.positions[idx]
		if u_axis.dot(p) > 0.0:
			data.positions[idx] = p + u_axis * 2.0
	cube.rebuild()

	# splat_bounds must NOT have stretched:
	assert_eq(face.splat_bounds[0], orig_bounds[0])
	assert_eq(face.splat_bounds[1], orig_bounds[1])
	assert_eq(face.splat_bounds[2], orig_bounds[2])
	assert_eq(face.splat_bounds[3], orig_bounds[3])

	# Mask coordinates at the unmoved vertices must be identical (no sliding):
	for idx in face.get_distinct_indexes():
		var p: Vector3 = data.positions[idx]
		if u_axis.dot(p) < 0.0:
			assert_almost_eq(data.splat_uvs[idx].x, orig_uv[idx].x, 0.001)
			assert_almost_eq(data.splat_uvs[idx].y, orig_uv[idx].y, 0.001)
		else:
			# Moved vertices land outside the original mask rect (u > 1): the
			# painted area keeps its object-space anchor, the new geometry
			# simply clips instead of stretching the paint.
			assert_true(data.splat_uvs[idx].x > 1.5, "Moved vertices map outside the painted rect, not rescaled to 1.0")

## Moving the object in Object Mode does not disturb decal pixels: the layer is
## stored in mesh-local space, so the stamp travels with the mesh.
func test_decal_pixels_are_mesh_local_under_object_moves() -> void:
	var cube := PBMesh.create_cube(2.0)
	add_child_autofree(cube)
	var ctrl := PBPaintController.new()
	ctrl.set_mode(PBPaintController.Mode.STAMP)
	ctrl.stamp_texture = ImageTexture.create_from_image(_solid_image(Color(0.2, 0.8, 0.4)))
	ctrl.stamp_scale = 1.0
	ctrl.update_cursor(Vector3(0, 1.0, 0), Vector3.UP, cube, 4)
	ctrl.apply_stamp()

	var mat := cube.pb_mesh_data.get_face_material(cube.pb_mesh_data.faces[4]) as ShaderMaterial
	var before := PBSplat.get_decal_layer_image(mat).get_data()

	cube.position = Vector3(10, 5, -3)
	assert_true(_same_bytes(PBSplat.get_decal_layer_image(mat).get_data(), before),
			"Object-mode moves must not touch decal pixels (mesh-local storage)")

## Legacy scenes carried stamps as decal quads under PBStamps. Loading one now
## re-pastes every recorded decal into the decal layer and drops the nodes.
func test_legacy_stamp_nodes_migrate_into_the_decal_layer() -> void:
	var cube := PBMesh.create_cube(2.0)
	add_child_autofree(cube)
	var container := Node3D.new()
	container.name = "PBStamps"
	cube.add_child(container)
	var quad := MeshInstance3D.new()
	quad.name = "Stamp_1"
	quad.mesh = QuadMesh.new()
	quad.transform = Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)), Vector3(0, 1.0, 0))
	quad.set_meta("anchor_center", Vector2(0.5, 0.5))
	quad.set_meta("anchor_du", Vector2(0.25, 0.0))
	quad.set_meta("anchor_dv", Vector2(0.0, 0.25))
	quad.set_meta("face_idx", 4)
	quad.set_meta("stamp_scale", 0.5)
	quad.set_meta("stamp_rotation", 0.0)
	quad.set_meta("stamp_opacity", 1.0)
	var tex_img := _solid_image(Color(0.9, 0.1, 0.6))
	var tex := ImageTexture.create_from_image(tex_img)
	var path := "user://pb_test_legacy_stamp.png"
	tex_img.save_png(path)
	quad.set_meta("stamp_texture_path", ProjectSettings.globalize_path(path))
	container.add_child(quad)

	var migrated := PBSplat.migrate_legacy_stamps(cube)
	assert_eq(migrated, 1, "The recorded decal must be re-pasted")
	await get_tree().process_frame

	var data := cube.pb_mesh_data
	var mat := data.get_face_material(data.faces[4]) as ShaderMaterial
	assert_true(PBSplat.is_splat_material(mat), "Migration must give the face a splat material")
	assert_true(PBSplat.has_decal_layer(mat), "Migration must write into the decal layer")
	var decal := PBSplat.get_decal_layer_image(mat)
	var mid := decal.get_width() / 2
	assert_almost_eq(decal.get_pixel(mid, mid).a, 1.0, 0.05, "The migrated decal must have pixels")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

## The export-facing face paint state collector returns base material + layers
## + normalized planar bounds for a painted face, and {} for an unpainted one.
func test_collect_face_paint_state_exports_layers_and_bounds() -> void:
	var data := _test_cube.pb_mesh_data
	var face := data.faces[0]
	PBSplat.ensure_mesh_splat_uv(data)

	# Unpainted face: stock material -> no paint state.
	assert_true(PBSplat.collect_face_paint_state(data, face).is_empty(),
		"Unpainted face exports no paint state")

	# Paint one layer.
	var mat := PBSplat.create_splat_material()
	var layer_tex := ImageTexture.create_from_image(Image.create(8, 8, false, Image.FORMAT_RGBA8))
	var layer_idx := PBSplat.add_layer(mat, layer_tex)
	data.set_face_material(face, mat)
	var center := _face_center_local(data, face)
	PBSplat.paint_face_splat(data, face, mat, layer_idx, center, 0.4, 0.5, 0.6, false, {})

	var state := PBSplat.collect_face_paint_state(data, face)
	assert_false(state.is_empty(), "Painted face exports paint state")
	assert_eq((state["layers"] as Array).size(), 1, "One enabled layer exported")
	var layer0: Dictionary = (state["layers"] as Array)[0]
	assert_eq(layer0["slot"], layer_idx)
	assert_not_null(layer0["mask_image"], "Layer mask image must be exported for baking")
	var bounds: Dictionary = state["planar_bounds"]
	assert_true(bounds.has("u") and bounds.has("v") and bounds.has("range_u"),
		"Planar bounds must be exported (normalized mapping for baking)")
	assert_true(bounds["range_u"] > 0.0 and bounds["range_v"] > 0.0)

## Erasing is a brush operation now: painting into the decal layer with Erase
## fades the pixels instead of deleting a node.
func test_decal_brush_erases_parts_of_a_stamp() -> void:
	var cube := PBMesh.create_cube(2.0)
	add_child_autofree(cube)
	var ctrl := PBPaintController.new()
	ctrl.set_mode(PBPaintController.Mode.STAMP)
	ctrl.stamp_texture = ImageTexture.create_from_image(_solid_image(Color.WHITE))
	ctrl.stamp_scale = 1.6
	ctrl.update_cursor(Vector3(0, 1.0, 0), Vector3.UP, cube, 4)
	ctrl.apply_stamp()

	var data := cube.pb_mesh_data
	var mat := data.get_face_material(data.faces[4]) as ShaderMaterial
	var decal := PBSplat.get_decal_layer_image(mat)
	var mid := decal.get_width() / 2
	assert_almost_eq(decal.get_pixel(mid, mid).a, 1.0, 0.05, "Precondition: opaque stamp center")

	# Erase the middle of it with the decal brush.
	ctrl.set_mode(PBPaintController.Mode.PAINT)
	ctrl.paint_target = PBPaintController.PaintTarget.DECAL
	ctrl.paint_texture = ImageTexture.create_from_image(_solid_image(Color.WHITE))
	ctrl.brush_radius = 0.25
	ctrl.brush_softness = 0.0
	ctrl.brush_opacity = 1.0
	ctrl.erase_mode = true
	ctrl.update_cursor(Vector3(0, 1.0, 0), Vector3.UP, cube, 4)
	ctrl.begin_stroke()
	ctrl.end_stroke()

	assert_almost_eq(PBSplat.get_decal_layer_image(mat).get_pixel(mid, mid).a, 0.0, 0.05,
			"Erasing must fade the decal pixels away")

func test_cross_object_paint_stroke_multi_mesh_undo() -> void:
	var floor_mesh := PBMesh.create_cube(20.0)
	floor_mesh.name = "Floor"
	add_child_autofree(floor_mesh)

	var cube_mesh := PBMesh.create_cube(2.0)
	cube_mesh.name = "Cube"
	cube_mesh.position = Vector3(0, 11, 0)
	add_child_autofree(cube_mesh)

	var controller := PBPaintController.new()
	controller.set_mode(PBPaintController.Mode.PAINT)
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color.GREEN)
	controller.paint_texture = ImageTexture.create_from_image(img)

	# 1. Begin stroke on Floor
	controller.update_cursor(Vector3(0, 10, 0), Vector3.UP, floor_mesh, 1)
	controller.begin_stroke()
	assert_true(controller.is_stroke_active)
	assert_true(controller._stroke_meshes.has(floor_mesh), "Floor must be registered in stroke meshes")

	# 2. Cross over to Cube in the same stroke
	controller.update_cursor(Vector3(0, 12, 0), Vector3.UP, cube_mesh, 1)
	controller.apply_paint_stroke()
	assert_true(controller._stroke_meshes.has(cube_mesh), "Cube must be registered in stroke meshes")

	# Pre-stroke geometric extents
	var floor_pos_before := floor_mesh.pb_mesh_data.positions[0]
	var cube_pos_before := cube_mesh.pb_mesh_data.positions[0]
	assert_almost_eq(absf(floor_pos_before.x), 10.0, 0.001, "Floor corner is at 10m")
	assert_almost_eq(absf(cube_pos_before.x), 1.0, 0.001, "Cube corner is at 1m")

	# Record before snapshots captured by controller
	var floor_before_snap: PBMeshData = controller._stroke_meshes[floor_mesh]["before"]
	var cube_before_snap: PBMeshData = controller._stroke_meshes[cube_mesh]["before"]

	# End stroke
	controller.end_stroke()
	assert_false(controller.is_stroke_active)

	# Simulate undo by restoring each mesh's captured before snapshot
	PBCommand.restore_mesh_data(floor_mesh.pb_mesh_data, floor_before_snap)
	PBCommand.restore_mesh_data(cube_mesh.pb_mesh_data, cube_before_snap)

	# Verify: neither mesh got the other's geometry (no "floor comes up" or cube becoming floor)
	assert_almost_eq(absf(floor_mesh.pb_mesh_data.positions[0].x), 10.0, 0.001, "Floor retained its 10m extent")
	assert_almost_eq(absf(cube_mesh.pb_mesh_data.positions[0].x), 1.0, 0.001, "Cube retained its 1m extent")

# ==============================================================================
# UV Editor Splat Preview (UV2 channel underlay)
# ==============================================================================

func test_build_preview_texture_null_for_non_splat_materials() -> void:
	assert_null(PBSplat.build_preview_texture(null), "Null material must yield no preview")
	assert_null(PBSplat.build_preview_texture(StandardMaterial3D.new()), "StandardMaterial3D must yield no preview")

func test_build_preview_texture_base_only_when_no_layers() -> void:
	var base_img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	base_img.fill(Color.RED)
	var base_mat := StandardMaterial3D.new()
	base_mat.albedo_texture = ImageTexture.create_from_image(base_img)
	var splat_mat := PBSplat.create_splat_material(base_mat)

	var preview := PBSplat.build_preview_texture(splat_mat)
	assert_not_null(preview, "Splat material must produce a preview even with no layers")
	assert_true(preview is ImageTexture, "Preview must be an ImageTexture")

	var px: Color = preview.get_image().get_pixel(128, 128)
	assert_almost_eq(px.r, 1.0, 0.02, "Base-only preview must show base texture red")
	assert_almost_eq(px.g, 0.0, 0.02, "Base-only preview must show base texture red")
	assert_almost_eq(px.b, 0.0, 0.02, "Base-only preview must show base texture red")

func test_build_preview_texture_composites_painted_layer() -> void:
	var cube_data := PBMeshData.create_cube(1.0)
	var top_face: PBFace = cube_data.faces[4] # top face (+Y)

	var base_img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	base_img.fill(Color.RED)
	var base_mat := StandardMaterial3D.new()
	base_mat.albedo_texture = ImageTexture.create_from_image(base_img)
	var splat_mat := PBSplat.create_splat_material(base_mat)

	var layer_img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	layer_img.fill(Color.GREEN)
	var slot := PBSplat.add_layer(splat_mat, ImageTexture.create_from_image(layer_img))

	# Paint the whole face white through the real brush engine (huge radius covers all)
	var version_before: int = PBSplat.mask_state_version
	var modified := PBSplat.paint_face_splat(cube_data, top_face, splat_mat, slot,
			Vector3(0, 0.5, 0), 10.0, 0.0, 1.0)
	assert_true(modified, "Paint must modify the layer mask")
	assert_gt(PBSplat.mask_state_version, version_before, "paint_face_splat must bump mask_state_version")

	var preview := PBSplat.build_preview_texture(splat_mat)
	assert_not_null(preview, "Painted splat material must produce a preview")
	var px: Color = preview.get_image().get_pixel(128, 128)
	assert_almost_eq(px.g, 1.0, 0.02, "Painted area must composite the layer texture green")
	assert_almost_eq(px.r, 0.0, 0.02, "Painted area must be fully replaced by the layer")

func test_mask_state_version_bumps_on_layer_management() -> void:
	var mat := PBSplat.create_splat_material()
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color.BLUE)
	var tex := ImageTexture.create_from_image(img)

	var v0: int = PBSplat.mask_state_version
	var slot := PBSplat.add_layer(mat, tex)
	assert_gt(PBSplat.mask_state_version, v0, "add_layer must bump mask_state_version")

	var v1: int = PBSplat.mask_state_version
	PBSplat.clear_layer(mat, slot)
	assert_gt(PBSplat.mask_state_version, v1, "clear_layer must bump mask_state_version")

	var v2: int = PBSplat.mask_state_version
	PBSplat.remove_layer(mat, slot)
	assert_gt(PBSplat.mask_state_version, v2, "remove_layer must bump mask_state_version")

func test_authored_uv2_survives_rebuild_without_splat_data() -> void:
	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)
	# Simulate an authored UV2 unwrap (e.g. prepared for LightmapGI) on a mesh
	# with no splat data anywhere — the rebuild pipeline must leave it alone.
	var authored := PackedVector2Array()
	authored.resize(cube.positions.size())
	for i in range(authored.size()):
		authored[i] = Vector2(fposmod(0.13 * i, 1.0), 0.75)
	cube.textures1 = authored

	cube.to_array_mesh()

	assert_eq(cube.textures1.size(), authored.size(), "Splat-free mesh must keep its UV2 array")
	for i in range(authored.size()):
		if cube.textures1[i].distance_squared_to(authored[i]) > 0.000001:
			assert_true(false, "Authored UV2 (lightmap unwrap) must survive rebuild without splat data")
			return

func test_splat_uvs_regenerate_without_touching_uv2() -> void:
	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)
	cube.faces[0].splat_bounds = PackedFloat32Array([0.0, 1.0, 0.0, 1.0])
	# Simulate an authored lightmap unwrap that must survive the rebuild.
	var authored := PackedVector2Array()
	authored.resize(cube.positions.size())
	for i in range(authored.size()):
		authored[i] = Vector2(fposmod(0.17 * i, 1.0), 0.4)
	cube.textures1 = authored
	var garbage := PackedVector2Array()
	garbage.resize(cube.positions.size())
	garbage.fill(Vector2(9.0, 9.0))
	cube.splat_uvs = garbage

	cube.to_array_mesh()

	assert_eq(cube.splat_uvs.size(), cube.positions.size(), "Splat meshes regenerate mask coordinates on rebuild")
	assert_ne(cube.splat_uvs[0], Vector2(9.0, 9.0), "Stale mask coordinates must be replaced by face-planar ones")
	for i in range(authored.size()):
		if cube.textures1[i].distance_squared_to(authored[i]) > 0.000001:
			assert_true(false, "Paint must never clobber an authored UV2 (lightmap unwrap)")
			return

func test_splat_material_assignment_triggers_splat_uv_generation() -> void:
	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)
	assert_true(cube.splat_uvs.is_empty(), "Precondition: no mask coordinates without splat data")
	cube.set_face_material(cube.faces[2], PBSplat.create_splat_material())
	cube.to_array_mesh()
	assert_eq(cube.splat_uvs.size(), cube.positions.size(), "Assigning a splat material must generate mask coordinates on rebuild")
	var uv: Vector2 = cube.splat_uvs[0]
	assert_true(uv.x >= 0.0 and uv.x <= 1.0 and uv.y >= 0.0 and uv.y <= 1.0,
			"Generated mask coordinates must be normalized face-planar ones")

# ==============================================================================
# Transparency guard: transparent geometry (billboards) is not paintable
# ==============================================================================

## The mesh the sprite placer places: a standing quad in a PBMesh whose
## material is the placer's alpha-scissor billboard material.
func _billboard_mesh() -> PBMesh:
	var mesh := PBMesh.new()
	var md := PBShapeGenerators.create_sprite(2.0, 1.0)
	var mat := PBSpritePlacer.create_billboard_material(
			ImageTexture.create_from_image(_solid_image(Color(1, 1, 1, 1))), false, true)
	md.materials = [mat]
	mesh.pb_mesh_data = md
	mesh.pb_mesh_data.shape_id = &"sprite"
	add_child_autofree(mesh)
	return mesh

func test_transparent_surfaces_report_why_they_are_unpaintable() -> void:
	var bb := _billboard_mesh()
	assert_eq(PBSplat.face_paint_block_reason(bb, 0), "billboard sprite",
			"A sprite face is refused as a billboard")

	# A transparent (non-billboard) material is refused too: the splat shader
	# has no alpha mode, so painting it would turn it opaque.
	var glass := PBMesh.create_cube(2.0)
	add_child_autofree(glass)
	var glass_mat := StandardMaterial3D.new()
	glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.pb_mesh_data.set_face_material(glass.pb_mesh_data.faces[4], glass_mat)
	assert_eq(PBSplat.face_paint_block_reason(glass, 4), "transparent material")

	# Opaque geometry stays paintable — the guard must not over-block.
	var solid := PBMesh.create_cube(2.0)
	add_child_autofree(solid)
	assert_eq(PBSplat.face_paint_block_reason(solid, 4), "",
			"An opaque face is paintable")
	# …and an already-splat-painted face is too (painting over your own paint).
	solid.pb_mesh_data.set_face_material(solid.pb_mesh_data.faces[4], PBSplat.create_splat_material())
	assert_eq(PBSplat.face_paint_block_reason(solid, 4), "")

## The end the user saw: painting a sprite replaced its material with a splat
## shader — the alpha-scissor flag lived on the material that was thrown away,
## so the sprite turned into an opaque rectangle. The tools refuse instead.
func test_paint_and_stamp_leave_a_billboard_untouched() -> void:
	var bb := _billboard_mesh()
	var face := bb.pb_mesh_data.faces[0]
	var before_mat := bb.pb_mesh_data.get_face_material(face)
	var ctrl := PBPaintController.new()
	ctrl.set_mode(PBPaintController.Mode.PAINT)
	ctrl.paint_target = PBPaintController.PaintTarget.DECAL
	ctrl.brush_radius = 0.5
	ctrl.update_cursor(Vector3(0, 0.5, 0), Vector3.FORWARD, bb, 0)
	assert_false(ctrl.paintable, "Hovering a billboard reports the refused state")
	assert_eq(ctrl.blocked_reason, "billboard sprite")
	ctrl.begin_stroke()
	assert_false(ctrl.is_stroke_active, "A refused face starts no stroke")
	ctrl.end_stroke()
	assert_eq(bb.pb_mesh_data.get_face_material(face), before_mat,
			"A decal stroke must leave the billboard's material alone")

	# The stamp path is the same contract.
	ctrl.set_mode(PBPaintController.Mode.STAMP)
	ctrl.stamp_texture = ImageTexture.create_from_image(_solid_image(Color(1, 0, 0, 1)))
	ctrl.stamp_scale = 1.0
	ctrl.update_cursor(Vector3(0, 0.5, 0), Vector3.FORWARD, bb, 0)
	ctrl.apply_stamp()
	assert_eq(bb.pb_mesh_data.get_face_material(face), before_mat,
			"A stamp must not overwrite a billboard's material")

	# …and so is a splat stroke.
	ctrl.set_mode(PBPaintController.Mode.PAINT)
	ctrl.paint_target = PBPaintController.PaintTarget.SPLAT
	ctrl.paint_texture = ImageTexture.create_from_image(_solid_image(Color(0, 0, 1, 1)))
	ctrl.update_cursor(Vector3(0, 0.5, 0), Vector3.FORWARD, bb, 0)
	ctrl.begin_stroke()
	ctrl.end_stroke()
	assert_eq(bb.pb_mesh_data.get_face_material(face), before_mat,
			"A splat stroke must not overwrite a billboard's material")
	for m in bb.pb_mesh_data.materials:
		assert_false(PBSplat.is_splat_material(m), "No splat material may appear on a billboard")

	# Positive control: the very same gesture DOES paint an opaque face.
	var cube := PBMesh.create_cube(2.0)
	add_child_autofree(cube)
	ctrl.paint_target = PBPaintController.PaintTarget.DECAL
	ctrl.brush_color = Color(0.1, 0.9, 0.2, 1.0)
	ctrl.brush_source = PBPaintController.BrushSource.COLOR
	ctrl.update_cursor(Vector3(0, 1.0, 0), Vector3.UP, cube, 4)
	assert_true(ctrl.paintable, "An opaque face is paintable")
	ctrl.begin_stroke()
	ctrl.end_stroke()
	assert_true(PBSplat.is_splat_material(cube.pb_mesh_data.get_face_material(cube.pb_mesh_data.faces[4])),
			"An opaque face still converts to a splat material when painted")

# ==============================================================================
# Stamp preview: the quad follows the SELECTED image, not the previous one
# ==============================================================================

func test_stamp_preview_quad_follows_a_texture_switch() -> void:
	var host := Node3D.new()
	add_child_autofree(host)
	var ctrl := PBPaintController.new()
	ctrl.setup_previews(host)
	ctrl.set_mode(PBPaintController.Mode.STAMP)
	ctrl.stamp_scale = 2.0

	# A 2:1 banner previews 2:1…
	var banner := ImageTexture.create_from_image(Image.create(256, 128, false, Image.FORMAT_RGBA8))
	ctrl.stamp_texture = banner
	var quad := ctrl.stamp_mesh_instance.mesh as QuadMesh
	assert_almost_eq(quad.size.x, 2.0, 0.001, "Banner preview is stamp_scale wide")
	assert_almost_eq(quad.size.y, 1.0, 0.001, "Banner preview height follows the image aspect")

	# …and switching to a square sticker RESIZES the quad. It used to keep the
	# banner's ratio until a spinbox nudge (the "square sticker comes out
	# stretched to hello world's aspect" report).
	var square := ImageTexture.create_from_image(Image.create(64, 64, false, Image.FORMAT_RGBA8))
	ctrl.stamp_texture = square
	quad = ctrl.stamp_mesh_instance.mesh as QuadMesh
	assert_almost_eq(quad.size.x, 2.0, 0.001, "Square preview keeps stamp_scale as its width")
	assert_almost_eq(quad.size.y, 2.0, 0.001, "Square preview must be square, not the old banner ratio")

	# Switching back restores the banner ratio (no sticky state either way).
	ctrl.stamp_texture = banner
	quad = ctrl.stamp_mesh_instance.mesh as QuadMesh
	assert_almost_eq(quad.size.y, 1.0, 0.001, "Banner ratio comes back on re-selection")

# ==============================================================================
# Paint panel contract: source default + only where it applies
# ==============================================================================

func test_paint_defaults_to_the_palette_image_source() -> void:
	var ctrl := PBPaintController.new()
	assert_eq(ctrl.paint_target, PBPaintController.PaintTarget.SPLAT,
			"Splat layers stays the default paint target")
	assert_eq(ctrl.brush_source, PBPaintController.BrushSource.IMAGE,
			"The decal brush defaults to the palette image, not a flat colour")

func test_dock_disables_the_brush_source_where_it_does_not_apply() -> void:
	var dock := PBMaterialDock.new()
	add_child_autofree(dock)
	var ctrl := PBPaintController.new()
	dock.set_paint_controller(ctrl)
	dock._set_dock_mode(PBMaterialDock.DockMode.PAINT)

	# Painting defaults to Splat layers, where the brush paints the palette
	# texture by definition: the source/colour pickers are disabled rather than
	# silently ignored (that is what made the panel look like it did nothing).
	assert_eq(ctrl.paint_target, PBPaintController.PaintTarget.SPLAT)
	assert_true(dock._opt_brush_source.disabled, "Brush source is disabled for Splat layers")
	assert_true(dock._btn_brush_color.disabled, "Colour picker is disabled for Splat layers")
	assert_eq(dock._opt_brush_source.selected, int(PBPaintController.BrushSource.IMAGE),
			"The disabled row still shows the palette-image default")

	# Decal layer is where the source applies.
	dock._opt_paint_target.item_selected.emit(PBPaintController.PaintTarget.DECAL)
	assert_eq(ctrl.paint_target, PBPaintController.PaintTarget.DECAL)
	assert_false(dock._opt_brush_source.disabled, "Brush source is live for the decal layer")
	assert_false(dock._btn_brush_color.disabled, "Colour picker is live for the decal layer")

	# …and switching the target takes it away again.
	dock._opt_paint_target.item_selected.emit(PBPaintController.PaintTarget.SPLAT)
	assert_true(dock._opt_brush_source.disabled, "Brush source disables again on Splat layers")

# ==============================================================================
# Decal window density: the brush sprite must match it
# ==============================================================================

## Painted alpha along the window's centre row, and the window's last column.
func _decal_row_alpha(img: Image) -> PackedByteArray:
	var out := PackedByteArray()
	var row := img.get_height() / 2
	var b := img.get_data()
	for x in range(img.get_width()):
		out.append(b[(row * img.get_width() + x) * 4 + 3])
	return out

## The colour brush's dab sprite is built at the WINDOW's real density, not the
## requested 256 texels/m. When the window's density has dropped (a long painted
## span on a big face), a sprite built at the requested density is drawn that
## much larger in window pixels: the stroke's late dabs run past the window edge
## and are clipped mid-falloff — the "paint cuts off abruptly at the edge of the
## texture as it expands" report. A correct stroke ends in a soft fade INSIDE
## the window.
func test_decal_stroke_fades_out_inside_the_window() -> void:
	# A 60 m face (where the window's density really does drop) with a stroke
	# that spans 28 m: the window lands around 100 texels/m, well under the
	# 256 the dab sprite asks for.
	var data := PBShapeGenerators.create_plane(60.0, 60.0, 1, 1)
	PBUv.refresh_mesh_uvs(data, true)
	var mesh := PBMesh.new()
	mesh.name = "StrokeProbe"
	mesh.pb_mesh_data = data
	add_child_autofree(mesh)
	var ctrl := PBPaintController.new()
	ctrl.set_mode(PBPaintController.Mode.PAINT)
	ctrl.paint_target = PBPaintController.PaintTarget.DECAL
	ctrl.brush_source = PBPaintController.BrushSource.COLOR
	ctrl.brush_color = Color(0.85, 0.25, 0.2, 1.0)
	ctrl.brush_radius = 0.5
	ctrl.brush_softness = 1.0
	ctrl.brush_opacity = 1.0
	for i in range(29):
		ctrl.update_cursor(Vector3(-14.0 + float(i), 0, 0), Vector3.UP, mesh, 0)
		ctrl.begin_stroke()
		ctrl.end_stroke()

	var face := data.faces[0]
	var mat := data.get_face_material(face) as ShaderMaterial
	assert_true(PBSplat.is_splat_material(mat), "Fixture: the stroke created a splat material")
	var img := PBSplat.get_decal_layer_image(mat)
	assert_not_null(img, "Fixture: the stroke painted into the decal window")
	var dens := PBSplat.decal_density(mat, Vector2(60.0, 60.0))
	assert_lt(dens, PBSplat.DECAL_TEXELS_PER_M,
		"Fixture: a 28 m painted span lowers the window's density (%.0f texels/m)" % dens)

	var alpha := _decal_row_alpha(img)
	var width := img.get_width()
	var painted := 0
	for x in range(width):
		if alpha[x] > 2:
			painted += 1
	assert_gt(painted, 0, "Fixture: the stroke painted pixels")
	assert_eq(int(alpha[width - 1]), 0, "The window's last column is untouched (the dab sprite used to overshoot it)")
	assert_eq(int(alpha[width - 2]), 0, "…and so is the column before it")

	# The stroke's own end fades: the last painted texel is a falloff tail, not
	# a slab cut by the window edge.
	var last := -1
	for x in range(width):
		if alpha[x] > 2:
			last = x
	assert_lt(last, width - 2, "The paint ends inside the window")
	assert_lt(int(alpha[last]), 128, "The last painted texel is a tail (%d), not a cut slab" % int(alpha[last]))

## The window's density is chosen against a per-axis cap AND a texel budget. A
## big face's painted span used to collapse to the 2048-per-axis cap (a 60 m
## floor's 25 m span landed at ~70 texels/m, half the base texture's density,
## so its decals read blocky next to the surface around them).
func test_decal_window_density_respects_cap_and_budget() -> void:
	var data := PBShapeGenerators.create_plane(60.0, 60.0, 1, 1)
	PBUv.refresh_mesh_uvs(data, true)
	var mat := PBSplat.create_splat_material()
	var face := data.faces[0]
	PBSplat.ensure_face_splat_bounds(data, face)
	var bounds := PBSplat.get_face_planar_bounds(data, face)
	var face_m := Vector2(bounds["range_u"], bounds["range_v"])
	assert_almost_eq(face_m.x, 60.0, 0.001, "Fixture: a 60 m face")

	# Two stickers 19 m apart: the window has to cover both (a 19 m span).
	PBSplat.ensure_decal_window(mat, Rect2(0.01, 0.01, 0.02, 0.02), face_m)
	var img := PBSplat.ensure_decal_window(mat, Rect2(0.33, 0.33, 0.02, 0.02), face_m)
	assert_not_null(img)
	var texels := img.get_width() * img.get_height()
	assert_lte(texels, int(PBSplat.DECAL_MAX_WINDOW_TEXELS * 1.25),
		"The window stays inside its texel budget (%d texels)" % texels)
	assert_lte(maxi(img.get_width(), img.get_height()), PBSplat.DECAL_MAX_WINDOW_PX,
		"…and inside the per-axis cap")
	var dens := PBSplat.decal_density(mat, face_m)
	# 19.2 m of span + padding: the budget allows ~140 texels/m, the old
	# 2048-px cap only 106.
	assert_gt(dens, 120.0, "A 19 m painted span keeps a usable density (%.0f texels/m)" % dens)
	assert_lte(dens, PBSplat.DECAL_TEXELS_PER_M, "…and never exceeds the requested density")

	# A small span keeps the full 256 texels/m.
	var small := PBSplat.create_splat_material()
	PBSplat.ensure_decal_window(small, Rect2(0.4, 0.4, 0.02, 0.02), face_m)
	assert_almost_eq(PBSplat.decal_density(small, face_m), PBSplat.DECAL_TEXELS_PER_M, 1.0,
		"A compact decal keeps the full density")

# ==============================================================================
# Brush ring: built when the mode is entered
# ==============================================================================

## The ring's mesh used to be built only by the stamp path (and by a radius /
## softness nudge): with the previews set up while the dock was on another tab,
## entering PAINT showed no ring until the size was touched once.
func test_brush_ring_mesh_exists_on_mode_entry() -> void:
	var host := Node3D.new()
	add_child_autofree(host)
	var ctrl := PBPaintController.new()
	ctrl.setup_previews(host)
	ctrl.set_mode(PBPaintController.Mode.STAMP)
	assert_null(ctrl.brush_mesh_instance.mesh, "Fixture: the stamp tab has not built the ring")
	ctrl.set_mode(PBPaintController.Mode.PAINT)
	assert_not_null(ctrl.brush_mesh_instance.mesh,
		"Entering PAINT builds the ring — no size nudge needed")
	var im := ctrl.brush_mesh_instance.mesh as ImmediateMesh
	assert_eq(im.get_surface_count(), 2, "The ring carries its band + crosshair surfaces")

# ==============================================================================
# Paint-state collection with hand-authored (unset) layer params
# ==============================================================================

## A splat material may enable a layer WITHOUT setting its color/roughness
## shader params (the shader defaults apply — this is exactly how a scripted
## floor authored its splat). The paint state must coalesce those nils to the
## shader's own defaults, not pass them through: every consumer reads the dict
## with .get("color", Color.WHITE), whose default only covers a MISSING key —
## a present-but-null one crashed the modern-GLB bake's typed Color assignment.
func test_collect_paint_state_coalesces_unset_layer_params() -> void:
	var data := _test_cube.pb_mesh_data
	var mat := PBSplat.create_splat_material()
	# Deliberately NOT via add_layer (which initializes color/roughness):
	# enable the layer and give it texture + mask only.
	mat.set_shader_parameter("layer_1_enabled", true)
	mat.set_shader_parameter("layer_1_texture", load("res://addons/poibuilder/materials/textures/brick_path_4x4.png"))
	var mask := Image.create(8, 8, false, Image.FORMAT_R8)
	mask.fill(Color(1, 1, 1, 1))
	mat.set_shader_parameter("layer_1_mask", ImageTexture.create_from_image(mask))
	data.set_face_material(data.faces[0], mat)

	var state := PBSplat.collect_face_paint_state(data, data.faces[0])
	assert_not_null(state, "paint state collects for a splat face")
	assert_eq(state["layers"].size(), 1, "the enabled layer is collected")
	var layer: Dictionary = state["layers"][0]
	assert_true(layer["color"] is Color, "nil layer color coalesces to a Color (got nil)")
	assert_eq(layer["color"], Color.WHITE, "nil layer color defaults to WHITE")
	assert_true(layer["roughness"] is float, "nil layer roughness coalesces to a float (got nil)")
	assert_almost_eq(float(layer["roughness"]), 0.8, 0.0001, "nil layer roughness defaults to 0.8")
