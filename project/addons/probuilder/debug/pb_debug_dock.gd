## PBDebugDock — Editor dock panel showing live debug info
##
## Displays: log tail, mesh stats, selection state, operation timing.
@tool
extends VBoxContainer
class_name PBDebugDock

var logger: PBLogger:
	set(value):
		if logger:
			logger.entry_added.disconnect(_on_entry_added)
		logger = value
		if logger:
			logger.entry_added.connect(_on_entry_added)

var log_text: RichTextLabel
var stats_label: Label
var max_visible_lines: int = 200

func _ready() -> void:
	# Title
	var title := Label.new()
	title.text = "ProBuilder Debug"
	title.add_theme_font_size_override("font_size", 14)
	add_child(title)

	# Stats section
	stats_label = Label.new()
	stats_label.text = "No mesh selected"
	add_child(stats_label)

	# Separator
	add_child(HSeparator.new())

	# Log output
	var log_label := Label.new()
	log_label.text = "Log:"
	add_child(log_label)

	log_text = RichTextLabel.new()
	log_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_text.scroll_following = true
	log_text.bbcode_enabled = true
	log_text.fit_content = false
	log_text.custom_minimum_size = Vector2(200, 100)
	add_child(log_text)

func _on_entry_added(entry: Dictionary) -> void:
	if not log_text:
		return
	var color: String
	match entry.level:
		PBLogger.Level.ERROR:
			color = "red"
		PBLogger.Level.WARN:
			color = "yellow"
		PBLogger.Level.DEBUG:
			color = "gray"
		_:
			color = "white"
	var line := "[color=%s][%s] %s: %s[/color]" % [
		color,
		PBLogger.Level.keys()[entry.level],
		entry.category,
		entry.message
	]
	log_text.append_text(line + "\n")

func update_stats(vertices: int, faces: int, edges: int, selection_mode: String, selected_count: int) -> void:
	if stats_label:
		stats_label.text = "V:%d F:%d E:%d | Mode:%s Sel:%d" % [
			vertices, faces, edges, selection_mode, selected_count
		]
