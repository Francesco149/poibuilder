@tool
extends EditorPlugin
class_name PoiBuilderPlugin

# ==============================================================================
# Core Systems
# ==============================================================================

var logger: PBLogger = PBLogger.new()
var editor: PBEditor = PBEditor.new()
var gizmo_plugin: PBGizmoPlugin = PBGizmoPlugin.new()
var tool_bridge: PBToolBridge = PBToolBridge.new()

## The plugin's own grid/snapping state (independent of the editor's 3D
## grid): element drags, the extrude gesture, and shape creation snap to it;
## `draw_on_grid` routes creation onto the grid plane at the grid elevation.
var grid: PBGrid = PBGrid.new()

## Live EditorSettings instance (null in headless test runs) — shortcut
## rebinds and grid persistence go through it.
var _settings: Object = null

## The viewport-rendered cyan grid (PBGridView injects a line mesh into the
## editor's 3D SubViewport; it never pollutes the edited scene).
var grid_view: PBGridView = PBGridView.new(grid)

# ==============================================================================
# UI Components
# ==============================================================================

var tool_overlay: PBToolOverlay
var toolbar: PBToolbar

## Hover id already reflected in the last gizmo redraw (avoids redundant
## update_gizmos calls on every motion event).
var _hover_drawn_last: int = -1

## Last cursor position + camera seen in the 3D viewport (presses AND motion).
## Lets a selection change (clicking another object) auto-pick the element
## under the exact click position.
var _last_mouse_pos: Vector2 = Vector2.ZERO
var _last_mouse_camera: Camera3D = null
## Time of the last press seen in the viewport, for click-recency checks.
var _last_press_msec: int = -10000

## Invisible anchor used to locate the 3D editor's toolbar containers; added
## to CONTAINER_SPATIAL_EDITOR_MENU, walked for the placement below, then
## removed again.
var _toolbar_anchor: Control = null

# ==============================================================================
# Plugin Lifecycle
# ==============================================================================

func _get_plugin_name() -> String:
	return "PoiBuilder"

## Bump when behavior changes so stale-build testing is detectable.
const VERSION := "0.9.34"

func _enter_tree():
	logger.info("plugin", "PoiBuilder v%s entering tree" % VERSION)

	# Receive 3D viewport input even with NOTHING selected: shape creation is
	# armed from the New Shape menu and must work before any PBMesh is in the
	# editing context (the engine otherwise only forwards viewport input to
	# plugins whose _handles() matches the currently edited object).
	set_input_event_forwarding_always_enabled()

	# Wire up subsystems
	editor.logger = logger
	gizmo_plugin.editor = editor
	gizmo_plugin.logger = logger
	gizmo_plugin.element_editor.editor = editor
	gizmo_plugin.element_editor.undo = get_undo_redo()
	gizmo_plugin.element_editor.grid = grid
	gizmo_plugin.shape_creator = shape_creator
	shape_creator.grid = grid
	tool_bridge.logger = logger
	tool_bridge.on_tool_selected = _on_engine_tool_selected

	# Register every plugin action into the editor's shortcut store (rebinds
	# live in Editor Settings → Shortcuts like native editor commands) and
	# load the persisted grid settings.
	_settings = get_editor_interface().get_editor_settings()
	PBActions.register(_settings, logger)
	_load_grid_settings()
	grid.changed.connect(_on_grid_changed)
	grid_view.logger = logger
	gizmo_plugin.grid_view = grid_view
	set_process(true)
	_attach_grid_view_scenario()

	# Connect editor signals
	editor.active_mesh_changed.connect(_on_active_mesh_changed)
	editor.select_mode_changed.connect(_on_select_mode_changed)
	editor.element_selection_changed.connect(_on_element_selection_changed)
	editor.orientation_space_changed.connect(_on_orientation_space_changed)
	editor.tool_mode_changed.connect(_on_tool_mode_changed)
	gizmo_plugin.element_editor.element_drag_updated.connect(_on_drag_updated)
	gizmo_plugin.element_editor.drag_topology_committed.connect(_on_drag_topology_committed)

	# Register custom type
	add_custom_type(
		"PBMesh",
		"MeshInstance3D",
		preload("res://addons/poibuilder/core/pb_mesh.gd"),
		preload("res://addons/poibuilder/icons/pb_mesh_icon.svg") if FileAccess.file_exists("res://addons/poibuilder/icons/pb_mesh_icon.svg") else null
	)

	# Register the node gizmo plugin — this is the native editor integration:
	# element picking, rubber-band selection, transform drags, snapping, and
	# undo are all driven by the editor through the subgizmo API.
	add_node_3d_gizmo_plugin(gizmo_plugin)

	# Persistent toolbar row UNDER the 3D scene toolbar (not inside it)
	toolbar = PBToolbar.new()
	toolbar.editor = editor
	toolbar.set_editing_active(false)
	toolbar.shape_requested.connect(_on_shape_requested)
	toolbar.operation_requested.connect(_on_operation_requested)
	toolbar.edit_params_requested.connect(_on_edit_params_requested)
	toolbar.overlay_toggled.connect(_on_overlay_toggled)
	toolbar.reset_panel_requested.connect(_on_reset_panel_requested)
	toolbar.grid_panel_toggled.connect(_on_grid_panel_toggled)
	_add_toolbar_row_below_3d_toolbar()
	toolbar.sync_grid(grid)

	# Tool overlay panel floating in the 3D viewport (readouts + params
	# modal; logging goes to the Godot console via PBLogger).
	tool_overlay = PBToolOverlay.new()
	tool_overlay.editor = editor
	tool_overlay.element_editor = gizmo_plugin.element_editor
	tool_overlay.visible = false
	tool_overlay.params_applied.connect(_on_params_applied)
	tool_overlay.params_canceled.connect(_on_params_canceled)
	tool_overlay.param_changed.connect(_on_param_changed)
	tool_overlay.grid_setting_changed.connect(_on_grid_ui_setting)
	tool_overlay.grid_reset_pressed.connect(_on_grid_reset)
	tool_overlay.sync_grid(grid)
	_add_overlay_to_3d_viewport(tool_overlay)

	# Half-size manipulator gizmos by default (the engine default of 80px is
	# huge next to PoiBuilder's element work). Respect user customization:
	# only applied while the setting still sits at the engine default.
	var editor_settings: EditorSettings = get_editor_interface().get_editor_settings()
	if editor_settings != null and editor_settings.has_setting("editors/3d/manipulator_gizmo_size") \
			and int(editor_settings.get_setting("editors/3d/manipulator_gizmo_size")) == 80:
		editor_settings.set_setting("editors/3d/manipulator_gizmo_size", 40)
		logger.info("plugin", "Manipulator gizmo size set 80 → 40 (Editor Settings > Editors > 3D to change)")

	# Bridge onto the editor's tool buttons (own tool modes; never the
	# universal gizmo). Needs the Node3DEditor, located via the toolbar walk.
	if toolbar_has_3d_editor():
		if tool_bridge.setup(_n3d_editor):
			logger.info("plugin", "Tool bridge attached to the editor's Move/Rotate/Scale buttons; Q/V pin out while editing")
		else:
			logger.warn("plugin", "Engine tool buttons not found — plugin tool modes will not drive the editor gizmo")
		# The engine's View-Grid menu + Snap Settings dialog live under the
		# editor's main tree, not the Node3DEditor subtree.
		tool_bridge.find_editor_menus(get_editor_interface().get_base_control())
	else:
		logger.warn("plugin", "Node3DEditor not found — tool bridge inactive")

	# Listen for selection changes
	var selection: EditorSelection = get_editor_interface().get_selection()
	selection.selection_changed.connect(_on_selection_changed)

	logger.info("plugin", "PoiBuilder plugin initialized")

