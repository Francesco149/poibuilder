## PBTopology — Mesh topology queries, WingedEdge graph construction, and edge loop/ring traversals.
##
## Provides WingedEdge representation for polygon mesh traversal and static topological
## operations including edge adjacency sorting, spoke querying, edge loops, and edge rings.
@tool
class_name PBTopology
extends RefCounted


# ==============================================================================
# PBWingedEdge Inner Class
# ==============================================================================

## PBWingedEdge — Represents a directed boundary edge in a polygon face linked into a topological graph.
class PBWingedEdge extends RefCounted:
	## The local and common edge pair associated with this winged edge.
	var edge: PBEdge.PBEdgeLookup

	## The face this winged edge belongs to.
	var face: PBFace

	## Next winged edge in the face perimeter cycle (originating from edge.local.b).
	var next: PBWingedEdge

	## Previous winged edge in the face perimeter cycle (terminating at edge.local.a).
	var previous: PBWingedEdge

	## The matching winged edge on the adjacent face sharing the same common edge.
	var opposite: PBWingedEdge

	func _init(p_edge: PBEdge.PBEdgeLookup = null, p_face: PBFace = null) -> void:
		edge = p_edge
		face = p_face
		next = null
		previous = null
		opposite = null

	## Returns the number of edges in this face boundary cycle.
	func count() -> int:
		var current: PBWingedEdge = self
		var c: int = 0
		while current != null:
			c += 1
			current = current.next
			if current == self:
				break
		return c

	## Returns next or previous winged edge if it contains the specified common vertex index.
	func get_adjacent_edge_with_common_index(common: int) -> PBWingedEdge:
		if next != null and next.edge != null and next.edge.common != null and next.edge.common.contains(common):
			return next
		elif previous != null and previous.edge != null and previous.edge.common != null and previous.edge.common.contains(common):
			return previous
		return null

	## Compares two PBWingedEdge instances based on their local edge equality.
	func equals(other: PBWingedEdge) -> bool:
		if other == null or edge == null or other.edge == null:
			return false
		if edge.local == null or other.edge.local == null:
			return false
		return edge.local.equals(other.edge.local)

	## Returns the hash code of the local edge.
	func get_hash() -> int:
		if edge != null and edge.local != null:
			return edge.local.get_hash()
		return 0

	## Formats string representation for debugging.
	func _to_string() -> String:
		var comm_str: String = str(edge.common) if edge != null and edge.common != null else "null"
		var loc_str: String = str(edge.local) if edge != null and edge.local != null else "null"
		var opp_str: String = str(opposite.edge) if opposite != null and opposite.edge != null else "null"
		var face_str: String = str(face) if face != null else "null"
		return "Common: %s\nLocal: %s\nOpposite: %s\nFace: %s" % [comm_str, loc_str, opp_str, face_str]


# ==============================================================================
# Edge Adjacency Sorting
# ==============================================================================

## Sorts face perimeter edges so each edge's b index matches the next edge's a index.
## Returns a new Array[PBEdge] with oriented, contiguous edges.
static func sort_edges_by_adjacency(edges: Array[PBEdge]) -> Array[PBEdge]:
	var result: Array[PBEdge] = []
	for e in edges:
		if e != null:
			result.append(PBEdge.new(e.a, e.b))

	if result.size() <= 1:
		return result

	for i in range(1, result.size()):
		var want: int = result[i - 1].b
		for n in range(i, result.size()):
			if result[n].a == want:
				if n != i:
					var temp: PBEdge = result[i]
					result[i] = result[n]
					result[n] = temp
				break
			elif result[n].b == want:
				result[n] = PBEdge.new(result[n].b, result[n].a)
				if n != i:
					var temp: PBEdge = result[i]
					result[i] = result[n]
					result[n] = temp
				break

	return result


# ==============================================================================
# WingedEdge Graph Construction
# ==============================================================================

