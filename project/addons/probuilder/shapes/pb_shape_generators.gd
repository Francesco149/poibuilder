## PBShapeGenerators — Procedural mesh generation primitives for ProBuilder.
##
## Provides static factory methods to generate common geometric shapes (Box, Plane, Sprite, Prism)
## as PBMeshData instances with valid topologies, UVs, and shared vertex groupings.
@tool
class_name PBShapeGenerators
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
# 1. Cube / Box Generator (Segmented)
# ==============================================================================

## Creates a subdivided 3D box centered at the origin.
## Each quad face contains 4 unique vertices and 1 PBFace (2 triangles = 6 indices).
static func create_box(
	size: Vector3 = Vector3.ONE,
	width_segments: int = 1,
	height_segments: int = 1,
	depth_segments: int = 1
) -> PBMeshData:
	var w_seg: int = maxi(1, width_segments)
	var h_seg: int = maxi(1, height_segments)
	var d_seg: int = maxi(1, depth_segments)

	var hx: float = size.x * 0.5
	var hy: float = size.y * 0.5
	var hz: float = size.z * 0.5

	var positions := PackedVector3Array()
	var textures0 := PackedVector2Array()
	var faces: Array[PBFace] = []

	var vert_offset: int = 0

	# Face 0: Front (Z = -hz), segmented along X (w_seg) and Y (h_seg)
	for gy in range(h_seg):
		for gx in range(w_seg):
			var u0: float = float(gx) / float(w_seg)
			var u1: float = float(gx + 1) / float(w_seg)
			var v0: float = float(gy) / float(h_seg)
			var v1: float = float(gy + 1) / float(h_seg)

			var x0: float = lerp(hx, -hx, u0)
			var x1: float = lerp(hx, -hx, u1)
			var y0: float = lerp(-hy, hy, v0)
			var y1: float = lerp(-hy, hy, v1)

			positions.append(Vector3(x0, y0, -hz))
			positions.append(Vector3(x1, y0, -hz))
			positions.append(Vector3(x1, y1, -hz))
			positions.append(Vector3(x0, y1, -hz))

			textures0.append(Vector2(u0, v0))
			textures0.append(Vector2(u1, v0))
			textures0.append(Vector2(u1, v1))
			textures0.append(Vector2(u0, v1))

			faces.append(PBFace.new(PackedInt32Array([
				vert_offset + 0, vert_offset + 1, vert_offset + 2,
				vert_offset + 2, vert_offset + 3, vert_offset + 0
			])))
			vert_offset += 4

	# Face 1: Back (Z = +hz), segmented along X (w_seg) and Y (h_seg)
	for gy in range(h_seg):
		for gx in range(w_seg):
			var u0: float = float(gx) / float(w_seg)
			var u1: float = float(gx + 1) / float(w_seg)
			var v0: float = float(gy) / float(h_seg)
			var v1: float = float(gy + 1) / float(h_seg)

			var x0: float = lerp(-hx, hx, u0)
			var x1: float = lerp(-hx, hx, u1)
			var y0: float = lerp(-hy, hy, v0)
			var y1: float = lerp(-hy, hy, v1)

			positions.append(Vector3(x0, y0, hz))
			positions.append(Vector3(x1, y0, hz))
			positions.append(Vector3(x1, y1, hz))
			positions.append(Vector3(x0, y1, hz))

			textures0.append(Vector2(u0, v0))
			textures0.append(Vector2(u1, v0))
			textures0.append(Vector2(u1, v1))
			textures0.append(Vector2(u0, v1))

			faces.append(PBFace.new(PackedInt32Array([
				vert_offset + 0, vert_offset + 1, vert_offset + 2,
				vert_offset + 2, vert_offset + 3, vert_offset + 0
			])))
			vert_offset += 4

	# Face 2: Left (X = -hx), segmented along Z (d_seg) and Y (h_seg)
	for gy in range(h_seg):
		for gz in range(d_seg):
			var u0: float = float(gz) / float(d_seg)
			var u1: float = float(gz + 1) / float(d_seg)
			var v0: float = float(gy) / float(h_seg)
			var v1: float = float(gy + 1) / float(h_seg)

			var z0: float = lerp(-hz, hz, u0)
			var z1: float = lerp(-hz, hz, u1)
			var y0: float = lerp(-hy, hy, v0)
			var y1: float = lerp(-hy, hy, v1)

			positions.append(Vector3(-hx, y0, z0))
			positions.append(Vector3(-hx, y0, z1))
			positions.append(Vector3(-hx, y1, z1))
			positions.append(Vector3(-hx, y1, z0))

			textures0.append(Vector2(u0, v0))
			textures0.append(Vector2(u1, v0))
			textures0.append(Vector2(u1, v1))
			textures0.append(Vector2(u0, v1))

			faces.append(PBFace.new(PackedInt32Array([
				vert_offset + 0, vert_offset + 1, vert_offset + 2,
				vert_offset + 2, vert_offset + 3, vert_offset + 0
			])))
			vert_offset += 4

	# Face 3: Right (X = +hx), segmented along Z (d_seg) and Y (h_seg)
	for gy in range(h_seg):
		for gz in range(d_seg):
			var u0: float = float(gz) / float(d_seg)
			var u1: float = float(gz + 1) / float(d_seg)
			var v0: float = float(gy) / float(h_seg)
			var v1: float = float(gy + 1) / float(h_seg)

			var z0: float = lerp(hz, -hz, u0)
			var z1: float = lerp(hz, -hz, u1)
			var y0: float = lerp(-hy, hy, v0)
			var y1: float = lerp(-hy, hy, v1)

			positions.append(Vector3(hx, y0, z0))
			positions.append(Vector3(hx, y0, z1))
			positions.append(Vector3(hx, y1, z1))
			positions.append(Vector3(hx, y1, z0))

			textures0.append(Vector2(u0, v0))
			textures0.append(Vector2(u1, v0))
			textures0.append(Vector2(u1, v1))
			textures0.append(Vector2(u0, v1))

			faces.append(PBFace.new(PackedInt32Array([
				vert_offset + 0, vert_offset + 1, vert_offset + 2,
				vert_offset + 2, vert_offset + 3, vert_offset + 0
			])))
			vert_offset += 4

	# Face 4: Top (Y = +hy), segmented along Z (d_seg) and X (w_seg)
	for gx in range(w_seg):
		for gz in range(d_seg):
			var u0: float = float(gz) / float(d_seg)
			var u1: float = float(gz + 1) / float(d_seg)
			var v0: float = float(gx) / float(w_seg)
			var v1: float = float(gx + 1) / float(w_seg)

			var z0: float = lerp(-hz, hz, u0)
			var z1: float = lerp(-hz, hz, u1)
			var x0: float = lerp(-hx, hx, v0)
			var x1: float = lerp(-hx, hx, v1)

			positions.append(Vector3(x0, hy, z0))
			positions.append(Vector3(x0, hy, z1))
			positions.append(Vector3(x1, hy, z1))
			positions.append(Vector3(x1, hy, z0))

			textures0.append(Vector2(u0, v0))
			textures0.append(Vector2(u1, v0))
			textures0.append(Vector2(u1, v1))
			textures0.append(Vector2(u0, v1))

			faces.append(PBFace.new(PackedInt32Array([
				vert_offset + 0, vert_offset + 1, vert_offset + 2,
				vert_offset + 2, vert_offset + 3, vert_offset + 0
			])))
			vert_offset += 4

	# Face 5: Bottom (Y = -hy), segmented along Z (d_seg) and X (w_seg)
	for gx in range(w_seg):
		for gz in range(d_seg):
			var u0: float = float(gz) / float(d_seg)
			var u1: float = float(gz + 1) / float(d_seg)
			var v0: float = float(gx) / float(w_seg)
			var v1: float = float(gx + 1) / float(w_seg)

			var z0: float = lerp(hz, -hz, u0)
			var z1: float = lerp(hz, -hz, u1)
			var x0: float = lerp(-hx, hx, v0)
			var x1: float = lerp(-hx, hx, v1)

			positions.append(Vector3(x0, -hy, z0))
			positions.append(Vector3(x0, -hy, z1))
			positions.append(Vector3(x1, -hy, z1))
			positions.append(Vector3(x1, -hy, z0))

			textures0.append(Vector2(u0, v0))
			textures0.append(Vector2(u1, v0))
			textures0.append(Vector2(u1, v1))
			textures0.append(Vector2(u0, v1))

			faces.append(PBFace.new(PackedInt32Array([
				vert_offset + 0, vert_offset + 1, vert_offset + 2,
				vert_offset + 2, vert_offset + 3, vert_offset + 0
			])))
			vert_offset += 4

	var mesh_data := PBMeshData.new()
	mesh_data.positions = positions
	mesh_data.textures0 = textures0
	mesh_data.faces = faces
	mesh_data.shared_vertices = _build_shared_vertices(positions)
	mesh_data.shared_textures = []
	mesh_data.invalidate_caches()
	return mesh_data


