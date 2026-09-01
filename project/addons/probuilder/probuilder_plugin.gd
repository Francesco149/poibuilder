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

	return AFTER_GUI_INPUT_PASS

func _forward_3d_draw_over_viewport(viewport_control: Control):
	# 2D overlay drawing (e.g. stats, labels) — placeholder for future use
	pass

# ==============================================================================
# Selection Handling
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
		overlay.rebuild(editor.select_mode)
		toolbar.activate()
	else:
		overlay.detach()
		toolbar.deactivate()
	update_overlays()

func _on_select_mode_changed(mode: PBEditor.SelectMode) -> void:
	overlay.rebuild(mode)
	update_overlays()
