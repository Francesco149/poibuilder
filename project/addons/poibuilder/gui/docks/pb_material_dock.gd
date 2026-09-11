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

enum DockMode { MATERIAL, PAINT, STAMP, SPRITE }
const DEFAULT_MATERIAL_PATH := "res://addons/poibuilder/materials/pb_default_material.tres"
const SETTING_DEFAULT_MATERIAL := "poibuilder/materials/default_material_path"

## Reference to the main PoiBuilder plugin.
var plugin: EditorPlugin = null
var editor: PBEditor = null:
	set = set_editor

var paint_controller: PBPaintController = null:
	set = set_paint_controller
var sprite_placer: PBSpritePlacer = null

var dock_mode: DockMode = DockMode.MATERIAL

var _selected_material: Material = null
var _default_material_path: String = DEFAULT_MATERIAL_PATH
var _project_materials: Array[Material] = []

# UI Nodes - Mode Row
var _btn_mode_mat: Button
var _btn_mode_paint: Button
var _btn_mode_stamp: Button
var _btn_mode_sprite: Button
# UI Nodes - Materials Section
var _scroll: ScrollContainer
var _material_grid: HFlowContainer
var _status_label: Label
var _file_dialog: EditorFileDialog

# UI Nodes - Sections Container
var _uv_and_tint_section: VBoxContainer
var _paint_tool_section: VBoxContainer
var _stamp_tool_section: VBoxContainer
var _sprite_tool_section: VBoxContainer

# Sprite Tool Controls
var _active_sprite_drop_box: PanelContainer
var _active_sprite_icon: TextureRect
var _active_sprite_label: Label
var _btn_place_sprite: Button

var _sprite_hint: Label
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

# Scrolling Texture (animated UV) Controls
var _spin_scroll_u: Range
var _spin_scroll_v: Range
var _btn_scroll_apply: Button
var _btn_scroll_clear: Button
var _lbl_scroll_speed: Label
var _chk_animate_in_editor: CheckBox

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

func _get_material_or_texture_path(mat: Material) -> String:
	if mat == null:
		return ""
	if mat.has_meta("source_texture_path"):
		return str(mat.get_meta("source_texture_path"))
	if mat is StandardMaterial3D and mat.albedo_texture != null and not mat.albedo_texture.resource_path.is_empty():
		return mat.albedo_texture.resource_path
	return mat.resource_path

func _save_default_material_setting(path: String) -> void:
	_default_material_path = path
	var settings = EditorInterface.get_editor_settings() if Engine.is_editor_hint() else null
	if settings != null:
		settings.set_setting(SETTING_DEFAULT_MATERIAL, path)
	PBMeshData.invalidate_default_material()

