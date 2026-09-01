## Unit tests for CmdMoveElements.
## Tests element translation (vertex/edge/face), coincident vertex welding,
## world-space delta conversion, PBMesh rebuild, and UndoRedo integration.
extends GutTest

# ==============================================================================
# Helper Test Classes
# ==============================================================================

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

## 1. Move face 0 by Vector3(0, 0, -1) via setup_from_selection in FACE mode
func test_move_face_0_selection() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var selection := PBSelection.new(mesh_data)
	selection.add_face(0)

	var delta := Vector3(0.0, 0.0, -1.0)
	var cmd := CmdMoveElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.FACE, delta)

	# Face 0 has 4 corners -> 12 coincident vertices
	assert_eq(cmd.indices.size(), 12, "Moving Face 0 must resolve to exactly 12 coincident vertices")

	cmd.do_it()

	# Face 0 distinct local vertices are 0, 1, 2, 3
	# Calculate centroid before and after
	var orig_centroid := (original_positions[0] + original_positions[1] + original_positions[2] + original_positions[3]) / 4.0
	var new_centroid := (mesh_data.positions[0] + mesh_data.positions[1] + mesh_data.positions[2] + mesh_data.positions[3]) / 4.0
	assert_true(new_centroid.is_equal_approx(orig_centroid + delta), "Face 0 centroid must move by delta")

	# Coincident vertices of Face 0 corners:
	# Group 1 (corner +h,-h,-h): [0, 13, 22]
	# Group 0 (corner -h,-h,-h): [1, 8, 21]
	# Group 2 (corner -h,+h,-h): [2, 11, 16]
	# Group 3 (corner +h,+h,-h): [3, 14, 19]
	var moved_indices := [0, 13, 22, 1, 8, 21, 2, 11, 16, 3, 14, 19]
	for idx in moved_indices:
		var expected: Vector3 = original_positions[idx] + delta
		assert_true(mesh_data.positions[idx].is_equal_approx(expected), "Face 0 coincident vertex %d must move by delta" % idx)

	# Face 1 (Back face, Z = +0.5) distinct local vertices 4, 5, 6, 7 must be UNCHANGED
	for idx in [4, 5, 6, 7]:
		assert_true(mesh_data.positions[idx].is_equal_approx(original_positions[idx]), "Face 1 vertex %d must remain unchanged" % idx)

## 2. Undo restores every position; redo do_it() reapplies original + delta (snapshot-once)
func test_undo_and_redo_idempotent() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var selection := PBSelection.new(mesh_data)
	selection.add_face(0)

	var delta := Vector3(0.0, 0.0, -1.0)
	var cmd := CmdMoveElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.FACE, delta)

	# 1. do_it
	cmd.do_it()
	for idx in cmd.indices:
		assert_true(mesh_data.positions[idx].is_equal_approx(original_positions[idx] + delta), "Vertex %d moved after do_it" % idx)

	# 2. undo_it
	cmd.undo_it()
	for i in range(mesh_data.positions.size()):
		assert_true(mesh_data.positions[i].is_equal_approx(original_positions[i]), "Vertex %d restored after undo_it" % i)

	# 3. redo (do_it called again)
	cmd.do_it()
	for idx in cmd.indices:
		assert_true(mesh_data.positions[idx].is_equal_approx(original_positions[idx] + delta), "Vertex %d moved after redo" % idx)

	# 4. repeated do_it without undo must be idempotent (not stack delta)
	cmd.do_it()
	for idx in cmd.indices:
		assert_true(mesh_data.positions[idx].is_equal_approx(original_positions[idx] + delta), "Repeated do_it is idempotent (snapshot-once)")

