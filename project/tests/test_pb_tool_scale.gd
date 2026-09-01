## Tests for Phase 6 (IU P6-05): Scale Tool (PBToolScale)
##
## Tests PBToolScale viewport drag scaling with snapshot-once live preview,
## undo/redo, uniform scaling relative to centroid, ray-plane intersection,
## and mode constraints.
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
# 1. PBToolScale Base & Initial State Tests
# ==============================================================================

func test_tool_name_and_initial_state():
	var tool := PBToolScale.new()
	assert_eq(tool.tool_name(), "Scale", "PBToolScale tool name should be 'Scale'")
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

	var tool := PBToolScale.new()
	tool.editor = editor

	var ok: bool = tool.begin_drag(Vector3(0.5, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	assert_false(ok, "begin_drag must return false when selection is empty")
	assert_false(tool.is_dragging(), "Tool must not be dragging")
	assert_eq(tool.state, PBTool.State.IDLE)

func test_begin_drag_false_in_object_mode():
	var mesh_data := PBMeshData.create_cube(1.0)
	var editor := PBEditor.new()
	var mesh := PBMesh.new()
	mesh.pb_mesh_data = mesh_data
	add_child_autofree(mesh)
	editor.active_mesh = mesh

	editor.selection.set_faces(PackedInt32Array([0]))
	editor.select_mode = PBEditor.SelectMode.OBJECT

	var tool := PBToolScale.new()
	tool.editor = editor

	var ok: bool = tool.begin_drag(Vector3(0.5, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	assert_false(ok, "begin_drag must return false in OBJECT select mode")
	assert_false(tool.is_dragging())
	assert_eq(tool.state, PBTool.State.IDLE)

# ==============================================================================
# 2. Face Selection Drag, Live Preview & Scaling Invariants
# ==============================================================================

func test_scale_face_0_drag_and_invariants():
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

	var tool := PBToolScale.new()
	tool.editor = editor

	# Begin ray: origin (0.5, 0, -5), dir (0, 0, 1) -> hits (0.5, 0, -0.5); d0 = 0.5 from centroid (0, 0, -0.5)
	var ok: bool = tool.begin_drag(Vector3(0.5, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	assert_true(ok, "begin_drag must return true for valid face selection")
	assert_true(tool.is_dragging(), "Tool must be in DRAGGING state")
	assert_eq(tool.state, PBTool.State.DRAGGING)
	assert_true(tool.get_hit_start().is_equal_approx(Vector3(0.5, 0.0, -0.5)), "Drag start hit should be at (0.5, 0, -0.5)")
	assert_true(tool.get_world_centroid().is_equal_approx(Vector3(0.0, 0.0, -0.5)), "World centroid should be (0, 0, -0.5)")

	# Update ray: origin (1.0, 0, -5), dir (0, 0, 1) -> hits (1.0, 0, -0.5); d1 = 1.0; factor = 2.0
	tool.update_drag(Vector3(1.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))

	var scaled_indices: PackedInt32Array = tool.get_command().indices
	assert_eq(scaled_indices.size(), 12, "Face 0 should resolve to 12 coincident vertices")

	# Invariant 1: Centroid must remain unchanged after scaling
	var new_centroid: Vector3 = PBMath.average(mesh_data.positions, scaled_indices)
	assert_true(new_centroid.is_equal_approx(initial_centroid),
		"Face 0 centroid after scaling must remain (0, 0, -0.5), got %s" % str(new_centroid))

	# Invariant 2: Distances from vertices to centroid must double (factor = 2.0)
	# Original vertex 0: (0.5, -0.5, -0.5) -> new: (1.0, -1.0, -0.5)
	assert_true(mesh_data.positions[0].is_equal_approx(Vector3(1.0, -1.0, -0.5)),
		"Vertex 0 must scale to (1.0, -1.0, -0.5), got %s" % str(mesh_data.positions[0]))
	# Original vertex 1: (-0.5, -0.5, -0.5) -> new: (-1.0, -1.0, -0.5)
	assert_true(mesh_data.positions[1].is_equal_approx(Vector3(-1.0, -1.0, -0.5)),
		"Vertex 1 must scale to (-1.0, -1.0, -0.5), got %s" % str(mesh_data.positions[1]))
	# Original vertex 2: (-0.5, 0.5, -0.5) -> new: (-1.0, 1.0, -0.5)
	assert_true(mesh_data.positions[2].is_equal_approx(Vector3(-1.0, 1.0, -0.5)),
		"Vertex 2 must scale to (-1.0, 1.0, -0.5), got %s" % str(mesh_data.positions[2]))
	# Original vertex 3: (0.5, 0.5, -0.5) -> new: (1.0, 1.0, -0.5)
	assert_true(mesh_data.positions[3].is_equal_approx(Vector3(1.0, 1.0, -0.5)),
		"Vertex 3 must scale to (1.0, 1.0, -0.5), got %s" % str(mesh_data.positions[3]))

	# Invariant 3: Face 1 (Back face, Z = +0.5, vertices 4-7) must remain unchanged
	assert_true(mesh_data.positions[4].is_equal_approx(Vector3(-0.5, -0.5, 0.5)), "Face 1 vertex 4 must be unchanged")
	assert_true(mesh_data.positions[5].is_equal_approx(Vector3(0.5, -0.5, 0.5)), "Face 1 vertex 5 must be unchanged")
	assert_true(mesh_data.positions[6].is_equal_approx(Vector3(0.5, 0.5, 0.5)), "Face 1 vertex 6 must be unchanged")
	assert_true(mesh_data.positions[7].is_equal_approx(Vector3(-0.5, 0.5, 0.5)), "Face 1 vertex 7 must be unchanged")

# ==============================================================================
# 3. Finish Drag (Commit) & Cancel Drag (Revert)
# ==============================================================================

func test_finish_drag_keeps_scaled_positions():
	var mesh_data := PBMeshData.create_cube(1.0)
	var editor := PBEditor.new()
	var mesh := PBMesh.new()
	mesh.pb_mesh_data = mesh_data
	add_child_autofree(mesh)
	editor.active_mesh = mesh
	editor.select_mode = PBEditor.SelectMode.FACE
	editor.selection.set_faces(PackedInt32Array([0]))

	var tool := PBToolScale.new()
	tool.editor = editor

	tool.begin_drag(Vector3(0.5, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	tool.update_drag(Vector3(1.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))

	var v0_preview: Vector3 = mesh_data.positions[0]

	tool.finish_drag(null)

	assert_false(tool.is_dragging(), "Tool must be IDLE after finish_drag")
	assert_eq(tool.state, PBTool.State.IDLE)
	assert_true(mesh_data.positions[0].is_equal_approx(v0_preview), "Scaled positions must persist after finish_drag")

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

	var tool := PBToolScale.new()
	tool.editor = editor

	tool.begin_drag(Vector3(0.5, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	tool.update_drag(Vector3(1.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))

	# Cancel the drag
	tool.cancel_drag()

	assert_false(tool.is_dragging(), "Tool must be IDLE after cancel_drag")
	assert_eq(tool.state, PBTool.State.IDLE)

	for i in range(mesh_data.positions.size()):
		assert_true(mesh_data.positions[i].is_equal_approx(original_positions[i]),
			"Vertex %d must match pre-drag snapshot after cancel_drag" % i)

# ==============================================================================
# 4. Two Updates Not Stacked & Identity Update
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

	var tool := PBToolScale.new()
	tool.editor = editor

	# Start at (0.5, 0, -5) -> d0 = 0.5
	tool.begin_drag(Vector3(0.5, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))

	# First update: ray at (1.0, 0, -5) -> d1 = 1.0 -> factor = 2.0
	tool.update_drag(Vector3(1.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	assert_true(mesh_data.positions[0].is_equal_approx(Vector3(1.0, -1.0, -0.5)),
		"After 2x scale, vertex 0 should be at (1.0, -1.0, -0.5)")

	# Second update: ray at (1.5, 0, -5) -> d2 = 1.5 -> factor = 3.0 from start (not 2.0 * 3.0 = 6.0)
	tool.update_drag(Vector3(1.5, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	assert_true(mesh_data.positions[0].is_equal_approx(Vector3(1.5, -1.5, -0.5)),
		"After 3x scale from start, vertex 0 must be (1.5, -1.5, -0.5) not stacked (3.0, -3.0, -0.5), got %s" % str(mesh_data.positions[0]))

	# Third update: ray at (0.25, 0, -5) -> d3 = 0.25 -> factor = 0.5
	tool.update_drag(Vector3(0.25, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	assert_true(mesh_data.positions[0].is_equal_approx(Vector3(0.25, -0.25, -0.5)),
		"After 0.5x scale, vertex 0 should be at (0.25, -0.25, -0.5)")

	tool.finish_drag(null)

func test_identity_update_positions_unchanged():
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions: PackedVector3Array = mesh_data.positions.duplicate()

	var editor := PBEditor.new()
	var mesh := PBMesh.new()
	mesh.pb_mesh_data = mesh_data
	add_child_autofree(mesh)
	editor.active_mesh = mesh
	editor.select_mode = PBEditor.SelectMode.FACE
	editor.selection.set_faces(PackedInt32Array([0]))

	var tool := PBToolScale.new()
	tool.editor = editor

	tool.begin_drag(Vector3(0.5, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	# Update at same hit point as start (factor = 1.0)
	tool.update_drag(Vector3(0.5, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))

	for i in range(mesh_data.positions.size()):
		assert_true(mesh_data.positions[i].is_equal_approx(original_positions[i]),
			"Positions must be unchanged after identity scale update")

	tool.finish_drag(null)

# ==============================================================================
# 5. Logger Integration
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

	var tool := PBToolScale.new()
	tool.editor = editor
	tool.logger = logger

	tool.begin_drag(Vector3(0.5, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	tool.update_drag(Vector3(1.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	tool.finish_drag(null)

	var tool_entries: Array = logger.get_entries_by_category("tools")
	var undo_entries: Array = logger.get_entries_by_category("undo")

	assert_gt(tool_entries.size(), 0, "Logger must have entries under 'tools' category")
	assert_gt(undo_entries.size(), 0, "Logger must have entries under 'undo' category from CmdScaleElements")

# ==============================================================================
# 6. UndoRedo Manager Integration via finish_drag(undo)
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

	var tool := PBToolScale.new()
	tool.editor = editor

	tool.begin_drag(Vector3(0.5, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	tool.update_drag(Vector3(1.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	var scaled_pos_0: Vector3 = mesh_data.positions[0]

	tool.finish_drag(fake_undo)

	assert_eq(fake_undo.actions.size(), 1, "One undo action should be committed")
	assert_eq(fake_undo.actions[0]["name"], "Scale Elements")

	# Test undo
	fake_undo.undo()
	assert_true(mesh_data.positions[0].is_equal_approx(Vector3(0.5, -0.5, -0.5)), "Undo should restore initial vertex 0 position")

	# Test redo
	fake_undo.redo()
	assert_true(mesh_data.positions[0].is_equal_approx(scaled_pos_0), "Redo should reapply scaled vertex 0 position")

# ==============================================================================
# 7. Vertex & Edge Mode Dragging
# ==============================================================================

func test_drag_vertex_selection():
	var mesh_data := PBMeshData.create_cube(1.0)
	var editor := PBEditor.new()
	var mesh := PBMesh.new()
	mesh.pb_mesh_data = mesh_data
	add_child_autofree(mesh)
	editor.active_mesh = mesh
	editor.select_mode = PBEditor.SelectMode.VERTEX
	editor.selection.set_vertices(PackedInt32Array([0, 1]))

	var tool := PBToolScale.new()
	tool.editor = editor

	# Ray aimed at (0, 0.5, -5) -> hits (0, 0.5, -0.5)
	var ok: bool = tool.begin_drag(Vector3(0.0, 0.5, -5.0), Vector3(0.0, 0.0, 1.0))
	assert_true(ok, "begin_drag must succeed in VERTEX mode")

	tool.update_drag(Vector3(0.0, 1.0, -5.0), Vector3(0.0, 0.0, 1.0))
	tool.finish_drag(null)

	assert_false(tool.is_dragging())

func test_drag_edge_selection():
	var mesh_data := PBMeshData.create_cube(1.0)
	var editor := PBEditor.new()
	var mesh := PBMesh.new()
	mesh.pb_mesh_data = mesh_data
	add_child_autofree(mesh)
	editor.active_mesh = mesh
	editor.select_mode = PBEditor.SelectMode.EDGE
	editor.selection.set_edges([PBEdge.new(0, 1)])

	var tool := PBToolScale.new()
	tool.editor = editor

	var ok: bool = tool.begin_drag(Vector3(0.0, 0.5, -5.0), Vector3(0.0, 0.0, 1.0))
	assert_true(ok, "begin_drag must succeed in EDGE mode")

	tool.update_drag(Vector3(0.0, 1.0, -5.0), Vector3(0.0, 0.0, 1.0))
	tool.finish_drag(null)

	assert_false(tool.is_dragging())

# ==============================================================================
# 8. Edge Cases & Robustness
# ==============================================================================

func test_centroid_hit_start_zero_d0_ignored():
	var mesh_data := PBMeshData.create_cube(1.0)
	var original_positions: PackedVector3Array = mesh_data.positions.duplicate()

	var editor := PBEditor.new()
	var mesh := PBMesh.new()
	mesh.pb_mesh_data = mesh_data
	add_child_autofree(mesh)
	editor.active_mesh = mesh
	editor.select_mode = PBEditor.SelectMode.FACE
	editor.selection.set_faces(PackedInt32Array([0]))

	var tool := PBToolScale.new()
	tool.editor = editor

	# Begin at exact centroid (0, 0, -0.5) -> d0 is 0.0
	tool.begin_drag(Vector3(0.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	# Update at (1, 0, -5) -> should be ignored because d0 is 0
	tool.update_drag(Vector3(1.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))

	for i in range(mesh_data.positions.size()):
		assert_true(mesh_data.positions[i].is_equal_approx(original_positions[i]),
			"Position %d must remain unchanged when begin hit is at exact centroid" % i)

	tool.finish_drag(null)

func test_parallel_ray_update_ignored():
	var mesh_data := PBMeshData.create_cube(1.0)
	var editor := PBEditor.new()
	var mesh := PBMesh.new()
	mesh.pb_mesh_data = mesh_data
	add_child_autofree(mesh)
	editor.active_mesh = mesh
	editor.select_mode = PBEditor.SelectMode.FACE
	editor.selection.set_faces(PackedInt32Array([0]))

	var tool := PBToolScale.new()
	tool.editor = editor

	tool.begin_drag(Vector3(0.5, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	tool.update_drag(Vector3(1.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	var c_before: Vector3 = PBMath.average(mesh_data.positions, PackedInt32Array([0, 1, 2, 3]))

	# Parallel ray: plane normal is (0, 0, -1), ray dir (1, 0, 0)
	tool.update_drag(Vector3(0.0, 0.0, -0.5), Vector3(1.0, 0.0, 0.0))

	var c_after: Vector3 = PBMath.average(mesh_data.positions, PackedInt32Array([0, 1, 2, 3]))
	assert_true(c_after.is_equal_approx(c_before), "Parallel ray update must be ignored without crashing")

	tool.finish_drag(null)

func test_null_safety():
	var tool := PBToolScale.new()
	assert_false(tool.begin_drag(Vector3.ZERO, Vector3.FORWARD), "Null editor should return false")
	tool.update_drag(Vector3.ZERO, Vector3.FORWARD)
	tool.finish_drag(null)
	tool.cancel_drag()

	var editor := PBEditor.new()
	tool.editor = editor
	assert_false(tool.begin_drag(Vector3.ZERO, Vector3.FORWARD), "Null mesh should return false")
