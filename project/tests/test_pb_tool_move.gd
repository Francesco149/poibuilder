## Tests for Phase 6 (IU P6-03): Move Tool & PBTool Base
##
## Tests PBTool base functionality and PBToolMove viewport drag translation
## with snapshot-once live preview, undo/redo, coordinate space transformation,
## ray-plane intersection, and mode constraints.
extends GutTest

# ==============================================================================
# Helper Mock Objects
# ==============================================================================

class FakeUndoRedo extends RefCounted:
	var actions: Array[Dictionary] = []
	var _current_action: Dictionary = {}

	func create_action(name: String) -> void:
		_current_action = {
			"name": name,
			"do_methods": [],
			"undo_methods": []
		}

	func add_do_method(object: Object, method: String, arg1 = null, arg2 = null) -> void:
		_current_action["do_methods"].append({"object": object, "method": method, "args": [arg1, arg2]})

	func add_undo_method(object: Object, method: String, arg1 = null, arg2 = null) -> void:
		_current_action["undo_methods"].append({"object": object, "method": method, "args": [arg1, arg2]})

	func commit_action() -> void:
		for item in _current_action["do_methods"]:
			item["object"].call(item["method"])
		actions.append(_current_action)

	func undo() -> void:
		if actions.is_empty():
			return
		var act: Dictionary = actions.back()
		for item in act["undo_methods"]:
			item["object"].call(item["method"])

	func redo() -> void:
		if actions.is_empty():
			return
		var act: Dictionary = actions.back()
		for item in act["do_methods"]:
			item["object"].call(item["method"])

# ==============================================================================
# 1. PBTool Base & State Tests
# ==============================================================================

func test_tool_name_and_initial_state():
	var tool := PBToolMove.new()
	assert_eq(tool.tool_name(), "Move", "PBToolMove tool name should be 'Move'")
	assert_eq(tool.state, PBTool.State.IDLE, "Initial state must be IDLE")
	assert_false(tool.is_dragging(), "is_dragging() must be false initially")

