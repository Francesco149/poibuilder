## PBEditor — Central editor state for ProBuilder.
##
## Manages the active PBMesh, selection mode (Object/Vertex/Edge/Face),
## element selection state, and coordinates overlay/toolbar updates.
## Lives as a child of the EditorPlugin node.
@tool
class_name PBEditor
extends RefCounted

# ==============================================================================
# Selection Mode
# ==============================================================================

## Element selection modes matching ProBuilder's SelectMode.
enum SelectMode {
	OBJECT,   ## Standard Godot object-level selection
	VERTEX,   ## Select individual vertices
	EDGE,     ## Select edges
	FACE,     ## Select faces
}

# ==============================================================================
# Signals
# ==============================================================================

## Emitted when the selection mode changes.
signal select_mode_changed(mode: SelectMode)

## Emitted when the active PBMesh node changes (selected/deselected).
signal active_mesh_changed(mesh: PBMesh)

## Emitted when the element selection changes (vertices/edges/faces).
signal element_selection_changed()

## Emitted when the active viewport editing tool changes.
signal active_tool_changed(tool: PBTool)
# ==============================================================================
# State
# ==============================================================================

## Current element selection mode.
var select_mode: SelectMode = SelectMode.OBJECT:
	set = set_select_mode

## The currently active (selected) PBMesh, or null.
var active_mesh: PBMesh = null:
	set = set_active_mesh

## Element selection state for the active mesh.
var selection: PBSelection = PBSelection.new()

## Currently active viewport editing tool, or null for selection-only mode.
var active_tool: PBTool = null:
	set = set_active_tool

## Logger reference for debug output.
var logger: PBLogger = null:
	set = set_logger
# ==============================================================================
# Setters
# ==============================================================================

func set_select_mode(value: SelectMode) -> void:
	if select_mode == value:
		return
	if active_tool != null and active_tool.is_dragging():
		active_tool.cancel_drag()
	var old := select_mode
	select_mode = value
	if logger:
		logger.info("editor", "Mode changed: %s → %s" % [SelectMode.keys()[old], SelectMode.keys()[value]])
	select_mode_changed.emit(select_mode)

func set_active_tool(value: PBTool) -> void:
	if active_tool == value:
		return
	if active_tool != null and active_tool.is_dragging():
		active_tool.cancel_drag()
	active_tool = value
	if active_tool != null:
		active_tool.editor = self
		active_tool.logger = logger
	if logger:
		var tname: String = active_tool.tool_name() if active_tool != null else "Select"
		logger.info("editor", "Active tool: %s" % tname)
	active_tool_changed.emit(active_tool)

func set_logger(value: PBLogger) -> void:
	logger = value
	if active_tool != null:
		active_tool.logger = value
func set_active_mesh(value: PBMesh) -> void:
	if active_mesh == value:
		return
	if active_tool != null and active_tool.is_dragging():
		active_tool.cancel_drag()
	# Disconnect old selection signal
	if selection.selection_changed.is_connected(_on_selection_changed):
		selection.selection_changed.disconnect(_on_selection_changed)
	active_mesh = value
	if active_mesh == null:
		selection.set_mesh_data(null)
		# Revert to object mode when no mesh is selected
		select_mode = SelectMode.OBJECT
	else:
		selection.set_mesh_data(active_mesh.pb_mesh_data)
		if select_mode == SelectMode.OBJECT:
			# Enter face mode by default when a PBMesh is selected (ProBuilder behavior)
			select_mode = SelectMode.FACE
	# Connect new selection signal
	selection.selection_changed.connect(_on_selection_changed)
	if logger:
		var name_str: String = active_mesh.name if active_mesh else "null"
		logger.info("editor", "Active mesh: %s" % name_str)
	active_mesh_changed.emit(active_mesh)

# ==============================================================================
# Queries
# ==============================================================================

## Returns true if we are in any element editing mode (not Object).
func is_editing() -> bool:
	return active_mesh != null and select_mode != SelectMode.OBJECT

## Returns the display name for a given mode.
static func mode_name(mode: SelectMode) -> String:
	return SelectMode.keys()[mode].capitalize()

# ==============================================================================
# Selection Callbacks
# ==============================================================================

func _on_selection_changed() -> void:
	element_selection_changed.emit()
