extends GutTest

## Comprehensive test suite for PoiBuilder's precision vertex snapping (V-Snap / Hold-V).

var cube_a: PBMeshData
var cube_b: PBMeshData

func before_each() -> void:
	cube_a = PBMeshData.create_cube(1.0)
	cube_b = PBMeshData.create_cube(1.0)

# ==============================================================================
# Precision Axis Snapping (Fixes: No sideways jumping, no backwards collapse)
# ==============================================================================

func test_axis_constrained_y_does_not_shift_x_or_z() -> void:
	var ee := PBElementEditor.new()
	var mesh: PBMesh = autofree(PBMesh.new())
	mesh.pb_mesh_data = cube_a
	ee.vertex_snap_enabled = true

	# Select top face (Y = +0.5). Base vertices are at Y = -0.5.
	ee._drag_latest_id = 0
	ee._drag_start_xf[0] = Transform3D(Basis(), Vector3(0.0, 0.5, 0.0))
	var union_idxs := PackedInt32Array()
	for i in range(cube_a.positions.size()):
		if is_equal_approx(cube_a.positions[i].y, 0.5):
			union_idxs.append(i)
	ee._drag_union = union_idxs

	# Moving UP along Y must NEVER move X or Z sideways!
	var motion := Vector3(0.0, 0.15, 0.0)
	var snapped := ee._snap_move_motion(mesh, motion)
	assert_almost_eq(snapped.x, 0.0, 0.0001, "X must remain 0 on Y-axis drag")
	assert_almost_eq(snapped.z, 0.0, 0.0001, "Z must remain 0 on Y-axis drag")
	assert_almost_eq(snapped.y, 0.15, 0.001, "Y moves freely when outside snap threshold of base")

func test_moving_away_from_base_does_not_snap_backwards_to_zero_height() -> void:
	var ee := PBElementEditor.new()
	var mesh: PBMesh = autofree(PBMesh.new())
	mesh.pb_mesh_data = cube_a
	ee.vertex_snap_enabled = true

	ee._drag_latest_id = 0
	ee._drag_start_xf[0] = Transform3D(Basis(), Vector3(0.0, 0.5, 0.0))
	var union_idxs := PackedInt32Array()
	for i in range(cube_a.positions.size()):
		if is_equal_approx(cube_a.positions[i].y, 0.5):
			union_idxs.append(i)
	ee._drag_union = union_idxs

	# Base vertices are at Y = -0.5, which is -1.0 relative to start pivot (0.5).
	# Dragging UP by any small amount (0.01 to 0.5) must NOT snap backwards to -1.0.
	var test_deltas := [0.01, 0.05, 0.1, 0.25, 0.5]
	for dy in test_deltas:
		var snapped := ee._snap_move_motion(mesh, Vector3(0.0, dy, 0.0))
		assert_gt(snapped.y, 0.0, "Motion must stay positive when dragging up; must not collapse to base")
		assert_almost_eq(snapped.y, dy, 0.001, "Delta should match input when not near any vertex")

func test_snaps_to_adjacent_mesh_vertex_and_dislodges() -> void:
	var ee := PBElementEditor.new()
	var root: Node3D = autofree(Node3D.new())

	var mesh_a: PBMesh = autofree(PBMesh.new())
	mesh_a.pb_mesh_data = cube_a
	mesh_a.transform = Transform3D(Basis(), Vector3(0.0, 0.0, 0.0))
	root.add_child(mesh_a)

	var mesh_b: PBMesh = autofree(PBMesh.new())
	mesh_b.pb_mesh_data = cube_b
	# Place mesh B so its top vertices are at Y = 1.25 (offset by 0.75m from mesh A's top at 0.5)
	mesh_b.transform = Transform3D(Basis(), Vector3(2.0, 0.75, 0.0))
	root.add_child(mesh_b)

	ee.vertex_snap_enabled = true
	ee._drag_latest_id = 0
	ee._drag_start_xf[0] = Transform3D(Basis(), Vector3(0.0, 0.5, 0.0))
	var union_idxs := PackedInt32Array()
	for i in range(cube_a.positions.size()):
		if is_equal_approx(cube_a.positions[i].y, 0.5):
			union_idxs.append(i)
	ee._drag_union = union_idxs

	# Target height on mesh B is Y = 1.25, which is a delta of +0.75 from mesh A's start pivot (0.5).
	# 1. When dragged to dy = 0.72 (diff 0.03 <= snap_threshold 0.2):
	var snapped_near := ee._snap_move_motion(mesh_a, Vector3(0.0, 0.72, 0.0))
	assert_almost_eq(snapped_near.y, 0.75, 0.001, "Should catch and snap to adjacent mesh B vertex height (0.75)")
	assert_almost_eq(snapped_near.x, 0.0, 0.0001, "X remains 0")
	assert_almost_eq(snapped_near.z, 0.0, 0.0001, "Z remains 0")

	# 2. When dragged past to dy = 1.05 (diff 0.30 > snap_threshold 0.2):
	var snapped_past := ee._snap_move_motion(mesh_a, Vector3(0.0, 1.05, 0.0))
	assert_almost_eq(snapped_past.y, 1.05, 0.001, "Should dislodge cleanly once outside snap threshold")

