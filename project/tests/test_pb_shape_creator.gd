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

## A slab dragged DOWN out of the plane is as thick as the drag. The parameter
## used to be the raw signed height clamped to the 0.1 m minimum, so a floor
## dragged 0.5 m downward came out 0.1 m thick — which is how the showcase's
## courtyard floor became a wafer z-fighting the grid.
func test_negative_height_keeps_the_dragged_magnitude():
	var creator := _armed_creator()
	creator.begin(Vector3.ZERO, Vector3.UP, Vector3(0, 0, -1))
	creator.update_base(Vector3(6, 0, 6))
	creator.end_base()
	creator.update_height_point(Vector3(6, -0.5, 6))
	assert_almost_eq(creator.height, -0.5, 0.0001, "The drag itself stays signed")
	assert_almost_eq(creator.values["height"], 0.5, 0.0001,
		"The parameter is the MAGNITUDE of the drag, not a clamped 0.1")
	var data := creator.build_data()
	var lo := INF
	var hi := -INF
	for p in data.positions:
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
	assert_almost_eq(hi - lo, 0.5, 0.001, "The slab is 0.5 m thick")
	var xf := creator.placement_transform(data)
	assert_almost_eq((xf * Vector3(0, hi, 0)).y, 0.0, 0.001,
		"And its top face lands in the drag plane")

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
	creator.update_base(Vector3(2, 0, 0.2))  # dominant +X rect
	assert_almost_eq(absf(creator.facing.normalized().dot(Vector3.RIGHT)), 1.0, 0.001,
		"The facing arrow follows the dominant drag dimension")
	assert_gt(creator.facing.dot(Vector3.RIGHT), 0.0,
		"The arrow points away from the drag start")
	# Dragging the SAME rect until the other axis dominates re-points the arrow
	# (the rect's aspect decides; the base drag is never read as a "nudge").
	creator.update_base(Vector3(2.1, 0, 3.5))
	assert_almost_eq(absf(creator.facing.normalized().dot(Vector3.BACK)), 1.0, 0.001,
		"Once the other axis dominates, the arrow follows it")
	# Tiny steps never flip it (dead zone).
	creator.update_base(Vector3(2.1, 0, 3.52))
	assert_almost_eq(creator.facing.normalized().dot(Vector3.BACK), 1.0, 0.001,
		"Sub-dead-zone rect changes keep the facing stable")

func test_stairs_facing_biased_along_longer_dimension():
	var creator := _armed_creator(&"stair")
	_begin_base(creator, Vector3.ZERO)
	# Drag 3m along X, 1m along Z: stairs must naturally run along X (longer)
	creator.update_base(Vector3(3.0, 0, 1.0))
	assert_almost_eq(absf(creator.facing.dot(Vector3.RIGHT)), 1.0, 0.001,
		"Stairs facing naturally points along the longer dimension (+X)")
	# Drag 1m along X, 3m along Z: stairs must naturally run along Z (longer)
	var creator2 := _armed_creator(&"stair")
	_begin_base(creator2, Vector3.ZERO)
	creator2.update_base(Vector3(1.0, 0, 3.0))
	assert_almost_eq(absf(creator2.facing.dot(Vector3.BACK)), 1.0, 0.001,
		"Stairs facing naturally points along the longer dimension (+Z)")

func test_door_facing_biased_parallel_to_shorter_dimension():
	var creator := _armed_creator(&"door")
	_begin_base(creator, Vector3.ZERO)
	# Drag 2.5m along X, 0.4m along Z: door must naturally face along Z (shorter, wall thickness)
	creator.update_base(Vector3(2.5, 0, 0.4))
	assert_almost_eq(absf(creator.facing.dot(Vector3.BACK)), 1.0, 0.001,
		"Door facing naturally points parallel to the shorter dimension (+Z)")
	# Drag 0.4m along X, 2.5m along Z: door must naturally face along X (shorter, wall thickness)
	var creator2 := _armed_creator(&"door")
	_begin_base(creator2, Vector3.ZERO)
	creator2.update_base(Vector3(0.4, 0, 2.5))
	assert_almost_eq(absf(creator2.facing.dot(Vector3.RIGHT)), 1.0, 0.001,
		"Door facing naturally points parallel to the shorter dimension (+X)")


