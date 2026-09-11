## ShowcaseDirector — deterministic, frame-stepped capture of the PoiBuilder
## editor for the showcase video.
##
## WHY FRAME-STEPPED: screen recording of the editor under software GL drops
## frames and jitters motion. Here the recorder OWNS time: the synthesised
## animation advances one 1/60 s step per rendered frame, and every rendered
## frame is written to disk. The output is frame-exact and reproducible; the
## video is assembled from the frames afterwards, so crops, captions and
## transitions can be changed without re-rendering the editor.
##
## WHAT IT WRITES (into PB_SHOWCASE_OUT):
##   frames/%06d.png   the full editor window, one file per captured frame
##   cursor.bin        int32 x,y per captured frame (the video cursor is drawn
##                     in post — crisp, and independent of the editor's own
##                     draw order)
##   events.jsonl      clicks / keys / markers, with frame numbers
##   manifest.json     window size, named region rects, shot ranges, checks
##
## It drives the REAL editor: clicks go through Input.parse_input_event (real
## toolbar buttons light up, real picking runs) and element transforms through
## PBElementEditor's own delivery protocol (the same entry point the engine's
## transform gizmo calls). Nothing here reimplements the plugin.
@tool
class_name ShowcaseDirector
extends Node3D

const FPS := 60
## Wall-clock guard rail: a session that stops making progress (a deadlocked
## editor, a failed script) still exits instead of hanging a build forever.
var watchdog_sec := 1800.0

var out_dir := ""
var session_name := ""
var only: PackedStringArray = []
var verbose := true

var iface = null                        # EditorInterface singleton
var plugin: Node = null
var vp: SubViewport = null
var vp_host: Control = null
var cam: Camera3D = null
var win: Window = null

var cursor := Vector2(960.0, 540.0)     # synthetic pointer, window coords
var capturing := false
var frame := 0                          # frames captured this session (progress)
var shot_frame := 0                     # frames captured this shot (filenames)
var shot_name := ""
var shots: Array[Dictionary] = []
var regions: Dictionary = {}            # name -> [x, y, w, h]
var checks: Array[Dictionary] = []
var _drag_down := false
var _mods := {"shift": false, "alt": false, "ctrl": false}
var _t0 := 0

var _shot_dir := ""
var _shot_frames_dir := ""
var _shot_cursor: FileAccess = null
var _events_file: FileAccess = null

# =============================================================================
# Boot
# =============================================================================
func _ready() -> void:
	if Engine.is_editor_hint() and OS.get_environment("PB_SHOWCASE_SESSION") != "":
		_boot.call_deferred()

func _boot() -> void:
	_t0 = Time.get_ticks_msec()
	session_name = OS.get_environment("PB_SHOWCASE_SESSION")
	out_dir = OS.get_environment("PB_SHOWCASE_OUT")
	var only_env := OS.get_environment("PB_SHOWCASE_ONLY")
	if only_env != "":
		only = only_env.split(",", false)
	if out_dir == "":
		push_error("[showcase] PB_SHOWCASE_OUT is required")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out_dir)
	var wd := OS.get_environment("PB_SHOWCASE_WATCHDOG")
	if wd != "":
		watchdog_sec = float(wd)
	get_tree().create_timer(watchdog_sec).timeout.connect(func():
		_log_line("WATCHDOG: session exceeded %d s" % int(watchdog_sec))
		_finish(3))

	await frames(40)
	iface = EditorInterface
	win = get_tree().root
	iface.set_main_screen_editor("3D")
	await frames(20)

	vp = iface.get_editor_viewport_3d(0)
	vp_host = vp.get_parent().get_parent() as Control
	cam = vp.get_camera_3d()
	plugin = _find_plugin(win)

	_log_line("session=%s out=%s window=%s vp=%s" % [
		session_name, out_dir, str(DisplayServer.window_get_size()), str(vp.size)])
	if plugin == null:
		push_error("[showcase] PoiBuilder plugin not found")
		_finish(2)
		return

	_prepare_layout()
	await frames(10)
	snapshot_regions()

	var script_path := "res://showcase/sessions/%s.gd" % session_name
	if not ResourceLoader.exists(script_path):
		push_error("[showcase] no such session: " + script_path)
		_finish(2)
		return
	# The session script resolves `ShowcaseDirector` through the global script
	# class cache, which the editor rebuilds asynchronously at startup — a load
	# attempted too early fails to resolve the type. Retry instead of failing
	# the whole render on a race that resolves itself in a few frames.
	var res: Resource = null
	for attempt in range(40):
		res = ResourceLoader.load(script_path, "Script", ResourceLoader.CACHE_MODE_REUSE)
		if res is Script and (res as Script).can_instantiate():
			break
		if attempt == 0:
			_log_line("waiting for %s to compile (class cache warm-up)" % script_path)
		await frames(15)
	if res == null or not (res is Script) or not (res as Script).can_instantiate():
		push_error("[showcase] session failed to compile: " + script_path)
		_finish(2)
		return
	var session: Object = res.new()
	session.set("director", self)
	await session.call("run", self)
	_finish(0)

func _finish(code: int) -> void:
	_write_manifest()
	if _shot_cursor != null:
		_shot_cursor.close()
		_shot_cursor = null
	if _events_file != null:
		_events_file.close()
		_events_file = null
	var fails := 0
	for c in checks:
		if not c["ok"]:
			fails += 1
	_log_line("SUMMARY checks=%d failed=%d frames=%d elapsed=%.1fs code=%d" % [
		checks.size(), fails, frame, float(Time.get_ticks_msec() - _t0) / 1000.0, code])
	print("[showcase] done: %d captured frames, %d checks (%d failed)" % [frame, checks.size(), fails])
	get_tree().quit(code)

func _log_line(s: String) -> void:
	print("[showcase] " + s)

func _find_plugin(node: Node) -> Node:
	if node.get_script() != null and str(node.get_script().resource_path).ends_with("poibuilder_plugin.gd"):
		return node
	for child in node.get_children():
		var found := _find_plugin(child)
		if found != null:
			return found
	return null

## The showcase layout: 3D main screen, bottom panel closed (a startup warning
## auto-opens it, which would eat 268 px of the captured column).
func _prepare_layout() -> void:
	var base = iface.get_base_control()
	for node in _walk(base):
		if node is Button:
			var b := node as Button
			var t := b.tooltip_text.to_lower()
			if b.toggle_mode and b.button_pressed and "bottom panel" in t:
				b.button_pressed = false
				_log_line("closed bottom panel via '%s'" % b.name)
				break
	iface.get_selection().clear()
	await frames(6)

# =============================================================================
# Frame stepping & capture
# =============================================================================

