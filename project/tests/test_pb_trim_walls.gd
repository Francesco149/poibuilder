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
	# Offset is measured OFF the placement edge: at Top, positive moves the
	# strip DOWN (away from the ceiling).
	tool.params["offset"] = 0.5
	data = tool.build(Callable(), ceiling_probe)
	hi = -INF
	for p in data.positions:
		hi = maxf(hi, p.y)
	assert_almost_eq(hi, 2.3, 0.001, "positive top offset slides the cornice DOWN off the ceiling")

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

## REGRESSION ("changing offset permanently shifts the trimming up even if I
## put it back to zero"): the recorded paths baked the Offset in, so Edit
## Params offsetting +0.3 then back to 0 never returned to the walls. The
## recording must be offset-FREE; the rebuild applies Offset itself.
func test_recorded_paths_are_offset_free():
	var wall := _wall(Vector3(4, 3, 0.2), Vector3(2, 1.5, -0.1))
	var face := _face_with_normal(wall, Vector3(0, 0, 1))
	var tool := PBTrimWallsTool.new()
	tool.arm()
	tool.toggle_wall(wall, face)

	tool.params["offset"] = 0.35
	tool.build()
	var shifted: Array = tool.last_paths.duplicate(true)

	tool.params["offset"] = 0.0
	tool.build()
	var neutral: Array = tool.last_paths.duplicate(true)

	assert_eq(shifted.size(), neutral.size(), "same walls, same paths")
	for i in range(neutral.size()):
		var a: PackedVector3Array = shifted[i]["points"]
		var b: PackedVector3Array = neutral[i]["points"]
		assert_eq(a.size(), b.size())
		for j in range(b.size()):
			assert_almost_eq(a[j].y, b[j].y, 0.001,
				"the RECORD is offset-free - Offset is applied at sweep time")

	# And the rebuild path applies Offset as a plain vertical shift.
	var values := {"wall_paths": neutral.duplicate(true), "offset": 0.5}
	var data := PBShapeParams.build(&"trim_walls", values)
	assert_ne(data, null)
	var lo := INF
	for p in data.positions:
		lo = minf(lo, p.y)
	assert_almost_eq(lo, 0.5, 0.001, "rebuild Offset slides the recorded run")

## REGRESSION ("toggling smoothing makes the corner ping pong up and down",
## "top only applies to the newest corner"): build() must be a PURE function
## of (walls, params, probes) — same input, byte-identical geometry, and
## placement params affect EVERY wall, not just the newest.
func test_build_is_deterministic_and_params_are_global():
	var wall_a := _wall(Vector3(4, 3, 0.2), Vector3(2, 1.5, -0.1))
	var wall_b := _wall(Vector3(0.2, 3, 4), Vector3(4.1, 1.5, 2))
	var face_a := _face_with_normal(wall_a, Vector3(0, 0, 1))
	var face_b := _face_with_normal(wall_b, Vector3(-1, 0, 0))
	var slab_y := 0.0
	var ceiling_y := 3.0
	var floor_probe := func(_f: Vector3) -> float: return slab_y
	var ceiling_probe := func(_f: Vector3) -> float: return ceiling_y

	var tool := PBTrimWallsTool.new()
	tool.arm()
	tool.toggle_wall(wall_a, face_a)
	tool.toggle_wall(wall_b, face_b)

	# Determinism: two builds with the same state are identical.
	tool.params["top"] = 1.0
	var d1 := tool.build(Callable(), ceiling_probe)
	var d2 := tool.build(Callable(), ceiling_probe)
	assert_ne(d1, null)
	assert_eq(d1.positions.size(), d2.positions.size())
	for i in range(d1.positions.size()):
		assert_almost_eq(d1.positions[i].y, d2.positions[i].y, 0.0001,
			"rebuilds never drift (the preview probe must not feed back)")

	# Globality: Placement Top hangs EVERY wall's run under the ceiling,
	# not just the newest pick's corner.
	tool.params["top"] = 0.0
	tool.params["height"] = 0.2
	var bottom_build := tool.build(Callable(), ceiling_probe)
	var bottom_lo := INF
	for p in bottom_build.positions:
		bottom_lo = minf(bottom_lo, p.y)
	tool.params["top"] = 1.0
	var top_build := tool.build(Callable(), ceiling_probe)
	assert_ne(top_build, null)
	# Bottom placement sits on the slab (y=0); top placement hangs under 3.0.
	var top_lo := INF
	var top_hi := -INF
	for p in top_build.positions:
		top_lo = minf(top_lo, p.y)
		top_hi = maxf(top_hi, p.y)
	assert_almost_eq(bottom_lo, 0.0, 0.001, "bottom run sits on the floor")
	assert_almost_eq(top_hi, ceiling_y, 0.001,
		"top run tucks under the ceiling on EVERY wall (global placement)")
	assert_almost_eq(top_hi - top_lo, 0.2, 0.002)