func test_plane_drag_constrained_to_plane() -> void:
	var ee := PBElementEditor.new()
	var mesh: PBMesh = autofree(PBMesh.new())
	mesh.pb_mesh_data = cube_a
	ee.vertex_snap_enabled = true

	ee._drag_latest_id = 0
	ee._drag_start_xf[0] = Transform3D(Basis(), Vector3(0.0, 0.5, 0.0))
	ee._drag_union = PackedInt32Array([0, 1, 2, 3])

	# Plane drag in XZ ground plane (Y motion = 0):
	var motion := Vector3(0.12, 0.0, 0.14)
	var snapped := ee._snap_move_motion(mesh, motion)
	assert_almost_eq(snapped.y, 0.0, 0.0001, "Y must remain 0 on XZ plane drag")

func test_extrude_vertex_snap() -> void:
	var ee := PBElementEditor.new()
	var root: Node3D = autofree(Node3D.new())

	var mesh_a: PBMesh = autofree(PBMesh.new())
	mesh_a.pb_mesh_data = cube_a
	root.add_child(mesh_a)

	var mesh_b: PBMesh = autofree(PBMesh.new())
	mesh_b.pb_mesh_data = cube_b
	mesh_b.transform = Transform3D(Basis(), Vector3(2.0, 1.0, 0.0))
	root.add_child(mesh_b)

	ee.vertex_snap_enabled = true
	ee._drag_gesture = PBElementEditor.DragGesture.EXTRUDE_MOVE
	ee._extrude_normal_world = Vector3.UP
	ee._extrude_pivot_world = Vector3(0.0, 0.5, 0.0)
	ee._drag_union = PackedInt32Array([0, 1, 2, 3])

	# Extrude cap moving UP along Y. Candidate vertices on mesh B are at Y = 1.5 (dist = 1.0 from pivot 0.5).
	var motion_near := Vector3(0.0, 0.95, 0.0)
	var snapped := ee._snap_extrude_motion(mesh_a, motion_near)
	assert_almost_eq(snapped.y, 1.0, 0.001, "Extrude cap should snap to mesh B vertex height (1.0m extrusion distance)")
	assert_almost_eq(snapped.x, 0.0, 0.0001)
	assert_almost_eq(snapped.z, 0.0, 0.0001)

func test_hold_v_activates_vertex_snapping() -> void:
	var ee := PBElementEditor.new()
	assert_false(ee.is_vertex_snap_active(), "Should be false initially")

	ee.vertex_snap_held = true
	assert_true(ee.is_vertex_snap_active(), "Holding V should activate vertex snapping")

	ee.vertex_snap_held = false
	assert_false(ee.is_vertex_snap_active(), "Releasing V should deactivate vertex snapping")

	ee.vertex_snap_enabled = true
	assert_true(ee.is_vertex_snap_active(), "Toggling toolbar button should activate vertex snapping")

