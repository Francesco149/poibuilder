## Test: PBTopology and PBWingedEdge
##
## Verifies WingedEdge data structure, edge adjacency sorting, spoke querying,
## edge ring traversals, and edge loop traversals across various mesh topologies.
extends GutTest

# ==============================================================================
# Helper Mesh Builders for Topology Tests
# ==============================================================================

## Creates a 2x2 quad grid on the XZ plane with 4 faces and 9 shared vertices.
## Center vertex (group 4) has valence 4 (4 edges meeting).
static func _create_2x2_quad_grid() -> PBMeshData:
	var mesh_data := PBMeshData.new()

	# 4 quads * 4 distinct vertices = 16 positions
	# Vertex coordinates (x, 0, z) for x,z in [0, 1, 2]
	# Grid layout of shared vertices:
	# 6 -- 7 -- 8
	# | Q2 | Q3 |
	# 3 -- 4 -- 5
	# | Q0 | Q1 |
	# 0 -- 1 -- 2
	mesh_data.positions = PackedVector3Array([
		# Q0 (corners 0, 1, 4, 3)
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1),
		# Q1 (corners 1, 2, 5, 4)
		Vector3(1, 0, 0), Vector3(2, 0, 0), Vector3(2, 0, 1), Vector3(1, 0, 1),
		# Q2 (corners 3, 4, 7, 6)
		Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 0, 2), Vector3(0, 0, 2),
		# Q3 (corners 4, 5, 8, 7)
		Vector3(1, 0, 1), Vector3(2, 0, 1), Vector3(2, 0, 2), Vector3(1, 0, 2),
	])

	mesh_data.faces = []
	for i in range(4):
		var base: int = i * 4
		var face := PBFace.new(PackedInt32Array([
			base + 0, base + 1, base + 2,
			base + 2, base + 3, base + 0
		]))
		mesh_data.faces.append(face)

	mesh_data.shared_vertices = [
		PBSharedVertex.new(PackedInt32Array([0])),              # 0
		PBSharedVertex.new(PackedInt32Array([1, 4])),           # 1
		PBSharedVertex.new(PackedInt32Array([5])),              # 2
		PBSharedVertex.new(PackedInt32Array([3, 8])),           # 3
		PBSharedVertex.new(PackedInt32Array([2, 7, 9, 12])),    # 4 (Center - valence 4)
		PBSharedVertex.new(PackedInt32Array([6, 13])),          # 5
		PBSharedVertex.new(PackedInt32Array([11])),             # 6
		PBSharedVertex.new(PackedInt32Array([10, 15])),         # 7
		PBSharedVertex.new(PackedInt32Array([14])),             # 8
	]

	mesh_data.invalidate_caches()
	return mesh_data

