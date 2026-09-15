## PBSelectionOps — Static selection expansion, traversal, and query algorithms.
##
## Implements:
## - Grow/shrink selection with normal angle threshold (preventing growth over sharp creases).
## - Select coplanar faces (flood-fill adjacent faces on the same plane within angle tolerance).
## - Select similar faces (by Material, Smoothing Group, Element Color, or Surface Area).
## - Select boundary edges and hole loops (edges used by exactly 1 face).
## - Face loop and face ring traversal (quad strip traversal via winged edges).
## - Select all & invert selection query helpers.
@tool
class_name PBSelectionOps
extends RefCounted

# ==============================================================================
# Grow / Shrink with Normal Angle Threshold
# ==============================================================================

## Grows face selection across adjacent faces sharing an edge, optionally bounded
## by `max_angle_deg`. If `max_angle_deg >= 0.0`, will not cross crease edges where
## dihedral angle between face normals exceeds the threshold.
static func grow_faces_with_angle(mesh_data: PBMeshData, current_faces: PackedInt32Array,
		max_angle_deg: float = -1.0) -> PackedInt32Array:
	if mesh_data == null or current_faces.is_empty():
		return current_faces

	var lookup: Dictionary = mesh_data.get_shared_vertex_lookup()
	var selected_set: Dictionary = {}
	for fi in current_faces:
		selected_set[fi] = true

	# Collect all common edges of selected faces mapped to the faces using them
	var edge_to_selected_face: Dictionary = {} # Vector2i -> int
	for fi in current_faces:
		if fi < 0 or fi >= mesh_data.faces.size():
			continue
		var face: PBFace = mesh_data.faces[fi]
		if face == null:
			continue
		for edge in face.get_edges():
			var ca: int = lookup.get(edge.a, -1)
			var cb: int = lookup.get(edge.b, -1)
			var key := Vector2i(mini(ca, cb), maxi(ca, cb))
			edge_to_selected_face[key] = fi

	var result := current_faces.duplicate()
	for fi in range(mesh_data.faces.size()):
		if selected_set.has(fi):
			continue
		var candidate_face: PBFace = mesh_data.faces[fi]
		if candidate_face == null:
			continue

		var can_add := false
		for edge in candidate_face.get_edges():
			var ca: int = lookup.get(edge.a, -1)
			var cb: int = lookup.get(edge.b, -1)
			var key := Vector2i(mini(ca, cb), maxi(ca, cb))
			if edge_to_selected_face.has(key):
				if max_angle_deg >= 0.0:
					var neighbor_fi: int = edge_to_selected_face[key]
					var neighbor_face: PBFace = mesh_data.faces[neighbor_fi]
					var n1: Vector3 = PBMath.normal_from_positions(mesh_data.positions, candidate_face.get_indexes())
					var n2: Vector3 = PBMath.normal_from_positions(mesh_data.positions, neighbor_face.get_indexes())
					var angle_deg: float = rad_to_deg(n1.angle_to(n2))
					if angle_deg <= max_angle_deg:
						can_add = true
						break
				else:
					can_add = true
					break

		if can_add:
			result.append(fi)
			selected_set[fi] = true

	return result

# ==============================================================================
# Select Coplanar Faces
# ==============================================================================