## Builds a WingedEdge graph from PBMeshData.
## If faces_subset is empty, all faces in mesh_data are processed.
## If one_wing_per_face is true, only the first WingedEdge per face is returned in the result array.
static func get_winged_edges(mesh_data: PBMeshData, faces_subset: Array[PBFace] = [], one_wing_per_face: bool = false) -> Array[PBWingedEdge]:
	if mesh_data == null:
		return []

	var target_faces: Array[PBFace] = faces_subset if not faces_subset.is_empty() else mesh_data.faces
	var lookup: Dictionary = mesh_data.get_shared_vertex_lookup()

	var winged: Array[PBWingedEdge] = []
	var opposite_dict: Dictionary = {} # Vector2i -> PBWingedEdge

	for f in target_faces:
		if f == null:
			continue
		var edges: Array[PBEdge] = sort_edges_by_adjacency(f.get_edges())
		var edge_length: int = edges.size()
		if edge_length == 0:
			continue

		var first: PBWingedEdge = null
		var prev: PBWingedEdge = null

		for n in range(edge_length):
			var e: PBEdge = edges[n]
			var ca: int = lookup.get(e.a, -1)
			var cb: int = lookup.get(e.b, -1)
			var common_edge := PBEdge.new(ca, cb)
			var edge_lookup := PBEdge.PBEdgeLookup.new(common_edge, e)

			var w := PBWingedEdge.new(edge_lookup, f)

			if n == 0:
				first = w
			else:
				w.previous = prev
				prev.next = w

			if n == edge_length - 1:
				w.next = first
				first.previous = w

			prev = w

			var key := Vector2i(mini(ca, cb), maxi(ca, cb))
			if opposite_dict.has(key):
				var opp: PBWingedEdge = opposite_dict[key]
				opp.opposite = w
				w.opposite = opp
			else:
				w.opposite = null
				opposite_dict[key] = w

			if not one_wing_per_face or n == 0:
				winged.append(w)

	return winged


# ==============================================================================
# Spokes Queries
# ==============================================================================

## Returns a Dictionary mapping each common vertex index (int) to an Array[PBWingedEdge] referencing it.
static func get_all_spokes(wings: Array[PBWingedEdge]) -> Dictionary:
	var spokes: Dictionary = {} # int -> Array[PBWingedEdge]
	for w in wings:
		if w == null or w.edge == null or w.edge.common == null:
			continue
		var ca: int = w.edge.common.a
		var cb: int = w.edge.common.b

		if not spokes.has(ca):
			spokes[ca] = [] as Array[PBWingedEdge]
		spokes[ca].append(w)

		if not spokes.has(cb):
			spokes[cb] = [] as Array[PBWingedEdge]
		spokes[cb].append(w)

	return spokes

## Returns spokes dictionary for all common vertices, or for a specific common_vertex if >= 0.
static func get_spokes(wings: Array[PBWingedEdge], common_vertex: int = -1) -> Variant:
	var all_spokes: Dictionary = get_all_spokes(wings)
	if common_vertex >= 0:
		var list: Array[PBWingedEdge] = all_spokes.get(common_vertex, [] as Array[PBWingedEdge])
		return list
	return all_spokes

static func _next_spoke(wing: PBWingedEdge, pivot: int, opp: bool) -> PBWingedEdge:
	if wing == null:
		return null
	if opp:
		return wing.opposite
	if wing.next != null and wing.next.edge != null and wing.next.edge.common != null and wing.next.edge.common.contains(pivot):
		return wing.next
	if wing.previous != null and wing.previous.edge != null and wing.previous.edge.common != null and wing.previous.edge.common.contains(pivot):
		return wing.previous
	return null

