## Unit tests for CmdScaleElements.
## Tests element scaling (vertex/edge/face), uniform and non-uniform scaling,
## centroid auto-pivot vs custom pivot, near-zero scale clamping, coincident vertex welding,
## PBMesh rebuild, and UndoRedo integration.
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

## 1. Uniform scale face 0 by Vector3(2, 2, 2) with auto centroid pivot:
##    - Centroid is unchanged
##    - Distance from each moved vertex to pivot doubles
##    - Face 1 vertices 4-7 are unchanged
##    - 12 coincident locals of face 0 corners are all scaled
func test_uniform_scale_face_0_auto_centroid() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var selection := PBSelection.new(mesh_data)
	selection.add_face(0)

	var scale_factor := Vector3(2.0, 2.0, 2.0)
	var cmd := CmdScaleElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.FACE, scale_factor)

	# Face 0 has 4 corners -> 12 coincident vertices
	assert_eq(cmd.indices.size(), 12, "Scaling Face 0 must resolve to exactly 12 coincident vertices")

	var orig_centroid := (original_positions[0] + original_positions[1] + original_positions[2] + original_positions[3]) / 4.0
	assert_true(orig_centroid.is_equal_approx(Vector3(0.0, 0.0, -0.5)), "Face 0 original centroid is (0, 0, -0.5)")

	cmd.do_it()

	# Centroid after uniform scale about auto centroid must be unchanged
	var new_centroid := (mesh_data.positions[0] + mesh_data.positions[1] + mesh_data.positions[2] + mesh_data.positions[3]) / 4.0
	assert_true(new_centroid.is_equal_approx(orig_centroid), "Face 0 centroid must remain unchanged after uniform scaling about centroid")

	# Check distance from pivot doubles for each moved vertex
	var moved_indices := [0, 13, 22, 1, 8, 21, 2, 11, 16, 3, 14, 19]
	for idx in moved_indices:
		var orig_dist: float = original_positions[idx].distance_to(orig_centroid)
		var new_dist: float = mesh_data.positions[idx].distance_to(orig_centroid)
		assert_almost_eq(new_dist, orig_dist * 2.0, 0.0001, "Distance from vertex %d to pivot must double" % idx)

		var expected_pos: Vector3 = orig_centroid + (original_positions[idx] - orig_centroid) * 2.0
		assert_true(mesh_data.positions[idx].is_equal_approx(expected_pos), "Vertex %d position must equal expected scaled position" % idx)

	# Face 1 (Back face, Z = +0.5) distinct local vertices 4, 5, 6, 7 must remain UNCHANGED
	for idx in [4, 5, 6, 7]:
		assert_true(mesh_data.positions[idx].is_equal_approx(original_positions[idx]), "Face 1 vertex %d must remain unchanged" % idx)

## 2. Undo restores every position; redo do_it() reapplies scale without stacking (snapshot-once)
func test_undo_and_redo_idempotent() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var selection := PBSelection.new(mesh_data)
	selection.add_face(0)

	var scale_factor := Vector3(2.0, 2.0, 2.0)
	var cmd := CmdScaleElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.FACE, scale_factor)

	var orig_centroid := (original_positions[0] + original_positions[1] + original_positions[2] + original_positions[3]) / 4.0

	# 1. do_it
	cmd.do_it()
	for idx in cmd.indices:
		var expected: Vector3 = orig_centroid + (original_positions[idx] - orig_centroid) * 2.0
		assert_true(mesh_data.positions[idx].is_equal_approx(expected), "Vertex %d scaled after do_it" % idx)

	# 2. undo_it
	cmd.undo_it()
	for i in range(mesh_data.positions.size()):
		assert_true(mesh_data.positions[i].is_equal_approx(original_positions[i]), "Vertex %d restored after undo_it" % i)

	# 3. redo (do_it called again)
	cmd.do_it()
	for idx in cmd.indices:
		var expected: Vector3 = orig_centroid + (original_positions[idx] - orig_centroid) * 2.0
		assert_true(mesh_data.positions[idx].is_equal_approx(expected), "Vertex %d scaled after redo" % idx)

	# 4. repeated do_it without undo must be idempotent (snapshot-once, does not stack to 4x)
	cmd.do_it()
	for idx in cmd.indices:
		var expected: Vector3 = orig_centroid + (original_positions[idx] - orig_centroid) * 2.0
		assert_true(mesh_data.positions[idx].is_equal_approx(expected), "Repeated do_it does not stack to 4x (snapshot-once)")

