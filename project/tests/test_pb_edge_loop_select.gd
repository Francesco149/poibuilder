## Tests for the edge LOOP / RING selection gestures (alt+click or
## double-click = loop; shift+alt+click or shift+double-click = ring) — the
## engine selection stays the seed id, while dragging/highlighting/the
## PBSelection mirror expand through the recorded spread.
##
## The two walks are different topology questions and the video review caught
## the plugin answering the wrong one: a loop runs END TO END through 4-valence
## corners (which is what "select the loop the loop cut just made" means),
## a ring is crossed by the quad strip perpendicular to the seed (which is what
## the loop cut itself consumes).
extends GutTest

func _make_setup(data: PBMeshData = null) -> Dictionary:
	var ed := PBEditor.new()
	var logic := PBElementEditor.new()
	logic.editor = ed
	var mesh := PBMesh.create_cube(1.0)
	if data != null:
		mesh.pb_mesh_data = data
	add_child_autofree(mesh)
	ed.active_mesh = mesh
	ed.select_mode = PBEditor.SelectMode.EDGE
	return {"ed": ed, "logic": logic, "mesh": mesh}

## A cube whose every face is split once: the mid-edge vertices are 4-valence,
## so an edge loop runs through them instead of stopping at a cube corner.
func _grid_cube() -> PBMeshData:
	var data := PBMeshData.create_cube(1.0)
	var all := PackedInt32Array()
	for i in range(data.faces.size()):
		all.append(i)
	PBMeshOps.subdivide_faces(data, all)
	return data

## The first common edge whose LOOP is longer than the seed.
func _seed_with_a_loop(logic: PBElementEditor, md: PBMeshData) -> int:
	for i in range(md.get_common_edges().size()):
		if logic.edge_loop_ids(md, i).size() > 2:
			return i
	return -1

func test_plain_click_records_no_loop():
	var s := _make_setup()
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	var loop := logic.record_edge_click(md, 0, false)
	assert_eq(loop.size(), 0, "A plain click (no alt, no double) records no loop")
	assert_eq(logic.selected_loops.size(), 0)

func test_alt_click_on_a_plain_cube_stops_at_the_corner():
	var s := _make_setup()
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	var loop := logic.record_edge_click(md, 0, true)
	# A cube corner has 3 edges: an edge loop cannot pass through it, so the
	# walk ends immediately. (The RING of the same edge is the 4 vertical edges
	# — that is the shift+alt gesture.)
	assert_eq(loop.size(), 0, "A cube edge has no loop of its own")
	assert_eq(logic.selected_loops.size(), 0)

func test_alt_click_records_the_edge_loop():
	var s := _make_setup(_grid_cube())
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	var seed := _seed_with_a_loop(logic, md)
	assert_gt(seed, -1, "the grid cube has an edge with a loop")
	var loop := logic.record_edge_click(md, seed, true)
	assert_gt(loop.size(), 1, "Alt+click selects more than the single edge")
	assert_true(loop.has(seed), "The seed edge is part of its loop")
	assert_eq(logic.selected_loops[seed], loop)

func test_shift_alt_click_records_the_ring():
	var s := _make_setup()
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	var ring := logic.record_edge_click(md, 0, true, true)
	# A cube edge's ring: 4 edges, one loop around the shape.
	assert_eq(ring.size(), 4, "Shift+alt+click selects the cube edge's ring")
	assert_true(ring.has(0), "The seed edge is part of its ring")

func test_shift_alt_click_on_a_subdivided_cube_ring_vs_loop():
	var s := _make_setup(_grid_cube())
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	var seed := _seed_with_a_loop(logic, md)
	var loop := logic.edge_loop_ids(md, seed)
	var ring := logic.edge_ring_ids(md, seed)
	assert_gt(loop.size(), 1, "the seed has a loop")
	assert_gt(ring.size(), 1, "the seed has a ring")
	# (The two walks coincide in SIZE on a symmetric grid cube; that they are
	# different sets with different extents is pinned exactly on the loop-cut
	# mesh at the end of this file: 4 loop edges against a 6-edge ring.)

func test_double_click_records_the_loop():
	var s := _make_setup(_grid_cube())
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	var seed := _seed_with_a_loop(logic, md)
	var want := logic.edge_loop_ids(md, seed).size()
	logic.record_edge_click(md, seed, false)  # first click
	var loop := logic.record_edge_click(md, seed, false)  # double-click timing
	assert_eq(loop.size(), want, "A second click within the window selects the loop")

func test_double_click_on_a_different_edge_is_not_a_double_click():
	var s := _make_setup(_grid_cube())
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	var seed := _seed_with_a_loop(logic, md)
	logic.record_edge_click(md, seed, false)
	var loop := logic.record_edge_click(md, seed + 1, false)
	assert_eq(loop.size(), 0, "Clicking a different edge never counts as double-click")

func test_plain_reclick_drops_the_loop():
	var s := _make_setup(_grid_cube())
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	var seed := _seed_with_a_loop(logic, md)
	logic.record_edge_click(md, seed, true)
	assert_eq(logic.selected_loops.size(), 1)
	logic.record_edge_click(md, seed, false)
	assert_eq(logic.selected_loops.size(), 0,
		"A plain click on a looped edge falls back to the single edge")

