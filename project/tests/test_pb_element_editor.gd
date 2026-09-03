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
	s["ed"].tool_mode = PBEditor.ToolMode.ROTATE
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

	func create_action(_name: String, _merge: int = 0, _context: Object = null) -> void:
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

# ==============================================================================
# Regression: vertex-mode id semantics (the "moves a different vert" bug)
# ==============================================================================

func test_vertex_drag_moves_the_selected_corner_not_a_neighbor():
	## Subgizmo ids in VERTEX mode are shared-vertex GROUP indices. The old
	## code passed the group id to get_coincident_vertices* which looked it up
	## as a POSITION index — moving a different corner than the gizmo showed.
	var s := _make_setup(PBEditor.SelectMode.VERTEX)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data

	var ids := _ids([0]) # group 0 == positions [1, 8, 21], corner (-h,-h,-h)
	var start_positions: PackedVector3Array = md.positions.duplicate()
	var start_xf: Transform3D = logic.get_subgizmo_transform(md, mesh, 0)
	var delta := Vector3(0.3, 0.2, -0.4)

	_apply_motion(s, ids, {0: start_xf.translated(delta)})

	# The gizmo sat at group 0's position — group 0's members must move
	var group0: PackedInt32Array = md.shared_vertices[0].indices
	for idx in group0:
		assert_lt((md.positions[idx] - (start_positions[idx] + delta)).length(), 0.0001,
			"Group 0 vertex %d must move by the drag delta" % idx)

	# The corner whose POSITION INDEX equals the group id must NOT move
	# (old bug: positions [0,13,22] moved instead)
	for idx in md.shared_vertices[1].indices:
		assert_eq(md.positions[idx], start_positions[idx],
			"Group 1 vertex %d must not move when dragging group 0" % idx)

	# Exactly one corner (3 welded positions) moved
	var moved := 0
	for i in range(md.positions.size()):
		if not md.positions[i].is_equal_approx(start_positions[i]):
			moved += 1
	assert_eq(moved, 3, "Exactly one welded corner (3 positions) must move")

func test_vertex_origin_matches_group_not_position_lookup():
	var s := _make_setup(PBEditor.SelectMode.VERTEX)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data

	# The gizmo origin for group id must be the group's own position
	for g in range(md.shared_vertices.size()):
		var origin: Vector3 = logic.element_origin(md, g)
		var expected: Vector3 = md.positions[md.shared_vertices[g].indices[0]]
		assert_eq(origin, expected, "Group %d gizmo origin must be its own corner" % g)

# ==============================================================================
# Regression: depth tie-break in picking (hidden far-side elements)
# ==============================================================================

func test_vertex_pick_prefers_near_corner_when_projected_together():
	## Camera looks along the cube's diagonal: corners (h,h,h) and (-h,-h,-h)
	## project to the SAME screen point. The visible near corner must win.
	var s := _make_setup(PBEditor.SelectMode.VERTEX)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]

	var center: Vector2 = _camera.unproject_position(Vector3.ZERO)
	var result: PBPicking.VertexPickResult = PBPicking.pick_vertex(
		mesh.pb_mesh_data, mesh.global_transform, center, _camera)

	# Group [6,15,18] is corner (+h,+h,+h) — the near one
	var near_group: int = -1
	for g in range(mesh.pb_mesh_data.shared_vertices.size()):
		if mesh.pb_mesh_data.shared_vertices[g].indices.has(6):
			near_group = g
			break
	assert_eq(result.common_index, near_group,
		"Pick at screen center must return the NEAR corner group, not the far one")

