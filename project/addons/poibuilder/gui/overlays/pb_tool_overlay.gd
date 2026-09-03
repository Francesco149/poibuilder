## PBToolOverlay — Floating in-viewport readout / parameter panel.
##
## COMPACT BY DEFAULT: the panel only shows when it has something useful to
## say —
## - SELECTION info while elements are selected (active mode + count),
## - the live manipulation readout while a gizmo drag runs,
## - the shape-parameter MODAL (after creating a shape, or via Edit Params):
##   live-updating parameter controls with Apply/Cancel.
## Otherwise it hides itself, unless pinned via the toolbar's Panel toggle.
## Mesh-op buttons live in the persistent toolbar, NOT here.
##
## The panel can be dragged by its header and collapsed to just the header.
## It only occupies its own rect — clicks on it are consumed, everything
## else passes to the scene. Standard panel language: section headers and
## label/value rows.
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

## Emitted on every parameter control change while a params session is open
## (the plugin live-rebuilds the preview mesh).
signal param_changed(param_name: String, value: float)

## Emitted when the user presses Apply in the params modal.
signal params_applied

## Emitted when the user presses Cancel in the params modal.
signal params_canceled

# ==============================================================================
# UI
# ==============================================================================

var title_label: Label
var _collapse_btn: Button
var _body: VBoxContainer
var _selection_row: HBoxContainer
var _selection_mode_label: Label
var _selection_count_label: Label
var _drag_row: HBoxContainer
var drag_value_label: Label
var _params_section: VBoxContainer
var _params_title: Label
var _params_grid: GridContainer
var _params_hint: Label
var _creation_row: HBoxContainer
var _creation_label: Label

## param name -> SpinBox (rebuilt per params session)
var _param_spinboxes: Dictionary = {}

## param name -> CheckBox for KIND_BOOL params (rebuilt per params session)
var _param_checkboxes: Dictionary = {}

## Pin state (toolbar Panel toggle). Pinned = always visible while a mesh
## is selected; unpinned = auto-hide when there is nothing to show.
var pinned: bool = false:
	set(value):
		pinned = value
		update_visibility()

## True while a params session (modal) is open.
var params_open: bool = false

## Margin from the viewport edges when dragging or clamping.
const PADDING: float = 6.0

## Default offset from bottom-left corner when anchored.
const DEFAULT_OFFSET: float = 12.0

## Header drag state.
var _panel_dragging: bool = false
var _collapsed: bool = false
var _custom_position_set: bool = false

## Stored bottom-left position of the panel in parent coordinates.
## Anchoring by bottom-left means whenever content height changes (collapsing,
## expanding, opening modal, closing modal), the panel's bottom edge remains
## pinned in place and content grows/shrinks cleanly upwards with zero empty space below.
var _bottom_left: Vector2 = Vector2.ZERO

## Master visibility toggle state (driven by toolbar Panel toggle button).
## When false, the panel is strictly hidden regardless of selection or modals.
var panel_enabled: bool = true:
	set = set_panel_enabled

## Tracks if the user manually collapsed the panel via the collapse button.
var _user_collapsed: bool = false
var _ui_built: bool = false
func set_panel_enabled(value: bool) -> void:
	panel_enabled = value
	update_visibility()

# ==============================================================================
# Lifecycle
# ==============================================================================

func _ready() -> void:
	_ensure_ui()
	refresh()
	_apply_anchor.call_deferred()
	var p := get_parent() as Control
	if p != null and not p.resized.is_connected(_on_parent_resized):
		p.resized.connect(_on_parent_resized)
	if not resized.is_connected(_on_self_resized):
		resized.connect(_on_self_resized)

func _exit_tree() -> void:
	var p := get_parent() as Control
	if p != null and p.resized.is_connected(_on_parent_resized):
		p.resized.disconnect(_on_parent_resized)
	if resized.is_connected(_on_self_resized):
		resized.disconnect(_on_self_resized)

func _on_parent_resized() -> void:
	var parent_ctl := get_parent() as Control
	if parent_ctl == null:
		return
	if not _custom_position_set:
		_bottom_left = Vector2(DEFAULT_OFFSET, parent_ctl.size.y - DEFAULT_OFFSET)
	_update_position_from_bottom_left()

