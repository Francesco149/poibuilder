extends GutTest

## Tests for PBSelection — selection state management.
## Tests add/remove/toggle/clear for vertices, edges, and faces.
## Tests select all, invert, grow, and shrink operations.

var data: PBMeshData


func before_each() -> void:
	data = PBMeshData.create_cube(1.0)


# ==============================================================================
# Vertex Selection
# ==============================================================================

func test_vertex_add_and_query() -> void:
	var sel := PBSelection.new(data)
	sel.add_vertex(0)
	assert_true(sel.is_vertex_selected(0), "Vertex 0 should be selected")
	assert_false(sel.is_vertex_selected(1), "Vertex 1 should not be selected")
	assert_eq(sel.selected_vertex_count(), 1)


func test_vertex_remove() -> void:
	var sel := PBSelection.new(data)
	sel.add_vertex(0)
	sel.add_vertex(1)
	sel.remove_vertex(0)
	assert_false(sel.is_vertex_selected(0))
	assert_true(sel.is_vertex_selected(1))
	assert_eq(sel.selected_vertex_count(), 1)


func test_vertex_toggle() -> void:
	var sel := PBSelection.new(data)
	sel.toggle_vertex(0)
	assert_true(sel.is_vertex_selected(0))
	sel.toggle_vertex(0)
	assert_false(sel.is_vertex_selected(0))


func test_vertex_clear() -> void:
	var sel := PBSelection.new(data)
	sel.add_vertex(0)
	sel.add_vertex(1)
	sel.clear_vertices()
	assert_eq(sel.selected_vertex_count(), 0)


func test_vertex_set() -> void:
	var sel := PBSelection.new(data)
	sel.add_vertex(0)
	sel.set_vertices(PackedInt32Array([2, 3]))
	assert_false(sel.is_vertex_selected(0))
	assert_true(sel.is_vertex_selected(2))
	assert_true(sel.is_vertex_selected(3))
	assert_eq(sel.selected_vertex_count(), 2)


func test_vertex_duplicate_add() -> void:
	var sel := PBSelection.new(data)
	sel.add_vertex(0)
	sel.add_vertex(0)  # Should not duplicate
	assert_eq(sel.selected_vertex_count(), 1)


func test_get_selected_vertex_indices() -> void:
	var sel := PBSelection.new(data)
	sel.add_vertex(0)
	var indices: PackedInt32Array = sel.get_selected_vertex_indices()
	assert_gt(indices.size(), 0, "Should return local vertex indices for shared group 0")
	# Each local index should appear in shared_vertices[0]
	var expected: PackedInt32Array = data.shared_vertices[0].indices
	for idx in indices:
		assert_true(expected.has(idx), "Index %d should be in shared group 0" % idx)


# ==============================================================================
# Edge Selection
# ==============================================================================

func test_edge_add_and_query() -> void:
	var sel := PBSelection.new(data)
	var edges: Array[PBEdge] = data.faces[0].get_edges()
	assert_gt(edges.size(), 0)
	sel.add_edge(edges[0])
	assert_true(sel.is_edge_selected(edges[0]))
	assert_eq(sel.selected_edge_count(), 1)


func test_edge_remove() -> void:
	var sel := PBSelection.new(data)
	var edges: Array[PBEdge] = data.faces[0].get_edges()
	sel.add_edge(edges[0])
	sel.add_edge(edges[1])
	sel.remove_edge(edges[0])
	assert_false(sel.is_edge_selected(edges[0]))
	assert_true(sel.is_edge_selected(edges[1]))


func test_edge_toggle() -> void:
	var sel := PBSelection.new(data)
	var edges: Array[PBEdge] = data.faces[0].get_edges()
	sel.toggle_edge(edges[0])
	assert_true(sel.is_edge_selected(edges[0]))
	sel.toggle_edge(edges[0])
	assert_false(sel.is_edge_selected(edges[0]))


func test_edge_dedup_by_common() -> void:
	var sel := PBSelection.new(data)
	# Two faces sharing an edge should deduplicate when adding edges that map to same common edge
	var edges_face0: Array[PBEdge] = data.faces[0].get_edges()
	sel.add_edge(edges_face0[0])
	var count_before: int = sel.selected_edge_count()
	# Find the same edge in another face's edges (reversed direction)
	var common_target: PBEdge = data.get_common_edge(edges_face0[0])
	var found_dup: bool = false
	for fi in range(1, data.faces.size()):
		var face_edges: Array[PBEdge] = data.faces[fi].get_edges()
		for e in face_edges:
			var common_e: PBEdge = data.get_common_edge(e)
			if common_e != null and common_e.equals(common_target):
				sel.add_edge(e)
				found_dup = true
				break
		if found_dup:
			break
	if found_dup:
		assert_eq(sel.selected_edge_count(), count_before, "Duplicate common edge should not increase count")


# ==============================================================================
# Face Selection
# ==============================================================================

func test_face_add_and_query() -> void:
	var sel := PBSelection.new(data)
	sel.add_face(0)
	assert_true(sel.is_face_selected(0))
	assert_false(sel.is_face_selected(1))
	assert_eq(sel.selected_face_count(), 1)


func test_face_remove() -> void:
	var sel := PBSelection.new(data)
	sel.add_face(0)
	sel.add_face(1)
	sel.remove_face(0)
	assert_false(sel.is_face_selected(0))
	assert_true(sel.is_face_selected(1))


