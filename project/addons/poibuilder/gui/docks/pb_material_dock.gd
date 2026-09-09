## PBMaterialDock — Material picker, UV mapping, texture splatting & stamping dock for PoiBuilder.
##
## Docks to the right of the 3D viewport (DOCK_SLOT_RIGHT_UL), to the left of the Inspector.
## Toggleable from the PoiBuilder toolbar.
##
## Modes:
## - Material & UV:
##   - Material Picker: Click a material card -> applies to selected face(s) (or whole mesh in Object mode).
##   - UV Tiling & Mapping: x2, /2, Reset (1m), 45° Diagonal, manual tiling, offset, angle, flips.
##   - Face Tint: ColorPickerButton setting vertex color tint.
## - Texture Paint (Splatting):
##   - Select any texture/material from the palette to paint with.
##   - Adjustable Brush Radius, Softness, Opacity, Erase mode.
##   - Layer management (up to 8 blend layers over face's base texture).
## - Stamp:
##   - Select any texture/image to stamp on mesh.
##   - Live preview on geometry, click to paste, mouse wheel to rotate, Ctrl+wheel to scale.
@tool
class_name PBMaterialDock
extends PanelContainer

enum DockMode { MATERIAL, PAINT, STAMP }

const DEFAULT_MATERIAL_PATH := "res://addons/poibuilder/materials/pb_default_material.tres"
const SETTING_DEFAULT_MATERIAL := "poibuilder/materials/default_material_path"

## Reference to the main PoiBuilder plugin.
var plugin: EditorPlugin = null
var editor: PBEditor = null:
	set = set_editor

var paint_controller: PBPaintController = null:
	set = set_paint_controller

var dock_mode: DockMode = DockMode.MATERIAL

var _selected_material: Material = null
var _default_material_path: String = DEFAULT_MATERIAL_PATH
var _project_materials: Array[Material] = []

# UI Nodes - Mode Row
var _btn_mode_mat: Button
var _btn_mode_paint: Button
var _btn_mode_stamp: Button

# UI Nodes - Materials Section
var _scroll: ScrollContainer
var _material_grid: HFlowContainer
var _status_label: Label
var _file_dialog: EditorFileDialog

# UI Nodes - Sections Container
var _uv_and_tint_section: VBoxContainer
var _paint_tool_section: VBoxContainer
var _stamp_tool_section: VBoxContainer

# UV Controls
var _btn_x2: Button
var _btn_half: Button
var _btn_reset_uv: Button
var _btn_diagonal: Button
var _spin_tiling_u: Range
var _spin_tiling_v: Range
var _spin_offset_u: Range
var _spin_offset_v: Range
var _spin_angle: Range
var _chk_flip_u: CheckBox
var _chk_flip_v: CheckBox

# Tint Controls
var _color_picker: ColorPickerButton
var _btn_reset_tint: Button

# Paint Tool Controls
var _active_paint_label: Label
var _spin_brush_radius: Range
var _spin_brush_softness: Range
var _spin_brush_opacity: Range
var _chk_erase: CheckBox
var _spin_paint_layer: Range
var _btn_clear_layer: Button

# Stamp Tool Controls
var _active_stamp_label: Label
var _btn_stamp_place: Button
var _btn_stamp_delete: Button
var _stamp_hint: Label
var _spin_stamp_scale: Range
var _spin_stamp_rotation: Range
var _spin_stamp_opacity: Range
# Context Menu
var _context_menu: PopupMenu
var _context_material: Material = null

# Flag to prevent recursive updates while syncing from selection
var _syncing: bool = false

# ==============================================================================
# Lifecycle
# ==============================================================================

func _init() -> void:
	name = "Material & UV"
	custom_minimum_size = Vector2(250, 320)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_load_default_material_setting()

func _ready() -> void:
	_build_ui()
	refresh_materials()
	sync_selection()

func set_editor(val: PBEditor) -> void:
	if editor == val:
		return
	if editor != null and editor.selection != null:
		if editor.selection.selection_changed.is_connected(sync_selection):
			editor.selection.selection_changed.disconnect(sync_selection)
	editor = val
	if editor != null and editor.selection != null:
		if not editor.selection.selection_changed.is_connected(sync_selection):
			editor.selection.selection_changed.connect(sync_selection)
	sync_selection()

func set_paint_controller(val: PBPaintController) -> void:
	if paint_controller == val:
		return
	if paint_controller != null:
		if paint_controller.brush_changed.is_connected(_on_paint_controller_changed):
			paint_controller.brush_changed.disconnect(_on_paint_controller_changed)
		if paint_controller.stamp_changed.is_connected(_on_paint_controller_changed):
			paint_controller.stamp_changed.disconnect(_on_paint_controller_changed)
	paint_controller = val
	if paint_controller != null:
		if not paint_controller.brush_changed.is_connected(_on_paint_controller_changed):
			paint_controller.brush_changed.connect(_on_paint_controller_changed)
		if not paint_controller.stamp_changed.is_connected(_on_paint_controller_changed):
			paint_controller.stamp_changed.connect(_on_paint_controller_changed)
	sync_selection()

func _on_paint_controller_changed() -> void:
	if _syncing or paint_controller == null:
		return
	_syncing = true
	if _spin_brush_radius != null:
		_spin_brush_radius.value = paint_controller.brush_radius
	if _spin_brush_softness != null:
		_spin_brush_softness.value = paint_controller.brush_softness
	if _spin_brush_opacity != null:
		_spin_brush_opacity.value = paint_controller.brush_opacity
	if _chk_erase != null:
		_chk_erase.button_pressed = paint_controller.erase_mode
	if _spin_paint_layer != null:
		_spin_paint_layer.value = paint_controller.active_layer_idx
	if _spin_stamp_scale != null:
		_spin_stamp_scale.value = paint_controller.stamp_scale
	if _spin_stamp_rotation != null:
		_spin_stamp_rotation.value = paint_controller.stamp_rotation
	if _spin_stamp_opacity != null:
		_spin_stamp_opacity.value = paint_controller.stamp_opacity
	_update_tool_labels()
	_syncing = false

