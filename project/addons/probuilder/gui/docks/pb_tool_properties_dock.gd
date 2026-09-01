## PBToolPropertiesDock — Editor dock panel showing active tool properties and settings.
##
## Displays: active tool name, selection mode, selection counts, and live transform readout.
@tool
class_name PBToolPropertiesDock
extends VBoxContainer

# ==============================================================================
# Properties
# ==============================================================================

## PBEditor reference for tracking active tool, mode, and selection state.
var editor: PBEditor = null:
	set = set_editor

## UI Labels
var title_label: Label
var tool_label: Label
var mode_label: Label
var selection_label: Label
var settings_label: Label

var _ui_built: bool = false

# ==============================================================================
# Lifecycle
# ==============================================================================

func _ready() -> void:
	_ensure_ui()
	refresh()

## Ensures that all UI child nodes are instantiated.
## Can be called before _ready() if tests or callers invoke refresh() off-tree.
func build_ui() -> void:
	_ensure_ui()

func _ensure_ui() -> void:
	if _ui_built:
		return
	_ui_built = true

	# Title
	title_label = Label.new()
	title_label.name = "TitleLabel"
	title_label.text = "Tool Properties"
	title_label.add_theme_font_size_override("font_size", 14)
	add_child(title_label)

	# Separator
	add_child(HSeparator.new())

	# Tool name
	tool_label = Label.new()
	tool_label.name = "ToolLabel"
	tool_label.text = "Tool: Select"
	add_child(tool_label)

	# Selection mode
	mode_label = Label.new()
	mode_label.name = "ModeLabel"
	mode_label.text = "Mode: Object"
	add_child(mode_label)

	# Selection counts
	selection_label = Label.new()
	selection_label.name = "SelectionLabel"
	selection_label.text = "Selection: V:0 E:0 F:0"
	add_child(selection_label)

	# Separator
	add_child(HSeparator.new())

	# Settings / live transform readout
	settings_label = Label.new()
	settings_label.name = "SettingsLabel"
	settings_label.text = "—"
	add_child(settings_label)

# ==============================================================================
# Editor Binding
# ==============================================================================

func set_editor(value: PBEditor) -> void:
	if editor != null:
		if editor.active_tool_changed.is_connected(_on_editor_changed):
			editor.active_tool_changed.disconnect(_on_editor_changed)
		if editor.select_mode_changed.is_connected(_on_editor_changed):
			editor.select_mode_changed.disconnect(_on_editor_changed)
		if editor.element_selection_changed.is_connected(_on_editor_changed):
			editor.element_selection_changed.disconnect(_on_editor_changed)
		if editor.active_mesh_changed.is_connected(_on_editor_changed):
			editor.active_mesh_changed.disconnect(_on_editor_changed)
		if editor.orientation_space_changed.is_connected(_on_editor_changed):
			editor.orientation_space_changed.disconnect(_on_editor_changed)

	editor = value

	if editor != null:
		editor.active_tool_changed.connect(_on_editor_changed)
		editor.select_mode_changed.connect(_on_editor_changed)
		editor.element_selection_changed.connect(_on_editor_changed)
		editor.active_mesh_changed.connect(_on_editor_changed)
		editor.orientation_space_changed.connect(_on_editor_changed)

	refresh()

func _on_editor_changed(_arg = null) -> void:
	refresh()

# ==============================================================================
# Refresh Logic
# ==============================================================================

## Refreshes all label readouts from the current editor state.
func refresh() -> void:
	_ensure_ui()

	if editor == null:
		if tool_label:
			tool_label.text = "Tool: Select"
		if mode_label:
			mode_label.text = "Mode: Object"
		if selection_label:
			selection_label.text = "Selection: V:0 E:0 F:0"
		if settings_label:
			settings_label.text = "—"
		return

	# 1. Tool name
	var tool_name_str: String = "Select"
	if editor.active_tool != null:
		tool_name_str = editor.active_tool.tool_name()
	if tool_label:
		tool_label.text = "Tool: %s" % tool_name_str

	# 2. Select mode
	var mode_str: String = PBEditor.mode_name(editor.select_mode)
	if mode_label:
		var space_str: String = PBEditor.OrientationSpace.keys()[editor.orientation_space]
		mode_label.text = "Mode: %s  Space: %s (X)" % [mode_str, space_str.capitalize()]

	# 3. Selection counts
	var v_cnt: int = 0
	var e_cnt: int = 0
	var f_cnt: int = 0
	if editor.selection != null:
		v_cnt = editor.selection.selected_vertex_count()
		e_cnt = editor.selection.selected_edge_count()
		f_cnt = editor.selection.selected_face_count()
	if selection_label:
		selection_label.text = "Selection: V:%d E:%d F:%d" % [v_cnt, e_cnt, f_cnt]

	# 4. Settings line / live transform readout
	var settings_str: String = "—"
	if editor.active_tool != null and editor.active_tool.has_method("get_command"):
		var cmd = editor.active_tool.get_command()
		if cmd != null:
			if editor.active_tool is PBToolMove and cmd is CmdMoveElements:
				settings_str = "Delta: %s" % _format_vector3(cmd.delta)
			elif editor.active_tool is PBToolRotate and cmd is CmdRotateElements:
				var euler_rad: Vector3 = cmd.rotation.get_euler()
				var euler_deg := Vector3(rad_to_deg(euler_rad.x), rad_to_deg(euler_rad.y), rad_to_deg(euler_rad.z))
				settings_str = "Rotation: %s deg" % _format_vector3(euler_deg)
			elif editor.active_tool is PBToolScale and cmd is CmdScaleElements:
				settings_str = "Scale: %s" % _format_vector3(cmd.scale)

	if settings_label:
		settings_label.text = settings_str

# ==============================================================================
# Helper Formatting
# ==============================================================================

static func _format_vector3(v: Vector3) -> String:
	var x: float = 0.0 if is_zero_approx(v.x) else v.x
	var y: float = 0.0 if is_zero_approx(v.y) else v.y
	var z: float = 0.0 if is_zero_approx(v.z) else v.z
	var rounded := Vector3(
		round(x * 1000.0) / 1000.0,
		round(y * 1000.0) / 1000.0,
		round(z * 1000.0) / 1000.0
	)
	return str(rounded)
