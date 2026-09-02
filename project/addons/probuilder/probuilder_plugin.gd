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

# ==============================================================================
# UI Components
# ==============================================================================

var tool_overlay: PBToolOverlay
var toolbar: PBToolbar

## Hover id already reflected in the last gizmo redraw (avoids redundant
## update_gizmos calls on every motion event).
var _hover_drawn_last: int = -1

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
const VERSION := "0.8.0"

func _enter_tree():
	logger.info("plugin", "PoiBuilder v%s entering tree" % VERSION)

	# Wire up subsystems
	editor.logger = logger
	gizmo_plugin.editor = editor
	gizmo_plugin.logger = logger
	gizmo_plugin.element_editor.editor = editor
	gizmo_plugin.element_editor.undo = get_undo_redo()
	tool_bridge.logger = logger
	tool_bridge.on_tool_selected = _on_engine_tool_selected

	# Connect editor signals
	editor.active_mesh_changed.connect(_on_active_mesh_changed)
	editor.select_mode_changed.connect(_on_select_mode_changed)
	editor.element_selection_changed.connect(_on_element_selection_changed)
	editor.orientation_space_changed.connect(_on_orientation_space_changed)
	editor.tool_mode_changed.connect(_on_tool_mode_changed)
	gizmo_plugin.element_editor.element_drag_updated.connect(_on_drag_updated)

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

	# Persistent toolbar row UNDER the 3D scene toolbar (not inside it)
	toolbar = PBToolbar.new()
	toolbar.editor = editor
	toolbar.set_editing_active(false)
	toolbar.shape_requested.connect(_on_shape_requested)
	_add_toolbar_row_below_3d_toolbar()

	# Tool overlay panel floating in the 3D viewport (replaces the docks;
	# logging goes to the Godot console via PBLogger).
	tool_overlay = PBToolOverlay.new()
	tool_overlay.editor = editor
	tool_overlay.element_editor = gizmo_plugin.element_editor
	tool_overlay.visible = false
	tool_overlay.operation_requested.connect(_on_operation_requested)
	_add_overlay_to_3d_viewport(tool_overlay)

	# Bridge onto the editor's tool buttons (own tool modes; never the
	# universal gizmo). Needs the Node3DEditor, located via the toolbar walk.
	if toolbar_has_3d_editor():
		if tool_bridge.setup(_n3d_editor):
			logger.info("plugin", "Tool bridge attached to the editor's Move/Rotate/Scale buttons; Q/V pin out while editing")
		else:
			logger.warn("plugin", "Engine tool buttons not found — plugin tool modes will not drive the editor gizmo")
	else:
		logger.warn("plugin", "Node3DEditor not found — tool bridge inactive")

	# Listen for selection changes
	var selection: EditorSelection = get_editor_interface().get_selection()
	selection.selection_changed.connect(_on_selection_changed)

	logger.info("plugin", "PoiBuilder plugin initialized")

func _exit_tree():
	if logger:
		logger.info("plugin", "PoiBuilder plugin exiting tree")

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
	if not editor.is_editing():
		return AFTER_GUI_INPUT_PASS

	# Hover highlight: observe motion WITHOUT consuming it. The engine keeps
	# processing (camera nav, marquee, gizmo drags). Picking is skipped while
	# a button is held or a subgizmo drag is in flight.
	if event is InputEventMouseMotion and event.button_mask == 0 \
			and not gizmo_plugin.element_editor.drag_active:
		var node := editor.active_mesh
		if node != null and node.pb_mesh_data != null:
			var id: int = gizmo_plugin.element_editor.pick_ray(
				node.pb_mesh_data, node.global_transform, camera, event.position)
			editor.hover_id = id
			if editor.hover_id != _hover_drawn_last:
				_hover_drawn_last = editor.hover_id
				node.update_gizmos()
			return AFTER_GUI_INPUT_PASS

	# Element mode hotkeys (matching ProBuilder: H vertex, J edge, K face,
	# X cycles gizmo space). Move/rotate/scale are the plugin's OWN tool
	# buttons (and W/E/R mirror in via the engine tool buttons).
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
		mesh.update_gizmos()
	else:
		editor.hover_id = -1
	_update_editing_context()

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
	if editor.is_editing() and tool_bridge.is_ready():
		tool_bridge.apply_tool(editor.tool_mode)

## The user switched the engine tool itself (W/E/R or its toolbar buttons)
## while editing — mirror it into the plugin's own tool state.
func _on_engine_tool_selected(tool: int) -> void:
	if editor.is_editing():
		editor.tool_mode = tool as PBEditor.ToolMode

## Applies the plugin editing context to the editor UI: toolbar buttons,
## engine tool buttons (universal/select disabled while editing, our tool
## forced active), and the overlay panel visibility.
func _update_editing_context() -> void:
	var editing := editor.is_editing()
	toolbar.set_editing_active(editing)
	tool_overlay.visible = editor.active_mesh != null
	if tool_bridge.is_ready():
		tool_bridge.set_editing_active(editing)
		if editing:
			tool_bridge.editor_space = editor.orientation_space
			tool_bridge.apply_orientation_space(editor.orientation_space)
			tool_bridge.apply_tool(editor.tool_mode)

func _on_drag_updated(active: bool, _t: Vector3, _r: Vector3, _s: Vector3) -> void:
	if active:
		editor.hover_id = -1
		_hover_drawn_last = -1
		if editor.active_mesh != null:
			editor.active_mesh.update_gizmos()

