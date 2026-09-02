## PBToolbar — ProBuilder's persistent toolbar row.
##
## Lives as its own full-width row directly BELOW the 3D scene toolbar (not
## inside it) and stays visible at all times. When no PBMesh is selected the
## buttons are disabled but the row remains.
##
## Two groups:
## - Tool (Move/Rotate/Scale): the plugin's OWN transform tool. While editing
##   we never follow the editor's Q/V universal/select tool state.
## - Mode (Vertex/Edge/Face): element selection mode, remembered across
##   selection changes by PBEditor.
@tool
class_name PBToolbar
extends HBoxContainer

# ==============================================================================
# Signals
# ==============================================================================

## Emitted when the user clicks a mode button.
signal mode_button_pressed(mode: PBEditor.SelectMode)

## Emitted when the user clicks a tool button.
signal tool_button_pressed(tool: PBEditor.ToolMode)

# ==============================================================================
# Internal UI
# ==============================================================================

var _label: Label
var _btn_move: Button
var _btn_rotate: Button
var _btn_scale: Button
var _btn_space: Button
var _btn_vertex: Button
var _btn_edge: Button
var _btn_face: Button

## Editor reference for mode/tool tracking
var editor: PBEditor = null:
	set = set_editor

# ==============================================================================
# Lifecycle
# ==============================================================================

func _init() -> void:
	name = "PBToolbar"
	size_flags_horizontal = Control.SIZE_EXPAND | Control.SIZE_FILL
	add_theme_constant_override("separation", 4)
	_build_ui()

func _build_ui() -> void:
	_label = Label.new()
	_label.text = "ProBuilder"
	_label.add_theme_font_size_override("font_size", 13)
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_label)

	_add_sep()

	# Transform tool group (plugin-owned; never the editor's universal gizmo)
	_btn_move = _create_tool_button("Move", PBEditor.ToolMode.MOVE)
	_btn_rotate = _create_tool_button("Rotate", PBEditor.ToolMode.ROTATE)
	_btn_scale = _create_tool_button("Scale", PBEditor.ToolMode.SCALE)

	_add_sep()

	# Orientation space readout/cycler (X key does the same)
	_btn_space = Button.new()
	_btn_space.text = "Space: Element"
	_btn_space.flat = true
	_btn_space.pressed.connect(_on_space_button_pressed)
	add_child(_btn_space)

	_add_sep()

	# Element mode group
	_btn_vertex = _create_mode_button("Vertex", PBEditor.SelectMode.VERTEX)
	_btn_edge = _create_mode_button("Edge", PBEditor.SelectMode.EDGE)
	_btn_face = _create_mode_button("Face", PBEditor.SelectMode.FACE)

func _add_sep() -> void:
	add_child(VSeparator.new())

func _create_tool_button(text: String, tool: PBEditor.ToolMode) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.toggle_mode = true
	btn.flat = true
	btn.pressed.connect(_on_tool_button_pressed.bind(tool))
	add_child(btn)
	return btn

func _create_mode_button(text: String, mode: PBEditor.SelectMode) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.toggle_mode = true
	btn.flat = true
	btn.pressed.connect(_on_mode_button_pressed.bind(mode))
	add_child(btn)
	return btn

# ==============================================================================
# Editor Binding
# ==============================================================================

func set_editor(value: PBEditor) -> void:
	if editor != null:
		if editor.select_mode_changed.is_connected(_on_mode_changed):
			editor.select_mode_changed.disconnect(_on_mode_changed)
		if editor.tool_mode_changed.is_connected(_on_tool_changed):
			editor.tool_mode_changed.disconnect(_on_tool_changed)
		if editor.orientation_space_changed.is_connected(_on_space_changed):
			editor.orientation_space_changed.disconnect(_on_space_changed)
	editor = value
	if editor != null:
		editor.select_mode_changed.connect(_on_mode_changed)
		editor.tool_mode_changed.connect(_on_tool_changed)
		editor.orientation_space_changed.connect(_on_space_changed)
		_on_mode_changed(editor.select_mode)
		_on_tool_changed(editor.tool_mode)
		_on_space_changed(editor.orientation_space)

# ==============================================================================
# Button State Sync
# ==============================================================================

func _on_mode_changed(mode: PBEditor.SelectMode) -> void:
	_btn_vertex.set_pressed_no_signal(mode == PBEditor.SelectMode.VERTEX)
	_btn_edge.set_pressed_no_signal(mode == PBEditor.SelectMode.EDGE)
	_btn_face.set_pressed_no_signal(mode == PBEditor.SelectMode.FACE)

func _on_tool_changed(tool: PBEditor.ToolMode) -> void:
	_btn_move.set_pressed_no_signal(tool == PBEditor.ToolMode.MOVE)
	_btn_rotate.set_pressed_no_signal(tool == PBEditor.ToolMode.ROTATE)
	_btn_scale.set_pressed_no_signal(tool == PBEditor.ToolMode.SCALE)

func _on_space_changed(space: PBEditor.OrientationSpace) -> void:
	_btn_space.text = "Space: %s" % PBEditor.OrientationSpace.keys()[space].capitalize()

func _on_mode_button_pressed(mode: PBEditor.SelectMode) -> void:
	if editor != null:
		editor.select_mode = mode
	mode_button_pressed.emit(mode)

func _on_tool_button_pressed(tool: PBEditor.ToolMode) -> void:
	if editor != null:
		editor.tool_mode = tool
	tool_button_pressed.emit(tool)

func _on_space_button_pressed() -> void:
	if editor != null:
		editor.cycle_orientation_space()

# ==============================================================================
# Editing Context
# ==============================================================================

## The toolbar row is persistent: it is ALWAYS visible. Buttons are only
## enabled while a PBMesh is being edited; otherwise they are disabled so
## the state they would switch is never out of context.
func set_editing_active(active: bool) -> void:
	for btn: Button in [_btn_move, _btn_rotate, _btn_scale, _btn_space, _btn_vertex, _btn_edge, _btn_face]:
		btn.disabled = not active
