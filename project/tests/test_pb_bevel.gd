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


func _chamfer_width(d: PBMeshData, a: Vector3, b: Vector3) -> float:
	var dir: Vector3 = (b - a).normalized()
	var closest := 999.0
	var span: float = a.distance_to(b)
	for p in d.positions:
		var t: float = (p - a).dot(dir)
		if t < -0.01 or t > span + 0.01:
			continue
		var dist: float = p.distance_to(a + dir * t)
		if dist > 0.005 and dist < closest:
			closest = dist
	return closest

func _loop_sizes(data: PBMeshData) -> Dictionary:
	var counts := {}
	for fi in range(data.faces.size()):
		var n := PBMeshOps._ordered_loop(data.faces[fi]).size()
		counts[n] = int(counts.get(n, 0)) + 1
	return counts


func _loop_bevel_faces(base: int, segs: int) -> int:
	# Valence-2 loop corners share a straight rail: no extra corner-grid faces.
	return base + 4 * segs




# ==============================================================================
# Unit Tests
# ==============================================================================

func test_bevel_single_edge_chamfer():
	var cube := _cube()
	# Bevel edge 0 with amount 0.2, 1 segment (chamfer).
	# ProBuilder / Blender: 1 bridge quad, 2 adjacent faces stay quads, 2 end
	# faces become pentagons. No triangle fan, no split of the top face.
	var res := PBMeshOps.bevel_edges(cube, PackedInt32Array([0]), 0.2, 1)
	assert_true(res.get("ok", false), "Beveling single edge should succeed: %s" % str(res.get("error", "")))
	assert_eq(cube.faces.size(), 7, "Single edge chamfer is 6 original + 1 bridge (7), not a triangulated 11")
	var sizes := _loop_sizes(cube)
	assert_eq(int(sizes.get(3, 0)), 0, "Single-edge chamfer must not fan faces into triangles")
	assert_eq(int(sizes.get(4, 0)), 5, "5 quads: 2 adjacent + 2 untouched + 1 bridge")
	assert_eq(int(sizes.get(5, 0)), 2, "2 end faces stay pentagons")
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
	# 6 retracted octagons + 12 edges * 2 strip quads + 8 corner domes
	# (1 inset ring band of 6 quads + 1 flat inner n-gon: ring = 3 tips + 3 arcs)
	assert_eq(cube.faces.size(), 86, "Beveled cube with 2 segments produces 86 faces")

	_assert_watertight(cube, "Beveled cube 2 segments")
	_assert_compiled_convention(cube, true, "Beveled cube 2 segments")

func test_bevel_multi_segment_three_and_four():
	var cube3 := _cube()
	var all_edges := PackedInt32Array()
	for i in range(cube3.get_common_edges().size()):
		all_edges.append(i)

	var res3 := PBMeshOps.bevel_edges(cube3, all_edges, 0.2, 3)
	assert_true(res3.get("ok", false), "Multi-segment bevel (seg=3) should succeed")
	assert_eq(cube3.faces.size(), 194, "Beveled cube with 3 segments produces 194 faces (6 octagons + 36 strip quads + 8 domes: 2 bands * 9 + 1 inner n-gon)")

	_assert_watertight(cube3, "Beveled cube 3 segments")

	var cube4 := _cube()
	var res4 := PBMeshOps.bevel_edges(cube4, all_edges, 0.2, 4)
	assert_true(res4.get("ok", false), "Multi-segment bevel (seg=4) should succeed")
	assert_eq(cube4.faces.size(), 350, "Beveled cube with 4 segments produces 350 faces (6 octagons + 48 strip quads + 8 domes: 3 bands * 12 + 1 inner n-gon)")

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
	# Beveling one edge with segments = 3 must not leave open holes on the end
	# faces AND must not split the two faces of the edge into triangles.
	# 2 adjacent quads + 2 untouched + 3 bridge quads + 2 rounded end caps
	# (Blender's vertex mesh: the profile arc closed by the cut chord) = 11.
	var cube := _cube()
	var res := PBMeshOps.bevel_edges(cube, PackedInt32Array([0]), 0.2, 3)
	assert_true(res.get("ok", false), "Single edge bevel with segments=3 should succeed: %s" % str(res.get("error", "")))
	assert_eq(cube.faces.size(), 11, "Single edge bevel with 3 segments produces 11 faces, not a triangulated 27")
	var sizes := _loop_sizes(cube)
	assert_eq(int(sizes.get(3, 0)), 0, "Single-edge fillet must not fan original faces into triangles")
	assert_eq(int(sizes.get(4, 0)), 9, "9 quads: 2 adjacent + 2 untouched + 3 bridges + 2 end caps")
	assert_eq(int(sizes.get(5, 0)), 2, "2 end faces keep the cut corner as pentagons")
	_assert_watertight(cube, "Single edge 3-segment fillet")
	_assert_compiled_convention(cube, true, "Single edge 3-segment fillet")

