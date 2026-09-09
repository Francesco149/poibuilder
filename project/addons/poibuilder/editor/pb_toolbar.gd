## PBToolbar — PoiBuilder's persistent toolbar row.
##
## Lives as its own full-width row directly BELOW the 3D scene toolbar (not
## inside it) and stays visible at all times. When no PBMesh is selected the
## context buttons are disabled but the row remains.
##
## Groups (icon-driven; simple SVG glyphs, see icons/):
## - Tool (Move/Rotate/Scale): the plugin's OWN transform tool. While editing
##   we never follow the editor's Q/V universal/select tool state.
## - Mode (Object/Vertex/Edge/Face): element selection mode. OBJECT is a real
##   mode: whole-object transforms happen only there; clicking between
##   objects in an element mode auto-picks the element under the cursor.
## - Space button: cycles the gizmo orientation space (same as X).
## - Operations: mesh ops acting on the current selection, enabled per
##   selection context (greyed out otherwise). The overlay panel does NOT
##   carry op buttons.
## - Shape actions: New Shape menu (always enabled), Edit Params (enabled
##   while the selected mesh is a pristine, unedited factory shape).
## - Panel toggle: pins the overlay panel on/off (it otherwise auto-hides).
@tool
class_name PBToolbar
extends VBoxContainer
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

## Emitted when the user clicks a mesh operation button. The plugin performs
## the op — selection reading and undo live there.
signal operation_requested(op_name: String)

## Emitted when the user asks to re-edit the selected mesh's shape params.
signal edit_params_requested

## Emitted when the user toggles the overlay panel pin.
signal overlay_toggled(pinned: bool)

## Emitted when the user clicks the explicit Reset Panel button on the toolbar.
signal reset_panel_requested

## Grid settings moved out of the toolbar into the overlay panel (opened by
## this button); the toolbar keeps only a lightweight grid-status readout
## that mirrors PBGrid.
signal grid_panel_toggled(open: bool)

## Emitted when the user clicks the Material & UV dock button to focus it.

## Emitted when the user toggles the Display Settings section in the overlay.
signal settings_panel_toggled(open: bool)
signal materials_dock_requested

## Emitted when the user clicks the Export button to open the map export dialog.
signal export_requested

## Emitted when the user toggles the split-rows layout button.
signal split_rows_toggled(two_rows: bool)
# Icons
# ==============================================================================

const ICON_DIR := "res://addons/poibuilder/icons/"

# ==============================================================================
# Internal UI & Layout
# ==============================================================================

enum RowsMode {
	AUTO = 0,
	SINGLE = 1,
	TWO_ROWS = 2,
}

## Window width breakpoint in pixels for auto-detection: below this width, 2 rows are used.
const AUTO_SPLIT_THRESHOLD := 1050.0

var rows_mode: RowsMode = RowsMode.AUTO
var _row1: HBoxContainer
var _row2: HBoxContainer
var _two_rows: bool = false
var _btn_split_rows: Button

var _logo: TextureRect
var _btn_move: Button
var _btn_rotate: Button
var _btn_scale: Button
var _btn_object: Button
var _btn_vertex: Button
var _btn_edge: Button
var _btn_face: Button
var _btn_space: Button
var _btn_new_shape: MenuButton
var _btn_ngon: Button
var _btn_edit_params: Button
var _btn_overlay: Button
var _btn_recover_overlay: Button
var _btn_materials: Button
var _op_buttons: Dictionary = {}
var _btn_settings: Button
var _btn_export: Button
var _btn_grid_panel: Button
var _lbl_grid_state: Label

var _sep_tools: VSeparator
var _sep_modes: VSeparator
var _sep_space: VSeparator
var _sep_grid: VSeparator
var _sep_ops: VSeparator
var _sep_shapes: VSeparator
var _sep_overlay: VSeparator
var _sep_docks: VSeparator
var _sep_export: VSeparator

var _tool_group: ButtonGroup = ButtonGroup.new()
var _mode_group: ButtonGroup = ButtonGroup.new()

## Whether the toolbar is displayed across 2 rows.
var two_rows: bool:
	get:
		return _two_rows
	set(val):
		set_two_rows(val)
var editor: PBEditor = null:
	set = set_editor

# ==============================================================================
# Lifecycle
# ==============================================================================

func _init() -> void:
	name = "PBToolbar"
	size_flags_horizontal = Control.SIZE_EXPAND | Control.SIZE_FILL
	add_theme_constant_override("separation", 2)
	_build_ui()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_check_auto_split()

