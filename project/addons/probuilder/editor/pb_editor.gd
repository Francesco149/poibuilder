## PBEditor — Central editor state for ProBuilder.
##
## Manages the active PBMesh, selection mode (Object/Vertex/Edge/Face),
## and coordinates overlay/toolbar updates. Lives as a child of the
## EditorPlugin node.
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

# ==============================================================================
# State
# ==============================================================================

## Current element selection mode.
var select_mode: SelectMode = SelectMode.OBJECT:
	set = set_select_mode

## The currently active (selected) PBMesh, or null.
var active_mesh: PBMesh = null:
	set = set_active_mesh

## Logger reference for debug output.
var logger: PBLogger = null

# ==============================================================================
# Setters
# ==============================================================================

func set_select_mode(value: SelectMode) -> void:
	if select_mode == value:
		return
	var old := select_mode
	select_mode = value
	if logger:
		logger.info("editor", "Mode changed: %s → %s" % [SelectMode.keys()[old], SelectMode.keys()[value]])
	select_mode_changed.emit(select_mode)

func set_active_mesh(value: PBMesh) -> void:
	if active_mesh == value:
		return
	active_mesh = value
	if active_mesh == null:
		# Revert to object mode when no mesh is selected
		select_mode = SelectMode.OBJECT
	elif select_mode == SelectMode.OBJECT:
		# Enter face mode by default when a PBMesh is selected (ProBuilder behavior)
		select_mode = SelectMode.FACE
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
