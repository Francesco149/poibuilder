## PBEdge — Value type representing an undirected edge between two vertex indices.
##
## Edges are defined by two vertex indices (a and b). Equality and hashing
## are order-independent, meaning Edge(1, 2) == Edge(2, 1).
@tool
class_name PBEdge
extends RefCounted

## Sentinel empty/invalid edge index.
const EMPTY_INDEX: int = -1

## Vertex index a.
var a: int = 0

## Vertex index b.
var b: int = 0

func _init(p_a: int = 0, p_b: int = 0) -> void:
	a = p_a
	b = p_b

## Creates a new PBEdge with endpoints (p_a, p_b).
static func make(p_a: int, p_b: int) -> PBEdge:
	return PBEdge.new(p_a, p_b)

## Tests whether this edge points to valid, non-degenerate vertex indices.
func is_valid() -> bool:
	return a > EMPTY_INDEX and b > EMPTY_INDEX and a != b

## Order-independent equality check.
func equals(other: PBEdge) -> bool:
	if other == null:
		return false
	return (a == other.a and b == other.b) or (a == other.b and b == other.a)

## Order-independent hash code for use in Dictionary keys or sets.
func get_hash() -> int:
	var min_val: int = mini(a, b)
	var max_val: int = maxi(a, b)
	var hash_val: int = 27
	hash_val = hash_val * 29 + min_val
	hash_val = hash_val * 29 + max_val
	return hash_val

## Returns true if this edge connects to the given vertex index.
func contains(vertex: int) -> bool:
	return a == vertex or b == vertex

## Returns the other vertex index connected by this edge, or -1 if vertex is not on this edge.
func other_vertex(vertex: int) -> int:
	if vertex == a:
		return b
	elif vertex == b:
		return a
	return -1

## Returns true if this edge shares any vertex index with another edge.
func contains_edge(other: PBEdge) -> bool:
	if other == null:
		return false
	return a == other.a or b == other.a or a == other.b or b == other.b

## String representation formatted as "[a, b]".
func _to_string() -> String:
	return "[%d, %d]" % [a, b]


## PBEdgeLookup — Associates a local face edge with its corresponding common (shared vertex) edge.
##
## Equality and hashing are based solely on the common edge, allowing deduplication
## of topological edges across adjacent faces while retaining a reference to a local edge.
class PBEdgeLookup extends RefCounted:
	## Edge in distinct mesh vertex indices.
	var local: PBEdge

	## Edge in shared vertex group indices.
	var common: PBEdge

	func _init(p_common: PBEdge = null, p_local: PBEdge = null) -> void:
		common = p_common
		local = p_local

	## Factory method to create a PBEdgeLookup instance.
	static func make(p_common: PBEdge, p_local: PBEdge) -> PBEdgeLookup:
		return PBEdgeLookup.new(p_common, p_local)

	## Compares EdgeLookup instances based on their common edge.
	func equals(other: PBEdgeLookup) -> bool:
		if other == null or common == null or other.common == null:
			return false
		return common.equals(other.common)

	## Returns hash based on the common edge.
	func get_hash() -> int:
		return common.get_hash() if common != null else 0

	func _to_string() -> String:
		return "Common: %s, local: %s" % [str(common), str(local)]

	## Creates a list of EdgeLookup entries from local edges and a shared vertex lookup dictionary.
	static func get_edge_lookup(edges: Array[PBEdge], lookup: Dictionary) -> Array[PBEdgeLookup]:
		var result: Array[PBEdgeLookup] = []
		for e in edges:
			if e == null:
				continue
			var ca: int = lookup.get(e.a, -1)
			var cb: int = lookup.get(e.b, -1)
			result.append(PBEdgeLookup.new(PBEdge.new(ca, cb), e))
		return result

	## Creates a deduplicated dictionary (keyed by common edge hash) of EdgeLookup entries.
	static func get_edge_lookup_dict(edges: Array[PBEdge], lookup: Dictionary) -> Dictionary:
		var result: Dictionary = {}
		for e in edges:
			if e == null:
				continue
			var ca: int = lookup.get(e.a, -1)
			var cb: int = lookup.get(e.b, -1)
			var el := PBEdgeLookup.new(PBEdge.new(ca, cb), e)
			var h: int = el.get_hash()
			if not result.has(h):
				result[h] = el
		return result
