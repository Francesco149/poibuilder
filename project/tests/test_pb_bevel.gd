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

func _assert_no_ngons(data: PBMeshData, context: String) -> void:
	for fi in range(data.faces.size()):
		var n := PBMeshOps._ordered_loop(data.faces[fi]).size()
		assert_true(n <= 4, context + ": face %d has %d verts (quads/tris only)" % [fi, n])

func _unique_near(data: PBMeshData, corner: Vector3, radius: float) -> Array:
	var seen := {}
	var pts: Array = []
	for i in range(data.positions.size()):
		var p: Vector3 = data.positions[i]
		if p.distance_to(corner) > radius:
			continue
		var k := "%d,%d,%d" % [roundi(p.x * 10000.0), roundi(p.y * 10000.0), roundi(p.z * 10000.0)]
		if seen.has(k):
			continue
		seen[k] = true
		pts.append(p)
	return pts

func _loop_bevel_faces(base: int, segs: int) -> int:
	# S=1: 4 strip quads. S>1: 4 cylindrical strips + 4 corner grids of S faces.
	if segs <= 1:
		return base + 4 * segs
	return base + 8 * segs

func _assert_profile_rounded(pts: Array, context: String) -> void:
	assert_gt(pts.size(), 3, context + ": rounded profile has more than the chord's 2 ends")
	var a: Vector3 = pts[0]
	var b: Vector3 = pts[0]
	var best := -1.0
	for i in range(pts.size()):
		for j in range(i + 1, pts.size()):
			var d: float = pts[i].distance_to(pts[j])
			if d > best:
				best = d
				a = pts[i]
				b = pts[j]
	var ab: Vector3 = b - a
	assert_gt(ab.length(), 0.001, context + ": chord has length")
	var max_off := 0.0
	for p in pts:
		var t: float = (p - a).dot(ab) / ab.length_squared()
		max_off = maxf(max_off, p.distance_to(a + ab * t))
	assert_gt(max_off, 0.015, context + ": profile must bulge off the chamfer chord (offset %s)" % str(max_off))



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
	# Beveling one edge with segments = 3 must not leave open holes on the end faces.
	# 6 - 4 (the two faces of the edge + the two end faces) + 4 rebuilt + 3 bridge
	# quads + 2 corner caps = 11.
	var cube := _cube()
	var res := PBMeshOps.bevel_edges(cube, PackedInt32Array([0]), 0.2, 3)
	assert_true(res.get("ok", false), "Single edge bevel with segments=3 should succeed")
	assert_eq(cube.faces.size(), 11, "Single edge bevel with 3 segments produces 11 faces")
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
		assert_eq(c_test.faces.size(), 14 + 4 * segs, "inner-rim loop bevel segs=%d face count" % segs)
		_assert_no_ngons(c_test, "Inset inward extrusion inner-rim bevel segs=" + str(segs))
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
	# The reported bug: inset a cube face, extrude it inward, select the outer
	# edge loop of the inset and bevel it — the corner came out "not connected
	# and not even aligned": the faces either side of a beveled edge disagreed
	# about how far the edge had moved, and the corner geometry was rebuilt
	# from separately computed copies that did not line up.
	#
	# What must hold afterwards, for every segment count:
	#   - watertight and consistently wound (no duplicated or inverted surface),
	#   - every weld group can be MOVED without tearing the mesh: that is the
	#     "not connected" symptom, and it is what this test reproduces,
	#   - every face offset from a beveled edge sits the same distance in.
	var cube := PBMeshData.create_cube(2.0)
	var inset_res := PBMeshOps.inset_faces(cube, PackedInt32Array([1]), 0.3)
	assert_true(inset_res["ok"], "Inset succeeds")
	var inner_face_id: int = inset_res["cap_face_ids"][0]
	assert_true(PBMeshOps.extrude_faces(cube, PackedInt32Array([inner_face_id]), -0.5)["ok"], "Inward extrude succeeds")

	# The four outer edges of the inset ring (both ends on the face's perimeter).
	var hz := 1.0
	var outer := PackedInt32Array()
	for eid in range(cube.get_common_edges().size()):
		var e := cube.get_common_edges()[eid]
		var pa := cube.positions[e.a]
		var pb := cube.positions[e.b]
		if absf(pa.z - hz) > 0.001 or absf(pb.z - hz) > 0.001:
			continue
		var on_outer_a: bool = absf(pa.x) > 0.99 or absf(pa.y) > 0.99
		var on_outer_b: bool = absf(pb.x) > 0.99 or absf(pb.y) > 0.99
		if on_outer_a and on_outer_b:
			outer.append(eid)
	assert_eq(outer.size(), 4, "The inset's outer edge loop has 4 edges")

	for segs in [1, 2, 3, 4]:
		var c := PBCommand.copy_mesh_data(cube)
		var res := PBMeshOps.bevel_edges(c, outer, 0.1, segs)
		assert_true(res.get("ok", false), "Bevel segs=%d succeeds: %s" % [segs, str(res.get("error", ""))])
		assert_eq(c.faces.size(), _loop_bevel_faces(14, segs), "loop bevel segs=%d face count" % segs)

		_assert_no_ngons(c, "Inset outer loop bevel segs=%d" % segs)
		_assert_watertight(c, "Inset outer loop bevel segs=%d" % segs)
		assert_eq(_surface_defects(c), 0, "Inset outer loop bevel segs=%d has no inverted or degenerate faces" % segs)
		assert_eq(_tearing_groups(c), 0, "Inset outer loop bevel segs=%d: no weld group tears the mesh when moved" % segs)


