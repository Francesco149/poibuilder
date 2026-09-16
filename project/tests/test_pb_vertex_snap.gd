extends GutTest

## Vertex snapping (V-Snap / hold-V) — pair-magnet semantics.
##
## A snap catches ONLY when a dragged corner passes within the magnet radius
## of a scene vertex under the active drag constraint; the output motion
## stays exactly on the constrained axes and never moves sideways. A dragged
## face/edge snaps at its real corners; a single dragged vertex degenerates
## to one source (snap off that one point).
##
## Regression coverage for the two failure modes this replaced:
## - projection-only acceptance: any vertex whose height along the drag axis
##   matched the drag distance yanked the selection, no matter how far away
##   laterally ("ping-pongs between positions that aren't near anything");
## - the 35px screen-space cursor override: teleported the selection to
##   whatever vertex happened to sit under the mouse.

var cube_a: PBMeshData
var cube_b: PBMeshData

## Default magnet radius (grid off → 0.2 m).
const R := 0.2

func before_each() -> void:
	cube_a = PBMeshData.create_cube(1.0)
	cube_b = PBMeshData.create_cube(1.0)

## Standard setup: drag the top face (every position with y = +0.5) of a unit
## cube at the origin. Returns the configured editor; tests pass their own
## PBMesh wrapping the same mesh_data to the snap calls.
func _top_face_drag(mesh_data: PBMeshData) -> PBElementEditor:
	var ee := PBElementEditor.new()
	ee.vertex_snap_enabled = true
	ee._drag_latest_id = 0
	ee._drag_start_xf[0] = Transform3D(Basis(), Vector3(0.0, 0.5, 0.0))
	ee._drag_original_positions = mesh_data.positions.duplicate()
	var union := PackedInt32Array()
	for i in range(mesh_data.positions.size()):
		if is_equal_approx(mesh_data.positions[i].y, 0.5):
			union.append(i)
	ee._drag_union = union
	return ee

# ==============================================================================
# Axis-constrained drags (raise / lower along one gizmo axis)
# ==============================================================================

func test_axis_drag_without_nearby_geometry_passes_through() -> void:
	var ee := _top_face_drag(cube_a)
	var mesh: PBMesh = autofree(PBMesh.new())
	mesh.pb_mesh_data = cube_a

	# Own base corners sit 1m below (t = -1): outside the window when raising.
	var snapped := ee._snap_move_motion(mesh, Vector3(0.0, 0.15, 0.0))
	assert_almost_eq(snapped.y, 0.15, 0.001, "Passes through when nothing is reachable")
	assert_almost_eq(snapped.x, 0.0, 0.0001, "X must remain 0 on a Y-axis drag")
	assert_almost_eq(snapped.z, 0.0, 0.0001, "Z must remain 0 on a Y-axis drag")

func test_raising_never_collapses_backwards_to_the_base() -> void:
	var ee := _top_face_drag(cube_a)
	var mesh: PBMesh = autofree(PBMesh.new())
	mesh.pb_mesh_data = cube_a
	for dy in [0.01, 0.05, 0.1, 0.25, 0.5]:
		var snapped := ee._snap_move_motion(mesh, Vector3(0.0, dy, 0.0))
		assert_gt(snapped.y, 0.0, "Must stay positive when dragging up")
		assert_almost_eq(snapped.y, dy, 0.001, "Uncaught motion passes through")

func test_lowering_snaps_flush_to_own_base_corners() -> void:
	var ee := _top_face_drag(cube_a)
	var mesh: PBMesh = autofree(PBMesh.new())
	mesh.pb_mesh_data = cube_a
	# Base corners sit directly below the dragged corners (perp 0, t = -1).
	var snapped := ee._snap_move_motion(mesh, Vector3(0.0, -0.97, 0.0))
	assert_almost_eq(snapped.y, -1.0, 0.001, "Face locks flush onto its own base")
	assert_almost_eq(snapped.x, 0.0, 0.0001)
	assert_almost_eq(snapped.z, 0.0, 0.0001)

