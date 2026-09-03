## PBPicking — Raycast-based element picking for PBMesh nodes.
##
## Provides CPU-based picking for vertices, edges, and faces from a camera ray.
## For click picking, uses ray-triangle intersection (faces), screen-space distance
## (edges/vertices). For rect selection, projects elements to screen space and tests
## containment.
##
## This is a pure-logic class with no scene tree dependencies, making it testable
## in headless mode with synthetic camera transforms.
@tool
class_name PBPicking
extends RefCounted

# ==============================================================================
# Constants
# ==============================================================================

## Maximum screen-space distance (pixels) to pick a vertex.
const MAX_VERTEX_PICK_DISTANCE: float = 20.0

## Maximum screen-space distance (pixels) to pick an edge.
## ProBuilder gives edges a generous hitbox so you can grab them without
## pixel-perfect aim; 20px matches that feel.
const MAX_EDGE_PICK_DISTANCE: float = 20.0

## Screen-distance window (pixels) inside which two candidates are considered
## tied and the one CLOSER TO THE CAMERA wins. Without this, a hidden far-side
## edge/vertex projecting near the cursor can steal the pick from the visible
## one (its highlight then shows through the mesh — the "diagonal of the top
## face" report).
const PICK_DEPTH_TIE_BREAK_PIXELS: float = 6.0

## Slack (world units along the ray) for the occlusion test. Smaller than any
## realistic face spacing, large enough to absorb float noise on grazing rays.
const OCCLUSION_EPSILON: float = 0.05

## Minimum epsilon for ray distance comparisons.
const PICK_EPSILON: float = 0.0001

# ==============================================================================
# Pick Results
# ==============================================================================

## Result of a face pick operation.
class FacePickResult extends RefCounted:
	var face_index: int = -1
	var distance: float = INF
	var hit_point: Vector3 = Vector3.ZERO

	func _init(p_face_index: int = -1, p_distance: float = INF, p_hit_point: Vector3 = Vector3.ZERO) -> void:
		face_index = p_face_index
		distance = p_distance
		hit_point = p_hit_point

## Result of an edge pick operation.
class EdgePickResult extends RefCounted:
	var edge: PBEdge = null
	var face_index: int = -1
	var screen_distance: float = INF

	func _init(p_edge: PBEdge = null, p_face_index: int = -1, p_screen_distance: float = INF) -> void:
		edge = p_edge
		face_index = p_face_index
		screen_distance = p_screen_distance

## Result of a vertex pick operation.
class VertexPickResult extends RefCounted:
	var common_index: int = -1  ## Shared vertex group index
	var vertex_index: int = -1  ## Local vertex index
	var screen_distance: float = INF
	var face_index: int = -1    ## Face under the cursor at pick time (side)

	func _init(p_common: int = -1, p_vertex: int = -1, p_screen_dist: float = INF) -> void:
		common_index = p_common
		vertex_index = p_vertex
		screen_distance = p_screen_dist

# ==============================================================================
# Face Picking (Ray-Triangle Intersection)
# ==============================================================================

## Picks the nearest face intersected by a ray from the camera through screen_pos.
## Returns FacePickResult with face_index >= 0 on hit, or face_index == -1 on miss.
static func pick_face(mesh_data: PBMeshData, mesh_transform: Transform3D,
		ray_origin: Vector3, ray_dir: Vector3) -> FacePickResult:
	if mesh_data == null:
		return FacePickResult.new()

	var positions := mesh_data.positions
	var best := FacePickResult.new()

	for fi in range(mesh_data.faces.size()):
		var face: PBFace = mesh_data.faces[fi]
		if face == null:
			continue
		var indexes := face.get_indexes()
		for tri_i in range(0, indexes.size() - 2, 3):
			var i0: int = indexes[tri_i]
			var i1: int = indexes[tri_i + 1]
			var i2: int = indexes[tri_i + 2]
			if i0 < 0 or i0 >= positions.size() or i1 < 0 or i1 >= positions.size() or i2 < 0 or i2 >= positions.size():
				continue
			var v0: Vector3 = mesh_transform * positions[i0]
			var v1: Vector3 = mesh_transform * positions[i1]
			var v2: Vector3 = mesh_transform * positions[i2]
			var result: Dictionary = PBMath.ray_intersects_triangle(ray_origin, ray_dir, v0, v1, v2)
			if result.get("hit", false):
				var dist: float = result["distance"]
				if dist < best.distance:
					best = FacePickResult.new(fi, dist, result["point"])

	return best

