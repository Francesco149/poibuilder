## Test: PBEdge, PBEdgeLookup, and PBSharedVertex
##
## Verifies edge representation, order-independent equality and hashing,
## edge lookup pairing, shared vertex groupings, and lookup dictionary building.
extends GutTest

# ==============================================================================
# PBEdge Tests
# ==============================================================================

func test_edge_construction_and_fields():
	var e_default := PBEdge.new()
	assert_eq(e_default.a, 0, "Default a should be 0")
	assert_eq(e_default.b, 0, "Default b should be 0")

	var e := PBEdge.new(3, 7)
	assert_eq(e.a, 3, "Field a should be 3")
	assert_eq(e.b, 7, "Field b should be 7")

	var e_make := PBEdge.make(10, 20)
	assert_eq(e_make.a, 10, "Field a should be 10 via make")
	assert_eq(e_make.b, 20, "Field b should be 20 via make")

func test_edge_equality():
	var e1 := PBEdge.new(1, 2)
	var e2 := PBEdge.new(1, 2)
	var e3 := PBEdge.new(2, 1) # Reversed
	var e4 := PBEdge.new(1, 3) # Different
	var e5 := PBEdge.new(3, 2) # Different

	assert_true(e1.equals(e2), "Identical edges should be equal")
	assert_true(e1.equals(e3), "Reversed edges should be equal (order-independent)")
	assert_true(e3.equals(e1), "Symmetric order-independent equality")
	assert_false(e1.equals(e4), "Different endpoints should not be equal")
	assert_false(e1.equals(e5), "Different endpoints should not be equal")
	assert_false(e1.equals(null), "Comparison with null should return false")

func test_edge_contains_and_other_vertex():
	var e := PBEdge.new(4, 9)

	assert_true(e.contains(4), "Edge should contain start vertex 4")
	assert_true(e.contains(9), "Edge should contain end vertex 9")
	assert_false(e.contains(0), "Edge should not contain vertex 0")
	assert_false(e.contains(5), "Edge should not contain vertex 5")

	assert_eq(e.other_vertex(4), 9, "Other vertex for 4 should be 9")
	assert_eq(e.other_vertex(9), 4, "Other vertex for 9 should be 4")
	assert_eq(e.other_vertex(10), -1, "Other vertex for non-member should be -1")

func test_edge_contains_edge():
	var e1 := PBEdge.new(1, 2)
	var e2 := PBEdge.new(2, 3)
	var e3 := PBEdge.new(4, 5)

	assert_true(e1.contains_edge(e2), "e1 and e2 share vertex 2")
	assert_false(e1.contains_edge(e3), "e1 and e3 share no vertices")
	assert_false(e1.contains_edge(null), "contains_edge(null) should return false")

func test_edge_hash_consistency():
	var e1 := PBEdge.new(5, 12)
	var e2 := PBEdge.new(12, 5)
	var e3 := PBEdge.new(5, 13)

	assert_eq(e1.get_hash(), e2.get_hash(), "Order-independent edges must have identical hash")
	assert_ne(e1.get_hash(), e3.get_hash(), "Different edges should produce different hashes")

	# Test hash usable in Dictionary
	var edge_dict := {}
	edge_dict[e1.get_hash()] = "first"
	assert_true(edge_dict.has(e2.get_hash()), "Dictionary keyed by hash should find reversed edge")
	assert_eq(edge_dict[e2.get_hash()], "first")

func test_edge_is_valid():
	var valid_edge := PBEdge.new(0, 1)
	var invalid_sentinel := PBEdge.new(-1, 0)
	var invalid_sentinel2 := PBEdge.new(0, -1)
	var degenerate := PBEdge.new(3, 3)

	assert_true(valid_edge.is_valid(), "Valid edge (0, 1)")
	assert_false(invalid_sentinel.is_valid(), "Invalid edge (-1, 0)")
	assert_false(invalid_sentinel2.is_valid(), "Invalid edge (0, -1)")
	assert_false(degenerate.is_valid(), "Degenerate edge (3, 3)")