func test_axis_catch_requires_lateral_proximity() -> void:
	# THE ping-pong regression: mesh B sits 2m to the side at a height that
	# matches the drag distance along Y. The projection-only solver yanked the
	# face to B's top height; the pair-magnet solver must not (B's vertices
	# are 1m+ away from every dragged corner in XZ).
	var ee := _top_face_drag(cube_a)
	var root: Node3D = autofree(Node3D.new())
	var mesh_a: PBMesh = autofree(PBMesh.new())
	mesh_a.pb_mesh_data = cube_a
	root.add_child(mesh_a)
	var mesh_b: PBMesh = autofree(PBMesh.new())
	mesh_b.pb_mesh_data = cube_b
	mesh_b.transform = Transform3D(Basis(), Vector3(2.0, 0.75, 0.0))
	root.add_child(mesh_b)

	var snapped := ee._snap_move_motion(mesh_a, Vector3(0.0, 0.72, 0.0))
	assert_almost_eq(snapped.y, 0.72, 0.001, "A vertex 1m to the side must NOT catch")
	assert_almost_eq(snapped.x, 0.0, 0.0001)
	assert_almost_eq(snapped.z, 0.0, 0.0001)

func test_axis_snaps_to_overhead_vertex_and_releases() -> void:
	# B sits in the SAME footprint, top at y = 1.25: raising the face by 0.75
	# puts A's corners exactly onto B's top corners.
	var ee := _top_face_drag(cube_a)
	var root: Node3D = autofree(Node3D.new())
	var mesh_a: PBMesh = autofree(PBMesh.new())
	mesh_a.pb_mesh_data = cube_a
	root.add_child(mesh_a)
	var mesh_b: PBMesh = autofree(PBMesh.new())
	mesh_b.pb_mesh_data = cube_b
	mesh_b.transform = Transform3D(Basis(), Vector3(0.0, 0.75, 0.0))
	root.add_child(mesh_b)

	# Inside the window → lock onto the vertex height (delta 0.75).
	var caught := ee._snap_move_motion(mesh_a, Vector3(0.0, 0.72, 0.0))
	assert_almost_eq(caught.y, 0.75, 0.001, "Snaps the corner onto B's top vertex")
	assert_almost_eq(caught.x, 0.0, 0.0001, "Never sideways")
	assert_almost_eq(caught.z, 0.0, 0.0001, "Never sideways")

	# Outside the window in both directions → raw motion passes through.
	var below := ee._snap_move_motion(mesh_a, Vector3(0.0, 0.5, 0.0))
	assert_almost_eq(below.y, 0.5, 0.001, "Not yet within the window")
	var past := ee._snap_move_motion(mesh_a, Vector3(0.0, 1.05, 0.0))
	assert_almost_eq(past.y, 1.05, 0.001, "Releases cleanly once past the window")

func test_elongated_face_snaps_at_its_corner_vertex() -> void:
	# A 10m-long face whose centroid is 5m from the target: the snap must be
	# evaluated at the dragged CORNERS, not the selection centroid.
	var ee := PBElementEditor.new()
	var root: Node3D = autofree(Node3D.new())
	var mesh_a: PBMesh = autofree(PBMesh.new())
	var md_a := PBMeshData.new()
	md_a.positions = PackedVector3Array([
		Vector3(0.0, 1.0, 0.0),
		Vector3(10.0, 1.0, 0.0),
		Vector3(10.0, 1.0, 1.0),
		Vector3(0.0, 1.0, 1.0)
	])
	var face := PBFace.new()
	face.set_indexes(PackedInt32Array([0, 1, 2, 0, 2, 3]))
	md_a.faces.append(face)
	mesh_a.pb_mesh_data = md_a
	root.add_child(mesh_a)

	# Target directly above the far corner (10, 1, 0) at height 2.5.
	var mesh_b: PBMesh = autofree(PBMesh.new())
	var md_b := PBMeshData.new()
	md_b.positions = PackedVector3Array([Vector3(10.0, 2.5, 0.0)])
	var face_b := PBFace.new()
	face_b.set_indexes(PackedInt32Array([0, 0, 0]))
	md_b.faces.append(face_b)
	mesh_b.pb_mesh_data = md_b
	root.add_child(mesh_b)

	ee.vertex_snap_enabled = true
	ee._drag_latest_id = 0
	# Pivot (the centroid) is at (5, 1, 0.5) — irrelevant to the catch.
	ee._drag_start_xf[0] = Transform3D(Basis(), Vector3(5.0, 1.0, 0.5))
	ee._drag_union = PackedInt32Array([0, 1, 2, 3])

	var snapped := ee._snap_move_motion(mesh_a, Vector3(0.0, 1.42, 0.0))
	assert_almost_eq(snapped.y, 1.5, 0.001, "Corner locks onto the vertex above it")
	assert_almost_eq(snapped.x, 0.0, 0.0001, "No sideways shift in X")
	assert_almost_eq(snapped.z, 0.0, 0.0001, "No sideways shift in Z")

