## PBShapeCylinder — Procedural cylindrical mesh generators for PoiBuilder.
##
## Provides static factory methods to generate:
## - Cylinder (with optional height subdivisions and smoothing)
## - Cone (with optional smoothing)
## - Pipe (hollow cylinder with configurable thickness and subdivisions)
## All returned meshes are PBMeshData instances with valid topologies, UVs,
## and shared vertex groupings.
@tool
class_name PBShapeCylinder
extends RefCounted


# ==============================================================================
# Helper Methods
# ==============================================================================

## Groups disjoint vertex indices that share identical 3D positions into PBSharedVertex objects.
static func _build_shared_vertices(positions: PackedVector3Array, tolerance: float = 0.0001) -> Array[PBSharedVertex]:
	var groups: Array[PackedInt32Array] = []
	var grid: Dictionary = {}
	var inv_cell: float = 1.0 / (tolerance * 10.0)

	for i in range(positions.size()):
		var p: Vector3 = positions[i]
		var cell := Vector3i(int(floor(p.x * inv_cell)), int(floor(p.y * inv_cell)), int(floor(p.z * inv_cell)))
		var found_group: int = -1

		for dx in range(-1, 2):
			for dy in range(-1, 2):
				for dz in range(-1, 2):
					var neighbor_cell := cell + Vector3i(dx, dy, dz)
					if grid.has(neighbor_cell):
						var cand_groups: Array = grid[neighbor_cell]
						for g_idx in cand_groups:
							if positions[groups[g_idx][0]].distance_to(p) <= tolerance:
								found_group = g_idx
								break
					if found_group != -1:
						break
				if found_group != -1:
					break
			if found_group != -1:
				break

		if found_group != -1:
			groups[found_group].append(i)
		else:
			var new_group_idx: int = groups.size()
			groups.append(PackedInt32Array([i]))
			if not grid.has(cell):
				grid[cell] = []
			grid[cell].append(new_group_idx)

	var shared: Array[PBSharedVertex] = []
	for g in groups:
		shared.append(PBSharedVertex.new(g))
	return shared


# ==============================================================================
# 1. Cylinder Generator
# ==============================================================================

