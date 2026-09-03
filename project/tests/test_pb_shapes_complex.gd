extends GutTest

# ==============================================================================
# Sphere (Icosphere) Tests
# ==============================================================================

func test_sphere_default():
	var md = PBShapeComplex.create_sphere()
	assert_eq(md.validate(), "", "Sphere should validate")
	# 2 subdivisions: 20 × 4^2 = 320 faces, 960 vertices
	assert_eq(md.face_count(), 320, "Sphere: 320 faces")
	assert_eq(md.vertex_count(), 960, "Sphere: 960 vertices")

func test_sphere_0_subdivision():
	var md = PBShapeComplex.create_sphere(0.5, 0)
	assert_eq(md.validate(), "")
	assert_eq(md.face_count(), 20)
	assert_eq(md.vertex_count(), 60)

func test_sphere_1_subdivision():
	var md = PBShapeComplex.create_sphere(0.5, 1)
	assert_eq(md.validate(), "")
	assert_eq(md.face_count(), 80)
	assert_eq(md.vertex_count(), 240)

func test_sphere_positions_on_surface():
	var md = PBShapeComplex.create_sphere(1.0, 1)
	for i in range(md.vertex_count()):
		var r = md.positions[i].length()
		assert_almost_eq(r, 1.0, 0.01, "Vertex should be on sphere surface")

func test_sphere_compiles():
	var md = PBShapeComplex.create_sphere(0.5, 1)
	var mesh = md.to_array_mesh()
	assert_not_null(mesh)
	assert_gt(mesh.get_surface_count(), 0)

func test_sphere_normals():
	var md = PBShapeComplex.create_sphere(1.0, 1)
	var normals = md.calculate_normals()
	assert_eq(normals.size(), md.vertex_count())
	for i in range(md.vertex_count()):
		var n: Vector3 = normals[i]
		var p: Vector3 = md.positions[i]
		# Outward normal should have positive dot product with vertex position
		assert_gt(n.dot(p), 0.0, "Icosphere normals should face outward")

func test_sphere_smoothing_groups():
	var md_smooth = PBShapeComplex.create_sphere(0.5, 1, true)
	for f in md_smooth.faces:
		assert_eq(f.smoothing_group, 1)

	var md_flat = PBShapeComplex.create_sphere(0.5, 1, false)
	for f in md_flat.faces:
		assert_eq(f.smoothing_group, 0)

# ==============================================================================
# Torus Tests
# ==============================================================================

func test_torus_default():
	var md = PBShapeComplex.create_torus()
	assert_eq(md.validate(), "", "Torus should validate")
	# 12 rows × 16 columns = 192 faces, 768 vertices
	assert_eq(md.face_count(), 192)
	assert_eq(md.vertex_count(), 768)

func test_torus_small():
	var md = PBShapeComplex.create_torus(0.5, 0.1, 4, 6)
	assert_eq(md.validate(), "")
	assert_eq(md.face_count(), 24)
	assert_eq(md.vertex_count(), 96)

func test_torus_compiles():
	var md = PBShapeComplex.create_torus(0.5, 0.1, 4, 6)
	var mesh = md.to_array_mesh()
	assert_not_null(mesh)

func test_torus_normals():
	var md = PBShapeComplex.create_torus(0.5, 0.1, 4, 6)
	var normals = md.calculate_normals()
	assert_eq(normals.size(), md.vertex_count())
	for n in normals:
		assert_almost_eq(n.length(), 1.0, 0.01)

func test_torus_normals_face_away_from_the_tube():
	# Winding regression: the quad order used to produce INWARD normals
	# (the classic inside-out torus — every face culled from outside).
	var major := 0.5
	var minor := 0.1
	var md = PBShapeComplex.create_torus(major, minor, 8, 10)
	var normals = md.calculate_normals()
	for f in md.faces:
		var idxs: PackedInt32Array = f.get_indexes()
		var c := Vector3.ZERO
		for j in idxs:
			c += md.positions[j]
		c /= float(idxs.size())
		# Closest point on the ring's center circle (the tube's spine).
		var flat := Vector2(c.x, c.z).normalized() * major
		var spine := Vector3(flat.x, 0.0, flat.y)
		assert_gt(normals[idxs[0]].dot(c - spine), 0.0,
			"Torus faces must point away from the tube's spine (outward)")