## Picks ALL faces intersected by a ray, sorted by distance (nearest first).
static func pick_faces_all(mesh_data: PBMeshData, mesh_transform: Transform3D,
		ray_origin: Vector3, ray_dir: Vector3) -> Array[FacePickResult]:
	if mesh_data == null:
		return []

	var positions := mesh_data.positions
	var results: Array[FacePickResult] = []
	# Track best distance per face (a face may have multiple triangles)
	var face_best: Dictionary = {} # int -> FacePickResult

	for fi in range(mesh_data.faces.size()):
		var face: PBFace = mesh_data.faces[fi]
		if face == null:
			continue
		var indexes := face.get_indexes()
		for tri_i in range(0, indexes.size() - 2, 3):
			var i0: int = indexes[tri_i]
			var i1: int = indexes[tri_i + 1]
			var i2: int = indexes[tri_i + 2]
			if i0 < 0 or i0 >= positions.size() or i1 < 0 or i1 >= positions.size() or i2 < 0 or i2 >= positions.size():
				continue
			var v0: Vector3 = mesh_transform * positions[i0]
			var v1: Vector3 = mesh_transform * positions[i1]
			var v2: Vector3 = mesh_transform * positions[i2]
			var result: Dictionary = PBMath.ray_intersects_triangle(ray_origin, ray_dir, v0, v1, v2)
			if result.get("hit", false):
				var dist: float = result["distance"]
				if not face_best.has(fi) or dist < face_best[fi].distance:
					face_best[fi] = FacePickResult.new(fi, dist, result["point"])

	for fpr in face_best.values():
		results.append(fpr)

	results.sort_custom(func(a: FacePickResult, b: FacePickResult) -> bool:
		return a.distance < b.distance
	)
	return results

# ==============================================================================
# Edge Picking (Screen-Space Distance)
# ==============================================================================

## Picks the nearest edge to a screen position with ProBuilder-style UX:
## - BIG hitbox (MAX_EDGE_PICK_DISTANCE).
## - VISIBLE edges always win over hidden ones at comparable screen distance.
## - If no visible edge is under the cursor, a hidden edge within the hitbox
##   IS selectable — selecting far edges through the mesh is a first-class
##   workflow (grab the edge where it appears behind the face).
## - The face under the cursor is returned in `face_index` so the element
##   gizmo can orient to the side you picked from.
## Returns EdgePickResult with edge != null on hit, or null edge on miss.
static func pick_edge(mesh_data: PBMeshData, mesh_transform: Transform3D,
		screen_pos: Vector2, camera: Camera3D) -> EdgePickResult:
	if mesh_data == null or camera == null:
		return EdgePickResult.new()

	var positions := mesh_data.positions
	var lookup: Dictionary = mesh_data.get_shared_vertex_lookup()
	var cam_pos: Vector3 = camera.global_position
	var cam_fwd: Vector3 = -camera.global_basis.z

	var ray_origin: Vector3 = camera.project_ray_origin(screen_pos)
	var ray_dir: Vector3 = camera.project_ray_normal(screen_pos)
	var ray_hit := _first_ray_hit(mesh_data, mesh_transform, ray_origin, ray_dir)

	# Collect all candidates within the pixel radius: [dist, depth, edge, face]
	var candidates: Array = []
	var seen: Dictionary = {} # Vector2i -> bool (by common edge)

	for fi in range(mesh_data.faces.size()):
		var face: PBFace = mesh_data.faces[fi]
		if face == null:
			continue
		for edge in face.get_edges():
			# Deduplicate by common edge
			var ca: int = lookup.get(edge.a, -1)
			var cb: int = lookup.get(edge.b, -1)
			var key := Vector2i(mini(ca, cb), maxi(ca, cb))
			if seen.has(key):
				continue
			seen[key] = true

			if edge.a < 0 or edge.a >= positions.size() or edge.b < 0 or edge.b >= positions.size():
				continue
			var world_a: Vector3 = mesh_transform * positions[edge.a]
			var world_b: Vector3 = mesh_transform * positions[edge.b]

			# Check if both points are behind the camera
			if (world_a - cam_pos).dot(cam_fwd) < 0 and (world_b - cam_pos).dot(cam_fwd) < 0:
				continue

			# Occlusion flag: hidden behind the first surface the ray hits
			# (own-face elements are never hidden). Hidden edges stay
			# selectable as fallback — see the two-tier selection below.
			var edge_t: float = _ray_closest_approach_t(ray_origin, ray_dir, world_a, world_b)
			var hit_face: int = ray_hit["face"]
			var own := hit_face != -1 and _face_contains_common_edge(
				mesh_data, mesh_data.faces[hit_face], edge)
			var occluded: bool = _is_occluded(ray_hit, edge_t, own)

			var screen_a: Vector2 = camera.unproject_position(world_a)
			var screen_b: Vector2 = camera.unproject_position(world_b)

			var dist: float = PBMath.distance_point_line_segment_2d(screen_pos, screen_a, screen_b)
			if dist > MAX_EDGE_PICK_DISTANCE:
				continue

			var midpoint: Vector3 = (world_a + world_b) * 0.5
			var side_face: int = hit_face if (hit_face != -1 and own) else fi
			candidates.append([dist, (midpoint - cam_pos).length(), edge, occluded, side_face])

	if candidates.is_empty():
		return EdgePickResult.new()

	# Tier 1: visible candidates. Tier 2 (only if no visible candidate):
	# hidden ones — selecting far edges through the mesh is intentional UX.
	for occluded_flag in [false, true]:
		var best_dist: float = INF
		var nearest_depth: float = INF
		var best: EdgePickResult = null
		for c in candidates:
			if c[3] != occluded_flag:
				continue
			if c[0] < best_dist:
				best_dist = c[0]
		if is_inf(best_dist):
			continue
		for c in candidates:
			if c[3] != occluded_flag or c[0] > best_dist + PICK_DEPTH_TIE_BREAK_PIXELS:
				continue
			if c[1] < nearest_depth:
				nearest_depth = c[1]
				best = EdgePickResult.new(c[2], c[4], c[0])
		if best != null:
			return best

	return EdgePickResult.new()

