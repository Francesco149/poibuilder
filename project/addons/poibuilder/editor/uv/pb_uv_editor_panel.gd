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


const ICON_DIR := "res://addons/poibuilder/icons/"

static func _load_icon(icon_name: String) -> Texture2D:
	var path := ICON_DIR + icon_name
	if ResourceLoader.exists(path):
		return load(path)
	return null

func _create_icon_btn(name_id: String, icon_name: String, fallback_text: String, tip: String, toggle: bool = false) -> Button:
	var btn := Button.new()
	btn.name = name_id
	var ico := _load_icon(icon_name)
	if ico != null:
		btn.icon = ico
		btn.text = ""
	else:
		btn.text = fallback_text
	btn.toggle_mode = toggle
	btn.tooltip_text = tip
	btn.flat = true
	btn.custom_minimum_size = Vector2(24, 24)
	return btn
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

# Tool buttons
var _btn_tool_move: Button
var _btn_tool_rot: Button
var _btn_tool_scale: Button
var _tool_group: ButtonGroup

# Operations toolbar controls
var _ops_toolbar: HBoxContainer
var _btn_mode_auto: Button
var _btn_mode_manual: Button
var _btn_proj_planar: Button
var _btn_proj_box: Button
var _btn_proj_fit: Button
var _btn_flip_u: Button
var _btn_flip_v: Button
var _btn_rot_ccw: Button
var _btn_rot_cw: Button
var _btn_sew: Button
var _btn_split: Button
var _btn_collapse: Button
var _btn_stitch: Button
var _spin_texel: SpinBox
var _btn_texel_get: Button
var _btn_texel_set: Button
var _btn_export_png: Button

## Optional UndoRedoManager reference for headless tests
var undo_redo: Object = null

# Floating window instance
var _floating_window: Window = null
var _is_floating: bool = false

# Mesh & Editor references
var active_mesh: PBMesh = null:
	set = set_active_mesh
var editor: PBEditor = null
var plugin: Object = null
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
	if Engine.is_editor_hint():
		var ur := EditorInterface.get_editor_undo_redo()
		if ur and not ur.version_changed.is_connected(_on_undo_redo_version_changed):
			ur.version_changed.connect(_on_undo_redo_version_changed)

