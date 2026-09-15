## Tests for mode-switch selection conversion (ProBuilder parity: switching
## element modes converts the selection — a face becomes its verts, selected
## verts become the faces they fully cover, ...).
##
## The architecture under test: the engine's script API holds a SINGLE
## subgizmo id, so a converted multi-selection is carried as ONE seed id
## plus a conversion expansion (selected_conversion) — the same pattern as
## edge loops and UV island groups. Everything (drag union, mirror,
## highlights, undo payloads, pivot) goes through the SAME code path as an
## ordinary selection; there is no parallel selection state.
extends GutTest

func _make_setup(mode: PBEditor.SelectMode = PBEditor.SelectMode.VERTEX) -> Dictionary:
	var ed := PBEditor.new()
	var logic := PBElementEditor.new()
	logic.editor = ed
	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)
	ed.active_mesh = mesh
	ed.select_mode = mode
	return {"ed": ed, "logic": logic, "mesh": mesh}

func _any_face(md: PBMeshData) -> int:
	for fi in range(md.faces.size()):
		if md.faces[fi] != null:
			return fi
	return -1

func _sorted(a: PackedInt32Array) -> PackedInt32Array:
	var out := a.duplicate()
	out.sort()
	return out

func _same_set(a: PackedInt32Array, b: PackedInt32Array) -> bool:
	return _sorted(a) == _sorted(b)

## Undo spy covering per-position payloads (_apply_positions).
class ConversionUndoSpy:
	var last_indices := PackedInt32Array()
	var last_before := PackedVector3Array()
	var last_after := PackedVector3Array()

	func create_action(_name: String, _merge: int = 0, _context: Object = null) -> void:
		pass

	func add_do_method(_obj: Object, method: String, a = null, b = null, c = null) -> void:
		if method == "_apply_positions":
			last_indices = b
			last_after = c

	func add_undo_method(_obj: Object, method: String, a = null, b = null, c = null) -> void:
		if method == "_apply_positions":
			last_before = c

	func commit_action() -> void:
		pass

# ==============================================================================
# Pure conversion rules (PBSelection)
# ==============================================================================

func test_face_to_vertex_selects_the_corners():
	var md := PBMeshData.create_cube(1.0)
	var fi := _any_face(md)
	var verts := PBSelection.faces_to_vertex_ids(md, PackedInt32Array([fi]))
	assert_eq(verts.size(), 4, "A quad face converts to its 4 corner groups")

func test_face_to_edge_selects_the_perimeter():
	var md := PBMeshData.create_cube(1.0)
	var fi := _any_face(md)
	var edges := PBSelection.faces_to_edge_ids(md, PackedInt32Array([fi]))
	assert_eq(edges.size(), 4, "A quad face converts to its 4 edges")

func test_vertex_to_face_needs_full_coverage():
	var md := PBMeshData.create_cube(1.0)
	var fi := _any_face(md)
	var verts := PBSelection.faces_to_vertex_ids(md, PackedInt32Array([fi]))
	var faces := PBSelection.vertex_ids_to_faces(md, verts)
	assert_true(_same_set(faces, PackedInt32Array([fi])), "Only the face whose every corner is selected converts back")
	# Drop one corner: nothing survives (conservative rule).
	var partial := verts.duplicate()
	partial.remove_at(0)
	assert_eq(PBSelection.vertex_ids_to_faces(md, partial).size(), 0,
		"Partial corner coverage converts to nothing")

func test_vertex_to_edge_needs_both_endpoints():
	var md := PBMeshData.create_cube(1.0)
	var fi := _any_face(md)
	var verts := PBSelection.faces_to_vertex_ids(md, PackedInt32Array([fi]))
	var edges := PBSelection.vertex_ids_to_edge_ids(md, verts)
	assert_eq(edges.size(), 4, "The face's 4 edges have both endpoints selected")
	var partial := verts.duplicate()
	partial.remove_at(0)
	# Removing one corner of a quad leaves the two far edges fully covered
	# (both endpoints selected); the two edges touching the removed corner die.
	assert_eq(PBSelection.vertex_ids_to_edge_ids(md, partial).size(), 2,
		"Only edges with BOTH endpoints among the selected groups convert")

