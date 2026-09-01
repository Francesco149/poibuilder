## Tests for PBElementEditor — the runtime-safe element editing logic behind
## the native subgizmo integration (PBGizmoPlugin adapts the editor API).
##
## Covers the Phase 6 regression cluster:
## - drag math composes from the drag-start snapshot (idempotent under the
##   engine delivering one transform per selected id per motion — regression
##   test for the "teleporting cube" bug)
## - commit registers an undo action with exact before/after positions
## - cancel restores pre-drag positions
## - picking by ray and frustum in all three element modes
## - orientation-space bases for the element transform gizmo
##
## PBElementEditor is a plain RefCounted, so all of this runs headless.
extends GutTest

const DEPTH := 400

var _viewport: SubViewport
var _camera: Camera3D

func before_each() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(DEPTH, DEPTH)
	add_child_autofree(_viewport)
	_camera = Camera3D.new()
	_viewport.add_child(_camera)
	_camera.position = Vector3(3, 3, 3)
	_camera.look_at(Vector3.ZERO, Vector3.UP)

func _make_setup(mode: PBEditor.SelectMode) -> Dictionary:
	var ed := PBEditor.new()
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

## Simulates the engine's per-motion loop: for each selected id, deliver the
## same motion's absolute target transform, exactly like
## Node3DEditorViewport::apply_transform does.
func _apply_motion(state: Dictionary, ids: PackedInt32Array, id_to_target: Dictionary) -> void:
	var logic: PBElementEditor = state["logic"]
	var mesh: PBMesh = state["mesh"]
	for id in ids:
		if id_to_target.has(id):
			logic.set_subgizmo_transform(mesh, ids, id, id_to_target[id])

# ==============================================================================
# Transform origin tests
# ==============================================================================

func test_subgizmo_transform_origins_face_mode():
	var s := _make_setup(PBEditor.SelectMode.FACE)
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data

	for fi in range(md.faces.size()):
		var xf: Transform3D = logic.get_subgizmo_transform(md, s["mesh"], fi)
		var expected: Vector3 = logic.element_origin(md, fi)
		assert_eq(xf.origin, expected, "Face %d pivot should be its centroid" % fi)

