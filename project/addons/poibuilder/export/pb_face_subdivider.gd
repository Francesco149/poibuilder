## PBFaceSubdivider — Subdivides mesh faces into grid-aligned triangulated quads.
##
## Used by the retro export pipeline to chop large faces into uniform tiles matching
## the texture tiling grid (or configured grid size). This produces dense vertex grids
## for high-fidelity vertex lighting (direct + shadows + AO) and enables per-tile
## texture baking where only painted tiles generate new textures while unpainted
## tiles reuse the shared base texture.
@tool
class_name PBFaceSubdivider
extends RefCounted

## Holds geometry and metadata for one subdivided tile fragment of a face.
class TileFragment:
	## Grid cell coordinate (k, m).
	var cell_coord: Vector2i = Vector2i.ZERO
	## Planar bounds of this grid cell in (u, v) space.
	var cell_bounds: Rect2 = Rect2()
	## Triangulated 3D vertex positions (length is multiple of 3).
	var positions: PackedVector3Array = PackedVector3Array()
	## Vertex normals (outward).
	var normals: PackedVector3Array = PackedVector3Array()
	## Global/tiled UV coordinates (matching face auto-UV projection).
	var uvs: PackedVector2Array = PackedVector2Array()
	## Normalized local UV coordinates within this cell [0.0, 1.0].
	var tile_uvs: PackedVector2Array = PackedVector2Array()
	## Triangle indices pointing into positions/normals/uvs.
	var indices: PackedInt32Array = PackedInt32Array()
	## Reference to source face.
	var source_face: PBFace = null
	## Face index in mesh data.
	var face_index: int = -1

# ==============================================================================
# Public API
# ==============================================================================

