## PBMaterialDock — Material picker and UV mapping dock for PoiBuilder.
##
## Docks to the right of the 3D viewport (DOCK_SLOT_RIGHT_UL), to the left of the Inspector.
## Toggleable from the PoiBuilder toolbar.
##
## Features:
## - Material Picker:
##   - Click a material card -> applies to selected face(s) (or whole mesh in Object mode).
##   - Right-click a material card -> context menu with "Set as Default for New Shapes", "Copy Path", etc.
##   - Default material is badged with an indicator icon.
##   - Drag material card -> drag-and-drop onto any face in the 3D viewport.
## - UV Tiling & Mapping:
##   - Tiling x2 / /2 buttons.
##   - Reset (1x1m) button.
##   - 45° Diagonal button: tiles to match grid diagonals (sqrt(2)m) cleanly aligned for quads.
##   - Manual Tiling U & V, Offset U & V, Rotation Angle (°), and Flip U & V.
## - Face Tint:
##   - ColorPickerButton setting vertex color tint for selected face(s).
@tool
class_name PBMaterialDock
extends PanelContainer

const DEFAULT_MATERIAL_PATH := "res://addons/poibuilder/materials/pb_default_material.tres"
const SETTING_DEFAULT_MATERIAL := "poibuilder/materials/default_material_path"

## Reference to the main PoiBuilder plugin.
var plugin: EditorPlugin = null
var editor: PBEditor = null:
	set = set_editor

var _selected_material: Material = null
var _default_material_path: String = DEFAULT_MATERIAL_PATH
var _project_materials: Array[Material] = []

# UI Nodes
var _scroll: ScrollContainer
var _material_grid: HFlowContainer
var _status_label: Label
var _active_mesh_label: Label
var _file_dialog: EditorFileDialog

# UV Controls
var _btn_x2: Button
var _btn_half: Button
var _btn_reset_uv: Button
var _btn_diagonal: Button
var _spin_tiling_u: SpinBox
var _spin_tiling_v: SpinBox
var _spin_offset_u: SpinBox
var _spin_offset_v: SpinBox
var _spin_angle: SpinBox
var _chk_flip_u: CheckBox
var _chk_flip_v: CheckBox

# Tint Controls
var _color_picker: ColorPickerButton
var _btn_reset_tint: Button

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
	custom_minimum_size = Vector2(240, 300)
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

	# 1. Header
	var title_lbl := Label.new()
	title_lbl.text = "Material & UV"
	title_lbl.add_theme_font_size_override("font_size", 13)
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root_vbox.add_child(title_lbl)

	# 2. Materials Section Header + Actions
	var mat_header := HBoxContainer.new()
	var mat_title := Label.new()
	mat_title.text = "Materials"
	mat_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mat_header.add_child(mat_title)

	var btn_add := Button.new()
	btn_add.text = "+ Add"
	btn_add.tooltip_text = "Add material from project..."
	btn_add.pressed.connect(_on_add_material_pressed)
	mat_header.add_child(btn_add)

	var btn_refresh := Button.new()
	btn_refresh.text = "↺"
	btn_refresh.tooltip_text = "Scan project for materials"
	btn_refresh.pressed.connect(refresh_materials)
	mat_header.add_child(btn_refresh)
	root_vbox.add_child(mat_header)

	# Material Cards Container
	var mat_scroll := ScrollContainer.new()
	mat_scroll.custom_minimum_size = Vector2(0, 140)
	mat_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mat_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root_vbox.add_child(mat_scroll)

	_material_grid = HFlowContainer.new()
	_material_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mat_scroll.add_child(_material_grid)

	root_vbox.add_child(HSeparator.new())

	# 3. Face UV Tiling Section
	var uv_title := Label.new()
	uv_title.text = "Face UV Tiling"
	root_vbox.add_child(uv_title)

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
	root_vbox.add_child(quick_row)

	# 45° Diagonal Button
	_btn_diagonal = Button.new()
	_btn_diagonal.text = "45° Diagonal Tiling (√2m)"
	_btn_diagonal.tooltip_text = "Scale texture to grid diagonal (1.414m) at 45° angle, cleanly aligned for triangulated quads"
	_btn_diagonal.pressed.connect(_on_diagonal_pressed)
	root_vbox.add_child(_btn_diagonal)

	# Grid of Manual UV Controls
	var uv_grid := GridContainer.new()
	uv_grid.columns = 2
	uv_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	uv_grid.add_child(_make_label("Tiling U:"))
	_spin_tiling_u = _make_spinbox(0.01, 100.0, 0.05, 1.0)
	_spin_tiling_u.value_changed.connect(func(_v): _on_uv_property_changed())
	uv_grid.add_child(_spin_tiling_u)

	uv_grid.add_child(_make_label("Tiling V:"))
	_spin_tiling_v = _make_spinbox(0.01, 100.0, 0.05, 1.0)
	_spin_tiling_v.value_changed.connect(func(_v): _on_uv_property_changed())
	uv_grid.add_child(_spin_tiling_v)

	uv_grid.add_child(_make_label("Offset U:"))
	_spin_offset_u = _make_spinbox(-100.0, 100.0, 0.05, 0.0)
	_spin_offset_u.value_changed.connect(func(_v): _on_uv_property_changed())
	uv_grid.add_child(_spin_offset_u)

	uv_grid.add_child(_make_label("Offset V:"))
	_spin_offset_v = _make_spinbox(-100.0, 100.0, 0.05, 0.0)
	_spin_offset_v.value_changed.connect(func(_v): _on_uv_property_changed())
	uv_grid.add_child(_spin_offset_v)

	uv_grid.add_child(_make_label("Angle:"))
	_spin_angle = _make_spinbox(-360.0, 360.0, 5.0, 0.0)
	_spin_angle.suffix = "°"
	_spin_angle.value_changed.connect(func(_v): _on_uv_property_changed())
	uv_grid.add_child(_spin_angle)

	root_vbox.add_child(uv_grid)

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
	root_vbox.add_child(flip_row)

	root_vbox.add_child(HSeparator.new())

	# 4. Face Tint Section
	var tint_title := Label.new()
	tint_title.text = "Face Tint"
	root_vbox.add_child(tint_title)

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
	root_vbox.add_child(tint_row)

	# 5. Status / Selection feedback
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

	# 3. Scan project for other materials (shallow/fast scan)
	_scan_dir_for_materials("res://")

	_rebuild_material_grid()