# ==============================================================================
# Single-vertex drags snap off that one point
# ==============================================================================

func test_single_vertex_drag_snaps_off_that_point_only() -> void:
	var ee := PBElementEditor.new()
	var root: Node3D = autofree(Node3D.new())
	var mesh_a: PBMesh = autofree(PBMesh.new())
	mesh_a.pb_mesh_data = cube_a
	root.add_child(mesh_a)

	# A single floating vertex directly above A's +X+Y+Z corner.
	var mesh_b: PBMesh = autofree(PBMesh.new())
	var md_b := PBMeshData.new()
	md_b.positions = PackedVector3Array([Vector3(0.5, 1.25, 0.5)])
	var face_b := PBFace.new()
	face_b.set_indexes(PackedInt32Array([0, 0, 0]))
	md_b.faces.append(face_b)
	mesh_b.pb_mesh_data = md_b
	root.add_child(mesh_b)

	ee.vertex_snap_enabled = true
	ee._drag_latest_id = 0
	ee._drag_start_xf[0] = Transform3D(Basis(), Vector3(0.5, 0.5, 0.5))
	var union := PackedInt32Array()
	for i in range(cube_a.positions.size()):
		var p := cube_a.positions[i]
		if is_equal_approx(p.x, 0.5) and is_equal_approx(p.y, 0.5) and is_equal_approx(p.z, 0.5):
			union.append(i)
	assert_gt(union.size(), 0, "Fixture: the corner exists")
	ee._drag_union = union

	var snapped := ee._snap_move_motion(mesh_a, Vector3(0.0, 0.72, 0.0))
	assert_almost_eq(snapped.y, 0.75, 0.001, "The one dragged vertex snaps to the target")
	assert_almost_eq(snapped.x, 0.0, 0.0001)
	assert_almost_eq(snapped.z, 0.0, 0.0001)

# ==============================================================================
# Plane + free drags
# ==============================================================================

func test_plane_drag_stays_on_the_plane() -> void:
	var ee := _top_face_drag(cube_a)
	var mesh: PBMesh = autofree(PBMesh.new())
	mesh.pb_mesh_data = cube_a
	ee._drag_union = PackedInt32Array([0, 1, 2, 3])

	var motion := Vector3(0.12, 0.0, 0.14)
	var snapped := ee._snap_move_motion(mesh, motion)
	assert_almost_eq(snapped.y, 0.0, 0.0001, "Y must remain 0 on an XZ plane drag")