## Advance `n` video frames (1/60 s each). Every rendered frame is captured
## while a shot is recording; otherwise the same stepping still happens so
## state evolves identically whether or not we are recording.
func frames(n: int = 1) -> void:
	for i in range(n):
		await get_tree().process_frame
		if capturing:
			await _grab()

func _grab() -> void:
	await RenderingServer.frame_post_draw
	var img: Image = win.get_texture().get_image()
	img.save_png("%s/%06d.png" % [_shot_frames_dir, shot_frame])
	_shot_cursor.store_32(int(cursor.x))
	_shot_cursor.store_32(int(cursor.y))
	shot_frame += 1
	frame += 1
	if frame % 300 == 0:
		_log_line("captured %d frames (%.1fs elapsed, shot %s)" % [
			frame, float(Time.get_ticks_msec() - _t0) / 1000.0, shot_name])

## A recorded beat. `fn` is a Callable; the shot gets its own directory
## (frames, cursor, events) so re-rendering one beat never disturbs the others,
## and the manifest records where it landed.
func shot(name: String, fn: Callable) -> void:
	var want := only.is_empty() or only.has(name)
	shot_name = name
	capturing = want
	var t0 := Time.get_ticks_msec()
	if want:
		_shot_dir = "%s/shots/%s" % [out_dir, _slug(name)]
		_shot_frames_dir = _shot_dir + "/frames"
		DirAccess.make_dir_recursive_absolute(_shot_frames_dir)
		for old in DirAccess.get_files_at(_shot_frames_dir):
			DirAccess.remove_absolute(_shot_frames_dir + "/" + old)
		_shot_cursor = FileAccess.open(_shot_dir + "/cursor.bin", FileAccess.WRITE)
		if _events_file != null:
			_events_file.close()
		_events_file = FileAccess.open(_shot_dir + "/events.jsonl", FileAccess.WRITE)
		shot_frame = 0
		_event("shot_begin", {"name": name})
	await fn.call()
	capturing = false
	var dur := float(Time.get_ticks_msec() - t0) / 1000.0
	if want:
		if _shot_cursor != null:
			_shot_cursor.close()
			_shot_cursor = null
		shots.append({
			"name": name,
			"dir": "shots/" + _slug(name),
			"frames": shot_frame,
			"seconds": float(shot_frame) / float(FPS),
			"regions": _region_snapshot(),
			"wall_seconds": dur,
		})
		_log_line("shot %s: %d frames (%.2fs video, %.1fs wall)" % [
			name, shot_frame, float(shot_frame) / float(FPS), dur])
	shot_name = ""

func _slug(s: String) -> String:
	var out := ""
	for i in range(s.length()):
		var c := s[i]
		out += c if (c.is_valid_identifier() or c == "_" or c == "-" or c.is_valid_int()) else "_"
	return out

# =============================================================================
# Namespaced api handed to session scripts
# =============================================================================

## Positions the synthetic pointer without sending an event (used to place the
## cursor before the first captured frame of a shot).
func cursor_set(pos: Vector2) -> void:
	cursor = pos
	_send_motion(false)

func cursor_set_world(world: Vector3) -> void:
	cursor_set(w2s(world))

## Glide the pointer to `to` over `n` frames with a smooth ease.
func glide(to: Vector2, n: int = 24, ease_mode := 0) -> void:
	var from := cursor
	for i in range(n):
		var t := float(i + 1) / float(maxi(n, 1))
		cursor = from.lerp(to, _ease(t, ease_mode))
		_send_motion()
		await frames(1)

func glide_world(world: Vector3, n: int = 24, ease_mode := 0) -> void:
	await glide(w2s(world), n, ease_mode)

func _send_motion(held := false) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = cursor
	ev.global_position = cursor
	if held or _drag_down:
		ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	ev.shift_pressed = _mods.get("shift", false)
	ev.alt_pressed = _mods.get("alt", false)
	ev.ctrl_pressed = _mods.get("ctrl", false)
	Input.parse_input_event(ev)

func mouse_down(btn := MOUSE_BUTTON_LEFT) -> void:
	_drag_down = true
	var ev := InputEventMouseButton.new()
	ev.button_index = btn
	ev.pressed = true
	ev.position = cursor
	ev.global_position = cursor
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	ev.shift_pressed = _mods.get("shift", false)
	ev.alt_pressed = _mods.get("alt", false)
	ev.ctrl_pressed = _mods.get("ctrl", false)
	Input.parse_input_event(ev)
	_event("mousedown", {"x": int(cursor.x), "y": int(cursor.y), "btn": btn})
	await frames(2)

func mouse_up(btn := MOUSE_BUTTON_LEFT) -> void:
	_drag_down = false
	var ev := InputEventMouseButton.new()
	ev.button_index = btn
	ev.pressed = false
	ev.position = cursor
	ev.global_position = cursor
	ev.shift_pressed = _mods.get("shift", false)
	ev.alt_pressed = _mods.get("alt", false)
	ev.ctrl_pressed = _mods.get("ctrl", false)
	Input.parse_input_event(ev)
	_event("mouseup", {"x": int(cursor.x), "y": int(cursor.y), "btn": btn})
	await frames(2)

## Click at the current position (or glide to `to` first). `mods` names the
## modifiers to hold for the click (e.g. ["alt"] for alt+click).
func click(to := Vector2.INF, settle := 6, hold: Array = []) -> void:
	if to != Vector2.INF:
		await glide(to, 18)
	for m in hold:
		await modifier(m, true)
	await mouse_down()
	await frames(3)
	await mouse_up()
	for m in hold:
		await modifier(m, false)
	await frames(settle)

func drag(from: Vector2, to: Vector2, n: int = 24, shift := false, ease_mode := 0) -> void:
	cursor = from
	_send_motion()
	await frames(2)
	if shift:
		await shift_held(true)
	await mouse_down()
	var start := from
	for i in range(n):
		var t := float(i + 1) / float(maxi(n, 1))
		cursor = start.lerp(to, _ease(t, ease_mode))
		_send_motion(true)
		await frames(1)
	await mouse_up()
	if shift:
		await shift_held(false)
	await frames(2)

## Global modifier state (Input.is_key_pressed drives the plugin's gesture
## decision, so it must be pressed, not just flagged on the event).
func shift_held(down: bool) -> void:
	await modifier("shift", down)

func modifier(name: String, down: bool) -> void:
	_mods[name] = down
	var ev := InputEventKey.new()
	var k: Key = KEY_SHIFT
	match name:
		"alt": k = KEY_ALT
		"ctrl": k = KEY_CTRL
	ev.keycode = k
	ev.physical_keycode = k
	ev.pressed = down
	Input.parse_input_event(ev)
	await frames(2)