## Subdivides a face into an array of TileFragments aligned to the texture grid.
## If `subdivide` is false, returns a single TileFragment representing the entire face.
static func subdivide_face(mesh_data: PBMeshData, face: PBFace, face_idx: int,
		subdivide: bool = true, grid_size: float = 1.0) -> Array[TileFragment]:
	var result: Array[TileFragment] = []
	if mesh_data == null or face == null:
		return result

	var face_indices: PackedInt32Array = face.get_indexes()
	if face_indices.is_empty() or face_indices.size() % 3 != 0:
		return result

	var normal: Vector3 = PBMath.normal_from_positions(mesh_data.positions, face_indices)
	if normal.length_squared() < 0.0001:
		normal = Vector3.UP
	else:
		normal = normal.normalized()

	var basis := PBUv.get_planar_basis(normal)
	var u_axis: Vector3 = basis["u"]
	var v_axis: Vector3 = basis["v"]
	var anchor: Vector3 = mesh_data.get_texture_anchor() if not face.uv_use_world_space else Vector3.ZERO
	var p0_face: Vector3 = mesh_data.positions[face_indices[0]]
	var plane_dist: float = normal.dot(p0_face - anchor)
	# Compute planar (u, v) coordinates for all face vertices
	var planar_points: Array[Vector2] = []
	var min_u := INF
	var max_u := -INF
	var min_v := INF
	var max_v := -INF

	var face_uvs := PBUv.calculate_face_uvs(mesh_data, face)

	for idx in face_indices:
		var p: Vector3 = mesh_data.positions[idx]
		var rel := p - anchor
		var uv_planar := Vector2(u_axis.dot(rel), v_axis.dot(rel))
		planar_points.append(uv_planar)
		min_u = minf(min_u, uv_planar.x)
		max_u = maxf(max_u, uv_planar.x)
		min_v = minf(min_v, uv_planar.y)
		max_v = maxf(max_v, uv_planar.y)

	var face_bounds := Rect2(min_u, min_v, maxf(max_u - min_u, 0.001), maxf(max_v - min_v, 0.001))

	# If subdivision is disabled, return the full face as a single fragment
	if not subdivide:
		var frag := TileFragment.new()
		frag.cell_coord = Vector2i.ZERO
		frag.cell_bounds = face_bounds
		frag.source_face = face
		frag.face_index = face_idx

		for i in range(face_indices.size()):
			var vi: int = face_indices[i]
			frag.positions.append(mesh_data.positions[vi])
			frag.normals.append(normal)
			frag.uvs.append(face_uvs.get(vi, Vector2.ZERO))
			# Local tile UV mapped to face bounds
			var pu: float = planar_points[i].x
			var pv: float = planar_points[i].y
			var local_u := (pu - min_u) / maxf(max_u - min_u, 0.0001)
			var local_v := (pv - min_v) / maxf(max_v - min_v, 0.0001)
			frag.tile_uvs.append(Vector2(local_u, local_v))
		# Reverse triangle index order from CCW (internal PBMeshData) to CW (Godot ArrayMesh)
		for tri_i in range(0, face_indices.size() - 2, 3):
			frag.indices.append(tri_i + 2)
			frag.indices.append(tri_i + 1)
			frag.indices.append(tri_i)
		result.append(frag)
		return result

	# Grid-aligned subdivision
	var step_u := grid_size
	var step_v := grid_size
	if face.uv_scale.x != 0.0:
		step_u = grid_size / absf(face.uv_scale.x)
	if face.uv_scale.y != 0.0:
		step_v = grid_size / absf(face.uv_scale.y)

	var off_u: float = face.uv_offset.x * step_u
	var off_v: float = face.uv_offset.y * step_v

	var k_min := int(floor((min_u - off_u) / step_u))
	var k_max := int(ceil((max_u - off_u) / step_u))
	var m_min := int(floor((min_v - off_v) / step_v))
	var m_max := int(ceil((max_v - off_v) / step_v))

	# Bound reasonable subdivision count to prevent catastrophic runaway on giant values
	k_max = mini(k_max, k_min + 256)
	m_max = mini(m_max, m_min + 256)
	# Extract 2D boundary polygon for clean grid slicing (quads, stair side walls, pillar caps).
	# Clipping the boundary directly eliminates interior diagonals and avoids chaotic sliver fans.
	var has_polygon := false
	var face_poly_2d: Array[Vector2] = []
	if face.is_quad():
		var q_indices: PackedInt32Array = face.to_quad()
		if q_indices.size() == 4:
			for q_idx in q_indices:
				var p: Vector3 = mesh_data.positions[q_idx]
				var rel := p - anchor
				face_poly_2d.append(Vector2(u_axis.dot(rel), v_axis.dot(rel)))
			has_polygon = true
	else:
		face_poly_2d = _extract_perimeter_polygon_2d(mesh_data, face, u_axis, v_axis, anchor)
		has_polygon = not face_poly_2d.is_empty()

	# Enforce CCW winding in 2D planar space so Sutherland-Hodgman keeps the interior
	if has_polygon and not face_poly_2d.is_empty():
		var area := 0.0
		for i in range(face_poly_2d.size()):
			var p1: Vector2 = face_poly_2d[i]
			var p2: Vector2 = face_poly_2d[(i + 1) % face_poly_2d.size()]
			area += (p1.x * p2.y - p2.x * p1.y)
		if area < 0.0:
			face_poly_2d.reverse()

	var tri_count := face_indices.size() / 3
	for m in range(m_min, m_max):
		for k in range(k_min, k_max):
			var u0 := k * step_u + off_u
			var u1 := (k + 1) * step_u + off_u
			var v0 := m * step_v + off_v
			var v1 := (m + 1) * step_v + off_v
			var cell_rect := Rect2(u0, v0, u1 - u0, v1 - v0)

			# Collect all polygon fragments inside this cell
			var cell_positions := PackedVector3Array()
			var cell_normals := PackedVector3Array()
			var cell_uvs := PackedVector2Array()
			var cell_tile_uvs := PackedVector2Array()
			var cell_indices := PackedInt32Array()

			if has_polygon:
				if max_u < u0 or min_u > u1 or max_v < v0 or min_v > v1:
					continue
				var poly: Array = face_poly_2d.duplicate()
				poly = _clip_polygon_axis(poly, true, u0, true)
				if not poly.is_empty(): poly = _clip_polygon_axis(poly, true, u1, false)
				if not poly.is_empty(): poly = _clip_polygon_axis(poly, false, v0, true)
				if not poly.is_empty(): poly = _clip_polygon_axis(poly, false, v1, false)
				if poly.size() >= 3:
					_triangulate_cell_polygon(poly, u0, u1, v0, v1, anchor, u_axis, v_axis, plane_dist, normal, face, cell_positions, cell_normals, cell_uvs, cell_tile_uvs, cell_indices)
			else:
				for t in range(tri_count):
					var i0 := t * 3
					var i1 := t * 3 + 1
					var i2 := t * 3 + 2
					var p0_2d: Vector2 = planar_points[i0]
					var p1_2d: Vector2 = planar_points[i1]
					var p2_2d: Vector2 = planar_points[i2]
					var tri_min_u := minf(p0_2d.x, minf(p1_2d.x, p2_2d.x))
					var tri_max_u := maxf(p0_2d.x, maxf(p1_2d.x, p2_2d.x))
					var tri_min_v := minf(p0_2d.y, minf(p1_2d.y, p2_2d.y))
					var tri_max_v := maxf(p0_2d.y, maxf(p1_2d.y, p2_2d.y))
					if tri_max_u < u0 or tri_min_u > u1 or tri_max_v < v0 or tri_min_v > v1:
						continue
					var poly := [p0_2d, p1_2d, p2_2d]
					poly = _clip_polygon_axis(poly, true, u0, true)
					if not poly.is_empty(): poly = _clip_polygon_axis(poly, true, u1, false)
					if not poly.is_empty(): poly = _clip_polygon_axis(poly, false, v0, true)
					if not poly.is_empty(): poly = _clip_polygon_axis(poly, false, v1, false)
					if poly.size() >= 3:
						_append_polygon_triangles(poly, u0, u1, v0, v1, anchor, u_axis, v_axis, plane_dist, normal, face, cell_positions, cell_normals, cell_uvs, cell_tile_uvs, cell_indices)
			if not cell_indices.is_empty():
				var frag := TileFragment.new()
				frag.cell_coord = Vector2i(k, m)
				frag.cell_bounds = cell_rect
				frag.positions = cell_positions
				frag.normals = cell_normals
				frag.uvs = cell_uvs
				frag.tile_uvs = cell_tile_uvs
				frag.indices = cell_indices
				frag.source_face = face
				frag.face_index = face_idx
				result.append(frag)
	return result
