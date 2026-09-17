## PBUvCanvas — 2D Interactive UV Canvas for PoiBuilder UV Editor.
##
## Provides a high-performance, zoomable, pannable 2D canvas for inspecting and
## selecting mesh texture coordinates (UV1 and UV2). Features:
## - Cursor-anchored zooming and middle-mouse / space-drag panning.
## - Dark slate canvas with adaptive grid and [0, 1] unit square boundary.
## - Material texture underlay with optional repeat tiling.
## - Wireframe rendering for vertices, edges, and faces from PBMeshData.
## - Element selection (Vertex, Edge, Face, Island) with marquee drag.
## - Bidirectional synchronization with the 3D scene selection.
@tool
class_name PBUvCanvas
extends Control

# ==============================================================================
# Signals
# ==============================================================================

## Emitted when element selection in UV space changes.
signal selection_changed

## Emitted when the user modifies UV coordinates (e.g. dragging in manual mode).
signal uv_modified(action_name: String)

## Emitted when the canvas zoom or pan changes.
signal view_changed(zoom: float, pan: Vector2)

## Emitted when the active 2D transform tool (Move, Rotate, Scale) changes.
signal tool_changed(tool_mode: PBUvGizmo.ToolMode)

## Emitted when the selection mode (Vertex, Edge, Face, Island) changes.
signal select_mode_changed(mode: SelectMode)

# ==============================================================================
# Constants & Enums
# ==============================================================================

enum SelectMode {
	VERTEX = 0,
	EDGE = 1,
	FACE = 2,
	ISLAND = 3,
}

enum UvChannel {
	UV1 = 0,
	UV2 = 1,
}

const MIN_ZOOM := 20.0
const MAX_ZOOM := 10000.0
const DEFAULT_ZOOM := 350.0

const COLOR_CANVAS_BG := Color(0.12, 0.13, 0.16, 1.0)
const COLOR_UNIT_BORDER := Color(0.38, 0.58, 0.88, 0.9)
const COLOR_GRID_MINOR := Color(0.24, 0.27, 0.32, 0.4)
const COLOR_GRID_MAJOR := Color(0.32, 0.38, 0.48, 0.65)
const COLOR_AXIS_U := Color(0.85, 0.35, 0.35, 0.85) # Red horizontal (V = 0)
const COLOR_AXIS_V := Color(0.35, 0.75, 0.45, 0.85) # Green vertical (U = 0)

const COLOR_FACE_UNSELECTED := Color(0.25, 0.45, 0.65, 0.08)
const COLOR_FACE_SELECTED := Color(1.0, 0.85, 0.20, 0.35)
const COLOR_FACE_HOVER := Color(0.20, 0.90, 1.00, 0.25)

const COLOR_EDGE_UNSELECTED := Color(0.55, 0.68, 0.80, 0.65)
const COLOR_EDGE_SELECTED := Color(1.0, 0.88, 0.20, 1.0)
const COLOR_EDGE_HOVER := Color(0.20, 0.90, 1.00, 1.0)

const COLOR_VERT_UNSELECTED := Color(0.85, 0.90, 0.95, 0.9)
const COLOR_VERT_SELECTED := Color(1.0, 0.88, 0.20, 1.0)
const COLOR_VERT_HOVER := Color(0.20, 0.90, 1.00, 1.0)

const COLOR_MARQUEE_FILL := Color(0.20, 0.75, 1.00, 0.15)
const COLOR_MARQUEE_BORDER := Color(0.30, 0.85, 1.00, 0.85)

# ==============================================================================
# View State
# ==============================================================================

## Pixels per UV unit. At zoom = 350, the [0, 1] unit square is 350x350 px.
var zoom: float = DEFAULT_ZOOM:
	set(val):
		var clamped := clampf(val, MIN_ZOOM, MAX_ZOOM)
		if not is_equal_approx(zoom, clamped):
			zoom = clamped
			queue_redraw()
			view_changed.emit(zoom, pan_offset)

## Offset from control center in pixels.
var pan_offset: Vector2 = Vector2.ZERO:
	set(val):
		if pan_offset != val:
			pan_offset = val
			queue_redraw()
			view_changed.emit(zoom, pan_offset)

## Current element selection mode in UV editor.
var select_mode: SelectMode = SelectMode.FACE:
	set(val):
		if select_mode != val:
			select_mode = val
			hover_vert = -1
			hover_edge = Vector2i(-1, -1)
			hover_face = -1
			_convert_selection_to_mode(val)
			_update_gizmo_pivot()
			select_mode_changed.emit(val)
			queue_redraw()
## Target UV channel to display and edit.
var uv_channel: UvChannel = UvChannel.UV1:
	set(val):
		if uv_channel != val:
			uv_channel = val
			# Face indices are channel-independent (they index pb_mesh_data.faces),
			# so a face selection survives a channel switch — that is what keeps
			# the UV2 splat underlay following the selected face. Vertex/edge
			# selections refer to per-channel UV coordinates, so those reset.
			var had_vert_edge := not selected_verts.is_empty() or not selected_edges.is_empty()
			selected_verts.clear()
			selected_edges.clear()
			if had_vert_edge:
				selection_changed.emit()
				_update_gizmo_pivot()
			_update_preview_texture()
			queue_redraw()

## Display settings
var show_texture: bool = true:
	set(val):
		if show_texture != val:
			show_texture = val
			queue_redraw()

var show_texture_tiling: bool = false:
	set(val):
		if show_texture_tiling != val:
			show_texture_tiling = val
			queue_redraw()

var texture_opacity: float = 0.6:
	set(val):
		var clamped := clampf(val, 0.0, 1.0)
		if not is_equal_approx(texture_opacity, clamped):
			texture_opacity = clamped
			queue_redraw()

var grid_snap_step: float = 0.125: # 1/8 default
	set(val):
		if val > 0.0001:
			grid_snap_step = val
			if gizmo:
				gizmo.grid_snap_step = val
			queue_redraw()

var snap_enabled: bool = true:
	set(val):
		snap_enabled = val
		if gizmo:
			gizmo.snap_enabled = val

## 2D Transform gizmo instance for manipulating selected UVs
var gizmo: PBUvGizmo = PBUvGizmo.new()

## Active 2D transform tool (Move, Rotate, Scale)
var transform_tool: PBUvGizmo.ToolMode:
	get:
		return gizmo.tool_mode if gizmo != null else PBUvGizmo.ToolMode.MOVE
	set(val):
		if gizmo != null and gizmo.tool_mode != val:
			gizmo.tool_mode = val
			tool_changed.emit(val)
			queue_redraw()

## Optional UndoRedoManager reference
var undo_redo: Object = null:
	get:
		if _undo_redo != null:
			return _undo_redo
		if Engine.is_editor_hint():
			return EditorInterface.get_editor_undo_redo()
		return null
	set(val):
		_undo_redo = val
var _undo_redo: Object = null
# ==============================================================================
# Target Mesh Data
# ==============================================================================

