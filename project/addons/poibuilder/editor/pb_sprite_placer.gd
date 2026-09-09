## PBSpritePlacer — Interactive placement, camera orientation & scaling controller for Billboard Sprites.
##
## UX Workflow:
## 1. Click surface: places a billboard with the last used texture.
## 2. Click & drag (or click when no last texture): opens modal horizontal carousel showing
##    5 billboard textures at a time; drag/move left-right to smoothly scroll; releasing LMB
##    or clicking confirms the centered texture.
## 3. Raise & Orient: mouse up/down raises the billboard from the surface while dynamically
##    facing the camera; click locks elevation and facing angle.
## 4. Scale: mouse left/right scales the billboard uniformly (respecting grid snap if enabled);
##    click confirms and finalizes placement with full undo/redo.
## 5. ESC at any time cancels cleanly with no stray nodes left behind.
@tool
class_name PBSpritePlacer
extends RefCounted

enum State {
	INACTIVE = 0,
	ARMED = 1,
	TEXTURE_SELECT = 2,
	RAISE = 3,
	SCALE = 4,
}

const DRAG_THRESHOLD := 6.0
const TEXTURE_DIRS := [
	"res://addons/poibuilder/materials/textures",
	"res://materials/textures",
]

var state: State = State.INACTIVE

# Texture selection state
var last_texture: Texture2D = null
var selected_texture: Texture2D = null
var available_textures: Array[Texture2D] = []
var selected_texture_idx: int = 0
var scroll_offset: float = 0.0
var is_hold_mode: bool = false
var _press_pending: bool = false

# Transform / placement tracking
var press_screen_pos: Vector2 = Vector2.ZERO
var press_surface_point: Vector3 = Vector3.ZERO
var press_surface_normal: Vector3 = Vector3.UP
var elevation: float = 0.0
var locked_basis: Basis = Basis()
var scale_factor: float = 1.0
var scale_start_x: float = 0.0

# Shape properties
var lit: bool = false
var cast_shadow: bool = true
var billboard: bool = true
var base_width: float = 1.0
var base_height: float = 1.0

# Node references
var scene_root_override: Node = null
var preview_node: PBMesh = null
var plugin: EditorPlugin = null
var grid: PBGrid = null

# UI Overlay Control
var carousel_overlay: Control = null
var _carousel_card_container: HBoxContainer = null
var _carousel_title_label: Label = null
var _carousel_active_name_label: Label = null

signal state_changed(new_state: State)
signal sprite_placed(node: PBMesh)
signal placement_aborted()

# ==============================================================================
# Initialization & Texture Scanning
# ==============================================================================

func refresh_available_textures() -> void:
	available_textures.clear()
	var seen_paths: Dictionary = {}

	for dir_path in TEXTURE_DIRS:
		_scan_dir_for_textures(dir_path, seen_paths)

	# Set default selection if none
	if not available_textures.is_empty():
		if last_texture != null and available_textures.has(last_texture):
			selected_texture_idx = available_textures.find(last_texture)
		else:
			selected_texture_idx = 0
		selected_texture = available_textures[selected_texture_idx]
		scroll_offset = float(selected_texture_idx)

func _scan_dir_for_textures(dir_path: String, seen_paths: Dictionary) -> void:
	if not DirAccess.dir_exists_absolute(dir_path):
		return
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			var ext := file_name.get_extension().to_lower()
			if ext in ["png", "jpg", "jpeg", "webp"]:
				var full_path := dir_path.path_join(file_name)
				if not seen_paths.has(full_path) and ResourceLoader.exists(full_path):
					var tex = ResourceLoader.load(full_path)
					if tex is Texture2D:
						seen_paths[full_path] = true
						available_textures.append(tex)
		file_name = dir.get_next()
	dir.list_dir_end()

func is_active() -> bool:
	return state != State.INACTIVE

func arm() -> void:
	abort()
	refresh_available_textures()
	state = State.ARMED
	_press_pending = false
	state_changed.emit(state)

func abort() -> void:
	_press_pending = false
	if preview_node != null and is_instance_valid(preview_node):
		if preview_node.get_parent() != null:
			preview_node.get_parent().remove_child(preview_node)
		preview_node.queue_free()
		preview_node = null

	hide_carousel()
	var prev_state := state
	state = State.INACTIVE
	if prev_state != State.INACTIVE:
		state_changed.emit(state)
		placement_aborted.emit()

# ==============================================================================
# Carousel Overlay Setup & Live Updates
# ==============================================================================