func test_bevel_two_adjacent_edges_terminals_are_ngons():
	# Shift-selecting two edges that share a vertex must bevel BOTH. The
	# meeting corner is a quad/tri grid; the two strip ends stay n-gons
	# (ProBuilder/Blender), not a triangle fan.
	var cube := _cube()
	var common := cube.get_common_edges()
	var lookup := cube.get_shared_vertex_lookup()
	var e0 := common[0]
	var a0: int = lookup.get(e0.a, e0.a)
	var b0: int = lookup.get(e0.b, e0.b)
	var ids := PackedInt32Array([0])
	for i in range(1, common.size()):
		var e := common[i]
		var ca: int = lookup.get(e.a, e.a)
		var cb: int = lookup.get(e.b, e.b)
		if ca == a0 or ca == b0 or cb == a0 or cb == b0:
			ids.append(i)
			break
	assert_eq(ids.size(), 2, "found an adjacent edge pair")
	var res := PBMeshOps.bevel_edges(cube, ids, 0.2, 3)
	assert_true(res.get("ok", false), "two adjacent edges bevel: %s" % str(res.get("error", "")))
	assert_gt(cube.faces.size(), 9, "two edges add more faces than one")
	assert_eq(int(_loop_sizes(cube).get(3, 0)), 0, "adjacent-edge path must not fan terminals into triangles")
	_assert_watertight(cube, "two adjacent edges S=3")


func test_bevel_multi_segment_loops_round_the_corner():
	# The reported bug: beveling the inset rim loop with >1 segment produced
	# the same FLAT 45-degree chamfer as 1 segment (just subdivided). The
	# loop-corner rails are now tangent arcs in the corner plane, so the
	# corner profile must approach the original corner like a quarter-round:
	# nearest approach ~0.41*amount at the 45-degree sample versus 0.87*amount
	# for the old straight chord.
	var amt := 0.1
	for segs in [2, 3, 4]:
		var cube := PBMeshData.create_cube(2.0)
		var ir := PBMeshOps.inset_faces(cube, PackedInt32Array([4]), 0.25)
		assert_true(PBMeshOps.extrude_faces(cube, PackedInt32Array([ir["cap_face_ids"][0]]), -0.4)["ok"], "extrude")
		var corners: Array[Vector3] = []
		var ids := PackedInt32Array()
		for eid in range(cube.get_common_edges().size()):
			var e := cube.get_common_edges()[eid]
			var pa: Vector3 = cube.positions[e.a]
			var pb: Vector3 = cube.positions[e.b]
			if absf(pa.y - 1.0) < 0.001 and absf(pb.y - 1.0) < 0.001:
				var rima: bool = absf(absf(pa.x) - 1.0) < 0.001 or absf(absf(pa.z) - 1.0) < 0.001
				var rimb: bool = absf(absf(pb.x) - 1.0) < 0.001 or absf(absf(pb.z) - 1.0) < 0.001
				if not rima and not rimb:
					ids.append(eid)
					for qi in [e.a, e.b]:
						var pc: Vector3 = cube.positions[qi]
						var known := false
						for cc in corners:
							if cc.distance_to(pc) < 0.001:
								known = true
								break
						if not known:
							corners.append(pc)
		assert_eq(ids.size(), 4, "inner rim loop")
		var res := PBMeshOps.bevel_edges(cube, ids, amt, segs)
		assert_true(res.get("ok", false), "rim bevel segs=%d: %s" % [segs, str(res.get("error", ""))])
		_assert_watertight(cube, "rim bevel segs=%d" % segs)
		assert_eq(_tearing_groups(cube), 0, "rim bevel segs=%d: shared corner rails stay welded" % segs)
		var nearest := 999.0
		for cc in corners:
			for p in cube.positions:
				var d: float = p.distance_to(cc)
				if d > 0.0005:
					nearest = minf(nearest, d)
		assert_true(nearest < amt * 0.75,
			"segs=%d corner profile rounds toward the corner (nearest %.4f < %.4f; straight chord would be %.4f)"
			% [segs, nearest, amt * 0.75, amt * 0.866])
		assert_true(nearest > amt * 0.3, "segs=%d profile must not collapse onto the corner (%.4f)" % [segs, nearest])


