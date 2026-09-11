## PBEnvironment — Time-of-day environment and lighting presets for PoiBuilder.
##
## Inspired by dioramap lighting presets, providing a 1-button way to switch a scene
## between Dawn, Day, Dusk, and Night. Configures WorldEnvironment (procedural sky,
## ambient light, and fog) and DirectionalLight3D (sun angle, color, and intensity).
@tool
class_name PBEnvironment
extends RefCounted

## Environment preset data definitions.
const PRESETS: Dictionary = {
	"dawn": {
		"name": "Dawn",
		"label": "🌅 Dawn",
		"sun_yaw": 80.0,
		"sun_pitch": 12.0,
		"sun_color": Color(1.0, 0.667, 0.431), # 255, 170, 110 warm sunrise
		"sun_energy": 0.95,
		"ambient_sky": Color(0.627, 0.549, 0.745), # 160, 140, 190
		"ambient_ground": Color(0.275, 0.196, 0.176), # 70, 50, 45
		"ambient_color": Color(0.345, 0.302, 0.410),
		"ambient_energy": 0.55,
		"fog_color": Color(0.157, 0.125, 0.149), # 40, 32, 38
		"fog_density": 0.012,
		"fog_start": 16.0,
		"fog_end": 52.0,
		"sky_top": Color(0.35, 0.38, 0.55, 1.0),
		"sky_horizon": Color(0.85, 0.55, 0.40, 1.0),
		"ground_bottom": Color(0.15, 0.12, 0.14, 1.0),
		"ground_horizon": Color(0.45, 0.32, 0.30, 1.0),
		"psp_clear_bgr": 0x262028, # BGR for PSP framebuffer
	},
	"day": {
		"name": "Day",
		"label": "☀️ Day",
		"sun_yaw": 55.0,
		"sun_pitch": 50.0,
		"sun_color": Color(1.0, 0.961, 0.863), # 255, 245, 220 warm white
		"sun_energy": 1.25,
		"ambient_sky": Color(0.431, 0.510, 0.627), # 110, 130, 160
		"ambient_ground": Color(0.176, 0.196, 0.235), # 45, 50, 60
		"ambient_color": Color(0.280, 0.332, 0.408),
		"ambient_energy": 0.65,
		"fog_color": Color(0.094, 0.094, 0.110), # 24, 24, 28
		"fog_density": 0.006,
		"fog_start": 22.0,
		"fog_end": 65.0,
		"sky_top": Color(0.35, 0.48, 0.68, 1.0),
		"sky_horizon": Color(0.68, 0.76, 0.82, 1.0),
		"ground_bottom": Color(0.15, 0.16, 0.18, 1.0),
		"ground_horizon": Color(0.55, 0.60, 0.65, 1.0),
		"psp_clear_bgr": 0x382218,
	},
	"dusk": {
		"name": "Dusk",
		"label": "🌇 Dusk",
		"sun_yaw": 250.0,
		"sun_pitch": 8.0,
		"sun_color": Color(1.0, 0.471, 0.235), # 255, 120, 60 fiery amber
		"sun_energy": 0.90,
		"ambient_sky": Color(0.314, 0.275, 0.471), # 80, 70, 120
		"ambient_ground": Color(0.196, 0.137, 0.157), # 50, 35, 40
		"ambient_color": Color(0.157, 0.138, 0.235),
		"ambient_energy": 0.50,
		"fog_color": Color(0.141, 0.094, 0.110), # 36, 24, 28
		"fog_density": 0.015,
		"fog_start": 14.0,
		"fog_end": 48.0,
		"sky_top": Color(0.20, 0.18, 0.38, 1.0),
		"sky_horizon": Color(0.88, 0.42, 0.20, 1.0),
		"ground_bottom": Color(0.12, 0.10, 0.12, 1.0),
		"ground_horizon": Color(0.35, 0.22, 0.20, 1.0),
		"psp_clear_bgr": 0x1C1824,
	},
	"night": {
		"name": "Night",
		"label": "🌙 Night",
		"sun_yaw": 200.0,
		"sun_pitch": 70.0,
		"sun_color": Color(0.706, 0.784, 1.0), # 180, 200, 255 cool moonlight
		"sun_energy": 0.35,
		"ambient_sky": Color(0.078, 0.110, 0.196), # 20, 28, 50
		"ambient_ground": Color(0.047, 0.055, 0.086), # 12, 14, 22
		"ambient_color": Color(0.031, 0.044, 0.078),
		"ambient_energy": 0.35,
		"fog_color": Color(0.031, 0.039, 0.063), # 8, 10, 16
		"fog_density": 0.022,
		"fog_start": 10.0,
		"fog_end": 40.0,
		"sky_top": Color(0.04, 0.06, 0.12, 1.0),
		"sky_horizon": Color(0.08, 0.12, 0.22, 1.0),
		"ground_bottom": Color(0.02, 0.03, 0.05, 1.0),
		"ground_horizon": Color(0.05, 0.07, 0.12, 1.0),
		"psp_clear_bgr": 0x100A08,
	},
}