func setup_carousel_overlay(host_control: Control) -> void:
	if carousel_overlay != null and is_instance_valid(carousel_overlay):
		return
	if host_control == null:
		return

	carousel_overlay = PanelContainer.new()
	carousel_overlay.name = "PBBillboardCarousel"
	carousel_overlay.visible = false
	carousel_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Styling
	var sbox := StyleBoxFlat.new()
	sbox.bg_color = Color(0.1, 0.12, 0.16, 0.92)
	sbox.set_corner_radius_all(10)
	sbox.set_border_width_all(2)
	sbox.border_color = Color(0.2, 0.85, 1.0, 0.8)
	sbox.content_margin_left = 16
	sbox.content_margin_right = 16
	sbox.content_margin_top = 10
	sbox.content_margin_bottom = 12
	carousel_overlay.add_theme_stylebox_override("panel", sbox)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	carousel_overlay.add_child(vbox)

	_carousel_title_label = Label.new()
	_carousel_title_label.text = "SELECT BILLBOARD TEXTURE"
	_carousel_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_carousel_title_label.add_theme_color_override("font_color", Color(0.2, 0.9, 1.0))
	_carousel_title_label.add_theme_font_size_override("font_size", 13)
	vbox.add_child(_carousel_title_label)

	var hint_lbl := Label.new()
	hint_lbl.text = "Drag or Move Mouse Horizontally to Scroll • Release / Click to Confirm"
	hint_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_lbl.add_theme_color_override("font_color", Color(0.7, 0.78, 0.85))
	hint_lbl.add_theme_font_size_override("font_size", 11)
	vbox.add_child(hint_lbl)

	_carousel_card_container = HBoxContainer.new()
	_carousel_card_container.alignment = BoxContainer.ALIGNMENT_CENTER
	_carousel_card_container.add_theme_constant_override("separation", 12)
	vbox.add_child(_carousel_card_container)

	_carousel_active_name_label = Label.new()
	_carousel_active_name_label.text = ""
	_carousel_active_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_carousel_active_name_label.add_theme_color_override("font_color", Color(1.0, 0.88, 0.2))
	_carousel_active_name_label.add_theme_font_size_override("font_size", 12)
	vbox.add_child(_carousel_active_name_label)

	host_control.add_child(carousel_overlay)
	_position_carousel(host_control)

func _position_carousel(host: Control) -> void:
	if carousel_overlay == null:
		return
	var h_size := host.size
	carousel_overlay.custom_minimum_size = Vector2(460, 140)
	var x := (h_size.x - 460) * 0.5
	var y := h_size.y - 180
	carousel_overlay.position = Vector2(maxf(10.0, x), maxf(10.0, y))

func show_carousel(host_control: Control = null) -> void:
	if host_control != null and carousel_overlay == null:
		setup_carousel_overlay(host_control)
	if carousel_overlay != null:
		if host_control != null:
			_position_carousel(host_control)
		carousel_overlay.visible = true
		update_carousel_ui()

func hide_carousel() -> void:
	if carousel_overlay != null:
		carousel_overlay.visible = false

func update_carousel_ui() -> void:
	if _carousel_card_container == null:
		return

	for c in _carousel_card_container.get_children():
		c.queue_free()

	if available_textures.is_empty():
		return

	var count := available_textures.size()
	selected_texture_idx = posmod(int(round(scroll_offset)), count)
	selected_texture = available_textures[selected_texture_idx]

	if _carousel_active_name_label != null and selected_texture != null:
		var fn := selected_texture.resource_path.get_file()
		_carousel_active_name_label.text = "Selected: %s (%d / %d)" % [fn, selected_texture_idx + 1, count]

	# Render 5 cards: offsets -2, -1, 0, +1, +2 relative to selected_texture_idx
	for offset in range(-2, 3):
		var idx := posmod(selected_texture_idx + offset, count)
		var tex := available_textures[idx]
		var is_center := (offset == 0)

		var card := PanelContainer.new()
		var card_style := StyleBoxFlat.new()
		card_style.set_corner_radius_all(6)

		if is_center:
			card_style.bg_color = Color(0.2, 0.85, 1.0, 0.28)
			card_style.set_border_width_all(2)
			card_style.border_color = Color(0.2, 0.9, 1.0, 0.95)
			card.custom_minimum_size = Vector2(74, 74)
		else:
			card_style.bg_color = Color(0.14, 0.16, 0.2, 0.65)
			card_style.set_border_width_all(1)
			card_style.border_color = Color(0.3, 0.35, 0.42, 0.5)
			card.custom_minimum_size = Vector2(58, 58)

		card.add_theme_stylebox_override("panel", card_style)

		var trect := TextureRect.new()
		trect.texture = tex
		trect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		trect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		trect.custom_minimum_size = card.custom_minimum_size
		card.add_child(trect)

		_carousel_card_container.add_child(card)

