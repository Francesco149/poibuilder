extends GutTest

# ==============================================================================
# N-Gon Prism Generation Tests
# ==============================================================================

func test_ngon_prism_triangle():
	var poly := PackedVector3Array([
		Vector3(0, 0, 0),
		Vector3(2, 0, 0),
		Vector3(1, 0, 2)
	])
	var md := PBShapeComplex.create_ngon_prism(poly, 1.5, Vector3.UP)
	assert_not_null(md, "Triangle prism should be generated")
	assert_eq(md.validate(), "", "Mesh should validate cleanly")
	# 2 caps + 3 side quads = 5 faces
	assert_eq(md.faces.size(), 5, "Triangle prism should have 5 faces")
	var counts := PBMeshOps.edge_usage_counts(md)
	for edge_key in counts:
		assert_eq(counts[edge_key], 2, "Watertight: edge %s used by exactly 2 faces" % str(edge_key))

func test_ngon_prism_pentagon_and_hexagon():
	for sides in [5, 6]:
		var poly := PackedVector3Array()
		for i in range(sides):
			var angle: float = float(i) * TAU / float(sides)
			poly.append(Vector3(cos(angle), 0, sin(angle)))
		var md := PBShapeComplex.create_ngon_prism(poly, 2.0, Vector3.UP)
		assert_not_null(md)
		assert_eq(md.validate(), "")
		assert_eq(md.faces.size(), sides + 2, "%d-gon prism should have %d faces" % [sides, sides + 2])
		# Caps are single n-gon faces
		assert_eq(md.faces[0].get_edges().size(), sides, "Bottom cap is %d-gon" % sides)
		assert_eq(md.faces[1].get_edges().size(), sides, "Top cap is %d-gon" % sides)
		var counts := PBMeshOps.edge_usage_counts(md)
		for edge_key in counts:
			assert_eq(counts[edge_key], 2, "Watertight manifold everywhere")

func test_ngon_prism_concave_l_shape():
	# L-shaped polygon (concave n-gon)
	var poly := PackedVector3Array([
		Vector3(0, 0, 0),
		Vector3(2, 0, 0),
		Vector3(2, 0, 1),
		Vector3(1, 0, 1),
		Vector3(1, 0, 2),
		Vector3(0, 0, 2)
	])
	var md := PBShapeComplex.create_ngon_prism(poly, 1.0, Vector3.UP)
	assert_not_null(md)
	assert_eq(md.validate(), "")
	# 2 caps + 6 side quads = 8 faces
	assert_eq(md.faces.size(), 8)
	var counts := PBMeshOps.edge_usage_counts(md)
	for edge_key in counts:
		assert_eq(counts[edge_key], 2, "Concave prism is watertight manifold")

func test_ngon_prism_negative_height():
	var poly := PackedVector3Array([
		Vector3(0, 0, 0),
		Vector3(2, 0, 0),
		Vector3(2, 0, 2),
		Vector3(0, 0, 2)
	])
	var md := PBShapeComplex.create_ngon_prism(poly, -1.5, Vector3.UP)
	assert_not_null(md)
	assert_eq(md.validate(), "")
	assert_eq(md.faces.size(), 6)
	var counts := PBMeshOps.edge_usage_counts(md)
	for edge_key in counts:
		assert_eq(counts[edge_key], 2, "Negative height prism is watertight manifold")

# ==============================================================================
# Knife Tool / Face Cutting Tests
# ==============================================================================

func test_knife_edge_to_edge_split_straight():
	# Create a simple 2x2 plane box or plane
	var md := PBShapeGenerators.create_box(Vector3(2, 2, 2))
	var top_face_idx := -1
	for fi in range(md.faces.size()):
		var n := PBMath.normal_from_positions(md.positions, md.faces[fi].get_indexes())
		if n.dot(Vector3.UP) > 0.9:
			top_face_idx = fi
			break
	assert_gt(top_face_idx, -1, "Must find top face")

	# Cut straight across the top face along X = 0 (from Z = -1 to Z = +1)
	var cut := PackedVector3Array([
		Vector3(0, 1, -1),
		Vector3(0, 1, 1)
	])
	var res := PBMeshOps.cut_face(md, top_face_idx, cut, false)
	assert_true(res.get("ok", false), "Cut face should succeed: %s" % res.get("error", ""))

	# Original 6 faces: 1 removed, 2 added = 7 faces
	assert_eq(md.faces.size(), 7, "Cube should now have 7 faces after split")
	var counts := PBMeshOps.edge_usage_counts(md)
	for edge_key in counts:
		assert_eq(counts[edge_key], 2, "Watertight manifold preserved after edge-to-edge cut: %s" % str(edge_key))

