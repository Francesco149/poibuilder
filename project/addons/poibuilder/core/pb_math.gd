## PBMath — Utility class providing geometry, projection, raycasting, and snapping math.
##
## Ported from Unity ProBuilder's Math.cs and Projection.cs to GDScript
## (Godot right-handed Y-up, counter-clockwise winding order for front faces).
@tool
class_name PBMath
extends RefCounted

# ==============================================================================
# Constants
# ==============================================================================

## Golden ratio constant, matching ProBuilder.
const PHI: float = 1.618033988749895

## Comparison epsilon.
const FLT_EPSILON: float = 0.0001

## Projection axes.
const PROJECTION_X: int = 0
const PROJECTION_X_NEG: int = 1
const PROJECTION_Y: int = 2
const PROJECTION_Y_NEG: int = 3
const PROJECTION_Z: int = 4
const PROJECTION_Z_NEG: int = 5

# ==============================================================================
# P2-01: Normal Calculation, Area, Centroid
# ==============================================================================

## Calculates and returns the unit vector normal of 3 points in a triangle.
## Formula: (p1 - p0) cross (p2 - p0), normalized.
## Returns Vector3.ZERO for degenerate triangles.
static func normal(p0: Vector3, p1: Vector3, p2: Vector3) -> Vector3:
	var edge1: Vector3 = p1 - p0
	var edge2: Vector3 = p2 - p0
	var cross_prod: Vector3 = edge1.cross(edge2)
	if cross_prod.length_squared() < (FLT_EPSILON * FLT_EPSILON):
		return Vector3.ZERO
	return cross_prod.normalized()

## Calculates the average normal across triangles defined by indexes.
## If indexes is empty or not divisible by 3, uses the first 3 positions.
## Returns Vector3.ZERO if positions has fewer than 3 points or is degenerate.
static func normal_from_positions(positions: PackedVector3Array, indexes: PackedInt32Array = PackedInt32Array()) -> Vector3:
	if indexes.is_empty() or indexes.size() % 3 != 0:
		if positions.size() < 3:
			return Vector3.ZERO
		return normal(positions[0], positions[1], positions[2])

	var nrm: Vector3 = Vector3.ZERO
	var tri_count: int = indexes.size() / 3
	var pos_count: int = positions.size()

	for i in range(0, indexes.size(), 3):
		var i0: int = indexes[i]
		var i1: int = indexes[i + 1]
		var i2: int = indexes[i + 2]
		if i0 < 0 or i0 >= pos_count or i1 < 0 or i1 >= pos_count or i2 < 0 or i2 >= pos_count:
			continue
		nrm += normal(positions[i0], positions[i1], positions[i2])

	if tri_count > 0:
		nrm /= float(tri_count)

	if nrm.length_squared() < (FLT_EPSILON * FLT_EPSILON):
		return Vector3.ZERO
	return nrm.normalized()

## Returns the area of a triangle given 3 vertex positions using Heron's formula variant.
static func triangle_area(a: Vector3, b: Vector3, c: Vector3) -> float:
	var a_sq: float = sqr_distance(a, b)
	var b_sq: float = sqr_distance(b, c)
	var c_sq: float = sqr_distance(c, a)
	var val: float = (2.0 * a_sq * b_sq + 2.0 * b_sq * c_sq + 2.0 * c_sq * a_sq - a_sq * a_sq - b_sq * b_sq - c_sq * c_sq) / 16.0
	if val <= 0.0:
		return 0.0
	return sqrt(val)

## Returns the total area of a polygon composed of triangles referenced by indexes.
static func polygon_area(positions: PackedVector3Array, indexes: PackedInt32Array) -> float:
	var area: float = 0.0
	var pos_count: int = positions.size()
	for i in range(0, indexes.size() - 2, 3):
		var i0: int = indexes[i]
		var i1: int = indexes[i + 1]
		var i2: int = indexes[i + 2]
		if i0 < 0 or i0 >= pos_count or i1 < 0 or i1 >= pos_count or i2 < 0 or i2 >= pos_count:
			continue
		area += triangle_area(positions[i0], positions[i1], positions[i2])
	return area

