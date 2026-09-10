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

@onready var camera: Camera3D = $Camera3D
@onready var map_container: Node3D = $MapContainer
@onready var hud: Control = $CanvasLayer/HUD
@onready var lbl_stats: Label = $CanvasLayer/HUD/VBox/StatsLabel
@onready var lbl_mode: Label = $CanvasLayer/HUD/VBox/ModeLabel
@onready var txt_load_path: LineEdit = $CanvasLayer/HUD/VBox/LoadBar/PathEdit
@onready var btn_load: Button = $CanvasLayer/HUD/VBox/LoadBar/LoadButton

func _ready() -> void:
	# Parse command line args for --map=...
	var map_to_load := default_map_path
	for arg in OS.get_cmdline_args():
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
	if not FileAccess.file_exists(map_to_load):
		for candidate in ["res://exports/showcase_retro_baked.glb", "res://exports/exported_map.glb", "res://test_scenes/showcase_retro_baked.glb"]:
			if FileAccess.file_exists(candidate):
				map_to_load = candidate
				break
	if FileAccess.file_exists(map_to_load):
		load_map(map_to_load)
	else:
		lbl_stats.text = "Map file not found: %s\nUse 'Browse / Load' to select a .glb file." % map_to_load

	var shot_mode := 1
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--mode="):
			shot_mode = int(arg.trim_prefix("--mode="))
		elif arg.begins_with("--wire_style="):
			var s_val := int(arg.trim_prefix("--wire_style="))
			wireframe_style = (clampi(s_val, 0, 2)) as WireframeStyle
		elif arg.begins_with("--wire_color="):
			var col_str := arg.trim_prefix("--wire_color=")
			wireframe_color = Color.from_string(col_str, Color(0.2, 0.9, 1.0))
			if _wireframe_material != null:
				_wireframe_material.set_shader_parameter("line_color", wireframe_color)
	var cam_pos := Vector3(2.5, 4.0, 5.0)
	var cam_look := Vector3(-1.5, 1.5, -1.5)
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--cam_pos="):
			var parts := arg.trim_prefix("--cam_pos=").split(",")
			if parts.size() == 3:
				cam_pos = Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
		elif arg.begins_with("--cam_look="):
			var parts := arg.trim_prefix("--cam_look=").split(",")
			if parts.size() == 3:
				cam_look = Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
	for arg in OS.get_cmdline_args():
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
			elif ke.keycode == KEY_P:
				toggle_play_mode()
			elif ke.keycode == KEY_R and is_play_mode:
				respawn_player()
			elif ke.keycode == KEY_H or ke.keycode == KEY_TAB:
				hud.visible = not hud.visible

func _process(delta: float) -> void:
	_handle_camera_movement(delta)
	_update_hud()

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
	_calculate_stats()
	_ensure_wireframe_meshes()
	_ensure_collider_wireframes()
	_setup_physics_world(generated_scene)
	set_display_mode(current_mode)
	# Position camera to look at the map bounds
	_frame_camera_on_map()
	return true

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
		lbl_mode.text = "Mode: %s — (Press P for Play Mode)" % mode_name
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
