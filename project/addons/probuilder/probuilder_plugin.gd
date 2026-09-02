@tool
extends EditorPlugin
class_name ProBuilderPlugin

# ==============================================================================
# Core Systems
# ==============================================================================

var logger: PBLogger = PBLogger.new()
var editor: PBEditor = PBEditor.new()
var gizmo_plugin: PBGizmoPlugin = PBGizmoPlugin.new()

# ==============================================================================
# UI Components
# ==============================================================================

var debug_dock_panel: PBDebugDock
var debug_dock: Control
var tool_properties_dock_panel: PBToolPropertiesDock
var tool_properties_dock: Control
var toolbar: PBToolbar

# ==============================================================================
# Plugin Lifecycle
# ==============================================================================

func _get_plugin_name() -> String:
	return "ProBuilder"

## Bump when behavior changes so stale-build testing is detectable.
const VERSION := "0.6.9"

func _enter_tree():
	logger.info("plugin", "ProBuilder v%s entering tree" % VERSION)

	# Wire up subsystems
	editor.logger = logger
	gizmo_plugin.editor = editor
	gizmo_plugin.logger = logger
	gizmo_plugin.element_editor.editor = editor
	gizmo_plugin.element_editor.undo = get_undo_redo()

	# Connect editor signals
	editor.active_mesh_changed.connect(_on_active_mesh_changed)
	editor.select_mode_changed.connect(_on_select_mode_changed)
	editor.element_selection_changed.connect(_on_element_selection_changed)
	editor.orientation_space_changed.connect(_on_orientation_space_changed)

	# Register custom type
	add_custom_type(
		"PBMesh",
		"MeshInstance3D",
		preload("res://addons/probuilder/core/pb_mesh.gd"),
		preload("res://addons/probuilder/icons/pb_mesh_icon.svg") if FileAccess.file_exists("res://addons/probuilder/icons/pb_mesh_icon.svg") else null
	)

	# Register the node gizmo plugin — this is the native editor integration:
	# element picking, rubber-band selection, transform drags, snapping, and
	# undo are all driven by the editor through the subgizmo API.
	add_node_3d_gizmo_plugin(gizmo_plugin)

	# Debug dock
	debug_dock_panel = preload("res://addons/probuilder/debug/pb_debug_dock.tscn").instantiate()
	debug_dock_panel.logger = logger
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, debug_dock_panel)
	debug_dock = debug_dock_panel

	# Tool properties dock
	tool_properties_dock_panel = preload("res://addons/probuilder/gui/docks/pb_tool_properties_dock.tscn").instantiate()
	tool_properties_dock_panel.editor = editor
	tool_properties_dock_panel.element_editor = gizmo_plugin.element_editor
	add_control_to_dock(DOCK_SLOT_LEFT_BL, tool_properties_dock_panel)
	tool_properties_dock = tool_properties_dock_panel

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

	# Unregister the gizmo plugin
	remove_node_3d_gizmo_plugin(gizmo_plugin)

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

	# Remove tool properties dock
	if tool_properties_dock:
		remove_control_from_docks(tool_properties_dock)
		tool_properties_dock.queue_free()
		tool_properties_dock = null
		tool_properties_dock_panel = null

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

## Keyboard handling only. ALL mouse events are passed through untouched:
## the native editor viewport handles clicks (subgizmo picking), rubber-band
## element selection, transform-gizmo drags, snapping, and camera controls.
## Hand-rolling any of that here is what caused the Phase 6 regression cluster
## (teleporting elements, double box-selection, stuck marquee).
func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if not editor.is_editing():
		return AFTER_GUI_INPUT_PASS

	# Element click-pick interception: a plain left press that hits an element
	# is consumed HERE and applied via set_subgizmo_selection. Without this,
	# the engine's transform-gizmo hit test (which runs before subgizmo
	# picking) swallows presses anywhere in the gizmo's ring/arrow footprint —
	# edges near the gizmo were unselectable and clicks "dragged the selected
	# edge" instead. Shift/ctrl presses pass through for native toggle
	# semantics; misses pass through for gizmo grabs and rubber-band select.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
			and event.pressed and not event.shift_pressed and not event.ctrl_pressed \
			and not event.alt_pressed:
		var node := editor.active_mesh
		if node != null and node.pb_mesh_data != null:
			var id: int = gizmo_plugin.element_editor.pick_ray(
				node.pb_mesh_data, node.global_transform, camera, event.position)
			if id != -1:
				var gizmo := gizmo_plugin.gizmo_for_node(node)
				if gizmo == null:
					if logger:
						logger.error("selection",
							"Element pick hit but no PB gizmo is attached to '%s' — pass-through" % node.name)
				else:
					var current: PackedInt32Array = gizmo.get_subgizmo_selection()
					# Re-clicking the sole selected element passes through so
					# the transform gizmo's rings stay draggable around it.
					var already_sole: bool = current.size() == 1 and current[0] == id
					if not already_sole:
						# 4.7 signature takes the start transform explicitly
						# (the engine snapshots it as the drag baseline).
						var start_xf: Transform3D = gizmo_plugin.element_editor.get_subgizmo_transform(
							node.pb_mesh_data, node, id)
						node.set_subgizmo_selection(gizmo, id, start_xf)
						return AFTER_GUI_INPUT_STOP

	# Element mode hotkeys (matching ProBuilder: H vertex, J edge, K face,
	# X cycles gizmo space). Godot's own Q/W/E/R already switch
	# select/move/rotate/scale, so tools need no handling here.
	if event is InputEventKey and event.pressed and not event.echo:
		var key_event: InputEventKey = event as InputEventKey
		match key_event.keycode:
			KEY_H:
				if not key_event.ctrl_pressed and not key_event.alt_pressed:
					editor.select_mode = PBEditor.SelectMode.VERTEX
					return AFTER_GUI_INPUT_STOP
			KEY_J:
				if not key_event.ctrl_pressed and not key_event.alt_pressed:
					editor.select_mode = PBEditor.SelectMode.EDGE
					return AFTER_GUI_INPUT_STOP
			KEY_K:
				if not key_event.ctrl_pressed and not key_event.alt_pressed:
					editor.select_mode = PBEditor.SelectMode.FACE
					return AFTER_GUI_INPUT_STOP
			KEY_X:
				# X = Cycle orientation space (Element → Object → World)
				if not key_event.ctrl_pressed and not key_event.alt_pressed and not key_event.shift_pressed:
					editor.cycle_orientation_space()
					return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_PASS

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
		# Heal missing/partial weld groups before any element interaction:
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
		toolbar.activate()
		mesh.update_gizmos()
	else:
		toolbar.deactivate()

func _on_select_mode_changed(mode: PBEditor.SelectMode) -> void:
	# Clear element selection when mode changes (ProBuilder behavior).
	# The engine's subgizmo selection is the authoritative drag source, so it
	# must be cleared too, and the gizmo redrawn for the new element type.
	editor.selection.clear_all()
	gizmo_plugin.element_editor.reset_side_faces()
	if editor.active_mesh != null:
		editor.active_mesh.clear_subgizmo_selection()
		editor.active_mesh.update_gizmos()

func _on_element_selection_changed() -> void:
	if tool_properties_dock_panel:
		tool_properties_dock_panel.refresh()

func _on_orientation_space_changed(_space: PBEditor.OrientationSpace) -> void:
	# Re-fetch subgizmo transforms so the editor re-renders the transform
	# gizmo with the new axis orientation.
	if editor.active_mesh != null:
		editor.active_mesh.update_gizmos()
