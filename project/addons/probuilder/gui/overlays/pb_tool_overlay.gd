## PBToolOverlay — Floating in-viewport panel with ProBuilder tool info.
##
## Replaces the docked panels: this is a small PanelContainer parented to the
## 3D editor's viewport (bottom-left, like ProBuilder's Selection overlay)
## showing the active mode, transform tool, orientation space, selection
## counts, and a live readout while the native transform gizmo drags elements.
## It only occupies its own rect — clicks on it are consumed, everything else
## passes to the scene.
##
## As features land, sections are added to this panel (and more panels can be
## parented the same way).
@tool
class_name PBToolOverlay
extends PanelContainer

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

	# Use the engine's own viewport-info panel style when available so the
	# overlay looks native (same stylebox as the engine's viewport info bar).
	var editor_gui := EditorInterface.get_base_control() if Engine.is_editor_hint() else null
	if editor_gui != null and editor_gui.has_theme_stylebox("Information3dViewport", "EditorStyles"):
		add_theme_stylebox_override("panel",
			editor_gui.get_theme_stylebox("Information3dViewport", "EditorStyles"))

	mouse_filter = Control.MOUSE_FILTER_STOP

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_bottom", 6)
	add_child(margin)

	var vbox := VBoxContainer.new()
	margin.add_child(vbox)

	# Title
	title_label = Label.new()
	title_label.name = "TitleLabel"
	title_label.text = "ProBuilder v%s" % PBEditor.PLUGIN_VERSION
	title_label.add_theme_font_size_override("font_size", 13)
	vbox.add_child(title_label)

	# Selection mode + orientation space + transform tool
	mode_label = Label.new()
	mode_label.name = "ModeLabel"
	mode_label.text = "Mode: Object"
	vbox.add_child(mode_label)

	# Selection counts
	selection_label = Label.new()
	selection_label.name = "SelectionLabel"
	selection_label.text = "Selection: V:0 E:0 F:0"
	vbox.add_child(selection_label)

	# Live transform readout while dragging elements
	settings_label = Label.new()
	settings_label.name = "SettingsLabel"
	settings_label.text = "—"
	vbox.add_child(settings_label)

	# Anchor to the bottom-left of the host viewport.
	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	position += Vector2(12, -12)
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	grow_horizontal = Control.GROW_DIRECTION_END

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
		if editor.tool_mode_changed.is_connected(_on_editor_changed):
			editor.tool_mode_changed.disconnect(_on_editor_changed)

	editor = value

	if editor != null:
		editor.select_mode_changed.connect(_on_editor_changed)
		editor.element_selection_changed.connect(_on_editor_changed)
		editor.active_mesh_changed.connect(_on_editor_changed)
		editor.orientation_space_changed.connect(_on_editor_changed)
		editor.tool_mode_changed.connect(_on_editor_changed)

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

	# 1. Select mode + transform tool + orientation space
	var mode_str: String = PBEditor.mode_name(editor.select_mode)
	if mode_label:
		var space_str: String = PBEditor.OrientationSpace.keys()[editor.orientation_space]
		mode_label.text = "Mode: %s  Tool: %s  Space: %s (X)" % [
			mode_str, PBEditor.tool_name(editor.tool_mode), space_str.capitalize()]

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