# ==============================================================================
# Settings
# ==============================================================================

func _load_default_material_setting() -> void:
	var settings = EditorInterface.get_editor_settings() if Engine.is_editor_hint() else null
	if settings != null and settings.has_setting(SETTING_DEFAULT_MATERIAL):
		_default_material_path = String(settings.get_setting(SETTING_DEFAULT_MATERIAL))
	else:
		_default_material_path = DEFAULT_MATERIAL_PATH

func _save_default_material_setting(path: String) -> void:
	_default_material_path = path
	var settings = EditorInterface.get_editor_settings() if Engine.is_editor_hint() else null
	if settings != null:
		settings.set_setting(SETTING_DEFAULT_MATERIAL, path)

func get_default_material() -> Material:
	if ResourceLoader.exists(_default_material_path):
		return ResourceLoader.load(_default_material_path) as Material
	if ResourceLoader.exists(DEFAULT_MATERIAL_PATH):
		return ResourceLoader.load(DEFAULT_MATERIAL_PATH) as Material
	return null

# ==============================================================================
# UI Construction
# ==============================================================================

func _build_ui() -> void:
	for c in get_children():
		c.queue_free()

	var root_vbox := VBoxContainer.new()
	root_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(root_vbox)

	# 1. Mode Selector Segmented Row
	var mode_row := HBoxContainer.new()
	mode_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_btn_mode_mat = Button.new()
	_btn_mode_mat.text = "Material & UV"
	_btn_mode_mat.tooltip_text = "Standard material assignment and UV mapping"
	_btn_mode_mat.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_mode_mat.toggle_mode = true
	_btn_mode_mat.button_pressed = (dock_mode == DockMode.MATERIAL)
	_btn_mode_mat.pressed.connect(func(): _set_dock_mode(DockMode.MATERIAL))
	mode_row.add_child(_btn_mode_mat)

	_btn_mode_paint = Button.new()
	_btn_mode_paint.text = "Texture Paint"
	_btn_mode_paint.tooltip_text = "Paint with brush and alpha masks over splat layers"
	_btn_mode_paint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_mode_paint.toggle_mode = true
	_btn_mode_paint.button_pressed = (dock_mode == DockMode.PAINT)
	_btn_mode_paint.pressed.connect(func(): _set_dock_mode(DockMode.PAINT))
	mode_row.add_child(_btn_mode_paint)

	_btn_mode_stamp = Button.new()
	_btn_mode_stamp.text = "Stamp"
	_btn_mode_stamp.tooltip_text = "Paste textures/images anywhere on geometry with live preview, wheel rotate, and ctrl+wheel scale"
	_btn_mode_stamp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_mode_stamp.toggle_mode = true
	_btn_mode_stamp.button_pressed = (dock_mode == DockMode.STAMP)
	_btn_mode_stamp.pressed.connect(func(): _set_dock_mode(DockMode.STAMP))
	mode_row.add_child(_btn_mode_stamp)

	root_vbox.add_child(mode_row)
	root_vbox.add_child(HSeparator.new())

	# 2. Materials & Textures Palette Section Header + Actions
	var mat_header := HBoxContainer.new()
	var mat_title := Label.new()
	mat_title.text = "Palette"
	mat_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mat_header.add_child(mat_title)

	var btn_add := Button.new()
	btn_add.text = "+ Add"
	btn_add.tooltip_text = "Add material or texture from project..."
	btn_add.pressed.connect(_on_add_material_pressed)
	mat_header.add_child(btn_add)

	var btn_refresh := Button.new()
	btn_refresh.text = "↺"
	btn_refresh.tooltip_text = "Scan project for materials and textures"
	btn_refresh.pressed.connect(refresh_materials)
	mat_header.add_child(btn_refresh)
	root_vbox.add_child(mat_header)

	# Material Cards Container
	var mat_scroll := ScrollContainer.new()
	mat_scroll.custom_minimum_size = Vector2(0, 130)
	mat_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mat_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root_vbox.add_child(mat_scroll)

	_material_grid = HFlowContainer.new()
	_material_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mat_scroll.add_child(_material_grid)

	root_vbox.add_child(HSeparator.new())

	# =========================================================================
	# Section A: Material & UV Controls (Visible in MATERIAL mode)
	# =========================================================================
	_uv_and_tint_section = VBoxContainer.new()
	_uv_and_tint_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_vbox.add_child(_uv_and_tint_section)

	var uv_title := Label.new()
	uv_title.text = "Face UV Tiling"
	_uv_and_tint_section.add_child(uv_title)

	# Quick Scale Row
	var quick_row := HBoxContainer.new()
	_btn_x2 = Button.new()
	_btn_x2.text = "x2"
	_btn_x2.tooltip_text = "Double tiling frequency (x2)"
	_btn_x2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_x2.pressed.connect(func(): _scale_tiling(2.0))
	quick_row.add_child(_btn_x2)

	_btn_half = Button.new()
	_btn_half.text = "/2"
	_btn_half.tooltip_text = "Half tiling frequency (/2)"
	_btn_half.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_half.pressed.connect(func(): _scale_tiling(0.5))
	quick_row.add_child(_btn_half)

	_btn_reset_uv = Button.new()
	_btn_reset_uv.text = "Reset (1m)"
	_btn_reset_uv.tooltip_text = "Reset tiling to default 1x1 meter pattern"
	_btn_reset_uv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_reset_uv.pressed.connect(_on_reset_uv_pressed)
	quick_row.add_child(_btn_reset_uv)
	_uv_and_tint_section.add_child(quick_row)

	# 45° Diagonal Button
	_btn_diagonal = Button.new()
	_btn_diagonal.text = "45° Diagonal Tiling (√2m)"
	_btn_diagonal.tooltip_text = "Scale texture to grid diagonal (1.414m) at 45° angle, cleanly aligned for triangulated quads"
	_btn_diagonal.pressed.connect(_on_diagonal_pressed)
	_uv_and_tint_section.add_child(_btn_diagonal)

	# Grid of Manual UV Controls
	var uv_grid := GridContainer.new()
	uv_grid.columns = 2
	uv_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	uv_grid.add_child(_make_label("Tiling U:"))
	_spin_tiling_u = _make_spinbox(0.01, 100.0, 0.01, 1.0)
	_spin_tiling_u.value_changed.connect(func(_v): _on_uv_property_changed())
	uv_grid.add_child(_spin_tiling_u)

	uv_grid.add_child(_make_label("Tiling V:"))
	_spin_tiling_v = _make_spinbox(0.01, 100.0, 0.01, 1.0)
	_spin_tiling_v.value_changed.connect(func(_v): _on_uv_property_changed())
	uv_grid.add_child(_spin_tiling_v)

	uv_grid.add_child(_make_label("Offset U:"))
	_spin_offset_u = _make_spinbox(-100.0, 100.0, 0.01, 0.0)
	_spin_offset_u.value_changed.connect(func(_v): _on_uv_property_changed())
	uv_grid.add_child(_spin_offset_u)

	uv_grid.add_child(_make_label("Offset V:"))
	_spin_offset_v = _make_spinbox(-100.0, 100.0, 0.01, 0.0)
	_spin_offset_v.value_changed.connect(func(_v): _on_uv_property_changed())
	uv_grid.add_child(_spin_offset_v)

	uv_grid.add_child(_make_label("Angle:"))
	_spin_angle = _make_spinbox(-360.0, 360.0, 1.0, 0.0, "°")
	_spin_angle.value_changed.connect(func(_v): _on_uv_property_changed())
	uv_grid.add_child(_spin_angle)

	_uv_and_tint_section.add_child(uv_grid)

	# Flips Row
	var flip_row := HBoxContainer.new()
	_chk_flip_u = CheckBox.new()
	_chk_flip_u.text = "Flip U"
	_chk_flip_u.toggled.connect(func(_b): _on_uv_property_changed())
	flip_row.add_child(_chk_flip_u)

	_chk_flip_v = CheckBox.new()
	_chk_flip_v.text = "Flip V"
	_chk_flip_v.toggled.connect(func(_b): _on_uv_property_changed())
	flip_row.add_child(_chk_flip_v)
	_uv_and_tint_section.add_child(flip_row)

	_uv_and_tint_section.add_child(HSeparator.new())

	# Face Tint Section
	var tint_title := Label.new()
	tint_title.text = "Face Tint"
	_uv_and_tint_section.add_child(tint_title)

	var tint_row := HBoxContainer.new()
	_color_picker = ColorPickerButton.new()
	_color_picker.text = "Color"
	_color_picker.color = Color.WHITE
	_color_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_color_picker.color_changed.connect(_on_tint_changed)
	tint_row.add_child(_color_picker)

	_btn_reset_tint = Button.new()
	_btn_reset_tint.text = "Reset"
	_btn_reset_tint.tooltip_text = "Reset face tint to white"
	_btn_reset_tint.pressed.connect(func():
		_color_picker.color = Color.WHITE
		_on_tint_changed(Color.WHITE)
	)
	tint_row.add_child(_btn_reset_tint)
	_uv_and_tint_section.add_child(tint_row)

	# =========================================================================
	# Section B: Texture Paint Tool Controls (Visible in PAINT mode)
	# =========================================================================
	_paint_tool_section = VBoxContainer.new()
	_paint_tool_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_paint_tool_section.visible = false
	root_vbox.add_child(_paint_tool_section)

	var paint_header := Label.new()
	paint_header.text = "Paint Brush Settings"
	_paint_tool_section.add_child(paint_header)

	_active_paint_label = Label.new()
	_active_paint_label.text = "Paint: (Select a palette card)"
	_active_paint_label.add_theme_color_override("font_color", Color(0.2, 0.85, 1.0))
	_paint_tool_section.add_child(_active_paint_label)

	var paint_grid := GridContainer.new()
	paint_grid.columns = 2
	paint_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	paint_grid.add_child(_make_label("Radius:"))
	_spin_brush_radius = _make_spinbox(0.02, 10.0, 0.01, 0.5, "m")
	_spin_brush_radius.value_changed.connect(func(v):
		if paint_controller != null and not _syncing:
			paint_controller.brush_radius = v
	)
	paint_grid.add_child(_spin_brush_radius)

	paint_grid.add_child(_make_label("Softness:"))
	_spin_brush_softness = _make_spinbox(0.0, 1.0, 0.005, 0.5)
	_spin_brush_softness.value_changed.connect(func(v):
		if paint_controller != null and not _syncing:
			paint_controller.brush_softness = v
	)
	paint_grid.add_child(_spin_brush_softness)

	paint_grid.add_child(_make_label("Opacity:"))
	_spin_brush_opacity = _make_spinbox(0.01, 1.0, 0.005, 1.0)
	_spin_brush_opacity.value_changed.connect(func(v):
		if paint_controller != null and not _syncing:
			paint_controller.brush_opacity = v
	)
	paint_grid.add_child(_spin_brush_opacity)
	_spin_paint_layer = _make_spinbox(1, 8, 1, 1)
	_spin_paint_layer.value_changed.connect(func(v):
		if paint_controller != null and not _syncing:
			paint_controller.active_layer_idx = int(v)
	)
	paint_grid.add_child(_spin_paint_layer)

	_paint_tool_section.add_child(paint_grid)

	var paint_action_row := HBoxContainer.new()
	_chk_erase = CheckBox.new()
	_chk_erase.text = "Erase (Subtract)"
	_chk_erase.tooltip_text = "When enabled, the brush erases up to the Opacity amount per stroke on the active layer mask"
	_chk_erase.toggled.connect(func(b):
		if paint_controller != null and not _syncing:
			paint_controller.erase_mode = b
	)
	paint_action_row.add_child(_chk_erase)

	_btn_clear_layer = Button.new()
	_btn_clear_layer.text = "Clear Layer"
	_btn_clear_layer.tooltip_text = "Clears alpha mask for current layer on selected face"
	_btn_clear_layer.pressed.connect(_on_clear_layer_pressed)
	paint_action_row.add_child(_btn_clear_layer)
	_paint_tool_section.add_child(paint_action_row)

	var paint_hint := Label.new()
	paint_hint.text = "LMB drag in viewport to paint splat layer. Zero lag."
	paint_hint.add_theme_color_override("font_color", Color(0.65, 0.75, 0.85))
	paint_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_paint_tool_section.add_child(paint_hint)

	# =========================================================================
	# Section C: Stamp Tool Controls (Visible in STAMP mode)
	# =========================================================================
	_stamp_tool_section = VBoxContainer.new()
	_stamp_tool_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stamp_tool_section.visible = false
	root_vbox.add_child(_stamp_tool_section)

	var stamp_header := Label.new()
	stamp_header.text = "Stamp Tool Settings"
	_stamp_tool_section.add_child(stamp_header)

	var stamp_submode_row := HBoxContainer.new()
	stamp_submode_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_btn_stamp_place = Button.new()
	_btn_stamp_place.text = "Place Stamp"
	_btn_stamp_place.tooltip_text = "Place stamp decals on surfaces"
	_btn_stamp_place.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_stamp_place.toggle_mode = true
	_btn_stamp_place.button_pressed = true
	_btn_stamp_place.pressed.connect(func(): _set_stamp_submode(false))
	stamp_submode_row.add_child(_btn_stamp_place)

	_btn_stamp_delete = Button.new()
	_btn_stamp_delete.text = "Delete Tool"
	_btn_stamp_delete.tooltip_text = "Delete stamp billboards: Hover over any placed stamp to highlight it in red, click to delete"
	_btn_stamp_delete.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_stamp_delete.toggle_mode = true
	_btn_stamp_delete.button_pressed = false
	_btn_stamp_delete.pressed.connect(func(): _set_stamp_submode(true))
	stamp_submode_row.add_child(_btn_stamp_delete)

	_stamp_tool_section.add_child(stamp_submode_row)
	_active_stamp_label = Label.new()
	_active_stamp_label.text = "Stamp: (Select a palette card)"
	_active_stamp_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	_stamp_tool_section.add_child(_active_stamp_label)

	var stamp_grid := GridContainer.new()
	stamp_grid.columns = 2
	stamp_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	stamp_grid.add_child(_make_label("Scale:"))
	var scale_box := HBoxContainer.new()
	scale_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var btn_scale_dn := Button.new()
	btn_scale_dn.text = "-"
	btn_scale_dn.tooltip_text = "Scale Down"
	btn_scale_dn.pressed.connect(func():
		if paint_controller != null:
			paint_controller.stamp_scale = clampf(paint_controller.stamp_scale / 1.1, 0.05, 50.0)
	)
	scale_box.add_child(btn_scale_dn)
	_spin_stamp_scale = _make_spinbox(0.05, 50.0, 0.01, 1.0, "m")
	_spin_stamp_scale.value_changed.connect(func(v):
		if paint_controller != null and not _syncing:
			paint_controller.stamp_scale = v
	)
	scale_box.add_child(_spin_stamp_scale)
	var btn_scale_up := Button.new()
	btn_scale_up.text = "+"
	btn_scale_up.tooltip_text = "Scale Up"
	btn_scale_up.pressed.connect(func():
		if paint_controller != null:
			paint_controller.stamp_scale = clampf(paint_controller.stamp_scale * 1.1, 0.05, 50.0)
	)
	scale_box.add_child(btn_scale_up)
	stamp_grid.add_child(scale_box)

	stamp_grid.add_child(_make_label("Rotation:"))
	var rot_box := HBoxContainer.new()
	rot_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var btn_rot_ccw := Button.new()
	btn_rot_ccw.text = "↺"
	btn_rot_ccw.tooltip_text = "Rotate CCW -15°"
	btn_rot_ccw.pressed.connect(func():
		if paint_controller != null:
			paint_controller.stamp_rotation = wrapf(paint_controller.stamp_rotation - 15.0, 0.0, 360.0)
	)
	rot_box.add_child(btn_rot_ccw)
	_spin_stamp_rotation = _make_spinbox(0.0, 360.0, 1.0, 0.0, "°")
	_spin_stamp_rotation.value_changed.connect(func(v):
		if paint_controller != null and not _syncing:
			paint_controller.stamp_rotation = v
	)
	rot_box.add_child(_spin_stamp_rotation)
	var btn_rot_cw := Button.new()
	btn_rot_cw.text = "↻"
	btn_rot_cw.tooltip_text = "Rotate CW +15°"
	btn_rot_cw.pressed.connect(func():
		if paint_controller != null:
			paint_controller.stamp_rotation = wrapf(paint_controller.stamp_rotation + 15.0, 0.0, 360.0)
	)
	rot_box.add_child(btn_rot_cw)
	stamp_grid.add_child(rot_box)

	stamp_grid.add_child(_make_label("Opacity:"))
	_spin_stamp_opacity = _make_spinbox(0.01, 1.0, 0.005, 1.0)
	_spin_stamp_opacity.value_changed.connect(func(v):
		if paint_controller != null and not _syncing:
			paint_controller.stamp_opacity = v
	)
	stamp_grid.add_child(_spin_stamp_opacity)
	_stamp_tool_section.add_child(stamp_grid)

	var btn_clear_stamps := Button.new()
	btn_clear_stamps.text = "Clear All Stamps"
	btn_clear_stamps.tooltip_text = "Removes all placed stamp decals on the active mesh"
	btn_clear_stamps.pressed.connect(_on_clear_all_stamps_pressed)
	_stamp_tool_section.add_child(btn_clear_stamps)

	_stamp_hint = Label.new()
	_stamp_hint.text = "Hover mesh for live preview. Click to paste.\nScale & Rotate via buttons and spinners above."
	_stamp_hint.add_theme_color_override("font_color", Color(0.65, 0.75, 0.85))
	_stamp_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_stamp_tool_section.add_child(_stamp_hint)
	root_vbox.add_child(HSeparator.new())

	# Status / Selection feedback
	_status_label = Label.new()
	_status_label.text = "Select a face to edit UVs / Material"
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	root_vbox.add_child(_status_label)

	# Context Menu for right click on materials
	_context_menu = PopupMenu.new()
	_context_menu.id_pressed.connect(_on_context_menu_id_pressed)
	add_child(_context_menu)

