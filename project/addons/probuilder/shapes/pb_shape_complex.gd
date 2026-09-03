## PBShapeComplex — Generator for complex PoiBuilder shape primitives.
##
## Provides procedural generation methods for Sphere (Icosphere), Torus,
## Arch, Stairs, and Door primitives returning valid PBMeshData instances.
@tool
class_name PBShapeComplex
extends RefCounted

# ==============================================================================
# Helper Functions
# ==============================================================================

## Helper to build shared_vertices by grouping vertex indices with matching 3D positions.
static func _build_shared_vertices(positions: PackedVector3Array) -> Array[PBSharedVertex]:
	var groups: Dictionary = {} # String key -> PackedInt32Array
	for i in range(positions.size()):
		var p: Vector3 = positions[i]
		var sx: float = snappedf(p.x, 0.0001) + 0.0
		var sy: float = snappedf(p.y, 0.0001) + 0.0
		var sz: float = snappedf(p.z, 0.0001) + 0.0
		var key: String = "%.4f,%.4f,%.4f" % [sx, sy, sz]
		if not groups.has(key):
			groups[key] = PackedInt32Array()
		groups[key].append(i)

	var shared: Array[PBSharedVertex] = []
	for key in groups.keys():
		var sv := PBSharedVertex.new(groups[key])
		shared.append(sv)
	return shared

## Ear-clips a simple CCW polygon (2D) into index triangles. Concave-safe;
## reflex and collinear corners are skipped as ears, and a guard bails to a
## fan fallback if the corner cases ever stall (our polygons are mild).
static func _triangulate_2d(points: PackedVector2Array) -> Array:
	var n := points.size()
	var idxs: Array[int] = []
	for i in range(n):
		idxs.append(i)
	var tris: Array = []
	var guard: int = n * n + 16
	while idxs.size() > 3 and guard > 0:
		guard -= 1
		var m := idxs.size()
		var clipped := false
		for i in range(m):
			var i0: int = idxs[(i + m - 1) % m]
			var i1: int = idxs[i]
			var i2: int = idxs[(i + 1) % m]
			var a := points[i0]
			var b := points[i1]
			var c := points[i2]
			if (b - a).cross(c - b) <= 0.0000001:
				continue  # reflex or collinear corner — not an ear
			var ear := true
			for j in idxs:
				if j == i0 or j == i1 or j == i2:
					continue
				if PBShapeComplex._point_in_triangle(points[j], a, b, c):
					ear = false
					break
			if not ear:
				continue
			tris.append([i0, i1, i2])
			idxs.remove_at(i)
			clipped = true
			break
		if not clipped:
			break
	if idxs.size() == 3:
		tris.append([idxs[0], idxs[1], idxs[2]])
	elif idxs.size() > 3:
		for i in range(1, idxs.size() - 1):
			tris.append([idxs[0], idxs[i], idxs[i + 1]])
	return tris

