## CmdRotateElements — Command to rotate mesh elements (vertices/edges/faces) around a local pivot.
##
## Supports vertex, edge, and face selection modes with automatic coincident-vertex
## expansion so welded mesh corners remain welded during rotation.
## Implements the snapshot-once undo/redo pattern inherited from PBCommand.
@tool
class_name CmdRotateElements
extends PBCommand

# ==============================================================================
# Properties
# ==============================================================================

## Target mesh data to modify.
var mesh_data: PBMeshData = null

## Optional mesh node wrapper to rebuild after do_it / undo_it.
var mesh_node: PBMesh = null

## Local-space rotation to apply.
var rotation: Quaternion = Quaternion.IDENTITY

## Local-space pivot point around which rotation is applied.
var pivot: Vector3 = Vector3.ZERO

## When true, automatically computes the pivot as the centroid of resolved vertices from snapshot.
var auto_pivot: bool = true

## Resolved local vertex indices to rotate.
var indices: PackedInt32Array = PackedInt32Array()

## Pre-operation snapshot captured during setup.
var _snapshot: PBMeshData = null

# ==============================================================================
# Lifecycle & Setup
# ==============================================================================

func _init(
	p_mesh_data: PBMeshData = null,
	p_rotation: Quaternion = Quaternion.IDENTITY,
	p_mesh_node: PBMesh = null,
	p_pivot: Vector3 = Vector3.ZERO,
	p_auto_pivot: bool = true,
	p_logger: PBLogger = null
) -> void:
	command_name = "Rotate Elements"
	mesh_data = p_mesh_data
	rotation = p_rotation
	mesh_node = p_mesh_node
	pivot = p_pivot
	auto_pivot = p_auto_pivot
	logger = p_logger
	if mesh_data != null:
		_snapshot = PBCommand.copy_mesh_data(mesh_data)

## Sets up the command from explicit local vertex indices.
## When expand_coincident is true, expands every index to include all coincident vertices.
func setup_from_indices(
	p_mesh_data: PBMeshData,
	local_indices: PackedInt32Array,
	p_rotation: Quaternion,
	expand_coincident: bool = true,
	p_mesh_node: PBMesh = null,
	p_pivot: Vector3 = Vector3.ZERO,
	p_auto_pivot: bool = true
) -> void:
	command_name = "Rotate Elements"
	mesh_data = p_mesh_data
	rotation = p_rotation
	mesh_node = p_mesh_node
	pivot = p_pivot
	auto_pivot = p_auto_pivot

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
	p_rotation: Quaternion,
	p_mesh_node: PBMesh = null,
	p_pivot: Vector3 = Vector3.ZERO,
	p_auto_pivot: bool = true
) -> void:
	command_name = "Rotate Elements"
	mesh_data = p_mesh_data
	rotation = p_rotation
	mesh_node = p_mesh_node
	pivot = p_pivot
	auto_pivot = p_auto_pivot

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
	p_rotation: Quaternion,
	expand_coincident: bool = true,
	p_mesh_node: PBMesh = null,
	p_pivot: Vector3 = Vector3.ZERO,
	p_auto_pivot: bool = true
) -> void:
	setup_from_indices(p_mesh_data, p_indices, p_rotation, expand_coincident, p_mesh_node, p_pivot, p_auto_pivot)

## Sets rotation from a 3x3 orientation Basis.
func set_rotation_basis(b: Basis) -> void:
	rotation = b.get_rotation_quaternion()

## Returns the internal pre-operation snapshot.
func get_snapshot() -> PBMeshData:
	return _snapshot

# ==============================================================================
# PBCommand Implementation
# ==============================================================================

## Applies rotation deterministically from pre-operation snapshot positions around pivot.
func do_it() -> void:
	if mesh_data == null or _snapshot == null:
		return

	if indices.is_empty():
		mesh_data.positions = _snapshot.positions.duplicate()
		mesh_data.invalidate_caches()
		if mesh_node != null:
			mesh_node.rebuild()
		if logger != null:
			logger.info("undo", "CmdRotateElements.do_it: 0 vertices rotated (empty selection)")
		return

	var new_pos: PackedVector3Array = _snapshot.positions.duplicate()
	var p: Vector3 = PBMath.average(_snapshot.positions, indices) if auto_pivot else pivot
	var pos_count: int = new_pos.size()

	for idx in indices:
		if idx >= 0 and idx < pos_count:
			var v: Vector3 = _snapshot.positions[idx]
			new_pos[idx] = p + rotation * (v - p)

	mesh_data.positions = new_pos
	mesh_data.invalidate_caches()

	if mesh_node != null:
		mesh_node.rebuild()

	if logger != null:
		logger.info("undo", "Rotated %d vertices by %s around pivot %s" % [indices.size(), str(rotation), str(p)])

## Reverts mesh data to pre-operation snapshot.
func undo_it() -> void:
	if mesh_data == null or _snapshot == null:
		return

	PBCommand.restore_mesh_data(mesh_data, _snapshot)

	if mesh_node != null:
		mesh_node.rebuild()

	if logger != null:
		logger.info("undo", "CmdRotateElements.undo_it restored mesh")
