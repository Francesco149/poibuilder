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
# 3. UV2 Planar Face Mapping Tests
# ==============================================================================

func test_ensure_mesh_uv2_mapping() -> void:
	var data := _test_cube.pb_mesh_data
	assert_not_null(data)

	PBSplat.ensure_mesh_uv2(data)
	assert_eq(data.textures1.size(), data.positions.size(), "textures1 should match vertex count")

	for i in range(data.textures1.size()):
		var uv2 := data.textures1[i]
		assert_true(uv2.x >= -0.001 and uv2.x <= 1.001, "UV2.x (%f) should be in [0, 1]" % uv2.x)
		assert_true(uv2.y >= -0.001 and uv2.y <= 1.001, "UV2.y (%f) should be in [0, 1]" % uv2.y)

func test_to_array_mesh_includes_uv2() -> void:
	var data := _test_cube.pb_mesh_data
	PBSplat.ensure_mesh_uv2(data)

	var arr_mesh := data.to_array_mesh()
	assert_not_null(arr_mesh)
	assert_true(arr_mesh.get_surface_count() > 0)

	var arrays := arr_mesh.surface_get_arrays(0)
	var uv2_arr = arrays[Mesh.ARRAY_TEX_UV2]
	assert_not_null(uv2_arr, "ArrayMesh surface should contain ARRAY_TEX_UV2")
	assert_eq(uv2_arr.size(), data.positions.size())

# ==============================================================================
# 4. Brush Painting Performance & Falloff Tests
# ==============================================================================

func test_brush_painting_hit_inside_and_outside_radius() -> void:
	var data := _test_cube.pb_mesh_data
	var face := data.faces[0] # top face or front face
	PBSplat.ensure_mesh_uv2(data)

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
	PBSplat.ensure_mesh_uv2(data)

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
	PBSplat.ensure_mesh_uv2(data)

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
	assert_true(elapsed_msec < 800, "100 brush stroke applications should take < 800ms (took %d ms)" % elapsed_msec)

# ==============================================================================
# 5. Stamp Pasting Tests
# ==============================================================================

func test_stamp_face_pasting_with_rotation_and_scale() -> void:
	var data := _test_cube.pb_mesh_data
	var face := data.faces[0]
	PBSplat.ensure_mesh_uv2(data)

	var mat := PBSplat.create_splat_material()
	var stamp_img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	stamp_img.fill(Color(0.2, 0.6, 0.9, 1.0)) # Rich blue stamp
	var center_local := Vector3.ZERO
	var idxs := face.get_distinct_indexes()
	for idx in idxs:
		center_local += data.positions[idx]
	center_local /= float(idxs.size())

	# Stamp 1m wide at center, rotated 45 degrees
	var stamped := PBSplat.stamp_face(data, face, mat, stamp_img, center_local, 1.0, 45.0, 1.0)
	assert_true(stamped, "stamp_face should return true")
	assert_true(PBSplat.has_stamp_layer(mat), "Dedicated stamp layer should be enabled")

	var stamp_target := PBSplat.get_stamp_layer_image(mat)
	assert_not_null(stamp_target)
	var mid := stamp_target.get_width() / 2
	var px := stamp_target.get_pixel(mid, mid)
	assert_almost_eq(px.a, 1.0, 0.05, "Stamped center pixel should have alpha 1.0")
	assert_almost_eq(px.r, 0.2, 0.05, "Stamped center pixel should have copied 1:1 red channel")
	assert_almost_eq(px.g, 0.6, 0.05, "Stamped center pixel should have copied 1:1 green channel")
	assert_almost_eq(px.b, 0.9, 0.05, "Stamped center pixel should have copied 1:1 blue channel")
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

