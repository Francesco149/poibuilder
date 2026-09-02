## PBToolbar — PoiBuilder's persistent toolbar row.
##
## Lives as its own full-width row directly BELOW the 3D scene toolbar (not
## inside it) and stays visible at all times. When no PBMesh is selected the
## buttons are disabled but the row remains.
##
## Icon-driven groups (simple SVG glyphs, see icons/):
## - Tool (Move/Rotate/Scale): the plugin's OWN transform tool. While editing
##   we never follow the editor's Q/V universal/select tool state.
## - Mode (Vertex/Edge/Face): element selection mode, remembered across
##   selection changes by PBEditor.
## - Space button: cycles the gizmo orientation space (same as X).
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

## Emitted when the user picks a shape from the New Shape menu. Works with
## NOTHING selected — shape creation is the toolbar's always-on entry point.
signal shape_requested(shape_id: StringName)

# ==============================================================================
# Icons
# ==============================================================================

const ICON_DIR := "res://addons/probuilder/icons/"

# ==============================================================================
# Internal UI
# ==============================================================================

var _logo: TextureRect
var _btn_move: Button
var _btn_rotate: Button
var _btn_scale: Button
var _btn_space: Button
var _btn_vertex: Button
var _btn_edge: Button
var _btn_face: Button
var _btn_new_shape: MenuButton

var _tool_group: ButtonGroup = ButtonGroup.new()
var _mode_group: ButtonGroup = ButtonGroup.new()

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
	_logo = TextureRect.new()
	_logo.name = "Logo"
	_logo.texture = _load_icon("pb_logo.svg")
	_logo.custom_minimum_size = Vector2(18, 18)
	_logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_logo.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_logo.tooltip_text = "PoiBuilder"
	add_child(_logo)

	_label_space()

	# Transform tool group (plugin-owned; never the editor's universal gizmo)
	_btn_move = _create_tool_button("Move", PBEditor.ToolMode.MOVE, "icon_move.svg")
	_btn_rotate = _create_tool_button("Rotate", PBEditor.ToolMode.ROTATE, "icon_rotate.svg")
	_btn_scale = _create_tool_button("Scale", PBEditor.ToolMode.SCALE, "icon_scale.svg")

	_label_space()

	# Element mode group
	_btn_vertex = _create_mode_button("Vertex", PBEditor.SelectMode.VERTEX, "icon_vertex.svg")
	_btn_edge = _create_mode_button("Edge", PBEditor.SelectMode.EDGE, "icon_edge.svg")
	_btn_face = _create_mode_button("Face", PBEditor.SelectMode.FACE, "icon_face.svg")

	_label_space()

	# Orientation space readout/cycler (X key does the same)
	_btn_space = Button.new()
	_btn_space.name = "SpaceButton"
	_btn_space.icon = _load_icon("icon_space.svg")
	_btn_space.text = "Element"
	_btn_space.flat = true
	_btn_space.tooltip_text = "Gizmo orientation space (X to cycle): Element, Object, World"
	_btn_space.pressed.connect(_on_space_button_pressed)
	add_child(_btn_space)

	_label_space()

	# New Shape menu: the always-enabled creation entry point (no PBMesh
	# selection required). The plugin performs placement + undo.
	_btn_new_shape = MenuButton.new()
	_btn_new_shape.name = "NewShape"
	_btn_new_shape.text = "New Shape"
	_btn_new_shape.flat = true
	_btn_new_shape.tooltip_text = "Create a new PoiBuilder shape in front of the editor camera"
	var popup: PopupMenu = _btn_new_shape.get_popup()
	for shape_id in PBShapeFactory.get_shape_ids():
		popup.add_item(String(shape_id).capitalize(), popup.item_count)
	popup.id_pressed.connect(_on_shape_menu_pressed)
	add_child(_btn_new_shape)

func _label_space() -> void:
	add_child(VSeparator.new())

static func _load_icon(icon_name: String) -> Texture2D:
	var path := ICON_DIR + icon_name
	if ResourceLoader.exists(path):
		return load(path)
	return null

func _create_tool_button(text: String, tool: PBEditor.ToolMode, icon_name: String) -> Button:
	var btn := Button.new()
	btn.name = "Tool" + text
	btn.icon = _load_icon(icon_name)
	if btn.icon == null:
		btn.text = text
	btn.toggle_mode = true
	btn.flat = true
	btn.button_group = _tool_group
	btn.tooltip_text = "%s tool (%s)" % [text, ["W", "E", "R"][tool]]
	btn.pressed.connect(_on_tool_button_pressed.bind(tool))
	add_child(btn)
	return btn

func _create_mode_button(text: String, mode: PBEditor.SelectMode, icon_name: String) -> Button:
	var btn := Button.new()
	btn.name = "Mode" + text
	btn.icon = _load_icon(icon_name)
	if btn.icon == null:
		btn.text = text
	btn.toggle_mode = true
	btn.flat = true
	btn.button_group = _mode_group
	btn.tooltip_text = "%s select mode (%s)" % [text, ["", "H", "J", "K"][mode]]
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
	_btn_space.text = PBEditor.OrientationSpace.keys()[space].capitalize()

func _on_mode_button_pressed(mode: PBEditor.SelectMode) -> void:
	if editor != null:
		editor.select_mode = mode
		# Re-clicking the active button toggles it off visually while the
		# editor state is unchanged — restore the pressed look.
		_on_mode_changed(editor.select_mode)
	mode_button_pressed.emit(mode)

func _on_tool_button_pressed(tool: PBEditor.ToolMode) -> void:
	if editor != null:
		editor.tool_mode = tool
		_on_tool_changed(editor.tool_mode)
	tool_button_pressed.emit(tool)

func _on_space_button_pressed() -> void:
	if editor != null:
		editor.cycle_orientation_space()

func _on_shape_menu_pressed(id: int) -> void:
	var ids := PBShapeFactory.get_shape_ids()
	if id >= 0 and id < ids.size():
		shape_requested.emit(ids[id])

# ==============================================================================
# Editing Context
# ==============================================================================

## The toolbar row is persistent: it is ALWAYS visible. Buttons are only
## enabled while a PBMesh is being edited; otherwise they are disabled so
## the state they would switch is never out of context.
func set_editing_active(active: bool) -> void:
	for btn: Button in [_btn_move, _btn_rotate, _btn_scale, _btn_space, _btn_vertex, _btn_edge, _btn_face]:
		btn.disabled = not active
	# New Shape stays enabled: creation needs no editing context.

func new_shape_button() -> MenuButton:
	return _btn_new_shape