# ==============================================================================
# Mesh Operations (overlay OPERATIONS section)
# ==============================================================================

## Performs a mesh op from the overlay on the current selection. Face-mode
## ops read the selected faces; edge extrude reads the selected edges. Undo
## goes through full-mesh snapshots (CmdMeshOp) — ops rewrite topology, so
## per-index payloads don't apply.
func _on_operation_requested(op_name: String) -> void:
	if not editor.is_editing() or editor.active_mesh == null:
		return
	var mesh := editor.active_mesh
	var mesh_data: PBMeshData = mesh.pb_mesh_data
	if mesh_data == null:
		return

	var distance: float = tool_overlay.extrude_distance
	var amount: float = tool_overlay.inset_amount
	var selection := editor.selection

	if op_name == "detach_faces":
		_perform_detach(mesh, selection.selected_faces.duplicate())
		return

	var cmd := CmdMeshOp.new(mesh_data, OP_ACTION_NAMES.get(op_name, "Mesh Operation"))
	var result: Dictionary
	match op_name:
		"extrude_faces":
			result = PBMeshOps.extrude_faces(mesh_data, selection.selected_faces.duplicate(), distance)
		"inset_faces":
			result = PBMeshOps.inset_faces(mesh_data, selection.selected_faces.duplicate(), amount)
		"subdivide_faces":
			result = PBMeshOps.subdivide_faces(mesh_data, selection.selected_faces.duplicate())
		"delete_faces":
			result = PBMeshOps.delete_faces(mesh_data, selection.selected_faces.duplicate())
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

	var undo := get_undo_redo()
	undo.create_action("Detach Faces")
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
	if logger:
		logger.info("mesh_ops", "%s: %d new face(s)" % [op_name, new_face_count])

## Undo-history display names per overlay op.
const OP_ACTION_NAMES := {
	"extrude_faces": "Extrude Faces",
	"inset_faces": "Inset Faces",
	"subdivide_faces": "Subdivide Faces",
	"delete_faces": "Delete Faces",
	"detach_faces": "Detach Faces",
	"extrude_edges": "Extrude Edges",
	"insert_edge_loop": "Insert Edge Loop",
}

# ==============================================================================
# Shape Creation (toolbar New Shape menu)
# ==============================================================================

## Creates a new PBMesh from a factory shape id, places it in front of the
## editor camera, registers a node-level undo action, and selects it. Works
## with nothing selected — creation needs no editing context.
func _on_shape_requested(shape_id: StringName) -> void:
	var data := PBShapeFactory.create_shape(shape_id)
	if data == null:
		if logger:
			logger.warn("plugin", "Unknown shape id: %s" % shape_id)
		return
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		if logger:
			logger.warn("plugin", "No edited scene — shape not created")
		return

	var node := PBMesh.new()
	node.name = _unique_shape_name(scene_root, shape_id)
	node.pb_mesh_data = data
	node.global_transform = _placement_transform()

	var undo := get_undo_redo()
	undo.create_action("Add %s" % String(shape_id).capitalize())
	undo.add_do_method(self, "_attach_detached", node, scene_root)
	undo.add_do_reference(node)
	undo.add_undo_method(self, "_detach_node", node)
	undo.commit_action()

	# Select the new shape so element editing starts immediately (not part
	# of the undo action — selection state is the user's to change).
	var editor_selection := get_editor_interface().get_selection()
	editor_selection.clear()
	editor_selection.add_node(node)

	if logger:
		logger.info("plugin", "Created shape '%s' (%s)" % [node.name, shape_id])

func _unique_shape_name(scene_root: Node, shape_id: StringName) -> String:
	var base := "Shape_%s" % String(shape_id).capitalize().replace(" ", "")
	if scene_root.get_node_or_null(NodePath(base)) == null:
		return base
	var i := 2
	while scene_root.get_node_or_null(NodePath("%s%d" % [base, i])) != null:
		i += 1
	return "%s%d" % [base, i]

## 3m in front of the first 3D editor viewport's camera (origin as fallback).
func _placement_transform() -> Transform3D:
	var viewport: SubViewport = get_editor_interface().get_editor_viewport_3d(0)
	if viewport != null:
		var cam: Camera3D = viewport.get_camera_3d()
		if cam != null:
			var pos: Vector3 = cam.global_position - cam.global_transform.basis.z * 3.0
			return Transform3D(Basis.IDENTITY, pos)
	return Transform3D.IDENTITY

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
func _restore_mesh_snapshot(mesh_id: int, snapshot: PBMeshData) -> void:
	var mesh := instance_from_id(mesh_id) as PBMesh
	if mesh == null or mesh.pb_mesh_data == null:
		return
	PBCommand.restore_mesh_data(mesh.pb_mesh_data, snapshot)
	mesh.rebuild()
	mesh.update_gizmos()

func _attach_detached(node: Node, parent: Node) -> void:
	if parent == null or not is_instance_valid(parent):
		return
	parent.add_child(node)
	node.owner = get_editor_interface().get_edited_scene_root()

## Undo of detach: remove the node WITHOUT freeing it — the undo history's
## do-reference keeps it alive so redo can re-attach it.
func _detach_node(node: Node) -> void:
	if node != null and is_instance_valid(node) and node.get_parent() != null:
		node.get_parent().remove_child(node)