## The currently edited PBMesh instance.
var active_mesh: PBMesh = null:
	set = set_active_mesh

## Cached reference texture for underlay.
var preview_texture: Texture2D = null:
	set(val):
		if preview_texture != val:
			preview_texture = val
			queue_redraw()

## Splat composite previews for the UV2 channel, keyed by material instance id.
## Each entry remembers the PBSplat.mask_state_version it was built from.
var _splat_preview_cache: Dictionary = {}

# Selection sets (keyed by integer indices)
var selected_faces: Dictionary = {}   # {face_idx: true}
var selected_verts: Dictionary = {}   # {vertex_idx: true}
var selected_edges: Dictionary = {}   # {Vector2i(min(a,b), max(a,b)): true}

# Hover state
var hover_vert: int = -1
var hover_edge: Vector2i = Vector2i(-1, -1)
var hover_face: int = -1

# Interaction state
var _is_panning: bool = false
var _pan_start_mouse: Vector2 = Vector2.ZERO
var _pan_start_offset: Vector2 = Vector2.ZERO

var _is_marquee: bool = false
var _marquee_start: Vector2 = Vector2.ZERO
var _marquee_current: Vector2 = Vector2.ZERO
var _marquee_add: bool = false

var _space_held: bool = false


# Gizmo drag interaction state
var _is_gizmo_dragging: bool = false
var _gizmo_drag_snapshot_uvs: PackedVector2Array = PackedVector2Array()
var _gizmo_drag_snapshot_mesh: PBMeshData = null
var _gizmo_affected_indices: Array[int] = []
# ==============================================================================
# Lifecycle
# ==============================================================================

func _init() -> void:
	name = "PBUvCanvas"
	clip_contents = true
	focus_mode = Control.FOCUS_ALL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	custom_minimum_size = Vector2(200, 150)

func _ready() -> void:
	mouse_entered.connect(func(): grab_focus())

# ==============================================================================
# Mesh & Selection Binding
# ==============================================================================

func set_active_mesh(mesh: PBMesh) -> void:
	if active_mesh == mesh:
		return
	if active_mesh != null and active_mesh.has_signal("mesh_rebuilt") and active_mesh.mesh_rebuilt.is_connected(_on_active_mesh_rebuilt):
		active_mesh.mesh_rebuilt.disconnect(_on_active_mesh_rebuilt)
	active_mesh = mesh
	if active_mesh != null and active_mesh.has_signal("mesh_rebuilt") and not active_mesh.mesh_rebuilt.is_connected(_on_active_mesh_rebuilt):
		active_mesh.mesh_rebuilt.connect(_on_active_mesh_rebuilt)
	_update_preview_texture()
	clear_selection()
	queue_redraw()

func _on_active_mesh_rebuilt() -> void:
	if not _is_gizmo_dragging:
		refresh_from_mesh()
func refresh_from_mesh() -> void:
	_update_preview_texture()
	_update_gizmo_pivot()
	queue_redraw()

func _update_preview_texture() -> void:
	if active_mesh == null or active_mesh.pb_mesh_data == null:
		preview_texture = null
		return

	# Candidate materials, most specific first: the selected face's material,
	# then the mesh's first material as fallback.
	var candidates: Array[Material] = []
	if not active_mesh.pb_mesh_data.materials.is_empty():
		if not selected_faces.is_empty():
			var first_face_idx: int = selected_faces.keys()[0]
			if first_face_idx >= 0 and first_face_idx < active_mesh.pb_mesh_data.faces.size():
				var f: PBFace = active_mesh.pb_mesh_data.faces[first_face_idx]
				var face_mat := active_mesh.pb_mesh_data.get_face_material(f)
				if face_mat != null:
					candidates.append(face_mat)
		candidates.append(active_mesh.pb_mesh_data.materials[0])

	var albedo_tex: Texture2D = null
	var splat_mat: ShaderMaterial = null
	for mat in candidates:
		if mat == null:
			continue
		if splat_mat == null and PBSplat.is_splat_material(mat):
			splat_mat = mat
		if albedo_tex == null:
			albedo_tex = _material_albedo_texture(mat)

	# UV2 shows the painted splat composite when the material is a splat stack;
	# otherwise (and for UV1) fall back to the plain albedo texture.
	preview_texture = null
	if uv_channel == UvChannel.UV2 and splat_mat != null:
		preview_texture = _get_splat_preview(splat_mat)
	if preview_texture == null:
		preview_texture = albedo_tex

## Extracts the albedo/base texture a material presents, including splat
## ShaderMaterials (whose base texture is a shader parameter, not `albedo_texture`).
static func _material_albedo_texture(mat: Material) -> Texture2D:
	if mat is StandardMaterial3D:
		return (mat as StandardMaterial3D).albedo_texture
	if mat is ORMMaterial3D:
		return (mat as ORMMaterial3D).albedo_texture
	if mat is ShaderMaterial and PBSplat.is_splat_material(mat):
		return (mat as ShaderMaterial).get_shader_parameter("base_texture") as Texture2D
	return null

## Returns the cached UV2 splat composite for `splat_mat`, rebuilding it when
## the material's masks have changed (PBSplat.mask_state_version moved).
func _get_splat_preview(splat_mat: ShaderMaterial) -> Texture2D:
	var id := splat_mat.get_instance_id()
	var entry: Dictionary = _splat_preview_cache.get(id, {})
	if not entry.is_empty() and entry.get("version", -1) == PBSplat.mask_state_version:
		return entry.get("texture")
	var tex := PBSplat.build_preview_texture(splat_mat)
	if tex == null:
		return null
	if _splat_preview_cache.size() > 12:
		_splat_preview_cache.clear()
	_splat_preview_cache[id] = {"version": PBSplat.mask_state_version, "texture": tex}
	return tex

# ==============================================================================
# Coordinate Space Conversions
# ==============================================================================

## Converts normalized UV coordinate (0..1) to local screen pixel position.
func uv_to_screen(uv: Vector2) -> Vector2:
	return (size * 0.5) + pan_offset + (uv - Vector2(0.5, 0.5)) * zoom

## Converts local screen pixel position to normalized UV coordinate.
func screen_to_uv(screen_pos: Vector2) -> Vector2:
	return Vector2(0.5, 0.5) + (screen_pos - (size * 0.5) - pan_offset) / zoom

# ==============================================================================
# View Navigation (Pan & Zoom)
# ==============================================================================

## Centers the [0, 1] unit square in the viewport.
func frame_unit_square() -> void:
	pan_offset = Vector2.ZERO
	var fit_dim: float = minf(size.x, size.y)
	if fit_dim > 20.0:
		zoom = fit_dim * 0.75
	else:
		zoom = DEFAULT_ZOOM
	queue_redraw()