# ==============================================================================
# Viewport Input Handling
# ==============================================================================

func handle_input(camera: Camera3D, event: InputEvent, surface_hit: Dictionary, host_control: Control) -> int:
	const PASS := 0
	const STOP := 1

	if state == State.INACTIVE:
		return PASS

	if carousel_overlay == null and host_control != null:
		setup_carousel_overlay(host_control)

	if event is InputEventKey and event.pressed:
		var k := event as InputEventKey
		if k.keycode == KEY_ESCAPE:
			abort()
			return STOP

	match state:
		State.ARMED:
			if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
				if event.pressed:
					if surface_hit.is_empty():
						return PASS
					press_surface_point = surface_hit["point"]
					press_surface_normal = surface_hit["normal"]
					press_screen_pos = event.position
					_press_pending = true

					if last_texture == null:
						# No previous texture -> click triggers click-mode carousel
						is_hold_mode = false
						state = State.TEXTURE_SELECT
						show_carousel(host_control)
						state_changed.emit(state)
						return STOP
					return STOP

				else:
					# LMB Released
					if _press_pending:
						_press_pending = false
						# Clean single click -> create sprite with last_texture and enter RAISE
						selected_texture = last_texture
						_start_raise_phase(camera)
						return STOP

			elif event is InputEventMouseMotion and _press_pending:
				var dist: float = event.position.distance_to(press_screen_pos)
				if dist >= DRAG_THRESHOLD:
					_press_pending = false
					# Click-and-drag -> open hold-mode carousel
					is_hold_mode = true
					state = State.TEXTURE_SELECT
					show_carousel(host_control)
					state_changed.emit(state)
					return STOP

		State.TEXTURE_SELECT:
			if event is InputEventMouseMotion:
				# Drag or move mouse left/right smoothly scrolls textures
				scroll_offset += event.relative.x * 0.018
				update_carousel_ui()
				return STOP

			elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
				if is_hold_mode and not event.pressed:
					# Release LMB confirms in hold mode
					last_texture = selected_texture
					hide_carousel()
					_start_raise_phase(camera)
					return STOP
				elif not is_hold_mode and event.pressed:
					# Click confirms in click mode
					last_texture = selected_texture
					hide_carousel()
					_start_raise_phase(camera)
					return STOP

		State.RAISE:
			if event is InputEventMouseMotion:
				# Mouse up increases elevation, mouse down decreases
				elevation = maxf(0.0, elevation - event.relative.y * 0.012)
				if grid != null and grid.enabled:
					elevation = grid.snap_val(elevation)
				_update_raise_transform(camera)
				return STOP

			elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
				# Click locks elevation and facing angle -> enter SCALE phase
				if preview_node != null:
					locked_basis = preview_node.global_transform.basis if preview_node.is_inside_tree() else preview_node.transform.basis
				else:
					locked_basis = Basis.IDENTITY
				scale_start_x = event.position.x
				scale_factor = 1.0
				state = State.SCALE
				state_changed.emit(state)
				return STOP

		State.SCALE:
			if event is InputEventMouseMotion:
				var delta_x: float = event.position.x - scale_start_x
				var s := maxf(0.05, 1.0 + delta_x * 0.01)
				if grid != null and grid.enabled:
					s = maxf(0.1, grid.snap_val(s))
				scale_factor = s
				_update_scale_transform()
				return STOP

			elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
				# Click confirms scale -> finalize placement
				finalize_placement()
				return STOP

	return PASS

# ==============================================================================
# Placement Phases Execution
# ==============================================================================

func _start_raise_phase(camera: Camera3D) -> void:
	state = State.RAISE
	elevation = 0.0
	_spawn_preview_node()
	_update_raise_transform(camera)
	state_changed.emit(state)