func test_torus_smoothing_groups():
	var md_smooth = PBShapeComplex.create_torus(0.5, 0.1, 4, 6, true)
	for f in md_smooth.faces:
		assert_eq(f.smoothing_group, 1)

	var md_flat = PBShapeComplex.create_torus(0.5, 0.1, 4, 6, false)
	for f in md_flat.faces:
		assert_eq(f.smoothing_group, 0)

# ==============================================================================
# Arch Tests
# ==============================================================================

func test_arch_default():
	var md = PBShapeComplex.create_arch()
	assert_eq(md.validate(), "", "Arch should validate")
	assert_gt(md.face_count(), 0)
	assert_gt(md.vertex_count(), 0)
	# 8 sides × 4 faces (outer, inner, front, back) + 2 end caps = 34 faces
	assert_eq(md.face_count(), 34)
	assert_eq(md.vertex_count(), 136)

func test_arch_compiles():
	var md = PBShapeComplex.create_arch()
	var mesh = md.to_array_mesh()
	assert_not_null(mesh)

func test_arch_full_circle():
	var md = PBShapeComplex.create_arch(1.0, 0.5, 0.25, 8, 360.0, false)
	assert_eq(md.validate(), "")
	# 8 sides × 4 faces = 32 faces (no end caps on 360)
	assert_eq(md.face_count(), 32)
	assert_eq(md.vertex_count(), 128)

func test_arch_no_end_caps():
	var md = PBShapeComplex.create_arch(1.0, 0.5, 0.25, 6, 180.0, false)
	assert_eq(md.validate(), "")
	# 6 sides × 4 faces = 24 faces
	assert_eq(md.face_count(), 24)
	assert_eq(md.vertex_count(), 96)

func test_arch_normals():
	var md = PBShapeComplex.create_arch()
	var normals = md.calculate_normals()
	assert_eq(normals.size(), md.vertex_count())
	for n in normals:
		assert_almost_eq(n.length(), 1.0, 0.01)

# ==============================================================================
# Stairs Tests
# ==============================================================================

func test_stairs_default():
	var md = PBShapeComplex.create_stairs()
	assert_eq(md.validate(), "", "Stairs should validate")
	assert_gt(md.face_count(), 0)
	assert_gt(md.vertex_count(), 0)
	# 6 steps × 2 (riser+tread) + 6 left + 6 right + 1 back = 25 faces
	assert_eq(md.face_count(), 25)
	assert_eq(md.vertex_count(), 100)

func test_stairs_step_count():
	var md = PBShapeComplex.create_stairs(Vector3(1, 1, 2), 4, false)
	assert_eq(md.validate(), "")
	# 4 steps × 2 faces (riser + tread) = 8 faces (no sides, no back)
	assert_eq(md.face_count(), 8, "4 steps without sides: 8 faces")
	assert_eq(md.vertex_count(), 32)

func test_stairs_with_sides():
	var md = PBShapeComplex.create_stairs(Vector3(1, 1, 2), 4, true)
	assert_eq(md.validate(), "")
	assert_gt(md.face_count(), 8, "With sides should have more faces")
	# 4 × 2 + 4 + 4 + 1 = 17 faces
	assert_eq(md.face_count(), 17)
	assert_eq(md.vertex_count(), 68)

func test_stairs_compiles():
	var md = PBShapeComplex.create_stairs()
	var mesh = md.to_array_mesh()
	assert_not_null(mesh)

func test_stairs_normals():
	var md = PBShapeComplex.create_stairs()
	var normals = md.calculate_normals()
	assert_eq(normals.size(), md.vertex_count())
	for n in normals:
		assert_almost_eq(n.length(), 1.0, 0.01)

func test_curved_stairs_default():
	var md := PBShapeComplex.create_curved_stairs()
	assert_eq(md.validate(), "", "Curved stairs should validate")
	assert_gt(md.face_count(), 0)
	assert_gt(md.vertex_count(), 0)
	var mesh := md.to_array_mesh()
	assert_not_null(mesh)