static func _point_in_triangle(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var d1 := (b - a).cross(p - a)
	var d2 := (c - b).cross(p - b)
	var d3 := (a - c).cross(p - c)
	var has_neg := d1 < -0.0000001 or d2 < -0.0000001 or d3 < -0.0000001
	var has_pos := d1 > 0.0000001 or d2 > 0.0000001 or d3 > 0.0000001
	return not (has_neg and has_pos)

## Helper to add a quad face (4 vertices, 2 triangles = 6 indices) to mesh arrays.
static func _add_quad(
	positions: PackedVector3Array,
	uvs: PackedVector2Array,
	faces: Array[PBFace],
	p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
	uv0: Vector2 = Vector2(0.0, 0.0),
	uv1: Vector2 = Vector2(1.0, 0.0),
	uv2: Vector2 = Vector2(1.0, 1.0),
	uv3: Vector2 = Vector2(0.0, 1.0),
	smoothing_group: int = 0
) -> void:
	var base: int = positions.size()
	positions.append(p0)
	positions.append(p1)
	positions.append(p2)
	positions.append(p3)

	uvs.append(uv0)
	uvs.append(uv1)
	uvs.append(uv2)
	uvs.append(uv3)

	var face := PBFace.new(PackedInt32Array([
		base + 0, base + 1, base + 2,
		base + 2, base + 3, base + 0
	]))
	face.smoothing_group = smoothing_group
	faces.append(face)

## Helper to add a single triangle face (3 vertices) to mesh arrays.
static func _add_tri(
	positions: PackedVector3Array,
	uvs: PackedVector2Array,
	faces: Array[PBFace],
	p0: Vector3, p1: Vector3, p2: Vector3,
	smoothing_group: int = 0
) -> void:
	var base: int = positions.size()
	positions.append(p0)
	positions.append(p1)
	positions.append(p2)
	uvs.append(Vector2(0.0, 0.0))
	uvs.append(Vector2(1.0, 0.0))
	uvs.append(Vector2(0.0, 1.0))
	var face := PBFace.new(PackedInt32Array([
		base + 0, base + 1, base + 2
	]))
	face.smoothing_group = smoothing_group
	faces.append(face)

# ==============================================================================
# 1. Sphere (Icosphere) Generator
# ==============================================================================

## Creates an icosphere by recursively subdividing a regular icosahedron.
## Returns a PBMeshData with radius, subdivisions, and optional smooth shading.
static func create_sphere(radius: float = 0.5, subdivisions: int = 2, smooth: bool = true) -> PBMeshData:
	var mesh_data := PBMeshData.new()
	var subs: int = maxi(0, subdivisions)
	var rad: float = maxf(0.0001, radius)

	# Regular icosahedron template vertices
	var phi: float = (1.0 + sqrt(5.0)) * 0.5
	var template: Array[Vector3] = [
		Vector3(-1.0,  phi,  0.0), # 0
		Vector3( 1.0,  phi,  0.0), # 1
		Vector3(-1.0, -phi,  0.0), # 2
		Vector3( 1.0, -phi,  0.0), # 3
		Vector3( 0.0, -1.0,  phi), # 4
		Vector3( 0.0,  1.0,  phi), # 5
		Vector3( 0.0, -1.0, -phi), # 6
		Vector3( 0.0,  1.0, -phi), # 7
		Vector3( phi,  0.0, -1.0), # 8
		Vector3( phi,  0.0,  1.0), # 9
		Vector3(-phi,  0.0, -1.0), # 10
		Vector3(-phi,  0.0,  1.0), # 11
	]

	# 20 triangular faces of the icosahedron (outward CCW winding)
	var base_triangles_idx: Array = [
		# 5 around vertex 0
		[0, 11, 5],
		[0, 5, 1],
		[0, 1, 7],
		[0, 7, 10],
		[0, 10, 11],
		# 5 adjacent to top
		[1, 5, 9],
		[5, 11, 4],
		[11, 10, 2],
		[10, 7, 6],
		[7, 1, 8],
		# 5 around vertex 3
		[3, 9, 4],
		[3, 4, 2],
		[3, 2, 6],
		[3, 6, 8],
		[3, 8, 9],
		# 5 adjacent to bottom
		[4, 9, 5],
		[2, 4, 11],
		[6, 2, 10],
		[8, 6, 7],
		[9, 8, 1],
	]

	var current_triangles: Array = []
	for tri_idx in base_triangles_idx:
		var v0: Vector3 = template[tri_idx[0]].normalized() * rad
		var v1: Vector3 = template[tri_idx[1]].normalized() * rad
		var v2: Vector3 = template[tri_idx[2]].normalized() * rad
		# Ensure CCW outward normal
		var norm: Vector3 = (v1 - v0).cross(v2 - v0)
		if norm.dot(v0 + v1 + v2) < 0.0:
			current_triangles.append([v0, v2, v1])
		else:
			current_triangles.append([v0, v1, v2])

	# Subdivide recursively
	for _s in range(subs):
		var next_triangles: Array = []
		for tri in current_triangles:
			var p0: Vector3 = tri[0]
			var p2: Vector3 = tri[1]
			var p5: Vector3 = tri[2]

			var p1: Vector3 = ((p0 + p2) * 0.5).normalized() * rad
			var p3: Vector3 = ((p0 + p5) * 0.5).normalized() * rad
			var p4: Vector3 = ((p2 + p5) * 0.5).normalized() * rad

			next_triangles.append([p0, p1, p3])
			next_triangles.append([p1, p2, p4])
			next_triangles.append([p1, p4, p3])
			next_triangles.append([p3, p4, p5])
		current_triangles = next_triangles

	# Build mesh arrays: unshared vertices (3 per triangle)
	var positions := PackedVector3Array()
	var textures0 := PackedVector2Array()
	var faces: Array[PBFace] = []

	var total_verts: int = current_triangles.size() * 3
	positions.resize(total_verts)
	textures0.resize(total_verts)

	var smooth_grp: int = 1 if smooth else 0

	for i in range(current_triangles.size()):
		var tri: Array = current_triangles[i]
		var base: int = i * 3

		var v0: Vector3 = tri[0]
		var v1: Vector3 = tri[1]
		var v2: Vector3 = tri[2]

		positions[base + 0] = v0
		positions[base + 1] = v1
		positions[base + 2] = v2

		# Spherical UV coordinates
		var n0: Vector3 = v0.normalized()
		var n1: Vector3 = v1.normalized()
		var n2: Vector3 = v2.normalized()

		textures0[base + 0] = Vector2(0.5 + atan2(n0.z, n0.x) / (2.0 * PI), 0.5 - asin(clampf(n0.y, -1.0, 1.0)) / PI)
		textures0[base + 1] = Vector2(0.5 + atan2(n1.z, n1.x) / (2.0 * PI), 0.5 - asin(clampf(n1.y, -1.0, 1.0)) / PI)
		textures0[base + 2] = Vector2(0.5 + atan2(n2.z, n2.x) / (2.0 * PI), 0.5 - asin(clampf(n2.y, -1.0, 1.0)) / PI)

		var face := PBFace.new(PackedInt32Array([base + 0, base + 1, base + 2]))
		face.smoothing_group = smooth_grp
		faces.append(face)

	mesh_data.positions = positions
	mesh_data.textures0 = textures0
	mesh_data.faces = faces
	mesh_data.shared_vertices = _build_shared_vertices(positions)
	mesh_data.shared_textures = []
	mesh_data.invalidate_caches()
	return mesh_data

# ==============================================================================
# 2. Torus Generator
# ==============================================================================

## Creates a torus mesh centered at the origin in the XZ plane.
## rows: cross-section divisions, columns: revolution divisions.
static func create_torus(
	major_radius: float = 0.5,
	minor_radius: float = 0.15,
	rows: int = 12,
	columns: int = 16,
	smooth: bool = true
) -> PBMeshData:
	var mesh_data := PBMeshData.new()
	var num_rows: int = maxi(3, rows)
	var num_cols: int = maxi(3, columns)

	var positions := PackedVector3Array()
	var textures0 := PackedVector2Array()
	var faces: Array[PBFace] = []

	var smooth_grp: int = 1 if smooth else 0

	for j in range(num_cols):
		var j1: int = j
		var j2: int = (j + 1) % num_cols

		var theta1: float = (float(j1) / float(num_cols)) * TAU
		var theta2: float = (float(j2) / float(num_cols)) * TAU

		var cos_t1: float = cos(theta1)
		var sin_t1: float = sin(theta1)
		var cos_t2: float = cos(theta2)
		var sin_t2: float = sin(theta2)

		var u1: float = float(j1) / float(num_cols)
		var u2: float = float(j + 1) / float(num_cols)

		for i in range(num_rows):
			var i1: int = i
			var i2: int = (i + 1) % num_rows

			var phi1: float = (float(i1) / float(num_rows)) * TAU
			var phi2: float = (float(i2) / float(num_rows)) * TAU

			var cos_p1: float = cos(phi1)
			var sin_p1: float = sin(phi1)
			var cos_p2: float = cos(phi2)
			var sin_p2: float = sin(phi2)

			var v1: float = float(i1) / float(num_rows)
			var v2: float = float(i + 1) / float(num_rows)

			var r1: float = major_radius + minor_radius * cos_p1
			var r2: float = major_radius + minor_radius * cos_p2

			# 4 quad vertices
			var p0 := Vector3(r1 * cos_t1, minor_radius * sin_p1, r1 * sin_t1)
			var p1 := Vector3(r1 * cos_t2, minor_radius * sin_p1, r1 * sin_t2)
			var p2 := Vector3(r2 * cos_t2, minor_radius * sin_p2, r2 * sin_t2)
			var p3 := Vector3(r2 * cos_t1, minor_radius * sin_p2, r2 * sin_t1)

			var uv0 := Vector2(u1, v1)
			var uv1 := Vector2(u2, v1)
			var uv2 := Vector2(u2, v2)
			var uv3 := Vector2(u1, v2)

			# Winding: (p0, p1, p2, p3) walks +theta then +phi, whose cross
			# product points INTO the tube (inward normals — the classic
			# inside-out torus). Traversing p0 → p3 → p2 → p1 flips the quad
			# to CCW-from-outside like every other generator.
			_add_quad(positions, textures0, faces, p0, p3, p2, p1, uv0, uv3, uv2, uv1, smooth_grp)

	mesh_data.positions = positions
	mesh_data.textures0 = textures0
	mesh_data.faces = faces
	mesh_data.shared_vertices = _build_shared_vertices(positions)
	mesh_data.shared_textures = []
	mesh_data.invalidate_caches()
	return mesh_data

# ==============================================================================
# 3. Arch Generator
# ==============================================================================

## Creates an extruded cylindrical arch segment with inner and outer profiles.
static func create_arch(
	radius: float = 1.0,
	depth: float = 0.5,
	thickness: float = 0.25,
	sides: int = 8,
	arch_degrees: float = 180.0,
	end_caps: bool = true,
	smooth: bool = true
) -> PBMeshData:
	var mesh_data := PBMeshData.new()
	var num_sides: int = maxi(3, sides)
	var degs: float = clampf(arch_degrees, 1.0, 360.0)
	# The tube can never be thicker than the arch's radius (the inner
	# profile would fold inside out past the outer one).
	var inner_rad: float = maxf(0.001, radius - minf(thickness, radius * 0.999))
	var hd: float = depth * 0.5
	var is_full_circle: bool = absf(degs - 360.0) < 0.001
	var make_caps: bool = end_caps and not is_full_circle

	# Outer and inner 2D profile points along the arc
	var outer_pts: Array[Vector2] = []
	var inner_pts: Array[Vector2] = []
	for k in range(num_sides + 1):
		var angle_rad: float = deg_to_rad(degs * float(k) / float(num_sides))
		var cos_a: float = cos(angle_rad)
		var sin_a: float = sin(angle_rad)
		outer_pts.append(Vector2(radius * cos_a, radius * sin_a))
		inner_pts.append(Vector2(inner_rad * cos_a, inner_rad * sin_a))

	var positions := PackedVector3Array()
	var textures0 := PackedVector2Array()
	var faces: Array[PBFace] = []

	var wall_smooth_grp: int = 1 if smooth else 0

	for k in range(num_sides):
		var k1: int = k
		var k2: int = k + 1

		var o_f1 := Vector3(outer_pts[k1].x, outer_pts[k1].y,  hd)
		var o_f2 := Vector3(outer_pts[k2].x, outer_pts[k2].y,  hd)
		var o_b1 := Vector3(outer_pts[k1].x, outer_pts[k1].y, -hd)
		var o_b2 := Vector3(outer_pts[k2].x, outer_pts[k2].y, -hd)

		var i_f1 := Vector3(inner_pts[k1].x, inner_pts[k1].y,  hd)
		var i_f2 := Vector3(inner_pts[k2].x, inner_pts[k2].y,  hd)
		var i_b1 := Vector3(inner_pts[k1].x, inner_pts[k1].y, -hd)
		var i_b2 := Vector3(inner_pts[k2].x, inner_pts[k2].y, -hd)

		# 1. Outer wall quad (facing outwards)
		_add_quad(positions, textures0, faces, o_f1, o_b1, o_b2, o_f2, Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1), wall_smooth_grp)

		# 2. Inner wall quad (facing inwards)
		_add_quad(positions, textures0, faces, i_f1, i_f2, i_b2, i_b1, Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1), wall_smooth_grp)

		# 3. Front face quad (facing +Z)
		_add_quad(positions, textures0, faces, i_f1, o_f1, o_f2, i_f2, Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1), 0)

		# 4. Back face quad (facing -Z)
		_add_quad(positions, textures0, faces, i_b1, i_b2, o_b2, o_b1, Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1), 0)

	# End caps if not full 360 circle
	if make_caps:
		# Start cap (at k = 0, facing along -tangent)
		var i_f0 := Vector3(inner_pts[0].x, inner_pts[0].y,  hd)
		var i_b0 := Vector3(inner_pts[0].x, inner_pts[0].y, -hd)
		var o_b0 := Vector3(outer_pts[0].x, outer_pts[0].y, -hd)
		var o_f0 := Vector3(outer_pts[0].x, outer_pts[0].y,  hd)
		_add_quad(positions, textures0, faces, i_f0, i_b0, o_b0, o_f0, Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1), 0)

		# End cap (at k = num_sides, facing along +tangent)
		var i_fk := Vector3(inner_pts[num_sides].x, inner_pts[num_sides].y,  hd)
		var o_fk := Vector3(outer_pts[num_sides].x, outer_pts[num_sides].y,  hd)
		var o_bk := Vector3(outer_pts[num_sides].x, outer_pts[num_sides].y, -hd)
		var i_bk := Vector3(inner_pts[num_sides].x, inner_pts[num_sides].y, -hd)
		_add_quad(positions, textures0, faces, i_fk, o_fk, o_bk, i_bk, Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1), 0)

	mesh_data.positions = positions
	mesh_data.textures0 = textures0
	mesh_data.faces = faces
	mesh_data.shared_vertices = _build_shared_vertices(positions)
	mesh_data.shared_textures = []
	mesh_data.invalidate_caches()
	return mesh_data