static func _triangulate_cell_polygon(poly: Array, u0: float, u1: float, v0: float, v1: float,
		anchor: Vector3, u_axis: Vector3, v_axis: Vector3, plane_dist: float, normal: Vector3,
		face: PBFace, cell_positions: PackedVector3Array, cell_normals: PackedVector3Array,
		cell_uvs: PackedVector2Array, cell_tile_uvs: PackedVector2Array, cell_indices: PackedInt32Array) -> void:
	if poly.size() < 3:
		return

	# If the polygon has intermediate step or notch vertices (size > 4),
	# slice it along intermediate U and V coordinates into clean rectangular/trapezoidal sub-boxes.
	# This guarantees clean grid topology with single diagonals and zero fans or slivers.
	if poly.size() > 4:
		var u_set := {}
		for p: Vector2 in poly:
			u_set[snappedf(p.x, 0.0001)] = true
		var u_vals: Array = u_set.keys()
		u_vals.sort()

		if u_vals.size() > 2:
			for i in range(u_vals.size() - 1):
				var ua: float = u_vals[i]
				var ub: float = u_vals[i + 1]
				if ub - ua < 0.0001:
					continue
				var strip: Array = _clip_polygon_axis(poly, true, ua, true)
				strip = _clip_polygon_axis(strip, true, ub, false)
				if strip.size() < 3:
					continue

				var v_set := {}
				for p: Vector2 in strip:
					v_set[snappedf(p.y, 0.0001)] = true
				var v_vals: Array = v_set.keys()
				v_vals.sort()

				if v_vals.size() > 2:
					for j in range(v_vals.size() - 1):
						var va: float = v_vals[j]
						var vb: float = v_vals[j + 1]
						if vb - va < 0.0001:
							continue
						var box: Array = _clip_polygon_axis(strip, false, va, true)
						box = _clip_polygon_axis(box, false, vb, false)
						if box.size() >= 3:
							_append_polygon_triangles(box, u0, u1, v0, v1, anchor, u_axis, v_axis, plane_dist, normal, face, cell_positions, cell_normals, cell_uvs, cell_tile_uvs, cell_indices)
				else:
					_append_polygon_triangles(strip, u0, u1, v0, v1, anchor, u_axis, v_axis, plane_dist, normal, face, cell_positions, cell_normals, cell_uvs, cell_tile_uvs, cell_indices)
			return

	_append_polygon_triangles(poly, u0, u1, v0, v1, anchor, u_axis, v_axis, plane_dist, normal, face, cell_positions, cell_normals, cell_uvs, cell_tile_uvs, cell_indices)

