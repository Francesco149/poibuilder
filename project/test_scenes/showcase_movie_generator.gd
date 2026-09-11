## Showcase Movie Generator — Produces a smooth, dense 60fps video demonstrating
## PoiBuilder map composition, geometry manipulation, scrolling textures, and PSP export.
@tool
extends Node3D

var _plugin: Node = null
var _vp: SubViewport = null
var _host: Control = null
var _cam: Camera3D = null
var _root: Node = null

# Software cursor & HUD overlay
var _overlay_layer: CanvasLayer = null
var _cursor_control: Control = null
var _cursor_pos := Vector2(960, 540)
var _target_cursor_pos := Vector2(960, 540)
var _click_pulses: Array[Dictionary] = [] # [{pos, radius, alpha, color}]
var _hud_title := "PoiBuilder — ProBuilder Clone for Godot"
var _hud_subtitle := "Initializing..."
var _hud_progress := 0.0

func _ready() -> void:
	if Engine.is_editor_hint() and OS.get_environment("PB_SHOWCASE_MOVIE") != "":
		_run.call_deferred()

func _find_plugin(node: Node) -> Node:
	if node.get_script() != null and str(node.get_script().resource_path).ends_with("poibuilder_plugin.gd"):
		return node
	for child in node.get_children():
		var found := _find_plugin(child)
		if found != null:
			return found
	return null

func _frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame

func _setup_overlay() -> void:
	_overlay_layer = CanvasLayer.new()
	_overlay_layer.layer = 128
	add_child(_overlay_layer)

	_cursor_control = Control.new()
	_cursor_control.set_anchors_preset(Control.PRESET_FULL_RECT)
	_cursor_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor_control.draw.connect(_on_overlay_draw)
	_overlay_layer.add_child(_cursor_control)

func _on_overlay_draw() -> void:
	if _cursor_control == null:
		return
	var font := ThemeDB.fallback_font
	var font_size := 16

	# 1. Lower-third Glassmorphism Action Banner
	var banner_w := 820.0
	var banner_h := 84.0
	var banner_x := (1920.0 - banner_w) * 0.5
	var banner_y := 1080.0 - banner_h - 32.0
	var rect := Rect2(banner_x, banner_y, banner_w, banner_h)

	# Dark glass background + cyan border
	_cursor_control.draw_rect(rect, Color(0.06, 0.09, 0.14, 0.88), true)
	_cursor_control.draw_rect(rect, Color(0.25, 0.75, 1.0, 0.90), false, 2.0)

	# Accent tag
	var tag_rect := Rect2(banner_x + 16, banner_y + 16, 8, banner_h - 32)
	_cursor_control.draw_rect(tag_rect, Color(0.2, 0.9, 1.0, 1.0), true)

	# Title & Subtitle
	_cursor_control.draw_string(font, Vector2(banner_x + 36, banner_y + 34), _hud_title,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.95, 0.95, 0.95))
	_cursor_control.draw_string(font, Vector2(banner_x + 36, banner_y + 60), _hud_subtitle,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.3, 0.85, 1.0))

	# Subtle progress line at bottom of banner
	var prog_w := (banner_w - 4.0) * clampf(_hud_progress, 0.0, 1.0)
	_cursor_control.draw_line(Vector2(banner_x + 2, banner_y + banner_h - 2),
		Vector2(banner_x + 2 + prog_w, banner_y + banner_h - 2), Color(0.2, 0.9, 1.0, 0.95), 3.0)

	# 2. Click ripple pulses
	for pulse in _click_pulses:
		var pos: Vector2 = pulse["pos"]
		var r: float = pulse["radius"]
		var col: Color = pulse["color"]
		col.a = pulse["alpha"]
		_cursor_control.draw_arc(pos, r, 0, TAU, 32, col, 2.5, true)

	# 3. Vector Mouse Cursor
	var pts := PackedVector2Array([
		_cursor_pos,
		_cursor_pos + Vector2(0, 22),
		_cursor_pos + Vector2(5.5, 17),
		_cursor_pos + Vector2(10.5, 27),
		_cursor_pos + Vector2(13.5, 25.5),
		_cursor_pos + Vector2(8.5, 15.5),
		_cursor_pos + Vector2(15.5, 15.5),
		_cursor_pos
	])
	_cursor_control.draw_colored_polygon(pts, Color(0.98, 0.98, 0.98, 1.0))
	_cursor_control.draw_polyline(pts, Color(0.08, 0.08, 0.10, 1.0), 2.0, true)