func _on_undo_redo_version_changed() -> void:
	if canvas:
		canvas.refresh_from_mesh()
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

	# --- Tool Buttons (Move / Rotate / Scale) ---
	_tool_group = ButtonGroup.new()
	_btn_tool_move = _create_tool_btn("Move", "icon_move.svg", PBUvGizmo.ToolMode.MOVE, "Move tool (W)")
	_btn_tool_move.button_pressed = true
	_btn_tool_rot = _create_tool_btn("Rotate", "icon_rotate.svg", PBUvGizmo.ToolMode.ROTATE, "Rotate tool (E)")
	_btn_tool_scale = _create_tool_btn("Scale", "icon_scale.svg", PBUvGizmo.ToolMode.SCALE, "Scale tool (R)")

	_toolbar.add_child(_btn_tool_move)
	_toolbar.add_child(_btn_tool_rot)
	_toolbar.add_child(_btn_tool_scale)

	_toolbar.add_child(_make_vsep())

	# --- Mode Buttons ---
	_mode_group = ButtonGroup.new()

	_btn_mode_face = _create_mode_btn("Face", "icon_face.svg", PBUvCanvas.SelectMode.FACE, "Face selection mode")
	_btn_mode_face.button_pressed = true
	_btn_mode_vert = _create_mode_btn("Vertex", "icon_vertex.svg", PBUvCanvas.SelectMode.VERTEX, "UV Vertex selection mode")
	_btn_mode_edge = _create_mode_btn("Edge", "icon_edge.svg", PBUvCanvas.SelectMode.EDGE, "UV Edge selection mode")
	_btn_mode_island = _create_mode_btn("Island", "icon_island.svg", PBUvCanvas.SelectMode.ISLAND, "UV Island (connected shell) selection mode")

	_toolbar.add_child(_btn_mode_face)
	_toolbar.add_child(_btn_mode_vert)
	_toolbar.add_child(_btn_mode_edge)
	_toolbar.add_child(_btn_mode_island)

	_toolbar.add_child(_make_vsep())

	# --- Framing ---
	_btn_frame_unit = _create_icon_btn("FrameUnit", "icon_uv_frame_unit.svg", "[0,1]", "Frame [0, 1] unit square")
	_btn_frame_unit.pressed.connect(func(): if canvas: canvas.frame_unit_square())
	_toolbar.add_child(_btn_frame_unit)

	_btn_frame_sel = _create_icon_btn("FrameSel", "icon_uv_frame_sel.svg", "⛶ Frame", "Frame Selection (F)")
	_btn_frame_sel.pressed.connect(func(): if canvas: canvas.frame_selection())
	_toolbar.add_child(_btn_frame_sel)

	_toolbar.add_child(_make_vsep())

	# --- Snapping ---
	_btn_snap_toggle = _create_icon_btn("SnapToggle", "icon_uv_snap.svg", "Snap", "Toggle UV snapping to grid", true)
	_btn_snap_toggle.button_pressed = true
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
	_btn_toggle_tex = _create_icon_btn("ToggleTex", "icon_uv_texture.svg", "Texture", "Show active material texture underlay", true)
	_btn_toggle_tex.button_pressed = true
	_btn_toggle_tex.toggled.connect(func(on: bool): if canvas: canvas.show_texture = on)
	_toolbar.add_child(_btn_toggle_tex)

	_btn_toggle_tile = _create_icon_btn("ToggleTile", "icon_uv_tile.svg", "Tile", "Repeat texture underlay across UV space", true)
	_btn_toggle_tile.button_pressed = false
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
	_btn_pop_out = _create_icon_btn("PopOutButton", "icon_uv_pop_out.svg", "↗ Window", "Pop out UV Editor into a floating window")
	_btn_pop_out.pressed.connect(_toggle_pop_out)
	_toolbar.add_child(_btn_pop_out)

	# 2. Operations Toolbar Row
	_ops_toolbar = HBoxContainer.new()
	_ops_toolbar.name = "OpsToolbar"
	_ops_toolbar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ops_toolbar.add_theme_constant_override("separation", 5)
	add_child(_ops_toolbar)

	# Mode Conversion
	var lbl_mode := Label.new()
	lbl_mode.text = "Mode:"
	_ops_toolbar.add_child(lbl_mode)

	_btn_mode_auto = _create_icon_btn("BtnModeAuto", "icon_uv_auto.svg", "Auto", "Convert selected faces to Auto UV")
	_btn_mode_auto.pressed.connect(func(): _execute_uv_op("Convert to Auto UV", func() -> bool: return PBUvOps.convert_to_auto(active_mesh.pb_mesh_data, _get_target_faces())))
	_ops_toolbar.add_child(_btn_mode_auto)

	_btn_mode_manual = _create_icon_btn("BtnModeManual", "icon_uv_manual.svg", "Manual", "Convert selected faces to Manual UV (freeze coordinates)")
	_btn_mode_manual.pressed.connect(func(): _execute_uv_op("Convert to Manual UV", func() -> bool: return PBUvOps.convert_to_manual(active_mesh.pb_mesh_data, _get_target_faces())))
	_ops_toolbar.add_child(_btn_mode_manual)

	_ops_toolbar.add_child(_make_vsep())

	# Projections
	var lbl_proj := Label.new()
	lbl_proj.text = "Project:"
	_ops_toolbar.add_child(lbl_proj)

	_btn_proj_planar = _create_icon_btn("BtnProjPlanar", "icon_uv_planar.svg", "Planar", "Planar project selected faces along average normal")
	_btn_proj_planar.pressed.connect(func(): _execute_uv_op("Planar Project UVs", func() -> bool: return PBUvOps.planar_project(active_mesh.pb_mesh_data, _get_target_faces(), canvas.uv_channel if canvas else 0)))
	_ops_toolbar.add_child(_btn_proj_planar)

	_btn_proj_box = _create_icon_btn("BtnProjBox", "icon_uv_box.svg", "Box", "Box project selected faces along dominant cardinal normal")
	_btn_proj_box.pressed.connect(func(): _execute_uv_op("Box Project UVs", func() -> bool: return PBUvOps.box_project(active_mesh.pb_mesh_data, _get_target_faces(), canvas.uv_channel if canvas else 0)))
	_ops_toolbar.add_child(_btn_proj_box)

	_btn_proj_fit = _create_icon_btn("BtnProjFit", "icon_uv_fit.svg", "Fit", "Fit selected UVs into [0, 1] bounds")
	_btn_proj_fit.pressed.connect(func(): _execute_uv_op("Fit UVs", func() -> bool: return PBUvOps.fit_uvs(active_mesh.pb_mesh_data, _get_target_faces(), canvas.uv_channel if canvas else 0)))
	_ops_toolbar.add_child(_btn_proj_fit)

	_ops_toolbar.add_child(_make_vsep())

	# Transforms
	var lbl_xform := Label.new()
	lbl_xform.text = "Transform:"
	_ops_toolbar.add_child(lbl_xform)

	_btn_flip_u = _create_icon_btn("BtnFlipU", "icon_uv_flip_h.svg", "Flip U", "Flip UVs horizontally")
	_btn_flip_u.pressed.connect(func(): _execute_uv_op("Flip UVs Horizontal", func() -> bool: return PBUvOps.flip_uvs(active_mesh.pb_mesh_data, _get_target_faces(), true, canvas.uv_channel if canvas else 0)))
	_ops_toolbar.add_child(_btn_flip_u)

	_btn_flip_v = _create_icon_btn("BtnFlipV", "icon_uv_flip_v.svg", "Flip V", "Flip UVs vertically")
	_btn_flip_v.pressed.connect(func(): _execute_uv_op("Flip UVs Vertical", func() -> bool: return PBUvOps.flip_uvs(active_mesh.pb_mesh_data, _get_target_faces(), false, canvas.uv_channel if canvas else 0)))
	_ops_toolbar.add_child(_btn_flip_v)

	_btn_rot_ccw = _create_icon_btn("BtnRotCCW", "icon_uv_rot_ccw.svg", "↶ 90°", "Rotate UVs 90 degrees CCW")
	_btn_rot_ccw.pressed.connect(func(): _execute_uv_op("Rotate UVs 90° CCW", func() -> bool: return PBUvOps.rotate_90(active_mesh.pb_mesh_data, _get_target_faces(), false, canvas.uv_channel if canvas else 0)))
	_ops_toolbar.add_child(_btn_rot_ccw)

	_btn_rot_cw = _create_icon_btn("BtnRotCW", "icon_uv_rot_cw.svg", "↷ 90°", "Rotate UVs 90 degrees CW")
	_btn_rot_cw.pressed.connect(func(): _execute_uv_op("Rotate UVs 90° CW", func() -> bool: return PBUvOps.rotate_90(active_mesh.pb_mesh_data, _get_target_faces(), true, canvas.uv_channel if canvas else 0)))
	_ops_toolbar.add_child(_btn_rot_cw)

	_ops_toolbar.add_child(_make_vsep())

	# Seams & Topology
	var lbl_seams := Label.new()
	lbl_seams.text = "Seams:"
	_ops_toolbar.add_child(lbl_seams)

	_btn_sew = _create_icon_btn("BtnSew", "icon_uv_sew.svg", "Sew", "Sew proximate 3D coincident UV vertices")
	_btn_sew.pressed.connect(func(): _execute_uv_op("Sew UVs", func() -> bool: return PBUvOps.sew_uvs(active_mesh.pb_mesh_data, _get_target_vertices(), 0.05, canvas.uv_channel if canvas else 0) > 0))
	_ops_toolbar.add_child(_btn_sew)

	_btn_split = _create_icon_btn("BtnSplit", "icon_uv_split.svg", "Split", "Split coincident UV vertices")
	_btn_split.pressed.connect(func(): _execute_uv_op("Split UVs", func() -> bool: return PBUvOps.split_uvs(active_mesh.pb_mesh_data, _get_target_vertices(), Vector2(0.05, 0.05), canvas.uv_channel if canvas else 0) > 0))
	_ops_toolbar.add_child(_btn_split)

	_btn_collapse = _create_icon_btn("BtnCollapse", "icon_uv_collapse.svg", "Collapse", "Collapse selected UV vertices to centroid")
	_btn_collapse.pressed.connect(func(): _execute_uv_op("Collapse UVs", func() -> bool: return PBUvOps.collapse_uvs(active_mesh.pb_mesh_data, _get_target_vertices(), canvas.uv_channel if canvas else 0)))
	_ops_toolbar.add_child(_btn_collapse)

	_btn_stitch = _create_icon_btn("BtnStitch", "icon_uv_stitch.svg", "Stitch", "Auto-stitch matching edge of 2 selected adjacent faces")
	_btn_stitch.pressed.connect(_on_stitch_pressed)
	_ops_toolbar.add_child(_btn_stitch)

	_ops_toolbar.add_child(_make_vsep())

	# Texel Density
	var lbl_texel := Label.new()
	lbl_texel.text = "Texel:"
	_ops_toolbar.add_child(lbl_texel)

	_btn_texel_get = _create_icon_btn("BtnTexelGet", "icon_uv_texel_get.svg", "Get", "Sample texel density from selected face")
	_btn_texel_get.pressed.connect(_on_texel_get_pressed)
	_ops_toolbar.add_child(_btn_texel_get)

	_spin_texel = SpinBox.new()
	_spin_texel.name = "SpinTexel"
	_spin_texel.min_value = 16.0
	_spin_texel.max_value = 4096.0
	_spin_texel.step = 1.0
	_spin_texel.value = 256.0
	_spin_texel.suffix = "px/m"
	_spin_texel.custom_minimum_size = Vector2(90, 20)
	_spin_texel.tooltip_text = "Target texel density in pixels per meter"
	_ops_toolbar.add_child(_spin_texel)

	_btn_texel_set = _create_icon_btn("BtnTexelSet", "icon_uv_texel_set.svg", "Set", "Apply target texel density to selected faces")
	_btn_texel_set.pressed.connect(_on_texel_set_pressed)
	_ops_toolbar.add_child(_btn_texel_set)

	_ops_toolbar.add_child(_make_vsep())

	# Export
	_btn_export_png = _create_icon_btn("BtnExportPng", "icon_uv_export.svg", "Export PNG", "Export UV template as a PNG image")
	_btn_export_png.pressed.connect(_on_export_png_pressed)
	_ops_toolbar.add_child(_btn_export_png)

	# 3. Canvas Container


	var canvas_container := PanelContainer.new()
	canvas_container.name = "CanvasContainer"
	canvas_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(canvas_container)

	canvas = PBUvCanvas.new()
	canvas.name = "UvCanvas"
	canvas.selection_changed.connect(_on_canvas_selection_changed)
	canvas.view_changed.connect(_on_canvas_view_changed)
	canvas.tool_changed.connect(_on_canvas_tool_changed)
	canvas.select_mode_changed.connect(_on_canvas_select_mode_changed)
	canvas_container.add_child(canvas)

