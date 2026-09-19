## Unit tests for PBEnvironment presets and scene application
extends GutTest

func test_presets_exist_and_have_required_fields() -> void:
	var names := PBEnvironment.get_preset_names()
	assert_eq(names.size(), 4, "Must have 4 presets (dawn, day, dusk, night)")
	assert_true("dawn" in names)
	assert_true("day" in names)
	assert_true("dusk" in names)
	assert_true("night" in names)

	for p_name in names:
		var p := PBEnvironment.get_preset(p_name)
		assert_true(p.has("sun_yaw"), "Preset %s must have sun_yaw" % p_name)
		assert_true(p.has("sun_pitch"), "Preset %s must have sun_pitch" % p_name)
		assert_true(p.has("sun_color"), "Preset %s must have sun_color" % p_name)
		assert_true(p.has("sun_energy"), "Preset %s must have sun_energy" % p_name)
		assert_true(p.has("ambient_color"), "Preset %s must have ambient_color" % p_name)
		assert_true(p.has("fog_color"), "Preset %s must have fog_color" % p_name)
		assert_true(p.has("sky_top"), "Preset %s must have sky_top" % p_name)
		assert_true(p.has("sky_horizon"), "Preset %s must have sky_horizon" % p_name)
		assert_true(p.has("psp_clear_bgr"), "Preset %s must have psp_clear_bgr" % p_name)

func test_sun_direction_math() -> void:
	# Day: yaw 55, pitch 50 -> pointing from North-East / Up towards South-West / Down
	var dir_day := PBEnvironment.get_sun_direction("day")
	assert_gt(dir_day.y, 0.0, "Day sun direction Y must be positive (light comes from above)")
	assert_almost_eq(dir_day.length(), 1.0, 0.001, "Sun direction vector must be normalized")

	# Dawn: pitch 12 (grazing angle)
	var dir_dawn := PBEnvironment.get_sun_direction("dawn")
	assert_gt(dir_dawn.y, 0.0, "Dawn sun Y must be positive")
	assert_lt(dir_dawn.y, dir_day.y, "Dawn sun pitch must be lower than Day sun pitch")

	# Dusk: yaw 250 (setting in West)
	var dir_dusk := PBEnvironment.get_sun_direction("dusk")
	assert_lt(dir_dusk.x, 0.0, "Dusk sun X must point towards West (-X)")

	# Night: moonlight
	var dir_night := PBEnvironment.get_sun_direction("night")
	assert_gt(dir_night.y, dir_day.y, "Night moon pitch (70 deg) must be higher than Day sun pitch")

func test_apply_preset_to_scene() -> void:
	var root := Node3D.new()
	add_child_autofree(root)

	# Apply Dawn preset
	var res := PBEnvironment.apply_preset(root, "dawn")
	assert_not_null(res.get("world_env"), "Must create/find WorldEnvironment")
	assert_not_null(res.get("sun"), "Must create/find Sun DirectionalLight3D")
	assert_eq(res.get("preset"), "dawn")
	assert_eq(root.get_meta("poi_env_preset"), "dawn")

	var env: Environment = res["world_env"].environment
	assert_not_null(env)
	assert_not_null(env.sky)
	assert_true(env.sky.sky_material is ProceduralSkyMaterial)
	var sky_mat := env.sky.sky_material as ProceduralSkyMaterial
	var dawn_p := PBEnvironment.get_preset("dawn")
	assert_eq(sky_mat.sky_top_color, dawn_p["sky_top"])
	assert_eq(sky_mat.sky_horizon_color, dawn_p["sky_horizon"])

	var sun: DirectionalLight3D = res["sun"]
	assert_eq(sun.light_color, dawn_p["sun_color"])
	assert_almost_eq(sun.light_energy, dawn_p["sun_energy"], 0.01)

	# Switch to Night preset on the same root
	var res_night := PBEnvironment.apply_preset(root, "night")
	assert_eq(res_night.get("preset"), "night")
	assert_eq(root.get_meta("poi_env_preset"), "night")
	var night_p := PBEnvironment.get_preset("night")
	assert_eq(sky_mat.sky_top_color, night_p["sky_top"])
	assert_eq(sun.light_color, night_p["sun_color"])
	assert_almost_eq(sun.light_energy, night_p["sun_energy"], 0.01)


## The baked-map display contract: sky + linear fog, ZERO added lighting.
## A fully baked map carries every lumen in its vertex colors — a consumer
## that applied the live preset on top would double-light it (and drift from
## what the PSP draws).
func test_apply_retro_display_adds_no_lighting() -> void:
	var root := Node3D.new()
	autofree(root)
	PBEnvironment.apply_retro_display(root, "dusk")

	assert_eq(root.get_meta("poi_env_preset", ""), "",
			"Retro display must not restamp the authoring preset meta")
	var world_env := PBEnvironment.find_world_environment(root)
	assert_not_null(world_env, "Must create a WorldEnvironment")
	if world_env == null:
		return
	var env: Environment = world_env.environment
	assert_not_null(env)
	assert_true(env.fog_enabled, "The preset's linear fog must be on")
	assert_eq(env.fog_mode, Environment.FOG_MODE_DEPTH, "Fog must be the PSP's linear depth ramp")
	var dusk_p := PBEnvironment.get_preset("dusk")
	assert_almost_eq(env.fog_depth_begin, dusk_p["fog_start"], 0.01, "Fog near must match the PSP table")
	assert_almost_eq(env.fog_depth_end, dusk_p["fog_end"], 0.01, "Fog far must match the PSP table")
	assert_eq(env.fog_light_color, dusk_p["fog_color"])
	assert_eq(env.ambient_light_source, Environment.AMBIENT_SOURCE_COLOR)
	assert_eq(env.ambient_light_color, Color.BLACK, "The display env must add no ambient")
	assert_eq(env.reflected_light_source, Environment.REFLECTION_SOURCE_DISABLED,
			"Sky reflections must be off — the PSP has none")
	assert_eq(env.tonemap_mode, Environment.TONE_MAPPER_LINEAR,
			"The bake already decided the colors; no tonemap may re-decide them")
	var sky_mat := env.sky.sky_material as ProceduralSkyMaterial
	assert_not_null(sky_mat, "The preset sky must be present")
	if sky_mat != null:
		assert_eq(sky_mat.sky_top_color, dusk_p["sky_top"])
