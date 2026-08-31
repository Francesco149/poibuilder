## PBSharedVertex — Groups disjoint vertex indices that share the same 3D spatial position.
##
## ProBuilder stores meshes with per-face vertex duplication (disjoint vertices).
## PBSharedVertex clusters these distinct local vertex indices into topological groups.
@tool
class_name PBSharedVertex
extends Resource

## The vertex indices belonging to this coincident group.
var indices: PackedInt32Array = PackedInt32Array()

func _init(p_indices: PackedInt32Array = PackedInt32Array()) -> void:
	indices = p_indices

## Creates a new PBSharedVertex from a PackedInt32Array.
static func make(p_indices: PackedInt32Array) -> PBSharedVertex:
	return PBSharedVertex.new(p_indices)

## Creates a new PBSharedVertex from an untyped or typed Array of integers.
static func from_array(p_array: Array) -> PBSharedVertex:
	var arr := PackedInt32Array()
	for val in p_array:
		arr.append(int(val))
	return PBSharedVertex.new(arr)

## Returns true if this shared vertex group contains the given local vertex index.
func contains(index: int) -> bool:
	return indices.has(index)

## Returns the number of vertex indices in this shared vertex group.
func size() -> int:
	return indices.size()

## Adds a vertex index to this group if not already present.
func add(index: int) -> void:
	if not indices.has(index):
		indices.append(index)

## Removes a vertex index from this group. Returns true if found and removed.
func remove(index: int) -> bool:
	var idx: int = indices.find(index)
	if idx != -1:
		indices.remove_at(idx)
		return true
	return false

## Clears all indices from this group.
func clear() -> void:
	indices.clear()

## Offsets all indices in this group by the specified amount.
func shift_indices(offset: int) -> void:
	for i in range(indices.size()):
		indices[i] += offset

## Returns a shallow copy of this PBSharedVertex with a duplicated indices array.
func duplicate_shared() -> PBSharedVertex:
	return PBSharedVertex.new(indices.duplicate())

## Returns a comma-delimited string representation of the indices.
func _to_string() -> String:
	var parts: PackedStringArray = []
	for idx in indices:
		parts.append(str(idx))
	return ",".join(parts)

## Builds a reverse lookup dictionary mapping local vertex index -> shared vertex group index.
## E.g., for each vertex index, lookup[vertex_index] = group_index in shared_vertices array.
static func build_lookup(shared_vertices: Array[PBSharedVertex]) -> Dictionary:
	var lookup: Dictionary = {}
	for group_idx in range(shared_vertices.size()):
		var sv: PBSharedVertex = shared_vertices[group_idx]
		if sv == null:
			continue
		for v_idx in sv.indices:
			if not lookup.has(v_idx):
				lookup[v_idx] = group_idx
	return lookup

## Reconstructs an Array[PBSharedVertex] from a lookup dictionary (vertex_index -> group_index).
static func to_shared_vertices(lookup: Dictionary) -> Array[PBSharedVertex]:
	var group_map: Dictionary = {} # group_index (int) -> Array[int]
	var unshared: Array[PBSharedVertex] = []

	for vertex_idx in lookup.keys():
		var group_idx: int = lookup[vertex_idx]
		if group_idx < 0:
			var packed_single := PackedInt32Array([int(vertex_idx)])
			unshared.append(PBSharedVertex.new(packed_single))
		else:
			if not group_map.has(group_idx):
				group_map[group_idx] = []
			group_map[group_idx].append(int(vertex_idx))

	var result: Array[PBSharedVertex] = []
	for g_idx in group_map.keys():
		var int_arr: Array = group_map[g_idx]
		var packed := PackedInt32Array()
		for val in int_arr:
			packed.append(val)
		result.append(PBSharedVertex.new(packed))

	for u in unshared:
		result.append(u)

	return result