# ==============================================================================
# Vertex Picking (Screen-Space Distance)
# ==============================================================================

## Picks the nearest vertex to a screen position with the same two-tier
## policy as edges: visible vertices win; hidden vertices remain selectable
## as fallback (ProBuilder's grab-through-the-mesh workflow). The face under
## the cursor is returned in face_index for side-aware gizmo orientation.
## Returns VertexPickResult with common_index >= 0 on hit, or -1 on miss.
static func pick_vertex(mesh_data: PBMeshData, mesh_transform: Transform3D,
		screen_pos: Vector2, camera: Camera3D) -> VertexPickResult:
	if mesh_data == null or camera == null:
		return VertexPickResult.new()

	var positions := mesh_data.positions
	var cam_pos: Vector3 = camera.global_position
	var cam_fwd: Vector3 = -camera.global_basis.z

	var ray_origin: Vector3 = camera.project_ray_origin(screen_pos)
	var ray_dir: Vector3 = camera.project_ray_normal(screen_pos)
	var ray_hit := _first_ray_hit(mesh_data, mesh_transform, ray_origin, ray_dir)

	var candidates: Array = [] # [dist, depth, common_index, local_idx]

	for sv_idx in range(mesh_data.shared_vertices.size()):
		var sv: PBSharedVertex = mesh_data.shared_vertices[sv_idx]
		if sv == null or sv.indices.is_empty():
			continue
		var local_idx: int = sv.indices[0]
		if local_idx < 0 or local_idx >= positions.size():
			continue

		var world_pos: Vector3 = mesh_transform * positions[local_idx]

		# Check if behind camera
		if (world_pos - cam_pos).dot(cam_fwd) < 0:
			continue

		# Occlusion flag (hidden vertices remain selectable as fallback).
		var vertex_t: float = _ray_closest_approach_t(ray_origin, ray_dir, world_pos, world_pos)
		var hit_face: int = ray_hit["face"]
		var own := hit_face != -1 and _face_contains_common_vertex(
			mesh_data, mesh_data.faces[hit_face], sv)
		var occluded: bool = _is_occluded(ray_hit, vertex_t, own)

		var screen_pt: Vector2 = camera.unproject_position(world_pos)
		var dist: float = screen_pos.distance_to(screen_pt)

		if dist <= MAX_VERTEX_PICK_DISTANCE:
			var side_face: int = hit_face if (hit_face != -1 and own) else -1
			candidates.append([dist, (world_pos - cam_pos).length(), sv_idx, local_idx, occluded, side_face])

	if candidates.is_empty():
		return VertexPickResult.new()

	for occluded_flag in [false, true]:
		var best_dist: float = INF
		for c in candidates:
			if c[4] == occluded_flag:
				best_dist = minf(best_dist, c[0])
		if is_inf(best_dist):
			continue
		var best := VertexPickResult.new()
		var nearest_depth: float = INF
		for c in candidates:
			if c[4] != occluded_flag or c[0] > best_dist + PICK_DEPTH_TIE_BREAK_PIXELS:
				continue
			if c[1] < nearest_depth:
				nearest_depth = c[1]
				best = VertexPickResult.new(c[2], c[3], c[0])
				best.face_index = c[5]
		if best.common_index != -1:
			return best
	return VertexPickResult.new()

