## Tests for PBShapeCreator — the drag-to-create state machine
## (ARMED → BASE → HEIGHT → PARAMS) and its placement math.
##
## All geometry is headless: no editor classes, no viewport. The plugin feeds
## surface points/rays; these tests do the same directly.
extends GutTest

func _armed_creator(shape_id := &"cube") -> PBShapeCreator:
	var creator := PBShapeCreator.new()
	creator.arm(shape_id)
	return creator

func _begin_base(creator: PBShapeCreator, at: Vector3, normal := Vector3.UP) -> void:
	# view_z (-1,0,0) → the drag axis seeds along +X on floor surfaces.
	creator.begin(at, normal, Vector3(-1, 0, 0))

# ==============================================================================
# Arming
# ==============================================================================

func test_arm_does_not_create_anything():
	var creator := _armed_creator()
	assert_true(creator.is_active())
	assert_eq(creator.state, PBShapeCreator.State.ARMED)
	assert_null(creator.preview_node, "Arming creates no preview node")
	assert_eq(creator.shape_id, &"cube")
	assert_gt(creator.values.size(), 0, "Values seed from the shape defaults")

func test_reset_returns_to_inactive():
	var creator := _armed_creator()
	creator.reset()
	assert_false(creator.is_active())
	assert_eq(creator.shape_id, &"")

# ==============================================================================
# Base drag
# ==============================================================================

func test_begin_captures_the_surface_plane():
	var creator := _armed_creator()
	var wall_normal := Vector3(0, 0, -1)
	_begin_base(creator, Vector3(0, 1, 2), wall_normal)
	assert_eq(creator.state, PBShapeCreator.State.BASE)
	assert_eq(creator.plane_point, Vector3(0, 1, 2))
	assert_eq(creator.plane_normal, wall_normal, "The pressed surface's plane is captured")

func test_base_rect_grows_coplanar_with_the_plane():
	var creator := _armed_creator()
	_begin_base(creator, Vector3.ZERO)
	# Drag 2m along +X and 1m along +Z (both in the floor plane).
	creator.update_base(Vector3(2, 0, 1))
	assert_almost_eq(creator.u_size, 2.0, 0.0001)
	assert_almost_eq(creator.v_size, 1.0, 0.0001)
	assert_almost_eq(creator.rect_center.x, 1.0, 0.0001, "Rect center is the drag midpoint")
	# The size params follow the drag THROUGH THE FACING: the dominant drag
	# dimension re-pointed the arrow along +X, so local Z (depth) runs along
	# the drag and the lateral extent becomes the width.
	assert_almost_eq(creator.values["depth"], 2.0, 0.0001)
	assert_almost_eq(creator.values["width"], 1.0, 0.0001)

func test_base_on_a_wall_stays_coplanar_with_the_wall():
	var creator := _armed_creator()
	var wall := Vector3(0, 0, -1)  # normal faces -Z (a wall in the XY plane)
	_begin_base(creator, Vector3(0, 0, 3), wall)
	# Drag on the wall: motion in the XY plane, z stays put.
	creator.update_base(Vector3(2, 1, 3))
	# Facing followed the dominant horizontal drag → depth = 2 along the
	# wall; the wall-vertical extent (1) becomes the width (local X lands
	# vertical: x = normal x facing).
	assert_almost_eq(creator.values["depth"], 2.0, 0.0001)
	assert_almost_eq(creator.values["width"], 1.0, 0.0001,
		"The wall's vertical extent maps to the width dim (local x lands vertical)")

func test_height_stage_on_a_wall_grows_along_the_normal():
	var creator := _armed_creator()
	var wall := Vector3(0, 0, -1)
	_begin_base(creator, Vector3(0, 0, 3), wall)
	creator.update_base(Vector3(2, 1, 3))
	creator.end_base()
	# Phase 2: pull AWAY from the wall — the normal faces -Z, so away = z→0.
	creator.update_height_point(Vector3(0, 0, 0))
	assert_almost_eq(creator.height, 3.0, 0.0001, "Height reads along the wall normal")
	assert_almost_eq(creator.values["height"], 3.0, 0.0001,
		"The normal extent is the height param — the placement basis points local Y "
		+ "along the face normal, so the shape grows ALONG the face")
	assert_almost_eq(creator.values["depth"], 2.0, 0.0001,
		"The wall-horizontal drag extent stays (local z runs along the wall)")
	assert_almost_eq(creator.values["width"], 1.0, 0.0001,
		"The wall-vertical extent from the base drag stays (local x lands vertical)")