func get_default_material() -> Material:
	_load_default_material_setting()
	return PBMeshData.load_material_or_texture(_default_material_path)
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

	_btn_mode_sprite = Button.new()
	_btn_mode_sprite.text = "Sprite"
	_btn_mode_sprite.tooltip_text = "Billboard & Sprite Shapes: Select/drop sprite textures, adjust properties, and place sprites"
	_btn_mode_sprite.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_mode_sprite.toggle_mode = true
	_btn_mode_sprite.button_pressed = (dock_mode == DockMode.SPRITE)
	_btn_mode_sprite.pressed.connect(func(): _set_dock_mode(DockMode.SPRITE))
	mode_row.add_child(_btn_mode_sprite)

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

	# -------------------------------------------------------------------------
	# Scrolling Texture (animated UV): the animation a retro engine can play
	# without a shader or a texture flipbook. It is a MATERIAL property — the
	# unit the retro exporters split meshes by — so applying it to a face whose
	# material is shared with faces outside the selection duplicates the
	# material rather than animating them too.
	# -------------------------------------------------------------------------
	_uv_and_tint_section.add_child(HSeparator.new())

	var scroll_title := Label.new()
	scroll_title.text = "Scrolling Texture (UV Animation)"
	_uv_and_tint_section.add_child(scroll_title)

	var scroll_grid := GridContainer.new()
	scroll_grid.columns = 2
	scroll_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	scroll_grid.add_child(_make_label("Speed U:"))
	_spin_scroll_u = _make_spinbox(-8.0, 8.0, 0.01, 0.0)
	_spin_scroll_u.tooltip_text = "Horizontal scroll in texture repeats per second (negative = leftwards)"
	_spin_scroll_u.value_changed.connect(func(_v): _refresh_scroll_label_from_selection())
	scroll_grid.add_child(_spin_scroll_u)

	scroll_grid.add_child(_make_label("Speed V:"))
	_spin_scroll_v = _make_spinbox(-8.0, 8.0, 0.01, 0.0)
	_spin_scroll_v.tooltip_text = "Vertical scroll in texture repeats per second (negative = downwards on a wall)"
	_spin_scroll_v.value_changed.connect(func(_v): _refresh_scroll_label_from_selection())
	scroll_grid.add_child(_spin_scroll_v)
	_uv_and_tint_section.add_child(scroll_grid)

	_lbl_scroll_speed = Label.new()
	_lbl_scroll_speed.add_theme_color_override("font_color", Color(0.6, 0.75, 0.85))
	_lbl_scroll_speed.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_uv_and_tint_section.add_child(_lbl_scroll_speed)

	var scroll_row := HBoxContainer.new()
	_btn_scroll_apply = Button.new()
	_btn_scroll_apply.text = "Apply Scroll"
	_btn_scroll_apply.tooltip_text = "Animate the selected faces' texture at this speed. Exported maps (and the PSP demo) scroll it live; the texture is kept out of the tile atlases so it can wrap."
	_btn_scroll_apply.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_scroll_apply.pressed.connect(_on_scroll_apply_pressed)
	scroll_row.add_child(_btn_scroll_apply)

	_btn_scroll_clear = Button.new()
	_btn_scroll_clear.text = "Clear"
	_btn_scroll_clear.tooltip_text = "Stop animating the selected faces' texture"
	_btn_scroll_clear.pressed.connect(_on_scroll_clear_pressed)
	scroll_row.add_child(_btn_scroll_clear)
	_uv_and_tint_section.add_child(scroll_row)

	_chk_animate_in_editor = CheckBox.new()
	_chk_animate_in_editor.text = "Animate in Viewport"
	_chk_animate_in_editor.tooltip_text = "When enabled, scrolling textures animate live in the 3D editor viewport while editing."
	_chk_animate_in_editor.button_pressed = plugin.animate_scrolling_textures if plugin != null else true
	_chk_animate_in_editor.toggled.connect(_on_animate_in_editor_toggled)
	_uv_and_tint_section.add_child(_chk_animate_in_editor)

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

	# =========================================================================
	# Section D: Sprite Tool Controls (Visible in SPRITE mode)
	# =========================================================================
	_sprite_tool_section = VBoxContainer.new()
	_sprite_tool_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sprite_tool_section.visible = false
	root_vbox.add_child(_sprite_tool_section)

	var sprite_header := Label.new()
	sprite_header.text = "Billboard Sprite Settings"
	_sprite_tool_section.add_child(sprite_header)

	# Active Sprite drop box / card
	_active_sprite_drop_box = PBSpriteDropBox.new()
	_active_sprite_drop_box.dock = self
	_active_sprite_drop_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_active_sprite_drop_box.custom_minimum_size = Vector2(0, 68)
	var db_style := StyleBoxFlat.new()
	db_style.bg_color = Color(0.12, 0.15, 0.20, 0.95)
	db_style.set_corner_radius_all(6)
	db_style.set_border_width_all(1)
	db_style.border_color = Color(0.2, 0.85, 1.0, 0.7)
	db_style.content_margin_left = 8
	db_style.content_margin_right = 8
	db_style.content_margin_top = 6
	db_style.content_margin_bottom = 6
	_active_sprite_drop_box.add_theme_stylebox_override("panel", db_style)

	var db_hbox := HBoxContainer.new()
	db_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	db_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_active_sprite_drop_box.add_child(db_hbox)

	_active_sprite_icon = TextureRect.new()
	_active_sprite_icon.custom_minimum_size = Vector2(56, 56)
	_active_sprite_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_active_sprite_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_active_sprite_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	db_hbox.add_child(_active_sprite_icon)

	var db_vbox := VBoxContainer.new()
	db_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	db_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	db_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	db_hbox.add_child(db_vbox)

	_active_sprite_label = Label.new()
	_active_sprite_label.text = "Active: (Click card below or drop image here)"
	_active_sprite_label.add_theme_color_override("font_color", Color(1.0, 0.88, 0.2))
	_active_sprite_label.add_theme_font_size_override("font_size", 12)
	_active_sprite_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	db_vbox.add_child(_active_sprite_label)

	var db_sub := Label.new()
	db_sub.text = "Drop image from FileSystem or click palette card"
	db_sub.add_theme_color_override("font_color", Color(0.65, 0.75, 0.85))
	db_sub.add_theme_font_size_override("font_size", 10)
	db_sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	db_vbox.add_child(db_sub)

	_sprite_tool_section.add_child(_active_sprite_drop_box)

	# Place Sprite Button
	_btn_place_sprite = Button.new()
	_btn_place_sprite.text = "🌲 Place Sprite (B)"
	_btn_place_sprite.tooltip_text = "Arm billboard placement tool (B key): click surface to place, drag to pick, mouse up to raise & orient, mouse left/right to scale"
	_btn_place_sprite.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_place_sprite.pressed.connect(func():
		if plugin != null and plugin.has_method("_start_sprite_tool"):
			plugin._start_sprite_tool()
	)
	_sprite_tool_section.add_child(_btn_place_sprite)

	_sprite_hint = Label.new()
	_sprite_hint.text = "Click card in palette or drop image above to set active sprite.\nClick 'Place Sprite' (or press B in viewport) to place.\nProperties (dimensions, lighting, shadows, camera-facing) are adjusted in the Overlay."
	_sprite_hint.add_theme_color_override("font_color", Color(0.65, 0.75, 0.85))
	_sprite_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sprite_tool_section.add_child(_sprite_hint)
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
	_btn_mode_sprite.button_pressed = (dock_mode == DockMode.SPRITE)

	_uv_and_tint_section.visible = (dock_mode == DockMode.MATERIAL)
	_paint_tool_section.visible = (dock_mode == DockMode.PAINT)
	_stamp_tool_section.visible = (dock_mode == DockMode.STAMP)
	_sprite_tool_section.visible = (dock_mode == DockMode.SPRITE)

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
			DockMode.SPRITE:
				paint_controller.set_mode(PBPaintController.Mode.NONE)
				if sprite_placer != null and sprite_placer.last_texture == null and not _project_materials.is_empty():
					_select_sprite_material(_project_materials[0])
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

	if _active_sprite_label != null:
		if sprite_placer != null and sprite_placer.last_texture != null:
			var tex := sprite_placer.last_texture
			_active_sprite_label.text = "%s (%dx%d)" % [tex.resource_path.get_file(), tex.get_width(), tex.get_height()]
			if _active_sprite_icon != null:
				_active_sprite_icon.texture = tex
		else:
			_active_sprite_label.text = "Active: (Click card below or drop image here)"


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


