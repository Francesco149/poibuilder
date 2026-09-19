## fly_rig.gd — the fly bench's free camera + frame-time HUD, one Control.
## Input and movement mirror the retro viewer (WASD + mouse, Shift turbo,
## wheel speed), and the HUD is the numbers that make smoothness legible:
## a mangohud-style rolling frame-time graph with 60/30 fps reference lines
## plus median / 1% low (p99) / worst / hitches over BOTH a 240-frame rolling
## window and the whole session. Created (and driven) by fly_bench.gd; the
## exact same scene assembly as frame_pacing_bench.gd via BenchVariants.
extends Control

const WINDOW_FRAMES := 240
const GRAPH_SIZE := Vector2(470, 140)
const GRAPH_MARGIN := 16.0
const SESSION_BUCKET_MS := 0.2
const SESSION_BUCKETS := 1500 # 0.2 ms buckets cover 0..300 ms frames

const BG := Color(0.02, 0.04, 0.07, 0.68)
const FRAME_COLOR := Color(0.55, 0.65, 0.8, 0.9)
const BAR_COLOR := Color(0.35, 0.8, 1.0, 0.95)
const BAR_OVER_60 := Color(1.0, 0.62, 0.15, 0.95)
const BAR_OVER_30 := Color(1.0, 0.2, 0.15, 0.95)
const LINE_60 := Color(0.3, 1.0, 0.5, 0.8)
const LINE_30 := Color(1.0, 0.62, 0.15, 0.8)
const TEXT_DIM := Color(0.85, 0.9, 1.0, 0.8)

var camera: Camera3D
var variant := ""
var spawn_pose: Array = []
var pois: Array = []

var mouse_captured := false
var yaw := 0.0
var pitch := 0.0
var mouse_sensitivity := 0.003
var move_speed := 8.0
var boost_multiplier := 3.0

# Frame record: a 240-frame rolling window (exact percentiles via sort) and
# a whole-session histogram (0.2 ms buckets — quantiles without re-sorting
# 100k+ frames every update).
var _window := PackedFloat64Array()
var _window_sum := 0.0
var _hist := PackedInt32Array()
var _session_frames := 0
var _session_ms := 0.0
var _session_worst := 0.0
var _last_ms := 0.0
var _prev_us := 0

var _hud_visible := true
var _graph_visible := true
var _y_scale := 33.4
var _font: Font

var title_label: Label
var stats_label: Label
var help_label: Label
var hint_label: Label
var _stats_cooldown := 0.0

func setup(cam: Camera3D, variant_name: String, gpu: String,
		spawn: Array, teleports: Array) -> void:
	camera = cam
	variant = variant_name
	spawn_pose = spawn
	pois = teleports
	_hist.resize(SESSION_BUCKETS)
	_font = _load_mono_font()
	# Start where the spawn pose looks, not at identity rotation: the first
	# mouse motion must continue from the spawn view, not snap to it.
	pitch = camera.rotation.x
	yaw = camera.rotation.y

	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)

	title_label = _make_label(14, Color.WHITE, Vector2(14, 10))
	title_label.text = "PoiBuilder fly bench — %s — %s — %s — vsync off" % [
		BenchVariants.display_name(variant),
		RenderingServer.get_current_rendering_method(), gpu]
	stats_label = _make_label(14, Color.WHITE, Vector2(14, 32))
	help_label = _make_label(12, TEXT_DIM, Vector2(14, 102))
	var poi_names := []
	for p in pois:
		poi_names.append(str(p[0]))
	var help_text := "WASD + mouse: fly   Space/E: up   Q/C: down   Shift: turbo   wheel: speed\n" + \
		"1..%d: photo poses (%s)   R: spawn\n" + \
		"H/Tab: HUD   G: graph   Esc: release mouse / quit"
	help_label.text = help_text % [pois.size(), ", ".join(poi_names)]
	hint_label = _make_label(14, Color.WHITE, Vector2.ZERO)
	hint_label.text = "click to capture the mouse and fly — Esc twice quits"
	hint_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM,
		Control.PRESET_MODE_MINSIZE, 48.0)
	_update_stats_text()

