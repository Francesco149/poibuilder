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

## Shape creation and interactive polygon drawing controllers
var shape_creator: PBShapeCreator = PBShapeCreator.new()
var ngon_drawer: PBNgonDrawer = PBNgonDrawer.new()
var sprite_placer: PBSpritePlacer = PBSpritePlacer.new()
## Particle emitter placement (the Particles dock tab): click-to-place
## GPUParticles3D emitters shaped like the reference PSP demo's.
var particle_placer: PBParticlePlacer = PBParticlePlacer.new()

## Trim Walls session: click wall faces, live preview, one committed object.
var trim_walls_tool: PBTrimWallsTool = PBTrimWallsTool.new()
## The preview node shown while a Trim Walls session is armed (world-space
## data, node transform stays identity). Owned by the plugin like the
## shape-creation preview.
var _trim_walls_preview: PBMesh = null
var _trim_walls_last_click_msec: int = -10000
var _trim_walls_last_click_pos: Vector2 = Vector2.ZERO

# ==============================================================================
# UI Components
# ==============================================================================

var tool_overlay: PBToolOverlay
var toolbar: PBToolbar
var material_dock: PBMaterialDock = null
var uv_editor_panel: PBUvEditorPanel = null
var _uv_bottom_button: Button = null
var material_drop_overlay: PBMaterialDropOverlay = null
var paint_controller: PBPaintController = PBPaintController.new()
var _export_dialog: PBExportDialog = null
var _cursor_extents_label: Label = null
## Top-center hint banner over the 3D scene (paint / stamp / sprite / shape
## modes and their exit route). Pure readout, never consumes input.
var mode_banner: PBModeBanner = null
## The shape the Shapes dock tab keeps armed (re-armed after every placement).
var _shape_mode_shape: StringName = &"cube"
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
## Live animated scrolling textures in editor viewport.
var animate_scrolling_textures: bool = true:
	set(val):
		animate_scrolling_textures = val
		if not val:
			_reset_scrolling_texture_offsets()
		else:
			scan_scrolling_materials()
var _scroll_time: float = 0.0
var _animated_materials: Dictionary = {} # Material -> { "speed": Vector2, "base_offset": Vector3 }
var _last_scroll_scan_msec: int = -10000


# ==============================================================================
# Plugin Lifecycle
# ==============================================================================

func _get_plugin_name() -> String:
	return "PoiBuilder"

const VERSION := "0.9.154"

func _enter_tree():
	logger.info("plugin", "PoiBuilder v%s entering tree" % VERSION)

	# Receive 3D viewport input even with NOTHING selected: shape creation is
	# armed from the New Shape menu and must work before any PBMesh is in the
	# editing context (the engine otherwise only forwards viewport input to
	# plugins whose _handles() matches the currently edited object).
	set_input_event_forwarding_always_enabled()
	var ep_settings: EditorSettings = get_editor_interface().get_editor_settings() if get_editor_interface() != null else null
	if ep_settings != null and ep_settings.has_setting("poibuilder/editor/animate_scrolling_textures"):
		animate_scrolling_textures = ep_settings.get_setting("poibuilder/editor/animate_scrolling_textures")


	# Wire up subsystems
	editor.logger = logger
	gizmo_plugin.editor = editor
	gizmo_plugin.logger = logger
	gizmo_plugin.element_editor.editor = editor
	gizmo_plugin.element_editor.undo = get_undo_redo()
	gizmo_plugin.element_editor.grid = grid
	gizmo_plugin.shape_creator = shape_creator
	shape_creator.grid = grid
	gizmo_plugin.ngon_drawer = ngon_drawer
	ngon_drawer.grid = grid
	_wire_creation_vertex_snap()
	sprite_placer.plugin = self
	sprite_placer.grid = grid
	sprite_placer.sprite_placed.connect(_on_sprite_placed)
	particle_placer.plugin = self
	particle_placer.grid = grid
	particle_placer.emitter_placed.connect(_on_emitter_placed)
	paint_controller.plugin = self
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
	toolbar.trim_walls_requested.connect(_on_trim_walls_requested)
	toolbar.overlay_toggled.connect(_on_overlay_toggled)
	toolbar.reset_panel_requested.connect(_on_reset_panel_requested)
	toolbar.grid_panel_toggled.connect(_on_grid_panel_toggled)
	toolbar.materials_dock_requested.connect(focus_material_dock)
	toolbar.uv_editor_requested.connect(focus_uv_editor)
	toolbar.settings_panel_toggled.connect(_on_settings_panel_toggled)
	toolbar.export_requested.connect(_on_export_requested)
	toolbar.docs_requested.connect(_on_docs_requested)
	toolbar.env_preset_requested.connect(_on_env_preset_requested)
	toolbar.split_rows_toggled.connect(_on_toolbar_split_rows_toggled)
	toolbar.vertex_snap_toggled.connect(func(on: bool):
		gizmo_plugin.element_editor.vertex_snap_enabled = on
		if editor.active_mesh != null:
			editor.active_mesh.update_gizmos()
	)
	toolbar.proportional_toggled.connect(func(on: bool):
		gizmo_plugin.element_editor.proportional_enabled = on
		if editor.active_mesh != null:
			editor.active_mesh.update_gizmos()
	)
	toolbar.proportional_radius_changed.connect(func(rad: float):
		gizmo_plugin.element_editor.proportional_radius = rad
		if editor.active_mesh != null:
			editor.active_mesh.update_gizmos()
	)
	toolbar.object_lit_toggled.connect(_on_object_lit_toggled)
	toolbar.object_shadow_toggled.connect(_on_object_shadow_toggled)
	if Engine.is_editor_hint():
		var ed_settings := EditorInterface.get_editor_settings()
		if ed_settings != null:
			if ed_settings.has_setting("poibuilder/toolbar/rows_mode"):
				toolbar.set_rows_mode(int(ed_settings.get_setting("poibuilder/toolbar/rows_mode")))
			elif ed_settings.has_setting("poibuilder/toolbar/two_rows"):
				toolbar.set_two_rows(bool(ed_settings.get_setting("poibuilder/toolbar/two_rows")))
	_add_toolbar_row_below_3d_toolbar()
	_export_dialog = PBExportDialog.new()
	if Engine.is_editor_hint():
		var base := EditorInterface.get_base_control()
		if base != null:
			base.add_child(_export_dialog)
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
	tool_overlay.edit_params_requested.connect(_on_edit_params_requested)
	tool_overlay.edit_emitter_requested.connect(_on_edit_emitter_requested)
	tool_overlay.grid_setting_changed.connect(_on_grid_ui_setting)
	tool_overlay.grid_reset_pressed.connect(_on_grid_reset)
	tool_overlay.sync_grid(grid)
	tool_overlay.display_setting_changed.connect(_on_display_setting_changed)
	tool_overlay.display_reset_pressed.connect(_on_display_reset)
	tool_overlay.env_preset_requested.connect(_on_env_preset_requested)
	_load_display_settings()
	_add_overlay_to_3d_viewport(tool_overlay)

	# Live (x, y, z) cursor extents label next to mouse during shape creation
	_cursor_extents_label = Label.new()
	_cursor_extents_label.name = "PoiBuilderCursorExtents"
	_cursor_extents_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor_extents_label.add_theme_color_override("font_color", Color.WHITE)
	_cursor_extents_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_cursor_extents_label.add_theme_constant_override("outline_size", 8)
	_cursor_extents_label.add_theme_font_size_override("font_size", 14)
	_cursor_extents_label.visible = false
	_cursor_extents_label.z_index = 100
	_add_overlay_to_3d_viewport(_cursor_extents_label)
	# Top-center mode banner (paint / stamp / sprite / shape mode readout)
	mode_banner = PBModeBanner.new()
	mode_banner.z_index = 90
	_add_overlay_to_3d_viewport(mode_banner)
	# Material drag-and-drop overlay in the 3D viewport
	material_drop_overlay = PBMaterialDropOverlay.new()
	material_drop_overlay.plugin = self
	_add_overlay_to_3d_viewport(material_drop_overlay)
	# Material & UV Dock panel (DOCK_SLOT_RIGHT_UL)
	material_dock = PBMaterialDock.new()
	material_dock.plugin = self
	material_dock.editor = editor
	material_dock.visible = true
	material_dock.set_paint_controller(paint_controller)
	material_dock.sprite_placer = sprite_placer
	material_dock.particle_placer = particle_placer
	material_dock.dock_mode_changed.connect(_on_dock_mode_changed)
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, material_dock)
	_setup_ideal_dock_layout.call_deferred()
	# Dedicated 2D UV Editor Panel (Bottom dock)
	uv_editor_panel = PBUvEditorPanel.new()
	uv_editor_panel.editor = editor
	uv_editor_panel.plugin = self
	if Engine.is_editor_hint():
		_uv_bottom_button = add_control_to_bottom_panel(uv_editor_panel, "UV Editor")
	uv_editor_panel.pop_out_toggled.connect(_on_uv_pop_out_toggled)
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
	if ngon_drawer.is_active():
		var node := ngon_drawer.preview_node
		ngon_drawer.reset()
		if node != null and is_instance_valid(node) and node.get_parent() != null:
			node.get_parent().remove_child(node)
			node.queue_free()

	if shape_creator.is_active():
		var node := shape_creator.preview_node
		shape_creator.reset()
		if node != null and is_instance_valid(node) and node.get_parent() != null:
			node.get_parent().remove_child(node)
			node.queue_free()


	if sprite_placer != null and sprite_placer.is_active():
		sprite_placer.abort()
	if particle_placer != null and particle_placer.is_active():
		particle_placer.abort()
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
		if is_instance_valid(toolbar) and toolbar.get_parent() != null:
			toolbar.get_parent().remove_child(toolbar)
			toolbar.queue_free()
		toolbar = null
	if _toolbar_anchor:
		if is_instance_valid(_toolbar_anchor) and _toolbar_anchor.get_parent() != null:
			remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _toolbar_anchor)
			_toolbar_anchor.queue_free()
		_toolbar_anchor = null
	# Remove overlay panel
	if tool_overlay:
		if is_instance_valid(tool_overlay):
			tool_overlay.get_parent().remove_child(tool_overlay)
			tool_overlay.queue_free()
		tool_overlay = null
	# Remove mode banner
	if mode_banner != null:
		if is_instance_valid(mode_banner):
			if mode_banner.get_parent() != null:
				mode_banner.get_parent().remove_child(mode_banner)
			mode_banner.queue_free()
		mode_banner = null

	# Remove material dock and drop overlay
	if material_dock != null:
		remove_control_from_docks(material_dock)
		if is_instance_valid(material_dock):
			material_dock.queue_free()
	# Remove UV editor panel
	if uv_editor_panel != null:
		if not uv_editor_panel._is_floating and Engine.is_editor_hint():
			remove_control_from_bottom_panel(uv_editor_panel)
		if is_instance_valid(uv_editor_panel):
			uv_editor_panel.queue_free()
		uv_editor_panel = null
		_uv_bottom_button = null
	# Remove export dialog
	if _export_dialog != null:
		if is_instance_valid(_export_dialog) and _export_dialog.get_parent() != null:
			_export_dialog.get_parent().remove_child(_export_dialog)
			_export_dialog.queue_free()
		_export_dialog = null


	if material_drop_overlay != null:
		if is_instance_valid(material_drop_overlay):
			material_drop_overlay.queue_free()
		material_drop_overlay = null
	if _cursor_extents_label != null:
		if is_instance_valid(_cursor_extents_label) and _cursor_extents_label.get_parent() != null:
			_cursor_extents_label.get_parent().remove_child(_cursor_extents_label)
			_cursor_extents_label.queue_free()
		_cursor_extents_label = null
	if paint_controller != null:
		paint_controller.cleanup_previews()

	# Remove custom type
	remove_custom_type("PBMesh")
	if grid_view != null:
		grid_view.detach_scenario()
	_reset_scrolling_texture_offsets()

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
		add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, toolbar)
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _toolbar_anchor)
		_toolbar_anchor.queue_free()
		_toolbar_anchor = null
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
	# A non-PBMesh primary (mixed selection, plain GLB mesh) does NOT clear the
	# active mesh here — _on_selection_changed owns that decision and runs after
	# this (the engine's selection_changed signal is deferred), so clearing
	# would only race the authoritative update.

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

	# Interactive N-gon drawing / Knife tool owns the mouse while active
	if ngon_drawer.is_active():
		return _ngon_drawer_input(camera, event)

	# Trim Walls session owns the mouse while armed (wall picking + preview)
	if trim_walls_tool.is_active():
		return _trim_walls_input(camera, event)

	# Shape creation owns the mouse while armed/dragging/modal (checked even
	# when nothing is selected — creation needs no editing context).
	if shape_creator.is_active():
		return _creation_input(camera, event)

	# Billboard Sprite Placer owns the mouse while active
	if sprite_placer != null and sprite_placer.is_active():
		var result := _sprite_placer_input(camera, event)
		# Joypad/controller events also arrive here and have no `position`.
		if event is InputEventMouse:
			_update_cursor_extents(event.position)
		return result
	# Particle emitter placement owns the mouse while active
	if particle_placer != null and particle_placer.is_active():
		var result := _particle_placer_input(camera, event)
		if event is InputEventMouse:
			_update_cursor_extents(event.position)
		return result
	# Texture splatting / Stamp tool owns the mouse while active
	if paint_controller != null and paint_controller.is_active():
		return _paint_controller_input(camera, event)

	# If an Edit Params, Bevel or Emitter session modal is open, handle its modal lifecycle:
	if _params_session_kind == "edit" or _params_session_kind == "bevel" or _params_session_kind == "emitter_edit":
		if event is InputEventKey and event.pressed:
			var k := event as InputEventKey
			if k.keycode == KEY_ESCAPE:
				_on_params_canceled()
				return AFTER_GUI_INPUT_STOP
			elif k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER:
				_on_params_applied()
				return AFTER_GUI_INPUT_STOP
			else:
				_on_params_applied()
				return AFTER_GUI_INPUT_PASS
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if _params_session_kind == "bevel":
				_on_params_applied()
				return AFTER_GUI_INPUT_STOP
			if logger:
				logger.info("plugin", "Params modal cancelled (viewport press)")
			_on_params_canceled()
			return AFTER_GUI_INPUT_PASS
	# Everything key-driven funnels through the rebindable action table BEFORE
	# the editing gate: grid keys work with nothing selected (the grid must be
	# adjustable before use), while action-internal context gates keep unbound
	# keys passing through as before.
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.keycode == KEY_V and not k.ctrl_pressed and not k.alt_pressed and not k.meta_pressed:
			gizmo_plugin.element_editor.vertex_snap_held = k.pressed
		if k.pressed:
			return _handle_action_key(k)

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
	var sp_active := sprite_placer != null and sprite_placer.is_active()
	var pp_active := particle_placer != null and particle_placer.is_active()
	var pb_context := editing or editor.active_mesh != null or shape_creator.is_active() or ngon_drawer.is_active() or sp_active or pp_active
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
		&"select_texture":
			if not pb_context:
				return AFTER_GUI_INPUT_PASS
			editor.select_mode = PBEditor.SelectMode.TEXTURE
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
		&"select_all":
			if not editing or editor.active_mesh == null:
				return AFTER_GUI_INPUT_PASS
			_perform_select_all()
		&"invert_selection":
			if not editing or editor.active_mesh == null:
				return AFTER_GUI_INPUT_PASS
			_perform_invert_selection()
		&"grow_selection":
			if not editing or editor.active_mesh == null:
				return AFTER_GUI_INPUT_PASS
			_perform_grow_selection()
		&"shrink_selection":
			if not editing or editor.active_mesh == null:
				return AFTER_GUI_INPUT_PASS
			_perform_shrink_selection()
		&"select_coplanar":
			if not editing or editor.active_mesh == null:
				return AFTER_GUI_INPUT_PASS
			_perform_select_coplanar()
		&"select_similar":
			if not editing or editor.active_mesh == null:
				return AFTER_GUI_INPUT_PASS
			_perform_select_similar()
		&"select_boundary":
			if not editing or editor.active_mesh == null:
				return AFTER_GUI_INPUT_PASS
			_perform_select_boundary()
		&"select_face_loop":
			if not editing or editor.active_mesh == null:
				return AFTER_GUI_INPUT_PASS
			_perform_select_face_loop(false)
		&"select_face_ring":
			if not editing or editor.active_mesh == null:
				return AFTER_GUI_INPUT_PASS
			_perform_select_face_loop(true)
		&"toggle_vertex_snap":
			gizmo_plugin.element_editor.vertex_snap_enabled = not gizmo_plugin.element_editor.vertex_snap_enabled
			if toolbar != null:
				toolbar.sync_snapping(
					gizmo_plugin.element_editor.vertex_snap_enabled,
					gizmo_plugin.element_editor.proportional_enabled,
					gizmo_plugin.element_editor.proportional_radius)
			if logger:
				logger.info("tools", "Vertex Snap %s" % ["ON" if gizmo_plugin.element_editor.vertex_snap_enabled else "OFF"])
		&"toggle_proportional":
			gizmo_plugin.element_editor.proportional_enabled = not gizmo_plugin.element_editor.proportional_enabled
			if logger:
				logger.info("tools", "Proportional Editing %s (radius=%.2f)" % [
					"ON" if gizmo_plugin.element_editor.proportional_enabled else "OFF",
					gizmo_plugin.element_editor.proportional_radius])
		&"env_dawn":
			_on_env_preset_requested("dawn")
		&"env_day":
			_on_env_preset_requested("day")
		&"env_dusk":
			_on_env_preset_requested("dusk")
		&"env_night":
			_on_env_preset_requested("night")
		&"env_cycle":
			_cycle_env_preset()
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
		if editor.is_editing() or editor.active_mesh != null or shape_creator.is_active() or ngon_drawer.is_active():
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
	elif action == &"tool_sprite":
		_enter_sprite_mode()
	elif action == &"obj_toggle_lit":
		if _selected_state_nodes().is_empty():
			return AFTER_GUI_INPUT_PASS
		_toggle_object_lit()
	elif action == &"obj_toggle_shadows":
		if _selected_state_nodes().is_empty():
			return AFTER_GUI_INPUT_PASS
		_toggle_object_shadow()
	else:
		return AFTER_GUI_INPUT_PASS
	return AFTER_GUI_INPUT_STOP
func _is_repeatable_grid_key(k: InputEventKey) -> bool:
	var act := PBActions.action_for(k, _settings)
	return act == &"grid_raise" or act == &"grid_lower"


# ==============================================================================
# Grid + Snapping (own grid, independent of the engine's 3D grid)
# ==============================================================================

## Persisted grid settings (Editor Settings keys; origin/elevation is
## session-only — a floating grid from yesterday's session would surprise).
const GRID_SETTING_PREFIX := "poibuilder/grid/"
const GRID_SETTING_KEYS := ["enabled", "unit", "subdivisions",
	"show_grid", "rotate_step_deg"]