## Calculates and returns the centroid (average position) of positions.
## If indexes is empty, averages all positions; otherwise averages only indexed positions.
static func average(positions: PackedVector3Array, indexes: PackedInt32Array = PackedInt32Array()) -> Vector3:
	if positions.is_empty():
		return Vector3.ZERO
	var has_indexes: bool = not indexes.is_empty()
	var count: int = indexes.size() if has_indexes else positions.size()
	if count == 0:
		return Vector3.ZERO

	var sum: Vector3 = Vector3.ZERO
	if has_indexes:
		var pos_count: int = positions.size()
		for idx in indexes:
			if idx >= 0 and idx < pos_count:
				sum += positions[idx]
	else:
		for pos in positions:
			sum += pos

	return sum / float(count)

# ==============================================================================
# P2-02: Ray-Triangle, Line Segments, Point-in-Polygon, Distances
# ==============================================================================

## Tests whether a ray intersects a triangle using the Möller–Trumbore algorithm (non-culling).
## Returns {"hit": true, "distance": float, "point": Vector3} or {"hit": false}.
static func ray_intersects_triangle(ray_origin: Vector3, ray_dir: Vector3, v0: Vector3, v1: Vector3, v2: Vector3) -> Dictionary:
	var e1: Vector3 = v1 - v0
	var e2: Vector3 = v2 - v0
	var p: Vector3 = ray_dir.cross(e2)
	var det: float = e1.dot(p)

	# Non-culling branch: if determinant is near zero, ray lies in plane of triangle
	if det > -FLT_EPSILON and det < FLT_EPSILON:
		return {"hit": false}

	var inv_det: float = 1.0 / det
	var t_vec: Vector3 = ray_origin - v0
	var u: float = t_vec.dot(p) * inv_det
	if u < 0.0 or u > 1.0:
		return {"hit": false}

	var q: Vector3 = t_vec.cross(e1)
	var v: float = ray_dir.dot(q) * inv_det
	if v < 0.0 or (u + v) > 1.0:
		return {"hit": false}

	var t: float = e2.dot(q) * inv_det
	if t > FLT_EPSILON:
		var hit_point: Vector3 = Vector3(
			u * v1.x + v * v2.x + (1.0 - (u + v)) * v0.x,
			u * v1.y + v * v2.y + (1.0 - (u + v)) * v0.y,
			u * v1.z + v * v2.z + (1.0 - (u + v)) * v0.z
		)
		return {
			"hit": true,
			"distance": t,
			"point": hit_point
		}

	return {"hit": false}

## Returns the shortest distance between a point and a finite 2D line segment.
static func distance_point_line_segment_2d(point: Vector2, line_start: Vector2, line_end: Vector2) -> float:
	var line_vec: Vector2 = line_end - line_start
	var l2: float = line_vec.length_squared()
	if l2 < (FLT_EPSILON * FLT_EPSILON):
		return point.distance_to(line_start)

	var t: float = (point - line_start).dot(line_vec) / l2
	if t < 0.0:
		return point.distance_to(line_start)
	elif t > 1.0:
		return point.distance_to(line_end)

	var projection: Vector2 = line_start + t * line_vec
	return point.distance_to(projection)

## Returns the shortest distance between a point and a finite 3D line segment.
static func distance_point_line_segment_3d(point: Vector3, line_start: Vector3, line_end: Vector3) -> float:
	var line_vec: Vector3 = line_end - line_start
	var l2: float = line_vec.length_squared()
	if l2 < (FLT_EPSILON * FLT_EPSILON):
		return point.distance_to(line_start)

	var t: float = (point - line_start).dot(line_vec) / l2
	if t < 0.0:
		return point.distance_to(line_start)
	elif t > 1.0:
		return point.distance_to(line_end)

	var projection: Vector3 = line_start + t * line_vec
	return point.distance_to(projection)

