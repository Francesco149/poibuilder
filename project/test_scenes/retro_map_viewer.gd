## RetroMapViewer — Standalone viewer and smoke test renderer for baked retro map exports.
##
## Features a Godot-style free camera (WASD + mouse look), real-time scene statistics,
## and multiple inspection display modes:
## [1] Full Baked (Textures + Vertex Color Lighting)
## [2] Vertex Colors Only (Inspects direct lighting, shadows, and AO)
## [3] Textures Only (Unshaded, inspects tile baking and stamp blending)
## [4] Wireframe Mode (Inspects grid-aligned quad subdivision)
extends Node3D

enum DisplayMode {
	FULL_BAKED = 1,
	VERTEX_COLORS_ONLY = 2,
	TEXTURES_ONLY = 3,
	WIREFRAME = 4,
	COLLIDERS_ONLY = 5,
}

enum WireframeStyle {
	DARK_SLATE = 0,
	VERTEX_LIGHT = 1,
	TEXTURES = 2,
}

@export var default_map_path: String = "res://exports/showcase_retro_baked.glb"
var current_preset: String = "day"
var _env_buttons: Dictionary = {}

var current_mode: DisplayMode = DisplayMode.FULL_BAKED
var wireframe_style: WireframeStyle = WireframeStyle.DARK_SLATE
var wireframe_color: Color = Color(0.2, 0.9, 1.0) # Vibrant PoiBuilder Cyan
var wireframe_mesh_instances: Array[MeshInstance3D] = []
var collider_wireframe_instances: Array[MeshInstance3D] = []
var _wireframe_material: ShaderMaterial
var _collider_wireframe_material: ShaderMaterial
var _collider_fill_material: StandardMaterial3D

# Play Mode properties
var is_play_mode: bool = false
var player: CharacterBody3D = null
var player_cam: Camera3D = null
var player_pitch: float = 0.0
var physics_world: Node3D = null
var spawn_point: Vector3 = Vector3(0, 3, 0)
var btn_play_toggle: Button
var move_speed: float = 8.0
var boost_multiplier: float = 3.0
var mouse_sensitivity: float = 0.003
var mouse_captured: bool = false
var yaw: float = 0.0
var pitch: float = 0.0

# Stats
var total_vertices: int = 0
var total_triangles: int = 0
var total_surfaces: int = 0
var loaded_mesh_instances: Array[MeshInstance3D] = []
var original_materials: Dictionary = {} # MeshInstance3D -> Array[Material]

## Animated (scrolling) surfaces of the loaded map, as
## {mi, surface, speed, base_offset}: the exporter writes a material's
## poi_uv_scroll into the GLB material `extras`, and the viewer replays the
## same linear texture-coordinate shift the retro engines apply, so the Godot
## preview shows what the PSP will show.
var animated_surfaces: Array[Dictionary] = []
## Particle emitter previews: { mi, rec, parts } per authored emitter. The
## preview plays the emitters with the SAME semantics the format defines for the
## runtime (closed-form looping particles), so an author sees the real effect
## without a device in the loop.
var emitter_previews: Array[Dictionary] = []
var _emit_time: float = 0.0
var _scroll_time: float = 0.0
## When >= 0 the animation is pinned to this scene time instead of advancing.
## Two screenshots at different --scroll_time values with one fixed camera are
## then a deterministic A/B of the animation alone (used to check the scroll
## DIRECTION against the PSP build, which is easy to get backwards).
var _scroll_freeze: float = -1.0

@onready var camera: Camera3D = $Camera3D
@onready var map_container: Node3D = $MapContainer
@onready var hud: Control = $CanvasLayer/HUD
@onready var lbl_stats: Label = $CanvasLayer/HUD/VBox/StatsLabel
@onready var lbl_mode: Label = $CanvasLayer/HUD/VBox/ModeLabel
@onready var txt_load_path: LineEdit = $CanvasLayer/HUD/VBox/LoadBar/PathEdit
@onready var btn_load: Button = $CanvasLayer/HUD/VBox/LoadBar/LoadButton