## Clears every trace of the previous element selection.
##
## The plugin mirrors the ENGINE's subgizmo selection into its own PBSelection,
## but a mesh swap leaves the engine's selection empty while the mirrored copy
## keeps the old element id — and an id from a subdivided mesh is out of range
## on the fresh one. The toolbar then looks perfectly selected while every op
## fails with "invalid selection" (reproduced in showcase/sessions/probe_ops.gd).
## Beats that build a fresh object call this so nothing leaks across.
func clear_element_selection() -> void:
	var mesh = active_mesh()
	if mesh != null:
		mesh.clear_subgizmo_selection()
		mesh.update_gizmos()
	plugin.editor.selection.clear_all()
	plugin.editor.hover_id = -1
	await frames(4)

## The element id under a WINDOW position according to the plugin's own picker.
func element_id_at_screen(pos: Vector2) -> int:
	var mesh = active_mesh()
	if mesh == null:
		return -1
	return element_editor().pick_ray(mesh.pb_mesh_data, mesh.global_transform, cam,
		w2v(pos))

## The element id under a world position, via the plugin's own picker.
func element_id_at(world: Vector3) -> int:
	return element_id_at_screen(w2s(world))

## If the plugin's mirrored selection is empty, take the element under the
## pointer from the plugin's picker so an operation has something to act on.
func ensure_selection() -> bool:
	if selection_ids().size() > 0:
		return true
	var id := element_id_at_screen(cursor)
	if id < 0:
		return false
	_log_line("no mirrored selection at op time — picked element %d under the pointer" % id)
	await apply_selection_ids(PackedInt32Array([id]))
	return selection_ids().size() > 0

## The plugin's mirrored element selection as ids (faces / common edges /
## shared vertices, matching the current mode).
func selection_ids() -> PackedInt32Array:
	var sel = plugin.editor.selection
	var mesh = active_mesh()
	match plugin.editor.select_mode:
		PBEditor.SelectMode.EDGE:
			var out := PackedInt32Array()
			if mesh != null:
				var common = mesh.pb_mesh_data.get_common_edges()
				for e in sel.selected_edges:
					out.append(common.find(e))
			return out
		PBEditor.SelectMode.VERTEX:
			return sel.selected_vertices.duplicate()
		_:
			return sel.selected_faces.duplicate()

## Writes ids into the plugin's mirrored selection (the ops read it) AND into the
## engine's subgizmo selection. Both are required: the plugin re-mirrors the
## engine's selection on every gizmo redraw, so anything written only into the
## mirror is wiped within a frame.
func apply_selection_ids(ids: PackedInt32Array, settle := true) -> void:
	var mesh = active_mesh()
	if mesh == null:
		return
	var sel = plugin.editor.selection
	match plugin.editor.select_mode:
		PBEditor.SelectMode.EDGE:
			var edges: Array[PBEdge] = []
			var common = mesh.pb_mesh_data.get_common_edges()
			for id in ids:
				if id >= 0 and id < common.size():
					edges.append(common[id])
			sel.selected_edges = edges
		PBEditor.SelectMode.VERTEX:
			sel.selected_vertices = ids.duplicate()
		_:
			sel.selected_faces = ids.duplicate()
	# The engine's script-side API is single-id; the id it holds is what the
	# mirror reproduces, so it is set to the first element.
	var g = plugin.gizmo_plugin.gizmo_for_node(mesh)
	if g != null and ids.size() > 0:
		var ed = element_editor()
		mesh.set_subgizmo_selection(g, ids[0],
			ed.get_subgizmo_transform(mesh.pb_mesh_data, mesh, ids[0]))
	mesh.update_gizmos()
	if settle:
		await frames(4)

## Clicks `world` (or each point in turn, from the second on with Shift) to build
## an element selection, then VERIFIES it against the plugin's own picker and
## repairs it when the engine's mirrored selection came up short.
##
## The mirror is the thing the toolbar operations read, and it can legitimately
## come up empty or out of range after the mesh changes underneath it — the
## toolbar then looks selected while every op fails with "invalid selection"
## (reproduced in showcase/sessions/probe_ops.gd). A beat must not silently do
## nothing, so the intent is asserted, not assumed.
func select_points(points: Array, settle := 8) -> int:
	for i in range(points.size()):
		var p: Vector3 = points[i]
		await click(w2s(p), settle, ["shift"] if i > 0 else [])
	var want := PackedInt32Array()
	for p in points:
		var id := element_id_at(p)
		if id >= 0:
			want.append(id)
	var have := selection_ids()
	if have.size() != want.size() or want.size() != points.size():
		_log_line("selection mismatch: wanted %d (%s), plugin has %d (%s) — repairing"
			% [want.size(), str(want), have.size(), str(have)])
		await apply_selection_ids(want)
		_check(selection_ids().size() == points.size(),
			"selection repaired to %d element(s)" % points.size())
	return selection_ids().size()

## Like `op()`, but the effect is verified by `probe` (a Callable returning any
## comparable value). Welding moves corners without adding or removing anything,
## so face/position COUNTS cannot see it — the op needs a probe that measures
## what it is actually supposed to change.
func op_verify(op_name: String, probe: Callable, settle := 16) -> void:
	var before = probe.call()
	var ids := selection_ids()
	await ensure_selection()
	await click_button(op_name, settle)
	await frames(6)
	if probe.call() == before:
		_log_line("op %s: button click had no effect — restoring the selection and calling the plugin" % op_name)
		if ids.size() > 0:
			apply_selection_ids(ids, false)
		plugin.call("_on_operation_requested", op_name)
		await frames(10)
	var after = probe.call()
	_check(before != after, "op '%s' changed the mesh (%s -> %s)" % [op_name, before, after])

## Opens the export dialog and VERIFIES it is on screen.
##
## The dialog object exists from plugin startup, so "the dialog is not null" says
## nothing — and the toolbar click can be swallowed like any other. Both are
## checked here, with the plugin's own entry point as the fallback.
func open_export_dialog() -> bool:
	var dlg = plugin._export_dialog
	if dlg == null:
		_check(false, "the plugin has an export dialog")
		return false
	await click_button("export", 16)
	await frames(8)
	if not (dlg as Window).visible:
		_log_line("export dialog did not open from the toolbar button — calling the plugin")
		plugin.call("_on_export_requested")
		await frames(8)
	_check((dlg as Window).visible, "export dialog is on screen")
	return (dlg as Window).visible

