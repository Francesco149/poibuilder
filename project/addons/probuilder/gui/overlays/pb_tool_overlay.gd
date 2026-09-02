## PBToolOverlay — Floating in-viewport tool panel.
##
## Replaces the docked panels: a small PanelContainer parented to the 3D
## editor's viewport (bottom-left) that uses standard panel language —
## section headers and label/value rows with real controls, ready to grow
## tool/shape parameter sections (e.g. stair parameters after placing
## stairs). It only occupies its own rect — clicks on it are consumed,
## everything else passes to the scene. It appears only while a PBMesh is
## being edited (visibility is managed by the plugin).
##
## Sections:
## - TOOL: transform tool buttons, orientation space picker, live drag readout
## - SELECTION: element mode and selection counts
## - OPERATIONS: mesh ops (extrude/inset/subdivide/delete/detach) acting on
##   the current selection, with numeric params (extrude distance, inset
##   amount). Buttons enable per selection context — see refresh().
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

## Emitted when the user clicks a mesh operation button. The plugin performs
## the op — selection reading and undo live there.
signal operation_requested(op_name: String)

## Header
var title_label: Label
## Tool section controls
var _btn_move: Button
var _btn_rotate: Button
var _btn_scale: Button
var space_option: OptionButton
var drag_value_label: Label
## Selection section controls
var mode_value_label: Label
var vertices_value_label: Label
var edges_value_label: Label
var faces_value_label: Label
## Operations section controls
var extrude_faces_btn: Button
var extrude_edges_btn: Button
var loop_cut_btn: Button
var weld_vertices_btn: Button
var inset_btn: Button
var subdivide_btn: Button
var delete_btn: Button
var detach_btn: Button
var merge_btn: Button
var extrude_distance_spin: SpinBox
var inset_amount_spin: SpinBox

## Numeric params read by the plugin when performing ops.
var extrude_distance: float:
	get: return extrude_distance_spin.value if extrude_distance_spin != null else 0.25
var inset_amount: float:
	get: return inset_amount_spin.value if inset_amount_spin != null else 0.25

var _tool_group: ButtonGroup = ButtonGroup.new()

var _ui_built: bool = false

# ==============================================================================
# Lifecycle
# ==============================================================================