func _ready() -> void:
	# Options may be passed either way round: Godot keeps the arguments after a
	# bare `--` out of get_cmdline_args() and puts them in get_cmdline_user_args()
	# (which is how the documented invocations here are written), so parse both.
	var cli_args := OS.get_cmdline_args()
	cli_args.append_array(OS.get_cmdline_user_args())

	# Parse command line args for --map=...
	var target_preset := ""
	for arg in cli_args:
		if arg.begins_with("--preset="):
			target_preset = arg.trim_prefix("--preset=").to_lower()
		elif arg.to_lower() in ["dawn", "day", "dusk", "night"]:
			target_preset = arg.to_lower()
	if target_preset != "":
		current_preset = target_preset
	var map_to_load := default_map_path
	for arg in cli_args:
		if arg.begins_with("--map="):
			map_to_load = arg.trim_prefix("--map=")
		elif arg.ends_with(".glb") or arg.ends_with(".gltf"):
			map_to_load = arg

	txt_load_path.text = map_to_load
	btn_load.pressed.connect(func(): load_map(txt_load_path.text))

	# Play Mode toggle button in HUD
	btn_play_toggle = Button.new()
	btn_play_toggle.name = "PlayToggleButton"
	btn_play_toggle.text = "▶ Play Mode (P)"
	btn_play_toggle.tooltip_text = "Toggle First-Person Play Mode (P) to test colliders with physical character"
	btn_play_toggle.pressed.connect(toggle_play_mode)
	var load_bar: HBoxContainer = get_node_or_null("CanvasLayer/HUD/VBox/LoadBar")
	if load_bar != null:
		load_bar.add_child(btn_play_toggle)
	pitch = camera.rotation.x

	# Auto-capture mouse on click in viewport
	_capture_mouse(true)
	get_viewport().msaa_3d = Viewport.MSAA_4X
	# Look for preset-specific baked map if target_preset was specified
	if target_preset != "" and map_to_load == default_map_path:
		var preset_candidates := [
			"res://exports/showcase_retro_baked_%s.glb" % target_preset,
			"res://test_scenes/showcase_retro_baked_%s.glb" % target_preset,
		]
		for c in preset_candidates:
			if FileAccess.file_exists(c):
				map_to_load = c
				break

	if not FileAccess.file_exists(map_to_load):
		for candidate in ["res://exports/showcase_retro_baked.glb", "res://exports/exported_map.glb", "res://test_scenes/showcase_retro_baked.glb"]:
			if FileAccess.file_exists(candidate):
				map_to_load = candidate
				break
	if FileAccess.file_exists(map_to_load):
		load_map(map_to_load)
	else:
		lbl_stats.text = "Map file not found: %s\nUse 'Browse / Load' to select a .glb file." % map_to_load

	# Time of Day buttons in HUD
	var env_bar := HBoxContainer.new()
	env_bar.name = "EnvBar"
	env_bar.add_theme_constant_override("separation", 6)
	var env_lbl := Label.new()
	env_lbl.text = "Time of Day (6):"
	env_lbl.add_theme_font_size_override("font_size", 13)
	env_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	env_bar.add_child(env_lbl)

	for p_name in PBEnvironment.get_preset_names():
		var p: Dictionary = PBEnvironment.get_preset(p_name)
		var btn := Button.new()
		btn.name = "BtnEnv_" + p_name.capitalize()
		btn.text = p.get("label", p_name.capitalize())
		btn.tooltip_text = "Apply %s environment preset" % p.get("name", p_name)
		btn.pressed.connect(func(): set_environment_preset(p_name))
		env_bar.add_child(btn)
		_env_buttons[p_name] = btn
	var vbox: VBoxContainer = get_node_or_null("CanvasLayer/HUD/VBox")
	if vbox != null:
		vbox.add_child(env_bar)

	set_environment_preset(current_preset, false)

	var shot_mode := 1
	for arg in cli_args:
		if arg.begins_with("--mode="):
			shot_mode = int(arg.trim_prefix("--mode="))
		elif arg.begins_with("--wire_style="):
			var s_val := int(arg.trim_prefix("--wire_style="))
			wireframe_style = (clampi(s_val, 0, 2)) as WireframeStyle
		elif arg.begins_with("--scroll_time="):
			_scroll_freeze = float(arg.trim_prefix("--scroll_time="))
		elif arg.begins_with("--wire_color="):
			var col_str := arg.trim_prefix("--wire_color=")
			wireframe_color = Color.from_string(col_str, Color(0.2, 0.9, 1.0))
			if _wireframe_material != null:
				_wireframe_material.set_shader_parameter("line_color", wireframe_color)
	var cam_pos := Vector3(2.5, 4.0, 5.0)
	var cam_look := Vector3(-1.5, 1.5, -1.5)
	for arg in cli_args:
		if arg.begins_with("--cam_pos="):
			var parts := arg.trim_prefix("--cam_pos=").split(",")
			if parts.size() == 3:
				cam_pos = Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
		elif arg.begins_with("--cam_look="):
			var parts := arg.trim_prefix("--cam_look=").split(",")
			if parts.size() == 3:
				cam_look = Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
	for arg in cli_args:
		if arg == "--play" or arg == "--play=1":
			enter_play_mode()
		elif arg.begins_with("--screenshot="):
			var shot_path := arg.trim_prefix("--screenshot=")
			camera.global_position = cam_pos
			camera.look_at(cam_look, Vector3.UP)
			set_display_mode(shot_mode as DisplayMode)
			if is_play_mode and player != null:
				player.global_position = cam_pos
			_take_screenshot_and_quit(shot_path)
			return
func _take_screenshot_and_quit(shot_path: String) -> void:
	for i in range(5):
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	if img != null:
		img.save_png(shot_path)
		print("Saved screenshot to: ", shot_path)
	get_tree().quit(0)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and not mouse_captured:
			_capture_mouse(true)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			move_speed = clampf(move_speed * 1.15, 1.0, 50.0)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			move_speed = clampf(move_speed * 0.85, 1.0, 50.0)

	elif event is InputEventMouseMotion and mouse_captured:
		var mm := event as InputEventMouseMotion
		if is_play_mode and player != null and is_instance_valid(player):
			player.rotate_y(-mm.relative.x * mouse_sensitivity)
			player_pitch = clampf(player_pitch - mm.relative.y * mouse_sensitivity, -1.45, 1.45)
			player_cam.rotation.x = player_pitch
		else:
			yaw -= mm.relative.x * mouse_sensitivity
			pitch = clampf(pitch - mm.relative.y * mouse_sensitivity, -1.5, 1.5)
			camera.rotation = Vector3(pitch, yaw, 0.0)
	elif event is InputEventKey:
		var ke := event as InputEventKey
		if ke.pressed and not ke.echo:
			if ke.keycode == KEY_ESCAPE:
				_capture_mouse(not mouse_captured)
			elif ke.keycode == KEY_1:
				set_display_mode(DisplayMode.FULL_BAKED)
			elif ke.keycode == KEY_2:
				set_display_mode(DisplayMode.VERTEX_COLORS_ONLY)
			elif ke.keycode == KEY_3:
				set_display_mode(DisplayMode.TEXTURES_ONLY)
			elif ke.keycode == KEY_4:
				if current_mode == DisplayMode.WIREFRAME:
					cycle_wireframe_style()
				else:
					set_display_mode(DisplayMode.WIREFRAME)
			elif ke.keycode == KEY_5:
				set_display_mode(DisplayMode.COLLIDERS_ONLY)
			elif ke.keycode == KEY_6:
				cycle_environment_preset()
			elif ke.keycode == KEY_P:
				toggle_play_mode()
			elif ke.keycode == KEY_R and is_play_mode:
				respawn_player()
			elif ke.keycode == KEY_H or ke.keycode == KEY_TAB:
				hud.visible = not hud.visible

func _process(delta: float) -> void:
	_handle_camera_movement(delta)
	_update_animated_uvs(delta)
	_update_emitters(delta)
	_update_hud()

## Replays the map's UV-scroll animation. The offset is applied to whichever
## material is currently assigned to the surface (the display modes swap in
## override materials), from a pristine base so repeated frames never
## accumulate error.
func _update_animated_uvs(delta: float) -> void:
	if animated_surfaces.is_empty():
		return
	if _scroll_freeze >= 0.0:
		_scroll_time = _scroll_freeze
	else:
		_scroll_time += delta
	for entry in animated_surfaces:
		var mi: MeshInstance3D = entry["mi"]
		if mi == null or not is_instance_valid(mi) or mi.mesh == null:
			continue
		var surface: int = entry["surface"]
		var mat: Material = mi.get_surface_override_material(surface)
		if mat == null:
			mat = mi.mesh.surface_get_material(surface)
		if not (mat is BaseMaterial3D):
			continue
		var speed: Vector2 = entry["speed"]
		# The speed is where the PATTERN travels (PBM 3.0), and the viewer has
		# to realise it the SAME WAY THE DEVICE DOES or the preview lies about
		# the direction. Both renderers add the offset to the texture
		# coordinate, and in both an advancing offset walks the pattern toward
		# -V — which is why the offset advances WITH the speed here, exactly as
		# the PSP's offset register does. Subtracting (the "obvious" reading of
		# what an offset does to a sampled image) made the waterfall climb its
		# wall in this viewer while the device had it right.
		# uv1_offset is a Vector3 (u, v, w); w is left alone.
		var off: Vector3 = entry["base_offset"]
		(mat as BaseMaterial3D).uv1_offset = Vector3(
			off.x + speed.x * _scroll_time,
			off.y + speed.y * _scroll_time,
			off.z)

