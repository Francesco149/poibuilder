## Tests for PBMeshOps.bevel_edges (Bevel & Chamfer modeling operations).
##
## Covers:
## - Single-edge chamfer (1 segment) on a cube.
## - Edge loop chamfer (4 perimeter edges of a face).
## - Full cube bevel (all 12 edges) producing a truncated cube (26 faces).
## - Multi-segment circular arc fillets (segments = 2, 3, 4).
## - Face-mode perimeter beveling via face_perimeter_common_edge_ids.
## - Distance clamping on excessive amounts.
## - Boundary edge rejection (cannot bevel open edges).
## - Watertightness (edge_usage_counts == 2 everywhere) and compiled ArrayMesh conventions.
## - Full undo/redo via CmdMeshOp.
extends GutTest

# ==============================================================================
# Helpers
# ==============================================================================

func _cube() -> PBMeshData:
	return PBMeshData.create_cube(1.0)

func _assert_watertight(data: PBMeshData, context: String) -> void:
	var counts := PBMeshOps.edge_usage_counts(data)
	var bad: int = 0
	for key in counts:
		if counts[key] != 2:
			bad += 1
	assert_eq(bad, 0, context + ": every perimeter edge must be used by exactly 2 faces")

func _assert_compiled_convention(data: PBMeshData, convex: bool, context: String) -> void:
	var mesh: ArrayMesh = data.to_array_mesh()
	assert_true(mesh.get_surface_count() > 0, context + ": compiles to a surface")
	if mesh.get_surface_count() == 0:
		return
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var aabb := AABB(verts[0], Vector3.ZERO)
	for v in verts:
		aabb = aabb.expand(v)
	var bad_culling: int = 0
	var bad_outward: int = 0
	var tris: int = idx.size() / 3
	for t in range(tris):
		var a: int = idx[t * 3]
		var b: int = idx[t * 3 + 1]
		var c: int = idx[t * 3 + 2]
		var cross: Vector3 = (verts[b] - verts[a]).cross(verts[c] - verts[a])
		if cross.length_squared() < 0.000000001:
			continue
		if norms[a].dot(cross.normalized()) > 0.0:
			bad_culling += 1
		if convex:
			var face_center: Vector3 = (verts[a] + verts[b] + verts[c]) / 3.0
			if norms[a].dot(face_center - aabb.get_center()) <= 0.0:
				bad_outward += 1
	assert_eq(bad_culling, 0, context + ": CW front faces cull inward (Godot convention)")
	if convex:
		assert_eq(bad_outward, 0, context + ": normals point outward from convex hull")

# ==============================================================================
# Unit Tests
# ==============================================================================

func test_bevel_single_edge_chamfer():
	var cube := _cube()
	# Bevel edge 0 with amount 0.2, 1 segment (chamfer)
	var res := PBMeshOps.bevel_edges(cube, PackedInt32Array([0]), 0.2, 1)
	assert_true(res.get("ok", false), "Beveling single edge should succeed")
	assert_eq(cube.faces.size(), 7, "Single edge bevel on cube adds 1 bridge face (6 -> 7 faces)")
	_assert_watertight(cube, "Single edge chamfer")
	_assert_compiled_convention(cube, true, "Single edge chamfer")

func test_bevel_four_top_edges_loop():
	var cube := _cube()
	# Face 4 is top (+Y) in PBMeshData.create_cube
	var top_edge_ids := PBMeshOps.face_perimeter_common_edge_ids(cube, PackedInt32Array([4]))
	assert_eq(top_edge_ids.size(), 4, "Top face should have 4 perimeter common edges")

	var res := PBMeshOps.bevel_edges(cube, top_edge_ids, 0.2, 1)
	assert_true(res.get("ok", false), "Beveling 4 top edges should succeed")
	# Top face shrunk + bottom face untouched + 4 sides + 4 bevel quads = 10 faces
	assert_eq(cube.faces.size(), 10, "Top 4 edges bevel on cube produces 10 faces")
	_assert_watertight(cube, "Top 4 edges chamfer")
	_assert_compiled_convention(cube, true, "Top 4 edges chamfer")

func test_bevel_all_twelve_edges_chamfer():
	var cube := _cube()
	var all_edges := PackedInt32Array()
	for i in range(cube.get_common_edges().size()):
		all_edges.append(i)
	assert_eq(all_edges.size(), 12, "Cube has 12 common edges")

	var res := PBMeshOps.bevel_edges(cube, all_edges, 0.2, 1)
	assert_true(res.get("ok", false), "Beveling all 12 edges should succeed")
	# Truncated cube: 6 octagons + 12 bevel quads + 8 corner triangles = 26 faces
	assert_eq(cube.faces.size(), 26, "Beveled cube (all 12 edges) has exactly 26 faces")
	_assert_watertight(cube, "Truncated cube 12 edges")
	_assert_compiled_convention(cube, true, "Truncated cube 12 edges")