func test_subgizmo_transform_origins_edge_and_vertex_mode():
	var s := _make_setup(PBEditor.SelectMode.EDGE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data
	var edges := md.get_common_edges()
	assert_eq(edges.size(), 12, "Cube should have 12 common edges")
	var xf: Transform3D = logic.get_subgizmo_transform(md, mesh, 0)
	assert_eq(xf.origin, (md.positions[edges[0].a] + md.positions[edges[0].b]) * 0.5,
		"Edge pivot should be its midpoint")

	var sv := _make_setup(PBEditor.SelectMode.VERTEX)
	var slogic: PBElementEditor = sv["logic"]
	var smesh: PBMesh = sv["mesh"]
	var sv_xf: Transform3D = slogic.get_subgizmo_transform(smesh.pb_mesh_data, smesh, 0)
	var cube_md: PBMeshData = smesh.pb_mesh_data
	assert_eq(sv_xf.origin, cube_md.positions[cube_md.shared_vertices[0].indices[0]],
		"Vertex pivot should be the group position")

# ==============================================================================
# Orientation space tests
# ==============================================================================

func test_element_space_basis_aligned_to_face_normal():
	var s := _make_setup(PBEditor.SelectMode.FACE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data

	# Face 0 is the Z=-h front face → element basis Z should be -Z (its normal)
	var xf: Transform3D = logic.get_subgizmo_transform(md, mesh, 0)
	var normal: Vector3 = PBMath.normal_from_positions(md.positions, md.faces[0].get_indexes())
	assert_true(xf.basis.z.is_equal_approx(normal),
		"ELEMENT space Z axis should equal the face normal")

func test_world_and_object_space_bases():
	var s := _make_setup(PBEditor.SelectMode.FACE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var ed: PBEditor = s["ed"]
	var md: PBMeshData = mesh.pb_mesh_data

	# Rotate the node so spaces differ
	mesh.rotation = Vector3(0.0, rad_to_deg(0.5), rad_to_deg(0.3))

	ed.orientation_space = PBEditor.OrientationSpace.OBJECT
	var obj_xf: Transform3D = logic.get_subgizmo_transform(md, mesh, 0)
	assert_true(obj_xf.basis.is_equal_approx(Basis.IDENTITY),
		"OBJECT space basis should be identity in local space")

	ed.orientation_space = PBEditor.OrientationSpace.WORLD
	var world_xf: Transform3D = logic.get_subgizmo_transform(md, mesh, 0)
	# Displayed world basis = node_basis * local basis → should be ~identity
	var world_display: Basis = mesh.global_transform.basis * world_xf.basis
	assert_true(world_display.is_equal_approx(Basis.IDENTITY),
		"WORLD space should display identity in world space")

	ed.orientation_space = PBEditor.OrientationSpace.ELEMENT
	var elem_xf: Transform3D = logic.get_subgizmo_transform(md, mesh, 0)
	var elem_display: Basis = mesh.global_transform.basis * elem_xf.basis
	var normal: Vector3 = mesh.global_transform.basis * PBMath.normal_from_positions(md.positions, md.faces[0].get_indexes())
	assert_lt((elem_display.z - normal.normalized()).length(), 0.001,
		"ELEMENT space should display the face normal in world space")

# ==============================================================================
# Editing gate
# ==============================================================================

func test_is_editing_gate():
	var s := _make_setup(PBEditor.SelectMode.FACE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var ed: PBEditor = s["ed"]

	assert_true(logic.is_editing_node(mesh), "Editing when mesh is active and mode != OBJECT")
	ed.select_mode = PBEditor.SelectMode.OBJECT
	assert_false(logic.is_editing_node(mesh), "Not editing in OBJECT mode")

	var mesh2 := PBMesh.new()
	add_child_autofree(mesh2)
	ed.select_mode = PBEditor.SelectMode.FACE
	assert_false(logic.is_editing_node(mesh2), "Not editing a different mesh")

# ==============================================================================
# Drag semantics / teleport regression
# ==============================================================================

func test_translate_drag_moves_only_selected_element():
	var s := _make_setup(PBEditor.SelectMode.FACE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data

	var ids := _ids([0])
	var start_positions: PackedVector3Array = md.positions.duplicate()
	var start_xf: Transform3D = logic.get_subgizmo_transform(md, mesh, 0)
	var delta := Vector3(0.25, -0.5, 0.75)
	var target: Transform3D = start_xf.translated(delta)

	# Engine calls _set for EVERY selected id (here one) per motion
	_apply_motion(s, ids, {0: target})

	var moved_indices := {}
	for idx in logic.element_indices(md, 0):
		moved_indices[idx] = true
		assert_lt((md.positions[idx] - (start_positions[idx] + delta)).length(), 0.0001,
			"Selected element vertex %d should move by delta" % idx)

	for i in range(md.positions.size()):
		if not moved_indices.has(i):
			assert_eq(md.positions[i], start_positions[i],
				"Vertex %d belongs to another element and must not move" % i)

func test_drag_is_idempotent_per_motion_no_teleport():
	## REGRESSION: the old hand-rolled tool applied deltas cumulatively and
	## the whole cube could fly away. The engine delivers _set_subgizmo_transform
	## once per selected id; repeated delivery for the same motion must converge.
	var s := _make_setup(PBEditor.SelectMode.FACE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data

	var ids := _ids([0, 1])
	var start_positions: PackedVector3Array = md.positions.duplicate()
	var start0: Transform3D = logic.get_subgizmo_transform(md, mesh, 0)
	var start1: Transform3D = logic.get_subgizmo_transform(md, mesh, 1)
	var delta := Vector3(0.4, 0.2, -0.3)

	# Same motion delivered 5 times must equal one application
	for _i in range(5):
		_apply_motion(s, ids, {0: start0.translated(delta), 1: start1.translated(delta)})

	for i in range(md.positions.size()):
		var moved0: bool = logic.element_indices(md, 0).has(i)
		var moved1: bool = logic.element_indices(md, 1).has(i)
		if moved0 or moved1:
			assert_lt((md.positions[i] - (start_positions[i] + delta)).length(), 0.0001,
				"Vertex %d must be exactly start+delta after repeated delivery" % i)
		else:
			assert_eq(md.positions[i], start_positions[i],
				"Unselected vertex %d must not move" % i)

func test_multi_face_translate_welds_shared_vertices():
	var s := _make_setup(PBEditor.SelectMode.FACE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data
	var ids := _ids([0, 1])

	var start_positions: PackedVector3Array = md.positions.duplicate()
	var starts := {}
	for id in [0, 1]:
		starts[id] = logic.get_subgizmo_transform(md, mesh, id)
	var delta := Vector3(0, 0.5, 0)

	_apply_motion(s, ids, {
		0: starts[0].translated(delta),
		1: starts[1].translated(delta),
	})

	# Vertices shared between faces 0 and 1 must exist and be moved once
	var shared := {}
	for idx in logic.element_indices(md, 0):
		shared[idx] = true
	for idx in logic.element_indices(md, 1):
		shared[idx] = true
	assert_gt(shared.size(), 8, "Two adjacent cube faces should span more than 8 corners")
	for i in range(md.positions.size()):
		if shared.has(i):
			assert_lt((md.positions[i] - (start_positions[i] + delta)).length(), 0.0001)

func test_rotate_drag_rotates_face_about_its_pivot():
	var s := _make_setup(PBEditor.SelectMode.FACE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data

	var ids := _ids([0])
	var start_positions: PackedVector3Array = md.positions.duplicate()
	var start_xf: Transform3D = logic.get_subgizmo_transform(md, mesh, 0)

	# Simulate the engine's rotate composition: new_xf = T(pivot) R T(-pivot) * start_xf
	var angle := 0.4
	var pivot: Vector3 = start_xf.origin
	var rot: Basis = Basis(Vector3.UP, angle)
	var target: Transform3D = Transform3D(rot, pivot) * Transform3D(Basis(), -pivot) * start_xf

	_apply_motion(s, ids, {0: target})

	# Every moved vertex keeps its distance to the pivot (pure rotation).
	for idx in logic.element_indices(md, 0):
		var before: float = (start_positions[idx] - pivot).length()
		var after: float = (md.positions[idx] - pivot).length()
		assert_lt(absf(before - after), 0.0001,
			"Vertex %d should rotate about the pivot at constant radius" % idx)

	# And some vertex must actually have moved (rotation is not a no-op)
	var any_moved := false
	for idx in logic.element_indices(md, 0):
		if (md.positions[idx] - start_positions[idx]).length() > 0.001:
			any_moved = true
	assert_true(any_moved, "Rotation should move face vertices")

func test_commit_registers_undo_with_exact_positions():
	var s := _make_setup(PBEditor.SelectMode.FACE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data

	var fake_undo := FakeUndoManager.new()
	logic.undo = fake_undo

	var ids := _ids([0])
	var start_positions: PackedVector3Array = md.positions.duplicate()
	var start_xf: Transform3D = logic.get_subgizmo_transform(md, mesh, 0)
	var delta := Vector3(0.1, 0.2, 0.3)
	_apply_motion(s, ids, {0: start_xf.translated(delta)})

	logic.commit_subgizmos(mesh, ids, false)

	assert_eq(fake_undo.actions.size(), 1, "Commit should create exactly one undo action")
	assert_eq(fake_undo.actions[0]["do"].size(), fake_undo.actions[0]["undo"].size())
	assert_eq(fake_undo.actions[0]["indices"].size(), fake_undo.actions[0]["do"].size())

	# Do-state matches post-drag; undo-state matches pre-drag
	for i in range(fake_undo.actions[0]["indices"].size()):
		var idx: int = fake_undo.actions[0]["indices"][i]
		assert_lt((fake_undo.actions[0]["do"][i] - (start_positions[idx] + delta)).length(), 0.0001)
		assert_eq(fake_undo.actions[0]["undo"][i], start_positions[idx])

	# Replay undo payload → restores original; replay do → reapplies
	logic._apply_positions(mesh.get_instance_id(), fake_undo.actions[0]["indices"], fake_undo.actions[0]["undo"])
	for i in range(md.positions.size()):
		assert_eq(md.positions[i], start_positions[i], "Undo payload must restore original mesh")
	logic._apply_positions(mesh.get_instance_id(), fake_undo.actions[0]["indices"], fake_undo.actions[0]["do"])
	for idx in logic.element_indices(md, 0):
		assert_lt((md.positions[idx] - (start_positions[idx] + delta)).length(), 0.0001)

func test_commit_without_change_registers_nothing():
	var s := _make_setup(PBEditor.SelectMode.FACE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data
	var fake_undo := FakeUndoManager.new()
	logic.undo = fake_undo

	var ids := _ids([0])
	var start_xf: Transform3D = logic.get_subgizmo_transform(md, mesh, 0)
	_apply_motion(s, ids, {0: start_xf}) # no-op motion
	logic.commit_subgizmos(mesh, ids, false)
	assert_eq(fake_undo.actions.size(), 0, "Zero-delta drag must not pollute undo history")

func test_cancel_restores_positions():
	var s := _make_setup(PBEditor.SelectMode.FACE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data

	var ids := _ids([0])
	var start_positions: PackedVector3Array = md.positions.duplicate()
	var start_xf: Transform3D = logic.get_subgizmo_transform(md, mesh, 0)
	_apply_motion(s, ids, {0: start_xf.translated(Vector3(2, 0, 0))})
	assert_gt((md.positions[0] - start_positions[0]).length(), 1.0, "Preview should move vertices")

	logic.commit_subgizmos(mesh, ids, true)
	for i in range(md.positions.size()):
		assert_eq(md.positions[i], start_positions[i], "Cancel must restore pre-drag mesh")

# ==============================================================================
# Picking tests
# ==============================================================================

func test_ray_pick_faces():
	var s := _make_setup(PBEditor.SelectMode.FACE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]

	var center: Vector2 = _camera.unproject_position(Vector3.ZERO)
	var hit: int = logic.pick_ray(mesh.pb_mesh_data, mesh.global_transform, _camera, center)
	assert_gte(hit, 0, "Face pick at cube center should hit a face")

	# A screen point well to the side of the cube must miss
	var side_point: Vector3 = _camera.to_global(Vector3(5, 0, -2))
	var miss: int = logic.pick_ray(mesh.pb_mesh_data, mesh.global_transform, _camera,
		_camera.unproject_position(side_point))
	assert_eq(miss, -1, "Pick far from the mesh should miss")

func test_frustum_selects_faces():
	var s := _make_setup(PBEditor.SelectMode.FACE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]

	# Frustum covering the whole scene: all 6 faces inside
	var planes: Array[Plane] = [
		Plane(Vector3(1, 0, 0), 10), Plane(Vector3(-1, 0, 0), 10),
		Plane(Vector3(0, 1, 0), 10), Plane(Vector3(0, -1, 0), 10),
		Plane(Vector3(0, 0, 1), 10), Plane(Vector3(0, 0, -1), 10),
	]
	var all_ids: PackedInt32Array = logic.pick_frustum(mesh.pb_mesh_data, mesh.global_transform, planes)
	assert_eq(all_ids.size(), 6, "Whole-scene frustum should select all 6 faces")

	# Half-space y >= 0.25: top face centroids (y=0.5) in, sides (y=0) out.
	# Plane semantics: inside = n·p <= d, so n=(0,-1,0), d=-0.25 → -y <= -0.25.
	var top_only: Array[Plane] = [
		Plane(Vector3(0, -1, 0), -0.25), Plane(Vector3(0, 1, 0), 10),
		Plane(Vector3(1, 0, 0), 10), Plane(Vector3(-1, 0, 0), 10),
		Plane(Vector3(0, 0, 1), 10), Plane(Vector3(0, 0, -1), 10),
	]
	var top_ids: PackedInt32Array = logic.pick_frustum(mesh.pb_mesh_data, mesh.global_transform, top_only)
	assert_eq(top_ids.size(), 1, "Half-space frustum should select the top face only")

func test_frustum_selects_vertices_and_edges():
	var s := _make_setup(PBEditor.SelectMode.VERTEX)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var planes: Array[Plane] = [
		Plane(Vector3(0, -1, 0), -0.25), Plane(Vector3(0, 1, 0), 10),
		Plane(Vector3(1, 0, 0), 10), Plane(Vector3(-1, 0, 0), 10),
		Plane(Vector3(0, 0, 1), 10), Plane(Vector3(0, 0, -1), 10),
	]
	var ids: PackedInt32Array = logic.pick_frustum(mesh.pb_mesh_data, mesh.global_transform, planes)
	assert_eq(ids.size(), 4, "Cube should have 4 top vertex groups")

	var se := _make_setup(PBEditor.SelectMode.EDGE)
	var slogic: PBElementEditor = se["logic"]
	var smesh: PBMesh = se["mesh"]
	var edge_ids: PackedInt32Array = slogic.pick_frustum(smesh.pb_mesh_data, smesh.global_transform, planes)
	assert_eq(edge_ids.size(), 4, "Cube should have 4 top edges")

# ==============================================================================
# Selection mirroring tests
# ==============================================================================

func test_mirror_engine_selection_faces():
	var s := _make_setup(PBEditor.SelectMode.FACE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var ed: PBEditor = s["ed"]
	var md: PBMeshData = mesh.pb_mesh_data

	var changed := logic.mirror_engine_selection(ed.selection, md, _ids([0, 2]))
	assert_true(changed, "Mirroring new ids should report change")
	assert_true(ed.selection.is_face_selected(0), "Face 0 should be mirrored into PBSelection")
	assert_true(ed.selection.is_face_selected(2), "Face 2 should be mirrored into PBSelection")
	assert_eq(ed.selection.selected_face_count(), 2)

	# Same ids again → no change
	changed = logic.mirror_engine_selection(ed.selection, md, _ids([0, 2]))
	assert_false(changed, "Repeated mirror of identical ids should be a no-op")

	# Clearing the engine selection mirrors too
	changed = logic.mirror_engine_selection(ed.selection, md, PackedInt32Array())
	assert_true(changed)
	assert_eq(ed.selection.selected_face_count(), 0, "Clearing engine selection should mirror")

func test_mirror_engine_selection_edges():
	var s := _make_setup(PBEditor.SelectMode.EDGE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var ed: PBEditor = s["ed"]
	var md: PBMeshData = mesh.pb_mesh_data

	logic.mirror_engine_selection(ed.selection, md, _ids([0, 5, 11]))
	assert_eq(ed.selection.selected_edge_count(), 3, "Edge ids should mirror to PBSelection")
	var edges := md.get_common_edges()
	assert_true(ed.selection.is_edge_selected(edges[5]), "Selected edge should match id 5")

# ==============================================================================
# Duck-typed stand-ins
# ==============================================================================

class FakeUndoManager:
	var actions: Array = []
	var _current: Dictionary = {}

	func create_action(_name: String, _merge: int = 0) -> void:
		_current = {"name": _name, "do": PackedVector3Array(), "undo": PackedVector3Array(), "indices": PackedInt32Array()}

	func add_do_method(_obj: Object, method: String, node_id: int, indices: PackedInt32Array, positions: PackedVector3Array) -> void:
		if method == "_apply_positions":
			_current["indices"] = indices
			_current["do"] = positions

	func add_undo_method(_obj: Object, method: String, _node_id: int, _indices: PackedInt32Array, positions: PackedVector3Array) -> void:
		if method == "_apply_positions":
			_current["undo"] = positions

	func commit_action() -> void:
		actions.append(_current)
		_current = {}