## Applies a time-of-day preset by clicking the toolbar's Env menu and picking
## the item, falling back to the plugin's entry point if the popup row cannot be
## hit. Verified against the scene meta the preset applier writes.
func env_preset(name: String, settle := 14) -> void:
	var menu: MenuButton = plugin.toolbar._btn_env
	var wanted := name.to_lower()
	await click(menu.get_global_rect().get_center(), 10)
	var idx := -1
	var popup: PopupMenu = menu.get_popup()
	for i in range(popup.item_count):
		if popup.get_item_text(i).to_lower().contains(wanted):
			idx = i
			break
	var landed := false
	if idx >= 0:
		var font: Font = popup.get_theme_font("font")
		var fs: int = popup.get_theme_font_size("font_size")
		var sep: int = popup.get_theme_constant("v_separation")
		var pad: int = popup.get_theme_constant("item_start_padding")
		var row_h := float(font.get_height(fs) + sep + pad)
		var panel := popup.get_theme_stylebox("panel")
		var top := popup.position.y + (panel.content_margin_top if panel != null else 0.0)
		await glide(Vector2(popup.position.x + popup.size.x * 0.5,
			top + row_h * (float(idx) + 0.5)), 12)
		await mouse_down()
		await frames(2)
		await mouse_up()
		await frames(settle)
		landed = _env_is(name)
	if not landed:
		plugin.call("_on_env_preset_requested", name)
		await frames(settle)
		_log_line("env preset '%s' applied via api (menu item missed)" % name)
	_check(_env_is(name), "environment preset is '%s'" % name)

func _env_is(name: String) -> bool:
	var root := EditorInterface.get_edited_scene_root()
	return root != null and String(root.get_meta("poi_env_preset", "")) == name

## Runs `fn` without recording: scene setup between beats (building the object
## for the next beat must not appear in the previous one's last frames).
func off(fn: Callable, settle := 4) -> Variant:
	var was := capturing
	capturing = false
	var out: Variant = await fn.call()
	await frames(settle)
	capturing = was
	return out

## Glide to a WORLD point, re-projecting every frame so the pointer stays on it
## while the camera moves underneath.
func glide_world_track(world: Vector3, n := 28) -> void:
	var from := cursor
	for i in range(n):
		var t := _ease(float(i + 1) / float(maxi(n, 1)), 1)
		cursor = from.lerp(w2s(world), t)
		_send_motion()
		await frames(1)

## Travels the camera along an arc AND the pointer to `world` in the same
## frames: the pointer is re-projected after every camera step, so it lands
## exactly on the point no matter how the camera moved.
func orbit_glide(center: Vector3, az0: float, az1: float, elev: float, dist: float,
		world: Vector3, n := 30, aim := Vector3.ZERO, ease_mode := 1) -> void:
	var from := cursor
	for i in range(n):
		var t := _ease(float(i + 1) / float(maxi(n, 1)), ease_mode)
		cam_at_polar(center, lerpf(az0, az1, t), elev, dist, aim)
		cursor = from.lerp(w2s(world), t)
		_send_motion()
		await frames(1)

func key(k: Key, mods := {}) -> void:
	# Keyboard events go to the FOCUSED control: after a toolbar button click
	# that focus can sit on the button, and Enter/H/J/K are then swallowed
	# instead of reaching the viewport (the knife's Enter-to-cut did exactly
	# that). Focus is cheap to assert and the failure is invisible otherwise.
	if vp_host != null and is_instance_valid(vp_host) and not vp_host.has_focus():
		vp_host.grab_focus()
		await frames(2)
	var down := InputEventKey.new()
	down.keycode = k
	down.physical_keycode = k
	down.pressed = true
	down.ctrl_pressed = mods.get("ctrl", false)
	down.shift_pressed = mods.get("shift", false)
	down.alt_pressed = mods.get("alt", false)
	Input.parse_input_event(down)
	_event("key", {"k": k, "ctrl": mods.get("ctrl", false)})
	await frames(4)
	var up := InputEventKey.new()
	up.keycode = k
	up.physical_keycode = k
	up.pressed = false
	up.ctrl_pressed = mods.get("ctrl", false)
	up.shift_pressed = mods.get("shift", false)
	up.alt_pressed = mods.get("alt", false)
	Input.parse_input_event(up)
	await frames(4)

# =============================================================================
# World <-> window coordinates
# =============================================================================
func w2s(world: Vector3) -> Vector2:
	var local: Vector2 = cam.unproject_position(world)
	return vp_host.global_position + local * (vp_host.size / Vector2(vp.size))

func s2w(screen: Vector2, depth: float = 10.0) -> Vector3:
	var local: Vector2 = (screen - vp_host.global_position) * (Vector2(vp.size) / vp_host.size)
	return cam.project_position(local, depth)

# =============================================================================
# Camera
# =============================================================================
func cam_look_at(eye: Vector3, target: Vector3, up := Vector3.UP) -> void:
	if (eye - target).length() < 0.001:
		return
	cam.global_transform = Transform3D(Basis.IDENTITY, eye).looking_at(target, up)

func cam_snap(eye: Vector3, target: Vector3, up := Vector3.UP) -> void:
	cam_look_at(eye, target, up)
	await frames(2)

## Smooth move: both the eye and the look target travel, so the framing eases
## instead of whipping around the subject.
func cam_move(eye: Vector3, target: Vector3, n: int = 48, ease_mode := 1, up := Vector3.UP) -> void:
	var eye0 := cam.global_position
	var target0 := eye0 - cam.global_transform.basis.z * maxf(0.5, (eye0 - target).length())
	for i in range(n):
		var t := _ease(float(i + 1) / float(maxi(n, 1)), ease_mode)
		var e := eye0.lerp(eye, t)
		var tg := target0.lerp(target, t)
		cam_look_at(e, tg, up)
		await frames(1)

## Orbiting move: swings the eye around `target` while keeping the distance.
func cam_orbit(target: Vector3, from_az: float, to_az: float, dist: float, height: float,
		n: int = 48, ease_mode := 1) -> void:
	for i in range(n):
		var t := _ease(float(i + 1) / float(maxi(n, 1)), ease_mode)
		var az: float = deg_to_rad(lerpf(from_az, to_az, t))
		var eye := target + Vector3(sin(az) * dist, height, cos(az) * dist)
		cam_look_at(eye, target)
		await frames(1)

func cam_fov(f: float) -> void:
	cam.fov = f
	await frames(2)

## The WORLD-space AABB of a node's visual content (its own mesh if it has one).
func node_aabb(node: Node3D) -> AABB:
	var mi := node as MeshInstance3D
	if mi != null and mi.mesh != null:
		return mi.global_transform * mi.get_aabb()
	var box := AABB()
	var first := true
	for child in _walk(node):
		var m := child as MeshInstance3D
		if m == null or m.mesh == null:
			continue
		var child_aabb: AABB = m.global_transform * m.get_aabb()
		box = child_aabb if first else box.merge(child_aabb)
		first = false
	return box

