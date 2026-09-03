## PBShapeCreator — ProBuilder-style drag-to-create state machine.
##
## Pure logic + geometry (no editor classes, headless-testable). The plugin
## drives it from viewport input:
##
##   ARMED  — a shape was picked from the New Shape menu; waiting for an
##            LMB press on a surface (PBMesh face or the editor grid plane).
##   BASE   — LMB held: the base rect grows coplanar with the surface that
##            was pressed (the plane is captured at press and never changes).
##   HEIGHT — LMB released: mouse motion adjusts the 3rd dimension along the
##            surface normal (the shape preview grows from its base); the
##            next LMB click confirms.
##   OFFSET — the sprite flow only: a single CLICK anchors the shape ON the
##            surface, mouse motion then displaces it along the surface
##            normal, and the next click confirms (no base drag — a flat
##            sprite is drawn by parameters, not by dragging a rect).
##   PARAMS — the overlay parameter modal is open (live preview, Apply /
##            Cancel). Cancel restores session_values (the state at modal
##            open); neither destroys the shape — only ESC before the
##            confirming click aborts without creating anything.
##
## The plugin owns the preview PBMesh node; the creator supplies the data
## (PBShapeParams.build) and the placement transform that anchors the data's
## base face onto the drag plane at the rect center.
@tool
class_name PBShapeCreator
extends RefCounted

enum State { INACTIVE, ARMED, BASE, HEIGHT, OFFSET, PARAMS }

## Sentinel for "ray missed the plane" from ray_plane_intersect.
const RAY_MISS := Vector3(INF, INF, INF)

## Minimum base extent so a stray click cannot create a degenerate shape.
const MIN_EXTENT := 0.05

var state: State = State.INACTIVE

## The factory shape being created.
var shape_id: StringName = &""

## Current parameter values (starts from PBShapeParams defaults; the base
## drag writes the size dims, the modal writes anything).
var values: Dictionary = {}

## Snapshot of `values` at base release — the baseline the height drag applies
## against for round shapes (sphere/torus/arch resize RELATIVELY from here).
var base_values: Dictionary = {}

## Snapshot taken when the params modal opened — Cancel restores it.
var session_values: Dictionary = {}

## The captured creation plane (surface pressed at begin).
var plane_point: Vector3 = Vector3.ZERO
var plane_normal: Vector3 = Vector3.UP

## Orthonormal in-plane axis along the drag direction (u); the perpendicular
## in-plane axis is plane_normal.cross(u_dir).
var u_dir: Vector3 = Vector3.RIGHT

## False until the first meaningful drag motion locks the width axis: on
## axis-aligned surfaces u_dir then snaps to the nearest world axis
## (ProBuilder behavior — shapes come out axis aligned); on arbitrary
## surfaces it follows the drag direction in the surface plane.
var _u_locked: bool = false

## First press point and current rect center, both on the plane.
var base_start: Vector3 = Vector3.ZERO
var rect_center: Vector3 = Vector3.ZERO

## Base rect extents along u_dir / the in-plane perpendicular.
var u_size: float = 0.0
var v_size: float = 0.0

## Signed extent along the plane normal (negative = grows below the surface).
var height: float = 0.0

## In-plane world-space unit direction the shape's LOCAL +Z ("forward": the
## high side of stairs) points to. Follows the drag heuristic: the dimension
## (u or v) that received the biggest delta in the last significant movement,
## signed away from the drag start — so it can be nudged while placing.
var facing: Vector3 = Vector3.ZERO

## The corner of the base rect the cursor dragged out (world, on the plane):
## one end of the base drag, kept for the creation vertex gizmos.
var base_end: Vector3 = Vector3.ZERO

## Last surface point seen (drag steps are measured against it).
var _last_point: Vector3 = Vector3.ZERO

## Steps smaller than this don't re-point the facing arrow (dead zone).
## Set to 0.15m to prevent mouse tremors and jitter from ping-ponging the facing.
const FACING_DEAD_ZONE := 0.15

## Threshold difference between u_size and v_size to consider one dimension clearly dominant.
const ASPECT_BIAS_THRESHOLD := 0.20
## The live preview node (owned and managed by the plugin; the creator only
## supplies data + placement for it). Null while nothing is being drawn.
var preview_node: PBMesh = null

# ── Queries ──────────────────────────────────────────────────────────────────

func is_active() -> bool:
	return state != State.INACTIVE

## Local-space facing direction for the creation arrow (ZERO = none).
func facing_direction() -> Vector3:
	return PBShapeParams.facing_direction(shape_id)

## The world-space direction the creation arrow points to (unit, in-plane).
## Falls back to the shape's canonical facing before the drag starts.
func arrow_direction() -> Vector3:
	if facing.length_squared() > 0.5:
		return facing.normalized()
	return plane_normal.cross(u_dir).normalized()