func test_base_drag_snaps_to_world_axes_on_aligned_surfaces():
	var creator := _armed_creator()
	_begin_base(creator, Vector3.ZERO)  # floor: axis aligned
	creator.update_base(Vector3(2, 0, 1))  # mostly-X diagonal drag
	assert_eq(creator.u_dir, Vector3.RIGHT,
		"The drag axis snaps to the dominant world axis (axis-aligned creation)")
	assert_almost_eq(creator.values["depth"], 2.0, 0.0001,
		"The dominant drag extent is the depth (local z runs along the arrow)")

func test_arbitrary_surfaces_keep_the_drag_direction():
	var creator := _armed_creator()
	var tilted := Vector3(0.3, 0.8, 0.52).normalized()
	creator.begin(Vector3.ZERO, tilted, Vector3(0, 0, -1))
	var drag := _project(Vector3(2.0, 0, 0.7), tilted)
	creator.update_base(creator.plane_point + drag)
	assert_lt(absf(creator.u_dir.dot(tilted)), 0.001, "u stays in the plane")
	assert_gt(absf(creator.u_dir.dot(drag.normalized())), 0.999,
		"Non-axis-aligned faces follow the drag direction, not world axes")

static func _project(v: Vector3, normal: Vector3) -> Vector3:
	return v - normal * v.dot(normal)

func test_base_rect_corners_frame_the_drag():
	var creator := _armed_creator()
	_begin_base(creator, Vector3.ZERO)
	creator.update_base(Vector3(4, 0, 2))
	var corners := creator.base_rect_corners()
	assert_eq(corners.size(), 4)
	for c in corners:
		assert_almost_eq(c.y, 0.0, 0.0001, "Corners lie in the base plane")
	var xs: Array = []
	var zs: Array = []
	for c in corners:
		if not xs.has(c.x):
			xs.append(c.x)
		if not zs.has(c.z):
			zs.append(c.z)
	assert_eq(xs.size(), 2, "Two x extremes")
	assert_almost_eq(absf(xs[0] - xs[1]), 4.0, 0.0001, "Rect spans the u extent")
	assert_eq(zs.size(), 2, "Two z extremes")
	assert_almost_eq(absf(zs[0] - zs[1]), 2.0, 0.0001, "Rect spans the v extent")

func test_tiny_base_drag_aborts():
	var creator := _armed_creator()
	_begin_base(creator, Vector3.ZERO)
	creator.update_base(Vector3(0.01, 0, 0))  # a stray click, not a drag
	assert_false(creator.end_base(), "A sub-minimum drag aborts creation")
	assert_false(creator.is_active(), "Aborted creation leaves nothing behind")

func test_normal_release_enters_height_state():
	var creator := _armed_creator()
	_begin_base(creator, Vector3.ZERO)
	creator.update_base(Vector3(2, 0, 2))
	assert_true(creator.end_base())
	assert_eq(creator.state, PBShapeCreator.State.HEIGHT)

# ==============================================================================
# Height + confirm
# ==============================================================================

func test_height_follows_the_reference_point():
	var creator := _armed_creator()
	_drag_cube_base(creator)
	creator.update_height_point(Vector3(1, 3, 1))
	assert_almost_eq(creator.height, 3.0, 0.0001, "Height reads along the surface normal")
	assert_almost_eq(creator.values["height"], 3.0, 0.0001)

func test_negative_height_grows_below_the_surface():
	var creator := _armed_creator()
	_drag_cube_base(creator)
	creator.update_height_point(Vector3(1, -2, 1))
	assert_almost_eq(creator.height, -2.0, 0.0001, "Negative height grows below the plane")

func test_confirm_keeps_the_shape_and_opens_params():
	var creator := _armed_creator()
	_drag_cube_base(creator)
	creator.update_height_point(Vector3(1, 2, 1))
	creator.confirm_height()
	assert_eq(creator.state, PBShapeCreator.State.PARAMS,
		"The confirming click opens the params modal state")
	assert_almost_eq(creator.session_values["height"], 2.0, 0.0001,
		"Session snapshot taken at modal open")