## Creates a 4-quad, 2-segment open cylinder (tube) with 8 quad faces and 12 shared vertices.
## The 4 middle ring vertices (groups 4, 5, 6, 7) all have valence 4.
static func _create_2_segment_cylinder() -> PBMeshData:
	var mesh_data := PBMeshData.new()

	# 8 quads * 4 vertices = 32 distinct vertices
	# Shared vertex rings:
	# Top:    8,  9, 10, 11
	# Middle: 4,  5,  6,  7  (valence 4)
	# Bottom: 0,  1,  2,  3
	var positions := PackedVector3Array()
	positions.resize(32)

	# Shared positions
	var ring_bottom: Array[Vector3] = [Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(0, 0, -1)]
	var ring_mid: Array[Vector3] = [Vector3(1, 1, 0), Vector3(0, 1, 1), Vector3(-1, 1, 0), Vector3(0, 1, -1)]
	var ring_top: Array[Vector3] = [Vector3(1, 2, 0), Vector3(0, 2, 1), Vector3(-1, 2, 0), Vector3(0, 2, -1)]

	# Lower 4 quads (0..3): corners (i, (i+1)%4, (i+1)%4 + 4, i + 4)
	# Upper 4 quads (4..7): corners (i + 4, (i+1)%4 + 4, (i+1)%4 + 8, i + 8)
	var shared_groups: Array[Array] = []
	for _s in range(12):
		shared_groups.append([])

	mesh_data.faces = []
	var v_idx: int = 0

	# Lower segment faces
	for i in range(4):
		var next_i: int = (i + 1) % 4
		var c0: int = i
		var c1: int = next_i
		var c2: int = next_i + 4
		var c3: int = i + 4

		positions[v_idx + 0] = ring_bottom[c0]
		positions[v_idx + 1] = ring_bottom[c1]
		positions[v_idx + 2] = ring_mid[c2 - 4]
		positions[v_idx + 3] = ring_mid[c3 - 4]

		shared_groups[c0].append(v_idx + 0)
		shared_groups[c1].append(v_idx + 1)
		shared_groups[c2].append(v_idx + 2)
		shared_groups[c3].append(v_idx + 3)

		var face := PBFace.new(PackedInt32Array([
			v_idx + 0, v_idx + 1, v_idx + 2,
			v_idx + 2, v_idx + 3, v_idx + 0
		]))
		mesh_data.faces.append(face)
		v_idx += 4

	# Upper segment faces
	for i in range(4):
		var next_i: int = (i + 1) % 4
		var c0: int = i + 4
		var c1: int = next_i + 4
		var c2: int = next_i + 8
		var c3: int = i + 8

		positions[v_idx + 0] = ring_mid[c0 - 4]
		positions[v_idx + 1] = ring_mid[c1 - 4]
		positions[v_idx + 2] = ring_top[c2 - 8]
		positions[v_idx + 3] = ring_top[c3 - 8]

		shared_groups[c0].append(v_idx + 0)
		shared_groups[c1].append(v_idx + 1)
		shared_groups[c2].append(v_idx + 2)
		shared_groups[c3].append(v_idx + 3)

		var face := PBFace.new(PackedInt32Array([
			v_idx + 0, v_idx + 1, v_idx + 2,
			v_idx + 2, v_idx + 3, v_idx + 0
		]))
		mesh_data.faces.append(face)
		v_idx += 4

	mesh_data.positions = positions
	mesh_data.shared_vertices = []
	for g in shared_groups:
		var arr := PackedInt32Array()
		for val in g:
			arr.append(val)
		mesh_data.shared_vertices.append(PBSharedVertex.new(arr))

	mesh_data.invalidate_caches()
	return mesh_data


# ==============================================================================
# PBWingedEdge Unit Tests
# ==============================================================================

func test_winged_edge_construction_and_fields():
	var local_e := PBEdge.new(0, 1)
	var common_e := PBEdge.new(10, 11)
	var lookup := PBEdge.PBEdgeLookup.new(common_e, local_e)
	var face := PBFace.new(PackedInt32Array([0, 1, 2]))

	var wing := PBTopology.PBWingedEdge.new(lookup, face)
	assert_eq(wing.edge, lookup, "Edge lookup should match")
	assert_eq(wing.face, face, "Face should match")
	assert_null(wing.next, "Next should be default null")
	assert_null(wing.previous, "Previous should be default null")
	assert_null(wing.opposite, "Opposite should be default null")

func test_winged_edge_count_cycle():
	var w0 := PBTopology.PBWingedEdge.new()
	var w1 := PBTopology.PBWingedEdge.new()
	var w2 := PBTopology.PBWingedEdge.new()
	var w3 := PBTopology.PBWingedEdge.new()

	# Form a 4-cycle
	w0.next = w1
	w1.next = w2
	w2.next = w3
	w3.next = w0

	assert_eq(w0.count(), 4, "4-cycle should have count 4")
	assert_eq(w1.count(), 4, "Any node in 4-cycle should have count 4")

	# Single disconnected wing
	var single := PBTopology.PBWingedEdge.new()
	assert_eq(single.count(), 1, "Single unlinked wing count should be 1")

