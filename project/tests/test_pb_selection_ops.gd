extends GutTest

## Tests for PBSelectionOps and advanced selection/snapping functionality.

var cube: PBMeshData
var cylinder: PBMeshData

func before_each() -> void:
	cube = PBMeshData.create_cube(1.0)
	cylinder = PBShapeCylinder.create_cylinder(0.5, 1.0, 8, 1, 1)

# ==============================================================================
# Grow Selection with Angle Limit
# ==============================================================================

func test_grow_faces_angle_limit() -> void:
	# Cube faces meet at 90 degrees.
	var start_faces := PackedInt32Array([0])

	# Angle threshold 45 deg should NOT cross 90-deg crease edges
	var restricted := PBSelectionOps.grow_faces_with_angle(cube, start_faces, 45.0)
	assert_eq(restricted.size(), 1, "45-deg threshold should not cross 90-deg crease on cube")

	# Angle threshold 95 deg should cross 90-deg edges and add 4 adjacent faces
	var expanded := PBSelectionOps.grow_faces_with_angle(cube, start_faces, 95.0)
	assert_eq(expanded.size(), 5, "95-deg threshold should grow to 5 faces (1 original + 4 adjacent)")

	# Unconstrained (-1) should also grow
	var unconstrained := PBSelectionOps.grow_faces_with_angle(cube, start_faces, -1.0)
	assert_eq(unconstrained.size(), 5, "Unconstrained should grow to 5 faces")

# ==============================================================================
# Select Coplanar Faces
# ==============================================================================

func test_select_coplanar_faces_on_cube() -> void:
	# On a standard cube, no two adjacent faces are coplanar
	var start_faces := PackedInt32Array([0])
	var coplanar := PBSelectionOps.select_coplanar_faces(cube, start_faces, 1.0)
	assert_eq(coplanar.size(), 1, "Cube has no adjacent coplanar faces")

func test_select_coplanar_faces_on_subdivided_face() -> void:
	# Subdivide face 0 on cube -> creates coplanar child faces on the top
	PBMeshOps.subdivide_faces(cube, PackedInt32Array([0]))
	# After subdividing face 0, we have coplanar faces sharing the top plane
	var start := PackedInt32Array([0])
	var coplanar := PBSelectionOps.select_coplanar_faces(cube, start, 1.0)
	assert_gt(coplanar.size(), 1, "Subdivided coplanar faces should all be selected")

# ==============================================================================
# Select Similar Faces
# ==============================================================================

func test_select_similar_by_material() -> void:
	# Set material_id on faces 0 and 1 to 5, others to 0
	cube.faces[0].submesh_index = 5
	cube.faces[1].submesh_index = 5
	cube.faces[2].submesh_index = 0

	var similar := PBSelectionOps.select_similar_faces(cube, PackedInt32Array([0]), "material")
	assert_eq(similar.size(), 2, "Should select both faces with material 5")
	assert_true(similar.has(0))
	assert_true(similar.has(1))

func test_select_similar_by_color() -> void:
	var cols := PackedColorArray()
	cols.resize(cube.positions.size())
	cols.fill(Color.WHITE)
	for idx in cube.faces[0].get_distinct_indexes():
		cols[idx] = Color(1, 0, 0, 1)
	for idx in cube.faces[2].get_distinct_indexes():
		cols[idx] = Color(1, 0, 0, 1)
	for idx in cube.faces[1].get_distinct_indexes():
		cols[idx] = Color(0, 1, 0, 1)
	cube.colors = cols
	var similar := PBSelectionOps.select_similar_faces(cube, PackedInt32Array([0]), "color")
	assert_eq(similar.size(), 2, "Should select both red faces")
	assert_true(similar.has(0))
	assert_true(similar.has(2))

func test_select_similar_by_smoothing_group() -> void:
	cube.faces[0].smoothing_group = 3
	cube.faces[3].smoothing_group = 3
	cube.faces[1].smoothing_group = 0

	var similar := PBSelectionOps.select_similar_faces(cube, PackedInt32Array([0]), "smoothing_group")
	assert_eq(similar.size(), 2, "Should select both faces with smoothing group 3")
	assert_true(similar.has(0))
	assert_true(similar.has(3))

func test_select_similar_by_area() -> void:
	# All faces on a 1x1 cube have area 1.0
	var similar := PBSelectionOps.select_similar_faces(cube, PackedInt32Array([0]), "area")
	assert_eq(similar.size(), 6, "All 6 faces of unit cube have identical area 1.0")

# ==============================================================================
# Select Boundary Edges & Holes
# ==============================================================================

func test_boundary_edges_on_closed_mesh() -> void:
	# Closed watertight cube has 0 boundary edges
	var edges := PBSelectionOps.select_boundary_edges(cube)
	assert_eq(edges.size(), 0, "Watertight cube should have no boundary edges")