func test_edge_to_vertex_and_face():
	var md := PBMeshData.create_cube(1.0)
	var fi := _any_face(md)
	var edges := PBSelection.faces_to_edge_ids(md, PackedInt32Array([fi]))
	var verts := PBSelection.edges_to_vertex_ids(md, edges_from_ids(md, edges))
	assert_eq(verts.size(), 4, "A face's edges convert to its 4 corners")
	var faces := PBSelection.edge_ids_to_faces(md, edges)
	assert_true(_same_set(faces, PackedInt32Array([fi])), "Faces whose every edge is selected convert back from the edge set")

func test_texture_mode_shares_the_face_id_space():
	var md := PBMeshData.create_cube(1.0)
	var fi := _any_face(md)
	var faces := PackedInt32Array([fi])
	var verts := PBSelection.convert_between_modes(md, PBEditor.SelectMode.TEXTURE,
		PBEditor.SelectMode.VERTEX, PackedInt32Array(), [], faces)
	assert_true(_same_set(verts, PBSelection.faces_to_vertex_ids(md, faces)), "TEXTURE converts like FACE")
	var back := PBSelection.convert_between_modes(md, PBEditor.SelectMode.FACE,
		PBEditor.SelectMode.TEXTURE, verts, [], PackedInt32Array())
	assert_eq(back.size(), 0, "VERTEX -> TEXTURE (face space) with no full faces is empty")

func test_round_trip_face_vert_edge_face():
	var md := PBMeshData.create_cube(1.0)
	var fi := _any_face(md)
	var faces := PackedInt32Array([fi])
	var verts := PBSelection.convert_between_modes(md, PBEditor.SelectMode.FACE,
		PBEditor.SelectMode.VERTEX, PackedInt32Array(), [], faces)
	var edges := PBSelection.convert_between_modes(md, PBEditor.SelectMode.VERTEX,
		PBEditor.SelectMode.EDGE, verts, [], PackedInt32Array())
	var back := PBSelection.convert_between_modes(md, PBEditor.SelectMode.EDGE,
		PBEditor.SelectMode.FACE, PackedInt32Array(),
		edges_from_ids(md, edges), PackedInt32Array())
	assert_true(_same_set(back, faces), "face -> vert -> edge -> face lands on the original face")

func test_same_mode_conversion_is_identity():
	var md := PBMeshData.create_cube(1.0)
	var faces := PackedInt32Array([_any_face(md)])
	var out := PBSelection.convert_between_modes(md, PBEditor.SelectMode.FACE,
		PBEditor.SelectMode.FACE, PackedInt32Array(), [], faces)
	assert_true(_same_set(out, faces), "Same-mode conversion returns the ids unchanged")

func test_object_mode_target_has_no_conversion():
	var md := PBMeshData.create_cube(1.0)
	var out := PBSelection.convert_between_modes(md, PBEditor.SelectMode.FACE,
		PBEditor.SelectMode.OBJECT, PackedInt32Array(), [], PackedInt32Array([_any_face(md)]))
	assert_eq(out.size(), 0, "Converting into OBJECT mode clears")

## Array[PBEdge] helper (typed arrays cannot be built inline in assert calls).
func edges_from_ids(md: PBMeshData, ids: PackedInt32Array) -> Array[PBEdge]:
	var common := md.get_common_edges()
	var out: Array[PBEdge] = []
	for eid in ids:
		if eid >= 0 and eid < common.size():
			out.append(common[eid])
	return out

# ==============================================================================
# The seed + expansion carry (PBElementEditor)
# ==============================================================================

func test_conversion_seed_expands_element_indices():
	var s := _make_setup(PBEditor.SelectMode.VERTEX)
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	var fi := _any_face(md)
	var groups := PBSelection.faces_to_vertex_ids(md, PackedInt32Array([fi]))
	var seed := logic.seed_id_nearest_centroid(md, groups)
	assert_true(groups.has(seed), "The seed is a member of the converted set")
	logic.set_conversion_group(seed, groups)
	# Dragging the seed must move every corner of the face: element_indices
	# (the drag union source) expands through the conversion.
	var union := logic.element_indices(md, seed)
	var want := PackedInt32Array()
	for gid in groups:
		want.append_array(md.shared_vertices[gid].indices)
	assert_true(_same_set(union, want), "The seed's drag union covers the whole converted set")