func _exit_tree():
	if logger:
		logger.info("plugin", "PoiBuilder plugin exiting tree")

	# Drop a half-created shape preview (it never entered the undo history).
	if shape_creator.is_active():
		var node := shape_creator.preview_node
		shape_creator.reset()
		if node != null and is_instance_valid(node) and node.get_parent() != null:
			node.get_parent().remove_child(node)
			node.queue_free()

	# Disconnect selection
	var selection: EditorSelection = get_editor_interface().get_selection()
	if selection.selection_changed.is_connected(_on_selection_changed):
		selection.selection_changed.disconnect(_on_selection_changed)

	# Unregister the gizmo plugin
	remove_node_3d_gizmo_plugin(gizmo_plugin)

	# Restore the editor's tool buttons to stock behavior
	tool_bridge.teardown()

	# Remove toolbar
	if toolbar:
		if is_instance_valid(toolbar):
			toolbar.get_parent().remove_child(toolbar)
			toolbar.queue_free()
		toolbar = null
	if _toolbar_anchor:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _toolbar_anchor)
		_toolbar_anchor.queue_free()
		_toolbar_anchor = null

	# Remove overlay panel
	if tool_overlay:
		if is_instance_valid(tool_overlay):
			tool_overlay.get_parent().remove_child(tool_overlay)
			tool_overlay.queue_free()
		tool_overlay = null

	# Remove custom type
	remove_custom_type("PBMesh")
	if grid_view != null:
		grid_view.detach_scenario()

# ==============================================================================
# 3D Editor UI Placement
# ==============================================================================

var _n3d_editor: Node = null

func toolbar_has_3d_editor() -> bool:
	return _n3d_editor != null and is_instance_valid(_n3d_editor)

## Adds the toolbar as its own row below the 3D scene toolbar.
##
## The plugin API only offers a slot INSIDE the engine's toolbar flow, so a
## throwaway anchor control is added there and walked to find the real
## layout: anchor → context panel → HFlowContainer → toolbar MarginContainer
## → layout container. In Godot 4.7 the Node3DEditor IS the layout VBox
## (`VBoxContainer *vbc = this;` — get_class() still reports
## "Node3DEditor", so class-name searches for a VBox miss it and must never
## be used; one such search landed the row inside a hidden snap dialog).
## Inserting our row into the margin's parent container as a sibling AFTER
## the engine toolbar makes the engine's own VBox layout give us a
## full-width row and push the viewports down, whatever the version.
func _add_toolbar_row_below_3d_toolbar() -> void:
	_toolbar_anchor = Control.new()
	_toolbar_anchor.name = "PBToolbarAnchor"
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _toolbar_anchor)

	var flow: Node = _find_ancestor_of_class(_toolbar_anchor, "HFlowContainer")
	_n3d_editor = _find_ancestor_of_class(_toolbar_anchor, "Node3DEditor")
	var layout: Container = null
	if flow != null and flow.get_parent() is Container:
		var margin: Container = flow.get_parent()
		if margin.get_parent() is Container:
			layout = margin.get_parent()
	if layout == null or _n3d_editor == null:
		logger.warn("plugin", "Could not locate the 3D editor toolbar layout — toolbar placed inside the scene toolbar")
		return

	layout.add_child(toolbar)
	var margin: Node = flow.get_parent()
	layout.move_child(toolbar, mini(margin.get_index() + 1, layout.get_child_count() - 1))

	# The anchor's job (locating the layout) is done; remove it so it does
	# not leave an invisible entry in the context toolbar.
	remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _toolbar_anchor)
	_toolbar_anchor.queue_free()
	_toolbar_anchor = null
	logger.info("plugin", "Toolbar added as a row below the 3D scene toolbar")

## Parents `control` to the first 3D editor viewport so it floats over the
## scene. The Node3DEditorViewport is a plain Control (no container sort), so
## anchored children keep their place; being the last child, it also receives
## mouse events over its own rect before the viewport surface does.
func _add_overlay_to_3d_viewport(control: Control) -> void:
	var viewport: SubViewport = get_editor_interface().get_editor_viewport_3d(0)
	if viewport == null:
		logger.warn("plugin", "No 3D editor viewport — tool overlay not created")
		return
	var host := viewport.get_parent().get_parent()
	if host == null or not (host is Control):
		logger.warn("plugin", "Unexpected 3D viewport layout — tool overlay not created")
		return
	host.add_child(control)

func _find_ancestor_of_class(node: Node, klass: String) -> Node:
	var current := node
	while current != null:
		if current.get_class() == klass:
			return current
		current = current.get_parent()
	return null

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

## Keyboard + hover handling. Clicks pass through UNTOUCHED: the native editor
## viewport decides input priority itself — the transform gizmo wins over
## element picking (its hit test runs first), and presses that miss the gizmo
## fall through to subgizmo selection / rubber-band. Interception here is what
## broke gizmo drags in earlier rounds.
func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	# Feed the live cursor to the element editor — the extrude gesture drives
	# the cap distance from the mouse (see PBElementEditor.track_mouse).
	if event is InputEventMouseMotion:
		gizmo_plugin.element_editor.track_mouse(camera, event.position)

	# Shape creation owns the mouse while armed/dragging/modal (checked even
	# when nothing is selected — creation needs no editing context).
	if shape_creator.is_active():
		return _creation_input(camera, event)

	# Everything key-driven funnels through the rebindable action table BEFORE
	# the editing gate: grid keys work with nothing selected (the grid must be
	# adjustable before use), while action-internal context gates keep unbound
	# keys passing through as before.
	if event is InputEventKey and event.pressed and not event.echo:
		return _handle_action_key(event as InputEventKey)

	if not editor.is_editing():
		return AFTER_GUI_INPUT_PASS

	# Remember press positions: a following selection change (clicking another
	# object) auto-picks the element under this exact position.
	if event is InputEventMouseButton and event.pressed:
		_last_mouse_pos = event.position
		_last_mouse_camera = camera
		_last_press_msec = Time.get_ticks_msec()

	# Hover highlight: observe motion WITHOUT consuming it. The engine keeps
	# processing (camera nav, marquee, gizmo drags). Picking is skipped while
	# a button is held or a subgizmo drag is in flight.
	if event is InputEventMouseMotion and event.button_mask == 0 \
			and not gizmo_plugin.element_editor.drag_active:
		var node := editor.active_mesh
		if node != null and node.pb_mesh_data != null:
			_last_mouse_pos = event.position
			_last_mouse_camera = camera
			# Hover must never re-record the pick-side face (the element gizmo
			# stays locked to the side it was selected from).
			var id: int = gizmo_plugin.element_editor.pick_ray(
				node.pb_mesh_data, node.global_transform, camera, event.position, false)
			editor.hover_id = id
			if editor.hover_id != _hover_drawn_last:
				_hover_drawn_last = editor.hover_id
				node.update_gizmos()
			return AFTER_GUI_INPUT_PASS

	return AFTER_GUI_INPUT_PASS

## Maps a viewport keypress to a rebindable PoiBuilder action. Actions with
## an editing context consume the event (STOP); everything else PASSES so
## the engine's own shortcuts keep working untouched.
func _handle_action_key(key_event: InputEventKey) -> int:
	var grid_result := _handle_grid_action_key(key_event)
	if grid_result == AFTER_GUI_INPUT_STOP:
		return AFTER_GUI_INPUT_STOP
	var action := PBActions.action_for(key_event, _settings)
	if action == &"":
		return AFTER_GUI_INPUT_PASS
	var editing := editor.is_editing()
	var pb_context := editing or editor.active_mesh != null or shape_creator.is_active()
	match action:
		# Selection modes need a PoiBuilder context (if we consumed H/J/K with
		# nothing PoiBuilder-related active, scene-tree search fields would
		# lose the letters to a no-op).
		&"select_vertex":
			if not pb_context:
				return AFTER_GUI_INPUT_PASS
			editor.select_mode = PBEditor.SelectMode.VERTEX
		&"select_edge":
			if not pb_context:
				return AFTER_GUI_INPUT_PASS
			editor.select_mode = PBEditor.SelectMode.EDGE
		&"select_face":
			if not pb_context:
				return AFTER_GUI_INPUT_PASS
			editor.select_mode = PBEditor.SelectMode.FACE
		&"select_object":
			if not pb_context:
				return AFTER_GUI_INPUT_PASS
			editor.select_mode = PBEditor.SelectMode.OBJECT
		&"cycle_space":
			if not editing:
				return AFTER_GUI_INPUT_PASS
			editor.cycle_orientation_space()
		&"snap_selection":
			if not editing:
				return AFTER_GUI_INPUT_PASS
			_on_snap_selection_to_grid()
		_:
			# Mesh operation keys route into the toolbar ops pipeline; the
			# op itself validates the selection context.
			if not editing or not PBActions.OP_ACTION_TO_OPERATION.has(action):
				return AFTER_GUI_INPUT_PASS
			_on_operation_requested(PBActions.OP_ACTION_TO_OPERATION[action])
	return AFTER_GUI_INPUT_STOP

