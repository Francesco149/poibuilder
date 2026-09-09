## PBExportDialog — Editor dialog for exporting PoiBuilder maps to GLB.
##
## Supports both Retro Baked Map export and Modern Engine GLB export,
## with individual toggles for quad subdivision, lighting bake (shadows + AO),
## texture baking, billboards, and collision meshes.
@tool
class_name PBExportDialog
extends ConfirmationDialog

signal export_completed(path: String, mode: int)

var _mode_option: OptionButton
var _chk_subdivide: CheckBox
var _spin_grid_size: SpinBox
var _chk_bake_lighting: CheckBox
var _chk_bake_shadows: CheckBox
var _chk_bake_ao: CheckBox
var _spin_ao_samples: SpinBox
var _spin_ao_distance: SpinBox
var _chk_bake_textures: CheckBox
var _spin_tile_res: OptionButton
var _spin_max_tex_size: OptionButton
var _chk_export_billboards: CheckBox
var _chk_export_colliders: CheckBox
var _txt_path: LineEdit
var _btn_browse: Button
var _file_dialog: FileDialog
var _lbl_status: Label

var _scene_root: Node = null

func _init() -> void:
	title = "Export PoiBuilder Map"
	min_size = Vector2(460, 480)
	ok_button_text = "Export"
	_build_ui()

func _build_ui() -> void:
	var root_vb := VBoxContainer.new()
	root_vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_vb.add_theme_constant_override("separation", 8)
	add_child(root_vb)

	# Mode selection
	var hb_mode := HBoxContainer.new()
	var lbl_mode := Label.new()
	lbl_mode.text = "Target Engine Mode:"
	lbl_mode.custom_minimum_size = Vector2(160, 0)
	hb_mode.add_child(lbl_mode)
	_mode_option = OptionButton.new()
	_mode_option.add_item("Retro Engine (Fully Baked Map)", PBMapExporter.ExportMode.RETRO)
	_mode_option.add_item("Modern Engine (GLB + Metadata)", PBMapExporter.ExportMode.MODERN)
	_mode_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mode_option.item_selected.connect(_on_mode_selected)
	hb_mode.add_child(_mode_option)
	root_vb.add_child(hb_mode)

	root_vb.add_child(HSeparator.new())

	# Geometry & Subdivision
	var hb_sub := HBoxContainer.new()
	_chk_subdivide = CheckBox.new()
	_chk_subdivide.text = "Subdivide Faces into Grid Quads"
	_chk_subdivide.button_pressed = true
	_chk_subdivide.tooltip_text = "Chops faces into triangulated quads aligned to the texture grid for dense vertex lighting and tile baking"
	hb_sub.add_child(_chk_subdivide)

	var lbl_grid := Label.new()
	lbl_grid.text = "Tile Grid Size (m):"
	hb_sub.add_child(lbl_grid)

	_spin_grid_size = SpinBox.new()
	_spin_grid_size.min_value = 0.25
	_spin_grid_size.max_value = 8.0
	_spin_grid_size.step = 0.25
	_spin_grid_size.value = 1.0
	_spin_grid_size.custom_minimum_size = Vector2(80, 0)
	hb_sub.add_child(_spin_grid_size)
	root_vb.add_child(hb_sub)

	# Textures & Baking
	var hb_tex := HBoxContainer.new()
	_chk_bake_textures = CheckBox.new()
	_chk_bake_textures.text = "Bake Splatting & Stamps to Tiles"
	_chk_bake_textures.button_pressed = true
	_chk_bake_textures.tooltip_text = "Generates composite tile textures for painted areas; unpainted tiles reuse the base texture"
	hb_tex.add_child(_chk_bake_textures)

	var lbl_res := Label.new()
	lbl_res.text = "Tile Res:"
	hb_tex.add_child(lbl_res)

	_spin_tile_res = OptionButton.new()
	_spin_tile_res.add_item("32x32", 32)
	_spin_tile_res.add_item("64x64", 64)
	_spin_tile_res.add_item("128x128", 128)
	_spin_tile_res.add_item("256x256", 256)
	_spin_tile_res.add_item("512x512", 512)
	_spin_tile_res.select(2) # 128 default
	hb_tex.add_child(_spin_tile_res)

	var lbl_max := Label.new()
	lbl_max.text = "Max Size:"
	hb_tex.add_child(lbl_max)

	_spin_max_tex_size = OptionButton.new()
	_spin_max_tex_size.add_item("64x64", 64)
	_spin_max_tex_size.add_item("128x128", 128)
	_spin_max_tex_size.add_item("256x256", 256)
	_spin_max_tex_size.add_item("512x512", 512)
	_spin_max_tex_size.add_item("1024x1024", 1024)
	_spin_max_tex_size.select(3) # 512 default
	_spin_max_tex_size.tooltip_text = "Enforces power-of-two texture dimensions clamped to this maximum size for retro engines"
	hb_tex.add_child(_spin_max_tex_size)
	root_vb.add_child(hb_tex)

	root_vb.add_child(HSeparator.new())

	# Lighting Bake (Vertex Colors)
	_chk_bake_lighting = CheckBox.new()
	_chk_bake_lighting.text = "Bake Lighting into Vertex Colors"
	_chk_bake_lighting.button_pressed = true
	_chk_bake_lighting.toggled.connect(func(on: bool):
		_chk_bake_shadows.editable = on
		_chk_bake_ao.editable = on
		_spin_ao_samples.editable = on
	)
	root_vb.add_child(_chk_bake_lighting)

	var hb_light_ops := HBoxContainer.new()
	hb_light_ops.add_theme_constant_override("separation", 16)

	_chk_bake_shadows = CheckBox.new()
	_chk_bake_shadows.text = "Direct Shadows"
	_chk_bake_shadows.button_pressed = true
	hb_light_ops.add_child(_chk_bake_shadows)

	_chk_bake_ao = CheckBox.new()
	_chk_bake_ao.text = "Ambient Occlusion"
	_chk_bake_ao.button_pressed = true
	hb_light_ops.add_child(_chk_bake_ao)

	var lbl_ao_samp := Label.new()
	lbl_ao_samp.text = "AO Rays:"
	hb_light_ops.add_child(lbl_ao_samp)

	_spin_ao_samples = SpinBox.new()
	_spin_ao_samples.min_value = 4
	_spin_ao_samples.max_value = 64
	_spin_ao_samples.value = 16
	hb_light_ops.add_child(_spin_ao_samples)
	root_vb.add_child(hb_light_ops)

	root_vb.add_child(HSeparator.new())

	# Entities & Billboards
	var hb_entities := HBoxContainer.new()
	_chk_export_billboards = CheckBox.new()
	_chk_export_billboards.text = "Export Billboards (Lit affected by vertex light)"
	_chk_export_billboards.button_pressed = true
	hb_entities.add_child(_chk_export_billboards)

	_chk_export_colliders = CheckBox.new()
	_chk_export_colliders.text = "Export Colliders (Collider_*)"
	_chk_export_colliders.button_pressed = true
	hb_entities.add_child(_chk_export_colliders)
	root_vb.add_child(hb_entities)

	root_vb.add_child(HSeparator.new())

	# Output path
	var lbl_path_title := Label.new()
	lbl_path_title.text = "Output File Path (.glb):"
	root_vb.add_child(lbl_path_title)

	var hb_path := HBoxContainer.new()
	_txt_path = LineEdit.new()
	_txt_path.text = "res://exported_map.glb"
	_txt_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb_path.add_child(_txt_path)

	_btn_browse = Button.new()
	_btn_browse.text = "Browse..."
	_btn_browse.pressed.connect(_on_browse_pressed)
	hb_path.add_child(_btn_browse)
	root_vb.add_child(hb_path)

	_lbl_status = Label.new()
	_lbl_status.modulate = Color(0.2, 0.9, 1.0)
	root_vb.add_child(_lbl_status)

	# File Dialog
	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_file_dialog.access = FileDialog.ACCESS_RESOURCES
	_file_dialog.filters = PackedStringArray(["*.glb ; Binary glTF Map", "*.gltf ; Text glTF Scene"])
	_file_dialog.file_selected.connect(func(path: String): _txt_path.text = path)
	add_child(_file_dialog)

	confirmed.connect(_on_confirmed)