## Returns the list of available preset keys in standard progression order.
static func get_preset_names() -> Array[String]:
	return ["dawn", "day", "dusk", "night"]

## Returns the preset definition dictionary for a given name, defaulting to "day".
static func get_preset(name: String) -> Dictionary:
	var key := name.to_lower().strip_edges()
	if PRESETS.has(key):
		return PRESETS[key]
	return PRESETS["day"]

## Computes the normalized 3D direction pointing TO the sun (light ray comes from this direction).
static func get_sun_direction(preset_name: String) -> Vector3:
	var p := get_preset(preset_name)
	var yaw_rad: float = deg_to_rad(float(p.get("sun_yaw", 55.0)))
	var pitch_rad: float = deg_to_rad(float(p.get("sun_pitch", 50.0)))
	var cos_p := cos(pitch_rad)
	var sin_p := sin(pitch_rad)
	var to_sun := Vector3(sin(yaw_rad) * cos_p, sin_p, cos(yaw_rad) * cos_p).normalized()
	return to_sun

## Finds the first WorldEnvironment node in the scene tree under root.
static func find_world_environment(root: Node) -> WorldEnvironment:
	if root == null:
		return null
	if root is WorldEnvironment:
		return root as WorldEnvironment
	for child in root.get_children():
		if child is WorldEnvironment:
			return child as WorldEnvironment
	for child in root.get_children():
		var found := find_world_environment(child)
		if found != null:
			return found
	return null

## Finds the first DirectionalLight3D in the scene tree under root (preferring one named "Sun").
static func find_sun(root: Node) -> DirectionalLight3D:
	if root == null:
		return null
	if root is DirectionalLight3D:
		return root as DirectionalLight3D
	# Pass 1: exact name check
	for child in root.get_children():
		if child is DirectionalLight3D and (child.name == "Sun" or child.name == "DirectionalLight3D"):
			return child as DirectionalLight3D
	# Pass 2: any child DirectionalLight3D
	for child in root.get_children():
		if child is DirectionalLight3D:
			return child as DirectionalLight3D
	# Pass 3: recursive
	for child in root.get_children():
		var found := find_sun(child)
		if found != null:
			return found
	return null