## Tests whether two 2D line segments (p0->p1 and p2->p3) intersect.
## Returns {"intersects": true, "point": Vector2} or {"intersects": false}.
static func get_line_segment_intersect(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2) -> Dictionary:
	var s1: Vector2 = p1 - p0
	var s2: Vector2 = p3 - p2
	var denom: float = -s2.x * s1.y + s1.x * s2.y
	if absf(denom) < FLT_EPSILON:
		return {"intersects": false}

	var s: float = (-s1.y * (p0.x - p2.x) + s1.x * (p0.y - p2.y)) / denom
	var t: float = (s2.x * (p0.y - p2.y) - s2.y * (p0.x - p2.x)) / denom

	if s >= 0.0 and s <= 1.0 and t >= 0.0 and t <= 1.0:
		var intersect_pt: Vector2 = Vector2(p0.x + (t * s1.x), p0.y + (t * s1.y))
		return {
			"intersects": true,
			"point": intersect_pt
		}
	return {"intersects": false}

## Tests whether a 2D point is inside or on the boundary of a contiguous polygon ring.
static func point_in_polygon(polygon: PackedVector2Array, point: Vector2) -> bool:
	var n: int = polygon.size()
	if n < 3:
		return false

	# Check if point is on any edge or vertex
	for i in range(n):
		var p0: Vector2 = polygon[i]
		var p1: Vector2 = polygon[(i + 1) % n]
		if distance_point_line_segment_2d(point, p0, p1) < FLT_EPSILON:
			return true

	# Bounding box check for fast rejection
	var min_x: float = polygon[0].x
	var max_x: float = polygon[0].x
	var min_y: float = polygon[0].y
	var max_y: float = polygon[0].y
	for i in range(1, n):
		var p: Vector2 = polygon[i]
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_y = minf(min_y, p.y)
		max_y = maxf(max_y, p.y)

	if point.x < min_x or point.x > max_x or point.y < min_y or point.y > max_y:
		return false

	# Ray casting test (Jordan curve theorem)
	var inside: bool = false
	var j: int = n - 1
	for i in range(n):
		var pi: Vector2 = polygon[i]
		var pj: Vector2 = polygon[j]
		if ((pi.y > point.y) != (pj.y > point.y)) and (point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x):
			inside = not inside
		j = i

	return inside

## Returns the squared Euclidean distance between two 3D points.
static func sqr_distance(a: Vector3, b: Vector3) -> float:
	var dx: float = b.x - a.x
	var dy: float = b.y - a.y
	var dz: float = b.z - a.z
	return dx * dx + dy * dy + dz * dz

# ==============================================================================
# P2-03: Projection Utilities
# ==============================================================================

## Finds the least-squares best-fit plane for a set of 3D points.
## Ported from ProBuilder Projection.cs FindBestPlane.
static func find_best_plane(points: PackedVector3Array, indexes: PackedInt32Array = PackedInt32Array()) -> Plane:
	var ind: bool = not indexes.is_empty()
	var count: int = indexes.size() if ind else points.size()
	if count == 0:
		return Plane(Vector3.UP, Vector3.ZERO)

	var c: Vector3 = Vector3.ZERO
	var pos_count: int = points.size()
	for i in range(count):
		var idx: int = indexes[i] if ind else i
		if idx >= 0 and idx < pos_count:
			c += points[idx]
	c /= float(count)

	var xx: float = 0.0
	var xy: float = 0.0
	var xz: float = 0.0
	var yy: float = 0.0
	var yz: float = 0.0
	var zz: float = 0.0

	for i in range(count):
		var idx: int = indexes[i] if ind else i
		if idx >= 0 and idx < pos_count:
			var r: Vector3 = points[idx] - c
			xx += r.x * r.x
			xy += r.x * r.y
			xz += r.x * r.z
			yy += r.y * r.y
			yz += r.y * r.z
			zz += r.z * r.z

	var det_x: float = yy * zz - yz * yz
	var det_y: float = xx * zz - xz * xz
	var det_z: float = xx * yy - xy * xy

	var n: Vector3 = Vector3.ZERO
	if det_x > det_y and det_x > det_z and det_x > 0.0:
		n.x = 1.0
		n.y = (xz * yz - xy * zz) / det_x
		n.z = (xy * yz - xz * yy) / det_x
	elif det_y > det_z and det_y > 0.0:
		n.x = (yz * xz - xy * zz) / det_y
		n.y = 1.0
		n.z = (xy * xz - yz * xx) / det_y
	elif det_z > 0.0:
		n.x = (yz * xy - xz * yy) / det_z
		n.y = (xz * xy - yz * xx) / det_z
		n.z = 1.0
	else:
		n = Vector3.UP

	if n.length_squared() < (FLT_EPSILON * FLT_EPSILON):
		n = Vector3.UP
	else:
		n = n.normalized()

	return Plane(n, c)