func _build_ui() -> void:
	_row1 = HBoxContainer.new()
	_row1.name = "Row1"
	_row1.size_flags_horizontal = Control.SIZE_EXPAND | Control.SIZE_FILL
	_row1.add_theme_constant_override("separation", 4)
	add_child(_row1)

	_row2 = HBoxContainer.new()
	_row2.name = "Row2"
	_row2.size_flags_horizontal = Control.SIZE_EXPAND | Control.SIZE_FILL
	_row2.add_theme_constant_override("separation", 4)
	_row2.visible = false
	add_child(_row2)

	# Header: Logo + Split Rows button (placed on the left so it's never cut off)
	_logo = TextureRect.new()
	_logo.name = "Logo"
	_logo.texture = _load_icon("pb_logo.svg")
	_logo.custom_minimum_size = Vector2(18, 18)
	_logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_logo.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_logo.tooltip_text = "PoiBuilder"

	_btn_split_rows = Button.new()
	_btn_split_rows.name = "SplitRowsToggle"
	_btn_split_rows.icon = _load_icon("icon_split_rows.svg")
	if _btn_split_rows.icon == null:
		_btn_split_rows.text = "☷"
	_btn_split_rows.flat = true
	_btn_split_rows.toggle_mode = true
	_btn_split_rows.focus_mode = Control.FOCUS_NONE
	_update_split_button_tooltip()
	_btn_split_rows.toggled.connect(_on_split_rows_button_toggled)
	_btn_split_rows.gui_input.connect(_on_split_rows_button_gui_input)

	# Tools group
	_sep_tools = _make_sep()
	_btn_move = _create_tool_button("Move", PBEditor.ToolMode.MOVE, "icon_move.svg")
	_btn_rotate = _create_tool_button("Rotate", PBEditor.ToolMode.ROTATE, "icon_rotate.svg")
	_btn_scale = _create_tool_button("Scale", PBEditor.ToolMode.SCALE, "icon_scale.svg")
	_btn_scale.tooltip_text = "Scale tool (R) — axis handles scale freely; the CENTER square scales all axes together (Shift + center on faces insets)"

	# Selection modes group
	_sep_modes = _make_sep()
	_btn_object = _create_mode_button("Object", PBEditor.SelectMode.OBJECT, "icon_object.svg")
	_btn_vertex = _create_mode_button("Vertex", PBEditor.SelectMode.VERTEX, "icon_vertex.svg")
	_btn_edge = _create_mode_button("Edge", PBEditor.SelectMode.EDGE, "icon_edge.svg")
	_btn_face = _create_mode_button("Face", PBEditor.SelectMode.FACE, "icon_face.svg")

	# Orientation space
	_sep_space = _make_sep()
	_btn_space = Button.new()
	_btn_space.name = "SpaceButton"
	_btn_space.icon = _load_icon("icon_space.svg")
	_btn_space.text = "Element"
	_btn_space.flat = true
	_btn_space.tooltip_text = "Gizmo orientation space (X to cycle): Element, Object, World"
	_btn_space.pressed.connect(_on_space_button_pressed)

	# Grid settings & readout
	_sep_grid = _make_sep()
	_btn_grid_panel = Button.new()
	_btn_grid_panel.name = "GridPanelToggle"
	_btn_grid_panel.text = "Grid"
	_btn_grid_panel.toggle_mode = true
	_btn_grid_panel.flat = true
	_btn_grid_panel.focus_mode = Control.FOCUS_NONE
	_btn_grid_panel.tooltip_text = "Grid & snapping settings (unit, subdivisions, elevation, draw-on-grid). Keys: =/- subdivisions, Shift+=/- unit, [/] elevation, \\ reset, Y snap, G draw-on-grid"
	_btn_grid_panel.toggled.connect(func(on: bool): grid_panel_toggled.emit(on))

	_lbl_grid_state = Label.new()
	_lbl_grid_state.name = "GridState"
	_lbl_grid_state.text = "0.2m"
	_lbl_grid_state.tooltip_text = "Current snap step (unit / subdivisions) — elevation shown when nonzero"

	# Operations group
	_sep_ops = _make_sep()
	_make_op_button("Extrude", "extrude_faces", "Extrude selected faces/edges along their normal (Shift+Move does this live)", "icon_extrude.svg")
	_make_op_button("Inset", "inset_faces", "Inset selected faces (Shift+Scale does this live)", "icon_inset.svg")
	_make_op_button("Knife", "knife_tool", "Knife: Cut faces by placing vertices (Enter to complete cut)", "icon_knife.svg")
	_make_op_button("Loop Cut", "insert_edge_loop", "Insert an edge loop through the ring of quads crossed by the selected edge", "icon_loop_cut.svg")
	_make_op_button("Merge", "merge_faces", "Merge edge-adjacent selected faces into one n-gon", "icon_merge.svg")
	_make_op_button("Subdiv", "subdivide_faces", "Subdivide the selected quads into 4", "icon_subdivide.svg")
	_make_op_button("Weld", "weld_vertices", "Weld the selected vertices together at their centroid", "icon_weld.svg")
	_make_op_button("Detach", "detach_faces", "Detach the selected faces into a new PBMesh node", "icon_detach.svg")
	_make_op_button("Del", "delete_faces", "Delete the selected faces", "icon_delete.svg")

	# Shapes group
	_sep_shapes = _make_sep()
	_btn_new_shape = MenuButton.new()
	_btn_new_shape.name = "NewShape"
	_btn_new_shape.icon = _load_icon("icon_new_shape.svg")
	if _btn_new_shape.icon == null:
		_btn_new_shape.text = "New Shape"
	_btn_new_shape.flat = true
	_btn_new_shape.tooltip_text = "New Shape: Create a new primitive 3D shape (drag base on any surface, set height)"
	var popup: PopupMenu = _btn_new_shape.get_popup()
	for shape_id in PBShapeFactory.get_shape_ids():
		popup.add_item(String(shape_id).capitalize(), popup.item_count)
	popup.id_pressed.connect(_on_shape_menu_pressed)

	_btn_ngon = Button.new()
	_btn_ngon.name = "NgonTool"
	_btn_ngon.icon = _load_icon("icon_ngon.svg")
	if _btn_ngon.icon == null:
		_btn_ngon.text = "N-Gon"
	_btn_ngon.flat = true
	_btn_ngon.tooltip_text = "N-Gon: Draw custom polygon and extrude into 3D (Enter to size height)"
	_btn_ngon.pressed.connect(func(): shape_requested.emit(&"ngon"))

	_btn_edit_params = Button.new()
	_btn_edit_params.name = "EditParams"
	_btn_edit_params.icon = _load_icon("icon_edit_params.svg")
	if _btn_edit_params.icon == null:
		_btn_edit_params.text = "Edit Params"
	_btn_edit_params.flat = true
	_btn_edit_params.tooltip_text = "Edit Params: Re-edit creation parameters for the selected shape"
	_btn_edit_params.disabled = true
	_btn_edit_params.pressed.connect(func(): edit_params_requested.emit())

	# Overlay panel group
	_sep_overlay = _make_sep()
	_btn_overlay = Button.new()
	_btn_overlay.name = "OverlayToggle"
	_btn_overlay.icon = _load_icon("icon_panel.svg")
	if _btn_overlay.icon == null:
		_btn_overlay.text = "Panel"
	_btn_overlay.flat = true
	_btn_overlay.toggle_mode = true
	_btn_overlay.tooltip_text = "Toggle Overlay Panel: Show or hide the viewport overlay panel"
	_btn_overlay.toggled.connect(func(pressed: bool): overlay_toggled.emit(pressed))

	_btn_recover_overlay = Button.new()
	_btn_recover_overlay.name = "RecoverPanel"
	_btn_recover_overlay.icon = _load_icon("icon_panel_reset.svg")
	if _btn_recover_overlay.icon == null:
		_btn_recover_overlay.text = "↺"
	_btn_recover_overlay.flat = true
	_btn_recover_overlay.focus_mode = Control.FOCUS_NONE
	_btn_recover_overlay.tooltip_text = "Reset Panel: Recover overlay panel and dock to bottom-left corner"
	_btn_recover_overlay.pressed.connect(func(): reset_panel_requested.emit())

	# Docks & settings group
	_sep_docks = _make_sep()
	_btn_materials = Button.new()
	_btn_materials.name = "MaterialsButton"
	_btn_materials.icon = _load_icon("icon_materials.svg")
	if _btn_materials.icon == null:
		_btn_materials.text = "Material"
	_btn_materials.flat = true
	_btn_materials.tooltip_text = "Material & UV: Focus the material picker and UV mapping dock"
	_btn_materials.pressed.connect(func(): materials_dock_requested.emit())

	_btn_settings = Button.new()
	_btn_settings.name = "SettingsButton"
	_btn_settings.icon = _load_icon("icon_settings.svg")
	if _btn_settings.icon == null:
		_btn_settings.text = "Settings"
	_btn_settings.flat = true
	_btn_settings.toggle_mode = true
	_btn_settings.focus_mode = Control.FOCUS_NONE
	_btn_settings.tooltip_text = "Display settings (grid, wireframe, selection, hover opacity)"
	_btn_settings.toggled.connect(func(on: bool): settings_panel_toggled.emit(on))

	# Export group
	_sep_export = _make_sep()
	_btn_export = Button.new()
	_btn_export.name = "ExportButton"
	_btn_export.text = "Export"
	_btn_export.flat = true
	_btn_export.focus_mode = Control.FOCUS_NONE
	_btn_export.tooltip_text = "Export Map: Export scene to retro baked map or modern GLB"
	_btn_export.pressed.connect(func(): export_requested.emit())

	_update_row_layout()