func test_winged_edge_adjacent_with_common_index():
	var w0 := PBTopology.PBWingedEdge.new(PBEdge.PBEdgeLookup.new(PBEdge.new(0, 1), PBEdge.new(0, 1)))
	var w1 := PBTopology.PBWingedEdge.new(PBEdge.PBEdgeLookup.new(PBEdge.new(1, 2), PBEdge.new(1, 2)))
	var w2 := PBTopology.PBWingedEdge.new(PBEdge.PBEdgeLookup.new(PBEdge.new(2, 0), PBEdge.new(2, 0)))

	w0.next = w1
	w0.previous = w2
	w1.next = w2
	w1.previous = w0
	w2.next = w0
	w2.previous = w1

	# From w0 (edge 0,1): next is w1 (edge 1,2) containing 2; previous is w2 (edge 2,0) containing 2
	assert_eq(w0.get_adjacent_edge_with_common_index(1), w1, "Next contains common index 1")
	assert_eq(w0.get_adjacent_edge_with_common_index(2), w1, "Next contains common index 2")
	assert_eq(w0.get_adjacent_edge_with_common_index(99), null, "Unrelated index returns null")

func test_winged_edge_equals_and_hash():
	var w1 := PBTopology.PBWingedEdge.new(PBEdge.PBEdgeLookup.new(PBEdge.new(10, 20), PBEdge.new(1, 2)))
	var w2 := PBTopology.PBWingedEdge.new(PBEdge.PBEdgeLookup.new(PBEdge.new(99, 88), PBEdge.new(2, 1))) # same local edge reversed
	var w3 := PBTopology.PBWingedEdge.new(PBEdge.PBEdgeLookup.new(PBEdge.new(10, 20), PBEdge.new(3, 4))) # different local edge

	assert_true(w1.equals(w2), "WingedEdges with equal local edges must be equal")
	assert_false(w1.equals(w3), "WingedEdges with different local edges must not be equal")
	assert_false(w1.equals(null), "Comparison with null must return false")
	assert_eq(w1.get_hash(), w2.get_hash(), "Hashes of equivalent local edges must match")


# ==============================================================================
# Edge Adjacency Sorting Tests
# ==============================================================================

func test_sort_edges_by_adjacency_empty_and_single():
	var empty: Array[PBEdge] = []
	var sorted_empty := PBTopology.sort_edges_by_adjacency(empty)
	assert_eq(sorted_empty.size(), 0)

	var single: Array[PBEdge] = [PBEdge.new(1, 2)]
	var sorted_single := PBTopology.sort_edges_by_adjacency(single)
	assert_eq(sorted_single.size(), 1)
	assert_eq(sorted_single[0].a, 1)
	assert_eq(sorted_single[0].b, 2)

func test_sort_edges_by_adjacency_already_sorted():
	var edges: Array[PBEdge] = [
		PBEdge.new(0, 1),
		PBEdge.new(1, 2),
		PBEdge.new(2, 3),
		PBEdge.new(3, 0),
	]
	var sorted := PBTopology.sort_edges_by_adjacency(edges)
	assert_eq(sorted.size(), 4)
	for i in range(4):
		var next_i: int = (i + 1) % 4
		assert_eq(sorted[i].b, sorted[next_i].a, "Edge %d.b must connect to edge %d.a" % [i, next_i])

func test_sort_edges_by_adjacency_scrambled_and_flipped():
	# Quad perimeter edges scrambled and with inverted directions:
	# Desired cycle: 0 -> 1 -> 2 -> 3 -> 0
	var scrambled: Array[PBEdge] = [
		PBEdge.new(0, 1),
		PBEdge.new(0, 3), # Flipped (should become 3, 0 at end)
		PBEdge.new(3, 2), # Flipped (should become 2, 3)
		PBEdge.new(1, 2),
	]
	var sorted := PBTopology.sort_edges_by_adjacency(scrambled)
	assert_eq(sorted.size(), 4)
	for i in range(4):
		var next_i: int = (i + 1) % 4
		assert_eq(sorted[i].b, sorted[next_i].a, "Sorted edge %d.b (%d) must connect to next edge.a (%d)" % [i, sorted[i].b, sorted[next_i].a])


