## PBUvEditorPanel — Dedicated UV Editor Panel for PoiBuilder.
##
## Hosts the 2D UV canvas (PBUvCanvas) inside Godot's bottom panel dock with:
## - Full toolbar: Element modes (Vertex/Edge/Face/Island), UV Channels (UV1/UV2),
##   Frame Selection / Frame Unit Quad, Texture underlay & tiling toggles,
##   Zoom and Snap step controls, and Pop-out floating window toggle.
## - Bidirectional selection synchronization between 2D UV canvas and 3D viewport.
## - Integration with EditorUndoRedoManager for non-destructive edits.
@tool
class_name PBUvEditorPanel
extends VBoxContainer

# ==============================================================================
# Signals
# ==============================================================================

## Emitted when the panel requests to pop out into an independent floating window.
signal pop_out_toggled(floating: bool)

## Emitted when selection changes inside the UV Editor.
signal uv_selection_changed

# ==============================================================================
# Controls
# ==============================================================================

var canvas: PBUvCanvas

# Toolbar controls
var _toolbar: HBoxContainer
var _btn_mode_vert: Button
var _btn_mode_edge: Button
var _btn_mode_face: Button
var _btn_mode_island: Button
var _mode_group: ButtonGroup

var _opt_channel: OptionButton
var _btn_frame_unit: Button
var _btn_frame_sel: Button

var _btn_toggle_tex: Button
var _btn_toggle_tile: Button
var _slider_opacity: Slider

var _btn_snap_toggle: Button
var _opt_snap_step: OptionButton

var _btn_pop_out: Button
var _lbl_status: Label

# Floating window instance
var _floating_window: Window = null
var _is_floating: bool = false

# Mesh & Editor references
var active_mesh: PBMesh = null:
	set = set_active_mesh
var editor: PBEditor = null

var _syncing_selection: bool = false

# ==============================================================================
# Lifecycle
# ==============================================================================

func _init() -> void:
	name = "PBUvEditorPanel"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	custom_minimum_size = Vector2(300, 200)
	_build_ui()

func _ready() -> void:
	_update_status()

# ==============================================================================
# UI Construction
# ==============================================================================