func _make_sep() -> VSeparator:
	return VSeparator.new()

## Sets layout mode: AUTO (0), SINGLE (1), or TWO_ROWS (2).
func set_rows_mode(mode: int) -> void:
	rows_mode = (clampi(mode, 0, 2)) as RowsMode
	if rows_mode == RowsMode.AUTO:
		_check_auto_split()
	else:
		set_two_rows(rows_mode == RowsMode.TWO_ROWS)
	_update_split_button_tooltip()
## Sets whether the toolbar is split across 2 horizontal rows.
func set_two_rows(value: bool) -> void:
	if _two_rows == value and _row1.get_child_count() > 0:
		return
	_two_rows = value
	if _btn_split_rows != null and _btn_split_rows.button_pressed != value:
		_btn_split_rows.set_pressed_no_signal(value)
	_update_split_button_tooltip()
	_update_row_layout()

func _check_auto_split() -> void:
	if rows_mode != RowsMode.AUTO:
		return
	var avail_w := size.x
	if avail_w <= 10.0 and get_viewport() != null:
		avail_w = get_viewport().get_visible_rect().size.x
	if avail_w <= 10.0:
		return
	var should_two_rows := avail_w < AUTO_SPLIT_THRESHOLD
	if _two_rows != should_two_rows or _row1.get_child_count() == 0:
		_two_rows = should_two_rows
		if _btn_split_rows != null:
			_btn_split_rows.set_pressed_no_signal(_two_rows)
			_update_split_button_tooltip()
		_update_row_layout()
		split_rows_toggled.emit(_two_rows)

