## CmdMoveElements — Command to translate mesh elements (vertices/edges/faces) in local space.
##
## Supports vertex, edge, and face selection modes with automatic coincident-vertex
## expansion so welded mesh corners remain welded during translation.
## Implements the snapshot-once undo/redo pattern inherited from PBCommand.
@tool
class_name CmdMoveElements
extends PBCommand

# ==============================================================================
# Properties
# ==============================================================================

## Target mesh data to modify.
var mesh_data: PBMeshData = null

## Optional mesh node wrapper to rebuild after do_it / undo_it.
var mesh_node: PBMesh = null

## Local-space translation offset.
var delta: Vector3 = Vector3.ZERO

## Resolved local vertex indices to translate.
var indices: PackedInt32Array = PackedInt32Array()

## Pre-operation snapshot captured during setup.
var _snapshot: PBMeshData = null

# ==============================================================================
# Lifecycle & Setup
# ==============================================================================

func _init(
	p_mesh_data: PBMeshData = null,
	p_delta: Vector3 = Vector3.ZERO,
	p_mesh_node: PBMesh = null,
	p_logger: PBLogger = null
) -> void:
	command_name = "Move Elements"
	mesh_data = p_mesh_data
	delta = p_delta
	mesh_node = p_mesh_node
	logger = p_logger
	if mesh_data != null:
		_snapshot = PBCommand.copy_mesh_data(mesh_data)

## Sets up the command from explicit local vertex indices.
## When expand_coincident is true, expands every index to include all coincident vertices.
func setup_from_indices(
	p_mesh_data: PBMeshData,
	local_indices: PackedInt32Array,
	p_delta: Vector3,
	expand_coincident: bool = true,
	p_mesh_node: PBMesh = null
) -> void:
	command_name = "Move Elements"
	mesh_data = p_mesh_data
	delta = p_delta
	mesh_node = p_mesh_node

	if mesh_data == null:
		_snapshot = null
		indices = PackedInt32Array()
		return

	_snapshot = PBCommand.copy_mesh_data(mesh_data)

	if local_indices.is_empty():
		indices = PackedInt32Array()
		return

	var seen: Dictionary = {}
	var resolved := PackedInt32Array()

	if expand_coincident:
		for idx in local_indices:
			if idx < 0 or idx >= mesh_data.positions.size():
				continue
			var coin: PackedInt32Array = mesh_data.get_coincident_vertices(idx)
			for cv in coin:
				if not seen.has(cv):
					seen[cv] = true
					resolved.append(cv)
	else:
		for idx in local_indices:
			if idx < 0 or idx >= mesh_data.positions.size():
				continue
			if not seen.has(idx):
				seen[idx] = true
				resolved.append(idx)

	indices = resolved

## Sets up the command from a PBSelection and PBEditor.SelectMode.
## Expands coincident vertices according to the active selection mode.
func setup_from_selection(
	p_mesh_data: PBMeshData,
	selection: PBSelection,
	mode: PBEditor.SelectMode,
	p_delta: Vector3,
	p_mesh_node: PBMesh = null
) -> void:
	command_name = "Move Elements"
	mesh_data = p_mesh_data
	delta = p_delta
	mesh_node = p_mesh_node

	if mesh_data == null:
		_snapshot = null
		indices = PackedInt32Array()
		return

	_snapshot = PBCommand.copy_mesh_data(mesh_data)

	if selection == null:
		indices = PackedInt32Array()
		return

	var raw_indices := PackedInt32Array()

	match mode:
		PBEditor.SelectMode.VERTEX:
			raw_indices = selection.get_selected_vertex_indices()
		PBEditor.SelectMode.EDGE:
			for edge in selection.selected_edges:
				if edge != null:
					raw_indices.append(edge.a)
					raw_indices.append(edge.b)
		PBEditor.SelectMode.FACE:
			for fi in selection.selected_faces:
				if fi >= 0 and fi < mesh_data.faces.size():
					var face: PBFace = mesh_data.faces[fi]
					if face != null:
						raw_indices.append_array(face.get_distinct_indexes())
		PBEditor.SelectMode.OBJECT, _:
			indices = PackedInt32Array()
			return

	if raw_indices.is_empty():
		indices = PackedInt32Array()
		return

	var seen: Dictionary = {}
	var resolved := PackedInt32Array()
	for idx in raw_indices:
		if idx < 0 or idx >= mesh_data.positions.size():
			continue
		var coin: PackedInt32Array = mesh_data.get_coincident_vertices(idx)
		for cv in coin:
			if not seen.has(cv):
				seen[cv] = true
				resolved.append(cv)

	indices = resolved

## Convenience setup delegating to setup_from_indices.
func setup(
	p_mesh_data: PBMeshData,
	p_indices: PackedInt32Array,
	p_delta: Vector3,
	expand_coincident: bool = true,
	p_mesh_node: PBMesh = null
) -> void:
	setup_from_indices(p_mesh_data, p_indices, p_delta, expand_coincident, p_mesh_node)

## Converts a world-space offset to local delta using the inverse basis of global_xform.
func set_world_delta(global_xform: Transform3D, world_delta: Vector3) -> void:
	if not is_zero_approx(global_xform.basis.determinant()):
		delta = global_xform.basis.inverse() * world_delta
	else:
		delta = world_delta

## Returns the internal pre-operation snapshot.
func get_snapshot() -> PBMeshData:
	return _snapshot

# ==============================================================================
# PBCommand Implementation
# ==============================================================================

## Applies translation deterministically from pre-operation snapshot positions.
func do_it() -> void:
	if mesh_data == null or _snapshot == null:
		return

	if indices.is_empty():
		mesh_data.positions = _snapshot.positions.duplicate()
		mesh_data.invalidate_caches()
		if mesh_node != null:
			mesh_node.rebuild()
		if logger != null:
			logger.info("undo", "CmdMoveElements.do_it: 0 vertices moved (empty selection)")
		return

	var new_pos: PackedVector3Array = _snapshot.positions.duplicate()
	var pos_count: int = new_pos.size()
	for idx in indices:
		if idx >= 0 and idx < pos_count:
			new_pos[idx] = _snapshot.positions[idx] + delta

	mesh_data.positions = new_pos
	mesh_data.invalidate_caches()

	if mesh_node != null:
		mesh_node.rebuild()

	if logger != null:
		logger.info("undo", "Moved %d vertices by %s" % [indices.size(), str(delta)])

## Reverts mesh data to pre-operation snapshot.
func undo_it() -> void:
	if mesh_data == null or _snapshot == null:
		return

	PBCommand.restore_mesh_data(mesh_data, _snapshot)

	if mesh_node != null:
		mesh_node.rebuild()

	if logger != null:
		logger.info("undo", "CmdMoveElements.undo_it restored mesh")