# ==============================================================================
# Mode Management
# ==============================================================================

func _set_dock_mode(new_mode: DockMode) -> void:
	dock_mode = new_mode
	_btn_mode_mat.button_pressed = (dock_mode == DockMode.MATERIAL)
	_btn_mode_paint.button_pressed = (dock_mode == DockMode.PAINT)
	_btn_mode_stamp.button_pressed = (dock_mode == DockMode.STAMP)

	_uv_and_tint_section.visible = (dock_mode == DockMode.MATERIAL)
	_paint_tool_section.visible = (dock_mode == DockMode.PAINT)
	_stamp_tool_section.visible = (dock_mode == DockMode.STAMP)

	if paint_controller != null:
		match dock_mode:
			DockMode.MATERIAL:
				paint_controller.set_mode(PBPaintController.Mode.NONE)
			DockMode.PAINT:
				paint_controller.set_mode(PBPaintController.Mode.PAINT)
				if paint_controller.paint_texture == null and not _project_materials.is_empty():
					_select_paint_material(_project_materials[0])
			DockMode.STAMP:
				_set_stamp_submode(false)
				if paint_controller.stamp_texture == null and not _project_materials.is_empty():
					_select_stamp_material(_project_materials[0])

	_rebuild_material_grid()
	_update_tool_labels()
	sync_selection()

