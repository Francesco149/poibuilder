## Tests for the v0.9.0 drag gestures in PBElementEditor:
## - Scale defaults to UNIFORM (locked aspect ratio); shift+scale on
##   non-face selections keeps free scaling (#3)
## - Shift+Move on faces/edges extrudes at drag begin, then the gesture
##   drags ONLY the new caps/fins (#4)
## - Shift+Scale on faces insets uniformly (aspect fixed) (#5/#13)
## - Topology gestures undo via whole-mesh snapshots and cancel restores
extends GutTest

var _viewport: SubViewport
var _camera: Camera3D

func before_each() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(400, 400)
	add_child_autofree(_viewport)
	_camera = Camera3D.new()
	_viewport.add_child(_camera)
	_camera.position = Vector3(3, 3, 3)
	_camera.look_at(Vector3.ZERO, Vector3.UP)

func _make_setup(mode: PBEditor.SelectMode, tool: PBEditor.ToolMode) -> Dictionary:
	var ed := PBEditor.new()
	ed.tool_mode = tool
	var logic := PBElementEditor.new()
	logic.editor = ed
	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)
	ed.active_mesh = mesh
	ed.select_mode = mode
	return {"ed": ed, "logic": logic, "mesh": mesh}

func _ids(ids: Array) -> PackedInt32Array:
	var packed := PackedInt32Array()
	for id in ids:
		packed.append(id)
	return packed

## Drives the engine's per-motion delivery loop (one absolute target per id).
func _motion(s: Dictionary, ids: PackedInt32Array, id_to_target: Dictionary) -> void:
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	for id in ids:
		if id_to_target.has(id):
			logic.set_subgizmo_transform(mesh, ids, id, id_to_target[id])

func _gesture_state(s: Dictionary, ids: PackedInt32Array, shift: bool) -> Dictionary:
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data
	var start_xf := {}
	for id in ids:
		start_xf[id] = logic.get_subgizmo_transform(md, mesh, id)
	return {"logic": logic, "mesh": mesh, "ids": ids, "start": start_xf, "shift": shift}

# ==============================================================================
# Gesture decision
# ==============================================================================

func test_gesture_decision_matrix():
	var s := _make_setup(PBEditor.SelectMode.FACE, PBEditor.ToolMode.SCALE)
	var logic: PBElementEditor = s["logic"]
	var ed: PBEditor = s["ed"]

	assert_eq(logic._decide_gesture(false), PBElementEditor.DragGesture.UNIFORM_SCALE,
		"Scale without shift is UNIFORM (locked aspect ratio)")

	ed.tool_mode = PBEditor.ToolMode.MOVE
	assert_eq(logic._decide_gesture(false), PBElementEditor.DragGesture.NORMAL,
		"Move without shift is NORMAL")
	assert_eq(logic._decide_gesture(true), PBElementEditor.DragGesture.EXTRUDE_MOVE,
		"Shift+Move on faces EXTRUDES")

	ed.select_mode = PBEditor.SelectMode.EDGE
	assert_eq(logic._decide_gesture(true), PBElementEditor.DragGesture.EXTRUDE_MOVE,
		"Shift+Move on edges extrudes fins")

	ed.tool_mode = PBEditor.ToolMode.SCALE
	ed.select_mode = PBEditor.SelectMode.FACE
	assert_eq(logic._decide_gesture(true), PBElementEditor.DragGesture.INSET_SCALE,
		"Shift+Scale on faces INSETS")
	ed.select_mode = PBEditor.SelectMode.VERTEX
	assert_eq(logic._decide_gesture(true), PBElementEditor.DragGesture.NORMAL,
		"Shift+Scale on verts stays free scale (the aspect override)")
	ed.select_mode = PBEditor.SelectMode.EDGE
	assert_eq(logic._decide_gesture(true), PBElementEditor.DragGesture.NORMAL,
		"Shift+Scale on edges stays free scale (the aspect override)")

	ed.tool_mode = PBEditor.ToolMode.ROTATE
	assert_eq(logic._decide_gesture(true), PBElementEditor.DragGesture.NORMAL,
		"Rotate never becomes a topology gesture")

# ==============================================================================
# Uniform scale (#3)
# ==============================================================================

