## PBToolPropertiesDock — Editor dock panel showing ProBuilder element editing state.
##
## Displays: selection mode, gizmo orientation space, selection counts, and a
## live readout while the native transform gizmo drags elements.
@tool
class_name PBToolPropertiesDock
extends VBoxContainer

# ==============================================================================
# Properties
# ==============================================================================

## PBEditor reference for tracking mode, selection, and orientation space.
var editor: PBEditor = null:
	set = set_editor

## PBElementEditor reference for live drag readout.
var element_editor: PBElementEditor = null:
	set = set_element_editor

## UI Labels
var title_label: Label
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
	title_label.text = "ProBuilder"
	title_label.add_theme_font_size_override("font_size", 14)
	add_child(title_label)

	# Separator
	add_child(HSeparator.new())

	# Selection mode + orientation space
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

	# Live transform readout while dragging elements
	settings_label = Label.new()
	settings_label.name = "SettingsLabel"
	settings_label.text = "—"
	add_child(settings_label)

# ==============================================================================
# Editor Binding
# ==============================================================================

func set_editor(value: PBEditor) -> void:
	if editor != null:
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
		editor.select_mode_changed.connect(_on_editor_changed)
		editor.element_selection_changed.connect(_on_editor_changed)
		editor.active_mesh_changed.connect(_on_editor_changed)
		editor.orientation_space_changed.connect(_on_editor_changed)

	refresh()

func set_element_editor(value: PBElementEditor) -> void:
	if element_editor != null and element_editor.element_drag_updated.is_connected(_on_editor_changed):
		element_editor.element_drag_updated.disconnect(_on_editor_changed)
	element_editor = value
	if element_editor != null:
		element_editor.element_drag_updated.connect(_on_editor_changed)
	refresh()

func _on_editor_changed(_arg = null, _arg2 = null, _arg3 = null, _arg4 = null) -> void:
	refresh()

# ==============================================================================
# Refresh Logic
# ==============================================================================

## Refreshes all label readouts from the current editor state.
func refresh() -> void:
	_ensure_ui()

	if editor == null:
		if mode_label:
			mode_label.text = "Mode: Object"
		if selection_label:
			selection_label.text = "Selection: V:0 E:0 F:0"
		if settings_label:
			settings_label.text = "—"
		return

	# 1. Select mode + orientation space
	var mode_str: String = PBEditor.mode_name(editor.select_mode)
	if mode_label:
		var space_str: String = PBEditor.OrientationSpace.keys()[editor.orientation_space]
		mode_label.text = "Mode: %s  Space: %s (X)" % [mode_str, space_str.capitalize()]

	# 2. Selection counts
	var v_cnt: int = 0
	var e_cnt: int = 0
	var f_cnt: int = 0
	if editor.selection != null:
		v_cnt = editor.selection.selected_vertex_count()
		e_cnt = editor.selection.selected_edge_count()
		f_cnt = editor.selection.selected_face_count()
	if selection_label:
		selection_label.text = "Selection: V:%d E:%d F:%d" % [v_cnt, e_cnt, f_cnt]

	# 3. Live transform readout while the native gizmo drags elements
	var settings_str: String = "—"
	if element_editor != null:
		settings_str = element_editor.drag_readout()
	if settings_label:
		settings_label.text = settings_str