func test_bevel_single_edge_strips_span_the_true_edge():
	# Regression: the rail arcs were once computed in a garbage plane because
	# the edge direction was read from weld-group ids as if they were position
	# indexes. With the true edge direction the strip profile points of one
	# edge end lie in that end's cap plane (perpendicular to the edge through
	# the corner) — every new position near an end but off the two adjacent
	# faces is an arc point and must sit in that plane.
	var cube := _cube()
	var e := cube.get_common_edges()[0]
	var a: Vector3 = cube.positions[e.a]
	var b: Vector3 = cube.positions[e.b]
	var dir := (b - a).normalized()
	var res := PBMeshOps.bevel_edges(cube, PackedInt32Array([0]), 0.2, 4)
	assert_true(res.get("ok", false), "single edge segs=4: %s" % str(res.get("error", "")))
	_assert_watertight(cube, "single edge segs=4")
	_assert_compiled_convention(cube, true, "single edge segs=4")
	for end_pos: Vector3 in [a, b]:
		for p in cube.positions:
			if p.distance_to(end_pos) > 0.35:
				continue
			var local := p - end_pos
			var along := local.dot(dir)
			# slid corners ride ALONG the perimeter edges; arc points must sit
			# within the cap plane (no drift along the edge beyond a slide).
			var perp := local - dir * along
			var near_arc := along < 0.001 and perp.length() > 0.001
			if near_arc:
				assert_true(absf(along) < 0.0005,
					"arc point %s drifts %.5f along the edge from the cap plane at %s" % [str(p), along, str(end_pos)])


func test_bevel_vertical_strip_uvs_do_not_stretch():
	# The reported bug: beveling a VERTICAL cube edge produced a stretched
	# checkerboard — the band's transverse UV gradient cancelled because both
	# walls' phases coincide at the corner. The strip must instead unfold the
	# band at true texel density (transverse span ~= the rail-to-rail chord)
	# and keep phase continuity with its anchor wall along the shared rail.
	var cube := _cube()
	var vid := -1
	for eid in range(cube.get_common_edges().size()):
		var e := cube.get_common_edges()[eid]
		var a: Vector3 = cube.positions[e.a]
		var b: Vector3 = cube.positions[e.b]
		if absf(absf(a.x) - 0.5) < 0.001 and absf(absf(a.z) - 0.5) < 0.001 \
				and absf(a.y - b.y) > 0.1:
			vid = eid
			break
	assert_gt(vid, -1, "found a vertical cube edge")
	var amt := 0.2
	var res := PBMeshOps.bevel_edges(cube, PackedInt32Array([vid]), amt, 2)
	assert_true(res.get("ok", false), "vertical edge bevel: %s" % str(res.get("error", "")))

	var walls: Array = []
	for fid in res.get("new_face_ids", PackedInt32Array()):
		if not cube.faces[fid].manual_uv:
			walls.append(cube.faces[fid])
	# The band's segment quads share one continuous mapping: measure the
	# transverse span and the wall matches over ALL strip corners together.
	var u_min := INF
	var u_max := -INF
	var rail_matches := 0
	for sid in range(cube.faces.size()):
		if not cube.faces[sid].manual_uv:
			continue
		for idx in cube.faces[sid].get_distinct_indexes():
			var uv: Vector2 = cube.textures0[idx]
			u_min = minf(u_min, uv.x)
			u_max = maxf(u_max, uv.x)
			var p: Vector3 = cube.positions[idx]
			for w in walls:
				var want: Dictionary = PBUv.calculate_face_uvs(cube, w)
				for idx2 in want:
					if cube.positions[idx2].distance_to(p) < 0.000001:
						if uv.distance_to(want[idx2]) < 0.0005:
							rail_matches += 1
						break
	var chord: float = amt * sqrt(2.0)   # rail-to-rail distance across the band
	var u_span := u_max - u_min
	assert_true(absf(u_span - chord) < 0.02,
		"band transverse span %.4f matches the chord %.4f (no stretch/cancellation)" % [u_span, chord])
	assert_gt(rail_matches, 1, "band stays phase-true with its anchor wall (%d corners)" % rail_matches)


