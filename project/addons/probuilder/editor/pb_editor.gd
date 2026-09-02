## PBEditor — Central editor state for ProBuilder.
##
## Manages the active PBMesh, element selection mode (Object/Vertex/Edge/Face),
## element selection state, and the gizmo orientation space.
##
## Input, picking, dragging, and transform-gizmo behavior are NOT managed here:
## those are delegated to the native Godot editor via PBGizmoPlugin subgizmos.
## This class only holds state and emits change signals for UI (toolbar, dock).
@tool
class_name PBEditor
extends RefCounted

## Plugin version, shown in the dock and logged at startup so a stale build
## is immediately obvious when behavior "doesn't match" what was fixed.
const PLUGIN_VERSION := "0.6.7"

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

## Coordinate space for the element transform gizmo axes.
enum OrientationSpace {
	ELEMENT,  ## Axes aligned to the selected element's normal
	OBJECT,   ## Axes aligned to the PBMesh node's local transform
	WORLD,    ## Axes aligned to world XYZ
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

## Emitted when the orientation space changes.
signal orientation_space_changed(space: OrientationSpace)

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
## NOTE: the engine's subgizmo selection is authoritative while editing;
## PBGizmoPlugin mirrors engine selection into this object.
var selection: PBSelection = PBSelection.new()

## Logger reference for debug output.
var logger: PBLogger = null:
	set = set_logger

## Active coordinate space for the element transform gizmo orientation.
var orientation_space: OrientationSpace = OrientationSpace.ELEMENT:
	set = set_orientation_space

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

func set_logger(value: PBLogger) -> void:
	logger = value

func set_orientation_space(value: OrientationSpace) -> void:
	if orientation_space == value:
		return
	orientation_space = value
	if logger:
		logger.info("editor", "Orientation space: %s" % OrientationSpace.keys()[value])
	orientation_space_changed.emit(orientation_space)

## Cycles orientation space: Element → Object → World → Element.
func cycle_orientation_space() -> void:
	var next: int = (orientation_space + 1) % OrientationSpace.size()
	set_orientation_space(next as OrientationSpace)

func set_active_mesh(value: PBMesh) -> void:
	if active_mesh == value:
		return
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