func test_knife_edge_to_edge_split_zigzag():
	var md := PBShapeGenerators.create_box(Vector3(4, 2, 4))
	var top_face_idx := -1
	for fi in range(md.faces.size()):
		var n := PBMath.normal_from_positions(md.positions, md.faces[fi].get_indexes())
		if n.dot(Vector3.UP) > 0.9:
			top_face_idx = fi
			break
	assert_gt(top_face_idx, -1)

	# Stepped cut with 4 vertices
	var cut := PackedVector3Array([
		Vector3(-2, 1, 0),
		Vector3(-0.5, 1, 0),
		Vector3(-0.5, 1, 1),
		Vector3(2, 1, 1)
	])
	var res := PBMeshOps.cut_face(md, top_face_idx, cut, false)
	assert_true(res.get("ok", false), "Zigzag cut should succeed: %s" % res.get("error", ""))
	assert_eq(md.faces.size(), 7)
	var counts := PBMeshOps.edge_usage_counts(md)
	for edge_key in counts:
		assert_eq(counts[edge_key], 2, "Watertight manifold preserved after zigzag cut")

func test_knife_vertex_to_vertex_diagonal():
	var md := PBShapeGenerators.create_box(Vector3(2, 2, 2))
	var top_face_idx := -1
	for fi in range(md.faces.size()):
		var n := PBMath.normal_from_positions(md.positions, md.faces[fi].get_indexes())
		if n.dot(Vector3.UP) > 0.9:
			top_face_idx = fi
			break
	assert_gt(top_face_idx, -1)

	# Diagonal from corner (-1, 1, -1) to corner (1, 1, 1)
	var cut := PackedVector3Array([
		Vector3(-1, 1, -1),
		Vector3(1, 1, 1)
	])
	var res := PBMeshOps.cut_face(md, top_face_idx, cut, false)
	assert_true(res.get("ok", false), "Diagonal cut should succeed: %s" % res.get("error", ""))
	assert_eq(md.faces.size(), 7)
	var counts := PBMeshOps.edge_usage_counts(md)
	for edge_key in counts:
		assert_eq(counts[edge_key], 2, "Watertight manifold preserved after diagonal cut")

func test_knife_closed_loop_hole_cut():
	var md := PBShapeGenerators.create_box(Vector3(4, 2, 4))
	var top_face_idx := -1
	for fi in range(md.faces.size()):
		var n := PBMath.normal_from_positions(md.positions, md.faces[fi].get_indexes())
		if n.dot(Vector3.UP) > 0.9:
			top_face_idx = fi
			break
	assert_gt(top_face_idx, -1)

	# 1m square inside 4m square top face
	var cut := PackedVector3Array([
		Vector3(-0.5, 1, -0.5),
		Vector3(0.5, 1, -0.5),
		Vector3(0.5, 1, 0.5),
		Vector3(-0.5, 1, 0.5)
	])
	var res := PBMeshOps.cut_face(md, top_face_idx, cut, true)
	assert_true(res.get("ok", false), "Closed loop cut should succeed: %s" % res.get("error", ""))
	# Original 6 faces: 1 removed, 2 added (inner + outer) = 7 faces
	assert_eq(md.faces.size(), 7)

	# Both inner face and outer face are clean PBFace instances
	var found_inner := false
	var found_outer := false
	for fi in range(md.faces.size()):
		var f := md.faces[fi]
		var n := PBMath.normal_from_positions(md.positions, f.get_indexes())
		if n.dot(Vector3.UP) > 0.9:
			var edges := f.get_edges()
			if edges.size() == 4:
				found_inner = true
			elif edges.size() >= 8: # 4 outer edges + 4 inner hole edges
				found_outer = true
	assert_true(found_inner, "Inner face should exist with 4 edges")
	assert_true(found_outer, "Outer face should exist with hole perimeter")