## Builds the current shape data from the current values.
func build_data() -> PBMeshData:
	if shape_id == &"":
		return null
	return PBShapeParams.build(shape_id, values)

## Node transform placing `data` so its base face lies IN the drag plane,
## centered on rect_center. The basis orients local +Z along `facing` (the
## drag heuristic direction), local +Y along the surface normal — so e.g.
## stairs rise toward the arrow.
##
## Height sign anchors the base face (>= 0, sits on the surface) or the top
## face (< 0, grows below — ProBuilder behavior) — EXCEPT for shapes that
## must stay pinned to the surface (PBShapeParams.stays_on_surface): round
## shapes SHRINK on a negative drag rather than flipping underground, and the
## sprite rides the normal offset on top of its plane-aligned base.
func placement_transform(data: PBMeshData) -> Transform3D:
	var f := arrow_direction()
	var x_axis := plane_normal.cross(f).normalized()
	var basis := Basis(x_axis, plane_normal, f)
	var aabb := _aabb_of(data)
	var lift: float = -aabb.position.y
	if height < 0.0 and not PBShapeParams.stays_on_surface(shape_id):
		lift = -(aabb.position.y + aabb.size.y)
	elif PBShapeParams.height_drags_offset(shape_id):
		lift += height
	return Transform3D(basis, rect_center + plane_normal * lift)

# ── Transitions ──────────────────────────────────────────────────────────────

## Arms creation for `p_shape_id` (a New Shape menu pick). Nothing exists yet.
func arm(p_shape_id: StringName) -> void:
	state = State.ARMED
	shape_id = p_shape_id
	values = PBShapeParams.get_default_values(p_shape_id)
	session_values = {}

## Begins the base drag on the surface point/normal under the press. `view_z`
## is the camera's forward direction — the drag axis seeds from the view so
## horizontal drags feel natural on walls too.
func begin(surface_point: Vector3, surface_normal: Vector3, view_z: Vector3) -> void:
	state = State.BASE
	plane_point = surface_point
	plane_normal = surface_normal.normalized()
	# Seed the drag axis: camera forward projected into the plane, falling
	# back to the plane-perpendicular-of-up and then world X.
	var seed_dir: Vector3 = _project_on_plane(-view_z, plane_normal)
	if seed_dir.length_squared() < 0.01:
		seed_dir = _project_on_plane(Vector3.RIGHT, plane_normal)
	if seed_dir.length_squared() < 0.01:
		seed_dir = _project_on_plane(Vector3.UP.cross(plane_normal), plane_normal)
	u_dir = seed_dir.normalized() if seed_dir.length_squared() > 0.0001 else Vector3.RIGHT
	base_start = surface_point
	rect_center = surface_point
	u_size = 0.0
	v_size = 0.0
	height = 0.0
	_u_locked = false
	base_end = surface_point
	_last_point = surface_point
	# At rest the forward arrow sits along v (perpendicular to the drag seed)
	# so the initial extent mapping matches "u → width, v → depth"; the first
	# significant movement re-points it via the heuristic.
	facing = plane_normal.cross(u_dir).normalized()
	_apply_drag_extents()

## Updates the base rect from a point ON the captured plane. Height-driven
## values are untouched here (the base stage doesn't know the height yet).
## The first meaningful drag motion LOCKS the width axis: axis-aligned
## surfaces snap it to the nearest world axis (shapes come out axis
## aligned); arbitrary surfaces keep the drag direction in the plane.
func update_base(point_on_plane: Vector3) -> void:
	if state != State.BASE:
		return
	var drag := point_on_plane - base_start
	if not _u_locked and drag.length() > 0.05:
		var drag_in_plane := _project_on_plane(drag, plane_normal)
		if drag_in_plane.length_squared() > 0.0001:
			u_dir = _snap_axis(drag_in_plane)
			_u_locked = true
	var along_u := drag.dot(u_dir)
	var v_dir := plane_normal.cross(u_dir).normalized()
	var along_v := drag.dot(v_dir)
	u_size = absf(along_u)
	v_size = absf(along_v)
	rect_center = base_start + drag * 0.5
	base_end = point_on_plane
	_update_facing(point_on_plane, v_dir)
	_apply_drag_extents()

## Ends the base drag (LMB release). Returns false (and aborts) when the
## drag was too small to be intentional.
func end_base() -> bool:
	if state != State.BASE:
		return false
	if u_size < MIN_EXTENT and v_size < MIN_EXTENT:
		reset()
		return false
	state = State.HEIGHT
	height = 0.0
	# The values NOW are the baseline the height drag works against (round
	# shapes resize relative to their base-release footprint).
	base_values = values.duplicate()
	_apply_drag_extents()
	return true