func test_pivot_origin_is_the_converted_centroid():
	var s := _make_setup(PBEditor.SelectMode.VERTEX)
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	var fi := _any_face(md)
	var groups := PBSelection.faces_to_vertex_ids(md, PackedInt32Array([fi]))
	var seed := logic.seed_id_nearest_centroid(md, groups)
	logic.set_conversion_group(seed, groups)
	var xf := logic.get_subgizmo_transform(md, s["mesh"], seed)
	var sum := Vector3.ZERO
	for gid in groups:
		sum += logic.element_origin(md, gid)
	var centroid := sum / float(groups.size())
	assert_lt(xf.origin.distance_to(centroid), 0.0001,
		"The seed reports the set's centroid as its pivot (gizmo lands on center)")
	assert_gt(logic.element_origin(md, seed).distance_to(centroid), 0.0001,
		"sanity: the pivot is NOT just the seed's own corner on a quad face")

func test_drag_moves_the_whole_converted_set():
	var s := _make_setup(PBEditor.SelectMode.VERTEX)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data
	var fi := _any_face(md)
	var groups := PBSelection.faces_to_vertex_ids(md, PackedInt32Array([fi]))
	var seed := logic.seed_id_nearest_centroid(md, groups)
	logic.set_conversion_group(seed, groups)
	var corner_idxs := PackedInt32Array()
	for gid in groups:
		corner_idxs.append_array(md.shared_vertices[gid].indices)
	var before := PackedVector3Array()
	for idx in corner_idxs:
		before.append(md.positions[idx])

	var start := logic.get_subgizmo_transform(md, mesh, seed)
	# The engine composes drag motion THROUGH the subgizmo's start transform
	# (gizmo-local motion). A node-space translation of the start origin is
	# the delivery for "move along world X" — rel comes out as a pure
	# translation regardless of the element basis the start carries.
	var target := Transform3D(start.basis, start.origin + Vector3(0.5, 0, 0))
	logic.set_subgizmo_transform_with_shift(mesh, PackedInt32Array([seed]), seed,
		target, false)

	for i in range(corner_idxs.size()):
		var moved: Vector3 = md.positions[corner_idxs[i]]
		assert_lt(moved.distance_to(before[i] + Vector3(0.5, 0, 0)), 0.0001,
			"Converted corner %d moved with the seed's drag" % i)

	# ...and the UNDO payload covers every converted corner (the reverted
	# attempt's "undo only undoes that one vert" failure).
	var spy := ConversionUndoSpy.new()
	logic.undo = spy
	logic.commit_subgizmos(mesh, PackedInt32Array([seed]), false)
	assert_eq(spy.last_indices.size(), corner_idxs.size(),
		"The undo payload covers every corner position the drag moved")

func test_mirror_reports_the_full_converted_set():
	var s := _make_setup(PBEditor.SelectMode.VERTEX)
	var ed: PBEditor = s["ed"]
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	var fi := _any_face(md)
	var groups := PBSelection.faces_to_vertex_ids(md, PackedInt32Array([fi]))
	var seed := logic.seed_id_nearest_centroid(md, groups)
	logic.set_conversion_group(seed, groups)
	logic.mirror_engine_selection(ed.selection, md, PackedInt32Array([seed]))
	assert_eq(ed.selection.selected_vertex_count(), groups.size(),
		"The mirror (ops, docks, highlights) sees the whole converted set")
	for gid in groups:
		assert_true(ed.selection.is_vertex_selected(gid))