func open_dialog(scene_root: Node) -> void:
	_scene_root = scene_root
	_lbl_status.text = ""
	popup_centered()

func _on_mode_selected(idx: int) -> void:
	var is_retro := idx == PBMapExporter.ExportMode.RETRO
	_chk_subdivide.button_pressed = is_retro
	_chk_bake_lighting.button_pressed = is_retro
	_chk_bake_textures.button_pressed = is_retro

func _on_browse_pressed() -> void:
	_file_dialog.current_path = _txt_path.text
	_file_dialog.popup_centered(Vector2(600, 450))

func _on_confirmed() -> void:
	if _scene_root == null:
		_lbl_status.text = "Error: No active scene to export."
		return

	var path := _txt_path.text.strip_edges()
	if path.is_empty():
		_lbl_status.text = "Error: Output path cannot be empty."
		return

	var settings := PBMapExporter.ExportSettings.new()
	settings.export_mode = _mode_option.get_selected_id() as PBMapExporter.ExportMode
	settings.subdivide_quads = _chk_subdivide.button_pressed
	settings.grid_size = _spin_grid_size.value
	settings.bake_lighting = _chk_bake_lighting.button_pressed
	settings.bake_shadows = _chk_bake_shadows.button_pressed
	settings.bake_ao = _chk_bake_ao.button_pressed
	settings.ao_samples = int(_spin_ao_samples.value)
	settings.bake_textures = _chk_bake_textures.button_pressed
	settings.tile_resolution = _spin_tile_res.get_selected_id()
	settings.max_texture_size = _spin_max_tex_size.get_selected_id()
	settings.export_billboards = _chk_export_billboards.button_pressed
	settings.export_colliders = _chk_export_colliders.button_pressed

	var err := PBMapExporter.export_map(_scene_root, path, settings)
	if err == OK:
		_lbl_status.text = "Export successful: %s" % path
		export_completed.emit(path, settings.export_mode)
		hide()
	else:
		_lbl_status.text = "Export failed with error code: %d" % err
