## Unit tests for PBCommand base class and EditorUndoRedoManager integration.
extends GutTest

# ==============================================================================
# Helper Test Classes
# ==============================================================================

## Minimal test command that translates all mesh positions by delta.
## Implements the snapshot-once pattern.
class CmdNudgeAll extends PBCommand:
	var _target: PBMeshData
	var _delta: Vector3
	var _snapshot: PBMeshData

	func _init(target: PBMeshData, delta: Vector3, p_logger: PBLogger = null) -> void:
		command_name = "Nudge All"
		_target = target
		_delta = delta
		logger = p_logger
		# Snapshot-once pattern: snapshot captured at creation
		_snapshot = PBCommand.copy_mesh_data(target)

	func do_it() -> void:
		if _target == null or _snapshot == null:
			return
		if logger != null:
			logger.info("undo", "CmdNudgeAll.do_it delta: %s" % str(_delta))
		var new_pos := PackedVector3Array()
		new_pos.resize(_snapshot.positions.size())
		for i in range(_snapshot.positions.size()):
			new_pos[i] = _snapshot.positions[i] + _delta
		_target.positions = new_pos
		_target.invalidate_caches()

	func undo_it() -> void:
		if _target == null or _snapshot == null:
			return
		if logger != null:
			logger.info("undo", "CmdNudgeAll.undo_it")
		PBCommand.restore_mesh_data(_target, _snapshot)

## Duck-typed fake undo manager mirroring EditorUndoRedoManager API.
class FakeUndo extends RefCounted:
	var action_name: String = ""
	var do_object: Object = null
	var do_method: String = ""
	var undo_object: Object = null
	var undo_method: String = ""
	var commit_called: bool = false
	var execute_on_commit: bool = true

	func create_action(name: String, _merge_mode: int = 0) -> void:
		action_name = name

	func add_do_method(object: Object, method: String) -> void:
		do_object = object
		do_method = method

	func add_undo_method(object: Object, method: String) -> void:
		undo_object = object
		undo_method = method

	func commit_action(execute: bool = true) -> void:
		commit_called = true
		if execute and execute_on_commit:
			if do_object != null and do_object.has_method(do_method):
				do_object.call(do_method)

# ==============================================================================
# Tests
# ==============================================================================

## 1. Default PBCommand contract
func test_default_pb_command() -> void:
	var cmd := PBCommand.new()
	assert_eq(cmd.command_name, "ProBuilder Command", "Default command_name should be 'ProBuilder Command'")
	assert_null(cmd.logger, "Default logger should be null")

	# Virtual do_it and undo_it should be callable without error
	cmd.do_it()
	cmd.undo_it()
	assert_true(true, "do_it and undo_it executed as no-ops without error")

## 2. Deep copy of PBMeshData
func test_copy_mesh_data_cube() -> void:
	var source := PBMeshData.create_cube(1.0)
	var copy := PBCommand.copy_mesh_data(source)

	assert_not_null(copy, "copy_mesh_data should return a non-null PBMeshData")
	assert_ne(copy, source, "copy must be a distinct object instance")
	assert_eq(copy.vertex_count(), source.vertex_count(), "Vertex counts must match")
	assert_eq(copy.face_count(), source.face_count(), "Face counts must match")
	assert_eq(copy.positions.size(), source.positions.size(), "Positions count must match")

	for i in range(source.positions.size()):
		assert_true(copy.positions[i].is_equal_approx(source.positions[i]), "Position %d must match" % i)

	# Verify independence of positions
	var original_pos_0: Vector3 = source.positions[0]
	copy.positions[0] = copy.positions[0] + Vector3(10, 20, 30)
	assert_true(source.positions[0].is_equal_approx(original_pos_0), "Mutating copy.positions must not affect source")

	# Verify independence of faces
	assert_ne(copy.faces[0], source.faces[0], "Face instances must be distinct")
	var original_idx_0: int = source.faces[0].get_indexes()[0]
	var copy_indexes: PackedInt32Array = copy.faces[0].get_indexes().duplicate()
	copy_indexes[0] = 999
	copy.faces[0].set_indexes(copy_indexes)
	assert_eq(source.faces[0].get_indexes()[0], original_idx_0, "Mutating copy face indexes must not affect source")

	# Verify independence of shared vertices
	assert_eq(copy.shared_vertices.size(), source.shared_vertices.size(), "Shared vertices count must match")
	if not copy.shared_vertices.is_empty():
		assert_ne(copy.shared_vertices[0], source.shared_vertices[0], "Shared vertex instances must be distinct")
		var original_sv_idx: int = source.shared_vertices[0].indices[0]
		copy.shared_vertices[0].indices[0] = 777
		assert_eq(source.shared_vertices[0].indices[0], original_sv_idx, "Mutating copy shared vertices must not affect source")