static func _append_polygon_triangles(poly: Array, u0: float, u1: float, v0: float, v1: float,
		anchor: Vector3, u_axis: Vector3, v_axis: Vector3, plane_dist: float, normal: Vector3,
		face: PBFace, cell_positions: PackedVector3Array, cell_normals: PackedVector3Array,
		cell_uvs: PackedVector2Array, cell_tile_uvs: PackedVector2Array, cell_indices: PackedInt32Array) -> void:
	var area := 0.0
	for vi in range(poly.size()):
		var p1: Vector2 = poly[vi]
		var p2: Vector2 = poly[(vi + 1) % poly.size()]
		area += (p1.x * p2.y - p2.x * p1.y)
	if absf(area) < 0.00001:
		return

	var base_idx := cell_positions.size()
	for vi in range(poly.size()):
		var pt2d: Vector2 = poly[vi]
		var pos3d := anchor + pt2d.x * u_axis + pt2d.y * v_axis + plane_dist * normal
		cell_positions.append(pos3d)
		cell_normals.append(normal)
		cell_uvs.append(_compute_planar_uv(pt2d, face))

		var tu := (pt2d.x - u0) / maxf(u1 - u0, 0.0001)
		var tv := (pt2d.y - v0) / maxf(v1 - v0, 0.0001)
		if face.uv_flip_u: tu = 1.0 - tu
		if face.uv_flip_v: tv = 1.0 - tv
		if face.uv_swap_uv:
			var tmp := tu
			tu = tv
			tv = tmp
		cell_tile_uvs.append(Vector2(tu, tv))

	var tris := _ear_clip_2d(poly)
	for t in tris:
		var idx0: int = base_idx + int(t[0])
		var idx1: int = base_idx + int(t[1])
		var idx2: int = base_idx + int(t[2])
		var p0: Vector3 = cell_positions[idx0]
		var p1: Vector3 = cell_positions[idx1]
		var p2: Vector3 = cell_positions[idx2]
		var cross: Vector3 = (p1 - p0).cross(p2 - p0)
		if cross.length_squared() < 0.000001:
			continue # Skip degenerate zero-area triangles
		if normal.dot(cross) > 0.0:
			cell_indices.append(idx0)
			cell_indices.append(idx2)
			cell_indices.append(idx1)
		else:
			cell_indices.append(idx0)
			cell_indices.append(idx1)
			cell_indices.append(idx2)
# ==============================================================================
# Helper Methods
# ==============================================================================

