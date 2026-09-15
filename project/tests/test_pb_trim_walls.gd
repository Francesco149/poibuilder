## Tests for PBTrimWallsTool — click-walls trim with mitred corners.
##
## All geometry is headless: walls are PBMesh boxes OUTSIDE the tree (the
## tool falls back to .transform), probes are canned Callables.
extends GutTest

var _wall_seq := 0

func _wall(size: Vector3, pos: Vector3) -> PBMesh:
	var mesh: PBMesh = autofree(PBMesh.new())
	mesh.name = "Wall%d" % _wall_seq
	_wall_seq += 1
	mesh.pb_mesh_data = PBShapeGenerators.create_box(size)
	mesh.position = pos
	return mesh

## The face index of a box's face whose world normal matches `wanted`.
func _face_with_normal(mesh: PBMesh, wanted: Vector3) -> int:
	var md: PBMeshData = mesh.pb_mesh_data
	for fi in range(md.faces.size()):
		var n := PBMath.normal_from_positions(md.positions, md.faces[fi].get_indexes())
		if (mesh.transform.basis * n).normalized().dot(wanted) > 0.99:
			return fi
	return -1

func test_toggle_and_drop_semantics():
	var tool := PBTrimWallsTool.new()
	tool.arm()
	assert_true(tool.is_active())
	var wall := _wall(Vector3(4, 3, 0.2), Vector3(2, 1.5, -0.1))
	var face := _face_with_normal(wall, Vector3(0, 0, 1))
	assert_gt(face, -1)
	assert_true(tool.toggle_wall(wall, face), "first click chooses the wall")
	assert_eq(tool.wall_count(), 1)
	assert_false(tool.toggle_wall(wall, face), "clicking again drops it")
	assert_eq(tool.wall_count(), 0)
	assert_true(tool.toggle_wall(wall, face))
	assert_true(tool.drop_last(), "Backspace drops the last")
	assert_eq(tool.wall_count(), 0)
	assert_false(tool.drop_last(), "nothing left to drop")

func test_run_segments_cross_section():
	# A wall polygon: the cross-section at y=0 is the bottom edge span.
	var poly := PackedVector3Array([
		Vector3(0, 0, 0), Vector3(4, 0, 0), Vector3(4, 3, 0), Vector3(0, 3, 0)])
	var segs := PBTrimWallsTool.run_segments_at_height(poly, 0.0)
	assert_eq(segs.size(), 1, "a plain wall face yields one run")
	var span: float = (segs[0]["a"] as Vector3).distance_to(segs[0]["b"])
	assert_almost_eq(span, 4.0, 0.001)
	# Raised base: the cross-section rides up the vertical edges, same span.
	var segs_hi := PBTrimWallsTool.run_segments_at_height(poly, 1.0)
	assert_eq(segs_hi.size(), 1)
	var span_hi: float = (segs_hi[0]["a"] as Vector3).distance_to(segs_hi[0]["b"])
	assert_almost_eq(span_hi, 4.0, 0.001)
	# Below the wall entirely: no run.
	assert_eq(PBTrimWallsTool.run_segments_at_height(poly, 5.0).size(), 0)

func test_colinear_overlaps_merge_into_the_visible_run():
	# Two wall cubes in a line whose runs overlap by 1 m.
	var s1 := {"a": Vector3(0, 0, 0), "b": Vector3(3, 0, 0), "dir": Vector3(1, 0, 0), "y": 0.0}
	var s2 := {"a": Vector3(2, 0, 0), "b": Vector3(5, 0, 0), "dir": Vector3(1, 0, 0), "y": 0.0}
	var merged := PBTrimWallsTool.merge_colinear([s1, s2])
	assert_eq(merged.size(), 1, "overlapping colinear runs become ONE")
	var span: float = (merged[0]["a"] as Vector3).distance_to(merged[0]["b"])
	assert_almost_eq(span, 5.0, 0.001, "the union, not the sum (visible run only)")