## Creates a cylinder centered at origin, axis along Y.
## - `radius`: cylinder radius
## - `height`: total cylinder height
## - `axis_divisions`: number of sides around circumference (min 3, max 64)
## - `height_cuts`: number of horizontal subdivisions (0 = no cuts = 1 wall segment)
## - `smooth`: if true, wall faces have smoothing_group = 1 (caps remain 0)
static func create_cylinder(
	radius: float = 0.5,
	height: float = 1.0,
	axis_divisions: int = 8,
	height_cuts: int = 0,
	smooth: bool = true
) -> PBMeshData:
	var div: int = clampi(axis_divisions, 3, 64)
	var cuts: int = maxi(0, height_cuts)
	var h_segments: int = cuts + 1

	var hy: float = height * 0.5
	var y_step: float = height / float(h_segments)

	var positions := PackedVector3Array()
	var textures0 := PackedVector2Array()
	var faces: Array[PBFace] = []

	var vert_offset: int = 0

	# 1. Wall Quads
	for s in range(h_segments):
		var y0: float = -hy + float(s) * y_step
		var y1: float = -hy + float(s + 1) * y_step
		var v0: float = float(s) / float(h_segments)
		var v1: float = float(s + 1) / float(h_segments)

		for i in range(div):
			var theta0: float = float(i) * TAU / float(div)
			var theta1: float = float(i + 1) * TAU / float(div)

			var u0: float = float(i) / float(div)
			var u1: float = float(i + 1) / float(div)

			var cos0: float = cos(theta0)
			var sin0: float = sin(theta0)
			var cos1: float = cos(theta1)
			var sin1: float = sin(theta1)

			# 4 vertices per quad in CCW order from outside:
			# (theta0, y0) -> (theta0, y1) -> (theta1, y1) -> (theta1, y0)
			positions.append(Vector3(radius * cos0, y0, radius * sin0))
			positions.append(Vector3(radius * cos0, y1, radius * sin0))
			positions.append(Vector3(radius * cos1, y1, radius * sin1))
			positions.append(Vector3(radius * cos1, y0, radius * sin1))

			textures0.append(Vector2(u0, v0))
			textures0.append(Vector2(u0, v1))
			textures0.append(Vector2(u1, v1))
			textures0.append(Vector2(u1, v0))

			var face := PBFace.new(PackedInt32Array([
				vert_offset + 0, vert_offset + 1, vert_offset + 2,
				vert_offset + 2, vert_offset + 3, vert_offset + 0
			]))
			if smooth:
				face.smoothing_group = 1
			faces.append(face)
			vert_offset += 4

	# 2. Top Cap (+Y)
	var top_center := Vector3(0.0, hy, 0.0)
	var top_center_uv := Vector2(0.5, 0.5)

	for i in range(div):
		var theta0: float = float(i) * TAU / float(div)
		var theta1: float = float(i + 1) * TAU / float(div)

		var cos0: float = cos(theta0)
		var sin0: float = sin(theta0)
		var cos1: float = cos(theta1)
		var sin1: float = sin(theta1)

		var p0 := Vector3(radius * cos0, hy, radius * sin0)
		var p1 := Vector3(radius * cos1, hy, radius * sin1)

		# Winding for +Y normal (CCW viewed from above): top_center, p1, p0.
		# (theta0, p0, p1) crosses to -Y — that is the bottom-cap order.
		positions.append(top_center)
		positions.append(p1)
		positions.append(p0)

		textures0.append(top_center_uv)
		textures0.append(Vector2(0.5 + 0.5 * cos1, 0.5 + 0.5 * sin1))
		textures0.append(Vector2(0.5 + 0.5 * cos0, 0.5 + 0.5 * sin0))

		var face := PBFace.new(PackedInt32Array([
			vert_offset + 0, vert_offset + 1, vert_offset + 2
		]))
		face.smoothing_group = 0
		faces.append(face)
		vert_offset += 3

	# 3. Bottom Cap (-Y)
	var bottom_center := Vector3(0.0, -hy, 0.0)
	var bottom_center_uv := Vector2(0.5, 0.5)

	for i in range(div):
		var theta0: float = float(i) * TAU / float(div)
		var theta1: float = float(i + 1) * TAU / float(div)

		var cos0: float = cos(theta0)
		var sin0: float = sin(theta0)
		var cos1: float = cos(theta1)
		var sin1: float = sin(theta1)

		var p0 := Vector3(radius * cos0, -hy, radius * sin0)
		var p1 := Vector3(radius * cos1, -hy, radius * sin1)

		# Winding for -Y normal (CCW viewed from below): bottom_center, p0, p1.
		positions.append(bottom_center)
		positions.append(p0)
		positions.append(p1)

		textures0.append(bottom_center_uv)
		textures0.append(Vector2(0.5 + 0.5 * cos0, 0.5 + 0.5 * sin0))
		textures0.append(Vector2(0.5 + 0.5 * cos1, 0.5 + 0.5 * sin1))

		var face := PBFace.new(PackedInt32Array([
			vert_offset + 0, vert_offset + 1, vert_offset + 2
		]))
		face.smoothing_group = 0
		faces.append(face)
		vert_offset += 3

	var mesh_data := PBMeshData.new()
	mesh_data.positions = positions
	mesh_data.textures0 = textures0
	mesh_data.faces = faces
	mesh_data.shared_vertices = _build_shared_vertices(positions)
	mesh_data.shared_textures = []
	mesh_data.invalidate_caches()
	return mesh_data


# ==============================================================================
# 2. Cone Generator
# ==============================================================================