## REGRESSION (door front): the door's front is ONE concave polygon wrapping
## its arch. Boundary-order crossing pairing scrambled it - only ONE pier
## got trim (a sliver of the other). Crossings sorted along the line pair
## into both piers.
func test_door_front_yields_both_pier_runs():
	var md := PBShapeComplex.create_door(3.0, 2.5, 2.0, 0.5, 1.0, true, 6)
	var front := -1
	for fi in range(md.faces.size()):
		var n := PBMath.normal_from_positions(md.positions, md.faces[fi].get_indexes())
		var poly := md.get_face_outline_positions(fi)
		var c := Vector3.ZERO
		for p in poly:
			c += p
		c /= poly.size()
		if n.z > 0.9 and c.z > 0:
			front = fi
	assert_gt(front, -1)
	var segs := PBTrimWallsTool.run_segments_at_height(
		md.get_face_outline_positions(front), 0.05)
	assert_eq(segs.size(), 2, "BOTH sides of the doorway get a trim run")
	var min_x := INF
	var max_x := -INF
	for sg in segs:
		min_x = minf(min_x, minf((sg["a"] as Vector3).x, (sg["b"] as Vector3).x))
		max_x = maxf(max_x, maxf((sg["a"] as Vector3).x, (sg["b"] as Vector3).x))
	assert_lt(min_x, -0.9, "the left pier run spans the left side")
	assert_gt(max_x, 0.9, "the right pier run spans the right side")

## REGRESSION (stairs): the stair side faces store vertices in sliver-
## triangle appearance order - the outline reconstruction must chain
## boundary edges so the base run spans the whole stair on BOTH sides.
func test_stair_sides_span_their_base_on_both_sides():
	var mesh: PBMesh = autofree(PBMesh.new())
	mesh.pb_mesh_data = PBShapeComplex.create_stairs(Vector3(3, 1.2, 2), 6, true)
	mesh.position = Vector3(0, 0.6, 0)  # sits on the floor
	for side in [-1.0, 1.0]:
		var face := -1
		var mdata: PBMeshData = mesh.pb_mesh_data
		for fi in range(mdata.faces.size()):
			var n := PBMath.normal_from_positions(mdata.positions, mdata.faces[fi].get_indexes())
			if absf(n.x) > 0.9 and (mesh.transform.basis * n).normalized().dot(Vector3(side, 0, 0)) > 0.9:
				face = fi
		assert_gt(face, -1)
		var segs := PBTrimWallsTool.run_segments_at_height(
			PBTrimWallsTool.face_world_polygon(mesh, face), 0.05)
		assert_eq(segs.size(), 1, "side %s: one base run at floor height" % side)
		var span: float = (segs[0]["a"] as Vector3).distance_to(segs[0]["b"])
		assert_almost_eq(span, 2.0, 0.01,
			"the run spans the stair's full depth (outline order, not zigzag)")

## Placement stays live AFTER the commit: the recorded run carries its
## room-shell references (floor/ceiling), so Edit Params Bottom/Top/Height/
## Offset re-place the SAME run instead of doing nothing.
func test_rebuild_replaces_bottom_top_against_recorded_shell():
	var wall := _wall(Vector3(4, 3, 0.2), Vector3(2, 1.5, -0.1))
	var face := _face_with_normal(wall, Vector3(0, 0, 1))
	var tool := PBTrimWallsTool.new()
	tool.arm()
	tool.params["height"] = 0.2
	tool.toggle_wall(wall, face)
	var floor_probe := func(_f: Vector3) -> float: return 0.0
	var ceiling_probe := func(_f: Vector3) -> float: return 3.0
	tool.build(floor_probe, ceiling_probe)
	assert_eq(tool.last_paths.size(), 1)
	assert_almost_eq(float(tool.last_paths[0]["floor_y"]), 0.0, 0.001,
		"the run records its floor reference")
	assert_almost_eq(float(tool.last_paths[0]["ceil_y"]), 3.0, 0.001,
		"the run records its ceiling reference")
	var recorded: Array = []
	for p in tool.last_paths:
		recorded.append({"points": p["points"], "closed": p["closed"],
			"floor_y": p["floor_y"], "ceil_y": p["ceil_y"]})

	# Committed at bottom; Edit Params switches to Top: the same run hangs
	# under the ceiling.
	var top_data := PBShapeParams.build(&"trim_walls",
		{"wall_paths": recorded, "top": 1.0, "height": 0.2})
	var hi := -INF
	for p in top_data.positions:
		hi = maxf(hi, p.y)
	assert_almost_eq(hi, 3.0, 0.002, "Placement Top re-places the committed run")
	# ...and Offset at Top slides DOWN off the ceiling.
	var top_off := PBShapeParams.build(&"trim_walls",
		{"wall_paths": recorded, "top": 1.0, "height": 0.2, "offset": 0.5})
	var hi2 := -INF
	for p in top_off.positions:
		hi2 = maxf(hi2, p.y)
	assert_almost_eq(hi2, 2.5, 0.002, "top offset slides the run down off the ceiling")