func _capture_mouse(capture: bool) -> void:
	mouse_captured = capture
	if capture:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _handle_camera_movement(delta: float) -> void:
	if not mouse_captured or is_play_mode:
		return
	var speed := move_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= boost_multiplier

	var move_vec := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): move_vec += -camera.global_basis.z
	if Input.is_key_pressed(KEY_S): move_vec += camera.global_basis.z
	if Input.is_key_pressed(KEY_A): move_vec += -camera.global_basis.x
	if Input.is_key_pressed(KEY_D): move_vec += camera.global_basis.x
	if Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_SPACE): move_vec += Vector3.UP
	if Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_C): move_vec += Vector3.DOWN

	if move_vec.length_squared() > 0.0001:
		camera.global_position += move_vec.normalized() * speed * delta

func load_map(path: String) -> bool:
	if not FileAccess.file_exists(path):
		if lbl_stats != null:
			lbl_stats.text = "File does not exist: %s" % path
		return false

	if map_container == null:
		map_container = get_node_or_null("MapContainer")
	if camera == null:
		camera = get_node_or_null("Camera3D")

	# Clear previous map
	if map_container != null:
		for c in map_container.get_children():
			c.queue_free()
	loaded_mesh_instances.clear()
	original_materials.clear()
	wireframe_mesh_instances.clear()
	collider_wireframe_instances.clear()
	animated_surfaces.clear()
	for ep in emitter_previews:
		var ep_mi: MeshInstance3D = ep.get("mi")
		if ep_mi != null and is_instance_valid(ep_mi):
			ep_mi.queue_free()
	emitter_previews.clear()
	_emit_time = 0.0
	_scroll_time = 0.0
	total_vertices = 0
	total_triangles = 0
	total_surfaces = 0
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(path, state)
	if err != OK:
		if lbl_stats != null:
			lbl_stats.text = "Failed to parse GLTF/GLB: error code %d" % err
		return false

	var generated_scene := doc.generate_scene(state)
	if generated_scene == null:
		if lbl_stats != null:
			lbl_stats.text = "Failed to generate scene from GLTF."
		return false

	map_container.add_child(generated_scene)
	_collect_mesh_instances(generated_scene)
	_setup_emitters(generated_scene)
	_calculate_stats()
	_ensure_wireframe_meshes()
	_ensure_collider_wireframes()
	_setup_physics_world(generated_scene)
	set_display_mode(current_mode)
	# Position camera to look at the map bounds
	_frame_camera_on_map()
	return true

## ── Particle emitter preview ────────────────────────────────────────────────
## An emitter in an exported map is a LOOPING, STATELESS particle stream: at any
## scene time every particle is a closed form of (t, its index, the emitter's
## seed). This preview implements that definition literally -- the same hash, the
## same phase slots, the same two-segment size/colour curves, the same flipbook
## frame -- which is what makes it a reference for what the device does rather
## than an artist's impression of it. The C reference lives in
## retro_engine/psp/psp_render.c; SPEC_RETRO_FORMAT.md §8 defines the semantics.

## The emitter random source (identical to pbm.h's pbm_hash32 / pbm_rand).
static func _pbm_hash32(x: int) -> int:
	x &= 0xFFFFFFFF
	x ^= x >> 16
	x = (x * 0x7feb352d) & 0xFFFFFFFF
	x ^= x >> 15
	x = (x * 0x846ca68b) & 0xFFFFFFFF
	x ^= x >> 16
	return x & 0xFFFFFFFF

static func _pbm_rand(seed_v: int, idx: int, chan: int) -> float:
	var h := _pbm_hash32(seed_v ^ ((idx * 0x9E3779B9) & 0xFFFFFFFF) ^ ((chan * 0x85EBCA6B) & 0xFFFFFFFF))
	return float(h >> 8) * (1.0 / 16777216.0)

## Derives the per-particle constants, exactly as the loader does at load time.
static func _derive_particles(rec: Dictionary) -> Array:
	var count: int = maxi(1, int(rec.get("count", 1)))
	var seed_v: int = int(rec.get("seed", 0))
	var dir: Vector3 = _vec3(rec, "dir", Vector3.UP).normalized()
	var t1 := (Vector3(0, 0, 1) if absf(dir.y) > 0.9 else Vector3.UP).cross(dir).normalized()
	var t2 := dir.cross(t1)
	var spread: float = float(rec.get("spread", 0.0))
	var life_min: float = float(rec.get("life_min", 1.0))
	var life_max: float = float(rec.get("life_max", 1.0))
	var speed_min: float = float(rec.get("speed_min", 0.0))
	var speed_max: float = float(rec.get("speed_max", 0.0))
	var size_min: float = float(rec.get("size_min", 0.1))
	var size_max: float = float(rec.get("size_max", 0.1))
	var spin_min: float = float(rec.get("spin_min", 0.0))
	var spin_max: float = float(rec.get("spin_max", 0.0))
	var angle_min: float = float(rec.get("angle_min", 0.0))
	var angle_max: float = float(rec.get("angle_max", 0.0))
	var spawn_radius: float = float(rec.get("spawn_radius", 0.0))
	var aligned: bool = (int(rec.get("flags", 0)) & 8) != 0
	var parts: Array = []
	for k in range(count):
		var theta: float = spread * sqrt(_pbm_rand(seed_v, k, 7))
		var phi: float = _pbm_rand(seed_v, k, 8) * TAU
		var st := sin(theta)
		var d := dir * cos(theta) + (t1 * cos(phi) + t2 * sin(phi)) * st
		var spawn := Vector3.ZERO
		if spawn_radius > 0.0:
			var cz: float = 2.0 * _pbm_rand(seed_v, k, 10) - 1.0
			var sz := sqrt(maxf(0.0, 1.0 - cz * cz))
			var ang: float = _pbm_rand(seed_v, k, 11) * TAU
			spawn = Vector3(sz * cos(ang), sz * sin(ang), cz) * spawn_radius * pow(_pbm_rand(seed_v, k, 9), 1.0 / 3.0)
		var life: float = maxf(0.0001, lerpf(life_min, life_max, _pbm_rand(seed_v, k, 0)))
		var phase: float = 0.0 if aligned else fposmod(float(k) / float(count) + _pbm_rand(seed_v, k, 1) / float(count), 1.0)
		parts.append({
			"life": life,
			"inv_life": 1.0 / life,
			"phase": phase,
			"speed": lerpf(speed_min, speed_max, _pbm_rand(seed_v, k, 2)),
			"size": lerpf(size_min, size_max, _pbm_rand(seed_v, k, 3)),
			"spin": lerpf(spin_min, spin_max, _pbm_rand(seed_v, k, 4)),
			"angle0": lerpf(angle_min, angle_max, _pbm_rand(seed_v, k, 12)),
			"wobble_phase": _pbm_rand(seed_v, k, 5) * TAU,
			"anim_offset": _pbm_rand(seed_v, k, 6),
			"dir": d,
			"spawn": spawn,
		})
	return parts