func _update_tool_labels() -> void:
	if _active_paint_label != null:
		if paint_controller != null and paint_controller.paint_texture != null:
			var tex_name := paint_controller.paint_texture.resource_path.get_file()
			if tex_name.is_empty():
				tex_name = "Texture"
			_active_paint_label.text = "Paint: %s (Layer %d)" % [tex_name, paint_controller.active_layer_idx]
		else:
			_active_paint_label.text = "Paint: (Select a palette card)"

	if _active_stamp_label != null:
		if paint_controller != null and paint_controller.stamp_texture != null:
			var tex_name := paint_controller.stamp_texture.resource_path.get_file()
			if tex_name.is_empty():
				tex_name = "Texture"
			_active_stamp_label.text = "Stamp: %s (%.1fm, %d°)" % [tex_name, paint_controller.stamp_scale, int(paint_controller.stamp_rotation)]
		else:
			_active_stamp_label.text = "Stamp: (Select a palette card)"


func _set_stamp_submode(delete_active: bool) -> void:
	if _btn_stamp_place != null:
		_btn_stamp_place.button_pressed = not delete_active
	if _btn_stamp_delete != null:
		_btn_stamp_delete.button_pressed = delete_active
	if paint_controller != null:
		if delete_active:
			paint_controller.set_mode(PBPaintController.Mode.STAMP_DELETE)
		else:
			paint_controller.set_mode(PBPaintController.Mode.STAMP)
	if _stamp_hint != null:
		if delete_active:
			_stamp_hint.text = "Delete Tool active: Hover over any placed stamp billboard to highlight it in red. Click to delete."
			_stamp_hint.add_theme_color_override("font_color", Color(1.0, 0.45, 0.45))
		else:
			_stamp_hint.text = "Hover mesh for live preview. Click to paste.\nScale & Rotate via buttons and spinners above."
			_stamp_hint.add_theme_color_override("font_color", Color(0.65, 0.75, 0.85))