func test_begin_drag_false_on_empty_selection():
	var mesh_data := PBMeshData.create_cube(1.0)
	var editor := PBEditor.new()
	var mesh := PBMesh.new()
	mesh.pb_mesh_data = mesh_data
	add_child_autofree(mesh)
	editor.active_mesh = mesh
	editor.select_mode = PBEditor.SelectMode.FACE
	editor.selection.clear_all()

	var tool := PBToolMove.new()
	tool.editor = editor

	# Ray aimed at cube center from -Z
	var ok: bool = tool.begin_drag(Vector3(0.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	assert_false(ok, "begin_drag must return false when selection is empty")
	assert_false(tool.is_dragging(), "Tool must not be dragging")
	assert_eq(tool.state, PBTool.State.IDLE)

# ==============================================================================
# 2. Face Selection Drag, Live Preview & Centroid
# ==============================================================================

func test_move_face_0_drag_and_centroid():
	var mesh_data := PBMeshData.create_cube(1.0)
	var editor := PBEditor.new()
	var mesh := PBMesh.new()
	mesh.pb_mesh_data = mesh_data
	add_child_autofree(mesh)
	editor.active_mesh = mesh
	editor.select_mode = PBEditor.SelectMode.FACE
	editor.selection.set_faces(PackedInt32Array([0]))

	# Cube Face 0 is at Z = -0.5, centroid (0, 0, -0.5)
	var initial_centroid: Vector3 = PBMath.average(mesh_data.positions, PackedInt32Array([0, 1, 2, 3]))
	assert_true(initial_centroid.is_equal_approx(Vector3(0.0, 0.0, -0.5)), "Initial Face 0 centroid must be (0, 0, -0.5)")

	var tool := PBToolMove.new()
	tool.editor = editor

	# Begin ray: origin (0, 0, -5), dir (0, 0, 1) -> hits (0, 0, -0.5)
	var ok: bool = tool.begin_drag(Vector3(0.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	assert_true(ok, "begin_drag must return true for valid face selection")
	assert_true(tool.is_dragging(), "Tool must be in DRAGGING state")
	assert_eq(tool.state, PBTool.State.DRAGGING)
	assert_true(tool.get_hit_start().is_equal_approx(Vector3(0.0, 0.0, -0.5)), "Drag start hit should be at (0, 0, -0.5)")

	# Update ray: origin (1, 0, -5), dir (0, 0, 1) -> hits (1, 0, -0.5) => delta (1, 0, 0)
	tool.update_drag(Vector3(1.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))

	# Check Face 0 centroid moved by ~(1, 0, 0) to (1, 0, -0.5)
	var moved_indices: PackedInt32Array = tool.get_command().indices
	assert_eq(moved_indices.size(), 12, "Face 0 should resolve to 12 coincident vertices")
	var new_centroid: Vector3 = PBMath.average(mesh_data.positions, moved_indices)
	assert_true(new_centroid.is_equal_approx(Vector3(1.0, 0.0, -0.5)),
		"Face 0 centroid after update must be (1, 0, -0.5), got %s" % str(new_centroid))

	# Coincident vertices of Face 0 must have moved by (1, 0, 0)
	# Vertex 0 original: (0.5, -0.5, -0.5) -> new: (1.5, -0.5, -0.5)
	assert_true(mesh_data.positions[0].is_equal_approx(Vector3(1.5, -0.5, -0.5)), "Vertex 0 must move by (1, 0, 0)")
	# Vertex 1 original: (-0.5, -0.5, -0.5) -> new: (0.5, -0.5, -0.5)
	assert_true(mesh_data.positions[1].is_equal_approx(Vector3(0.5, -0.5, -0.5)), "Vertex 1 must move by (1, 0, 0)")

	# Face 1 (Back, Z = +0.5, vertices 4, 5, 6, 7) must remain unchanged
	assert_true(mesh_data.positions[4].is_equal_approx(Vector3(-0.5, -0.5, 0.5)), "Face 1 vertex 4 must be unchanged")
	assert_true(mesh_data.positions[5].is_equal_approx(Vector3(0.5, -0.5, 0.5)), "Face 1 vertex 5 must be unchanged")
	assert_true(mesh_data.positions[6].is_equal_approx(Vector3(0.5, 0.5, 0.5)), "Face 1 vertex 6 must be unchanged")
	assert_true(mesh_data.positions[7].is_equal_approx(Vector3(-0.5, 0.5, 0.5)), "Face 1 vertex 7 must be unchanged")

# ==============================================================================
# 3. Finish Drag (Commit)
# ==============================================================================

func test_finish_drag_keeps_moved_positions():
	var mesh_data := PBMeshData.create_cube(1.0)
	var editor := PBEditor.new()
	var mesh := PBMesh.new()
	mesh.pb_mesh_data = mesh_data
	add_child_autofree(mesh)
	editor.active_mesh = mesh
	editor.select_mode = PBEditor.SelectMode.FACE
	editor.selection.set_faces(PackedInt32Array([0]))

	var tool := PBToolMove.new()
	tool.editor = editor

	tool.begin_drag(Vector3(0.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	tool.update_drag(Vector3(1.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))

	# Commit drag without external undo manager
	tool.finish_drag(null)

	assert_false(tool.is_dragging(), "Tool must be IDLE after finish_drag")
	assert_eq(tool.state, PBTool.State.IDLE)

	# Positions should persist
	var new_centroid: Vector3 = PBMath.average(mesh_data.positions, PackedInt32Array([0, 1, 2, 3]))
	assert_true(new_centroid.is_equal_approx(Vector3(1.0, 0.0, -0.5)), "Moved positions must be retained on finish_drag")

# ==============================================================================
# 4. Cancel Drag (Revert Snapshot)
# ==============================================================================

func test_cancel_drag_restores_snapshot():
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions: PackedVector3Array = mesh_data.positions.duplicate()

	var editor := PBEditor.new()
	var mesh := PBMesh.new()
	mesh.pb_mesh_data = mesh_data
	add_child_autofree(mesh)
	editor.active_mesh = mesh
	editor.select_mode = PBEditor.SelectMode.FACE
	editor.selection.set_faces(PackedInt32Array([0]))

	var tool := PBToolMove.new()
	tool.editor = editor

	tool.begin_drag(Vector3(0.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	tool.update_drag(Vector3(1.0, 2.0, -5.0), Vector3(0.0, 0.0, 1.0))

	# Verify it moved during drag
	var drag_centroid: Vector3 = PBMath.average(mesh_data.positions, PackedInt32Array([0, 1, 2, 3]))
	assert_false(drag_centroid.is_equal_approx(Vector3(0.0, 0.0, -0.5)), "Positions should be modified during preview")

	# Cancel the drag
	tool.cancel_drag()

	assert_false(tool.is_dragging(), "Tool must be IDLE after cancel_drag")
	assert_eq(tool.state, PBTool.State.IDLE)

	# Face 0 centroid restored
	var restored_centroid: Vector3 = PBMath.average(mesh_data.positions, PackedInt32Array([0, 1, 2, 3]))
	assert_true(restored_centroid.is_equal_approx(Vector3(0.0, 0.0, -0.5)), "Face 0 centroid must be restored to (0, 0, -0.5)")

	# All vertices must match original snapshot
	for i in range(mesh_data.positions.size()):
		assert_true(mesh_data.positions[i].is_equal_approx(original_positions[i]),
			"Vertex %d must match pre-drag snapshot" % i)

# ==============================================================================
# 5. Two Updates: Not Stacked / Total Delta from Start
# ==============================================================================

func test_two_updates_not_stacked():
	var mesh_data := PBMeshData.create_cube(1.0)
	var editor := PBEditor.new()
	var mesh := PBMesh.new()
	mesh.pb_mesh_data = mesh_data
	add_child_autofree(mesh)
	editor.active_mesh = mesh
	editor.select_mode = PBEditor.SelectMode.FACE
	editor.selection.set_faces(PackedInt32Array([0]))

	var tool := PBToolMove.new()
	tool.editor = editor

	# Begin drag at (0, 0, -5) -> hit (0, 0, -0.5)
	tool.begin_drag(Vector3(0.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))

	# First update: ray at (1, 0, -5) -> hit (1, 0, -0.5) -> delta (1, 0, 0)
	tool.update_drag(Vector3(1.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	var c1: Vector3 = PBMath.average(mesh_data.positions, PackedInt32Array([0, 1, 2, 3]))
	assert_true(c1.is_equal_approx(Vector3(1.0, 0.0, -0.5)), "Centroid after first update should be (1, 0, -0.5)")

	# Second update: ray at (2, 0, -5) -> hit (2, 0, -0.5) -> total delta (2, 0, 0) from start
	tool.update_drag(Vector3(2.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	var c2: Vector3 = PBMath.average(mesh_data.positions, PackedInt32Array([0, 1, 2, 3]))
	assert_true(c2.is_equal_approx(Vector3(2.0, 0.0, -0.5)),
		"Centroid after second update must be (2, 0, -0.5) not stacked (3, 0, -0.5), got %s" % str(c2))

	# Third update moving backwards: ray at (-0.5, 0, -5) -> hit (-0.5, 0, -0.5) -> total delta (-0.5, 0, 0)
	tool.update_drag(Vector3(-0.5, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	var c3: Vector3 = PBMath.average(mesh_data.positions, PackedInt32Array([0, 1, 2, 3]))
	assert_true(c3.is_equal_approx(Vector3(-0.5, 0.0, -0.5)),
		"Centroid after third update must reflect total offset (-0.5, 0, 0), got %s" % str(c3))

	tool.finish_drag(null)

# ==============================================================================
# 6. Object Mode Rejection
# ==============================================================================

func test_begin_drag_false_in_object_mode():
	var mesh_data := PBMeshData.create_cube(1.0)
	var editor := PBEditor.new()
	var mesh := PBMesh.new()
	mesh.pb_mesh_data = mesh_data
	add_child_autofree(mesh)
	editor.active_mesh = mesh

	# Force OBJECT select mode even if face selection exists
	editor.selection.set_faces(PackedInt32Array([0]))
	editor.select_mode = PBEditor.SelectMode.OBJECT

	var tool := PBToolMove.new()
	tool.editor = editor

	var ok: bool = tool.begin_drag(Vector3(0.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	assert_false(ok, "begin_drag must return false in OBJECT select mode")
	assert_false(tool.is_dragging())
	assert_eq(tool.state, PBTool.State.IDLE)

# ==============================================================================
# 7. Rotated Mesh Node (World to Local Delta Transformation)
# ==============================================================================

func test_rotated_mesh_node_world_to_local_delta():
	var mesh_data := PBMeshData.create_cube(1.0)
	var editor := PBEditor.new()
	var mesh := PBMesh.new()
	mesh.pb_mesh_data = mesh_data
	add_child_autofree(mesh)

	# Rotate mesh 90 degrees around Y axis
	# Basis rotates local +X to -Z, local +Z to +X, local +Y to +Y
	# Inverse basis rotates world +X to +Z
	mesh.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(90.0)), Vector3.ZERO)

	editor.active_mesh = mesh
	editor.select_mode = PBEditor.SelectMode.FACE
	editor.selection.set_faces(PackedInt32Array([0]))

	# Local Face 0 centroid: (0, 0, -0.5)
	# World Face 0 centroid: mesh.global_transform * (0, 0, -0.5) = (-0.5, 0, 0)
	var local_c0: Vector3 = PBMath.average(mesh_data.positions, PackedInt32Array([0, 1, 2, 3]))
	var world_c0: Vector3 = mesh.global_transform * local_c0
	assert_true(world_c0.is_equal_approx(Vector3(-0.5, 0.0, 0.0)),
		"World Face 0 centroid for 90 deg Y rotated mesh should be (-0.5, 0, 0), got %s" % str(world_c0))

	var tool := PBToolMove.new()
	tool.editor = editor

	# Begin ray aimed at world centroid (-0.5, 0, 0) along +Z
	var ok: bool = tool.begin_drag(Vector3(-0.5, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	assert_true(ok, "begin_drag must succeed on rotated mesh")
	assert_true(tool.get_hit_start().is_equal_approx(Vector3(-0.5, 0.0, 0.0)),
		"Drag start hit should be at world (-0.5, 0, 0)")

	# Update ray: world offset +1 along X -> ray at (0.5, 0, -5), dir (0, 0, 1) -> hit (0.5, 0, 0)
	# World delta = (1, 0, 0)
	tool.update_drag(Vector3(0.5, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))

	# Expected local delta = basis.inverse() * (1, 0, 0)
	var expected_local_delta: Vector3 = mesh.global_transform.basis.inverse() * Vector3(1.0, 0.0, 0.0)
	assert_true(tool.get_command().delta.is_equal_approx(expected_local_delta),
		"CmdMoveElements.delta must equal basis.inverse() * world_delta: expected %s, got %s" % [
			str(expected_local_delta), str(tool.get_command().delta)
		])

	# Local centroid must have moved by local delta
	var new_local_c: Vector3 = PBMath.average(mesh_data.positions, PackedInt32Array([0, 1, 2, 3]))
	assert_true(new_local_c.is_equal_approx(local_c0 + expected_local_delta),
		"Local centroid must move by local delta")

	# World centroid must have moved by world delta (1, 0, 0) from (-0.5, 0, 0) to (0.5, 0, 0)
	var new_world_c: Vector3 = mesh.global_transform * new_local_c
	assert_true(new_world_c.is_equal_approx(Vector3(0.5, 0.0, 0.0)),
		"World centroid must move by world delta (+1, 0, 0) to (0.5, 0, 0), got %s" % str(new_world_c))

	tool.finish_drag(null)

# ==============================================================================
# 8. Logger Integration
# ==============================================================================

func test_logger_categories_tools_and_undo():
	var logger := PBLogger.new()
	var mesh_data := PBMeshData.create_cube(1.0)
	var editor := PBEditor.new()
	var mesh := PBMesh.new()
	mesh.pb_mesh_data = mesh_data
	add_child_autofree(mesh)
	editor.active_mesh = mesh
	editor.select_mode = PBEditor.SelectMode.FACE
	editor.selection.set_faces(PackedInt32Array([0]))
	editor.logger = logger

	var tool := PBToolMove.new()
	tool.editor = editor
	tool.logger = logger

	tool.begin_drag(Vector3(0.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	tool.update_drag(Vector3(1.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	tool.finish_drag(null)

	var tool_entries: Array = logger.get_entries_by_category("tools")
	var undo_entries: Array = logger.get_entries_by_category("undo")

	assert_gt(tool_entries.size(), 0, "Logger must have entries under 'tools' category")
	assert_gt(undo_entries.size(), 0, "Logger must have entries under 'undo' category from CmdMoveElements")

# ==============================================================================
# 9. UndoRedo Manager Integration via finish_drag(undo)
# ==============================================================================

func test_finish_drag_with_undo_redo_manager():
	var fake_undo := FakeUndoRedo.new()
	var mesh_data := PBMeshData.create_cube(1.0)
	var editor := PBEditor.new()
	var mesh := PBMesh.new()
	mesh.pb_mesh_data = mesh_data
	add_child_autofree(mesh)
	editor.active_mesh = mesh
	editor.select_mode = PBEditor.SelectMode.FACE
	editor.selection.set_faces(PackedInt32Array([0]))

	var tool := PBToolMove.new()
	tool.editor = editor

	tool.begin_drag(Vector3(0.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	tool.update_drag(Vector3(1.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	tool.finish_drag(fake_undo)

	# Action registered in fake_undo
	assert_eq(fake_undo.actions.size(), 1, "One undo action should be committed")
	assert_eq(fake_undo.actions[0]["name"], "Move Elements")

	# Position after commit
	var c_committed: Vector3 = PBMath.average(mesh_data.positions, PackedInt32Array([0, 1, 2, 3]))
	assert_true(c_committed.is_equal_approx(Vector3(1.0, 0.0, -0.5)))

	# Test undo
	fake_undo.undo()
	var c_undone: Vector3 = PBMath.average(mesh_data.positions, PackedInt32Array([0, 1, 2, 3]))
	assert_true(c_undone.is_equal_approx(Vector3(0.0, 0.0, -0.5)), "Undo should restore centroid to (0, 0, -0.5)")

	# Test redo
	fake_undo.redo()
	var c_redone: Vector3 = PBMath.average(mesh_data.positions, PackedInt32Array([0, 1, 2, 3]))
	assert_true(c_redone.is_equal_approx(Vector3(1.0, 0.0, -0.5)), "Redo should reapply moved centroid (1, 0, -0.5)")

# ==============================================================================
# 10. Vertex & Edge Mode Dragging
# ==============================================================================

func test_drag_vertex_selection():
	var mesh_data := PBMeshData.create_cube(1.0)
	var editor := PBEditor.new()
	var mesh := PBMesh.new()
	mesh.pb_mesh_data = mesh_data
	add_child_autofree(mesh)
	editor.active_mesh = mesh
	editor.select_mode = PBEditor.SelectMode.VERTEX
	# Select common vertex 0 (corner -0.5, -0.5, -0.5) -> coincident vertices [1, 8, 21]
	editor.selection.set_vertices(PackedInt32Array([0]))

	var tool := PBToolMove.new()
	tool.editor = editor

	# Ray aimed at corner (-0.5, -0.5, -0.5) from -Z
	var ok: bool = tool.begin_drag(Vector3(-0.5, -0.5, -5.0), Vector3(0.0, 0.0, 1.0))
	assert_true(ok, "begin_drag must succeed in VERTEX mode")
	assert_true(tool.get_hit_start().is_equal_approx(Vector3(-0.5, -0.5, -0.5)))

	# Drag by (+1, +1, 0)
	tool.update_drag(Vector3(0.5, 0.5, -5.0), Vector3(0.0, 0.0, 1.0))

	# Coincident vertices [1, 8, 21] should move to (0.5, 0.5, -0.5)
	assert_true(mesh_data.positions[1].is_equal_approx(Vector3(0.5, 0.5, -0.5)), "Vertex 1 must move")
	assert_true(mesh_data.positions[8].is_equal_approx(Vector3(0.5, 0.5, -0.5)), "Vertex 8 must move")
	assert_true(mesh_data.positions[21].is_equal_approx(Vector3(0.5, 0.5, -0.5)), "Vertex 21 must move")

	# Unselected vertex 0 should remain unchanged
	assert_true(mesh_data.positions[0].is_equal_approx(Vector3(0.5, -0.5, -0.5)), "Unselected vertex 0 must be unchanged")

	tool.finish_drag(null)

func test_drag_edge_selection():
	var mesh_data := PBMeshData.create_cube(1.0)
	var editor := PBEditor.new()
	var mesh := PBMesh.new()
	mesh.pb_mesh_data = mesh_data
	add_child_autofree(mesh)
	editor.active_mesh = mesh
	editor.select_mode = PBEditor.SelectMode.EDGE

	# Select edge (0, 1) on Face 0
	editor.selection.set_edges([PBEdge.new(0, 1)])

	var tool := PBToolMove.new()
	tool.editor = editor

	# Centroid of edge (0, 1) between (0.5, -0.5, -0.5) and (-0.5, -0.5, -0.5) is (0, -0.5, -0.5)
	var ok: bool = tool.begin_drag(Vector3(0.0, -0.5, -5.0), Vector3(0.0, 0.0, 1.0))
	assert_true(ok, "begin_drag must succeed in EDGE mode")
	assert_true(tool.get_hit_start().is_equal_approx(Vector3(0.0, -0.5, -0.5)))

	# Drag by (+0.5, +0.5, 0)
	tool.update_drag(Vector3(0.5, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))

	# Endpoint coincident groups [0, 13, 22] and [1, 8, 21] should move by (+0.5, +0.5, 0)
	assert_true(mesh_data.positions[0].is_equal_approx(Vector3(1.0, 0.0, -0.5)), "Edge endpoint 0 must move")
	assert_true(mesh_data.positions[1].is_equal_approx(Vector3(0.0, 0.0, -0.5)), "Edge endpoint 1 must move")

	tool.finish_drag(null)

# ==============================================================================
# 11. Edge Cases & Robustness
# ==============================================================================

func test_parallel_ray_update_ignored():
	var mesh_data := PBMeshData.create_cube(1.0)
	var editor := PBEditor.new()
	var mesh := PBMesh.new()
	mesh.pb_mesh_data = mesh_data
	add_child_autofree(mesh)
	editor.active_mesh = mesh
	editor.select_mode = PBEditor.SelectMode.FACE
	editor.selection.set_faces(PackedInt32Array([0]))

	var tool := PBToolMove.new()
	tool.editor = editor

	tool.begin_drag(Vector3(0.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	tool.update_drag(Vector3(1.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	var c_before: Vector3 = PBMath.average(mesh_data.positions, PackedInt32Array([0, 1, 2, 3]))

	# Update with ray parallel to plane (plane normal is (0, 0, -1), so ray dir (1, 0, 0) is parallel)
	tool.update_drag(Vector3(0.0, 0.0, -0.5), Vector3(1.0, 0.0, 0.0))

	# Position must be unchanged (update ignored)
	var c_after: Vector3 = PBMath.average(mesh_data.positions, PackedInt32Array([0, 1, 2, 3]))
	assert_true(c_after.is_equal_approx(c_before), "Parallel ray update must be ignored without crashing")

	tool.finish_drag(null)

func test_null_safety():
	var tool := PBToolMove.new()
	# Null editor
	assert_false(tool.begin_drag(Vector3.ZERO, Vector3.FORWARD), "Null editor should return false")
	tool.update_drag(Vector3.ZERO, Vector3.FORWARD) # should not crash
	tool.finish_drag(null) # should not crash
	tool.cancel_drag() # should not crash

	# Editor with no mesh
	var editor := PBEditor.new()
	tool.editor = editor
	assert_false(tool.begin_drag(Vector3.ZERO, Vector3.FORWARD), "Null mesh should return false")