func test_bevel_corner_dome_lies_on_the_fillet_sphere():
	# The corner dome must follow the fillet sphere the edge strips are
	# tangent to (Blender's vertex mesh blends its edge profiles onto that
	# sphere): every dome position strictly inside the retracted face planes
	# sits (within tolerance) at the sphere radius from the sphere centre,
	# which rests sqrt(3)*amount down the corner diagonal.
	var amt := 0.2
	var cube := _cube()
	var all_edges := PackedInt32Array()
	for i in range(cube.get_common_edges().size()):
		all_edges.append(i)
	var res := PBMeshOps.bevel_edges(cube, all_edges, amt, 4)
	assert_true(res.get("ok", false), "bevel succeeds: %s" % str(res.get("error", "")))
	var plane := 0.5 - amt   # retracted face planes
	var checked := 0
	for corner: Vector3 in [Vector3(0.5, 0.5, 0.5), Vector3(-0.5, 0.5, 0.5),
			Vector3(0.5, -0.5, 0.5), Vector3(0.5, 0.5, -0.5), Vector3(-0.5, -0.5, 0.5),
			Vector3(-0.5, 0.5, -0.5), Vector3(0.5, -0.5, -0.5), Vector3(-0.5, -0.5, -0.5)]:
		var centre: Vector3 = corner - corner.normalized() * sqrt(3.0) * amt
		for p in cube.positions:
			if p.distance_to(corner) > 0.5:
				continue
			# interior dome points only: strictly inside every retracted plane
			if absf(p.x) < plane + 0.001 or absf(p.y) < plane + 0.001 or absf(p.z) < plane + 0.001:
				continue
			var dev: float = absf(p.distance_to(centre) - amt)
			assert_true(dev < 0.02,
				"dome point %s deviates %.4f from the fillet sphere at %s" % [str(p), dev, str(centre)])
			checked += 1
	assert_gt(checked, 0, "found interior dome points to check")


func test_bevel_smooth_shades_the_fillet():
	# Strips and domes share ONE fresh smoothing group (the fillet shades
	# continuously within itself, across seam rails and dome bands alike);
	# the rebuilt adjacent faces keep group 0 so the fillet creases sharply
	# where it meets the untouched flat surface. The smoothed normals must
	# differ from flat at the smooth/shared welds.
	var cube := _cube()
	var all := PackedInt32Array()
	for i in range(cube.get_common_edges().size()):
		all.append(i)
	var res := PBMeshOps.bevel_edges(cube, all, 0.2, 3)
	assert_true(res.get("ok", false), "bevel succeeds: %s" % str(res.get("error", "")))
	var groups := {}
	var smooth_count := 0
	for face in cube.faces:
		if face.smoothing_group != 0:
			groups[face.smoothing_group] = true
			smooth_count += 1
	assert_eq(groups.size(), 1, "all smooth faces share one smoothing group")
	assert_gt(smooth_count, 19, "12 strips + 8 domes wear the group")

	# duplicate(): invalidate_caches() clears the shared packed buffer
	var smoothed := cube.calculate_normals().duplicate()
	for face in cube.faces:
		face.smoothing_group = 0
	cube.invalidate_caches()
	var flat := cube.calculate_normals()
	var changed := 0
	for i in range(smoothed.size()):
		if smoothed[i].distance_to(flat[i]) > 0.001:
			changed += 1
	assert_gt(changed, 0, "smoothing changed the normals at fillet welds")


