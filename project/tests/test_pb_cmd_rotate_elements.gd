## Unit tests for CmdRotateElements.
## Tests element rotation (vertex/edge/face), coincident vertex welding,
## auto vs custom pivot calculations, PBMesh rebuild, and UndoRedo integration.
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

## 1. Rotate face 0 by 90° around Y through auto centroid
func test_rotate_face_0_auto_centroid() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var selection := PBSelection.new(mesh_data)
	selection.add_face(0)

	var rot := Quaternion(Vector3.UP, PI / 2.0)
	var cmd := CmdRotateElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.FACE, rot)

	# Face 0 has 4 corners -> 12 coincident vertices
	assert_eq(cmd.indices.size(), 12, "Rotating Face 0 must resolve to exactly 12 coincident vertices")

	# Calculate pre-rotation centroid of Face 0 (verts 0, 1, 2, 3) -> (0, 0, -0.5)
	var orig_centroid := (original_positions[0] + original_positions[1] + original_positions[2] + original_positions[3]) / 4.0
	assert_true(orig_centroid.is_equal_approx(Vector3(0.0, 0.0, -0.5)), "Original Face 0 centroid must be (0, 0, -0.5)")

	cmd.do_it()

	# Face 0 centroid after rotation around auto centroid MUST BE UNCHANGED
	var new_centroid := (mesh_data.positions[0] + mesh_data.positions[1] + mesh_data.positions[2] + mesh_data.positions[3]) / 4.0
	assert_true(new_centroid.is_equal_approx(orig_centroid), "Face 0 centroid must remain unchanged after rotation around its centroid")

	# Check each moved vertex: distance to pivot must match pre-rotation distance
	for idx in cmd.indices:
		var dist_orig: float = original_positions[idx].distance_to(orig_centroid)
		var dist_new: float = mesh_data.positions[idx].distance_to(orig_centroid)
		assert_true(is_equal_approx(dist_orig, dist_new), "Distance from vertex %d to pivot must be preserved" % idx)

		var expected_pos: Vector3 = orig_centroid + rot * (original_positions[idx] - orig_centroid)
		assert_true(mesh_data.positions[idx].is_equal_approx(expected_pos), "Vertex %d position must match rotated position" % idx)

	# Face 1 (Back face, Z = +0.5) distinct local vertices 4, 5, 6, 7 must be UNCHANGED
	for idx in [4, 5, 6, 7]:
		assert_true(mesh_data.positions[idx].is_equal_approx(original_positions[idx]), "Face 1 vertex %d must remain unchanged" % idx)

## 2. Undo restores every position; redo do_it() reapplies rotation (snapshot-once, not stacked)
func test_undo_and_redo_idempotent() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var selection := PBSelection.new(mesh_data)
	selection.add_face(0)

	var rot := Quaternion(Vector3.UP, PI / 2.0)
	var cmd := CmdRotateElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.FACE, rot)

	# 1. do_it
	cmd.do_it()
	var orig_centroid := (original_positions[0] + original_positions[1] + original_positions[2] + original_positions[3]) / 4.0
	for idx in cmd.indices:
		var expected: Vector3 = orig_centroid + rot * (original_positions[idx] - orig_centroid)
		assert_true(mesh_data.positions[idx].is_equal_approx(expected), "Vertex %d rotated after do_it" % idx)

	# 2. undo_it
	cmd.undo_it()
	for i in range(mesh_data.positions.size()):
		assert_true(mesh_data.positions[i].is_equal_approx(original_positions[i]), "Vertex %d restored after undo_it" % i)

	# 3. redo (do_it called again)
	cmd.do_it()
	for idx in cmd.indices:
		var expected: Vector3 = orig_centroid + rot * (original_positions[idx] - orig_centroid)
		assert_true(mesh_data.positions[idx].is_equal_approx(expected), "Vertex %d rotated after redo" % idx)

	# 4. repeated do_it without undo must be idempotent (snapshot-once, not 180 degrees)
	cmd.do_it()
	for idx in cmd.indices:
		var expected: Vector3 = orig_centroid + rot * (original_positions[idx] - orig_centroid)
		assert_true(mesh_data.positions[idx].is_equal_approx(expected), "Repeated do_it is idempotent (snapshot-once)")

