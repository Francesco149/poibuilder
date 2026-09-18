## Tests for PBParticleParams / PBParticlePlacer (the Particles tab) and the
## dock's particle palette. Pins the emitter model to what the retro exporter
## maps onto the format's emitter record: presets, the placement gesture,
## PSP budget caps, properties round-trip, and export-record parity.
extends GutTest

var _root: Node3D = null
var _host: Control = null
var _camera: Camera3D = null

func _flame_tex() -> Texture2D:
	var path := "res://addons/poibuilder/materials/textures/particle_flame.png"
	if ResourceLoader.exists(path):
		return load(path)
	return ImageTexture.create_from_image(Image.create(8, 8, false, Image.FORMAT_RGBA8))

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

func test_presets_key_on_texture_family() -> void:
	var flame := PBParticleParams.preset_for_texture("res://x/particle_flame.png")
	assert_true(flame["additive"], "Flame is additive")
	assert_eq(float(flame["count"]), 24.0)

	var smoke := PBParticleParams.preset_for_texture("res://x/particle_smoke.png")
	assert_false(smoke["additive"], "Smoke is soft-blended")
	assert_true(smoke["y_locked"], "Smoke is a cylinder billboard (the mist emitter's look)")

	var glow := PBParticleParams.preset_for_texture("res://x/particle_glow.png")
	assert_true(glow["additive"])

	# Unknown textures fall back to the cheap default (additive, small).
	var unknown := PBParticleParams.preset_for_texture("res://x/sparkle_custom.png")
	assert_true(unknown["additive"], "Additive is the PSP-friendly default")
	assert_true(float(unknown["size"]) <= 1.0)

func test_build_node_matches_export_record() -> void:
	var tex := _flame_tex()
	var values := PBParticleParams.preset_for_texture(tex.resource_path.get_file())
	var node := PBParticleParams.build_node(tex, values, "Emitter_Flame")
	autofree(node)

	assert_eq(node.name, "Emitter_Flame")
	assert_lte(node.amount, PBParticleParams.MAX_PER_EMITTER, "Per-emitter format cap")
	assert_true(node.use_fixed_seed, "Deterministic preview")
	assert_true(node.has_meta("poi_seed"), "Seed mirrored to the exporter's meta")
	assert_eq(int(node.get_meta("poi_seed")), node.seed)
	assert_false(node.one_shot, "Continuous stream (no PHASE_ALIGN flag)")

	# Export-record parity: the node the tool builds must map onto a valid
	# emitter record with the preset's blending.
	var rec := PBMapExporter._emitter_from_node(node)
	assert_eq(int(rec["count"]), node.amount)
	var flags := int(rec["flags"])
	assert_eq(flags & PBMapExporter.PBM_EMIT_ADDITIVE, PBMapExporter.PBM_EMIT_ADDITIVE,
		"Flame exports additive")
	assert_almost_eq(float(rec["spread"]), deg_to_rad(14.0), 0.001)
	assert_eq(int(rec["atlas_cols"]), 1)
	# Alpha ramp peak at 0.35 -> knee.
	assert_almost_eq(float(rec["knee"]), 0.35, 0.02)

	# Unlit + billboard material on the draw pass.
	var sm := (node.draw_pass_1 as QuadMesh).material as StandardMaterial3D
	assert_eq(sm.shading_mode, BaseMaterial3D.SHADING_MODE_UNSHADED)
	assert_eq(sm.billboard_mode, BaseMaterial3D.BILLBOARD_ENABLED)
	assert_eq(sm.blend_mode, BaseMaterial3D.BLEND_MODE_ADD)

func test_build_node_y_locked_preset_sets_meta_and_export_flag() -> void:
	var tex_path := "res://addons/poibuilder/materials/textures/particle_smoke.png"
	var tex: Texture2D = load(tex_path) if ResourceLoader.exists(tex_path) \
			else ImageTexture.create_from_image(Image.create(8, 8, false, Image.FORMAT_RGBA8))
	var values := PBParticleParams.preset_for_texture(tex_path)
	values["y_locked"] = true
	var node := PBParticleParams.build_node(tex, values, "Emitter_Smoke")
	autofree(node)
	assert_true(bool(node.get_meta("poi_y_locked")))
	var rec := PBMapExporter._emitter_from_node(node)
	assert_eq(int(rec["flags"]) & PBMapExporter.PBM_EMIT_Y_LOCKED, PBMapExporter.PBM_EMIT_Y_LOCKED)
	# Blended smoke exports WITHOUT the additive flag.
	assert_eq(int(rec["flags"]) & PBMapExporter.PBM_EMIT_ADDITIVE, 0)