func test_bevel_strip_uvs_continue_the_adjacent_face():
	# The reported bug: a single-edge bevel smeared the texture across the
	# strip. Strips now carry the anchor face's own auto mapping continued
	# across the band: at the rail shared with the anchor face the strip's UVs
	# must EQUAL that face's rendered UVs at the same 3D corners, and each
	# further strip segment must equal its neighbour strip across their shared
	# rail — the texture runs unbroken from the anchor face across the band.
	# Strips are manual so later auto refreshes keep the continuation.
	var cube := _cube()
	var res := PBMeshOps.bevel_edges(cube, PackedInt32Array([0]), 0.3, 2)
	assert_true(res.get("ok", false), "bevel succeeds: %s" % str(res.get("error", "")))

	# auto faces: stored UVs must match their own projection (the op writes
	# them; direct textures0 consumers never see stale corner copies)
	for fid: int in res.get("new_face_ids", PackedInt32Array()):
		var f := cube.faces[fid]
		if f.manual_uv:
			continue
		var want: Dictionary = PBUv.calculate_face_uvs(cube, f)
		for idx in want:
			assert_true(cube.textures0[idx].distance_to(want[idx]) < 0.001,
				"face %d carries its own auto-projection UVs" % fid)

	# count UV-matching shared corners between every strip and every other
	# face (auto or strip): the band must connect to the anchor face and stay
	# connected across its own segments through seamless rails. Auto faces are
	# compared via their projection (== stored); strips via their STORED UVs
	# (calculate_face_uvs would recompute, losing the continuation).
	var strips: Array = []
	for fid in range(cube.faces.size()):
		if cube.faces[fid].manual_uv:
			strips.append(fid)
	assert_gt(strips.size(), 0, "the bevel has strip faces with continued UVs")
	for sid: int in strips:
		var strip := cube.faces[sid]
		var best_matches := 0
		for fid2 in range(cube.faces.size()):
			if fid2 == sid:
				continue
			var other := cube.faces[fid2]
			var want: Dictionary = PBUv.calculate_face_uvs(cube, other)
			if other.manual_uv:
				want = {}
				for idx2 in other.get_distinct_indexes():
					want[idx2] = cube.textures0[idx2]
			var matches := 0
			for idx in strip.get_distinct_indexes():
				var p: Vector3 = cube.positions[idx]
				for idx2 in want:
					if cube.positions[idx2].distance_to(p) < 0.000001 \
							and cube.textures0[idx].distance_to(want[idx2]) < 0.0005:
						matches += 1
						break
			best_matches = maxi(best_matches, matches)
		assert_true(best_matches >= 2,
			"strip %d connects seamlessly to its neighbour (best %d shared corners match)" % [sid, best_matches])


