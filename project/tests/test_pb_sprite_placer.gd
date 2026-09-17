## Tests for PBSpritePlacer (Billboard Sprite placement, orientation, scaling & carousel UX).
extends GutTest

var _root: Node3D = null
var _host: Control = null
var _camera: Camera3D = null

func before_each() -> void:
	_root = Node3D.new()
	add_child_autofree(_root)

	_host = Control.new()
	_host.size = Vector2(800, 600)
	_root.add_child(_host)

	_camera = Camera3D.new()
	_camera.position = Vector3(0, 2, 5)
	_camera.look_at(Vector3.ZERO, Vector3.UP)
	_root.add_child(_camera)

func test_texture_discovery_finds_project_textures() -> void:
	var placer := PBSpritePlacer.new()
	placer.refresh_available_textures()
	assert_gt(placer.available_textures.size(), 0, "Should discover textures in project")

	var found_names: Array[String] = []
	for tex in placer.available_textures:
		found_names.append(tex.resource_path.get_file())

	assert_has(found_names, "tree_pine.png")
	assert_has(found_names, "tree_oak.png")
	assert_has(found_names, "bush_foliage.png")
	assert_has(found_names, "grass_tuft.png")
	# v0.9.139 asset categorization: the sprite carousel must list ONLY
	# sprites — stamps (flower_patch) and paint textures (tiles/brick) are
	# filtered out by PBAssetCatalog.
	assert_false(found_names.has("flower_patch.png"), "stamps must not appear in the sprite carousel")
	assert_false(found_names.has("tiles_wet_4x4.png"), "paint textures must not appear in the sprite carousel")
	assert_false(found_names.has("particle_flame.png"), "particles must not appear in the sprite carousel")

func test_placer_lifecycle_and_arming() -> void:
	var placer := PBSpritePlacer.new()
	assert_eq(placer.state, PBSpritePlacer.State.INACTIVE)
	assert_false(placer.is_active())

	placer.arm()
	assert_eq(placer.state, PBSpritePlacer.State.ARMED)
	assert_true(placer.is_active())

	placer.abort()
	assert_eq(placer.state, PBSpritePlacer.State.INACTIVE)
	assert_false(placer.is_active())

func test_first_click_no_texture_opens_click_carousel() -> void:
	var placer := PBSpritePlacer.new()
	placer.scene_root_override = _root
	placer.last_texture = null
	placer.arm()

	var hit := {"point": Vector3(0, 0, 0), "normal": Vector3.UP}
	var press_ev := InputEventMouseButton.new()
	press_ev.button_index = MOUSE_BUTTON_LEFT
	press_ev.pressed = true
	press_ev.position = Vector2(400, 300)

	var res := placer.handle_input(_camera, press_ev, hit, _host)
	assert_eq(res, 1, "Should consume input (STOP)")
	assert_eq(placer.state, PBSpritePlacer.State.TEXTURE_SELECT)
	assert_false(placer.is_hold_mode, "First click with no texture should be click mode (not hold)")
	assert_not_null(placer.carousel_overlay)
	assert_true(placer.carousel_overlay.visible)

	# Click confirms selection
	var click_ev := InputEventMouseButton.new()
	click_ev.button_index = MOUSE_BUTTON_LEFT
	click_ev.pressed = true
	click_ev.position = Vector2(400, 300)

	res = placer.handle_input(_camera, click_ev, hit, _host)
	assert_eq(res, 1)
	assert_eq(placer.state, PBSpritePlacer.State.RAISE)
	assert_not_null(placer.last_texture, "Selected texture should be stored in last_texture")
	assert_not_null(placer.preview_node, "Preview node should exist in RAISE phase")
	assert_false(placer.carousel_overlay.visible, "Carousel should hide after selection")

	placer.abort()