func test_face_toggle() -> void:
	var sel := PBSelection.new(data)
	sel.toggle_face(0)
	assert_true(sel.is_face_selected(0))
	sel.toggle_face(0)
	assert_false(sel.is_face_selected(0))


func test_face_set() -> void:
	var sel := PBSelection.new(data)
	sel.add_face(0)
	sel.set_faces(PackedInt32Array([2, 3]))
	assert_false(sel.is_face_selected(0))
	assert_true(sel.is_face_selected(2))
	assert_true(sel.is_face_selected(3))


# ==============================================================================
# Bulk Operations
# ==============================================================================

func test_clear_all() -> void:
	var sel := PBSelection.new(data)
	sel.add_vertex(0)
	sel.add_edge(data.faces[0].get_edges()[0])
	sel.add_face(0)
	sel.clear_all()
	assert_true(sel.is_empty())
	assert_eq(sel.total_selected(), 0)


func test_is_empty() -> void:
	var sel := PBSelection.new(data)
	assert_true(sel.is_empty())
	sel.add_face(0)
	assert_false(sel.is_empty())


func test_total_selected() -> void:
	var sel := PBSelection.new(data)
	sel.add_vertex(0)
	sel.add_vertex(1)
	sel.add_face(0)
	assert_eq(sel.total_selected(), 3)


# ==============================================================================
# Signal Emission
# ==============================================================================

func test_signal_on_add_vertex() -> void:
	var sel := PBSelection.new(data)
	watch_signals(sel)
	sel.add_vertex(0)
	assert_signal_emitted(sel, "selection_changed")


func test_signal_on_clear() -> void:
	var sel := PBSelection.new(data)
	sel.add_face(0)
	watch_signals(sel)
	sel.clear_all()
	assert_signal_emitted(sel, "selection_changed")


func test_no_signal_on_empty_clear() -> void:
	var sel := PBSelection.new(data)
	watch_signals(sel)
	sel.clear_all()
	assert_signal_not_emitted(sel, "selection_changed")


# ==============================================================================
# Select All / Invert
# ==============================================================================

func test_select_all_vertices() -> void:
	var sel := PBSelection.new(data)
	sel.select_all(PBEditor.SelectMode.VERTEX)
	assert_eq(sel.selected_vertex_count(), data.shared_vertices.size())


func test_select_all_faces() -> void:
	var sel := PBSelection.new(data)
	sel.select_all(PBEditor.SelectMode.FACE)
	assert_eq(sel.selected_face_count(), data.faces.size())


func test_select_all_edges() -> void:
	var sel := PBSelection.new(data)
	sel.select_all(PBEditor.SelectMode.EDGE)
	# Cube has 12 unique edges
	assert_eq(sel.selected_edge_count(), 12)


func test_invert_vertices() -> void:
	var sel := PBSelection.new(data)
	sel.add_vertex(0)
	sel.add_vertex(1)
	sel.invert_selection(PBEditor.SelectMode.VERTEX)
	assert_false(sel.is_vertex_selected(0))
	assert_false(sel.is_vertex_selected(1))
	# All other shared vertex groups should be selected
	var expected: int = data.shared_vertices.size() - 2
	assert_eq(sel.selected_vertex_count(), expected)


func test_invert_faces() -> void:
	var sel := PBSelection.new(data)
	sel.add_face(0)
	sel.invert_selection(PBEditor.SelectMode.FACE)
	assert_false(sel.is_face_selected(0))
	assert_eq(sel.selected_face_count(), data.faces.size() - 1)


# ==============================================================================
# Grow / Shrink Selection
# ==============================================================================

func test_grow_face_selection() -> void:
	var sel := PBSelection.new(data)
	sel.add_face(0)
	var before: int = sel.selected_face_count()
	sel.grow_selection(PBEditor.SelectMode.FACE)
	# Growing from 1 face on a cube should add adjacent faces
	assert_gt(sel.selected_face_count(), before, "Grow should add adjacent faces")
	# On a cube, every face is adjacent to every other (sharing edges),
	# so growing once from 1 face should eventually reach all neighbors
	assert_gt(sel.selected_face_count(), 1)


func test_grow_vertex_selection() -> void:
	var sel := PBSelection.new(data)
	sel.add_vertex(0)
	var before: int = sel.selected_vertex_count()
	sel.grow_selection(PBEditor.SelectMode.VERTEX)
	assert_gt(sel.selected_vertex_count(), before, "Grow should add adjacent vertices")


func test_shrink_face_selection() -> void:
	var sel := PBSelection.new(data)
	# Select all faces, then shrink
	sel.select_all(PBEditor.SelectMode.FACE)
	sel.shrink_selection(PBEditor.SelectMode.FACE)
	# On a closed cube, all 6 faces are selected. Every edge borders two selected faces.
	# No face borders an unselected face, so none is on the boundary. Shrink keeps all.
	assert_eq(sel.selected_face_count(), 6, "All cube faces interior when all selected, shrink keeps all")


func test_shrink_then_empty() -> void:
	var sel := PBSelection.new(data)
	sel.add_face(0)
	sel.shrink_selection(PBEditor.SelectMode.FACE)
	# Single face is always on boundary
	assert_eq(sel.selected_face_count(), 0)


# ==============================================================================
# set_mesh_data resets selection
# ==============================================================================

func test_set_mesh_data_clears() -> void:
	var sel := PBSelection.new(data)
	sel.add_face(0)
	sel.add_vertex(0)
	var data2 := PBMeshData.create_cube(2.0)
	sel.set_mesh_data(data2)
	assert_true(sel.is_empty())
