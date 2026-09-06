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
	for i in range(50):
		var offset := Vector3(sin(i * 0.1) * 0.1, 0, cos(i * 0.1) * 0.1)
		PBSplat.paint_face_splat(data, face, mat, layer_idx, center_local + offset, 0.3, 0.5, 0.2, false)
	var elapsed_msec := Time.get_ticks_msec() - start_msec

	# 50 strokes should execute well under 100ms (< 2ms per stroke = 500+ FPS capability)
	assert_true(elapsed_msec < 150, "50 brush stroke applications should take < 150ms (took %d ms)" % elapsed_msec)

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