func test_bevel_offsets_are_uniform_across_faces():
	# Both faces of a beveled edge must be left the SAME distance from it. The
	# old corner formula moved a corner by `amount` along the diagonal — only
	# amount*cos(45 deg) perpendicular to each edge — while the neighbouring
	# face's corner moved a full amount, so the two faces disagreed about how far
	# the edge had moved and the corner opened up.
	var cube := _cube()
	var top_edges := PBMeshOps.face_perimeter_common_edge_ids(cube, PackedInt32Array([4]))
	assert_true(PBMeshOps.bevel_edges(cube, top_edges, 0.2, 1).get("ok", false), "Top perimeter bevel succeeds")
	# The beveled top face's boundary is exactly `amount` inside the old rim.
	var top := -1
	for fi in range(cube.faces.size()):
		if PBMeshOps._face_area_normal(cube, cube.faces[fi]).normalized().dot(Vector3.UP) > 0.99:
			top = fi
			break
	assert_gt(top, -1, "the beveled cube still has its top face")
	var inset_boundary := 0
	for v in cube.faces[top].get_indexes():
		var p: Vector3 = cube.positions[v]
		assert_true(absf(p.x) <= 0.301 and absf(p.z) <= 0.301, "top face vertex %s is inset by the bevel amount" % str(p))
		if absf(absf(p.x) - 0.3) < 0.001:
			inset_boundary += 1
	assert_gt(inset_boundary, 0, "the top face's boundary sits on the offset line (0.5 - 0.2)")

func test_bevel_clamps_amount_to_what_the_geometry_allows():
	# A bevel wider than the face it runs along is not representable: the op has
	# to shrink it rather than emit crossed offsets (which used to leave
	# non-manifold junk behind).
	var cube := PBMeshData.create_cube(1.0)
	var inset_res := PBMeshOps.inset_faces(cube, PackedInt32Array([1]), 0.2)
	assert_true(PBMeshOps.extrude_faces(cube, PackedInt32Array([inset_res["cap_face_ids"][0]]), -0.4)["ok"], "extrude")
	var hz := 0.5
	var outer := PackedInt32Array()
	for eid in range(cube.get_common_edges().size()):
		var e := cube.get_common_edges()[eid]
		var pa := cube.positions[e.a]
		var pb := cube.positions[e.b]
		if absf(pa.z - hz) > 0.001 or absf(pb.z - hz) > 0.001:
			continue
		if absf(pa.x) > 0.49 or absf(pa.y) > 0.49 or absf(pb.x) > 0.49 or absf(pb.y) > 0.49:
			outer.append(eid)
	# 0.4 is far wider than the 0.2 ring: the op must still return a clean mesh.
	var res := PBMeshOps.bevel_edges(cube, outer, 0.4, 3)
	assert_true(res.get("ok", false), "An over-wide bevel still succeeds: %s" % str(res.get("error", "")))
	_assert_watertight(cube, "Over-wide bevel")
	assert_eq(_surface_defects(cube), 0, "Over-wide bevel has no inverted or degenerate faces")