## Centers the current selection (or all UVs if empty) in the viewport.
func frame_selection() -> void:
	var bounds := get_selection_bounds()
	if bounds.size.x < 0.0001 and bounds.size.y < 0.0001:
		bounds = get_all_uv_bounds()
	if bounds.size.x < 0.0001 and bounds.size.y < 0.0001:
		frame_unit_square()
		return

	var center_uv := bounds.get_center()
	pan_offset = -(center_uv - Vector2(0.5, 0.5)) * zoom

	var fit_scale_x := (size.x * 0.75) / maxf(0.001, bounds.size.x)
	var fit_scale_y := (size.y * 0.75) / maxf(0.001, bounds.size.y)
	zoom = clampf(minf(fit_scale_x, fit_scale_y), MIN_ZOOM, MAX_ZOOM)
	queue_redraw()

func get_selection_bounds() -> Rect2:
	var uvs := get_uv_array()
	if uvs.is_empty():
		return Rect2()

	var min_p := Vector2(INF, INF)
	var max_p := Vector2(-INF, -INF)
	var count := 0

	match select_mode:
		SelectMode.VERTEX:
			for v_idx: int in selected_verts:
				if v_idx >= 0 and v_idx < uvs.size():
					var uv := uvs[v_idx]
					min_p = min_p.min(uv)
					max_p = max_p.max(uv)
					count += 1
		SelectMode.EDGE:
			for edge: Vector2i in selected_edges:
				for v_idx: int in [edge.x, edge.y]:
					if v_idx >= 0 and v_idx < uvs.size():
						var uv := uvs[v_idx]
						min_p = min_p.min(uv)
						max_p = max_p.max(uv)
						count += 1
		SelectMode.FACE, SelectMode.ISLAND:
			if active_mesh and active_mesh.pb_mesh_data:
				for f_idx: int in selected_faces:
					if f_idx >= 0 and f_idx < active_mesh.pb_mesh_data.faces.size():
						var face: PBFace = active_mesh.pb_mesh_data.faces[f_idx]
						for v_idx in face.get_distinct_indexes():
							if v_idx >= 0 and v_idx < uvs.size():
								var uv := uvs[v_idx]
								min_p = min_p.min(uv)
								max_p = max_p.max(uv)
								count += 1

	if count == 0:
		return Rect2()
	return Rect2(min_p, max_p - min_p)

func get_all_uv_bounds() -> Rect2:
	var uvs := get_uv_array()
	if uvs.is_empty():
		return Rect2(Vector2.ZERO, Vector2.ONE)

	var min_p := Vector2(INF, INF)
	var max_p := Vector2(-INF, -INF)
	for uv in uvs:
		min_p = min_p.min(uv)
		max_p = max_p.max(uv)
	return Rect2(min_p, max_p - min_p)

func get_uv_array() -> PackedVector2Array:
	if active_mesh == null or active_mesh.pb_mesh_data == null:
		return PackedVector2Array()
	if uv_channel == UvChannel.UV2:
		return active_mesh.pb_mesh_data.textures1
	return active_mesh.pb_mesh_data.textures0

# ==============================================================================
# Input & Event Handling
# ==============================================================================

func _gui_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.keycode == KEY_SPACE:
			_space_held = key_event.pressed
			mouse_default_cursor_shape = Control.CURSOR_DRAG if _space_held else Control.CURSOR_ARROW
			accept_event()
			return
		if not key_event.pressed and key_event.keycode == KEY_F:
			frame_selection()
			accept_event()
			return
		if not key_event.pressed and key_event.keycode == KEY_A and key_event.ctrl_pressed:
			select_all()
			accept_event()
			return
		if not key_event.pressed and key_event.keycode == KEY_W:
			transform_tool = PBUvGizmo.ToolMode.MOVE
			accept_event()
			return
		if not key_event.pressed and key_event.keycode == KEY_E:
			transform_tool = PBUvGizmo.ToolMode.ROTATE
			accept_event()
			return
		if not key_event.pressed and key_event.keycode == KEY_R:
			transform_tool = PBUvGizmo.ToolMode.SCALE
			accept_event()
			return

	# Mouse wheel zooming
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom_at(mb.position, 1.15)
			accept_event()
			return
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom_at(mb.position, 1.0 / 1.15)
			accept_event()
			return

		# Middle click pan or Space+LMB pan
		if (mb.button_index == MOUSE_BUTTON_MIDDLE) or (mb.button_index == MOUSE_BUTTON_LEFT and _space_held):
			if mb.pressed:
				_is_panning = true
				_pan_start_mouse = mb.position
				_pan_start_offset = pan_offset
				mouse_default_cursor_shape = Control.CURSOR_DRAG
			else:
				_is_panning = false
				mouse_default_cursor_shape = Control.CURSOR_DRAG if _space_held else Control.CURSOR_ARROW
			accept_event()
			return

		# Left click selection & marquee
		if mb.button_index == MOUSE_BUTTON_LEFT and not _space_held:
			if mb.pressed:
				if mb.double_click:
					_handle_double_click(mb.position, mb.shift_pressed)
				else:
					_handle_left_press(mb.position, mb.shift_pressed)
			else:
				_handle_left_release(mb.position)
			accept_event()
			return

	# Mouse motion
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _is_panning:
			pan_offset = _pan_start_offset + (mm.position - _pan_start_mouse)
			accept_event()
			return

		if _is_gizmo_dragging:
			var t := gizmo.apply_drag(mm.position, self, mm.shift_pressed, mm.ctrl_pressed)
			if not t.is_empty():
				_apply_gizmo_transform(t)
			queue_redraw()
			accept_event()
			return

		if _is_marquee:
			_marquee_current = mm.position
			queue_redraw()
			accept_event()
			return

		# Update hover highlight
		_update_hover(mm.position)
		accept_event()
		return

func _zoom_at(pivot_screen: Vector2, factor: float) -> void:
	var anchor_uv := screen_to_uv(pivot_screen)
	var new_zoom := clampf(zoom * factor, MIN_ZOOM, MAX_ZOOM)
	if is_equal_approx(new_zoom, zoom):
		return
	zoom = new_zoom
	var new_screen := uv_to_screen(anchor_uv)
	pan_offset += pivot_screen - new_screen

func has_selection() -> bool:
	return not selected_faces.is_empty() or not selected_verts.is_empty() or not selected_edges.is_empty()

