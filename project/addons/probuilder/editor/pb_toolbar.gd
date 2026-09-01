## PBToolbar — Mode switching toolbar displayed in the 3D viewport header.
##
## Shows Object/Vertex/Edge/Face mode buttons when a PBMesh is selected.
## Integrates with PBEditor to track and change the current selection mode.
@tool
class_name PBToolbar
extends HBoxContainer

# ==============================================================================
# Signals
# ==============================================================================

## Emitted when the user clicks a mode button.
signal mode_button_pressed(mode: PBEditor.SelectMode)

# ==============================================================================
# Internal UI
# ==============================================================================

var _label: Label
var _btn_vertex: Button
var _btn_edge: Button
var _btn_face: Button
var _separator: VSeparator

## Editor reference for mode tracking
var editor: PBEditor = null:
	set = set_editor

# ==============================================================================
# Lifecycle
# ==============================================================================

func _init() -> void:
	name = "PBToolbar"
	# Build toolbar UI
	_build_ui()

func _build_ui() -> void:
	# Separator before our toolbar
	_separator = VSeparator.new()
	add_child(_separator)

	# Label
	_label = Label.new()
	_label.text = "ProBuilder"
	_label.add_theme_font_size_override("font_size", 13)
	add_child(_label)

	# Mode buttons
	_btn_vertex = _create_mode_button("Vertex", PBEditor.SelectMode.VERTEX)
	_btn_edge = _create_mode_button("Edge", PBEditor.SelectMode.EDGE)
	_btn_face = _create_mode_button("Face", PBEditor.SelectMode.FACE)

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
	if editor != null and editor.select_mode_changed.is_connected(_on_mode_changed):
		editor.select_mode_changed.disconnect(_on_mode_changed)
	editor = value
	if editor != null:
		editor.select_mode_changed.connect(_on_mode_changed)
		_on_mode_changed(editor.select_mode)

# ==============================================================================
# Button State Sync
# ==============================================================================

func _on_mode_changed(mode: PBEditor.SelectMode) -> void:
	_btn_vertex.set_pressed_no_signal(mode == PBEditor.SelectMode.VERTEX)
	_btn_edge.set_pressed_no_signal(mode == PBEditor.SelectMode.EDGE)
	_btn_face.set_pressed_no_signal(mode == PBEditor.SelectMode.FACE)

func _on_mode_button_pressed(mode: PBEditor.SelectMode) -> void:
	if editor != null:
		editor.select_mode = mode
	mode_button_pressed.emit(mode)

# ==============================================================================
# Visibility
# ==============================================================================

## Show the toolbar (when PBMesh is selected)
func activate() -> void:
	visible = true

## Hide the toolbar (when no PBMesh is selected)
func deactivate() -> void:
	visible = false