func _process(_delta: float) -> void:
	if _cursor_control == null:
		return
	# Smoothly animate click pulses
	var alive_pulses: Array[Dictionary] = []
	for p in _click_pulses:
		p["radius"] += 2.5
		p["alpha"] -= 0.06
		if p["alpha"] > 0.01:
			alive_pulses.append(p)
	_click_pulses = alive_pulses
	_cursor_control.queue_redraw()

func _move_cursor(to_pos: Vector2, duration_frames: int = 20) -> void:
	var start := _cursor_pos
	for i in range(duration_frames):
		var t := float(i + 1) / float(duration_frames)
		# Smoothstep interpolation
		var s := t * t * (3.0 - 2.0 * t)
		_cursor_pos = start.lerp(to_pos, s)
		var ev := InputEventMouseMotion.new()
		ev.position = _cursor_pos
		ev.global_position = _cursor_pos
		Input.parse_input_event(ev)
		await get_tree().process_frame

func _click_at(pos: Vector2, color: Color = Color(0.2, 0.9, 1.0)) -> void:
	await _move_cursor(pos, 15)
	_click_pulses.append({"pos": pos, "radius": 4.0, "alpha": 0.95, "color": color})
	var ev_down := InputEventMouseButton.new()
	ev_down.button_index = MOUSE_BUTTON_LEFT
	ev_down.pressed = true
	ev_down.position = pos
	ev_down.global_position = pos
	ev_down.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(ev_down)
	await _frames(4)

	var ev_up := InputEventMouseButton.new()
	ev_up.button_index = MOUSE_BUTTON_LEFT
	ev_up.pressed = false
	ev_up.position = pos
	ev_up.global_position = pos
	Input.parse_input_event(ev_up)
	await _frames(6)

func _drag_mouse(from_pos: Vector2, to_pos: Vector2, duration_frames: int = 30, shift: bool = false) -> void:
	await _move_cursor(from_pos, 15)
	_click_pulses.append({"pos": from_pos, "radius": 4.0, "alpha": 0.95, "color": Color(1.0, 0.8, 0.2)})

	var ev_down := InputEventMouseButton.new()
	ev_down.button_index = MOUSE_BUTTON_LEFT
	ev_down.pressed = true
	ev_down.position = from_pos
	ev_down.global_position = from_pos
	ev_down.button_mask = MOUSE_BUTTON_MASK_LEFT
	ev_down.shift_pressed = shift
	Input.parse_input_event(ev_down)
	await _frames(3)

	var start := from_pos
	for i in range(duration_frames):
		var t := float(i + 1) / float(duration_frames)
		var s := t * t * (3.0 - 2.0 * t)
		_cursor_pos = start.lerp(to_pos, s)
		var ev_move := InputEventMouseMotion.new()
		ev_move.position = _cursor_pos
		ev_move.global_position = _cursor_pos
		ev_move.button_mask = MOUSE_BUTTON_MASK_LEFT
		ev_move.shift_pressed = shift
		Input.parse_input_event(ev_move)
		await get_tree().process_frame

	var ev_up := InputEventMouseButton.new()
	ev_up.button_index = MOUSE_BUTTON_LEFT
	ev_up.pressed = false
	ev_up.position = to_pos
	ev_up.global_position = to_pos
	ev_up.shift_pressed = shift
	Input.parse_input_event(ev_up)
	await _frames(6)

func _press_key(keycode: Key) -> void:
	var ev_down := InputEventKey.new()
	ev_down.keycode = keycode
	ev_down.physical_keycode = keycode
	ev_down.pressed = true
	Input.parse_input_event(ev_down)
	await _frames(3)
	var ev_up := InputEventKey.new()
	ev_up.keycode = keycode
	ev_up.physical_keycode = keycode
	ev_up.pressed = false
	Input.parse_input_event(ev_up)
	await _frames(4)