func _load_grid_settings() -> void:
	grid.draw_on_grid = false
	if _settings == null or not _settings.has_method("has_setting"):
		return
	if _settings.has_setting(GRID_SETTING_PREFIX + "draw_on_grid"):
		_settings.set_setting(GRID_SETTING_PREFIX + "draw_on_grid", false)
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
		PBEditor.SelectMode.FACE, PBEditor.SelectMode.TEXTURE:
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
	# The LAST PBMesh in the list wins: get_selected_nodes() is in click order,
	# so this is the node the user clicked most recently — the same "primary"
	# object the engine hands _edit(). (Taking the first used to make a
	# two-mesh selection edit the OLDER mesh while the gizmo sat on the newer
	# one.) A mixed selection (PBMesh + plain MeshInstance3D, e.g. while
	# picking a CSG cutter) keeps the PBMesh active.
	# Unconditionally update active_mesh: if a non-PBMesh (or nothing) is selected,
	# active_mesh becomes null so PoiBuilder mode deactivates cleanly.
	editor.active_mesh = pb_mesh

	# A selected GPUParticles3D gets the overlay's Edit Emitter Properties
	# button (the fine-tuning surface for placed emitters). Exactly one.
	var emitter: GPUParticles3D = null
	for node in nodes:
		if node is GPUParticles3D:
			emitter = node as GPUParticles3D
			break
	# Sync the button ONLY on an actual flip: element clicks change the
	# selection constantly and must not queue a deferred overlay refresh each
	# time — the panel only needs to react when an emitter actually appears
	# in (or leaves) the selection.
	var emitter_present := emitter != null
	if tool_overlay != null and tool_overlay.emitter_props_available != emitter_present:
		tool_overlay.emitter_props_available = emitter_present
		tool_overlay.call_deferred("refresh")

	# While an element mode is active the scene selection stays narrowed to
	# ONE mesh (see _collapse_selection_to_active): ctrl/shift-adding another
	# node while editing therefore SWITCHES the edit target instead of
	# stacking a second whole-object gizmo that swallows element clicks.
	# (Multi-select workflows — moving several objects, CSG booleans, merge —
	# belong to object mode, where nothing is collapsed.)
	if editor.is_editing():
		_collapse_selection_to_active.call_deferred()

	# Selecting something else while a params session is open cancels it:
	# unconfirmed changes are reverted like clicking Cancel.
	# Re-entrant call from _finish_creation_session's own selection
	# change is a no-op (the session kind is already cleared).
	if _params_session_kind != "" or (tool_overlay != null and tool_overlay.params_open):
		if _params_session_kind == "create" and pb_mesh == shape_creator.preview_node:
			pass
		elif _params_session_kind == "bevel" and pb_mesh == _bevel_session_node:
			pass
		elif _params_session_kind == "edit" and pb_mesh == _params_edit_node:
			pass
		elif _params_session_kind == "emitter_edit" and emitter == _params_edit_emitter:
			pass
		elif _params_session_kind == "trim_walls":
			# A wall-picking session survives selection changes: stray clicks
			# that miss a wall select scene nodes but must not tear the
			# session down (only Esc / Cancel / Apply end it).
			pass
		else:
			if logger:
				logger.info("plugin", "Params session cancelled (selection changed)")
			_on_params_canceled()
	# Row-3 Lit / Cast Shadows toggles mirror the selection's combined state.
	_update_object_state_buttons()

# ==============================================================================
# Object State Toggles — Lit / Cast Shadows (row 3 + bindable hotkeys)
# ==============================================================================
# The toggles apply to EVERY selected object (PBMesh, MeshInstance3D, CSG
# primitive). Button semantics follow a mixed checkbox: all on = checked,
# all off = unchecked, mixed = unchecked — checking synchronizes the whole
# selection. All decisions live in PBObjectState (headless-testable); the
# plugin only wraps the returned records into undo actions.

func _selected_state_nodes() -> Array[GeometryInstance3D]:
	var selection: EditorSelection = get_editor_interface().get_selection()
	if selection == null:
		return []
	return PBObjectState.applicable_nodes(selection.get_selected_nodes())

func _update_object_state_buttons() -> void:
	if toolbar == null:
		return
	var nodes := _selected_state_nodes()
	if nodes.is_empty():
		toolbar.sync_object_state(0, 0, false)
		return
	toolbar.sync_object_state(
		PBObjectState.lit_state(nodes), PBObjectState.shadow_state(nodes), true)

## Hotkey semantics: flip the whole selection to the opposite of its
## combined state (mixed counts as "lit"/"casting" → all off).
func _toggle_object_lit() -> void:
	var nodes := _selected_state_nodes()
	if nodes.is_empty():
		return
	_apply_object_lit(nodes, PBObjectState.lit_state(nodes) != 1)

func _toggle_object_shadow() -> void:
	var nodes := _selected_state_nodes()
	if nodes.is_empty():
		return
	_apply_object_shadow(nodes, PBObjectState.shadow_state(nodes) != 1)

func _on_object_lit_toggled(pressed: bool) -> void:
	_apply_object_lit(_selected_state_nodes(), pressed)

func _on_object_shadow_toggled(pressed: bool) -> void:
	_apply_object_shadow(_selected_state_nodes(), pressed)

func _apply_object_lit(nodes: Array[GeometryInstance3D], lit: bool) -> void:
	var records: Array[Dictionary] = []
	for node in nodes:
		var rec := PBObjectState.set_node_lit(node, lit)
		if not rec.is_empty():
			records.append(rec)
	if records.is_empty():
		_update_object_state_buttons()
		return
	var undo := get_undo_redo()
	var context: Node = records[0]["node"] if records[0]["node"].is_inside_tree() else null
	undo.create_action("Toggle Lit" if lit else "Toggle Unlit", UndoRedo.MERGE_DISABLE, context)
	for rec in records:
		undo.add_do_method(self, "_apply_lit_record", rec, true)
		undo.add_undo_method(self, "_apply_lit_record", rec, false)
	undo.commit_action()
	_update_object_state_buttons()
	if logger:
		logger.info("tools", "%s %d object(s)" % ["Lit" if lit else "Unlit", records.size()])

func _apply_object_shadow(nodes: Array[GeometryInstance3D], cast: bool) -> void:
	var records: Array[Dictionary] = []
	for node in nodes:
		var rec := PBObjectState.set_node_shadow(node, cast)
		if not rec.is_empty():
			records.append(rec)
	if records.is_empty():
		_update_object_state_buttons()
		return
	var undo := get_undo_redo()
	var context: Node = records[0]["node"] if records[0]["node"].is_inside_tree() else null
	undo.create_action("Toggle Cast Shadows" if cast else "Toggle No Cast Shadows",
		UndoRedo.MERGE_DISABLE, context)
	for rec in records:
		undo.add_do_method(self, "_apply_shadow_record", rec, true)
		undo.add_undo_method(self, "_apply_shadow_record", rec, false)
	undo.commit_action()
	_update_object_state_buttons()
	if logger:
		logger.info("tools", "%s shadows on %d object(s)" % ["Cast" if cast else "Removed", records.size()])

## Replays one PBObjectState record; `forward` picks the new/old side.
func _apply_lit_record(rec: Dictionary, forward: bool) -> void:
	var node: Node = rec.get("node")
	if node == null or not is_instance_valid(node):
		return
	match rec.get("kind", ""):
		"pbmesh":
			var pb := node as PBMesh
			if pb == null or pb.pb_mesh_data == null:
				return
			var mats: Array = rec.get("new_materials") if forward else rec.get("old_materials")
			var typed: Array[Material] = []
			for m in mats:
				typed.append(m)
			pb.pb_mesh_data.materials = typed
			pb.rebuild()
		"surfaces", "override":
			var mi := node as MeshInstance3D
			if mi == null:
				return
			if rec.get("kind") == "override":
				mi.material_override = rec.get("new_override") if forward else rec.get("old_override")
			else:
				var overrides: Dictionary = rec.get("new_overrides") if forward else rec.get("old_overrides")
				for idx in overrides:
					mi.set_surface_override_material(int(idx), overrides[idx])
		"csg":
			var csg := node as CSGPrimitive3D
			if csg == null:
				return
			csg.material = rec.get("new_material") if forward else rec.get("old_material")

func _apply_shadow_record(rec: Dictionary, forward: bool) -> void:
	var node: Node = rec.get("node")
	if node == null or not is_instance_valid(node):
		return
	node.cast_shadow = rec.get("new") if forward else rec.get("old")

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
	if material_dock != null:
		material_dock.sync_selection()
	_sync_uv_editor_selection()

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
	if _params_session_kind != "" or (tool_overlay != null and tool_overlay.params_open):
		_on_params_applied()
	# ProBuilder parity: switching element modes CONVERTS the selection
	# (a face becomes its verts, selected verts become the faces they fully
	# cover, ...). The conversion rides the SAME code path as an ordinary
	# selection: PBSelection holds the converted ids, one seed id represents
	# the set in the engine's subgizmo selection (single-id script API), and
	# the element editor's conversion expansion makes drag/highlight/ops
	# treat it exactly like a hand-picked set. Empty conversions (OBJECT
	# mode, nothing selected, nothing survives) clear, as before.
	var source_faces := editor.selection.selected_faces.duplicate()
	var converted := PackedInt32Array()
	if editor.active_mesh != null and editor.active_mesh.pb_mesh_data != null \
			and editor.select_mode != PBEditor.SelectMode.OBJECT:
		converted = PBSelection.convert_between_modes(
			editor.active_mesh.pb_mesh_data, _last_select_mode, editor.select_mode,
			editor.selection.selected_vertices, editor.selection.selected_edges,
			editor.selection.selected_faces)
	_last_select_mode = editor.select_mode
	editor.selection.clear_all()
	editor.hover_id = -1
	_hover_drawn_last = -1
	gizmo_plugin.element_editor.reset_side_faces()
	if editor.active_mesh != null:
		if converted.is_empty():
			editor.active_mesh.clear_subgizmo_selection()
		else:
			_apply_selection_set(editor.active_mesh, converted, source_faces)
		editor.active_mesh.update_gizmos()
	_update_editing_context()
	# Element modes edit exactly ONE mesh: with several nodes selected the
	# engine keeps a whole-object transform gizmo on every one of them, and
	# that multi-node gizmo swallows the element clicks (faces hover but never
	# select). Entering an element mode therefore narrows the engine
	# selection to the active PBMesh — object mode stays free for the
	# multi-select workflows (move both, CSG booleans, merge).
	if editor.select_mode != PBEditor.SelectMode.OBJECT:
		_collapse_selection_to_active.call_deferred()
	if material_dock != null:
		material_dock.sync_selection()
	_sync_uv_editor_selection()

## Narrows the engine's scene selection to just the active PBMesh (deferred —
## the engine is still finishing its own selection change when the mode
## switch fires). No-op for single/empty selections.
func _collapse_selection_to_active() -> void:
	var mesh := editor.active_mesh
	if mesh == null or not is_instance_valid(mesh):
		return
	var sel: EditorSelection = get_editor_interface().get_selection()
	if sel == null or sel.get_selected_nodes().size() <= 1:
		return
	if not mesh.is_inside_tree():
		return
	if logger:
		logger.info("plugin", "Element mode edits one mesh — selection narrowed to '%s'" % mesh.name)
	sel.clear()
	sel.add_node(mesh)

## The element mode the selection currently lives in — the conversion's
## SOURCE when the mode changes (select_mode is already the TARGET by the
## time this handler runs).
var _last_select_mode: PBEditor.SelectMode = PBEditor.SelectMode.OBJECT

## Materializes an element selection set through the ordinary selection path.
## PBSelection gets the ids, and ONE seed id (the element nearest the set's
## centroid) carries the set in the engine via the conversion expansion —
## the seed reports the set's centroid as its pivot so the transform gizmo
## lands on the selection's center. `source_faces` (when coming from a face
## selection) keeps the gizmo oriented to the face the elements were
## selected FROM (ProBuilder pick-side UX). Callers: mode-switch conversion,
## bevel Apply (the new band), bridge/fill (the created faces).
func _apply_selection_set(mesh: PBMesh, ids: PackedInt32Array,
		source_faces: PackedInt32Array) -> void:
	var mesh_data: PBMeshData = mesh.pb_mesh_data
	var ee := gizmo_plugin.element_editor
	var seed := ee.seed_id_nearest_centroid(mesh_data, ids)
	if seed < 0:
		return
	ee.set_conversion_group(seed, ids)
	match editor.select_mode:
		PBEditor.SelectMode.VERTEX:
			editor.selection.set_vertices(ids)
		PBEditor.SelectMode.EDGE:
			var common := mesh_data.get_common_edges()
			var edges: Array[PBEdge] = []
			for eid in ids:
				if eid >= 0 and eid < common.size():
					edges.append(common[eid])
			editor.selection.set_edges(edges)
		PBEditor.SelectMode.FACE, PBEditor.SelectMode.TEXTURE:
			editor.selection.set_faces(ids)
	# Orientation continuity: coming FROM face mode, the seed's gizmo orients
	# to the nearest source face's normal, not an average over the mesh.
	if source_faces.size() > 0 and editor.select_mode != PBEditor.SelectMode.FACE \
			and editor.select_mode != PBEditor.SelectMode.TEXTURE:
		var origin: Vector3 = ee.element_origin(mesh_data, seed)
		var best := -1
		var best_dist := INF
		for fi in source_faces:
			if fi < 0 or fi >= mesh_data.faces.size() or mesh_data.faces[fi] == null:
				continue
			var d: float = ee.element_origin(mesh_data, fi).distance_squared_to(origin)
			if d < best_dist:
				best_dist = d
				best = fi
		if best >= 0:
			ee.pick_side_faces[seed] = best
	var gizmo := gizmo_plugin.gizmo_for_node(mesh)
	if gizmo != null:
		mesh.set_subgizmo_selection(gizmo, seed,
			ee.get_subgizmo_transform(mesh_data, mesh, seed))

func _on_element_selection_changed() -> void:
	if tool_overlay:
		tool_overlay.refresh()
	# Deferred: this fires from inside a gizmo redraw (the engine-selection
	# mirror) — the engine tool must not be flipped re-entrantly.
	_update_engine_tool.call_deferred()
	if material_dock != null:
		material_dock.sync_selection()
	_sync_uv_editor_selection()

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
	if _params_session_kind != "" or (tool_overlay != null and tool_overlay.params_open):
		_on_params_applied()
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
		var sc_active := shape_creator != null and shape_creator.is_active()
		var ng_active := ngon_drawer != null and ngon_drawer.is_active()
		var sp_active := sprite_placer != null and sprite_placer.is_active()
		var pp_active := particle_placer != null and particle_placer.is_active()
		var tw_active := trim_walls_tool != null and trim_walls_tool.is_active()
		var pb_context := mesh_selected or sc_active or ng_active or sp_active or pp_active or tw_active or grid.draw_on_grid or absf(grid.origin.y) > 0.0001
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

func _process(delta: float) -> void:
	# Live animated scrolling textures in 3D editor viewport
	if animate_scrolling_textures:
		_scroll_time += delta
		var now_msec := Time.get_ticks_msec()
		if now_msec - _last_scroll_scan_msec > 1500:
			_last_scroll_scan_msec = now_msec
			scan_scrolling_materials()

		if not _animated_materials.is_empty():
			var to_erase: Array = []
			for mat in _animated_materials.keys():
				if not is_instance_valid(mat):
					to_erase.append(mat)
					continue
				var entry: Dictionary = _animated_materials[mat]
				var speed: Vector2 = entry["speed"]
				if speed == Vector2.ZERO or not PBUv.has_scroll(mat):
					(mat as StandardMaterial3D).uv1_offset = entry["base_offset"]
					to_erase.append(mat)
					continue
				var base_off: Vector3 = entry["base_offset"]
				var cur_u := fposmod(base_off.x + speed.x * _scroll_time, 1000.0)
				var cur_v := fposmod(base_off.y + speed.y * _scroll_time, 1000.0)
				(mat as StandardMaterial3D).uv1_offset = Vector3(cur_u, cur_v, base_off.z)

			for m in to_erase:
				_animated_materials.erase(m)

	if grid_view == null:
		return
	var wants := show_grid_should_draw() and grid.show_grid
	var vp := get_editor_interface().get_editor_viewport_3d(0)
	var cam: Camera3D = null
	if vp != null:
		cam = vp.get_camera_3d()
		var w3d := vp.find_world_3d()
		if w3d != null:
			var cur_scenario := w3d.get_scenario()
			if grid_view.get_scenario() != cur_scenario:
				grid_view.attach_scenario(cur_scenario)
		if wants:
			grid_view.update(cam)
	grid_view.set_visible(wants)
	if tool_bridge != null and tool_bridge.is_ready():
		tool_bridge.set_engine_grid_hidden(wants, cam)
## The grid renders while any PoiBuilder context is active (a PBMesh is
## selected — object mode included — or shape creation is armed, or drawing
## on an elevated/custom grid, or grid settings panel is open).
func show_grid_should_draw() -> bool:
	var sc_active := shape_creator != null and shape_creator.is_active()
	var ng_active := ngon_drawer != null and ngon_drawer.is_active()
	var sp_active := sprite_placer != null and sprite_placer.is_active()
	var pp_active := particle_placer != null and particle_placer.is_active()
	return editor.active_mesh != null or sc_active or ng_active or sp_active or pp_active or grid.draw_on_grid or absf(grid.origin.y) > 0.0001 or _grid_panel_open
func _attach_grid_view_scenario() -> void:
	if grid_view == null:
		return
	var vp := get_editor_interface().get_editor_viewport_3d(0)
	if vp != null:
		vp.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
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

func set_animate_scrolling_textures(enabled: bool) -> void:
	animate_scrolling_textures = enabled
	var ep_settings: EditorSettings = get_editor_interface().get_editor_settings() if get_editor_interface() != null else null
	if ep_settings != null:
		ep_settings.set_setting("poibuilder/editor/animate_scrolling_textures", enabled)

func scan_scrolling_materials() -> void:
	var scene_root: Node = null
	if get_editor_interface() != null:
		scene_root = get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return
	_scan_node_scrolling_materials(scene_root)

func _scan_node_scrolling_materials(node: Node) -> void:
	if node is PBMesh:
		var pb: PBMesh = node
		if pb.pb_mesh_data != null:
			for mat in pb.pb_mesh_data.materials:
				if mat is StandardMaterial3D and PBUv.has_scroll(mat):
					_register_scrolling_mat(mat)
	elif node is MeshInstance3D:
		var mi: MeshInstance3D = node
		if mi.material_override is StandardMaterial3D and PBUv.has_scroll(mi.material_override):
			_register_scrolling_mat(mi.material_override)
		if mi.mesh != null:
			for s in range(mi.mesh.get_surface_count()):
				var mat := mi.get_surface_override_material(s)
				if mat == null:
					mat = mi.mesh.surface_get_material(s)
				if mat is StandardMaterial3D and PBUv.has_scroll(mat):
					_register_scrolling_mat(mat)
	for child in node.get_children():
		_scan_node_scrolling_materials(child)

func _register_scrolling_mat(mat: StandardMaterial3D) -> void:
	if not _animated_materials.has(mat):
		_animated_materials[mat] = {
			"speed": PBUv.get_scroll_speed(mat),
			"base_offset": mat.uv1_offset
		}
	else:
		_animated_materials[mat]["speed"] = PBUv.get_scroll_speed(mat)

func _reset_scrolling_texture_offsets() -> void:
	for mat in _animated_materials.keys():
		if is_instance_valid(mat):
			var entry: Dictionary = _animated_materials[mat]
			(mat as StandardMaterial3D).uv1_offset = entry["base_offset"]
	_animated_materials.clear()
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

func _on_settings_panel_toggled(open: bool) -> void:
	if tool_overlay == null:
		return
	if open:
		tool_overlay.open_settings()
	else:
		tool_overlay.close_settings()
func _on_env_preset_requested(preset_name: String) -> void:
	var root: Node3D = null
	if Engine.is_editor_hint():
		root = EditorInterface.get_edited_scene_root() as Node3D
	if root == null and get_tree() != null:
		root = get_tree().current_scene as Node3D
	if root == null and is_inside_tree() and get_tree().root != null:
		for child in get_tree().root.get_children():
			if child is Node3D:
				root = child
				break
	if root == null:
		if logger:
			logger.warn("env", "Cannot apply environment preset: no active 3D scene root")
		return

	var ur = get_undo_redo() if Engine.is_editor_hint() else null
	var res := PBEnvironment.apply_preset(root, preset_name, ur)
	var norm_name: String = res.get("preset", preset_name)
	if toolbar != null:
		toolbar.set_env_preset(norm_name)
	if tool_overlay != null:
		tool_overlay.set_active_env_preset(norm_name)
	if logger:
		logger.info("env", "Applied environment preset '%s'" % norm_name)

func _cycle_env_preset() -> void:
	var names := PBEnvironment.get_preset_names()
	var root: Node3D = null
	if Engine.is_editor_hint():
		root = EditorInterface.get_edited_scene_root() as Node3D
	var cur: String = root.get_meta("poi_env_preset", "day") if root != null else "day"
	var idx := names.find(cur)
	var next_idx := (idx + 1) % names.size()
	_on_env_preset_requested(names[next_idx])