func test_two_walls_mitre_at_their_corner():
	# Room strip x∈[0,4], z>0. Wall A runs along x at z=0 (room side +Z);
	# Wall B runs along z at x=4 (room side -X). They meet at (4, 0).
	var wall_a := _wall(Vector3(4, 3, 0.2), Vector3(2, 1.5, -0.1))
	var wall_b := _wall(Vector3(0.2, 3, 4), Vector3(4.1, 1.5, 2))
	var face_a := _face_with_normal(wall_a, Vector3(0, 0, 1))
	var face_b := _face_with_normal(wall_b, Vector3(-1, 0, 0))
	assert_gt(face_a, -1)
	assert_gt(face_b, -1)
	var tool := PBTrimWallsTool.new()
	tool.arm()
	tool.toggle_wall(wall_a, face_a)
	tool.toggle_wall(wall_b, face_b)
	var data := tool.build()
	assert_ne(data, null, "the trim builds from two walls")
	assert_eq(tool.last_paths.size(), 1, "the two runs chain into ONE path")
	var pts: PackedVector3Array = tool.last_paths[0]["points"]
	assert_eq(pts.size(), 3, "start, mitred corner, end")
	var has_corner := false
	for p in pts:
		if p.distance_to(Vector3(4, 0, 0)) < 0.02:
			has_corner = true
	assert_true(has_corner, "the mitre lands on the walls' shared corner")
	assert_false(tool.last_paths[0]["closed"], "an open L is not a ring")
	# The strip rises its height and its back hugs the walls.
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for p in data.positions:
		lo = lo.min(p)
		hi = hi.max(p)
	assert_almost_eq(lo.y, 0.0, 0.001, "the skirting sits on the floor (wall bottom)")
	assert_almost_eq(hi.y - lo.y, tool.params["height"], 0.002)
	assert_almost_eq(lo.z, 0.0, 0.002,
		"the back is ON wall A's plane (z=0)...")
	assert_almost_eq(hi.z, 4.0, 0.002, "...and the run reaches wall B's far corner")
	var has_room_side_protrusion := false
	for p in data.positions:
		if absf(p.z - float(tool.params["depth"])) < 0.002 \
				or absf(p.x - (4.0 - float(tool.params["depth"]))) < 0.002:
			has_room_side_protrusion = true
	assert_true(has_room_side_protrusion,
		"the depth protrudes INTO the room on both walls (back on the wall face)")

func test_four_walls_close_into_a_ring():
	var tool := PBTrimWallsTool.new()
	tool.arm()
	tool.params["height"] = 0.1
	# A 4x4 room: four wall cubes with their room-side faces inward.
	var south := _wall(Vector3(4, 3, 0.2), Vector3(2, 1.5, -0.1))   # face +Z, z=0
	var north := _wall(Vector3(4, 3, 0.2), Vector3(2, 1.5, 4.1))   # face -Z, z=4
	var west := _wall(Vector3(0.2, 3, 4), Vector3(-0.1, 1.5, 2))   # face +X, x=0
	var east := _wall(Vector3(0.2, 3, 4), Vector3(4.1, 1.5, 2))    # face -X, x=4
	for pair in [[south, Vector3(0, 0, 1)], [north, Vector3(0, 0, -1)],
			[west, Vector3(1, 0, 0)], [east, Vector3(-1, 0, 0)]]:
		var fi := _face_with_normal(pair[0], pair[1])
		assert_gt(fi, -1)
		tool.toggle_wall(pair[0], fi)
	var data := tool.build()
	assert_ne(data, null)
	assert_eq(tool.last_paths.size(), 1, "the perimeter chains into one loop")
	assert_true(tool.last_paths[0]["closed"], "walls all the way round close into a ring")
	var pts: PackedVector3Array = tool.last_paths[0]["points"]
	assert_eq(pts.size(), 5, "four corners + the closing point (= the start)")
	# Sweep of a closed ring: every path node exists, all four corners hit.
	var corners := [Vector3(0, 0, 0), Vector3(4, 0, 0), Vector3(4, 0, 4), Vector3(0, 0, 4)]
	for c in corners:
		var found := false
		for p in pts:
			if p.distance_to(c) < 0.02:
				found = true
		assert_true(found, "ring corner %s present" % c)
	assert_gt(data.faces.size(), 0)

