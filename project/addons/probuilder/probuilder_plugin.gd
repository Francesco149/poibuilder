@tool
extends EditorPlugin
class_name ProBuilderPlugin

# ==============================================================================
# Core Systems
# ==============================================================================

var logger: PBLogger = PBLogger.new()
var editor: PBEditor = PBEditor.new()
var overlay: PBOverlay = PBOverlay.new()

# ==============================================================================
# Rect Selection State
# ==============================================================================

## Whether a rect-drag selection is in progress.
var _is_rect_selecting: bool = false

## Start point of the rect selection drag (screen coords).
var _rect_start: Vector2 = Vector2.ZERO

## Current end point of the rect selection drag.
var _rect_end: Vector2 = Vector2.ZERO

# ==============================================================================
# Tool Drag State
# ==============================================================================

## Whether an active tool drag session has begun.
var _tool_drag_begun: bool = false

## Whether the mouse has moved far enough (>4px) during a tool drag to apply live preview.
var _is_moving: bool = false

## Mouse press position for drag distance calculation.
var _mouse_press_pos: Vector2 = Vector2.ZERO
# ==============================================================================
# UI Components
# ==============================================================================

var debug_dock_panel: PBDebugDock
var debug_dock: Control
var toolbar: PBToolbar

# ==============================================================================
# Plugin Lifecycle
# ==============================================================================

func _get_plugin_name() -> String:
	return "ProBuilder"

func _enter_tree():
	logger.info("plugin", "ProBuilder plugin entering tree")

	# Wire up subsystems
	editor.logger = logger
	overlay.logger = logger

	# Connect editor signals
	editor.active_mesh_changed.connect(_on_active_mesh_changed)
	editor.select_mode_changed.connect(_on_select_mode_changed)
	editor.element_selection_changed.connect(_on_element_selection_changed)

	# Register custom type
	add_custom_type(
		"PBMesh",
		"MeshInstance3D",
		preload("res://addons/probuilder/core/pb_mesh.gd"),
		preload("res://addons/probuilder/icons/pb_mesh_icon.svg") if FileAccess.file_exists("res://addons/probuilder/icons/pb_mesh_icon.svg") else null
	)

	# Debug dock
	debug_dock_panel = preload("res://addons/probuilder/debug/pb_debug_dock.tscn").instantiate()
	debug_dock_panel.logger = logger
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, debug_dock_panel)
	debug_dock = debug_dock_panel

	# Mode toolbar (added to 3D viewport header)
	toolbar = PBToolbar.new()
	toolbar.editor = editor
	toolbar.deactivate()
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, toolbar)

	# Listen for selection changes
	var selection: EditorSelection = get_editor_interface().get_selection()
	selection.selection_changed.connect(_on_selection_changed)

	logger.info("plugin", "ProBuilder plugin initialized")

func _exit_tree():
	if logger:
		logger.info("plugin", "ProBuilder plugin exiting tree")

	# Disconnect selection
	var selection: EditorSelection = get_editor_interface().get_selection()
	if selection.selection_changed.is_connected(_on_selection_changed):
		selection.selection_changed.disconnect(_on_selection_changed)

	# Clean up overlay
	overlay.detach()

	# Remove toolbar
	if toolbar:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, toolbar)
		toolbar.queue_free()
		toolbar = null

	# Remove debug dock
	if debug_dock:
		remove_control_from_docks(debug_dock)
		debug_dock.queue_free()
		debug_dock = null

	# Remove custom type
	remove_custom_type("PBMesh")

# ==============================================================================
# EditorPlugin Overrides
# ==============================================================================

func _handles(object: Object) -> bool:
	return object is PBMesh

func _edit(object: Object) -> void:
	if object is PBMesh:
		editor.active_mesh = object as PBMesh
	else:
		editor.active_mesh = null

func _make_visible(visible: bool) -> void:
	if not visible:
		editor.active_mesh = null

