## PBShapeTrim — Procedural architectural moulding and trim generator.
##
## Generates classic architectural trims (Skirting, Cornice, Dado) with profile types
## (Flat, Chamfer, Round, Cove, Ogee, Stepped) swept along 3D wall paths with mitred corners.
@tool
class_name PBShapeTrim
extends RefCounted

enum ProfileType {
	FLAT,
	CHAMFER,
	ROUND,
	COVE,
	OGEE,
	STEPPED,
}

enum TrimKind {
	SKIRTING,
	CORNICE,
	DADO,
}

# ==============================================================================
# 2D Profile Curves
# ==============================================================================

## Returns 2D cross-section profile points (x = depth from wall, y = height along wall).
static func get_profile_points(profile: ProfileType, width: float, height: float,
		segments: int = 4, upside_down: bool = false, flip_side: bool = false) -> PackedVector2Array:
	var w := maxf(0.01, width)
	var h := maxf(0.01, height)
	var segs := maxi(2, segments)
	var pts := PackedVector2Array()

	match profile:
		ProfileType.FLAT:
			pts.append(Vector2(0.0, 0.0))
			pts.append(Vector2(w, 0.0))
			pts.append(Vector2(w, h))
			pts.append(Vector2(0.0, h))

		ProfileType.CHAMFER:
			var chamfer_h := h * 0.3
			var chamfer_w := w * 0.5
			pts.append(Vector2(0.0, 0.0))
			pts.append(Vector2(w, 0.0))
			pts.append(Vector2(w, h - chamfer_h))
			pts.append(Vector2(w - chamfer_w, h))
			pts.append(Vector2(0.0, h))

		ProfileType.ROUND:
			var arc_r := minf(w * 0.6, h * 0.4)
			var base_h := h - arc_r
			pts.append(Vector2(0.0, 0.0))
			pts.append(Vector2(w, 0.0))
			pts.append(Vector2(w, base_h))
			for i in range(1, segs + 1):
				var theta: float = (float(i) / float(segs)) * (PI * 0.5)
				var px: float = (w - arc_r) + arc_r * cos(theta)
				var py: float = base_h + arc_r * sin(theta)
				pts.append(Vector2(px, py))
			pts.append(Vector2(0.0, h))

		ProfileType.COVE:
			var arc_r := minf(w * 0.8, h * 0.8)
			pts.append(Vector2(0.0, 0.0))
			pts.append(Vector2(w, 0.0))
			# Scooped concave arc towards wall
			for i in range(1, segs):
				var theta: float = (float(i) / float(segs)) * (PI * 0.5)
				var px: float = w - arc_r * sin(theta)
				var py: float = arc_r * (1.0 - cos(theta))
				pts.append(Vector2(px, py))
			pts.append(Vector2(w - arc_r, h))
			pts.append(Vector2(0.0, h))

		ProfileType.OGEE:
			# Classic S-curve moulding
			pts.append(Vector2(0.0, 0.0))
			pts.append(Vector2(w, 0.0))
			var mid_h := h * 0.5
			var mid_w := w * 0.5
			for i in range(1, segs + 1):
				var t: float = float(i) / float(segs)
				var y_pos: float = mid_h * t
				var x_pos: float = w - (w - mid_w) * (1.0 - cos(t * PI * 0.5))
				pts.append(Vector2(x_pos, y_pos))
			for i in range(1, segs + 1):
				var t: float = float(i) / float(segs)
				var y_pos: float = mid_h + mid_h * t
				var x_pos: float = mid_w - mid_w * sin(t * PI * 0.5)
				pts.append(Vector2(x_pos, y_pos))
			pts.append(Vector2(0.0, h))

		ProfileType.STEPPED:
			pts.append(Vector2(0.0, 0.0))
			pts.append(Vector2(w, 0.0))
			pts.append(Vector2(w, h * 0.35))
			pts.append(Vector2(w * 0.65, h * 0.35))
			pts.append(Vector2(w * 0.65, h * 0.7))
			pts.append(Vector2(w * 0.35, h * 0.7))
			pts.append(Vector2(w * 0.35, h))
			pts.append(Vector2(0.0, h))

	if upside_down or flip_side:
		var transformed := PackedVector2Array()
		for p in pts:
			var px := -p.x if flip_side else p.x
			var py := (h - p.y) if upside_down else p.y
			transformed.append(Vector2(px, py))
		if (upside_down and not flip_side) or (flip_side and not upside_down):
			transformed.reverse()
		return transformed
	return pts