func test_copy_mesh_data_null() -> void:
	var copy := PBCommand.copy_mesh_data(null)
	assert_null(copy, "copy_mesh_data(null) should return null")

## 3. Restore mesh data into existing target instance
func test_restore_mesh_data() -> void:
	var target := PBMeshData.create_cube(1.0)
	var snapshot := PBCommand.copy_mesh_data(target)

	# Mutate target positions and face count
	var mutated_positions := PackedVector3Array()
	for p in target.positions:
		mutated_positions.append(p + Vector3(5, 5, 5))
	target.positions = mutated_positions
	target.faces.pop_back() # reduce face count to 5

	assert_ne(target.face_count(), snapshot.face_count(), "Target face count was mutated")
	assert_false(target.positions[0].is_equal_approx(snapshot.positions[0]), "Target positions were mutated")

	# Restore from snapshot
	var target_instance := target
	PBCommand.restore_mesh_data(target, snapshot)

	# Assert target instance identity is preserved
	assert_eq(target, target_instance, "Target object instance must be preserved after restore")
	assert_eq(target.face_count(), snapshot.face_count(), "Face count must match snapshot after restore")
	assert_eq(target.vertex_count(), snapshot.vertex_count(), "Vertex count must match snapshot after restore")

	for i in range(target.positions.size()):
		assert_true(target.positions[i].is_equal_approx(snapshot.positions[i]), "Position %d must match snapshot" % i)

	# Mutating snapshot after restore should not affect target
	snapshot.positions[0] = Vector3(99, 99, 99)
	assert_false(target.positions[0].is_equal_approx(snapshot.positions[0]), "Mutating snapshot must not affect restored target")

func test_restore_mesh_data_null_safety() -> void:
	var target := PBMeshData.create_cube(1.0)
	# Should not crash
	PBCommand.restore_mesh_data(null, target)
	PBCommand.restore_mesh_data(target, null)
	PBCommand.restore_mesh_data(null, null)
	assert_true(true, "restore_mesh_data handled null arguments without error")