# ==============================================================================
# Cube WingedEdge Construction Tests (P2-04)
# ==============================================================================

func test_cube_winged_edges_count_and_topology():
	var cube: PBMeshData = PBMeshData.create_cube()
	var wings: Array[PBTopology.PBWingedEdge] = PBTopology.get_winged_edges(cube)

	# 6 faces * 4 edges = 24 WingedEdges
	assert_eq(wings.size(), 24, "Cube must have exactly 24 WingedEdges")

	# one_wing_per_face should return 6 wings
	var wings_one: Array[PBTopology.PBWingedEdge] = PBTopology.get_winged_edges(cube, [], true)
	assert_eq(wings_one.size(), 6, "One wing per face must return 6 wings")

	# Every wing must have a valid face, edge, and next/prev/opposite links
	for i in range(wings.size()):
		var w: PBTopology.PBWingedEdge = wings[i]
		assert_not_null(w.face, "Wing %d must have a non-null face" % i)
		assert_not_null(w.edge, "Wing %d must have a non-null edge" % i)
		assert_not_null(w.edge.local, "Wing %d must have local edge" % i)
		assert_not_null(w.edge.common, "Wing %d must have common edge" % i)
		assert_not_null(w.next, "Wing %d must have next wing" % i)
		assert_not_null(w.previous, "Wing %d must have previous wing" % i)
		assert_not_null(w.opposite, "Wing %d on closed cube must have opposite wing" % i)

		# Cycle count for each quad face must be 4
		assert_eq(w.count(), 4, "Wing %d face cycle count must be 4" % i)

		# Mutual opposite verification
		assert_eq(w.opposite.opposite, w, "Wing %d opposite.opposite must be self" % i)

		# Opposite edge must share identical common edge
		assert_true(w.edge.common.equals(w.opposite.edge.common), "Opposite wings must share common edge")

		# Prev/Next mutual linkage
		assert_eq(w.next.previous, w, "w.next.previous must equal w")
		assert_eq(w.previous.next, w, "w.previous.next must equal w")

func test_cube_unique_common_edges():
	var cube: PBMeshData = PBMeshData.create_cube()
	var wings: Array[PBTopology.PBWingedEdge] = PBTopology.get_winged_edges(cube)

	var unique_common_keys: Dictionary = {}
	for w in wings:
		var ca: int = w.edge.common.a
		var cb: int = w.edge.common.b
		var key := Vector2i(mini(ca, cb), maxi(ca, cb))
		unique_common_keys[key] = true

	# A cube has 12 topological edges
	assert_eq(unique_common_keys.size(), 12, "Cube must have exactly 12 unique common edges")

func test_cube_spokes_counts():
	var cube: PBMeshData = PBMeshData.create_cube()
	var wings: Array[PBTopology.PBWingedEdge] = PBTopology.get_winged_edges(cube)

	var all_spokes: Dictionary = PBTopology.get_all_spokes(wings)
	assert_eq(all_spokes.size(), 8, "Cube must have 8 shared vertex keys in spokes dictionary")

	# Each vertex on a cube connects to 3 adjacent faces -> 6 WingedEdges total (2 per face)
	# and exactly 3 unique common edges meeting at that corner
	for v in range(8):
		var spokes_v: Array[PBTopology.PBWingedEdge] = all_spokes.get(v, [])
		assert_eq(spokes_v.size(), 6, "Vertex %d should be touched by 6 wings (2 per adjacent face)" % v)

		# Distinct edges meeting at vertex
		var distinct_wings := PBTopology._distinct_wings_by_common(spokes_v)
		assert_eq(distinct_wings.size(), 3, "Vertex %d must have exactly 3 unique edges meeting at corner" % v)

		# get_spokes helper
		var queried_spokes: Array[PBTopology.PBWingedEdge] = PBTopology.get_spokes(wings, v)
		assert_eq(queried_spokes.size(), 6, "get_spokes with vertex %d must return 6 wings" % v)