# ==============================================================================
# 2. Plane Generator
# ==============================================================================

## Creates a flat plane grid on the XZ plane (Y=0) centered at the origin.
## Creates width_segments × depth_segments quad faces with CCW winding (facing +Y).
static func create_plane(
	width: float = 1.0,
	depth: float = 1.0,
	width_segments: int = 1,
	depth_segments: int = 1
) -> PBMeshData:
	var w_seg: int = maxi(1, width_segments)
	var d_seg: int = maxi(1, depth_segments)

	var hw: float = width * 0.5
	var hd: float = depth * 0.5

	var positions := PackedVector3Array()
	var textures0 := PackedVector2Array()
	var faces: Array[PBFace] = []

	var vert_offset: int = 0

	for gz in range(d_seg):
		for gx in range(w_seg):
			var u0: float = float(gx) / float(w_seg)
			var u1: float = float(gx + 1) / float(w_seg)
			var v0: float = float(gz) / float(d_seg)
			var v1: float = float(gz + 1) / float(d_seg)

			var x0: float = lerp(-hw, hw, u0)
			var x1: float = lerp(-hw, hw, u1)
			var z0: float = lerp(-hd, hd, v0)
			var z1: float = lerp(-hd, hd, v1)

			positions.append(Vector3(x0, 0.0, z0))
			positions.append(Vector3(x0, 0.0, z1))
			positions.append(Vector3(x1, 0.0, z1))
			positions.append(Vector3(x1, 0.0, z0))

			textures0.append(Vector2(u0, v0))
			textures0.append(Vector2(u0, v1))
			textures0.append(Vector2(u1, v1))
			textures0.append(Vector2(u1, v0))

			faces.append(PBFace.new(PackedInt32Array([
				vert_offset + 0, vert_offset + 1, vert_offset + 2,
				vert_offset + 2, vert_offset + 3, vert_offset + 0
			])))
			vert_offset += 4

	var mesh_data := PBMeshData.new()
	mesh_data.positions = positions
	mesh_data.textures0 = textures0
	mesh_data.faces = faces
	mesh_data.shared_vertices = _build_shared_vertices(positions)
	mesh_data.shared_textures = []
	mesh_data.invalidate_caches()
	return mesh_data