## 3. Non-uniform scale Vector3(2, 1, 1): extents in X about pivot double; Y offset from pivot unchanged
func test_non_uniform_scale() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var selection := PBSelection.new(mesh_data)
	selection.add_face(0)

	var scale_factor := Vector3(2.0, 1.0, 1.0)
	var cmd := CmdScaleElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.FACE, scale_factor)

	var orig_centroid := (original_positions[0] + original_positions[1] + original_positions[2] + original_positions[3]) / 4.0

	cmd.do_it()

	for idx in cmd.indices:
		var orig_p: Vector3 = original_positions[idx]
		var new_p: Vector3 = mesh_data.positions[idx]
		var d_orig: Vector3 = orig_p - orig_centroid
		var d_new: Vector3 = new_p - orig_centroid

		# X offset doubles
		assert_almost_eq(d_new.x, d_orig.x * 2.0, 0.0001, "X offset from pivot must double for vertex %d" % idx)
		# Y offset unchanged
		assert_almost_eq(d_new.y, d_orig.y, 0.0001, "Y offset from pivot must remain unchanged for vertex %d" % idx)
		# Z offset unchanged
		assert_almost_eq(d_new.z, d_orig.z, 0.0001, "Z offset from pivot must remain unchanged for vertex %d" % idx)

## 4. Scale one common vertex group: 3 coincident locals remain coincident (welding maintained)
func test_scale_one_common_vertex() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var selection := PBSelection.new(mesh_data)
	# Common index 0 -> corner (-0.5, -0.5, -0.5) -> Group 0 [1, 8, 21]
	selection.add_vertex(0)

	# Scale about custom pivot Vector3.ZERO (origin)
	var scale_factor := Vector3(2.0, 2.0, 2.0)
	var cmd := CmdScaleElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.VERTEX, scale_factor, null, Vector3.ZERO, false)

	assert_eq(cmd.indices.size(), 3, "Common vertex 0 should resolve to 3 coincident vertices")

	cmd.do_it()

	# Corner (-0.5, -0.5, -0.5) scaled by 2 about (0,0,0) becomes (-1.0, -1.0, -1.0)
	var expected_corner := Vector3(-1.0, -1.0, -1.0)
	for idx in [1, 8, 21]:
		assert_true(mesh_data.positions[idx].is_equal_approx(expected_corner), "Coincident vertex %d in Group 0 must scale to (-1, -1, -1)" % idx)

	# All 3 coincident vertices must share identical position (welding preserved)
	assert_true(mesh_data.positions[1].is_equal_approx(mesh_data.positions[8]), "Vertices 1 and 8 share identical position")
	assert_true(mesh_data.positions[8].is_equal_approx(mesh_data.positions[21]), "Vertices 8 and 21 share identical position")

	# All other vertices must remain unchanged
	for i in range(mesh_data.positions.size()):
		if not [1, 8, 21].has(i):
			assert_true(mesh_data.positions[i].is_equal_approx(original_positions[i]), "Unselected vertex %d must remain unchanged" % i)

## 5. Scale Vector3.ONE: no change
func test_scale_one_no_op() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var selection := PBSelection.new(mesh_data)
	selection.add_face(0)

	var cmd := CmdScaleElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.FACE, Vector3.ONE)

	cmd.do_it()

	for i in range(mesh_data.positions.size()):
		assert_true(mesh_data.positions[i].is_equal_approx(original_positions[i]), "Position %d must not change when scaling by Vector3.ONE" % i)

## 6. Empty selection: no change
func test_empty_selection() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var selection := PBSelection.new(mesh_data) # Empty

	var scale_factor := Vector3(2.0, 3.0, 4.0)
	var cmd := CmdScaleElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.FACE, scale_factor)

	assert_eq(cmd.indices.size(), 0, "Empty selection must yield 0 indices")

	cmd.do_it()

	for i in range(mesh_data.positions.size()):
		assert_true(mesh_data.positions[i].is_equal_approx(original_positions[i]), "Position %d must not change on empty selection" % i)

