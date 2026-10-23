## CmdMeshOp — Undoable command for whole-mesh topology operations
## (extrude / inset / subdivide / delete / detach, see PBMeshOps).
##
## Mesh ops rewrite face topology, so per-index payloads (CmdMoveElements
## style) don't apply — this command deep-copies the ENTIRE PBMeshData before
## the op and captures it again afterwards; undo/redo swap the snapshots.
## PoiBuilder meshes are small (hundreds of faces), so full snapshots are the
## robust choice; revisit if large meshes become a use case.
@tool
class_name CmdMeshOp
extends PBCommand

## The PBMeshData being mutated (kept by identity — restore_mesh_data writes
## into it in place so node references stay valid).
var target_mesh: PBMeshData = null

## The node rendering target_mesh. do_it/undo_it MUST rebuild it: restoring
## the PBMeshData alone leaves the previously compiled ArrayMesh on screen
## (the "undo doesn't visually un-extrude until I move something" bug).
var node: PBMesh = null

## Deep copies taken around the operation.
var before: PBMeshData = null
var after: PBMeshData = null

func _init(p_mesh: PBMeshData = null, p_name: String = "Mesh Operation",
		p_node: PBMesh = null) -> void:
	target_mesh = p_mesh
	node = p_node
	command_name = p_name
	if target_mesh != null:
		before = PBCommand.copy_mesh_data(target_mesh)
		_paint_sources = PBSplat.capture_paint_sources(target_mesh)

## Pre-op paint bookkeeping (empty for a mesh without paint): the faces the op
## creates inherit or drop their source face's paint in capture_after.
var _paint_sources: Dictionary = {}

## Call AFTER mutating target_mesh to capture the redo state.
func capture_after() -> void:
	if target_mesh != null:
		# Before the snapshot, so redo restores the settled state.
		settle_paint()
		_release_paint_sources()
		after = PBCommand.copy_mesh_data(target_mesh)

## Settles the paint of the faces the op created (PBSplat.settle_derived_faces).
## capture_after does this; call it directly when the op's result is shown
## before the command is captured (the bevel modal's first preview).
func settle_paint() -> void:
	if target_mesh != null:
		PBSplat.settle_derived_faces(target_mesh, _paint_sources)

## Called by capture_after once the op is settled: the sources hold the
## pre-op faces and LIVE splat materials, and a command lives as long as its
## undo step — keeping them would pin those materials' GPU textures there.
func _release_paint_sources() -> void:
	_paint_sources = {}

func _apply_snapshot(snapshot: PBMeshData) -> void:
	if target_mesh == null or snapshot == null:
		return
	PBCommand.restore_mesh_data(target_mesh, snapshot)
	if node != null and is_instance_valid(node):
		node.pb_mesh_data.invalidate_caches()
		node.rebuild()
		node.update_gizmos()
	if logger != null:
		logger.info("mesh_ops", "%s applied: V=%d F=%d (render rebuilt)" % [
			command_name, target_mesh.positions.size(), target_mesh.faces.size()])

func do_it() -> void:
	_apply_snapshot(after)

func undo_it() -> void:
	_apply_snapshot(before)


func add_to_undo_manager(undo: Object) -> void:
	if undo == null:
		return
	if undo is UndoRedo:
		undo.create_action(command_name)
		undo.add_do_method(Callable(self, "do_it"))
		undo.add_undo_method(Callable(self, "undo_it"))
		undo.commit_action()
		return
	if undo is EditorUndoRedoManager and node != null and is_instance_valid(node):
		undo.create_action(command_name, UndoRedo.MERGE_DISABLE, node)
	else:
		undo.create_action(command_name)
	undo.add_do_method(self, "do_it")
	undo.add_undo_method(self, "undo_it")
	undo.commit_action()
## True when the op produced no change worth an undo entry.
func is_noop() -> bool:
	return before == null or after == null
