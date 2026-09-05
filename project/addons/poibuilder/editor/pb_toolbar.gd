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
# ==============================================================================
# Icons
# ==============================================================================

const ICON_DIR := "res://addons/poibuilder/icons/"

# ==============================================================================
# Internal UI
# ==============================================================================

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
var _btn_edit_params: Button
var _btn_overlay: Button
var _btn_recover_overlay: Button
var _op_buttons: Dictionary = {}

var _btn_grid_panel: Button
var _lbl_grid_state: Label

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
	_btn_scale.tooltip_text = "Scale tool (R) — axis handles scale freely; the CENTER square scales all axes together (Shift + center on faces insets)"

	_label_space()

	# Element mode group — Object included: it is its own mode now, the only
	# place whole-object transforms happen.
	_btn_object = _create_mode_button("Object", PBEditor.SelectMode.OBJECT, "icon_object.svg")
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

	# Grid: one button opens the settings panel (the live readout mirrors the
	# current step so the active granularity is visible at a glance).
	_btn_grid_panel = Button.new()
	_btn_grid_panel.name = "GridPanelToggle"
	_btn_grid_panel.text = "Grid"
	_btn_grid_panel.toggle_mode = true
	_btn_grid_panel.flat = true
	_btn_grid_panel.focus_mode = Control.FOCUS_NONE
	_btn_grid_panel.tooltip_text = "Grid & snapping settings (unit, subdivisions, elevation, draw-on-grid). Keys: =/- subdivisions, Shift+=/- unit, [/] elevation, \\ reset, Y snap, G draw-on-grid"
	_btn_grid_panel.toggled.connect(func(on: bool): grid_panel_toggled.emit(on))
	add_child(_btn_grid_panel)

	_lbl_grid_state = Label.new()
	_lbl_grid_state.name = "GridState"
	_lbl_grid_state.text = "0.2m"
	_lbl_grid_state.tooltip_text = "Current snap step (unit / subdivisions) — elevation shown when nonzero"
	add_child(_lbl_grid_state)

	_label_space()

	# Mesh operations on the current selection with SVG icons.
	_make_op_button("Extrude", "extrude_faces", "Extrude selected faces/edges along their normal (Shift+Move does this live)", "icon_extrude.svg")
	_make_op_button("Inset", "inset_faces", "Inset selected faces (Shift+Scale does this live)", "icon_inset.svg")
	_make_op_button("Loop Cut", "insert_edge_loop", "Insert an edge loop through the ring of quads crossed by the selected edge", "icon_loop_cut.svg")
	_make_op_button("Merge", "merge_faces", "Merge edge-adjacent selected faces into one n-gon", "icon_merge.svg")
	_make_op_button("Subdiv", "subdivide_faces", "Subdivide the selected quads into 4", "icon_subdivide.svg")
	_make_op_button("Weld", "weld_vertices", "Weld the selected vertices together at their centroid", "icon_weld.svg")
	_make_op_button("Detach", "detach_faces", "Detach the selected faces into a new PBMesh node", "icon_detach.svg")
	_make_op_button("Del", "delete_faces", "Delete the selected faces", "icon_delete.svg")

	_label_space()

	# New Shape menu: creation entry point with SVG icon.
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
	add_child(_btn_new_shape)

	# Edit Params: re-open parameter modal with SVG icon.
	_btn_edit_params = Button.new()
	_btn_edit_params.name = "EditParams"
	_btn_edit_params.icon = _load_icon("icon_edit_params.svg")
	if _btn_edit_params.icon == null:
		_btn_edit_params.text = "Edit Params"
	_btn_edit_params.flat = true
	_btn_edit_params.tooltip_text = "Edit Params: Re-edit creation parameters for the selected shape"
	_btn_edit_params.disabled = true
	_btn_edit_params.pressed.connect(func(): edit_params_requested.emit())
	add_child(_btn_edit_params)

	_label_space()

	# Overlay panel toggle: represents current panel visibility state with SVG icon.
	_btn_overlay = Button.new()
	_btn_overlay.name = "OverlayToggle"
	_btn_overlay.icon = _load_icon("icon_panel.svg")
	if _btn_overlay.icon == null:
		_btn_overlay.text = "Panel"
	_btn_overlay.flat = true
	_btn_overlay.toggle_mode = true
	_btn_overlay.tooltip_text = "Toggle Overlay Panel: Show or hide the viewport overlay panel"
	_btn_overlay.toggled.connect(func(pressed: bool): overlay_toggled.emit(pressed))
	add_child(_btn_overlay)

	# Separate recovery button right next to panel toggle with reset icon.
	_btn_recover_overlay = Button.new()
	_btn_recover_overlay.name = "RecoverPanel"
	_btn_recover_overlay.icon = _load_icon("icon_panel_reset.svg")
	if _btn_recover_overlay.icon == null:
		_btn_recover_overlay.text = "↺"
	_btn_recover_overlay.flat = true
	_btn_recover_overlay.focus_mode = Control.FOCUS_NONE
	_btn_recover_overlay.tooltip_text = "Reset Panel: Recover overlay panel and dock to bottom-left corner"
	_btn_recover_overlay.pressed.connect(func(): reset_panel_requested.emit())
	add_child(_btn_recover_overlay)
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
	add_child(btn)
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
	if _op_buttons.has("insert_edge_loop"):
		_op_buttons["insert_edge_loop"].disabled = not (in_edge and edges_selected)
	if _op_buttons.has("merge_faces"):
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

func new_shape_button() -> MenuButton:
	return _btn_new_shape