func _on_export_requested() -> void:
	if paint_controller != null:
		paint_controller.mode = PBPaintController.Mode.NONE
	if _export_dialog == null:
		return
	var scene: Node = null
	if Engine.is_editor_hint():
		scene = EditorInterface.get_edited_scene_root()
	if scene == null and get_tree() != null:
		scene = get_tree().current_scene
	if scene == null and is_inside_tree():
		scene = get_tree().root
	_export_dialog.open_dialog(scene)

func _on_docs_requested() -> void:
	var script_res := get_script() as Script
	var plugin_dir := ""
	if script_res != null:
		plugin_dir = script_res.resource_path.get_base_dir()
	var candidates: PackedStringArray = PackedStringArray()
	if plugin_dir != "":
		candidates.append(ProjectSettings.globalize_path(plugin_dir.path_join("docs-site/index.html")))
		var global_plugin := ProjectSettings.globalize_path(plugin_dir)
		# project/addons/poibuilder → repo root
		var repo := global_plugin.get_base_dir().get_base_dir().get_base_dir()
		candidates.append(repo.path_join("docs/site/out/index.html"))
	for path in candidates:
		if FileAccess.file_exists(path):
			OS.shell_open(path)
			if logger:
				logger.info("plugin", "Opened docs at %s" % path)
			return
	OS.shell_open("https://francesco149.github.io/poibuilder/")
	if logger:
		logger.info("plugin", "Opened docs on GitHub Pages (no local site built)")


func _on_toolbar_split_rows_toggled(two_rows: bool) -> void:
	if Engine.is_editor_hint():
		var ed_settings := EditorInterface.get_editor_settings()
		if ed_settings != null:
			ed_settings.set_setting("poibuilder/toolbar/rows_mode", toolbar.rows_mode)
			ed_settings.set_setting("poibuilder/toolbar/two_rows", two_rows)
func _load_display_settings() -> void:
	var grid_op := 0.7
	var wire_op := 0.7
	var sel_op := 0.25
	var hov_op := 0.25
	if _settings != null:
		if _settings.has_setting("poibuilder/display/grid_opacity"):
			grid_op = float(_settings.get_setting("poibuilder/display/grid_opacity"))
		if _settings.has_setting("poibuilder/display/wireframe_opacity"):
			wire_op = float(_settings.get_setting("poibuilder/display/wireframe_opacity"))
		if _settings.has_setting("poibuilder/display/selection_opacity_v2"):
			sel_op = float(_settings.get_setting("poibuilder/display/selection_opacity_v2"))
		if _settings.has_setting("poibuilder/display/hover_opacity_v2"):
			hov_op = float(_settings.get_setting("poibuilder/display/hover_opacity_v2"))

	grid_view.grid_opacity = grid_op
	gizmo_plugin.apply_display_opacities(wire_op, sel_op, hov_op)
	tool_overlay.sync_display_settings(grid_op, wire_op, sel_op, hov_op)

func _on_display_setting_changed(setting_name: StringName, value: float) -> void:
	match setting_name:
		&"grid_opacity":
			grid_view.grid_opacity = value
		&"wireframe_opacity":
			gizmo_plugin.apply_display_opacities(value, gizmo_plugin.selection_opacity, gizmo_plugin.hover_opacity)
			if editor.active_mesh != null:
				editor.active_mesh.update_gizmos()
		&"selection_opacity":
			gizmo_plugin.apply_display_opacities(gizmo_plugin.wireframe_opacity, value, gizmo_plugin.hover_opacity)
			if editor.active_mesh != null:
				editor.active_mesh.update_gizmos()
		&"hover_opacity":
			gizmo_plugin.apply_display_opacities(gizmo_plugin.wireframe_opacity, gizmo_plugin.selection_opacity, value)
			if editor.active_mesh != null:
				editor.active_mesh.update_gizmos()
	if _settings != null:
		var key := String(setting_name)
		if key == "selection_opacity" or key == "hover_opacity":
			key += "_v2"
		_settings.set_setting("poibuilder/display/" + key, value)

func _on_display_reset() -> void:
	_on_display_setting_changed(&"grid_opacity", 0.7)
	_on_display_setting_changed(&"wireframe_opacity", 0.7)
	_on_display_setting_changed(&"selection_opacity", 0.25)
	_on_display_setting_changed(&"hover_opacity", 0.25)
	tool_overlay.sync_display_settings(0.7, 0.7, 0.25, 0.25)

## Focuses the Material & UV dock.
func focus_material_dock() -> void:
	if material_dock == null:
		return
	var editor_dock := material_dock.get_parent() as Control
	if editor_dock != null:
		editor_dock.show()
		var tab_container := editor_dock.get_parent() as TabContainer
		if tab_container != null:
			tab_container.current_tab = editor_dock.get_index()
			if tab_container.has_method("get_tab_bar"):
				var tb = tab_container.call("get_tab_bar")
				if tb != null and tb.has_method("grab_focus"):
					tb.call("grab_focus", true)
	material_dock.show()
	material_dock.sync_selection()

## Focuses or opens the UV Editor bottom dock panel.
func focus_uv_editor() -> void:
	if uv_editor_panel == null:
		return
	if uv_editor_panel._is_floating:
		if uv_editor_panel._floating_window != null:
			uv_editor_panel._floating_window.show()
			uv_editor_panel._floating_window.grab_focus()
	else:
		if Engine.is_editor_hint():
			make_bottom_panel_item_visible(uv_editor_panel)
	_sync_uv_editor_selection()

func _on_uv_pop_out_toggled(floating: bool) -> void:
	if not Engine.is_editor_hint():
		return
	if floating:
		remove_control_from_bottom_panel(uv_editor_panel)
		_uv_bottom_button = null
	else:
		_uv_bottom_button = add_control_to_bottom_panel(uv_editor_panel, "UV Editor")
		make_bottom_panel_item_visible(uv_editor_panel)

func _sync_uv_editor_selection() -> void:
	if uv_editor_panel == null:
		return
	if uv_editor_panel._syncing_selection:
		return
	if uv_editor_panel.active_mesh != editor.active_mesh:
		uv_editor_panel.active_mesh = editor.active_mesh
	if editor.active_mesh != null and editor.selection != null:
		if uv_editor_panel.has_method("sync_selection_from_3d_state"):
			uv_editor_panel.sync_selection_from_3d_state(editor.select_mode, editor.selection)
		else:
			var sel_faces: Array = []
			for fi in editor.selection.selected_faces:
				sel_faces.append(fi)
			uv_editor_panel.sync_selection_from_3d(sel_faces)

## Programmatically selects a subgizmo element (vertex common_idx, common_edge id, or face index) on `mesh`.
func select_subgizmo_element(mesh: PBMesh, id: int) -> void:
	if mesh == null:
		return
	var gizmo := gizmo_plugin.gizmo_for_node(mesh)
	if gizmo != null:
		if id >= 0:
			var xf := gizmo_plugin.element_editor.get_subgizmo_transform(mesh.pb_mesh_data, mesh, id)
			mesh.set_subgizmo_selection(gizmo, id, xf)
		else:
			mesh.clear_subgizmo_selection()
	mesh.update_gizmos()
## Moves Inspector and other standard docks from DockSlotRightUL to DockSlotRightUR,
## leaving DockSlotRightUL exclusively for PoiBuilder's Material & UV dock.
func _setup_ideal_dock_layout() -> void:
	if material_dock == null:
		return
	var editor_dock := material_dock.get_parent() as Control
	if editor_dock == null:
		return
	var ul_container := editor_dock.get_parent() as TabContainer
	if ul_container == null:
		return

	# Find the main split containing right_l_vsplit and right_r_vsplit
	var vsplit_l := ul_container.get_parent()
	if vsplit_l == null:
		return
	var main_hsplit := vsplit_l.get_parent()
	if main_hsplit == null:
		return

	# Find right_r_vsplit and its DockSlotRightUR
	var ur_container: TabContainer = null
	for child in main_hsplit.get_children():
		if child != vsplit_l and child.name == "DockVSplitRightR":
			for sub in child.get_children():
				if sub is TabContainer and sub.name == "DockSlotRightUR":
					ur_container = sub
					break
			break

	if ur_container == null:
		return

	# Move existing non-PoiBuilder docks (Inspector, Node, Groups, etc.)
	# from DockSlotRightUL to DockSlotRightUR.
	var to_move: Array[Node] = []
	for child in ul_container.get_children():
		if child != editor_dock and not (child is TabBar) and not (child is Popup):
			to_move.append(child)

	for node in to_move:
		node.reparent(ur_container)

	if ur_container.get_tab_count() > 0:
		ur_container.current_tab = 0

## Applies a material to the given faces of a mesh with full undo/redo.
## The incoming material is PREPARED first (PBApplyPrep): texture transparency
## is enabled from the texture's pixels (matching what the retro bake does),
## and the faces' current scroll speed is carried over so re-skinning a
## scrolling surface keeps it scrolling instead of silently stopping it.
func apply_faces_material(mesh: PBMesh, target_faces: Array, material: Material) -> void:
	if mesh == null or mesh.pb_mesh_data == null or target_faces.is_empty() or material == null:
		return

	var previous: Material = mesh.pb_mesh_data.get_face_material(target_faces[0])
	var prepared := PBApplyPrep.prepare(material, previous)
	if prepared != material and logger:
		logger.info("materials", "Applied material prepared: transparency/scroll carried from %s"
			% (previous.resource_name if previous != null else "(none)"))

	var before := PBCommand.copy_mesh_data(mesh.pb_mesh_data)
	mesh.pb_mesh_data.set_faces_material(target_faces, prepared)
	var after := PBCommand.copy_mesh_data(mesh.pb_mesh_data)

	var undo := get_undo_redo()
	undo.create_action("Apply Material to Faces", UndoRedo.MERGE_DISABLE, mesh)
	undo.add_do_method(self, "_restore_mesh_snapshot", mesh.get_instance_id(), after)
	undo.add_undo_method(self, "_restore_mesh_snapshot", mesh.get_instance_id(), before)
	undo.commit_action()

	mesh.rebuild()
	mesh.update_gizmos()
	# Re-register immediately: a scrolling material must not wait for the next
	# periodic scan (up to 1.5 s of visible stillness after every change).
	scan_scrolling_materials()
	if material_dock != null:
		material_dock.sync_selection()
	if logger:
		var mat_name := prepared.resource_name if not prepared.resource_name.is_empty() else prepared.resource_path.get_file()
		logger.info("materials", "Applied material '%s' to %d face(s) on %s" % [mat_name, target_faces.size(), mesh.name])
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
func _on_drag_topology_committed(mesh: PBMesh, new_face_ids: PackedInt32Array = PackedInt32Array()) -> void:
	editor.hover_id = -1
	_hover_drawn_last = -1
	editor.selection.clear_all()
	gizmo_plugin.element_editor.reset_side_faces()
	mesh.clear_subgizmo_selection()
	# Ops that create faces select their output — same rule as the toolbar
	# ops. Without this, a shift+drag extrude of a converted/grouped set
	# (coplanar, similar, mode-switch) left NOTHING selected: the gizmo
	# dropped back to the whole-object pivot and the overlay count went to
	# zero/one even though the whole set had been extruded.
	if not new_face_ids.is_empty() and editor.select_mode == PBEditor.SelectMode.FACE \
			and is_instance_valid(mesh) and mesh.pb_mesh_data != null:
		_apply_selection_set(mesh, new_face_ids, PackedInt32Array())
	mesh.update_gizmos()

# ==============================================================================
# Mesh Operations (overlay OPERATIONS section)
# ==============================================================================

## Numeric params for the toolbar op buttons. The LIVE equivalents are the
## gestures: Shift+Move extrudes, Shift+Scale insets (both drag-driven);
## these buttons use the session defaults.
const OP_EXTRUDE_DISTANCE := 0.25
const OP_INSET_AMOUNT := 0.25
const OP_BEVEL_AMOUNT := 0.1
const OP_BEVEL_SEGMENTS := 1
var op_bevel_amount: float = OP_BEVEL_AMOUNT
var op_bevel_segments: int = OP_BEVEL_SEGMENTS

## Edge ids the gizmo is actually highlighting: engine selection expanded
## through recorded loops. Toolbar clicks must not shrink this to the seed.
func _edge_ids_for_op(mesh_data: PBMeshData) -> PackedInt32Array:
	var seeds := PBMeshOps.common_edge_ids(mesh_data, editor.selection.selected_edges)
	var ee := gizmo_plugin.element_editor if gizmo_plugin != null else null
	if ee == null:
		return seeds
	if seeds.is_empty() and not ee.selected_loops.is_empty():
		seeds = PackedInt32Array()
		for k in ee.selected_loops.keys():
			seeds.append(int(k))
	return ee.expand_edge_ids(mesh_data, seeds)

## Performs a mesh op from the toolbar on the current selection. Face-mode
## ops read the selected faces; edge extrude reads the selected edges. Undo
## goes through full-mesh snapshots (CmdMeshOp) — ops rewrite topology, so
## per-index payloads don't apply.
func _on_operation_requested(op_name: String) -> void:
	# Object-level ops act on the SCENE selection (plain MeshInstance3D /
	# CSGShape3D nodes, or several PBMeshes at once) — they must run even when
	# nothing is being element-edited: poibuilderizing a raw GLB mesh happens
	# exactly when NO PBMesh is active, so these sit BEFORE the editing gate.
	if op_name == "poibuilderize" or op_name == "probuilderize":
		_perform_poibuilderize()
		return
	if op_name == "csg_union":
		_perform_csg_boolean(PBCsg.BooleanOp.UNION)
		return
	if op_name == "csg_subtract":
		_perform_csg_boolean(PBCsg.BooleanOp.SUBTRACT)
		return
	if op_name == "csg_intersect":
		_perform_csg_boolean(PBCsg.BooleanOp.INTERSECT)
		return
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
	if op_name == "knife_tool":
		_start_knife_tool()
		return

	if op_name == "select_all":
		_perform_select_all()
		return
	if op_name == "invert_selection":
		_perform_invert_selection()
		return
	if op_name == "grow_selection":
		_perform_grow_selection()
		return
	if op_name == "shrink_selection":
		_perform_shrink_selection()
		return
	if op_name == "select_coplanar":
		_perform_select_coplanar()
		return
	if op_name == "select_similar":
		_perform_select_similar()
		return
	if op_name == "select_boundary":
		_perform_select_boundary()
		return
	if op_name == "select_face_loop":
		_perform_select_face_loop(false)
		return
	if op_name == "select_face_ring":
		_perform_select_face_loop(true)
		return
	if op_name == "toggle_vertex_snap":
		gizmo_plugin.element_editor.vertex_snap_enabled = not gizmo_plugin.element_editor.vertex_snap_enabled
		if toolbar != null:
			toolbar.sync_snapping(
				gizmo_plugin.element_editor.vertex_snap_enabled,
				gizmo_plugin.element_editor.proportional_enabled,
				gizmo_plugin.element_editor.proportional_radius)
		return
	if op_name == "merge_objects":
		_perform_merge_objects()
		return
	if op_name == "mirror_object":
		_perform_mirror_object()
		return
	if op_name == "center_pivot":
		_perform_center_pivot()
		return
	if op_name == "freeze_transform":
		_perform_freeze_transform()
		return
	if op_name == "smooth_auto":
		_perform_auto_smooth()
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
			var edge_ids := _edge_ids_for_op(mesh_data)
			result = PBMeshOps.extrude_edges(mesh_data, edge_ids, distance)
		"insert_edge_loop":
			var loop_ids := _edge_ids_for_op(mesh_data)
			result = PBMeshOps.insert_edge_loop(mesh_data, loop_ids)
		"bridge_edges":
			var edge_ids := _edge_ids_for_op(mesh_data)
			result = PBMeshOps.bridge_edges(mesh_data, edge_ids)
		"connect_edges":
			if editor.select_mode == PBEditor.SelectMode.VERTEX:
				result = PBMeshOps.connect_vertices(mesh_data, selection.selected_vertices.duplicate())
			else:
				var edge_ids := _edge_ids_for_op(mesh_data)
				result = PBMeshOps.connect_edges(mesh_data, edge_ids)
		"connect_vertices":
			result = PBMeshOps.connect_vertices(mesh_data, selection.selected_vertices.duplicate())
		"collapse_elements":
			var elem_ids: PackedInt32Array
			match editor.select_mode:
				PBEditor.SelectMode.VERTEX:
					elem_ids = selection.selected_vertices.duplicate()
				PBEditor.SelectMode.EDGE:
					elem_ids = _edge_ids_for_op(mesh_data)
				PBEditor.SelectMode.FACE:
					elem_ids = selection.selected_faces.duplicate()
			result = PBMeshOps.collapse_elements(mesh_data, int(editor.select_mode), elem_ids)
		"fill_hole":
			var edge_ids := _edge_ids_for_op(mesh_data)
			result = PBMeshOps.fill_hole(mesh_data, edge_ids)
		"bevel_edges":
			var is_face_bevel := false
			var edge_ids: PackedInt32Array
			if editor.select_mode == PBEditor.SelectMode.FACE:
				if selection.selected_faces.size() == mesh_data.faces.size():
					edge_ids = PBMeshOps.face_edges_common_ids(mesh_data, selection.selected_faces)
				else:
					is_face_bevel = true
			else:
				edge_ids = _edge_ids_for_op(mesh_data)


			if not is_face_bevel and edge_ids.is_empty():
				return
			if is_face_bevel and selection.selected_faces.is_empty():
				return

			var shortest_l := INF
			if is_face_bevel:
				for fi in selection.selected_faces:
					if fi >= 0 and fi < mesh_data.faces.size():
						var f := mesh_data.faces[fi]
						if f != null:
							for e in f.get_edges():
								var l := mesh_data.positions[e.a].distance_to(mesh_data.positions[e.b])
								if l > 0.0001 and l < shortest_l:
									shortest_l = l
			else:
				var common := mesh_data.get_common_edges()
				for eid in edge_ids:
					if eid >= 0 and eid < common.size():
						var ce := common[eid]
						var l := mesh_data.positions[ce.a].distance_to(mesh_data.positions[ce.b])
						if l > 0.0001 and l < shortest_l:
							shortest_l = l

			var eff_amount := op_bevel_amount
			var pre_snapshot := PBCommand.copy_mesh_data(mesh_data)
			var faces_to_bevel := selection.selected_faces.duplicate()
			var edges_to_bevel: Array[PBEdge] = []
			if not is_face_bevel:
				var common_store := mesh_data.get_common_edges()
				for eid in edge_ids:
					if eid >= 0 and eid < common_store.size():
						edges_to_bevel.append(common_store[eid])
			else:
				edges_to_bevel = selection.selected_edges.duplicate()


			if is_face_bevel:
				result = PBMeshOps.bevel_faces(mesh_data, faces_to_bevel, eff_amount, op_bevel_segments)
			else:
				result = PBMeshOps.bevel_edges(mesh_data, edge_ids, eff_amount, op_bevel_segments)

			if result.get("ok", false):
				if tool_overlay != null:
					_start_bevel_modal(mesh, is_face_bevel, faces_to_bevel, edges_to_bevel, float(result.get("max_amount", shortest_l)), eff_amount, result.get("new_face_ids", PackedInt32Array()), pre_snapshot)
					return
				_finish_mesh_op(mesh, op_name, int(result["new_face_ids"].size()), result.get("new_face_ids", PackedInt32Array()))
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
	_finish_mesh_op(mesh, op_name, int(result["new_face_ids"].size()), result.get("new_face_ids", PackedInt32Array()))
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
## selection and our mirror are both stale — clear them and re-render. Ops
## that CREATE faces (bridge, fill hole) select their output through the
## ordinary selection path so the gizmo lands on the new geometry instead
## of going dead until the next click.
func _finish_mesh_op(mesh: PBMesh, op_name: String, new_face_count: int, created_faces: PackedInt32Array = PackedInt32Array()) -> void:
	editor.hover_id = -1
	_hover_drawn_last = -1
	gizmo_plugin.element_editor.reset_side_faces()
	mesh.rebuild()
	editor.selection.clear_all()
	mesh.clear_subgizmo_selection()
	if (op_name == "bridge_edges" or op_name == "fill_hole") and not created_faces.is_empty():
		editor.select_mode = PBEditor.SelectMode.FACE
		_apply_selection_set(mesh, created_faces, PackedInt32Array())
	if mesh.pb_mesh_data != null:
		mesh.pb_mesh_data.shape_edited = true
	mesh.update_gizmos()
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
	"knife_tool": "Knife Cut",
	"bevel_edges": "Bevel Edges",
	"bridge_edges": "Bridge Edges",
	"connect_edges": "Connect",
	"connect_vertices": "Connect Vertices",
	"collapse_elements": "Collapse",
	"fill_hole": "Fill Hole",
}
func _perform_select_all() -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.pb_mesh_data == null:
		return
	var ids := PBSelectionOps.get_all_ids(mesh.pb_mesh_data, editor.select_mode)
	if not ids.is_empty():
		_apply_selection_set(mesh, ids, PackedInt32Array())
	mesh.update_gizmos()