## Maps a 3D direction vector to one of the 6 projection axis constants.
static func vector_to_projection_axis(direction: Vector3) -> int:
	var x: float = absf(direction.x)
	var y: float = absf(direction.y)
	var z: float = absf(direction.z)

	if absf(x - y) > FLT_EPSILON and x > y and absf(x - z) > FLT_EPSILON and x > z:
		return PROJECTION_X if direction.x > 0.0 else PROJECTION_X_NEG

	if absf(y - z) > FLT_EPSILON and y > z:
		return PROJECTION_Y if direction.y > 0.0 else PROJECTION_Y_NEG

	return PROJECTION_Z if direction.z > 0.0 else PROJECTION_Z_NEG

## Returns the tangent vector for a given projection axis.
static func get_tangent_to_axis(axis: int) -> Vector3:
	match axis:
		PROJECTION_X, PROJECTION_X_NEG:
			return Vector3.UP
		PROJECTION_Y, PROJECTION_Y_NEG:
			return Vector3.FORWARD
		PROJECTION_Z, PROJECTION_Z_NEG:
			return Vector3.UP
		_:
			return Vector3.UP

## Projects 3D positions to 2D coordinates using best-fit plane or specified direction.
static func planar_project(positions: PackedVector3Array, indexes: PackedInt32Array = PackedInt32Array(), direction: Vector3 = Vector3.ZERO) -> PackedVector2Array:
	if positions.is_empty():
		return PackedVector2Array()

	var nrm: Vector3 = direction
	if nrm.length_squared() < (FLT_EPSILON * FLT_EPSILON):
		nrm = find_best_plane(positions, indexes).normal

	if nrm.length_squared() < (FLT_EPSILON * FLT_EPSILON):
		nrm = Vector3.UP
	else:
		nrm = nrm.normalized()

	var axis: int = vector_to_projection_axis(nrm)
	var prj: Vector3 = get_tangent_to_axis(axis)
	var u: Vector3 = nrm.cross(prj)
	if u.length_squared() < (FLT_EPSILON * FLT_EPSILON):
		var alt_prj: Vector3 = Vector3.RIGHT if absf(nrm.dot(Vector3.RIGHT)) < 0.9 else Vector3.UP
		u = nrm.cross(alt_prj)
	var v: Vector3 = u.cross(nrm)
	u = u.normalized()
	v = v.normalized()

	var results := PackedVector2Array()
	var ind: bool = not indexes.is_empty()
	var count: int = indexes.size() if ind else positions.size()
	results.resize(count)

	var pos_count: int = positions.size()
	for i in range(count):
		var idx: int = indexes[i] if ind else i
		if idx >= 0 and idx < pos_count:
			var p: Vector3 = positions[idx]
			results[i] = Vector2(u.dot(p), v.dot(p))
		else:
			results[i] = Vector2.ZERO

	return results

# ==============================================================================
# P2-06: Snapping
# ==============================================================================

## Snaps a float value to the nearest multiple of snap_size.
static func snap_value(value: float, snap_size: float) -> float:
	if absf(snap_size) < FLT_EPSILON:
		return value
	return roundf(value / snap_size) * snap_size

## Component-wise snap of a Vector3 to snap_size increments.
static func snap_vector3(v: Vector3, snap_size: Vector3) -> Vector3:
	return Vector3(
		snap_value(v.x, snap_size.x),
		snap_value(v.y, snap_size.y),
		snap_value(v.z, snap_size.z)
	)

## Snaps an angle in degrees to the nearest multiple of snap_angle.
static func snap_angle(angle: float, snap_angle: float) -> float:
	return snap_value(angle, snap_angle)