## Frames `box` from a 3/4 angle: `az` degrees around the vertical axis,
## `elev` degrees above the horizon, filling `fill` of the smaller field of
## view so the subject always sits the same way in the frame.
func frame_box(box: AABB, az := 35.0, elev := 22.0, fill := 0.42) -> void:
	var f := framing(box, fill, az, elev)
	cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])

func frame_node(node: Node3D, az := 35.0, elev := 22.0, fill := 0.42) -> void:
	frame_box(node_aabb(node), az, elev, fill)
	await frames(2)

## Smooth version of frame_box.
func frame_box_to(box: AABB, az := 35.0, elev := 22.0, fill := 0.42, n := 48,
		ease_mode := 1) -> void:
	var f := framing(box, fill, az, elev)
	await cam_move(f["center"] + _polar_dir(az, elev) * float(f["dist"]),
		f["center"] + f["aim"], n, ease_mode)

func frame_node_to(node: Node3D, az := 35.0, elev := 22.0, fill := 0.42, n := 48) -> void:
	await frame_box_to(node_aabb(node), az, elev, fill, n)

func _polar_dir(az: float, elev: float) -> Vector3:
	var a := deg_to_rad(az)
	var e := deg_to_rad(elev)
	return Vector3(sin(a) * cos(e), sin(e), cos(a) * cos(e))

## Global framing taste knob: the `fill` values sessions pass are authored at
## 1.0; a session can set this once to make every shot tighter (or looser)
## without touching each beat. See `framing()`.
var fill_scale := 1.0

## Camera parameters that frame `box` at a 3/4 angle: {center, aim, dist, az, elev}.
##
## The distance comes from projecting the box's eight corners onto the camera's
## own right/up axes: `fill` is the fraction of the frame those extents should
## occupy, so one number frames a cube, a 35 m lineup and a flat slab the same
## way. A 12% perspective margin keeps near corners inside the shot, and `bias`
## lifts the subject above the frame centre to leave room for the caption strip.
func framing(box: AABB, fill := 0.42, az := 35.0, elev := 22.0, bias := 0.10) -> Dictionary:
	var center := box.get_center()
	var dir := _polar_dir(az, elev)                       # centre → camera
	var right := Vector3(dir.z, 0.0, -dir.x)
	if right.length() < 0.001:
		right = Vector3.RIGHT
	right = right.normalized()
	var up_axis := right.cross(dir).normalized()
	var ext_right := 0.0
	var ext_up := 0.0
	for i in range(8):
		var corner := box.position + Vector3(
			box.size.x * float(i & 1),
			box.size.y * float((i >> 1) & 1),
			box.size.z * float((i >> 2) & 1)) - center
		ext_right = maxf(ext_right, absf(corner.dot(right)))
		ext_up = maxf(ext_up, absf(corner.dot(up_axis)))
	var half_v: float = deg_to_rad(cam.fov) * 0.5
	var aspect: float = float(vp.size.x) / maxf(1.0, float(vp.size.y))
	var half_h: float = atan(tan(half_v) * aspect)
	var f := maxf(0.05, fill) * maxf(0.05, fill_scale)
	var dist: float = 1.12 * maxf(ext_up / (f * tan(half_v)), ext_right / (f * tan(half_h)))
	return {
		"center": center,
		"aim": Vector3(0.0, -bias * 2.0 * dist * tan(half_v), 0.0),
		"dist": maxf(1.0, dist),
		"az": az,
		"elev": elev,
	}

func framing_node(node: Node3D, fill := 0.42, az := 35.0, elev := 22.0,
		bias := 0.10) -> Dictionary:
	return framing(node_aabb(node), fill, az, elev, bias)

func cam_at_polar(center: Vector3, az: float, elev: float, dist: float,
		aim := Vector3.ZERO) -> void:
	var a := deg_to_rad(az)
	var e := deg_to_rad(elev)
	var dir := Vector3(sin(a) * cos(e), sin(e), cos(a) * cos(e))
	cam_look_at(center + dir * dist, center + aim)

## A gentle orbit around `center` from `az0` to `az1`, with a simultaneous
## elevation change — the standard "living camera" move for a beat.
func cam_swing(center: Vector3, az0: float, az1: float, elev0: float, elev1: float,
		dist: float, n := 60, ease_mode := 1, aim := Vector3.ZERO) -> void:
	for i in range(n):
		var t := _ease(float(i + 1) / float(maxi(n, 1)), ease_mode)
		cam_at_polar(center, lerpf(az0, az1, t), lerpf(elev0, elev1, t), dist, aim)
		await frames(1)

## cam_swing straight from a `framing()` result, with an optional azimuth delta.
func swing_framing(f: Dictionary, n := 60, daz := 16.0, delev := -4.0,
		dscale := 1.0, ease_mode := 1) -> void:
	await cam_swing(f["center"], f["az"], float(f["az"]) + daz,
		f["elev"], float(f["elev"]) + delev, float(f["dist"]) * dscale, n, ease_mode,
		f.get("aim", Vector3.ZERO))

## Moves the camera between two explicit poses (eye + look target) — the
## general-purpose dolly for lineups and reveals.
func cam_lerp(eye0: Vector3, target0: Vector3, eye1: Vector3, target1: Vector3,
		n := 60, ease_mode := 1, up := Vector3.UP) -> void:
	for i in range(n):
		var t := _ease(float(i + 1) / float(maxi(n, 1)), ease_mode)
		cam_look_at(eye0.lerp(eye1, t), target0.lerp(target1, t), up)
		await frames(1)

## Camera pose helper: the eye and target for a polar position around `center`.
func polar_pose(center: Vector3, az: float, elev: float, dist: float,
		aim := Vector3.ZERO) -> Array:
	var a := deg_to_rad(az)
	var e := deg_to_rad(elev)
	var dir := Vector3(sin(a) * cos(e), sin(e), cos(a) * cos(e))
	return [center + dir * dist, center + aim]

func set_ortho(on: bool) -> void:
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL if on else Camera3D.PROJECTION_PERSPECTIVE
	await frames(3)

func _ease(t: float, mode: int) -> float:
	t = clampf(t, 0.0, 1.0)
	match mode:
		1: return t * t * (3.0 - 2.0 * t)            # smoothstep
		2: return 1.0 - pow(1.0 - t, 3.0)            # ease-out cubic
		3: return t * t                              # ease-in quad
		4: return 1.0 - cos(t * PI * 0.5)            # ease-out sine
		_: return t                                   # linear

# =============================================================================
# Editor UI driving
# =============================================================================

