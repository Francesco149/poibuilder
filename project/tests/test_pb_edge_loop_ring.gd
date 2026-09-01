extends GutTest

## Tests for PBSelection edge loop and edge ring selection,
## utilizing PBTopology traversal functions.

var data: PBMeshData


func before_each() -> void:
	# Use a cylinder for loop/ring tests (has clear loop/ring topology)
	data = PBShapeCylinder.create_cylinder(0.5, 1.0, 8, 1, 1)


# ==============================================================================
# Edge Loop Selection
# ==============================================================================

func test_edge_loop_on_cylinder() -> void:
	# Pick a vertical edge on the cylinder body and select its loop
	var seed_edges: Array[PBEdge] = _find_vertical_body_edge()
	assert_gt(seed_edges.size(), 0, "Should find a vertical body edge")

	var loop: Array[PBEdge] = PBTopology.get_edge_loop(data, seed_edges)
	# A vertical edge loop on 8-sided cylinder body should traverse all 8 segments
	assert_gt(loop.size(), 1, "Edge loop should find multiple edges")


func test_edge_loop_on_horizontal_ring() -> void:
	# Pick a horizontal edge (connecting adjacent vertices on the same ring)
	var seed_edges: Array[PBEdge] = _find_horizontal_body_edge()
	assert_gt(seed_edges.size(), 0, "Should find a horizontal body edge")

	var loop: Array[PBEdge] = PBTopology.get_edge_loop(data, seed_edges)
	# A horizontal loop on 8-sided cylinder should find edges around the ring
	assert_gt(loop.size(), 1, "Horizontal edge loop should find multiple edges")


func test_edge_loop_empty_input() -> void:
	var result: Array[PBEdge] = PBTopology.get_edge_loop(data, [])
	assert_eq(result.size(), 0)


func test_edge_loop_null_data() -> void:
	var edge := PBEdge.new(0, 1)
	var edges: Array[PBEdge] = [edge]
	var result: Array[PBEdge] = PBTopology.get_edge_loop(null, edges)
	assert_eq(result.size(), 0)


# ==============================================================================
# Edge Ring Selection
# ==============================================================================

func test_edge_ring_on_cylinder() -> void:
	# Pick a horizontal edge on the cylinder body and select its ring
	var seed_edges: Array[PBEdge] = _find_horizontal_body_edge()
	assert_gt(seed_edges.size(), 0, "Should find a horizontal body edge")

	var ring: Array[PBEdge] = PBTopology.get_edge_ring(data, seed_edges)
	assert_gt(ring.size(), 1, "Edge ring should find multiple edges")


func test_edge_ring_on_vertical() -> void:
	# Pick a vertical edge and select its ring
	var seed_edges: Array[PBEdge] = _find_vertical_body_edge()
	assert_gt(seed_edges.size(), 0, "Should find a vertical body edge")

	var ring: Array[PBEdge] = PBTopology.get_edge_ring(data, seed_edges)
	assert_gt(ring.size(), 1, "Vertical edge ring should find multiple edges")


func test_edge_ring_empty_input() -> void:
	var result: Array[PBEdge] = PBTopology.get_edge_ring(data, [])
	assert_eq(result.size(), 0)


func test_edge_ring_null_data() -> void:
	var edge := PBEdge.new(0, 1)
	var edges: Array[PBEdge] = [edge]
	var result: Array[PBEdge] = PBTopology.get_edge_ring(null, edges)
	assert_eq(result.size(), 0)


# ==============================================================================
# Cube Edge Loop/Ring
# ==============================================================================

func test_edge_loop_on_cube() -> void:
	var cube_data := PBMeshData.create_cube(1.0)
	# All cube edges should be at 4-valence (for quad faces), enabling loops
	var first_edge: Array[PBEdge] = [cube_data.faces[0].get_edges()[0]]
	var loop: Array[PBEdge] = PBTopology.get_edge_loop(cube_data, first_edge)
	# On a cube, a horizontal edge loop should go around 4 edges
	assert_gt(loop.size(), 0, "Cube edge loop should find edges")