## Creates a cone centered at origin with base at Y = -height/2 and apex at Y = +height/2.
## - `radius`: base radius
## - `height`: total cone height
## - `sides`: number of sides around base (min 3, max 64)
## - `smooth`: if true, side faces have smoothing_group = 1 (bottom remains 0)
static func create_cone(
	radius: float = 0.5,
	height: float = 1.0,
	sides: int = 8,
	smooth: bool = true
) -> PBMeshData:
	var side_count: int = clampi(sides, 3, 64)
	var hy: float = height * 0.5

	var positions := PackedVector3Array()
	var textures0 := PackedVector2Array()
	var faces: Array[PBFace] = []

	var vert_offset: int = 0

	var apex := Vector3(0.0, hy, 0.0)
	var bottom_center := Vector3(0.0, -hy, 0.0)
	var bottom_center_uv := Vector2(0.5, 0.5)

	# 1. Side Faces (triangles: apex, ring[i+1], ring[i])
	for i in range(side_count):
		var theta0: float = float(i) * TAU / float(side_count)
		var theta1: float = float(i + 1) * TAU / float(side_count)

		var cos0: float = cos(theta0)
		var sin0: float = sin(theta0)
		var cos1: float = cos(theta1)
		var sin1: float = sin(theta1)

		var p0 := Vector3(radius * cos0, -hy, radius * sin0)
		var p1 := Vector3(radius * cos1, -hy, radius * sin1)

		# Side face winding (CCW from outside): apex, ring[i+1], ring[i]
		positions.append(apex)
		positions.append(p1)
		positions.append(p0)

		# Planar UV projection
		textures0.append(Vector2(0.5, 1.0))
		textures0.append(Vector2(0.5 + 0.5 * cos1, 0.0))
		textures0.append(Vector2(0.5 + 0.5 * cos0, 0.0))

		var face := PBFace.new(PackedInt32Array([
			vert_offset + 0, vert_offset + 1, vert_offset + 2
		]))
		if smooth:
			face.smoothing_group = 1
		faces.append(face)
		vert_offset += 3

	# 2. Bottom Faces (triangles: ring[i], ring[i+1], bottom_center)
	for i in range(side_count):
		var theta0: float = float(i) * TAU / float(side_count)
		var theta1: float = float(i + 1) * TAU / float(side_count)

		var cos0: float = cos(theta0)
		var sin0: float = sin(theta0)
		var cos1: float = cos(theta1)
		var sin1: float = sin(theta1)

		var p0 := Vector3(radius * cos0, -hy, radius * sin0)
		var p1 := Vector3(radius * cos1, -hy, radius * sin1)

		# Bottom face winding (CCW from below): ring[i], ring[i+1], bottom_center
		positions.append(p0)
		positions.append(p1)
		positions.append(bottom_center)

		# Radial UV projection
		textures0.append(Vector2(0.5 + 0.5 * cos0, 0.5 + 0.5 * sin0))
		textures0.append(Vector2(0.5 + 0.5 * cos1, 0.5 + 0.5 * sin1))
		textures0.append(bottom_center_uv)

		var face := PBFace.new(PackedInt32Array([
			vert_offset + 0, vert_offset + 1, vert_offset + 2
		]))
		face.smoothing_group = 0
		faces.append(face)
		vert_offset += 3

	var mesh_data := PBMeshData.new()
	mesh_data.positions = positions
	mesh_data.textures0 = textures0
	mesh_data.faces = faces
	mesh_data.shared_vertices = _build_shared_vertices(positions)
	mesh_data.shared_textures = []
	mesh_data.invalidate_caches()
	return mesh_data


# ==============================================================================
# 3. Pipe Generator
# ==============================================================================