func _scan_dir_for_materials(dir_path: String, depth: int = 0) -> void:
	if depth > 3 or _project_materials.size() > 50:
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
	btn.tooltip_text = "%s\nLeft-click: Apply to selected face(s)\nRight-click: Set as default" % mat_name

	# Display swatch or texture
	if mat is StandardMaterial3D and mat.albedo_texture != null:
		btn.icon = mat.albedo_texture
		btn.expand_icon = true
	elif mat is StandardMaterial3D:
		btn.text = mat_name
		btn.modulate = mat.albedo_color
	else:
		btn.text = mat_name

	# Left-click -> Apply
	btn.pressed.connect(func(): _apply_material_to_selection(mat))

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

	return btn

func _show_context_menu(mat: Material, pos: Vector2) -> void:
	_context_material = mat
	_context_menu.clear()
	var is_def := (mat.resource_path == _default_material_path)
	_context_menu.add_item("★ Set as Default for New Shapes", 1)
	if is_def:
		_context_menu.set_item_disabled(0, true)
	_context_menu.add_item("Apply to Selection", 2)
	_context_menu.add_separator()
	_context_menu.add_item("Copy Path", 3)
	_context_menu.popup(Rect2i(Vector2i(pos), Vector2i(180, 80)))

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

func _on_add_material_pressed() -> void:
	if _file_dialog == null:
		_file_dialog = EditorFileDialog.new()
		_file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
		_file_dialog.add_filter("*.tres, *.material", "Materials")
		_file_dialog.file_selected.connect(_on_file_dialog_selected)
		add_child(_file_dialog)
	_file_dialog.popup_file_dialog()

func _on_file_dialog_selected(path: String) -> void:
	if ResourceLoader.exists(path):
		var mat = ResourceLoader.load(path)
		if mat is Material and not _project_materials.has(mat):
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

	# Enable / disable controls
	_btn_x2.disabled = not has_selection
	_btn_half.disabled = not has_selection
	_btn_reset_uv.disabled = not has_selection
	_btn_diagonal.disabled = not has_selection
	_spin_tiling_u.editable = has_selection
	_spin_tiling_v.editable = has_selection
	_spin_offset_u.editable = has_selection
	_spin_offset_v.editable = has_selection
	_spin_angle.editable = has_selection
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

func _make_spinbox(min_val: float, max_val: float, step_val: float, default_val: float) -> SpinBox:
	var sb := SpinBox.new()
	sb.min_value = min_val
	sb.max_value = max_val
	sb.step = step_val
	sb.value = default_val
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return sb