## 3. Move one common vertex in VERTEX mode: all 3 locals in that group move; other groups stay
func test_move_one_common_vertex() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var selection := PBSelection.new(mesh_data)
	# Common index 0 -> corner (-h, -h, -h) -> Group 0 [1, 8, 21]
	selection.add_vertex(0)

	var delta := Vector3(-2.0, -1.0, 0.5)
	var cmd := CmdMoveElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.VERTEX, delta)

	assert_eq(cmd.indices.size(), 3, "Common vertex 0 should resolve to 3 coincident vertices")

	cmd.do_it()

	# Vertices 1, 8, 21 must be moved
	for idx in [1, 8, 21]:
		assert_true(mesh_data.positions[idx].is_equal_approx(original_positions[idx] + delta), "Coincident vertex %d in Group 0 must move" % idx)

	# All other vertices must remain unchanged
	for i in range(mesh_data.positions.size()):
		if not [1, 8, 21].has(i):
			assert_true(mesh_data.positions[i].is_equal_approx(original_positions[i]), "Unselected vertex %d must remain unchanged" % i)

## 4. Move one edge of face 0: both endpoint corners' coincident verts move (6 locals); others stay
func test_move_one_edge() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var selection := PBSelection.new(mesh_data)
	# Face 0 edge between local 0 (Group 1 [0, 13, 22]) and local 1 (Group 0 [1, 8, 21])
	selection.add_edge(PBEdge.new(0, 1))

	var delta := Vector3(0.0, -2.0, 0.0)
	var cmd := CmdMoveElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.EDGE, delta)

	assert_eq(cmd.indices.size(), 6, "Edge selection should expand to 6 coincident vertices (2 corners * 3)")

	cmd.do_it()

	var edge_moved_indices := [0, 13, 22, 1, 8, 21]
	for idx in edge_moved_indices:
		assert_true(mesh_data.positions[idx].is_equal_approx(original_positions[idx] + delta), "Edge endpoint vertex %d must move" % idx)

	# Other two Face 0 corners: Group 2 [2, 11, 16] and Group 3 [3, 14, 19] must stay
	for idx in [2, 11, 16, 3, 14, 19]:
		assert_true(mesh_data.positions[idx].is_equal_approx(original_positions[idx]), "Other Face 0 corner vertex %d must not move" % idx)

## 5. Move all vertices (select all in VERTEX mode): entire cube translates; AABB shifts
func test_move_all_vertices() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var selection := PBSelection.new(mesh_data)
	selection.select_all(PBEditor.SelectMode.VERTEX)

	var delta := Vector3(3.0, 4.0, 5.0)
	var cmd := CmdMoveElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.VERTEX, delta)

	assert_eq(cmd.indices.size(), 24, "Select all must resolve to all 24 vertices")

	cmd.do_it()

	var aabb_orig := AABB(Vector3(-0.5, -0.5, -0.5), Vector3(1.0, 1.0, 1.0))
	var aabb_expected := AABB(aabb_orig.position + delta, aabb_orig.size)

	var aabb_actual := AABB(mesh_data.positions[0], Vector3.ZERO)
	for p in mesh_data.positions:
		aabb_actual = aabb_actual.expand(p)

	assert_true(aabb_actual.position.is_equal_approx(aabb_expected.position), "AABB min position should translate by delta")
	assert_true(aabb_actual.size.is_equal_approx(aabb_expected.size), "AABB size should remain unchanged")

## 6. Empty selection: do_it does not change positions
func test_empty_selection() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var selection := PBSelection.new(mesh_data) # Empty

	var delta := Vector3(1.0, 2.0, 3.0)
	var cmd := CmdMoveElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.FACE, delta)

	assert_eq(cmd.indices.size(), 0, "Empty selection must yield 0 indices")

	cmd.do_it()

	for i in range(mesh_data.positions.size()):
		assert_true(mesh_data.positions[i].is_equal_approx(original_positions[i]), "Position %d must not change on empty selection" % i)