func _select_paint_material(mat: Material) -> void:
	if mat == null or paint_controller == null:
		return
	var tex := _extract_texture(mat)
	if tex != null:
		paint_controller.set_paint_texture_and_update_layer(tex)
		_update_tool_labels()
		_rebuild_material_grid()
		if plugin != null and plugin.logger != null:
			plugin.logger.info("paint", "Selected paint texture: %s" % tex.resource_path.get_file())

func _select_stamp_material(mat: Material) -> void:
	if mat == null or paint_controller == null:
		return
	var tex := _extract_texture(mat)
	if tex != null:
		paint_controller.stamp_texture = tex
		_update_tool_labels()
		_rebuild_material_grid()
		if plugin != null and plugin.logger != null:
			plugin.logger.info("stamp", "Selected stamp texture: %s" % tex.resource_path.get_file())

func _extract_texture(mat: Material) -> Texture2D:
	if mat is StandardMaterial3D and mat.albedo_texture != null:
		return mat.albedo_texture
	elif mat is ShaderMaterial:
		var tex = (mat as ShaderMaterial).get_shader_parameter("base_texture")
		if tex is Texture2D:
			return tex
	var def := get_default_material()
	if def is StandardMaterial3D and def.albedo_texture != null:
		return def.albedo_texture
	return null

func _on_clear_layer_pressed() -> void:
	var mesh: PBMesh = editor.active_mesh if editor != null else null
	if mesh == null or mesh.pb_mesh_data == null or paint_controller == null:
		return

	var sel_faces := _get_target_faces(mesh)
	if sel_faces.is_empty():
		return

	var before := PBCommand.copy_mesh_data(mesh.pb_mesh_data)
	var cleared := false

	for face in sel_faces:
		var mat = mesh.pb_mesh_data.get_face_material(face)
		if PBSplat.is_splat_material(mat):
			PBSplat.clear_layer(mat as ShaderMaterial, paint_controller.active_layer_idx)
			cleared = true

	if cleared:
		var after := PBCommand.copy_mesh_data(mesh.pb_mesh_data)
		_commit_mesh_action(mesh, "Clear Splat Layer", before, after)