func test_bevel_multi_segment_two():
	var cube := _cube()
	var all_edges := PackedInt32Array()
	for i in range(cube.get_common_edges().size()):
		all_edges.append(i)

	var res := PBMeshOps.bevel_edges(cube, all_edges, 0.2, 2)
	assert_true(res.get("ok", false), "Multi-segment bevel (seg=2) should succeed")
	# 6 octagons + 12 * 2 quads + 8 corner caps = 38 faces
	assert_eq(cube.faces.size(), 38, "Beveled cube with 2 segments produces 38 faces")
	_assert_watertight(cube, "Beveled cube 2 segments")
	_assert_compiled_convention(cube, true, "Beveled cube 2 segments")

func test_bevel_multi_segment_three_and_four():
	var cube3 := _cube()
	var all_edges := PackedInt32Array()
	for i in range(cube3.get_common_edges().size()):
		all_edges.append(i)

	var res3 := PBMeshOps.bevel_edges(cube3, all_edges, 0.2, 3)
	assert_true(res3.get("ok", false), "Multi-segment bevel (seg=3) should succeed")
	assert_eq(cube3.faces.size(), 50, "Beveled cube with 3 segments produces 50 faces")
	_assert_watertight(cube3, "Beveled cube 3 segments")

	var cube4 := _cube()
	var res4 := PBMeshOps.bevel_edges(cube4, all_edges, 0.2, 4)
	assert_true(res4.get("ok", false), "Multi-segment bevel (seg=4) should succeed")
	assert_eq(cube4.faces.size(), 62, "Beveled cube with 4 segments produces 62 faces")
	_assert_watertight(cube4, "Beveled cube 4 segments")
	_assert_compiled_convention(cube4, true, "Beveled cube 4 segments")

func test_bevel_face_mode_perimeter():
	var cube := _cube()
	var face_ids := PackedInt32Array([4]) # Top face
	var edge_ids := PBMeshOps.face_perimeter_common_edge_ids(cube, face_ids)
	assert_eq(edge_ids.size(), 4, "face_perimeter_common_edge_ids must find all 4 perimeter edges")

	var res := PBMeshOps.bevel_edges(cube, edge_ids, 0.15, 1)
	assert_true(res.get("ok", false), "Beveling face perimeter edges should succeed")
	assert_eq(cube.faces.size(), 10, "Beveled face perimeter produces 10 faces")
	_assert_watertight(cube, "Face mode perimeter bevel")

func test_bevel_distance_clamping_excessive_amount():
	var cube := _cube()
	# Passing 100.0 meters on a 1.0m cube must clamp safely without crashing or inverting
	var res := PBMeshOps.bevel_edges(cube, PackedInt32Array([0]), 100.0, 1)
	assert_true(res.get("ok", false), "Excessive amount should clamp safely and succeed")
	_assert_watertight(cube, "Clamped excessive bevel amount")

func test_bevel_rejects_empty_selection():
	var cube := _cube()
	var res := PBMeshOps.bevel_edges(cube, PackedInt32Array(), 0.2, 1)
	assert_false(res.get("ok", true), "Empty selection should fail cleanly")
	assert_true(res.get("error", "").contains("no edges selected"), "Error message explains failure")

func test_bevel_rejects_open_boundary_edge():
	# Create a single plane quad (4 boundary edges, each with only 1 incident face)
	var data := PBMeshData.new()
	data.positions = PackedVector3Array([
		Vector3(-1, 0, -1), Vector3(1, 0, -1),
		Vector3(1, 0, 1), Vector3(-1, 0, 1)
	])
	data.faces = [PBFace.new(PackedInt32Array([0, 1, 2, 2, 3, 0]))]
	data.rebuild_welds()

	var common := data.get_common_edges()
	var res := PBMeshOps.bevel_edges(data, PackedInt32Array([0]), 0.2, 1)
	assert_false(res.get("ok", true), "Beveling open boundary edge on single plane must fail cleanly")
	assert_true(res.get("error", "").contains("boundary"), "Error message explains open boundary rejection")