## Return all winged edges connected to wing with common_index as the pivot point in face-adjacency order.
## The first entry in the list is always the queried wing.
static func get_spokes_around(wing: PBWingedEdge, common_index: int, allow_holes: bool = false) -> Array[PBWingedEdge]:
	if wing == null:
		return []

	var spokes: Array[PBWingedEdge] = []
	var cur: PBWingedEdge = wing
	var opp: bool = false

	while cur != null:
		if spokes.has(cur):
			return spokes

		spokes.append(cur)
		cur = _next_spoke(cur, common_index, opp)
		opp = not opp

		if cur != null and cur.edge != null and cur.edge.common != null and wing.edge != null and wing.edge.common != null:
			if cur.edge.common.equals(wing.edge.common):
				return spokes

	if not allow_holes:
		return []

	cur = wing.opposite
	opp = false
	var fragment: Array[PBWingedEdge] = []

	while cur != null:
		if cur.edge != null and cur.edge.common != null and wing.edge != null and wing.edge.common != null:
			if cur.edge.common.equals(wing.edge.common):
				break
		fragment.append(cur)
		cur = _next_spoke(cur, common_index, opp)
		opp = not opp

	fragment.reverse()
	spokes.append_array(fragment)

	return spokes

static func _distinct_wings_by_common(wings: Array[PBWingedEdge]) -> Array[PBWingedEdge]:
	var result: Array[PBWingedEdge] = []
	var seen: Dictionary = {}
	for w in wings:
		if w == null or w.edge == null or w.edge.common == null:
			continue
		var key := Vector2i(mini(w.edge.common.a, w.edge.common.b), maxi(w.edge.common.a, w.edge.common.b))
		if not seen.has(key):
			seen[key] = true
			result.append(w)
	return result


# ==============================================================================
# Edge Ring Traversal
# ==============================================================================

## Returns the opposite edge across an even-sided polygon face (e.g. quad), or null for odd-sided polygons.
static func edge_ring_next(edge: PBWingedEdge) -> PBWingedEdge:
	if edge == null:
		return null

	var next: PBWingedEdge = edge.next
	var prev: PBWingedEdge = edge.previous
	var i: int = 0

	while next != prev and next != edge:
		if next == null or prev == null:
			return null
		next = next.next
		if next == prev:
			return null
		prev = prev.previous
		i += 1

	if i % 2 == 0 or next == edge:
		return null

	return next

## Given seed edges, find all edges in the edge ring(s).
static func get_edge_ring(mesh_data: PBMeshData, edges: Array[PBEdge]) -> Array[PBEdge]:
	if mesh_data == null or edges.is_empty():
		return []

	var wings: Array[PBWingedEdge] = get_winged_edges(mesh_data)
	var lookup: Dictionary = mesh_data.get_shared_vertex_lookup()

	var wings_dict: Dictionary = {} # Vector2i -> PBWingedEdge
	for w in wings:
		if w == null or w.edge == null or w.edge.common == null:
			continue
		var key := Vector2i(mini(w.edge.common.a, w.edge.common.b), maxi(w.edge.common.a, w.edge.common.b))
		if not wings_dict.has(key):
			wings_dict[key] = w

	var used_common: Dictionary = {} # Vector2i -> bool
	var result_edges: Array[PBEdge] = []

	for e in edges:
		if e == null:
			continue
		var ca: int = lookup.get(e.a, -1)
		var cb: int = lookup.get(e.b, -1)
		var seed_key := Vector2i(mini(ca, cb), maxi(ca, cb))

		if not wings_dict.has(seed_key) or used_common.has(seed_key):
			continue

		var we: PBWingedEdge = wings_dict[seed_key]
		var cur: PBWingedEdge = we

		# Direction 1
		while cur != null:
			var cur_key := Vector2i(mini(cur.edge.common.a, cur.edge.common.b), maxi(cur.edge.common.a, cur.edge.common.b))
			if used_common.has(cur_key):
				break
			used_common[cur_key] = true
			result_edges.append(cur.edge.local)

			cur = edge_ring_next(cur)
			if cur != null and cur.opposite != null:
				cur = cur.opposite
			else:
				cur = null

		# Direction 2
		cur = edge_ring_next(we.opposite) if we.opposite != null else null
		if cur != null and cur.opposite != null:
			cur = cur.opposite
		else:
			cur = null

		while cur != null:
			var cur_key := Vector2i(mini(cur.edge.common.a, cur.edge.common.b), maxi(cur.edge.common.a, cur.edge.common.b))
			if used_common.has(cur_key):
				break
			used_common[cur_key] = true
			result_edges.append(cur.edge.local)

			cur = edge_ring_next(cur)
			if cur != null and cur.opposite != null:
				cur = cur.opposite
			else:
				cur = null

	return result_edges