func test_bevel_corners_are_quads_not_fans():
	# Multi-segment bevel is a cylindrical fillet: S quads along each edge, and
	# at a loop corner a grid of quads/tris bridging the two cylinder ends —
	# rounded, connected, no leftover n-gon.
	var cube := PBMeshData.create_cube(2.0)
	var inset_res := PBMeshOps.inset_faces(cube, PackedInt32Array([1]), 0.3)
	PBMeshOps.extrude_faces(cube, PackedInt32Array([inset_res["cap_face_ids"][0]]), -0.5)
	assert_eq(cube.faces.size(), 14, "inset + inward extrude is 14 faces")
	var outer := PackedInt32Array()
	for eid in range(cube.get_common_edges().size()):
		var e := cube.get_common_edges()[eid]
		var pa := cube.positions[e.a]
		var pb := cube.positions[e.b]
		if absf(pa.z - 1.0) > 0.001 or absf(pb.z - 1.0) > 0.001:
			continue
		if (absf(pa.x) > 0.99 or absf(pa.y) > 0.99) and (absf(pb.x) > 0.99 or absf(pb.y) > 0.99):
			outer.append(eid)
	assert_eq(outer.size(), 4)

	for segs in [2, 3, 4]:
		var c := PBCommand.copy_mesh_data(cube)
		assert_true(PBMeshOps.bevel_edges(c, outer, 0.1, segs).get("ok", false), "bevel segs=%d" % segs)
		assert_eq(c.faces.size(), _loop_bevel_faces(14, segs), "loop bevel segs=%d face count" % segs)
		_assert_no_ngons(c, "loop bevel segs=%d" % segs)
		_assert_watertight(c, "loop bevel segs=%d" % segs)
		assert_eq(_tearing_groups(c), 0, "loop bevel segs=%d: no weld group tears" % segs)
		for corner: Vector3 in [Vector3(1, 1, 1), Vector3(-1, 1, 1), Vector3(1, -1, 1), Vector3(-1, -1, 1)]:
			var pts := _unique_near(c, corner, 0.35)
			_assert_profile_rounded(pts, "corner %s segs=%d" % [str(corner), segs])


func test_bevel_sweep_all_shapes_stay_closed():
	# The sweep that found the reported corner: cube sizes, inset widths, inward
	# extrude depths, bevel distances, segment counts and both rim loops of the
	# inset cavity. Every combination must come out closed, consistently wound
	# and tear-free — one bad case is a corner that opens when a vertex is moved.
	var cases := 0
	for size in [1.0, 2.0]:
		for inset in [0.1, 0.2, 0.3]:
			for depth in [0.2, 0.5]:
				for amount in [0.05, 0.1, 0.2, 0.3]:
					for segs in [1, 2, 3]:
						for inner in [false, true]:
							cases += 1
							var cube := PBMeshData.create_cube(size)
							var inset_res := PBMeshOps.inset_faces(cube, PackedInt32Array([1]), inset)
							PBMeshOps.extrude_faces(cube, PackedInt32Array([inset_res["cap_face_ids"][0]]), -depth)
							var hz: float = float(size) * 0.5
							var ids := PackedInt32Array()
							for eid in range(cube.get_common_edges().size()):
								var e := cube.get_common_edges()[eid]
								var pa := cube.positions[e.a]
								var pb := cube.positions[e.b]
								if absf(pa.z - hz) > 0.001 or absf(pb.z - hz) > 0.001:
									continue
								var a_outer: bool = absf(pa.x) > hz - 0.01 or absf(pa.y) > hz - 0.01
								var b_outer: bool = absf(pb.x) > hz - 0.01 or absf(pb.y) > hz - 0.01
								if a_outer == inner and b_outer == inner:
									ids.append(eid)
							assert_gt(ids.size(), 0, "case %d selected edges" % cases)
							var tag: String = "s=%.1f inset=%.2f depth=%.2f amt=%.2f segs=%d %s" % [size, inset, depth, amount, segs, "inner" if inner else "outer"]
							var res := PBMeshOps.bevel_edges(cube, ids, amount, segs)
							assert_true(res.get("ok", false), "%s: %s" % [tag, str(res.get("error", ""))])
							_assert_watertight(cube, tag)
							assert_eq(_surface_defects(cube), 0, "%s: no inverted or degenerate faces" % tag)
							assert_eq(_tearing_groups(cube), 0, "%s: no weld group tears the mesh" % tag)
	assert_eq(cases, 288, "the sweep covers every combination")