func _make_label(font_size: int, color: Color, pos: Vector2) -> Label:
	var lbl := Label.new()
	if _font != null:
		lbl.add_theme_font_override("font", _font)
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)
	lbl.position = pos
	add_child(lbl)
	return lbl

## The HUD must stay readable over a bright sky; a monospaced font also keeps
## the stat columns aligned. Candidate paths cover this workstation's guard
## container (Linux) and the Windows bench box; fall back to Godot's font.
static func _load_mono_font() -> Font:
	for path in [
		"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
		"/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"C:/Windows/Fonts/consola.ttf",
	]:
		if FileAccess.file_exists(path):
			var f := FontFile.new()
			if f.load_dynamic_font(path) == OK:
				return f
	return null

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
				if mouse_captured:
					_capture_mouse(false)
				else:
					get_tree().quit()
			elif ke.keycode == KEY_H or ke.keycode == KEY_TAB:
				_hud_visible = not _hud_visible
				title_label.visible = _hud_visible
				stats_label.visible = _hud_visible
				help_label.visible = _hud_visible
				hint_label.visible = _hud_visible and not mouse_captured
			elif ke.keycode == KEY_G:
				_graph_visible = not _graph_visible
			elif ke.keycode == KEY_R:
				_teleport(spawn_pose)
			elif ke.keycode >= KEY_1 and ke.keycode <= KEY_5:
				var idx := ke.keycode - KEY_1
				if idx < pois.size():
					_teleport(pois[idx])

func _teleport(pose: Array) -> void:
	camera.position = pose[0]
	var look := ((pose[1] as Vector3) - (pose[0] as Vector3)).normalized()
	pitch = asin(clampf(look.y, -1.0, 1.0))
	yaw = atan2(-look.x, -look.z)
	camera.rotation = Vector3(pitch, yaw, 0.0)

func _capture_mouse(capture: bool) -> void:
	mouse_captured = capture
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if capture else Input.MOUSE_MODE_VISIBLE
	hint_label.visible = _hud_visible and not capture

func _process(delta: float) -> void:
	var now := Time.get_ticks_usec()
	if _prev_us > 0:
		_record((now - _prev_us) / 1000.0)
	_prev_us = now
	_move(delta)
	_stats_cooldown -= delta
	if _stats_cooldown <= 0.0:
		_stats_cooldown = 0.15
		_update_stats_text()
	queue_redraw()

func _move(delta: float) -> void:
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

func _record(ms: float) -> void:
	_last_ms = ms
	_window.append(ms)
	_window_sum += ms
	if _window.size() > WINDOW_FRAMES:
		_window_sum -= _window[0]
		_window.remove_at(0)
	var bucket := clampi(int(ms / SESSION_BUCKET_MS), 0, SESSION_BUCKETS - 1)
	_hist[bucket] += 1
	_session_frames += 1
	_session_ms += ms
	_session_worst = maxf(_session_worst, ms)

func _hist_quantile(q: float) -> float:
	if _session_frames == 0:
		return 0.0
	var target := q * float(_session_frames)
	var acc := 0
	for i in range(_hist.size()):
		acc += _hist[i]
		if float(acc) >= target:
			return (i + 1) * SESSION_BUCKET_MS
	return SESSION_BUCKETS * SESSION_BUCKET_MS

func _window_stats() -> Dictionary:
	var n := _window.size()
	if n == 0:
		return {}
	var sorted := Array(_window)
	sorted.sort()
	var median: float = sorted[n / 2]
	var over_60 := 0
	var over_30 := 0
	var hitches := 0
	for v: float in sorted:
		if v > 16.7: over_60 += 1
		if v > 33.3: over_30 += 1
		if v > median * 2.0: hitches += 1
	return {
		"frames": n,
		"median": median,
		"p99": sorted[mini(int(n * 0.99), n - 1)],
		"worst": sorted[n - 1],
		"pct_over_60": 100.0 * over_60 / n,
		"pct_over_30": 100.0 * over_30 / n,
		"hitches": hitches,
		"window_s": _window_sum / 1000.0,
	}