# ==============================================================================
# 4. Stairs Generator (Straight Only)
# ==============================================================================

## Creates a straight staircase centered at the origin.
## size: total bounding box extents, steps: number of steps, sides: whether to build side walls and back.
static func create_stairs(
	size: Vector3 = Vector3(1, 1, 2),
	steps: int = 6,
	sides: bool = true
) -> PBMeshData:
	var mesh_data := PBMeshData.new()
	var num_steps: int = maxi(1, steps)

	var hw: float = size.x * 0.5
	var hh: float = size.y * 0.5
	var hd: float = size.z * 0.5

	var step_h: float = size.y / float(num_steps)
	var step_d: float = size.z / float(num_steps)

	var positions := PackedVector3Array()
	var textures0 := PackedVector2Array()
	var faces: Array[PBFace] = []

	for s in range(num_steps):
		var y0: float = -hh + float(s) * step_h
		var y1: float = -hh + float(s + 1) * step_h
		var z0: float = -hd + float(s) * step_d
		var z1: float = -hd + float(s + 1) * step_d

		# 1. Riser: vertical front face (normal -Z)
		var r0 := Vector3(-hw, y0, z0)
		var r1 := Vector3(-hw, y1, z0)
		var r2 := Vector3( hw, y1, z0)
		var r3 := Vector3( hw, y0, z0)
		_add_quad(positions, textures0, faces, r0, r1, r2, r3)

		# 2. Tread: horizontal top face (normal +Y)
		var t0 := Vector3(-hw, y1, z0)
		var t1 := Vector3(-hw, y1, z1)
		var t2 := Vector3( hw, y1, z1)
		var t3 := Vector3( hw, y1, z0)
		_add_quad(positions, textures0, faces, t0, t1, t2, t3)

		if sides:
			# Left side wall quad under step s (normal -X)
			var ls0 := Vector3(-hw, -hh, z0)
			var ls1 := Vector3(-hw, -hh, z1)
			var ls2 := Vector3(-hw,  y1, z1)
			var ls3 := Vector3(-hw,  y1, z0)
			_add_quad(positions, textures0, faces, ls0, ls1, ls2, ls3)

			# Right side wall quad under step s (normal +X)
			var rs0 := Vector3(hw, -hh, z0)
			var rs1 := Vector3(hw,  y1, z0)
			var rs2 := Vector3(hw,  y1, z1)
			var rs3 := Vector3(hw, -hh, z1)
			_add_quad(positions, textures0, faces, rs0, rs1, rs2, rs3)

	if sides:
		# Back wall quad (normal +Z)
		var b0 := Vector3(-hw, -hh, hd)
		var b1 := Vector3( hw, -hh, hd)
		var b2 := Vector3( hw,  hh, hd)
		var b3 := Vector3(-hw,  hh, hd)
		_add_quad(positions, textures0, faces, b0, b1, b2, b3)

	mesh_data.positions = positions
	mesh_data.textures0 = textures0
	mesh_data.faces = faces
	mesh_data.shared_vertices = _build_shared_vertices(positions)
	mesh_data.shared_textures = []
	mesh_data.invalidate_caches()
	return mesh_data