## Grid + snap toggles work in EVERY context (nothing selected, mid-drag of
## a new shape, editing) — the grid must be adjustable before and during
## use. toggle_snap is the exception: with no PoiBuilder context at all the
## engine's own Use Snap button keeps its Y binding.
func _handle_grid_action_key(key_event: InputEventKey) -> int:
	var action := PBActions.action_for(key_event, _settings)
	if action == &"":
		return AFTER_GUI_INPUT_PASS
	if action == &"toggle_snap":
		if editor.is_editing() or editor.active_mesh != null or shape_creator.is_active():
			grid.enabled = not grid.enabled
			return AFTER_GUI_INPUT_STOP
		return AFTER_GUI_INPUT_PASS
	elif action == &"toggle_on_grid":
		grid.draw_on_grid = not grid.draw_on_grid
	elif action == &"toggle_grid":
		grid.show_grid = not grid.show_grid
	elif action == &"subdiv_increase":
		grid.subdivisions_up()
	elif action == &"subdiv_decrease":
		grid.subdivisions_down()
	elif action == &"unit_increase":
		grid.unit_up()
	elif action == &"unit_decrease":
		grid.unit_down()
	elif action == &"grid_raise":
		grid.raise()
	elif action == &"grid_lower":
		grid.lower()
	elif action == &"grid_reset":
		grid.reset_origin()
	else:
		return AFTER_GUI_INPUT_PASS
	return AFTER_GUI_INPUT_STOP

# ==============================================================================
# Grid + Snapping (own grid, independent of the engine's 3D grid)
# ==============================================================================

## Persisted grid settings (Editor Settings keys; origin/elevation is
## session-only — a floating grid from yesterday's session would surprise).
const GRID_SETTING_PREFIX := "poibuilder/grid/"
const GRID_SETTING_KEYS := ["enabled", "unit", "subdivisions",
	"draw_on_grid", "show_grid", "rotate_step_deg"]

func _load_grid_settings() -> void:
	if _settings == null or not _settings.has_method("has_setting"):
		return
	for key in GRID_SETTING_KEYS:
		var path: String = GRID_SETTING_PREFIX + key
		if _settings.has_setting(path):
			grid.set(key, _settings.get_setting(path))
	_on_grid_changed()

func _on_grid_changed() -> void:
	if _settings != null and _settings.has_method("set_setting"):
		for key in GRID_SETTING_KEYS:
			_settings.set_setting(GRID_SETTING_PREFIX + key, grid.get(key))
	if toolbar != null:
		toolbar.sync_grid(grid)
	if tool_overlay != null:
		tool_overlay.sync_grid(grid)
	if logger != null:
		logger.info("grid", "unit=%s subdivs=%d step=%s snap=%s on_grid=%s show=%s elev=%s rot_step=%s" % [
			str(grid.unit), grid.subdivisions, str(grid.step()), str(grid.enabled),
			str(grid.draw_on_grid), str(grid.show_grid), str(grid.origin.y),
			str(grid.rotate_step_deg)])
	grid_view.mark_dirty()
	# Object-mode engine snap tracks live grid changes while a PBMesh is
	# selected (element modes never use it — see _update_editing_context).
	if editor.active_mesh != null and not editor.is_editing():
		tool_bridge.apply_engine_snap(grid.step(), grid.rotate_step_deg, grid.enabled)

## Quantizes every selected element's positions onto the world grid
## (ProBuilder/ProGrids "push to grid"): positions move, indexes unchanged —
## weld groups keep topology sound, undo is a full-mesh snapshot.
func _on_snap_selection_to_grid() -> void:
	if not editor.is_editing() or editor.active_mesh == null:
		return
	var mesh := editor.active_mesh
	var mesh_data: PBMeshData = mesh.pb_mesh_data
	if mesh_data == null:
		return
	var indices := PackedInt32Array()
	match editor.select_mode:
		PBEditor.SelectMode.VERTEX:
			for group_idx in editor.selection.selected_vertices:
				if group_idx >= 0 and group_idx < mesh_data.shared_vertices.size():
					var sv: PBSharedVertex = mesh_data.shared_vertices[group_idx]
					if sv != null:
						for idx: int in sv.indices:
							indices.append(idx)
		PBEditor.SelectMode.EDGE:
			indices = mesh_data.get_coincident_vertices_from_edges(editor.selection.selected_edges)
		PBEditor.SelectMode.FACE:
			indices = mesh_data.get_coincident_vertices_from_faces(editor.selection.selected_faces)
	if indices.is_empty():
		return
	var cmd := CmdMeshOp.new(mesh_data, "Snap Selection To Grid", mesh)
	if logger:
		cmd.logger = logger
	var basis := mesh.global_transform.basis
	var inv := basis.inverse()
	var moved := false
	for idx: int in indices:
		if idx < 0 or idx >= mesh_data.positions.size():
			continue
		var world: Vector3 = mesh.global_transform.origin + basis * mesh_data.positions[idx]
		var snapped := grid.snap_point(world)
		var local: Vector3 = inv * (snapped - mesh.global_transform.origin)
		if not (mesh_data.positions[idx] as Vector3).is_equal_approx(local):
			mesh_data.positions[idx] = local
			moved = true
	if not moved:
		return
	mesh_data.invalidate_caches()
	mesh_data.calculate_normals()
	cmd.capture_after()
	if not cmd.is_noop():
		cmd.add_to_undo_manager(get_undo_redo())
	_finish_mesh_op(mesh, "snap_selection", 0)

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

	# Selecting something else while a params session is open cancels it:
	# unconfirmed changes are reverted like clicking Cancel.
	# Re-entrant call from _finish_creation_session's own selection
	# change is a no-op (the session kind is already cleared).
	if _params_session_kind == "edit":
		if logger:
			logger.info("plugin", "Edit Params session cancelled (selection changed)")
		_on_params_canceled()
	elif _params_session_kind == "create" and pb_mesh != null and pb_mesh != shape_creator.preview_node:
		if logger:
			logger.info("plugin", "Create Params session cancelled (selection changed)")
		_on_params_canceled()

# ==============================================================================
# Editor State Callbacks
# ==============================================================================

func _on_active_mesh_changed(mesh: PBMesh) -> void:
	if gizmo_plugin != null and gizmo_plugin.element_editor != null \
			and gizmo_plugin.element_editor.drag_active:
		gizmo_plugin.element_editor.commit_subgizmos(editor.active_mesh, PackedInt32Array(), true)
	if mesh != null:
		# broken welds make element ids resolve to raw position pairs, which
		# tears corners apart on drag (the "moved those 2 verts" failure).
		if mesh.pb_mesh_data != null and mesh.pb_mesh_data.ensure_welds():
			mesh.rebuild()
			if logger:
				logger.warn("editor", "Mesh '%s' had missing weld groups — rebuilt from coincident positions" % mesh.name)
		if logger:
			var md: PBMeshData = mesh.pb_mesh_data
			if md != null:
				logger.info("editor", "Mesh '%s': V=%d F=%d weld_groups=%d edges=%d" % [
					mesh.name, md.positions.size(), md.faces.size(),
					md.shared_vertices.size(), md.get_common_edges().size()])
		if gizmo_plugin.gizmo_for_node(mesh) == null:
			# A gizmo-less PBMesh can never be picked or element-edited (its
			# first gizmo request ran before it had an owner). Re-request via
			# the editor's own deferred group call.
			get_tree().call_group_flags(SceneTree.GROUP_CALL_DEFERRED,
				"_spatial_editor_group", "_request_gizmo_for_id", mesh.get_instance_id())
		mesh.update_gizmos()
		# Clicking ANOTHER object while in an element mode lands directly on
		# the element under the cursor — no transient whole-object gizmo.
		# (Deferred: the engine is still finishing its own selection change.)
		if editor.is_editing() and _last_mouse_camera != null \
				and Time.get_ticks_msec() - _last_press_msec < 500:
			_auto_pick_element.call_deferred(mesh)
	else:
		editor.hover_id = -1
	_update_editing_context()