func test_doorway_jamb_breaks_the_run():
	# Two colinear piers with a 0.8 m doorway between them: the runs must NOT
	# bridge the opening (colinear runs only butt-join when touching).
	var pier_l := _wall(Vector3(1.6, 3, 0.2), Vector3(0.8, 1.5, -0.1))  # x∈[0,1.6]
	var pier_r := _wall(Vector3(1.6, 3, 0.2), Vector3(4.0, 1.5, -0.1))  # x∈[3.2,4.8]
	var tool := PBTrimWallsTool.new()
	tool.arm()
	tool.toggle_wall(pier_l, _face_with_normal(pier_l, Vector3(0, 0, 1)))
	tool.toggle_wall(pier_r, _face_with_normal(pier_r, Vector3(0, 0, 1)))
	var data := tool.build()
	assert_ne(data, null)
	assert_eq(tool.last_paths.size(), 2, "the doorway breaks the run at the jambs")
	for p in tool.last_paths:
		assert_false(p["closed"])

func test_floor_probe_lands_the_skirting_on_the_slab():
	# A wall cube reaching BELOW the floor slab: the skirting still sits on
	# the slab's surface (the probe), not the cube's buried bottom.
	var wall := _wall(Vector3(4, 4, 0.2), Vector3(2, 1.0, -0.1))  # y∈[-1, 3]
	var face := _face_with_normal(wall, Vector3(0, 0, 1))
	var tool := PBTrimWallsTool.new()
	tool.arm()
	tool.toggle_wall(wall, face)
	var slab_y := 0.0
	var probe := func(_from: Vector3) -> float: return slab_y
	var data := tool.build(probe, Callable())
	var lo := INF
	for p in data.positions:
		lo = minf(lo, p.y)
	assert_almost_eq(lo, 0.0, 0.001, "the skirting lands ON the slab, not at y=-1")

func test_cornice_hangs_from_the_top_and_tucks_under_the_ceiling():
	var wall := _wall(Vector3(4, 4, 0.2), Vector3(2, 1.0, -0.1))  # y∈[-1, 3]
	var face := _face_with_normal(wall, Vector3(0, 0, 1))
	var tool := PBTrimWallsTool.new()
	tool.arm()
	tool.params["top"] = 1.0
	tool.params["height"] = 0.2
	tool.toggle_wall(wall, face)
	# Ceiling slab underside at 2.8 (below the wall cube's 3.0 top).
	var ceiling_probe := func(_from: Vector3) -> float: return 2.8
	var data := tool.build(Callable(), ceiling_probe)
	var lo := INF
	var hi := -INF
	for p in data.positions:
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
	assert_almost_eq(hi, 2.8, 0.001, "the cornice tucks UNDER the ceiling slab")
	assert_almost_eq(hi - lo, 0.2, 0.002, "its height hangs from there")
	# Offset slides it down.
	tool.params["offset"] = -0.5
	data = tool.build(Callable(), ceiling_probe)
	hi = -INF
	for p in data.positions:
		hi = maxf(hi, p.y)
	assert_almost_eq(hi, 2.3, 0.001, "a negative offset slides the cornice down")

func test_no_walls_builds_nothing_and_floor_faces_are_not_walls():
	var tool := PBTrimWallsTool.new()
	tool.arm()
	assert_null(tool.build(), "no walls, no trim")
	# A horizontal face is refused as a "wall".
	var slab := _wall(Vector3(4, 0.2, 4), Vector3(2, -0.1, 2))  # a floor slab
	var top := _face_with_normal(slab, Vector3(0, 1, 0))
	assert_gt(top, -1)
	tool.toggle_wall(slab, top)
	assert_null(tool.build(), "a floor face is not a wall")

func test_committed_shape_rebuilds_from_recorded_paths():
	# "Its parameters stay live for the same walls": the committed tool
	# records its paths; PBShapeParams.build sweeps them with new params.
	var wall := _wall(Vector3(4, 3, 0.2), Vector3(2, 1.5, -0.1))
	var tool := PBTrimWallsTool.new()
	tool.arm()
	tool.toggle_wall(wall, _face_with_normal(wall, Vector3(0, 0, 1)))
	tool.build()
	assert_eq(tool.last_paths.size(), 1)
	var recorded: Array = []
	for p in tool.last_paths:
		recorded.append({"points": p["points"], "closed": p["closed"]})
	var values := {"wall_paths": recorded, "height": 0.3}
	var data := PBShapeParams.build(&"trim_walls", values)
	assert_ne(data, null, "the recorded path rebuilds")
	var lo := INF
	var hi := -INF
	for p in data.positions:
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
	assert_almost_eq(hi - lo, 0.3, 0.002, "the new height applies to the SAME walls")
	assert_eq(data.textures0.size(), data.positions.size(), "UVs stay paired")