# ==============================================================================
# 5. Door Generator
# ==============================================================================

## Creates a doorway frame centered at the origin with an opening.
## width / height / depth: overall bounding dimensions.
## opening_height: opening height measured from the bottom edge.
## leg_width: width of each side leg (the frame).
## arched: top the opening with a semicircular arch (one arc segment per
##         arch_segments) instead of a flat lintel. The arch always spans
##         the full opening width; when the opening is taller than half its
##         width it is a true semicircle, otherwise it flattens into an
##         elliptical segment springing from the opening's bottom corners.
static func create_door(
	width: float = 3.0,
	height: float = 2.5,
	opening_height: float = 2.0,
	leg_width: float = 0.5,
	depth: float = 1.0,
	arched: bool = true,
	arch_segments: int = 6
) -> PBMeshData:
	var mesh_data := PBMeshData.new()

	var hw: float = width * 0.5
	var hh: float = height * 0.5
	var hd: float = depth * 0.5

	# Frame columns (leg_width clamped so the opening can never close).
	var leg: float = clampf(leg_width, 0.01, width * 0.5 - 0.01)
	var x0: float = -hw
	var x1: float = -hw + leg
	var x2: float = hw - leg
	var x3: float = hw
	var xc: float = 0.5 * (x1 + x2)

	# Opening top, measured from the bottom edge (always below the frame top).
	var y0: float = -hh
	var y2: float = hh
	var yo: float = y0 + clampf(opening_height, 0.05, height - 0.05)

	# Arch profile: an ellipse arc spanning the opening, springing at
	# spring_y and peaking at the opening top. A true semicircle when the
	# opening is at least half as tall as it is wide.
	var spring_y: float = yo
	var arc_segs: int = 0
	var arc: PackedVector2Array = PackedVector2Array()
	if arched:
		var rise: float = minf(0.5 * (x2 - x1), yo - y0)
		if rise >= 0.0001:
			spring_y = yo - rise
			if absf(spring_y - y0) < 0.0001:
				spring_y = y0  # exact floor springing
			arc_segs = maxi(1, arch_segments)
			for k in range(arc_segs + 1):
				var t: float = PI * (1.0 - float(k) / float(arc_segs))
				arc.append(Vector2(xc + (xc - x1) * cos(t), spring_y + rise * sin(t)))
			arc[0] = Vector2(x1, spring_y)
			arc[arc_segs] = Vector2(x2, spring_y)
			# Snap apex points that touch the opening top onto it exactly — the
			# spandrel corners and the header strip boundaries must be THE SAME
			# point or the shell carries a float-fuzz T-junction.
			for k in range(arc_segs + 1):
				if absf(arc[k].y - yo) < 0.0001:
					arc[k].y = yo

	## The shell is welded ONE FACE PER SIDE, and the sides are SIMPLE
	## POLYGONS: the opening is a notch touching the bottom edge, so the
	## front/back are one concave n-gon each (ear-clipped — the notch adds
	## no hole and no interior triangulation edges reach the perimeter).
	## The perimeter carries no collinear splits: the outer walls and the
	## top are plain full-size quads that pair edge-for-edge with it, and
	## extruding a side produces exactly one wall per true edge.
	var has_jambs: bool = spring_y > y0 + 0.0001

	var positions := PackedVector3Array()
	var textures0 := PackedVector2Array()
	var faces: Array[PBFace] = []

	# ── Front/back sides (z = ±hd): ONE ear-clipped n-gon each ──────────────
	# CCW corner walk: bottom rim into the notch, over the arch (or under
	# the lintel), back along the bottom rim, up the right side and across.
	# (Corner dedup matters: a floor-springing arch's arc endpoints ARE its
	# rim corners.)
	var front2 := PackedVector2Array()
	var push := func(p: Vector2) -> void:
		if front2.is_empty() or front2[front2.size() - 1].distance_to(p) > 0.0001:
			front2.append(p)
	push.call(Vector2(x0, y0))
	push.call(Vector2(x1, y0))
	if arc_segs > 0:
		for k in range(arc_segs + 1):
			push.call(arc[k])
	else:
		push.call(Vector2(x1, yo))
		push.call(Vector2(x2, yo))
	push.call(Vector2(x2, y0))
	push.call(Vector2(x3, y0))
	push.call(Vector2(x3, y2))
	push.call(Vector2(x0, y2))
	# The walk closes: drop a final corner equal to the first one.
	if front2.size() > 3 and front2[0].distance_to(front2[front2.size() - 1]) < 0.0001:
		front2.remove_at(front2.size() - 1)

	# The ear clip needs the CCW (front) winding; the back face re-uses the
	# same triangulation with each triangle's winding flipped (CCW-from-
	# outside flips with the normal).
	var corner_tris: Array = _triangulate_2d(front2)
	for z in [hd, -hd]:
		var base: int = positions.size()
		for p in front2:
			positions.append(Vector3(p.x, p.y, z))
			textures0.append(p)
		var indexes := PackedInt32Array()
		for t in corner_tris:
			if z == hd:
				indexes.append_array(PackedInt32Array([base + int(t[0]), base + int(t[1]), base + int(t[2])]))
			else:
				indexes.append_array(PackedInt32Array([base + int(t[0]), base + int(t[2]), base + int(t[1])]))
		faces.append(PBFace.new(indexes))

	# ── Opening reveals ──────────────────────────────────────────────────────
	# A flat-topped opening (or a semicircle springing above the floor) has
	# jamb walls; an elliptical arch springing at the floor has none.
	if has_jambs:
		# Left jamb (normal +X)
		_add_quad(positions, textures0, faces,
			Vector3(x1, y0, hd), Vector3(x1, y0, -hd), Vector3(x1, spring_y, -hd), Vector3(x1, spring_y, hd))
		# Right jamb (normal -X)
		_add_quad(positions, textures0, faces,
			Vector3(x2, y0, hd), Vector3(x2, spring_y, hd), Vector3(x2, spring_y, -hd), Vector3(x2, y0, -hd))
	if arc_segs == 0:
		# Flat lintel underside (normal -Y)
		_add_quad(positions, textures0, faces,
			Vector3(x1, yo, hd), Vector3(x1, yo, -hd), Vector3(x2, yo, -hd), Vector3(x2, yo, hd))
	else:
		# Arch tunnel: one quad per segment, normals pointing into the
		# opening (toward the arc center).
		for k in range(arc_segs):
			_add_quad(positions, textures0, faces,
				Vector3(arc[k].x, arc[k].y, hd), Vector3(arc[k].x, arc[k].y, -hd),
				Vector3(arc[k + 1].x, arc[k + 1].y, -hd), Vector3(arc[k + 1].x, arc[k + 1].y, hd))

	# ── Outer shell (the frame's outside faces) ─────────────────────────────
	# Plain full-size quads: the front/back polygons' side and top edges are
	# single perimeter edges now, so the walls and top pair edge-for-edge
	# with no split points at all.
	# Left outer wall (normal -X)
	_add_quad(positions, textures0, faces,
		Vector3(x0, y0, -hd), Vector3(x0, y0, hd), Vector3(x0, y2, hd), Vector3(x0, y2, -hd))
	# Right outer wall (normal +X)
	_add_quad(positions, textures0, faces,
		Vector3(x3, y0, -hd), Vector3(x3, y2, -hd), Vector3(x3, y2, hd), Vector3(x3, y0, hd))
	# Top wall (normal +Y)
	_add_quad(positions, textures0, faces,
		Vector3(x0, y2, -hd), Vector3(x0, y2, hd), Vector3(x3, y2, hd), Vector3(x3, y2, -hd))

	mesh_data.positions = positions
	mesh_data.textures0 = textures0
	mesh_data.faces = faces
	mesh_data.shared_vertices = _build_shared_vertices(positions)
	mesh_data.shared_textures = []
	mesh_data.invalidate_caches()
	return mesh_data
