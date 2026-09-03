## PBLogger — Ring buffer logger for PoiBuilder debug/telemetry
##
## All PoiBuilder subsystems log through this. Entries are kept in a ring
## buffer and can be dumped to file or displayed in the debug dock.
##
## NOTE: The method is named `info()` not `log()` because GDScript reserves
## `log()` for the natural logarithm built-in.
@tool
class_name PBLogger
extends RefCounted

enum Level { DEBUG, INFO, WARN, ERROR }

## Console verbosity gate: INFO/DEBUG logging is opt-in via the
## POIBUILDER_DEBUG environment variable (set it to any non-empty value,
## e.g. POIBUILDER_DEBUG=1, when reporting viewport bugs). WARN/ERROR always
## record and print. The gate also guards the hot call sites (per-motion
## drag lines, redraw/hover logs, per-commit audits) so their format
## strings are never built in a normal session.
static var verbose: bool = not String(OS.get_environment("POIBUILDER_DEBUG")).is_empty() \
	and OS.get_environment("POIBUILDER_DEBUG") != "0"

## Each entry: {time_msec: int, level: Level, category: String, message: String}
var entries: Array[Dictionary] = []
var max_entries: int = 10000

## Signal emitted on every new log entry — the debug dock connects to this.
signal entry_added(entry: Dictionary)

func _log(category: String, message: String, level: Level = Level.INFO) -> void:
	if level < Level.WARN and not verbose:
		return
	var entry := {
		"time_msec": Time.get_ticks_msec(),
		"level": level,
		"category": category,
		"message": message,
	}
	entries.append(entry)
	if entries.size() > max_entries:
		entries.pop_front()
	entry_added.emit(entry)

	# Print to Godot output. Uses print/printerr (not push_error/push_warning)
	# to avoid triggering test framework error detection.
	if level >= Level.ERROR:
		printerr("[PB/%s] %s" % [category, message])
	elif level >= Level.WARN:
		printerr("[PB/%s] WARN: %s" % [category, message])
	else:
		print("[PB/%s] %s" % [category, message])

func info(category: String, message: String) -> void:
	_log(category, message, Level.INFO)

func debug(category: String, message: String) -> void:
	_log(category, message, Level.DEBUG)

func warn(category: String, message: String) -> void:
	_log(category, message, Level.WARN)

func error(category: String, message: String) -> void:
	_log(category, message, Level.ERROR)

func clear() -> void:
	entries.clear()

func get_entries_by_category(category: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for e in entries:
		if e.category == category:
			result.append(e)
	return result

func get_entries_by_level(min_level: Level) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for e in entries:
		if e.level >= min_level:
			result.append(e)
	return result

func dump_to_file(path: String) -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if not f:
		return FileAccess.get_open_error()
	for e in entries:
		f.store_line("%d [%s] %s: %s" % [
			e.time_msec,
			Level.keys()[e.level],
			e.category,
			e.message
		])
	return OK

func entry_count() -> int:
	return entries.size()