func test_stamp_decompresses_compressed_vram_texture() -> void:
	var data := _test_cube.pb_mesh_data
	var face := data.faces[0]
	PBSplat.ensure_mesh_uv2(data)
	var mat := PBSplat.create_splat_material()

	var pattern_tex := load("res://addons/poibuilder/materials/textures/circular_square_pattern.png") as Texture2D
	assert_not_null(pattern_tex)
	var raw_img := pattern_tex.get_image()
	assert_not_null(raw_img)

	var center_local := Vector3.ZERO
	var idxs := face.get_distinct_indexes()
	for idx in idxs:
		center_local += data.positions[idx]
	center_local /= float(idxs.size())

	# Stamping should automatically decompress raw_img without throwing "Can't get_pixel() on compressed image"
	var stamped := PBSplat.stamp_face(data, face, mat, raw_img, center_local, 1.0, 0.0, 1.0)
	assert_true(stamped)
	assert_false(raw_img.is_compressed(), "Image should be decompressed after stamp_face")

	var target_img := PBSplat.get_stamp_layer_image(mat)
	assert_not_null(target_img)
	var mid := target_img.get_width() / 2
	var px := target_img.get_pixel(mid, mid)
	# Circular square pattern has center white/light-blue shape with alpha > 0.8
	assert_true(px.a > 0.5, "Center pixel should have positive alpha (not 0)")
	assert_true(px.r > 0.2, "Center pixel should have color (not black square)")
# ==============================================================================
# 6. Undo/Redo & Splat Cloning Tests
# ==============================================================================

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
	# Also test dedicated stamp layer cloning
	var stamp_img := PBSplat.get_stamp_layer_image(mat)
	stamp_img.set_pixel(20, 20, Color(0.3, 0.7, 0.1, 0.9))
	var clone2 := PBSplat.clone_splat_material(mat)
	assert_true(PBSplat.has_stamp_layer(clone2))
	var clone2_stamp_img := PBSplat.get_stamp_layer_image(clone2)
	assert_almost_eq(clone2_stamp_img.get_pixel(20, 20).r, 0.3, 0.01)
	assert_almost_eq(clone2_stamp_img.get_pixel(20, 20).a, 0.9, 0.01)
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

func test_dynamic_image_resizing_on_large_faces() -> void:
	var mat := PBSplat.create_splat_material()
	# Create initial 256x256 image
	var img_256 := PBSplat.get_stamp_layer_image(mat, Vector2i(256, 256))
	assert_eq(img_256.get_width(), 256)

	# Request 1024x1024 on same material (e.g. when stamping on a larger 4m face)
	var img_1024 := PBSplat.get_stamp_layer_image(mat, Vector2i(1024, 1024))
	assert_eq(img_1024.get_width(), 1024, "Stamp layer image should dynamically upscale to 1024")
	assert_eq(img_1024.get_height(), 1024, "Stamp layer image should dynamically upscale to 1024")

func test_billboard_decal_stamping() -> void:
	var cube := PBMesh.create_cube(2.0)
	add_child_autofree(cube)

	var ctrl := PBPaintController.new()
	ctrl.set_mode(PBPaintController.Mode.STAMP)
	var stamp_tex := ImageTexture.create_from_image(Image.create(32, 32, false, Image.FORMAT_RGBA8))
	ctrl.stamp_texture = stamp_tex
	ctrl.update_cursor(Vector3(0, 1.0, 0), Vector3.UP, cube, 4)

	ctrl.apply_stamp()
	var stamps := cube.get_node_or_null("PBStamps")
	assert_not_null(stamps, "PBStamps container should be created on target mesh")
	assert_eq(stamps.get_child_count(), 1, "Should contain 1 stamp decal")

	var decal := stamps.get_child(0) as MeshInstance3D
	assert_not_null(decal)
	assert_true(decal.mesh is QuadMesh, "Decal mesh should be QuadMesh")
	assert_true(decal.material_override != null, "Decal should have a valid material")
	if decal.material_override is ShaderMaterial:
		var smat := decal.material_override as ShaderMaterial
		assert_eq(smat.get_shader_parameter("albedo_texture"), stamp_tex)
	elif decal.material_override is StandardMaterial3D:
		assert_eq((decal.material_override as StandardMaterial3D).albedo_texture, stamp_tex)

	# Clear all stamps
	ctrl.clear_all_stamps(cube)
	assert_eq(stamps.get_child_count(), 0, "Stamps should be cleared")