func test_click_and_drag_triggers_hold_carousel_and_raise() -> void:
	var placer := PBSpritePlacer.new()
	placer.scene_root_override = _root
	placer.refresh_available_textures()
	assert_gt(placer.available_textures.size(), 0)
	placer.last_texture = placer.available_textures[0]
	placer.arm()

	var hit := {"point": Vector3(0, 0, 0), "normal": Vector3.UP}
	var press_ev := InputEventMouseButton.new()
	press_ev.button_index = MOUSE_BUTTON_LEFT
	press_ev.pressed = true
	press_ev.position = Vector2(400, 300)

	placer.handle_input(_camera, press_ev, hit, _host)
	assert_eq(placer.state, PBSpritePlacer.State.ARMED, "State stays ARMED until drag threshold is reached")

	# Motion > 6px -> opens hold mode
	var motion_ev := InputEventMouseMotion.new()
	motion_ev.position = Vector2(410, 300)
	motion_ev.relative = Vector2(10, 0)

	placer.handle_input(_camera, motion_ev, hit, _host)
	assert_eq(placer.state, PBSpritePlacer.State.TEXTURE_SELECT)
	assert_true(placer.is_hold_mode, "Click-and-drag opens hold mode")
	assert_true(placer.carousel_overlay.visible)

	# Further horizontal motion scrolls carousel
	var init_scroll := placer.scroll_offset
	var scroll_ev := InputEventMouseMotion.new()
	scroll_ev.position = Vector2(460, 300)
	scroll_ev.relative = Vector2(50, 0)
	placer.handle_input(_camera, scroll_ev, hit, _host)
	assert_gt(placer.scroll_offset, init_scroll, "Horizontal motion should scroll textures")

	# Release LMB confirms in hold mode
	var release_ev := InputEventMouseButton.new()
	release_ev.button_index = MOUSE_BUTTON_LEFT
	release_ev.pressed = false
	release_ev.position = Vector2(460, 300)

	placer.handle_input(_camera, release_ev, hit, _host)
	assert_eq(placer.state, PBSpritePlacer.State.RAISE)
	assert_not_null(placer.preview_node)

	placer.abort()

func test_raise_orient_and_scale_phases_to_finalization() -> void:
	var placer := PBSpritePlacer.new()
	placer.scene_root_override = _root
	placer.refresh_available_textures()
	placer.last_texture = placer.available_textures[0]
	placer.arm()

	var hit := {"point": Vector3(1, 0, 1), "normal": Vector3.UP}
	var press_ev := InputEventMouseButton.new()
	press_ev.button_index = MOUSE_BUTTON_LEFT
	press_ev.pressed = true
	press_ev.position = Vector2(400, 300)
	placer.handle_input(_camera, press_ev, hit, _host)

	# Release immediately -> clean single click creates with last_texture
	var rel_ev := InputEventMouseButton.new()
	rel_ev.button_index = MOUSE_BUTTON_LEFT
	rel_ev.pressed = false
	rel_ev.position = Vector2(400, 300)
	placer.handle_input(_camera, rel_ev, hit, _host)

	assert_eq(placer.state, PBSpritePlacer.State.RAISE)
	assert_not_null(placer.preview_node)
	assert_almost_eq(placer.elevation, 0.0, 0.001)

	# Mouse up raises elevation
	var up_ev := InputEventMouseMotion.new()
	up_ev.position = Vector2(400, 250)
	up_ev.relative = Vector2(0, -50)
	placer.handle_input(_camera, up_ev, hit, _host)
	assert_gt(placer.elevation, 0.0, "Mousing up should raise elevation")

	# Click confirms elevation and locks angle -> enters SCALE
	var lock_ev := InputEventMouseButton.new()
	lock_ev.button_index = MOUSE_BUTTON_LEFT
	lock_ev.pressed = true
	lock_ev.position = Vector2(400, 250)
	placer.handle_input(_camera, lock_ev, hit, _host)

	assert_eq(placer.state, PBSpritePlacer.State.SCALE)

	# Mouse right scales up
	var scale_ev := InputEventMouseMotion.new()
	scale_ev.position = Vector2(450, 250)
	scale_ev.relative = Vector2(50, 0)
	placer.handle_input(_camera, scale_ev, hit, _host)
	assert_gt(placer.scale_factor, 1.0, "Mouse right should scale up")

	# Click confirms scale and finalizes
	var confirm_ev := InputEventMouseButton.new()
	confirm_ev.button_index = MOUSE_BUTTON_LEFT
	confirm_ev.pressed = true
	confirm_ev.position = Vector2(450, 250)

	watch_signals(placer)
	placer.handle_input(_camera, confirm_ev, hit, _host)

	assert_signal_emitted(placer, "sprite_placed")
	assert_eq(placer.state, PBSpritePlacer.State.INACTIVE)