## Sprite-style anchor placement: a single press pins the shape ON the
## surface (no base rect — the drag stages are skipped entirely); mouse
## motion then displaces it along the captured normal (OFFSET state).
func begin_anchor(surface_point: Vector3, surface_normal: Vector3, view_z: Vector3) -> void:
	begin(surface_point, surface_normal, view_z)
	state = State.OFFSET
	facing = Vector3.ZERO  # no base drag → no facing heuristic, no arrow
	# begin() seeded the size dims from the zero rect; the anchor flow never
	# drags a base, so the shape keeps its default parameters.
	values = PBShapeParams.get_default_values(shape_id)
	base_values = values.duplicate()

## Updates the height (or the sprite's normal offset) from a world point
## (already projected onto the view-parallel plane by the caller). On walls
## the normal extent maps to the shape's DEPTH (the shape grows along the
## face normal); on floors it maps to the height. The facing arrow LOCKS at
## the base release — height motion must not re-point it. The sprite's
## offset never goes negative (a sprite rides ON the surface, not through
## it); height-param shapes keep signed growth (negative = below).
func update_height_point(world_point: Vector3) -> void:
	if state != State.HEIGHT and state != State.OFFSET:
		return
	height = (world_point - plane_point).dot(plane_normal)
	if state == State.OFFSET:
		height = maxf(0.0, height)
	_apply_drag_extents()

## The dragged base rect's four corners IN WORLD SPACE (on the captured
## plane) — the BASE-phase outline the gizmo draws while the mesh preview is
## still hidden.
func base_rect_corners() -> PackedVector3Array:
	var v_dir := plane_normal.cross(u_dir).normalized()
	var u := u_dir * (u_size * 0.5)
	var v := v_dir * (v_size * 0.5)
	return PackedVector3Array([
		rect_center - u - v,
		rect_center + u - v,
		rect_center + u + v,
		rect_center - u + v,
	])

## LMB click in HEIGHT (or the sprite's OFFSET): keep the shape, open the
## params modal.
func confirm_height() -> void:
	if state == State.HEIGHT or state == State.OFFSET:
		state = State.PARAMS
		session_values = values.duplicate()

## A modal parameter edit. Height-like changes re-anchor the placement.
func set_param(param_name: String, value: float) -> void:
	values[param_name] = value
	if param_name == "height" or param_name == "radius" or param_name == "outer_radius":
		if values.has("height"):
			height = values["height"]

## Cancel in the modal: restore the values from modal-open.
func cancel_params() -> void:
	if state == State.PARAMS:
		values = session_values.duplicate()
		if values.has("height"):
			height = values["height"]

## Tears everything down (ESC before the confirming click creates nothing).
func reset() -> void:
	state = State.INACTIVE
	shape_id = &""
	values = {}
	base_values = {}
	session_values = {}
	height = 0.0
	u_size = 0.0
	v_size = 0.0
	_u_locked = false
	facing = Vector3.ZERO
	base_end = Vector3.ZERO
	_last_point = Vector3.ZERO
	preview_node = null

# ── Geometry helpers ─────────────────────────────────────────────────────────

## Facing-arrow heuristic:
## 1. Biased towards the dimension that makes sense for the shape:
##    - Doors: parallel to the shorter dimension (opening spans width, depth is thickness).
##    - Stairs: along the longer dimension (steps rise along the longer run).
##    - Other shapes: follows dominant drag / nudge direction.
## 2. Protected by deadzone and hysteresis:
##    - Near-square rectangles (difference < FACING_DEAD_ZONE) do not flip back-and-forth.
##    - Sub-dead-zone nudges keep the facing stable.
func _update_facing(point: Vector3, v_dir: Vector3) -> void:
	var step := _project_on_plane(point - _last_point, plane_normal)
	_last_point = point
	var step_len := step.length()

	var cum := point - base_start
	var du := step.dot(u_dir)
	var dv := step.dot(v_dir)

	# Shapes with an inherent dimension bias:
	# Door: parallel to the shorter dimension.
	# Stairs: along the longer dimension.
	if PBShapeParams.facing_prefers_shorter(shape_id):
		# Door: facing runs across the dominant extent (along the shorter extent).
		# Apply hysteresis near square to avoid ping-pong.
		var longer_is_u: bool
		if absf(u_size - v_size) >= FACING_DEAD_ZONE:
			longer_is_u = u_size >= v_size
		else:
			longer_is_u = absf(facing.dot(v_dir)) >= absf(facing.dot(u_dir))
		var across := v_dir if longer_is_u else u_dir
		var toward: float = (rect_center - base_start).dot(across)
		facing = across * (1.0 if toward >= 0.0 else -1.0)
		return
	elif shape_id == &"stair" or shape_id == &"curved_stair":
		# Stairs: facing runs along the longer extent.
		# Deliberate lateral nudges bigger than deadzone can override.
		var longer_is_u: bool
		if absf(u_size - v_size) >= FACING_DEAD_ZONE:
			longer_is_u = u_size >= v_size
		else:
			longer_is_u = absf(facing.dot(u_dir)) >= absf(facing.dot(v_dir))
		var natural_axis := u_dir if longer_is_u else v_dir
		var lateral_axis := v_dir if longer_is_u else u_dir
		if step_len >= FACING_DEAD_ZONE and absf(step.dot(lateral_axis)) > absf(step.dot(natural_axis)) * 1.5:
			var lat_sign := signf(cum.dot(lateral_axis))
			facing = lateral_axis * (lat_sign if lat_sign != 0.0 else 1.0)
		else:
			var nat_sign := signf(cum.dot(natural_axis))
			facing = natural_axis * (nat_sign if nat_sign != 0.0 else 1.0)
		return

	# General shapes: steps inside the dead zone never re-point facing.
	if step_len < FACING_DEAD_ZONE:
		return
	if absf(du) >= absf(dv):
		var su := signf(cum.dot(u_dir))
		facing = u_dir * (su if su != 0.0 else signf(du))
	else:
		var sv := signf(cum.dot(v_dir))
		facing = v_dir * (sv if sv != 0.0 else signf(dv))