func test_values_round_trip_through_apply() -> void:
	var tex := _flame_tex()
	var node := GPUParticles3D.new()
	autofree(node)
	node.name = "Emitter_RoundTrip"
	var values := PBParticleParams.preset_for_texture("flame")
	values["count"] = 40.0
	values["size"] = 0.75
	values["speed"] = 2.0
	values["lifetime"] = 1.5
	values["spread"] = 45.0
	values["rise"] = -0.5
	values["opacity"] = 0.7
	values["additive"] = 0.0
	PBParticleParams.apply_values(node, values, tex)

	var back := PBParticleParams.values_from_node(node)
	assert_eq(float(back["count"]), 40.0)
	assert_almost_eq(float(back["size"]), 0.75, 0.001)
	assert_almost_eq(float(back["speed"]), 2.0, 0.001)
	assert_almost_eq(float(back["lifetime"]), 1.5, 0.001)
	assert_almost_eq(float(back["spread"]), 45.0, 0.001)
	assert_almost_eq(float(back["rise"]), -0.5, 0.001)
	assert_almost_eq(float(back["opacity"]), 0.7, 0.001)
	assert_almost_eq(float(back["additive"]), 0.0, 0.001)

	var pm := node.process_material as ParticleProcessMaterial
	assert_almost_eq(pm.gravity.y, -0.5, 0.001)
	var sm := (node.draw_pass_1 as QuadMesh).material as StandardMaterial3D
	assert_eq(sm.blend_mode, BaseMaterial3D.BLEND_MODE_MIX, "additive=0 builds a blended emitter")

func test_apply_clamps_count_and_size_to_psp_caps() -> void:
	var node := GPUParticles3D.new()
	autofree(node)
	node.name = "Emitter_Caps"
	var values := PBParticleParams.preset_for_texture("glow")
	values["count"] = 999.0
	values["size"] = 50.0
	PBParticleParams.apply_values(node, values, null)
	assert_lte(node.amount, PBParticleParams.MAX_PER_EMITTER, "Count clamps to the format cap")
	var qm := node.draw_pass_1 as QuadMesh
	assert_lte(qm.size.y, PBParticleParams.MAX_QUAD_HEIGHT, "Size clamps to the fill-rate cap")

func test_placement_gesture_to_finalized_node() -> void:
	var placer := PBParticlePlacer.new()
	placer.scene_root_override = _root
	autofree(placer)
	var tex := _flame_tex()
	placer.last_texture = tex
	placer.last_values = PBParticleParams.preset_for_texture(tex.resource_path.get_file())
	placer.arm()
	assert_eq(placer.state, PBParticlePlacer.State.ARMED)

	var hit := {"point": Vector3(1, 0, 1), "normal": Vector3.UP}
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(400, 300)
	placer.handle_input(_camera, press, hit, _host)
	assert_eq(placer.state, PBParticlePlacer.State.ARMED, "State advances on RELEASE")

	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = Vector2(400, 300)
	placer.handle_input(_camera, release, hit, _host)
	assert_eq(placer.state, PBParticlePlacer.State.RAISE)
	assert_not_null(placer.preview_node, "Live GPUParticles3D preview exists")
	assert_eq(placer.preview_node.get_parent(), _root)

	# Mouse up lifts the emitter off the surface (0.012 m/px like sprites).
	var up := InputEventMouseMotion.new()
	up.position = Vector2(400, 250)
	up.relative = Vector2(0, -50)
	placer.handle_input(_camera, up, hit, _host)
	assert_almost_eq(placer.elevation, 0.6, 0.001)

	# Click locks the offset -> TUNE.
	var lock := InputEventMouseButton.new()
	lock.button_index = MOUSE_BUTTON_LEFT
	lock.pressed = true
	lock.position = Vector2(400, 250)
	placer.handle_input(_camera, lock, hit, _host)
	assert_eq(placer.state, PBParticlePlacer.State.TUNE)

	# Horizontal motion adjusts count within the format cap.
	var tune := InputEventMouseMotion.new()
	tune.position = Vector2(800, 250)
	placer.handle_input(_camera, tune, hit, _host)
	var tuned_count := placer.preview_node.amount
	assert_gt(tuned_count, int(placer.last_values.get("count", 16.0)), "Mouse right adds particles")
	assert_lte(tuned_count, PBParticleParams.MAX_PER_EMITTER)

	# Click commits; exactly one node lands and the signal fires.
	var placed: Array = []
	placer.emitter_placed.connect(func(n: GPUParticles3D): placed.append(n))
	var commit := InputEventMouseButton.new()
	commit.button_index = MOUSE_BUTTON_LEFT
	commit.pressed = true
	commit.position = Vector2(800, 250)
	placer.handle_input(_camera, commit, hit, _host)
	assert_eq(placed.size(), 1, "finalize commits exactly one emitter")
	assert_eq(placer.state, PBParticlePlacer.State.INACTIVE)
	var node: GPUParticles3D = placed[0]
	autofree(node)
	assert_true(node.is_inside_tree())
	assert_eq(node.amount, tuned_count, "Tuned count lands on the committed node")
	assert_almost_eq(node.position.y, 0.6, 0.001, "Raised offset lands on the committed node")