## Creates a hollow pipe centered at origin, axis along Y.
## - `radius`: outer radius
## - `height`: total pipe height
## - `thickness`: wall thickness (inner radius = radius - thickness)
## - `sides`: number of sides around circumference (min 3, max 64)
## - `height_cuts`: number of horizontal subdivisions (0 = no cuts = 1 wall segment)
## - `smooth`: if true, wall faces (inner and outer) have smoothing_group = 1 (rims remain 0)
static func create_pipe(
	radius: float = 0.5,
	height: float = 1.0,
	thickness: float = 0.15,
	sides: int = 8,
	height_cuts: int = 0,
	smooth: bool = true
) -> PBMeshData:
	var side_count: int = clampi(sides, 3, 64)
	var cuts: int = maxi(0, height_cuts)
	var h_segments: int = cuts + 1

	var r_outer: float = radius
	var r_inner: float = radius - thickness
	if r_inner <= 0.0:
		r_inner = radius * 0.5

	var hy: float = height * 0.5
	var y_step: float = height / float(h_segments)

	var positions := PackedVector3Array()
	var textures0 := PackedVector2Array()
	var faces: Array[PBFace] = []

	var vert_offset: int = 0

	# 1. Outer Wall Quads
	for s in range(h_segments):
		var y0: float = -hy + float(s) * y_step
		var y1: float = -hy + float(s + 1) * y_step
		var v0: float = float(s) / float(h_segments)
		var v1: float = float(s + 1) / float(h_segments)

		for i in range(side_count):
			var theta0: float = float(i) * TAU / float(side_count)
			var theta1: float = float(i + 1) * TAU / float(side_count)

			var u0: float = float(i) / float(side_count)
			var u1: float = float(i + 1) / float(side_count)

			var cos0: float = cos(theta0)
			var sin0: float = sin(theta0)
			var cos1: float = cos(theta1)
			var sin1: float = sin(theta1)

			# Outer wall quad: outward normal
			positions.append(Vector3(r_outer * cos0, y0, r_outer * sin0))
			positions.append(Vector3(r_outer * cos0, y1, r_outer * sin0))
			positions.append(Vector3(r_outer * cos1, y1, r_outer * sin1))
			positions.append(Vector3(r_outer * cos1, y0, r_outer * sin1))

			textures0.append(Vector2(u0, v0))
			textures0.append(Vector2(u0, v1))
			textures0.append(Vector2(u1, v1))
			textures0.append(Vector2(u1, v0))

			var face := PBFace.new(PackedInt32Array([
				vert_offset + 0, vert_offset + 1, vert_offset + 2,
				vert_offset + 2, vert_offset + 3, vert_offset + 0
			]))
			if smooth:
				face.smoothing_group = 1
			faces.append(face)
			vert_offset += 4

	# 2. Inner Wall Quads
	# Reversed winding so normals point inward towards Y axis
	for s in range(h_segments):
		var y0: float = -hy + float(s) * y_step
		var y1: float = -hy + float(s + 1) * y_step
		var v0: float = float(s) / float(h_segments)
		var v1: float = float(s + 1) / float(h_segments)

		for i in range(side_count):
			var theta0: float = float(i) * TAU / float(side_count)
			var theta1: float = float(i + 1) * TAU / float(side_count)

			var u0: float = float(i) / float(side_count)
			var u1: float = float(i + 1) / float(side_count)

			var cos0: float = cos(theta0)
			var sin0: float = sin(theta0)
			var cos1: float = cos(theta1)
			var sin1: float = sin(theta1)

			# Inner wall quad: inward normal
			positions.append(Vector3(r_inner * cos1, y0, r_inner * sin1))
			positions.append(Vector3(r_inner * cos1, y1, r_inner * sin1))
			positions.append(Vector3(r_inner * cos0, y1, r_inner * sin0))
			positions.append(Vector3(r_inner * cos0, y0, r_inner * sin0))

			textures0.append(Vector2(u1, v0))
			textures0.append(Vector2(u1, v1))
			textures0.append(Vector2(u0, v1))
			textures0.append(Vector2(u0, v0))

			var face := PBFace.new(PackedInt32Array([
				vert_offset + 0, vert_offset + 1, vert_offset + 2,
				vert_offset + 2, vert_offset + 3, vert_offset + 0
			]))
			if smooth:
				face.smoothing_group = 1
			faces.append(face)
			vert_offset += 4

	# 3. Top Rim Quads (connecting inner and outer rings at Y = +hy, normal +Y)
	for i in range(side_count):
		var theta0: float = float(i) * TAU / float(side_count)
		var theta1: float = float(i + 1) * TAU / float(side_count)

		var cos0: float = cos(theta0)
		var sin0: float = sin(theta0)
		var cos1: float = cos(theta1)
		var sin1: float = sin(theta1)

		var p_in0 := Vector3(r_inner * cos0, hy, r_inner * sin0)
		var p_in1 := Vector3(r_inner * cos1, hy, r_inner * sin1)
		var p_out1 := Vector3(r_outer * cos1, hy, r_outer * sin1)
		var p_out0 := Vector3(r_outer * cos0, hy, r_outer * sin0)

		# Top rim quad: normal +Y
		positions.append(p_in0)
		positions.append(p_in1)
		positions.append(p_out1)
		positions.append(p_out0)

		# Planar radial UV projection
		textures0.append(Vector2(0.5 + 0.5 * (r_inner / r_outer) * cos0, 0.5 + 0.5 * (r_inner / r_outer) * sin0))
		textures0.append(Vector2(0.5 + 0.5 * (r_inner / r_outer) * cos1, 0.5 + 0.5 * (r_inner / r_outer) * sin1))
		textures0.append(Vector2(0.5 + 0.5 * cos1, 0.5 + 0.5 * sin1))
		textures0.append(Vector2(0.5 + 0.5 * cos0, 0.5 + 0.5 * sin0))

		var face := PBFace.new(PackedInt32Array([
			vert_offset + 0, vert_offset + 1, vert_offset + 2,
			vert_offset + 2, vert_offset + 3, vert_offset + 0
		]))
		face.smoothing_group = 0
		faces.append(face)
		vert_offset += 4

	# 4. Bottom Rim Quads (connecting outer and inner rings at Y = -hy, normal -Y)
	for i in range(side_count):
		var theta0: float = float(i) * TAU / float(side_count)
		var theta1: float = float(i + 1) * TAU / float(side_count)

		var cos0: float = cos(theta0)
		var sin0: float = sin(theta0)
		var cos1: float = cos(theta1)
		var sin1: float = sin(theta1)

		var p_out0 := Vector3(r_outer * cos0, -hy, r_outer * sin0)
		var p_out1 := Vector3(r_outer * cos1, -hy, r_outer * sin1)
		var p_in1 := Vector3(r_inner * cos1, -hy, r_inner * sin1)
		var p_in0 := Vector3(r_inner * cos0, -hy, r_inner * sin0)

		# Bottom rim quad: normal -Y
		positions.append(p_out0)
		positions.append(p_out1)
		positions.append(p_in1)
		positions.append(p_in0)

		# Planar radial UV projection
		textures0.append(Vector2(0.5 + 0.5 * cos0, 0.5 + 0.5 * sin0))
		textures0.append(Vector2(0.5 + 0.5 * cos1, 0.5 + 0.5 * sin1))
		textures0.append(Vector2(0.5 + 0.5 * (r_inner / r_outer) * cos1, 0.5 + 0.5 * (r_inner / r_outer) * sin1))
		textures0.append(Vector2(0.5 + 0.5 * (r_inner / r_outer) * cos0, 0.5 + 0.5 * (r_inner / r_outer) * sin0))

		var face := PBFace.new(PackedInt32Array([
			vert_offset + 0, vert_offset + 1, vert_offset + 2,
			vert_offset + 2, vert_offset + 3, vert_offset + 0
		]))
		face.smoothing_group = 0
		faces.append(face)
		vert_offset += 4

	var mesh_data := PBMeshData.new()
	mesh_data.positions = positions
	mesh_data.textures0 = textures0
	mesh_data.faces = faces
	mesh_data.shared_vertices = _build_shared_vertices(positions)
	mesh_data.shared_textures = []
	mesh_data.invalidate_caches()
	return mesh_data