## 4. CmdNudgeAll do / undo round-trip and snapshot-once pattern
func test_cmd_nudge_all_round_trip() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var delta := Vector3(1.0, 2.0, 3.0)
	var logger := PBLogger.new()

	var cmd := CmdNudgeAll.new(mesh_data, delta, logger)

	# Initial state: unchanged before do_it
	for i in range(mesh_data.positions.size()):
		assert_true(mesh_data.positions[i].is_equal_approx(original_positions[i]), "Position initially unmodified")

	# 1. Apply do_it
	cmd.do_it()
	for i in range(mesh_data.positions.size()):
		var expected: Vector3 = original_positions[i] + delta
		assert_true(mesh_data.positions[i].is_equal_approx(expected), "Position %d moved by delta after do_it" % i)

	# 2. Apply undo_it
	cmd.undo_it()
	for i in range(mesh_data.positions.size()):
		assert_true(mesh_data.positions[i].is_equal_approx(original_positions[i]), "Position %d restored after undo_it" % i)

	# 3. Snapshot-once verification: calling do_it AGAIN (redo)
	# Must re-apply original+delta, not add delta on top of anything else
	cmd.do_it()
	for i in range(mesh_data.positions.size()):
		var expected: Vector3 = original_positions[i] + delta
		assert_true(mesh_data.positions[i].is_equal_approx(expected), "Position %d moved by delta after second do_it (redo)" % i)

	# 4. Repeated do_it without undo should be idempotent (applying from snapshot)
	cmd.do_it()
	for i in range(mesh_data.positions.size()):
		var expected: Vector3 = original_positions[i] + delta
		assert_true(mesh_data.positions[i].is_equal_approx(expected), "Repeated do_it is idempotent (snapshot-once)")

	# Verify logger entries under "undo" category
	var undo_logs := logger.get_entries_by_category("undo")
	assert_gt(undo_logs.size(), 0, "Logger must have recorded entries in 'undo' category")

## 5. Real Godot core UndoRedo stack integration
func test_real_godot_undo_redo_stack() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var delta := Vector3(0.5, -1.0, 2.0)

	var cmd := CmdNudgeAll.new(mesh_data, delta)

	var ur := UndoRedo.new()
	ur.create_action(cmd.command_name)
	ur.add_do_method(cmd.do_it)
	ur.add_undo_method(cmd.undo_it)
	ur.commit_action()

	# Action executed on commit -> positions moved
	for i in range(mesh_data.positions.size()):
		var expected: Vector3 = original_positions[i] + delta
		assert_true(mesh_data.positions[i].is_equal_approx(expected), "Position %d moved after ur.commit_action()" % i)

	# Undo action -> positions restored
	ur.undo()
	for i in range(mesh_data.positions.size()):
		assert_true(mesh_data.positions[i].is_equal_approx(original_positions[i]), "Position %d restored after ur.undo()" % i)

	# Redo action -> positions moved again
	ur.redo()
	for i in range(mesh_data.positions.size()):
		var expected: Vector3 = original_positions[i] + delta
		assert_true(mesh_data.positions[i].is_equal_approx(expected), "Position %d moved after ur.redo()" % i)

## 6. add_to_undo_manager with FakeUndo duck
func test_add_to_undo_manager_fake_undo() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var delta := Vector3(3.0, 0.0, -2.0)

	var cmd := CmdNudgeAll.new(mesh_data, delta)
	var fake_undo := FakeUndo.new()

	cmd.add_to_undo_manager(fake_undo)

	# Verify registration
	assert_eq(fake_undo.action_name, "Nudge All", "Action name passed to create_action")
	assert_eq(fake_undo.do_object, cmd, "do_object registered")
	assert_eq(fake_undo.do_method, "do_it", "do_method registered as 'do_it'")
	assert_eq(fake_undo.undo_object, cmd, "undo_object registered")
	assert_eq(fake_undo.undo_method, "undo_it", "undo_method registered as 'undo_it'")
	assert_true(fake_undo.commit_called, "commit_action was called")

	# Verify execution on commit
	for i in range(mesh_data.positions.size()):
		var expected: Vector3 = original_positions[i] + delta
		assert_true(mesh_data.positions[i].is_equal_approx(expected), "Position %d moved by fake_undo commit execution" % i)

	# Test undo invocation via registered undo_method
	fake_undo.undo_object.call(fake_undo.undo_method)
	for i in range(mesh_data.positions.size()):
		assert_true(mesh_data.positions[i].is_equal_approx(original_positions[i]), "Position %d restored via fake_undo undo_method" % i)

func test_add_to_undo_manager_null() -> void:
	var cmd := PBCommand.new()
	# Should not crash on null undo manager
	cmd.add_to_undo_manager(null)
	assert_true(true, "add_to_undo_manager(null) safely ignored")