func _on_split_rows_button_toggled(pressed: bool) -> void:
	rows_mode = RowsMode.TWO_ROWS if pressed else RowsMode.SINGLE
	set_two_rows(pressed)
	split_rows_toggled.emit(pressed)
func _on_split_rows_button_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		rows_mode = RowsMode.AUTO
		_check_auto_split()
		_update_split_button_tooltip()
		split_rows_toggled.emit(_two_rows)

func _update_split_button_tooltip() -> void:
	if _btn_split_rows == null:
		return
	var mode_name := "Auto (%s)" % ("2 rows" if _two_rows else "1 row")
	if rows_mode == RowsMode.SINGLE:
		mode_name = "Single Row (Manual)"
	elif rows_mode == RowsMode.TWO_ROWS:
		mode_name = "Two Rows (Manual)"
	_btn_split_rows.tooltip_text = "Toolbar Layout: %s\nClick to toggle 1 vs 2 rows.\nRight-click to reset to Auto (< 1050px)." % mode_name

func _update_row_layout() -> void:
	for c in _row1.get_children():
		_row1.remove_child(c)
	for c in _row2.get_children():
		_row2.remove_child(c)

	var grp_header: Array[Control] = [_logo, _btn_split_rows]
	var grp_tools: Array[Control] = [_sep_tools, _btn_move, _btn_rotate, _btn_scale]
	var grp_modes: Array[Control] = [_sep_modes, _btn_object, _btn_vertex, _btn_edge, _btn_face]
	var grp_space: Array[Control] = [_sep_space, _btn_space]
	var grp_grid: Array[Control] = [_sep_grid, _btn_grid_panel, _lbl_grid_state]
	var grp_ops: Array[Control] = [
		_sep_ops,
		_op_buttons["extrude_faces"], _op_buttons["inset_faces"],
		_op_buttons["knife_tool"], _op_buttons["insert_edge_loop"],
		_op_buttons["merge_faces"], _op_buttons["subdivide_faces"],
		_op_buttons["weld_vertices"], _op_buttons["detach_faces"],
		_op_buttons["delete_faces"]
	]
	var grp_shapes: Array[Control] = [_sep_shapes, _btn_new_shape, _btn_ngon, _btn_edit_params]
	var grp_overlay: Array[Control] = [_sep_overlay, _btn_overlay, _btn_recover_overlay]
	var grp_docks: Array[Control] = [_sep_docks, _btn_materials, _btn_settings]
	var grp_export: Array[Control] = [_sep_export, _btn_export]

	if _two_rows:
		_row2.visible = true
		# Row 1: Logo + Split (left) | Tools | Operations
		for c in grp_header: _row1.add_child(c)
		for c in grp_tools: _row1.add_child(c)
		for c in grp_ops: _row1.add_child(c)

		# Row 2: Modes (without initial sep) | Space | Grid | Shapes | Overlay | Docks | Export
		_row2.add_child(_btn_object)
		_row2.add_child(_btn_vertex)
		_row2.add_child(_btn_edge)
		_row2.add_child(_btn_face)
		for c in grp_space: _row2.add_child(c)
		for c in grp_grid: _row2.add_child(c)
		for c in grp_shapes: _row2.add_child(c)
		for c in grp_overlay: _row2.add_child(c)
		for c in grp_docks: _row2.add_child(c)
		for c in grp_export: _row2.add_child(c)
	else:
		_row2.visible = false
		# Single Row: All 10 groups in sequential classic order
		for c in grp_header: _row1.add_child(c)
		for c in grp_tools: _row1.add_child(c)
		for c in grp_modes: _row1.add_child(c)
		for c in grp_space: _row1.add_child(c)
		for c in grp_grid: _row1.add_child(c)
		for c in grp_ops: _row1.add_child(c)
		for c in grp_shapes: _row1.add_child(c)
		for c in grp_overlay: _row1.add_child(c)
		for c in grp_docks: _row1.add_child(c)
		for c in grp_export: _row1.add_child(c)