func set_active_sprite_texture(tex: Texture2D) -> void:
	if tex == null:
		return
	if sprite_placer != null:
		sprite_placer.last_texture = tex
		sprite_placer.selected_texture = tex

	if _active_sprite_icon != null:
		_active_sprite_icon.texture = tex
	if _active_sprite_label != null:
		var fn := tex.resource_path.get_file()
		_active_sprite_label.text = "%s (%dx%d)" % [fn, tex.get_width(), tex.get_height()]

	var dims := PBSpritePlacer.compute_texture_dimensions(tex, 1.5)
	if sprite_placer != null:
		sprite_placer.base_width = dims.x
		sprite_placer.base_height = dims.y


	_rebuild_material_grid()
	if plugin != null and plugin.logger != null:
		plugin.logger.info("sprite", "Selected billboard sprite texture: %s" % tex.resource_path.get_file())

func _select_sprite_material(mat: Material) -> void:
	if mat == null:
		return
	var tex := _extract_texture(mat)
	if tex != null:
		set_active_sprite_texture(tex)
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
							mat.set_meta("source_texture_path", full_path)
							mat.albedo_texture = tex
							mat.roughness = 0.8
							mat.vertex_color_use_as_albedo = true
							mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
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
		DockMode.SPRITE:
			tooltip += "\nLeft-click: Select as active billboard sprite"

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
			DockMode.SPRITE:
				_select_sprite_material(mat)
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
	var is_default := false
	var def_path := _default_material_path
	var card_path := _get_material_or_texture_path(mat)
	if not def_path.is_empty() and not card_path.is_empty() and card_path == def_path:
		is_default = true
	elif mat == get_default_material():
		is_default = true
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
	var is_active_sprite := (dock_mode == DockMode.SPRITE and sprite_placer != null and tex != null and sprite_placer.last_texture == tex)
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

	elif is_active_sprite:
		var spbadge := Label.new()
		spbadge.text = "🌲"
		spbadge.position = Vector2(48, 2)
		btn.add_child(spbadge)
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
	_context_menu.add_item("Set as Sprite Texture", 6)
	_context_menu.add_separator()
	_context_menu.add_item("Copy Path", 3)
	_context_menu.popup(Rect2i(Vector2i(pos), Vector2i(190, 110)))