func test_knife_closed_loop_pentagon_interior_cut():
	var md := PBShapeGenerators.create_box(Vector3(4, 2, 4))
	var top_face_idx := -1
	for fi in range(md.faces.size()):
		var n := PBMath.normal_from_positions(md.positions, md.faces[fi].get_indexes())
		if n.dot(Vector3.UP) > 0.9:
			top_face_idx = fi
			break
	assert_gt(top_face_idx, -1)

	# Asymmetric 5-gon cut in the interior (matching Image #1)
	var cut := PackedVector3Array([
		Vector3(-0.3, 1, 0.2),
		Vector3(0.2, 1, 0.5),
		Vector3(0.6, 1, 0.1),
		Vector3(0.5, 1, -0.4),
		Vector3(-0.1, 1, -0.6)
	])
	var res := PBMeshOps.cut_face(md, top_face_idx, cut, true)
	assert_true(res.get("ok", false), "Pentagon cut should succeed: %s" % res.get("error", ""))
	assert_eq(md.faces.size(), 7)

	# Verify area of inner + outer faces equals original face area (16.0)
	var area_sum := 0.0
	for fi in range(md.faces.size()):
		var f := md.faces[fi]
		var n := PBMath.normal_from_positions(md.positions, f.get_indexes())
		if n.dot(Vector3.UP) > 0.9:
			var idxs := f.get_indexes()
			for t in range(0, idxs.size(), 3):
				var p0: Vector3 = md.positions[idxs[t]]
				var p1: Vector3 = md.positions[idxs[t + 1]]
				var p2: Vector3 = md.positions[idxs[t + 2]]
				area_sum += 0.5 * (p1 - p0).cross(p2 - p0).length()
	assert_almost_eq(area_sum, 16.0, 0.01, "Area of inner + outer faces must equal original 4x4 face area")

	var counts := PBMeshOps.edge_usage_counts(md)
	for edge_key in counts:
		assert_eq(counts[edge_key], 2, "Watertight manifold: edge %s used by 2 faces" % str(edge_key))

func test_knife_edge_cases():
	var md := PBShapeGenerators.create_box(Vector3(2, 2, 2))
	# Less than 2 points
	var res1 := PBMeshOps.cut_face(md, 0, PackedVector3Array([Vector3(0, 0, 0)]))
	assert_false(res1.get("ok", true), "Single point cut should fail")

	# Invalid face index
	var res2 := PBMeshOps.cut_face(md, 999, PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0)]))
	assert_false(res2.get("ok", true), "Out of range face index should fail")

	# Null mesh data
	var res3 := PBMeshOps.cut_face(null, 0, PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0)]))
	assert_false(res3.get("ok", true), "Null mesh data should fail")

# ==============================================================================
# PBNgonDrawer State Machine Tests
# ==============================================================================

func test_ngon_drawer_state_machine_extrude():
	var drawer := PBNgonDrawer.new()
	assert_false(drawer.is_active())

	drawer.arm(PBNgonDrawer.Mode.NGON_EXTRUDE)
	assert_true(drawer.is_active())
	assert_eq(drawer.state, PBNgonDrawer.State.ARMED)

	drawer.begin(Vector3(0, 0, 0), Vector3.UP)
	assert_eq(drawer.state, PBNgonDrawer.State.DRAWING)
	assert_eq(drawer.points.size(), 1)

	# Place vertices: triangle
	assert_true(drawer.add_point(Vector3(2, 0, 0)))
	assert_true(drawer.add_point(Vector3(1, 0, 2)))
	assert_eq(drawer.points.size(), 3)

	# Drag a vertex
	drawer.start_drag_vert(1)
	assert_eq(drawer.state, PBNgonDrawer.State.DRAGGING_VERT)
	drawer.update_cursor_plane(Vector3(3, 0, 0))
	assert_eq(drawer.points[1], Vector3(3, 0, 0))
	drawer.end_drag_vert()
	assert_eq(drawer.state, PBNgonDrawer.State.DRAWING)

	# Complete -> enter HEIGHT state
	var comp_res := drawer.complete()
	assert_true(comp_res.get("ok", false))
	assert_eq(drawer.state, PBNgonDrawer.State.HEIGHT)

	# Adjust height
	drawer.update_height_point(Vector3(0, 2.5, 0))
	assert_almost_eq(drawer.height, 2.5, 0.01)

	# Confirm height
	var final_res := drawer.confirm_height()
	assert_true(final_res.get("ok", false))
	var data: PBMeshData = final_res["data"]
	assert_not_null(data)
	assert_eq(data.validate(), "")
	assert_false(drawer.is_active())