func test_boundary_edges_on_open_mesh() -> void:
	# Delete face 0 from cube -> opening leaves 4 boundary edges
	PBMeshOps.delete_faces(cube, PackedInt32Array([0]))
	var edges := PBSelectionOps.select_boundary_edges(cube)
	assert_eq(edges.size(), 4, "Deleted cube face should leave 4 boundary edges")

	var edge_ids := PBSelectionOps.select_boundary_edge_ids(cube)
	assert_eq(edge_ids.size(), 4, "Should find 4 boundary edge IDs")

# ==============================================================================
# Face Loop & Ring
# ==============================================================================

func test_face_loop_on_cylinder() -> void:
	# Find a quad face on cylinder body
	var body_face_idx := -1
	for i in range(cylinder.faces.size()):
		if cylinder.faces[i].get_distinct_indexes().size() == 4:
			body_face_idx = i
			break
	assert_true(body_face_idx >= 0, "Cylinder should have body quad faces")

	var loop := PBSelectionOps.get_face_loop(cylinder, PackedInt32Array([body_face_idx]), false)
	# Cylinder body has 8 segments around
	assert_gt(loop.size(), 1, "Face loop should traverse connected quads")

# ==============================================================================
# Select All & Invert Helpers
# ==============================================================================

func test_get_all_and_inverted_ids() -> void:
	var all_faces := PBSelectionOps.get_all_ids(cube, PBEditor.SelectMode.FACE)
	assert_eq(all_faces.size(), 6, "Cube has 6 faces")

	var inv := PBSelectionOps.get_inverted_ids(cube, PackedInt32Array([0, 1]), PBEditor.SelectMode.FACE)
	assert_eq(inv.size(), 4, "Inverting 2 selected faces should yield 4")
	assert_false(inv.has(0))
	assert_false(inv.has(1))

# ==============================================================================
# Proportional Editing Falloff Curves
# ==============================================================================

func test_proportional_weights() -> void:
	var r := 2.0
	# At distance 0, weight should be 1.0 across all falloffs
	assert_almost_eq(PBElementEditor.calculate_proportional_weight(0.0, r, PBElementEditor.ProportionalFalloff.SMOOTH), 1.0, 0.001)
	assert_almost_eq(PBElementEditor.calculate_proportional_weight(0.0, r, PBElementEditor.ProportionalFalloff.LINEAR), 1.0, 0.001)
	assert_almost_eq(PBElementEditor.calculate_proportional_weight(0.0, r, PBElementEditor.ProportionalFalloff.SPHERE), 1.0, 0.001)
	assert_almost_eq(PBElementEditor.calculate_proportional_weight(0.0, r, PBElementEditor.ProportionalFalloff.SHARP), 1.0, 0.001)
	assert_almost_eq(PBElementEditor.calculate_proportional_weight(0.0, r, PBElementEditor.ProportionalFalloff.CONSTANT), 1.0, 0.001)

	# At distance >= r, weight should be 0.0
	assert_almost_eq(PBElementEditor.calculate_proportional_weight(2.0, r, PBElementEditor.ProportionalFalloff.SMOOTH), 0.0, 0.001)
	assert_almost_eq(PBElementEditor.calculate_proportional_weight(2.5, r, PBElementEditor.ProportionalFalloff.SMOOTH), 0.0, 0.001)

	# At midpoint distance 1.0 (t = 0.5):
	var w_linear := PBElementEditor.calculate_proportional_weight(1.0, r, PBElementEditor.ProportionalFalloff.LINEAR)
	assert_almost_eq(w_linear, 0.5, 0.001)

func test_vertex_snap_find_nearest() -> void:
	var ee := PBElementEditor.new()
	var mesh: PBMesh = autofree(PBMesh.new())
	mesh.pb_mesh_data = cube
	# Cube vertices are at +/-0.5 on each axis.
	var target := Vector3(0.52, 0.49, 0.51)
	var nearest := ee._find_nearest_scene_vertex(mesh, target)
	assert_almost_eq(nearest.x, 0.5, 0.001)
	assert_almost_eq(nearest.y, 0.5, 0.001)
	assert_almost_eq(nearest.z, 0.5, 0.001)