func _create_mode_btn(label: String, icon_name: String, mode: PBUvCanvas.SelectMode, tip: String) -> Button:
	var btn := Button.new()
	btn.name = "Mode" + label
	var ico := _load_icon(icon_name)
	if ico != null:
		btn.icon = ico
		btn.text = ""
	else:
		btn.text = label
	btn.toggle_mode = true
	btn.button_group = _mode_group
	btn.tooltip_text = tip
	btn.flat = true
	btn.custom_minimum_size = Vector2(24, 24)
	btn.pressed.connect(func(): if canvas: canvas.select_mode = mode; _update_status())
	return btn

func _create_tool_btn(label: String, icon_name: String, mode: PBUvGizmo.ToolMode, tip: String) -> Button:
	var btn := Button.new()
	btn.name = "Tool" + label
	var ico := _load_icon(icon_name)
	if ico != null:
		btn.icon = ico
		btn.text = ""
	else:
		btn.text = label
	btn.toggle_mode = true
	btn.button_group = _tool_group
	btn.tooltip_text = tip
	btn.flat = true
	btn.custom_minimum_size = Vector2(24, 24)
	btn.pressed.connect(func(): if canvas: canvas.transform_tool = mode)
	return btn

func _on_canvas_tool_changed(mode: PBUvGizmo.ToolMode) -> void:
	match mode:
		PBUvGizmo.ToolMode.MOVE:
			if _btn_tool_move: _btn_tool_move.button_pressed = true
		PBUvGizmo.ToolMode.ROTATE:
			if _btn_tool_rot: _btn_tool_rot.button_pressed = true
		PBUvGizmo.ToolMode.SCALE:
			if _btn_tool_scale: _btn_tool_scale.button_pressed = true