func _on_context_menu_id_pressed(id: int) -> void:
	if _context_material == null:
		return
	match id:
		1: # Set as default
			var mat_path := _get_material_or_texture_path(_context_material)
			if not mat_path.is_empty():
				_save_default_material_setting(mat_path)
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
		6: # Sprite
			_select_sprite_material(_context_material)
			_set_dock_mode(DockMode.SPRITE)

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
	_set_slider_enabled(_spin_scroll_u, has_selection)
	_set_slider_enabled(_spin_scroll_v, has_selection)
	_btn_scroll_apply.disabled = not has_selection
	_btn_scroll_clear.disabled = not has_selection

	if first_face != null:
		_spin_tiling_u.value = first_face.uv_scale.x
		_spin_tiling_v.value = first_face.uv_scale.y
		_spin_offset_u.value = first_face.uv_offset.x
		_spin_offset_v.value = first_face.uv_offset.y
		_spin_angle.value = first_face.uv_rotation
		_chk_flip_u.button_pressed = first_face.uv_flip_u
		_chk_flip_v.button_pressed = first_face.uv_flip_v

		# Scrolling texture: the speed lives on the face's material.
		var scroll := PBUv.get_scroll_speed(mesh.pb_mesh_data.get_face_material(first_face))
		_spin_scroll_u.value = scroll.x
		_spin_scroll_v.value = scroll.y
		_update_scroll_speed_label(scroll, first_face)

		# Read vertex color tint if available
		var data: PBMeshData = mesh.pb_mesh_data
		var idxs := first_face.get_distinct_indexes()
		if not idxs.is_empty() and idxs[0] < data.colors.size():
			_color_picker.color = data.colors[idxs[0]]
		else:
			_color_picker.color = Color.WHITE
	else:
		_update_scroll_speed_label(Vector2.ZERO, null)
	if _chk_animate_in_editor != null and plugin != null:
		_chk_animate_in_editor.set_pressed_no_signal(plugin.animate_scrolling_textures)

	_syncing = false

## Second line under the scroll spins: the same speed in metres per second.
## "Repeats per second" is the format's unit (it survives any tiling change),
## but what an author is actually choosing is how fast the surface appears to
## move — and that depends on how many metres one repeat covers, i.e. the
## face's tiling. Both are shown so the number in the file stays honest.
## Recomputed from the spins as they are typed, so the metres/second figure
## tracks the edit before it is applied.
func _refresh_scroll_label_from_selection() -> void:
	if _syncing or _lbl_scroll_speed == null:
		return
	var face: PBFace = null
	var mesh: PBMesh = editor.active_mesh if editor != null else null
	if mesh != null and editor != null and editor.selection != null and not editor.selection.selected_faces.is_empty():
		var fi: int = editor.selection.selected_faces[0]
		if fi >= 0 and fi < mesh.pb_mesh_data.faces.size():
			face = mesh.pb_mesh_data.faces[fi]
	_update_scroll_speed_label(Vector2(_spin_scroll_u.value, _spin_scroll_v.value), face)