func _on_clear_all_stamps_pressed() -> void:
	var mesh: PBMesh = editor.active_mesh if editor != null else null
	if mesh == null and paint_controller != null:
		mesh = paint_controller.target_mesh
	if mesh == null:
		return
	var stamps := mesh.get_node_or_null("PBStamps") as Node3D
	if stamps == null or stamps.get_child_count() == 0:
		return
	if plugin != null and plugin.has_method("get_undo_redo"):
		var undo = plugin.get_undo_redo()
		if undo != null:
			undo.create_action("Clear All Stamps", UndoRedo.MERGE_DISABLE, mesh)
			for c in stamps.get_children():
				undo.add_do_method(plugin, "_detach_node", c)
				undo.add_undo_method(plugin, "_attach_detached", c, stamps)
				undo.add_undo_method(plugin, "_own_node", c)
			undo.commit_action()
			return
	for c in stamps.get_children():
		c.queue_free()


# ==============================================================================
# Material Management & Grid Population
# ==============================================================================

func refresh_materials() -> void:
	_project_materials.clear()

	# 1. Always include default material first
	var def_mat := get_default_material()
	if def_mat != null:
		_project_materials.append(def_mat)

	# 2. Add materials from active mesh if any
	if editor != null and editor.active_mesh != null and editor.active_mesh.pb_mesh_data != null:
		for m in editor.active_mesh.pb_mesh_data.materials:
			if m != null and not _project_materials.has(m):
				_project_materials.append(m)

	# 3. Scan project for materials and texture images
	_scan_dir_for_materials("res://")

	_rebuild_material_grid()

func _scan_dir_for_materials(dir_path: String, depth: int = 0) -> void:
	if depth > 3 or _project_materials.size() > 60:
		return
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var name_str := d.get_next()
	while name_str != "":
		if not name_str.begins_with(".") and not name_str.begins_with(".godot"):
			var full_path := dir_path.path_join(name_str)
			if d.current_is_dir():
				_scan_dir_for_materials(full_path, depth + 1)
			else:
				var ext := name_str.get_extension().to_lower()
				if ext == "tres" or ext == "material":
					if ResourceLoader.exists(full_path):
						var res = ResourceLoader.load(full_path)
						if res is Material and not _project_materials.has(res):
							_project_materials.append(res)
				elif ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "webp":
					if ResourceLoader.exists(full_path):
						var tex = ResourceLoader.load(full_path)
						if tex is Texture2D:
							var mat := StandardMaterial3D.new()
							mat.resource_name = name_str.get_basename().capitalize()
							mat.albedo_texture = tex
							mat.roughness = 0.8
							_project_materials.append(mat)
		name_str = d.get_next()
	d.list_dir_end()

func _rebuild_material_grid() -> void:
	if _material_grid == null:
		return
	for c in _material_grid.get_children():
		c.queue_free()

	for mat in _project_materials:
		if mat == null:
			continue
		var card := _create_material_card(mat)
		_material_grid.add_child(card)

func _create_material_card(mat: Material) -> Control:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(64, 64)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	btn.clip_text = true

	var mat_name := mat.resource_name
	if mat_name.is_empty():
		mat_name = mat.resource_path.get_file().get_basename()
	if mat_name.is_empty():
		mat_name = "Material"

	var tooltip := mat_name
	match dock_mode:
		DockMode.MATERIAL:
			tooltip += "\nLeft-click: Apply to selected face(s)\nRight-click: Set as default"
		DockMode.PAINT:
			tooltip += "\nLeft-click: Select as active paint brush texture"
		DockMode.STAMP:
			tooltip += "\nLeft-click: Select as active stamp texture"
	btn.tooltip_text = tooltip

	var tex := _extract_texture(mat)
	if tex != null:
		btn.icon = tex
		btn.expand_icon = true
	elif mat is StandardMaterial3D:
		btn.text = mat_name
		btn.modulate = mat.albedo_color
	else:
		btn.text = mat_name

	# Left-click routing based on active dock mode
	btn.pressed.connect(func():
		match dock_mode:
			DockMode.MATERIAL:
				_apply_material_to_selection(mat)
			DockMode.PAINT:
				_select_paint_material(mat)
			DockMode.STAMP:
				_select_stamp_material(mat)
	)

	# Right-click -> Context Menu
	btn.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
			_show_context_menu(mat, btn.get_global_mouse_position())
	)

	# Drag & Drop source
	btn.set_script(preload("res://addons/poibuilder/gui/docks/pb_material_card_drag.gd"))
	btn.set("material_resource", mat)

	# Default indicator badge
	var is_default := (mat.resource_path == _default_material_path or mat == get_default_material())
	if is_default:
		var badge := Label.new()
		badge.text = "★"
		badge.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
		badge.add_theme_font_size_override("font_size", 14)
		badge.position = Vector2(4, 2)
		btn.add_child(badge)

	# Active selection badge for Paint / Stamp
	var is_active_paint := (dock_mode == DockMode.PAINT and paint_controller != null and tex != null and paint_controller.paint_texture == tex)
	var is_active_stamp := (dock_mode == DockMode.STAMP and paint_controller != null and tex != null and paint_controller.stamp_texture == tex)

	if is_active_paint:
		var pbadge := Label.new()
		pbadge.text = "🖌"
		pbadge.position = Vector2(48, 2)
		btn.add_child(pbadge)
	elif is_active_stamp:
		var sbadge := Label.new()
		sbadge.text = "⎘"
		sbadge.position = Vector2(48, 2)
		btn.add_child(sbadge)

	return btn

func _show_context_menu(mat: Material, pos: Vector2) -> void:
	_context_material = mat
	_context_menu.clear()
	var is_def := (mat.resource_path == _default_material_path)
	_context_menu.add_item("★ Set as Default for New Shapes", 1)
	if is_def:
		_context_menu.set_item_disabled(0, true)
	_context_menu.add_item("Apply to Selection", 2)
	_context_menu.add_item("Set as Paint Texture", 4)
	_context_menu.add_item("Set as Stamp Texture", 5)
	_context_menu.add_separator()
	_context_menu.add_item("Copy Path", 3)
	_context_menu.popup(Rect2i(Vector2i(pos), Vector2i(190, 110)))

