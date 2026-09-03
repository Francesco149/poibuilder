## PBEditor — Central editor state for PoiBuilder.
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
const PLUGIN_VERSION := "0.9.17"

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

## The plugin's OWN transform tool, shown by the PoiBuilder toolbar. While
## editing we never follow the editor's Q/V (universal/select) tool state —
## one of these three is always active, so the engine's transform gizmo over
## the elements always shows exactly move arrows, rotate rings, or scale
## handles, and never the combined universal gizmo.
enum ToolMode {
	MOVE,     ## Translate arrows
	ROTATE,   ## Rotation rings
	SCALE,    ## Scale handles
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

## Emitted when the active transform tool changes.
signal tool_mode_changed(tool: ToolMode)

## Emitted when the hovered element id changes (-1 = nothing hovered).
signal hover_changed(id: int)

# ==============================================================================
# State
# ==============================================================================

## Current element selection mode.
var select_mode: SelectMode = SelectMode.OBJECT:
	set = set_select_mode

## The plugin's active transform tool (independent of the editor's Q/W/E/R
## state; the bridge mirrors it onto the editor's tool buttons).
var tool_mode: ToolMode = ToolMode.MOVE:
	set = set_tool_mode

## Element id currently under the cursor for hover highlighting, or -1.
var hover_id: int = -1:
	set = set_hover_id

## The active (selected) PBMesh, or null.
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

## Last element mode the user was in. Re-entering a PBMesh (after clicking
## off, selecting another node, or deselecting everything) restores this
## instead of falling back to FACE, so the plugin "stays in" its mode.
var _last_element_mode: SelectMode = SelectMode.FACE

## True while OBJECT mode was chosen EXPLICITLY (toolbar button / mode set).
## An explicit object mode survives deselect + reselect (clicking off an
## object and back must not bounce the user into an element mode); the
## IMPLICIT object mode (fresh editor, nothing chosen yet) still hands over
## to the remembered element mode on first selection.
var _object_mode_explicit: bool = false

# ==============================================================================
# Setters
# ==============================================================================

func set_select_mode(value: SelectMode) -> void:
	if select_mode == value:
		return
	var old := select_mode
	select_mode = value
	if value != SelectMode.OBJECT:
		_last_element_mode = value
	_object_mode_explicit = value == SelectMode.OBJECT
	if logger:
		logger.info("editor", "Mode changed: %s → %s" % [SelectMode.keys()[old], SelectMode.keys()[value]])
	select_mode_changed.emit(select_mode)

func set_tool_mode(value: ToolMode) -> void:
	if tool_mode == value:
		return
	tool_mode = value
	if logger:
		logger.info("editor", "Tool changed: %s" % ToolMode.keys()[value])
	tool_mode_changed.emit(tool_mode)

func set_hover_id(value: int) -> void:
	if hover_id == value:
		return
	hover_id = value
	hover_changed.emit(hover_id)

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
	var previous := active_mesh
	# Disconnect old selection signal
	if selection.selection_changed.is_connected(_on_selection_changed):
		selection.selection_changed.disconnect(_on_selection_changed)
	active_mesh = value
	if active_mesh == null:
		selection.set_mesh_data(null)
		hover_id = -1
		# Keep select_mode as-is: the plugin remembers the element mode, so
		# clicking off the object and back (or selecting another node and
		# back) re-enters the same mode.
	else:
		selection.set_mesh_data(active_mesh.pb_mesh_data)
		if select_mode == SelectMode.OBJECT and previous == null and not _object_mode_explicit:
			# FIRST entry into any mesh (from nothing selected, with no
			# explicit mode choice yet) lands in the remembered element mode.
			# An EXPLICIT object mode stays (clicking off and back must not
			# bounce the user out of object mode), and switching BETWEEN
			# meshes keeps whatever mode is current.
			select_mode = _last_element_mode
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

## Leaves OBJECT mode into the remembered element mode (e.g. after a shape
## creation session hands the new node over — the user can immediately
## select edges/faces/verts).
func restore_element_mode() -> void:
	if select_mode == SelectMode.OBJECT:
		select_mode = _last_element_mode

## Returns the display name for a given mode.
static func mode_name(mode: SelectMode) -> String:
	return SelectMode.keys()[mode].capitalize()

## Returns the display name for a given tool.
static func tool_name(tool: ToolMode) -> String:
	return ToolMode.keys()[tool].capitalize()

# ==============================================================================
# Selection Callbacks
# ==============================================================================

func _on_selection_changed() -> void:
	element_selection_changed.emit()