func test_plane_drag_magnet_locks_a_corner_onto_a_coplanar_vertex() -> void:
	var ee := PBElementEditor.new()
	var root: Node3D = autofree(Node3D.new())

	# A floor quad with one extra vertex at (1.5, 0, 0.5).
	var floor_mesh: PBMesh = autofree(PBMesh.new())
	var md_floor := PBMeshData.new()
	md_floor.positions = PackedVector3Array([
		Vector3(0, 0, 0), Vector3(3, 0, 0), Vector3(3, 0, 3), Vector3(0, 0, 3),
		Vector3(1.5, 0, 0.5),
	])
	var floor_face := PBFace.new()
	floor_face.set_indexes(PackedInt32Array([0, 1, 2, 0, 2, 3]))
	md_floor.faces.append(floor_face)
	floor_mesh.pb_mesh_data = md_floor
	root.add_child(floor_mesh)

	# The dragged 1x1 quad at the origin, coplanar with the floor.
	var quad: PBMesh = autofree(PBMesh.new())
	var md_quad := PBMeshData.new()
	md_quad.positions = PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1),
	])
	var quad_face := PBFace.new()
	quad_face.set_indexes(PackedInt32Array([0, 1, 2, 0, 2, 3]))
	md_quad.faces.append(quad_face)
	quad.pb_mesh_data = md_quad
	root.add_child(quad)

	ee.vertex_snap_enabled = true
	ee._drag_latest_id = 0
	ee._drag_start_xf[0] = Transform3D(Basis(), Vector3(0.5, 0.0, 0.5))
	ee._drag_union = PackedInt32Array([0, 1, 2, 3])

	# Dragging near the displacement that puts corner (1,0,0) onto (1.5,0,0.5)
	# locks the whole motion to exactly that corner-on-vertex displacement.
	var snapped := ee._snap_move_motion(quad, Vector3(0.55, 0.0, 0.45))
	assert_almost_eq(snapped.x, 0.5, 0.001, "Locks onto the corner-on-vertex displacement")
	assert_almost_eq(snapped.y, 0.0, 0.0001, "Stays on the drag plane")
	assert_almost_eq(snapped.z, 0.5, 0.001, "Locks onto the corner-on-vertex displacement")

func test_free_drag_snaps_a_corner_onto_a_vertex_in_3d() -> void:
	var ee := PBElementEditor.new()
	var root: Node3D = autofree(Node3D.new())
	var quad: PBMesh = autofree(PBMesh.new())
	var md_quad := PBMeshData.new()
	md_quad.positions = PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1),
	])
	var quad_face := PBFace.new()
	quad_face.set_indexes(PackedInt32Array([0, 1, 2, 0, 2, 3]))
	md_quad.faces.append(quad_face)
	quad.pb_mesh_data = md_quad
	root.add_child(quad)

	# A floating vertex above the floor.
	var floater: PBMesh = autofree(PBMesh.new())
	var md_f := PBMeshData.new()
	md_f.positions = PackedVector3Array([Vector3(1.5, 0.3, 0.5)])
	var f_face := PBFace.new()
	f_face.set_indexes(PackedInt32Array([0, 0, 0]))
	md_f.faces.append(f_face)
	floater.pb_mesh_data = md_f
	root.add_child(floater)

	ee.vertex_snap_enabled = true
	ee._drag_latest_id = 0
	ee._drag_start_xf[0] = Transform3D(Basis(), Vector3(0.5, 0.0, 0.5))
	ee._drag_union = PackedInt32Array([0, 1, 2, 3])

	# All three components active → free solve: corner (1,0,0) lands on the vertex.
	var snapped := ee._snap_move_motion(quad, Vector3(0.55, 0.28, 0.47))
	assert_almost_eq(snapped.x, 0.5, 0.001)
	assert_almost_eq(snapped.y, 0.3, 0.001)
	assert_almost_eq(snapped.z, 0.5, 0.001)

# ==============================================================================
# Extrude cap
# ==============================================================================