func test_curved_stairs_pie_steps():
	var md := PBShapeComplex.create_curved_stairs(1.5, 2.0, 0.0, 180.0, 6, true)
	assert_eq(md.validate(), "", "Curved stairs with 0 inner radius should validate")
	assert_gt(md.face_count(), 0)
	var mesh := md.to_array_mesh()
	assert_not_null(mesh)

func test_curved_stairs_negative_curvature():
	var md := PBShapeComplex.create_curved_stairs(1.5, 2.0, 0.5, -90.0, 6, true)
	assert_eq(md.validate(), "", "Curved stairs with negative curvature should validate")
	assert_gt(md.face_count(), 0)
	var normals := md.calculate_normals()
	for n in normals:
		assert_almost_eq(n.length(), 1.0, 0.01)

func test_curved_stairs_treads_face_up():
	var md := PBShapeComplex.create_curved_stairs(1.5, 2.0, 0.5, 180.0, 8, false)
	# With sides=false, 8 steps have 8 risers and 8 treads = 16 faces.
	assert_eq(md.face_count(), 16)
	var up_faces := 0
	for f in md.faces:
		var n: Vector3 = PBMath.normal_from_positions(md.positions, f.get_indexes())
		if n.y > 0.9:
			up_faces += 1
	assert_eq(up_faces, 8, "All 8 curved stairs treads must have up-facing (+Y) normals")

func test_curved_stairs_pie_treads_face_up():
	var md := PBShapeComplex.create_curved_stairs(1.5, 2.0, 0.0, 180.0, 8, false)
	assert_eq(md.face_count(), 16)
	var up_faces := 0
	for f in md.faces:
		var n: Vector3 = PBMath.normal_from_positions(md.positions, f.get_indexes())
		if n.y > 0.9:
			up_faces += 1
	assert_eq(up_faces, 8, "All 8 curved stairs pie treads must have up-facing (+Y) normals")

func test_door_wide_arch_rise_capped():
	# Even on a very wide door (width=10m, height=2.5m, opening_height=2.0m),
	# the arch rise must be capped so it never exceeds half the opening height.
	# This guarantees vertical jambs of at least 1.0m and prevents the arch from
	# becoming a floor-springing oval.
	var md := PBShapeComplex.create_door(10.0, 2.5, 2.0, 0.5, 1.0, true, 6)
	assert_eq(md.validate(), "")
	# Find lowest Y on the arch tunnel (should be spring_y >= y0 + 1.0 = -1.25 + 1.0 = -0.25)
	var spring_found := false
	for p in md.positions:
		# Check if any arc point touches floor (-1.25): only rim corners touch floor
		if absf(p.x) < 4.0 and absf(p.y - (-1.25)) < 0.001 and absf(p.z) < 0.4:
			spring_found = true
	assert_false(spring_found, "Arch must not spring from the floor on a wide door")

# ==============================================================================
# Door Tests
# ==============================================================================

func test_door_default():
	var md = PBShapeComplex.create_door()
	assert_eq(md.validate(), "", "Door should validate")
	# v0.9.17 welded shell: ONE face per side — front + back n-gons around
	# the opening, 2 jambs, 6 tunnel quads, 2 outer walls, 1 top.
	assert_eq(md.face_count(), 13, "Door: 13 faces")