func test_cancel_params_restores_session_values():
	var creator := _armed_creator()
	_drag_cube_base(creator)
	creator.update_height_point(Vector3(1, 2, 1))
	creator.confirm_height()
	creator.set_param("width", 9.0)
	creator.cancel_params()
	assert_almost_eq(creator.values["width"], 2.0, 0.0001,
		"Cancel resets params to the values at modal open")
	assert_almost_eq(creator.values["height"], 2.0, 0.0001)

func _drag_cube_base(creator: PBShapeCreator) -> void:
	creator.begin(Vector3.ZERO, Vector3.UP, Vector3(0, 0, -1))
	creator.update_base(Vector3(2, 0, 2))
	creator.end_base()

# ==============================================================================
# Placement
# ==============================================================================

func test_placement_anchors_the_base_face_on_the_plane():
	var creator := _armed_creator()
	creator.begin(Vector3(10, 0, -5), Vector3.UP, Vector3(0, 0, -1))
	creator.update_base(Vector3(12, 0, -3))
	creator.end_base()
	creator.update_height_point(Vector3(12, 4, -3))

	var data := creator.build_data()
	var xf := creator.placement_transform(data)
	# The data's bottom face (-y) must land on y=0 (the drag plane).
	var min_y: float = data.positions[0].y
	for p in data.positions:
		min_y = minf(min_y, p.y)
	var world_y: float = (xf * Vector3(0, min_y, 0)).y
	assert_almost_eq(world_y, 0.0, 0.001, "The shape's base sits IN the drag plane")

	# The rect center anchors horizontally.
	var world_origin: Vector3 = xf.origin
	assert_almost_eq(world_origin.x, 11.0, 0.001, "Centered on the base rect (x)")
	assert_almost_eq(world_origin.z, -4.0, 0.001, "Centered on the base rect (z)")

func test_negative_height_anchors_the_top_face():
	var creator := _armed_creator()
	creator.begin(Vector3.ZERO, Vector3.UP, Vector3(0, 0, -1))
	creator.update_base(Vector3(2, 0, 2))
	creator.end_base()
	creator.update_height_point(Vector3(1, -3, 1))
	var data := creator.build_data()
	var xf := creator.placement_transform(data)
	var max_y: float = data.positions[0].y
	for p in data.positions:
		max_y = maxf(max_y, p.y)
	var world_y: float = (xf * Vector3(0, max_y, 0)).y
	assert_almost_eq(world_y, 0.0, 0.001,
		"Growing downward anchors the TOP face to the plane")

func test_placement_basis_aligns_with_the_surface():
	var creator := _armed_creator()
	var wall := Vector3(0, 0, -1)
	creator.begin(Vector3.ZERO, wall, Vector3(0, 0, -1))
	creator.update_base(Vector3(2, 1, 0))
	creator.end_base()
	var data := creator.build_data()
	var xf := creator.placement_transform(data)
	var basis_y: Vector3 = xf.basis.y
	assert_almost_eq(basis_y.dot(wall), 1.0, 0.001,
		"The shape's local up axis aligns with the surface normal")

# ==============================================================================
# Facing arrow heuristic + flat start (v0.9.6)
# ==============================================================================

func test_facing_follows_the_dominant_drag_dimension():
	var creator := _armed_creator()
	_begin_base(creator, Vector3.ZERO)
	creator.update_base(Vector3(2, 0, 0.2))  # dominant +X step
	assert_almost_eq(absf(creator.facing.normalized().dot(Vector3.RIGHT)), 1.0, 0.001,
		"The facing arrow follows the dominant drag dimension")
	assert_gt(creator.facing.dot(Vector3.RIGHT), 0.0,
		"The arrow points away from the drag start")
	# A lateral step bigger than the dead zone re-points it.
	creator.update_base(Vector3(2.1, 0, 1.5))  # this step is dominated by +Z
	assert_almost_eq(absf(creator.facing.normalized().dot(Vector3.BACK)), 1.0, 0.001,
		"A dominant lateral step re-points the arrow")
	# Tiny steps never flip it (dead zone).
	creator.update_base(Vector3(2.1, 0, 1.52))
	assert_almost_eq(creator.facing.normalized().dot(Vector3.BACK), 1.0, 0.001,
		"Sub-dead-zone nudges keep the facing stable")