static func _vec3(d: Dictionary, key: String, fallback: Vector3) -> Vector3:
	var v = d.get(key, null)
	if v is Array and (v as Array).size() >= 3:
		return Vector3(v[0], v[1], v[2])
	if v is Vector3:
		return v
	return fallback

## Finds the emitters in an imported map and hides their texture carriers.
func _setup_emitters(root: Node) -> void:
	if root == null:
		return
	if root is MeshInstance3D and root.has_meta("extras"):
		var extras: Dictionary = root.get_meta("extras")
		if extras.has("poi_emitter"):
			# The zero-size quad whose material carries the particle texture.
			root.visible = false
			var rec: Dictionary = extras["poi_emitter"]
			var mi := MeshInstance3D.new()
			mi.name = "EmitterPreview_%s" % root.name
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var src_mat: Material = null
			if (root as MeshInstance3D).mesh != null and (root as MeshInstance3D).mesh.get_surface_count() > 0:
				src_mat = (root as MeshInstance3D).mesh.surface_get_material(0)
			else:
				src_mat = (root as MeshInstance3D).material_override
			mi.material_override = _emitter_preview_material(rec, src_mat)
			if map_container != null:
				map_container.add_child(mi)
			emitter_previews.append({ "mi": mi, "rec": rec, "parts": _derive_particles(rec) })
	for c in root.get_children():
		_setup_emitters(c)

## The preview material mirrors the emitter's own contract: unshaded, vertex
## colour as albedo (that is where the fade lives), depth writes off, and the
## emitter's blend mode.
func _emitter_preview_material(rec: Dictionary, src_mat: Material) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	if src_mat is StandardMaterial3D:
		mat.albedo_texture = (src_mat as StandardMaterial3D).albedo_texture
		mat.blend_mode = (src_mat as StandardMaterial3D).blend_mode
	else:
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return mat

## Rebuilds every emitter's geometry for the current scene time.
func _update_emitters(delta: float) -> void:
	if emitter_previews.is_empty():
		return
	_emit_time = _scroll_freeze if _scroll_freeze >= 0.0 else _emit_time + delta
	var cam: Camera3D = player_cam if (is_play_mode and player_cam != null) else camera
	var right := cam.global_transform.basis.x
	var up := cam.global_transform.basis.y
	for ep in emitter_previews:
		var mi: MeshInstance3D = ep["mi"]
		if mi == null or not is_instance_valid(mi):
			continue
		var rec: Dictionary = ep["rec"]
		mi.mesh = _build_emitter_mesh(rec, ep["parts"], _emit_time, right, up)

func _build_emitter_mesh(rec: Dictionary, parts: Array, t: float, cam_right: Vector3, cam_up: Vector3) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var origin := _vec3(rec, "pos", Vector3.ZERO)
	var gravity := _vec3(rec, "gravity", Vector3.ZERO)
	var damping: float = float(rec.get("damping", 0.0))
	var knee: float = clampf(float(rec.get("knee", 0.5)), 0.05, 0.95)
	var size_mid: float = float(rec.get("size_mid", 1.0))
	var size_end: float = float(rec.get("size_end", 1.0))
	var aspect: float = float(rec.get("aspect", 1.0))
	var wobble_amp: float = float(rec.get("wobble_amp", 0.0))
	var wobble_freq: float = float(rec.get("wobble_freq", 0.0))
	var c_start := _unpack_rgba(int(rec.get("color_start", -1)))
	var c_mid := _unpack_rgba(int(rec.get("color_mid", -1)))
	var c_end := _unpack_rgba(int(rec.get("color_end", -1)))
	var flags: int = int(rec.get("flags", 0))
	var cols_n: int = maxi(1, int(rec.get("atlas_cols", 1)))
	var rows_n: int = maxi(1, int(rec.get("atlas_rows", 1)))
	var loops: int = maxi(1, int(rec.get("anim_loops", 1)))
	var frames: int = cols_n * rows_n
	var axis: Vector3 = _vec3(rec, "dir", Vector3.UP).normalized()
	var w1: Vector3 = (Vector3(0, 0, 1) if absf(axis.y) > 0.9 else Vector3.UP).cross(axis).normalized()
	var w2: Vector3 = axis.cross(w1)

	for p in parts:
		var age: float = fposmod(t * float(p["inv_life"]) + float(p["phase"]), 1.0)
		var tau: float = age * float(p["life"])
		var size: float = float(p["size"]) * (lerpf(1.0, size_mid, age / knee) if age < knee
			else lerpf(size_mid, size_end, (age - knee) / (1.0 - knee)))
		var pos: Vector3 = origin + (p["spawn"] as Vector3)
		if damping > 0.0:
			var decay := exp(-damping * tau)
			var k1: float = (1.0 - decay) / damping
			var k2: float = (tau - k1) / damping
			pos += (p["dir"] as Vector3) * float(p["speed"]) * k1 + gravity * k2
		else:
			pos += (p["dir"] as Vector3) * float(p["speed"]) * tau + gravity * 0.5 * tau * tau
		if wobble_amp > 0.0:
			var w: float = TAU * wobble_freq * tau + float(p["wobble_phase"])
			pos += (w1 * sin(w) + w2 * cos(w)) * wobble_amp

		var col: Color = (c_start.lerp(c_mid, age / knee) if age < knee
			else c_mid.lerp(c_end, (age - knee) / (1.0 - knee)))
		var ang: float = float(p["angle0"]) + float(p["spin"]) * tau
		var rx: Vector3 = cam_right
		var uy: Vector3 = cam_up
		if (flags & 2) != 0:  # PBM_EMIT_Y_LOCKED
			var fwd: Vector3 = -cam_right.cross(cam_up)  # camera forward, from the basis
			rx = Vector3(fwd.z, 0.0, -fwd.x).normalized()
			uy = rx.cross(fwd).normalized()
		var rh: Vector3 = (rx * cos(ang) + uy * sin(ang)) * size * aspect * 0.5
		var uh: Vector3 = (uy * cos(ang) - rx * sin(ang)) * size * 0.5

		var u0 := 0.0
		var v0 := 0.0
		var du := 1.0
		var dv := 1.0
		if frames > 1:
			var af: float = fposmod(age * float(loops) + float(p["anim_offset"]), 1.0)
			var fr: int = mini(frames - 1, int(af * float(frames)))
			var cx_i: int = fr % cols_n
			var cy_i: int = fr / cols_n
			u0 = float(cx_i) / float(cols_n)
			v0 = float(cy_i) / float(rows_n)
			du = 1.0 / float(cols_n)
			dv = 1.0 / float(rows_n)

		var c0 := pos - rh - uh
		var c1 := pos + rh - uh
		var c2 := pos + rh + uh
		var c3 := pos - rh + uh
		var quad := PackedVector3Array([c3, c2, c1, c3, c1, c0])
		var quv := PackedVector2Array([
			Vector2(u0, v0), Vector2(u0 + du, v0), Vector2(u0 + du, v0 + dv),
			Vector2(u0, v0), Vector2(u0 + du, v0 + dv), Vector2(u0, v0 + dv)])
		for qi in range(6):
			verts.append(quad[qi])
			uvs.append(quv[qi])
			cols.append(col)

	var am := ArrayMesh.new()
	if verts.is_empty():
		return am
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return am