func test_edge_to_string():
	var e := PBEdge.new(3, 8)
	assert_eq(e._to_string(), "[3, 8]")
	assert_eq(str(e), "[3, 8]")


# ==============================================================================
# PBEdgeLookup Tests
# ==============================================================================

func test_edge_lookup_pairing_and_fields():
	var local_edge := PBEdge.new(0, 1)
	var common_edge := PBEdge.new(100, 101)

	var lookup := PBEdge.PBEdgeLookup.new(common_edge, local_edge)
	assert_eq(lookup.local, local_edge, "Local edge should match")
	assert_eq(lookup.common, common_edge, "Common edge should match")

	var lookup_make := PBEdge.PBEdgeLookup.make(common_edge, local_edge)
	assert_eq(lookup_make.local, local_edge)
	assert_eq(lookup_make.common, common_edge)

func test_edge_lookup_equality_and_hashing():
	var common_a := PBEdge.new(10, 20)
	var common_a_rev := PBEdge.new(20, 10)
	var common_b := PBEdge.new(30, 40)

	var el1 := PBEdge.PBEdgeLookup.new(common_a, PBEdge.new(0, 1))
	var el2 := PBEdge.PBEdgeLookup.new(common_a_rev, PBEdge.new(4, 5)) # Different local edge, same common edge
	var el3 := PBEdge.PBEdgeLookup.new(common_b, PBEdge.new(0, 1))     # Same local edge, different common edge

	assert_true(el1.equals(el2), "EdgeLookup equality is based ONLY on common edge")
	assert_false(el1.equals(el3), "EdgeLookup with different common edges should not be equal")
	assert_eq(el1.get_hash(), el2.get_hash(), "EdgeLookup hash must match for equivalent common edges")

func test_edge_lookup_utilities():
	# Local edges from two adjacent faces sharing a spatial edge (vertices 1,2 on face A and 5,4 on face B)
	# Common vertex mapping: { 1: 10, 2: 20, 4: 20, 5: 10 }
	var vertex_to_group := { 1: 10, 2: 20, 4: 20, 5: 10 }
	var edges: Array[PBEdge] = [PBEdge.new(1, 2), PBEdge.new(5, 4)]

	var lookups := PBEdge.PBEdgeLookup.get_edge_lookup(edges, vertex_to_group)
	assert_eq(lookups.size(), 2)
	assert_true(lookups[0].common.equals(PBEdge.new(10, 20)))
	assert_true(lookups[1].common.equals(PBEdge.new(10, 20)))
	assert_true(lookups[0].equals(lookups[1]), "Both lookups should be equivalent on common edge")

	var dict := PBEdge.PBEdgeLookup.get_edge_lookup_dict(edges, vertex_to_group)
	assert_eq(dict.size(), 1, "Deduplicated dictionary should collapse matching common edges to 1 entry")


# ==============================================================================
# PBSharedVertex Tests
# ==============================================================================

func test_shared_vertex_construction_and_size():
	var sv_default := PBSharedVertex.new()
	assert_eq(sv_default.size(), 0, "Default SharedVertex should be empty")

	var packed := PackedInt32Array([0, 4, 8])
	var sv := PBSharedVertex.new(packed)
	assert_eq(sv.size(), 3, "Size should be 3")
	assert_eq(sv.indices[0], 0)
	assert_eq(sv.indices[1], 4)
	assert_eq(sv.indices[2], 8)

	var sv_from_arr := PBSharedVertex.from_array([1, 5, 9])
	assert_eq(sv_from_arr.size(), 3)
	assert_eq(sv_from_arr.indices[1], 5)