func _on_self_resized() -> void:
	_update_position_from_bottom_left()
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
	gui_input.connect(_on_header_gui_input)
	custom_minimum_size = Vector2(165, 0)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	add_child(vbox)

	# ── Header bar: styled titlebar with logo, title, reset, and collapse ───
	var header_bar := PanelContainer.new()
	header_bar.name = "HeaderBar"
	header_bar.mouse_filter = Control.MOUSE_FILTER_PASS
	var header_style := StyleBoxFlat.new()
	header_style.bg_color = Color(0.14, 0.16, 0.20, 0.9)
	header_style.corner_radius_top_left = 4
	header_style.corner_radius_top_right = 4
	header_style.corner_radius_bottom_left = 4
	header_style.corner_radius_bottom_right = 4
	header_style.content_margin_left = 6
	header_style.content_margin_right = 4
	header_style.content_margin_top = 4
	header_style.content_margin_bottom = 4
	header_bar.add_theme_stylebox_override("panel", header_style)
	vbox.add_child(header_bar)

	var header := HBoxContainer.new()
	header.name = "Header"
	header.add_theme_constant_override("separation", 6)
	header.mouse_filter = Control.MOUSE_FILTER_STOP
	header.gui_input.connect(_on_header_gui_input)
	header.mouse_default_cursor_shape = Control.CURSOR_MOVE
	header.tooltip_text = "Drag header to move panel | Double-click or Right-click to reset position"
	header_bar.add_child(header)
	var logo := TextureRect.new()
	logo.texture = _load_icon("pb_logo.svg")
	logo.custom_minimum_size = Vector2(16, 16)
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(logo)

	title_label = Label.new()
	title_label.name = "TitleLabel"
	title_label.text = "PoiBuilder v%s" % PBEditor.PLUGIN_VERSION
	title_label.add_theme_font_size_override("font_size", 13)
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(title_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(spacer)

	_collapse_btn = Button.new()
	_collapse_btn.name = "CollapseButton"
	_collapse_btn.flat = true
	_collapse_btn.focus_mode = Control.FOCUS_NONE
	_collapse_btn.text = "▾"
	_collapse_btn.tooltip_text = "Collapse / expand the panel"
	_collapse_btn.pressed.connect(_on_collapse_pressed)
	header.add_child(_collapse_btn)

	var reset_btn := Button.new()
	reset_btn.name = "ResetButton"
	reset_btn.flat = true
	reset_btn.focus_mode = Control.FOCUS_NONE
	reset_btn.text = "↺"
	reset_btn.tooltip_text = "Reset panel position to bottom-left corner"
	reset_btn.pressed.connect(reset_to_default_position)
	header.add_child(reset_btn)

	# ── Body (hidden when collapsed) ─────────────────────────────────────────
	_body = VBoxContainer.new()
	_body.name = "Body"
	_body.add_theme_constant_override("separation", 4)
	vbox.add_child(_body)

	# SELECTION row: active mode + count, only while something is selected.
	_selection_row = HBoxContainer.new()
	_selection_row.name = "SelectionRow"
	_selection_row.add_theme_constant_override("separation", 8)
	_body.add_child(_selection_row)
	var mode_caption := _make_row_label("Selection")
	_selection_row.add_child(mode_caption)
	_selection_mode_label = _make_value_label()
	_selection_mode_label.name = "ModeValue"
	_selection_row.add_child(_selection_mode_label)
	_selection_count_label = _make_value_label()
	_selection_count_label.name = "CountValue"
	_selection_row.add_child(_selection_count_label)

	# DRAG row: live manipulation readout, only while a gizmo drag runs.
	_drag_row = HBoxContainer.new()
	_drag_row.name = "DragRow"
	_drag_row.add_theme_constant_override("separation", 8)
	_body.add_child(_drag_row)
	_drag_row.add_child(_make_row_label("Drag"))
	drag_value_label = _make_value_label()
	drag_value_label.name = "DragValue"
	drag_value_label.text = "—"
	_drag_row.add_child(drag_value_label)

	# CREATION row: what the shape-creation session expects next. Only while
	# a session is running (the plugin feeds the text).
	_creation_row = HBoxContainer.new()
	_creation_row.name = "CreationRow"
	_creation_row.add_theme_constant_override("separation", 8)
	_body.add_child(_creation_row)
	_creation_row.add_child(_make_row_label("Create"))
	_creation_label = _make_value_label()
	_creation_label.name = "CreationValue"
	_creation_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_creation_row.add_child(_creation_label)
	_creation_row.visible = false

	# PARAMS section: the shape-parameter modal.
	_params_section = VBoxContainer.new()
	_params_section.name = "ParamsSection"
	_params_section.add_theme_constant_override("separation", 3)
	_body.add_child(_params_section)
	_params_title = Label.new()
	_params_title.name = "ParamsTitle"
	_params_title.text = "SHAPE PARAMETERS"
	_params_title.add_theme_font_size_override("font_size", 10)
	_params_title.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	_params_section.add_child(_params_title)

	_params_grid = GridContainer.new()
	_params_grid.name = "ParamsGrid"
	_params_grid.columns = 2
	_params_grid.add_theme_constant_override("h_separation", 6)
	_params_grid.add_theme_constant_override("v_separation", 2)
	_params_section.add_child(_params_grid)

	_params_hint = Label.new()
	_params_hint.name = "ParamsHint"
	_params_hint.text = "Changes preview live"
	_params_hint.add_theme_font_size_override("font_size", 9)
	_params_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.45))
	_params_section.add_child(_params_hint)
	var buttons_row := HBoxContainer.new()
	buttons_row.alignment = BoxContainer.ALIGNMENT_END
	buttons_row.add_theme_constant_override("separation", 6)
	_params_section.add_child(buttons_row)

	var apply_btn := Button.new()
	apply_btn.name = "ApplyParams"
	apply_btn.text = "Apply"
	apply_btn.focus_mode = Control.FOCUS_NONE
	apply_btn.pressed.connect(func(): params_applied.emit())
	buttons_row.add_child(apply_btn)

	var cancel_btn := Button.new()
	cancel_btn.name = "CancelParams"
	cancel_btn.text = "Cancel"
	cancel_btn.focus_mode = Control.FOCUS_NONE
	cancel_btn.pressed.connect(func(): params_canceled.emit())
	buttons_row.add_child(cancel_btn)

	_params_section.visible = false
	_selection_row.visible = false
	_drag_row.visible = false