## 7. Custom pivot Vector3.ZERO auto_pivot false: centroid of face 0 moves
func test_custom_pivot_face_centroid_moves() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var selection := PBSelection.new(mesh_data)
	selection.add_face(0)

	var scale_factor := Vector3(2.0, 2.0, 2.0)
	var custom_pivot := Vector3.ZERO
	var cmd := CmdScaleElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.FACE, scale_factor, null, custom_pivot, false)

	var orig_centroid := (original_positions[0] + original_positions[1] + original_positions[2] + original_positions[3]) / 4.0
	assert_true(orig_centroid.is_equal_approx(Vector3(0.0, 0.0, -0.5)), "Original Face 0 centroid is (0, 0, -0.5)")

	cmd.do_it()

	var new_centroid := (mesh_data.positions[0] + mesh_data.positions[1] + mesh_data.positions[2] + mesh_data.positions[3]) / 4.0
	var expected_new_centroid := custom_pivot + (orig_centroid - custom_pivot) * 2.0
	assert_true(expected_new_centroid.is_equal_approx(Vector3(0.0, 0.0, -1.0)), "Expected new centroid is (0, 0, -1.0)")
	assert_true(new_centroid.is_equal_approx(expected_new_centroid), "Face 0 centroid moves to (0, 0, -1.0) when scaled around origin")
	assert_false(new_centroid.is_equal_approx(orig_centroid), "Face 0 centroid must have moved away from original centroid")

## 8. Near-zero scale Vector3(0, 0, 0) does not NaN; positions remain finite
func test_near_zero_scale_clamping() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var selection := PBSelection.new(mesh_data)
	selection.add_face(0)

	var cmd := CmdScaleElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.FACE, Vector3.ZERO)

	cmd.do_it()

	for idx in cmd.indices:
		var pos: Vector3 = mesh_data.positions[idx]
		assert_false(is_nan(pos.x), "Vertex %d pos.x must not be NaN" % idx)
		assert_false(is_nan(pos.y), "Vertex %d pos.y must not be NaN" % idx)
		assert_false(is_nan(pos.z), "Vertex %d pos.z must not be NaN" % idx)
		assert_false(is_inf(pos.x), "Vertex %d pos.x must not be Inf" % idx)
		assert_false(is_inf(pos.y), "Vertex %d pos.y must not be Inf" % idx)
		assert_false(is_inf(pos.z), "Vertex %d pos.z must not be Inf" % idx)

	# Direct testing of clamp_component helper
	assert_almost_eq(CmdScaleElements.clamp_component(0.0), CmdScaleElements.MIN_SCALE, 0.00001, "0.0 clamps to MIN_SCALE")
	assert_almost_eq(CmdScaleElements.clamp_component(0.00001), CmdScaleElements.MIN_SCALE, 0.00001, "Small positive clamps to MIN_SCALE")
	assert_almost_eq(CmdScaleElements.clamp_component(-0.00001), -CmdScaleElements.MIN_SCALE, 0.00001, "Small negative clamps to -MIN_SCALE")
	assert_almost_eq(CmdScaleElements.clamp_component(2.5), 2.5, 0.00001, "Normal scale 2.5 is preserved")
	assert_almost_eq(CmdScaleElements.clamp_component(-2.5), -2.5, 0.00001, "Negative scale -2.5 is preserved")

## 9. PBMesh rebuild: mesh_node.mesh is ArrayMesh with surface matching scaled positions
func test_pb_mesh_rebuild() -> void:
	var mesh_node := PBMesh.create_cube(1.0)
	autofree(mesh_node)
	mesh_node.rebuild()
	var initial_array_mesh: ArrayMesh = mesh_node.mesh as ArrayMesh
	assert_not_null(initial_array_mesh, "PBMesh must have an initial ArrayMesh")

	var selection := PBSelection.new(mesh_node.pb_mesh_data)
	selection.add_face(0)

	var scale_factor := Vector3(2.0, 2.0, 2.0)
	var cmd := CmdScaleElements.new()
	cmd.setup_from_selection(mesh_node.pb_mesh_data, selection, PBEditor.SelectMode.FACE, scale_factor, mesh_node)

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