## Applies the given preset configuration onto an existing Environment resource.
static func apply_to_environment(env: Environment, preset_name: String) -> void:
	if env == null:
		return
	var p := get_preset(preset_name)
	env.background_mode = Environment.BG_SKY

	var sky := env.sky
	if sky == null:
		sky = Sky.new()
		env.sky = sky
	var sky_mat := sky.sky_material as ProceduralSkyMaterial
	if sky_mat == null:
		sky_mat = ProceduralSkyMaterial.new()
		sky.sky_material = sky_mat

	sky_mat.sky_top_color = p["sky_top"]
	sky_mat.sky_horizon_color = p["sky_horizon"]
	sky_mat.ground_bottom_color = p["ground_bottom"]
	sky_mat.ground_horizon_color = p["ground_horizon"]
	sky_mat.sun_angle_max = 30.0

	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_color = p["ambient_color"]
	env.ambient_light_sky_contribution = 0.5
	env.ambient_light_energy = p["ambient_energy"]

	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	# Volumetric/depth fog
	env.fog_enabled = true
	env.fog_light_color = p["fog_color"]
	env.fog_density = p["fog_density"]
	env.fog_sky_affect = 0.4

## Applies the given preset configuration onto a DirectionalLight3D.
static func apply_to_sun(sun: DirectionalLight3D, preset_name: String) -> void:
	if sun == null:
		return
	var p := get_preset(preset_name)
	var to_sun := get_sun_direction(preset_name)
	# DirectionalLight3D shines along -Z. Looking at -to_sun points -Z in direction of incoming light.
	var pos := sun.global_position if sun.is_inside_tree() else sun.position
	if pos == Vector3.ZERO:
		pos = Vector3(0, 15, 0)
	sun.transform = Transform3D(Basis.looking_at(-to_sun, Vector3.UP), pos)
	sun.light_color = p["sun_color"]
	sun.light_energy = p["sun_energy"]
	sun.shadow_enabled = true

## Applies the preset to a scene root, finding or creating WorldEnvironment and Sun nodes.
## Returns a Dictionary with {"world_env": WorldEnvironment, "sun": DirectionalLight3D, "preset": String}.
## If an EditorUndoRedoManager is provided, records the operation with clean Undo/Redo.
static func apply_preset(root: Node3D, preset_name: String, undo_redo = null) -> Dictionary:
	var p := get_preset(preset_name)
	var norm_name: String = p["name"].to_lower()

	var world_env := find_world_environment(root)
	var created_env := false
	if world_env == null:
		world_env = WorldEnvironment.new()
		world_env.name = "WorldEnvironment"
		world_env.environment = Environment.new()
		root.add_child(world_env)
		if Engine.is_editor_hint():
			world_env.owner = root
		created_env = true
	elif world_env.environment == null:
		world_env.environment = Environment.new()

	var sun := find_sun(root)
	var created_sun := false
	if sun == null:
		sun = DirectionalLight3D.new()
		sun.name = "Sun"
		sun.position = Vector3(0, 15, 0)
		root.add_child(sun)
		if Engine.is_editor_hint():
			sun.owner = root
		created_sun = true

	# Capture previous state for Undo if requested
	var prev_preset: String = root.get_meta("poi_env_preset", "day")
	var prev_sun_xf := sun.transform
	var prev_sun_color := sun.light_color
	var prev_sun_energy := sun.light_energy
	var prev_sun_shadow := sun.shadow_enabled

	var prev_env_bg := world_env.environment.background_mode
	var prev_env_amb_source := world_env.environment.ambient_light_source
	var prev_env_amb_color := world_env.environment.ambient_light_color
	var prev_env_amb_energy := world_env.environment.ambient_light_energy
	var prev_env_fog := world_env.environment.fog_enabled
	var prev_env_fog_color := world_env.environment.fog_light_color
	var prev_env_fog_density := world_env.environment.fog_density

	var sky := world_env.environment.sky
	var sky_mat := sky.sky_material as ProceduralSkyMaterial if sky != null else null
	var prev_sky_top := sky_mat.sky_top_color if sky_mat != null else Color(0.35, 0.45, 0.6)
	var prev_sky_hor := sky_mat.sky_horizon_color if sky_mat != null else Color(0.65, 0.7, 0.75)
	var prev_gnd_bot := sky_mat.ground_bottom_color if sky_mat != null else Color(0.15, 0.15, 0.18)
	var prev_gnd_hor := sky_mat.ground_horizon_color if sky_mat != null else Color(0.65, 0.7, 0.75)

	# Apply changes
	apply_to_environment(world_env.environment, norm_name)
	apply_to_sun(sun, norm_name)
	root.set_meta("poi_env_preset", norm_name)

	# Handle UndoRedo
	if undo_redo != null:
		undo_redo.create_action("Apply Environment Preset: " + norm_name.capitalize(), UndoRedo.MERGE_DISABLE, root)
		# Do: apply target preset
		undo_redo.add_do_method(PBEnvironment, "apply_to_environment", world_env.environment, norm_name)
		undo_redo.add_do_method(PBEnvironment, "apply_to_sun", sun, norm_name)
		undo_redo.add_do_method(root, "set_meta", "poi_env_preset", norm_name)

		var snapshot := {
			"env_bg": prev_env_bg,
			"env_amb_source": prev_env_amb_source,
			"env_amb_color": prev_env_amb_color,
			"env_amb_energy": prev_env_amb_energy,
			"env_fog": prev_env_fog,
			"env_fog_color": prev_env_fog_color,
			"env_fog_density": prev_env_fog_density,
			"sky_top": prev_sky_top,
			"sky_hor": prev_sky_hor,
			"gnd_bot": prev_gnd_bot,
			"gnd_hor": prev_gnd_hor,
			"sun_xf": prev_sun_xf,
			"sun_color": prev_sun_color,
			"sun_energy": prev_sun_energy,
			"sun_shadow": prev_sun_shadow,
			"preset": prev_preset,
		}
		undo_redo.add_undo_method(PBEnvironment, "restore_snapshot", world_env, sun, root, snapshot)
		if created_env:
			undo_redo.add_do_reference(world_env)
		if created_sun:
			undo_redo.add_do_reference(sun)
		undo_redo.commit_action()

	return {
		"world_env": world_env,
		"sun": sun,
		"preset": norm_name,
	}