static func _unpack_rgba(packed: int) -> Color:
	var v: int = packed & 0xFFFFFFFF
	return Color(
		float(v & 0xFF) / 255.0,
		float((v >> 8) & 0xFF) / 255.0,
		float((v >> 16) & 0xFF) / 255.0,
		float((v >> 24) & 0xFF) / 255.0)

func _collect_mesh_instances(node: Node) -> void:
	if node is Light3D:
		(node as Light3D).visible = false
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			loaded_mesh_instances.append(mi)
			var mats: Array[Material] = []
			for s in range(mi.mesh.get_surface_count()):
				var mat: Material = mi.get_surface_override_material(s) if mi.get_surface_override_material(s) != null else mi.mesh.surface_get_material(s)
				if mat is StandardMaterial3D and mat.resource_name.begins_with("BakedTile_"):
					(mat as StandardMaterial3D).texture_repeat = false
				# Scrolling surfaces carry their speed in the GLB material's
				# `extras` (see PBUv.SCROLL_META).
				if mat is StandardMaterial3D and mat.has_meta("extras"):
					var speed := PBUv.scroll_from_extras(mat.get_meta("extras"))
					if speed != Vector2.ZERO:
						animated_surfaces.append({
							"mi": mi, "surface": s, "speed": speed,
							"base_offset": (mat as StandardMaterial3D).uv1_offset,
						})
				mats.append(mat)
			original_materials[mi] = mats

	for child in node.get_children():
		_collect_mesh_instances(child)

func _calculate_stats() -> void:
	total_vertices = 0
	total_triangles = 0
	total_surfaces = 0

	for mi in loaded_mesh_instances:
		var m := mi.mesh
		if m != null:
			for s in range(m.get_surface_count()):
				total_surfaces += 1
				var arrays := m.surface_get_arrays(s)
				if arrays.size() > Mesh.ARRAY_VERTEX and arrays[Mesh.ARRAY_VERTEX] != null:
					total_vertices += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
				if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] != null:
					var ind: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
					total_triangles += ind.size() / 3
				elif arrays.size() > Mesh.ARRAY_VERTEX and arrays[Mesh.ARRAY_VERTEX] != null:
					total_triangles += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3

func cycle_wireframe_style() -> void:
	wireframe_style = ((int(wireframe_style) + 1) % 3) as WireframeStyle
	set_display_mode(DisplayMode.WIREFRAME)

func set_display_mode(mode: DisplayMode) -> void:
	current_mode = mode

	# Ensure wireframe overlays are generated
	if mode == DisplayMode.WIREFRAME and wireframe_mesh_instances.is_empty():
		_ensure_wireframe_meshes()
	if mode == DisplayMode.COLLIDERS_ONLY and collider_wireframe_instances.is_empty():
		_ensure_collider_wireframes()

	# Update wireframe overlay visibility
	for w_mi in wireframe_mesh_instances:
		if w_mi != null and is_instance_valid(w_mi):
			w_mi.visible = (mode == DisplayMode.WIREFRAME)

	for cw_mi in collider_wireframe_instances:
		if cw_mi != null and is_instance_valid(cw_mi):
			cw_mi.visible = (mode == DisplayMode.COLLIDERS_ONLY)
	for mi in loaded_mesh_instances:
		var is_col := mi.name.begins_with("Collider_")
		if mode == DisplayMode.COLLIDERS_ONLY:
			if is_col:
				mi.visible = true
				for s in range(mi.mesh.get_surface_count()):
					mi.set_surface_override_material(s, _get_collider_fill_material())
			else:
				mi.visible = false
			continue

		# In non-collider modes, hide collider meshes completely
		if is_col:
			mi.visible = false
			continue
		else:
			mi.visible = true

		var orig_mats: Array = original_materials.get(mi, [])
		var m := mi.mesh
		if m == null: continue

		for s in range(m.get_surface_count()):
			var base_mat: Material = orig_mats[s] if s < orig_mats.size() else null

			if mode == DisplayMode.FULL_BAKED:
				var sm := StandardMaterial3D.new()
				sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				sm.vertex_color_use_as_albedo = true
				if base_mat is StandardMaterial3D:
					var bm := base_mat as StandardMaterial3D
					sm.albedo_texture = bm.albedo_texture
					sm.albedo_color = bm.albedo_color
					sm.transparency = bm.transparency
					sm.cull_mode = bm.cull_mode
					sm.texture_repeat = not bm.resource_name.begins_with("BakedTile_")
				mi.set_surface_override_material(s, sm)
			elif mode == DisplayMode.VERTEX_COLORS_ONLY:
				var sm := StandardMaterial3D.new()
				sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				sm.vertex_color_use_as_albedo = true
				sm.albedo_color = Color.WHITE
				if base_mat is StandardMaterial3D:
					var bm := base_mat as StandardMaterial3D
					if bm.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
						sm.transparency = bm.transparency
						sm.albedo_texture = bm.albedo_texture
						sm.cull_mode = bm.cull_mode
				mi.set_surface_override_material(s, sm)

			elif mode == DisplayMode.TEXTURES_ONLY:
				var sm := StandardMaterial3D.new()
				sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				sm.vertex_color_use_as_albedo = false
				if base_mat is StandardMaterial3D:
					var bm := base_mat as StandardMaterial3D
					sm.albedo_texture = bm.albedo_texture
					sm.albedo_color = bm.albedo_color
					sm.transparency = bm.transparency
					sm.cull_mode = bm.cull_mode
					sm.texture_repeat = not bm.resource_name.begins_with("BakedTile_")
				mi.set_surface_override_material(s, sm)
			elif mode == DisplayMode.WIREFRAME:
				var sm := StandardMaterial3D.new()
				sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				var bm: StandardMaterial3D = base_mat as StandardMaterial3D if base_mat is StandardMaterial3D else null

				# Preserve billboard / foliage transparency if present
				if bm != null and bm.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
					sm.transparency = bm.transparency
					sm.albedo_texture = bm.albedo_texture
					sm.cull_mode = bm.cull_mode

				match wireframe_style:
					WireframeStyle.DARK_SLATE:
						sm.vertex_color_use_as_albedo = false
						sm.albedo_color = Color(0.12, 0.14, 0.18)
					WireframeStyle.VERTEX_LIGHT:
						sm.vertex_color_use_as_albedo = true
						sm.albedo_color = Color(0.35, 0.38, 0.42)
					WireframeStyle.TEXTURES:
						sm.vertex_color_use_as_albedo = true
						if bm != null and bm.albedo_texture != null:
							sm.albedo_texture = bm.albedo_texture
							sm.texture_repeat = not bm.resource_name.begins_with("BakedTile_")
						sm.albedo_color = Color(0.35, 0.35, 0.35)
				mi.set_surface_override_material(s, sm)