func test_esc_aborts_with_no_leftovers() -> void:
	var placer := PBParticlePlacer.new()
	placer.scene_root_override = _root
	autofree(placer)
	placer.last_texture = _flame_tex()
	placer.arm()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(400, 300)
	placer.handle_input(_camera, press, {"point": Vector3.ZERO, "normal": Vector3.UP}, _host)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = Vector2(400, 300)
	placer.handle_input(_camera, release, {"point": Vector3.ZERO, "normal": Vector3.UP}, _host)
	assert_eq(placer.state, PBParticlePlacer.State.RAISE)
	assert_not_null(placer.preview_node)

	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	placer.handle_input(_camera, esc, {}, _host)
	assert_eq(placer.state, PBParticlePlacer.State.INACTIVE)
	assert_null(placer.preview_node, "Preview node freed on Esc")

func test_budget_readout_flags_over_map_budget() -> void:
	# Fresh nodes per root: add_child on an already-parented node errors
	# instead of reparenting.
	var low_root := Node3D.new()
	add_child_autofree(low_root)
	var a := GPUParticles3D.new()
	a.amount = 100
	low_root.add_child(a)
	assert_eq(PBParticleParams.total_amount(low_root), 100)
	assert_false(PBParticleParams.budget_readout(low_root).contains("OVER"))

	var over_root := Node3D.new()
	add_child_autofree(over_root)
	var b := GPUParticles3D.new()
	b.amount = PBParticleParams.MAP_BUDGET - 99
	over_root.add_child(a.duplicate())
	over_root.add_child(b)
	assert_eq(PBParticleParams.total_amount(over_root), PBParticleParams.MAP_BUDGET + 1)
	assert_true(PBParticleParams.budget_readout(over_root).contains("OVER"),
		"Over-budget readout is flagged")

func test_param_defs_cover_budget_fields() -> void:
	var names := {}
	for def in PBParticleParams.get_param_defs():
		names[def["name"]] = def
	assert_has(names, "count")
	assert_has(names, "size")
	assert_has(names, "additive")
	assert_has(names, "y_locked")
	assert_eq(float(names["count"]["max"]), float(PBParticleParams.MAX_PER_EMITTER),
		"The properties modal cannot exceed the format cap")
	assert_eq(float(names["size"]["max"]), float(PBParticleParams.MAX_QUAD_HEIGHT))

