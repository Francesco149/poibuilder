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
}

enum WireframeStyle {
	DARK_SLATE = 0,
	VERTEX_LIGHT = 1,
	TEXTURES = 2,
}

@export var default_map_path: String = "res://test_scenes/showcase_retro_baked.glb"

var current_mode: DisplayMode = DisplayMode.FULL_BAKED
var wireframe_style: WireframeStyle = WireframeStyle.DARK_SLATE
var wireframe_color: Color = Color(0.2, 0.9, 1.0) # Vibrant PoiBuilder Cyan
var wireframe_mesh_instances: Array[MeshInstance3D] = []
var _wireframe_material: ShaderMaterial
# Camera control properties
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

	yaw = camera.rotation.y
	pitch = camera.rotation.x

	# Auto-capture mouse on click in viewport
	_capture_mouse(true)
	get_viewport().msaa_3d = Viewport.MSAA_4X
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
		if arg.begins_with("--screenshot="):
			var shot_path := arg.trim_prefix("--screenshot=")
			camera.global_position = cam_pos
			camera.look_at(cam_look, Vector3.UP)
			set_display_mode(shot_mode as DisplayMode)
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
	if not mouse_captured:
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
		lbl_stats.text = "File does not exist: %s" % path
		return false

	# Clear previous map
	for c in map_container.get_children():
		c.queue_free()

	loaded_mesh_instances.clear()
	original_materials.clear()
	wireframe_mesh_instances.clear()
	total_vertices = 0
	total_triangles = 0
	total_surfaces = 0

	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(path, state)
	if err != OK:
		lbl_stats.text = "Failed to parse GLTF/GLB: error code %d" % err
		return false

	var generated_scene := doc.generate_scene(state)
	if generated_scene == null:
		lbl_stats.text = "Failed to generate scene from GLTF."
		return false

	map_container.add_child(generated_scene)
	_collect_mesh_instances(generated_scene)
	_calculate_stats()
	_ensure_wireframe_meshes()
	set_display_mode(current_mode)

	# Position camera to look at the map bounds
	_frame_camera_on_map()
	return true

func _collect_mesh_instances(node: Node) -> void:
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

	# Update wireframe overlay visibility
	for w_mi in wireframe_mesh_instances:
		if w_mi != null and is_instance_valid(w_mi):
			w_mi.visible = (mode == DisplayMode.WIREFRAME)

	for mi in loaded_mesh_instances:
		var orig_mats: Array = original_materials.get(mi, [])
		var m := mi.mesh
		if m == null: continue

		for s in range(m.get_surface_count()):
			var base_mat: Material = orig_mats[s] if s < orig_mats.size() else null

			if mode == DisplayMode.FULL_BAKED:
				mi.set_surface_override_material(s, base_mat)

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
			mode_name = "4: Wireframe [%s] (Press 4 to cycle style)" % style_label
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
		var b := mi.global_transform * mi.get_aabb()
		if first:
			aabb = b
			first = false
		else:
			aabb = aabb.merge(b)

	var center := aabb.get_center()
	var max_dim := maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
	var cam_dist := maxf(max_dim * 1.2, 5.0)
	camera.global_position = center + Vector3(cam_dist * 0.7, cam_dist * 0.5, cam_dist * 0.7)
	camera.look_at(center, Vector3.UP)
	yaw = camera.rotation.y
	pitch = camera.rotation.x