## 3. Rotate one common vertex group 90° around Y with custom pivot: all 3 coincident locals share the same post position
func test_rotate_one_common_vertex_welding() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var selection := PBSelection.new(mesh_data)
	# Common index 0 -> corner (-h, -h, -h) -> Group 0 [1, 8, 21]
	selection.add_vertex(0)

	var rot := Quaternion(Vector3.UP, PI / 2.0)
	var cmd := CmdRotateElements.new()
	# Rotate around origin (0, 0, 0)
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.VERTEX, rot, null, Vector3.ZERO, false)

	assert_eq(cmd.indices.size(), 3, "Common vertex 0 should resolve to 3 coincident vertices")

	cmd.do_it()

	# Coincident vertices 1, 8, 21 in Group 0 must all move to the same new position
	var p1: Vector3 = mesh_data.positions[1]
	var p8: Vector3 = mesh_data.positions[8]
	var p21: Vector3 = mesh_data.positions[21]
	assert_true(p1.is_equal_approx(p8), "Coincident vertex 1 and 8 must have identical positions")
	assert_true(p8.is_equal_approx(p21), "Coincident vertex 8 and 21 must have identical positions")

	# Expected position rotated around origin (0,0,0) by 90 deg around Y:
	# (-0.5, -0.5, -0.5) rotated 90 deg around Y -> (-0.5, -0.5, 0.5)
	var expected := rot * original_positions[1]
	assert_true(p1.is_equal_approx(expected), "Rotated vertex position must match rot * orig_pos")

	# All other vertices must remain unchanged
	for i in range(mesh_data.positions.size()):
		if not [1, 8, 21].has(i):
			assert_true(mesh_data.positions[i].is_equal_approx(original_positions[i]), "Unselected vertex %d must remain unchanged" % i)

## 4. 360° / identity quaternion leaves positions unchanged
func test_identity_and_full_rotation() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var selection := PBSelection.new(mesh_data)
	selection.add_face(0)

	# Identity rotation
	var cmd_identity := CmdRotateElements.new()
	cmd_identity.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.FACE, Quaternion.IDENTITY)
	cmd_identity.do_it()

	for i in range(mesh_data.positions.size()):
		assert_true(mesh_data.positions[i].is_equal_approx(original_positions[i]), "Identity rotation must leave vertex %d unchanged" % i)

	# 360 degree rotation
	var cmd_360 := CmdRotateElements.new()
	var rot_360 := Quaternion(Vector3.UP, TAU)
	cmd_360.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.FACE, rot_360)
	cmd_360.do_it()

	for i in range(mesh_data.positions.size()):
		assert_true(mesh_data.positions[i].is_equal_approx(original_positions[i]), "360 degree rotation must leave vertex %d unchanged" % i)

## 5. Empty selection: do_it does not change positions
func test_empty_selection() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var selection := PBSelection.new(mesh_data)

	var rot := Quaternion(Vector3.UP, PI / 2.0)
	var cmd := CmdRotateElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.FACE, rot)

	assert_eq(cmd.indices.size(), 0, "Empty selection must yield 0 indices")

	cmd.do_it()

	for i in range(mesh_data.positions.size()):
		assert_true(mesh_data.positions[i].is_equal_approx(original_positions[i]), "Position %d must not change on empty selection" % i)

## 6. Custom pivot (auto_pivot = false): rotate around Vector3.ZERO moves centroid of face 0
func test_custom_pivot_moves_centroid() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var selection := PBSelection.new(mesh_data)
	selection.add_face(0)

	var rot := Quaternion(Vector3.UP, PI / 2.0)
	var cmd := CmdRotateElements.new()
	# Rotate around Vector3.ZERO with auto_pivot = false
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.FACE, rot, null, Vector3.ZERO, false)

	cmd.do_it()

	var orig_centroid := (original_positions[0] + original_positions[1] + original_positions[2] + original_positions[3]) / 4.0
	var new_centroid := (mesh_data.positions[0] + mesh_data.positions[1] + mesh_data.positions[2] + mesh_data.positions[3]) / 4.0

	# Original centroid is (0, 0, -0.5); rotated 90 deg around Y about (0,0,0) becomes (-0.5, 0, 0)
	assert_false(new_centroid.is_equal_approx(orig_centroid), "Face 0 centroid must move when rotated around origin")
	var expected_centroid: Vector3 = rot * orig_centroid
	assert_true(new_centroid.is_equal_approx(expected_centroid), "Face 0 centroid must equal rot * orig_centroid")