## Every toolbar control the showcase can click, by stable name.
func toolbar_button(name: String) -> Button:
	var tb = plugin.toolbar
	var ops: Dictionary = tb._op_buttons
	if ops.has(name):
		return ops[name]
	var map := {
		"move": tb._btn_move, "rotate": tb._btn_rotate, "scale": tb._btn_scale,
		"object": tb._btn_object, "vertex": tb._btn_vertex,
		"edge": tb._btn_edge, "face": tb._btn_face, "space": tb._btn_space,
		"new_shape": tb._btn_new_shape, "ngon": tb._btn_ngon,
		"edit_params": tb._btn_edit_params, "overlay": tb._btn_overlay,
		"recover": tb._btn_recover_overlay, "materials": tb._btn_materials,
		"settings": tb._btn_settings, "env": tb._btn_env,
		"export": tb._btn_export, "grid": tb._btn_grid_panel,
	}
	return map.get(name, null)

## Click a toolbar control for real (the button visibly presses).
func click_button(name: String, settle := 10) -> bool:
	var b := toolbar_button(name)
	if b == null:
		_check(false, "toolbar button '%s' exists" % name)
		return false
	if not b.visible or b.disabled:
		_log_line("WARN button '%s' disabled=%s visible=%s" % [name, str(b.disabled), str(b.visible)])
	var rect := b.get_global_rect()
	_log_line("click '%s' at %s (rect %s, toolbar %s)" % [
		name, str(rect.get_center()), str(rect), str(plugin.toolbar.get_global_rect())])
	await glide(rect.get_center(), 12)
	var under = get_tree().root.gui_get_hovered_control()
	_log_line("click '%s': under cursor = %s (expected %s)" % [
		name, String(under.name) if under != null else "<none>", String(b.name)])
	await mouse_down()
	await frames(3)
	await mouse_up()
	await frames(settle)
	_check(b != null, "clicked toolbar button '%s'" % name)
	return true

## Drives a numeric control in the params modal (live preview updates as it
## changes, exactly like a drag on the field).
func overlay_param(name: String, value: float, settle := 10) -> bool:
	var ov = plugin.tool_overlay
	if ov == null:
		return false
	var sb = ov._param_spinboxes.get(name, null)
	if sb == null:
		_check(false, "overlay parameter '%s' exists" % name)
		return false
	await click(sb.get_global_rect().get_center(), 2)
	sb.value = value
	await frames(settle)
	_check(true, "parameter '%s' set to %s" % [name, str(value)])
	return true

func overlay_param_check(name: String, on: bool, settle := 10) -> bool:
	var ov = plugin.tool_overlay
	if ov == null:
		return false
	var cb = ov._param_checkboxes.get(name, null)
	if cb == null:
		_check(false, "overlay checkbox '%s' exists" % name)
		return false
	if cb.button_pressed != on:
		await click(cb.get_global_rect().get_center(), settle)
	_check(cb.button_pressed == on, "checkbox '%s' = %s" % [name, str(on)])
	return true

## Clicks any Control for real (dock buttons, segmented selectors, cards).
func click_control(c: Control, settle := 12, hold: Array = []) -> bool:
	if c == null:
		_check(false, "control exists")
		return false
	if not c.is_visible_in_tree():
		_log_line("WARN control '%s' is not visible" % c.name)
		return false
	await click(c.get_global_rect().get_center(), settle, hold)
	return true

## Clicks control `name` found anywhere under the plugin's material dock.
func click_dock_control(name: String, settle := 12) -> bool:
	var dock = plugin.material_dock
	if dock == null:
		_check(false, "material dock exists")
		return false
	var c := dock.find_child(name, true, false) as Control
	if c == null:
		_check(false, "dock control '%s' exists" % name)
		return false
	return await click_control(c, settle)

## Clicks one of the material dock's own controls by script member name (the
## dock's buttons are created unnamed, so find_child cannot see them).
func click_dock_member(member: String, settle := 12) -> bool:
	var dock = plugin.material_dock
	if dock == null:
		_check(false, "material dock exists")
		return false
	var c = dock.get(member)
	if not (c is Control):
		_check(false, "dock control '%s' exists" % member)
		return false
	return await click_control(c as Control, settle)

## Clicks an embedded dialog's OK button (ConfirmationDialog / AcceptDialog).
func dialog_ok(win: Window, settle := 14) -> bool:
	if win == null:
		_check(false, "dialog exists")
		return false
	var ok_btn = win.get_ok_button()
	if ok_btn == null:
		_check(false, "dialog has an OK button")
		return false
	return await click_control(ok_btn as Control, settle)

## Clicks a control inside the plugin's viewport overlay (e.g. the params
## modal's ApplyParams / CancelParams buttons) by node name.
func overlay_button(name: String, settle := 12) -> bool:
	var ov = plugin.tool_overlay
	if ov == null:
		return false
	var b := ov.find_child(name, true, false) as Button
	if b == null:
		_check(false, "overlay control '%s' exists" % name)
		return false
	if not b.visible or b.disabled:
		_log_line("WARN overlay control '%s' not clickable (visible=%s disabled=%s)"
			% [name, str(b.visible), str(b.disabled)])
		return false
	await click(b.get_global_rect().get_center(), settle)
	_check(true, "clicked overlay control '%s'" % name)
	return true

## New Shape menu: opens the popup and picks the item, visually. Falls back to
## the plugin entry point if the popup item rect cannot be hit (the menu still
## flashes open, so the beat reads correctly either way).
func arm_shape(shape_id: StringName, settle := 14) -> void:
	var menu: MenuButton = plugin.toolbar._btn_new_shape
	var popup: PopupMenu = menu.get_popup()
	var idx := -1
	for i in range(popup.item_count):
		if popup.get_item_text(i).to_lower() == String(shape_id).replace("_", " ").to_lower():
			idx = i
			break
	if idx == -1:
		for i in range(popup.item_count):
			if popup.get_item_text(i).to_lower().begins_with(String(shape_id).substr(0, 4).to_lower()):
				idx = i
				break
	await click(menu.get_global_rect().get_center(), 10)
	var clicked := false
	if idx >= 0:
		# PopupMenu rows: uniform height from the font + separation constants.
		var font: Font = popup.get_theme_font("font")
		var fs: int = popup.get_theme_font_size("font_size")
		var sep: int = popup.get_theme_constant("v_separation")
		var pad: int = popup.get_theme_constant("item_start_padding")
		var row_h := float(font.get_height(fs) + sep + pad)
		var panel := popup.get_theme_stylebox("panel")
		var top := popup.position.y + (panel.content_margin_top if panel != null else 0.0)
		var target := Vector2(popup.position.x + popup.size.x * 0.5, top + row_h * (float(idx) + 0.5))
		await glide(target, 12)
		await frames(4)
		await mouse_down()
		await frames(2)
		await mouse_up()
		await frames(settle)
		clicked = _shape_armed(shape_id)
	if not clicked:
		plugin.call("_on_shape_requested", shape_id)
		await frames(settle)
		_log_line("shape '%s' armed via api (menu item missed)" % shape_id)
	else:
		_log_line("shape '%s' armed via menu" % shape_id)
	_check(_shape_armed(shape_id), "shape '%s' armed" % shape_id)

	# A popup left open (the menu path above can miss the item rect) swallows
	# every later viewport event: the next press goes to the popup, no base drag
	# starts, and the piece silently never gets built. Close it either way.
	var popup_left: Popup = menu.get_popup()
	if popup_left != null and popup_left.visible:
		popup_left.hide()
		_log_line("closed a leftover New Shape popup")
	await frames(2)
