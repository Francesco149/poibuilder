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
const MAX_EDGE_PICK_DISTANCE: float = 15.0

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

## Picks the nearest edge to a screen position.
## camera_transform + projection_matrix are used to project edge endpoints to screen.
## Returns EdgePickResult with edge != null on hit, or null edge on miss.
static func pick_edge(mesh_data: PBMeshData, mesh_transform: Transform3D,
		screen_pos: Vector2, camera: Camera3D) -> EdgePickResult:
	if mesh_data == null or camera == null:
		return EdgePickResult.new()

	var positions := mesh_data.positions
	var lookup: Dictionary = mesh_data.get_shared_vertex_lookup()
	var best := EdgePickResult.new()
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
			var cam_pos: Vector3 = camera.global_position
			var cam_fwd: Vector3 = -camera.global_basis.z
			if (world_a - cam_pos).dot(cam_fwd) < 0 and (world_b - cam_pos).dot(cam_fwd) < 0:
				continue

			var screen_a: Vector2 = camera.unproject_position(world_a)
			var screen_b: Vector2 = camera.unproject_position(world_b)

			var dist: float = PBMath.distance_point_line_segment_2d(screen_pos, screen_a, screen_b)
			if dist < best.screen_distance and dist <= MAX_EDGE_PICK_DISTANCE:
				best = EdgePickResult.new(edge, fi, dist)

	return best

# ==============================================================================
# Vertex Picking (Screen-Space Distance)
# ==============================================================================

## Picks the nearest vertex to a screen position.
## Returns VertexPickResult with common_index >= 0 on hit, or -1 on miss.
static func pick_vertex(mesh_data: PBMeshData, mesh_transform: Transform3D,
		screen_pos: Vector2, camera: Camera3D) -> VertexPickResult:
	if mesh_data == null or camera == null:
		return VertexPickResult.new()

	var positions := mesh_data.positions
	var best := VertexPickResult.new()
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

		# Check if behind camera
		if (world_pos - cam_pos).dot(cam_fwd) < 0:
			continue

		var screen_pt: Vector2 = camera.unproject_position(world_pos)
		var dist: float = screen_pos.distance_to(screen_pt)

		if dist < best.screen_distance and dist <= MAX_VERTEX_PICK_DISTANCE:
			best = VertexPickResult.new(sv_idx, local_idx, dist)

	return best

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