# ==============================================================================
# 8. PBMaterialDock Integration Tests
# ==============================================================================

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
	PBSplat.ensure_mesh_uv2(data)
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
	PBSplat.ensure_mesh_uv2(data)
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
	PBSplat.ensure_mesh_uv2(data)
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
	PBSplat.ensure_mesh_uv2(data)
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

## Stamps carry a normalized face anchor; re-evaluating the anchor against the
## CURRENT geometry reproduces the stored transform (roundtrip).
func test_stamp_anchor_roundtrip() -> void:
	var cube := PBMesh.create_cube(2.0)
	add_child_autofree(cube)
	var ctrl := PBPaintController.new()
	ctrl.set_mode(PBPaintController.Mode.STAMP)
	ctrl.stamp_texture = ImageTexture.create_from_image(Image.create(16, 16, false, Image.FORMAT_RGBA8))
	ctrl.stamp_scale = 0.8
	ctrl.stamp_rotation = 30.0
	ctrl.update_cursor(Vector3(0.3, 1.0, 0.2), Vector3.UP, cube, 4)
	ctrl.apply_stamp()

	var stamps := cube.get_node_or_null("PBStamps")
	assert_not_null(stamps)
	assert_eq(stamps.get_child_count(), 1)
	var decal := stamps.get_child(0) as MeshInstance3D
	assert_true(decal.has_meta("anchor_center"), "Stamp should carry a normalized anchor_center")
	assert_true(decal.has_meta("anchor_du") and decal.has_meta("anchor_dv"))
	assert_true(decal.mesh is QuadMesh)
	assert_almost_eq((decal.mesh as QuadMesh).size.x, 1.0, 0.001, "Stamp quad is unit size; extents live in the basis")

	var data := cube.pb_mesh_data
	var face := data.faces[4]
	var res := PBSplat.stamp_transform_from_anchor(data, face, {
		"center": decal.get_meta("anchor_center"),
		"du": decal.get_meta("anchor_du"),
		"dv": decal.get_meta("anchor_dv"),
	})
	assert_false(res.is_empty(), "Anchor must produce a transform")
	var xf: Transform3D = res["transform"]
	assert_almost_eq(xf.origin.distance_to(decal.transform.origin), 0.0, 0.001, "Anchor reproduces the stamp center")
	assert_almost_eq(xf.basis.x.length(), ctrl.stamp_scale, 0.01, "Anchor reproduces the stamp extent")
	assert_almost_eq(xf.basis.y.length(), ctrl.stamp_scale, 0.01, "Anchor reproduces the stamp extent (y)")

## Resizing the face must NOT stretch or slide the stamp (nothing should stretch or slide).
func test_stamp_does_not_stretch_or_slide_when_face_resized() -> void:
	var cube := PBMesh.create_cube(2.0)
	add_child_autofree(cube)
	var ctrl := PBPaintController.new()
	ctrl.set_mode(PBPaintController.Mode.STAMP)
	ctrl.stamp_texture = ImageTexture.create_from_image(Image.create(16, 16, false, Image.FORMAT_RGBA8))
	ctrl.stamp_scale = 0.5
	ctrl.stamp_rotation = 0.0
	ctrl.update_cursor(Vector3(0.0, 1.0, 0.0), Vector3.UP, cube, 4)
	ctrl.apply_stamp()

	var decals := cube.get_node_or_null("PBStamps")
	var decal := decals.get_child(0) as MeshInstance3D
	var before_extent: float = decal.transform.basis.x.length()
	var before_pos: Vector3 = decal.transform.origin

	# Uniformly double the top face (face 4) about its in-plane center.
	var data := cube.pb_mesh_data
	var face := data.faces[4]
	var center := _face_center_local(data, face)
	for idx in face.get_distinct_indexes():
		data.positions[idx] = center + (data.positions[idx] - center) * 2.0
	cube.rebuild()

	var after_extent: float = decal.transform.basis.x.length()
	assert_almost_eq(after_extent, before_extent, 0.01,
		"Resizing the face must NOT stretch the stamp")
	assert_almost_eq(decal.transform.origin.distance_to(before_pos), 0.0, 0.001,
		"Resizing the face must NOT slide the stamp")

	# Non-uniform growth: stretch the face along +X only -> stamp still does not stretch or shear
	for idx in face.get_distinct_indexes():
		var p: Vector3 = data.positions[idx]
		data.positions[idx] = center + Vector3((p - center).x * 4.0, (p - center).y, (p - center).z)
	cube.rebuild()
	assert_almost_eq(decal.transform.basis.x.length(), before_extent, 0.01,
		"Non-uniform face stretch must NOT stretch the stamp x axis")
	assert_almost_eq(decal.transform.basis.y.length(), before_extent, 0.01,
		"Non-uniform face stretch must NOT stretch the stamp y axis")

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

	# Rebuild mesh and check initial UV2 coordinates
	cube.rebuild()
	var orig_uv2 := data.textures1.duplicate()
	assert_eq(orig_uv2.size(), data.positions.size())

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

	# UV2 at the unmoved vertices must be identical (no sliding):
	for idx in face.get_distinct_indexes():
		var p: Vector3 = data.positions[idx]
		if u_axis.dot(p) < 0.0:
			assert_almost_eq(data.textures1[idx].x, orig_uv2[idx].x, 0.001)
			assert_almost_eq(data.textures1[idx].y, orig_uv2[idx].y, 0.001)
		else:
			# Moved vertices have UV2 > 1.0 (new geometry outside the original mask):
			assert_true(data.textures1[idx].x > 1.5, "Moved vertices have UV2 proportionally expanded, not stretched to 1.0")