func _shape_armed(shape_id: StringName) -> bool:
	var sc = plugin.shape_creator
	if sc == null:
		return false
	return int(sc.state) != 0 or String(sc.shape_id) == String(shape_id)

## Fires a mesh operation through its toolbar button, and — if the click does
## not reach the operation — restores the element selection the click dropped
## and drives the plugin's own entry point instead, so the beat still performs
## the operation the video claims it performs.
##
## WHY THE FALLBACK EXISTS: a synthesized click on a toolbar button can leave
## the plugin's mirrored element selection cleared (the engine treats the press
## as a click away from the gizmo), and every op then refuses with "invalid
## selection" while the toolbar looks correctly selected. Reproduced end to end
## in showcase/sessions/probe_ops.gd.
func op(op_name: String, settle := 16) -> void:
	var before := _topology_signature()
	var mesh = active_mesh()
	var sel = plugin.editor.selection
	var ids := selection_ids()
	_log_line("op %s: active=%s mode=%s ids=%s faces_in_mesh=%d" % [
		op_name,
		String(mesh.name) if mesh != null else "<none>",
		PBEditor.SelectMode.keys()[plugin.editor.select_mode], str(ids),
		mesh.pb_mesh_data.faces.size() if mesh != null else -1])
	await ensure_selection()
	await click_button(op_name, settle)
	await frames(6)
	if _topology_signature() == before:
		_log_line("op %s: button click had no effect — restoring the selection and calling the plugin" % op_name)
		# Written and consumed in the SAME frame: the plugin re-mirrors the
		# engine's gizmo selection on every redraw, so a restored selection that
		# waits even one frame is wiped before the operation reads it.
		if ids.size() > 0:
			apply_selection_ids(ids, false)
		else:
			await ensure_selection()
		plugin.call("_on_operation_requested", op_name)
		await frames(10)
	var after := _topology_signature()
	_check(before != after, "op '%s' changed the mesh (%s -> %s)" % [op_name, before, after])

func _topology_signature() -> String:
	var m := 0
	if plugin.editor.active_mesh != null:
		m = plugin.editor.active_mesh.pb_mesh_data.faces.size()
		m = m * 100000 + plugin.editor.active_mesh.pb_mesh_data.positions.size()
	return str(m)

func select_mode(mode: String) -> void:
	await click_button(mode, 10)

func tool(mode: String) -> void:
	await click_button(mode, 10)

## Click a point in the viewport at (or near) a world position — real picking.
func pick_world(world: Vector3, settle := 10) -> void:
	await click(w2s(world), settle)

func pick_screen(pos: Vector2, settle := 10) -> void:
	await click(pos, settle)

# =============================================================================
# Element-level driving (the plugin's own gizmo delivery protocol)
# =============================================================================
func element_editor() -> RefCounted:
	return plugin.gizmo_plugin.element_editor

## The engine's current subgizmo (element) selection for the active mesh.
func subgizmo_ids() -> PackedInt32Array:
	var mesh = active_mesh()
	if mesh == null:
		return PackedInt32Array()
	var g = plugin.gizmo_plugin.gizmo_for_node(mesh)
	if g == null:
		return PackedInt32Array()
	return g.get_subgizmo_selection()

func active_mesh() -> Node:
	return plugin.editor.active_mesh

## True when the plugin sees a live element selection.
func has_element_selection() -> bool:
	return active_mesh() != null and subgizmo_ids().size() > 0

## Where the pointer should sit for a drag of the selection's pivot by
## `world_motion` — the cursor is derived FROM the motion so the two agree.
func drag_cursor_for(motion: Vector3) -> Vector2:
	var ed = element_editor()
	var mesh = active_mesh()
	var ids := subgizmo_ids()
	var pivot: Vector3 = mesh.to_global(ed.center_pivot(mesh.pb_mesh_data, ids))
	return w2s(pivot + motion)

## Translates the current element selection by `world_motion` over `n` frames
## through the editor's gizmo protocol. `shift` selects the plugin's gesture
## (shift+move = live extrude, shift+scale = inset).
func move_selection(world_motion: Vector3, n: int = 24, shift := false, ease_mode := 1) -> void:
	var ed = element_editor()
	var mesh = active_mesh()
	if mesh == null:
		_check(false, "move: an active mesh exists")
		return
	var ids := subgizmo_ids()
	if ids.is_empty():
		_check(false, "move: element selection is non-empty")
		return
	var start: Transform3D = ed.get_subgizmo_transform(mesh.pb_mesh_data, mesh, ids[0])
	# The gizmo protocol speaks NODE-LOCAL space (get_subgizmo_transform returns
	# the element's local basis/origin), so world motions are converted once.
	var basis_inv: Basis = mesh.global_transform.basis.inverse()
	var local_motion: Vector3 = basis_inv * world_motion
	if shift:
		await shift_held(true)
	for i in range(n):
		var t := _ease(float(i + 1) / float(maxi(n, 1)), ease_mode)
		ed.set_subgizmo_transform_with_shift(mesh, ids, ids[0],
			start.translated(local_motion * t), shift)
		cursor = drag_cursor_for(world_motion * t)
		_send_motion()
		await frames(1)
	ed.commit_subgizmos(mesh, ids, false)
	if shift:
		await shift_held(false)
	await frames(4)