## Selects the element under the last click position on `mesh` (single-id
## subgizmo selection — the engine's script API) so the element gizmo shows
## up immediately instead of the whole-object one.
func _auto_pick_element(mesh: PBMesh) -> void:
	if not editor.is_editing() or editor.active_mesh != mesh:
		return
	var gizmo := gizmo_plugin.gizmo_for_node(mesh)
	var id: int = gizmo_plugin.element_editor.pick_ray(
		mesh.pb_mesh_data, mesh.global_transform, _last_mouse_camera, _last_mouse_pos)
	if id >= 0 and gizmo != null:
		mesh.set_subgizmo_selection(gizmo, id,
			gizmo_plugin.element_editor.get_subgizmo_transform(mesh.pb_mesh_data, mesh, id))
	mesh.update_gizmos()

func _on_select_mode_changed(_mode: PBEditor.SelectMode) -> void:
	# Clear element selection when mode changes (ProBuilder behavior).
	# The engine's subgizmo selection is the authoritative drag source, so it
	# must be cleared too, and the gizmo redrawn for the new element type.
	editor.selection.clear_all()
	editor.hover_id = -1
	_hover_drawn_last = -1
	gizmo_plugin.element_editor.reset_side_faces()
	if editor.active_mesh != null:
		editor.active_mesh.clear_subgizmo_selection()
		editor.active_mesh.update_gizmos()
	_update_editing_context()

func _on_element_selection_changed() -> void:
	if tool_overlay:
		tool_overlay.refresh()
	# Deferred: this fires from inside a gizmo redraw (the engine-selection
	# mirror) — the engine tool must not be flipped re-entrantly.
	_update_engine_tool.call_deferred()

func _on_orientation_space_changed(_space: PBEditor.OrientationSpace) -> void:
	# The engine's transform gizmo only adopts a subgizmo's basis while its
	# own local-coords toggle is on (update_transform_gizmo in the engine
	# source) — the bridge flips that toggle, and the engine's `toggled`
	# handler then re-orients the gizmo over the selected subgizmos itself.
	tool_bridge.editor_space = editor.orientation_space
	if editor.is_editing() and tool_bridge.is_ready():
		var applied: bool = tool_bridge.apply_orientation_space(editor.orientation_space)
		if not applied and logger:
			logger.warn("plugin", "Engine local-coords toggle not found — gizmo space cannot be applied")
	# Re-fetch subgizmo transforms so our own gizmo redraw matches too.
	if editor.active_mesh != null:
		editor.active_mesh.update_gizmos()

func _on_tool_mode_changed(_tool: PBEditor.ToolMode) -> void:
	_update_engine_tool()
	# The center scale handle lives on the ELEMENT gizmo, which only renders
	# on a redraw — switching MOVE↔SCALE must refresh it or the handle simply
	# does not exist until some unrelated hover change triggers a redraw.
	if editor.active_mesh != null:
		editor.active_mesh.update_gizmos()

## The user switched the engine tool itself (W/E/R or its toolbar buttons)
## while editing — mirror it into the plugin's own tool state.
func _on_engine_tool_selected(tool: int) -> void:
	editor.tool_mode = tool as PBEditor.ToolMode

## Applies the plugin editing context to the editor UI: toolbar buttons,
## engine tool buttons (universal/select disabled while editing, our tool
## forced active), and the overlay panel visibility.
func _update_editing_context() -> void:
	var mesh_selected := editor.active_mesh != null
	var editing := editor.is_editing()
	toolbar.set_editing_active(mesh_selected)
	tool_overlay.update_visibility()
	if tool_bridge.is_ready():
		tool_bridge.set_editing_active(editing)
		if editing:
			tool_bridge.editor_space = editor.orientation_space
			tool_bridge.apply_orientation_space(editor.orientation_space)
		# Grid jurisdiction swap: inside ANY PoiBuilder context (mesh selected
		# or shape creation armed) the engine's stock grid hides and our cyan
		# grid draws (PBGridView); in OBJECT mode the engine's own transform
		# snap also tracks our grid so node-level drags match element drags.
		var pb_context := mesh_selected or shape_creator.is_active() or grid.draw_on_grid or absf(grid.origin.y) > 0.0001
		var cam3d: Camera3D = null
		var vp := get_editor_interface().get_editor_viewport_3d(0)
		if vp != null:
			cam3d = vp.get_camera_3d()
		tool_bridge.set_engine_grid_hidden(pb_context, cam3d)
		if not editing and mesh_selected:
			tool_bridge.apply_engine_snap(grid.step(), grid.rotate_step_deg, grid.enabled)
		else:
			tool_bridge.restore_engine_snap()
	else:
		# Bridge-less contexts can't sync engine internals — grid view still
		# follows the context via _process.
		pass
	_update_engine_tool()

## Grid driver, once per editor frame: the grid is drawn on the ACTIVE
## node's gizmo (PBGridView caches world-space lines; the camera focus +
## grid settings gate rebuilds), so a redraw is only requested on real
## staleness — gizmo redraws are the native re-render trigger.
var _grid_drawn_last := false

func _process(_delta: float) -> void:
	if grid_view == null:
		return
	var wants := show_grid_should_draw() and grid.show_grid
	var vp := get_editor_interface().get_editor_viewport_3d(0)
	var cam: Camera3D = null
	if vp != null:
		cam = vp.get_camera_3d()
		if not grid_view.is_active():
			var w3d := vp.find_world_3d()
			if w3d != null:
				grid_view.attach_scenario(w3d.get_scenario())
	if wants and cam != null:
		grid_view.update(cam)
	grid_view.set_visible(wants)
	if tool_bridge != null and tool_bridge.is_ready():
		tool_bridge.set_engine_grid_hidden(wants, cam)

## The grid renders while any PoiBuilder context is active (a PBMesh is
## selected — object mode included — or shape creation is armed, or drawing
## on an elevated/custom grid, or grid settings panel is open).
func show_grid_should_draw() -> bool:
	return editor.active_mesh != null or shape_creator.is_active() or grid.draw_on_grid or absf(grid.origin.y) > 0.0001 or _grid_panel_open

func _attach_grid_view_scenario() -> void:
	if grid_view == null:
		return
	var vp := get_editor_interface().get_editor_viewport_3d(0)
	if vp != null:
		var w3d := vp.find_world_3d()
		if w3d != null:
			grid_view.attach_scenario(w3d.get_scenario())

## Grid panel button on the toolbar toggles the overlay's grid section.
var _grid_panel_open := false

func _on_grid_panel_toggled(open: bool) -> void:
	_grid_panel_open = open
	if open:
		tool_overlay.panel_enabled = true
		toolbar.set_overlay_pinned(true)
		tool_overlay.open_grid()
	else:
		tool_overlay.close_grid()

## Instant-apply grid edits from the overlay panel (no Apply/Cancel).
func _on_grid_ui_setting(key: StringName, value: float) -> void:
	match key:
		&"enabled":
			grid.enabled = value > 0.5
		&"draw_on_grid":
			grid.draw_on_grid = value > 0.5
		&"show_grid":
			grid.show_grid = value > 0.5
		&"unit":
			grid.unit = value
		&"subdivisions":
			grid.subdivisions = int(value)
		&"rotate_step_deg":
			grid.rotate_step_deg = value
		&"elevation":
			grid.origin.y = value
		&"elev_up":
			grid.raise()
		&"elev_down":
			grid.lower()