func _perform_invert_selection() -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.pb_mesh_data == null:
		return
	var cur_ids := editor.selection.get_selected_ids(editor.select_mode)
	var inv_ids := PBSelectionOps.get_inverted_ids(mesh.pb_mesh_data, cur_ids, editor.select_mode)
	if inv_ids.is_empty():
		editor.selection.clear_all()
		var gizmo := gizmo_plugin.gizmo_for_node(mesh)
		if gizmo != null:
			mesh.clear_subgizmo_selection()
	else:
		_apply_selection_set(mesh, inv_ids, PackedInt32Array())
	mesh.update_gizmos()

func _perform_grow_selection() -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.pb_mesh_data == null:
		return
	editor.selection.grow_selection(editor.select_mode)
	var ids := editor.selection.get_selected_ids(editor.select_mode)
	if not ids.is_empty():
		_apply_selection_set(mesh, ids, PackedInt32Array())
	mesh.update_gizmos()

func _perform_shrink_selection() -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.pb_mesh_data == null:
		return
	editor.selection.shrink_selection(editor.select_mode)
	var ids := editor.selection.get_selected_ids(editor.select_mode)
	if ids.is_empty():
		editor.selection.clear_all()
		var gizmo := gizmo_plugin.gizmo_for_node(mesh)
		if gizmo != null:
			mesh.clear_subgizmo_selection()
	else:
		_apply_selection_set(mesh, ids, PackedInt32Array())
	mesh.update_gizmos()

func _perform_select_coplanar() -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.pb_mesh_data == null or editor.select_mode != PBEditor.SelectMode.FACE:
		return
	editor.selection.select_coplanar()
	var ids := editor.selection.selected_faces.duplicate()
	if not ids.is_empty():
		_apply_selection_set(mesh, ids, PackedInt32Array())
	mesh.update_gizmos()

func _perform_select_similar(criteria: String = "material") -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.pb_mesh_data == null or editor.select_mode != PBEditor.SelectMode.FACE:
		return
	editor.selection.select_similar(criteria)
	var ids := editor.selection.selected_faces.duplicate()
	if not ids.is_empty():
		_apply_selection_set(mesh, ids, PackedInt32Array())
	mesh.update_gizmos()

func _perform_select_boundary() -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.pb_mesh_data == null:
		return
	editor.select_mode = PBEditor.SelectMode.EDGE
	var ids := PBSelectionOps.select_boundary_edge_ids(mesh.pb_mesh_data)
	if not ids.is_empty():
		_apply_selection_set(mesh, ids, PackedInt32Array())
	mesh.update_gizmos()

func _perform_select_face_loop(ring: bool = false) -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.pb_mesh_data == null or editor.select_mode != PBEditor.SelectMode.FACE:
		return
	editor.selection.select_face_loop(ring)
	var ids := editor.selection.selected_faces.duplicate()
	if not ids.is_empty():
		_apply_selection_set(mesh, ids, PackedInt32Array())
	mesh.update_gizmos()
func _perform_merge_objects() -> void:
	var ei := get_editor_interface()
	var selected_nodes: Array[Node] = []
	if ei != null and ei.get_selection() != null:
		selected_nodes = ei.get_selection().get_selected_nodes()
	var pb_meshes: Array[PBMesh] = []
	for n in selected_nodes:
		if n is PBMesh and (n as PBMesh).pb_mesh_data != null:
			pb_meshes.append(n as PBMesh)
	if pb_meshes.size() < 2:
		if logger:
			logger.warn("plugin", "Merge Objects requires at least 2 selected PBMesh nodes")
		return
	var target := pb_meshes[0]
	var donors: Array[PBMesh] = []
	for i in range(1, pb_meshes.size()):
		donors.append(pb_meshes[i])
	var success := PBObjectOps.merge_meshes(target, donors)
	if success:
		for d in donors:
			if d.get_parent() != null:
				d.get_parent().remove_child(d)
		if logger:
			logger.info("plugin", "Merged %d objects into %s" % [donors.size(), target.name])

func _perform_mirror_object() -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.pb_mesh_data == null:
		return
	var success := PBObjectOps.mirror_mesh_data(mesh.pb_mesh_data, Vector3.AXIS_X)
	if success:
		mesh.rebuild()
		mesh.update_gizmos()
		if logger:
			logger.info("plugin", "Mirrored %s across X" % mesh.name)

func _perform_center_pivot() -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.pb_mesh_data == null:
		return
	var success := PBObjectOps.center_pivot(mesh)
	if success:
		mesh.update_gizmos()
		if logger:
			logger.info("plugin", "Centered pivot of %s" % mesh.name)

func _perform_freeze_transform() -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.pb_mesh_data == null:
		return
	var success := PBObjectOps.freeze_transform(mesh)
	if success:
		mesh.update_gizmos()
		if logger:
			logger.info("plugin", "Froze transform of %s" % mesh.name)

func _collect_convertible_nodes(nodes: Array[Node]) -> Array[Node]:
	var result: Array[Node] = []
	var seen: Dictionary = {}
	for root in nodes:
		if root == null:
			continue
		var stack: Array[Node] = [root]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			if seen.has(n):
				continue
			seen[n] = true
			if (n is MeshInstance3D and not (n is PBMesh)) or (n is CSGShape3D):
				result.append(n)
			for child in n.get_children():
				stack.append(child)
	return result

func _perform_poibuilderize() -> void:
	var ei := get_editor_interface()
	var selected_nodes: Array[Node] = []
	if ei != null and ei.get_selection() != null:
		selected_nodes = ei.get_selection().get_selected_nodes()
	if selected_nodes.is_empty() and editor.active_mesh != null:
		selected_nodes = [editor.active_mesh]

	var scene_root: Node = ei.get_edited_scene_root() if ei != null else null
	var candidates := _collect_convertible_nodes(selected_nodes)

	if candidates.is_empty():
		if logger:
			logger.warn("plugin", "Poibuilderize: select a MeshInstance3D, CSGShape3D, or a node with mesh children")
		return

	var undo_mgr := get_undo_redo()
	if undo_mgr != null:
		# Scene-history context (see the CSG action above): scene_root is
		# always in the edited scene; a context-less action would land in the
		# GLOBAL history and interleave with the engine's own scene actions.
		undo_mgr.create_action("Poibuilderize Meshes", UndoRedo.MERGE_DISABLE,
			scene_root if scene_root != null else candidates[0])

	var created_nodes: Array[PBMesh] = []
	for n in candidates:
		var pb: PBMesh = null
		if n is MeshInstance3D and not (n is PBMesh):
			pb = PBObjectOps.poibuilderize(n as MeshInstance3D)
		elif n is CSGShape3D:
			pb = PBObjectOps.poibuilderize_csg(n as CSGShape3D)

		if pb != null:
			var parent := n.get_parent()
			if parent == null and scene_root != null:
				parent = scene_root
			if parent != null:
				pb.transform = n.transform
				created_nodes.append(pb)
				# The whole swap runs through the undo do-methods: adding the
				# PBMesh directly here as well would make the committed
				# add_child a no-op error ("already has a parent") and leave
				# the action's bookkeeping out of sync with the tree.
				if undo_mgr != null:
					undo_mgr.add_do_reference(pb)
					undo_mgr.add_undo_reference(n)
					undo_mgr.add_do_method(parent, "add_child", pb)
					undo_mgr.add_do_method(self, "_own_node", pb)
					undo_mgr.add_do_method(parent, "remove_child", n)
					undo_mgr.add_undo_method(parent, "add_child", n)
					undo_mgr.add_undo_method(parent, "remove_child", pb)
				else:
					parent.add_child(pb)
					pb.owner = scene_root if scene_root != null else parent
					parent.remove_child(n)

	if undo_mgr != null:
		undo_mgr.commit_action()

	if not created_nodes.is_empty():
		if ei != null and ei.get_selection() != null:
			ei.get_selection().clear()
			for pb in created_nodes:
				ei.get_selection().add_node(pb)
			editor.active_mesh = created_nodes[0]
		if logger:
			logger.info("plugin", "Poibuilderized %d node(s) into editable PBMesh" % created_nodes.size())

func _perform_probuilderize() -> void:
	_perform_poibuilderize()

func _perform_csg_boolean(op: PBCsg.BooleanOp) -> void:
	var ei := get_editor_interface()
	var selected_nodes: Array[Node] = []
	if ei != null and ei.get_selection() != null:
		selected_nodes = ei.get_selection().get_selected_nodes()

	var candidates: Array[Node] = []
	for n in selected_nodes:
		if (n is PBMesh and (n as PBMesh).pb_mesh_data != null) or (n is CSGShape3D) or (n is MeshInstance3D and not (n is PBMesh)):
			candidates.append(n)

	if candidates.size() < 2:
		if logger:
			logger.warn("plugin", "CSG Booleans require 2 selected objects (Target and Cutter). Select both with Shift/Ctrl.")
		return

	# The SELECTION ORDER decides the operands — there is no hidden "active
	# mesh" when several nodes are selected: the FIRST-selected node is the
	# target, the LAST-selected node (the one you Shift/Ctrl-clicked last) is
	# the cutter. Select target first, then add the cutter.
	var target_node: Node = candidates[0]
	var cutter_node: Node = candidates[candidates.size() - 1]
	if target_node == cutter_node:
		if logger:
			logger.warn("plugin", "CSG Booleans require 2 different objects (target first, cutter last).")
		return
	if logger:
		logger.info("plugin", "CSG target: %s   cutter: %s" % [target_node.name, cutter_node.name])

	var target_mesh: PBMesh = null
	if target_node is PBMesh:
		target_mesh = target_node as PBMesh
	elif target_node is CSGShape3D:
		target_mesh = PBObjectOps.poibuilderize_csg(target_node as CSGShape3D)
	elif target_node is MeshInstance3D:
		target_mesh = PBObjectOps.poibuilderize(target_node as MeshInstance3D)

	if target_mesh == null or target_mesh.pb_mesh_data == null:
		if logger:
			logger.error("plugin", "CSG Error: Target object has no valid mesh")
		return

	var cutter_data: PBMeshData = null
	if cutter_node is PBMesh:
		cutter_data = (cutter_node as PBMesh).pb_mesh_data
	elif cutter_node is CSGShape3D:
		var tmp := PBObjectOps.poibuilderize_csg(cutter_node as CSGShape3D)
		if tmp != null:
			cutter_data = tmp.pb_mesh_data
			tmp.free()
	elif cutter_node is MeshInstance3D:
		var tmp := PBObjectOps.poibuilderize(cutter_node as MeshInstance3D)
		if tmp != null:
			cutter_data = tmp.pb_mesh_data
			tmp.free()

	if cutter_data == null:
		if logger:
			logger.error("plugin", "CSG Error: Cutter object has no valid mesh")
		return

	var target_xf: Transform3D = target_node.global_transform if target_node.is_inside_tree() else target_node.transform
	var cutter_xf: Transform3D = cutter_node.global_transform if cutter_node.is_inside_tree() else cutter_node.transform
	var rel_xf := target_xf.affine_inverse() * cutter_xf

	var res := PBCsg.perform_boolean(target_mesh.pb_mesh_data, cutter_data, op, rel_xf, get_tree())
	if not res.get("success", false):
		if logger:
			logger.error("plugin", "CSG Error: %s" % res.get("error", "Unknown error"))
		return

	var before_data := PBCommand.copy_mesh_data(target_mesh.pb_mesh_data)
	var after_data: PBMeshData = res["mesh_data"]

	var op_name_str: String = ["Union", "Intersect", "Subtract"][op]
	var undo_mgr := get_undo_redo()
	if undo_mgr != null:
		# The context object routes this action into the SCENE undo history.
		# Without it the action lands in the GLOBAL history, interleaves with
		# the engine's own scene actions (Translate etc.), and produces
		# "UndoRedo history mismatch" plus resync undos that detached the
		# restored cutter all over again.
		undo_mgr.create_action("CSG %s" % op_name_str, UndoRedo.MERGE_DISABLE, target_node)
		undo_mgr.add_do_method(self, "_restore_csg_mesh", target_mesh, after_data)
		undo_mgr.add_undo_method(self, "_restore_csg_mesh", target_mesh, before_data)
		var cutter_parent := cutter_node.get_parent()
		if cutter_parent != null:
			# The cutter swap follows the engine's own "Remove Node(s)"
			# convention (scene_tree_dock.cpp): a node REMOVED by the do gets
			# an UNDO reference — the detached cutter is freed only if the
			# action falls off the history tail, in its detached state. A DO
			# reference here was a crash: discard_redo() (the very next
			# commit after an undo) deletes do-referenced objects, so it
			# memdeleted the re-attached cutter under the editor — "invalid
			# callable" in add_do_method, then SIGSEGV.
			undo_mgr.add_undo_reference(cutter_node)
			undo_mgr.add_do_method(self, "_detach_node", cutter_node)
			undo_mgr.add_undo_method(self, "_reattach_csg_cutter", cutter_node, cutter_parent)
		undo_mgr.commit_action()
		# The cutter may have been the editor selection — a dangling selection
		# on a detached node breaks viewport picking until the next change.
		if ei != null and ei.get_selection() != null:
			var sel := ei.get_selection()
			sel.clear()
			if target_mesh.is_inside_tree():
				sel.add_node(target_mesh)
		editor.active_mesh = target_mesh
	else:
		target_mesh.pb_mesh_data = after_data
		target_mesh.rebuild()
		target_mesh.update_gizmos()
		if cutter_node.get_parent() != null:
			cutter_node.get_parent().remove_child(cutter_node)

	if logger:
		logger.info("plugin", "CSG %s committed successfully onto %s" % [op_name_str, target_mesh.name])

## Undo half of a CSG boolean: back into the tree, ownership restored to the
## edited scene, gizmo re-requested (a node whose gizmos were torn down on
## detach still renders — but no longer picks or draws its outline — until
## this runs).
func _reattach_csg_cutter(node: Node, parent: Node) -> void:
	if node == null or not is_instance_valid(node) \
			or parent == null or not is_instance_valid(parent):
		return
	if node.get_parent() == parent:
		return
	parent.add_child(node)
	node.owner = get_editor_interface().get_edited_scene_root()
	if node is Node3D:
		(node as Node3D).update_gizmos()

func _restore_csg_mesh(mesh: PBMesh, data: PBMeshData) -> void:
	if mesh != null and is_instance_valid(mesh):
		mesh.pb_mesh_data = PBCommand.copy_mesh_data(data)
		mesh.pb_mesh_data.shape_edited = true
		mesh.rebuild()
		mesh.update_gizmos()
func _perform_auto_smooth() -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.pb_mesh_data == null:
		return
	var count := PBSmoothGroups.auto_smooth(mesh.pb_mesh_data, 45.0)
	mesh.rebuild()
	mesh.update_gizmos()
	if logger:
		logger.info("plugin", "Auto-smoothed %s: created %d smoothing groups" % [mesh.name, count])

# ==============================================================================
# Shape Creation (drag base → height → params, ProBuilder-style)
# ==============================================================================


## What the overlay params modal is editing: "create" (a just-placed shape)
## or "edit" (Edit Params on a pristine factory shape).
var _params_session_kind: String = ""
var _params_edit_node: PBMesh = null
var _params_edit_snapshot: PBMeshData = null
var _params_edit_snapshot_cast_shadow: int = 0
var _bevel_session_node: PBMesh = null
var _bevel_session_snapshot: PBMeshData = null
var _bevel_session_mode: PBEditor.SelectMode = PBEditor.SelectMode.OBJECT
var _bevel_session_is_face_bevel: bool = false
var _bevel_session_faces: PackedInt32Array = PackedInt32Array()
var _bevel_session_edges: Array[PBEdge] = []
var _bevel_session_last_new_faces: PackedInt32Array = PackedInt32Array()
var _params_edit_values: Dictionary = {}

## The GPUParticles3D an "emitter_edit" params session is editing, plus the
## property snapshot (process_material / draw_pass_1 / amount / seed metas)
## Cancel restores and Apply wraps into one undo action.
var _params_edit_emitter: GPUParticles3D = null
var _params_edit_emitter_snapshot: Dictionary = {}

## A New Shape menu pick ARMS creation: nothing exists yet — the next LMB
## drag on any surface (PBMesh face or grid plane) draws the base. Any open
## params session is committed first (a create session in the modal applies;
## an Edit Params session commits) so the new shape never replaces the node
## a still-open dialog was editing.
func _on_shape_requested(shape_id: StringName) -> void:
	if _params_session_kind != "" or (tool_overlay != null and tool_overlay.params_open):
		if not trim_walls_tool.is_active():
			_on_params_applied()
	elif shape_creator.is_active():
		_creation_abort("a new shape was picked")
	elif ngon_drawer.is_active():
		_ngon_drawer_abort("a new shape was picked")
	if trim_walls_tool.is_active():
		_trim_walls_disarm("a new shape was picked")

	if shape_id == &"sprite":
		_enter_sprite_mode()
		return

	if shape_id == &"ngon" or shape_id == &"ngon_draw":
		_start_ngon_shape_tool()
		return
	shape_creator.arm(shape_id)
	# Trim depth carries across the project: a trim "starts at the last Depth
	# you set in this project (5 cm before you set one)" — it is never dragged,
	# so the typed value is the one thing that persists between trims.
	if shape_id == &"trim":
		_seed_trim_project_values()
	# Arming is a PoiBuilder context change too: the engine grid hides and
	# the elevated PB grid shows while drawing (engine-bridge a no-op).
	_update_editing_context()

	if shape_id == &"sprite":
		_set_creation_hint("%s — click a surface to anchor it (Esc cancels)"
			% String(shape_id).capitalize())
	elif PBShapeParams.commits_on_base_release(shape_id):
		_set_creation_hint("Trim — drag base along wall, release to commit (Esc cancels)")
	elif PBShapeParams.height_drags_offset(shape_id):
		_set_creation_hint("%s — drag out a sheet on any surface, then move to offset it (Ctrl: lock direction, Esc cancels)"
			% String(shape_id).capitalize())
	else:
		_set_creation_hint("%s — drag a base on any surface (Ctrl: lock direction, Esc cancels)" % String(shape_id).capitalize())
	if logger:
		logger.info("plugin", "Creating '%s' — drag on a surface to draw the base" % shape_id)

## Feeds the overlay's creation row so an armed/dragging session is never
## invisible (a sticky armed state used to swallow clicks "silently").
func _set_creation_hint(text: String) -> void:
	if tool_overlay != null:
		tool_overlay.set_creation_hint(text)