## Selects all faces connected to `start_faces` that are coplanar within `normal_threshold_deg`
## and distance tolerance from the face planes.
## If `start_faces` is empty, returns empty.
static func select_coplanar_faces(mesh_data: PBMeshData, start_faces: PackedInt32Array,
		normal_threshold_deg: float = 1.0, distance_threshold: float = 0.01) -> PackedInt32Array:
	if mesh_data == null or start_faces.is_empty():
		return PackedInt32Array()

	var lookup: Dictionary = mesh_data.get_shared_vertex_lookup()

	# Build edge-to-face adjacency map
	var edge_to_faces: Dictionary = {} # Vector2i -> Array[int]
	var face_normals: Array[Vector3] = []
	face_normals.resize(mesh_data.faces.size())

	for fi in range(mesh_data.faces.size()):
		var f: PBFace = mesh_data.faces[fi]
		if f == null:
			face_normals[fi] = Vector3.UP
			continue
		face_normals[fi] = PBMath.normal_from_positions(mesh_data.positions, f.get_indexes())
		for edge in f.get_edges():
			var ca: int = lookup.get(edge.a, -1)
			var cb: int = lookup.get(edge.b, -1)
			var key := Vector2i(mini(ca, cb), maxi(ca, cb))
			if not edge_to_faces.has(key):
				edge_to_faces[key] = []
			edge_to_faces[key].append(fi)

	var selected_set: Dictionary = {}
	var queue: Array[int] = []

	# Calculate reference plane for each starting face
	for fi in start_faces:
		if fi >= 0 and fi < mesh_data.faces.size() and mesh_data.faces[fi] != null:
			selected_set[fi] = true
			queue.append(fi)

	while not queue.is_empty():
		var curr_fi: int = queue.pop_front()
		var curr_face: PBFace = mesh_data.faces[curr_fi]
		var curr_normal: Vector3 = face_normals[curr_fi]
		var curr_center: Vector3 = PBMath.average(mesh_data.positions, curr_face.get_distinct_indexes())

		for edge in curr_face.get_edges():
			var ca: int = lookup.get(edge.a, -1)
			var cb: int = lookup.get(edge.b, -1)
			var key := Vector2i(mini(ca, cb), maxi(ca, cb))
			if not edge_to_faces.has(key):
				continue
			for neighbor_fi in edge_to_faces[key]:
				if selected_set.has(neighbor_fi):
					continue
				var neighbor_face: PBFace = mesh_data.faces[neighbor_fi]
				var neighbor_normal: Vector3 = face_normals[neighbor_fi]
				var angle: float = rad_to_deg(curr_normal.angle_to(neighbor_normal))
				if angle <= normal_threshold_deg:
					# Check plane distance
					var neighbor_center: Vector3 = PBMath.average(mesh_data.positions, neighbor_face.get_distinct_indexes())
					var dist: float = absf((neighbor_center - curr_center).dot(curr_normal))
					if dist <= distance_threshold:
						selected_set[neighbor_fi] = true
						queue.append(neighbor_fi)

	var result := PackedInt32Array()
	for fi in selected_set:
		result.append(fi)
	return result

# ==============================================================================
# Select Similar Faces
# ==============================================================================

## Selects all faces matching the criteria of any face in `start_faces`.
## Criteria:
## - "material": match material_id
## - "smoothing_group": match smoothing_group (ignores smoothing_group == 0 unless only 0 is selected)
## - "color": match element_color within RGB tolerance (0.02)
## - "area": match face surface area within 10% relative tolerance
static func select_similar_faces(mesh_data: PBMeshData, start_faces: PackedInt32Array,
		criteria: String = "material") -> PackedInt32Array:
	if mesh_data == null or start_faces.is_empty():
		return PackedInt32Array()

	var crit := criteria.to_lower().strip_edges()
	var result_set: Dictionary = {}

	match crit:
		"material":
			var target_materials: Dictionary = {}
			for fi in start_faces:
				if fi >= 0 and fi < mesh_data.faces.size() and mesh_data.faces[fi] != null:
					target_materials[mesh_data.faces[fi].submesh_index] = true
			for fi in range(mesh_data.faces.size()):
				var f: PBFace = mesh_data.faces[fi]
				if f != null and target_materials.has(f.submesh_index):
					result_set[fi] = true

		"smoothing_group":
			var target_groups: Dictionary = {}
			for fi in start_faces:
				if fi >= 0 and fi < mesh_data.faces.size() and mesh_data.faces[fi] != null:
					target_groups[mesh_data.faces[fi].smoothing_group] = true
			for fi in range(mesh_data.faces.size()):
				var f: PBFace = mesh_data.faces[fi]
				if f != null and target_groups.has(f.smoothing_group):
					result_set[fi] = true

		"color":
			var target_colors: Array[Color] = []
			for fi in start_faces:
				if fi >= 0 and fi < mesh_data.faces.size() and mesh_data.faces[fi] != null:
					target_colors.append(_get_face_color(mesh_data, mesh_data.faces[fi]))
			for fi in range(mesh_data.faces.size()):
				var f: PBFace = mesh_data.faces[fi]
				if f == null:
					continue
				for tc in target_colors:
					var c := _get_face_color(mesh_data, f)
					if absf(c.r - tc.r) < 0.02 and \
							absf(c.g - tc.g) < 0.02 and \
							absf(c.b - tc.b) < 0.02 and \
							absf(c.a - tc.a) < 0.02:
						result_set[fi] = true
						break

		"area":
			var target_areas: Array[float] = []
			for fi in start_faces:
				if fi >= 0 and fi < mesh_data.faces.size() and mesh_data.faces[fi] != null:
					target_areas.append(_calculate_face_area(mesh_data, mesh_data.faces[fi]))
			for fi in range(mesh_data.faces.size()):
				var f: PBFace = mesh_data.faces[fi]
				if f == null:
					continue
				var area: float = _calculate_face_area(mesh_data, f)
				for ta in target_areas:
					var tol: float = maxf(0.001, ta * 0.1)
					if absf(area - ta) <= tol:
						result_set[fi] = true
						break

	var result := PackedInt32Array()
	for fi in result_set:
		result.append(fi)
	return result