func _on_canvas_select_mode_changed(mode: PBUvCanvas.SelectMode) -> void:
	match mode:
		PBUvCanvas.SelectMode.VERTEX:
			if _btn_mode_vert: _btn_mode_vert.button_pressed = true
		PBUvCanvas.SelectMode.EDGE:
			if _btn_mode_edge: _btn_mode_edge.button_pressed = true
		PBUvCanvas.SelectMode.FACE:
			if _btn_mode_face: _btn_mode_face.button_pressed = true
		PBUvCanvas.SelectMode.ISLAND:
			if _btn_mode_island: _btn_mode_island.button_pressed = true
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

func sync_selection_from_3d_state(select_mode: int, selection: PBSelection) -> void:
	if canvas == null or active_mesh == null or active_mesh.pb_mesh_data == null or selection == null:
		return
	if _syncing_selection:
		return
	_syncing_selection = true

	var mesh_data := active_mesh.pb_mesh_data

	match select_mode:
		PBEditor.SelectMode.VERTEX:
			canvas.selected_faces.clear()
			canvas.selected_edges.clear()
			canvas.selected_verts.clear()
			canvas.select_mode = PBUvCanvas.SelectMode.VERTEX
			if _btn_mode_vert:
				_btn_mode_vert.button_pressed = true
			for sv_idx in selection.selected_vertices:
				if sv_idx >= 0 and sv_idx < mesh_data.shared_vertices.size():
					var sv: PBSharedVertex = mesh_data.shared_vertices[sv_idx]
					if sv != null:
						for vi in sv.indices:
							canvas.selected_verts[vi] = true

		PBEditor.SelectMode.EDGE:
			canvas.selected_faces.clear()
			canvas.selected_verts.clear()
			canvas.selected_edges.clear()
			canvas.select_mode = PBUvCanvas.SelectMode.EDGE
			if _btn_mode_edge:
				_btn_mode_edge.button_pressed = true
			for edge in selection.selected_edges:
				if edge != null:
					canvas.selected_edges[Vector2i(mini(edge.a, edge.b), maxi(edge.a, edge.b))] = true

		PBEditor.SelectMode.FACE:
			canvas.selected_verts.clear()
			canvas.selected_edges.clear()
			canvas.selected_faces.clear()
			if canvas.select_mode == PBUvCanvas.SelectMode.ISLAND:
				if _btn_mode_island:
					_btn_mode_island.button_pressed = true
				for fi in selection.selected_faces:
					for ifi in canvas._get_uv_island(int(fi)):
						canvas.selected_faces[ifi] = true
			else:
				canvas.select_mode = PBUvCanvas.SelectMode.FACE
				if _btn_mode_face:
					_btn_mode_face.button_pressed = true
				for fi in selection.selected_faces:
					canvas.selected_faces[int(fi)] = true
	canvas.refresh_from_mesh()
	_syncing_selection = false
	_update_status()

