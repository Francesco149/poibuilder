## PBToolMove — Interactive Move / Translation viewport tool.
##
## Translates selected mesh elements (vertices, edges, faces) along a camera-facing
## plane passing through the selection centroid in world space.
##
## Follows the snapshot-once preview pattern:
## - On begin_drag: snapshots mesh data into CmdMoveElements and initializes the drag plane.
## - On update_drag: updates CmdMoveElements.delta from ray-plane intersection and calls do_it().
## - On finish_drag: commits the current preview or registers with the undo manager.
## - On cancel_drag: calls CmdMoveElements.undo_it() to revert the preview.
@tool
class_name PBToolMove
extends PBTool

# ==============================================================================
# Internal State
# ==============================================================================

## Active translation command managing snapshot and vertex offset calculation.
var _command: CmdMoveElements = null

## World-space drag plane through selection centroid, facing camera ray at drag start.
var _drag_plane: Plane = Plane()

## Initial intersection point on _drag_plane at the start of the drag.
var _hit_start: Vector3 = Vector3.ZERO

# ==============================================================================
# PBTool Implementation
# ==============================================================================

## Returns the user-facing display name of this tool.
func tool_name() -> String:
	return "Move"

## Begins a translation drag session.
## Constructs CmdMoveElements from the current selection and establishes the drag plane.
func begin_drag(ray_origin: Vector3, ray_dir: Vector3) -> bool:
	if editor == null:
		return false

	if editor.select_mode == PBEditor.SelectMode.OBJECT:
		return false

	if editor.selection == null or editor.selection.is_empty():
		return false

	var mesh_node: PBMesh = editor.active_mesh
	var mesh_data: PBMeshData = null
	if mesh_node != null:
		mesh_data = mesh_node.pb_mesh_data
	if mesh_data == null and editor.selection != null:
		mesh_data = editor.selection.mesh_data

	if mesh_data == null:
		return false

	_command = CmdMoveElements.new()
	_command.logger = logger
	_command.setup_from_selection(mesh_data, editor.selection, editor.select_mode, Vector3.ZERO, mesh_node)

	if _command.indices.is_empty():
		_command = null
		return false

	# Centroid: average of resolved local indices transformed to world space
	var global_xform: Transform3D = mesh_node.global_transform if mesh_node != null else Transform3D.IDENTITY
	var local_centroid: Vector3 = PBMath.average(mesh_data.positions, _command.indices)
	var world_centroid: Vector3 = global_xform * local_centroid

	# Camera-facing drag plane through centroid with normal = -ray_dir.normalized() from BEGIN ray
	var dir_norm: Vector3 = ray_dir.normalized()
	if is_zero_approx(dir_norm.length_squared()):
		_command = null
		return false

	var plane_normal: Vector3 = -dir_norm
	_drag_plane = Plane(plane_normal, world_centroid)

	var hit_var = _drag_plane.intersects_ray(ray_origin, ray_dir)
	if hit_var == null:
		_command = null
		return false

	_hit_start = hit_var
	state = State.DRAGGING

	if logger != null:
		logger.info("tools", "PBToolMove: Drag begun at %s, centroid %s" % [_hit_start, world_centroid])

	return true

## Updates the translation preview from the current raycast.
func update_drag(ray_origin: Vector3, ray_dir: Vector3) -> void:
	if state != State.DRAGGING or _command == null:
		return

	var hit_var = _drag_plane.intersects_ray(ray_origin, ray_dir)
	if hit_var == null:
		# Parallel or miss — ignore update
		return

	var hit_now: Vector3 = hit_var
	var world_delta: Vector3 = hit_now - _hit_start

	var mesh_node: PBMesh = editor.active_mesh if editor != null else null
	var global_xform: Transform3D = mesh_node.global_transform if mesh_node != null else Transform3D.IDENTITY

	var local_delta: Vector3 = Vector3.ZERO
	if not is_zero_approx(global_xform.basis.determinant()):
		local_delta = global_xform.basis.inverse() * world_delta
	else:
		local_delta = world_delta

	_command.delta = local_delta
	_command.do_it()

	if logger != null:
		logger.debug("tools", "PBToolMove: Updated delta %s" % str(local_delta))

## Commits the translation preview.
func finish_drag(undo: Object = null) -> void:
	if state != State.DRAGGING:
		return

	if undo != null and _command != null:
		_command.add_to_undo_manager(undo)

	if logger != null:
		logger.info("tools", "PBToolMove: Drag finished")

	state = State.IDLE

## Cancels the translation drag and restores the pre-drag snapshot.
func cancel_drag() -> void:
	if state != State.DRAGGING:
		return

	if _command != null:
		_command.undo_it()

	if logger != null:
		logger.info("tools", "PBToolMove: Drag cancelled")

	state = State.IDLE

# ==============================================================================
# Queries / Testing Helpers
# ==============================================================================

## Returns the internal active command (useful for testing and inspection).
func get_command() -> CmdMoveElements:
	return _command

## Returns the current drag plane.
func get_drag_plane() -> Plane:
	return _drag_plane

## Returns the drag start hit position.
func get_hit_start() -> Vector3:
	return _hit_start