## The panel's Reset button: back to the stock defaults.
func _on_grid_reset() -> void:
	grid.enabled = true
	grid.draw_on_grid = false
	grid.show_grid = true
	grid.unit = 1.0
	grid.subdivisions = 5
	grid.rotate_step_deg = 15.0
	grid.origin = Vector3.ZERO
	if logger != null:
		logger.info("grid", "grid settings reset to defaults")

## Keeps the ENGINE's transform gizmo in the right state:
## - OBJECT mode: our Move/Rotate/Scale drives the whole-node gizmo (the
##   toolbar's tool buttons must visibly switch the node gizmo there too).
## - Element mode: WITH a subgizmo selection our tool drives the element
##   gizmo; with NO selection the engine idles in its SELECT tool — builder
##   mode must never show the whole-object transform gizmo, and the select
##   tool is also what makes click-selecting other nodes work natively.
func _update_engine_tool() -> void:
	if not tool_bridge.is_ready():
		return
	if not editor.is_editing():
		tool_bridge.apply_tool(editor.tool_mode)
		return
	var sel := editor.selection
	var has_selection := sel != null and (sel.selected_face_count() > 0 \
		or sel.selected_edge_count() > 0 or sel.selected_vertex_count() > 0)
	if has_selection:
		tool_bridge.apply_tool(editor.tool_mode)
	else:
		tool_bridge.press_engine_select_tool()

## Toolbar Panel toggle → overlay pin (and back, keeping both in sync).
func _on_overlay_toggled(pinned: bool) -> void:
	tool_overlay.panel_enabled = pinned
	tool_overlay.pinned = pinned
	if pinned:
		tool_overlay.expand()
		tool_overlay.ensure_visible_and_clamped()
	tool_overlay.update_visibility()

## Explicit toolbar recovery button: resets the panel, forces it visible, uncollapses it.
func _on_reset_panel_requested() -> void:
	if tool_overlay != null:
		tool_overlay.panel_enabled = true
		tool_overlay.pinned = true
		toolbar.set_overlay_pinned(true)
		tool_overlay.expand()
		tool_overlay.reset_to_default_position()
		tool_overlay.update_visibility()
		if logger:
			logger.info("plugin", "Overlay panel recovered to bottom-left corner")
## Drag lifecycle signal. Hover is cleared when a drag STARTS; per-update
## refreshes are deliberately NOT done here — the delivery path
## (_set_subgizmo_transform) already redraws the gizmo every motion, and a
## second full redraw per delivery halved the drag frame rate.
var _drag_was_active: bool = false

func _on_drag_updated(active: bool, _t: Vector3, _r: Vector3, _s: Vector3) -> void:
	if active and not _drag_was_active:
		editor.hover_id = -1
		_hover_drawn_last = -1
		if editor.active_mesh != null:
			editor.active_mesh.update_gizmos()
	_drag_was_active = active

## A shift+move / shift+scale gesture committed — face ids shifted, so the
## engine's subgizmo selection and our mirrors are stale. Clear and redraw
## (same dance as an explicit mesh op).
func _on_drag_topology_committed(mesh: PBMesh) -> void:
	editor.hover_id = -1
	_hover_drawn_last = -1
	editor.selection.clear_all()
	gizmo_plugin.element_editor.reset_side_faces()
	mesh.clear_subgizmo_selection()
	mesh.update_gizmos()

# ==============================================================================
# Mesh Operations (overlay OPERATIONS section)
# ==============================================================================

## Numeric params for the toolbar op buttons. The LIVE equivalents are the
## gestures: Shift+Move extrudes, Shift+Scale insets (both drag-driven);
## these buttons use the session defaults.
const OP_EXTRUDE_DISTANCE := 0.25
const OP_INSET_AMOUNT := 0.25

## Performs a mesh op from the toolbar on the current selection. Face-mode
## ops read the selected faces; edge extrude reads the selected edges. Undo
## goes through full-mesh snapshots (CmdMeshOp) — ops rewrite topology, so
## per-index payloads don't apply.
func _on_operation_requested(op_name: String) -> void:
	if not editor.is_editing() or editor.active_mesh == null:
		return
	# Extrude is ONE action: face mode extrudes faces, edge mode extrudes
	# fins (both the toolbar button and the op key route here).
	if op_name == "extrude_faces" and editor.select_mode == PBEditor.SelectMode.EDGE:
		op_name = "extrude_edges"
	var mesh := editor.active_mesh
	var mesh_data: PBMeshData = mesh.pb_mesh_data
	if mesh_data == null:
		return

	var distance := OP_EXTRUDE_DISTANCE
	var amount := OP_INSET_AMOUNT
	var selection := editor.selection

	if op_name == "detach_faces":
		_perform_detach(mesh, selection.selected_faces.duplicate())
		return

	var cmd := CmdMeshOp.new(mesh_data, OP_ACTION_NAMES.get(op_name, "Mesh Operation"), mesh)
	if logger:
		cmd.logger = logger
	var result: Dictionary
	match op_name:
		"extrude_faces":
			result = PBMeshOps.extrude_faces(mesh_data, selection.selected_faces.duplicate(), distance)
		"inset_faces":
			result = PBMeshOps.inset_faces(mesh_data, selection.selected_faces.duplicate(), amount)
		"subdivide_faces":
			result = PBMeshOps.subdivide_faces(mesh_data, selection.selected_faces.duplicate())
		"merge_faces":
			result = PBMeshOps.merge_faces(mesh_data, selection.selected_faces.duplicate())
		"delete_faces":
			result = PBMeshOps.delete_faces(mesh_data, selection.selected_faces.duplicate())
		"weld_vertices":
			result = PBMeshOps.weld_vertices(mesh_data, selection.selected_vertices.duplicate())
		"extrude_edges":
			var edge_ids := PBMeshOps.common_edge_ids(mesh_data, selection.selected_edges)
			result = PBMeshOps.extrude_edges(mesh_data, edge_ids, distance)
		"insert_edge_loop":
			var loop_ids := PBMeshOps.common_edge_ids(mesh_data, selection.selected_edges)
			result = PBMeshOps.insert_edge_loop(mesh_data, loop_ids)
		_:
			if logger:
				logger.warn("mesh_ops", "Unknown operation requested: %s" % op_name)
			return

	if not result["ok"]:
		if logger:
			logger.warn("mesh_ops", "%s failed: %s" % [op_name, result.get("error", "?")])
		return

	cmd.capture_after()
	if not cmd.is_noop():
		cmd.add_to_undo_manager(get_undo_redo())
	_finish_mesh_op(mesh, op_name, int(result["new_face_ids"].size()))

## Detach is special: besides mutating the source mesh it spawns a new PBMesh
## sibling holding the extracted faces. One undo action covers both (the new
## node is registered as a do-reference so undo keeps it alive for redo).
func _perform_detach(mesh: PBMesh, face_ids: PackedInt32Array) -> void:
	var mesh_data: PBMeshData = mesh.pb_mesh_data
	var before := PBCommand.copy_mesh_data(mesh_data)
	var result := PBMeshOps.detach_faces(mesh_data, face_ids)
	if not result["ok"]:
		if logger:
			logger.warn("mesh_ops", "detach failed: %s" % result.get("error", "?"))
		return
	var after := PBCommand.copy_mesh_data(mesh_data)

	var new_node := PBMesh.new()
	new_node.name = _unique_detached_name(mesh)
	new_node.pb_mesh_data = result["detached"]
	# The detached positions are in the SOURCE's local space — copying the
	# source transform keeps the new object exactly where the faces were
	# (position, rotation, and scale), instead of snapping to identity.
	new_node.transform = mesh.transform

	var undo := get_undo_redo()
	undo.create_action("Detach Faces", UndoRedo.MERGE_DISABLE, mesh)
	undo.add_do_method(self, "_restore_mesh_snapshot", mesh.get_instance_id(), after)
	undo.add_do_method(self, "_attach_detached", new_node, mesh.get_parent())
	undo.add_do_reference(new_node)
	undo.add_undo_method(self, "_detach_node", new_node)
	undo.add_undo_method(self, "_restore_mesh_snapshot", mesh.get_instance_id(), before)
	undo.commit_action()

	_finish_mesh_op(mesh, "detach_faces", int(result["new_face_ids"].size()))
	if logger:
		logger.info("mesh_ops", "Detached faces into new node '%s'" % new_node.name)