# ==============================================================================
# Path Extrusion & Sweeping
# ==============================================================================

## Sweeps a 2D profile along a 3D path with automated miter planes at corners.
## - `profile_pts`: 2D cross section (x = depth, y = height).
## - `path`: Sequence of 3D points forming the wall path.
## - `up`: Upward normal vector along the wall.
## - `closed`: Whether the path forms a closed loop.
static func extrude_profile_along_path(profile_pts: PackedVector2Array, path: PackedVector3Array,
		up: Vector3 = Vector3.UP, closed: bool = false, close_profile: bool = true) -> PBMeshData:
	if profile_pts.size() < 2 or path.size() < 2:
		return null

	var n_pts: int = path.size()
	var n_prof: int = profile_pts.size()

	# Build tangent frames and miter scale for each path node
	var frames: Array[Transform3D] = []
	var miter_scales: PackedFloat32Array = PackedFloat32Array()

	for i in range(n_pts):
		var p_curr: Vector3 = path[i]
		var d_in: Vector3 = Vector3.ZERO
		var d_out: Vector3 = Vector3.ZERO
		if closed:
			var p_prev: Vector3 = path[(i - 1 + n_pts) % n_pts]
			var p_next: Vector3 = path[(i + 1) % n_pts]
			d_in = (p_curr - p_prev).normalized()
			d_out = (p_next - p_curr).normalized()
		else:
			if i == 0:
				d_out = (path[1] - path[0]).normalized()
				d_in = d_out
			elif i == n_pts - 1:
				d_in = (path[n_pts - 1] - path[n_pts - 2]).normalized()
				d_out = d_in
			else:
				d_in = (p_curr - path[i - 1]).normalized()
				d_out = (path[i + 1] - p_curr).normalized()

		var bisector := (d_in + d_out).normalized()
		if bisector.length_squared() < 0.001:
			bisector = d_in

		# Miter scale factor
		var dot_val := clampf(d_in.dot(d_out), -0.99, 1.0)
		var angle_half: float = acos(dot_val) * 0.5
		var miter_s: float = 1.0 / maxf(0.3, cos(angle_half))
		miter_s = clampf(miter_s, 0.5, 2.5)
		miter_scales.append(miter_s)

		var z_axis := bisector
		var y_axis := up.normalized()
		var x_axis := y_axis.cross(z_axis).normalized()
		y_axis = z_axis.cross(x_axis).normalized()

		frames.append(Transform3D(Basis(x_axis, y_axis, z_axis), p_curr))

	# Compute 3D ring vertices
	var rings: Array[PackedVector3Array] = []
	for i in range(n_pts):
		var ring := PackedVector3Array()
		var xf: Transform3D = frames[i]
		var ms: float = miter_scales[i]

		for p2 in profile_pts:
			var local_pt := Vector3(p2.x * ms, p2.y, 0.0)
			ring.append(xf * local_pt)
		rings.append(ring)

	var split_positions := PackedVector3Array()
	var split_uvs := PackedVector2Array()
	var faces: Array[PBFace] = []
	var vertex_counter := 0

	var num_segments: int = n_pts if closed else n_pts - 1

	# Connect rings with quads
	for seg in range(num_segments):
		var i0: int = seg
		var i1: int = (seg + 1) % n_pts
		var ring0: PackedVector3Array = rings[i0]
		var ring1: PackedVector3Array = rings[i1]

		var u0: float = float(seg) / float(num_segments)
		var u1: float = float(seg + 1) / float(num_segments)

		var n_segs_prof: int = n_prof if close_profile else n_prof - 1
		for j in range(n_segs_prof):
			var j_next: int = (j + 1) % n_prof
			var v0: float = float(j) / float(n_segs_prof)
			var v1: float = float(j + 1) / float(n_segs_prof)

			var p_00: Vector3 = ring0[j]
			var p_01: Vector3 = ring0[j_next]
			var p_10: Vector3 = ring1[j]
			var p_11: Vector3 = ring1[j_next]
			# Quad vertices: 2 triangles (00 -> 01 -> 11) and (00 -> 11 -> 10)
			split_positions.append(p_00)
			split_positions.append(p_01)
			split_positions.append(p_11)
			split_positions.append(p_10)

			split_uvs.append(Vector2(u0, v0))
			split_uvs.append(Vector2(u0, v1))
			split_uvs.append(Vector2(u1, v1))
			split_uvs.append(Vector2(u1, v0))

			var face := PBFace.new()
			face.set_indexes(PackedInt32Array([
				vertex_counter, vertex_counter + 1, vertex_counter + 2,
				vertex_counter, vertex_counter + 2, vertex_counter + 3
			]))
			face.manual_uv = true
			faces.append(face)
			vertex_counter += 4

	# End caps for open paths
	if not closed and n_pts >= 2:
		# Start cap (reverse order for outward normal)
		var ring_start: PackedVector3Array = rings[0]
		var cap_indices := PackedInt32Array()
		var start_base := vertex_counter
		for j in range(n_prof):
			split_positions.append(ring_start[j])
			split_uvs.append(Vector2(profile_pts[j].x, profile_pts[j].y))
			vertex_counter += 1
		# Fan triangulation
		for j in range(1, n_prof - 1):
			cap_indices.append(start_base)
			cap_indices.append(start_base + j + 1)
			cap_indices.append(start_base + j)
		var face_start := PBFace.new()
		face_start.set_indexes(cap_indices)
		face_start.manual_uv = true
		faces.append(face_start)

		# End cap (forward order for outward normal)
		var ring_end: PackedVector3Array = rings[n_pts - 1]
		var cap_end_indices := PackedInt32Array()
		var end_base := vertex_counter
		for j in range(n_prof):
			split_positions.append(ring_end[j])
			split_uvs.append(Vector2(profile_pts[j].x, profile_pts[j].y))
			vertex_counter += 1
		for j in range(1, n_prof - 1):
			cap_end_indices.append(end_base)
			cap_end_indices.append(end_base + j)
			cap_end_indices.append(end_base + j + 1)
		var face_end := PBFace.new()
		face_end.set_indexes(cap_end_indices)
		face_end.manual_uv = true
		faces.append(face_end)

	var mesh_data := PBMeshData.new()
	mesh_data.positions = split_positions
	mesh_data.textures0 = split_uvs
	mesh_data.faces = faces
	mesh_data.rebuild_welds()
	mesh_data.calculate_normals()
	mesh_data.shape_edited = true
	return mesh_data