# ==============================================================================
# Edge Ring Tests (P2-05)
# ==============================================================================

func test_edge_ring_next():
	var cube: PBMeshData = PBMeshData.create_cube()
	var wings: Array[PBTopology.PBWingedEdge] = PBTopology.get_winged_edges(cube)

	var w: PBTopology.PBWingedEdge = wings[0]
	var opp_on_face: PBTopology.PBWingedEdge = PBTopology.edge_ring_next(w)
	assert_not_null(opp_on_face, "edge_ring_next on quad face should return opposite edge")
	assert_eq(opp_on_face, w.next.next, "In quad face, opposite edge is next.next")
	assert_eq(opp_on_face, w.previous.previous, "In quad face, opposite edge is previous.previous")

	# Single triangle wing (odd-sided)
	var t0 := PBTopology.PBWingedEdge.new()
	var t1 := PBTopology.PBWingedEdge.new()
	var t2 := PBTopology.PBWingedEdge.new()
	t0.next = t1
	t1.next = t2
	t2.next = t0
	t0.previous = t2
	t1.previous = t0
	t2.previous = t1
	assert_null(PBTopology.edge_ring_next(t0), "edge_ring_next on triangle face must return null")

func test_cube_edge_ring():
	var cube: PBMeshData = PBMeshData.create_cube()

	# Pick local edge (0, 1) on Face 0
	var seed_edge := PBEdge.new(0, 1)
	var ring: Array[PBEdge] = PBTopology.get_edge_ring(cube, [seed_edge])

	# On a cube, an edge ring traverses across 4 adjacent quads and returns 4 parallel edges
	assert_eq(ring.size(), 4, "Edge ring on cube must return 4 parallel edges")

	# Verify all 4 edges have distinct common edge representations
	var lookup := cube.get_shared_vertex_lookup()
	var common_keys: Dictionary = {}
	for e in ring:
		var ca: int = lookup.get(e.a, -1)
		var cb: int = lookup.get(e.b, -1)
		var key := Vector2i(mini(ca, cb), maxi(ca, cb))
		assert_false(common_keys.has(key), "Edge ring should not contain duplicate edges")
		common_keys[key] = true

	assert_eq(common_keys.size(), 4, "Ring must span 4 unique spatial edges")

func test_cube_edge_ring_iterative():
	var cube: PBMeshData = PBMeshData.create_cube()
	var seed_edge := PBEdge.new(0, 1)

	var ring_iter: Array[PBEdge] = PBTopology.get_edge_ring_iterative(cube, [seed_edge])
	# Iterative extends up to 1 step in each direction -> 3 edges (seed + 1 next + 1 prev)
	assert_eq(ring_iter.size(), 3, "Iterative edge ring on cube should return 3 edges")


# ==============================================================================
# Edge Loop Tests (P2-05)
# ==============================================================================

func test_edge_loop_on_cube_valence_3_termination():
	var cube: PBMeshData = PBMeshData.create_cube()
	var seed_edge := PBEdge.new(0, 1)

	# On a standard 6-face cube, all 8 vertices have valence 3.
	# An edge loop only traverses through regular valence-4 vertices.
	# Therefore at valence-3 cube corners, the loop terminates immediately and returns only the seed edge.
	var loop: Array[PBEdge] = PBTopology.get_edge_loop(cube, [seed_edge])
	assert_eq(loop.size(), 1, "Edge loop on simple cube terminates at valence 3 corners, returning 1 seed edge")
	assert_true(loop[0].equals(seed_edge))