func sync_selection_from_3d(selected_face_indices: Array) -> void:
	if canvas == null or active_mesh == null or active_mesh.pb_mesh_data == null:
		return
	if _syncing_selection:
		return
	_syncing_selection = true

	canvas.selected_verts.clear()
	canvas.selected_edges.clear()
	canvas.selected_faces.clear()

	for fi in selected_face_indices:
		canvas.selected_faces[int(fi)] = true

	canvas.refresh_from_mesh()
	_syncing_selection = false
	_update_status()

func _on_canvas_selection_changed() -> void:
	if _syncing_selection:
		return
	_update_status()
	uv_selection_changed.emit()

	if editor == null or active_mesh == null or active_mesh.pb_mesh_data == null or editor.selection == null:
		return

	var mesh_data := active_mesh.pb_mesh_data
	_syncing_selection = true

	match canvas.select_mode:
		PBUvCanvas.SelectMode.VERTEX:
			var sv_set: Dictionary = {}
			for vi in canvas.selected_verts:
				var sv: int = mesh_data.get_shared_vertex_index(vi)
				if sv >= 0:
					sv_set[sv] = true
			var sv_packed := PackedInt32Array()
			for sv in sv_set:
				sv_packed.append(sv)

			if editor.select_mode != PBEditor.SelectMode.VERTEX and not sv_packed.is_empty():
				editor.select_mode = PBEditor.SelectMode.VERTEX

			editor.selection.set_vertices(sv_packed)
			if plugin != null and plugin.has_method("select_subgizmo_element"):
				if not sv_packed.is_empty():
					plugin.select_subgizmo_element(active_mesh, sv_packed[0])
				else:
					plugin.select_subgizmo_element(active_mesh, -1)

		PBUvCanvas.SelectMode.EDGE:
			var edges_to_sel: Array[PBEdge] = []
			for pair: Vector2i in canvas.selected_edges:
				edges_to_sel.append(PBEdge.new(pair.x, pair.y))

			if editor.select_mode != PBEditor.SelectMode.EDGE and not edges_to_sel.is_empty():
				editor.select_mode = PBEditor.SelectMode.EDGE

			editor.selection.set_edges(edges_to_sel)
			if plugin != null and plugin.has_method("select_subgizmo_element"):
				if not edges_to_sel.is_empty():
					var common_edges := mesh_data.get_common_edges()
					var common := mesh_data.get_common_edge(edges_to_sel[0])
					var found_id := -1
					if common != null:
						for eid in range(common_edges.size()):
							if common_edges[eid].equals(common):
								found_id = eid
								break
					plugin.select_subgizmo_element(active_mesh, found_id)
				else:
					plugin.select_subgizmo_element(active_mesh, -1)

		PBUvCanvas.SelectMode.FACE, PBUvCanvas.SelectMode.ISLAND:
			var face_list: Array = canvas.selected_faces.keys()
			var packed := PackedInt32Array()
			for fi in face_list:
				packed.append(int(fi))

			if editor.select_mode != PBEditor.SelectMode.FACE and not packed.is_empty():
				editor.select_mode = PBEditor.SelectMode.FACE

			editor.selection.set_faces(packed)
			if plugin != null and plugin.has_method("select_subgizmo_element"):
				if not packed.is_empty():
					plugin.select_subgizmo_element(active_mesh, packed[0])
				else:
					plugin.select_subgizmo_element(active_mesh, -1)

	_syncing_selection = false