func _apply_anchor() -> void:
	if not is_inside_tree():
		return
	reset_to_default_position()

## Updates the top-left position based on the pinned bottom-left anchor.
func _update_position_from_bottom_left() -> void:
	var parent_ctl := get_parent() as Control
	if parent_ctl == null:
		position.x = _bottom_left.x
		position.y = maxf(PADDING, _bottom_left.y - size.y)
		return

	var min_x: float = PADDING
	var max_x: float = maxf(PADDING, parent_ctl.size.x - size.x - PADDING)
	_bottom_left.x = clampf(_bottom_left.x, min_x, max_x)

	var max_y: float = parent_ctl.size.y - PADDING
	var min_y: float = PADDING + size.y
	if min_y > max_y:
		position.x = _bottom_left.x
		position.y = PADDING
		_bottom_left.y = PADDING + size.y
		return

	_bottom_left.y = clampf(_bottom_left.y, min_y, max_y)
	position.x = _bottom_left.x
	position.y = _bottom_left.y - size.y

## Clamps the panel so it stays fully inside the parent viewport with padding.
func clamp_to_viewport() -> void:
	_update_position_from_bottom_left()

## Resets panel back to its default bottom-left docked location.
func reset_to_default_position() -> void:
	_custom_position_set = false
	_user_collapsed = false
	var parent_ctl := get_parent() as Control
	if parent_ctl != null:
		set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT, Control.PRESET_MODE_MINSIZE)
		grow_vertical = Control.GROW_DIRECTION_END
		grow_horizontal = Control.GROW_DIRECTION_END
		reset_size()
		_bottom_left = Vector2(DEFAULT_OFFSET, parent_ctl.size.y - DEFAULT_OFFSET)
	else:
		_bottom_left = Vector2(DEFAULT_OFFSET, DEFAULT_OFFSET + size.y)
	_update_position_from_bottom_left()
## Returns true if the panel is completely outside the parent's visible rect.
func is_offscreen() -> bool:
	var parent_ctl := get_parent() as Control
	if parent_ctl == null or not is_inside_tree():
		return false
	var parent_rect := Rect2(Vector2.ZERO, parent_ctl.size)
	var panel_rect := Rect2(position, size)
	return not parent_rect.intersects(panel_rect)