func _ready() -> void:
	_ensure_ui()
	refresh()
	_apply_anchor.call_deferred()

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
	for side in ["margin_left", "margin_right"]:
		margin.add_theme_constant_override(side, 10)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 8)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	margin.add_child(vbox)

	# ── Header ────────────────────────────────────────────────────────────────
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	vbox.add_child(header)

	var logo := TextureRect.new()
	logo.texture = _load_icon("pb_logo.svg")
	logo.custom_minimum_size = Vector2(16, 16)
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(logo)

	title_label = Label.new()
	title_label.name = "TitleLabel"
	title_label.text = "PoiBuilder v%s" % PBEditor.PLUGIN_VERSION
	title_label.add_theme_font_size_override("font_size", 13)
	header.add_child(title_label)

	# ── Tool section ──────────────────────────────────────────────────────────
	vbox.add_child(_make_section_label("Tool"))

	var tool_grid := _make_grid(vbox)

	tool_grid.add_child(_make_row_label("Transform"))
	var tool_row := HBoxContainer.new()
	tool_row.add_theme_constant_override("separation", 2)
	_btn_move = _make_tool_button("Move", PBEditor.ToolMode.MOVE, "icon_move.svg")
	_btn_rotate = _make_tool_button("Rotate", PBEditor.ToolMode.ROTATE, "icon_rotate.svg")
	_btn_scale = _make_tool_button("Scale", PBEditor.ToolMode.SCALE, "icon_scale.svg")
	tool_row.add_child(_btn_move)
	tool_row.add_child(_btn_rotate)
	tool_row.add_child(_btn_scale)
	tool_grid.add_child(tool_row)

	tool_grid.add_child(_make_row_label("Space"))
	space_option = OptionButton.new()
	space_option.name = "SpaceOption"
	for space_name in PBEditor.OrientationSpace.keys():
		space_option.add_item(String(space_name).capitalize())
	space_option.selected = 0
	space_option.item_selected.connect(_on_space_selected)
	tool_grid.add_child(space_option)

	tool_grid.add_child(_make_row_label("Last Drag"))
	drag_value_label = _make_value_label()
	drag_value_label.name = "DragValue"
	drag_value_label.text = "—"
	tool_grid.add_child(drag_value_label)

	# ── Selection section ─────────────────────────────────────────────────────
	vbox.add_child(_make_section_label("Selection"))

	var sel_grid := _make_grid(vbox)

	sel_grid.add_child(_make_row_label("Mode"))
	mode_value_label = _make_value_label()
	mode_value_label.name = "ModeValue"
	sel_grid.add_child(mode_value_label)

	sel_grid.add_child(_make_row_label("Vertices"))
	vertices_value_label = _make_value_label()
	vertices_value_label.name = "VerticesValue"
	sel_grid.add_child(vertices_value_label)

	sel_grid.add_child(_make_row_label("Edges"))
	edges_value_label = _make_value_label()
	edges_value_label.name = "EdgesValue"
	sel_grid.add_child(edges_value_label)

	sel_grid.add_child(_make_row_label("Faces"))
	faces_value_label = _make_value_label()
	faces_value_label.name = "FacesValue"
	sel_grid.add_child(faces_value_label)

	# ── Operations section ────────────────────────────────────────────────────
	vbox.add_child(_make_section_label("Operations"))

	var ops_grid := _make_grid(vbox)

	ops_grid.add_child(_make_row_label("Faces"))
	var face_ops_row := HBoxContainer.new()
	face_ops_row.add_theme_constant_override("separation", 2)
	extrude_faces_btn = _make_op_button("Extrude", "extrude_faces", "Extrude the selected faces along their normal")
	inset_btn = _make_op_button("Inset", "inset_faces", "Inset the selected faces (planar ring)")
	subdivide_btn = _make_op_button("Subdiv", "subdivide_faces", "Subdivide the selected quads into 4")
	merge_btn = _make_op_button("Merge", "merge_faces", "Merge coplanar edge-adjacent selected faces into one")
	delete_btn = _make_op_button("Del", "delete_faces", "Delete the selected faces")
	detach_btn = _make_op_button("Detach", "detach_faces", "Detach the selected faces into a new PBMesh")
	for btn: Button in [extrude_faces_btn, inset_btn, subdivide_btn, merge_btn, delete_btn, detach_btn]:
		face_ops_row.add_child(btn)
	ops_grid.add_child(face_ops_row)

	ops_grid.add_child(_make_row_label("Edges"))
	var edge_ops_row := HBoxContainer.new()
	edge_ops_row.add_theme_constant_override("separation", 2)
	extrude_edges_btn = _make_op_button("Extrude", "extrude_edges", "Extrude the selected edges along their faces' average normal")
	loop_cut_btn = _make_op_button("Loop Cut", "insert_edge_loop", "Insert an edge loop through the ring of quads crossed by the selected edge")
	edge_ops_row.add_child(extrude_edges_btn)
	edge_ops_row.add_child(loop_cut_btn)
	ops_grid.add_child(edge_ops_row)

	ops_grid.add_child(_make_row_label("Vertices"))
	weld_vertices_btn = _make_op_button("Weld", "weld_vertices",
		"Weld the selected vertices together at their centroid")
	ops_grid.add_child(weld_vertices_btn)

	ops_grid.add_child(_make_row_label("Distance"))
	extrude_distance_spin = SpinBox.new()
	extrude_distance_spin.name = "ExtrudeDistance"
	extrude_distance_spin.min_value = 0.01
	extrude_distance_spin.max_value = 100.0
	extrude_distance_spin.step = 0.05
	extrude_distance_spin.value = 0.25
	extrude_distance_spin.suffix = "m"
	ops_grid.add_child(extrude_distance_spin)

	ops_grid.add_child(_make_row_label("Inset"))
	inset_amount_spin = SpinBox.new()
	inset_amount_spin.name = "InsetAmount"
	inset_amount_spin.min_value = 0.01
	inset_amount_spin.max_value = 0.95
	inset_amount_spin.step = 0.05
	inset_amount_spin.value = 0.25
	ops_grid.add_child(inset_amount_spin)