func test_shared_vertex_contains_and_manipulation():
	var sv := PBSharedVertex.new(PackedInt32Array([2, 6]))

	assert_true(sv.contains(2), "Should contain 2")
	assert_true(sv.contains(6), "Should contain 6")
	assert_false(sv.contains(4), "Should not contain 4")

	# Add
	sv.add(10)
	assert_eq(sv.size(), 3, "Size should become 3 after adding 10")
	assert_true(sv.contains(10))

	# Duplicate add (should not add duplicate)
	sv.add(10)
	assert_eq(sv.size(), 3, "Duplicate add should not increase size")

	# Remove
	assert_true(sv.remove(6), "Removing existing element should return true")
	assert_eq(sv.size(), 2)
	assert_false(sv.contains(6))
	assert_false(sv.remove(99), "Removing non-existent element should return false")

	# Shift indices
	sv.shift_indices(5)
	# Original elements were [2, 10] -> now [7, 15]
	assert_true(sv.contains(7))
	assert_true(sv.contains(15))
	assert_false(sv.contains(2))

	# Clear
	sv.clear()
	assert_eq(sv.size(), 0)

func test_shared_vertex_to_string():
	var sv := PBSharedVertex.new(PackedInt32Array([0, 3, 7]))
	assert_eq(sv._to_string(), "0,3,7")
	assert_eq(str(sv), "0,3,7")

func test_shared_vertex_duplicate():
	var sv1 := PBSharedVertex.new(PackedInt32Array([1, 2, 3]))
	var sv2 := sv1.duplicate_shared()
	assert_eq(sv2.size(), 3)
	assert_true(sv2.contains(1))
	# Mutating sv2 should not affect sv1
	sv2.add(4)
	assert_eq(sv2.size(), 4)
	assert_eq(sv1.size(), 3)

func test_shared_vertex_build_lookup():
	# Setup a mock cube corner topology where 3 faces meet at each corner:
	# Group 0: local vertices [0, 8, 16]
	# Group 1: local vertices [1, 9, 17]
	# Group 2: local vertices [2, 10, 18]
	# Group 3: local vertices [3, 11, 19]
	var sv0 := PBSharedVertex.new(PackedInt32Array([0, 8, 16]))
	var sv1 := PBSharedVertex.new(PackedInt32Array([1, 9, 17]))
	var sv2 := PBSharedVertex.new(PackedInt32Array([2, 10, 18]))
	var sv3 := PBSharedVertex.new(PackedInt32Array([3, 11, 19]))

	var shared_list: Array[PBSharedVertex] = [sv0, sv1, sv2, sv3]
	var lookup := PBSharedVertex.build_lookup(shared_list)

	# Verify every local vertex maps to the correct group index
	assert_eq(lookup.size(), 12, "Lookup should contain all 12 vertex entries")

	assert_eq(lookup[0], 0, "Vertex 0 -> Group 0")
	assert_eq(lookup[8], 0, "Vertex 8 -> Group 0")
	assert_eq(lookup[16], 0, "Vertex 16 -> Group 0")

	assert_eq(lookup[1], 1, "Vertex 1 -> Group 1")
	assert_eq(lookup[9], 1, "Vertex 9 -> Group 1")
	assert_eq(lookup[17], 1, "Vertex 17 -> Group 1")

	assert_eq(lookup[2], 2, "Vertex 2 -> Group 2")
	assert_eq(lookup[10], 2, "Vertex 10 -> Group 2")
	assert_eq(lookup[18], 2, "Vertex 18 -> Group 2")

	assert_eq(lookup[3], 3, "Vertex 3 -> Group 3")
	assert_eq(lookup[11], 3, "Vertex 11 -> Group 3")
	assert_eq(lookup[19], 3, "Vertex 19 -> Group 3")

func test_shared_vertex_to_shared_vertices_roundtrip():
	var sv0 := PBSharedVertex.new(PackedInt32Array([0, 8]))
	var sv1 := PBSharedVertex.new(PackedInt32Array([1, 9]))
	var shared_list: Array[PBSharedVertex] = [sv0, sv1]

	var lookup := PBSharedVertex.build_lookup(shared_list)
	var reconstructed := PBSharedVertex.to_shared_vertices(lookup)

	assert_eq(reconstructed.size(), 2)
	var recon_lookup := PBSharedVertex.build_lookup(reconstructed)
	assert_eq(recon_lookup[0], 0)
	assert_eq(recon_lookup[8], 0)
	assert_eq(recon_lookup[1], 1)
	assert_eq(recon_lookup[9], 1)