## Shared tail of every op: element ids changed, so the engine's subgizmo
## selection and our mirror are both stale — clear them and re-render.
func _finish_mesh_op(mesh: PBMesh, op_name: String, new_face_count: int) -> void:
	editor.hover_id = -1
	_hover_drawn_last = -1
	editor.selection.clear_all()
	gizmo_plugin.element_editor.reset_side_faces()
	mesh.clear_subgizmo_selection()
	mesh.rebuild()
	mesh.update_gizmos()
	if mesh.pb_mesh_data != null:
		mesh.pb_mesh_data.shape_edited = true
	if logger:
		logger.info("mesh_ops", "%s: %d new face(s)" % [op_name, new_face_count])

## Undo-history display names per overlay op.
const OP_ACTION_NAMES := {
	"extrude_faces": "Extrude Faces",
	"inset_faces": "Inset Faces",
	"subdivide_faces": "Subdivide Faces",
	"merge_faces": "Merge Faces",
	"delete_faces": "Delete Faces",
	"detach_faces": "Detach Faces",
	"extrude_edges": "Extrude Edges",
	"insert_edge_loop": "Insert Edge Loop",
	"weld_vertices": "Weld Vertices",
}

# ==============================================================================
# Shape Creation (drag base → height → params, ProBuilder-style)
# ==============================================================================

var shape_creator: PBShapeCreator = PBShapeCreator.new()

## What the overlay params modal is editing: "create" (a just-placed shape)
## or "edit" (Edit Params on a pristine factory shape).
var _params_session_kind: String = ""
var _params_edit_node: PBMesh = null
var _params_edit_snapshot: PBMeshData = null
var _params_edit_values: Dictionary = {}

## A New Shape menu pick ARMS creation: nothing exists yet — the next LMB
## drag on any surface (PBMesh face or grid plane) draws the base. Any open
## params session is committed first (a create session in the modal applies;
## an Edit Params session commits) so the new shape never replaces the node
## a still-open dialog was editing.
func _on_shape_requested(shape_id: StringName) -> void:
	if _params_session_kind != "":
		_on_params_applied()
	elif shape_creator.is_active():
		_creation_abort("a new shape was picked")
	shape_creator.arm(shape_id)
	# Arming is a PoiBuilder context change too: the engine grid hides and
	# the elevated PB grid shows while drawing (engine-bridge a no-op).
	_update_editing_context()
	if PBShapeParams.height_drags_offset(shape_id):
		_set_creation_hint("%s — click a surface to anchor it (Esc cancels)"
			% String(shape_id).capitalize())
	else:
		_set_creation_hint("%s — drag a base on any surface (Esc cancels)" % String(shape_id).capitalize())
	if logger:
		logger.info("plugin", "Creating '%s' — drag on a surface to draw the base" % shape_id)

## Feeds the overlay's creation row so an armed/dragging session is never
## invisible (a sticky armed state used to swallow clicks "silently").
func _set_creation_hint(text: String) -> void:
	if tool_overlay != null:
		tool_overlay.set_creation_hint(text)

func _creation_input(camera: Camera3D, event: InputEvent) -> int:
	if event is InputEventMouseMotion:
		_last_mouse_pos = event.position
		_last_mouse_camera = camera
		_creation_motion(camera, event.position)
		return AFTER_GUI_INPUT_PASS

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			match shape_creator.state:
				PBShapeCreator.State.ARMED:
					if _creation_begin_from_surface(camera, event.position):
						# Consume the press so the engine never starts a
						# marquee / selection under the creation drag.
						return AFTER_GUI_INPUT_STOP
					return AFTER_GUI_INPUT_PASS
				PBShapeCreator.State.HEIGHT, PBShapeCreator.State.OFFSET:
					_creation_confirm()
					return AFTER_GUI_INPUT_STOP
				PBShapeCreator.State.PARAMS:
					# Clicking elsewhere cancels the uncommitted modal changes
					# (reverts to placement values), exactly like clicking Cancel.
					if logger:
						logger.info("plugin", "Params modal cancelled (viewport press)")
					_on_params_canceled()
					return AFTER_GUI_INPUT_PASS
		else:
			if shape_creator.state == PBShapeCreator.State.BASE:
				_creation_end_base()
				return AFTER_GUI_INPUT_STOP

	if event is InputEventKey and event.pressed and not event.echo:
		# Grid keys keep working mid-creation (raise the grid, change the
		# step, toggle snapping) — they never conflict with LMB/ESC/ENTER.
		if shape_creator.state != PBShapeCreator.State.PARAMS \
				and _handle_grid_action_key(event as InputEventKey) == AFTER_GUI_INPUT_STOP:
			return AFTER_GUI_INPUT_STOP
		if shape_creator.state == PBShapeCreator.State.PARAMS:
			if event.keycode == KEY_ESCAPE:
				_on_params_canceled()
				return AFTER_GUI_INPUT_STOP
			elif event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
				_on_params_applied()
				return AFTER_GUI_INPUT_STOP
			else:
				if logger:
					logger.info("plugin", "Params modal cancelled (key press)")
				_on_params_canceled()
				return AFTER_GUI_INPUT_PASS
		if event.keycode == KEY_ESCAPE:
			# ESC before confirming click: nothing is created at all.
			_creation_abort("cancelled with Escape")
			return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_PASS
## Nearest surface under the cursor: PBMesh faces (world space) with
## PoiBuilder's grid plane as the fallback, like ProBuilder dragging on the
## grid. With "Draw on Grid" ON, surface picking is skipped entirely — every
## new shape is drawn on the (possibly elevated) grid plane. Returns
## {point, normal} or {} on a miss.
func _pick_creation_surface(camera: Camera3D, screen_pos: Vector2) -> Dictionary:
	var ray_o: Vector3 = camera.project_ray_origin(screen_pos)
	var ray_d: Vector3 = camera.project_ray_normal(screen_pos)
	if grid.draw_on_grid:
		var on_grid := PBShapeCreator.ray_plane_intersect(ray_o, ray_d,
			grid.origin, Vector3.UP)
		if on_grid != PBShapeCreator.RAY_MISS:
			return {"point": on_grid, "normal": Vector3.UP}
		return {}
	var best_t := INF
	var best := {}
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root != null:
		for node in _collect_pbmeshes(scene_root):
			if node == shape_creator.preview_node or node.pb_mesh_data == null:
				continue
			var res := PBPicking.pick_face(node.pb_mesh_data, node.global_transform, ray_o, ray_d)
			if res.face_index >= 0 and res.distance < best_t:
				var normal := PBMath.normal_from_positions(
					node.pb_mesh_data.positions, node.pb_mesh_data.faces[res.face_index].get_indexes())
				best_t = res.distance
				best = {"point": res.hit_point,
					"normal": (node.global_transform.basis * normal).normalized()}
	if best.is_empty():
		var hit := PBShapeCreator.ray_plane_intersect(ray_o, ray_d, grid.origin, Vector3.UP)
		if hit != PBShapeCreator.RAY_MISS:
			best = {"point": hit, "normal": Vector3.UP}
	return best

func _collect_pbmeshes(root: Node) -> Array[PBMesh]:
	var out: Array[PBMesh] = []
	if root is PBMesh:
		out.append(root)
	for child in root.get_children():
		out.append_array(_collect_pbmeshes(child))
	return out