func test_bevel_undo_redo():
	var cube := _cube()
	var mesh := PBMesh.new()
	mesh.pb_mesh_data = cube
	add_child_autofree(mesh)

	var before := PBCommand.copy_mesh_data(cube)
	var cmd := CmdMeshOp.new(cube, "Bevel Edges", mesh)

	var res := PBMeshOps.bevel_edges(cube, PackedInt32Array([0]), 0.2, 1)
	assert_true(res.get("ok", false), "Bevel should succeed")
	assert_eq(cube.faces.size(), 7, "Cube now has 7 faces")

	cmd.capture_after()
	var ur := UndoRedo.new()
	cmd.add_to_undo_manager(ur)

	# Undo
	ur.undo()
	assert_eq(mesh.pb_mesh_data.faces.size(), 6, "Undo restores original 6 faces")
	_assert_watertight(mesh.pb_mesh_data, "Undo bevel")

	# Redo
	ur.redo()
	assert_eq(mesh.pb_mesh_data.faces.size(), 7, "Redo re-applies bevel with 7 faces")
	_assert_watertight(mesh.pb_mesh_data, "Redo bevel")

func test_bevel_single_edge_multi_segment_three():
	# Regression test for Issue 1: Bevel 1 edge with segments = 3 must not leave open holes on end faces
	var cube := _cube()
	var res := PBMeshOps.bevel_edges(cube, PackedInt32Array([0]), 0.2, 3)
	assert_true(res.get("ok", false), "Single edge bevel with segments=3 should succeed")
	assert_eq(cube.faces.size(), 9, "Single edge bevel with 3 segments produces 9 faces (6 - 1 + 3 bridge + 1)")
	_assert_watertight(cube, "Single edge 3-segment fillet")
	_assert_compiled_convention(cube, true, "Single edge 3-segment fillet")

func test_bevel_twice_all_edges_watertight():
	# Regression test for Issue 2: Selecting all edges of a beveled cube and beveling again must stay watertight
	var cube := _cube()
	var all_edges := PackedInt32Array()
	for i in range(cube.get_common_edges().size()):
		all_edges.append(i)
	var res1 := PBMeshOps.bevel_edges(cube, all_edges, 0.15, 1)
	assert_true(res1.get("ok", false), "First bevel all edges should succeed")
	assert_eq(cube.faces.size(), 26, "First bevel produces 26 faces")
	_assert_watertight(cube, "First full bevel")

	var all_edges_2 := PackedInt32Array()
	for i in range(cube.get_common_edges().size()):
		all_edges_2.append(i)
	var res2 := PBMeshOps.bevel_edges(cube, all_edges_2, 0.04, 1)
	assert_true(res2.get("ok", false), "Second bevel all edges should succeed")
	_assert_watertight(cube, "Second full bevel")

func test_bevel_all_faces_matches_all_edges():
	# Regression test: selecting all faces of a cube must bevel all 12 edges and produce 26 faces
	var cube := _cube()
	var all_faces := PackedInt32Array([0, 1, 2, 3, 4, 5])
	var edge_ids := PBMeshOps.face_edges_common_ids(cube, all_faces)
	assert_eq(edge_ids.size(), 12, "face_edges_common_ids on all 6 cube faces must return all 12 common edges")

	var res := PBMeshOps.bevel_edges(cube, edge_ids, 0.2, 1)
	assert_true(res.get("ok", false), "Beveling all faces should succeed")
	assert_eq(cube.faces.size(), 26, "Beveling all faces produces 26 faces (identical to all edges)")
	_assert_watertight(cube, "All faces bevel")

func test_rebevel_quad_edges_without_overlap():
	# Re-beveling the 2 long edges of an already beveled edge quad must not overlap
	var cube := _cube()
	var res1 := PBMeshOps.bevel_edges(cube, PackedInt32Array([0]), 0.2, 1)
	assert_true(res1.get("ok", false), "First bevel succeeds")
	assert_eq(cube.faces.size(), 7)

	var common := cube.get_common_edges()
	var lookup := cube.get_shared_vertex_lookup()
	var bevel_quad := cube.faces[cube.faces.size() - 1]
	var b_edges := bevel_quad.get_edges()
	var rebevel_ids := PackedInt32Array()
	for eid in range(common.size()):
		var e := common[eid]
		var ca: int = lookup.get(e.a, e.a)
		var cb: int = lookup.get(e.b, e.b)
		var k := Vector2i(mini(ca, cb), maxi(ca, cb))
		for be in b_edges:
			var b_ca: int = lookup.get(be.a, be.a)
			var b_cb: int = lookup.get(be.b, be.b)
			if k == Vector2i(mini(b_ca, b_cb), maxi(b_ca, b_cb)):
				var l := cube.positions[e.a].distance_to(cube.positions[e.b])
				if l > 0.8:
					rebevel_ids.append(eid)
	assert_eq(rebevel_ids.size(), 2, "Found 2 long edges of the bevel quad")

	var res2 := PBMeshOps.bevel_edges(cube, rebevel_ids, 0.2, 1) # amount 0.2 will be clamped safely
	assert_true(res2.get("ok", false), "Re-beveling bevel quad edges should succeed")
	assert_eq(cube.faces.size(), 9, "Re-beveling 2 edges adds 2 bridge faces (7 -> 9 faces)")
	_assert_watertight(cube, "Re-beveled quad edges")