## Ensures the panel is on-screen, recovering it if it was pushed off.
func ensure_visible_and_clamped() -> void:
	if is_offscreen():
		reset_to_default_position()
	elif _custom_position_set:
		clamp_to_viewport()
# ── UI helpers ────────────────────────────────────────────────────────────────

static func _load_icon(icon_name: String) -> Texture2D:
	var path := "res://addons/poibuilder/icons/" + icon_name
	if ResourceLoader.exists(path):
		return load(path)
	return null

func _make_row_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	return label

func _make_value_label() -> Label:
	var label := Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	return label

# ── Header drag + collapse ────────────────────────────────────────────────────

func _on_header_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.double_click and mb.pressed:
				_panel_dragging = false
				reset_to_default_position()
				accept_event()
				return
			_panel_dragging = mb.pressed
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_show_header_context_menu()
			accept_event()
	elif event is InputEventMouseMotion and _panel_dragging:
		var parent_ctl := get_parent() as Control
		if parent_ctl != null:
			_custom_position_set = true
			var mm := event as InputEventMouseMotion
			_bottom_left += mm.relative
			_update_position_from_bottom_left()
			accept_event()
func _show_header_context_menu() -> void:
	var popup := PopupMenu.new()
	popup.add_item("Reset Position to Bottom-Left", 0)
	popup.add_item("Collapse" if not _collapsed else "Expand", 1)
	popup.id_pressed.connect(func(id: int):
		if id == 0:
			reset_to_default_position()
		elif id == 1:
			_on_collapse_pressed()
		popup.queue_free()
	)
	popup.popup_hide.connect(func(): popup.queue_free())
	add_child(popup)
	popup.position = Vector2i(get_global_mouse_position())
	popup.popup()

func _on_collapse_pressed() -> void:
	_user_collapsed = not _user_collapsed
	_body.visible = not _user_collapsed
	_collapse_btn.text = "▸" if _user_collapsed else "▾"
	_update_position_from_bottom_left.call_deferred()

func expand() -> void:
	_user_collapsed = false
	_body.visible = true
	_collapse_btn.text = "▾"
	_update_position_from_bottom_left.call_deferred()
# ==============================================================================
# Creation hint (what the session expects next)
# ==============================================================================

## Shows/hides the creation guidance row. Empty text hides it and lets the
## panel auto-hide again.
func set_creation_hint(text: String) -> void:
	_ensure_ui()
	_creation_label.text = text
	_creation_row.visible = text != ""
	update_visibility()

func has_creation_hint() -> bool:
	return _ui_built and _creation_row.visible

# ==============================================================================
# Params session (modal)
# ==============================================================================

## Opens a shape-parameter session: one row per `def`
## ({name, label, min, max, step, suffix}) seeded from `values`.
## Changes emit param_changed live (the plugin rebuilds the preview).
func open_params(title: String, defs: Array, values: Dictionary) -> void:
	_ensure_ui()
	_params_title.text = title.to_upper()
	for child in _params_grid.get_children():
		child.queue_free()
	_param_spinboxes.clear()
	_param_checkboxes.clear()

	for def in defs:
		var caption := _make_row_label(str(def.get("label", def.get("name", "?"))))
		_params_grid.add_child(caption)
		var param_name := str(def.get("name", ""))
		if str(def.get("kind", "")) == PBShapeParams.KIND_BOOL:
			var check := CheckBox.new()
			check.name = "Param" + param_name
			check.button_pressed = float(values.get(param_name, 0.0)) > 0.5
			check.focus_mode = Control.FOCUS_NONE
			check.toggled.connect(_on_param_toggled.bind(param_name))
			_params_grid.add_child(check)
			_param_checkboxes[param_name] = check
			continue
		var spin := SpinBox.new()
		spin.name = "Param" + param_name
		spin.custom_minimum_size = Vector2(64, 0)
		spin.min_value = float(def.get("min", 0.01))
		spin.max_value = float(def.get("max", 1000.0))
		spin.step = float(def.get("step", 0.1))
		spin.suffix = str(def.get("suffix", ""))
		spin.value = float(values.get(param_name, def.get("min", 0.01)))
		spin.value_changed.connect(_on_param_value_changed.bind(param_name))
		_params_grid.add_child(spin)
		_param_spinboxes[param_name] = spin

	params_open = true
	panel_enabled = true
	_params_section.visible = true
	reset_size()
	expand()  # the modal must be visible even if the body was collapsed
	refresh()
	_update_position_from_bottom_left.call_deferred()