## Extracts an ordered 2D perimeter loop for any simple face polygon from its boundary edges.
## Returns an empty array if the edges do not form a single simple closed loop.
static func _extract_perimeter_polygon_2d(mesh_data: PBMeshData, face: PBFace,
		u_axis: Vector3, v_axis: Vector3, anchor: Vector3) -> Array[Vector2]:
	var edges: Array[PBEdge] = face.get_edges()
	if edges.is_empty() or edges.size() < 3:
		return []

	var adj: Dictionary = {}
	for e in edges:
		if not adj.has(e.a): adj[e.a] = [] as Array[int]
		if not adj.has(e.b): adj[e.b] = [] as Array[int]
		adj[e.a].append(e.b)
		adj[e.b].append(e.a)

	var start_idx: int = edges[0].a
	var cur_idx: int = start_idx
	var prev_idx: int = -1
	var ordered_indices: Array[int] = [start_idx]
	var visited := {start_idx: true}

	var max_steps := edges.size() + 2
	while max_steps > 0:
		max_steps -= 1
		var neighbors: Array = adj.get(cur_idx, [])
		var next_idx := -1
		for n_idx in neighbors:
			if n_idx != prev_idx:
				if n_idx == start_idx and ordered_indices.size() >= 3:
					next_idx = -2
					break
				elif not visited.has(n_idx):
					next_idx = n_idx
					break
		if next_idx == -2:
			break
		elif next_idx >= 0:
			ordered_indices.append(next_idx)
			visited[next_idx] = true
			prev_idx = cur_idx
			cur_idx = next_idx
		else:
			break

	# A simple closed polygon must have every vertex with degree exactly 2,
	# and the loop size must equal the total number of unique edges.
	# Non-simple faces (faces with holes, bridge slits, or junctions) cannot be cleanly clipped
	# as a single boundary and must fall back to their native triangle subdivision.
	if ordered_indices.size() < 3 or ordered_indices.size() != edges.size():
		return []
	for v in adj:
		if adj[v].size() != 2:
			return []

	var poly_2d: Array[Vector2] = []
	for vi in ordered_indices:
		var p: Vector3 = mesh_data.positions[vi]
		var rel := p - anchor
		poly_2d.append(Vector2(u_axis.dot(rel), v_axis.dot(rel)))
	for i in range(poly_2d.size()):
		for j in range(i + 1, poly_2d.size()):
			if poly_2d[i].distance_squared_to(poly_2d[j]) < 0.00001:
				return []

	# Slicing along U and V axes produces clean rectangular grids only for orthogonal stepped polygons (like stairs).
	# Polygons with diagonal edges or slanted cuts must fall back to triangle subdivision to prevent stepped slivers and cavities.
	for i in range(poly_2d.size()):
		var p1: Vector2 = poly_2d[i]
		var p2: Vector2 = poly_2d[(i + 1) % poly_2d.size()]
		var du := absf(p2.x - p1.x)
		var dv := absf(p2.y - p1.y)
		if du > 0.001 and dv > 0.001:
			return []

	return poly_2d

## Sutherland-Hodgman 1D half-plane clip against an axis-aligned line.
## is_u: true for U axis, false for V axis.
## greater_than: true for coord >= threshold, false for coord <= threshold.
static func _clip_polygon_axis(poly: Array, is_u: bool, threshold: float, greater_than: bool) -> Array:
	var out: Array = []
	var n: int = poly.size()
	if n < 3:
		return out

	for i in range(n):
		var p1: Vector2 = poly[i]
		var p2: Vector2 = poly[(i + 1) % n]
		var val1: float = p1.x if is_u else p1.y
		var val2: float = p2.x if is_u else p2.y

		var in1 := val1 >= threshold if greater_than else val1 <= threshold
		var in2 := val2 >= threshold if greater_than else val2 <= threshold

		if in1:
			if in2:
				_append_distinct_pt(out, p2)
			else:
				var t := (threshold - val1) / (val2 - val1) if absf(val2 - val1) > 0.000001 else 0.0
				_append_distinct_pt(out, p1.lerp(p2, clampf(t, 0.0, 1.0)))
		else:
			if in2:
				var t := (threshold - val1) / (val2 - val1) if absf(val2 - val1) > 0.000001 else 0.0
				_append_distinct_pt(out, p1.lerp(p2, clampf(t, 0.0, 1.0)))
				_append_distinct_pt(out, p2)

	if out.size() > 2 and out[0].distance_squared_to(out[out.size() - 1]) < 0.000001:
		out.pop_back()
	return out