func _update_stats_text() -> void:
	if stats_label == null:
		return
	if _session_frames == 0:
		stats_label.text = "recording…"
		return
	var ws := _window_stats()
	var p99 := _hist_quantile(0.99)
	var stats_text := "now %5.2f ms  %6.0f fps   avg %5.2f ms   draws %d   prims %s\n" + \
		"session (%d f, %.1f s)  median %5.2f  1%% low %6.2f ms (%4.0f fps)  worst %6.2f\n" + \
		"window (%d f ≈ %.1f s)  median %5.2f  1%% low %6.2f  >16.7 %5.1f%%  >33.3 %5.1f%%  hitches %d"
	stats_label.text = stats_text % [
			_last_ms, 1000.0 / maxf(_last_ms, 0.01), _session_ms / _session_frames,
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			_human_count(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
			_session_frames, _session_ms / 1000.0,
			_hist_quantile(0.5), p99, 1000.0 / maxf(p99, 0.01), _session_worst,
			ws["frames"], ws["window_s"], ws["median"], ws["p99"],
			ws["pct_over_60"], ws["pct_over_30"], ws["hitches"],
		]

static func _human_count(v: int) -> String:
	if v >= 1000000:
		return "%.2fM" % (v / 1000000.0)
	if v >= 1000:
		return "%.0fK" % (v / 1000.0)
	return str(v)

func _draw() -> void:
	if not _hud_visible:
		return
	# Panel behind the text block so it survives a bright sky.
	var text_w := maxf(maxf(title_label.get_minimum_size().x,
		stats_label.get_minimum_size().x), help_label.get_minimum_size().x)
	draw_rect(Rect2(8, 4, text_w + 16, 144), BG)
	if hint_label.visible and hint_label.size.x > 0:
		draw_rect(Rect2(hint_label.position - Vector2(10, 5),
			hint_label.size + Vector2(20, 10)), BG)
	if _graph_visible:
		_draw_graph()

func _draw_graph() -> void:
	var r := Rect2(Vector2(GRAPH_MARGIN, size.y - GRAPH_SIZE.y - GRAPH_MARGIN), GRAPH_SIZE)
	draw_rect(r, BG)
	draw_rect(r, FRAME_COLOR, false, 1.0)
	var n := _window.size()
	if n == 0:
		return
	# Y scale: at least 17 ms so the 60 fps line exists, and the window's
	# worst CEILINGED AT 50 ms (the 20 fps wall) — one load spike (1172 ms
	# here) must not flatten every real frame into invisibility; worse
	# frames clip red at the top, which is what the graph is saying anyway.
	var ws := _window_stats()
	var target := maxf(17.0, ceilf(minf(ws["worst"] * 1.05, 50.0) / 5.0) * 5.0)
	_y_scale = lerpf(_y_scale, target, 0.2)
	var base_y := r.position.y + r.size.y - 8.0
	var maxh := r.size.y - 24.0
	var bw := (r.size.x - 8.0) / float(WINDOW_FRAMES)
	for i in range(n):
		var ms := _window[i]
		var h := clampf(ms / _y_scale, 0.0, 1.0) * maxh
		var col := BAR_COLOR
		if ms > 33.3:
			col = BAR_OVER_30
		elif ms > 16.7:
			col = BAR_OVER_60
		var x := r.position.x + 4.0 + i * bw
		draw_line(Vector2(x, base_y), Vector2(x, base_y - h), col, maxf(bw - 0.4, 1.0))
	var font := _font if _font != null else ThemeDB.fallback_font
	for ref in [[16.7, LINE_60, "60"], [33.3, LINE_30, "30"]]:
		var ms: float = ref[0]
		if ms > _y_scale:
			continue
		var y := base_y - ms / _y_scale * maxh
		draw_line(Vector2(r.position.x + 2.0, y), Vector2(r.end.x - 2.0, y), ref[1], 1.0)
		if font != null:
			draw_string(font, Vector2(r.end.x - 44.0, y - 3.0), "%s fps" % ref[2],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, ref[1])
	# The window median: the line hitches (2× median) are measured against.
	if ws["median"] <= _y_scale:
		var y: float = base_y - ws["median"] / _y_scale * maxh
		draw_line(Vector2(r.position.x + 2.0, y), Vector2(r.end.x - 2.0, y),
			Color(1, 1, 1, 0.35), 1.0)
		if font != null:
			draw_string(font, Vector2(r.position.x + 6.0, y - 3.0), "median",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.5))