# ==============================================================================
# Occlusion Helpers
# ==============================================================================

## Nearest ray/mesh intersection: returns { "face": int (index, -1 on miss),
## "t": float (distance along the ray) }.
static func _first_ray_hit(mesh_data: PBMeshData, mesh_transform: Transform3D,
		ray_origin: Vector3, ray_dir: Vector3) -> Dictionary:
	var positions := mesh_data.positions
	var nearest_face: int = -1
	var nearest_t: float = INF
	for fi in range(mesh_data.faces.size()):
		var face: PBFace = mesh_data.faces[fi]
		if face == null:
			continue
		var indexes := face.get_indexes()
		for tri_i in range(0, indexes.size() - 2, 3):
			var i0: int = indexes[tri_i]
			var i1: int = indexes[tri_i + 1]
			var i2: int = indexes[tri_i + 2]
			if i0 < 0 or i0 >= positions.size() or i1 < 0 or i1 >= positions.size() or i2 < 0 or i2 >= positions.size():
				continue
			var result: Dictionary = PBMath.ray_intersects_triangle(
				ray_origin, ray_dir,
				mesh_transform * positions[i0],
				mesh_transform * positions[i1],
				mesh_transform * positions[i2])
			if result.get("hit", false) and result["distance"] < nearest_t:
				nearest_t = result["distance"]
				nearest_face = fi
	return { "face": nearest_face, "t": nearest_t }

## True when the face's perimeter contains an edge equivalent (by shared
## vertex group pair) to the given edge.
static func _face_contains_common_edge(mesh_data: PBMeshData, face: PBFace, edge: PBEdge) -> bool:
	if face == null or edge == null:
		return false
	var lookup: Dictionary = mesh_data.get_shared_vertex_lookup()
	var target := Vector2i(
		mini(lookup.get(edge.a, -1), lookup.get(edge.b, -1)),
		maxi(lookup.get(edge.a, -1), lookup.get(edge.b, -1)))
	for fe in face.get_edges():
		var ca: int = lookup.get(fe.a, -1)
		var cb: int = lookup.get(fe.b, -1)
		if Vector2i(mini(ca, cb), maxi(ca, cb)) == target:
			return true
	return false

## True when the face contains any position of the shared vertex group.
static func _face_contains_common_vertex(mesh_data: PBMeshData, face: PBFace, sv: PBSharedVertex) -> bool:
	if face == null or sv == null:
		return false
	var lookup: Dictionary = mesh_data.get_shared_vertex_lookup()
	for idx in face.get_distinct_indexes():
		if lookup.get(idx, -1) in sv.indices:
			return true
	return false

## Ray parameter t at the closest approach of the ray to segment (a, b).
static func _ray_closest_approach_t(ray_origin: Vector3, ray_dir: Vector3,
		a: Vector3, b: Vector3) -> float:
	var dir_sq: float = ray_dir.length_squared()
	if dir_sq < PICK_EPSILON:
		return INF
	var seg: Vector3 = b - a
	var seg_len_sq: float = seg.length_squared()
	var r: Vector3 = ray_origin - a
	if seg_len_sq < PICK_EPSILON:
		# Degenerate segment (a point)
		return -r.dot(ray_dir) / dir_sq
	var dd: float = ray_dir.dot(seg)
	var cc: float = ray_dir.dot(r)
	var ff: float = seg.dot(r)
	var denom: float = dir_sq * seg_len_sq - dd * dd
	var s: float = 0.0
	if absf(denom) > PICK_EPSILON * dir_sq * seg_len_sq:
		s = clampf((dir_sq * ff - dd * cc) / denom, 0.0, 1.0)
	# Recompute t from the clamped s (correct near segment endpoints and for
	# near-parallel ray/segment cases).
	var closest_on_seg: Vector3 = a + seg * s
	return (closest_on_seg - ray_origin).dot(ray_dir) / dir_sq