static func _calculate_face_area(mesh_data: PBMeshData, face: PBFace) -> float:
	var total_area := 0.0
	var tris: PackedInt32Array = face.get_indexes()
	for i in range(0, tris.size(), 3):
		var p0: Vector3 = mesh_data.positions[tris[i]]
		var p1: Vector3 = mesh_data.positions[tris[i + 1]]
		var p2: Vector3 = mesh_data.positions[tris[i + 2]]
		total_area += (p1 - p0).cross(p2 - p0).length() * 0.5
	return total_area

static func _get_face_color(mesh_data: PBMeshData, face: PBFace) -> Color:
	if mesh_data == null or face == null:
		return Color.WHITE
	var distinct := face.get_distinct_indexes()
	if not mesh_data.colors.is_empty() and not distinct.is_empty():
		var idx: int = distinct[0]
		if idx >= 0 and idx < mesh_data.colors.size():
			return mesh_data.colors[idx]
	return Color.WHITE

# ==============================================================================
# Select Boundary Edges & Holes
# ==============================================================================

## Returns all boundary edges (edges belonging to exactly 1 face).
static func select_boundary_edges(mesh_data: PBMeshData) -> Array[PBEdge]:
	if mesh_data == null or mesh_data.faces.is_empty():
		return []

	var lookup: Dictionary = mesh_data.get_shared_vertex_lookup()
	var usage: Dictionary = {} # Vector2i -> int
	var edge_map: Dictionary = {} # Vector2i -> PBEdge

	for face in mesh_data.faces:
		if face == null:
			continue
		for edge in face.get_edges():
			var ca: int = lookup.get(edge.a, edge.a)
			var cb: int = lookup.get(edge.b, edge.b)
			var key := Vector2i(mini(ca, cb), maxi(ca, cb))
			usage[key] = usage.get(key, 0) + 1
			if not edge_map.has(key):
				edge_map[key] = edge

	var boundary_edges: Array[PBEdge] = []
	for key in usage:
		if usage[key] == 1:
			boundary_edges.append(edge_map[key])
	return boundary_edges

## Returns common-edge indices for all boundary edges on the mesh.
static func select_boundary_edge_ids(mesh_data: PBMeshData) -> PackedInt32Array:
	if mesh_data == null or mesh_data.faces.is_empty():
		return PackedInt32Array()

	var lookup: Dictionary = mesh_data.get_shared_vertex_lookup()
	var common: Array[PBEdge] = mesh_data.get_common_edges()
	var usage: Dictionary = {} # Vector2i -> int

	for face in mesh_data.faces:
		if face == null:
			continue
		for edge in face.get_edges():
			var ca: int = lookup.get(edge.a, edge.a)
			var cb: int = lookup.get(edge.b, edge.b)
			var key := Vector2i(mini(ca, cb), maxi(ca, cb))
			usage[key] = usage.get(key, 0) + 1

	var ids := PackedInt32Array()
	for i in range(common.size()):
		var ce: PBEdge = common[i]
		var ca: int = lookup.get(ce.a, ce.a)
		var cb: int = lookup.get(ce.b, ce.b)
		var key := Vector2i(mini(ca, cb), maxi(ca, cb))
		if usage.get(key, 0) == 1:
			ids.append(i)
	return ids

