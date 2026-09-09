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
	assert_has(found_names, "flower_patch.png")

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