func _creation_input(camera: Camera3D, event: InputEvent) -> int:
	if event is InputEventWithModifiers:
		shape_creator.lock_direction = event.ctrl_pressed or Input.is_key_pressed(KEY_CTRL)
		if shape_creator.state == PBShapeCreator.State.HEIGHT:
			var alt_down: bool = event.alt_pressed or Input.is_key_pressed(KEY_ALT)
			if shape_creator.show_height_plane != alt_down:
				shape_creator.show_height_plane = alt_down
				_refresh_preview()
	elif event is InputEventKey:
		if shape_creator.state == PBShapeCreator.State.HEIGHT:
			var alt_down: bool = event.alt_pressed or Input.is_key_pressed(KEY_ALT)
			if shape_creator.show_height_plane != alt_down:
				shape_creator.show_height_plane = alt_down
				_refresh_preview()

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

	if event is InputEventKey and event.pressed:
		var k := event as InputEventKey
		if not k.echo or _is_repeatable_grid_key(k):
			if shape_creator.state != PBShapeCreator.State.PARAMS \
					and _handle_grid_action_key(k) == AFTER_GUI_INPUT_STOP:
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
			# AABB prefilter: a poibuilderized sculpt has thousands of faces,
			# so skip whole meshes the ray cannot hit before a nearer surface.
			var pb_span := PBPicking.ray_aabb_span(ray_o, ray_d, node.global_transform * node.get_aabb())
			if pb_span.x < 0.0 or pb_span.x >= best_t:
				continue
			var res := PBPicking.pick_face(node.pb_mesh_data, node.global_transform, ray_o, ray_d)
			if res.face_index >= 0 and res.distance < best_t:
				var normal := PBMath.normal_from_positions(
					node.pb_mesh_data.positions, node.pb_mesh_data.faces[res.face_index].get_indexes())
				best_t = res.distance
				best = {"point": res.hit_point,
					"normal": (node.global_transform.basis * normal).normalized()}

		var plain := PBPicking.pick_plain_mesh_surface(scene_root, ray_o, ray_d, best_t)
		if not plain.is_empty():
			best_t = ray_o.distance_to(plain["point"])
			best = plain

		var w3d := camera.get_world_3d()
		if w3d != null and w3d.direct_space_state != null:
			var ray_query := PhysicsRayQueryParameters3D.create(ray_o, ray_o + ray_d * 2000.0)
			var phys_hit := w3d.direct_space_state.intersect_ray(ray_query)
			if not phys_hit.is_empty() and phys_hit.has("position") and phys_hit.has("normal") and phys_hit.has("collider"):
				var col = phys_hit["collider"]
				var is_pbmesh_col := (col is Node and col.get_parent() is PBMesh)
				if not is_pbmesh_col:
					var dist: float = ray_o.distance_to(phys_hit["position"])
					if dist < best_t - 0.001:
						best_t = dist
						best = {
							"point": phys_hit["position"],
							"normal": phys_hit["normal"]
						}
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

func _collect_mesh_instances(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if root is MeshInstance3D and not (root is PBMesh):
		out.append(root as MeshInstance3D)
	for child in root.get_children():
		out.append_array(_collect_mesh_instances(child))
	return out

func _creation_begin_from_surface(camera: Camera3D, screen_pos: Vector2) -> bool:
	var hit := _pick_creation_surface(camera, screen_pos)
	if hit.is_empty():
		return false
	var view_z: Vector3 = camera.global_transform.basis.z
	# The visible face's normal opposes the viewing ray. A normal pointing
	# WITH the ray belongs to inward-wound geometry (GLB-sourced meshes with
	# the opposite winding) — shapes placed against it would protrude into
	# the surface and read inside-out ("flipped windings"). Face the viewer.
	var forward: Vector3 = -view_z
	if forward.dot(hit["normal"]) > 0.0:
		hit["normal"] = -hit["normal"]
	if shape_creator.shape_id == &"sprite":
		# Sprite flow: one click anchors the shape ON the surface; the mouse
		# then pushes it along the surface normal until the confirming click.
		# (The plane reaches the same OFFSET stage, but by dragging a base
		# rect first — see PBShapeParams.height_drags_offset.)
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
	# rebuild alone never redraws it.
	node.update_gizmos()
	if tool_overlay != null:
		tool_overlay.set_creation_extents(shape_creator.get_extents_readout())
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
				_update_cursor_extents(screen_pos)
			# No hover highlight while the base drag is out — the cursor is
			# busy drawing the rect, not picking a face.
		PBShapeCreator.State.HEIGHT, PBShapeCreator.State.OFFSET:
			var ref := PBShapeCreator.height_reference_point(camera.global_position,
				-camera.global_transform.basis.z, ray_o, ray_d, shape_creator.rect_center)
			shape_creator.update_height_point(ref)
			_refresh_preview()
			_update_cursor_extents(screen_pos)
			_clear_creation_hover()
		PBShapeCreator.State.PARAMS:
			_clear_creation_hover()
		_:
			_update_creation_hover(camera, screen_pos)

## Creation tools (shape creator / n-gon drawer) raise their shapes against
## the same V-snap state and scene vertices the element editor drags use.
func _wire_creation_vertex_snap() -> void:
	var ee := gizmo_plugin.element_editor
	shape_creator.vertex_snap_active_fn = func() -> bool:
		return ee.is_vertex_snap_active()
	shape_creator.vertex_snap_candidates_fn = func() -> PackedVector3Array:
		return _scene_vertex_candidates(shape_creator.preview_node)
	ngon_drawer.vertex_snap_active_fn = func() -> bool:
		return ee.is_vertex_snap_active()
	ngon_drawer.vertex_snap_candidates_fn = func() -> PackedVector3Array:
		return _scene_vertex_candidates(ngon_drawer.preview_node)

## World-space vertices of every PBMesh except `skip` (the live creation
## preview, whose corners ride the drag and must never catch themselves).
func _scene_vertex_candidates(skip: PBMesh) -> PackedVector3Array:
	var out := PackedVector3Array()
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return out
	var seen := {}
	for m in _collect_pbmeshes(scene_root):
		if m == skip or m.pb_mesh_data == null:
			continue
		var xf: Transform3D = m.global_transform
		for p in m.pb_mesh_data.positions:
			var w := xf * p
			var key := Vector3i(roundi(w.x * 1000.0), roundi(w.y * 1000.0), roundi(w.z * 1000.0))
			if not seen.has(key):
				seen[key] = true
				out.append(w)
	return out

## Cyan face highlight under the cursor while creating (skips the preview).
func _update_creation_hover(camera: Camera3D, screen_pos: Vector2) -> void:
	var ray_o: Vector3 = camera.project_ray_origin(screen_pos)
	var ray_d: Vector3 = camera.project_ray_normal(screen_pos)
	var best_t := INF
	var best_node: PBMesh = null
	var best_face := -1
	var best_point := Vector3.ZERO
	var best_normal := Vector3.UP
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root != null:
		for node in _collect_pbmeshes(scene_root):
			if node == shape_creator.preview_node or node.pb_mesh_data == null:
				continue
			# AABB prefilter: a poibuilderized sculpt has thousands of faces,
			# so skip whole meshes the ray cannot hit before a nearer surface.
			var pb_span := PBPicking.ray_aabb_span(ray_o, ray_d, node.global_transform * node.get_aabb())
			if pb_span.x < 0.0 or pb_span.x >= best_t:
				continue
			var res := PBPicking.pick_face(node.pb_mesh_data, node.global_transform, ray_o, ray_d)
			if res.face_index >= 0 and res.distance < best_t:
				best_t = res.distance
				best_node = node
				best_face = res.face_index
				best_point = res.hit_point
				var normal := PBMath.normal_from_positions(
					node.pb_mesh_data.positions, node.pb_mesh_data.faces[res.face_index].get_indexes())
				best_normal = (node.global_transform.basis * normal).normalized()
		var plain := PBPicking.pick_plain_mesh_surface(scene_root, ray_o, ray_d, best_t)
		if not plain.is_empty():
			best_t = ray_o.distance_to(plain["point"])
			best_node = null
			best_face = -1
			best_point = plain["point"]
			best_normal = plain["normal"]
		var w3d := camera.get_world_3d()
		if w3d != null and w3d.direct_space_state != null:
			var ray_query := PhysicsRayQueryParameters3D.create(ray_o, ray_o + ray_d * 2000.0)
			var phys_hit := w3d.direct_space_state.intersect_ray(ray_query)
			if not phys_hit.is_empty() and phys_hit.has("position") and phys_hit.has("collider"):
				var col = phys_hit["collider"]
				var is_pbmesh_col := (col is Node and col.get_parent() is PBMesh)
				if not is_pbmesh_col:
					var dist: float = ray_o.distance_to(phys_hit["position"])
					if dist < best_t - 0.001:
						best_t = dist
						best_node = null
						best_face = -1
						best_point = phys_hit["position"]
						if phys_hit.has("normal"):
							best_normal = phys_hit["normal"]
	if grid.draw_on_grid or best_point == Vector3.ZERO:
		var hit := PBShapeCreator.ray_plane_intersect(ray_o, ray_d, grid.origin, Vector3.UP)
		if hit != PBShapeCreator.RAY_MISS:
			best_point = hit
			best_normal = Vector3.UP
			best_node = null
			best_face = -1

	# Snap the hover vertex to the exact starting point creation will use when clicked:
	if shape_creator != null and shape_creator.state == PBShapeCreator.State.ARMED:
		best_point = shape_creator.snap_starting_point(best_point, best_normal)
	elif ngon_drawer != null and ngon_drawer.is_active() and ngon_drawer.state == PBNgonDrawer.State.ARMED:
		best_point = ngon_drawer.snap_starting_point(best_point, best_normal, best_node, best_face)
	elif sprite_placer != null and sprite_placer.is_active() and sprite_placer.state == PBSpritePlacer.State.ARMED:
		if grid != null and grid.enabled and PBGrid.is_cardinal(best_normal):
			best_point = grid.snap_point_masked(best_point, best_normal)
	elif particle_placer != null and particle_placer.is_active() and particle_placer.state == PBParticlePlacer.State.ARMED:
		if grid != null and grid.enabled and PBGrid.is_cardinal(best_normal):
			best_point = grid.snap_point_masked(best_point, best_normal)

	var target_node: PBMesh = best_node
	var target_face: int = best_face
	if target_node == null and editor.active_mesh != null and is_instance_valid(editor.active_mesh):
		target_node = editor.active_mesh
		target_face = -1

	var prev_node := gizmo_plugin.creation_hover_node
	var node_changed := (target_node != prev_node or target_face != gizmo_plugin.creation_hover_face)
	var pt_changed := gizmo_plugin.creation_hover_point.distance_to(best_point) > 0.001
	if node_changed:
		gizmo_plugin.creation_hover_node = target_node
		gizmo_plugin.creation_hover_face = target_face
		if prev_node != null and is_instance_valid(prev_node):
			prev_node.update_gizmos()
		if target_node != null:
			target_node.update_gizmos()
	elif pt_changed and target_node != null:
		target_node.update_gizmos()
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
	# end_base() rejects by resetting the creator — which NULLS preview_node.
	# Capture the node FIRST and tear it down ourselves, or an undersized /
	# click-only release leaves the BASE-phase preview (a meshless PBMesh with
	# a live gizmo) in the scene forever: the "errored Shape_Cube + persistent
	# vertex overlay" report.
	var abandoned := shape_creator.preview_node
	if not shape_creator.end_base():
		if abandoned != null and is_instance_valid(abandoned):
			if abandoned.get_parent() != null:
				abandoned.get_parent().remove_child(abandoned)
			abandoned.queue_free()
		_creation_abort("base drag too small")
		return
	if PBShapeParams.commits_on_base_release(shape_creator.shape_id):
		_creation_confirm()
		return
	# Rebuild NOW: the solid preview appears immediately as a flat slab ON
	# the surface (height 0) instead of popping in below it with a jump at
	# the first mouse move.
	_refresh_preview()
	if shape_creator.state == PBShapeCreator.State.OFFSET:
		_set_creation_hint("move to lift it off the surface, then click to confirm")
	else:
		_set_creation_hint("move to size it, then click to confirm (Alt: height plane)")

## The confirming click (after the height drag): the shape exists from here
## on (its node-add undo is registered now). Parameterized shapes open the
## params modal; simple size-only shapes finalize immediately (Edit Params
## is always available afterwards).
func _creation_confirm() -> void:
	# "Otherwise invalid" guard beside the undersized-drag rejection: degenerate
	# geometry (no faces, empty/nan positions) must never become a node — that
	# is what produced broken exclamation-mark nodes whose undo poisoned the
	# tree. Abort like a too-small drag instead.
	var preview := shape_creator.preview_node
	if preview == null or not is_instance_valid(preview) or preview.pb_mesh_data == null \
			or preview.pb_mesh_data.faces.is_empty() \
			or preview.pb_mesh_data.positions.size() < 3:
		_creation_abort("degenerate geometry")
		return
	for p in preview.pb_mesh_data.positions:
		if p.x != p.x or p.y != p.y or p.z != p.z:  # NaN check — finite garbage is bounded below by end_base's extents
			_creation_abort("degenerate geometry")
			return
	shape_creator.confirm_height()
	# The BASE phase keeps the render mesh hidden (the outline shows); shapes
	# that commit on base release (trim) go straight to PARAMS — restore the
	# mesh NOW or the trim stays invisible until the first parameter touch.
	_refresh_preview()
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
	if tool_overlay != null:
		tool_overlay.set_creation_extents("")
	if _cursor_extents_label != null:
		_cursor_extents_label.visible = false
	shape_creator.show_height_plane = false

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
	if shape_creator.shape_id == &"trim":
		# "On Wall records which way the strip was drawn" — a recorded flag on
		# the created data (not an editable modal row): true when the drag was
		# drawn on a vertical surface, so the strip lies flat on that wall.
		shape_creator.values["on_wall"] = absf(shape_creator.plane_normal.dot(Vector3.UP)) < 0.5
		_persist_trim_project_values(shape_creator.values)
	node.pb_mesh_data.shape_params = shape_creator.values.duplicate()
	node.pb_mesh_data.shape_edited = false
	node._update_collider()

const TRIM_SETTING_PREFIX := "poibuilder/trim/"

## Seeds a new trim's depth from the project's last committed value.
func _seed_trim_project_values() -> void:
	if _settings == null or not _settings.has_method("has_setting"):
		return
	var path := TRIM_SETTING_PREFIX + "last_depth"
	if _settings.has_setting(path):
		var d := float(_settings.get_setting(path))
		if d >= 0.005:
			shape_creator.values["depth"] = d

## Remembers the depth a trim was committed with.
func _persist_trim_project_values(values: Dictionary) -> void:
	if _settings == null or not _settings.has_method("set_setting"):
		return
	if values.has("depth"):
		_settings.set_setting(TRIM_SETTING_PREFIX + "last_depth", float(values["depth"]))
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
	if tool_overlay != null:
		tool_overlay.set_creation_extents("")
	if _cursor_extents_label != null:
		_cursor_extents_label.visible = false
	shape_creator.show_height_plane = false
	_update_editing_context()
	# The Shapes tab is a mode: its shape re-arms when a placement ends (the
	# reason is inspected — deliberate tool switches re-arm themselves).
	_rearm_shape_mode_after_session_end(reason)
	if logger:
		logger.info("plugin", "Shape creation aborted (%s)" % reason)

## Ends a "create" params session: the node stays either way (Apply keeps the
## edited params, Cancel restored the pre-modal ones), and the plugin hands
## the node over to element editing.
func _finish_creation_session(node: PBMesh) -> void:
	shape_creator.reset()
	_clear_creation_hover()
	_set_creation_hint("")
	if tool_overlay != null:
		tool_overlay.set_creation_extents("")
	if _cursor_extents_label != null:
		_cursor_extents_label.visible = false
	shape_creator.show_height_plane = false
	tool_overlay.close_params()
	_params_session_kind = ""
	if node != null and is_instance_valid(node):
		# A stray undo (or a corrupted session) could have detached the node —
		# re-attach before selecting so add_node sees a live tree node.
		if not node.is_inside_tree():
			_attach_detached(node, get_editor_interface().get_edited_scene_root())
	if PBShapeParams.commits_on_base_release(shape_creator.shape_id):
		_creation_confirm()
		return
	# The Shapes tab is a mode: keep its shape armed for the next placement.
	_arm_shape_mode_shape()

func _update_cursor_extents(screen_pos: Vector2) -> void:
	if _cursor_extents_label == null:
		return
	# Billboard sprite raise/scale: same floating readout as shape creation.
	if sprite_placer != null and sprite_placer.is_active() \
			and (sprite_placer.state == PBSpritePlacer.State.RAISE or sprite_placer.state == PBSpritePlacer.State.SCALE):
		var sp_text := sprite_placer.get_extents_readout()
		if not sp_text.is_empty():
			_show_cursor_extents(sp_text, screen_pos)
			return
	# Particle placement lift/tune: same treatment.
	if particle_placer != null and particle_placer.is_active() \
			and (particle_placer.state == PBParticlePlacer.State.RAISE or particle_placer.state == PBParticlePlacer.State.TUNE):
		var pp_text := particle_placer.get_extents_readout()
		if not pp_text.is_empty():
			_show_cursor_extents(pp_text, screen_pos)
			return
	# N-gon height drag: same treatment.
	if ngon_drawer != null and ngon_drawer.is_active() and ngon_drawer.state == PBNgonDrawer.State.HEIGHT:
		var ng_text := ngon_drawer.get_extents_readout()
		if not ng_text.is_empty():
			_show_cursor_extents(ng_text, screen_pos)
			return
	if shape_creator == null or not (shape_creator.state == PBShapeCreator.State.BASE or shape_creator.state == PBShapeCreator.State.HEIGHT or shape_creator.state == PBShapeCreator.State.OFFSET):
		_cursor_extents_label.visible = false
		return

	var text := shape_creator.get_cursor_extents_text()
	if text.is_empty():
		_cursor_extents_label.visible = false
		return

	_show_cursor_extents(text, screen_pos)

func _show_cursor_extents(text: String, screen_pos: Vector2) -> void:
	_cursor_extents_label.text = text
	_cursor_extents_label.visible = true

	var pos := screen_pos + Vector2(18, 18)
	var parent_ctrl := _cursor_extents_label.get_parent_control()
	if parent_ctrl != null:
		var vp_size := parent_ctrl.size
		var lbl_size := _cursor_extents_label.get_minimum_size()
		if pos.x + lbl_size.x > vp_size.x - 10:
			pos.x = maxf(10.0, screen_pos.x - lbl_size.x - 10)
		if pos.y + lbl_size.y > vp_size.y - 10:
			pos.y = maxf(10.0, screen_pos.y - lbl_size.y - 10)
	_cursor_extents_label.position = pos

func _forward_3d_draw_over_viewport(viewport_control: Control) -> void:
	if _cursor_extents_label != null and _cursor_extents_label.is_inside_tree() and _cursor_extents_label.visible:
		return
	if shape_creator == null or not (shape_creator.state == PBShapeCreator.State.BASE or shape_creator.state == PBShapeCreator.State.HEIGHT or shape_creator.state == PBShapeCreator.State.OFFSET):
		return
	var text := shape_creator.get_cursor_extents_text()
	if text.is_empty():
		return
	var font := viewport_control.get_theme_default_font()
	if font == null:
		font = ThemeDB.fallback_font
	var font_size := 14
	var outline_size := 8
	var ascent := font.get_ascent(font_size) if font != null else 12.0
	var pos := _last_mouse_pos + Vector2(18, 18 + ascent)
	viewport_control.draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, outline_size, Color.BLACK)
	viewport_control.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)
func _unique_shape_name(scene_root: Node, shape_id: StringName) -> String:
	var base := "Shape_%s" % String(shape_id).capitalize().replace(" ", "")
	if scene_root.get_node_or_null(NodePath(base)) == null:
		return base
	var i := 2
	while scene_root.get_node_or_null(NodePath("%s%d" % [base, i])) != null:
		i += 1
	return "%s%d" % [base, i]

# ==============================================================================
# Interactive N-Gon Drawing & Knife Tool
# ==============================================================================

func _start_knife_tool() -> void:
	if _params_session_kind != "" or (tool_overlay != null and tool_overlay.params_open):
		_on_params_applied()
	if shape_creator.is_active():
		_creation_abort("switched to knife tool")
	if ngon_drawer.is_active():
		_ngon_drawer_abort("switched to knife tool")
	_clear_creation_hover()
	var target_m: PBMesh = editor.active_mesh
	var target_f: int = -1
	if editor.selection != null and editor.selection.selected_face_count() > 0:
		target_f = editor.selection.selected_faces[0]
	ngon_drawer.arm(PBNgonDrawer.Mode.KNIFE, target_m, target_f)
	_make_ngon_preview_node()
	_update_editing_context()
	_set_creation_hint("Knife: click on a face to place vertices, drag to move, Enter to cut (Esc cancels)")
	if target_m != null:
		target_m.update_gizmos()
	if logger:
		logger.info("plugin", "Knife tool active — click on a face to place vertices")