## Placement-edge cross-sections: Bottom trims what exists at the floor
## (a door front = two piers), Top trims what exists at the face's top
## edge (a door front = one head run across the arch).
func test_door_cross_section_follows_placement_edge():
	var md := PBShapeComplex.create_door(3.0, 2.5, 2.0, 0.5, 1.0, true, 6)
	var front := -1
	for fi in range(md.faces.size()):
		var n := PBMath.normal_from_positions(md.positions, md.faces[fi].get_indexes())
		var poly := md.get_face_outline_positions(fi)
		var c := Vector3.ZERO
		for p in poly:
			c += p
		c /= poly.size()
		if n.z > 0.9 and c.z > 0:
			front = fi
	var poly := md.get_face_outline_positions(front)
	var lo := INF
	var hi := -INF
	for p in poly:
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
	assert_eq(PBTrimWallsTool.run_segments_at_height(poly, lo + 0.001).size(), 2,
		"bottom edge: two pier runs")
	assert_eq(PBTrimWallsTool.run_segments_at_height(poly, hi - 0.001).size(), 1,
		"top edge: one head run across the arch")

## Stairs at Top placement stop on the top step: two short runs on the top
## step's profile, nothing running down the front.
func test_stair_side_at_top_stops_on_the_top_step():
	var mesh: PBMesh = autofree(PBMesh.new())
	mesh.pb_mesh_data = PBShapeComplex.create_stairs(Vector3(3, 1.2, 2), 6, true)
	mesh.position = Vector3(0, 0.6, 0)
	var face := -1
	var mdata: PBMeshData = mesh.pb_mesh_data
	for fi in range(mdata.faces.size()):
		var n := PBMath.normal_from_positions(mdata.positions, mdata.faces[fi].get_indexes())
		if n.x > 0.9:
			face = fi
	var poly := PBTrimWallsTool.face_world_polygon(mesh, face)
	var hi := -INF
	for p in poly:
		hi = maxf(hi, p.y)
	var segs := PBTrimWallsTool.run_segments_at_height(poly, hi - 0.001)
	assert_eq(segs.size(), 1, "the top placement stops ON the top step")
	var span: float = (segs[0]["a"] as Vector3).distance_to(segs[0]["b"])
	assert_lt(span, 0.5, "the run is short (top step only, not the whole stair)")
	# ...while the bottom still runs the full depth.
	var bottom := PBTrimWallsTool.run_segments_at_height(poly, 0.05)
	assert_eq(bottom.size(), 1, "bottom placement runs the full depth")

## REGRESSION (full loop to Top): the door's INNER reveal faces kept their
## arch-level runs at Top placement. At Top the trim marks the structure's
## top edge - faces well below the tallest chosen face yield nothing -
## while in ISOLATION (only the door chosen) the door front still works.
func test_top_placement_skips_faces_below_the_structure_top():
	var wall := _wall(Vector3(6, 3, 0.2), Vector3(3, 1.5, -0.1))   # tall wall, hi=3
	var door := _wall(Vector3(1.2, 2, 0.2), Vector3(5, 1.0, -0.1)) # door-ish face, hi=2
	var tall_face := _face_with_normal(wall, Vector3(0, 0, 1))
	var door_face := _face_with_normal(door, Vector3(0, 0, 1))
	var tool := PBTrimWallsTool.new()
	tool.arm()
	tool.params["top"] = 1.0
	tool.toggle_wall(wall, tall_face)
	tool.toggle_wall(door, door_face)
	var data := tool.build()
	assert_ne(data, null)
	var hi := -INF
	for p in data.positions:
		hi = maxf(hi, p.y)
	assert_almost_eq(hi, 3.0, 0.002,
		"at Top the trim runs the structure's top edge - the door face below it yields nothing")
	var lo := INF
	for p in data.positions:
		lo = minf(lo, p.y)
	assert_almost_eq(lo, 3.0 - float(tool.params["height"]), 0.002,
		"the strip hangs under the top edge")

	# In ISOLATION (only the short face chosen) it is the tallest and works.
	var solo := PBTrimWallsTool.new()
	solo.arm()
	solo.params["top"] = 1.0
	solo.toggle_wall(door, door_face)
	var solo_data := solo.build()
	assert_ne(solo_data, null)
	var solo_hi := -INF
	for p in solo_data.positions:
		solo_hi = maxf(solo_hi, p.y)
	assert_almost_eq(solo_hi, 2.0, 0.002, "isolated, the short face is its own top edge")