static func _append_distinct_pt(arr: Array, pt: Vector2) -> void:
	if arr.is_empty() or arr[arr.size() - 1].distance_squared_to(pt) > 0.000001:
		arr.append(pt)

## Computes face UV coordinate from a 2D planar position (u, v).
static func _compute_planar_uv(pt: Vector2, face: PBFace) -> Vector2:
	var uv := pt
	if face.uv_flip_u:
		uv.x = -uv.x
	if face.uv_flip_v:
		uv.y = -uv.y
	if face.uv_swap_uv:
		var tmp := uv.x
		uv.x = uv.y
		uv.y = tmp

	var scale: Vector2 = face.uv_scale
	var rotation: float = face.uv_rotation
	var offset: Vector2 = face.uv_offset

	if rotation != 0.0:
		var rot_rad: float = deg_to_rad(rotation)
		var cos_r: float = cos(rot_rad)
		var sin_r: float = sin(rot_rad)
		var sx: float = uv.x * scale.x
		var sy: float = uv.y * scale.y
		var rx: float = sx * cos_r - sy * sin_r
		var ry: float = sx * sin_r + sy * cos_r
		return Vector2(rx, ry) + offset
	else:
		return Vector2(uv.x * scale.x, uv.y * scale.y) + offset

## 2D ear-clipping triangulation for arbitrary convex or concave cell polygons.
## Preserves reflex corners (steps, L-shapes) without inverting triangles into empty space.
static func _ear_clip_2d(points: Array) -> Array:
	var n := points.size()
	if n < 3:
		return []
	if n == 3:
		return [[0, 1, 2]]
	if n == 4:
		var a: Vector2 = points[0]
		var b: Vector2 = points[1]
		var c: Vector2 = points[2]
		var d: Vector2 = points[3]
		var c1 := (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
		var c2 := (c.x - a.x) * (d.y - a.y) - (c.y - a.y) * (d.x - a.x)
		if (c1 > 0.00001 and c2 > 0.00001) or (c1 < -0.00001 and c2 < -0.00001):
			return [[0, 1, 2], [0, 2, 3]]
		else:
			return [[1, 2, 3], [1, 3, 0]]

	var idxs: Array[int] = []
	for i in range(n):
		idxs.append(i)

	var area := 0.0
	for i in range(n):
		var p1: Vector2 = points[i]
		var p2: Vector2 = points[(i + 1) % n]
		area += (p2.x - p1.x) * (p2.y + p1.y)

	if area > 0.0:
		idxs.reverse()

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
			var a: Vector2 = points[i0]
			var b: Vector2 = points[i1]
			var c: Vector2 = points[i2]

			var cross := (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
			if cross <= 0.000001:
				continue

			var ear := true
			for j in idxs:
				if j == i0 or j == i1 or j == i2:
					continue
				var pj: Vector2 = points[j]
				if _point_in_tri_2d(pj, a, b, c):
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

	return tris

static func _point_in_tri_2d(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var d1 := (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
	var d2 := (c.x - b.x) * (p.y - b.y) - (c.y - b.y) * (p.x - b.x)
	var d3 := (a.x - c.x) * (p.y - c.y) - (a.y - c.y) * (p.x - c.x)
	var has_neg := (d1 < -0.000001) or (d2 < -0.000001) or (d3 < -0.000001)
	var has_pos := (d1 > 0.000001) or (d2 > 0.000001) or (d3 > 0.000001)
	return not (has_neg and has_pos)
