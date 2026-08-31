## PBShapeComplex — Generator for complex ProBuilder shape primitives.
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

			_add_quad(positions, textures0, faces, p0, p1, p2, p3, uv0, uv1, uv2, uv3, smooth_grp)

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
	var inner_rad: float = maxf(0.001, radius - thickness)
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

## Creates a doorway frame centered at the origin with opening.
## width, height, depth: overall bounding dimensions.
## door_height: height of the top lintel / pediment.
## leg_width: width of each side leg.
static func create_door(
	width: float = 3.0,
	height: float = 2.5,
	door_height: float = 0.5,
	leg_width: float = 0.75,
	depth: float = 1.0
) -> PBMeshData:
	var mesh_data := PBMeshData.new()

	var hw: float = width * 0.5
	var hh: float = height * 0.5
	var hd: float = depth * 0.5

	var x0: float = -hw
	var x1: float = -hw + leg_width
	var x2: float =  hw - leg_width
	var x3: float =  hw

	var y0: float = -hh
	var y1: float =  hh - door_height
	var y2: float =  hh

	# 12 Template points on front plane (Z = +hd)
	var p0 := Vector3(x0, y0, hd)
	var p1 := Vector3(x1, y0, hd)
	var p2 := Vector3(x2, y0, hd)
	var p3 := Vector3(x3, y0, hd)

	var p4 := Vector3(x0, y1, hd)
	var p5 := Vector3(x1, y1, hd)
	var p6 := Vector3(x2, y1, hd)
	var p7 := Vector3(x3, y1, hd)

	var p8 := Vector3(x0, y2, hd)
	var p9 := Vector3(x1, y2, hd)
	var p10 := Vector3(x2, y2, hd)
	var p11 := Vector3(x3, y2, hd)

	# 12 Template points on back plane (Z = -hd)
	var b0 := Vector3(x0, y0, -hd)
	var b1 := Vector3(x1, y0, -hd)
	var b2 := Vector3(x2, y0, -hd)
	var b3 := Vector3(x3, y0, -hd)

	var b4 := Vector3(x0, y1, -hd)
	var b5 := Vector3(x1, y1, -hd)
	var b6 := Vector3(x2, y1, -hd)
	var b7 := Vector3(x3, y1, -hd)

	var b8 := Vector3(x0, y2, -hd)
	var b9 := Vector3(x1, y2, -hd)
	var b10 := Vector3(x2, y2, -hd)
	var b11 := Vector3(x3, y2, -hd)

	var positions := PackedVector3Array()
	var textures0 := PackedVector2Array()
	var faces: Array[PBFace] = []

	# 5 Front quads (normal +Z)
	_add_quad(positions, textures0, faces, p0, p1, p5, p4)   # Left leg
	_add_quad(positions, textures0, faces, p4, p5, p9, p8)   # Top left
	_add_quad(positions, textures0, faces, p5, p6, p10, p9)  # Top mid
	_add_quad(positions, textures0, faces, p6, p7, p11, p10) # Top right
	_add_quad(positions, textures0, faces, p2, p3, p7, p6)   # Right leg

	# 5 Back quads (normal -Z)
	_add_quad(positions, textures0, faces, b0, b4, b5, b1)   # Left leg
	_add_quad(positions, textures0, faces, b4, b8, b9, b5)   # Top left
	_add_quad(positions, textures0, faces, b5, b9, b10, b6)  # Top mid
	_add_quad(positions, textures0, faces, b6, b10, b11, b7) # Top right
	_add_quad(positions, textures0, faces, b2, b6, b7, b3)   # Right leg

	# 3 Inner frame quads
	# Left jamb (normal +X)
	_add_quad(positions, textures0, faces, p1, b1, b5, p5)
	# Right jamb (normal -X)
	_add_quad(positions, textures0, faces, p2, p6, b6, b2)
	# Lintel underside (normal -Y)
	_add_quad(positions, textures0, faces, p5, b5, b6, p6)

	mesh_data.positions = positions
	mesh_data.textures0 = textures0
	mesh_data.faces = faces
	mesh_data.shared_vertices = _build_shared_vertices(positions)
	mesh_data.shared_textures = []
	mesh_data.invalidate_caches()
	return mesh_data