func test_vertex_snap_axis_constrained_no_lateral_shift() -> void:
	var ee := PBElementEditor.new()
	var mesh: PBMesh = autofree(PBMesh.new())
	mesh.pb_mesh_data = cube
	ee.vertex_snap_enabled = true

	# Set up drag state: pretend top face (Y=+0.5) is being dragged.
	# Top vertices on cube (Y = 0.5) are in _drag_union.
	# Base vertices are at Y = -0.5.
	ee._drag_latest_id = 0
	ee._drag_start_xf[0] = Transform3D(Basis(), Vector3(0.0, 0.5, 0.0))
	var union_idxs := PackedInt32Array()
	for i in range(cube.positions.size()):
		if is_equal_approx(cube.positions[i].y, 0.5):
			union_idxs.append(i)
	ee._drag_union = union_idxs

	# Motion UP along Y: (0, 0.1, 0).
	# Because 0.1 is far from base vertices (which are at Y = -0.5, diff = 1.1m > 0.2m threshold),
	# it should NOT snap to the base, and should NOT move sideways in X or Z!
	var motion := Vector3(0.0, 0.1, 0.0)
	var snapped := ee._snap_move_motion(mesh, motion)
	assert_almost_eq(snapped.x, 0.0, 0.0001, "Should not jump sideways in X")
	assert_almost_eq(snapped.z, 0.0, 0.0001, "Should not jump sideways in Z")
	assert_almost_eq(snapped.y, 0.1, 0.001, "Should continue moving up freely when outside snap threshold")

func test_vertex_snap_catches_and_dislodges() -> void:
	var ee := PBElementEditor.new()
	var mesh: PBMesh = autofree(PBMesh.new())
	mesh.pb_mesh_data = cube
	ee.vertex_snap_enabled = true

	ee._drag_latest_id = 0
	ee._drag_start_xf[0] = Transform3D(Basis(), Vector3(0.0, 0.5, 0.0))
	var union_idxs := PackedInt32Array()
	for i in range(cube.positions.size()):
		if is_equal_approx(cube.positions[i].y, 0.5):
			union_idxs.append(i)
	ee._drag_union = union_idxs

	# Base vertices are at Y = -0.5. The start pivot is at Y = +0.5.
	# The distance to base vertices along Y is -1.0.
	# When dragging DOWN toward the base:
	# At motion y = -0.92 (within threshold 0.2 of -1.0):
	var motion_near := Vector3(0.0, -0.92, 0.0)
	var snapped_near := ee._snap_move_motion(mesh, motion_near)
	assert_almost_eq(snapped_near.y, -1.0, 0.001, "Should snap to -1.0 (base vertex height) when near")
	assert_almost_eq(snapped_near.x, 0.0, 0.0001, "No X shift on Y axis drag")
	assert_almost_eq(snapped_near.z, 0.0, 0.0001, "No Z shift on Y axis drag")

	# When dragged further past the base, e.g. y = -1.35 (outside threshold 0.2):
	var motion_past := Vector3(0.0, -1.35, 0.0)
	var snapped_past := ee._snap_move_motion(mesh, motion_past)
	assert_almost_eq(snapped_past.y, -1.35, 0.001, "Should dislodge cleanly once outside threshold")

func test_vertex_snap_falls_back_to_grid_when_enabled() -> void:
	var ee := PBElementEditor.new()
	var mesh: PBMesh = autofree(PBMesh.new())
	mesh.pb_mesh_data = cube
	ee.vertex_snap_enabled = true

	var grid := PBGrid.new()
	grid.enabled = true
	grid.unit = 1.0
	grid.subdivisions = 2  # step = 0.5
	ee.grid = grid

	ee._drag_latest_id = 0
	ee._drag_start_xf[0] = Transform3D(Basis(), Vector3(0.0, 0.5, 0.0))
	var union_idxs := PackedInt32Array()
	for i in range(cube.positions.size()):
		if is_equal_approx(cube.positions[i].y, 0.5):
			union_idxs.append(i)
	ee._drag_union = union_idxs

	# Motion UP along Y: 0.43. Outside vertex snap threshold of base vertices.
	# Pivot starts at 0.5. Target is 0.5 + 0.43 = 0.93. Grid step is 0.5 -> snaps to 1.0!
	# Displacement = 1.0 - 0.5 = 0.5.
	var motion := Vector3(0.0, 0.43, 0.0)
	var snapped := ee._snap_move_motion(mesh, motion)
	assert_almost_eq(snapped.y, 0.5, 0.001, "Should fall back to grid snap (0.5 displacement) when vertex snap does not catch")
	assert_almost_eq(snapped.x, 0.0, 0.0001)
	assert_almost_eq(snapped.z, 0.0, 0.0001)

func test_selection_methods_on_pb_selection() -> void:
	var sel := PBSelection.new(cube)
	sel.add_face(0)
	sel.select_coplanar()
	assert_eq(sel.selected_face_count(), 1)

	# Test boundary selection on PBSelection
	PBMeshOps.delete_faces(cube, PackedInt32Array([0]))
	sel.select_boundary_edges()
	assert_eq(sel.selected_edge_count(), 4)