## Moving/raising an object in object mode keeps stamp clipping perfectly aligned (mesh-local clipping).
func test_stamp_clipping_moves_with_object_in_object_mode() -> void:
	var cube := PBMesh.create_cube(2.0)
	add_child_autofree(cube)
	var ctrl := PBPaintController.new()
	ctrl.set_mode(PBPaintController.Mode.STAMP)
	ctrl.stamp_texture = ImageTexture.create_from_image(Image.create(16, 16, false, Image.FORMAT_RGBA8))
	ctrl.stamp_scale = 1.0
	# Stamp placed near the bottom edge of face 0 (z = -1, y from -1 to 1)
	ctrl.update_cursor(Vector3(0.0, -0.8, -1.0), Vector3.FORWARD, cube, 0)
	ctrl.apply_stamp()

	var decals := cube.get_node_or_null("PBStamps")
	assert_not_null(decals)
	var decal := decals.get_child(0) as MeshInstance3D
	assert_not_null(decal)
	var smat := decal.material_override as ShaderMaterial
	assert_not_null(smat)

	var stamp_to_mesh: Transform3D = smat.get_shader_parameter("stamp_to_mesh")
	var face_bounds: Vector4 = smat.get_shader_parameter("face_bounds")
	var face_u: Vector3 = smat.get_shader_parameter("face_u")
	var face_v: Vector3 = smat.get_shader_parameter("face_v")

	# Point on bottom edge of stamp quad in decal local coordinates (y = -0.5)
	var p_local := Vector3(0.0, -0.5, 0.0)
	var p_mesh := stamp_to_mesh * p_local
	var v_coord := face_v.dot(p_mesh)
	var is_clipped_before := (v_coord < face_bounds.z or v_coord > face_bounds.w)

	# Move the cube in object mode: raise Y by 10m and shift X by 5m
	cube.global_position = Vector3(5.0, 10.0, 0.0)

	# Clipping calculation is mesh-local and invariant to object-mode movement:
	var stamp_to_mesh_after: Transform3D = smat.get_shader_parameter("stamp_to_mesh")
	assert_almost_eq(stamp_to_mesh_after.origin.distance_to(stamp_to_mesh.origin), 0.0, 0.001,
		"stamp_to_mesh is invariant to object-mode translation")
	var p_mesh_after := stamp_to_mesh_after * p_local
	var v_coord_after := face_v.dot(p_mesh_after)
	var is_clipped_after := (v_coord_after < face_bounds.z or v_coord_after > face_bounds.w)

	assert_eq(is_clipped_after, is_clipped_before,
		"Stamp clipping relative to the face is 100% preserved when the object moves in object mode")