## 10. UndoRedo stack integration
func test_undo_redo_stack_integration() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_pos_0: Vector3 = mesh_data.positions[0]
	var selection := PBSelection.new(mesh_data)
	selection.add_face(0)

	var orig_centroid := (mesh_data.positions[0] + mesh_data.positions[1] + mesh_data.positions[2] + mesh_data.positions[3]) / 4.0
	var scale_factor := Vector3(3.0, 3.0, 3.0)
	var expected_pos_0: Vector3 = orig_centroid + (original_pos_0 - orig_centroid) * 3.0

	var cmd := CmdScaleElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.FACE, scale_factor)

	var ur := UndoRedo.new()
	ur.create_action(cmd.command_name)
	ur.add_do_method(cmd.do_it)
	ur.add_undo_method(cmd.undo_it)
	ur.commit_action()

	# After commit
	assert_true(mesh_data.positions[0].is_equal_approx(expected_pos_0), "Vertex 0 scaled after commit")

	# After undo
	ur.undo()
	assert_true(mesh_data.positions[0].is_equal_approx(original_pos_0), "Vertex 0 restored after ur.undo()")

	# After redo
	ur.redo()
	assert_true(mesh_data.positions[0].is_equal_approx(expected_pos_0), "Vertex 0 scaled again after ur.redo()")

## 11. Null safety checks
func test_null_safety() -> void:
	var cmd := CmdScaleElements.new()
	# Setup with null mesh_data
	cmd.setup_from_indices(null, PackedInt32Array([0, 1]), Vector3(2, 2, 2))
	assert_eq(cmd.indices.size(), 0, "Null mesh data yields empty indices")
	# do_it and undo_it on uninitialized command
	cmd.do_it()
	cmd.undo_it()

	# setup_from_selection with null selection
	var mesh_data := PBMeshData.create_cube(1.0)
	cmd.setup_from_selection(mesh_data, null, PBEditor.SelectMode.FACE, Vector3(2, 2, 2))
	assert_eq(cmd.indices.size(), 0, "Null selection yields empty indices")

	# add_to_undo_manager with null
	cmd.add_to_undo_manager(null)
	assert_true(true, "Null safety tests executed successfully")

## 12. Edge selection scaling: edge midpoint auto pivot
func test_scale_one_edge() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var selection := PBSelection.new(mesh_data)
	# Face 0 edge between local 0 (Group 1 [0, 13, 22]) and local 1 (Group 0 [1, 8, 21])
	selection.add_edge(PBEdge.new(0, 1))

	var scale_factor := Vector3(2.0, 2.0, 2.0)
	var cmd := CmdScaleElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.EDGE, scale_factor)

	assert_eq(cmd.indices.size(), 6, "Edge selection should expand to 6 coincident vertices (2 corners * 3)")

	var edge_midpoint := (original_positions[0] + original_positions[1]) / 2.0

	cmd.do_it()

	var edge_moved_indices := [0, 13, 22, 1, 8, 21]
	for idx in edge_moved_indices:
		var expected: Vector3 = edge_midpoint + (original_positions[idx] - edge_midpoint) * 2.0
		assert_true(mesh_data.positions[idx].is_equal_approx(expected), "Edge vertex %d must scale away from edge midpoint" % idx)

	# Other two Face 0 corners: Group 2 [2, 11, 16] and Group 3 [3, 14, 19] must stay
	for idx in [2, 11, 16, 3, 14, 19]:
		assert_true(mesh_data.positions[idx].is_equal_approx(original_positions[idx]), "Other Face 0 corner vertex %d must not move" % idx)

## 13. Select all scaling: entire cube AABB doubles
func test_scale_all_vertices() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var selection := PBSelection.new(mesh_data)
	selection.select_all(PBEditor.SelectMode.VERTEX)

	var scale_factor := Vector3(2.0, 2.0, 2.0)
	var cmd := CmdScaleElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.VERTEX, scale_factor)

	assert_eq(cmd.indices.size(), 24, "Select all must resolve to all 24 vertices")

	cmd.do_it()

	var aabb_actual := AABB(mesh_data.positions[0], Vector3.ZERO)
	for p in mesh_data.positions:
		aabb_actual = aabb_actual.expand(p)

	var aabb_expected := AABB(Vector3(-1.0, -1.0, -1.0), Vector3(2.0, 2.0, 2.0))
	assert_true(aabb_actual.position.is_equal_approx(aabb_expected.position), "AABB min position should expand to (-1, -1, -1)")
	assert_true(aabb_actual.size.is_equal_approx(aabb_expected.size), "AABB size should double to (2, 2, 2)")