## Maps the base drag extents (u_size, v_size) and height onto the shape's
## parameters (width, depth, height, radius). One mapping fits every surface:
## local Y along the face normal, local +Z along facing (depth), and local +X
## perpendicular (width).
func _apply_drag_extents() -> void:
	if state == State.OFFSET:
		return  # anchor flow (sprite): the drag drives the normal offset only
	var height_value: float = height if state >= State.HEIGHT else NAN
	var v_dir := plane_normal.cross(u_dir).normalized()
	var forward_along_u: bool = absf(arrow_direction().dot(u_dir)) > absf(arrow_direction().dot(v_dir))
	var width := v_size if forward_along_u else u_size
	var depth := u_size if forward_along_u else v_size
	PBShapeParams.apply_drag_extents(values, maxf(width, MIN_EXTENT),
		maxf(depth, MIN_EXTENT), height_value, base_values)

## Snaps an in-plane direction to the nearest world axis (keeping the drag's
## sign) when the captured surface is axis aligned; arbitrary surfaces keep
## the drag direction. This is what makes created shapes axis aligned
## instead of camera aligned (ProBuilder behavior).
func _snap_axis(direction: Vector3) -> Vector3:
	for axis in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
		if absf(axis.dot(plane_normal)) > 0.999:
			# The surface normal IS axis aligned → snap the drag to the
			# nearest world axis orthogonal to the normal.
			var best_axis := Vector3.ZERO
			var best_dot := -1.0
			for candidate in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
				if absf(candidate.dot(plane_normal)) > 0.5:
					continue
				var d := absf(direction.normalized().dot(candidate))
				if d > best_dot:
					best_dot = d
					best_axis = candidate
			if best_axis != Vector3.ZERO:
				return best_axis * signf(direction.dot(best_axis))
			return direction.normalized()
	return direction.normalized()

static func _project_on_plane(v: Vector3, normal: Vector3) -> Vector3:
	return v - normal * v.dot(normal)

## Ray∩plane, or RAY_MISS when parallel/behind.
static func ray_plane_intersect(ray_origin: Vector3, ray_dir: Vector3,
		plane_point: Vector3, plane_normal: Vector3) -> Vector3:
	var denom := ray_dir.dot(plane_normal)
	if absf(denom) < 0.000001:
		return RAY_MISS
	var t: float = (plane_point - ray_origin).dot(plane_normal) / denom
	if t < 0.0:
		return RAY_MISS
	return ray_origin + ray_dir * t

## The world point to drive the height from: the mouse ray intersected with
## the plane through `plane_point` parallel to the camera image plane — the
## standard "follow the cursor" projection for extrude-style drags.
static func height_reference_point(camera_origin: Vector3, camera_dir: Vector3,
		ray_origin: Vector3, ray_dir: Vector3, plane_point: Vector3) -> Vector3:
	var hit := ray_plane_intersect(ray_origin, ray_dir, plane_point, camera_dir)
	if hit == RAY_MISS:
		return plane_point
	return hit

static func _aabb_of(data: PBMeshData) -> AABB:
	if data == null or data.positions.is_empty():
		return AABB(Vector3.ZERO, Vector3.ONE)
	var aabb := AABB(data.positions[0], Vector3.ZERO)
	for p in data.positions:
		aabb = aabb.expand(p)
	return aabb