func _build_ui() -> void:
	# 1. Top Toolbar Row
	_toolbar = HBoxContainer.new()
	_toolbar.name = "Toolbar"
	_toolbar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_toolbar.add_theme_constant_override("separation", 6)
	add_child(_toolbar)

	# --- Mode Buttons ---
	_mode_group = ButtonGroup.new()

	_btn_mode_face = _create_mode_btn("Face", PBUvCanvas.SelectMode.FACE, "Face selection mode")
	_btn_mode_face.button_pressed = true
	_btn_mode_vert = _create_mode_btn("Vertex", PBUvCanvas.SelectMode.VERTEX, "UV Vertex selection mode")
	_btn_mode_edge = _create_mode_btn("Edge", PBUvCanvas.SelectMode.EDGE, "UV Edge selection mode")
	_btn_mode_island = _create_mode_btn("Island", PBUvCanvas.SelectMode.ISLAND, "UV Island (connected shell) selection mode")

	_toolbar.add_child(_btn_mode_face)
	_toolbar.add_child(_btn_mode_vert)
	_toolbar.add_child(_btn_mode_edge)
	_toolbar.add_child(_btn_mode_island)

	_toolbar.add_child(_make_vsep())

	# --- Framing ---
	_btn_frame_unit = Button.new()
	_btn_frame_unit.name = "FrameUnit"
	_btn_frame_unit.text = "[0,1]"
	_btn_frame_unit.tooltip_text = "Frame [0, 1] unit square"
	_btn_frame_unit.pressed.connect(func(): if canvas: canvas.frame_unit_square())
	_toolbar.add_child(_btn_frame_unit)

	_btn_frame_sel = Button.new()
	_btn_frame_sel.name = "FrameSel"
	_btn_frame_sel.text = "⛶ Frame"
	_btn_frame_sel.tooltip_text = "Frame Selection (F)"
	_btn_frame_sel.pressed.connect(func(): if canvas: canvas.frame_selection())
	_toolbar.add_child(_btn_frame_sel)

	_toolbar.add_child(_make_vsep())

	# --- Snapping ---
	_btn_snap_toggle = Button.new()
	_btn_snap_toggle.name = "SnapToggle"
	_btn_snap_toggle.text = "Snap"
	_btn_snap_toggle.toggle_mode = true
	_btn_snap_toggle.button_pressed = true
	_btn_snap_toggle.tooltip_text = "Toggle UV snapping to grid"
	_btn_snap_toggle.toggled.connect(_on_snap_toggled)
	_toolbar.add_child(_btn_snap_toggle)

	_opt_snap_step = OptionButton.new()
	_opt_snap_step.name = "SnapStep"
	_opt_snap_step.tooltip_text = "UV Snap Grid Step"
	_opt_snap_step.add_item("1/32 (0.03125)", 0)
	_opt_snap_step.add_item("1/16 (0.0625)", 1)
	_opt_snap_step.add_item("1/8 (0.125)", 2)
	_opt_snap_step.add_item("1/4 (0.25)", 3)
	_opt_snap_step.add_item("1/2 (0.5)", 4)
	_opt_snap_step.add_item("1.0 (1.0)", 5)
	_opt_snap_step.selected = 2 # 1/8 default
	_opt_snap_step.item_selected.connect(_on_snap_step_selected)
	_toolbar.add_child(_opt_snap_step)

	_toolbar.add_child(_make_vsep())

	# --- Texture Underlay & Tiling ---
	_btn_toggle_tex = Button.new()
	_btn_toggle_tex.name = "ToggleTex"
	_btn_toggle_tex.text = "Texture"
	_btn_toggle_tex.toggle_mode = true
	_btn_toggle_tex.button_pressed = true
	_btn_toggle_tex.tooltip_text = "Show active material texture underlay"
	_btn_toggle_tex.toggled.connect(func(on: bool): if canvas: canvas.show_texture = on)
	_toolbar.add_child(_btn_toggle_tex)

	_btn_toggle_tile = Button.new()
	_btn_toggle_tile.name = "ToggleTile"
	_btn_toggle_tile.text = "Tile"
	_btn_toggle_tile.toggle_mode = true
	_btn_toggle_tile.button_pressed = false
	_btn_toggle_tile.tooltip_text = "Repeat texture underlay across UV space"
	_btn_toggle_tile.toggled.connect(func(on: bool): if canvas: canvas.show_texture_tiling = on)
	_toolbar.add_child(_btn_toggle_tile)

	var lbl_op := Label.new()
	lbl_op.text = "Opacity:"
	lbl_op.tooltip_text = "Texture underlay opacity"
	_toolbar.add_child(lbl_op)

	_slider_opacity = HSlider.new()
	_slider_opacity.name = "OpacitySlider"
	_slider_opacity.custom_minimum_size = Vector2(60, 16)
	_slider_opacity.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_slider_opacity.min_value = 0.0
	_slider_opacity.max_value = 1.0
	_slider_opacity.step = 0.05
	_slider_opacity.value = 0.6
	_slider_opacity.tooltip_text = "Texture underlay opacity"
	_slider_opacity.value_changed.connect(func(val: float): if canvas: canvas.texture_opacity = val)
	_toolbar.add_child(_slider_opacity)

	_toolbar.add_child(_make_vsep())

	# --- UV Channel Selector ---
	var lbl_chan := Label.new()
	lbl_chan.text = "Channel:"
	_toolbar.add_child(lbl_chan)

	_opt_channel = OptionButton.new()
	_opt_channel.name = "ChannelSelector"
	_opt_channel.add_item("UV1 (Albedo)", 0)
	_opt_channel.add_item("UV2 (Splat/Mask)", 1)
	_opt_channel.selected = 0
	_opt_channel.tooltip_text = "Select active UV channel"
	_opt_channel.item_selected.connect(_on_channel_selected)
	_toolbar.add_child(_opt_channel)

	# Spacer
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_toolbar.add_child(spacer)

	# --- Status readout ---
	_lbl_status = Label.new()
	_lbl_status.name = "StatusLabel"
	_lbl_status.text = "No selection"
	_lbl_status.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
	_toolbar.add_child(_lbl_status)

	_toolbar.add_child(_make_vsep())

	# --- Pop-out Floating Window Button ---
	_btn_pop_out = Button.new()
	_btn_pop_out.name = "PopOutButton"
	_btn_pop_out.text = "↗ Window"
	_btn_pop_out.tooltip_text = "Pop out UV Editor into a floating window"
	_btn_pop_out.pressed.connect(_toggle_pop_out)
	_toolbar.add_child(_btn_pop_out)

	# 2. Canvas Container
	var canvas_container := PanelContainer.new()
	canvas_container.name = "CanvasContainer"
	canvas_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(canvas_container)

	canvas = PBUvCanvas.new()
	canvas.name = "UvCanvas"
	canvas.selection_changed.connect(_on_canvas_selection_changed)
	canvas.view_changed.connect(_on_canvas_view_changed)
	canvas_container.add_child(canvas)

func _create_mode_btn(label: String, mode: PBUvCanvas.SelectMode, tip: String) -> Button:
	var btn := Button.new()
	btn.name = "Mode" + label
	btn.text = label
	btn.toggle_mode = true
	btn.button_group = _mode_group
	btn.tooltip_text = tip
	btn.pressed.connect(func(): if canvas: canvas.select_mode = mode; _update_status())
	return btn

func _make_vsep() -> VSeparator:
	var sep := VSeparator.new()
	sep.custom_minimum_size = Vector2(0, 18)
	sep.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return sep

# ==============================================================================
# Mesh Binding & Selection Sync
# ==============================================================================

func set_active_mesh(mesh: PBMesh) -> void:
	if active_mesh == mesh:
		return
	active_mesh = mesh
	if canvas:
		canvas.set_active_mesh(mesh)
	_update_status()