## Restores a previously captured snapshot of environment and sun state.
static func restore_snapshot(world_env: WorldEnvironment, sun: DirectionalLight3D, root: Node3D, snapshot: Dictionary) -> void:
	if world_env != null and world_env.environment != null:
		world_env.environment.background_mode = snapshot.get("env_bg", Environment.BG_SKY)
		world_env.environment.ambient_light_source = snapshot.get("env_amb_source", Environment.AMBIENT_SOURCE_SKY)
		world_env.environment.ambient_light_color = snapshot.get("env_amb_color", Color.WHITE)
		world_env.environment.ambient_light_energy = snapshot.get("env_amb_energy", 1.0)
		world_env.environment.fog_enabled = snapshot.get("env_fog", false)
		world_env.environment.fog_light_color = snapshot.get("env_fog_color", Color.WHITE)
		world_env.environment.fog_density = snapshot.get("env_fog_density", 0.01)
		var s := world_env.environment.sky
		if s != null and s.sky_material is ProceduralSkyMaterial:
			var sm := s.sky_material as ProceduralSkyMaterial
			sm.sky_top_color = snapshot.get("sky_top", Color.WHITE)
			sm.sky_horizon_color = snapshot.get("sky_hor", Color.WHITE)
			sm.ground_bottom_color = snapshot.get("gnd_bot", Color.WHITE)
			sm.ground_horizon_color = snapshot.get("gnd_hor", Color.WHITE)
	if sun != null:
		sun.transform = snapshot.get("sun_xf", Transform3D.IDENTITY)
		sun.light_color = snapshot.get("sun_color", Color.WHITE)
		sun.light_energy = snapshot.get("sun_energy", 1.0)
		sun.shadow_enabled = snapshot.get("sun_shadow", true)
	if root != null and is_instance_valid(root):
		root.set_meta("poi_env_preset", snapshot.get("preset", "day"))