func test_door_flat_lintel_has_closed_outer_shell():
	# v0.9.13: the legs' OUTER walls (±X) and the lintel's top (+Y) used to
	# be missing — the frame was hollow when seen from the side/above.
	var md = PBShapeComplex.create_door(3.0, 2.5, 2.0, 0.5, 1.0, false)
	assert_eq(md.validate(), "")
	# Front + back n-gons + 2 jambs + 1 lintel + 2 walls + 1 top = 8 faces.
	assert_eq(md.face_count(), 8, "Flat door: 8 faces")
	assert_eq(md.vertex_count(), 40, "Flat door: 40 vertices")

	var left_faces: Array = []
	var right_faces: Array = []
	var top_faces: Array = []
	for fi in range(md.faces.size()):
		var idxs: PackedInt32Array = md.faces[fi].get_indexes()
		var all_left := true
		var all_right := true
		var all_top := true
		for j in idxs:
			var p: Vector3 = md.positions[j]
			all_left = all_left and absf(p.x + 1.5) < 0.001
			all_right = all_right and absf(p.x - 1.5) < 0.001
			all_top = all_top and absf(p.y - 1.25) < 0.001
		if all_left:
			left_faces.append(fi)
		if all_right:
			right_faces.append(fi)
		if all_top:
			top_faces.append(fi)
	assert_eq(left_faces.size(), 1, "The left outer wall is ONE face")
	assert_eq(right_faces.size(), 1, "The right outer wall is ONE face")
	assert_eq(top_faces.size(), 1, "The top wall is ONE face")

	# And they must face OUTWARD (normals agree with the geometry).
	var normals = md.calculate_normals()
	assert_lt(normals[md.faces[left_faces[0]].get_indexes()[0]].x, 0.0,
		"Left outer wall faces -X")
	assert_gt(normals[md.faces[right_faces[0]].get_indexes()[0]].x, 0.0,
		"Right outer wall faces +X")
	assert_gt(normals[md.faces[top_faces[0]].get_indexes()[0]].y, 0.0,
		"Top wall faces +Y")

func test_door_opening_height_measured_from_the_bottom():
	# v0.9.13 semantics: opening_height is the opening's height above the
	# bottom edge (it used to be the lintel height — a 2m opening_height on
	# a 2.5m door left a 0.5m slot).
	var md = PBShapeComplex.create_door(3.0, 2.5, 2.0, 0.5, 1.0, false)
	var opening_top := -1.25 + 2.0
	var found_jamb_top := false
	for p in md.positions:
		if absf(p.x + 1.0) < 0.001 and absf(p.y - opening_top) < 0.001:
			found_jamb_top = true
	assert_true(found_jamb_top, "The jamb tops sit at bottom + opening_height")

func test_door_arch_reaches_the_opening_top():
	var md = PBShapeComplex.create_door(3.0, 2.5, 2.0, 0.5, 1.0, true, 6)
	var found_apex := false
	for p in md.positions:
		if absf(p.x) < 0.001 and absf(p.y - 0.75) < 0.001 and absf(absf(p.z) - 0.5) < 0.001:
			found_apex = true
	assert_true(found_apex, "The arch's apex touches the opening top on both faces")

func test_door_arch_segments_param_changes_topology():
	var three = PBShapeComplex.create_door(3.0, 2.5, 2.0, 0.5, 1.0, true, 3)
	var eight = PBShapeComplex.create_door(3.0, 2.5, 2.0, 0.5, 1.0, true, 8)
	assert_eq(three.validate(), "")
	assert_eq(eight.validate(), "")
	assert_eq(three.face_count(), 3 + 7, "3 segments: 10 faces")
	assert_eq(eight.face_count(), 8 + 7, "8 segments: 15 faces")

func test_door_compiles():
	var md = PBShapeComplex.create_door()
	var mesh = md.to_array_mesh()
	assert_not_null(mesh)

func test_door_normals():
	var md = PBShapeComplex.create_door()
	var normals = md.calculate_normals()
	assert_eq(normals.size(), md.vertex_count())
	for n in normals:
		assert_almost_eq(n.length(), 1.0, 0.01)

func test_door_shared_vertices():
	var md = PBShapeComplex.create_door()
	assert_gt(md.shared_vertices.size(), 0)
	# Coincident lookup should find sharing vertices
	var lookup = md.get_shared_vertex_lookup()
	assert_eq(lookup.size(), md.vertex_count())

static func _coord_open_counts(md: PBMeshData) -> Dictionary:
	var usage := {}
	for face in md.faces:
		for e in face.get_edges():
			var pa: Vector3 = md.positions[e.a]
			var pb: Vector3 = md.positions[e.b]
			var ka := Vector3(snappedf(pa.x, 0.0001), snappedf(pa.y, 0.0001), snappedf(pa.z, 0.0001))
			var kb := Vector3(snappedf(pb.x, 0.0001), snappedf(pb.y, 0.0001), snappedf(pb.z, 0.0001))
			var k: String
			if ka < kb:
				k = "%s|%s" % [ka, kb]
			else:
				k = "%s|%s" % [kb, ka]
			usage[k] = usage.get(k, 0) + 1
	return usage