func test_extrude_cap_snaps_along_the_normal() -> void:
	var ee := PBElementEditor.new()
	var root: Node3D = autofree(Node3D.new())
	var mesh_a: PBMesh = autofree(PBMesh.new())
	mesh_a.pb_mesh_data = cube_a
	root.add_child(mesh_a)

	# B in the same footprint, top at y = 1.5 — the cap distance 1.0 puts the
	# cap corners onto B's top corners.
	var mesh_b: PBMesh = autofree(PBMesh.new())
	mesh_b.pb_mesh_data = cube_b
	mesh_b.transform = Transform3D(Basis(), Vector3(0.0, 1.0, 0.0))
	root.add_child(mesh_b)

	ee.vertex_snap_enabled = true
	ee._drag_gesture = PBElementEditor.DragGesture.EXTRUDE_MOVE
	ee._extrude_normal_world = Vector3.UP
	ee._extrude_pivot_world = Vector3(0.0, 0.5, 0.0)
	ee._drag_union = PackedInt32Array([0, 1, 2, 3])  # front-face corners (z = -0.5)

	var snapped := ee._snap_extrude_motion(mesh_a, Vector3(0.0, 0.95, 0.0))
	assert_almost_eq(snapped.y, 1.0, 0.001, "Cap distance locks onto B's top vertex height")
	assert_almost_eq(snapped.x, 0.0, 0.0001)
	assert_almost_eq(snapped.z, 0.0, 0.0001)

# ==============================================================================
# Stability across successive deliveries (the anti-ping-pong guarantee)
# ==============================================================================

func test_catch_is_stable_across_successive_deliveries() -> void:
	# The engine re-delivers raw mouse displacements every motion; the solver
	# must measure sources from the DRAG-START snapshot, not the live
	# (already snapped) positions — otherwise each caught snap un-catches and
	# the selection jumps back to the raw position on the next motion.
	var ee := _top_face_drag(cube_a)
	var root: Node3D = autofree(Node3D.new())
	var mesh_a: PBMesh = autofree(PBMesh.new())
	mesh_a.pb_mesh_data = cube_a
	root.add_child(mesh_a)
	var mesh_b: PBMesh = autofree(PBMesh.new())
	mesh_b.pb_mesh_data = cube_b
	mesh_b.transform = Transform3D(Basis(), Vector3(0.0, 0.75, 0.0))
	root.add_child(mesh_b)

	var first := ee._snap_move_motion(mesh_a, Vector3(0.0, 0.72, 0.0))
	assert_almost_eq(first.y, 0.75, 0.001)

	# Simulate the drag applying the snapped result to the mesh.
	for idx in ee._drag_union:
		cube_a.positions[idx] = cube_a.positions[idx] + Vector3(0.0, 0.75, 0.0)

	var second := ee._snap_move_motion(mesh_a, Vector3(0.0, 0.72, 0.0))
	assert_almost_eq(second.y, 0.75, 0.001,
		"Re-delivery with the same raw motion must catch the same vertex")

# ==============================================================================
# Removed behaviors (regression guards)
# ==============================================================================

func test_cursor_hover_does_not_yank_the_selection() -> void:
	# The old solver teleported the selection toward any vertex under the
	# mouse cursor (35px screen radius), regardless of world distance.
	# Cursor position must be irrelevant now.
	var ee := _top_face_drag(cube_a)
	var root: Node3D = autofree(Node3D.new())
	var mesh_a: PBMesh = autofree(PBMesh.new())
	mesh_a.pb_mesh_data = cube_a
	root.add_child(mesh_a)
	var mesh_b: PBMesh = autofree(PBMesh.new())
	mesh_b.pb_mesh_data = cube_b
	mesh_b.transform = Transform3D(Basis(), Vector3(5.0, 2.5, 0.0))
	root.add_child(mesh_b)

	var vp: SubViewport = autofree(SubViewport.new())
	vp.size = Vector2i(800, 600)
	add_child_autofree(vp)
	var cam: Camera3D = autofree(Camera3D.new())
	cam.position = Vector3(2.5, 1.5, 10.0)
	vp.add_child(cam)
	ee.track_mouse(cam, cam.unproject_position(Vector3(4.5, 3.0, -0.5)))

	var snapped := ee._snap_move_motion(mesh_a, Vector3(0.0, 0.1, 0.0))
	assert_almost_eq(snapped.y, 0.1, 0.001, "A hovered far-away vertex must not catch")
	assert_almost_eq(snapped.x, 0.0, 0.0001)