func test_element_indices_expand_to_the_loop():
	var s := _make_setup(_grid_cube())
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	var edges := md.get_common_edges()
	var seed := _seed_with_a_loop(logic, md)

	logic.record_edge_click(md, seed, true)
	var single := md.get_coincident_vertices_from_edges([edges[seed]])
	var expanded := logic.element_indices(md, seed)
	assert_gt(expanded.size(), single.size(),
		"Dragging the seed id moves every vertex of the loop")
	for idx in single:
		assert_true(expanded.has(idx))

func test_mirror_expands_selection_to_the_loop():
	var s := _make_setup(_grid_cube())
	var ed: PBEditor = s["ed"]
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	var seed := _seed_with_a_loop(logic, md)
	var want := logic.edge_loop_ids(md, seed).size()

	logic.record_edge_click(md, seed, true)
	logic.mirror_engine_selection(ed.selection, md, PackedInt32Array([seed]))
	assert_eq(ed.selection.selected_edge_count(), want,
		"The selection mirror reports the whole loop (ops see the loop too)")

func test_mirror_prunes_loops_when_the_seed_deselects():
	var s := _make_setup(_grid_cube())
	var ed: PBEditor = s["ed"]
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	var seed := _seed_with_a_loop(logic, md)

	logic.record_edge_click(md, seed, true)
	logic.mirror_engine_selection(ed.selection, md, PackedInt32Array([seed]))
	logic.mirror_engine_selection(ed.selection, md, PackedInt32Array())
	assert_eq(logic.selected_loops.size(), 0,
		"A loop dies with its seed leaving the engine selection")

func test_expand_passes_plain_ids_through():
	var s := _make_setup(_grid_cube())
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	var seed := _seed_with_a_loop(logic, md)
	logic.record_edge_click(md, seed, true)
	var plain := PackedInt32Array()
	for i in range(md.get_common_edges().size()):
		if i != seed:
			plain.append(i)
			break
	var out := logic.expand_edge_ids(md, plain)
	assert_eq(out.size(), 1, "Non-loop ids expand to themselves")

func test_reset_side_faces_clears_loops():
	var s := _make_setup(_grid_cube())
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	var seed := _seed_with_a_loop(logic, md)
	logic.record_edge_click(md, seed, true)
	logic.reset_side_faces()
	assert_eq(logic.selected_loops.size(), 0,
		"Mode switches / ops clear loop state with the side faces")

## The loop cut's payoff, and the video review's report ("it only seems to cut
## 2 opposite faces"): after a loop cut the NEW edges are a loop — every one of
## their vertices sits between the two quad rows the cut made, so the walk runs
## all the way around the shape. Selecting one must select them all, because
## that is the gesture the clip uses to show what the cut produced.
func test_loop_cut_edges_form_a_selectable_loop():
	var data := PBShapeGenerators.create_box(Vector3(3.0, 2.0, 3.0))
	# the vertical corner edge at (+X, +Z)
	var seed_edge: PBEdge = null
	for e in data.get_common_edges():
		var a: Vector3 = data.positions[e.a]
		var b: Vector3 = data.positions[e.b]
		if absf(a.x - 1.5) < 0.01 and absf(b.x - 1.5) < 0.01 \
				and absf(a.z - 1.5) < 0.01 and absf(b.z - 1.5) < 0.01:
			seed_edge = e
	assert_not_null(seed_edge, "the box has its +X/+Z vertical edge")
	var cut := PBMeshOps.insert_edge_loop(data, PBMeshOps.common_edge_ids(data, [seed_edge]))
	assert_true(cut["ok"], "the loop cut ran (%s)" % cut.get("error", ""))
	assert_eq(data.faces.size(), 10, "all four side faces were split")

	var s := _make_setup(data)
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = data
	# A new mid-height edge: horizontal, at the cut's own height — the box's own
	# vertical middle, which is where `insert_edge_loop` puts the bisector. The
	# box generator centres its geometry, so the middle is the mean of the
	# vertical extent rather than an absolute number.
	var y_lo := INF
	var y_hi := -INF
	for p in md.positions:
		y_lo = minf(y_lo, p.y)
		y_hi = maxf(y_hi, p.y)
	var mid_y: float = (y_lo + y_hi) * 0.5
	var mid := -1
	for i in range(md.get_common_edges().size()):
		var e := md.get_common_edges()[i]
		var a: Vector3 = md.positions[e.a]
		var b: Vector3 = md.positions[e.b]
		if absf(a.y - b.y) < 0.001 and absf(a.y - mid_y) < 0.001:
			mid = i
			break
	assert_gt(mid, -1, "the cut created a mid-height edge")
	var loop := logic.record_edge_click(md, mid, true)
	assert_eq(loop.size(), 4,
		"the cut's own edges are one loop of 4 (not the 6-edge ring over top and bottom)")
	# ...and the ring of the same edge is the wider set (over the top, under the
	# bottom), which is what the loop cut consumes, not what it produces.
	var ring := logic.edge_ring_ids(md, mid)
	assert_eq(ring.size(), 6, "the ring through the same edge wraps the shape")