## Faces whose winding disagrees with their neighbours, or that have no area.
func _surface_defects(data: PBMeshData) -> int:
	var lookup := data.get_shared_vertex_lookup()
	var dirs := {}
	var defects := 0
	for face in data.faces:
		if face == null:
			continue
		var pts := PackedVector3Array()
		for i in face.get_indexes():
			pts.append(data.positions[i])
		var area := 0.0
		for t in range(pts.size() / 3):
			area += (pts[t * 3 + 1] - pts[t * 3]).cross(pts[t * 3 + 2] - pts[t * 3]).length() * 0.5
		if area < 0.000000001:
			defects += 1
			continue
		for e in face.get_edges():
			var ca: int = lookup.get(e.a, e.a)
			var cb: int = lookup.get(e.b, e.b)
			var k := Vector2i(mini(ca, cb), maxi(ca, cb))
			if not dirs.has(k):
				dirs[k] = []
			dirs[k].append(Vector2i(ca, cb))
	for k in dirs:
		var ds: Array = dirs[k]
		if ds.size() == 1:
			defects += 1
		elif ds.size() > 2:
			defects += 1
		elif ds[0].x == ds[1].x and ds[0].y == ds[1].y:
			defects += 1
	return defects

## Moves every weld group in turn and counts the ones whose members are not all
## connected: a group that tears the mesh open when moved is exactly the
## "vertices are not connected" symptom.
func _tearing_groups(data: PBMeshData) -> int:
	var lookup := data.get_shared_vertex_lookup()
	var groups := {}
	for i in range(data.positions.size()):
		var g: int = lookup.get(i, i)
		if not groups.has(g):
			groups[g] = []
		groups[g].append(i)
	var base := _surface_defects(data)
	var delta := Vector3(0.037, -0.021, 0.013)
	var torn := 0
	for g in groups:
		var members: Array = groups[g]
		for i in members:
			data.positions[i] = data.positions[i] + delta
		var after := _surface_defects(data)
		for i in members:
			data.positions[i] = data.positions[i] - delta
		if after != base:
			torn += 1
	return torn

func test_bevel_every_ring_edge_resolves():
	# Beveling EVERY edge of the inset ring quads (outer rim + inner rim + the
	# radial edges) is the densest bevel this shape can take: three beveled edges
	# meet at each corner, two of them on faces that keep their corner. It must
	# still come out closed, consistently wound and tear-free.
	var cube := PBMeshData.create_cube(2.0)
	var inset_res := PBMeshOps.inset_faces(cube, PackedInt32Array([1]), 0.3)
	assert_true(PBMeshOps.extrude_faces(cube, PackedInt32Array([inset_res["cap_face_ids"][0]]), -0.5)["ok"], "extrude")
	var all_ring := PackedInt32Array()
	for eid in range(cube.get_common_edges().size()):
		var e := cube.get_common_edges()[eid]
		if absf(cube.positions[e.a].z - 1.0) > 0.001 or absf(cube.positions[e.b].z - 1.0) > 0.001:
			continue
		all_ring.append(eid)
	assert_eq(all_ring.size(), 12, "the ring quads carry 12 edges (4 outer, 4 radial, 4 inner)")
	for segs in [1, 2, 3]:
		var c := PBCommand.copy_mesh_data(cube)
		var res := PBMeshOps.bevel_edges(c, all_ring, 0.1, segs)
		assert_true(res.get("ok", false), "Every-ring-edge bevel segs=%d succeeds: %s" % [segs, str(res.get("error", ""))])
		_assert_watertight(c, "Every ring edge segs=%d" % segs)
		assert_eq(_surface_defects(c), 0, "Every ring edge segs=%d: no inverted or degenerate faces" % segs)
		assert_eq(_tearing_groups(c), 0, "Every ring edge segs=%d: no weld group tears the mesh" % segs)
