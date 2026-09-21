## PBPaintTrace — per-frame trace of a LIVE paint session.
##
## Answers "what does the user actually feel" instead of what a synthetic
## bench produces: while you paint in a real editor session, every RENDERED
## frame writes one line with its delta and which paint stages ran inside
## it (pick / interpolated walk / dabs / upload flush), plus the
## input-event-to-drawn-frame latency. Long frames with a heavy handler are
## the plugin blocking the main thread; long frames with a light handler
## are render/editor/GPU cost — the trace separates the two, which a
## handler-only profiler cannot.
##
## Arm with PB_PAINT_TRACE=1 (any editor launch; `./trace_paint.sh` is the
## convenient runner). Recording covers the frames while a paint mode is
## ACTIVE (Paint/Stamp tab open); the trace lands in /tmp/pb_paint_trace.log
## and `tools/analyze_paint_trace.py` turns it into the jank story.
## Off by default and near-free: one bool check per hook.
@tool
class_name PBPaintTrace
extends RefCounted

static var enabled: bool = OS.get_environment("PB_PAINT_TRACE") != ""

const TRACE_PATH := "/tmp/pb_paint_trace.log"

static var _file: FileAccess = null
static var _file_failed: bool = false
static var _frame_hooked: bool = false
static var _last_draw_us: int = 0
static var _last_input_us: int = -1
static var _session_active: bool = false

## Per-frame accumulators, drained at the next frame_post_draw.
static var _events: int = 0
static var _stages: Dictionary = {} # StringName -> [usec, calls, bytes, pixels]

static func set_session_active(active: bool) -> void:
	if not enabled or _session_active == active:
		# Transition-only: PAINT <-> STAMP switches must not restart the window.
		return
	_ensure_file()
	_session_active = active
	if not active:
		# Don't let stale stage data bleed into a later session's first frame.
		_stages.clear()
		_events = 0
	_write("#S session %s" % ("begin" if active else "end"))
	if active:
		_ensure_frame_hook()

## Called by PBPaintProfile.add for every instrumented stage hit.
static func record_stage(stage: StringName, usec: int, calls: int, bytes: int, pixels: int) -> void:
	var e: Array = _stages.get(stage, [0, 0, 0, 0])
	e[0] = int(e[0]) + usec
	e[1] = int(e[1]) + calls
	e[2] = int(e[2]) + bytes
	e[3] = int(e[3]) + pixels
	_stages[stage] = e

## A paint-relevant input event reached the plugin's handler.
static func note_event(event: InputEvent) -> void:
	_events += 1
	_last_input_us = Time.get_ticks_usec()

## Closes the current frame and writes its line. Frames are recorded only
## while a paint mode is active — idle editor time stays out of the file.
static func _on_frame_drawn() -> void:
	var now := Time.get_ticks_usec()
	var dt_us := now - _last_draw_us if _last_draw_us > 0 else 0
	_last_draw_us = now
	if not _session_active:
		return
	var parts: PackedStringArray = []
	parts.append("F f=%d dt=%.2f" % [Engine.get_frames_drawn(), float(dt_us) / 1000.0])
	if _last_input_us > 0:
		parts.append("in=%.2f" % (float(now - _last_input_us) / 1000.0))
		_last_input_us = -1
	if _events > 0:
		parts.append("ev=%d" % _events)
		_events = 0
	var handler_us: int = _stage(&"handler")
	if handler_us > 0:
		parts.append("h=%.2f" % (float(handler_us) / 1000.0))
	for stage: StringName in [&"pick", &"interp_walk", &"dab_total", &"splat_dab", &"decal_dab", &"upload_flush"]:
		var e: Array = _stages.get(stage, [0, 0, 0, 0])
		if int(e[1]) > 0:
			parts.append("%s=%.2f/%d" % [stage, float(int(e[0])) / 1000.0, int(e[1])])
	var queued: Array = _stages.get(&"upload_queue", [0, 0, 0, 0])
	if int(queued[2]) > 0:
		parts.append("q=%d" % int(queued[2]))
	var px: Array = _stages.get(&"splat_dab", [0, 0, 0, 0])
	if int(px[3]) > 0:
		parts.append("px=%d" % int(px[3]))
	_stages.clear()
	_write(" ".join(parts))

static func _stage(stage: StringName) -> int:
	return int(_stages.get(stage, [0, 0, 0, 0])[0])

static func stroke_marker(line: String) -> void:
	_write("#S %s" % line)

static func _write(line: String) -> void:
	_ensure_file()
	if _file == null:
		return
	_file.store_line(line)
	_file.flush()

static func _ensure_file() -> void:
	if _file != null and _file.is_open():
		return
	if _file_failed:
		return
	_file = FileAccess.open(TRACE_PATH, FileAccess.WRITE)
	if _file == null:
		_file_failed = true
		printerr("[PBPaintTrace] cannot open %s (%s) — tracing disabled" % [
			TRACE_PATH, error_string(FileAccess.get_open_error())])
		return
	_file.store_line("# session date=%s godot=%s adapter=%s" % [
		Time.get_datetime_string_from_system(), Engine.get_version_info().get("string", "?"),
		RenderingServer.get_video_adapter_name()])
	_file.flush()
	print("[PBPaintTrace] recording paint frames to %s" % TRACE_PATH)

static func _ensure_frame_hook() -> void:
	if _frame_hooked:
		return
	_frame_hooked = true
	RenderingServer.frame_post_draw.connect(_on_frame_drawn)