func test_edge_pick_prefers_near_edge_when_projected_together():
	## Two stacked quads viewed with an ORTHOGONAL camera project identically.
	## The far quad is FIRST in the face list, so the old "first wins" behavior
	## returned the hidden far edge; depth tie-break must return the near one.
	var ed := PBEditor.new()
	var logic := PBElementEditor.new()
	logic.editor = ed
	ed.select_mode = PBEditor.SelectMode.EDGE

	# Quad A (far, listed first) at z=-1; quad B (near) at z=+1
	var md := PBMeshData.new()
	md.positions = PackedVector3Array([
		Vector3(-0.5, -0.5, -1), Vector3(0.5, -0.5, -1), Vector3(0.5, 0.5, -1), Vector3(-0.5, 0.5, -1),
		Vector3(-0.5, -0.5, 1), Vector3(0.5, -0.5, 1), Vector3(0.5, 0.5, 1), Vector3(-0.5, 0.5, 1),
	])
	var faces: Array[PBFace] = []
	for base in [0, 4]:
		faces.append(PBFace.new(PackedInt32Array([
			base + 0, base + 1, base + 2,
			base + 2, base + 3, base + 0,
		])))
	md.faces = faces
	# One shared-vertex group per position (no welds)
	var groups: Array[PBSharedVertex] = []
	for i in range(8):
		groups.append(PBSharedVertex.new(PackedInt32Array([i])))
	md.shared_vertices = groups
	md.invalidate_caches()

	var mesh := PBMesh.new()
	mesh.pb_mesh_data = md
	add_child_autofree(mesh)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 4.0
	_viewport.add_child(cam)
	cam.position = Vector3(0, 0, 5)
	cam.look_at(Vector3.ZERO, Vector3.UP)

	# Click at the projection of the top edge — both quads' top edges project there
	var click: Vector2 = cam.unproject_position(Vector3(0, 0.5, 0))
	var result: PBPicking.EdgePickResult = PBPicking.pick_edge(md, mesh.global_transform, click, cam)
	assert_true(result.edge != null, "Edge pick should hit an edge")
	if result.edge != null:
		var a: Vector3 = md.positions[result.edge.a]
		var b: Vector3 = md.positions[result.edge.b]
		var midpoint: Vector3 = (a + b) * 0.5
		assert_gt(midpoint.z, 0.0,
			"Must pick the NEAR (visible) edge, not the hidden far quad's edge")

func test_face_edges_are_perimeter_no_diagonals():
	## N-gon guarantee: a quad face's edge list is its 4 perimeter edges —
	## the triangulation diagonal (shared by both triangles) must be excluded.
	var md := PBMeshData.create_cube(1.0)
	var edges := md.get_common_edges()
	assert_eq(edges.size(), 12, "Cube must dedupe to 12 perimeter edges")
	for fi in range(md.faces.size()):
		assert_eq(md.faces[fi].get_edges().size(), 4,
			"Quad face %d must expose exactly 4 perimeter edges" % fi)

# ==============================================================================
# Regression: occlusion (the "selects the diagonal on a planar face" bug)
# ==============================================================================

func _is_top_edge(md: PBMeshData, edge: PBEdge) -> bool:
	return md.positions[edge.a].y > 0.4 and md.positions[edge.b].y > 0.4