func test_facing_locks_at_base_release():
	var creator := _armed_creator()
	_begin_base(creator, Vector3.ZERO)
	creator.update_base(Vector3(2, 0, 0.2))
	creator.end_base()
	var before: Vector3 = creator.facing
	# Height-stage motion must NOT re-point the arrow (locked at release).
	creator.update_height_point(Vector3(3, 0.5, 0.2))
	creator.update_height_point(Vector3(-1.5, 1.5, 0.2))
	assert_almost_eq(creator.height, 1.5, 0.0001, "Height still reads along the normal")
	assert_eq(creator.facing, before,
		"The facing arrow locks once the base drag is released")

func test_end_base_starts_flat_on_the_surface():
	var creator := _armed_creator()
	creator.begin(Vector3.ZERO, Vector3.UP, Vector3(-1, 0, 0))
	creator.update_base(Vector3(2, 0, 2))
	assert_true(creator.end_base())
	assert_almost_eq(creator.height, 0.0, 0.0001, "Release lands at height 0")
	assert_almost_eq(creator.values["height"], 0.05, 0.0001,
		"The preview is a flat slab (min height), sitting ON the surface")
	var data := creator.build_data()
	var xf := creator.placement_transform(data)
	var min_y: float = data.positions[0].y
	for p in data.positions:
		min_y = minf(min_y, p.y)
	assert_almost_eq((xf * Vector3(0, min_y, 0)).y, 0.0, 0.001,
		"The flat preview's base lies IN the drag plane (no sub-surface start)")

func test_placement_basis_points_z_along_facing():
	var creator := _armed_creator()
	creator.begin(Vector3.ZERO, Vector3.UP, Vector3(-1, 0, 0))
	creator.update_base(Vector3(2, 0, 0.2))  # dominant +X → facing ≈ +X
	creator.end_base()
	var data := creator.build_data()
	var xf := creator.placement_transform(data)
	assert_almost_eq(xf.basis.z.dot(Vector3.RIGHT), 1.0, 0.001,
		"Local +Z (the shape's forward, e.g. the stairs' high side) follows facing")
	assert_almost_eq(xf.basis.y.dot(Vector3.UP), 1.0, 0.001,
		"Local +Y stays on the surface normal")
	assert_almost_eq(xf.basis.x.dot(Vector3.FORWARD), 1.0, 0.001,
		"The basis stays right-handed: x = normal x facing")

# ==============================================================================
# Ray helpers
# ==============================================================================

func test_ray_plane_intersect_hits_and_misses():
	var hit := PBShapeCreator.ray_plane_intersect(
		Vector3(0, 5, 0), Vector3(0, -1, 0), Vector3.ZERO, Vector3.UP)
	assert_almost_eq(hit.y, 0.0, 0.0001, "Straight-down ray hits the floor at origin")
	assert_eq(hit, Vector3.ZERO)

	var miss := PBShapeCreator.ray_plane_intersect(
		Vector3(0, 5, 0), Vector3(0, 0, -1), Vector3.ZERO, Vector3.UP)
	assert_eq(miss, PBShapeCreator.RAY_MISS, "Parallel rays miss")

	var behind := PBShapeCreator.ray_plane_intersect(
		Vector3(0, 5, 0), Vector3(0, 1, 0), Vector3.ZERO, Vector3.UP)
	assert_eq(behind, PBShapeCreator.RAY_MISS, "Rays pointing away miss")

func test_height_reference_projects_through_the_cursor():
	# Camera at +Z looking at -Z; the reference plane is view-parallel.
	var ref := PBShapeCreator.height_reference_point(
		Vector3(0, 0, 10), Vector3(0, 0, -1),     # camera origin/dir
		Vector3(0, 0, 10), Vector3(0, -0.5, -1),  # ray aimed downward-forward
		Vector3.ZERO)
	assert_almost_eq(ref.z, 0.0, 0.0001, "Reference stays in the view-parallel plane")
	assert_lt(ref.y, 0.0, "Aiming below center reads a negative height")
