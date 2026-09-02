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

## Deep copies taken around the operation.
var before: PBMeshData = null
var after: PBMeshData = null

func _init(p_mesh: PBMeshData = null, p_name: String = "Mesh Operation") -> void:
	target_mesh = p_mesh
	command_name = p_name
	if target_mesh != null:
		before = PBCommand.copy_mesh_data(target_mesh)

## Call AFTER mutating target_mesh to capture the redo state.
func capture_after() -> void:
	if target_mesh != null:
		after = PBCommand.copy_mesh_data(target_mesh)

func do_it() -> void:
	PBCommand.restore_mesh_data(target_mesh, after)

func undo_it() -> void:
	PBCommand.restore_mesh_data(target_mesh, before)

## True when the op produced no change worth an undo entry.
func is_noop() -> bool:
	return before == null or after == null
