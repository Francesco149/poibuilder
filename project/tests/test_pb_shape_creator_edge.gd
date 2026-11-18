## Edge-first (GoBuild-style) shape placement — PBShapeCreator.PlacementStyle.EDGE.
##
## Click a start point, click the end of the first edge (any angle in the
## surface plane — it is the shape's width axis), pull the depth
## perpendicular to it, then the height. Opt-in: the default stays the
## ProBuilder drag.
extends GutTest

var creator: PBShapeCreator

func before_each() -> void:
	creator = PBShapeCreator.new()

func _arm_edge(shape: StringName = &"cube") -> void:
	creator.placement_style = PBShapeCreator.PlacementStyle.EDGE
	creator.arm(shape)

## World-space positions of the placed shape's data.
func _placed_points() -> PackedVector3Array:
	var data := creator.build_data()
	var xf := creator.placement_transform(data)
	var out := PackedVector3Array()
	for p in data.positions:
		out.append(xf * p)
	return out

func test_default_style_is_the_drag_flow():
	creator.arm(&"cube")
	assert_eq(creator.placement_style, PBShapeCreator.PlacementStyle.DRAG, "drag is the default")
	creator.begin(Vector3.ZERO, Vector3.UP, Vector3.BACK)
	assert_eq(creator.edge_stage, PBShapeCreator.EDGE_NONE, "the drag flow has no edge stages")

func test_edge_at_an_angle_orients_and_sizes_the_shape():
	_arm_edge()
	var start := Vector3(1, 0, 1)
	creator.begin(start, Vector3.UP, Vector3.BACK)
	assert_eq(creator.state, PBShapeCreator.State.BASE)
	assert_eq(creator.edge_stage, PBShapeCreator.EDGE_LINE, "edge flow starts with the line")
	var edge_end := start + Vector3(3, 0, 1.5)  # ~26.6° off world X
	creator.update_base(edge_end)
	var u := Vector3(3, 0, 1.5).normalized()
	assert_almost_eq(creator.u_size, Vector3(3, 0, 1.5).length(), 0.0001, "edge length = width")
	assert_almost_eq(creator.u_dir.dot(u), 1.0, 0.0001, "edge direction kept exactly (no axis snap)")
	assert_true(creator.lock_edge(), "a real edge locks")
	assert_eq(creator.edge_stage, PBShapeCreator.EDGE_DEPTH)
	var v := Vector3.UP.cross(u).normalized()
	creator.update_base(start + u * 1.0 + v * 2.0)
	assert_almost_eq(creator.v_size, 2.0, 0.0001, "depth is the perpendicular distance")
	assert_almost_eq(creator.facing.dot(v), 1.0, 0.0001, "forward faces the way the depth was pulled")
	assert_true(creator.end_base(), "depth click hands over to the height")
	assert_eq(creator.state, PBShapeCreator.State.HEIGHT)
	assert_eq(creator.edge_stage, PBShapeCreator.EDGE_NONE)
	creator.update_height_point(start + Vector3.UP * 1.5)
	# The placed cube must fill exactly the drawn rect: [0, L] along the edge,
	# [0, depth] across it, [0, h] up — measured from the start point.
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for p in _placed_points():
		var d := p - start
		var c := Vector3(d.dot(u), d.y, d.dot(v))
		lo = lo.min(c)
		hi = hi.max(c)
	assert_almost_eq(lo.x, 0.0, 0.001, "starts at the first click")
	assert_almost_eq(hi.x, Vector3(3, 0, 1.5).length(), 0.001, "ends at the edge's end")
	assert_almost_eq(lo.z, 0.0, 0.001, "flush with the edge")
	assert_almost_eq(hi.z, 2.0, 0.001, "depth pulled out to the cursor")
	assert_almost_eq(lo.y, 0.0, 0.001, "sits on the surface")
	assert_almost_eq(hi.y, 1.5, 0.001, "rises to the height")

func test_depth_pulled_to_the_other_side_flips_forward():
	_arm_edge()
	creator.begin(Vector3.ZERO, Vector3.UP, Vector3.BACK)
	creator.update_base(Vector3(2, 0, 0))
	creator.lock_edge()
	creator.update_base(Vector3(1, 0, 3))  # +Z side; UP x +X = -Z, so this is "right"
	assert_almost_eq(creator.facing.dot(Vector3(0, 0, 1)), 1.0, 0.0001, "forward follows the pull")
	assert_almost_eq(creator.v_size, 3.0, 0.0001)
	creator.end_base()
	creator.update_height_point(Vector3.UP)
	for p in _placed_points():
		assert_true(p.z > -0.001 and p.z < 3.001, "shape stays on the pulled side (z=%.3f)" % p.z)