## An element is occluded only when the FIRST surface along the cursor ray
## belongs to a face the element is NOT part of, and that surface is in front
## of the element. Elements lying on the hit surface (the clicked face's own
## border edges and corner vertices) stay pickable; hidden elements behind the
## clicked face (bottom/far edges whose on-top highlight draws across the face
## like a diagonal) become unpickable.
static func _is_occluded(hit: Dictionary, element_t: float, hit_face_is_own: bool) -> bool:
	var hit_face: int = hit["face"]
	if hit_face == -1:
		return false
	if hit_face_is_own:
		return false
	if is_inf(element_t):
		return true
	return hit["t"] + OCCLUSION_EPSILON < element_t

# ==============================================================================
# Rectangle Selection (Screen-Space Containment)
# ==============================================================================

## Returns all face indices whose centroid falls within screen_rect.
static func pick_faces_in_rect(mesh_data: PBMeshData, mesh_transform: Transform3D,
		screen_rect: Rect2, camera: Camera3D) -> PackedInt32Array:
	if mesh_data == null or camera == null:
		return PackedInt32Array()

	var result := PackedInt32Array()
	var positions := mesh_data.positions
	var cam_pos: Vector3 = camera.global_position
	var cam_fwd: Vector3 = -camera.global_basis.z

	for fi in range(mesh_data.faces.size()):
		var face: PBFace = mesh_data.faces[fi]
		if face == null:
			continue
		# Compute face centroid
		var distinct := face.get_distinct_indexes()
		if distinct.is_empty():
			continue
		var centroid := Vector3.ZERO
		var valid_count: int = 0
		for idx in distinct:
			if idx >= 0 and idx < positions.size():
				centroid += mesh_transform * positions[idx]
				valid_count += 1
		if valid_count == 0:
			continue
		centroid /= float(valid_count)

		if (centroid - cam_pos).dot(cam_fwd) < 0:
			continue

		var screen_pt: Vector2 = camera.unproject_position(centroid)
		if screen_rect.has_point(screen_pt):
			result.append(fi)

	return result

## Returns all edges whose midpoint falls within screen_rect.
## Returned edges are deduplicated by common edge.
static func pick_edges_in_rect(mesh_data: PBMeshData, mesh_transform: Transform3D,
		screen_rect: Rect2, camera: Camera3D) -> Array[PBEdge]:
	if mesh_data == null or camera == null:
		return []

	var result: Array[PBEdge] = []
	var positions := mesh_data.positions
	var lookup: Dictionary = mesh_data.get_shared_vertex_lookup()
	var seen: Dictionary = {}
	var cam_pos: Vector3 = camera.global_position
	var cam_fwd: Vector3 = -camera.global_basis.z

	for face in mesh_data.faces:
		if face == null:
			continue
		for edge in face.get_edges():
			var ca: int = lookup.get(edge.a, -1)
			var cb: int = lookup.get(edge.b, -1)
			var key := Vector2i(mini(ca, cb), maxi(ca, cb))
			if seen.has(key):
				continue
			seen[key] = true

			if edge.a < 0 or edge.a >= positions.size() or edge.b < 0 or edge.b >= positions.size():
				continue

			var world_a: Vector3 = mesh_transform * positions[edge.a]
			var world_b: Vector3 = mesh_transform * positions[edge.b]
			var midpoint: Vector3 = (world_a + world_b) * 0.5

			if (midpoint - cam_pos).dot(cam_fwd) < 0:
				continue

			var screen_pt: Vector2 = camera.unproject_position(midpoint)
			if screen_rect.has_point(screen_pt):
				result.append(edge)

	return result

## Returns common vertex indices whose position falls within screen_rect.
static func pick_vertices_in_rect(mesh_data: PBMeshData, mesh_transform: Transform3D,
		screen_rect: Rect2, camera: Camera3D) -> PackedInt32Array:
	if mesh_data == null or camera == null:
		return PackedInt32Array()

	var result := PackedInt32Array()
	var positions := mesh_data.positions
	var cam_pos: Vector3 = camera.global_position
	var cam_fwd: Vector3 = -camera.global_basis.z

	for sv_idx in range(mesh_data.shared_vertices.size()):
		var sv: PBSharedVertex = mesh_data.shared_vertices[sv_idx]
		if sv == null or sv.indices.is_empty():
			continue
		var local_idx: int = sv.indices[0]
		if local_idx < 0 or local_idx >= positions.size():
			continue

		var world_pos: Vector3 = mesh_transform * positions[local_idx]

		if (world_pos - cam_pos).dot(cam_fwd) < 0:
			continue

		var screen_pt: Vector2 = camera.unproject_position(world_pos)
		if screen_rect.has_point(screen_pt):
			result.append(sv_idx)

	return result