func _get_collider_fill_material() -> StandardMaterial3D:
	if _collider_fill_material == null:
		_collider_fill_material = StandardMaterial3D.new()
		_collider_fill_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_collider_fill_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_collider_fill_material.albedo_color = Color(0.1, 0.85, 0.45, 0.4) # translucent emerald green
		_collider_fill_material.cull_mode = BaseMaterial3D.CULL_DISABLED # double sided
	return _collider_fill_material

func _get_collider_wireframe_material() -> ShaderMaterial:
	if _collider_wireframe_material == null:
		var shader := Shader.new()
		shader.code = """
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform vec4 line_color : source_color = vec4(0.2, 1.0, 0.5, 1.0);
uniform float normal_offset : hint_range(0.0, 0.05) = 0.008;

void vertex() {
	if (length(NORMAL) > 0.001) {
		VERTEX += normalize(NORMAL) * normal_offset;
	}
}

void fragment() {
	ALBEDO = line_color.rgb;
}
"""
		_collider_wireframe_material = ShaderMaterial.new()
		_collider_wireframe_material.shader = shader
		_collider_wireframe_material.set_shader_parameter("line_color", Color(0.2, 1.0, 0.5, 1.0)) # crisp lime
		_collider_wireframe_material.set_shader_parameter("normal_offset", 0.008)
	return _collider_wireframe_material

func _ensure_collider_wireframes() -> void:
	for mi in loaded_mesh_instances:
		if mi == null or not is_instance_valid(mi):
			continue
		if not mi.name.begins_with("Collider_"):
			continue
		_create_wireframe_for_collider(mi)