func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if not editor.is_editing():
		return AFTER_GUI_INPUT_PASS

	# Mode hotkeys (matching ProBuilder: H for vertex, J for edge, K for face)
	if event is InputEventKey and event.pressed and not event.echo:
		var key_event: InputEventKey = event as InputEventKey
		match key_event.keycode:
			KEY_W:
				if not key_event.ctrl_pressed and not key_event.alt_pressed:
					editor.active_tool = PBToolMove.new()
					return AFTER_GUI_INPUT_STOP
			KEY_Q:
				if not key_event.ctrl_pressed and not key_event.alt_pressed:
					editor.active_tool = null
					return AFTER_GUI_INPUT_STOP
			KEY_H:
				editor.select_mode = PBEditor.SelectMode.VERTEX
				return AFTER_GUI_INPUT_STOP
			KEY_J:
				editor.select_mode = PBEditor.SelectMode.EDGE
				return AFTER_GUI_INPUT_STOP
			KEY_K:
				editor.select_mode = PBEditor.SelectMode.FACE
				return AFTER_GUI_INPUT_STOP
			KEY_ESCAPE:
				editor.active_mesh = null
				return AFTER_GUI_INPUT_STOP
			KEY_A:
				# Ctrl+A = Select All, Ctrl+Shift+A or Ctrl+I = Invert
				if key_event.ctrl_pressed:
					if key_event.shift_pressed:
						editor.selection.invert_selection(editor.select_mode)
					else:
						editor.selection.select_all(editor.select_mode)
					return AFTER_GUI_INPUT_STOP
			KEY_D:
				# Ctrl+D = Deselect All
				if key_event.ctrl_pressed:
					editor.selection.clear_all()
					return AFTER_GUI_INPUT_STOP
			KEY_EQUAL:
				# Ctrl+= (Numpad Plus) = Grow Selection
				if key_event.ctrl_pressed:
					editor.selection.grow_selection(editor.select_mode)
					return AFTER_GUI_INPUT_STOP
			KEY_MINUS:
				# Ctrl+- = Shrink Selection
				if key_event.ctrl_pressed:
					editor.selection.shrink_selection(editor.select_mode)
					return AFTER_GUI_INPUT_STOP

	# Element manipulation & picking via mouse click / drag
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_mouse_press_pos = mb.position
				_rect_start = mb.position
				_rect_end = mb.position
				_is_rect_selecting = false
				_is_moving = false
				_tool_drag_begun = false

				# If active tool is present and we have a nonempty selection, attempt begin_drag
				if editor.active_tool != null and not editor.selection.is_empty():
					var ray_origin: Vector3 = camera.project_ray_origin(mb.position)
					var ray_dir: Vector3 = camera.project_ray_normal(mb.position)
					if editor.active_tool.begin_drag(ray_origin, ray_dir):
						_tool_drag_begun = true
						return AFTER_GUI_INPUT_STOP

				# Fall through to default click/rect selection
				return AFTER_GUI_INPUT_PASS
			else:
				# Mouse button released
				if _tool_drag_begun:
					var was_moving: bool = _is_moving
					_tool_drag_begun = false
					_is_moving = false
					if was_moving:
						var undo_mgr: Object = get_undo_redo() if Engine.is_editor_hint() and has_method("get_undo_redo") else null
						editor.active_tool.finish_drag(undo_mgr)
						update_overlays()
						return AFTER_GUI_INPUT_STOP
					else:
						# Click without drag (released before 4px): cancel drag preview and do click pick
						editor.active_tool.cancel_drag()
						_do_click_pick(camera, mb)
						update_overlays()
						return AFTER_GUI_INPUT_STOP

				if _is_rect_selecting:
					# Rect selection complete
					_is_rect_selecting = false
					_do_rect_select(camera, mb)
					update_overlays()
					return AFTER_GUI_INPUT_STOP
				else:
					# Single click pick
					_do_click_pick(camera, mb)
					return AFTER_GUI_INPUT_STOP

	# Track mouse drag for tool manipulation or rect selection
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		var mm: InputEventMouseMotion = event as InputEventMouseMotion
		if _tool_drag_begun:
			if not _is_moving:
				var drag_dist: float = _mouse_press_pos.distance_to(mm.position)
				if drag_dist > 4.0:
					_is_moving = true
			if _is_moving:
				var ray_origin: Vector3 = camera.project_ray_origin(mm.position)
				var ray_dir: Vector3 = camera.project_ray_normal(mm.position)
				editor.active_tool.update_drag(ray_origin, ray_dir)
				update_overlays()
			return AFTER_GUI_INPUT_STOP

		_rect_end = mm.position
		if not _is_rect_selecting:
			var drag_dist: float = _rect_start.distance_to(_rect_end)
			if drag_dist > 4.0:
				_is_rect_selecting = true
		if _is_rect_selecting:
			update_overlays()
			return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_PASS

func _forward_3d_draw_over_viewport(viewport_control: Control):
	# Draw rect selection marquee
	if _is_rect_selecting:
		var rect := Rect2(_rect_start, _rect_end - _rect_start).abs()
		viewport_control.draw_rect(rect, Color(0.0, 0.824, 0.937, 0.15), true)
		viewport_control.draw_rect(rect, Color(0.0, 0.824, 0.937, 0.6), false, 1.0)

# ==============================================================================
# Click Picking
# ==============================================================================

func _do_click_pick(camera: Camera3D, event: InputEventMouseButton) -> void:
	var mesh: PBMesh = editor.active_mesh
	if mesh == null or mesh.pb_mesh_data == null:
		return

	var shift_held: bool = event.shift_pressed
	var ctrl_held: bool = event.ctrl_pressed

	match editor.select_mode:
		PBEditor.SelectMode.FACE:
			_pick_face(camera, event.position, shift_held, ctrl_held)
		PBEditor.SelectMode.EDGE:
			_pick_edge(camera, event.position, shift_held, ctrl_held)
		PBEditor.SelectMode.VERTEX:
			_pick_vertex(camera, event.position, shift_held, ctrl_held)