func test_border_edges_pickable_at_grazing_angles():
	## Round-4 regression: clicking each top edge dead-on at a grazing camera
	## pose must either return THAT edge, or a NEARER VISIBLE edge when the
	## clicked edge is on the far side (never a random unpickable state).
	var s := _make_setup(PBEditor.SelectMode.EDGE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data

	var cam := Camera3D.new()
	_viewport.add_child(cam)
	cam.position = Vector3(1.6, 2.4, -2.6)
	cam.look_at(Vector3.ZERO, Vector3.UP)

	for ei in range(md.get_common_edges().size()):
		var e: PBEdge = md.get_common_edges()[ei]
		if md.positions[e.a].y < 0.4:
			continue
		var mid := (md.positions[e.a] + md.positions[e.b]) * 0.5
		var screen: Vector2 = cam.unproject_position(mid)
		var result: PBPicking.EdgePickResult = PBPicking.pick_edge(
			md, mesh.global_transform, screen, cam)
		if result.edge == null:
			continue
		var is_target: bool = result.edge.a == e.a and result.edge.b == e.b
		if not is_target:
			var picked_mid: Vector3 = (md.positions[result.edge.a] + md.positions[result.edge.b]) * 0.5
			var target_mid: Vector3 = mid
			assert_lt(cam.global_position.distance_to(picked_mid),
				cam.global_position.distance_to(target_mid),
				"Non-target result must be a NEARER visible edge")

func test_far_edge_selectable_through_mesh():
	## ProBuilder UX: an edge seen THROUGH a face stays selectable — click its
	## projection when no visible edge is under the cursor and the far edge
	## itself is picked (big hitbox, grab through the mesh).
	var ed := PBEditor.new()
	var logic := PBElementEditor.new()
	logic.editor = ed
	ed.select_mode = PBEditor.SelectMode.EDGE

	# Big far quad + small near quad: the far quad's top edge has free screen
	# space outside the small near quad.
	var md := PBMeshData.new()
	md.positions = PackedVector3Array([
		Vector3(-1, -1, -2), Vector3(1, -1, -2), Vector3(1, 1, -2), Vector3(-1, 1, -2),
		Vector3(-0.2, -0.2, 1), Vector3(0.2, -0.2, 1), Vector3(0.2, 0.2, 1), Vector3(-0.2, 0.2, 1),
	])
	var faces: Array[PBFace] = []
	for base in [0, 4]:
		faces.append(PBFace.new(PackedInt32Array([
			base + 0, base + 1, base + 2,
			base + 2, base + 3, base + 0,
		])))
	md.faces = faces
	var groups: Array[PBSharedVertex] = []
	for i in range(8):
		groups.append(PBSharedVertex.new(PackedInt32Array([i])))
	md.shared_vertices = groups
	md.invalidate_caches()

	var mesh := PBMesh.new()
	mesh.pb_mesh_data = md
	add_child_autofree(mesh)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 5.0
	_viewport.add_child(cam)
	cam.position = Vector3(0, 0, 5)
	cam.look_at(Vector3.ZERO, Vector3.UP)

	var screen: Vector2 = cam.unproject_position(Vector3(0.6, 1, 0))
	var result: PBPicking.EdgePickResult = PBPicking.pick_edge(md, mesh.global_transform, screen, cam)
	assert_true(result.edge != null, "Far edge click must hit the far edge (big hitbox)")
	if result.edge != null:
		var mid: Vector3 = (md.positions[result.edge.a] + md.positions[result.edge.b]) * 0.5
		assert_lt(mid.z, 0.0, "Picked edge must be the FAR quad's edge")
		assert_almost_eq(mid.y, 1.0, 0.001, "Must be the far quad's TOP edge")

func test_visible_edge_wins_over_hidden_at_same_projection():
	var ed := PBEditor.new()
	var logic := PBElementEditor.new()
	logic.editor = ed
	ed.select_mode = PBEditor.SelectMode.EDGE

	var md := PBMeshData.new()
	md.positions = PackedVector3Array([
		Vector3(-0.5, -0.5, -1), Vector3(0.5, -0.5, -1), Vector3(0.5, 0.5, -1), Vector3(-0.5, 0.5, -1),
		Vector3(-0.5, -0.5, 1), Vector3(0.5, -0.5, 1), Vector3(0.5, 0.5, 1), Vector3(-0.5, 0.5, 1),
	])
	var faces: Array[PBFace] = []
	for base in [0, 4]:
		faces.append(PBFace.new(PackedInt32Array([
			base + 0, base + 1, base + 2,
			base + 2, base + 3, base + 0,
		])))
	md.faces = faces
	var groups: Array[PBSharedVertex] = []
	for i in range(8):
		groups.append(PBSharedVertex.new(PackedInt32Array([i])))
	md.shared_vertices = groups
	md.invalidate_caches()

	var mesh := PBMesh.new()
	mesh.pb_mesh_data = md
	add_child_autofree(mesh)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 4.0
	_viewport.add_child(cam)
	cam.position = Vector3(0, 0, 5)
	cam.look_at(Vector3.ZERO, Vector3.UP)

	var screen: Vector2 = cam.unproject_position(Vector3(0, 0.5, 0))
	var result: PBPicking.EdgePickResult = PBPicking.pick_edge(md, mesh.global_transform, screen, cam)
	assert_true(result.edge != null)
	if result.edge != null:
		var mid: Vector3 = (md.positions[result.edge.a] + md.positions[result.edge.b]) * 0.5
		assert_gt(mid.z, 0.0, "Visible (near) edge must win over the hidden far edge")

func test_side_face_recorded_and_gizmo_follows_picked_side():
	## ProBuilder UX: selecting an edge from different sides gives an
	## ELEMENT-space gizmo oriented by THAT side's face normal.
	var s := _make_setup(PBEditor.SelectMode.EDGE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data

	var cam := Camera3D.new()
	_viewport.add_child(cam)
	cam.position = Vector3(1.6, 2.4, -2.6)
	cam.look_at(Vector3.ZERO, Vector3.UP)

	# Top-front edge, clicked from above (the top face is under the cursor)
	var screen: Vector2 = cam.unproject_position(Vector3(0, 0.5, -0.5))
	var hit: int = logic.pick_ray(md, mesh.global_transform, cam, screen)
	assert_gte(hit, 0, "Top-front edge must be pickable")
	var side: int = logic.pick_side_faces.get(hit, -1)
	assert_gte(side, 0, "Pick must record the side face")
	if side >= 0:
		var side_normal := PBMath.normal_from_positions(
			md.positions, md.faces[side].get_indexes())
		assert_lt(side_normal.y, 0.5, "Side face for a top-edge-from-above pick must be an upward face")

	# ELEMENT-space basis Z must equal the side face's normal
	s["ed"].orientation_space = PBEditor.OrientationSpace.ELEMENT
	var xf: Transform3D = logic.get_subgizmo_transform(md, mesh, hit)
	var side_n := PBMath.normal_from_positions(md.positions, md.faces[side].get_indexes())
	assert_true(xf.basis.z.is_equal_approx(side_n),
		"ELEMENT gizmo Z must follow the picked side's face normal")

	# Reset clears the recorded sides
	logic.reset_side_faces()
	assert_true(logic.pick_side_faces.is_empty(), "reset_side_faces must clear the map")

func test_visible_border_edges_still_pickable_from_either_side():
	## Occlusion must not over-reject: an edge shared with the face the ray
	## hits stays pickable even when the cursor approaches from the other face.
	var s := _make_setup(PBEditor.SelectMode.EDGE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data

	var cam := Camera3D.new()
	_viewport.add_child(cam)
	cam.position = Vector3(2.2, 3.2, 2.6)
	cam.look_at(Vector3.ZERO, Vector3.UP)

	# Top-front edge midpoint: click exactly on it, and 3px toward the face
	var edge_mid := Vector3(0, 0.5, -0.5)
	var screen: Vector2 = cam.unproject_position(edge_mid)
	var result: PBPicking.EdgePickResult = PBPicking.pick_edge(
		md, mesh.global_transform, screen, cam)
	assert_true(result.edge != null, "Clicking exactly on a border edge must pick it")
	if result.edge != null:
		assert_true(_is_top_edge(md, result.edge), "The picked edge must be the border edge")

# ==============================================================================
# Regression: box-select occlusion + weld integrity (round 4)
# ==============================================================================

func test_frustum_select_excludes_hidden_far_elements():
	## Two stacked quads (far listed first) under an orthogonal camera looking
	## down -Z project identically. A frustum covering both must select ONLY
	## the near quad's elements — box select must match what the user sees.
	var ed := PBEditor.new()
	var logic := PBElementEditor.new()
	logic.editor = ed

	var md := PBMeshData.new()
	md.positions = PackedVector3Array([
		Vector3(-0.5, -0.5, -1), Vector3(0.5, -0.5, -1), Vector3(0.5, 0.5, -1), Vector3(-0.5, 0.5, -1),
		Vector3(-0.5, -0.5, 1), Vector3(0.5, -0.5, 1), Vector3(0.5, 0.5, 1), Vector3(-0.5, 0.5, 1),
	])
	var faces: Array[PBFace] = []
	for base in [0, 4]:
		faces.append(PBFace.new(PackedInt32Array([
			base + 0, base + 1, base + 2,
			base + 2, base + 3, base + 0,
		])))
	md.faces = faces
	var groups: Array[PBSharedVertex] = []
	for i in range(8):
		groups.append(PBSharedVertex.new(PackedInt32Array([i])))
	md.shared_vertices = groups
	md.invalidate_caches()

	var mesh := PBMesh.new()
	mesh.pb_mesh_data = md
	add_child_autofree(mesh)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 4.0
	_viewport.add_child(cam)
	cam.position = Vector3(0, 0, 5)
	cam.look_at(Vector3.ZERO, Vector3.UP)

	# Frustum that covers the whole silhouette (both quads)
	var planes: Array[Plane] = [
		Plane(Vector3(1, 0, 0), 2), Plane(Vector3(-1, 0, 0), 2),
		Plane(Vector3(0, 1, 0), 2), Plane(Vector3(0, -1, 0), 2),
		Plane(Vector3(0, 0, 1), 20), Plane(Vector3(0, 0, -1), 20),
	]

	ed.select_mode = PBEditor.SelectMode.FACE
	var face_ids: PackedInt32Array = logic.pick_frustum(md, mesh.global_transform, planes, cam)
	assert_eq(face_ids.size(), 1, "Box select must return only the NEAR (visible) face")
	assert_eq(face_ids[0], 1, "The visible face is quad B (far quad is occluded)")

	ed.select_mode = PBEditor.SelectMode.EDGE
	var edge_ids: PackedInt32Array = logic.pick_frustum(md, mesh.global_transform, planes, cam)
	assert_eq(edge_ids.size(), 4, "Only the near quad's 4 edges are selectable")
	for ei in edge_ids:
		var e: PBEdge = md.get_common_edges()[ei]
		assert_gt((md.positions[e.a].z + md.positions[e.b].z) * 0.5, 0.0,
			"Selected edges must be on the near quad")

	ed.select_mode = PBEditor.SelectMode.VERTEX
	var vert_ids: PackedInt32Array = logic.pick_frustum(md, mesh.global_transform, planes, cam)
	assert_eq(vert_ids.size(), 4, "Only the near quad's 4 corners are selectable")

	# Without a camera (occlusion off) the old behavior is available: 8 elements
	ed.select_mode = PBEditor.SelectMode.FACE
	var all_ids: PackedInt32Array = logic.pick_frustum(md, mesh.global_transform, planes)
	assert_eq(all_ids.size(), 2, "Occlusion-off path still sees both quads")

func test_ensure_welds_rebuilds_missing_groups():
	## A mesh with stripped weld groups (stale serialization, external edit)
	## must self-heal on activation, or edge drags tear corners apart.
	var md := PBMeshData.create_cube(1.0)
	md.shared_vertices = []
	md.invalidate_caches()

	assert_true(md.ensure_welds(), "Empty welds must be rebuilt")
	assert_eq(md.shared_vertices.size(), 8, "Cube must heal to 8 corner groups")

	# After healing, dragging one edge moves exactly 6 positions (2 corners)
	var edges := md.get_common_edges()
	assert_eq(edges.size(), 12, "Healed cube must dedupe to 12 perimeter edges")
	var e0 := edges[0]
	var moved := {}
	for g in md.shared_vertices:
		if g.indices.has(e0.a) or g.indices.has(e0.b):
			for idx in g.indices:
				moved[idx] = true
	assert_eq(moved.size(), 6, "An edge drag must move 2 full welded corners")

	# Second call is a no-op (welds are healthy)
	assert_false(md.ensure_welds(), "Healthy welds must not be rebuilt")

func test_ensure_welds_rebuilds_partial_coverage():
	var md := PBMeshData.create_cube(1.0)
	# Simulate partial damage: keep only the first group
	md.shared_vertices = [md.shared_vertices[0]]
	md.invalidate_caches()
	assert_true(md.ensure_welds(), "Partial coverage must be detected as damage")
	assert_eq(md.shared_vertices.size(), 8)

func test_face_fill_mesh_uses_the_face_triangulation():
	## The selected-face highlight must re-use the face's OWN triangles,
	## offset along the face normal. A centroid fan over the perimeter
	## spills triangles outside concave/n-gon faces (the welded door sides).
	var md := PBMeshData.create_cube(1.0)
	var fill := PBElementEditor.build_face_fill_mesh(md, 0)
	assert_not_null(fill)

	var arrays := fill.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	assert_eq(verts.size(), 6, "Quad = the face's own 2 triangles = 6 vertices")

	# Every vertex is offset off the face plane (z = -0.5 face → z < -0.5)
	for v in verts:
		assert_lt(v.z, -0.5, "Fill vertices must sit just above the surface")

	# And the fill's corners are the face's corners (modulo the normal
	# offset) — no invented points.
	var face_verts := {}
	for idx in md.faces[0].get_distinct_indexes():
		face_verts[Vector2(md.positions[idx].x, md.positions[idx].y)] = true
	for v in verts:
		assert_true(face_verts.has(Vector2(v.x, v.y)),
			"Fill corner belongs to the face")

# ==============================================================================
# Regression: common edges must be POSITION pairs (round 5 — the wireframe X)
# ==============================================================================

func test_common_edges_are_real_perimeter_edges_not_chords():
	## ROOT CAUSE of the "diagonal / X on the face" reports: get_common_edges()
	## used to return shared-GROUP indices, and renderers indexed `positions`
	## with them — drawing chords across faces (an X on the cube) and making
	## selected-edge highlights appear where no edge exists. On a unit cube
	## every real edge has length 1; any chord is longer.
	var md := PBMeshData.create_cube(1.0)
	var edges := md.get_common_edges()
	assert_eq(edges.size(), 12)
	for i in range(edges.size()):
		var e: PBEdge = edges[i]
		assert_lt(e.a, md.positions.size(), "Edge endpoints must be position indices")
		assert_lt(e.b, md.positions.size(), "Edge endpoints must be position indices")
		var length: float = md.positions[e.a].distance_to(md.positions[e.b])
		assert_almost_eq(length, 1.0, 0.001,
			"Edge %d must be a unit perimeter edge (length 1), not a chord" % i)

	# No edge may connect diagonal corners of the same quad face loop
	for face in md.faces:
		var loop := face.get_distinct_indexes()
		if loop.size() != 4:
			continue
		for e in edges:
			var ia: int = loop.find(e.a)
			var ib: int = loop.find(e.b)
			if ia != -1 and ib != -1:
				assert_ne(absi(ia - ib), 2,
					"No common edge may be a face diagonal")

func test_edge_subgizmo_drag_expands_to_full_welded_corners():
	## An edge subgizmo id must resolve to its two welded corners (6 positions
	## on a cube). Partial expansion tears corners apart on drag.
	var s := _make_setup(PBEditor.SelectMode.EDGE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data

	var ids := _ids([0])
	var start_positions: PackedVector3Array = md.positions.duplicate()
	var start_xf: Transform3D = logic.get_subgizmo_transform(md, mesh, 0)
	var delta := Vector3(0, 0.35, 0)

	_apply_motion(s, ids, {0: start_xf.translated(delta)})

	var moved := 0
	for i in range(md.positions.size()):
		if not md.positions[i].is_equal_approx(start_positions[i]):
			moved += 1
	assert_eq(moved, 6, "Edge drag must move exactly 2 welded corners (6 positions)")

	# All moved positions must move by the SAME delta (no tearing)
	var edge: PBEdge = md.get_common_edges()[0]
	for idx in logic.element_indices(md, 0):
		assert_lt((md.positions[idx] - (start_positions[idx] + delta)).length(), 0.0001)

func test_edge_pick_projection_matches_selected_edge_highlight():
	## The picked edge id, rendered, must draw the SAME segment the user
	## clicked: element origin must equal the real edge midpoint.
	var s := _make_setup(PBEditor.SelectMode.EDGE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data

	var cam := Camera3D.new()
	_viewport.add_child(cam)
	cam.position = Vector3(2.2, 3.2, 2.6)
	cam.look_at(Vector3.ZERO, Vector3.UP)

	# Click exactly on the top-back edge midpoint
	var target := Vector3(0, 0.5, -0.5)
	var screen: Vector2 = cam.unproject_position(target)
	var hit: int = logic.pick_ray(md, mesh.global_transform, cam, screen)
	assert_gte(hit, 0, "Border edge pick should hit")

	var origin: Vector3 = logic.element_origin(md, hit)
	assert_lt(origin.distance_to(target), 0.001,
		"The selected edge's origin must be the clicked edge's midpoint — " +
		"if not, the highlight draws somewhere the user never clicked")

# ==============================================================================
# Regression: raw-vs-group edge id mapping (round 9 — unselectable edges)
# ==============================================================================

func test_every_edge_maps_from_pick_to_correct_subgizmo_id():
	## ROOT CAUSE of "X-perpendicular edges unselectable": _common_edge_index
	## canonicalized the picked edge to a GROUP pair and compared it against
	## RAW position pairs with .equals() — matching only when the numbers
	## coincided (the 4 X-running cube edges), returning -1 for the other 8.
	## End-to-end: from two opposite corners (so every edge is visible from
	## at least one), clicking an edge's midpoint must select THAT edge.
	var s := _make_setup(PBEditor.SelectMode.EDGE)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data

	var checked := {}
	for cam_pos in [Vector3(2.2, 2.9, 2.6), Vector3(-2.2, -2.9, -2.6)]:
		var cam := Camera3D.new()
		_viewport.add_child(cam)
		cam.position = cam_pos
		cam.look_at(Vector3.ZERO, Vector3.UP)
		await get_tree().process_frame

		var edges := md.get_common_edges()
		for ei in range(edges.size()):
			var e: PBEdge = edges[ei]
			if checked.has(ei):
				continue
			var mid := (md.positions[e.a] + md.positions[e.b]) * 0.5
			var world_mid := mesh.global_transform * mid
			if logic._point_occluded(md, mesh.global_transform, cam, world_mid, -1, e):
				continue # hidden from this camera; covered by the opposite one
			var screen: Vector2 = cam.unproject_position(world_mid)
			var hit: int = logic.pick_ray(md, mesh.global_transform, cam, screen)
			assert_eq(hit, ei,
				"Clicking edge %d's midpoint must select edge %d itself" % [ei, ei])
			if hit == ei:
				var origin: Vector3 = logic.element_origin(md, hit)
				assert_lt(origin.distance_to(world_mid), 0.001,
					"Selected edge %d's gizmo origin must be its midpoint" % ei)
			checked[ei] = true
	assert_eq(checked.size(), 12, "All 12 edges must have been verified visible from the two corners")

func test_common_edge_index_maps_every_face_perimeter_edge():
	## Pure mapping test, camera-independent: every face's perimeter edge must
	## resolve to a common-edge id holding the same PHYSICAL edge (welded
	## corners share coordinates, whichever face contributed the entry).
	var md := PBMeshData.create_cube(1.0)
	var edges := md.get_common_edges()
	var mapped := {}
	for fi in range(md.faces.size()):
		for edge in md.faces[fi].get_edges():
			var id: int = logic_common_edge_index(md, edge)
			assert_gte(id, 0,
				"Perimeter edge (%d,%d) must map to a subgizmo id" % [edge.a, edge.b])
			if id >= 0:
				var stored: PBEdge = edges[id]
				var same: bool = (md.positions[stored.a].is_equal_approx(md.positions[edge.a]) \
					and md.positions[stored.b].is_equal_approx(md.positions[edge.b])) \
					or (md.positions[stored.a].is_equal_approx(md.positions[edge.b]) \
					and md.positions[stored.b].is_equal_approx(md.positions[edge.a]))
				assert_true(same,
					"Mapped id %d must hold the same physical edge" % id)
				mapped[id] = true
	assert_eq(mapped.size(), 12, "All 12 cube edges must be reachable via mapping")

func logic_common_edge_index(md: PBMeshData, edge: PBEdge) -> int:
	var logic := PBElementEditor.new()
	logic.editor = PBEditor.new()
	logic.editor.select_mode = PBEditor.SelectMode.EDGE
	return logic._common_edge_index(md, edge)