func test_material_property_configurations() -> void:
	var tex := ImageTexture.create_from_image(Image.create(16, 16, false, Image.FORMAT_RGBA8))

	# Unshaded & billboard
	var mat_unshaded := PBSpritePlacer.create_billboard_material(tex, false, true)
	assert_eq(mat_unshaded.shading_mode, BaseMaterial3D.SHADING_MODE_UNSHADED)
	assert_eq(mat_unshaded.billboard_mode, BaseMaterial3D.BILLBOARD_FIXED_Y)
	assert_eq(mat_unshaded.cull_mode, BaseMaterial3D.CULL_DISABLED)

	# Lit & fixed angle (no billboard)
	var mat_lit := PBSpritePlacer.create_billboard_material(tex, true, false)
	assert_eq(mat_lit.shading_mode, BaseMaterial3D.SHADING_MODE_PER_PIXEL)
	assert_eq(mat_lit.billboard_mode, BaseMaterial3D.BILLBOARD_DISABLED)

func test_sprite_dimensions_computed_from_aspect_ratio() -> void:
	# 256x512 texture (aspect 0.5)
	var tex_tall := ImageTexture.create_from_image(Image.create(256, 512, false, Image.FORMAT_RGBA8))
	var dims_tall := PBSpritePlacer.compute_texture_dimensions(tex_tall, 2.0)
	assert_almost_eq(dims_tall.x, 1.0, 0.001, "Width should be target_height * 0.5")
	assert_almost_eq(dims_tall.y, 2.0, 0.001, "Height should be target_height")

	# 256x256 texture (aspect 1.0)
	var tex_square := ImageTexture.create_from_image(Image.create(256, 256, false, Image.FORMAT_RGBA8))
	var dims_square := PBSpritePlacer.compute_texture_dimensions(tex_square, 1.5)
	assert_almost_eq(dims_square.x, 1.5, 0.001)
	assert_almost_eq(dims_square.y, 1.5, 0.001)

## Regression: the raise guide's top endpoint must land at the sprite's BASE
## (surface + normal * elevation). The sprite quad is base-anchored
## (create_sprite builds it from Y=0 up); the old `-h/2` term assumed a
## center-anchored quad and buried most of the guide below the surface.
func test_raise_guide_anchors_at_sprite_base() -> void:
	var placer := PBSpritePlacer.new()
	placer.scene_root_override = _root
	placer.refresh_available_textures()
	placer.last_texture = placer.available_textures[0]
	placer.arm()

	var hit := {"point": Vector3(1, 0, 1), "normal": Vector3.UP}
	var press_ev := InputEventMouseButton.new()
	press_ev.button_index = MOUSE_BUTTON_LEFT
	press_ev.pressed = true
	press_ev.position = Vector2(400, 300)
	placer.handle_input(_camera, press_ev, hit, _host)

	var rel_ev := InputEventMouseButton.new()
	rel_ev.button_index = MOUSE_BUTTON_LEFT
	rel_ev.pressed = false
	rel_ev.position = Vector2(400, 300)
	placer.handle_input(_camera, rel_ev, hit, _host)
	assert_eq(placer.state, PBSpritePlacer.State.RAISE)

	# Mouse up -> elevation 50 * 0.012 = 0.6 m
	var up_ev := InputEventMouseMotion.new()
	up_ev.position = Vector2(400, 250)
	up_ev.relative = Vector2(0, -50)
	placer.handle_input(_camera, up_ev, hit, _host)
	assert_almost_eq(placer.elevation, 0.6, 0.001)

	assert_true(placer._guide_line != null and is_instance_valid(placer._guide_line),
		"RAISE phase must show the guide line")
	var guide_mat := placer._guide_line.material_override as StandardMaterial3D
	assert_true(guide_mat.no_depth_test, "Guide must draw over the surface it rises from, not drown under it")

	var mesh := placer._guide_line.mesh as ImmediateMesh
	assert_true(mesh != null and mesh.get_surface_count() >= 2, "Guide mesh must have the band + core surfaces")
	# Surface 0 is the band strip: [ground±side, bottom±side]. The sprite base
	# sits at ground + normal * elevation, so the band's top pair is at the
	# ground plane and its bottom pair at the raised base.
	var band := mesh.surface_get_arrays(0)
	assert_true(band[Mesh.ARRAY_VERTEX] != null, "Guide band must carry vertices")
	var band_verts: PackedVector3Array = band[Mesh.ARRAY_VERTEX]
	assert_eq(band_verts.size(), 4, "Band strip has 4 vertices")
	assert_almost_eq(band_verts[0].y, 0.0, 0.01, "Band top pair sits on the ground plane")
	assert_almost_eq(band_verts[1].y, 0.0, 0.01, "Band top pair sits on the ground plane")
	assert_almost_eq(band_verts[2].y, placer.elevation, 0.01, "Band bottom pair lands at the sprite BASE (ground + elevation)")
	assert_almost_eq(band_verts[3].y, placer.elevation, 0.01, "Band bottom pair lands at the sprite BASE (ground + elevation)")

	placer.abort()