func test_uniform_scale_keeps_aspect_ratio():
	var s := _make_setup(PBEditor.SelectMode.FACE, PBEditor.ToolMode.SCALE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data
	var start_positions := md.positions.duplicate()

	var ids := _ids([0])  # +Y top face
	var start_xf := logic.get_subgizmo_transform(md, mesh, 0)
	# Engine-style axis scale: target = start scaled 2x along the gizmo x.
	var scaled := start_xf
	scaled.basis = start_xf.basis * Basis().scaled(Vector3(2, 1, 1))
	_motion(s, ids, {0: scaled})

	# Every moved vertex must keep its distance RATIO to the pivot: uniform
	# scaling about the face center scales x, y, and z equally.
	var pivot: Vector3 = start_xf.origin
	var checked := 0
	for idx in logic.element_indices(md, 0):
		var before := start_positions[idx] - pivot
		var after: Vector3 = md.positions[idx] - pivot
		if before.length() > 0.0001:
			var ratio: float = after.length() / before.length()
			assert_almost_eq(ratio, 2.0, 0.02,
				"Aspect is locked: every axis scales by the drag factor")
			checked += 1
	assert_gt(checked, 0, "Sanity: vertices actually scaled")

func test_shift_scale_on_verts_stays_free():
	# The documented override: shift+scale on a non-face selection must NOT
	# uniform-scale — decided NORMAL, so rel applies raw (free scaling).
	var s := _make_setup(PBEditor.SelectMode.VERTEX, PBEditor.ToolMode.SCALE)
	var logic: PBElementEditor = s["logic"]
	# The decision is what controls the path (asserted in the matrix above);
	# here we just verify the wiring compiles into a NORMAL drag end-to-end.
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data
	var ids := _ids([0])
	var start_xf := logic.get_subgizmo_transform(md, mesh, 0)
	_motion(s, ids, {0: start_xf.translated(Vector3(0.2, 0, 0))})
	assert_true(logic.drag_active, "A NORMAL drag runs via the plain entry point")

# ==============================================================================
# Shift+Move extrude (#4)
# ==============================================================================

func test_shift_move_extrudes_faces_at_drag_begin():
	var s := _make_setup(PBEditor.SelectMode.FACE, PBEditor.ToolMode.MOVE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data
	var faces_before := md.faces.size()

	var ids := _ids([0])  # front face (z = -0.5)
	var state := _gesture_state(s, ids, true)
	for id in ids:
		logic.set_subgizmo_transform_with_shift(mesh, ids, id,
			state["start"][id].translated(Vector3(0, 0.5, 0)), true)

	assert_eq(md.faces.size(), faces_before + 4,
		"Extruding the front face adds 4 side quads (6→10)")

	# The new cap geometry rose with the drag...
	var ring_intact := false
	var cap_rose := false
	for p in md.positions:
		if absf(p.y - 0.5) < 0.0001 and absf(absf(p.x) - 0.5) < 0.0001 and absf(absf(p.z) - 0.5) < 0.0001:
			ring_intact = true
		if absf(p.y - 1.0) < 0.0001 and absf(p.z + 0.5) < 0.0001:
			cap_rose = true
	assert_true(ring_intact,
		"The original face ring stays put (the gesture drags the new caps, not the mesh)")
	assert_true(cap_rose, "New cap geometry rose with the drag")

	logic.commit_subgizmos(mesh, ids, false)
	assert_eq(md.faces.size(), faces_before + 4, "Commit keeps the extruded topology")

func test_shift_move_extrude_commit_uses_snapshot_undo():
	var s := _make_setup(PBEditor.SelectMode.FACE, PBEditor.ToolMode.MOVE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data
	var fake := GestureUndoSpy.new()
	logic.undo = fake

	var faces_before := md.faces.size()
	var ids := _ids([0])
	var state := _gesture_state(s, ids, true)
	for id in ids:
		logic.set_subgizmo_transform_with_shift(mesh, ids, id,
			state["start"][id].translated(Vector3(0, 0.5, 0)), true)

	logic.commit_subgizmos(mesh, ids, false)
	assert_eq(fake.snapshot_actions.size(), 1,
		"A topology gesture commits ONE whole-mesh snapshot action")
	assert_eq(fake.snapshot_actions[0]["name"], "Extrude (Shift+Move)")

	# Replay undo → pre-gesture mesh (no extrude, original face count).
	logic._restore_full_mesh(mesh.get_instance_id(),
		fake.snapshot_actions[0]["undo_snapshot"])
	assert_eq(md.faces.size(), faces_before, "Undo restores the pre-extrude topology")

func test_shift_move_extrude_cancel_removes_the_extrusion():
	var s := _make_setup(PBEditor.SelectMode.FACE, PBEditor.ToolMode.MOVE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data
	var faces_before := md.faces.size()
	var positions_before := md.positions.duplicate()

	var ids := _ids([0])
	var state := _gesture_state(s, ids, true)
	for id in ids:
		logic.set_subgizmo_transform_with_shift(mesh, ids, id,
			state["start"][id].translated(Vector3(0, 0.5, 0)), true)
	assert_eq(md.faces.size(), faces_before + 4)

	logic.commit_subgizmos(mesh, ids, true)
	assert_eq(md.faces.size(), faces_before, "Cancel un-extrudes completely")
	assert_eq(md.positions.size(), positions_before.size(), "Cancel restores positions")
	for i in range(md.positions.size()):
		assert_eq(md.positions[i], positions_before[i])

func test_shift_move_edges_extrudes_fins():
	var s := _make_setup(PBEditor.SelectMode.EDGE, PBEditor.ToolMode.MOVE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data
	var faces_before := md.faces.size()

	var ids := _ids([2])
	var state := _gesture_state(s, ids, true)
	for id in ids:
		logic.set_subgizmo_transform_with_shift(mesh, ids, id,
			state["start"][id].translated(Vector3(0.5, 0, 0)), true)
	assert_eq(md.faces.size(), faces_before + 1, "Edge extrude adds one fin quad")

	logic.commit_subgizmos(mesh, ids, true)
	assert_eq(md.faces.size(), faces_before, "Cancel removes the fin")

## Minimal undo spy for snapshot payloads (the per-position FakeUndoManager
## in test_pb_element_editor.gd does not match the snapshot signature).
class GestureUndoSpy:
	var snapshot_actions: Array = []

	func create_action(name: String, _merge: int = 0) -> void:
		snapshot_actions.append({"name": name, "do_snapshot": null, "undo_snapshot": null})

	func add_do_method(_obj: Object, method: String, node_id: int, snapshot: PBMeshData) -> void:
		if method == "_restore_full_mesh":
			snapshot_actions[-1]["do_snapshot"] = snapshot
			snapshot_actions[-1]["node_id"] = node_id

	func add_undo_method(_obj: Object, method: String, node_id: int, snapshot: PBMeshData) -> void:
		if method == "_restore_full_mesh":
			snapshot_actions[-1]["undo_snapshot"] = snapshot

	func commit_action() -> void:
		pass

# ==============================================================================
# Shift+Scale inset (#5 / #13)
# ==============================================================================

func test_shift_scale_insets_faces_uniformly():
	var s := _make_setup(PBEditor.SelectMode.FACE, PBEditor.ToolMode.SCALE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data
	var faces_before := md.faces.size()

	var ids := _ids([0])
	var state := _gesture_state(s, ids, true)
	# Scale gesture: 0.5x along the gizmo x → inset amount 0.5.
	for id in ids:
		var target: Transform3D = state["start"][id]
		target.basis = state["start"][id].basis * Basis().scaled(Vector3(0.5, 1, 1))
		logic.set_subgizmo_transform_with_shift(mesh, ids, id, target, true)

	assert_eq(md.faces.size(), faces_before + 4,
		"The seeded inset adds one ring quad per face edge (6 → 10)")

	# Uniform inset: the gesture's union override lists the inner face's
	# corners — every corner sits at the SAME radius from the face centroid
	# (aspect ratio fixed), whatever the drag factor was.
	var inner_positions: Array[Vector3] = []
	for idx in logic._drag_union_override:
		inner_positions.append(md.positions[idx])
	assert_eq(inner_positions.size(), 4, "The union is the inner face's four corners")
	var centroid := Vector3.ZERO
	for p in inner_positions:
		centroid += p
	centroid /= float(inner_positions.size())
	var first_radius: float = (inner_positions[0] - centroid).length()
	for p in inner_positions:
		assert_almost_eq((p - centroid).length(), first_radius, 0.01,
			"Aspect ratio fixed: all corners sit at the same inset radius")
	assert_almost_eq(first_radius, 0.7071 * 0.5, 0.03,
		"A 0.5 drag factor insets by 0.5 (halfway to the centroid)")

	logic.commit_subgizmos(mesh, ids, true)
	assert_eq(md.faces.size(), faces_before, "Cancel un-insets completely")

func test_inset_gesture_commit_uses_snapshot_undo():
	var s := _make_setup(PBEditor.SelectMode.FACE, PBEditor.ToolMode.SCALE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data
	var fake := GestureUndoSpy.new()
	logic.undo = fake
	var faces_before := md.faces.size()

	var ids := _ids([0])
	var state := _gesture_state(s, ids, true)
	for id in ids:
		var target: Transform3D = state["start"][id]
		target.basis = state["start"][id].basis * Basis().scaled(Vector3(0.5, 1, 1))
		logic.set_subgizmo_transform_with_shift(mesh, ids, id, target, true)
	logic.commit_subgizmos(mesh, ids, false)

	assert_eq(fake.snapshot_actions.size(), 1, "Inset commits one snapshot action")
	assert_eq(fake.snapshot_actions[0]["name"], "Inset (Shift+Scale)")
	logic._restore_full_mesh(mesh.get_instance_id(), fake.snapshot_actions[0]["undo_snapshot"])
	assert_eq(md.faces.size(), faces_before, "Undo restores the pre-inset topology")