## REGRESSION (showcase map act): an ordinary drag out of a 4 x 1 m wall
## footprint walked the door's facing 90 degrees mid-drag. The drag grows the
## rect along X, the door faces along Z, so every frame's motion is
## perpendicular to the facing — indistinguishable from the old "nudge" rule,
## which fired and swapped the extents: the doorway came out 1 m wide with its
## frame legs clamped over the opening, i.e. a plain slab in the middle of the
## courtyard. The facing must follow the rect's aspect and nothing else.
func test_dragging_a_door_along_its_width_never_rotates_it():
	var creator := _armed_creator(&"door")
	_begin_base(creator, Vector3.ZERO)
	for t in [0.25, 0.5, 0.75, 1.0]:
		creator.update_base(Vector3(4.0 * t, 0, 1.0 * t))
		assert_almost_eq(absf(creator.facing.dot(Vector3.BACK)), 1.0, 0.001,
			"The door keeps facing across its width for the whole drag (t=%.2f)" % t)
		assert_almost_eq(creator.values["width"], maxf(0.1, 4.0 * t), 0.0001,
			"width follows the extent across the facing (t=%.2f)" % t)
		assert_almost_eq(creator.values["depth"], maxf(0.1, 1.0 * t), 0.0001,
			"depth follows the thin extent (t=%.2f)" % t)
	creator.end_base()
	creator.update_height_point(Vector3(0, 4.0, 0))
	var data := creator.build_data()
	var aabb := AABB(data.positions[0], Vector3.ZERO)
	for p in data.positions:
		aabb = aabb.expand(p)
	assert_almost_eq(aabb.size.x, 4.0, 0.001, "the doorway spans the 4 m drag")
	assert_almost_eq(aabb.size.z, 1.0, 0.001, "the doorway is one wall deep")
	# ...and the opening is a doorway, not a slab: the two frame legs together
	# leave most of the 4 m width open.
	var open_w: float = 4.0 - 2.0 * float(creator.values["leg_width"])
	assert_gt(open_w, 2.0, "the opening stays wide (%.2f m)" % open_w)


func test_facing_hysteresis_prevents_ping_pong_near_square():
	var creator := _armed_creator(&"door")
	_begin_base(creator, Vector3.ZERO)
	# Drag 1.05m along X, 1.00m along Z (near square, within 0.15m deadzone)
	creator.update_base(Vector3(1.05, 0, 1.00))
	var initial_facing: Vector3 = creator.facing
	# Slightly shift so Z becomes 1.06m (crosses 1.05m by 0.01m):
	# Because difference is within FACING_DEAD_ZONE, facing MUST NOT flip!
	creator.update_base(Vector3(1.05, 0, 1.06))
	assert_eq(creator.facing, initial_facing,
		"Near-square dimension crossover does not ping-pong facing")