func test_bevel_faces_single_face_on_beveled_cube_watertight():
	# Regression test: beveling a single face on an already beveled cube must not tear adjacent unselected quads or corner triangles
	var cube := _cube()
	var all_edges := PackedInt32Array()
	for i in range(cube.get_common_edges().size()):
		all_edges.append(i)
	PBMeshOps.bevel_edges(cube, all_edges, 0.15, 1)
	assert_eq(cube.faces.size(), 26)

	# Find top face (normal +Y)
	var top_fi := -1
	for fi in range(cube.faces.size()):
		var f := cube.faces[fi]
		var n := PBMeshOps._face_area_normal(cube, f)
		if n.dot(Vector3.UP) > 0.8:
			top_fi = fi
			break
	assert_gt(top_fi, -1)

	var res := PBMeshOps.bevel_faces(cube, PackedInt32Array([top_fi]), 0.05, 1)
	assert_true(res.get("ok", false), "bevel_faces on single face should succeed")
	assert_eq(cube.faces.size(), 30, "Replaced 1 face with 1 inner face + 4 bridge quads (26 - 1 + 5 = 30)")
	_assert_watertight(cube, "Single face bevel on beveled cube")

func test_bevel_faces_multi_segment():
	var cube := _cube()
	var res := PBMeshOps.bevel_faces(cube, PackedInt32Array([4]), 0.15, 3) # Top face with 3 segments
	assert_true(res.get("ok", false), "bevel_faces with segments=3 should succeed")
	# 6 - 1 + 1 inner face + 4 * 3 bridge quads = 18 faces
	assert_eq(cube.faces.size(), 18, "Cube with 1 face beveled (seg=3) produces 18 faces")
	_assert_watertight(cube, "Face bevel 3 segments")


func test_bevel_inset_inward_extrusion_outer_edges():
	var cube := PBMeshData.create_cube(2.0)
	# Face 1 is back face (+Z)
	var inset_res := PBMeshOps.inset_faces(cube, PackedInt32Array([1]), 0.3)
	assert_true(inset_res["ok"], "Inset succeeds")
	var inner_face_id: int = inset_res["cap_face_ids"][0]

	var extrude_res := PBMeshOps.extrude_faces(cube, PackedInt32Array([inner_face_id]), -0.5)
	assert_true(extrude_res["ok"], "Inward extrude succeeds")

	# Find the 4 outer edges of the inward extrusion (at Z ≈ 1.0)
	var common_edges := cube.get_common_edges()
	var outer_edge_ids := PackedInt32Array()
	for eid in range(common_edges.size()):
		var e := common_edges[eid]
		var pa := cube.positions[e.a]
		var pb := cube.positions[e.b]
		if absf(pa.z - 1.0) < 0.001 and absf(pb.z - 1.0) < 0.001:
			if absf(pa.x) < 0.99 and absf(pa.y) < 0.99 and absf(pb.x) < 0.99 and absf(pb.y) < 0.99:
				outer_edge_ids.append(eid)

	assert_eq(outer_edge_ids.size(), 4, "Must find exactly 4 outer edges of inward extrusion")
	for segs in [1, 2, 3, 4]:
		var c_test := PBCommand.copy_mesh_data(cube)
		var bevel_res := PBMeshOps.bevel_edges(c_test, outer_edge_ids, 0.1, segs)
		assert_true(bevel_res.get("ok", false), "Beveling outer edges with segs=" + str(segs) + " should succeed: " + str(bevel_res.get("error", "")))
		_assert_watertight(c_test, "Inset inward extrusion outer edge bevel segs=" + str(segs))
		_assert_compiled_convention(c_test, false, "Inset inward extrusion outer edge bevel segs=" + str(segs))