## Returns boundary loops touching `seed_edges`. If `seed_edges` is empty,
## returns all boundary edges grouped.
static func select_holes(mesh_data: PBMeshData, seed_edges: Array[PBEdge] = []) -> Array[PBEdge]:
	if mesh_data == null or mesh_data.faces.is_empty():
		return []

	var boundary_edges: Array[PBEdge] = select_boundary_edges(mesh_data)
	if boundary_edges.is_empty():
		return []
	if seed_edges.is_empty():
		return boundary_edges

	var lookup: Dictionary = mesh_data.get_shared_vertex_lookup()
	var seed_commons: Dictionary = {}
	for se in seed_edges:
		seed_commons[lookup.get(se.a, se.a)] = true
		seed_commons[lookup.get(se.b, se.b)] = true

	# Build adjacency graph among boundary edges
	var vert_to_edges: Dictionary = {}
	for be in boundary_edges:
		var ca: int = lookup.get(be.a, be.a)
		var cb: int = lookup.get(be.b, be.b)
		if not vert_to_edges.has(ca):
			vert_to_edges[ca] = []
		if not vert_to_edges.has(cb):
			vert_to_edges[cb] = []
		vert_to_edges[ca].append(be)
		vert_to_edges[cb].append(be)

	var selected_edges: Array[PBEdge] = []
	var visited_edges: Dictionary = {}

	for start_v in seed_commons:
		if not vert_to_edges.has(start_v):
			continue
		var queue: Array[int] = [start_v]
		var visited_v: Dictionary = {start_v: true}
		while not queue.is_empty():
			var v: int = queue.pop_front()
			for be in vert_to_edges.get(v, []):
				var ca: int = lookup.get(be.a, be.a)
				var cb: int = lookup.get(be.b, be.b)
				var key := Vector2i(mini(ca, cb), maxi(ca, cb))
				if not visited_edges.has(key):
					visited_edges[key] = true
					selected_edges.append(be)
				var next_v: int = cb if ca == v else ca
				if not visited_v.has(next_v):
					visited_v[next_v] = true
					queue.append(next_v)

	return selected_edges

# ==============================================================================
# Face Loop and Face Ring Traversal
# ==============================================================================

## Traverses quad strip face loop(s) starting from `start_faces`.
## If `ring` is true, traverses perpendicular ring direction across quads.
static func get_face_loop(mesh_data: PBMeshData, start_faces: PackedInt32Array, ring: bool = false) -> PackedInt32Array:
	if mesh_data == null or start_faces.is_empty():
		return PackedInt32Array()

	var wings: Array[PBTopology.PBWingedEdge] = PBTopology.get_winged_edges(mesh_data)
	if wings.is_empty():
		return start_faces

	# Face index lookup
	var face_to_wing: Dictionary = {} # int -> PBWingedEdge
	for w in wings:
		if w != null and w.face != null:
			var fi: int = mesh_data.faces.find(w.face)
			if fi >= 0 and not face_to_wing.has(fi):
				face_to_wing[fi] = w

	var loop_faces_set: Dictionary = {}
	for sf in start_faces:
		if not face_to_wing.has(sf):
			continue

		var start_wing: PBTopology.PBWingedEdge = face_to_wing[sf]
		if ring:
			start_wing = start_wing.next if start_wing.next != null else start_wing.previous

		# Walk in both forward and backward directions
		for dir in range(2):
			var cur: PBTopology.PBWingedEdge = start_wing
			if dir == 1:
				if start_wing.opposite != null and start_wing.opposite.face != null:
					cur = start_wing.opposite
				else:
					break

			var steps: int = 0
			while cur != null and cur.face != null and steps < 1000:
				steps += 1
				var fi: int = mesh_data.faces.find(cur.face)
				if fi >= 0:
					if loop_faces_set.has(fi) and dir == 0 and steps > 1:
						break
					loop_faces_set[fi] = true

				if cur.count() != 4:
					break # Stop on non-quad faces

				if cur.next == null or cur.next.next == null:
					break
				cur = cur.next.next.opposite

	var result := PackedInt32Array()
	for fi in loop_faces_set:
		result.append(fi)
	return result

# ==============================================================================
# Select All & Invert Query Helpers
# ==============================================================================

## Returns all valid element IDs for the given mode.
static func get_all_ids(mesh_data: PBMeshData, mode: PBEditor.SelectMode) -> PackedInt32Array:
	if mesh_data == null:
		return PackedInt32Array()
	var ids := PackedInt32Array()
	match mode:
		PBEditor.SelectMode.VERTEX:
			for i in range(mesh_data.shared_vertices.size()):
				ids.append(i)
		PBEditor.SelectMode.EDGE:
			var common := mesh_data.get_common_edges()
			for i in range(common.size()):
				ids.append(i)
		PBEditor.SelectMode.FACE, PBEditor.SelectMode.TEXTURE:
			for i in range(mesh_data.faces.size()):
				if mesh_data.faces[i] != null:
					ids.append(i)
	return ids

## Returns inverted element IDs for the given mode.
static func get_inverted_ids(mesh_data: PBMeshData, current_ids: PackedInt32Array,
		mode: PBEditor.SelectMode) -> PackedInt32Array:
	if mesh_data == null:
		return PackedInt32Array()
	var cur_set: Dictionary = {}
	for id in current_ids:
		cur_set[id] = true

	var all_ids := get_all_ids(mesh_data, mode)
	var inverted := PackedInt32Array()
	for id in all_ids:
		if not cur_set.has(id):
			inverted.append(id)
	return inverted