func test_the_anchor_click_release_never_locks_a_zero_edge():
	_arm_edge()
	creator.begin(Vector3.ZERO, Vector3.UP, Vector3.BACK)
	assert_false(creator.lock_edge(), "zero-length edge: the release of the first click does nothing")
	assert_eq(creator.edge_stage, PBShapeCreator.EDGE_LINE, "still waiting for the edge's end")
	creator.update_base(Vector3(0.05, 0, 0))
	assert_false(creator.lock_edge(), "a sliver below the minimum does not lock")
	assert_false(creator.end_base(), "end_base cannot skip the edge")
	assert_eq(creator.state, PBShapeCreator.State.BASE, "and does not abort the session either")

func test_shift_squares_the_depth():
	_arm_edge()
	creator.begin(Vector3.ZERO, Vector3.UP, Vector3.BACK)
	creator.update_base(Vector3(2, 0, 0))
	creator.lock_edge()
	creator.square_lock = true
	creator.update_base(Vector3(1, 0, -0.3))
	assert_almost_eq(creator.v_size, 2.0, 0.0001, "Shift: depth = edge length")
	assert_almost_eq(creator.facing.dot(Vector3(0, 0, -1)), 1.0, 0.0001, "on the side the cursor is")

func test_snapping_puts_the_edge_end_on_the_grid():
	var g := PBGrid.new()
	g.unit = 1.0
	g.subdivisions = 1
	g.enabled = true
	creator.grid = g
	_arm_edge()
	creator.begin(Vector3.ZERO, Vector3.UP, Vector3.BACK)
	creator.update_base(Vector3(2.3, 0, 0.8))
	assert_almost_eq(creator.base_end.x, 2.0, 0.0001, "end x on the grid")
	assert_almost_eq(creator.base_end.z, 1.0, 0.0001, "end z on the grid")
	assert_almost_eq(creator.u_size, Vector3(2, 0, 1).length(), 0.0001, "edge between grid points")
	creator.lock_edge()
	creator.update_base(Vector3(0, 0, 0) + Vector3.UP.cross(Vector3(2, 0, 1).normalized()) * 1.4)
	assert_almost_eq(creator.v_size, 1.0, 0.0001, "depth quantizes to the step")

func test_shapes_with_their_own_base_keep_the_drag_flow():
	for shape in [&"trim", &"plane"]:
		creator = PBShapeCreator.new()
		_arm_edge(shape)
		assert_false(creator.uses_edge_flow(), "%s keeps its own base semantics" % shape)
		creator.begin(Vector3.ZERO, Vector3.UP, Vector3.BACK)
		assert_eq(creator.edge_stage, PBShapeCreator.EDGE_NONE, "%s: no edge stage" % shape)

func test_stairs_climb_away_from_the_edge():
	_arm_edge(&"stair")
	creator.begin(Vector3.ZERO, Vector3.UP, Vector3.BACK)
	creator.update_base(Vector3(0, 0, 2))
	creator.lock_edge()
	creator.update_base(Vector3(3, 0, 1))
	creator.end_base()
	creator.update_height_point(Vector3.UP * 2.0)
	# The highest vertices must be the far side from the edge (x near 3).
	var top_x := -INF
	var top_y := -INF
	for p in _placed_points():
		if p.y > top_y + 0.001:
			top_y = p.y
			top_x = p.x
		elif absf(p.y - top_y) <= 0.001:
			top_x = maxf(top_x, p.x)
	assert_gt(top_x, 2.0, "the top step is across the depth, not at the edge")

func test_wall_edge_works_in_the_wall_plane():
	_arm_edge()
	var n := Vector3(0, 0, 1)
	creator.begin(Vector3(0, 1, 0), n, Vector3.BACK)
	creator.update_base(Vector3(2, 2, 0.4))  # off-plane z is projected away
	assert_almost_eq(creator.base_end.z, 0.0, 0.0001, "edge stays in the wall plane")
	assert_true(creator.lock_edge())
	creator.update_base(Vector3(0, 3, 0))
	assert_gt(creator.v_size, 0.1, "depth grows across the wall")
	assert_almost_eq(creator.facing.dot(n), 0.0, 0.0001, "forward stays in the wall plane")
	creator.end_base()
	creator.update_height_point(Vector3(0, 1, 0.5))
	assert_almost_eq(creator.height, 0.5, 0.0001, "height grows out of the wall")
