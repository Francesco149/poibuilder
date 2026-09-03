## PBCommand — Base class for all undoable PoiBuilder editing commands.
##
## Mesh editing operations extend PBCommand and implement do_it() and undo_it().
## Commands follow the "snapshot-once" pattern:
## 1. The pre-operation mesh state is snapshotted during command construction / setup.
## 2. do_it() applies modifications deterministically from the snapshot + parameters,
##    ensuring that repeated redo operations produce identical, correct results.
## 3. undo_it() restores the pre-operation snapshot into the target mesh resource.
##
## Integration with Godot's UndoRedo system:
## - add_to_undo_manager() accepts an EditorUndoRedoManager (in editor) or duck-typed
##   undo manager object and registers do_it / undo_it actions.
@tool
class_name PBCommand
extends RefCounted

## Human-readable action name displayed in the editor Undo/Redo history.
var command_name: String = "PoiBuilder Command"

## Optional logger for telemetry and debugging undo operations.
var logger: PBLogger = null

## Applies the command action. Subclasses must override this method.
## Should apply modifications deterministically from the initial snapshot.
func do_it() -> void:
	pass

## Reverts the command action. Subclasses must override this method.
## Should restore the target mesh data to its pre-operation snapshot state.
func undo_it() -> void:
	pass

## Registers this command with Godot's undo manager.
## Parameter is typed as Object to avoid compile-time dependency on EditorUndoRedoManager
## in headless / runtime environments.
func add_to_undo_manager(undo: Object) -> void:
	if undo == null:
		return
	undo.create_action(command_name)
	undo.add_do_method(self, "do_it")
	undo.add_undo_method(self, "undo_it")
	undo.commit_action()

## Creates a deep copy of the given PBMeshData resource.
## All vertex attributes, faces, and shared vertex groups are cloned.
static func copy_mesh_data(source: PBMeshData) -> PBMeshData:
	if source == null:
		return null

	var copy := PBMeshData.new()
	copy.positions = source.positions.duplicate()
	copy.textures0 = source.textures0.duplicate()
	copy.colors = source.colors.duplicate()
	copy.tangents = source.tangents.duplicate()

	var new_faces: Array[PBFace] = []
	for face in source.faces:
		if face != null:
			new_faces.append(face.duplicate_face())
		else:
			new_faces.append(null)
	copy.faces = new_faces

	var new_sv: Array[PBSharedVertex] = []
	for sv in source.shared_vertices:
		if sv != null:
			new_sv.append(sv.duplicate_shared())
		else:
			new_sv.append(null)
	copy.shared_vertices = new_sv

	var new_st: Array[PBSharedVertex] = []
	for st in source.shared_textures:
		if st != null:
			new_st.append(st.duplicate_shared())
		else:
			new_st.append(null)
	copy.shared_textures = new_st

	# Shape bookkeeping travels with snapshots so undo/redo never loses the
	# shape identity / editability of a factory-created mesh.
	copy.shape_id = source.shape_id
	copy.shape_params = source.shape_params.duplicate()
	copy.shape_edited = source.shape_edited

	copy.invalidate_caches()
	return copy

## Deep copies snapshot data back into an existing target PBMeshData resource.
## Keeps object identity of target intact so references (such as PBMesh.pb_mesh_data) remain valid.
static func restore_mesh_data(target: PBMeshData, snapshot: PBMeshData) -> void:
	if target == null or snapshot == null:
		return

	target.positions = snapshot.positions.duplicate()
	target.textures0 = snapshot.textures0.duplicate()
	target.colors = snapshot.colors.duplicate()
	target.tangents = snapshot.tangents.duplicate()

	var new_faces: Array[PBFace] = []
	for face in snapshot.faces:
		if face != null:
			new_faces.append(face.duplicate_face())
		else:
			new_faces.append(null)
	target.faces = new_faces

	var new_sv: Array[PBSharedVertex] = []
	for sv in snapshot.shared_vertices:
		if sv != null:
			new_sv.append(sv.duplicate_shared())
		else:
			new_sv.append(null)
	target.shared_vertices = new_sv

	var new_st: Array[PBSharedVertex] = []
	for st in snapshot.shared_textures:
		if st != null:
			new_st.append(st.duplicate_shared())
		else:
			new_st.append(null)
	target.shared_textures = new_st

	target.shape_id = snapshot.shape_id
	target.shape_params = snapshot.shape_params.duplicate()
	target.shape_edited = snapshot.shape_edited

	target.invalidate_caches()