func _create_wireframe_for_collider(mi: MeshInstance3D) -> void:
	var m := mi.mesh
	if m == null or mi.get_node_or_null("ColliderWireOverlay") != null:
		return

	var wire_mi := MeshInstance3D.new()
	wire_mi.name = "ColliderWireOverlay"
	wire_mi.material_override = _get_collider_wireframe_material()
	wire_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	wire_mi.visible = (current_mode == DisplayMode.COLLIDERS_ONLY)

	var arr_mesh := ArrayMesh.new()
	var wire_vertices := PackedVector3Array()
	var wire_normals := PackedVector3Array()

	for s in range(m.get_surface_count()):
		var arrs := m.surface_get_arrays(s)
		if arrs.is_empty() or arrs[Mesh.ARRAY_VERTEX] == null:
			continue
		var verts: PackedVector3Array = arrs[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arrs[Mesh.ARRAY_NORMAL] if arrs[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		var inds: PackedInt32Array = arrs[Mesh.ARRAY_INDEX] if arrs[Mesh.ARRAY_INDEX] != null else PackedInt32Array()

		var edges := {}
		if not inds.is_empty():
			for i in range(0, inds.size(), 3):
				_add_unique_edge(edges, inds[i], inds[i + 1])
				_add_unique_edge(edges, inds[i + 1], inds[i + 2])
				_add_unique_edge(edges, inds[i + 2], inds[i])
		else:
			for i in range(0, verts.size(), 3):
				_add_unique_edge(edges, i, i + 1)
				_add_unique_edge(edges, i + 1, i + 2)
				_add_unique_edge(edges, i + 2, i)

		for e in edges.keys():
			var a: int = e.x
			var b: int = e.y
			if a < verts.size() and b < verts.size():
				wire_vertices.append(verts[a])
				wire_vertices.append(verts[b])
				if a < norms.size() and b < norms.size():
					wire_normals.append(norms[a])
					wire_normals.append(norms[b])
				else:
					wire_normals.append(Vector3.UP)
					wire_normals.append(Vector3.UP)

	if not wire_vertices.is_empty():
		var surf_arrays := []
		surf_arrays.resize(Mesh.ARRAY_MAX)
		surf_arrays[Mesh.ARRAY_VERTEX] = wire_vertices
		if not wire_normals.is_empty():
			surf_arrays[Mesh.ARRAY_NORMAL] = wire_normals
		arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, surf_arrays)
		wire_mi.mesh = arr_mesh
		mi.add_child(wire_mi)
		collider_wireframe_instances.append(wire_mi)
func _get_wireframe_material() -> ShaderMaterial:
	if _wireframe_material == null:
		var shader := Shader.new()
		shader.code = """
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform vec4 line_color : source_color = vec4(0.2, 0.9, 1.0, 1.0);
uniform float normal_offset : hint_range(0.0, 0.05) = 0.006;

void vertex() {
	// Push outwards along geometric surface normal so wireframe cleanly floats just above the surface
	if (length(NORMAL) > 0.001) {
		VERTEX += normalize(NORMAL) * normal_offset;
	}
}

void fragment() {
	ALBEDO = line_color.rgb;
}
"""
		_wireframe_material = ShaderMaterial.new()
		_wireframe_material.shader = shader
		_wireframe_material.set_shader_parameter("line_color", wireframe_color)
		_wireframe_material.set_shader_parameter("normal_offset", 0.006)
	return _wireframe_material

func _ensure_wireframe_meshes() -> void:
	for mi in loaded_mesh_instances:
		if mi == null or not is_instance_valid(mi):
			continue
		if mi.name.begins_with("Collider_") or not mi.visible:
			continue
		_create_wireframe_for_mesh(mi)

func _create_wireframe_for_mesh(mi: MeshInstance3D) -> void:
	var m := mi.mesh
	if m == null:
		return
	if mi.get_node_or_null("WireframeOverlay") != null:
		return

	var wire_mi := MeshInstance3D.new()
	wire_mi.name = "WireframeOverlay"
	wire_mi.material_override = _get_wireframe_material()
	wire_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	wire_mi.visible = (current_mode == DisplayMode.WIREFRAME)

	var arr_mesh := ArrayMesh.new()
	var wire_vertices := PackedVector3Array()
	var wire_normals := PackedVector3Array()

	for s in range(m.get_surface_count()):
		var arrs := m.surface_get_arrays(s)
		if arrs.is_empty() or arrs[Mesh.ARRAY_VERTEX] == null:
			continue
		var verts: PackedVector3Array = arrs[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array
		if arrs[Mesh.ARRAY_NORMAL] != null:
			norms = arrs[Mesh.ARRAY_NORMAL]
		else:
			norms = PackedVector3Array()

		var inds: PackedInt32Array
		if arrs[Mesh.ARRAY_INDEX] != null:
			inds = arrs[Mesh.ARRAY_INDEX]
		else:
			inds = PackedInt32Array()

		var edges := {}
		if not inds.is_empty():
			for i in range(0, inds.size(), 3):
				_add_unique_edge(edges, inds[i], inds[i + 1])
				_add_unique_edge(edges, inds[i + 1], inds[i + 2])
				_add_unique_edge(edges, inds[i + 2], inds[i])
		else:
			for i in range(0, verts.size(), 3):
				_add_unique_edge(edges, i, i + 1)
				_add_unique_edge(edges, i + 1, i + 2)
				_add_unique_edge(edges, i + 2, i)

		for e in edges.keys():
			var a: int = e.x
			var b: int = e.y
			if a < verts.size() and b < verts.size():
				wire_vertices.append(verts[a])
				wire_vertices.append(verts[b])
				if a < norms.size() and b < norms.size():
					wire_normals.append(norms[a])
					wire_normals.append(norms[b])
				else:
					wire_normals.append(Vector3.UP)
					wire_normals.append(Vector3.UP)

	if not wire_vertices.is_empty():
		var surf_arrays := []
		surf_arrays.resize(Mesh.ARRAY_MAX)
		surf_arrays[Mesh.ARRAY_VERTEX] = wire_vertices
		if not wire_normals.is_empty():
			surf_arrays[Mesh.ARRAY_NORMAL] = wire_normals
		arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, surf_arrays)
		wire_mi.mesh = arr_mesh
		mi.add_child(wire_mi)
		wireframe_mesh_instances.append(wire_mi)

func _add_unique_edge(edges: Dictionary, a: int, b: int) -> void:
	if a == b:
		return
	var k := Vector2i(mini(a, b), maxi(a, b))
	edges[k] = true

func _update_hud() -> void:
	var mode_name := ""
	match current_mode:
		DisplayMode.FULL_BAKED: mode_name = "1: Full Baked (Texture + Vertex Light)"
		DisplayMode.VERTEX_COLORS_ONLY: mode_name = "2: Vertex Colors Only (Lighting/AO)"
		DisplayMode.TEXTURES_ONLY: mode_name = "3: Textures Only (Unshaded Tiles)"
		DisplayMode.WIREFRAME:
			var style_label := "Dark Slate"
			match wireframe_style:
				WireframeStyle.DARK_SLATE: style_label = "Dark Slate (Topology)"
				WireframeStyle.VERTEX_LIGHT: style_label = "Vertex Lighting (AO/Shadows)"
				WireframeStyle.TEXTURES: style_label = "Textures (Tile Alignment)"
		DisplayMode.WIREFRAME:
			var style_label := "Dark Slate"
			match wireframe_style:
				WireframeStyle.DARK_SLATE: style_label = "Dark Slate (Topology)"
				WireframeStyle.VERTEX_LIGHT: style_label = "Vertex Lighting (AO/Shadows)"
				WireframeStyle.TEXTURES: style_label = "Textures (Tile Alignment)"
			mode_name = "4: Wireframe [%s] (Press 4 to cycle style)" % style_label
		DisplayMode.COLLIDERS_ONLY:
			var col_count := 0
			for mi in loaded_mesh_instances:
				if mi.name.begins_with("Collider_"): col_count += 1
			mode_name = "5: Colliders Only (Wireframe + Translucent Emerald, %d Colliders)" % col_count

	if is_play_mode:
		var on_flr := "Yes" if (player != null and player.is_on_floor()) else "In Air"
		lbl_mode.text = "🎮 PLAY MODE (Active) — %s" % mode_name
		lbl_mode.modulate = Color(0.3, 1.0, 0.5)
		lbl_stats.text = "FPS: %d | On Floor: %s | Pos: (%.1f, %.1f, %.1f) | P: Exit to Fly Cam | R: Respawn" % [
			Engine.get_frames_per_second(),
			on_flr,
			player.global_position.x if player else 0.0,
			player.global_position.y if player else 0.0,
			player.global_position.z if player else 0.0,
		]
	else:
		lbl_mode.text = "Mode: %s | Env: %s (Press 6 to cycle) — (Press P for Play Mode)" % [mode_name, current_preset.capitalize()]
		lbl_mode.modulate = Color(1.0, 0.9, 0.3)
		lbl_stats.text = "FPS: %d | Meshes: %d | Surfaces: %d | Vertices: %d | Triangles: %d\nMove Speed: %.1f m/s (Wheel to adjust, Shift for turbo)" % [
			Engine.get_frames_per_second(),
			loaded_mesh_instances.size(),
			total_surfaces,
			total_vertices,
			total_triangles,
			move_speed,
		]
	lbl_stats.text = "FPS: %d | Meshes: %d | Surfaces: %d | Vertices: %d | Triangles: %d\nMove Speed: %.1f m/s (Wheel to adjust, Shift for turbo)" % [
		Engine.get_frames_per_second(),
		loaded_mesh_instances.size(),
		total_surfaces,
		total_vertices,
		total_triangles,
		move_speed,
	]

func _frame_camera_on_map() -> void:
	if loaded_mesh_instances.is_empty():
		return
	var aabb := AABB()
	var first := true
	for mi in loaded_mesh_instances:
		var xf := mi.global_transform if mi.is_inside_tree() else mi.transform
		var b := xf * mi.get_aabb()
		if first:
			aabb = b
			first = false
		else:
			aabb = aabb.merge(b)

	var center := aabb.get_center()
	var max_dim := maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
	var cam_dist := maxf(max_dim * 1.2, 5.0)
	if camera != null:
		var target_pos := center + Vector3(cam_dist * 0.7, cam_dist * 0.5, cam_dist * 0.7)
		if camera.is_inside_tree():
			camera.global_position = target_pos
			camera.look_at(center, Vector3.UP)
		else:
			camera.position = target_pos
			camera.look_at_from_position(target_pos, center, Vector3.UP)
		yaw = camera.rotation.y
		pitch = camera.rotation.x

# ==============================================================================
# Physics & First-Person Play Mode
# ==============================================================================

func _setup_physics_world(scene: Node) -> void:
	if physics_world != null and is_instance_valid(physics_world):
		physics_world.queue_free()
	physics_world = Node3D.new()
	physics_world.name = "PhysicsWorld"
	map_container.add_child(physics_world)

	var has_colliders := false
	for mi in loaded_mesh_instances:
		if mi.name.begins_with("Collider_") and mi.mesh != null:
			has_colliders = true
			_create_static_collision(mi, physics_world)

	# If map was exported without colliders, fallback to visual meshes for collision
	if not has_colliders:
		for mi in loaded_mesh_instances:
			if mi.mesh != null and not mi.name.begins_with("Billboard") and not mi.name.begins_with("Stamp"):
				_create_static_collision(mi, physics_world)

func _create_static_collision(mi: MeshInstance3D, parent: Node) -> void:
	var trimesh_shape := mi.mesh.create_trimesh_shape()
	if trimesh_shape == null:
		return
	var body := StaticBody3D.new()
	body.name = "Body_" + mi.name
	body.global_transform = mi.global_transform
	var col_shape := CollisionShape3D.new()
	col_shape.name = "CollisionShape"
	col_shape.shape = trimesh_shape
	body.add_child(col_shape)
	parent.add_child(body)

func _ensure_player() -> void:
	if player != null and is_instance_valid(player):
		return
	player = CharacterBody3D.new()
	player.name = "ViewerPlayer"

	var col := CollisionShape3D.new()
	col.name = "Capsule"
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	col.shape = cap
	col.position = Vector3(0, 0.9, 0)
	player.add_child(col)

	player_cam = Camera3D.new()
	player_cam.name = "PlayerCamera"
	player_cam.position = Vector3(0, 1.6, 0)
	player_cam.fov = 75.0
	player_cam.current = false
	player.add_child(player_cam)

	player.floor_snap_length = 0.3
	player.floor_max_angle = deg_to_rad(50.0)
	add_child(player)

func toggle_play_mode() -> void:
	if is_play_mode:
		exit_play_mode()
	else:
		enter_play_mode()

func enter_play_mode() -> void:
	_ensure_player()
	is_play_mode = true

	# Spawn slightly above current camera position
	spawn_point = camera.global_position
	player.global_position = spawn_point
	player.rotation.y = camera.rotation.y
	player_pitch = camera.rotation.x
	player_cam.rotation.x = player_pitch
	player.velocity = Vector3.ZERO

	camera.current = false
	player_cam.current = true
	_capture_mouse(true)
	if btn_play_toggle != null:
		btn_play_toggle.text = "✈ Fly Cam (P)"

func exit_play_mode() -> void:
	is_play_mode = false
	if player != null and is_instance_valid(player) and player_cam != null:
		camera.global_position = player_cam.global_position
		camera.rotation.y = player.rotation.y
		camera.rotation.x = player_cam.rotation.x
		yaw = camera.rotation.y
		pitch = camera.rotation.x

	if player_cam != null:
		player_cam.current = false
	camera.current = true
	if btn_play_toggle != null:
		btn_play_toggle.text = "▶ Play Mode (P)"

func respawn_player() -> void:
	if player != null and is_instance_valid(player):
		player.global_position = spawn_point + Vector3(0, 1.0, 0)
		player.velocity = Vector3.ZERO

func _physics_process(delta: float) -> void:
	if not is_play_mode or player == null or not is_instance_valid(player):
		return

	# Gravity
	if not player.is_on_floor():
		player.velocity.y -= 15.0 * delta

	# Jump
	if Input.is_key_pressed(KEY_SPACE) and player.is_on_floor():
		player.velocity.y = 5.5

	# Movement
	var speed := 5.5
	if Input.is_key_pressed(KEY_SHIFT):
		speed = 11.0

	var move_vec := Vector2.ZERO
	if Input.is_key_pressed(KEY_W): move_vec.y -= 1
	if Input.is_key_pressed(KEY_S): move_vec.y += 1
	if Input.is_key_pressed(KEY_A): move_vec.x -= 1
	if Input.is_key_pressed(KEY_D): move_vec.x += 1
	move_vec = move_vec.normalized()

	var fwd := -player.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var right := player.global_basis.x
	right.y = 0.0
	right = right.normalized()

	var wish_dir := (right * move_vec.x + fwd * -move_vec.y)
	if wish_dir.length_squared() > 0.001:
		player.velocity.x = wish_dir.x * speed
		player.velocity.z = wish_dir.z * speed
	else:
		player.velocity.x = move_toward(player.velocity.x, 0.0, speed * 8.0 * delta)
		player.velocity.z = move_toward(player.velocity.z, 0.0, speed * 8.0 * delta)

	player.move_and_slide()

	if player.global_position.y < -40.0:
		respawn_player()
func set_environment_preset(preset_name: String, reload_map: bool = true) -> void:
	current_preset = preset_name.to_lower().strip_edges()
	var env_node := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if env_node != null and env_node.environment != null:
		PBEnvironment.apply_to_environment(env_node.environment, current_preset)
	for p_name in _env_buttons:
		var btn: Button = _env_buttons[p_name]
		if btn != null:
			if p_name == current_preset:
				btn.add_theme_color_override("font_color", Color(0.2, 0.9, 1.0))
			else:
				btn.remove_theme_color_override("font_color")
	if reload_map:
		var preset_glb := "res://exports/showcase_retro_baked_%s.glb" % current_preset
		if FileAccess.file_exists(preset_glb):
			load_map(preset_glb)

func cycle_environment_preset() -> void:
	var names := PBEnvironment.get_preset_names()
	var idx := names.find(current_preset)
	var next_idx := (idx + 1) % names.size()
	set_environment_preset(names[next_idx])