func get_selected_vertex_indices() -> Array[int]:
	var result: Array[int] = []
	var seen: Dictionary = {}
	var uvs := get_uv_array()
	if uvs.is_empty():
		return result

	match select_mode:
		SelectMode.VERTEX:
			for v_idx: int in selected_verts:
				for c_idx in get_coincident_uv_vertices(v_idx):
					if c_idx >= 0 and c_idx < uvs.size() and not seen.has(c_idx):
						seen[c_idx] = true
						result.append(c_idx)
		SelectMode.EDGE:
			for edge: Vector2i in selected_edges:
				for ce in get_coincident_uv_edges(edge):
					for v_idx in [ce.x, ce.y]:
						for c_idx in get_coincident_uv_vertices(v_idx):
							if c_idx >= 0 and c_idx < uvs.size() and not seen.has(c_idx):
								seen[c_idx] = true
								result.append(c_idx)
		SelectMode.FACE:
			if active_mesh and active_mesh.pb_mesh_data:
				for f_idx: int in selected_faces:
					if f_idx >= 0 and f_idx < active_mesh.pb_mesh_data.faces.size():
						var face: PBFace = active_mesh.pb_mesh_data.faces[f_idx]
						for v_idx in face.get_distinct_indexes():
							for c_idx in get_coincident_uv_vertices(v_idx):
								if c_idx >= 0 and c_idx < uvs.size() and not seen.has(c_idx):
									seen[c_idx] = true
									result.append(c_idx)
		SelectMode.ISLAND:
			if active_mesh and active_mesh.pb_mesh_data:
				for f_idx: int in selected_faces:
					for ifi in _get_uv_island(f_idx):
						if ifi >= 0 and ifi < active_mesh.pb_mesh_data.faces.size():
							var face: PBFace = active_mesh.pb_mesh_data.faces[ifi]
							for v_idx in face.get_distinct_indexes():
								for c_idx in get_coincident_uv_vertices(v_idx):
									if c_idx >= 0 and c_idx < uvs.size() and not seen.has(c_idx):
										seen[c_idx] = true
										result.append(c_idx)
	return result

## Returns all vertex indices that share both the UV coordinate and 3D position of `v_idx` (sewn / stitched vertices).
## Two vertices are coincident/sewn if they belong to mesh_data.shared_textures or share a sewn 3D edge.
## Isolated corner coincidences (unconnected in UV space) are NOT sewn and not joined.
func get_coincident_uv_vertices(v_idx: int) -> Array[int]:
	var result: Array[int] = [v_idx]
	if active_mesh == null or active_mesh.pb_mesh_data == null:
		return result
	var mesh_data := active_mesh.pb_mesh_data
	var uvs := get_uv_array()
	if v_idx < 0 or v_idx >= uvs.size() or v_idx >= mesh_data.positions.size():
		return result

	# 1. Authoritative: check mesh_data.shared_textures
	if not mesh_data.shared_textures.is_empty():
		var lookup := mesh_data.get_shared_texture_lookup()
		if lookup.has(v_idx):
			var group_idx: int = lookup[v_idx]
			if group_idx >= 0 and group_idx < mesh_data.shared_textures.size():
				var sv: PBSharedVertex = mesh_data.shared_textures[group_idx]
				if sv != null:
					var out: Array[int] = []
					for vi in sv.indices:
						if vi >= 0 and vi < uvs.size():
							out.append(vi)
					return out
		return result

	# 2. If shared_textures is empty, only vertices sharing a full sewn edge
	# (both 3D endpoints coincident in both 3D and UV space) are considered coincident.
	var target_uv := uvs[v_idx]
	var target_pos := mesh_data.positions[v_idx]
	var f_v := _get_face_for_vertex(mesh_data, v_idx)
	if f_v == null:
		return result

	for i in range(uvs.size()):
		if i == v_idx or i >= mesh_data.positions.size():
			continue
		if uvs[i].distance_squared_to(target_uv) < 0.000001 and mesh_data.positions[i].distance_squared_to(target_pos) < 0.0001:
			var f_i := _get_face_for_vertex(mesh_data, i)
			if f_i == null or f_i == f_v:
				continue
			var shares_sewn_edge := false
			for e_v in f_v.get_edges():
				var other_v: int = e_v.b if e_v.a == v_idx else (e_v.a if e_v.b == v_idx else -1)
				if other_v == -1 or other_v >= uvs.size() or other_v >= mesh_data.positions.size():
					continue
				var p_ov: Vector3 = mesh_data.positions[other_v]
				var uv_ov: Vector2 = uvs[other_v]
				for e_i in f_i.get_edges():
					var other_i: int = e_i.b if e_i.a == i else (e_i.a if e_i.b == i else -1)
					if other_i == -1 or other_i >= uvs.size() or other_i >= mesh_data.positions.size():
						continue
					if mesh_data.positions[other_i].distance_squared_to(p_ov) < 0.0001:
						if uvs[other_i].distance_squared_to(uv_ov) < 0.000001:
							shares_sewn_edge = true
							break
				if shares_sewn_edge:
					break
			if shares_sewn_edge:
				result.append(i)

	return result

func _get_face_for_vertex(mesh_data: PBMeshData, v: int) -> PBFace:
	for face in mesh_data.faces:
		if face != null and face.get_distinct_indexes().has(v):
			return face
	return null