## Iterative edge ring traversal: adds up to 2 adjacent ring edges (one in each direction).
static func get_edge_ring_iterative(mesh_data: PBMeshData, edges: Array[PBEdge]) -> Array[PBEdge]:
	if mesh_data == null or edges.is_empty():
		return []

	var wings: Array[PBWingedEdge] = get_winged_edges(mesh_data)
	var lookup: Dictionary = mesh_data.get_shared_vertex_lookup()

	var wings_dict: Dictionary = {}
	for w in wings:
		if w == null or w.edge == null or w.edge.common == null:
			continue
		var key := Vector2i(mini(w.edge.common.a, w.edge.common.b), maxi(w.edge.common.a, w.edge.common.b))
		if not wings_dict.has(key):
			wings_dict[key] = w

	var used_common: Dictionary = {}
	var result_edges: Array[PBEdge] = []

	for e in edges:
		if e == null:
			continue
		var ca: int = lookup.get(e.a, -1)
		var cb: int = lookup.get(e.b, -1)
		var seed_key := Vector2i(mini(ca, cb), maxi(ca, cb))

		if not wings_dict.has(seed_key):
			continue

		var we: PBWingedEdge = wings_dict[seed_key]
		if not used_common.has(seed_key):
			used_common[seed_key] = true
			result_edges.append(we.edge.local)

		var next_wing := edge_ring_next(we)
		if next_wing != null and next_wing.opposite != null:
			var n_key := Vector2i(mini(next_wing.opposite.edge.common.a, next_wing.opposite.edge.common.b), maxi(next_wing.opposite.edge.common.a, next_wing.opposite.edge.common.b))
			if not used_common.has(n_key):
				used_common[n_key] = true
				result_edges.append(next_wing.opposite.edge.local)

		if we.opposite != null:
			var prev_wing := edge_ring_next(we.opposite)
			if prev_wing != null and prev_wing.opposite != null:
				var p_key := Vector2i(mini(prev_wing.opposite.edge.common.a, prev_wing.opposite.edge.common.b), maxi(prev_wing.opposite.edge.common.a, prev_wing.opposite.edge.common.b))
				if not used_common.has(p_key):
					used_common[p_key] = true
					result_edges.append(prev_wing.opposite.edge.local)

	return result_edges


# ==============================================================================
# Edge Loop Traversal
# ==============================================================================

## Given seed edges, find all edges along edge loop(s) traversing through 4-valence vertices.
static func get_edge_loop(mesh_data: PBMeshData, edges: Array[PBEdge]) -> Array[PBEdge]:
	if mesh_data == null or edges.is_empty():
		return []

	var wings: Array[PBWingedEdge] = get_winged_edges(mesh_data)
	var lookup: Dictionary = mesh_data.get_shared_vertex_lookup()

	var sources: Dictionary = {}
	for e in edges:
		if e == null:
			continue
		var ca: int = lookup.get(e.a, -1)
		var cb: int = lookup.get(e.b, -1)
		var key := Vector2i(mini(ca, cb), maxi(ca, cb))
		sources[key] = true

	var used_common: Dictionary = {}
	var loop_edges: Array[PBEdge] = []

	for i in range(wings.size()):
		var w: PBWingedEdge = wings[i]
		if w == null or w.edge == null or w.edge.common == null:
			continue
		var key := Vector2i(mini(w.edge.common.a, w.edge.common.b), maxi(w.edge.common.a, w.edge.common.b))
		if used_common.has(key) or not sources.has(key):
			continue

		var complete_loop: bool = _get_edge_loop_internal(w, w.edge.common.b, used_common, loop_edges)
		if not complete_loop:
			_get_edge_loop_internal(w, w.edge.common.a, used_common, loop_edges)

	return loop_edges