# ==============================================================================
# 3. Sprite Generator
# ==============================================================================

## Creates a single quad sprite on the XZ plane (Y=0) centered at the origin.
## Equivalent to create_plane(width, depth, 1, 1).
static func create_sprite(width: float = 1.0, depth: float = 1.0) -> PBMeshData:
	return create_plane(width, depth, 1, 1)


# ==============================================================================
# 4. Prism Generator
# ==============================================================================

## Creates a 3D triangular prism centered at the origin.
## Has 5 faces (2 triangular end caps + 3 rectangular quad sides), 18 vertices, 24 indices.
static func create_prism(size: Vector3 = Vector3.ONE) -> PBMeshData:
	var hx: float = size.x * 0.5
	var hy: float = size.y * 0.5
	var hz: float = size.z * 0.5

	var positions := PackedVector3Array([
		# Face 0: Front Triangle (Z = -hz) - Outward normal: (0, 0, -1)
		Vector3(hx, -hy, -hz), Vector3(-hx, -hy, -hz), Vector3(0.0, hy, -hz),

		# Face 1: Right Slope - Outward normal: (+X, +Y)
		Vector3(0.0, hy, -hz), Vector3(0.0, hy, hz), Vector3(hx, -hy, hz), Vector3(hx, -hy, -hz),

		# Face 2: Back Triangle (Z = +hz) - Outward normal: (0, 0, +1)
		Vector3(-hx, -hy, hz), Vector3(hx, -hy, hz), Vector3(0.0, hy, hz),

		# Face 3: Left Slope - Outward normal: (-X, +Y)
		Vector3(0.0, hy, hz), Vector3(0.0, hy, -hz), Vector3(-hx, -hy, -hz), Vector3(-hx, -hy, hz),

		# Face 4: Bottom (Y = -hy) - Outward normal: (0, -1, 0)
		Vector3(-hx, -hy, hz), Vector3(-hx, -hy, -hz), Vector3(hx, -hy, -hz), Vector3(hx, -hy, hz),
	])

	var textures0 := PackedVector2Array([
		# Face 0: Front Triangle
		Vector2(1.0, 0.0), Vector2(0.0, 0.0), Vector2(0.5, 1.0),

		# Face 1: Right Slope
		Vector2(0.0, 1.0), Vector2(1.0, 1.0), Vector2(1.0, 0.0), Vector2(0.0, 0.0),

		# Face 2: Back Triangle
		Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(0.5, 1.0),

		# Face 3: Left Slope
		Vector2(1.0, 1.0), Vector2(0.0, 1.0), Vector2(0.0, 0.0), Vector2(1.0, 0.0),

		# Face 4: Bottom
		Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0),
	])

	var faces: Array[PBFace] = [
		# Face 0: Front Triangle (3 indices)
		PBFace.new(PackedInt32Array([0, 1, 2])),

		# Face 1: Right Slope (6 indices)
		PBFace.new(PackedInt32Array([3, 4, 5, 5, 6, 3])),

		# Face 2: Back Triangle (3 indices)
		PBFace.new(PackedInt32Array([7, 8, 9])),

		# Face 3: Left Slope (6 indices)
		PBFace.new(PackedInt32Array([10, 11, 12, 12, 13, 10])),

		# Face 4: Bottom (6 indices)
		PBFace.new(PackedInt32Array([14, 15, 16, 16, 17, 14])),
	]

	var mesh_data := PBMeshData.new()
	mesh_data.positions = positions
	mesh_data.textures0 = textures0
	mesh_data.faces = faces
	mesh_data.shared_vertices = _build_shared_vertices(positions)
	mesh_data.shared_textures = []
	mesh_data.invalidate_caches()
	return mesh_data
