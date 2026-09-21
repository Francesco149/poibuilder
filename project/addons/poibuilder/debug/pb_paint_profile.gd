## PBPaintProfile — stage timers for the paint pipeline.
##
## Answers "where does a paint stroke actually spend its time" on the machine
## that shows the lag (the reference iGPU laptop), with the REAL stroke path:
## pick, interpolated dab walk, the splat/decal pixel loops, and the mask
## texture uploads. Off by default and near-free when off (one bool check per
## stage); set PB_PAINT_PROFILE=1 to arm it.
##
## The paint bench in test_scenes/editor_gui_test.gd (PB_PAINT_PERF=1) drives
## fast strokes through the plugin's real input path with the profiler armed
## and prints one summary line per stroke plus an aggregate — see
## run_paint_perf.sh. The counters are also usable by hand: arm the env, paint
## in a live editor, and every stroke's end_stroke prints the same line.
@tool
class_name PBPaintProfile
extends RefCounted

static var enabled: bool = OS.get_environment("PB_PAINT_PROFILE") != ""

## Per-stage counters for the CURRENT stroke: name -> {"usec", "calls", "bytes", "pixels"}.
static var _stages: Dictionary = {}
## Per-stage sums across every finished stroke since the last reset.
static var _aggregate: Dictionary = {}
## Wall-clock start of the current stroke (usec); -1 while idle.
static var _stroke_start: int = -1
## Finished stroke count since the last reset.
static var stroke_count: int = 0

static func reset() -> void:
	_stages = {}
	_aggregate = {}
	_stroke_start = -1
	stroke_count = 0

## Adds `usec` microseconds (0 for pure counters), `calls` hits, and optional
## byte/pixel totals to a stage.
static func add(stage: StringName, usec: int, calls: int = 1, bytes: int = 0, pixels: int = 0) -> void:
	var e: Dictionary = _stages.get(stage, {})
	if e.is_empty():
		e = {"usec": 0, "calls": 0, "bytes": 0, "pixels": 0}
		_stages[stage] = e
	e["usec"] = int(e["usec"]) + usec
	e["calls"] = int(e["calls"]) + calls
	e["bytes"] = int(e["bytes"]) + bytes
	e["pixels"] = int(e["pixels"]) + pixels

static func begin_stroke() -> void:
	if not enabled:
		return
	_stages = {}
	_stroke_start = Time.get_ticks_usec()

## Closes the current stroke and prints its summary. `label` names the brush
## configuration ("splat r0.50 3m" etc.) so lines stay greppable. Returns the
## stroke's wall time in ms (0.0 while idle or disabled).
static func end_stroke(label: String) -> float:
	if not enabled or _stroke_start < 0:
		return 0.0
	var wall_ms := float(Time.get_ticks_usec() - _stroke_start) / 1000.0
	_stroke_start = -1
	stroke_count += 1
	var pick := _stage_ms(&"pick")
	var interp := _stage_ms(&"interp_walk")
	var dab := _stage_ms(&"dab_total")
	var splat := _stage_ms(&"splat_dab")
	var decal := _stage_ms(&"decal_dab")
	var flush := _stage_ms(&"upload_flush")
	var picks := _stage_calls(&"pick")
	var steps := _stage_calls(&"interp_step")
	var dabs := _stage_calls(&"dab_total")
	var walked := _stage_pixels(&"splat_dab") + _stage_pixels(&"decal_dab")
	var queued := _stage_calls(&"upload_queue")
	var flushed := _stage_calls(&"upload_flush")
	var mbytes := float(_stage_bytes(&"upload_queue")) / (1024.0 * 1024.0)
	print("[PAINT PERF] #%d %s wall=%.1fms | pick=%.1f (%d calls, %d interp steps) dab=%.1f (splat=%.1f decal=%.1f, %d dabs, %d px walked) upload=%.1f flush (%d queued / %d flushed, %.2f MB) interp_walk=%.1f" % [
		stroke_count, label, wall_ms, pick, picks, steps, dab, splat, decal, dabs, walked,
		flush, queued, flushed, mbytes, interp])
	for stage: StringName in _stages:
		var e: Dictionary = _stages[stage]
		var a: Dictionary = _aggregate.get(stage, {})
		if a.is_empty():
			a = {"usec": 0, "calls": 0, "bytes": 0, "pixels": 0}
			_aggregate[stage] = a
		for k: String in ["usec", "calls", "bytes", "pixels"]:
			a[k] = int(a[k]) + int(e[k])
	return wall_ms

static func _stage_ms(stage: StringName) -> float:
	var e: Dictionary = _stages.get(stage, {})
	return float(int(e.get("usec", 0))) / 1000.0

static func _stage_calls(stage: StringName) -> int:
	return int(_stages.get(stage, {}).get("calls", 0))

static func _stage_bytes(stage: StringName) -> int:
	return int(_stages.get(stage, {}).get("bytes", 0))

static func _stage_pixels(stage: StringName) -> int:
	return int(_stages.get(stage, {}).get("pixels", 0))

## One-line mean-per-stroke aggregate over the finished strokes (the number to
## quote before/after an optimization round).
static func aggregate_line() -> String:
	if stroke_count == 0:
		return "no strokes"
	var n := float(stroke_count)
	var pick := float(int(_aggregate.get(&"pick", {}).get("usec", 0))) / 1000.0 / n
	var interp := float(int(_aggregate.get(&"interp_walk", {}).get("usec", 0))) / 1000.0 / n
	var dab := float(int(_aggregate.get(&"dab_total", {}).get("usec", 0))) / 1000.0 / n
	var flush := float(int(_aggregate.get(&"upload_flush", {}).get("usec", 0))) / 1000.0 / n
	var picks := float(int(_aggregate.get(&"pick", {}).get("calls", 0))) / n
	var dabs := float(int(_aggregate.get(&"dab_total", {}).get("calls", 0))) / n
	var walked := float(int(_aggregate.get(&"splat_dab", {}).get("pixels", 0))) / n
	return ("mean of %d strokes: wall-part pick=%.1fms dab=%.1fms flush=%.1fms interp=%.1fms | picks=%.0f dabs=%.0f walked=%.0fpx per stroke (wall total per stroke not averaged here — see per-stroke lines)"
		% [stroke_count, pick, dab, flush, interp, picks, dabs, walked])