func _on_context_menu_id_pressed(id: int) -> void:
	if _context_material == null:
		return
	match id:
		1: # Set as default
			if not _context_material.resource_path.is_empty():
				_save_default_material_setting(_context_material.resource_path)
				_rebuild_material_grid()
				if plugin != null and plugin.logger != null:
					plugin.logger.info("materials", "Set default shape material to %s" % _default_material_path)
		2: # Apply
			_apply_material_to_selection(_context_material)
		3: # Copy path
			DisplayServer.clipboard_set(_context_material.resource_path)
		4: # Paint
			_select_paint_material(_context_material)
			_set_dock_mode(DockMode.PAINT)
		5: # Stamp
			_select_stamp_material(_context_material)
			_set_dock_mode(DockMode.STAMP)

func _on_add_material_pressed() -> void:
	if _file_dialog == null:
		_file_dialog = EditorFileDialog.new()
		_file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
		_file_dialog.add_filter("*.tres, *.material, *.png, *.jpg, *.webp", "Materials & Textures")
		_file_dialog.file_selected.connect(_on_file_dialog_selected)
		add_child(_file_dialog)
	_file_dialog.popup_file_dialog()

func _on_file_dialog_selected(path: String) -> void:
	if ResourceLoader.exists(path):
		var res = ResourceLoader.load(path)
		if res is Material:
			if not _project_materials.has(res):
				_project_materials.append(res)
				_rebuild_material_grid()
		elif res is Texture2D:
			var mat := StandardMaterial3D.new()
			mat.resource_name = path.get_file().get_basename().capitalize()
			mat.albedo_texture = res
			mat.roughness = 0.8
			_project_materials.append(mat)
			_rebuild_material_grid()

# ==============================================================================
# Selection Synchronization & UI State
# ==============================================================================

func sync_selection() -> void:
	if _syncing:
		return
	_syncing = true
	if _status_label == null:
		_syncing = false
		return

	var mesh: PBMesh = editor.active_mesh if editor != null else null
	var has_selection: bool = false
	var first_face: PBFace = null

	if mesh != null and mesh.pb_mesh_data != null and editor != null and editor.selection != null:
		var sel_faces: PackedInt32Array = editor.selection.selected_faces
		if not sel_faces.is_empty():
			has_selection = true
			var fi: int = sel_faces[0]
			if fi >= 0 and fi < mesh.pb_mesh_data.faces.size():
				first_face = mesh.pb_mesh_data.faces[fi]
			_status_label.text = "%d face(s) selected on %s" % [sel_faces.size(), mesh.name]
		elif editor.tool_mode == PBEditor.SelectMode.OBJECT:
			has_selection = true
			_status_label.text = "Object %s selected (materials apply to all faces)" % mesh.name
		else:
			_status_label.text = "No faces selected on %s" % mesh.name
	else:
		_status_label.text = "No PBMesh selected"

	# Enable / disable UV controls
	_btn_x2.disabled = not has_selection
	_btn_half.disabled = not has_selection
	_btn_reset_uv.disabled = not has_selection
	_btn_diagonal.disabled = not has_selection
	_set_slider_enabled(_spin_tiling_u, has_selection)
	_set_slider_enabled(_spin_tiling_v, has_selection)
	_set_slider_enabled(_spin_offset_u, has_selection)
	_set_slider_enabled(_spin_offset_v, has_selection)
	_set_slider_enabled(_spin_angle, has_selection)
	_chk_flip_u.disabled = not has_selection
	_chk_flip_v.disabled = not has_selection
	_color_picker.disabled = not has_selection
	_btn_reset_tint.disabled = not has_selection

	if first_face != null:
		_spin_tiling_u.value = first_face.uv_scale.x
		_spin_tiling_v.value = first_face.uv_scale.y
		_spin_offset_u.value = first_face.uv_offset.x
		_spin_offset_v.value = first_face.uv_offset.y
		_spin_angle.value = first_face.uv_rotation
		_chk_flip_u.button_pressed = first_face.uv_flip_u
		_chk_flip_v.button_pressed = first_face.uv_flip_v

		# Read vertex color tint if available
		var data: PBMeshData = mesh.pb_mesh_data
		var idxs := first_face.get_distinct_indexes()
		if not idxs.is_empty() and idxs[0] < data.colors.size():
			_color_picker.color = data.colors[idxs[0]]
		else:
			_color_picker.color = Color.WHITE

	_syncing = false

# ==============================================================================
# UV & Material Actions
# ==============================================================================

func _apply_material_to_selection(mat: Material) -> void:
	var mesh: PBMesh = editor.active_mesh if editor != null else null
	if mesh == null or mesh.pb_mesh_data == null:
		return

	var target_faces: Array[PBFace] = []
	var sel_faces: PackedInt32Array = editor.selection.selected_faces if editor != null and editor.selection != null else PackedInt32Array()

	if not sel_faces.is_empty():
		for fi in sel_faces:
			if fi >= 0 and fi < mesh.pb_mesh_data.faces.size():
				target_faces.append(mesh.pb_mesh_data.faces[fi])
	else:
		# Object mode or all faces
		for f in mesh.pb_mesh_data.faces:
			if f != null:
				target_faces.append(f)

	if target_faces.is_empty():
		return

	if plugin != null and plugin.has_method("apply_faces_material"):
		plugin.apply_faces_material(mesh, target_faces, mat)
	else:
		mesh.pb_mesh_data.set_faces_material(target_faces, mat)
		mesh.rebuild()
		mesh.update_gizmos()

func _scale_tiling(factor: float) -> void:
	var mesh: PBMesh = editor.active_mesh if editor != null else null
	if mesh == null or mesh.pb_mesh_data == null:
		return
	var sel_faces := _get_target_faces(mesh)
	if sel_faces.is_empty():
		return

	var before := PBCommand.copy_mesh_data(mesh.pb_mesh_data)
	for face in sel_faces:
		PBUv.scale_face_tiling(face, factor)
	PBUv.refresh_mesh_uvs(mesh.pb_mesh_data)
	var after := PBCommand.copy_mesh_data(mesh.pb_mesh_data)

	_commit_mesh_action(mesh, "Scale Face Tiling", before, after)
	sync_selection()