## 7. PBMesh rebuild: mesh_node.mesh is ArrayMesh with vertex matching rotated position
func test_pb_mesh_rebuild() -> void:
	var mesh_node := PBMesh.create_cube(1.0)
	autofree(mesh_node)
	mesh_node.rebuild()
	var initial_array_mesh: ArrayMesh = mesh_node.mesh as ArrayMesh
	assert_not_null(initial_array_mesh, "PBMesh must have an initial ArrayMesh")

	var selection := PBSelection.new(mesh_node.pb_mesh_data)
	selection.add_face(0)

	var rot := Quaternion(Vector3.UP, PI / 2.0)
	var cmd := CmdRotateElements.new()
	cmd.setup_from_selection(mesh_node.pb_mesh_data, selection, PBEditor.SelectMode.FACE, rot, mesh_node)

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

## 8. UndoRedo stack integration
func test_undo_redo_stack_integration() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_pos_0: Vector3 = mesh_data.positions[0]
	var selection := PBSelection.new(mesh_data)
	selection.add_face(0)

	var rot := Quaternion(Vector3.UP, PI / 2.0)
	var cmd := CmdRotateElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.FACE, rot)

	var orig_centroid := (mesh_data.positions[0] + mesh_data.positions[1] + mesh_data.positions[2] + mesh_data.positions[3]) / 4.0
	var expected_pos_0: Vector3 = orig_centroid + rot * (original_pos_0 - orig_centroid)

	var ur := UndoRedo.new()
	ur.create_action(cmd.command_name)
	ur.add_do_method(cmd.do_it)
	ur.add_undo_method(cmd.undo_it)
	ur.commit_action()

	# After commit
	assert_true(mesh_data.positions[0].is_equal_approx(expected_pos_0), "Vertex 0 rotated after commit")

	# After undo
	ur.undo()
	assert_true(mesh_data.positions[0].is_equal_approx(original_pos_0), "Vertex 0 restored after ur.undo()")

	# After redo
	ur.redo()
	assert_true(mesh_data.positions[0].is_equal_approx(expected_pos_0), "Vertex 0 rotated again after ur.redo()")

## 9. Null safety checks
func test_null_safety() -> void:
	var cmd := CmdRotateElements.new()
	# Setup with null mesh_data
	cmd.setup_from_indices(null, PackedInt32Array([0, 1]), Quaternion.IDENTITY)
	assert_eq(cmd.indices.size(), 0, "Null mesh data yields empty indices")
	# do_it and undo_it on uninitialized command
	cmd.do_it()
	cmd.undo_it()

	# setup_from_selection with null selection
	var mesh_data := PBMeshData.create_cube(1.0)
	cmd.setup_from_selection(mesh_data, null, PBEditor.SelectMode.FACE, Quaternion.IDENTITY)
	assert_eq(cmd.indices.size(), 0, "Null selection yields empty indices")

	# add_to_undo_manager with null
	cmd.add_to_undo_manager(null)
	assert_true(true, "Null safety tests executed successfully")

## 10. set_rotation_basis helper converts Basis to Quaternion
func test_set_rotation_basis() -> void:
	var cmd := CmdRotateElements.new()
	var b := Basis(Vector3.UP, deg_to_rad(45.0))
	cmd.set_rotation_basis(b)

	var expected_quat := b.get_rotation_quaternion()
	assert_true(cmd.rotation.is_equal_approx(expected_quat), "set_rotation_basis must set rotation quaternion matching Basis")

## 11. Rotate one edge of face 0: both endpoint corners' coincident verts move (6 locals); others stay
func test_rotate_one_edge() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var selection := PBSelection.new(mesh_data)
	# Face 0 edge between local 0 (Group 1 [0, 13, 22]) and local 1 (Group 0 [1, 8, 21])
	selection.add_edge(PBEdge.new(0, 1))

	var rot := Quaternion(Vector3.FORWARD, PI / 2.0)
	var cmd := CmdRotateElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.EDGE, rot)

	assert_eq(cmd.indices.size(), 6, "Edge selection should expand to 6 coincident vertices (2 corners * 3)")

	cmd.do_it()

	# Edge midpoint / centroid
	var edge_centroid := (original_positions[0] + original_positions[1]) / 2.0
	var edge_moved_indices := [0, 13, 22, 1, 8, 21]
	for idx in edge_moved_indices:
		var expected: Vector3 = edge_centroid + rot * (original_positions[idx] - edge_centroid)
		assert_true(mesh_data.positions[idx].is_equal_approx(expected), "Edge endpoint vertex %d must rotate around edge center" % idx)

	# Other two Face 0 corners: Group 2 [2, 11, 16] and Group 3 [3, 14, 19] must stay
	for idx in [2, 11, 16, 3, 14, 19]:
		assert_true(mesh_data.positions[idx].is_equal_approx(original_positions[idx]), "Other Face 0 corner vertex %d must not move" % idx)

