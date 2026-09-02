## Tests for the v0.9.x drag gestures in PBElementEditor:
## - Engine scale drags (axis/plane handles) are FREE; uniform scaling and
##   inset live on the CENTER scale handle (ProBuilder-style center square)
## - Shift+Move on faces/edges extrudes at drag begin, then the gesture
##   drags ONLY the new caps/fins (#4)
## - Shift+center-handle on faces insets uniformly (aspect fixed) (#5/#13)
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

	# Engine-delivered scale drags (axis/plane handles) are ALWAYS free —
	# uniform scaling lives on the CENTER handle, not on forced ratios.
	assert_eq(logic._decide_gesture(false), PBElementEditor.DragGesture.NORMAL,
		"Scale via engine handles stays free (no ratio constraint)")

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
	assert_eq(logic._decide_gesture(true), PBElementEditor.DragGesture.NORMAL,
		"Shift+axis-scale is free (inset lives on the center handle)")

	ed.tool_mode = PBEditor.ToolMode.ROTATE
	assert_eq(logic._decide_gesture(true), PBElementEditor.DragGesture.NORMAL,
		"Rotate never becomes a topology gesture")

# ==============================================================================
# Center scale handle: uniform scale (the ProBuilder-style center square)
# ==============================================================================

func test_center_drag_uniform_scales_about_pivot():
	var s := _make_setup(PBEditor.SelectMode.FACE, PBEditor.ToolMode.SCALE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data
	var start_positions := md.positions.duplicate()

	var ids := _ids([0])
	var pivot := logic.center_pivot(md, ids)
	assert_true(logic.begin_center_drag(mesh, ids, false, pivot, Vector2(200, 200)),
		"Center drag begins over a selection")
	assert_true(logic.center_drag_active())

	# Drag LEFT 100px → factor 1 - (-100 * 0.01) = 2x scale.
	logic.apply_center_drag(mesh, _camera, Vector2(100, 200))

	var checked := 0
	for idx in logic.element_indices(md, 0):
		var before := start_positions[idx] - pivot
		var after: Vector3 = md.positions[idx] - pivot
		if before.length() > 0.0001:
			assert_almost_eq(after.length() / before.length(), 2.0, 0.02,
				"The center handle scales ALL axes together about the pivot")
			checked += 1
	assert_gt(checked, 0, "Sanity: vertices actually scaled")

	assert_true(logic.commit_center_drag(mesh, ids, false))
	assert_eq(md.faces.size(), 6, "Uniform scale commit keeps topology")

func test_center_drag_factor_tracks_horizontal_delta():
	var s := _make_setup(PBEditor.SelectMode.FACE, PBEditor.ToolMode.SCALE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data
	var start_positions := md.positions.duplicate()

	var ids := _ids([0])
	var pivot := logic.center_pivot(md, ids)
	# Drag RIGHT 50px → factor 1 - (50 * 0.01) = 0.5 (half size).
	logic.begin_center_drag(mesh, ids, false, pivot, Vector2(200, 200))
	logic.apply_center_drag(mesh, _camera, Vector2(250, 200))

	for idx in logic.element_indices(md, 0):
		var before := start_positions[idx] - pivot
		if before.length() > 0.0001:
			var after: Vector3 = md.positions[idx] - pivot
			assert_almost_eq(after.length() / before.length(), 0.5, 0.02,
				"Drag right = smaller (ProBuilder center handle, 1% per pixel)")

	# A fresh drag LEFT of the start grows the shape instead — and a drag
	# starting dead-on the handle can never explode (no division involved).
	logic.commit_center_drag(mesh, ids, true)
	logic.begin_center_drag(mesh, ids, false, pivot, Vector2(200, 200))
	logic.apply_center_drag(mesh, _camera, Vector2(100, 200))
	for idx in logic.element_indices(md, 0):
		var before := start_positions[idx] - pivot
		if before.length() > 0.0001:
			var after: Vector3 = md.positions[idx] - pivot
			assert_almost_eq(after.length() / before.length(), 2.0, 0.02,
				"Drag left = bigger")

func test_center_drag_scale_commit_uses_position_undo():
	var s := _make_setup(PBEditor.SelectMode.FACE, PBEditor.ToolMode.SCALE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data
	var fake := GestureUndoSpy.new()
	logic.undo = fake

	var ids := _ids([0])
	var pivot := logic.center_pivot(md, ids)
	logic.begin_center_drag(mesh, ids, false, pivot, Vector2(200, 200))
	logic.apply_center_drag(mesh, _camera, Vector2(260, 200))
	assert_true(logic.commit_center_drag(mesh, ids, false))

	assert_eq(fake.actions.size(), 1, "Exactly one undo action")
	assert_null(fake.actions[0]["do_snapshot"],
		"Uniform scale rewrites no topology — per-position undo, not snapshots")
	assert_eq(fake.actions[0]["position_indices"].size(), 12,
		"The payload covers the face's corners expanded through weld groups "
		+ "(4 corners x 3 adjacent face copies)")
	assert_eq(md.faces.size(), 6)

func test_center_drag_cancel_restores_positions():
	var s := _make_setup(PBEditor.SelectMode.FACE, PBEditor.ToolMode.SCALE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data
	var start_positions := md.positions.duplicate()

	var ids := _ids([0])
	var pivot := logic.center_pivot(md, ids)
	logic.begin_center_drag(mesh, ids, false, pivot, Vector2(200, 200))
	logic.apply_center_drag(mesh, _camera, Vector2(300, 200))
	logic.commit_center_drag(mesh, ids, true)

	for i in range(md.positions.size()):
		assert_eq(md.positions[i], start_positions[i], "Cancel restores the mesh")

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

func test_shift_move_crossing_zero_flips_side_winding():
	# Dragging the cap back through its base plane must flip the side quads'
	# winding (they were wound for the original extrude direction at drag
	# begin), or they render inside-out — "missing faces".
	var s := _make_setup(PBEditor.SelectMode.FACE, PBEditor.ToolMode.MOVE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data

	var ids := _ids([4])  # top face (y = +0.5)
	var state := _gesture_state(s, ids, true)
	# Extrude +Y, then reverse through the base and out the bottom.
	var targets := [0.5, 1.0, 0.25, -0.3, -1.0, -1.6]
	for t in targets:
		for id in ids:
			logic.set_subgizmo_transform_with_shift(mesh, ids, id,
				state["start"][id].translated(Vector3(0, t, 0)), true)

	var vol := _signed_volume(md)
	assert_gt(vol, 0.5,
		"Crossing zero keeps every side face outward-facing (signed volume stays positive)")

	logic.commit_subgizmos(mesh, ids, false)

## Divergence-theorem volume over the internal CCW triangles: positive for a
## closed outward-oriented surface; inverted faces cancel it toward zero.
static func _signed_volume(md: PBMeshData) -> float:
	var p := md.positions
	var vol := 0.0
	for face in md.faces:
		if face == null:
			continue
		var idxs := face.get_indexes()
		for t in range(0, idxs.size() - 2, 3):
			vol += p[idxs[t]].dot(p[idxs[t + 1]].cross(p[idxs[t + 2]]))
	return vol / 6.0

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
	assert_eq(fake.actions.size(), 1,
		"A topology gesture commits ONE whole-mesh snapshot action")
	assert_eq(fake.actions[0]["name"], "Extrude (Shift+Move)")

	# Replay undo → pre-gesture mesh (no extrude, original face count).
	logic._restore_full_mesh(mesh.get_instance_id(),
		fake.actions[0]["undo_snapshot"])
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

## Undo spy covering BOTH payload shapes: whole-mesh snapshots
## (_restore_full_mesh) and per-position payloads (_apply_positions).
class GestureUndoSpy:
	var actions: Array = []

	func _current() -> Dictionary:
		return actions[-1] if not actions.is_empty() else {}

	func create_action(name: String, _merge: int = 0, _context: Object = null) -> void:
		actions.append({"name": name, "do_snapshot": null, "undo_snapshot": null,
			"position_indices": PackedInt32Array()})

	func add_do_method(_obj: Object, method: String, a = null, b = null, c = null) -> void:
		if method == "_restore_full_mesh":
			_current()["do_snapshot"] = b
		elif method == "_apply_positions":
			_current()["position_indices"] = b

	func add_undo_method(_obj: Object, method: String, a = null, b = null, c = null) -> void:
		if method == "_restore_full_mesh":
			_current()["undo_snapshot"] = b

	func commit_action() -> void:
		pass

	func snapshot_actions() -> Array:
		return actions

# ==============================================================================
# Center handle + Shift on faces: uniform inset (#5 / #13)
# ==============================================================================

func test_center_drag_with_shift_insets_faces_uniformly():
	var s := _make_setup(PBEditor.SelectMode.FACE, PBEditor.ToolMode.SCALE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data
	var faces_before := md.faces.size()

	var ids := _ids([0])
	var pivot := logic.center_pivot(md, ids)
	assert_true(logic.begin_center_drag(mesh, ids, true, pivot, Vector2(200, 200)))
	assert_eq(md.faces.size(), faces_before + 4,
		"The seeded inset adds one ring quad per face edge (6 → 10)")

	# Drag RIGHT 50px → factor 0.5 → inset amount 0.5: the inner face's
	# corners sit halfway to the centroid, ALL at the same radius (aspect
	# ratio fixed).
	logic.apply_center_drag(mesh, _camera, Vector2(250, 200))

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
		"A 50px right drag insets by 0.5 (halfway to the centroid)")

	logic.commit_center_drag(mesh, ids, true)
	assert_eq(md.faces.size(), faces_before, "Cancel un-insets completely")

func pivot_screen_of(mesh: PBMesh, pivot: Vector3) -> Vector2:
	return _camera.unproject_position(mesh.global_transform * pivot)

func test_center_drag_inset_commit_uses_snapshot_undo():
	var s := _make_setup(PBEditor.SelectMode.FACE, PBEditor.ToolMode.SCALE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data
	var fake := GestureUndoSpy.new()
	logic.undo = fake
	var faces_before := md.faces.size()

	var ids := _ids([0])
	var pivot := logic.center_pivot(md, ids)
	logic.begin_center_drag(mesh, ids, true, pivot, Vector2(200, 200))
	logic.apply_center_drag(mesh, _camera, Vector2(170, 170))
	assert_true(logic.commit_center_drag(mesh, ids, false))

	assert_eq(fake.actions.size(), 1, "Inset commits one snapshot action")
	assert_eq(fake.actions[0]["name"], "Inset (Shift+Scale)")
	logic._restore_full_mesh(mesh.get_instance_id(), fake.actions[0]["undo_snapshot"])
	assert_eq(md.faces.size(), faces_before, "Undo restores the pre-inset topology")