## The export-facing collector returns plain, node-free stamp records.
func test_collect_stamp_data_exports_anchors() -> void:
	var cube := PBMesh.create_cube(2.0)
	add_child_autofree(cube)
	var ctrl := PBPaintController.new()
	ctrl.set_mode(PBPaintController.Mode.STAMP)
	var stamp_tex := ImageTexture.create_from_image(Image.create(16, 16, false, Image.FORMAT_RGBA8))
	ctrl.stamp_texture = stamp_tex
	ctrl.stamp_opacity = 0.8
	ctrl.update_cursor(Vector3(0.0, 1.0, 0.0), Vector3.UP, cube, 4)
	ctrl.apply_stamp()

	var collected := PBSplat.collect_stamp_data(cube)
	assert_eq(collected.size(), 1, "collect_stamp_data returns one record per anchored stamp")
	var rec: Dictionary = collected[0]
	assert_eq(rec["face_idx"], 4)
	assert_true(rec["anchor_center"] is Vector2)
	assert_true(rec["anchor_du"] is Vector2 and rec["anchor_dv"] is Vector2)
	assert_almost_eq(rec["opacity"], 0.8, 0.001)
	# Records are export-friendly: u,v of a unit-square anchor of a centered
	# stamp on a 2m top face sits at the face center.
	assert_almost_eq((rec["anchor_center"] as Vector2).x, 0.5, 0.05)
	assert_almost_eq((rec["anchor_center"] as Vector2).y, 0.5, 0.05)

## The export-facing face paint state collector returns base material + layers
## + normalized planar bounds for a painted face, and {} for an unpainted one.
func test_collect_face_paint_state_exports_layers_and_bounds() -> void:
	var data := _test_cube.pb_mesh_data
	var face := data.faces[0]
	PBSplat.ensure_mesh_uv2(data)

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

func test_stamp_delete_hover_and_click_deletion() -> void:
	var root := Node3D.new()
	add_child_autofree(root)
	var mesh_node := PBMesh.new()
	root.add_child(mesh_node)

	var stamps_container := Node3D.new()
	stamps_container.name = "PBStamps"
	mesh_node.add_child(stamps_container)

	var stamp := MeshInstance3D.new()
	stamp.name = "Stamp_1"
	var qm := QuadMesh.new()
	qm.size = Vector2.ONE
	stamp.mesh = qm
	stamp.transform = Transform3D(Basis.IDENTITY, Vector3(0, 1, 0))
	stamps_container.add_child(stamp)

	var controller := PBPaintController.new()
	controller.setup_previews(root)
	controller.set_mode(PBPaintController.Mode.STAMP_DELETE)

	var cam := Camera3D.new()
	root.add_child(cam)
	cam.position = Vector3(0, 1, 4)
	cam.look_at(Vector3(0, 1, 0), Vector3.UP)

	# Ray straight at the stamp
	var screen_center := Vector2(200, 200)
	# Update hover
	# Ray straight at the stamp
	controller.update_delete_hover(cam, screen_center, root, Vector3(0, 1, 4), Vector3(0, 0, -1))
	assert_not_null(controller.hovered_stamp, "Stamp should be hovered by ray")
	assert_eq(controller.hovered_stamp, stamp)
	assert_true(controller.delete_highlight_mesh.visible, "Highlight mesh should be visible when hovering stamp")

	# Test miss
	controller.update_delete_hover(cam, screen_center, root, Vector3(5, 5, 5), Vector3(0, 0, -1))
	assert_null(controller.hovered_stamp, "Miss ray should clear hover")
	assert_false(controller.delete_highlight_mesh.visible, "Miss ray should hide highlight mesh")

	# Re-hover
	controller.update_delete_hover(cam, screen_center, root, Vector3(0, 1, 4), Vector3(0, 0, -1))
	# Delete the hovered stamp
	var deleted := controller.delete_hovered_stamp()
	assert_true(deleted, "delete_hovered_stamp should return true")
	assert_null(controller.hovered_stamp, "Hovered stamp should be cleared after deletion")
	assert_false(controller.delete_highlight_mesh.visible, "Highlight should hide after deletion")
	assert_eq(stamps_container.get_child_count(), 0, "Stamp node should be removed from container")

	controller.cleanup_previews()
	root.queue_free()