# ==============================================================================
# Orientation spaces (constraint purity preserved)
# ==============================================================================

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

	ee._drag_latest_id = 0
	ee._drag_start_xf[0] = Transform3D(Basis(), Vector3(0.0, 0.5, 0.0))
	var union_idxs := PackedInt32Array()
	for i in range(cube_a.positions.size()):
		if is_equal_approx(cube_a.positions[i].y, 0.5):
			union_idxs.append(i)
	ee._drag_union = union_idxs

	var elem_b := ee.element_basis(cube_a, mesh, 0)
	var motion := elem_b.y * 0.1
	var snapped := ee._snap_move_motion(mesh, motion)
	var d_x := snapped.dot(elem_b.x)
	var d_z := snapped.dot(elem_b.z)
	assert_almost_eq(d_x, 0.0, 0.0001, "Tangent drift must be 0")
	assert_almost_eq(d_z, 0.0, 0.0001, "Bitangent drift must be 0")
	assert_almost_eq(snapped.dot(elem_b.y), 0.1, 0.001)

func test_edge_drag_single_axis_strictly_constrained() -> void:
	var ee := PBElementEditor.new()
	var editor_mock := PBEditor.new()
	editor_mock.select_mode = PBEditor.SelectMode.EDGE
	editor_mock.orientation_space = PBEditor.OrientationSpace.ELEMENT
	ee.editor = editor_mock

	var mesh: PBMesh = autofree(PBMesh.new())
	mesh.pb_mesh_data = cube_a
	ee.vertex_snap_enabled = true

	var edges := cube_a.get_common_edges()
	assert_gt(edges.size(), 0)
	var e0: PBEdge = edges[0]
	var p_a := cube_a.positions[e0.a]
	var p_b := cube_a.positions[e0.b]
	var mid := (p_a + p_b) * 0.5

	ee._drag_latest_id = 0
	var elem_b := ee.element_basis(cube_a, mesh, 0)
	ee._drag_start_xf[0] = Transform3D(elem_b, mid)
	ee._drag_union = PackedInt32Array([e0.a, e0.b])

	var d := 0.15
	var motion: Vector3 = elem_b * Vector3(d, 0.0, 0.0)
	var snapped := ee._snap_move_motion(mesh, motion)

	var local_snapped := elem_b.inverse() * snapped
	assert_almost_eq(local_snapped.x, 0.15, 0.001, "Motion along dragged axis 0 must be preserved")
	assert_almost_eq(local_snapped.y, 0.0, 0.0001, "Motion along axis 1 (Y) must be STRICTLY ZERO")
	assert_almost_eq(local_snapped.z, 0.0, 0.0001, "Motion along axis 2 (Z) must be STRICTLY ZERO")

	var motion_y: Vector3 = elem_b * Vector3(0.0, 0.12, 0.0)
	var snapped_y := ee._snap_move_motion(mesh, motion_y)
	var local_snapped_y := elem_b.inverse() * snapped_y
	assert_almost_eq(local_snapped_y.x, 0.0, 0.0001, "Motion along axis 0 (X) must be STRICTLY ZERO when dragging Y")
	assert_almost_eq(local_snapped_y.y, 0.12, 0.001, "Motion along dragged axis 1 (Y) must be preserved")
	assert_almost_eq(local_snapped_y.z, 0.0, 0.0001, "Motion along axis 2 (Z) must be STRICTLY ZERO when dragging Y")

func test_hold_v_activates_vertex_snapping() -> void:
	var ee := PBElementEditor.new()
	assert_false(ee.is_vertex_snap_active(), "Should be false initially")

	ee.vertex_snap_held = true
	assert_true(ee.is_vertex_snap_active(), "Holding V should activate vertex snapping")

	ee.vertex_snap_held = false
	assert_false(ee.is_vertex_snap_active(), "Releasing V should deactivate vertex snapping")

	ee.vertex_snap_enabled = true
	assert_true(ee.is_vertex_snap_active(), "Toggling toolbar button should activate vertex snapping")