## 7. World delta with 90 deg Y rotation
func test_world_delta_rotation() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var selection := PBSelection.new(mesh_data)
	selection.add_face(0)

	var cmd := CmdMoveElements.new()
	# Rotate 90 degrees around Y axis
	var xform := Transform3D(Basis(Vector3.UP, deg_to_rad(90.0)), Vector3(5, 0, 0))
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.FACE, Vector3.ZERO)
	cmd.set_world_delta(xform, Vector3(2.0, 0.0, 0.0))

	# World +X transformed by inverse 90 deg Y rotation should produce local +Z:
	# basis rotated by +90 deg around Y has inverse rotation -90 deg around Y
	var expected_local_delta: Vector3 = xform.basis.inverse() * Vector3(2.0, 0.0, 0.0)
	assert_true(cmd.delta.is_equal_approx(expected_local_delta), "Local delta must equal basis.inverse() * world_delta")

	cmd.do_it()
	# Face 0 centroid should have moved by expected_local_delta
	var orig_snap: PBMeshData = cmd.get_snapshot()
	var orig_c: Vector3 = (orig_snap.positions[0] + orig_snap.positions[1] + orig_snap.positions[2] + orig_snap.positions[3]) / 4.0
	var new_c: Vector3 = (mesh_data.positions[0] + mesh_data.positions[1] + mesh_data.positions[2] + mesh_data.positions[3]) / 4.0
	assert_true(new_c.is_equal_approx(orig_c + expected_local_delta), "Centroid must move by transformed local delta")

## 8. PBMesh rebuild: mesh_node.mesh is ArrayMesh with vertex matching moved position
func test_pb_mesh_rebuild() -> void:
	var mesh_node := PBMesh.create_cube(1.0)
	autofree(mesh_node)
	mesh_node.rebuild()
	var initial_array_mesh: ArrayMesh = mesh_node.mesh as ArrayMesh
	assert_not_null(initial_array_mesh, "PBMesh must have an initial ArrayMesh")

	var selection := PBSelection.new(mesh_node.pb_mesh_data)
	selection.add_face(0)

	var delta := Vector3(0.0, 0.0, -1.5)
	var cmd := CmdMoveElements.new()
	cmd.setup_from_selection(mesh_node.pb_mesh_data, selection, PBEditor.SelectMode.FACE, delta, mesh_node)

	cmd.do_it()

	var rebuilt_mesh: ArrayMesh = mesh_node.mesh as ArrayMesh
	assert_not_null(rebuilt_mesh, "PBMesh.mesh should be non-null after rebuild")
	assert_gt(rebuilt_mesh.get_surface_count(), 0, "ArrayMesh should have at least 1 surface")

	var surf_arrays := rebuilt_mesh.surface_get_arrays(0)
	var surf_verts: PackedVector3Array = surf_arrays[Mesh.ARRAY_VERTEX]
	assert_true(surf_verts[0].is_equal_approx(mesh_node.pb_mesh_data.positions[0]), "Rebuilt surface vertex 0 must match mesh_data position")

	# Undo rebuild
	cmd.undo_it()
	var undone_arrays := (mesh_node.mesh as ArrayMesh).surface_get_arrays(0)
	var undone_verts: PackedVector3Array = undone_arrays[Mesh.ARRAY_VERTEX]
	assert_true(undone_verts[0].is_equal_approx(cmd.get_snapshot().positions[0]), "Undone surface vertex 0 must match snapshot")

## 9. UndoRedo stack integration
func test_undo_redo_stack_integration() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_pos_0: Vector3 = mesh_data.positions[0]
	var selection := PBSelection.new(mesh_data)
	selection.add_face(0)

	var delta := Vector3(1.0, 2.0, 3.0)
	var cmd := CmdMoveElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.FACE, delta)

	var ur := UndoRedo.new()
	ur.create_action(cmd.command_name)
	ur.add_do_method(cmd.do_it)
	ur.add_undo_method(cmd.undo_it)
	ur.commit_action()

	# After commit
	assert_true(mesh_data.positions[0].is_equal_approx(original_pos_0 + delta), "Vertex 0 moved after commit")

	# After undo
	ur.undo()
	assert_true(mesh_data.positions[0].is_equal_approx(original_pos_0), "Vertex 0 restored after ur.undo()")

	# After redo
	ur.redo()
	assert_true(mesh_data.positions[0].is_equal_approx(original_pos_0 + delta), "Vertex 0 moved again after ur.redo()")