## Total number of controls and buttons across the toolbar rows.
func get_item_count() -> int:
	return _row1.get_child_count() + _row2.get_child_count()

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
	return btn

func _make_op_button(text: String, op_name: String, tooltip: String, icon_name: String = "") -> Button:
	var btn := Button.new()
	btn.name = "Op" + text
	btn.flat = true
	btn.tooltip_text = "%s: %s" % [text, tooltip]
	btn.disabled = true
	btn.focus_mode = Control.FOCUS_NONE
	if icon_name != "":
		var ico := _load_icon(icon_name)
		if ico != null:
			btn.icon = ico
		else:
			btn.text = text
	else:
		btn.text = text
	btn.pressed.connect(func(): operation_requested.emit(op_name))
	_op_buttons[op_name] = btn
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
		if editor.element_selection_changed.is_connected(_on_selection_info_changed):
			editor.element_selection_changed.disconnect(_on_selection_info_changed)
		if editor.active_mesh_changed.is_connected(_on_selection_info_changed):
			editor.active_mesh_changed.disconnect(_on_selection_info_changed)
	editor = value
	if editor != null:
		editor.select_mode_changed.connect(_on_mode_changed)
		editor.tool_mode_changed.connect(_on_tool_changed)
		editor.orientation_space_changed.connect(_on_space_changed)
		editor.element_selection_changed.connect(_on_selection_info_changed)
		editor.active_mesh_changed.connect(_on_selection_info_changed)
		_on_mode_changed(editor.select_mode)
		_on_tool_changed(editor.tool_mode)
		_on_space_changed(editor.orientation_space)
		_on_selection_info_changed()

# ==============================================================================
# Button State Sync
# ==============================================================================

func _on_mode_changed(mode: PBEditor.SelectMode) -> void:
	_btn_object.set_pressed_no_signal(mode == PBEditor.SelectMode.OBJECT)
	_btn_vertex.set_pressed_no_signal(mode == PBEditor.SelectMode.VERTEX)
	_btn_edge.set_pressed_no_signal(mode == PBEditor.SelectMode.EDGE)
	_btn_face.set_pressed_no_signal(mode == PBEditor.SelectMode.FACE)

func _on_tool_changed(tool: PBEditor.ToolMode) -> void:
	_btn_move.set_pressed_no_signal(tool == PBEditor.ToolMode.MOVE)
	_btn_rotate.set_pressed_no_signal(tool == PBEditor.ToolMode.ROTATE)
	_btn_scale.set_pressed_no_signal(tool == PBEditor.ToolMode.SCALE)