func test_bevel_rejects_knife_cut_splice_corner_cleanly():
	# KNOWN LIMITATION: a closed knife cut splices the inner loop into the
	# outer face through a zero-width slit that passes through a cut corner;
	# coincident-weld topology makes that corner visited TWICE by one face,
	# which the slide bevel cannot traverse. It must fail with an explanation
	# and roll back completely (no junk mesh), not tear.
	var cube := PBMeshData.create_cube(2.0)
	var top_fi := -1
	for fi in range(cube.faces.size()):
		if PBMeshOps._face_area_normal(cube, cube.faces[fi]).normalized().dot(Vector3.UP) > 0.9:
			top_fi = fi
			break
	var sq := PackedVector3Array([
		Vector3(-0.5, 1.001, -0.5), Vector3(0.5, 1.001, -0.5),
		Vector3(0.5, 1.001, 0.5), Vector3(-0.5, 1.001, 0.5),
		Vector3(-0.5, 1.001, -0.5),
	])
	var cut := PBMeshOps.cut_face(cube, top_fi, sq, true)
	assert_true(cut.get("ok", false), "knife cut succeeds")
	var inner := -1
	for fi in range(cube.faces.size()):
		var loop := PBMeshOps._ordered_loop(cube.faces[fi])
		if loop.size() < 4:
			continue
		var allnear := true
		for idx in loop:
			var p: Vector3 = cube.positions[idx]
			if not (absf(p.x) <= 0.501 and absf(p.z) <= 0.501 and absf(p.y - 1.0) < 0.001):
				allnear = false
				break
		if allnear:
			inner = fi
	assert_gt(inner, -1, "cut inner face found")
	assert_true(PBMeshOps.extrude_faces(cube, PackedInt32Array([inner]), -0.4)["ok"], "extrude succeeds")
	var rim := PackedInt32Array()
	for eid in range(cube.get_common_edges().size()):
		var e := cube.get_common_edges()[eid]
		var pa: Vector3 = cube.positions[e.a]
		var pb: Vector3 = cube.positions[e.b]
		if absf(pa.y - 1.0) < 0.001 and absf(pb.y - 1.0) < 0.001 \
				and absf(pa.x) < 0.51 and absf(pb.x) < 0.51 \
				and absf(pa.z) < 0.51 and absf(pb.z) < 0.51:
			rim.append(eid)
	assert_eq(rim.size(), 4, "rim loop found")
	var before := cube.faces.size()
	var res := PBMeshOps.bevel_edges(cube, rim, 0.1, 1)
	assert_false(res.get("ok", true), "the splice-slit corner cannot be beveled yet")
	assert_true(str(res.get("error", "")).contains("same corner twice"),
		"the error names the self-touching face: %s" % str(res.get("error", "")))
	assert_eq(cube.faces.size(), before, "the refused bevel rolled back")


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
	var first_sizes := _loop_sizes(cube)
	assert_eq(int(first_sizes.get(5, 0)), 2, "First single-edge chamfer keeps 2 pentagons")
	assert_eq(int(first_sizes.get(3, 0)), 0, "First single-edge chamfer has no triangles")
	var common := cube.get_common_edges()
	var lookup := cube.get_shared_vertex_lookup()
	var rebevel_ids := PackedInt32Array()
	for fi in range(cube.faces.size()):
		var loop := PBMeshOps._ordered_loop(cube.faces[fi])
		if loop.size() != 4:
			continue
		var b_edges := cube.faces[fi].get_edges()
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
					if l > 0.8 and rebevel_ids.find(eid) < 0:
						rebevel_ids.append(eid)
		if rebevel_ids.size() >= 2:
			break
	assert_gt(rebevel_ids.size(), 1, "Found long edges to re-bevel")

	if rebevel_ids.size() > 2:
		rebevel_ids = PackedInt32Array([rebevel_ids[0], rebevel_ids[1]])

	var res2 := PBMeshOps.bevel_edges(cube, rebevel_ids, 0.2, 1)
	assert_true(res2.get("ok", false), "Re-beveling bevel quad edges should succeed")
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
	assert_eq(cube.faces.size(), 34, "Octagon top face: 8 boundary strips, 26 - 1 + 1 + 8 = 34")
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
	# Chamfer (S=1) of a 4-valence rim end. If the termination is not
	# representable at this amount, refuse and roll back rather than shrink.
	var c_single := PBCommand.copy_mesh_data(cube)
	var before_n := c_single.faces.size()
	var b_res := PBMeshOps.bevel_edges(c_single, PackedInt32Array([outer_edge_ids[0]]), 0.1, 1)
	if b_res.get("ok", false):
		_assert_watertight(c_single, "Single rim edge bevel segs=1")
	else:
		assert_eq(c_single.faces.size(), before_n, "refused single-rim bevel must roll back")


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
	# 0.4 is far wider than the 0.2 ring. Clamp-and-succeed if possible;
	# otherwise refuse and roll back. Either way: no crossed junk.
	var before_faces := cube.faces.size()
	var res := PBMeshOps.bevel_edges(cube, outer, 0.4, 1)
	if res.get("ok", false):
		_assert_watertight(cube, "Over-wide bevel")
		assert_eq(_surface_defects(cube), 0, "Over-wide bevel has no inverted or degenerate faces")
	else:
		assert_eq(cube.faces.size(), before_faces, "refused over-wide bevel must roll back")
		_assert_watertight(cube, "Over-wide bevel rollback")

func test_bevel_corners_are_quads_not_fans():
	# Multi-segment loop: S quads along each edge, straight rail at valence-2
	# corners (no cylindrical bump, no leftover n-gon).
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
	for segs in [1, 2]:
		var c := PBCommand.copy_mesh_data(cube)
		var res := PBMeshOps.bevel_edges(c, all_ring, 0.1, segs)
		assert_true(res.get("ok", false), "Every-ring-edge bevel segs=%d succeeds: %s" % [segs, str(res.get("error", ""))])
		_assert_watertight(c, "Every ring edge segs=%d" % segs)
		assert_eq(_surface_defects(c), 0, "Every ring edge segs=%d: no inverted or degenerate faces" % segs)
		assert_eq(_tearing_groups(c), 0, "Every ring edge segs=%d: no weld group tears the mesh" % segs)


func test_bevel_requested_distance_is_the_chamfer_width():
	# 0.10 / 0.11 / 0.12 used to ping-pong between a ~0.02 retry leftover and
	# the real amount. The chamfer width must track the request.
	for amt in [0.10, 0.11, 0.12, 0.20]:
		var cube := _cube()
		var e := cube.get_common_edges()[0]
		var a: Vector3 = cube.positions[e.a]
		var b: Vector3 = cube.positions[e.b]
		var res := PBMeshOps.bevel_edges(cube, PackedInt32Array([0]), amt, 1)
		assert_true(res.get("ok", false), "amt=%.2f should succeed: %s" % [amt, str(res.get("error", ""))])
		var w := _chamfer_width(cube, a, b)
		assert_true(absf(w - amt) < amt * 0.08, "amt=%.2f produced width %.4f" % [amt, w])