func test_cursor_targeting_snaps_to_hovered_vertex() -> void:
	var ee := PBElementEditor.new()
	var root: Node3D = autofree(Node3D.new())

	var mesh_a: PBMesh = autofree(PBMesh.new())
	mesh_a.pb_mesh_data = cube_a
	root.add_child(mesh_a)

	var mesh_b: PBMesh = autofree(PBMesh.new())
	mesh_b.pb_mesh_data = cube_b
	# Place mesh B with top at Y = 3.0 (way outside 0.2m proximity threshold from 0.5)
	mesh_b.transform = Transform3D(Basis(), Vector3(5.0, 2.5, 0.0))
	root.add_child(mesh_b)
	var vp: SubViewport = autofree(SubViewport.new())
	vp.size = Vector2i(800, 600)
	add_child_autofree(vp)

	var cam: Camera3D = autofree(Camera3D.new())
	cam.position = Vector3(2.5, 1.5, 10.0)
	vp.add_child(cam)
	ee.vertex_snap_enabled = true
	ee._drag_latest_id = 0
	ee._drag_start_xf[0] = Transform3D(Basis(), Vector3(0.0, 0.5, 0.0))
	ee._drag_union = PackedInt32Array([0, 1, 2, 3])

	# Candidate vertex on mesh B at world (4.5, 3.0, -0.5):
	var target_vert := Vector3(4.5, 3.0, -0.5)
	var screen_pos := cam.unproject_position(target_vert)
	ee.track_mouse(cam, screen_pos)

	# Dragging mesh A top face up by just 0.1 (far from 2.5m delta needed for Y=3.0).
	# But because cursor is directly over target_vert on screen, it snaps to target_vert height!
	var motion := Vector3(0.0, 0.1, 0.0)
	var snapped := ee._snap_move_motion(mesh_a, motion)
	assert_almost_eq(snapped.y, 2.5, 0.001, "Should snap to cursor-hovered vertex height (2.5m delta to reach Y=3.0)")
	assert_almost_eq(snapped.x, 0.0, 0.0001)

func test_object_space_vertex_snap() -> void:
	var ee := PBElementEditor.new()
	var editor_mock := PBEditor.new()
	editor_mock.orientation_space = PBEditor.OrientationSpace.OBJECT
	ee.editor = editor_mock

	var mesh: PBMesh = autofree(PBMesh.new())
	mesh.pb_mesh_data = cube_a
	ee.vertex_snap_enabled = true

	ee._drag_latest_id = 0
	ee._drag_start_xf[0] = Transform3D(Basis(), Vector3(0.0, 0.5, 0.0))
	var union_idxs := PackedInt32Array()
	for i in range(cube_a.positions.size()):
		if is_equal_approx(cube_a.positions[i].y, 0.5):
			union_idxs.append(i)
	ee._drag_union = union_idxs

	# Motion UP along Y in object space: (0, 0.1, 0)
	var motion := Vector3(0.0, 0.1, 0.0)
	var snapped := ee._snap_move_motion(mesh, motion)
	assert_almost_eq(snapped.x, 0.0, 0.0001, "No sideways shift in X")
	assert_almost_eq(snapped.z, 0.0, 0.0001, "No sideways shift in Z")
	assert_almost_eq(snapped.y, 0.1, 0.001)

func test_element_space_vertex_snap() -> void:
	var ee := PBElementEditor.new()
	var editor_mock := PBEditor.new()
	editor_mock.orientation_space = PBEditor.OrientationSpace.ELEMENT
	ee.editor = editor_mock

	var mesh: PBMesh = autofree(PBMesh.new())
	mesh.pb_mesh_data = cube_a
	ee.vertex_snap_enabled = true

	# Face 0 on cube has normal UP (0, 1, 0).
	ee._drag_latest_id = 0
	ee._drag_start_xf[0] = Transform3D(Basis(), Vector3(0.0, 0.5, 0.0))
	var union_idxs := PackedInt32Array()
	for i in range(cube_a.positions.size()):
		if is_equal_approx(cube_a.positions[i].y, 0.5):
			union_idxs.append(i)
	ee._drag_union = union_idxs

	var elem_b := ee.element_basis(cube_a, mesh, 0)
	# Drag along normal (elem_b.y):
	var motion := elem_b.y * 0.1
	var snapped := ee._snap_move_motion(mesh, motion)
	var d_x := snapped.dot(elem_b.x)
	var d_z := snapped.dot(elem_b.z)
	assert_almost_eq(d_x, 0.0, 0.0001, "Tangent drift must be 0")
	assert_almost_eq(d_z, 0.0, 0.0001, "Bitangent drift must be 0")
	assert_almost_eq(snapped.dot(elem_b.y), 0.1, 0.001)
	assert_almost_eq(snapped.z, 0.0, 0.0001)
