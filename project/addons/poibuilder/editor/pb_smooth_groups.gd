## PBSmoothGroups — Surface smoothing group management and auto-smoothing for PoiBuilder.
##
## Manages smoothing groups 1..30 per face (0 = hard/none) and provides dihedral angle
## auto-smoothing and normal line visualization.
@tool
class_name PBSmoothGroups
extends RefCounted

const MIN_GROUP := 0
const MAX_GROUP := 30

## Sets the smoothing group for the specified faces (0 = hard, 1..30 = smooth).
static func set_smoothing_group(mesh_data: PBMeshData, faces: PackedInt32Array, group: int) -> void:
	if mesh_data == null or faces.is_empty():
		return
	var grp := clampi(group, MIN_GROUP, MAX_GROUP)
	for fi in faces:
		if fi >= 0 and fi < mesh_data.faces.size() and mesh_data.faces[fi] != null:
			mesh_data.faces[fi].smoothing_group = grp
	mesh_data.calculate_normals()
	mesh_data.shape_edited = true

## Clears smoothing groups on specified faces (sets to 0 / hard).
static func clear_smoothing_groups(mesh_data: PBMeshData, faces: PackedInt32Array) -> void:
	set_smoothing_group(mesh_data, faces, 0)

## Automatically clusters faces into smooth groups based on dihedral angle threshold.
## Adjacent faces whose angle between normals <= threshold_deg receive the same smoothing group.
## Returns the number of smooth groups generated.
static func auto_smooth(mesh_data: PBMeshData, threshold_deg: float = 45.0) -> int:
	if mesh_data == null or mesh_data.faces.is_empty():
		return 0

	var lookup := mesh_data.get_shared_vertex_lookup()
	var face_count := mesh_data.faces.size()

	# Compute normals
	var face_normals: Array[Vector3] = []
	face_normals.resize(face_count)
	for fi in range(face_count):
		var f: PBFace = mesh_data.faces[fi]
		if f == null:
			face_normals[fi] = Vector3.UP
		else:
			face_normals[fi] = PBMath.normal_from_positions(mesh_data.positions, f.get_indexes()).normalized()

	# Edge to faces adjacency
	var edge_to_faces: Dictionary = {}
	for fi in range(face_count):
		var f: PBFace = mesh_data.faces[fi]
		if f == null:
			continue
		for e in f.get_edges():
			var ca: int = lookup.get(e.a, e.a)
			var cb: int = lookup.get(e.b, e.b)
			var key := Vector2i(mini(ca, cb), maxi(ca, cb))
			if not edge_to_faces.has(key):
				edge_to_faces[key] = []
			edge_to_faces[key].append(fi)

	var visited: Dictionary = {}
	var cluster_id := 1

	for fi in range(face_count):
		if visited.has(fi) or mesh_data.faces[fi] == null:
			continue

		var cluster: Array[int] = []
		var queue: Array[int] = [fi]
		visited[fi] = true

		while not queue.is_empty():
			var curr: int = queue.pop_front()
			cluster.append(curr)
			var curr_f: PBFace = mesh_data.faces[curr]
			var curr_n: Vector3 = face_normals[curr]

			for e in curr_f.get_edges():
				var ca: int = lookup.get(e.a, e.a)
				var cb: int = lookup.get(e.b, e.b)
				var key := Vector2i(mini(ca, cb), maxi(ca, cb))
				if not edge_to_faces.has(key):
					continue
				for neighbor in edge_to_faces[key]:
					if visited.has(neighbor) or mesh_data.faces[neighbor] == null:
						continue
					var neighbor_n: Vector3 = face_normals[neighbor]
					var angle: float = rad_to_deg(curr_n.angle_to(neighbor_n))
					if angle <= threshold_deg:
						visited[neighbor] = true
						queue.append(neighbor)

		# If cluster has >= 2 faces, assign smoothing group 1..30
		if cluster.size() >= 2:
			var assigned_group: int = ((cluster_id - 1) % MAX_GROUP) + 1
			for c_fi in cluster:
				mesh_data.faces[c_fi].smoothing_group = assigned_group
			cluster_id += 1
		else:
			mesh_data.faces[fi].smoothing_group = 0

	mesh_data.calculate_normals()
	mesh_data.shape_edited = true
	return cluster_id - 1

## Generates preview line segments for vertex/face normals [start, end, start, end, ...].
static func get_normal_preview_lines(mesh_data: PBMeshData, length: float = 0.2) -> PackedVector3Array:
	if mesh_data == null or mesh_data.positions.is_empty():
		return PackedVector3Array()

	var normals := mesh_data.get_normals()
	var lines := PackedVector3Array()
	lines.resize(mesh_data.positions.size() * 2)

	for i in range(mesh_data.positions.size()):
		var p: Vector3 = mesh_data.positions[i]
		var n: Vector3 = normals[i]
		lines[i * 2] = p
		lines[i * 2 + 1] = p + n * length

	return lines