func test_lock_direction_preserves_facing_during_drag():
	var creator := _armed_creator(&"stair")
	_begin_base(creator, Vector3.ZERO)
	# Drag 3m along X, 1m along Z: stairs naturally face along X
	creator.update_base(Vector3(3.0, 0, 1.0))
	assert_almost_eq(absf(creator.facing.dot(Vector3.RIGHT)), 1.0, 0.001,
		"Initially stairs face along +X (longer)")
	var locked_facing := creator.facing

	# Lock direction (simulating holding Ctrl)
	creator.lock_direction = true

	# Now drag Z to 5.0m (longer than X=3.0m, which would normally flip facing to Z)
	creator.update_base(Vector3(3.0, 0, 5.0))
	assert_eq(creator.facing, locked_facing,
		"Facing must stay strictly locked while lock_direction is true")

	# A further step along the same axis is ignored while locked
	creator.update_base(Vector3(3.0, 0, 5.5))
	assert_eq(creator.facing, locked_facing,
		"Facing is ignored while lock_direction is true")

	# Unlock direction (simulating releasing Ctrl)
	creator.lock_direction = false
	creator.update_base(Vector3(3.0, 0, 6.0))
	assert_almost_eq(absf(creator.facing.dot(Vector3.BACK)), 1.0, 0.001,
		"Facing updates naturally once lock_direction is released")
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
	assert_almost_eq(creator.values["height"], 0.1, 0.0001,
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
# Round shapes: the height drag resizes RELATIVE to the base (v0.9.13)
# ==============================================================================

func test_sphere_height_drag_resizes_relative_to_base():
	var creator := _armed_creator(&"sphere")
	creator.begin(Vector3.ZERO, Vector3.UP, Vector3(0, 0, -1))
	creator.update_base(Vector3(2, 0, 0))
	creator.end_base()
	assert_almost_eq(creator.values["radius"], 1.0, 0.0001, "Base rect 2m → footprint radius 1")
	creator.update_height_point(Vector3(0, 1, 0))
	assert_almost_eq(creator.values["radius"], 1.5, 0.0001,
		"1m mouse-up grows the radius by 0.5 — the top follows the cursor 1:1")
	creator.update_height_point(Vector3(0, -0.5, 0))
	assert_almost_eq(creator.values["radius"], 0.75, 0.0001,
		"Mouse-down shrinks the sphere (used to be a dead zone)")

func test_sphere_negative_height_stays_on_the_surface():
	var creator := _armed_creator(&"sphere")
	creator.begin(Vector3.ZERO, Vector3.UP, Vector3(0, 0, -1))
	creator.update_base(Vector3(2, 0, 0))
	creator.end_base()
	creator.update_height_point(Vector3(0, -0.8, 0))
	var data := creator.build_data()
	var xf := creator.placement_transform(data)
	var min_y: float = data.positions[0].y
	for p in data.positions:
		min_y = minf(min_y, p.y)
	assert_almost_eq((xf * Vector3(0, min_y, 0)).y, 0.0, 0.001,
		"A negative drag SHRINKS the sphere on the surface — it never flips underground")

func test_torus_height_drag_thickens_the_tube():
	var creator := _armed_creator(&"torus")
	creator.begin(Vector3.ZERO, Vector3.UP, Vector3(0, 0, -1))
	creator.update_base(Vector3(3, 0, 0))
	creator.end_base()
	assert_almost_eq(creator.values["outer_radius"], 1.5, 0.0001)
	assert_almost_eq(creator.values["tube_radius"], 0.15, 0.0001)
	creator.update_height_point(Vector3(0, 0.5, 0))
	assert_almost_eq(creator.values["outer_radius"], 1.5, 0.0001,
		"The height drag no longer inflates the ring (it used to fight the mouse)")
	assert_almost_eq(creator.values["tube_radius"], 0.4, 0.0001,
		"The height drag thickens the tube — the 3rd dimension follows the mouse")

func test_arch_height_drag_grows_and_shrinks_one_to_one():
	var creator := _armed_creator(&"arch")
	creator.begin(Vector3.ZERO, Vector3.UP, Vector3(0, 0, -1))
	# Two-step drag: the long 2m extent accumulates first, then the lateral
	# 0.4m step re-points the facing onto itself — the span lands in the
	# width slot (the arch's local X) with the wall depth along the facing.
	creator.update_base(Vector3(2.0, 0, 0))
	creator.update_base(Vector3(2.0, 0, 0.4))
	creator.end_base()
	assert_almost_eq(creator.values["radius"], 1.0, 0.0001, "The 2m lateral span → radius 1")
	assert_almost_eq(creator.values["depth"], 0.4, 0.0001, "The facing extent → wall depth")
	creator.update_height_point(Vector3(0, 0.5, 0))
	assert_almost_eq(creator.values["radius"], 1.5, 0.0001,
		"The arch's top follows the cursor 1:1 (rate 1.0 — no slow crawl)")
	creator.update_height_point(Vector3(0, -0.5, 0))
	assert_almost_eq(creator.values["radius"], 0.5, 0.0001,
		"The arch shrinks below its base size (used to be stuck at a minimum)")

# ==============================================================================
# Sprite anchor flow (v0.9.13): click → offset along the normal → click
# ==============================================================================

func test_sprite_anchors_without_a_base_drag():
	var creator := _armed_creator(&"sprite")
	creator.begin_anchor(Vector3(1, 2, 3), Vector3.BACK, Vector3(0, 0, -1))
	assert_eq(creator.state, PBShapeCreator.State.OFFSET,
		"A sprite press anchors immediately — no base rect stage")
	assert_almost_eq(creator.values["width"], 1.0, 0.0001,
		"The sprite keeps its default size (no base rect to size it)")
	assert_almost_eq(creator.values["depth"], 1.0, 0.0001)
	assert_almost_eq(creator.height, 0.0, 0.0001, "The offset starts at the surface")

func test_sprite_offset_follows_the_normal():
	var creator := _armed_creator(&"sprite")
	creator.begin_anchor(Vector3.ZERO, Vector3.BACK, Vector3(0, 0, -1))
	creator.update_height_point(Vector3(0, 0, 0.75))
	assert_almost_eq(creator.height, 0.75, 0.0001, "Offset reads along the surface normal")
	var data := creator.build_data()
	var xf := creator.placement_transform(data)
	assert_almost_eq(xf.basis.y.dot(Vector3.BACK), 1.0, 0.001,
		"The sprite's plane stays parallel to the surface")
	assert_almost_eq(xf.origin.z, 0.75, 0.001,
		"The offset displaces the sprite off the surface")
	creator.confirm_height()
	assert_eq(creator.state, PBShapeCreator.State.PARAMS, "The next click confirms")

func test_sprite_negative_offset_never_passes_through_the_surface():
	var creator := _armed_creator(&"sprite")
	creator.begin_anchor(Vector3.ZERO, Vector3.BACK, Vector3(0, 0, -1))
	creator.update_height_point(Vector3(0, 0, -2.0))
	assert_almost_eq(creator.height, 0.0, 0.0001, "The offset clamps at the surface")
	var data := creator.build_data()
	var xf := creator.placement_transform(data)
	assert_almost_eq(xf.origin.z, 0.0, 0.001,
		"A behind-the-cursor ray pins the sprite IN the surface plane")

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

func test_door_drag_maps_width_to_the_dominant_extent():
	## REGRESSION (v0.9.16): the dominant-step facing heuristic (built for
	## stairs) ran for the door too — a wide, thin base drag mapped the thin
	## extent onto width and the door grew as a 0.3m-wide tunnel, leaving
	## the height drag nothing visible to size. The door's front runs ACROSS
	## its dominant extent: width = the bigger drag, facing perpendicular.
	var creator := _armed_creator(&"door")
	_begin_base(creator, Vector3.ZERO)
	creator.update_base(Vector3(2.5, 0, 0.3))
	creator.end_base()
	assert_almost_eq(creator.values["width"], 2.5, 0.0001,
		"The dominant extent is the width (the door's face, not a tunnel)")
	assert_almost_eq(creator.values["depth"], 0.3, 0.0001)
	# The facing runs across the width: the front points along +Z here.
	assert_almost_eq(absf(creator.facing.dot(Vector3.BACK)), 1.0, 0.001,
		"The facing is perpendicular to the width (the front contains it)")
	# And the height drag sizes the standing door.
	creator.update_height_point(Vector3(0, 2.0, 0))
	assert_almost_eq(creator.values["height"], 2.0, 0.0001)
	var data := creator.build_data()
	assert_almost_eq(data.positions[0].y * 2.0, 0.0, 4.0)  # (sanity: builds)
	var aabb := AABB(data.positions[0], Vector3.ZERO)
	for p in data.positions:
		aabb = aabb.expand(p)
	assert_almost_eq(aabb.size.y, 2.0, 0.001, "The placed door stands 2m tall")
	assert_almost_eq(aabb.size.x, 2.5, 0.001, "The placed door spans the dominant drag")


func test_door_extends_to_wide_base_even_when_not_tall():
	var creator := _armed_creator(&"door")
	_begin_base(creator, Vector3.ZERO)
	# Drag 6.0m along X, 0.4m along Z
	creator.update_base(Vector3(6.0, 0, 0.4))
	creator.end_base()
	assert_almost_eq(creator.values["width"], 6.0, 0.0001, "Width spans full 6m base")
	# Short height of 1.5m
	creator.update_height_point(Vector3(0, 1.5, 0))
	assert_almost_eq(creator.values["height"], 1.5, 0.0001)
	var data := creator.build_data()
	var aabb := AABB(data.positions[0], Vector3.ZERO)
	for p in data.positions:
		aabb = aabb.expand(p)
	assert_almost_eq(aabb.size.x, 6.0, 0.001, "Door mesh spans full 6m dragged area")
	assert_almost_eq(aabb.size.y, 1.5, 0.001, "Door mesh height is 1.5m")
func test_door_drag_mapping_is_drag_order_independent():
	## The same footprint drawn in either direction must produce the same
	## door (the old heuristic made creation nondeterministic).
	var a := _armed_creator(&"door")
	_begin_base(a, Vector3.ZERO)
	a.update_base(Vector3(2.5, 0, 0.3))
	a.end_base()
	var b := _armed_creator(&"door")
	_begin_base(b, Vector3.ZERO)
	b.update_base(Vector3(0.3, 0, 2.5))
	b.end_base()
	assert_almost_eq(b.values["width"], a.values["width"], 0.0001)
	assert_almost_eq(b.values["depth"], a.values["depth"], 0.0001)

func test_creator_extents_readout_in_all_states():
	var c := _armed_creator(&"cube")
	assert_eq(c.get_extents_readout(), "", "Armed state has empty extents")

	# BASE phase
	_begin_base(c, Vector3.ZERO)
	c.update_base(Vector3(3.5, 0.0, 2.0))
	var base_ro := c.get_extents_readout()
	assert_true(base_ro.contains("3.50m"), "Base readout contains width")
	assert_true(base_ro.contains("2.00m"), "Base readout contains depth")

	# HEIGHT phase
	c.end_base()
	c.update_height_point(Vector3(0.0, 1.8, 0.0))
	var height_ro := c.get_extents_readout()
	assert_true(height_ro.contains("1.80m"), "Height readout contains height")

	# Cylinder (radius shape)
	var cyl := _armed_creator(&"cylinder")
	_begin_base(cyl, Vector3.ZERO)
	cyl.update_base(Vector3(2.0, 0.0, 2.0))
	assert_true(cyl.get_extents_readout().contains("Radius"), "Cylinder base readout shows Radius")
	cyl.end_base()
	cyl.update_height_point(Vector3(0.0, 4.0, 0.0))
	assert_true(cyl.get_extents_readout().contains("Height"), "Cylinder height readout shows Height")

func test_creator_show_height_plane_toggle():
	var c := _armed_creator(&"cube")
	assert_false(c.show_height_plane)
	c.show_height_plane = true
	assert_true(c.show_height_plane)
	c.reset()
	assert_false(c.show_height_plane, "Resetting creator turns off height plane")

func test_creator_cursor_extents_text_xyz():
	var c := _armed_creator(&"cube")
	assert_eq(c.get_cursor_extents_text(), "", "Armed state has empty cursor text")

	# BASE phase: shows dimensions of base box as (X, Y, 0.00)
	_begin_base(c, Vector3.ZERO)
	c.update_base(Vector3(4.0, 0.0, 2.5))
	assert_eq(c.get_cursor_extents_text(), "(4.00, 2.50, 0.00)", "Base phase shows (X, Y, 0.00)")

	# HEIGHT phase: shows (X, Y, Z) with live height as Z
	c.end_base()
	c.update_height_point(Vector3(0.0, 1.8, 0.0))
	assert_eq(c.get_cursor_extents_text(), "(4.00, 2.50, 1.80)", "Height phase shows (X, Y, Z)")

# ==============================================================================
# Stand-off planes: world-aligned in-plane axes (v0.9.79)
# ==============================================================================

## REGRESSION (showcase map act): a plane drawn on a wall took its in-plane
## axes from the DRAG, so the sheet's V axis (its texture flow) ran sideways
## along the wall and the pool's ran across the floor instead of away from the
## wall — "the scrolling textures flow the wrong way". A plane's axes come from
## the world now: V points DOWN on a wall, +Z on a floor, which is the shipped
## map's own convention for its water sheets and pool.
func test_plane_flow_axis_points_down_a_wall_and_back_on_a_floor():
	assert_eq(PBShapeParams.plane_flow_axis(Vector3.UP), Vector3.BACK,
		"A floor plane flows along +Z (away from the wall behind it)")
	assert_eq(PBShapeParams.plane_flow_axis(Vector3.DOWN), Vector3.BACK,
		"A ceiling plane flows along +Z too")
	assert_eq(PBShapeParams.plane_flow_axis(Vector3.BACK), Vector3.DOWN,
		"A wall plane flows DOWN the wall")
	assert_eq(PBShapeParams.plane_flow_axis(Vector3.RIGHT), Vector3.DOWN)

func test_plane_on_a_wall_stands_v_down():
	var creator := _armed_creator(&"plane")
	# A wall at z = 0 facing the courtyard (+Z), the map act's sheet footprint.
	_begin_base(creator, Vector3(3.5, 0.1, 0.0), Vector3.BACK)
	creator.update_base(Vector3(5.5, 4.3, 0.0))
	creator.end_base()
	assert_almost_eq(creator.values["width"], 2.0, 0.0001, "the drag's width is the sheet's width")
	assert_almost_eq(creator.values["depth"], 4.2, 0.0001, "the drag's height is the sheet's depth")
	var data := creator.build_data()
	var xf := creator.placement_transform(data)
	assert_almost_eq(xf.basis.z.dot(Vector3.DOWN), 1.0, 0.001,
		"The sheet's V axis runs DOWN the wall (falling water falls)")
	assert_almost_eq(absf(xf.basis.y.dot(Vector3.BACK)), 1.0, 0.001,
		"The sheet's normal is the wall's normal")
	assert_almost_eq(xf.basis.x.dot(Vector3.RIGHT), 1.0, 0.001,
		"...and its U axis runs along the wall")

func test_plane_on_a_floor_keeps_world_axes():
	var creator := _armed_creator(&"plane")
	_begin_base(creator, Vector3(2.7, 0.0, -5.0), Vector3.UP)
	creator.update_base(Vector3(6.3, 0.0, -1.8))
	creator.end_base()
	assert_almost_eq(creator.values["width"], 3.6, 0.0001)
	assert_almost_eq(creator.values["depth"], 3.2, 0.0001)
	var data := creator.build_data()
	var xf := creator.placement_transform(data)
	assert_almost_eq(xf.basis.x.dot(Vector3.RIGHT), 1.0, 0.001)
	assert_almost_eq(xf.basis.y.dot(Vector3.UP), 1.0, 0.001)
	assert_almost_eq(xf.basis.z.dot(Vector3.BACK), 1.0, 0.001,
		"The floor pool's flow axis runs +Z, away from the wall it was drawn against")

# ==============================================================================
# Trim placement (v0.9.108): the strip stands on the drag's start edge
# ==============================================================================

## REGRESSION: the trim used to be CENTERED on the drawn rect like every other
## shape, so a strip dragged along the base of a wall floated half a height
## off the wall instead of sitting flush against it. Per the Unibuilder spec
## the strip "stands up on the edge you started the drag from, so start at
## the wall": the back-bottom edge lands ON the start edge, the depth runs
## toward the drag side, and the drawn rect maps u → length, v → height (the
## depth is never dragged).
func test_trim_on_a_floor_stands_flush_on_the_start_edge():
	var creator := _armed_creator(&"trim")
	# Floor at y=0; a wall runs along X with its body at z < 0. The drag
	# starts at the wall base and wobbles slightly into the room (+z).
	_begin_base(creator, Vector3(0, 0, 0))
	creator.update_base(Vector3(4, 0, 0.2))
	creator.end_base()
	assert_almost_eq(creator.values["length"], 4.0, 0.0001, "u extent = length")
	assert_almost_eq(creator.values["height"], 0.2, 0.0001, "v extent = height")
	assert_almost_eq(creator.values["depth"], 0.05, 0.0001, "the depth is never dragged")
	var data := creator.build_data()
	var xf := creator.placement_transform(data)
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for p in data.positions:
		var w: Vector3 = xf * p
		lo = lo.min(w)
		hi = hi.max(w)
	assert_almost_eq(lo.y, 0.0, 0.001, "the strip stands ON the floor")
	assert_almost_eq(hi.y - lo.y, 0.2, 0.001, "...risks its height vertically")
	assert_almost_eq(lo.z, 0.0, 0.001, "the BACK sits on the start edge — flush with the wall at z=0")
	assert_almost_eq(hi.z - lo.z, 0.05, 0.001, "the depth runs toward the drag side (into the room)")
	assert_almost_eq(lo.x, 0.0, 0.001, "the strip spans the drag from its start")
	assert_almost_eq(hi.x - lo.x, 4.0, 0.001, "...to its end (length = u extent)")

## A drag that runs mostly toward -v flips the depth side, not the height:
## the strip's body must always end up on the side the mouse went.
func test_trim_depth_follows_the_drag_side():
	var creator := _armed_creator(&"trim")
	# Same wall, dragged with the wobble to -z (v_dir is -Z here, so the
	# perpendicular component is POSITIVE along v_dir).
	_begin_base(creator, Vector3(0, 0, 0))
	creator.update_base(Vector3(4, 0, -0.2))
	creator.end_base()
	var data := creator.build_data()
	var xf := creator.placement_transform(data)
	var lo := INF
	var hi := -INF
	for p in data.positions:
		var z: float = (xf * p).z
		lo = minf(lo, z)
		hi = maxf(hi, z)
	assert_almost_eq(hi, 0.0, 0.001, "the back still sits on the start edge")
	assert_almost_eq(lo, -0.05, 0.001, "the body follows the drag to -z")

## With Draw on Surface pointed at a wall the trim "lies flat on the wall,
## its bottom on the lower edge of the drag", protruding along the wall's
## normal into the room.
func test_trim_on_a_wall_lies_flat_with_its_bottom_on_the_lower_edge():
	var creator := _armed_creator(&"trim")
	# Wall plane z=0, its normal +Z (into the room). Drag 3 m along the wall
	# and 1.2 m UP the wall.
	_begin_base(creator, Vector3(0, 1, 0), Vector3.BACK)
	creator.update_base(Vector3(3, 2.2, 0))
	creator.end_base()
	assert_almost_eq(creator.values["length"], 3.0, 0.0001)
	assert_almost_eq(creator.values["height"], 1.2, 0.0001)
	var data := creator.build_data()
	var xf := creator.placement_transform(data)
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for p in data.positions:
		var w: Vector3 = xf * p
		lo = lo.min(w)
		hi = hi.max(w)
	assert_almost_eq(lo.z, 0.0, 0.001, "the back is ON the wall surface")
	assert_almost_eq(hi.z - lo.z, 0.05, 0.001, "the depth protrudes OUT of the wall")
	assert_almost_eq(lo.y, 1.0, 0.001, "the bottom sits on the drag's LOWER edge")
	assert_almost_eq(hi.y - lo.y, 1.2, 0.001, "the height spans the drag's vertical extent")
	assert_almost_eq(hi.x - lo.x, 3.0, 0.001, "the length runs along the drag")

func test_trim_faces_along_the_drag_not_the_aspect_heuristic():
	var creator := _armed_creator(&"trim")
	_begin_base(creator, Vector3(0, 0, 0))
	creator.update_base(Vector3(4, 0, 0.2))
	assert_almost_eq(creator.facing.normalized().dot(Vector3.RIGHT), 1.0, 0.001,
		"the run arrow follows the drag direction")
	# Growing the perpendicular extent must NOT re-point the run (no aspect
	# flip mid-drag — the strip keeps running the way it was drawn).
	creator.update_base(Vector3(4, 0, 2.0))
	assert_almost_eq(creator.facing.normalized().dot(Vector3.RIGHT), 1.0, 0.001,
		"the run never flips to the longer perpendicular extent")

## REGRESSION (the "trim goes UP instead" report): the u axis locks to the
## first centimetres of motion — a wall-base drag begun with a perpendicular
## wobble locked u INTO the room, the long along-wall extent landed in v, and
## the old u→length / v→height mapping stood the strip the whole drag length
## TALL. The longer side of the drawn rect is the run now, and the strip
## stands on the line through the drag start along it, so the back stays
## flush with the wall line no matter which way the lock picked.
func test_trim_run_follows_the_longer_side_not_the_u_lock():
	var creator := _armed_creator(&"trim")
	_begin_base(creator, Vector3(0, 0, 0))
	creator.update_base(Vector3(0, 0, 0.3))  # first motion locks u INTO the room (+Z)
	creator.update_base(Vector3(4, 0, 0.3))  # the real drag: along the wall
	creator.end_base()
	assert_almost_eq(creator.values["length"], 4.0, 0.0001, "the longer side of the rect is the run")
	assert_almost_eq(creator.values["height"], 0.3, 0.0001, "the perpendicular drift is the height")
	var data := creator.build_data()
	var xf := creator.placement_transform(data)
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for p in data.positions:
		var w: Vector3 = xf * p
		lo = lo.min(w)
		hi = hi.max(w)
	assert_almost_eq(hi.y - lo.y, 0.3, 0.001, "the strip rises its height — NOT the drag length")
	assert_almost_eq(lo.x, 0.0, 0.001, "the run spans the drag along the wall")
	assert_almost_eq(hi.x - lo.x, 4.0, 0.001)
	assert_almost_eq(lo.z, 0.0, 0.001, "the back sits on the wall line through the drag start")
	assert_almost_eq(hi.z - lo.z, 0.05, 0.001, "the depth runs toward the room (the drift side)")

## A mostly-vertical drag on a wall still comes out an upright moulding: the
## vertical extent is the height, the horizontal one the length.
func test_trim_on_a_wall_stays_upright_when_dragged_up():
	var creator := _armed_creator(&"trim")
	_begin_base(creator, Vector3(0, 1, 0), Vector3.BACK)
	creator.update_base(Vector3(0.2, 3.0, 0))  # mostly UP the wall
	creator.end_base()
	assert_almost_eq(creator.values["length"], 0.2, 0.0001, "the horizontal extent is the length")
	assert_almost_eq(creator.values["height"], 2.0, 0.0001, "the vertical extent is the height")
	var data := creator.build_data()
	var xf := creator.placement_transform(data)
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for p in data.positions:
		var w: Vector3 = xf * p
		lo = lo.min(w)
		hi = hi.max(w)
	assert_almost_eq(lo.y, 1.0, 0.001, "the bottom sits on the drag's lower edge")
	assert_almost_eq(hi.y - lo.y, 2.0, 0.001, "...and rises the vertical extent (upright)")
	assert_almost_eq(lo.z, 0.0, 0.001, "the back is on the wall surface")
	assert_almost_eq(hi.z - lo.z, 0.05, 0.001, "the depth protrudes out of the wall")

## Winding guard: the placed trim is a closed tube — its signed volume must
## stay POSITIVE (normals outward) for every surface and drag direction.
## A negative volume means an inverted (inside-out) trim. The basis is built
## x = y × z so it is always right-handed; this pins that contract.
func test_trim_world_winding_is_outward_on_every_surface():
	var cases := [
		# [begin point, surface normal, drag end]
		[Vector3(0, 0, 0), Vector3.UP, Vector3(4, 0, 0.2)],          # floor
		[Vector3(0, 0, 0), Vector3.UP, Vector3(4, 0, -0.2)],         # floor, wobble -z
		[Vector3(0, 3, 0), Vector3.DOWN, Vector3(3, 3, 0.3)],        # ceiling
		[Vector3(0, 1, 0), Vector3.BACK, Vector3(3, 2.2, 0)],        # wall, drag up
		[Vector3(0, 2.2, 0), Vector3.BACK, Vector3(3, 1.0, 0)],      # wall, drag down
		[Vector3(0, 1, 0), Vector3.FORWARD, Vector3(3, 2.0, 0)],       # opposite wall
		[Vector3(1, 1, 0), Vector3.RIGHT, Vector3(-1.5, 1.8, 0)],    # side wall
		[Vector3(0, 1, 0), Vector3(1, 1, 0).normalized(), Vector3(2, 1.6, 0)],  # ramp
	]
	for tc in cases:
		var creator := _armed_creator(&"trim")
		creator.begin(tc[0], tc[1], Vector3(-1, 0, 0))
		creator.update_base(tc[2])
		if not creator.end_base():
			continue
		var data := creator.build_data()
		var xf := creator.placement_transform(data)
		var world: Array[Vector3] = []
		for p in data.positions:
			world.append(xf * p)
		var vol := 0.0
		for f in data.faces:
			var idx := f.get_indexes()
			for i in range(0, idx.size(), 3):
				vol += world[idx[i]].dot(world[idx[i + 1]].cross(world[idx[i + 2]])) / 6.0
		assert_gt(vol, 0.0,
			"trim on %s points its normals OUTWARD (signed volume %f)" % [str(tc[1]), vol])
		assert_almost_eq(xf.basis.determinant(), 1.0, 0.001,
			"the placement basis is never mirrored")

## REGRESSION: the Trim Walls hover outline was pushed through the node's
## INVERSE transform even though get_face_positions is already local - the
## outline floated away from the face on any node with a transform. The
## stroke points must equal the local face polygon exactly.
func test_trim_wall_highlight_strokes_are_local_face_positions():
	var md := PBShapeParams.build(&"cube", {"width": 1.0, "height": 1.0, "depth": 1.0})
	var face := 0
	var poly := md.get_face_positions(face)
	# The gizmo draws exactly these points as the outline strokes.
	var stroke_pts := PackedVector3Array()
	for i in range(poly.size()):
		stroke_pts.append(poly[i])
		stroke_pts.append(poly[(i + 1) % poly.size()])
	assert_eq(stroke_pts.size(), poly.size() * 2)
	for i in range(0, stroke_pts.size(), 2):
		assert_true(poly.has(stroke_pts[i]),
			"every stroke vertex IS a face polygon vertex (no transform applied)")

# ==============================================================================
# Vertex snap (V-Snap) on the height/offset drag
# ==============================================================================

## The base rect drawn from (0,0,0) to (2,0,2) on the floor has corners at
## (0,0,0), (2,0,0), (2,0,2), (0,0,2) — snap sources for the rising shape.
func _height_state_creator() -> PBShapeCreator:
	var creator := PBShapeCreator.new()
	creator.arm(&"cube")
	creator.begin(Vector3.ZERO, Vector3.UP, Vector3(-1, 0, 0))
	creator.update_base(Vector3(2, 0, 2))
	creator.end_base()
	return creator

func test_height_drags_onto_a_nearby_vertex_when_v_snap_is_on():
	var creator := _height_state_creator()
	creator.vertex_snap_active_fn = func() -> bool: return true
	# A wall vertex 1.6m up, directly above the base corner at the origin.
	creator.vertex_snap_candidates_fn = func() -> PackedVector3Array:
		return PackedVector3Array([Vector3(0, 1.6, 0)])
	creator.update_height_point(Vector3(1, 1.45, 1))
	assert_almost_eq(creator.height, 1.6, 0.001,
		"height locks onto the vertex 0.15m from the raw drag (within the magnet radius)")

func test_height_passes_through_when_no_vertex_is_reachable():
	var creator := _height_state_creator()
	creator.vertex_snap_active_fn = func() -> bool: return true
	creator.vertex_snap_candidates_fn = func() -> PackedVector3Array:
		return PackedVector3Array([Vector3(0, 5.0, 0)])
	creator.update_height_point(Vector3(1, 1.45, 1))
	assert_almost_eq(creator.height, 1.45, 0.001,
		"a vertex 3.5m beyond the drag never catches")

func test_height_ignores_vertices_when_v_snap_is_off():
	var creator := _height_state_creator()
	creator.vertex_snap_active_fn = func() -> bool: return false
	creator.vertex_snap_candidates_fn = func() -> PackedVector3Array:
		return PackedVector3Array([Vector3(0, 1.6, 0)])
	creator.update_height_point(Vector3(1, 1.45, 1))
	assert_almost_eq(creator.height, 1.45, 0.001, "V-snap off → raw height")

func test_height_snap_sources_are_the_base_corners():
	# A candidate directly above the base CENTER (not a corner) must not
	# catch: corners are the sources, centers are not.
	var creator := _height_state_creator()
	creator.vertex_snap_active_fn = func() -> bool: return true
	creator.vertex_snap_candidates_fn = func() -> PackedVector3Array:
		return PackedVector3Array([Vector3(1, 1.5, 1)])
	creator.update_height_point(Vector3(1, 1.45, 1))
	assert_almost_eq(creator.height, 1.45, 0.001,
		"only base corners catch; the rect center is not a snap source")