func _apply_anchor() -> void:
	if not is_inside_tree():
		return
	# Bottom-left of the host viewport, 12px in from the corner, growing up
	# and right from there.
	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 12)
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	grow_horizontal = Control.GROW_DIRECTION_END

# ── UI helpers ────────────────────────────────────────────────────────────────

static func _load_icon(icon_name: String) -> Texture2D:
	var path := "res://addons/probuilder/icons/" + icon_name
	if ResourceLoader.exists(path):
		return load(path)
	return null

func _make_section_label(text: String) -> Label:
	var label := Label.new()
	label.text = text.to_upper()
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	return label

func _make_grid(parent: Control) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 3)
	parent.add_child(grid)
	return grid

func _make_row_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	return label

func _make_value_label() -> Label:
	var label := Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label

func _make_tool_button(text: String, tool: PBEditor.ToolMode, icon_name: String) -> Button:
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

func _make_op_button(text: String, op_name: String, tooltip: String) -> Button:
	var btn := Button.new()
	btn.name = "Op" + text
	btn.text = text
	btn.tooltip_text = tooltip
	btn.focus_mode = Control.FOCUS_NONE
	btn.pressed.connect(func(): operation_requested.emit(op_name))
	return btn

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

func _on_space_selected(index: int) -> void:
	if editor != null:
		editor.orientation_space = index as PBEditor.OrientationSpace

func _on_tool_button_pressed(tool: PBEditor.ToolMode) -> void:
	if editor != null:
		editor.tool_mode = tool
		var current: Button = [_btn_move, _btn_rotate, _btn_scale][tool]
		current.set_pressed_no_signal(true)

# ==============================================================================
# Refresh Logic
# ==============================================================================

## Refreshes all readouts and control states from the current editor state.
func refresh() -> void:
	_ensure_ui()

	if editor == null:
		mode_value_label.text = "Object"
		vertices_value_label.text = "0 / 0"
		edges_value_label.text = "0 / 0"
		faces_value_label.text = "0 / 0"
		drag_value_label.text = "—"
		return

	# 1. Mode, transform tool buttons, orientation space
	mode_value_label.text = PBEditor.mode_name(editor.select_mode)
	_btn_move.set_pressed_no_signal(editor.tool_mode == PBEditor.ToolMode.MOVE)
	_btn_rotate.set_pressed_no_signal(editor.tool_mode == PBEditor.ToolMode.ROTATE)
	_btn_scale.set_pressed_no_signal(editor.tool_mode == PBEditor.ToolMode.SCALE)
	space_option.selected = editor.orientation_space

	# 2. Selection counts against the mesh's element totals
	var sel := editor.selection
	var totals := {"v": 0, "e": 0, "f": 0}
	var mesh_data: PBMeshData = editor.active_mesh.pb_mesh_data if editor.active_mesh != null else null
	if mesh_data != null:
		totals.v = mesh_data.shared_vertices.size()
		totals.e = mesh_data.get_common_edges().size()
		totals.f = mesh_data.faces.size()
	if sel != null:
		vertices_value_label.text = "%d / %d" % [sel.selected_vertex_count(), totals.v]
		edges_value_label.text = "%d / %d" % [sel.selected_edge_count(), totals.e]
		faces_value_label.text = "%d / %d" % [sel.selected_face_count(), totals.f]

	# 3. Live transform readout while the native gizmo drags elements
	drag_value_label.text = element_editor.drag_readout() if element_editor != null else "—"

	# 4. Operation buttons enable per selection context (mode + counts).
	var faces_selected: bool = sel.selected_face_count() > 0
	var edges_selected: bool = sel.selected_edge_count() > 0
	for btn: Button in [extrude_faces_btn, inset_btn, subdivide_btn, merge_btn, delete_btn, detach_btn]:
		btn.disabled = not faces_selected
	extrude_edges_btn.disabled = not edges_selected
	loop_cut_btn.disabled = not edges_selected
	weld_vertices_btn.disabled = sel.selected_vertex_count() < 2