func _spawn_preview_node() -> void:
	if preview_node != null and is_instance_valid(preview_node):
		if preview_node.get_parent() != null:
			preview_node.get_parent().remove_child(preview_node)
		preview_node.queue_free()
		preview_node = null

	var scene_root: Node = scene_root_override
	if scene_root == null and plugin != null and plugin.has_method("get_editor_interface"):
		scene_root = plugin.get_editor_interface().get_edited_scene_root()
	preview_node = PBMesh.new()
	preview_node.name = "Billboard_Sprite"

	# Build upright standing quad
	var md := PBShapeGenerators.create_sprite(base_width, base_height)
	var mat := create_billboard_material(selected_texture, lit, billboard)
	md.materials = [mat]
	preview_node.pb_mesh_data = md

	if cast_shadow:
		preview_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	else:
		preview_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	preview_node.collider_type = PBMesh.ColliderType.OFF

	if scene_root != null:
		scene_root.add_child(preview_node)
		preview_node.owner = scene_root

	preview_node.rebuild()

func _update_raise_transform(camera: Camera3D) -> void:
	if preview_node == null or not is_instance_valid(preview_node):
		return

	var sprite_pos := press_surface_point + press_surface_normal * elevation

	# Orient to face camera: upright along normal, facing camera in surface plane
	var fwd := Vector3.FORWARD
	if camera != null:
		var cam_to_sprite := camera.global_position - sprite_pos
		var planar_cam := cam_to_sprite - press_surface_normal * cam_to_sprite.dot(press_surface_normal)
		if planar_cam.length_squared() > 0.0001:
			fwd = planar_cam.normalized()

	var right := press_surface_normal.cross(fwd).normalized()
	var basis := Basis(right, press_surface_normal, fwd)

	if preview_node.is_inside_tree():
		preview_node.global_transform = Transform3D(basis, sprite_pos)
	else:
		preview_node.transform = Transform3D(basis, sprite_pos)

func _update_scale_transform() -> void:
	if preview_node == null or not is_instance_valid(preview_node):
		return
	var cur_pos := preview_node.global_transform.origin if preview_node.is_inside_tree() else preview_node.transform.origin
	var scaled_basis := locked_basis.scaled(Vector3(scale_factor, scale_factor, scale_factor))
	if preview_node.is_inside_tree():
		preview_node.global_transform = Transform3D(scaled_basis, cur_pos)
	else:
		preview_node.transform = Transform3D(scaled_basis, cur_pos)
func finalize_placement() -> void:
	if preview_node == null or not is_instance_valid(preview_node):
		abort()
		return

	var node := preview_node
	preview_node = null
	state = State.INACTIVE

	var final_w := base_width * scale_factor
	var final_h := base_height * scale_factor

	# Update mesh data shape bookkeeping
	if node.pb_mesh_data != null:
		node.pb_mesh_data.shape_id = &"sprite"
		node.pb_mesh_data.shape_params = {
			"width": final_w,
			"height": final_h,
			"lit": 1.0 if lit else 0.0,
			"cast_shadow": 1.0 if cast_shadow else 0.0,
			"billboard": 1.0 if billboard else 0.0,
		}
		node.pb_mesh_data.shape_edited = false

	if selected_texture != null:
		node.set_meta("sprite_texture_path", selected_texture.resource_path)

	var scene_root: Node = null
	if plugin != null and plugin.has_method("get_editor_interface"):
		scene_root = plugin.get_editor_interface().get_edited_scene_root()

	if plugin != null and plugin.has_method("get_undo_redo"):
		var undo = plugin.get_undo_redo()
		if undo != null and scene_root != null:
			undo.create_action("Add Billboard Sprite", UndoRedo.MERGE_DISABLE, node)
			undo.add_do_method(plugin, "_attach_detached", node, scene_root)
			undo.add_do_method(plugin, "_own_node", node)
			undo.add_do_reference(node)
			undo.add_undo_method(plugin, "_detach_node", node)
			undo.commit_action()
		else:
			if node.get_parent() == null and scene_root != null:
				scene_root.add_child(node)
				node.owner = scene_root
	else:
		if node.get_parent() == null and scene_root != null:
			scene_root.add_child(node)
			node.owner = scene_root

	if plugin != null and plugin.has_method("get_editor_interface"):
		var sel := plugin.get_editor_interface().get_selection()
		if sel != null:
			sel.clear()
			sel.add_node(node)

	state_changed.emit(state)
	sprite_placed.emit(node)

# ==============================================================================
# Helper Material Factory
# ==============================================================================

static func create_billboard_material(tex: Texture2D, is_lit: bool, is_billboard: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	if is_lit:
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	else:
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	if is_billboard:
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	else:
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED

	return mat