func _update_status() -> void:
	if _lbl_status == null:
		return
	if active_mesh == null or active_mesh.pb_mesh_data == null:
		_lbl_status.text = "No mesh selected"
		return

	if canvas == null:
		return

	var mode_str := PBUvOps.get_uv_mode(active_mesh.pb_mesh_data, canvas.selected_faces.keys())

	var sel_text := ""
	match canvas.select_mode:
		PBUvCanvas.SelectMode.VERTEX:
			var c := canvas.selected_verts.size()
			sel_text = "%d Vertices" % c if c > 0 else "0 Vertices"
		PBUvCanvas.SelectMode.EDGE:
			var c := canvas.selected_edges.size()
			sel_text = "%d Edges" % c if c > 0 else "0 Edges"
		PBUvCanvas.SelectMode.FACE, PBUvCanvas.SelectMode.ISLAND:
			var c := canvas.selected_faces.size()
			sel_text = "%d Faces" % c if c > 0 else "0 Faces"

	_lbl_status.text = "Mode: %s | %s selected" % [mode_str, sel_text]

func _get_undo_redo() -> Object:
	if undo_redo != null:
		return undo_redo
	if Engine.is_editor_hint():
		return EditorInterface.get_editor_undo_redo()
	return null

func _get_target_faces() -> Array:
	if canvas == null or active_mesh == null or active_mesh.pb_mesh_data == null:
		return []
	if not canvas.selected_faces.is_empty():
		return canvas.selected_faces.keys()
	if not canvas.selected_verts.is_empty() or not canvas.selected_edges.is_empty():
		var sel_verts := canvas.get_selected_vertex_indices()
		var v_set: Dictionary = {}
		for v in sel_verts:
			v_set[v] = true
		var faces: Array = []
		for fi in range(active_mesh.pb_mesh_data.faces.size()):
			var f: PBFace = active_mesh.pb_mesh_data.faces[fi]
			for idx in f.get_distinct_indexes():
				if v_set.has(idx):
					faces.append(fi)
					break
		return faces
	# Default to all faces if nothing selected
	var all_faces: Array = []
	for fi in range(active_mesh.pb_mesh_data.faces.size()):
		all_faces.append(fi)
	return all_faces