func _start_ngon_shape_tool() -> void:
	if _params_session_kind != "" or (tool_overlay != null and tool_overlay.params_open):
		_on_params_applied()
	if shape_creator.is_active():
		_creation_abort("switched to n-gon tool")
	if ngon_drawer.is_active():
		_ngon_drawer_abort("switched to n-gon tool")
	_clear_creation_hover()
	if editor.active_mesh != null:
		var prev: PBMesh = editor.active_mesh
		editor.active_mesh = null
		prev.update_gizmos()
	var ed_sel := get_editor_interface().get_selection()
	if ed_sel != null:
		ed_sel.clear()
	ngon_drawer.arm(PBNgonDrawer.Mode.NGON_EXTRUDE)
	_make_ngon_preview_node()
	_update_editing_context()
	_set_creation_hint("N-Gon: click a surface to place vertices, drag to move, Enter to size height (Esc cancels)")
	if logger:
		logger.info("plugin", "N-Gon Extrude active — click a surface to draw polygon")
func _ngon_drawer_input(camera: Camera3D, event: InputEvent) -> int:
	if event is InputEventMouseMotion:
		_last_mouse_pos = event.position
		_last_mouse_camera = camera
		var ray_o: Vector3 = camera.project_ray_origin(event.position)
		var ray_d: Vector3 = camera.project_ray_normal(event.position)

		match ngon_drawer.state:
			PBNgonDrawer.State.HEIGHT:
				var ref := PBShapeCreator.height_reference_point(camera.global_position,
					-camera.global_transform.basis.z, ray_o, ray_d, ngon_drawer.plane_point)
				ngon_drawer.update_height_point(ref)
				_refresh_ngon_preview()
				_update_cursor_extents(event.position)
			PBNgonDrawer.State.ARMED:
				_update_creation_hover(camera, event.position)
				var hit := _pick_creation_surface(camera, event.position)
				if not hit.is_empty():
					var pt: Vector3 = hit["point"]
					var best_m: PBMesh = null
					var best_f: int = -1
					var best_dist := INF
					var scene_root := get_editor_interface().get_edited_scene_root()
					if scene_root != null:
						for node in _collect_pbmeshes(scene_root):
							if node == ngon_drawer.preview_node or node.pb_mesh_data == null:
								continue
							var res := PBPicking.pick_face(node.pb_mesh_data, node.global_transform, ray_o, ray_d)
							if res.face_index >= 0 and res.distance < best_dist:
								best_dist = res.distance
								best_m = node
								best_f = res.face_index
					var norm: Vector3 = hit.get("normal", Vector3.UP)
					pt = ngon_drawer.snap_starting_point(pt, norm, best_m, best_f)
					ngon_drawer.live_cursor_point = pt
					if ngon_drawer.preview_node != null:
						ngon_drawer.preview_node.update_gizmos()
					elif best_m != null:
						best_m.update_gizmos()
			PBNgonDrawer.State.DRAWING, PBNgonDrawer.State.DRAGGING_VERT:
				# Knife mode: check if cursor hits an adjacent face to switch to
				if ngon_drawer.mode == PBNgonDrawer.Mode.KNIFE and ngon_drawer.target_mesh != null:
					var tm: PBMesh = ngon_drawer.target_mesh
					if tm.pb_mesh_data != null:
						var pick_res := PBPicking.pick_face(tm.pb_mesh_data, tm.global_transform, ray_o, ray_d)
						if pick_res.face_index >= 0 and pick_res.face_index != ngon_drawer.target_face_index:
							if ngon_drawer.can_transition_to_face(pick_res.face_index):
								ngon_drawer.switch_target_face(pick_res.face_index)

				var hit := PBNgonDrawer.ray_plane_intersect(ray_o, ray_d,
					ngon_drawer.plane_point, ngon_drawer.plane_normal)
				if hit != PBNgonDrawer.RAY_MISS:
					ngon_drawer.update_cursor_plane(hit)
					if ngon_drawer.preview_node != null:
						ngon_drawer.preview_node.update_gizmos()
					elif ngon_drawer.target_mesh != null:
						ngon_drawer.target_mesh.update_gizmos()
					elif editor.active_mesh != null:
						editor.active_mesh.update_gizmos()
		return AFTER_GUI_INPUT_PASS

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			match ngon_drawer.state:
				PBNgonDrawer.State.ARMED:
					if _ngon_drawer_begin_from_surface(camera, event.position):
						return AFTER_GUI_INPUT_STOP
					return AFTER_GUI_INPUT_PASS
				PBNgonDrawer.State.DRAWING:
					if ngon_drawer.hovered_vert_idx >= 0:
						if ngon_drawer.hovered_vert_idx == 0 and ngon_drawer.points.size() >= 3:
							_on_ngon_drawer_complete()
							return AFTER_GUI_INPUT_STOP
						else:
							ngon_drawer.start_drag_vert(ngon_drawer.hovered_vert_idx)
							return AFTER_GUI_INPUT_STOP
					else:
						ngon_drawer.add_point(ngon_drawer.live_cursor_point)
						if ngon_drawer.preview_node != null:
							ngon_drawer.preview_node.update_gizmos()
						elif ngon_drawer.target_mesh != null:
							ngon_drawer.target_mesh.update_gizmos()
						elif editor.active_mesh != null:
							editor.active_mesh.update_gizmos()
						return AFTER_GUI_INPUT_STOP
				PBNgonDrawer.State.HEIGHT:
					_on_ngon_drawer_confirm_height()
					return AFTER_GUI_INPUT_STOP
		else:
			if ngon_drawer.state == PBNgonDrawer.State.DRAGGING_VERT:
				ngon_drawer.end_drag_vert()
				if ngon_drawer.preview_node != null:
					ngon_drawer.preview_node.update_gizmos()
				elif ngon_drawer.target_mesh != null:
					ngon_drawer.target_mesh.update_gizmos()
				return AFTER_GUI_INPUT_STOP

	if event is InputEventKey and event.pressed:
		var k := event as InputEventKey
		if k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER:
			if ngon_drawer.state == PBNgonDrawer.State.DRAWING or ngon_drawer.state == PBNgonDrawer.State.DRAGGING_VERT:
				_on_ngon_drawer_complete()
				return AFTER_GUI_INPUT_STOP
			elif ngon_drawer.state == PBNgonDrawer.State.HEIGHT:
				_on_ngon_drawer_confirm_height()
				return AFTER_GUI_INPUT_STOP
		elif k.keycode == KEY_ESCAPE:
			_ngon_drawer_abort("cancelled with Escape")
			return AFTER_GUI_INPUT_STOP
		elif not k.echo or _is_repeatable_grid_key(k):
			if _handle_grid_action_key(k) == AFTER_GUI_INPUT_STOP:
				return AFTER_GUI_INPUT_STOP

	return AFTER_GUI_INPUT_PASS

func _ngon_drawer_begin_from_surface(camera: Camera3D, screen_pos: Vector2) -> bool:
	var hit := _pick_creation_surface(camera, screen_pos)
	if hit.is_empty():
		return false

	var ray_o: Vector3 = camera.project_ray_origin(screen_pos)
	var ray_d: Vector3 = camera.project_ray_normal(screen_pos)
	var best_mesh: PBMesh = null
	var best_face: int = -1
	var best_dist := INF

	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root != null:
		for node in _collect_pbmeshes(scene_root):
			if node.pb_mesh_data == null:
				continue
			var res := PBPicking.pick_face(node.pb_mesh_data, node.global_transform, ray_o, ray_d)
			if res.face_index >= 0 and res.distance < best_dist:
				best_dist = res.distance
				best_mesh = node
				best_face = res.face_index

	if ngon_drawer.mode == PBNgonDrawer.Mode.KNIFE:
		if best_mesh == null or best_face < 0:
			return false
		var start_pt := ngon_drawer.snap_starting_point(hit["point"], hit["normal"], best_mesh, best_face)
		ngon_drawer.begin(start_pt, hit["normal"], best_mesh, best_face)
		_clear_creation_hover()
		_set_creation_hint("Knife: click to place cut vertices, drag to move, Enter to complete cut")
		best_mesh.update_gizmos()
		return true
	else:
		var start_pt := ngon_drawer.snap_starting_point(hit["point"], hit["normal"], best_mesh, best_face)
		ngon_drawer.begin(start_pt, hit["normal"], best_mesh, best_face)
		_set_creation_hint("N-Gon: click to place vertices, drag to move, Enter to extrude")
		_make_ngon_preview_node()
		_refresh_ngon_preview()
		return true

func _make_ngon_preview_node() -> void:
	if ngon_drawer.preview_node != null and is_instance_valid(ngon_drawer.preview_node):
		return
	var scene_root := get_editor_interface().get_edited_scene_root()
	var node := PBMesh.new()
	node.name = _unique_shape_name(scene_root, &"ngon")
	node.pb_mesh_data = PBShapeGenerators.create_box(Vector3(0.01, 0.01, 0.01))
	node.mesh = null
	scene_root.add_child(node)
	node.owner = scene_root
	ngon_drawer.preview_node = node
	node.update_gizmos()

func _refresh_ngon_preview() -> void:
	var node := ngon_drawer.preview_node
	if node == null:
		return
	if ngon_drawer.state == PBNgonDrawer.State.HEIGHT:
		var data := ngon_drawer.build_preview_data()
		if data != null:
			node.transform = Transform3D.IDENTITY
			node.pb_mesh_data = data
			node.rebuild()
	else:
		node.mesh = null
	node.update_gizmos()
func _on_ngon_drawer_complete() -> void:
	if ngon_drawer.mode == PBNgonDrawer.Mode.NGON_EXTRUDE:
		if ngon_drawer.points.size() < 3:
			_set_creation_hint("N-Gon requires at least 3 vertices to extrude")
			return
		var res := ngon_drawer.complete()
		if res.get("ok", false):
			if ngon_drawer.preview_node == null:
				_make_ngon_preview_node()
			_refresh_ngon_preview()
			_set_creation_hint("move mouse to size height, click to confirm (Esc cancels)")
	elif ngon_drawer.mode == PBNgonDrawer.Mode.KNIFE:
		var target_m := ngon_drawer.target_mesh
		var target_f := ngon_drawer.target_face_index
		if target_m == null or target_m.pb_mesh_data == null or target_f < 0:
			_ngon_drawer_abort("Knife target face lost")
			return

		var cmd := CmdMeshOp.new(target_m.pb_mesh_data, "Knife Cut", target_m)
		if logger:
			cmd.logger = logger

		var res := ngon_drawer.complete()
		if not res.get("ok", false):
			if logger:
				logger.warn("mesh_ops", "Knife cut failed: %s" % res.get("error", "?"))
			_set_creation_hint("Knife cut failed: %s" % res.get("error", "?"))
			return

		cmd.capture_after()
		if not cmd.is_noop():
			cmd.add_to_undo_manager(get_undo_redo())

		# Destroy the preview node immediately so no drawing gizmo can linger
		var preview := ngon_drawer.preview_node
		if preview != null and is_instance_valid(preview):
			if preview.get_parent() != null:
				preview.get_parent().remove_child(preview)
			preview.queue_free()
		ngon_drawer.preview_node = null

		# Reset drawer state BEFORE updating target mesh gizmos
		ngon_drawer.reset()
		_clear_creation_hover()
		_set_creation_hint("")

		# Finish mesh op and rebuild target_m gizmos cleanly (drawer is now inactive)
		_finish_mesh_op(target_m, "knife_tool", int(res.get("new_face_ids", []).size()))
		if logger:
			logger.info("plugin", "Knife cut completed on '%s' face %d" % [target_m.name, target_f])
		_update_editing_context()
func _on_ngon_drawer_confirm_height() -> void:
	var node := ngon_drawer.preview_node
	var res := ngon_drawer.confirm_height()
	if not res.get("ok", false) or node == null:
		_ngon_drawer_abort("Failed to finalize N-Gon")
		return

	var data: PBMeshData = res["data"]
	var xf: Transform3D = res["transform"]
	node.transform = xf
	node.pb_mesh_data = data
	node._update_collider()

	var scene_root := get_editor_interface().get_edited_scene_root()
	var undo := get_undo_redo()
	undo.create_action("Add Custom N-Gon", UndoRedo.MERGE_DISABLE, node)
	undo.add_do_method(self, "_attach_detached", node, scene_root)
	undo.add_do_method(self, "_own_node", node)
	undo.add_do_reference(node)
	undo.add_undo_method(self, "_detach_node", node)
	undo.commit_action()

	_clear_creation_hover()
	_set_creation_hint("")
	var editor_selection := get_editor_interface().get_selection()
	if editor_selection != null and is_instance_valid(node):
		editor_selection.clear()
		editor_selection.add_node(node)
		editor.active_mesh = node

	node.update_gizmos()
	if logger:
		logger.info("plugin", "Created custom N-Gon '%s'" % node.name)
	_update_editing_context()

func _ngon_drawer_abort(reason: String) -> void:
	var node := ngon_drawer.preview_node
	var prev_mesh := ngon_drawer.target_mesh
	ngon_drawer.reset()
	if node != null and is_instance_valid(node) and node.get_parent() != null:
		node.get_parent().remove_child(node)
		node.queue_free()
	if prev_mesh != null and is_instance_valid(prev_mesh):
		prev_mesh.update_gizmos()
	_clear_creation_hover()
	_set_creation_hint("")
	_update_editing_context()
	if logger:
		logger.info("plugin", "N-gon drawing aborted (%s)" % reason)

# ==============================================================================
# Billboard Sprite Placement Tool + dock placement modes
# ==============================================================================

## B key / New Shape menu "Sprite": the SPRITE DOCK TAB is the sprite mode —
## switching the tab arms placement (always armed), so every entry point
## converges on the same state through dock_mode_changed.
func _enter_sprite_mode() -> void:
	if material_dock != null and is_instance_valid(material_dock):
		if material_dock.dock_mode == PBMaterialDock.DockMode.SPRITE:
			_start_sprite_tool()   # already the tab's mode: re-arm
		else:
			material_dock.set_dock_mode(PBMaterialDock.DockMode.SPRITE)
	else:
		_start_sprite_tool()

func _dock_is_sprite_mode() -> bool:
	return material_dock != null and is_instance_valid(material_dock) \
		and material_dock.dock_mode == PBMaterialDock.DockMode.SPRITE

func _dock_is_shape_mode() -> bool:
	return material_dock != null and is_instance_valid(material_dock) \
		and material_dock.dock_mode == PBMaterialDock.DockMode.SHAPE

## The dock tab switched: each mode arms/disarms what lives in the viewport.
## (The dock itself only flips UI sections; this is the tool-side mirror.)
func _on_dock_mode_changed(new_mode: PBMaterialDock.DockMode) -> void:
	# The paint/stamp previews and their "not paintable" readout are cursor
	# state: leaving those tabs must not leave the line (or a stale preview)
	# behind for the next session that uses the extents row.
	if new_mode != PBMaterialDock.DockMode.PAINT and new_mode != PBMaterialDock.DockMode.STAMP:
		if paint_controller != null:
			paint_controller.clear_cursor()
		_sync_paint_readout()
	match new_mode:
		PBMaterialDock.DockMode.SPRITE:
			_start_sprite_tool()
		PBMaterialDock.DockMode.PARTICLE:
			_start_particle_tool()
		PBMaterialDock.DockMode.SHAPE:
			if sprite_placer != null and sprite_placer.is_active():
				sprite_placer.abort()
			if particle_placer != null and particle_placer.is_active():
				particle_placer.abort()
			_arm_shape_mode_shape()
		_:
			# Material / Paint / Stamp: placement modes disarm (an armed but
			# not-yet-dragged shape session dies with its tab; a drag in
			# progress is allowed to finish).
			if sprite_placer != null and sprite_placer.is_active():
				sprite_placer.abort()
			if particle_placer != null and particle_placer.is_active():
				particle_placer.abort()
			if shape_creator.is_active() and shape_creator.state == PBShapeCreator.State.ARMED:
				shape_creator.reset()
				_set_creation_hint("")
				_update_editing_context()
	_update_mode_banner()

## Arms the Shapes tab's selected shape. No-op unless the Shapes tab is the
## active dock mode (this is the re-arm hook after every placement too).
func _arm_shape_mode_shape() -> void:
	if not _dock_is_shape_mode():
		return
	if shape_creator.is_active() and shape_creator.shape_id == _shape_mode_shape \
			and shape_creator.state == PBShapeCreator.State.ARMED:
		return
	_on_shape_requested(_shape_mode_shape)

## A Shapes-tab card picked: remember it and arm it straight away.
func _on_shape_palette_selected(shape_id: StringName) -> void:
	_shape_mode_shape = shape_id
	if _dock_is_shape_mode():
		_on_shape_requested(shape_id)
		_update_mode_banner()

## Re-arms the Shapes tab's shape after a creation session ended (Esc, tiny
## drag, Apply/Cancel of the params modal). Deliberate SWITCHES ("a new shape
## was picked", another tool taking over) own their arming and must not
## re-arm — the aborts they trigger arrive while they continue arming.
func _rearm_shape_mode_after_session_end(reason: String) -> void:
	if reason in ["a new shape was picked", "switched to sprite tool",
			"switched to particle tool", "switched to trim walls",
			"switched to n-gon tool", "plugin exit"]:
		return
	_arm_shape_mode_shape()

## The top-center banner: one exit reminder for every placement mode (which
## mode is active is obvious from the dock's highlighted tab — repeating it,
## or the armed shape's name, was noise).
func _update_mode_banner() -> void:
	if mode_banner == null or not is_instance_valid(mode_banner):
		return
	if material_dock == null or not is_instance_valid(material_dock):
		mode_banner.set_hint("")
		return
	match material_dock.dock_mode:
		PBMaterialDock.DockMode.PAINT, PBMaterialDock.DockMode.STAMP, \
		PBMaterialDock.DockMode.SPRITE, PBMaterialDock.DockMode.SHAPE, \
		PBMaterialDock.DockMode.PARTICLE:
			mode_banner.set_hint("Select Material & UV tab to exit placement mode")
		_:
			mode_banner.set_hint("")

func _start_sprite_tool() -> void:
	if _params_session_kind != "" or (tool_overlay != null and tool_overlay.params_open):
		if not trim_walls_tool.is_active():
			_on_params_applied()
	if shape_creator.is_active():
		_creation_abort("switched to sprite tool")
	if ngon_drawer.is_active():
		_ngon_drawer_abort("switched to sprite tool")
	if trim_walls_tool.is_active():
		_trim_walls_disarm("switched to sprite tool")
	if particle_placer != null and particle_placer.is_active():
		particle_placer.abort()
	_clear_creation_hover()
	sprite_placer.arm()
	_update_editing_context()
	_set_creation_hint("Sprite: click a surface to place the selected sprite (drag to pick a texture, Esc cancels)")
	_update_mode_banner()
	if logger:
		logger.info("plugin", "Sprite placement armed — click a surface to place the selected sprite")

func _on_sprite_placed(node: PBMesh) -> void:
	_clear_creation_hover()
	_update_editing_context()
	if _dock_is_sprite_mode():
		# Always-armed mode: the next click places the next sprite.
		sprite_placer.arm()
		_set_creation_hint("Sprite: click a surface to place the selected sprite (drag to pick a texture, Esc cancels)")
	else:
		_set_creation_hint("")
	if logger and node != null:
		logger.info("plugin", "Placed billboard sprite '%s'" % node.name)

## The dock tab is the particle mode — every entry converges here.
func _start_particle_tool() -> void:
	if _params_session_kind != "" or (tool_overlay != null and tool_overlay.params_open):
		if not trim_walls_tool.is_active():
			_on_params_applied()
	if shape_creator.is_active():
		_creation_abort("switched to particle tool")
	if ngon_drawer.is_active():
		_ngon_drawer_abort("switched to particle tool")
	if trim_walls_tool.is_active():
		_trim_walls_disarm("switched to particle tool")
	if sprite_placer != null and sprite_placer.is_active():
		sprite_placer.abort()
	_clear_creation_hover()
	particle_placer.arm()
	_update_editing_context()
	_set_creation_hint(particle_placer.phase_hint())
	_update_mode_banner()
	if material_dock != null:
		material_dock._refresh_particle_labels()
	if logger:
		logger.info("plugin", "Particle placement armed — click a surface to place an emitter")