func _on_space_changed(space: PBEditor.OrientationSpace) -> void:
	_btn_space.text = PBEditor.OrientationSpace.keys()[space].capitalize()

## Op buttons enable per selection context (mode + counts); Edit Params
## enables when the selected mesh is a pristine factory shape. Refreshed on
## every selection/mode/active-mesh change.
func _on_selection_info_changed(_arg = null) -> void:
	var sel := editor.selection if editor != null else null
	var faces_selected: bool = sel != null and sel.selected_face_count() > 0
	var edges_selected: bool = sel != null and sel.selected_edge_count() > 0
	var verts_selected: bool = sel != null and sel.selected_vertex_count() > 1
	var mode: PBEditor.SelectMode = editor.select_mode if editor != null else PBEditor.SelectMode.OBJECT
	var in_face: bool = mode == PBEditor.SelectMode.FACE
	var in_edge: bool = mode == PBEditor.SelectMode.EDGE
	var in_vertex: bool = mode == PBEditor.SelectMode.VERTEX

	if _op_buttons.has("extrude_faces"):
		# Face mode extrudes faces; edge mode extrudes fins — same button and
		# the same key action (the plugin routes by mode).
		_op_buttons["extrude_faces"].disabled = not (in_face and faces_selected) \
			and not (in_edge and edges_selected)
	if _op_buttons.has("inset_faces"):
		_op_buttons["inset_faces"].disabled = not (in_face and faces_selected)
	if _op_buttons.has("knife_tool"):
		_op_buttons["knife_tool"].disabled = editor == null or editor.active_mesh == null
	if _op_buttons.has("insert_edge_loop"):
		_op_buttons["insert_edge_loop"].disabled = not (in_edge and edges_selected)
		_op_buttons["merge_faces"].disabled = not (in_face and faces_selected)
	if _op_buttons.has("subdivide_faces"):
		_op_buttons["subdivide_faces"].disabled = not (in_face and faces_selected)
	if _op_buttons.has("weld_vertices"):
		_op_buttons["weld_vertices"].disabled = not (in_vertex and verts_selected)
	if _op_buttons.has("detach_faces"):
		_op_buttons["detach_faces"].disabled = not (in_face and faces_selected)
	if _op_buttons.has("delete_faces"):
		_op_buttons["delete_faces"].disabled = not (in_face and faces_selected)

	_btn_edit_params.disabled = not _active_mesh_editable()

## A mesh can re-open its params while it is still the pristine factory shape
## it was created as (no element drags, no mesh ops).
func _active_mesh_editable() -> bool:
	if editor == null or editor.active_mesh == null:
		return false
	var data: PBMeshData = editor.active_mesh.pb_mesh_data
	return data != null and data.shape_id != &"" and not data.shape_edited

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

## The toolbar row is persistent: it is ALWAYS visible. Context buttons are
## enabled whenever a PBMesh is selected — including OBJECT mode (Object is
## its own mode; switching back to an element mode must always be possible).
func set_editing_active(active: bool) -> void:
	for btn: Button in [_btn_move, _btn_rotate, _btn_scale, _btn_space,
			_btn_object, _btn_vertex, _btn_edge, _btn_face]:
		btn.disabled = not active
	# New Shape stays enabled: creation needs no editing context.
	_on_selection_info_changed()

func set_overlay_pinned(pinned: bool) -> void:
	_btn_overlay.set_pressed_no_signal(pinned)

## Mirrors PBGrid into the one-line readout WITHOUT emitting (the plugin
## owns the state; the overlay panel is the control surface).
func sync_grid(g: PBGrid) -> void:
	if g == null:
		return
	var text: String = "%sm" % str(snappedf(g.step(), 0.0001))
	var elev := g.elevation_summary()
	if elev != "":
		text += "  " + elev
	if not g.enabled:
		text += " (snap off)"
	_lbl_grid_state.text = text

## Lets the plugin reflect external close events back on the button.
func set_grid_panel_open(open: bool) -> void:
	_btn_grid_panel.set_pressed_no_signal(open)

## Reflects materials dock open/closed state on the button.
func set_materials_dock_active(active: bool) -> void:
	if _btn_materials != null and _btn_materials.button_pressed != active:
		_btn_materials.set_pressed_no_signal(active)

func set_settings_panel_open(open: bool) -> void:
	if _btn_settings != null and _btn_settings.button_pressed != open:
		_btn_settings.set_pressed_no_signal(open)

func new_shape_button() -> MenuButton:
	return _btn_new_shape