## 12. Rotate all vertices (select all in VERTEX mode)
func test_rotate_all_vertices() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var selection := PBSelection.new(mesh_data)
	selection.select_all(PBEditor.SelectMode.VERTEX)

	var rot := Quaternion(Vector3.UP, PI / 2.0)
	var cmd := CmdRotateElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.VERTEX, rot)

	assert_eq(cmd.indices.size(), 24, "Select all must resolve to all 24 vertices")

	cmd.do_it()

	# Centroid of whole cube is (0, 0, 0)
	for i in range(24):
		var expected: Vector3 = rot * original_positions[i]
		assert_true(mesh_data.positions[i].is_equal_approx(expected), "Vertex %d must rotate around cube centroid" % i)

## 13. setup_from_indices with expand_coincident = false vs true
func test_setup_from_indices_expand_flag() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var cmd_unshared := CmdRotateElements.new()
	# Only local index 0 without expansion
	cmd_unshared.setup_from_indices(mesh_data, PackedInt32Array([0]), Quaternion.IDENTITY, false)
	assert_eq(cmd_unshared.indices.size(), 1, "Without expansion, exactly 1 index should be stored")
	assert_eq(cmd_unshared.indices[0], 0, "Index must be 0")

	var cmd_shared := CmdRotateElements.new()
	# Local index 0 with expansion (group 1 [0, 13, 22])
	cmd_shared.setup_from_indices(mesh_data, PackedInt32Array([0]), Quaternion.IDENTITY, true)
	assert_eq(cmd_shared.indices.size(), 3, "With expansion, all 3 coincident vertices should be stored")

## 14. Object mode in setup_from_selection yields empty indices
func test_object_mode_selection() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var selection := PBSelection.new(mesh_data)
	selection.add_face(0)

	var cmd := CmdRotateElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.OBJECT, Quaternion.IDENTITY)
	assert_eq(cmd.indices.size(), 0, "OBJECT mode should not resolve indices")

## 15. FakeUndo and Logger integration
func test_fake_undo_and_logger() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_pos_0: Vector3 = mesh_data.positions[0]
	var selection := PBSelection.new(mesh_data)
	selection.add_face(0)

	PBLogger.verbose = true  # these tests assert on INFO entries
	var logger := PBLogger.new()
	var rot := Quaternion(Vector3.UP, PI / 2.0)
	var cmd := CmdRotateElements.new(mesh_data, rot, null, Vector3.ZERO, true, logger)
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.FACE, rot)
	cmd.logger = logger

	var orig_centroid := (mesh_data.positions[0] + mesh_data.positions[1] + mesh_data.positions[2] + mesh_data.positions[3]) / 4.0
	var expected_pos_0: Vector3 = orig_centroid + rot * (original_pos_0 - orig_centroid)

	var fake_undo := FakeUndo.new()
	cmd.add_to_undo_manager(fake_undo)

	assert_eq(fake_undo.action_name, "Rotate Elements", "Action name registered as 'Rotate Elements'")
	assert_true(fake_undo.commit_called, "commit_action was called")
	assert_true(mesh_data.positions[0].is_equal_approx(expected_pos_0), "Vertex 0 rotated by fake_undo commit")

	# Check logger recorded undo entries
	var undo_entries := logger.get_entries_by_category("undo")
	assert_gt(undo_entries.size(), 0, "Logger must have entries under 'undo' category")

	# Undo via fake_undo
	fake_undo.undo_object.call(fake_undo.undo_method)
	assert_true(mesh_data.positions[0].is_equal_approx(original_pos_0), "Vertex 0 restored via fake_undo undo")