static func _open_off_bottom(md: PBMeshData, usage: Dictionary) -> Array:
	var y0 := INF
	for p in md.positions:
		y0 = minf(y0, p.y)
	var off_bottom: Array = []
	for k in usage.keys():
		if usage[k] == 1:
			var both_bottom := true
			for half in (k as String).split("|"):
				var comp: PackedStringArray = half.replace("(", "").replace(")", "").split(", ")
				if absf(comp[1].to_float() - y0) > 0.0011:
					both_bottom = false
			if not both_bottom:
				off_bottom.append(k)
	return off_bottom

func test_door_shell_is_tjunction_free():
	## REGRESSION (v0.9.15): the shell used to carry T-junctions (a vertex
	## lying ON another face's edge — e.g. the opening-top corner on the
	## outer wall's edge); grabbing any frame face sheared it off the wall
	## and tore triangular holes ("one vert left behind"). Every edge must
	## now be shared in full by exactly 2 faces, except the open bottom rim.
	for params in [[3.0, 2.5, 2.0, 0.5, 1.0, false, 6],
			[3.0, 2.5, 2.0, 0.5, 1.0, true, 6],
			[3.0, 2.5, 2.0, 0.5, 1.0, true, 3],
			[4.0, 1.4, 1.0, 0.4, 0.8, true, 6]]:
		var md = PBShapeComplex.create_door(
			params[0], params[1], params[2], params[3], params[4], params[5], params[6])
		var usage := _coord_open_counts(md)
		for k in usage.keys():
			assert_lt(usage[k], 3, "Edge used by more than 2 faces: %s" % k)
		var off_bottom := _open_off_bottom(md, usage)
		assert_eq(off_bottom.size(), 0,
			"Door shell must have no open/T-junction edges off the bottom rim")
		var rim := 0
		for k in usage.keys():
			if usage[k] == 1:
				rim += 1
		assert_eq(rim, 8, "Exactly the 8 bottom-rim segments stay open")

## True when a usage-1 edge is legitimate: it carries the moved side
## (an endpoint in the union) or lies on the original bottom rim.
static func _is_open_edge_ok(md: PBMeshData, e: PBEdge, union: Dictionary,
		y0: float) -> bool:
	if union.has(e.a) or union.has(e.b):
		return true
	var pa: Vector3 = md.positions[e.a]
	var pb: Vector3 = md.positions[e.b]
	return absf(pa.y - y0) < 0.0011 and absf(pb.y - y0) < 0.0011

## y0 = the PRE-move bottom rim height (a moved leg piece can dip below it).
static func _tears_after_move(md: PBMeshData, union_ids: PackedInt32Array,
		y0: float) -> int:
	var union := {}
	for idx in union_ids:
		union[idx] = true
	var usage := _coord_open_counts(md)
	var tears := 0
	for k in usage.keys():
		if usage[k] != 1:
			continue
		var ok := false
		for fi in range(md.faces.size()):
			for e in md.faces[fi].get_edges():
				var pa: Vector3 = md.positions[e.a]
				var pb: Vector3 = md.positions[e.b]
				var ka := Vector3(snappedf(pa.x, 0.0001), snappedf(pa.y, 0.0001), snappedf(pa.z, 0.0001))
				var kb := Vector3(snappedf(pb.x, 0.0001), snappedf(pb.y, 0.0001), snappedf(pb.z, 0.0001))
				var k2: String
				if ka < kb:
					k2 = "%s|%s" % [ka, kb]
				else:
					k2 = "%s|%s" % [kb, ka]
				if k2 == k:
					if _is_open_edge_ok(md, e, union, y0):
						ok = true
					break
			if ok:
				break
		if not ok:
			tears += 1
	return tears