func test_bevel_inset_inner_loop_honors_amount():
	# Inset+inward-extrude, then bevel the hole's top loop at 0.1. The 0.38×
	# shortest-incident clamp used to shrink that to ~0.067 (and fail with
	# folded seams on some amounts). A 0.18 m radial has room for 0.1.
	var cube := PBMeshData.create_cube(1.0)
	var ir := PBMeshOps.inset_faces(cube, PackedInt32Array([4]), 0.25)
	assert_true(PBMeshOps.extrude_faces(cube, PackedInt32Array([ir["cap_face_ids"][0]]), -0.4)["ok"], "extrude")
	var hy := -999.0
	for p in cube.positions:
		hy = maxf(hy, p.y)
	var aabb := AABB(cube.positions[0], Vector3.ZERO)
	for p in cube.positions:
		aabb = aabb.expand(p)
	var inner := PackedInt32Array()
	for eid in range(cube.get_common_edges().size()):
		var e := cube.get_common_edges()[eid]
		var pa: Vector3 = cube.positions[e.a]
		var pb: Vector3 = cube.positions[e.b]
		if absf(pa.y - hy) > 0.02 or absf(pb.y - hy) > 0.02:
			continue
		var pa_rim := absf(pa.x - aabb.position.x) < 0.02 or absf(pa.x - aabb.end.x) < 0.02 \
			or absf(pa.z - aabb.position.z) < 0.02 or absf(pa.z - aabb.end.z) < 0.02
		var pb_rim := absf(pb.x - aabb.position.x) < 0.02 or absf(pb.x - aabb.end.x) < 0.02 \
			or absf(pb.z - aabb.position.z) < 0.02 or absf(pb.z - aabb.end.z) < 0.02
		if pa_rim or pb_rim:
			continue
		inner.append(eid)
	assert_eq(inner.size(), 4, "inner hole loop")
	var seed := cube.get_common_edges()[inner[0]]
	var sa: Vector3 = cube.positions[seed.a]
	var sb: Vector3 = cube.positions[seed.b]
	for segs in [1, 2, 3]:
		var c := PBCommand.copy_mesh_data(cube)
		var res := PBMeshOps.bevel_edges(c, inner, 0.1, segs)
		assert_true(res.get("ok", false), "inner loop S=%d 0.1: %s" % [segs, str(res.get("error", ""))])
		_assert_watertight(c, "inner loop S=%d" % segs)
		var w := _chamfer_width(c, sa, sb)
		# The requested distance must be honored (not the old 0.067 clamp):
		# a 1-segment chamfer's surface keeps its full distance from the old
		# edge; a rounded multi-segment profile dips to the quarter-circle
		# tangent point ((sqrt(2)-1) * amount at the closest sample) — both
		# prove the rails were NOT shrunk, which is what this guards.
		if segs == 1:
			assert_true(w > 0.09, "inner loop S=1 width %.4f should be ~0.1 not the old 0.06 clamp" % w)
		else:
			assert_true(w > 0.035, "inner loop S=%d width %.4f should stay near the quarter-round minimum 0.041" % [segs, w])


func test_bevel_repeated_restore_rebevel_never_sticks():
	# The reported stuck state: cancelling a bevel modal (snapshot restore)
	# left the mesh in a state where every later bevel failed with
	# "the corner at (...) collapsed". Restore + re-bevel must succeed
	# indefinitely, at any amount and segment count.
	var cube := PBMeshData.create_cube(1.0)
	for i in range(6):
		var snapshot := PBCommand.copy_mesh_data(cube)
		var res := PBMeshOps.bevel_edges(cube, PackedInt32Array([0]), 0.08 + 0.03 * (i % 4), 1 + (i % 3))
		assert_true(res.get("ok", false), "bevel %d should succeed: %s" % [i, str(res.get("error", ""))])
		_assert_watertight(cube, "bevel %d" % i)
		PBCommand.restore_mesh_data(cube, snapshot)