func test_material_dock_particle_mode_filters_palette() -> void:
	var dock := PBMaterialDock.new()
	add_child_autofree(dock)
	var placer := PBParticlePlacer.new()
	autofree(placer)
	dock.particle_placer = placer

	dock._set_dock_mode(PBMaterialDock.DockMode.PARTICLE)
	assert_eq(dock.dock_mode, PBMaterialDock.DockMode.PARTICLE)
	assert_true(dock._particle_tool_section.visible)
	assert_false(dock._sprite_tool_section.visible)

	# The palette must contain ONLY particle-classified cards (flame/glow/
	# smoke textures exist in the addon); no sprites, stamps or paint tiles.
	var card_names: Array[String] = []
	for mat in dock._project_materials:
		if mat != null and mat.has_meta("source_texture_path"):
			var path := str(mat.get_meta("source_texture_path"))
			if PBAssetCatalog.classify_path(path) == "particle":
				card_names.append(path.get_file())
	assert_gt(card_names.size(), 0, "Shipped particle textures must be in the project scan")
	for name in card_names:
		assert_true(name.begins_with("particle_"), "Only particle textures listed")

	# The auto-select picks a particle texture (never falls back to a
	# non-particle material).
	if placer.last_texture != null:
		assert_true(PBAssetCatalog.classify_path(placer.last_texture.resource_path) == "particle",
			"Auto-selected emitter texture is particle-classified")

## The flipbook quad shows ONE cell of the sheet, so its width follows the
## CELL's aspect (tex_w/cols : tex_h/rows) — a square quad against a 1/3-wide
## cell stretched the art 3x, which is what "the columns make the particles
## stretch" was. The exporter reads the aspect off the QuadMesh, so the viewer
## and the device draw the same proportions.
func test_sheet_cells_size_the_quad_by_the_cell_aspect() -> void:
	# A 192x64 sheet with 3 columns is three square 64x64 cells.
	var sheet := ImageTexture.create_from_image(Image.create(192, 64, false, Image.FORMAT_RGBA8))
	var values := PBParticleParams.preset_for_texture("glow")
	values["size"] = 0.5
	values["atlas_cols"] = 3.0
	var node := PBParticleParams.build_node(sheet, values, "Emitter_Sheet")
	autofree(node)
	var qm := node.draw_pass_1 as QuadMesh
	assert_almost_eq(qm.size.y, 0.5, 0.001, "Sheet cell keeps the size knob as its height")
	assert_almost_eq(qm.size.x, 0.5, 0.001, "Square cells -> square quad (not 3x stretched)")
	var sm := qm.material as StandardMaterial3D
	assert_eq(sm.billboard_mode, BaseMaterial3D.BILLBOARD_PARTICLES, "The sheet grid lives in the particles mode")
	assert_eq(sm.particles_anim_h_frames, 3)
	assert_eq(sm.particles_anim_v_frames, 1)
	var rec := PBMapExporter._emitter_from_node(node)
	assert_eq(int(rec["atlas_cols"]), 3)
	assert_almost_eq(float(rec["aspect"]), 1.0, 0.001, "The cell aspect reaches the emitter record")

	# A 2:1 row of cells (128x32 with 2 columns -> 64x32 cells) is a wide quad.
	var wide := ImageTexture.create_from_image(Image.create(128, 32, false, Image.FORMAT_RGBA8))
	values["atlas_cols"] = 2.0
	var node_wide := PBParticleParams.build_node(wide, values, "Emitter_Wide")
	autofree(node_wide)
	var qm_wide := node_wide.draw_pass_1 as QuadMesh
	assert_almost_eq(qm_wide.size.y, 0.5, 0.001)
	assert_almost_eq(qm_wide.size.x, 1.0, 0.001, "64x32 cells are 2:1 wide")
	assert_almost_eq(float(PBMapExporter._emitter_from_node(node_wide)["aspect"]), 2.0, 0.001)

	# Rows: a 64x192 sheet with 3 rows is three square cells again.
	var tall := ImageTexture.create_from_image(Image.create(64, 192, false, Image.FORMAT_RGBA8))
	values["atlas_cols"] = 1.0
	values["atlas_rows"] = 3.0
	var node_tall := PBParticleParams.build_node(tall, values, "Emitter_Tall")
	autofree(node_tall)
	var qm_tall := node_tall.draw_pass_1 as QuadMesh
	assert_almost_eq(qm_tall.size.x, 0.5, 0.001, "3 square rows -> square quad")
	assert_eq((qm_tall.material as StandardMaterial3D).particles_anim_v_frames, 3)

	# A single-frame texture keeps its own aspect (no sheet knobs touched).
	var banner := ImageTexture.create_from_image(Image.create(128, 64, false, Image.FORMAT_RGBA8))
	values["atlas_rows"] = 1.0
	var node_banner := PBParticleParams.build_node(banner, values, "Emitter_Banner")
	autofree(node_banner)
	var qm_banner := node_banner.draw_pass_1 as QuadMesh
	assert_almost_eq(qm_banner.size.y, 0.5, 0.001)
	assert_almost_eq(qm_banner.size.x, 1.0, 0.001, "A 2:1 image is a 2:1 particle, not squished square")
	assert_eq((qm_banner.material as StandardMaterial3D).billboard_mode,
			BaseMaterial3D.BILLBOARD_ENABLED, "A single frame is not a flipbook")

	# The properties modal round-trips the height, not the (frame-dependent) width.
	var back := PBParticleParams.values_from_node(node_wide)
	assert_almost_eq(float(back["size"]), 0.5, 0.001)
	assert_almost_eq(float(back["atlas_cols"]), 2.0, 0.001)