func test_door_face_grab_never_tears():
	## The user-facing guarantee: grabbing ANY face and moving its weld
	## union must never open a hole. Open edges may only carry the moved
	## side or sit on the untouched bottom rim — everything else is a tear.
	for arched in [true, false]:
		var md = PBShapeComplex.create_door(3.0, 2.5, 2.0, 0.5, 1.0, arched, 6)
		var y0 := INF
		for p in md.positions:
			y0 = minf(y0, p.y)
		for fi in range(md.faces.size()):
			var union := md.get_coincident_vertices_from_faces(PackedInt32Array([fi]))
			for idx in union:
				md.positions[idx] += Vector3(0.37, -0.53, 0.21)
			md.rebuild_welds()
			assert_eq(_tears_after_move(md, union, y0), 0,
				"Face %d grab+move opens no hole" % fi)
			for idx in union:
				md.positions[idx] -= Vector3(0.37, -0.53, 0.21)
			md.rebuild_welds()

func test_door_front_is_one_ngon_with_hole_perimeter():
	## "A stock door should be 1 n-gon face per side": the front face's
	## perimeter is its outer rect + the opening outline (sub-edge chains
	## included); its wireframe contributes ONLY perimeter edges — the
	## internal piece triangulation is invisible.
	var md = PBShapeComplex.create_door(3.0, 2.5, 2.0, 0.5, 1.0, true, 6)
	assert_eq(md.faces.size(), 13)
	var front: PBFace = md.faces[0]
	var edges: Array[PBEdge] = front.get_edges()
	# The opening is a NOTCH touching the bottom edge, so the side is one
	# simple concave polygon: 2 rim edges + 2 jamb edges + 6 arc edges +
	# 2 side edges + 1 top edge = 13 perimeter edges, no collinear chains.
	assert_eq(edges.size(), 13, "Front perimeter: one edge per true boundary edge")
	assert_false(front.is_quad(), "The front is an n-gon, not a quad")
	# Every perimeter edge of the front must pair with exactly one neighbor
	# edge or sit on the bottom rim (no T-junctions).
	var usage := _coord_open_counts(md)
	var y0 := INF
	for p in md.positions:
		y0 = minf(y0, p.y)
	for e in edges:
		var pa: Vector3 = md.positions[e.a]
		var pb: Vector3 = md.positions[e.b]
		var ka := Vector3(snappedf(pa.x, 0.0001), snappedf(pa.y, 0.0001), snappedf(pa.z, 0.0001))
		var kb := Vector3(snappedf(pb.x, 0.0001), snappedf(pb.y, 0.0001), snappedf(pb.z, 0.0001))
		var k: String
		if ka < kb:
			k = "%s|%s" % [ka, kb]
		else:
			k = "%s|%s" % [kb, ka]
		if usage[k] == 1:
			assert_true(absf(pa.y - y0) < 0.0011 and absf(pb.y - y0) < 0.0011,
				"An unpaired front perimeter edge may only sit on the bottom rim")
		else:
			assert_eq(usage[k], 2,
				"Front perimeter edge pairs with exactly one neighbor edge")

func test_door_front_extrudes_normally():
	## Extruding the merged front creates the cap + walls around BOTH the
	## outer rect and the hole, and the new edges stay (watertight shell).
	var md = PBShapeComplex.create_door(3.0, 2.5, 2.0, 0.5, 1.0, true, 6)
	var usage_before := _coord_open_counts(md)
	var rim_before := 0
	for k in usage_before.keys():
		if usage_before[k] == 1:
			rim_before += 1
	var r: Dictionary = PBMeshOps.extrude_faces(md, PackedInt32Array([0]), 0.3)
	assert_true(r["ok"], "Extrude ok")
	assert_eq(r["cap_face_ids"].size(), 1, "One cap replaces the front")
	# 12 remaining + 1 cap + 13 walls (one per perimeter edge) = 26.
	assert_eq(md.faces.size(), 26, "The extrusion adds one wall per perimeter edge")
	var usage_after := _coord_open_counts(md)
	var rim_after := 0
	for k in usage_after.keys():
		assert_lt(usage_after[k], 3, "No edge used by more than 2 faces")
		if usage_after[k] == 1:
			rim_after += 1
	assert_eq(rim_after, rim_before,
		"The new walls close the cap perimeter; the bottom rim stays the only opening")