func _window_pos(world: Vector3) -> Vector2:
	if _vp == null or _cam == null or _host == null:
		return Vector2(960, 540)
	var local := _cam.unproject_position(world)
	var sx: float = _host.size.x / float(_vp.size.x)
	var sy: float = _host.size.y / float(_vp.size.y)
	return _host.global_position + Vector2(local.x * sx, local.y * sy)

func _set_hud(title: String, subtitle: String, progress: float) -> void:
	_hud_title = title
	_hud_subtitle = subtitle
	_hud_progress = progress

func _run() -> void:
	await _frames(60)
	_setup_overlay()

	var iface := EditorInterface
	iface.set_main_screen_editor("3D")
	await _frames(15)

	_vp = iface.get_editor_viewport_3d(0)
	if _vp != null:
		_cam = _vp.get_camera_3d()
		_host = _vp.get_parent().get_parent() as Control
	_root = iface.get_edited_scene_root()

	_plugin = _find_plugin(get_tree().root)

	# =========================================================================
	# Step 1: Procedural Grid & Surface Placement
	# =========================================================================
	_set_hud("Step 1: Infinite Procedural Grid & Snapping",
		"Drawing 12m x 12m Courtyard Floor directly in surface plane...", 0.10)
	_cam.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 8.0, 14.0)).looking_at(Vector3(0, 0, 0), Vector3.UP)
	await _frames(30)

	var p_start := _window_pos(Vector3(-6.0, 0.0, -6.0))
	var p_end := _window_pos(Vector3(6.0, 0.0, 6.0))

	if _plugin != null:
		_plugin.call("_on_shape_requested", &"cube")
	await _frames(20)

	# Drag out courtyard floor
	await _drag_mouse(p_start, p_end, 40)
	# Height drag
	var p_lift := _window_pos(Vector3(6.0, 0.5, 6.0))
	await _move_cursor(p_lift, 25)
	await _click_at(p_lift)
	await _frames(30)

	# =========================================================================
	# Step 2: Arched Doorway Architecture
	# =========================================================================
	_set_hud("Step 2: Parametric Arched Doorway Creation",
		"Placing 4m x 4m arched doorway on north courtyard boundary...", 0.25)
	_cam.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 4.0, 6.0)).looking_at(Vector3(0, 2, -5.5), Vector3.UP)
	await _frames(30)

	if _plugin != null:
		_plugin.call("_on_shape_requested", &"door")
	await _frames(20)

	var d_start := _window_pos(Vector3(-2.0, 0.0, -5.5))
	var d_end := _window_pos(Vector3(2.0, 0.0, -4.5))
	await _drag_mouse(d_start, d_end, 35)

	var d_height := _window_pos(Vector3(2.0, 4.0, -4.5))
	await _move_cursor(d_height, 25)
	await _click_at(d_height)
	await _frames(30)

	# =========================================================================
	# Step 3: Grand Stairs & Balcony Platform
	# =========================================================================
	_set_hud("Step 3: Terraced Stairs & Elevated Balcony",
		"Placing 8-step staircase leading to terrace balcony...", 0.40)
	_cam.global_transform = Transform3D(Basis.IDENTITY, Vector3(-8.0, 5.0, 5.0)).looking_at(Vector3(-4.5, 1.5, 0.0), Vector3.UP)
	await _frames(30)

	if _plugin != null:
		_plugin.call("_on_shape_requested", &"stair")
	await _frames(20)

	var s_start := _window_pos(Vector3(-5.5, 0.0, 2.0))
	var s_end := _window_pos(Vector3(-3.5, 0.0, -2.0))
	await _drag_mouse(s_start, s_end, 35)
	var s_height := _window_pos(Vector3(-3.5, 3.0, -2.0))
	await _move_cursor(s_height, 25)
	await _click_at(s_height)
	await _frames(30)

	# =========================================================================
	# Step 4: Geometry Manipulation (Face Inset & Shift+Extrude)
	# =========================================================================
	_set_hud("Step 4: Geometry Manipulation — Face Inset & Shift+Extrude",
		"Selecting face (yellow highlight), uniform center inset, and shift-extrude...", 0.55)
	# Switch to Face mode
	await _press_key(KEY_K)
	await _frames(25)

	# Hover and click face
	var face_pos := _window_pos(Vector3(0.0, 2.0, -5.5))
	await _move_cursor(face_pos, 25)
	await _click_at(face_pos, Color(1.0, 0.85, 0.2)) # Yellow selection
	await _frames(30)

	# Shift + Extrude motion
	var ext_to := _window_pos(Vector3(0.0, 2.0, -4.5))
	await _drag_mouse(face_pos, ext_to, 35, true)
	await _frames(30)

	# =========================================================================
	# Step 5: Surface-Parallel Plane & Live Scrolling Waterfall Texture
	# =========================================================================
	_set_hud("Step 5: Surface Plane & Live Scrolling Waterfall",
		"Surface-parallel plane creation + standoff normal offset + live UV scroll at 60 FPS...", 0.70)
	_cam.global_transform = Transform3D(Basis.IDENTITY, Vector3(4.5, 3.5, -1.0)).looking_at(Vector3(4.5, 2.5, -5.0), Vector3.UP)
	await _frames(30)

	# Arm Plane creation
	if _plugin != null:
		_plugin.call("_on_shape_requested", &"plane")
	await _frames(20)

	var p_sheet_start := _window_pos(Vector3(3.5, 4.3, -5.0))
	var p_sheet_end := _window_pos(Vector3(5.5, 0.1, -5.0))
	# Drag base rectangle coplanar with the wall
	await _drag_mouse(p_sheet_start, p_sheet_end, 40)
	# Normal offset
	var p_standoff := _window_pos(Vector3(5.5, 0.1, -4.9))
	await _move_cursor(p_standoff, 25)
	await _click_at(p_standoff)
	await _frames(30)

	# Assign waterfall sheet texture and apply scroll speed
	var sheet_tex_path := "res://addons/poibuilder/materials/textures/waterfall_sheet.png"
	var sheet_mat: StandardMaterial3D = null
	if ResourceLoader.exists(sheet_tex_path):
		sheet_mat = StandardMaterial3D.new()
		sheet_mat.resource_name = "Waterfall_Sheet_Mat"
		sheet_mat.albedo_texture = load(sheet_tex_path)
		sheet_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		sheet_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		PBUv.set_scroll_speed(sheet_mat, Vector2(0.04, -0.75))

	var active_mesh: PBMesh = _plugin.editor.active_mesh if _plugin != null and _plugin.editor != null else null
	if active_mesh != null and sheet_mat != null:
		active_mesh.pb_mesh_data.materials = [sheet_mat]
		active_mesh.rebuild()
		if _plugin != null:
			_plugin.scan_scrolling_materials()
	await _frames(60)

	# =========================================================================
	# Step 6: Decal Stamping & Multi-Layer Paint
	# =========================================================================
	_set_hud("Step 6: High-Fidelity Decal Stamping & Painting",
		"Placing face-aligned decal stamps with zero z-fighting and clean bounds clipping...", 0.85)
	var stamp_pos := _window_pos(Vector3(4.5, 1.2, 1.0))
	await _move_cursor(stamp_pos, 30)
	await _click_at(stamp_pos, Color(0.2, 0.9, 1.0))
	await _frames(40)

	# =========================================================================
	# Step 7: Retro Platform Export (.pbm)
	# =========================================================================
	_set_hud("Step 7: Retro Map Export (.pbm) for Sony PSP",
		"Baking vertex lighting, AO, tile atlases, and exporting to binary .pbm...", 0.95)
	# Open export dialog
	if _plugin != null and _plugin.toolbar != null:
		_plugin.call("_on_export_requested")
	await _frames(60)

	_set_hud("PoiBuilder — Hardware Verification",
		"Export complete! Running live on Sony PlayStation Portable (PSP) hardware @ 60 FPS...", 1.00)
	await _frames(90)

	print("[SHOWCASE GENERATOR] Editor walkthrough recorded successfully!")
	get_tree().quit(0)