func _on_reset_uv_pressed() -> void:
	var mesh: PBMesh = editor.active_mesh if editor != null else null
	if mesh == null or mesh.pb_mesh_data == null:
		return
	var sel_faces := _get_target_faces(mesh)
	if sel_faces.is_empty():
		return

	var before := PBCommand.copy_mesh_data(mesh.pb_mesh_data)
	for face in sel_faces:
		face.uv_scale = Vector2.ONE
		face.uv_offset = Vector2.ZERO
		face.uv_rotation = 0.0
		face.uv_flip_u = false
		face.uv_flip_v = false
	PBUv.refresh_mesh_uvs(mesh.pb_mesh_data)
	var after := PBCommand.copy_mesh_data(mesh.pb_mesh_data)

	_commit_mesh_action(mesh, "Reset Face UVs", before, after)
	sync_selection()

func _on_diagonal_pressed() -> void:
	var mesh: PBMesh = editor.active_mesh if editor != null else null
	if mesh == null or mesh.pb_mesh_data == null:
		return
	var sel_faces := _get_target_faces(mesh)
	if sel_faces.is_empty():
		return

	var before := PBCommand.copy_mesh_data(mesh.pb_mesh_data)
	for face in sel_faces:
		PBUv.set_face_45_degree_diagonal(face)
	PBUv.refresh_mesh_uvs(mesh.pb_mesh_data)
	var after := PBCommand.copy_mesh_data(mesh.pb_mesh_data)

	_commit_mesh_action(mesh, "45° Diagonal UV Tiling", before, after)
	sync_selection()

func _on_uv_property_changed() -> void:
	if _syncing:
		return
	var mesh: PBMesh = editor.active_mesh if editor != null else null
	if mesh == null or mesh.pb_mesh_data == null:
		return
	var sel_faces := _get_target_faces(mesh)
	if sel_faces.is_empty():
		return

	var before := PBCommand.copy_mesh_data(mesh.pb_mesh_data)

	for face in sel_faces:
		face.uv_scale = Vector2(_spin_tiling_u.value, _spin_tiling_v.value)
		face.uv_offset = Vector2(_spin_offset_u.value, _spin_offset_v.value)
		face.uv_rotation = _spin_angle.value
		face.uv_flip_u = _chk_flip_u.button_pressed
		face.uv_flip_v = _chk_flip_v.button_pressed

	PBUv.refresh_mesh_uvs(mesh.pb_mesh_data)
	var after := PBCommand.copy_mesh_data(mesh.pb_mesh_data)
	_commit_mesh_action(mesh, "Change Face UVs", before, after)

func _on_tint_changed(color: Color) -> void:
	if _syncing:
		return
	var mesh: PBMesh = editor.active_mesh if editor != null else null
	if mesh == null or mesh.pb_mesh_data == null:
		return
	var sel_faces := _get_target_faces(mesh)
	if sel_faces.is_empty():
		return

	var before := PBCommand.copy_mesh_data(mesh.pb_mesh_data)

	var data := mesh.pb_mesh_data
	var vc := data.positions.size()
	if data.colors.size() != vc:
		data.colors.resize(vc)
		data.colors.fill(Color.WHITE)

	for face in sel_faces:
		for idx in face.get_distinct_indexes():
			if idx >= 0 and idx < vc:
				data.colors[idx] = color

	var after := PBCommand.copy_mesh_data(mesh.pb_mesh_data)
	_commit_mesh_action(mesh, "Change Face Tint", before, after)
	mesh.update_gizmos()

func _get_target_faces(mesh: PBMesh) -> Array[PBFace]:
	var result: Array[PBFace] = []
	if mesh == null or mesh.pb_mesh_data == null:
		return result
	var sel_faces: PackedInt32Array = editor.selection.selected_faces if editor != null and editor.selection != null else PackedInt32Array()
	if not sel_faces.is_empty():
		for fi in sel_faces:
			if fi >= 0 and fi < mesh.pb_mesh_data.faces.size():
				result.append(mesh.pb_mesh_data.faces[fi])
	else:
		for f in mesh.pb_mesh_data.faces:
			if f != null:
				result.append(f)
	return result

func _commit_mesh_action(mesh: PBMesh, action_name: String, before: PBMeshData, after: PBMeshData) -> void:
	mesh.rebuild()
	mesh.update_gizmos()
	if plugin != null and plugin.has_method("get_undo_redo"):
		var undo = plugin.get_undo_redo()
		if undo != null:
			undo.create_action(action_name, UndoRedo.MERGE_DISABLE, mesh)
			undo.add_do_method(plugin, "_restore_mesh_snapshot", mesh.get_instance_id(), after)
			undo.add_undo_method(plugin, "_restore_mesh_snapshot", mesh.get_instance_id(), before)
			undo.commit_action()

# ==============================================================================
# UI Helpers
# ==============================================================================

func _make_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l

func _make_spinbox(min_val: float, max_val: float, step_val: float, default_val: float, suffix_str: String = "") -> Range:
	if Engine.is_editor_hint() and ClassDB.can_instantiate("EditorSpinSlider"):
		var s := EditorSpinSlider.new()
		s.min_value = min_val
		s.max_value = max_val
		s.step = step_val
		s.value = default_val
		if not suffix_str.is_empty():
			s.suffix = suffix_str
		s.flat = false
		s.hide_slider = true
		s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		return s
	else:
		var sb := SpinBox.new()
		sb.min_value = min_val
		sb.max_value = max_val
		sb.step = step_val
		sb.value = default_val
		if not suffix_str.is_empty():
			sb.suffix = suffix_str
		sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		return sb

func _set_slider_enabled(slider: Range, enabled: bool) -> void:
	if slider == null:
		return
	if slider is SpinBox:
		(slider as SpinBox).editable = enabled
	elif slider is EditorSpinSlider:
		(slider as EditorSpinSlider).read_only = not enabled