## 14. setup_from_indices expand_coincident flag
func test_setup_from_indices_expand_flag() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var cmd_unshared := CmdScaleElements.new()
	cmd_unshared.setup_from_indices(mesh_data, PackedInt32Array([0]), Vector3(2, 2, 2), false)
	assert_eq(cmd_unshared.indices.size(), 1, "Without expansion, exactly 1 index should be stored")
	assert_eq(cmd_unshared.indices[0], 0, "Index must be 0")

	var cmd_shared := CmdScaleElements.new()
	cmd_shared.setup_from_indices(mesh_data, PackedInt32Array([0]), Vector3(2, 2, 2), true)
	assert_eq(cmd_shared.indices.size(), 3, "With expansion, all 3 coincident vertices should be stored")

## 15. Object mode in setup_from_selection yields empty indices
func test_object_mode_selection() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var selection := PBSelection.new(mesh_data)
	selection.add_face(0)

	var cmd := CmdScaleElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.OBJECT, Vector3(2, 2, 2))
	assert_eq(cmd.indices.size(), 0, "OBJECT mode should not resolve indices")

## 16. FakeUndo and Logger integration
func test_fake_undo_and_logger() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_pos_0: Vector3 = mesh_data.positions[0]
	var selection := PBSelection.new(mesh_data)
	selection.add_face(0)

	var orig_centroid := (mesh_data.positions[0] + mesh_data.positions[1] + mesh_data.positions[2] + mesh_data.positions[3]) / 4.0
	var scale_factor := Vector3(2.0, 2.0, 2.0)
	var expected_pos_0: Vector3 = orig_centroid + (original_pos_0 - orig_centroid) * 2.0

	var logger := PBLogger.new()
	var cmd := CmdScaleElements.new(mesh_data, scale_factor, null, logger)
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.FACE, scale_factor)
	cmd.logger = logger

	var fake_undo := FakeUndo.new()
	cmd.add_to_undo_manager(fake_undo)

	assert_eq(fake_undo.action_name, "Scale Elements", "Action name registered as 'Scale Elements'")
	assert_true(fake_undo.commit_called, "commit_action was called")
	assert_true(mesh_data.positions[0].is_equal_approx(expected_pos_0), "Vertex 0 scaled by fake_undo commit")

	# Check logger recorded undo entries
	var undo_entries := logger.get_entries_by_category("undo")
	assert_gt(undo_entries.size(), 0, "Logger must have entries under 'undo' category")

	# Undo via fake_undo
	fake_undo.undo_object.call(fake_undo.undo_method)
	assert_true(mesh_data.positions[0].is_equal_approx(original_pos_0), "Vertex 0 restored via fake_undo undo")

## 17. Negative scale component (reflection / flipping across pivot)
func test_negative_scale_reflection() -> void:
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions := mesh_data.positions.duplicate()
	var selection := PBSelection.new(mesh_data)
	selection.add_face(0)

	var orig_centroid := (original_positions[0] + original_positions[1] + original_positions[2] + original_positions[3]) / 4.0
	var scale_factor := Vector3(-1.0, 1.0, 1.0)
	var cmd := CmdScaleElements.new()
	cmd.setup_from_selection(mesh_data, selection, PBEditor.SelectMode.FACE, scale_factor)

	cmd.do_it()

	for idx in cmd.indices:
		var orig_p: Vector3 = original_positions[idx]
		var new_p: Vector3 = mesh_data.positions[idx]
		var d_orig: Vector3 = orig_p - orig_centroid
		var d_new: Vector3 = new_p - orig_centroid

		# X offset is negated (flipped)
		assert_almost_eq(d_new.x, -d_orig.x, 0.0001, "X offset should be negated for vertex %d" % idx)
		# Y and Z unchanged
		assert_almost_eq(d_new.y, d_orig.y, 0.0001, "Y offset should be unchanged for vertex %d" % idx)
		assert_almost_eq(d_new.z, d_orig.z, 0.0001, "Z offset should be unchanged for vertex %d" % idx)