func test_bevel_width_grows_monotonically_with_the_request():
	# The drag ping-pong: widths must grow with the request — the op clamps,
	# it never refuses an amount the slider can reach, and it never lands on
	# a leftover retry size.
	var cube := PBMeshData.create_cube(1.0)
	var ir := PBMeshOps.inset_faces(cube, PackedInt32Array([4]), 0.25)
	PBMeshOps.extrude_faces(cube, PackedInt32Array([ir["cap_face_ids"][0]]), -0.4)
	var seed := cube.get_common_edges()[0]
	var a: Vector3 = cube.positions[seed.a]
	var b: Vector3 = cube.positions[seed.b]
	var last_w := -1.0
	for amt in [0.02, 0.04, 0.06, 0.08, 0.1, 0.15, 0.2, 0.4, 0.8]:
		var c := PBCommand.copy_mesh_data(cube)
		var ids := PackedInt32Array()
		for eid in range(c.get_common_edges().size()):
			ids.append(eid)
		var res := PBMeshOps.bevel_edges(c, ids, amt, 2)
		assert_true(res.get("ok", false), "amt=%.2f should succeed: %s" % [amt, str(res.get("error", ""))])
		var w := _chamfer_width(c, a, b)
		assert_true(w >= last_w - 0.0001, "amt=%.2f width %.4f must not shrink from %.4f" % [amt, w, last_w])
		last_w = w


func test_bevel_repeated_restore_rebevel_never_sticks_verify_snapshot_fidelity():
	# The cancel path restores the FULL snapshot (positions, faces, welds).
	# After a restore, topology queries must match the pre-op mesh exactly.
	var cube := PBMeshData.create_cube(1.0)
	var snapshot := PBCommand.copy_mesh_data(cube)
	PBMeshOps.bevel_edges(cube, PackedInt32Array([0, 1, 2]), 0.1, 2)
	assert_gt(cube.faces.size(), 6, "op applied")
	PBCommand.restore_mesh_data(cube, snapshot)
	assert_eq(cube.faces.size(), 6, "restore brings back 6 faces")
	assert_eq(cube.get_common_edges().size(), 12, "restore brings back 12 edges")
	assert_eq(cube.shared_vertices.size(), 8, "restore brings back 8 weld groups")
	var res := PBMeshOps.bevel_edges(cube, PackedInt32Array([3]), 0.12, 1)
	assert_true(res.get("ok", false), "bevel after restore works: %s" % str(res.get("error", "")))


func test_bevel_outer_loop_fillet_does_not_bump_the_corner():
	# Cylindrical rails at a 2-edge corner bowed back toward the original
	# vertex (d≈0.05). A straight rail stays on the chamfer chord (d≥0.1).
	var cube := PBMeshData.create_cube(1.0)
	var ir := PBMeshOps.inset_faces(cube, PackedInt32Array([4]), 0.25)
	PBMeshOps.extrude_faces(cube, PackedInt32Array([ir["cap_face_ids"][0]]), -0.4)
	var hy := -999.0
	for p in cube.positions:
		hy = maxf(hy, p.y)
	var aabb := AABB(cube.positions[0], Vector3.ZERO)
	for p in cube.positions:
		aabb = aabb.expand(p)
	var outer := PackedInt32Array()
	for eid in range(cube.get_common_edges().size()):
		var e := cube.get_common_edges()[eid]
		var pa: Vector3 = cube.positions[e.a]
		var pb: Vector3 = cube.positions[e.b]
		if absf(pa.y - hy) > 0.02 or absf(pb.y - hy) > 0.02:
			continue
		var pa_rim := absf(pa.x - aabb.position.x) < 0.02 or absf(pa.x - aabb.end.x) < 0.02 \
			or absf(pa.z - aabb.position.z) < 0.02 or absf(pa.z - aabb.end.z) < 0.02
		var pb_rim := absf(pb.x - aabb.position.x) < 0.02 or absf(pb.x - aabb.end.x) < 0.02 \
			or absf(pb.z - aabb.position.z) < 0.02 or absf(pb.z - aabb.end.z) < 0.02
		if pa_rim and pb_rim:
			outer.append(eid)
	assert_eq(outer.size(), 4, "outer frame loop")
	var res := PBMeshOps.bevel_edges(cube, outer, 0.1, 3)
	assert_true(res.get("ok", false), "outer S=3: %s" % str(res.get("error", "")))
	_assert_watertight(cube, "outer S=3")
	var corner := Vector3(-0.5, 0.5, -0.5)
	for p in cube.positions:
		if p.distance_to(corner) > 0.4:
			continue
		assert_true(p.x >= -0.501 and p.y <= 0.501 and p.z >= -0.501,
			"fillet point stays inside the cube at %s" % str(p))