func _get_target_vertices() -> Array:
	if canvas == null or active_mesh == null or active_mesh.pb_mesh_data == null:
		return []
	var sel_verts := canvas.get_selected_vertex_indices()
	if not sel_verts.is_empty():
		return sel_verts
	var all_verts: Array = []
	for vi in range(active_mesh.pb_mesh_data.positions.size()):
		all_verts.append(vi)
	return all_verts

func _execute_uv_op(action_name: String, op_callable: Callable) -> void:
	if active_mesh == null or active_mesh.pb_mesh_data == null:
		return

	var cmd := CmdMeshOp.new(active_mesh.pb_mesh_data, action_name, active_mesh)
	var res = op_callable.call()
	if res != false:
		cmd.capture_after()
		var ur := _get_undo_redo()
		if ur != null:
			cmd.add_to_undo_manager(ur)
		else:
			active_mesh.rebuild()
		if canvas:
			canvas.refresh_from_mesh()
		_update_status()
		uv_selection_changed.emit()

func _on_stitch_pressed() -> void:
	if active_mesh == null or active_mesh.pb_mesh_data == null or canvas == null:
		return
	var faces := _get_target_faces()
	if faces.size() < 2:
		return
	var f0: int = int(faces[0])
	var f1: int = int(faces[1])
	_execute_uv_op("Auto-Stitch UVs", func() -> bool:
		return PBUvOps.auto_stitch(active_mesh.pb_mesh_data, f0, f1, canvas.uv_channel if canvas else 0)
	)

func _on_texel_get_pressed() -> void:
	if active_mesh == null or active_mesh.pb_mesh_data == null or canvas == null or _spin_texel == null:
		return
	var target_faces := _get_target_faces()
	if target_faces.is_empty():
		return
	var f_idx: int = int(target_faces[0])
	if f_idx >= 0 and f_idx < active_mesh.pb_mesh_data.faces.size():
		var face: PBFace = active_mesh.pb_mesh_data.faces[f_idx]
		var d := PBUvOps.sample_texel_density(active_mesh.pb_mesh_data, face, Vector2(512, 512), canvas.uv_channel)
		if d > 0.0:
			_spin_texel.value = roundf(d)

func _on_texel_set_pressed() -> void:
	if _spin_texel == null:
		return
	_execute_uv_op("Normalize Texel Density", func() -> bool:
		return PBUvOps.normalize_texel_density(
			active_mesh.pb_mesh_data,
			_get_target_faces(),
			_spin_texel.value,
			Vector2(512, 512),
			canvas.uv_channel if canvas else 0
		) > 0
	)

func _on_export_png_pressed() -> void:
	if active_mesh == null or active_mesh.pb_mesh_data == null:
		return
	var dir := "res://exports"
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir + "/uv_template.png"
	var err := PBUvOps.export_uv_template(
		active_mesh.pb_mesh_data,
		path,
		1024,
		Color.WHITE,
		Color.BLACK,
		false,
		false,
		[],
		canvas.uv_channel if canvas else 0
	)
	if err == OK:
		print("[PB/uv] Exported UV template to %s" % path)
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