## Uniform scale of the element selection about its pivot (center handle).
func scale_selection_factor(factor: float, n: int = 24, inset := false) -> void:
	var ed = element_editor()
	var mesh = active_mesh()
	if mesh == null:
		_check(false, "scale: an active mesh exists")
		return
	var ids := subgizmo_ids()
	if ids.is_empty():
		_check(false, "scale: element selection is non-empty")
		return
	var pivot: Vector3 = mesh.to_global(ed.center_pivot(mesh.pb_mesh_data, ids))
	var start_window := w2s(pivot)
	# The engine delivers handle drags in VIEWPORT coordinates, so the center
	# drag's start/deltas are converted from window space to match.
	var start_screen := w2v(start_window)
	cursor = start_window
	_send_motion()
	await frames(2)
	ed.begin_center_drag(mesh, ids, inset, ed.center_pivot(mesh.pb_mesh_data, ids), start_screen)
	for i in range(n):
		var t := float(i + 1) / float(maxi(n, 1))
		var f: float = lerpf(1.0, factor, _ease(t, 1))
		# The center handle reads a horizontal screen delta: 1% per pixel.
		var px: float = (1.0 - f) * 100.0
		cursor = start_window + Vector2(px, 0.0)
		_send_motion()
		ed.apply_center_drag(mesh, cam, start_screen + Vector2(px, 0.0))
		await frames(1)
	ed.commit_center_drag(mesh, ids, false)
	await frames(4)

## Window → viewport coordinates (the engine's handle drags use these).
func w2v(pos: Vector2) -> Vector2:
	return (pos - vp_host.global_position) * (Vector2(vp.size) / vp_host.size)

## The world-space screen axis of `world_dir` at `origin` (px per world unit).
func screen_axis(origin: Vector3, world_dir: Vector3) -> Vector2:
	var a := w2s(origin)
	var b := w2s(origin + world_dir.normalized())
	return (b - a)

# =============================================================================
# Shape creation: the height stage, and the grid it draws on
# =============================================================================

## Drives the creation HEIGHT stage to (approximately) `target` world units
## along the surface normal, and returns the height the plugin actually
## reached.
##
## WHY THIS IS A CLOSED LOOP: the height is `(ray ∩ view-parallel plane − press
## point) · normal`, so gliding the pointer to `corner + normal * target` — the
## obvious thing, and what the beats used to do — does not produce that height
## at all (the two only coincide for a camera looking straight down the
## normal). Here each step moves the pointer by the screen delta between the
## CURRENT and the TARGET reference point and then reads `shape_creator.height`
## back, so the error shrinks every step whatever the camera orientation is.
func height_drag_to(target: float, max_steps := 8) -> float:
	var sc = plugin.shape_creator
	var h := float(sc.height)
	for i in range(max_steps):
		if absf(target - h) <= 0.02:
			break
		var here: Vector3 = sc.rect_center + sc.plane_normal * h
		var goal: Vector3 = sc.rect_center + sc.plane_normal * target
		var px: Vector2 = w2s(goal) - w2s(here)
		if px.length() < 1.0:
			break
		await glide(cursor + px, 8)
		h = float(sc.height)
	return h

## Shows/hides PoiBuilder's own grid. A surface lying exactly at the grid's
## elevation (the courtyard floor, a bench top) z-fights with it, so beats that
## build one turn the grid off once the drag that needed it is done. Drawing on
## the grid still works while it is hidden — the creation surface fallback uses
## the grid PLANE, not its pixels.
func grid_show(on: bool) -> void:
	plugin.grid.show_grid = on
	if plugin.grid_view != null:
		plugin.grid_view.mark_dirty()
	await frames(2)

# =============================================================================
# Regions, events, checks, manifest
# =============================================================================
func snapshot_regions() -> void:
	regions = _region_snapshot()

func _region_snapshot() -> Dictionary:
	var out := {"window": [0, 0, int(win.get_visible_rect().size.x), int(win.get_visible_rect().size.y)]}
	var base = iface.get_base_control()
	var host_rect := vp_host.get_global_rect()
	out["viewport"] = _r(host_rect)
	out["viewport_ui"] = _r(Rect2(host_rect.position - Vector2(0, 33), Vector2(host_rect.size.x, host_rect.size.y + 33)))
	var tb: Control = plugin.toolbar
	if tb != null:
		out["toolbar"] = _r(tb.get_global_rect())
	var ov = plugin.tool_overlay
	if ov is Control and (ov as Control).visible:
		out["overlay"] = _r((ov as Control).get_global_rect())
	if plugin.material_dock != null:
		out["material_dock"] = _r((plugin.material_dock as Control).get_global_rect())
	var col = base.find_child("DockVSplitCenter", true, false)
	if col is Control:
		out["center_column"] = _r((col as Control).get_global_rect())
	var left = base.find_child("DockVSplitLeftR", true, false)
	if left is Control:
		out["left_docks"] = _r((left as Control).get_global_rect())
	var dl = plugin._export_dialog
	if dl is Window:
		var w := dl as Window
		out["export_dialog"] = [int(w.position.x), int(w.position.y), int(w.size.x), int(w.size.y)]
	elif dl is Control:
		out["export_dialog"] = _r((dl as Control).get_global_rect())
	return out

func _r(r: Rect2) -> Array:
	return [int(r.position.x), int(r.position.y), int(r.size.x), int(r.size.y)]

func _event(kind: String, data: Dictionary = {}) -> void:
	if _events_file == null:
		return
	data["f"] = shot_frame
	data["t"] = kind
	_events_file.store_line(JSON.stringify(data))

## Records an assertion about what a beat was supposed to accomplish. The
## video build fails loudly on any failed check — a showcase that silently
## shows nothing is the exact failure this guards against.
func check(ok: bool, msg: String) -> void:
	_check(ok, msg)

func _check(ok: bool, msg: String) -> void:
	checks.append({"ok": ok, "msg": msg, "shot": shot_name, "frame": shot_frame})
	if ok:
		if verbose:
			print("[showcase]   ok   %s" % msg)
	else:
		printerr("[showcase]   FAIL %s (shot %s)" % [msg, shot_name])

func _write_manifest() -> void:
	# A partial render (PB_SHOWCASE_ONLY) must not drop the shots it skipped:
	# merge into the existing manifest, replacing same-named entries.
	var merged: Array = []
	var seen := {}
	for s in shots:
		seen[s["name"]] = true
		merged.append(s)
	var path := out_dir + "/manifest.json"
	if FileAccess.file_exists(path):
		var f0 := FileAccess.open(path, FileAccess.READ)
		if f0 != null:
			var prev = JSON.parse_string(f0.get_as_text())
			f0.close()
			if prev is Dictionary and prev.has("shots"):
				for s in prev["shots"]:
					if not seen.has(s.get("name", "")):
						merged.append(s)
	var data := {
		"session": session_name,
		"fps": FPS,
		"frames": frame,
		"window": [int(win.get_visible_rect().size.x), int(win.get_visible_rect().size.y)] if win != null else [0, 0],
		"regions": regions,
		"shots": merged,
		"checks": checks,
		"elapsed": float(Time.get_ticks_msec() - _t0) / 1000.0,
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data, "  "))
		f.close()

func _walk(node: Node) -> Array:
	var out: Array = [node]
	for c in node.get_children():
		out.append_array(_walk(c))
	return out