func _pick_face(camera: Camera3D, screen_pos: Vector2, shift: bool, ctrl: bool) -> void:
	var mesh: PBMesh = editor.active_mesh
	var ray_origin: Vector3 = camera.project_ray_origin(screen_pos)
	var ray_dir: Vector3 = camera.project_ray_normal(screen_pos)
	var result: PBPicking.FacePickResult = PBPicking.pick_face(
		mesh.pb_mesh_data, mesh.global_transform, ray_origin, ray_dir)

	if result.face_index < 0:
		# Miss — clear unless shift/ctrl held
		if not shift and not ctrl:
			editor.selection.clear_faces()
		return

	if ctrl:
		# Ctrl-click = remove
		editor.selection.remove_face(result.face_index)
	elif shift:
		# Shift-click = toggle
		editor.selection.toggle_face(result.face_index)
	else:
		# Plain click = replace selection
		editor.selection.set_faces(PackedInt32Array([result.face_index]))

func _pick_edge(camera: Camera3D, screen_pos: Vector2, shift: bool, ctrl: bool) -> void:
	var mesh: PBMesh = editor.active_mesh
	var result: PBPicking.EdgePickResult = PBPicking.pick_edge(
		mesh.pb_mesh_data, mesh.global_transform, screen_pos, camera)

	if result.edge == null:
		if not shift and not ctrl:
			editor.selection.clear_edges()
		return

	if ctrl:
		editor.selection.remove_edge(result.edge)
	elif shift:
		editor.selection.toggle_edge(result.edge)
	else:
		var edges: Array[PBEdge] = [result.edge]
		editor.selection.set_edges(edges)

func _pick_vertex(camera: Camera3D, screen_pos: Vector2, shift: bool, ctrl: bool) -> void:
	var mesh: PBMesh = editor.active_mesh
	var result: PBPicking.VertexPickResult = PBPicking.pick_vertex(
		mesh.pb_mesh_data, mesh.global_transform, screen_pos, camera)

	if result.common_index < 0:
		if not shift and not ctrl:
			editor.selection.clear_vertices()
		return

	if ctrl:
		editor.selection.remove_vertex(result.common_index)
	elif shift:
		editor.selection.toggle_vertex(result.common_index)
	else:
		editor.selection.set_vertices(PackedInt32Array([result.common_index]))

# ==============================================================================
# Rect Selection
# ==============================================================================

func _do_rect_select(camera: Camera3D, event: InputEventMouseButton) -> void:
	var mesh: PBMesh = editor.active_mesh
	if mesh == null or mesh.pb_mesh_data == null:
		return

	var rect := Rect2(_rect_start, _rect_end - _rect_start).abs()
	var shift_held: bool = event.shift_pressed
	var ctrl_held: bool = event.ctrl_pressed

	match editor.select_mode:
		PBEditor.SelectMode.FACE:
			var faces: PackedInt32Array = PBPicking.pick_faces_in_rect(
				mesh.pb_mesh_data, mesh.global_transform, rect, camera)
			if ctrl_held:
				for fi in faces:
					editor.selection.remove_face(fi)
			elif shift_held:
				for fi in faces:
					editor.selection.add_face(fi)
			else:
				editor.selection.set_faces(faces)
		PBEditor.SelectMode.EDGE:
			var edges: Array[PBEdge] = PBPicking.pick_edges_in_rect(
				mesh.pb_mesh_data, mesh.global_transform, rect, camera)
			if ctrl_held:
				for edge in edges:
					editor.selection.remove_edge(edge)
			elif shift_held:
				for edge in edges:
					editor.selection.add_edge(edge)
			else:
				editor.selection.set_edges(edges)
		PBEditor.SelectMode.VERTEX:
			var verts: PackedInt32Array = PBPicking.pick_vertices_in_rect(
				mesh.pb_mesh_data, mesh.global_transform, rect, camera)
			if ctrl_held:
				for sv_idx in verts:
					editor.selection.remove_vertex(sv_idx)
			elif shift_held:
				for sv_idx in verts:
					editor.selection.add_vertex(sv_idx)
			else:
				editor.selection.set_vertices(verts)

# ==============================================================================
# Object Selection Handling
# ==============================================================================

func _on_selection_changed() -> void:
	var selection: EditorSelection = get_editor_interface().get_selection()
	var nodes: Array[Node] = selection.get_selected_nodes()

	var pb_mesh: PBMesh = null
	for node in nodes:
		if node is PBMesh:
			pb_mesh = node as PBMesh
			break

	if pb_mesh != null:
		editor.active_mesh = pb_mesh
	# Note: _make_visible(false) handles deselection

# ==============================================================================
# Editor State Callbacks
# ==============================================================================

func _on_active_mesh_changed(mesh: PBMesh) -> void:
	if mesh != null:
		overlay.attach(mesh)
		overlay.rebuild(editor.select_mode, editor.selection)
		toolbar.activate()
	else:
		overlay.detach()
		toolbar.deactivate()
	update_overlays()

func _on_select_mode_changed(mode: PBEditor.SelectMode) -> void:
	# Clear element selection when mode changes (ProBuilder behavior)
	editor.selection.clear_all()
	overlay.rebuild(mode, editor.selection)
	update_overlays()

func _on_element_selection_changed() -> void:
	overlay.rebuild(editor.select_mode, editor.selection)
	update_overlays()