## Synchronizes external 3D selection (e.g. from PBEditor / PBSelection) into 2D UV canvas.
func sync_selection_from_3d(selected_face_indices: Array) -> void:
	if canvas == null:
		return
	_syncing_selection = true

	canvas.selected_faces.clear()
	for fi in selected_face_indices:
		canvas.selected_faces[int(fi)] = true

	# Also mirror to vertices and edges if in those modes
	if active_mesh and active_mesh.pb_mesh_data:
		canvas.selected_verts.clear()
		canvas.selected_edges.clear()

		for fi in selected_face_indices:
			var f_idx: int = int(fi)
			if f_idx >= 0 and f_idx < active_mesh.pb_mesh_data.faces.size():
				var face: PBFace = active_mesh.pb_mesh_data.faces[f_idx]
				for v in face.get_distinct_indexes():
					canvas.selected_verts[v] = true
				for edge in face.get_edges():
					canvas.selected_edges[Vector2i(mini(edge.a, edge.b), maxi(edge.a, edge.b))] = true

	canvas.refresh_from_mesh()
	_syncing_selection = false
	_update_status()

func _on_canvas_selection_changed() -> void:
	if _syncing_selection:
		return
	_update_status()
	uv_selection_changed.emit()

	# Synchronize selected faces back to 3D scene if editor is present
	if editor != null and active_mesh != null and editor.selection != null:
		var face_list: Array = canvas.selected_faces.keys()
		if editor.select_mode == PBEditor.SelectMode.FACE:
			var packed := PackedInt32Array()
			for fi in face_list:
				packed.append(int(fi))
			editor.selection.set_faces(packed)
func _update_status() -> void:
	if _lbl_status == null:
		return
	if active_mesh == null:
		_lbl_status.text = "No mesh selected"
		return

	if canvas == null:
		return

	match canvas.select_mode:
		PBUvCanvas.SelectMode.VERTEX:
			var c := canvas.selected_verts.size()
			_lbl_status.text = "%d UV Vertices selected" % c if c > 0 else "0 Vertices selected"
		PBUvCanvas.SelectMode.EDGE:
			var c := canvas.selected_edges.size()
			_lbl_status.text = "%d UV Edges selected" % c if c > 0 else "0 Edges selected"
		PBUvCanvas.SelectMode.FACE, PBUvCanvas.SelectMode.ISLAND:
			var c := canvas.selected_faces.size()
			_lbl_status.text = "%d Faces selected" % c if c > 0 else "0 Faces selected"

# ==============================================================================
# Toolbar Handlers
# ==============================================================================

func _on_snap_toggled(on: bool) -> void:
	if canvas:
		canvas.snap_enabled = on

func _on_snap_step_selected(index: int) -> void:
	if canvas == null:
		return
	match index:
		0: canvas.grid_snap_step = 0.03125 # 1/32
		1: canvas.grid_snap_step = 0.0625  # 1/16
		2: canvas.grid_snap_step = 0.125   # 1/8
		3: canvas.grid_snap_step = 0.25    # 1/4
		4: canvas.grid_snap_step = 0.5     # 1/2
		5: canvas.grid_snap_step = 1.0     # 1.0

func _on_channel_selected(index: int) -> void:
	if canvas == null:
		return
	canvas.uv_channel = PBUvCanvas.UvChannel.UV2 if index == 1 else PBUvCanvas.UvChannel.UV1
	_update_status()

func _on_canvas_view_changed(zoom: float, pan: Vector2) -> void:
	pass

# ==============================================================================
# Pop-out Window Handling
# ==============================================================================

func _toggle_pop_out() -> void:
	set_floating(not _is_floating)

func set_floating(floating: bool) -> void:
	if _is_floating == floating:
		return
	_is_floating = floating

	if _is_floating:
		# Create floating window
		_floating_window = Window.new()
		_floating_window.name = "PoiBuilder_UVEditor_Window"
		_floating_window.title = "PoiBuilder — UV Editor"
		_floating_window.size = Vector2i(750, 550)
		_floating_window.min_size = Vector2i(450, 300)
		_floating_window.wrap_controls = true
		_floating_window.transient = false
		_floating_window.close_requested.connect(func(): set_floating(false))

		# Move this panel inside floating window
		var parent := get_parent()
		if parent:
			parent.remove_child(self)
		_floating_window.add_child(self)

		var base_control := EditorInterface.get_base_control() if Engine.is_editor_hint() else null
		if base_control:
			base_control.add_child(_floating_window)
		else:
			get_tree().root.add_child(_floating_window)

		_floating_window.popup_centered()
		_btn_pop_out.text = "↙ Dock"
		_btn_pop_out.tooltip_text = "Dock UV Editor back into bottom panel"
		pop_out_toggled.emit(true)
	else:
		# Return back to bottom panel
		if _floating_window:
			_floating_window.remove_child(self)
			_floating_window.queue_free()
			_floating_window = null

		_btn_pop_out.text = "↗ Window"
		_btn_pop_out.tooltip_text = "Pop out UV Editor into a floating window"
		pop_out_toggled.emit(false)