func _dock_is_particle_mode() -> bool:
	return material_dock != null and is_instance_valid(material_dock) \
		and material_dock.dock_mode == PBMaterialDock.DockMode.PARTICLE

func _on_emitter_placed(node: GPUParticles3D) -> void:
	_clear_creation_hover()
	_update_editing_context()
	if _dock_is_particle_mode():
		# Always-armed mode: the next click places the next emitter.
		particle_placer.arm()
		_set_creation_hint(particle_placer.phase_hint())
		material_dock._refresh_particle_labels()
	else:
		_set_creation_hint("")
	if logger and node != null:
		logger.info("plugin", "Placed particle emitter '%s' (%d particles)" % [node.name, node.amount])

# ==============================================================================
# Trim Walls — click walls, live preview, one committed object
# ==============================================================================

## Arms the Trim Walls session: the trim's parameters appear in the adjust
## panel STRAIGHT AWAY (Placement, profile, sizes are chosen while picking
## walls), and the trim previews as walls are added.
func _on_trim_walls_requested() -> void:
	if _params_session_kind != "" or (tool_overlay != null and tool_overlay.params_open):
		_on_params_applied()
	if shape_creator.is_active():
		_creation_abort("switched to trim walls")
	if ngon_drawer.is_active():
		_ngon_drawer_abort("switched to trim walls")
	if sprite_placer != null and sprite_placer.is_active():
		sprite_placer.disarm()
	if particle_placer != null and particle_placer.is_active():
		particle_placer.abort()
	_clear_creation_hover()
	trim_walls_tool.arm()
	_trim_walls_ensure_preview()
	_sync_trim_walls_highlights()
	_update_editing_context()
	_params_session_kind = "trim_walls"
	if tool_overlay != null:
		tool_overlay.panel_enabled = true
		tool_overlay.open_params("Trim Walls Parameters",
			PBShapeParams.get_param_defs(&"trim_walls"), trim_walls_tool.params)
	_set_creation_hint("Trim Walls: click wall faces to trim (click again drops, Backspace undoes, Enter applies, Esc cancels)")
	if logger:
		logger.info("plugin", "Trim Walls armed — click wall faces to place the trim")

func _trim_walls_ensure_preview() -> void:
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		if logger:
			logger.warn("plugin", "Trim Walls: no edited scene")
		return
	if _trim_walls_preview != null and is_instance_valid(_trim_walls_preview):
		return
	var node := PBMesh.new()
	node.name = _unique_shape_name(scene_root, &"trim_walls")
	scene_root.add_child(node)
	# Owner BEFORE first draw — the editor attaches gizmos only to owned
	# nodes (see _make_preview_node).
	node.owner = scene_root
	_trim_walls_preview = node

## Tears the session down (Esc, Cancel, commit, or switching tools). Frees
## the un-committed preview.
func _trim_walls_disarm(reason: String) -> void:
	trim_walls_tool.disarm()
	gizmo_plugin.trim_walls_session = false
	gizmo_plugin.trim_walls_hover_node = null
	gizmo_plugin.trim_walls_hover_face = -1
	gizmo_plugin.trim_walls_chosen.clear()
	if _trim_walls_preview != null and is_instance_valid(_trim_walls_preview):
		var node := _trim_walls_preview
		_trim_walls_preview = null
		if node.get_parent() != null:
			node.get_parent().remove_child(node)
		node.queue_free()
	_set_creation_hint("")
	if tool_overlay != null and _params_session_kind == "trim_walls":
		tool_overlay.close_params()
		_params_session_kind = ""
	_update_editing_context()
	if logger:
		logger.info("plugin", "Trim Walls session ended (%s)" % reason)

func _trim_walls_input(camera: Camera3D, event: InputEvent) -> int:
	_trim_walls_camera = camera
	if event is InputEventMouseMotion:
		_last_mouse_pos = event.position
		_last_mouse_camera = camera
		var pick := _pick_wall_face(camera, event.position)
		var prev_node := gizmo_plugin.trim_walls_hover_node
		var prev_face := gizmo_plugin.trim_walls_hover_face
		var new_node: PBMesh = pick.get("node")
		var new_face: int = pick.get("face", -1)
		if new_node != prev_node or new_face != prev_face:
			gizmo_plugin.trim_walls_hover_node = new_node
			gizmo_plugin.trim_walls_hover_face = new_face
			if prev_node != null and is_instance_valid(prev_node):
				prev_node.update_gizmos()
			if new_node != null:
				new_node.update_gizmos()
		return AFTER_GUI_INPUT_PASS

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var pick := _pick_wall_face(camera, event.position)
		var mesh: PBMesh = pick.get("node")
		var face: int = pick.get("face", -1)
		if mesh != null and face >= 0:
			# A double-click commits instead of toggling (spec: Enter,
			# double-click or Apply commits) — but only when something is
			# chosen; the toggle itself still runs for a fresh wall.
			var is_double_click: bool = Time.get_ticks_msec() - _trim_walls_last_click_msec < 400 \
				and event.position.distance_to(_trim_walls_last_click_pos) < 10.0
			_trim_walls_last_click_msec = Time.get_ticks_msec()
			_trim_walls_last_click_pos = event.position
			if is_double_click and trim_walls_tool.is_chosen(mesh, face):
				_trim_walls_commit()
				return AFTER_GUI_INPUT_STOP
			var chosen: bool = trim_walls_tool.toggle_wall(mesh, face,
				pick.get("normal", Vector3.ZERO))
			if logger:
				logger.info("plugin", "Trim Walls: %s face %d (%s)"
					% [mesh.name, face, "chosen" if chosen else "dropped"])
			_sync_trim_walls_highlights()
			_refresh_trim_walls_preview()
			return AFTER_GUI_INPUT_STOP
		_trim_walls_last_click_msec = Time.get_ticks_msec()
		_trim_walls_last_click_pos = event.position
		return AFTER_GUI_INPUT_PASS

	if event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		if k.keycode == KEY_ESCAPE:
			_on_params_canceled()
			return AFTER_GUI_INPUT_STOP
		elif k.keycode == KEY_BACKSPACE:
			if trim_walls_tool.drop_last():
				_sync_trim_walls_highlights()
				_refresh_trim_walls_preview()
			return AFTER_GUI_INPUT_STOP
		elif k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER:
			_trim_walls_commit()
			return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_PASS

## Nearest VERTICAL PBMesh face under the cursor (floors/ceilings are not
## walls). Returns {"node": PBMesh, "face": int} or {}.
func _pick_wall_face(camera: Camera3D, screen_pos: Vector2) -> Dictionary:
	var ray_o: Vector3 = camera.project_ray_origin(screen_pos)
	var ray_d: Vector3 = camera.project_ray_normal(screen_pos)
	var scene_root := get_editor_interface().get_edited_scene_root()
	var best_t := INF
	var best_node: PBMesh = null
	var best_face := -1
	var best_normal := Vector3.ZERO
	if scene_root != null:
		for node in _collect_pbmeshes(scene_root):
			if node == _trim_walls_preview or node.pb_mesh_data == null \
					or not node.is_visible_in_tree():
				continue
			var res := PBPicking.pick_face(node.pb_mesh_data, node.global_transform, ray_o, ray_d)
			if res.face_index < 0 or res.distance >= best_t:
				continue
			var n := PBMath.normal_from_positions(
				node.pb_mesh_data.positions, node.pb_mesh_data.faces[res.face_index].get_indexes())
			var world_n: Vector3 = (node.global_transform.basis * n).normalized()
			if absf(world_n.dot(Vector3.UP)) > 0.7:
				continue  # a floor/ceiling — not a wall
			# The visible face's normal opposes the viewing ray; inward-wound
			# geometry (GLB sources) yields the flipped one — face the camera
			# so the trim protrudes into the room, never into the wall.
			if world_n.dot(ray_d) > 0.0:
				world_n = -world_n
			if absf(world_n.dot(Vector3.UP)) > 0.7:
				continue
			best_t = res.distance
			best_node = node
			best_face = res.face_index
			best_normal = world_n
	if best_node == null:
		return {}
	return {"node": best_node, "face": best_face, "normal": best_normal}

## Mirrors the session state into the gizmo plugin (teal hover, amber chosen).
func _sync_trim_walls_highlights() -> void:
	gizmo_plugin.trim_walls_session = trim_walls_tool.is_active()
	gizmo_plugin.trim_walls_chosen.clear()
	for w in trim_walls_tool.walls:
		gizmo_plugin.trim_walls_chosen.append(w)
	for node in _collect_pbmeshes(get_editor_interface().get_edited_scene_root()):
		if is_instance_valid(node):
			node.update_gizmos()

## Rebuilds the world-space preview from the chosen walls.
func _refresh_trim_walls_preview() -> void:
	if _trim_walls_preview == null or not is_instance_valid(_trim_walls_preview):
		return
	var data := trim_walls_tool.build(_probe_floor_y, _probe_ceiling_y)
	_trim_walls_preview.pb_mesh_data = data
	_trim_walls_preview.transform = Transform3D.IDENTITY
	_trim_walls_preview.rebuild()
	_trim_walls_preview.update_gizmos()
	# The panel must always SAY what the tool understood — silent empty
	# previews read as "broken".
	var count := trim_walls_tool.wall_count()
	if count == 0:
		_set_creation_hint("Trim Walls: click wall faces to trim (click again drops, Backspace undoes, Enter applies, Esc cancels)")
	elif data == null:
		_set_creation_hint("Trim Walls: %d wall face(s) chosen, but none produced a horizontal run at the trim height — pick wall faces, not floors/ceilings" % count)
	else:
		_set_creation_hint("Trim Walls: %d wall face(s) -> %d trim run(s). Enter applies, Esc cancels"
			% [count, trim_walls_tool.last_paths.size()])

## Enter / double-click / panel Apply: the result is ONE new object; its
## recorded paths keep the parameters live for the same walls (Edit Params).
func _trim_walls_commit() -> void:
	if trim_walls_tool.wall_count() == 0:
		if logger:
			logger.warn("plugin", "Trim Walls: click wall faces before applying")
		return
	var data := trim_walls_tool.build(_probe_floor_y, _probe_ceiling_y)
	if data == null or data.faces.is_empty():
		if logger:
			logger.warn("plugin", "Trim Walls: no wall runs in the selection")
		return
	data.shape_id = &"trim_walls"
	data.shape_edited = false
	var params := trim_walls_tool.params.duplicate()
	var recorded: Array = []
	for p in trim_walls_tool.last_paths:
		recorded.append({"points": p["points"], "closed": p["closed"],
			"floor_y": p.get("floor_y", 0.0), "ceil_y": p.get("ceil_y", 0.0)})
	params["wall_paths"] = recorded
	data.shape_params = params
	if data.materials.is_empty():
		var def := PBMeshData.get_default_material()
		if def != null:
			data.materials.append(def)

	var scene_root := get_editor_interface().get_edited_scene_root()
	var node := PBMesh.new()
	node.name = _unique_shape_name(scene_root, &"trim_walls")
	node.transform = Transform3D.IDENTITY
	node.pb_mesh_data = data
	node.rebuild()
	node._update_collider()
	var undo := get_undo_redo()
	if undo != null:
		# Scene-history context (see the CSG action above).
		undo.create_action("Trim Walls", UndoRedo.MERGE_DISABLE, scene_root)
		undo.add_do_method(self, "_attach_detached", node, scene_root)
		undo.add_do_method(self, "_own_node", node)
		undo.add_do_reference(node)
		undo.add_undo_method(self, "_detach_node", node)
		undo.commit_action()
	else:
		_attach_detached(node, scene_root)

	var editor_selection := get_editor_interface().get_selection()
	if editor_selection != null:
		editor_selection.clear()
		editor_selection.add_node(node)
	editor.active_mesh = node
	var wall_total := trim_walls_tool.wall_count()
	_trim_walls_disarm("applied (%d walls)" % wall_total)
	if logger:
		logger.info("plugin", "Trim Walls committed from %d wall face(s)" % wall_total)

## Physics probes for the room-contact rule: the skirting lands on the slab's
## surface (not the wall cube's buried bottom), the cornice tucks under the
## ceiling slab. Return the hit's Y, or NAN for "nothing" (the tool falls
## back to the wall face's own edge).
func _probe_floor_y(from: Vector3) -> float:
	return _probe_surface_y(from, Vector3.DOWN)
func _probe_ceiling_y(from: Vector3) -> float:
	return _probe_surface_y(from, Vector3.UP)
func _probe_surface_y(from: Vector3, dir: Vector3) -> float:
	var cam := _trim_walls_camera
	if cam == null or not cam.is_inside_tree() or cam.get_world_3d() == null:
		return NAN
	var space := cam.get_world_3d().direct_space_state
	if space == null:
		return NAN
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 500.0)
	# Trims are EXCLUDED from the probe: the probe must measure the room
	# shell. Without this the previous preview's collider feeds back into
	# the next build - drift, smoothing-toggle ping-pong, and placement
	# "applying" only to the newest walls.
	var exclude: Array[RID] = []
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root != null:
		for node in _collect_pbmeshes(scene_root):
			var sid: StringName = node.pb_mesh_data.shape_id if node.pb_mesh_data != null else &""
			if node == _trim_walls_preview or sid == &"trim" or sid == &"trim_walls":
				for child in node.get_children():
					if child is StaticBody3D:
						exclude.append((child as StaticBody3D).get_rid())
	query.exclude = exclude
	var hit := space.intersect_ray(query)
	if hit.is_empty() or not hit.has("position"):
		return NAN
	return (hit["position"] as Vector3).y

## The last camera seen by the session (probes need a World3D).
var _trim_walls_camera: Camera3D = null

func _get_viewport_host() -> Control:
	var viewport: SubViewport = get_editor_interface().get_editor_viewport_3d(0)
	if viewport != null and viewport.get_parent() != null and viewport.get_parent().get_parent() is Control:
		return viewport.get_parent().get_parent() as Control
	return null

func _sprite_placer_input(camera: Camera3D, event: InputEvent) -> int:
	if sprite_placer == null or not sprite_placer.is_active():
		return AFTER_GUI_INPUT_PASS

	var host := _get_viewport_host()
	var surface_hit := {}
	if event is InputEventMouse:
		surface_hit = _pick_creation_surface(camera, event.position)
		# The same rule the shape-creation path applies: the visible face's
		# normal opposes the viewing ray. A normal pointing WITH the ray
		# (backface hit, or inward-wound geometry) would author the sprite's
		# basis upside-down — invisible in the editor because the fixed-Y
		# billboard shader rebuilds the basis from world up, but the exported
		# bake keeps the authored transform, so the sprite lands hanging
		# below the surface (the "upside-down tree" report).
		if not surface_hit.is_empty() and surface_hit.has("normal"):
			var view_forward: Vector3 = -camera.global_transform.basis.z
			if view_forward.dot(surface_hit["normal"]) > 0.0:
				surface_hit["normal"] = -surface_hit["normal"]
		if sprite_placer.state == PBSpritePlacer.State.ARMED:
			if not surface_hit.is_empty():
				_set_creation_hint("Sprite: click a surface to place the selected sprite (drag to pick a texture)")
				_update_creation_hover(camera, event.position)
			else:
				_clear_creation_hover()
		elif sprite_placer.state == PBSpritePlacer.State.TEXTURE_SELECT:
			_clear_creation_hover()
			_set_creation_hint("Sprite: scroll to select texture • release / click to confirm")
		elif sprite_placer.state == PBSpritePlacer.State.RAISE:
			_clear_creation_hover()
			_set_creation_hint("Sprite: mouse up/down to raise • click to lock angle")
		elif sprite_placer.state == PBSpritePlacer.State.SCALE:
			_clear_creation_hover()
			_set_creation_hint("Sprite: mouse left/right to scale • click to confirm placement")

	var res := sprite_placer.handle_input(camera, event, surface_hit, host)
	if not sprite_placer.is_active():
		# Esc / finished session: the SPRITE dock tab stays armed (the tab is
		# the mode) — re-arm so the next click places the next sprite.
		_clear_creation_hover()
		if _dock_is_sprite_mode():
			sprite_placer.arm()
			_set_creation_hint("Sprite: click a surface to place the selected sprite (drag to pick a texture, Esc cancels)")
			_update_editing_context()
		else:
			_set_creation_hint("")
			_update_editing_context()
	return res

## The Particles tab's viewport path: the same surface-pick + normal-flip
## rules as the sprite placer (an inverted normal would author an emitter
## whose preview lift drags it INTO the surface), phase hints, and the
## always-armed re-arm after each placement.
func _particle_placer_input(camera: Camera3D, event: InputEvent) -> int:
	if particle_placer == null or not particle_placer.is_active():
		return AFTER_GUI_INPUT_PASS

	var host := _get_viewport_host()
	var surface_hit := {}
	if event is InputEventMouse:
		surface_hit = _pick_creation_surface(camera, event.position)
		if not surface_hit.is_empty() and surface_hit.has("normal"):
			var view_forward: Vector3 = -camera.global_transform.basis.z
			if view_forward.dot(surface_hit["normal"]) > 0.0:
				surface_hit["normal"] = -surface_hit["normal"]
		if particle_placer.state == PBParticlePlacer.State.ARMED:
			if not surface_hit.is_empty():
				_set_creation_hint(particle_placer.phase_hint())
				_update_creation_hover(camera, event.position)
			else:
				_clear_creation_hover()
		else:
			_clear_creation_hover()
			_set_creation_hint(particle_placer.phase_hint())

	var res := particle_placer.handle_input(camera, event, surface_hit, host)
	if not particle_placer.is_active():
		_clear_creation_hover()
		if _dock_is_particle_mode():
			particle_placer.arm()
			_set_creation_hint(particle_placer.phase_hint())
			_update_editing_context()
		else:
			_set_creation_hint("")
			_update_editing_context()
	return res


# ==============================================================================
# Texture Splatting & Stamp Viewport Input
# ==============================================================================

func _paint_controller_input(camera: Camera3D, event: InputEvent) -> int:
	if paint_controller == null or not paint_controller.is_active():
		return AFTER_GUI_INPUT_PASS

	var scene_root := get_editor_interface().get_edited_scene_root()
	if paint_controller.preview_root == null and scene_root != null:
		paint_controller.setup_previews(scene_root)

	if event is InputEventMouseMotion:
		_last_mouse_pos = event.position
		_last_mouse_camera = camera
		var hit := _pick_paint_surface(camera, event.position)
		if not hit.is_empty():
			paint_controller.update_cursor(hit["point"], hit["normal"], hit["mesh"], hit["face_index"])
			_sync_paint_readout()
			if paint_controller.is_stroke_active:
				paint_controller.apply_paint_stroke()
		else:
			paint_controller.clear_cursor()
			_sync_paint_readout()

		if paint_controller.is_stroke_active:
			return AFTER_GUI_INPUT_STOP
		return AFTER_GUI_INPUT_PASS

	if event is InputEventMouseButton:
		# Plain mouse clicks only. Mouse wheel passes through to camera zoom untouched.
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if _export_dialog != null and _export_dialog.visible:
					return AFTER_GUI_INPUT_PASS
				# Make sure hit is up-to-date at click time
				var hit := _pick_paint_surface(camera, event.position)
				if not hit.is_empty():
					paint_controller.update_cursor(hit["point"], hit["normal"], hit["mesh"], hit["face_index"])
				_sync_paint_readout()
				if paint_controller.mode == PBPaintController.Mode.PAINT:
					paint_controller.begin_stroke()
					return AFTER_GUI_INPUT_STOP
				elif paint_controller.mode == PBPaintController.Mode.STAMP:
					paint_controller.apply_stamp()
					return AFTER_GUI_INPUT_STOP
			else:
				if paint_controller.mode == PBPaintController.Mode.PAINT and paint_controller.is_stroke_active:
					paint_controller.end_stroke()
					return AFTER_GUI_INPUT_STOP
	if event is InputEventKey and event.pressed:
		var k := event as InputEventKey
		if k.keycode == KEY_ESCAPE:
			paint_controller.reset()
			_sync_paint_readout()
			if material_dock != null:
				material_dock._set_dock_mode(PBMaterialDock.DockMode.MATERIAL)
			return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_PASS