func test_bevel_inset_inward_extrusion_single_rim_edge():
	var cube := PBMeshData.create_cube(2.0)
	var inset_res := PBMeshOps.inset_faces(cube, PackedInt32Array([1]), 0.3)
	var inner_fid: int = inset_res["cap_face_ids"][0]
	PBMeshOps.extrude_faces(cube, PackedInt32Array([inner_fid]), -0.5)

	var c_edges := cube.get_common_edges()
	var outer_edge_ids := PackedInt32Array()
	for eid in range(c_edges.size()):
		var e := c_edges[eid]
		var pa := cube.positions[e.a]
		var pb := cube.positions[e.b]
		if absf(pa.z - 1.0) < 0.001 and absf(pb.z - 1.0) < 0.001:
			if absf(pa.x) < 0.99 and absf(pa.y) < 0.99 and absf(pb.x) < 0.99 and absf(pb.y) < 0.99:
				outer_edge_ids.append(eid)
	for segs in [1, 2]:
		var c_single := PBCommand.copy_mesh_data(cube)
		var b_res := PBMeshOps.bevel_edges(c_single, PackedInt32Array([outer_edge_ids[0]]), 0.1, segs)
		assert_true(b_res.get("ok", false), "Beveling single rim edge with segs=" + str(segs) + " should succeed")
		_assert_watertight(c_single, "Single rim edge bevel segs=" + str(segs))
		_assert_compiled_convention(c_single, false, "Single rim edge bevel segs=" + str(segs))

	var c_single3 := PBCommand.copy_mesh_data(cube)
	var b_res3 := PBMeshOps.bevel_edges(c_single3, PackedInt32Array([outer_edge_ids[0]]), 0.1, 3)
	assert_true(b_res3.get("ok", false), "Beveling single rim edge with segs=3 should succeed")
	_assert_watertight(c_single3, "Single rim edge bevel segs=3")

func test_reproduce_user_bevel_outer_edge_loop():
	var elem_editor := PBElementEditor.new()
	var cube := PBMeshData.create_cube(2.0)
	var inset_res := PBMeshOps.inset_faces(cube, PackedInt32Array([1]), 0.3)
	assert_true(inset_res["ok"], "Inset succeeds")
	var inner_face_id: int = inset_res["cap_face_ids"][0]

	var extrude_res := PBMeshOps.extrude_faces(cube, PackedInt32Array([inner_face_id]), -0.5)
	assert_true(extrude_res["ok"], "Inward extrude succeeds")

	# Find the 4 OUTER edges of the front face (at Z ≈ 1.0, on perimeter: abs(x) > 0.99 or abs(y) > 0.99)
	var common_edges := cube.get_common_edges()
	var perimeter_4_edges := PackedInt32Array([9, 13, 14, 15])
	var c_perim := PBCommand.copy_mesh_data(cube)
	var b_perim := PBMeshOps.bevel_edges(c_perim, perimeter_4_edges, 0.1, 3)
	assert_true(b_perim.get("ok", false), "Beveling outer perimeter edges with segs=3 should succeed")
	assert_eq(c_perim.faces.size(), 26, "4 beveled edges with shared miters: 26 faces (no degenerate corner caps)")
	_assert_watertight(c_perim, "Outer perimeter edges bevel segs=3")
	_assert_compiled_convention(c_perim, false, "Outer perimeter edges bevel segs=3")

	# Verify weld groups around corner (+1, +1, +1)
	var lookup := c_perim.get_shared_vertex_lookup()
	var groups := {}
	for idx in range(c_perim.positions.size()):
		var g: int = lookup.get(idx, idx)
		if not groups.has(g):
			groups[g] = []
		groups[g].append(idx)

	# Find group near (0.981854, 0.981854, 0.96387)
	var miter_group := -1
	for g in groups:
		var pos: Vector3 = c_perim.positions[groups[g][0]]
		if pos.distance_to(Vector3(0.981854, 0.981854, 0.96387)) < 0.001:
			miter_group = g
			break
	assert_gt(miter_group, -1, "Must find miter rail vertex group")
	assert_eq(groups[miter_group].size(), 4, "Miter rail vertex must weld across both meeting bevel bridges (4 coincident positions)")

	# Test moving this vertex with CmdMoveElements — all 4 vertices must move in lockstep
	var move_delta := Vector3(0.2, 0.3, 0.1)
	var move_cmd := CmdMoveElements.new()
	var indices_to_move := PackedInt32Array()
	for idx in groups[miter_group]:
		indices_to_move.append(idx)
	move_cmd.setup(c_perim, indices_to_move, move_delta)
	move_cmd.do_it()

	var moved_pos: Vector3 = c_perim.positions[groups[miter_group][0]]
	for idx in groups[miter_group]:
		assert_eq(c_perim.positions[idx], moved_pos, "All 4 vertices in miter group must move in lockstep")
	_assert_watertight(c_perim, "After moving miter vertex: mesh must remain 100% watertight (no tears or open edges)")