func test_sprite_quad_has_manual_uv_and_correct_orientation() -> void:
	var md := PBShapeGenerators.create_sprite(1.0, 2.0)
	assert_eq(md.faces.size(), 1)
	assert_true(md.faces[0].manual_uv, "Sprite face must have manual_uv = true so auto-UV never flips it")

	# Bottom vertices at y = 0 must have UV V = 1.0 (bottom of image)
	# Top vertices at y = 2.0 must have UV V = 0.0 (top of image)
	var p0 := md.positions[0]
	var p1 := md.positions[1]
	assert_almost_eq(p0.y, 0.0, 0.001, "p0 is at ground level")
	assert_almost_eq(md.textures0[0].y, 1.0, 0.001, "Bottom vertex must map to V=1.0 (bottom of texture)")
	assert_almost_eq(p1.y, 2.0, 0.001, "p1 is at top")
	assert_almost_eq(md.textures0[1].y, 0.0, 0.001, "Top vertex must map to V=0.0 (top of texture)")

	# Rebuilding to ArrayMesh must preserve these exact UVs without inverting them
	var mesh := md.to_array_mesh()
	assert_not_null(mesh)
	assert_almost_eq(md.textures0[0].y, 1.0, 0.001, "to_array_mesh must not overwrite manual UVs")
	assert_almost_eq(md.textures0[1].y, 0.0, 0.001, "to_array_mesh must not overwrite manual UVs")

func test_material_dock_sprite_mode_and_texture_selection() -> void:
	var dock := PBMaterialDock.new()
	add_child_autofree(dock)
	var placer := PBSpritePlacer.new()
	dock.sprite_placer = placer

	dock._set_dock_mode(PBMaterialDock.DockMode.SPRITE)
	assert_eq(dock.dock_mode, PBMaterialDock.DockMode.SPRITE)
	assert_true(dock._sprite_tool_section.visible)
	assert_false(dock._paint_tool_section.visible)
	assert_false(dock._stamp_tool_section.visible)

	var tex := ImageTexture.create_from_image(Image.create(32, 64, false, Image.FORMAT_RGBA8))
	dock.set_active_sprite_texture(tex)
	assert_eq(placer.last_texture, tex, "Setting active sprite texture must set placer.last_texture")
	assert_eq(dock._active_sprite_icon.texture, tex)