## Returns all edges that share both UV endpoints and 3D endpoints with `edge` (sewn / stitched edges).
func get_coincident_uv_edges(edge: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = [edge]
	if active_mesh == null or active_mesh.pb_mesh_data == null:
		return result
	var mesh_data := active_mesh.pb_mesh_data
	var uvs := get_uv_array()
	if edge.x >= uvs.size() or edge.y >= uvs.size() or edge.x >= mesh_data.positions.size() or edge.y >= mesh_data.positions.size():
		return result

	var ea_v1 := get_coincident_uv_vertices(edge.x)
	var ea_v2 := get_coincident_uv_vertices(edge.y)

	var v1_set: Dictionary = {}
	for v in ea_v1:
		v1_set[v] = true
	var v2_set: Dictionary = {}
	for v in ea_v2:
		v2_set[v] = true

	for face in mesh_data.faces:
		for fe in face.get_edges():
			if (v1_set.has(fe.a) and v2_set.has(fe.b)) or (v1_set.has(fe.b) and v2_set.has(fe.a)):
				var pe := Vector2i(mini(fe.a, fe.b), maxi(fe.a, fe.b))
				if not result.has(pe):
					result.append(pe)

	return result

func _update_gizmo_pivot() -> void:
	if gizmo == null:
		return
	var uvs := get_uv_array()
	if uvs.is_empty():
		return

	if select_mode == SelectMode.VERTEX and not selected_verts.is_empty():
		if selected_verts.size() == 1:
			var v_idx: int = selected_verts.keys()[0]
			if v_idx >= 0 and v_idx < uvs.size():
				gizmo.pivot_uv = uvs[v_idx]
				return
		var min_p := Vector2(INF, INF)
		var max_p := Vector2(-INF, -INF)
		for v_idx: int in selected_verts:
			if v_idx >= 0 and v_idx < uvs.size():
				min_p = min_p.min(uvs[v_idx])
				max_p = max_p.max(uvs[v_idx])
		gizmo.pivot_uv = (min_p + max_p) * 0.5
		return
	elif select_mode == SelectMode.EDGE and not selected_edges.is_empty():
		var min_p := Vector2(INF, INF)
		var max_p := Vector2(-INF, -INF)
		for edge: Vector2i in selected_edges:
			for v_idx in [edge.x, edge.y]:
				if v_idx >= 0 and v_idx < uvs.size():
					min_p = min_p.min(uvs[v_idx])
					max_p = max_p.max(uvs[v_idx])
		gizmo.pivot_uv = (min_p + max_p) * 0.5
		return
	elif not selected_faces.is_empty():
		var bounds := get_selection_bounds()
		if bounds.size.x > 0.00001 or bounds.size.y > 0.00001:
			gizmo.pivot_uv = bounds.get_center()
		elif active_mesh and active_mesh.pb_mesh_data:
			var f_idx: int = selected_faces.keys()[0]
			if f_idx >= 0 and f_idx < active_mesh.pb_mesh_data.faces.size():
				var f: PBFace = active_mesh.pb_mesh_data.faces[f_idx]
				var distinct := f.get_distinct_indexes()
				if not distinct.is_empty() and distinct[0] < uvs.size():
					gizmo.pivot_uv = uvs[distinct[0]]

func _convert_selection_to_mode(new_mode: SelectMode) -> void:
	match new_mode:
		SelectMode.VERTEX:
			if not selected_faces.is_empty() and active_mesh and active_mesh.pb_mesh_data:
				for fi in selected_faces:
					var f_idx: int = int(fi)
					if f_idx >= 0 and f_idx < active_mesh.pb_mesh_data.faces.size():
						var f: PBFace = active_mesh.pb_mesh_data.faces[f_idx]
						for v in f.get_distinct_indexes():
							selected_verts[v] = true
			elif not selected_edges.is_empty():
				for edge: Vector2i in selected_edges:
					selected_verts[edge.x] = true
					selected_verts[edge.y] = true
			selected_faces.clear()
			selected_edges.clear()
		SelectMode.EDGE:
			if not selected_faces.is_empty() and active_mesh and active_mesh.pb_mesh_data:
				for fi in selected_faces:
					var f_idx: int = int(fi)
					if f_idx >= 0 and f_idx < active_mesh.pb_mesh_data.faces.size():
						var f: PBFace = active_mesh.pb_mesh_data.faces[f_idx]
						for e in f.get_edges():
							selected_edges[Vector2i(mini(e.a, e.b), maxi(e.a, e.b))] = true
			selected_faces.clear()
			selected_verts.clear()
		SelectMode.FACE, SelectMode.ISLAND:
			selected_verts.clear()
			selected_edges.clear()
func _apply_gizmo_transform(t: Dictionary) -> void:
	if uv_channel == UvChannel.UV2:
		return # Splat masks are splat-system-owned; the UV editor never writes UV2.
	if active_mesh == null or active_mesh.pb_mesh_data == null or _gizmo_affected_indices.is_empty():
		return

	var mesh_data: PBMeshData = active_mesh.pb_mesh_data
	var target_arr: PackedVector2Array = mesh_data.textures1 if uv_channel == UvChannel.UV2 else mesh_data.textures0
	var vc: int = mesh_data.positions.size()
	if target_arr.size() != vc:
		target_arr.resize(vc)

	PBUvOps._ensure_faces_manual_for_vertices(mesh_data, _gizmo_affected_indices)

	var t_type: String = t.get("type", "")
	match t_type:
		"move":
			var delta: Vector2 = t.get("delta", Vector2.ZERO)
			for vi in _gizmo_affected_indices:
				if vi >= 0 and vi < _gizmo_drag_snapshot_uvs.size() and vi < target_arr.size():
					target_arr[vi] = _gizmo_drag_snapshot_uvs[vi] + delta
		"rotate":
			var angle_deg: float = t.get("angle", 0.0)
			var pivot: Vector2 = t.get("pivot", Vector2.ZERO)
			var rad := deg_to_rad(angle_deg)
			for vi in _gizmo_affected_indices:
				if vi >= 0 and vi < _gizmo_drag_snapshot_uvs.size() and vi < target_arr.size():
					var orig := _gizmo_drag_snapshot_uvs[vi]
					target_arr[vi] = pivot + (orig - pivot).rotated(rad)
		"scale":
			var scale_factor: Vector2 = t.get("scale", Vector2.ONE)
			var pivot: Vector2 = t.get("pivot", Vector2.ZERO)
			for vi in _gizmo_affected_indices:
				if vi >= 0 and vi < _gizmo_drag_snapshot_uvs.size() and vi < target_arr.size():
					var orig := _gizmo_drag_snapshot_uvs[vi]
					target_arr[vi] = pivot + Vector2((orig.x - pivot.x) * scale_factor.x, (orig.y - pivot.y) * scale_factor.y)

	if uv_channel == UvChannel.UV2:
		mesh_data.textures1 = target_arr
	else:
		mesh_data.textures0 = target_arr

	active_mesh.rebuild()

func _commit_gizmo_drag() -> void:
	if not _is_gizmo_dragging:
		return
	_is_gizmo_dragging = false
	gizmo.commit_drag()
	_update_gizmo_pivot()

	if active_mesh and active_mesh.pb_mesh_data and _gizmo_drag_snapshot_mesh:
		var cmd := CmdMeshOp.new(active_mesh.pb_mesh_data, "Transform UVs", active_mesh)
		cmd.before = _gizmo_drag_snapshot_mesh
		cmd.capture_after()
		var ur: Object = undo_redo
		if ur != null:
			cmd.add_to_undo_manager(ur)
		_gizmo_drag_snapshot_mesh = null

	uv_modified.emit("Transform UVs")
	queue_redraw()

func _update_hover(mouse_pos: Vector2) -> void:
	var old_h_v := hover_vert
	var old_h_e := hover_edge
	var old_h_f := hover_face

	hover_vert = -1
	hover_edge = Vector2i(-1, -1)
	hover_face = -1

	var uvs := get_uv_array()
	if uvs.is_empty() or active_mesh == null or active_mesh.pb_mesh_data == null:
		if old_h_v != hover_vert or old_h_e != hover_edge or old_h_f != hover_face:
			queue_redraw()
		return

	const PICK_RADIUS_PX := 8.0
	var mouse_uv := screen_to_uv(mouse_pos)

	match select_mode:
		SelectMode.VERTEX:
			var best_dist := PICK_RADIUS_PX
			for i in range(uvs.size()):
				var p_screen := uv_to_screen(uvs[i])
				var d := p_screen.distance_to(mouse_pos)
				if d < best_dist:
					best_dist = d
					hover_vert = i

		SelectMode.EDGE:
			var best_dist := PICK_RADIUS_PX
			for face in active_mesh.pb_mesh_data.faces:
				for edge in face.get_edges():
					if edge.a < uvs.size() and edge.b < uvs.size():
						var sa := uv_to_screen(uvs[edge.a])
						var sb := uv_to_screen(uvs[edge.b])
						var d := _point_to_segment_distance(mouse_pos, sa, sb)
						if d < best_dist:
							best_dist = d
							hover_edge = Vector2i(mini(edge.a, edge.b), maxi(edge.a, edge.b))

		SelectMode.FACE, SelectMode.ISLAND:
			for fi in range(active_mesh.pb_mesh_data.faces.size()):
				var face: PBFace = active_mesh.pb_mesh_data.faces[fi]
				if _is_point_in_face_uv(face, mouse_uv, uvs):
					hover_face = fi
					break

	if old_h_v != hover_vert or old_h_e != hover_edge or old_h_f != hover_face:
		queue_redraw()

	if uv_channel == UvChannel.UV1 and has_selection() and not _is_panning and not _is_marquee:
		if gizmo and gizmo.update_hover(mouse_pos, self):
			queue_redraw()
# ==============================================================================
# Selection Logic
# ==============================================================================

func clear_selection() -> void:
	selected_faces.clear()
	selected_verts.clear()
	selected_edges.clear()
	queue_redraw()
	selection_changed.emit()

	_update_gizmo_pivot()
func select_all() -> void:
	var uvs := get_uv_array()
	if uvs.is_empty() or active_mesh == null or active_mesh.pb_mesh_data == null:
		return

	match select_mode:
		SelectMode.VERTEX:
			for i in range(uvs.size()):
				selected_verts[i] = true
		SelectMode.EDGE:
			for face in active_mesh.pb_mesh_data.faces:
				for edge in face.get_edges():
					selected_edges[Vector2i(mini(edge.a, edge.b), maxi(edge.a, edge.b))] = true
		SelectMode.FACE, SelectMode.ISLAND:
			for i in range(active_mesh.pb_mesh_data.faces.size()):
				selected_faces[i] = true

	queue_redraw()
	selection_changed.emit()
	_update_gizmo_pivot()

func _handle_left_press(mouse_pos: Vector2, is_shift: bool) -> void:
	_update_hover(mouse_pos)

	# UV2 (splat masks) is a read-only debug view: select to inspect, but the
	# gizmo never appears and transforms are refused (see _apply_gizmo_transform).
	if has_selection() and not is_shift and uv_channel == UvChannel.UV1:
		var gizmo_hit := gizmo.hit_test(mouse_pos, self)
		if gizmo_hit != PBUvGizmo.HandleType.NONE:
			_is_gizmo_dragging = true
			_gizmo_drag_snapshot_uvs = get_uv_array().duplicate()
			_gizmo_affected_indices = get_selected_vertex_indices()
			if active_mesh and active_mesh.pb_mesh_data:
				_gizmo_drag_snapshot_mesh = PBCommand.copy_mesh_data(active_mesh.pb_mesh_data)
			gizmo.begin_drag(gizmo_hit, mouse_pos, self)
			queue_redraw()
			return
	var hit := false
	match select_mode:
		SelectMode.VERTEX:
			if hover_vert >= 0:
				hit = true
				selected_faces.clear()
				selected_edges.clear()
				var coin := get_coincident_uv_vertices(hover_vert)
				if is_shift:
					var any_sel := false
					for v in coin:
						if selected_verts.has(v):
							any_sel = true
							break
					if any_sel:
						for v in coin:
							selected_verts.erase(v)
					else:
						for v in coin:
							selected_verts[v] = true
				else:
					selected_verts.clear()
					for v in coin:
						selected_verts[v] = true

		SelectMode.EDGE:
			if hover_edge.x >= 0:
				hit = true
				selected_faces.clear()
				selected_verts.clear()
				var coin_edges := get_coincident_uv_edges(hover_edge)
				if is_shift:
					var any_sel := false
					for e in coin_edges:
						if selected_edges.has(e):
							any_sel = true
							break
					if any_sel:
						for e in coin_edges:
							selected_edges.erase(e)
					else:
						for e in coin_edges:
							selected_edges[e] = true
				else:
					selected_edges.clear()
					for e in coin_edges:
						selected_edges[e] = true
		SelectMode.FACE:
			if hover_face >= 0:
				hit = true
				selected_verts.clear()
				selected_edges.clear()
				if is_shift:
					if selected_faces.has(hover_face):
						selected_faces.erase(hover_face)
					else:
						selected_faces[hover_face] = true
				else:
					selected_faces.clear()
					selected_faces[hover_face] = true

		SelectMode.ISLAND:
			if hover_face >= 0:
				hit = true
				selected_verts.clear()
				selected_edges.clear()
				var island := _get_uv_island(hover_face)
				if is_shift:
					for fi in island:
						if selected_faces.has(fi):
							selected_faces.erase(fi)
						else:
							selected_faces[fi] = true
				else:
					selected_faces.clear()
					for fi in island:
						selected_faces[fi] = true
	if hit:
		_update_preview_texture()
		queue_redraw()
		selection_changed.emit()
		_update_gizmo_pivot()
	else:
		# Start marquee selection
		_is_marquee = true
		_marquee_start = mouse_pos
		_marquee_current = mouse_pos
		_marquee_add = is_shift
		if not is_shift:
			clear_selection()

func _handle_left_release(mouse_pos: Vector2) -> void:
	if _is_gizmo_dragging:
		_commit_gizmo_drag()
		return

	if _is_marquee:
		_is_marquee = false
		_marquee_current = mouse_pos
		_apply_marquee_selection()
		_update_gizmo_pivot()
		queue_redraw()
func _handle_double_click(mouse_pos: Vector2, is_shift: bool) -> void:
	_update_hover(mouse_pos)
	if hover_face >= 0:
		var island := _get_uv_island(hover_face)
		if not is_shift:
			selected_faces.clear()
		for fi in island:
			selected_faces[fi] = true
		_update_preview_texture()
		queue_redraw()
		selection_changed.emit()
		_update_gizmo_pivot()

func _apply_marquee_selection() -> void:
	var rect := Rect2(_marquee_start, _marquee_current - _marquee_start).abs()
	if rect.size.x < 3.0 and rect.size.y < 3.0:
		return

	var uvs := get_uv_array()
	if uvs.is_empty() or active_mesh == null or active_mesh.pb_mesh_data == null:
		return

	if not _marquee_add:
		selected_verts.clear()
		selected_edges.clear()
		selected_faces.clear()

	match select_mode:
		SelectMode.VERTEX:
			for i in range(uvs.size()):
				if rect.has_point(uv_to_screen(uvs[i])):
					selected_verts[i] = true

		SelectMode.EDGE:
			for face in active_mesh.pb_mesh_data.faces:
				for edge in face.get_edges():
					if edge.a < uvs.size() and edge.b < uvs.size():
						var sa := uv_to_screen(uvs[edge.a])
						var sb := uv_to_screen(uvs[edge.b])
						if rect.has_point(sa) and rect.has_point(sb):
							selected_edges[Vector2i(mini(edge.a, edge.b), maxi(edge.a, edge.b))] = true

		SelectMode.FACE, SelectMode.ISLAND:
			for fi in range(active_mesh.pb_mesh_data.faces.size()):
				var face: PBFace = active_mesh.pb_mesh_data.faces[fi]
				var all_in := true
				for idx in face.get_distinct_indexes():
					if idx >= uvs.size() or not rect.has_point(uv_to_screen(uvs[idx])):
						all_in = false
						break
				if all_in:
					if select_mode == SelectMode.ISLAND:
						for ifi in _get_uv_island(fi):
							selected_faces[ifi] = true
					else:
						selected_faces[fi] = true

	_update_preview_texture()
	selection_changed.emit()
	_update_gizmo_pivot()

func _get_uv_island(seed_face_idx: int) -> Array[int]:
	var result: Array[int] = []
	if active_mesh == null or active_mesh.pb_mesh_data == null:
		return result
	var mesh_data := active_mesh.pb_mesh_data
	var faces := mesh_data.faces
	if seed_face_idx < 0 or seed_face_idx >= faces.size():
		return result

	var uvs := get_uv_array()
	if uvs.is_empty():
		return [seed_face_idx]

	# Build UV edge adjacency graph.
	# Two faces belong to the same UV island if they share a sewn edge in UV space
	# (both 3D endpoints match in 3D and in UV space).
	var edge_to_faces: Dictionary = {}

	for fi in range(faces.size()):
		var f: PBFace = faces[fi]
		for e in f.get_edges():
			if e.a >= uvs.size() or e.b >= uvs.size() or e.a >= mesh_data.positions.size() or e.b >= mesh_data.positions.size():
				continue
			var sv_a: int = mesh_data.get_shared_vertex_index(e.a)
			var sv_b: int = mesh_data.get_shared_vertex_index(e.b)
			if sv_a < 0: sv_a = e.a
			if sv_b < 0: sv_b = e.b
			var sv_min := mini(sv_a, sv_b)
			var sv_max := maxi(sv_a, sv_b)

			var q_a := _quantize_uv(uvs[e.a])
			var q_b := _quantize_uv(uvs[e.b])
			var q_min := q_a if (q_a.x < q_b.x or (q_a.x == q_b.x and q_a.y <= q_b.y)) else q_b
			var q_max := q_b if q_min == q_a else q_a

			var edge_key := "%d_%d_%d_%d_%d_%d" % [sv_min, sv_max, q_min.x, q_min.y, q_max.x, q_max.y]
			if not edge_to_faces.has(edge_key):
				edge_to_faces[edge_key] = []
			edge_to_faces[edge_key].append(fi)

	var visited := {}
	var queue: Array[int] = [seed_face_idx]
	visited[seed_face_idx] = true

	while not queue.is_empty():
		var curr_fi := queue.pop_front()
		result.append(curr_fi)
		var curr_face: PBFace = faces[curr_fi]
		for e in curr_face.get_edges():
			if e.a >= uvs.size() or e.b >= uvs.size() or e.a >= mesh_data.positions.size() or e.b >= mesh_data.positions.size():
				continue
			var sv_a: int = mesh_data.get_shared_vertex_index(e.a)
			var sv_b: int = mesh_data.get_shared_vertex_index(e.b)
			if sv_a < 0: sv_a = e.a
			if sv_b < 0: sv_b = e.b
			var sv_min := mini(sv_a, sv_b)
			var sv_max := maxi(sv_a, sv_b)

			var q_a := _quantize_uv(uvs[e.a])
			var q_b := _quantize_uv(uvs[e.b])
			var q_min := q_a if (q_a.x < q_b.x or (q_a.x == q_b.x and q_a.y <= q_b.y)) else q_b
			var q_max := q_b if q_min == q_a else q_a

			var edge_key := "%d_%d_%d_%d_%d_%d" % [sv_min, sv_max, q_min.x, q_min.y, q_max.x, q_max.y]
			for neighbor_fi: int in edge_to_faces.get(edge_key, []):
				if not visited.has(neighbor_fi):
					visited[neighbor_fi] = true
					queue.append(neighbor_fi)

	return result

func _quantize_uv(v: Vector2) -> Vector2i:
	return Vector2i(int(round(v.x * 10000.0)), int(round(v.y * 10000.0)))

func _point_to_segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len2 := ab.length_squared()
	if len2 < 0.00001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	var proj := a + ab * t
	return p.distance_to(proj)

func _is_point_in_face_uv(face: PBFace, uv: Vector2, uvs: PackedVector2Array) -> bool:
	var indices := face.get_indexes()
	if indices.size() < 3:
		return false

	# Point in triangle test across face triangles
	for i in range(0, indices.size(), 3):
		var ia: int = indices[i]
		var ib: int = indices[i + 1]
		var ic: int = indices[i + 2]
		if ia < uvs.size() and ib < uvs.size() and ic < uvs.size():
			if _point_in_triangle(uv, uvs[ia], uvs[ib], uvs[ic]):
				return true
	return false

func _point_in_triangle(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var d1 := (p.x - b.x) * (a.y - b.y) - (a.x - b.x) * (p.y - b.y)
	var d2 := (p.x - c.x) * (b.y - c.y) - (b.x - c.x) * (p.y - c.y)
	var d3 := (p.x - a.x) * (c.y - a.y) - (c.x - a.x) * (p.y - a.y)
	var has_neg := (d1 < 0) or (d2 < 0) or (d3 < 0)
	var has_pos := (d1 > 0) or (d2 > 0) or (d3 > 0)
	return not (has_neg and has_pos)

# ==============================================================================
# Rendering
# ==============================================================================

func _draw() -> void:
	# 1. Background
	draw_rect(Rect2(Vector2.ZERO, size), COLOR_CANVAS_BG)

	# 2. Grid & Axes
	_draw_grid()

	# 3. Texture Underlay
	_draw_texture_underlay()

	# 4. Unit Square Boundary [0, 1]
	_draw_unit_boundary()

	# 5. Mesh UV Geometry
	_draw_uv_geometry()

	# 6. Marquee Box
	if _is_marquee:
		var rect := Rect2(_marquee_start, _marquee_current - _marquee_start).abs()
		draw_rect(rect, COLOR_MARQUEE_FILL)
		draw_rect(rect, COLOR_MARQUEE_BORDER, false, 1.0)

	# 7. 2D Transform Gizmo (UV1 only — UV2 is the read-only splat view)
	if uv_channel == UvChannel.UV1 and has_selection() and not _is_marquee:
		gizmo.draw(self)

	# 8. Read-only banner on the UV2 splat view
	if uv_channel == UvChannel.UV2:
		var font := ThemeDB.fallback_font
		if font != null:
			draw_string(font, Vector2(8, size.y - 8),
					"UV2 — splat masks (read-only debug view; paint in the viewport to edit)",
					HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.65, 0.78, 0.95, 0.85))

func _draw_grid() -> void:
	var tl_uv := screen_to_uv(Vector2.ZERO)
	var br_uv := screen_to_uv(size)

	var min_u := floorf(minf(tl_uv.x, br_uv.x))
	var max_u := ceilf(maxf(tl_uv.x, br_uv.x))
	var min_v := floorf(minf(tl_uv.y, br_uv.y))
	var max_v := ceilf(maxf(tl_uv.y, br_uv.y))

	# Adaptive minor lines
	var step := grid_snap_step
	var screen_step := step * zoom
	while screen_step < 12.0:
		step *= 2.0
		screen_step = step * zoom

	# Draw minor grid lines
	var curr_u := floorf(min_u / step) * step
	while curr_u <= max_u:
		var is_int := is_equal_approx(curr_u, roundf(curr_u))
		if not is_int:
			var p1 := uv_to_screen(Vector2(curr_u, min_v))
			var p2 := uv_to_screen(Vector2(curr_u, max_v))
			draw_line(p1, p2, COLOR_GRID_MINOR, 1.0)
		curr_u += step

	var curr_v := floorf(min_v / step) * step
	while curr_v <= max_v:
		var is_int := is_equal_approx(curr_v, roundf(curr_v))
		if not is_int:
			var p1 := uv_to_screen(Vector2(min_u, curr_v))
			var p2 := uv_to_screen(Vector2(max_u, curr_v))
			draw_line(p1, p2, COLOR_GRID_MINOR, 1.0)
		curr_v += step

	# Draw major grid lines (integer units)
	for u_int in range(int(min_u), int(max_u) + 1):
		var p1 := uv_to_screen(Vector2(float(u_int), min_v))
		var p2 := uv_to_screen(Vector2(float(u_int), max_v))
		var col := COLOR_AXIS_V if u_int == 0 else COLOR_GRID_MAJOR
		var width := 1.5 if u_int == 0 else 1.0
		draw_line(p1, p2, col, width)

	for v_int in range(int(min_v), int(max_v) + 1):
		var p1 := uv_to_screen(Vector2(min_u, float(v_int)))
		var p2 := uv_to_screen(Vector2(max_u, float(v_int)))
		var col := COLOR_AXIS_U if v_int == 0 else COLOR_GRID_MAJOR
		var width := 1.5 if v_int == 0 else 1.0
		draw_line(p1, p2, col, width)

func _draw_texture_underlay() -> void:
	if not show_texture or preview_texture == null:
		return

	var rect_01 := Rect2(uv_to_screen(Vector2.ZERO), Vector2(zoom, zoom))
	var mod_color := Color(1.0, 1.0, 1.0, texture_opacity)

	if show_texture_tiling:
		# Draw tiling in visible range
		var tl := screen_to_uv(Vector2.ZERO)
		var br := screen_to_uv(size)
		var min_x := int(floorf(minf(tl.x, br.x)))
		var max_x := int(ceilf(maxf(tl.x, br.x)))
		var min_y := int(floorf(minf(tl.y, br.y)))
		var max_y := int(ceilf(maxf(tl.y, br.y)))

		var dim_color := Color(1.0, 1.0, 1.0, texture_opacity * 0.35)
		for x in range(min_x, max_x):
			for y in range(min_y, max_y):
				if x == 0 and y == 0:
					continue
				var tile_rect := Rect2(uv_to_screen(Vector2(float(x), float(y))), Vector2(zoom, zoom))
				draw_texture_rect(preview_texture, tile_rect, false, dim_color)

	# Main [0, 1] texture tile
	draw_texture_rect(preview_texture, rect_01, false, mod_color)

func _draw_unit_boundary() -> void:
	var p00 := uv_to_screen(Vector2(0, 0))
	var p10 := uv_to_screen(Vector2(1, 0))
	var p11 := uv_to_screen(Vector2(1, 1))
	var p01 := uv_to_screen(Vector2(0, 1))

	var rect := Rect2(p00, Vector2(zoom, zoom))
	draw_rect(rect, COLOR_UNIT_BORDER, false, 2.0)

	# Corner coordinate labels
	var default_font := ThemeDB.fallback_font
	var font_size := 10
	if default_font != null:
		draw_string(default_font, p00 + Vector2(4, 12), "(0,0)", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.7, 0.8, 0.9, 0.75))
		draw_string(default_font, p11 + Vector2(-28, -4), "(1,1)", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.7, 0.8, 0.9, 0.75))