## Updates several param values without emitting param_changed (used to
## snap back on cancel).
func set_param_values(values: Dictionary) -> void:
	for param_name in _param_spinboxes:
		if values.has(param_name):
			var spin: SpinBox = _param_spinboxes[param_name]
			spin.set_value_no_signal(float(values[param_name]))
	for param_name in _param_checkboxes:
		if values.has(param_name):
			var check: CheckBox = _param_checkboxes[param_name]
			check.set_pressed_no_signal(float(values[param_name]) > 0.5)

## Snapshot of all param values currently in the controls.
func get_param_values() -> Dictionary:
	var out := {}
	for param_name in _param_spinboxes:
		out[param_name] = _param_spinboxes[param_name].value
	for param_name in _param_checkboxes:
		out[param_name] = 1.0 if _param_checkboxes[param_name].button_pressed else 0.0
	return out

func close_params() -> void:
	params_open = false
	if _ui_built:
		_params_section.visible = false
	for child in _params_grid.get_children():
		child.queue_free()
	_param_spinboxes.clear()
	_param_checkboxes.clear()
	refresh()

func _on_param_value_changed(value: float, param_name: String) -> void:
	if params_open:
		param_changed.emit(param_name, value)

func _on_param_toggled(pressed: bool, param_name: String) -> void:
	if params_open:
		param_changed.emit(param_name, 1.0 if pressed else 0.0)

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
	if element_editor != null and element_editor.drag_active:
		_ensure_ui()
		_drag_row.visible = true
		drag_value_label.text = element_editor.drag_readout()
		update_visibility()
		return
	refresh()
# ==============================================================================
# Refresh + visibility
# ==============================================================================

## Refreshes all readouts and re-evaluates the panel's visibility.
func refresh() -> void:
	_ensure_ui()

	var has_selection := false
	if editor != null and editor.selection != null:
		var sel := editor.selection
		var mesh_data: PBMeshData = editor.active_mesh.pb_mesh_data if editor.active_mesh != null else null
		var count := 0
		var total := 0
		if editor.active_mesh != null and mesh_data != null:
			match editor.select_mode:
				PBEditor.SelectMode.FACE:
					count = sel.selected_face_count()
					total = mesh_data.faces.size()
				PBEditor.SelectMode.EDGE:
					count = sel.selected_edge_count()
					total = mesh_data.get_common_edges().size()
				PBEditor.SelectMode.VERTEX:
					count = sel.selected_vertex_count()
					total = mesh_data.shared_vertices.size()
				_:
					pass
			has_selection = count > 0
			_selection_mode_label.text = PBEditor.mode_name(editor.select_mode)
			_selection_count_label.text = "%d / %d" % [count, total]
		else:
			_selection_mode_label.text = "None"
			_selection_count_label.text = "No mesh"
	_selection_row.visible = has_selection

	var dragging := element_editor != null and element_editor.drag_active
	_drag_row.visible = dragging
	if dragging:
		drag_value_label.text = element_editor.drag_readout()

	# Content presence: is there anything meaningful to display in the body?
	var has_content := params_open or has_creation_hint() or dragging or has_selection

	# "empty panel is auto collapsed to just the header, not displayed empty."
	if editor != null and not has_content:
		_body.visible = false
		_collapse_btn.text = "▸"
	else:
		_body.visible = not _user_collapsed
		_collapse_btn.text = "▸" if _user_collapsed else "▾"
	update_visibility()
	_update_position_from_bottom_left.call_deferred()

## Evaluates panel visibility.
## When panel_enabled is false (user toggled Panel off on toolbar), panel is strictly hidden.
## Otherwise, shows if pinned, params open, creation hint, or if selection/drag is active on a mesh.
func update_visibility() -> void:
	if not panel_enabled:
		visible = false
		return
	var creation_hint := has_creation_hint()
	if editor == null:
		visible = params_open or creation_hint
		return
	var mesh_selected := editor.active_mesh != null
	visible = (mesh_selected and (pinned or params_open or _has_selection() \
		or (element_editor != null and element_editor.drag_active))) \
		or creation_hint
func _has_selection() -> bool:
	if editor == null or editor.selection == null:
		return false
	return editor.selection.selected_face_count() > 0 \
		or editor.selection.selected_edge_count() > 0 \
		or editor.selection.selected_vertex_count() > 0