func _creation_begin_from_surface(camera: Camera3D, screen_pos: Vector2) -> bool:
	var hit := _pick_creation_surface(camera, screen_pos)
	if hit.is_empty():
		return false
	var view_z: Vector3 = camera.global_transform.basis.z
	if PBShapeParams.height_drags_offset(shape_creator.shape_id):
		# Sprite flow: one click anchors the shape ON the surface; the mouse
		# then pushes it along the surface normal until the confirming click.
		shape_creator.begin_anchor(hit["point"], hit["normal"], view_z)
		_clear_creation_hover()
		_set_creation_hint("move off the surface to set the offset, then click to confirm")
		_make_preview_node()
		_refresh_preview()
		return true
	shape_creator.begin(hit["point"], hit["normal"], view_z)
	# The pressed face's hover highlight dies with the drag start (the base
	# outline takes over); hover stays off until the HEIGHT stage.
	_clear_creation_hover()
	_set_creation_hint("release the mouse, then move to set the height")
	_make_preview_node()
	_refresh_preview()
	return true

func _make_preview_node() -> void:
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		_creation_abort("no edited scene")
		return
	var node := PBMesh.new()
	node.name = _unique_shape_name(scene_root, shape_creator.shape_id)
	scene_root.add_child(node)
	# THE OWNER MUST BE SET BEFORE ANYTHING DRAWS: the editor attaches node
	# gizmos only to OWNED nodes, and a node whose first gizmo request ran
	# ownerless never re-requests them (Node3D caches gizmos_requested).
	# Without this, the preview has no gizmo — no outline, no picking, no
	# element editing — for its whole life.
	node.owner = scene_root
	shape_creator.preview_node = node

## Rebuilds the preview mesh + placement from the creator's current values.
## During the BASE phase the rendered MESH is hidden but the NODE stays
## visible — an invisible Node3D also loses its gizmo, which would hide the
## cyan base-rect outline. pb_mesh_data is still assigned (the gizmo's
## redraw needs it to pass its data checks); only the render mesh is
## cleared, AFTER the setter's rebuild.
func _refresh_preview() -> void:
	var node := shape_creator.preview_node
	if node == null:
		return
	var data := shape_creator.build_data()
	if data == null:
		return
	node.transform = shape_creator.placement_transform(data)
	node.pb_mesh_data = data
	if shape_creator.state == PBShapeCreator.State.BASE:
		node.mesh = null
	# The creation overlays (outline/bounds) live on the node's gizmo — a
	# rebuild alone never redraws it.
	node.update_gizmos()

func _creation_motion(camera: Camera3D, screen_pos: Vector2) -> void:
	var ray_o: Vector3 = camera.project_ray_origin(screen_pos)
	var ray_d: Vector3 = camera.project_ray_normal(screen_pos)
	match shape_creator.state:
		PBShapeCreator.State.BASE:
			var hit := PBShapeCreator.ray_plane_intersect(ray_o, ray_d,
				shape_creator.plane_point, shape_creator.plane_normal)
			if hit != PBShapeCreator.RAY_MISS:
				shape_creator.update_base(hit)
				_refresh_preview()
			# No hover highlight while the base drag is out — the cursor is
			# busy drawing the rect, not picking a face.
		PBShapeCreator.State.HEIGHT, PBShapeCreator.State.OFFSET:
			var ref := PBShapeCreator.height_reference_point(camera.global_position,
				-camera.global_transform.basis.z, ray_o, ray_d, shape_creator.rect_center)
			shape_creator.update_height_point(ref)
			_refresh_preview()
			_update_creation_hover(camera, screen_pos)
		PBShapeCreator.State.PARAMS:
			pass  # modal open — no preview updates, no hover
		_:
			_update_creation_hover(camera, screen_pos)

## Cyan face highlight under the cursor while creating (skips the preview).
func _update_creation_hover(camera: Camera3D, screen_pos: Vector2) -> void:
	var ray_o: Vector3 = camera.project_ray_origin(screen_pos)
	var ray_d: Vector3 = camera.project_ray_normal(screen_pos)
	var best_t := INF
	var best_node: PBMesh = null
	var best_face := -1
	var best_point := Vector3.ZERO
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root != null:
		for node in _collect_pbmeshes(scene_root):
			if node == shape_creator.preview_node or node.pb_mesh_data == null:
				continue
			var res := PBPicking.pick_face(node.pb_mesh_data, node.global_transform, ray_o, ray_d)
			if res.face_index >= 0 and res.distance < best_t:
				best_t = res.distance
				best_node = node
				best_face = res.face_index
				best_point = res.hit_point
	var prev_node := gizmo_plugin.creation_hover_node
	if best_node != prev_node or best_face != gizmo_plugin.creation_hover_face:
		gizmo_plugin.creation_hover_node = best_node
		gizmo_plugin.creation_hover_face = best_face
		if prev_node != null and is_instance_valid(prev_node):
			prev_node.update_gizmos()
		if best_node != null:
			best_node.update_gizmos()
	# Always tracked (cheap): the ARMED cursor square sits at this point.
	gizmo_plugin.creation_hover_point = best_point

func _clear_creation_hover() -> void:
	var prev_node := gizmo_plugin.creation_hover_node
	gizmo_plugin.creation_hover_node = null
	gizmo_plugin.creation_hover_face = -1
	gizmo_plugin.creation_hover_point = Vector3.ZERO
	if prev_node != null and is_instance_valid(prev_node):
		prev_node.update_gizmos()

func _creation_end_base() -> void:
	if not shape_creator.end_base():
		# A stray click (no real drag) — ProBuilder creates nothing either.
		_creation_abort("base drag too small")
		return
	# Rebuild NOW: the solid preview appears immediately as a flat slab ON
	# the surface (height 0) instead of popping in below it with a jump at
	# the first mouse move.
	_refresh_preview()
	_set_creation_hint("move to size it, then click to confirm")

## The confirming click (after the height drag): the shape exists from here
## on (its node-add undo is registered now). Parameterized shapes open the
## params modal; simple size-only shapes finalize immediately (Edit Params
## is always available afterwards).
func _creation_confirm() -> void:
	shape_creator.confirm_height()
	var node := shape_creator.preview_node
	var scene_root := get_editor_interface().get_edited_scene_root()
	var undo := get_undo_redo()
	undo.create_action("Add %s" % String(shape_creator.shape_id).capitalize(),
		UndoRedo.MERGE_DISABLE, node)
	undo.add_do_method(self, "_attach_detached", node, scene_root)
	undo.add_do_method(self, "_own_node", node)
	undo.add_do_reference(node)
	undo.add_undo_method(self, "_detach_node", node)
	undo.commit_action()
	_set_creation_hint("")

	# Select the created node immediately so the editor recognises it as active
	# and doesn't treat initial placement as a deselect event
	var editor_selection := get_editor_interface().get_selection()
	if editor_selection != null and node != null and is_instance_valid(node):
		editor_selection.clear()
		editor_selection.add_node(node)
		editor.active_mesh = node

	if PBShapeParams.needs_params_modal(shape_creator.shape_id):
		_params_session_kind = "create"
		tool_overlay.panel_enabled = true
		toolbar.set_overlay_pinned(true)
		tool_overlay.open_params("%s Parameters" % String(shape_creator.shape_id).capitalize(),
			PBShapeParams.get_param_defs(shape_creator.shape_id), shape_creator.values)
		if logger:
			logger.info("plugin", "Placed '%s' — adjust parameters, then Apply/Cancel" % node.name)
	else:
		_finalize_created_shape(node)
		_finish_creation_session(node)
		if logger:
			logger.info("plugin", "Created '%s'" % node.name)

## Stamps the creation bookkeeping onto the node's data from the creator's
## current values (shared by Apply and the no-modal fast path).
func _finalize_created_shape(node: PBMesh) -> void:
	if node == null or not is_instance_valid(node) or node.pb_mesh_data == null:
		return
	node.pb_mesh_data.shape_id = shape_creator.shape_id
	node.pb_mesh_data.shape_params = shape_creator.values.duplicate()
	node.pb_mesh_data.shape_edited = false
	node._update_collider()