func _draw_uv_geometry() -> void:
	var uvs := get_uv_array()
	if uvs.is_empty() or active_mesh == null or active_mesh.pb_mesh_data == null:
		return

	var faces := active_mesh.pb_mesh_data.faces

	# Pass 1: Face fills (selected / hovered / unselected)
	for fi in range(faces.size()):
		var face: PBFace = faces[fi]
		var indices := face.get_indexes()
		if indices.size() < 3:
			continue

		var is_sel: bool = selected_faces.has(fi)
		var is_hov: bool = (hover_face == fi and (select_mode == SelectMode.FACE or select_mode == SelectMode.ISLAND))
		var fill_color := COLOR_FACE_SELECTED if is_sel else (COLOR_FACE_HOVER if is_hov else COLOR_FACE_UNSELECTED)

		# Draw triangles
		for t in range(0, indices.size(), 3):
			var ia: int = indices[t]
			var ib: int = indices[t + 1]
			var ic: int = indices[t + 2]
			if ia < uvs.size() and ib < uvs.size() and ic < uvs.size():
				var pts := PackedVector2Array([
					uv_to_screen(uvs[ia]),
					uv_to_screen(uvs[ib]),
					uv_to_screen(uvs[ic])
				])
				draw_polygon(pts, PackedColorArray([fill_color, fill_color, fill_color]))

	# Pass 2: Edges
	var drawn_edges: Dictionary = {}
	for fi in range(faces.size()):
		var face: PBFace = faces[fi]
		var face_selected: bool = selected_faces.has(fi)
		for edge in face.get_edges():
			if edge.a >= uvs.size() or edge.b >= uvs.size():
				continue
			var ekey := Vector2i(mini(edge.a, edge.b), maxi(edge.a, edge.b))
			if drawn_edges.has(ekey):
				continue
			drawn_edges[ekey] = true

			var is_edge_sel: bool = face_selected or selected_edges.has(ekey)
			var is_edge_hov: bool = (hover_edge == ekey and select_mode == SelectMode.EDGE)

			var col := COLOR_EDGE_SELECTED if is_edge_sel else (COLOR_EDGE_HOVER if is_edge_hov else COLOR_EDGE_UNSELECTED)
			var width := 2.0 if (is_edge_sel or is_edge_hov) else 1.0

			draw_line(uv_to_screen(uvs[edge.a]), uv_to_screen(uvs[edge.b]), col, width)

	# Pass 3: Vertices (drawn in VERTEX mode or when selected)
	if select_mode == SelectMode.VERTEX or not selected_verts.is_empty():
		for i in range(uvs.size()):
			var is_sel: bool = selected_verts.has(i)
			var is_hov: bool = (hover_vert == i and select_mode == SelectMode.VERTEX)
			var pt := uv_to_screen(uvs[i])

			var col := COLOR_VERT_SELECTED if is_sel else (COLOR_VERT_HOVER if is_hov else COLOR_VERT_UNSELECTED)
			var dot_size := 6.0 if (is_sel or is_hov) else 4.0
			var half := dot_size * 0.5
			draw_rect(Rect2(pt - Vector2(half, half), Vector2(dot_size, dot_size)), col)
			draw_rect(Rect2(pt - Vector2(half, half), Vector2(dot_size, dot_size)), Color(0.1, 0.1, 0.1, 0.8), false, 1.0)