func test_mirror_prunes_the_conversion_when_the_seed_leaves():
	var s := _make_setup(PBEditor.SelectMode.VERTEX)
	var ed: PBEditor = s["ed"]
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	var fi := _any_face(md)
	var groups := PBSelection.faces_to_vertex_ids(md, PackedInt32Array([fi]))
	var seed := logic.seed_id_nearest_centroid(md, groups)
	logic.set_conversion_group(seed, groups)
	logic.mirror_engine_selection(ed.selection, md, PackedInt32Array([seed]))
	# A marquee or plain click that drops the seed: the expansion dies with it.
	var other := (seed + 1) % md.shared_vertices.size()
	logic.mirror_engine_selection(ed.selection, md, PackedInt32Array([other]))
	assert_eq(logic.selected_conversion.size(), 0,
		"A conversion dies with its seed leaving the engine selection")
	assert_eq(ed.selection.selected_vertex_count(), 1)

func test_plain_reclick_of_the_seed_drops_the_expansion():
	var s := _make_setup(PBEditor.SelectMode.EDGE)
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	var fi := _any_face(md)
	var edge_ids := PBSelection.faces_to_edge_ids(md, PackedInt32Array([fi]))
	var seed := logic.seed_id_nearest_centroid(md, edge_ids)
	logic.set_conversion_group(seed, edge_ids)
	logic.record_edge_click(md, seed, false)
	assert_eq(logic.selected_conversion.size(), 0,
		"A plain click on the seed re-selects just that edge")

func test_reset_side_faces_clears_the_conversion():
	var s := _make_setup(PBEditor.SelectMode.VERTEX)
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	var fi := _any_face(md)
	var groups := PBSelection.faces_to_vertex_ids(md, PackedInt32Array([fi]))
	logic.set_conversion_group(logic.seed_id_nearest_centroid(md, groups), groups)
	logic.reset_side_faces()
	assert_eq(logic.selected_conversion.size(), 0,
		"Mode switches / post-op resets clear the conversion with the side faces")

func test_edge_mode_expands_loops_and_conversions_together():
	var s := _make_setup(PBEditor.SelectMode.EDGE)
	var logic: PBElementEditor = s["logic"]
	var md: PBMeshData = s["mesh"].pb_mesh_data
	# Subdivide everything: mid-edge vertices are 4-valence, so loops exist.
	var all := PackedInt32Array()
	for i in range(md.faces.size()):
		all.append(i)
	PBMeshOps.subdivide_faces(md, all)
	# A conversion group on one edge...
	var fi := _any_face(md)
	var conv_ids := PBSelection.faces_to_edge_ids(md, PackedInt32Array([fi]))
	var conv_seed := logic.seed_id_nearest_centroid(md, conv_ids)
	logic.set_conversion_group(conv_seed, conv_ids)
	# ...and a loop on another edge.
	var loop_seed := -1
	for i in range(md.get_common_edges().size()):
		if i != conv_seed and logic.edge_loop_ids(md, i).size() > 2:
			loop_seed = i
			break
	assert_gt(loop_seed, -1, "the grid cube has a loopable edge")
	var loop := logic.edge_loop_ids(md, loop_seed)
	loop = logic.record_edge_click(md, loop_seed, true)

	var expanded := logic.expand_edge_ids(md, PackedInt32Array([conv_seed, loop_seed]))
	# The two expansions union (order aside), overlapping where they share edges.
	var want := {}
	for eid in conv_ids:
		want[eid] = true
	for eid in loop:
		want[eid] = true
	assert_eq(expanded.size(), want.size(),
		"A conversion seed and a loop seed expand independently and union")
	for eid in want.keys():
		assert_true(expanded.has(eid))

func test_conversion_survives_a_drag():
	var s := _make_setup(PBEditor.SelectMode.VERTEX)
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data
	var fi := _any_face(md)
	var groups := PBSelection.faces_to_vertex_ids(md, PackedInt32Array([fi]))
	var seed := logic.seed_id_nearest_centroid(md, groups)
	logic.set_conversion_group(seed, groups)
	var start := logic.get_subgizmo_transform(md, mesh, seed)
	logic.set_subgizmo_transform_with_shift(mesh, PackedInt32Array([seed]), seed,
		start * Transform3D(Basis.IDENTITY, Vector3(0.25, 0, 0)), false)
	logic.commit_subgizmos(mesh, PackedInt32Array([seed]), false)
	assert_eq(logic.selected_conversion.size(), 1,
		"The conversion expansion survives its drag (selection stays selectable)")