func _creation_abort(reason: String) -> void:
	var node := shape_creator.preview_node
	shape_creator.reset()
	if node != null and is_instance_valid(node) and node.get_parent() != null:
		# The preview never entered the undo history — removing it fully
		# un-creates the shape.
		node.get_parent().remove_child(node)
		node.queue_free()
	_clear_creation_hover()
	_set_creation_hint("")
	_update_editing_context()
	if logger:
		logger.info("plugin", "Shape creation aborted (%s)" % reason)

## Ends a "create" params session: the node stays either way (Apply keeps the
## edited params, Cancel restored the pre-modal ones), and the plugin hands
## the node over to element editing.
func _finish_creation_session(node: PBMesh) -> void:
	shape_creator.reset()
	_clear_creation_hover()
	_set_creation_hint("")
	tool_overlay.close_params()
	_params_session_kind = ""
	if node != null and is_instance_valid(node):
		# A stray undo (or a corrupted session) could have detached the node —
		# re-attach before selecting so add_node sees a live tree node.
		if not node.is_inside_tree():
			_attach_detached(node, get_editor_interface().get_edited_scene_root())
		var editor_selection := get_editor_interface().get_selection()
		editor_selection.clear()
		editor_selection.add_node(node)
		editor.restore_element_mode()
	_update_editing_context()

func _unique_shape_name(scene_root: Node, shape_id: StringName) -> String:
	var base := "Shape_%s" % String(shape_id).capitalize().replace(" ", "")
	if scene_root.get_node_or_null(NodePath(base)) == null:
		return base
	var i := 2
	while scene_root.get_node_or_null(NodePath("%s%d" % [base, i])) != null:
		i += 1
	return "%s%d" % [base, i]

# ==============================================================================
# Shape Params modal (create + edit sessions)
# ==============================================================================

func _on_param_changed(param_name: String, value: float) -> void:
	if _params_session_kind == "create":
		shape_creator.set_param(param_name, value)
		_refresh_preview()
	elif _params_session_kind == "edit" and _params_edit_node != null \
			and is_instance_valid(_params_edit_node):
		_params_edit_values[param_name] = value
		var data := _params_edit_node.pb_mesh_data
		var rebuilt := PBShapeParams.build(data.shape_id, _params_edit_values)
		if rebuilt != null:
			rebuilt.shape_id = data.shape_id
			rebuilt.shape_params = _params_edit_values.duplicate()
			rebuilt.shape_edited = false
			_params_edit_node.pb_mesh_data = rebuilt

func _on_params_applied() -> void:
	if _params_session_kind == "create":
		var node := shape_creator.preview_node
		shape_creator.values = tool_overlay.get_param_values()
		_finalize_created_shape(node)
		_finish_creation_session(node)
		if logger:
			logger.info("plugin", "Shape parameters applied")
	elif _params_session_kind == "edit":
		_commit_edit_params()

func _on_params_canceled() -> void:
	if _params_session_kind == "create":
		var node := shape_creator.preview_node
		shape_creator.cancel_params()
		var data := shape_creator.build_data()
		if node != null and data != null:
			data.shape_id = shape_creator.shape_id
			data.shape_params = shape_creator.values.duplicate()
			node.pb_mesh_data = data
			node.transform = shape_creator.placement_transform(data)
		_finish_creation_session(node)
		if logger:
			logger.info("plugin", "Shape parameters reverted to placement values")
	elif _params_session_kind == "edit":
		if _params_edit_node != null and is_instance_valid(_params_edit_node) \
				and _params_edit_snapshot != null:
			PBCommand.restore_mesh_data(_params_edit_node.pb_mesh_data, _params_edit_snapshot)
			_params_edit_node.rebuild()
			_params_edit_node.update_gizmos()
		tool_overlay.close_params()
		_params_session_kind = ""
		_params_edit_node = null
		_params_edit_snapshot = null
		_params_edit_values = {}
		if logger:
			logger.info("plugin", "Shape parameters edit cancelled")

## Edit Params on a pristine factory shape: live param rebuilds; Apply
## commits a snapshot undo, Cancel restores the pre-session data. Ignored
## while another params session is running.
func _on_edit_params_requested() -> void:
	if _params_session_kind != "":
		return
	var mesh := editor.active_mesh
	if mesh == null or mesh.pb_mesh_data == null:
		return
	var data: PBMeshData = mesh.pb_mesh_data
	if data.shape_id == &"" or data.shape_edited:
		if logger:
			logger.warn("plugin", "Edit Params needs an unedited factory shape")
		return
	_params_session_kind = "edit"
	_params_edit_node = mesh
	_params_edit_snapshot = PBCommand.copy_mesh_data(data)
	_params_edit_values = data.shape_params.duplicate()
	tool_overlay.panel_enabled = true
	toolbar.set_overlay_pinned(true)
	tool_overlay.open_params("%s Parameters" % String(data.shape_id).capitalize(),
		PBShapeParams.get_param_defs(data.shape_id), _params_edit_values)
func _commit_edit_params() -> void:
	var node := _params_edit_node
	if node == null or not is_instance_valid(node) or node.pb_mesh_data == null:
		return
	var data := node.pb_mesh_data
	data.shape_params = _params_edit_values.duplicate()
	data.shape_edited = false
	var before := _params_edit_snapshot
	var after := PBCommand.copy_mesh_data(data)
	var undo := get_undo_redo()
	undo.create_action("Edit %s Params" % String(data.shape_id).capitalize(),
		UndoRedo.MERGE_DISABLE, node)
	undo.add_do_method(self, "_restore_mesh_snapshot", node.get_instance_id(), after)
	undo.add_undo_method(self, "_restore_mesh_snapshot", node.get_instance_id(), before)
	undo.commit_action()
	tool_overlay.close_params()
	_params_session_kind = ""
	_params_edit_node = null
	_params_edit_snapshot = null
	_params_edit_values = {}
	if logger:
		logger.info("plugin", "Shape parameters committed")

func _unique_detached_name(mesh: PBMesh) -> String:
	var parent := mesh.get_parent()
	var base := mesh.name + "_Detached"
	if parent == null or parent.get_node_or_null(NodePath(base)) == null:
		return base
	var i := 2
	while parent.get_node_or_null(NodePath("%s%d" % [base, i])) != null:
		i += 1
	return "%s%d" % [base, i]

## Undo/redo payload: swap a mesh's whole data from a snapshot.
func _restore_mesh_snapshot(target: Variant, snapshot: PBMeshData) -> void:
	var mesh: PBMesh = null
	if target is PBMesh:
		mesh = target as PBMesh
	elif target is int:
		mesh = instance_from_id(target) as PBMesh
	if mesh == null or not is_instance_valid(mesh) or mesh.pb_mesh_data == null:
		return
	PBCommand.restore_mesh_data(mesh.pb_mesh_data, snapshot)
	mesh.rebuild()
	mesh.update_gizmos()
	if logger:
		logger.info("undo", "snapshot restored on %s: V=%d F=%d (render rebuilt)" % [
			mesh.name, mesh.pb_mesh_data.positions.size(), mesh.pb_mesh_data.faces.size()])

func _attach_detached(node: Node, parent: Node) -> void:
	if parent == null or not is_instance_valid(parent):
		return
	if node.get_parent() == parent:
		return  # already attached (creation finalize commits against a live preview)
	parent.add_child(node)
	node.owner = get_editor_interface().get_edited_scene_root()

## Undo "do" half for creation: the preview node is already in the tree when
## the action commits — only ownership is missing.
func _own_node(node: Node) -> void:
	if node != null and is_instance_valid(node):
		node.owner = get_editor_interface().get_edited_scene_root()

## Undo of detach: remove the node WITHOUT freeing it — the undo history's
## do-reference keeps it alive so redo can re-attach it.
func _detach_node(node: Node) -> void:
	if node != null and is_instance_valid(node) and node.get_parent() != null:
		node.get_parent().remove_child(node)
