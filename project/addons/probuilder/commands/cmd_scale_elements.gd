## CmdScaleElements — Command to scale mesh elements (vertices/edges/faces) in local space.
##
## Supports vertex, edge, and face selection modes with automatic coincident-vertex
## expansion so welded mesh corners remain welded during scaling.
## Implements the snapshot-once undo/redo pattern inherited from PBCommand.
@tool
class_name CmdScaleElements
extends PBCommand

# ==============================================================================
# Constants
# ==============================================================================

## Minimum scale component magnitude to avoid zero/singular collapse.
const MIN_SCALE: float = 0.0001

# ==============================================================================
# Properties
# ==============================================================================

## Target mesh data to modify.
var mesh_data: PBMeshData = null

## Optional mesh node wrapper to rebuild after do_it / undo_it.
var mesh_node: PBMesh = null

## Local-space scale factor (Vector3.ONE = no-op). Component-wise around pivot.
var scale: Vector3 = Vector3.ONE

## Local-space pivot point around which scaling occurs when _pivot_auto is false.
var pivot: Vector3 = Vector3.ZERO

## Whether pivot is computed automatically from selection centroid.
var _pivot_auto: bool = true

## Resolved local vertex indices to scale.
var indices: PackedInt32Array = PackedInt32Array()

## Pre-operation snapshot captured during setup.
var _snapshot: PBMeshData = null

# ==============================================================================
# Helper Methods
# ==============================================================================

## Clamps a scale component magnitude to MIN_SCALE while preserving its sign.
static func clamp_component(val: float) -> float:
	if absf(val) < MIN_SCALE:
		return -MIN_SCALE if val < 0.0 else MIN_SCALE
	return val

# ==============================================================================
# Lifecycle & Setup
# ==============================================================================

func _init(
	p_mesh_data: PBMeshData = null,
	p_scale: Vector3 = Vector3.ONE,
	p_mesh_node: PBMesh = null,
	p_logger: PBLogger = null,
	p_pivot: Vector3 = Vector3.ZERO,
	p_auto_pivot: bool = true
) -> void:
	command_name = "Scale Elements"
	mesh_data = p_mesh_data
	scale = p_scale
	mesh_node = p_mesh_node
	logger = p_logger
	pivot = p_pivot
	_pivot_auto = p_auto_pivot
	if mesh_data != null:
		_snapshot = PBCommand.copy_mesh_data(mesh_data)

## Sets up the command from explicit local vertex indices.
## When expand_coincident is true, expands every index to include all coincident vertices.
func setup_from_indices(
	p_mesh_data: PBMeshData,
	local_indices: PackedInt32Array,
	p_scale: Vector3 = Vector3.ONE,
	expand_coincident: bool = true,
	p_mesh_node: PBMesh = null,
	p_pivot: Vector3 = Vector3.ZERO,
	auto_pivot: bool = true
) -> void:
	command_name = "Scale Elements"
	mesh_data = p_mesh_data
	scale = p_scale
	mesh_node = p_mesh_node
	pivot = p_pivot
	_pivot_auto = auto_pivot

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
	p_scale: Vector3 = Vector3.ONE,
	p_mesh_node: PBMesh = null,
	p_pivot: Vector3 = Vector3.ZERO,
	auto_pivot: bool = true
) -> void:
	command_name = "Scale Elements"
	mesh_data = p_mesh_data
	scale = p_scale
	mesh_node = p_mesh_node
	pivot = p_pivot
	_pivot_auto = auto_pivot

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
	p_scale: Vector3 = Vector3.ONE,
	expand_coincident: bool = true,
	p_mesh_node: PBMesh = null,
	p_pivot: Vector3 = Vector3.ZERO,
	auto_pivot: bool = true
) -> void:
	setup_from_indices(p_mesh_data, p_indices, p_scale, expand_coincident, p_mesh_node, p_pivot, auto_pivot)

## Returns the internal pre-operation snapshot.
func get_snapshot() -> PBMeshData:
	return _snapshot

# ==============================================================================
# PBCommand Implementation
# ==============================================================================

## Applies scaling deterministically from pre-operation snapshot positions.
func do_it() -> void:
	if mesh_data == null or _snapshot == null:
		return

	if indices.is_empty():
		mesh_data.positions = _snapshot.positions.duplicate()
		mesh_data.invalidate_caches()
		if mesh_node != null:
			mesh_node.rebuild()
		if logger != null:
			logger.info("undo", "CmdScaleElements.do_it: 0 vertices scaled (empty selection)")
		return

	var s := Vector3(
		clamp_component(scale.x),
		clamp_component(scale.y),
		clamp_component(scale.z)
	)
	var new_pos: PackedVector3Array = _snapshot.positions.duplicate()
	var p: Vector3 = PBMath.average(_snapshot.positions, indices) if _pivot_auto else pivot
	var pos_count: int = new_pos.size()

	for idx in indices:
		if idx >= 0 and idx < pos_count:
			var v: Vector3 = _snapshot.positions[idx]
			var d: Vector3 = v - p
			new_pos[idx] = p + Vector3(d.x * s.x, d.y * s.y, d.z * s.z)

	mesh_data.positions = new_pos
	mesh_data.invalidate_caches()

	if mesh_node != null:
		mesh_node.rebuild()

	if logger != null:
		logger.info("undo", "Scaled %d vertices by %s about pivot %s" % [indices.size(), str(s), str(p)])

## Reverts mesh data to pre-operation snapshot.
func undo_it() -> void:
	if mesh_data == null or _snapshot == null:
		return

	PBCommand.restore_mesh_data(mesh_data, _snapshot)

	if mesh_node != null:
		mesh_node.rebuild()

	if logger != null:
		logger.info("undo", "CmdScaleElements.undo_it restored mesh")