## The overlay's extents row carries the paint cursor's state: why nothing is
## happening when the brush hovers a surface the tools refuse (a billboard
## sprite's transparent quad), or the decal layer's REAL texel density where a
## stamp will land — the number that says whether a decal can be crisp on this
## face (it drops on huge faces once the window hits its cap, which is why the
## same sticker reads sharper on a small panel than on a 60 m floor).
func _sync_paint_readout() -> void:
	if tool_overlay == null or paint_controller == null:
		return
	if not paint_controller.blocked_reason.is_empty():
		tool_overlay.set_creation_extents("Not paintable: %s — painting would drop its alpha"
			% paint_controller.blocked_reason)
		return
	var mesh := paint_controller.target_mesh
	if paint_controller.mode != PBPaintController.Mode.STAMP or mesh == null \
			or mesh.pb_mesh_data == null or not paint_controller.paintable:
		tool_overlay.set_creation_extents("")
		return
	var data := mesh.pb_mesh_data
	var face_idx := paint_controller.target_face_idx
	if face_idx < 0 or face_idx >= data.faces.size():
		tool_overlay.set_creation_extents("")
		return
	var face := data.faces[face_idx]
	var bounds := PBSplat.get_face_planar_bounds(data, face)
	var mat := data.get_face_material(face)
	if bounds.is_empty() or not PBSplat.is_splat_material(mat):
		tool_overlay.set_creation_extents("")
		return
	var dens := PBSplat.decal_density(mat as ShaderMaterial,
			Vector2(bounds["range_u"], bounds["range_v"]))
	if dens <= 0.0:
		tool_overlay.set_creation_extents("")
		return
	tool_overlay.set_creation_extents("Decal: %.0f texels/m%s" % [dens,
		" — low for this face (the window is capped; a smaller painted span is sharper)"
			if dens < PBSplat.DECAL_TEXELS_PER_M * 0.5 else ""])

func _pick_paint_surface(camera: Camera3D, screen_pos: Vector2) -> Dictionary:
	var ray_o: Vector3 = camera.project_ray_origin(screen_pos)
	var ray_d: Vector3 = camera.project_ray_normal(screen_pos)
	var best_dist := INF
	var best_res := {}
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return best_res

	# 1. First test editor.active_mesh if available
	if editor != null and editor.active_mesh != null and editor.active_mesh.pb_mesh_data != null and editor.active_mesh.is_visible_in_tree():
		var node: PBMesh = editor.active_mesh
		var res := PBPicking.pick_face(node.pb_mesh_data, node.global_transform, ray_o, ray_d)
		if res.face_index >= 0:
			var normal := PBMath.normal_from_positions(
				node.pb_mesh_data.positions, node.pb_mesh_data.faces[res.face_index].get_indexes())
			var world_normal: Vector3 = (node.global_transform.basis * normal).normalized()
			return {
				"mesh": node,
				"face_index": res.face_index,
				"point": res.hit_point,
				"normal": world_normal,
				"distance": res.distance
			}

	# 2. Test all other PBMesh instances in the scene
	for node in _collect_pbmeshes(scene_root):
		if node.pb_mesh_data == null or not node.is_visible_in_tree():
			continue
		if editor != null and node == editor.active_mesh:
			continue
		var res := PBPicking.pick_face(node.pb_mesh_data, node.global_transform, ray_o, ray_d)
		if res.face_index >= 0 and res.distance < best_dist:
			best_dist = res.distance
			var normal := PBMath.normal_from_positions(
				node.pb_mesh_data.positions, node.pb_mesh_data.faces[res.face_index].get_indexes())
			var world_normal: Vector3 = (node.global_transform.basis * normal).normalized()
			best_res = {
				"mesh": node,
				"face_index": res.face_index,
				"point": res.hit_point,
				"normal": world_normal,
				"distance": res.distance
			}

	return best_res
# ==============================================================================
# Shape Params modal (create + edit sessions)
# ==============================================================================

func _on_param_changed(param_name: String, value: float) -> void:
	if _params_session_kind == "create":
		shape_creator.set_param(param_name, value)
		_refresh_preview()
	elif _params_session_kind == "trim_walls":
		trim_walls_tool.params[param_name] = value
		_refresh_trim_walls_preview()
	elif _params_session_kind == "bevel":
		if param_name == "distance":
			op_bevel_amount = value
		elif param_name == "segments":
			op_bevel_segments = clampi(int(round(value)), 1, 8)
		_update_bevel_preview()
	elif _params_session_kind == "emitter_edit" and _params_edit_emitter != null \
			and is_instance_valid(_params_edit_emitter):
		_params_edit_values[param_name] = value
		# Live preview: rebuild the emitter from the merged values on every
		# spinner tick; Apply wraps the whole session into ONE undo action.
		PBParticleParams.apply_values(_params_edit_emitter, _params_edit_values,
			_emitter_texture(_params_edit_emitter))
	elif _params_session_kind == "edit" and _params_edit_node != null \
			and is_instance_valid(_params_edit_node):
		_params_edit_values[param_name] = value
		var data := _params_edit_node.pb_mesh_data
		if data != null and data.shape_id == &"trim" and param_name == "depth":
			_persist_trim_project_values(_params_edit_values)
		var old_materials: Array[Material] = data.materials.duplicate() if data != null else []
		var rebuilt := PBShapeParams.build(data.shape_id, _params_edit_values)
		if rebuilt != null:
			rebuilt.shape_id = data.shape_id
			rebuilt.shape_params = _params_edit_values.duplicate()
			rebuilt.shape_edited = false

			# For sprites: preserve texture and apply lit / billboard / cast_shadow live
			if data.shape_id == &"sprite":
				var is_lit: bool = float(_params_edit_values.get("lit", 0.0)) > 0.5
				var is_billboard: bool = float(_params_edit_values.get("billboard", 1.0)) > 0.5
				var has_shadow: bool = float(_params_edit_values.get("cast_shadow", 1.0)) > 0.5

				var existing_tex: Texture2D = null
				if not old_materials.is_empty() and old_materials[0] is StandardMaterial3D:
					existing_tex = (old_materials[0] as StandardMaterial3D).albedo_texture

				var smat := PBSpritePlacer.create_billboard_material(existing_tex, is_lit, is_billboard)
				rebuilt.materials = [smat]
				_params_edit_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED if has_shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

			_params_edit_node.pb_mesh_data = rebuilt
			_params_edit_node.rebuild()
			_params_edit_node.update_gizmos()

## Re-entrancy guard for the params dispatch: committing or cancelling a
## session switches select_mode, and the mode-change handler's "apply any
## open modal first" rule re-enters the dispatch while it is running. With
## two disagreeing mode assignments that ping-ponged EDGE<->FACE until the
## stack blew (the v0.9.105 bevel-Apply crash).
var _params_dispatch_underway := false

func _on_params_applied() -> void:
	if _params_dispatch_underway:
		return
	_params_dispatch_underway = true
	if _params_session_kind == "create":
		var node := shape_creator.preview_node
		shape_creator.values = tool_overlay.get_param_values()
		_finalize_created_shape(node)
		_finish_creation_session(node)
		if logger:
			logger.info("plugin", "Shape parameters applied")
	elif _params_session_kind == "trim_walls":
		trim_walls_tool.params = tool_overlay.get_param_values()
		_trim_walls_commit()
	elif _params_session_kind == "edit":
		_commit_edit_params()
	elif _params_session_kind == "emitter_edit":
		_commit_edit_emitter_params()
	elif _params_session_kind == "bevel":
		_commit_bevel_session()
	_params_dispatch_underway = false

func _on_params_canceled() -> void:
	if _params_dispatch_underway:
		return
	_params_dispatch_underway = true
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
			if _params_edit_node.pb_mesh_data != null and _params_edit_node.pb_mesh_data.shape_id == &"sprite":
				_params_edit_node.cast_shadow = _params_edit_snapshot_cast_shadow
			_params_edit_node.rebuild()
			_params_edit_node.update_gizmos()
		_params_session_kind = ""
		_params_edit_node = null
		_params_edit_snapshot = null
		_params_edit_values = {}
		if logger:
			logger.info("plugin", "Shape parameters edit cancelled")
	elif _params_session_kind == "emitter_edit":
		if _params_edit_emitter != null and is_instance_valid(_params_edit_emitter) \
				and not _params_edit_emitter_snapshot.is_empty():
			_restore_emitter_snapshot(_params_edit_emitter, _params_edit_emitter_snapshot)
		_close_emitter_session()
		if logger:
			logger.info("plugin", "Emitter parameters edit cancelled")
	elif _params_session_kind == "trim_walls":
		_trim_walls_disarm("cancelled")
	elif _params_session_kind == "bevel":
		_cancel_bevel_session()
	else:
		_params_session_kind = ""
		_params_edit_node = null
		_params_edit_snapshot = null
		_params_edit_values = {}

	if tool_overlay != null:
		tool_overlay.close_params()
	_params_dispatch_underway = false

func _start_bevel_modal(mesh: PBMesh, is_face_bevel: bool, faces: PackedInt32Array, edges: Array[PBEdge], max_amount: float, eff_amount: float, new_face_ids: PackedInt32Array, pre_snapshot: PBMeshData) -> void:
	_params_session_kind = "bevel"
	_bevel_session_node = mesh
	_bevel_session_snapshot = pre_snapshot
	_bevel_session_is_face_bevel = is_face_bevel
	_bevel_session_faces = faces
	_bevel_session_edges = edges
	_bevel_session_mode = editor.select_mode
	_bevel_session_last_new_faces = new_face_ids
	# The slider max is the op's own representable clamp, so every position on
	# the slider produces a valid bevel — dragging can never toggle between a
	# proper bevel and a refused/tiny one.
	var max_d := maxf(0.05, max_amount) if max_amount < INF else 1.0
	var defs := [
		{"name": "distance", "label": "Distance", "min": 0.0, "max": max_d, "step": 0.01, "suffix": "m"},
		{"name": "segments", "label": "Segments", "min": 1, "max": 8, "step": 1, "kind": "int"}
	]
	var values := {
		"distance": eff_amount,
		"segments": op_bevel_segments
	}
	tool_overlay.open_params("Bevel Settings", defs, values)

func _update_bevel_preview() -> void:
	if _bevel_session_node == null or _bevel_session_snapshot == null:
		return
	var mesh_data := _bevel_session_node.pb_mesh_data
	PBCommand.restore_mesh_data(mesh_data, _bevel_session_snapshot)
	var result: Dictionary
	if _bevel_session_is_face_bevel:
		result = PBMeshOps.bevel_faces(mesh_data, _bevel_session_faces, op_bevel_amount, op_bevel_segments)
	else:
		var edge_ids := PBMeshOps.common_edge_ids(mesh_data, _bevel_session_edges)
		if _bevel_session_mode == PBEditor.SelectMode.FACE and _bevel_session_faces.size() == _bevel_session_snapshot.faces.size():
			edge_ids = PBMeshOps.face_edges_common_ids(mesh_data, _bevel_session_faces)
		result = PBMeshOps.bevel_edges(mesh_data, edge_ids, op_bevel_amount, op_bevel_segments)
	if result.get("ok", false):
		_bevel_session_last_new_faces = result.get("new_face_ids", PackedInt32Array())
	_bevel_session_node.rebuild()
	_bevel_session_node.update_gizmos()

func _commit_bevel_session() -> void:
	if _bevel_session_node == null or _bevel_session_snapshot == null:
		return
	var node := _bevel_session_node
	var data := node.pb_mesh_data
	var before := _bevel_session_snapshot
	var after := PBCommand.copy_mesh_data(data)
	var session_mode := _bevel_session_mode
	var new_faces := _bevel_session_last_new_faces.duplicate()
	# Tear the session down BEFORE touching mode/selection: the mode switch
	# below fires _on_select_mode_changed, whose "apply any open modal first"
	# rule re-enters this commit while the session is still marked open —
	# and two disagreeing mode assignments (session mode vs FACE) then
	# ping-ponged until the stack blew. (The _params_dispatch_underway guard
	# is the second belt; this ordering is the actual fix.)
	_params_session_kind = ""
	_bevel_session_node = null
	_bevel_session_snapshot = null
	_bevel_session_faces = PackedInt32Array()
	_bevel_session_edges = []
	_bevel_session_last_new_faces = PackedInt32Array()

	var cmd := CmdMeshOp.new(data, "Bevel", node)
	cmd.before = before
	cmd.after = after
	if logger:
		cmd.logger = logger
	cmd.add_to_undo_manager(get_undo_redo())

	# Dismissing the dialog does NOT deselect: the bevel's own output (the
	# band/corner faces) becomes the selection, through the same path as an
	# ordinary face selection — provided the op produced a valid band. Clear
	# FIRST so the mode switch's conversion runs from a clean slate, then
	# apply the set (works whether or not the FACE switch fires a signal).
	if not new_faces.is_empty() and is_instance_valid(node):
		editor.selection.clear_all()
		node.clear_subgizmo_selection()
		gizmo_plugin.element_editor.reset_side_faces()
		editor.select_mode = PBEditor.SelectMode.FACE
		_apply_selection_set(node, new_faces, PackedInt32Array())
		node.update_gizmos()
	else:
		editor.select_mode = session_mode
		editor.selection.clear_all()
		if is_instance_valid(node):
			node.clear_subgizmo_selection()
			node.update_gizmos()
	if tool_overlay != null:
		tool_overlay.close_params()
	if logger:
		logger.info("plugin", "Bevel operation committed")

func _cancel_bevel_session() -> void:
	var node := _bevel_session_node
	var snapshot := _bevel_session_snapshot
	var session_mode := _bevel_session_mode
	var faces := _bevel_session_faces
	var edges := _bevel_session_edges
	# Session closed before any state work — same re-entrancy contract as
	# the commit path above.
	_params_session_kind = ""
	_bevel_session_node = null
	_bevel_session_snapshot = null
	_bevel_session_faces = PackedInt32Array()
	_bevel_session_edges = []
	_bevel_session_last_new_faces = PackedInt32Array()
	if node != null and is_instance_valid(node) and snapshot != null:
		PBCommand.restore_mesh_data(node.pb_mesh_data, snapshot)
		node.rebuild()
		node.update_gizmos()
		editor.select_mode = session_mode
		if session_mode == PBEditor.SelectMode.FACE:
			editor.selection.set_faces(faces)
		elif session_mode == PBEditor.SelectMode.EDGE:
			editor.selection.set_edges(edges)
	if tool_overlay != null:
		tool_overlay.close_params()
	if logger:
		logger.info("plugin", "Bevel cancelled and reverted")
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
	_params_edit_snapshot_cast_shadow = mesh.cast_shadow
	_params_edit_values = data.shape_params.duplicate()

	tool_overlay.open_params("%s Parameters" % String(data.shape_id).capitalize(),
		PBShapeParams.get_param_defs(data.shape_id), _params_edit_values)
## Edit Emitter Properties on a selected GPUParticles3D: live rebuilds via
## PBParticleParams (the same builders the placement tool uses, so a
## hand-tuned emitter stays export-identical); Apply commits one undo action,
## Cancel restores the pre-session properties. PBMesh shapes and emitters can
## share the modal machinery but never the session state.
func _on_edit_emitter_requested() -> void:
	if _params_session_kind != "":
		return
	var emitter := _params_edit_emitter if _params_edit_emitter != null and is_instance_valid(_params_edit_emitter) else _selected_emitter()
	if emitter == null:
		return
	_params_session_kind = "emitter_edit"
	_params_edit_emitter = emitter
	_params_edit_emitter_snapshot = _emitter_snapshot(emitter)
	_params_edit_values = PBParticleParams.values_from_node(emitter)

	tool_overlay.params_sticky = true
	tool_overlay.open_params("Emitter Parameters",
		PBParticleParams.get_param_defs(), _params_edit_values)
	if logger:
		logger.info("plugin", "Emitter properties session opened on %s" % emitter.name)

func _selected_emitter() -> GPUParticles3D:
	var selection: EditorSelection = get_editor_interface().get_selection()
	if selection == null:
		return null
	for node in selection.get_selected_nodes():
		if node is GPUParticles3D:
			return node as GPUParticles3D
	return null

func _emitter_snapshot(emitter: GPUParticles3D) -> Dictionary:
	return {
		"process_material": emitter.process_material,
		"draw_pass_1": emitter.draw_pass_1,
		"amount": emitter.amount,
		"seed": emitter.seed,
		"use_fixed_seed": emitter.use_fixed_seed,
		"poi_seed": emitter.get_meta("poi_seed") if emitter.has_meta("poi_seed") else null,
		"poi_y_locked": emitter.get_meta("poi_y_locked") if emitter.has_meta("poi_y_locked") else null,
	}

func _restore_emitter_snapshot(emitter: GPUParticles3D, snap: Dictionary) -> void:
	emitter.process_material = snap.get("process_material")
	emitter.draw_pass_1 = snap.get("draw_pass_1")
	emitter.amount = int(snap.get("amount", 1))
	emitter.seed = int(snap.get("seed", 0))
	emitter.use_fixed_seed = bool(snap.get("use_fixed_seed", false))
	if snap.get("poi_seed", null) != null:
		emitter.set_meta("poi_seed", snap["poi_seed"])
	else:
		emitter.remove_meta("poi_seed")
	if snap.get("poi_y_locked", null) != null:
		emitter.set_meta("poi_y_locked", snap["poi_y_locked"])
	else:
		emitter.remove_meta("poi_y_locked")

## The emitter's current albedo texture (draw-pass material), preserved
## across property edits.
static func _emitter_texture(emitter: GPUParticles3D) -> Texture2D:
	if emitter == null:
		return null
	var draw_mat: Material = emitter.material_override
	if draw_mat == null and emitter.draw_pass_1 != null and emitter.draw_pass_1.get_surface_count() > 0:
		draw_mat = emitter.draw_pass_1.surface_get_material(0)
	if draw_mat is StandardMaterial3D:
		return (draw_mat as StandardMaterial3D).albedo_texture
	return null

func _commit_edit_emitter_params() -> void:
	var node := _params_edit_emitter
	if node == null or not is_instance_valid(node):
		return
	var snap := _params_edit_emitter_snapshot
	var undo := get_undo_redo()
	undo.create_action("Edit Emitter Params", UndoRedo.MERGE_DISABLE, node)
	undo.add_do_method(self, "_restore_emitter_snapshot", node, _emitter_snapshot(node))
	undo.add_undo_method(self, "_restore_emitter_snapshot", node, snap)
	undo.commit_action()
	_close_emitter_session()
	if logger:
		logger.info("plugin", "Emitter parameters committed")

func _close_emitter_session() -> void:
	tool_overlay.params_sticky = false
	tool_overlay.close_params()
	_params_session_kind = ""
	_params_edit_emitter = null
	_params_edit_emitter_snapshot = {}
	_params_edit_values = {}

func _commit_edit_params() -> void:
	var node := _params_edit_node
	if node == null or not is_instance_valid(node) or node.pb_mesh_data == null:
		return
	var data := node.pb_mesh_data
	data.shape_params = _params_edit_values.duplicate()
	data.shape_edited = false
	if data.shape_id == &"sprite":
		var has_shadow: bool = float(_params_edit_values.get("cast_shadow", 1.0)) > 0.5
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED if has_shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var before := _params_edit_snapshot
	var after := PBCommand.copy_mesh_data(data)
	var undo := get_undo_redo()
	undo.create_action("Edit %s Params" % String(data.shape_id).capitalize(),
		UndoRedo.MERGE_DISABLE, node)
	undo.add_do_method(self, "_restore_mesh_snapshot", node.get_instance_id(), after)
	undo.add_undo_method(self, "_restore_mesh_snapshot", node.get_instance_id(), before)
	if data.shape_id == &"sprite":
		undo.add_do_property(node, "cast_shadow", node.cast_shadow)
		undo.add_undo_property(node, "cast_shadow", _params_edit_snapshot_cast_shadow)
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