## 10. Coincident welding: all locals in each moved shared group share the same position
func test_coincident_welding_maintained() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var selection := PBSelection.new(mesh_data)
	selection.add_face(0)

	var delta := Vector3(0.5, -0.5, -1.0)
	var cmd := CmdMoveElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.FACE, delta)

	cmd.do_it()

	# Check the 4 moved corner groups:
	# Group 0: [1, 8, 21]
	# Group 1: [0, 13, 22]
	# Group 2: [2, 11, 16]
	# Group 3: [3, 14, 19]
	var groups_to_check := [
		[1, 8, 21],
		[0, 13, 22],
		[2, 11, 16],
		[3, 14, 19],
	]

	for group in groups_to_check:
		var p0: Vector3 = mesh_data.positions[group[0]]
		var p1: Vector3 = mesh_data.positions[group[1]]
		var p2: Vector3 = mesh_data.positions[group[2]]
		assert_true(p0.is_equal_approx(p1), "Coincident vertices %d and %d must share position" % [group[0], group[1]])
		assert_true(p1.is_equal_approx(p2), "Coincident vertices %d and %d must share position" % [group[1], group[2]])

## 11. setup_from_indices with expand_coincident = false vs true
func test_setup_from_indices_expand_flag() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var cmd_unshared := CmdMoveElements.new()
	# Only local index 0 without expansion
	cmd_unshared.setup_from_indices(mesh_data, PackedInt32Array([0]), Vector3(1, 0, 0), false)
	assert_eq(cmd_unshared.indices.size(), 1, "Without expansion, exactly 1 index should be stored")
	assert_eq(cmd_unshared.indices[0], 0, "Index must be 0")

	var cmd_shared := CmdMoveElements.new()
	# Local index 0 with expansion (group 1 [0, 13, 22])
	cmd_shared.setup_from_indices(mesh_data, PackedInt32Array([0]), Vector3(1, 0, 0), true)
	assert_eq(cmd_shared.indices.size(), 3, "With expansion, all 3 coincident vertices should be stored")

## 12. Object mode in setup_from_selection yields empty indices
func test_object_mode_selection() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var selection := PBSelection.new(mesh_data)
	selection.add_face(0)

	var cmd := CmdMoveElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.OBJECT, Vector3(1, 2, 3))
	assert_eq(cmd.indices.size(), 0, "OBJECT mode should not resolve indices")

## 13. Null safety checks
func test_null_safety() -> void:
	var cmd := CmdMoveElements.new()
	# Setup with null mesh_data
	cmd.setup_from_indices(null, PackedInt32Array([0, 1]), Vector3.ONE)
	assert_eq(cmd.indices.size(), 0, "Null mesh data yields empty indices")
	# do_it and undo_it on uninitialized command
	cmd.do_it()
	cmd.undo_it()

	# setup_from_selection with null selection
	var mesh_data := PBMeshData.create_cube(1.0)
	cmd.setup_from_selection(mesh_data, null, PBEditor.SelectMode.FACE, Vector3.ONE)
	assert_eq(cmd.indices.size(), 0, "Null selection yields empty indices")

	# add_to_undo_manager with null
	cmd.add_to_undo_manager(null)
	assert_true(true, "Null safety tests executed successfully")

## 14. FakeUndo and Logger integration
func test_fake_undo_and_logger() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_pos_0: Vector3 = mesh_data.positions[0]
	var selection := PBSelection.new(mesh_data)
	selection.add_face(0)

	var logger := PBLogger.new()
	var delta := Vector3(0.0, 1.0, 0.0)
	var cmd := CmdMoveElements.new(mesh_data, delta, null, logger)
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.FACE, delta)
	cmd.logger = logger

	var fake_undo := FakeUndo.new()
	cmd.add_to_undo_manager(fake_undo)

	assert_eq(fake_undo.action_name, "Move Elements", "Action name registered as 'Move Elements'")
	assert_true(fake_undo.commit_called, "commit_action was called")
	assert_true(mesh_data.positions[0].is_equal_approx(original_pos_0 + delta), "Vertex 0 moved by fake_undo commit")

	# Check logger recorded undo entries
	var undo_entries := logger.get_entries_by_category("undo")
	assert_gt(undo_entries.size(), 0, "Logger must have entries under 'undo' category")

	# Undo via fake_undo
	fake_undo.undo_object.call(fake_undo.undo_method)
	assert_true(mesh_data.positions[0].is_equal_approx(original_pos_0), "Vertex 0 restored via fake_undo undo")
