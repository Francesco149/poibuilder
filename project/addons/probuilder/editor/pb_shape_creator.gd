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

enum State { INACTIVE, ARMED, BASE, HEIGHT, PARAMS }

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

## The live preview node (owned and managed by the plugin; the creator only
## supplies data + placement for it). Null while nothing is being drawn.
var preview_node: PBMesh = null

# ── Queries ──────────────────────────────────────────────────────────────────

func is_active() -> bool:
	return state != State.INACTIVE

## Local-space facing direction for the creation arrow (ZERO = none).
func facing_direction() -> Vector3:
	return PBShapeParams.facing_direction(shape_id)

## Builds the current shape data from the current values.
func build_data() -> PBMeshData:
	if shape_id == &"":
		return null
	return PBShapeParams.build(shape_id, values)

## Node transform placing `data` so its base face (AABB face towards the
## plane, by height sign) lies IN the drag plane, centered on rect_center.
func placement_transform(data: PBMeshData) -> Transform3D:
	var basis := Basis(u_dir, plane_normal, u_dir.cross(plane_normal))
	var aabb := _aabb_of(data)
	var lift: float
	if height >= 0.0:
		lift = -aabb.position.y
	else:
		lift = -(aabb.position.y + aabb.size.y)
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
	return true

## Updates the height from a world point (already projected onto the
## view-parallel plane by the caller). On walls the normal extent maps to
## the shape's DEPTH (the shape grows along the face normal); on floors it
## maps to the height.
func update_height_point(world_point: Vector3) -> void:
	if state != State.HEIGHT:
		return
	height = (world_point - plane_point).dot(plane_normal)
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

## LMB click in HEIGHT: keep the shape, open the params modal.
func confirm_height() -> void:
	if state == State.HEIGHT:
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
	session_values = {}
	height = 0.0
	u_size = 0.0
	v_size = 0.0
	_u_locked = false
	preview_node = null

# ── Geometry helpers ─────────────────────────────────────────────────────────

func _apply_drag_extents() -> void:
	# A negative height means "base stage — height-driven values keep their
	# current values" (the drag height only exists from HEIGHT on). One
	# mapping fits every surface: u → width, v → depth, the normal extent →
	# height (the placement basis points local Y along the face normal, so
	# "height" grows along the normal on walls exactly like it grows up on
	# floors).
	var height_value: float = height if state >= State.HEIGHT else -1.0
	PBShapeParams.apply_drag_extents(values, maxf(u_size, MIN_EXTENT),
		maxf(v_size, MIN_EXTENT), height_value)

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