func _update_scroll_speed_label(speed: Vector2, face: PBFace) -> void:
	if _lbl_scroll_speed == null:
		return
	if face == null or speed == Vector2.ZERO:
		_lbl_scroll_speed.text = "static" if face != null else ""
		return
	var mps := Vector2(
		speed.x / maxf(face.uv_scale.x, 0.0001),
		speed.y / maxf(face.uv_scale.y, 0.0001))
	_lbl_scroll_speed.text = "≈ %.2f, %.2f m/s on this face" % [mps.x, mps.y]

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

## Applies the scroll speed currently in the spins to every target face.
## The speed is written to a COPY of each face's material: the scroll lives on
## the material (that is the granularity the retro exporters split meshes by),
## so editing a shared material in place would silently animate every other
## face that happens to use the same texture. Copying also gives undo a clean
## handle — the snapshots then differ by which material a slot points at.
func _on_scroll_apply_pressed() -> void:
	var speed := Vector2(_spin_scroll_u.value, _spin_scroll_v.value)
	if speed == Vector2.ZERO:
		# "0,0" is the encoding for static — treat it as the Clear button so an
		# apply can never silently do nothing.
		_on_scroll_clear_pressed()
		return
	_apply_scroll_to_selection(speed, "Set Scrolling Texture")

func _on_scroll_clear_pressed() -> void:
	_apply_scroll_to_selection(Vector2.ZERO, "Clear Scrolling Texture")
func _on_animate_in_editor_toggled(pressed: bool) -> void:
	if plugin != null:
		plugin.set_animate_scrolling_textures(pressed)


func _apply_scroll_to_selection(speed: Vector2, action_name: String) -> void:
	var mesh: PBMesh = editor.active_mesh if editor != null else null
	if mesh == null or mesh.pb_mesh_data == null:
		return
	var target_faces := _get_target_faces(mesh)
	if target_faces.is_empty():
		return

	var before := PBCommand.copy_mesh_data(mesh.pb_mesh_data)
	var changed := 0
	for face in target_faces:
		var mat: Material = mesh.pb_mesh_data.get_face_material(face)
		if mat == null:
			continue
		if PBUv.get_scroll_speed(mat) == speed:
			continue
		var copy: Material = mat.duplicate()
		copy.resource_name = mat.resource_name
		PBUv.set_scroll_speed(copy, speed)
		mesh.pb_mesh_data.set_faces_material([face], copy)
		changed += 1
	if changed == 0:
		return
	var after := PBCommand.copy_mesh_data(mesh.pb_mesh_data)

	if plugin != null:
		plugin.scan_scrolling_materials()
	_commit_mesh_action(mesh, action_name, before, after)
	sync_selection()
	if plugin != null and plugin.get("logger") != null:
		plugin.logger.info("uv", "%s on %d face(s): %.2f, %.2f repeats/sec"
			% [action_name, changed, speed.x, speed.y])

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

class PBSpriteDropBox extends PanelContainer:
	var dock: PBMaterialDock = null

	func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
		if typeof(data) == TYPE_DICTIONARY:
			var dict: Dictionary = data
			if dict.get("type", "") == "files":
				var files: Array = dict.get("files", [])
				for f in files:
					var ext := str(f).get_extension().to_lower()
					if ext in ["png", "jpg", "jpeg", "webp", "tres", "material"]:
						return true
		return false

	func _drop_data(_at_position: Vector2, data: Variant) -> void:
		if typeof(data) == TYPE_DICTIONARY and dock != null:
			var dict: Dictionary = data
			if dict.get("type", "") == "files":
				var files: Array = dict.get("files", [])
				for f in files:
					var path_str := str(f)
					var ext := path_str.get_extension().to_lower()
					if ext in ["png", "jpg", "jpeg", "webp"]:
						if ResourceLoader.exists(path_str):
							var tex = ResourceLoader.load(path_str)
							if tex is Texture2D:
								dock.set_active_sprite_texture(tex)
								return
					elif ext in ["tres", "material"]:
						if ResourceLoader.exists(path_str):
							var mat = ResourceLoader.load(path_str)
							if mat is Material:
								dock._select_sprite_material(mat)
								return
