## PBTool — Base class for viewport manipulation tools (Move, Rotate, Scale).
##
## Defines the standard drag lifecycle for raycast-driven interactive viewport editing:
## - begin_drag(ray_origin, ray_dir) -> bool: Starts drag session if valid target
## - update_drag(ray_origin, ray_dir) -> void: Updates live preview during mouse drag
## - finish_drag(undo = null) -> void: Commits the operation (optionally to undo manager)
## - cancel_drag() -> void: Reverts live preview to initial pre-drag state
@tool
class_name PBTool
extends RefCounted

# ==============================================================================
# Enums & State
# ==============================================================================

## Operational states for viewport tools.
enum State {
	IDLE,      ## Tool is inactive or hovering without drag
	DRAGGING,  ## Tool is actively dragging elements with live preview
}

## Current state of the tool.
var state: State = State.IDLE

## Reference to the PBEditor holding active selection and mesh state.
var editor: PBEditor = null

## Logger for diagnostics and undo/tool operations.
var logger: PBLogger = null

# ==============================================================================
# Public API
# ==============================================================================

## Returns the user-facing display name of this tool.
func tool_name() -> String:
	return "Tool"

## Begins a drag operation given world-space ray origin and direction.
## Returns true if the drag was successfully initiated, or false if rejected.
func begin_drag(ray_origin: Vector3, ray_dir: Vector3) -> bool:
	return false

## Updates the drag operation given the current world-space ray origin and direction.
func update_drag(ray_origin: Vector3, ray_dir: Vector3) -> void:
	pass

## Commits the active drag preview. If undo is provided, registers with the undo manager.
func finish_drag(undo: Object = null) -> void:
	state = State.IDLE

## Reverts the active drag preview back to the pre-drag snapshot state.
func cancel_drag() -> void:
	state = State.IDLE

## Returns true if a drag operation is currently in progress.
func is_dragging() -> bool:
	return state == State.DRAGGING