## Convenience builder for a straight or perimeter wall trim moulding.
## Builds a single straight trim strip along local Z from (0, 0, 0) to (0, 0, length).
static func build_straight_trim(length: float, depth: float = 0.05, height: float = 0.15,
		profile: ProfileType = ProfileType.CHAMFER, segments: int = 4,
		upside_down: bool = false, flip_side: bool = false, smooth: bool = true) -> PBMeshData:
	var l := maxf(0.01, length)
	var d := maxf(0.005, depth)
	var h := maxf(0.01, height)
	var path := PackedVector3Array([
		Vector3(0.0, 0.0, -l * 0.5),
		Vector3(0.0, 0.0, l * 0.5)
	])
	var pts := get_profile_points(profile, d, h, segments, upside_down, flip_side)
	var md := extrude_profile_along_path(pts, path, Vector3.UP, false, true)
	if md != null and smooth:
		for f in md.faces:
			f.smoothing_group = 1
		md.calculate_normals()
	return md

## Convenience builder for a straight or perimeter wall trim moulding.
static func create_wall_trim(path: PackedVector3Array, profile: ProfileType = ProfileType.CHAMFER,
		depth: float = 0.05, height: float = 0.15, closed: bool = false,
		upside_down: bool = false, flip_side: bool = false, smooth: bool = true) -> PBMeshData:
	var pts := get_profile_points(profile, depth, height, 4, upside_down, flip_side)
	var md := extrude_profile_along_path(pts, path, Vector3.UP, closed, true)
	if md != null and smooth:
		for f in md.faces:
			f.smoothing_group = 1
		md.calculate_normals()
	return md