func test_edit_sprite_properties_via_overlay_params() -> void:
	var tex := ImageTexture.create_from_image(Image.create(32, 32, false, Image.FORMAT_RGBA8))
	var node := PBMesh.new()
	add_child_autofree(node)
	var md := PBShapeGenerators.create_sprite(1.0, 1.5)
	var mat := PBSpritePlacer.create_billboard_material(tex, false, true)
	md.materials = [mat]
	md.shape_id = &"sprite"
	md.shape_params = {
		"width": 1.0,
		"height": 1.5,
		"depth": 1.5,
		"lit": 0.0,
		"cast_shadow": 1.0,
		"billboard": 1.0,
	}
	node.pb_mesh_data = md
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	node.rebuild()

	# Simulate overlay params edit session
	var edit_values: Dictionary = node.pb_mesh_data.shape_params.duplicate()
	edit_values["lit"] = 1.0
	edit_values["billboard"] = 0.0
	edit_values["cast_shadow"] = 0.0
	edit_values["width"] = 2.5
	edit_values["height"] = 3.0

	# Rebuild shape
	var rebuilt := PBShapeParams.build(node.pb_mesh_data.shape_id, edit_values)
	assert_not_null(rebuilt)
	rebuilt.shape_id = &"sprite"
	rebuilt.shape_params = edit_values.duplicate()

	# Verify sprite-specific rebuild preserving texture & applying properties
	var is_lit: bool = float(edit_values.get("lit", 0.0)) > 0.5
	var is_billboard: bool = float(edit_values.get("billboard", 1.0)) > 0.5
	var has_shadow: bool = float(edit_values.get("cast_shadow", 1.0)) > 0.5
	var existing_tex: Texture2D = (node.pb_mesh_data.materials[0] as StandardMaterial3D).albedo_texture
	var smat := PBSpritePlacer.create_billboard_material(existing_tex, is_lit, is_billboard)
	rebuilt.materials = [smat]

	node.pb_mesh_data = rebuilt
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED if has_shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.rebuild()

	assert_eq(node.pb_mesh_data.materials.size(), 1)
	var updated_mat := node.pb_mesh_data.materials[0] as StandardMaterial3D
	assert_eq(updated_mat.albedo_texture, tex, "Texture must be preserved during property edits")
	assert_eq(updated_mat.shading_mode, BaseMaterial3D.SHADING_MODE_PER_PIXEL, "Lit property must set per-pixel shading")
	assert_eq(updated_mat.billboard_mode, BaseMaterial3D.BILLBOARD_DISABLED, "Billboard disabled must set BILLBOARD_DISABLED")
	assert_eq(node.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "Cast shadow disabled must turn off shadow casting")
	assert_almost_eq(node.pb_mesh_data.positions[2].x, 1.25, 0.001, "Width scaled to 2.5 (hw = 1.25)")
	assert_almost_eq(node.pb_mesh_data.positions[2].y, 3.0, 0.001, "Height scaled to 3.0")

func test_placed_sprite_casts_shadows_with_cutout_material() -> void:
	# Drive the placement phases directly (no viewport needed): the committed
	# sprite must be shadow-casting and its material ALPHA_SCISSOR — Godot's
	# shadow pass skips soft-alpha geometry entirely, so a TRANSPARENCY_ALPHA
	# billboard material meant placed sprites never cast a shadow.
	var placer := PBSpritePlacer.new()
	autofree(placer)
	var img := Image.create(16, 32, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 1))
	var tex := ImageTexture.create_from_image(img)
	placer.arm()
	placer.last_texture = tex
	placer.selected_texture = tex
	placer.press_surface_point = Vector3.ZERO
	placer.press_surface_normal = Vector3.UP
	placer._start_raise_phase(null)
	assert_eq(placer.state, PBSpritePlacer.State.RAISE, "Placement enters the raise phase")
	placer.scale_factor = 1.0
	var placed: Array = []
	placer.sprite_placed.connect(func(n: PBMesh): placed.append(n))
	placer.finalize_placement()
	assert_eq(placed.size(), 1, "finalize_placement commits exactly one node")
	var node: PBMesh = placed[0]
	autofree(node)
	assert_false(node.pb_mesh_data == null, "Placed node carries mesh data")
	assert_ne(node.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"Placed sprite must cast shadows by default")
	assert_gt(node.pb_mesh_data.materials.size(), 0, "Sprite carries its billboard material")
	var mat := node.pb_mesh_data.materials[0] as StandardMaterial3D
	assert_eq(mat.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR,
		"Sprite material must be alpha-scissor so the shadow pass renders it")