static func _get_edge_loop_internal(start: PBWingedEdge, start_index: int, used_common: Dictionary, loop_edges: Array[PBEdge]) -> bool:
	var ind: int = start_index
	var cur: PBWingedEdge = start

	while cur != null:
		var key := Vector2i(mini(cur.edge.common.a, cur.edge.common.b), maxi(cur.edge.common.a, cur.edge.common.b))
		if not used_common.has(key):
			used_common[key] = true
			loop_edges.append(cur.edge.local)

		var raw_spokes: Array[PBWingedEdge] = get_spokes_around(cur, ind, true)
		var distinct_spokes: Array[PBWingedEdge] = _distinct_wings_by_common(raw_spokes)

		cur = null
		if distinct_spokes.size() == 4:
			cur = distinct_spokes[2]
			ind = cur.edge.common.b if cur.edge.common.a == ind else cur.edge.common.a

			var next_key := Vector2i(mini(cur.edge.common.a, cur.edge.common.b), maxi(cur.edge.common.a, cur.edge.common.b))
			if used_common.has(next_key):
				return true

	return false

## Iterative edge loop traversal: extends seed edges by up to one step at each extremity where 4 edges meet.
static func get_edge_loop_iterative(mesh_data: PBMeshData, edges: Array[PBEdge]) -> Array[PBEdge]:
	if mesh_data == null or edges.is_empty():
		return []

	var wings: Array[PBWingedEdge] = get_winged_edges(mesh_data)
	var lookup: Dictionary = mesh_data.get_shared_vertex_lookup()

	var sources: Dictionary = {}
	for e in edges:
		if e == null:
			continue
		var ca: int = lookup.get(e.a, -1)
		var cb: int = lookup.get(e.b, -1)
		var key := Vector2i(mini(ca, cb), maxi(ca, cb))
		sources[key] = true

	var used_common: Dictionary = {}
	var loop_edges: Array[PBEdge] = []

	for i in range(wings.size()):
		var w: PBWingedEdge = wings[i]
		if w == null or w.edge == null or w.edge.common == null:
			continue
		var key := Vector2i(mini(w.edge.common.a, w.edge.common.b), maxi(w.edge.common.a, w.edge.common.b))
		if not sources.has(key):
			continue

		if not used_common.has(key):
			used_common[key] = true
			loop_edges.append(w.edge.local)

		var ind_a: int = w.edge.common.a
		var ind_b: int = w.edge.common.b

		var spokes_a: Array[PBWingedEdge] = _distinct_wings_by_common(get_spokes_around(w, ind_a, true))
		var spokes_b: Array[PBWingedEdge] = _distinct_wings_by_common(get_spokes_around(w, ind_b, true))

		if spokes_a.size() == 4:
			var cur_a: PBWingedEdge = spokes_a[2]
			var key_a := Vector2i(mini(cur_a.edge.common.a, cur_a.edge.common.b), maxi(cur_a.edge.common.a, cur_a.edge.common.b))
			if not used_common.has(key_a):
				used_common[key_a] = true
				loop_edges.append(cur_a.edge.local)

		if spokes_b.size() == 4:
			var cur_b: PBWingedEdge = spokes_b[2]
			var key_b := Vector2i(mini(cur_b.edge.common.a, cur_b.edge.common.b), maxi(cur_b.edge.common.a, cur_b.edge.common.b))
			if not used_common.has(key_b):
				used_common[key_b] = true
				loop_edges.append(cur_b.edge.local)

	return loop_edges
