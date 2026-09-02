## Tests for edge-loop selection (#14): alt+click or double-click on an edge
## selects its whole ring — the engine selection stays the seed id, while
## dragging/highlighting/the PBSelection mirror expand through the loop.
extends GutTest

func _make_setup() -> Dictionary:
	var ed := PBEditor.new()
	var logic := PBElementEditor.new()
	logic.editor = ed
	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)
	ed.active_mesh = mesh
	ed.select_mode = PBEditor.SelectMode.EDGE
	return {"ed": ed, "logic": logic, "mesh": mesh}

func test_plain_click_records_no_loop():
	var s := _make_setup()
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	var loop := logic.record_edge_click(md, 0, false)
	assert_eq(loop.size(), 0, "A plain click (no alt, no double) records no loop")
	assert_eq(logic.selected_loops.size(), 0)

func test_alt_click_records_the_ring():
	var s := _make_setup()
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	var loop := logic.record_edge_click(md, 0, true)
	assert_gt(loop.size(), 1, "Alt+click selects more than the single edge")
	assert_true(loop.has(0), "The seed edge is part of its loop")
	assert_eq(logic.selected_loops[0], loop)
	# A cube edge's ring: 4 edges (one loop around the cube).
	assert_eq(loop.size(), 4, "A cube edge ring has 4 edges")

func test_double_click_records_the_ring():
	var s := _make_setup()
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	logic.record_edge_click(md, 0, false)  # first click
	var loop := logic.record_edge_click(md, 0, false)  # double-click timing
	assert_eq(loop.size(), 4, "A second click on the same edge within the window selects the loop")

func test_second_click_on_a_different_edge_is_not_a_double_click():
	var s := _make_setup()
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	logic.record_edge_click(md, 0, false)
	var loop := logic.record_edge_click(md, 3, false)
	assert_eq(loop.size(), 0, "Clicking a different edge never counts as double-click")

func test_plain_reclick_drops_the_loop():
	var s := _make_setup()
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	logic.record_edge_click(md, 0, true)
	assert_eq(logic.selected_loops.size(), 1)
	logic.record_edge_click(md, 0, false)
	assert_eq(logic.selected_loops.size(), 0,
		"A plain click on a looped edge falls back to the single edge")

func test_element_indices_expand_to_the_loop():
	var s := _make_setup()
	var ed: PBEditor = s["ed"]
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	var edges := md.get_common_edges()

	logic.record_edge_click(md, 0, true)
	var single := md.get_coincident_vertices_from_edges([edges[0]])
	var expanded := logic.element_indices(md, 0)
	assert_gt(expanded.size(), single.size(),
		"Dragging the seed id moves every vertex of the loop")
	# And the expanded set must contain the single edge's corners.
	for idx in single:
		assert_true(expanded.has(idx))

func test_mirror_expands_selection_to_the_loop():
	var s := _make_setup()
	var ed: PBEditor = s["ed"]
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	var edges := md.get_common_edges()

	logic.record_edge_click(md, 0, true)
	logic.mirror_engine_selection(ed.selection, md, PackedInt32Array([0]))
	assert_eq(ed.selection.selected_edge_count(), 4,
		"The selection mirror reports the whole loop (ops see the loop too)")

func test_mirror_prunes_loops_when_the_seed_deselects():
	var s := _make_setup()
	var ed: PBEditor = s["ed"]
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data

	logic.record_edge_click(md, 0, true)
	logic.mirror_engine_selection(ed.selection, md, PackedInt32Array([0]))
	logic.mirror_engine_selection(ed.selection, md, PackedInt32Array())
	assert_eq(logic.selected_loops.size(), 0,
		"A loop dies with its seed leaving the engine selection")

func test_expand_passes_plain_ids_through():
	var s := _make_setup()
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	logic.record_edge_click(md, 0, true)
	var out := logic.expand_edge_ids(md, PackedInt32Array([2, 5]))
	assert_eq(out.size(), 2, "Non-loop ids expand to themselves")

func test_reset_side_faces_clears_loops():
	var s := _make_setup()
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	logic.record_edge_click(md, 0, true)
	logic.reset_side_faces()
	assert_eq(logic.selected_loops.size(), 0,
		"Mode switches / ops clear loop state with the side faces")