## The sheet knobs are the one emitter feature a preview cannot explain, so the
## properties modal states what they currently select (the cell size and the
## cycle) instead of leaving the user to guess why a non-sheet texture comes out
## in slices.
func test_sheet_readout_teaches_the_knobs() -> void:
	var sheet := ImageTexture.create_from_image(Image.create(192, 64, false, Image.FORMAT_RGBA8))
	var line := PBParticleParams.sheet_readout(sheet, {"atlas_cols": 3.0, "atlas_rows": 1.0})
	assert_true(line.contains("64 x 64"), "Three cells of a 192x64 sheet are 64x64 px: %s" % line)
	assert_true(line.contains("3 frames"), "The frame count is stated: %s" % line)
	assert_true(line.contains("one cycle per lifetime"), "The cycle is stated: %s" % line)

	var single := PBParticleParams.sheet_readout(sheet, {"atlas_cols": 1.0, "atlas_rows": 1.0})
	assert_true(single.contains("One frame"), "A single frame says so: %s" % single)
	assert_true(single.contains("192 x 64"), "…and names the image: %s" % single)

	assert_eq(PBParticleParams.sheet_readout(null, {}), "",
		"Without a texture there is nothing to say")

## The shipped SHEETS: the flipbook knobs need art that is actually a sheet, so
## the addon carries a 4-cell flame and smoke sheet and picking one arms the
## knobs for it (a single-frame texture under a >1 column is just the image
## sampled in slices — the "why is my glow cut into squares" report).
func test_shipped_particle_sheets_arm_the_flipbook() -> void:
	for file: String in ["particle_flame_sheet.png", "particle_smoke_sheet.png"]:
		var path := "res://addons/poibuilder/materials/textures/" + file
		assert_true(ResourceLoader.exists(path), "The shipped sheet %s must exist" % file)
		assert_eq(PBAssetCatalog.classify_path(path), "particle",
			"%s must land in the Particles palette" % file)
		var tex: Texture2D = load(path)
		assert_not_null(tex)
		assert_eq(tex.get_width(), tex.get_height() * 4,
			"%s must be four square cells in a row" % file)

		var values := PBParticleParams.preset_for_texture(file)
		assert_eq(float(values.get("atlas_cols", 0.0)), 4.0,
			"Picking %s arms Sheet Columns = 4" % file)
		assert_eq(float(values.get("atlas_rows", 0.0)), 1.0)
		var node := PBParticleParams.build_node(tex, values, "Sheet_Emitter")
		autofree(node)
		var qm := node.draw_pass_1 as QuadMesh
		var sm := qm.material as StandardMaterial3D
		assert_eq(sm.billboard_mode, BaseMaterial3D.BILLBOARD_PARTICLES,
			"A sheet builds a real flipbook")
		assert_eq(sm.particles_anim_h_frames, 4)
		# Square cells -> a square quad (the cell aspect, not the image's 4:1).
		assert_almost_eq(qm.size.x, qm.size.y, 0.001,
			"Four square cells keep the quad square, not 4:1")

	# A single-frame texture is untouched by the sheet rule.
	var single := PBParticleParams.preset_for_texture("particle_glow.png")
	assert_eq(float(single.get("atlas_cols", 1.0)), 1.0,
		"A single-frame texture stays one frame")