func test_edge_loop_on_2x2_quad_grid():
	var grid: PBMeshData = _create_2x2_quad_grid()
	var lookup: Dictionary = grid.get_shared_vertex_lookup()

	# In the 2x2 grid, center vertex (group 4) is shared by all 4 quads (valence 4).
	# Shared edge between Q0 and Q1 touching center vertex 4:
	# Q0 has edge (1, 4) in shared indices [local vertices (1, 2)]
	var seed_vertical := PBEdge.new(1, 2) # Local edge in Q0 connecting group 1 to group 4

	var loop: Array[PBEdge] = PBTopology.get_edge_loop(grid, [seed_vertical])

	# Loop should continue through center vertex 4 into the opposite edge (4, 7) [local (9, 10)]
	assert_eq(loop.size(), 2, "Edge loop through center valence-4 vertex should traverse 2 contiguous edges")

	# Check that both edges in loop share center vertex 4 in common indices
	var c0_a: int = lookup.get(loop[0].a, -1)
	var c0_b: int = lookup.get(loop[0].b, -1)
	var c1_a: int = lookup.get(loop[1].a, -1)
	var c1_b: int = lookup.get(loop[1].b, -1)

	var has_center: bool = (c0_a == 4 or c0_b == 4) and (c1_a == 4 or c1_b == 4)
	assert_true(has_center, "Both edges in loop must connect at the center valence-4 vertex")

func test_edge_loop_closed_cylinder_ring():
	var cyl: PBMeshData = _create_2_segment_cylinder()
	var lookup: Dictionary = cyl.get_shared_vertex_lookup()

	# Middle horizontal edge in lower segment: corners (4, 5) -> local edge (3, 2) in Face 0
	# All 4 vertices along the middle ring (4, 5, 6, 7) have valence 4!
	var seed_horizontal := PBEdge.new(3, 2)

	var loop: Array[PBEdge] = PBTopology.get_edge_loop(cyl, [seed_horizontal])

	# The horizontal loop around the cylinder traverses through 4 valence-4 vertices and forms a closed 4-edge cycle!
	assert_eq(loop.size(), 4, "Horizontal edge loop around 2-segment cylinder must form a complete 4-edge cycle")

	var unique_keys: Dictionary = {}
	for e in loop:
		var ca: int = lookup.get(e.a, -1)
		var cb: int = lookup.get(e.b, -1)
		var key := Vector2i(mini(ca, cb), maxi(ca, cb))
		unique_keys[key] = true

	assert_eq(unique_keys.size(), 4, "Horizontal loop must contain 4 unique topological edges")

func test_edge_loop_vertical_cylinder_column():
	var cyl: PBMeshData = _create_2_segment_cylinder()

	# Vertical edge in lower segment: corners (0, 4) -> local edge (0, 3) in Face 0
	var seed_vertical := PBEdge.new(0, 3)

	var loop: Array[PBEdge] = PBTopology.get_edge_loop(cyl, [seed_vertical])

	# Traverses through middle vertex 4 (valence 4) into upper segment vertical edge (4, 8),
	# and stops at top/bottom open boundaries (valence 3). Total 2 edges.
	assert_eq(loop.size(), 2, "Vertical edge loop along cylinder column should traverse 2 vertical edges")

func test_edge_loop_iterative():
	var cyl: PBMeshData = _create_2_segment_cylinder()
	var seed_horizontal := PBEdge.new(3, 2)

	var loop_iter: Array[PBEdge] = PBTopology.get_edge_loop_iterative(cyl, [seed_horizontal])
	# Seed edge extends by 1 step at each extremity (if valence 4) -> 3 edges total
	assert_eq(loop_iter.size(), 3, "Iterative edge loop should extend seed by 1 step at each 4-valence extremity")