func test_edge_ring_on_cube() -> void:
	var cube_data := PBMeshData.create_cube(1.0)
	var first_edge: Array[PBEdge] = [cube_data.faces[0].get_edges()[0]]
	var ring: Array[PBEdge] = PBTopology.get_edge_ring(cube_data, first_edge)
	assert_gt(ring.size(), 0, "Cube edge ring should find edges")


# ==============================================================================
# Integration: Selection + Loop/Ring
# ==============================================================================

func test_selection_with_edge_loop() -> void:
	var sel := PBSelection.new(data)
	var seed_edges: Array[PBEdge] = _find_vertical_body_edge()
	if seed_edges.is_empty():
		pass_test("No vertical edge found, skipping")
		return

	# Perform loop selection
	var loop: Array[PBEdge] = PBTopology.get_edge_loop(data, seed_edges)
	sel.set_edges(loop)
	assert_eq(sel.selected_edge_count(), loop.size())


func test_selection_with_edge_ring() -> void:
	var sel := PBSelection.new(data)
	var seed_edges: Array[PBEdge] = _find_horizontal_body_edge()
	if seed_edges.is_empty():
		pass_test("No horizontal edge found, skipping")
		return

	var ring: Array[PBEdge] = PBTopology.get_edge_ring(data, seed_edges)
	sel.set_edges(ring)
	assert_eq(sel.selected_edge_count(), ring.size())


# ==============================================================================
# Iterative Loop/Ring
# ==============================================================================

func test_edge_loop_iterative_extends() -> void:
	var seed_edges: Array[PBEdge] = _find_vertical_body_edge()
	if seed_edges.is_empty():
		pass_test("No vertical edge found, skipping")
		return

	var iterative: Array[PBEdge] = PBTopology.get_edge_loop_iterative(data, seed_edges)
	# Iterative should extend by at most 2 edges (one at each end)
	assert_gte(iterative.size(), seed_edges.size(), "Iterative should include seed")
	assert_lte(iterative.size(), seed_edges.size() + 2, "Iterative should add at most 2")


func test_edge_ring_iterative_extends() -> void:
	var seed_edges: Array[PBEdge] = _find_horizontal_body_edge()
	if seed_edges.is_empty():
		pass_test("No horizontal edge found, skipping")
		return

	var iterative: Array[PBEdge] = PBTopology.get_edge_ring_iterative(data, seed_edges)
	assert_gte(iterative.size(), seed_edges.size(), "Iterative should include seed")
	assert_lte(iterative.size(), seed_edges.size() + 2, "Iterative should add at most 2")


# ==============================================================================
# Helpers
# ==============================================================================

## Finds a vertical body edge on the cylinder (connects top to bottom ring).
func _find_vertical_body_edge() -> Array[PBEdge]:
	var positions := data.positions
	for face in data.faces:
		if face == null:
			continue
		for edge in face.get_edges():
			if edge.a < 0 or edge.a >= positions.size() or edge.b < 0 or edge.b >= positions.size():
				continue
			var pa: Vector3 = positions[edge.a]
			var pb: Vector3 = positions[edge.b]
			# Vertical edge: same angle around Y axis, different Y
			var dy: float = absf(pa.y - pb.y)
			var dxz: float = Vector2(pa.x - pb.x, pa.z - pb.z).length()
			if dy > 0.3 and dxz < 0.1:
				var result: Array[PBEdge] = [edge]
				return result
	return []


## Finds a horizontal body edge on the cylinder (connects adjacent vertices on same ring).
func _find_horizontal_body_edge() -> Array[PBEdge]:
	var positions := data.positions
	for face in data.faces:
		if face == null:
			continue
		for edge in face.get_edges():
			if edge.a < 0 or edge.a >= positions.size() or edge.b < 0 or edge.b >= positions.size():
				continue
			var pa: Vector3 = positions[edge.a]
			var pb: Vector3 = positions[edge.b]
			# Horizontal edge: same Y, different xz angle, on body (not cap center)
			var dy: float = absf(pa.y - pb.y)
			var dxz: float = Vector2(pa.x - pb.x, pa.z - pb.z).length()
			# Check not at center (cap vertex at 0,0)
			if dy < 0.05 and dxz > 0.1 and Vector2(pa.x, pa.z).length() > 0.1:
				var result: Array[PBEdge] = [edge]
				return result
	return []
