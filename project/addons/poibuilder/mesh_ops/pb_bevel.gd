## PBMeshBevel — bevel (chamfer / fillet) for PBMeshData.
##
## Runtime-safe, headless-testable; entry point is PBMeshOps.bevel_edges().
##
## DESIGN — one shared point registry, topology by construction
## ------------------------------------------------------------
## Every point the op creates exists EXACTLY ONCE and is referenced by index from
## every face that touches it: a face corner's offset chain, a point where a
## neighbouring face's offset crosses a shared edge, a bridge rail. Faces are
## therefore welded by construction. The previous implementation recomputed
## "the same" point independently per consumer (per-face rail endpoints fished
## out of a dictionary whose miss value was Vector3.ZERO, corner caps rebuilt by
## cancelling and re-chaining segments within a 0.5 mm tolerance) and relied on
## the copies agreeing; when they did not, corners tore open and, because the
## weld rebuild merges only EXACT coincidence, the result still counted as
## watertight while showing a slit.
##
## Geometry, per beveled vertex v:
##   - each face at v rebuilds its corner into a CHAIN:
##       * both of the face's edges at v beveled -> the two offset lines' MITER
##         point (segments == 1) or a fillet arc of radius `amount` centred on v
##         between the two offset points (segments >= 2),
##       * exactly one beveled -> the point where that edge's offset line meets
##         the other edge (which is at perpendicular distance `amount` from the
##         beveled edge, matching the miter point's offset),
##       * neither beveled -> the points a neighbour's offset placed on those
##         edges, with v itself between them,
##   - each beveled edge END gets a RAIL spanning from one incident face's chain
##     end to the other's (a straight segment for a chamfer, the fillet's end
##     ring for segments >= 2); the bridge quads interpolate between the rails,
##   - the ring of chains and rails around v closes into a CAP face.
##
## The old case-C formula shifted the corner by `amount` along the diagonal,
## i.e. only `amount * cos(45 deg)` perpendicular to each edge, while the
## neighbouring face's corner shifted a full `amount` — the two faces of one
## beveled edge disagreed about how far the edge moved. The miter intersection
## fixes that: every boundary line is offset by exactly `amount`.
@tool
class_name PBMeshBevel
extends RefCounted

## Chamfer / fillet the given common-edge ids. Mutates `mesh_data`.
## Returns { "ok", "error"?, "cap_face_ids", "new_face_ids", "position_remap" }.
static func bevel_edges(mesh_data: PBMeshData, edge_ids: PackedInt32Array,
		amount: float, segments: int = 1) -> Dictionary:
	if mesh_data == null or mesh_data.faces.is_empty():
		return _fail("Bevel edges: no mesh data")
	if edge_ids.is_empty():
		return _fail("Bevel edges: no edges selected")

	segments = clampi(segments, 1, 8)
	amount = maxf(amount, 0.0001)

	var lookup := mesh_data.get_shared_vertex_lookup()
	var common_edges := mesh_data.get_common_edges()

	var selected := {}
	for eid in edge_ids:
		if eid < 0 or eid >= common_edges.size():
			continue
		var e := common_edges[eid]
		selected[_key(lookup, e.a, e.b)] = true
	if selected.is_empty():
		return _fail("Bevel edges: no valid edges selected")

	# ---- 1. face loops + edge incidence ------------------------------------
	# A face whose perimeter is not a single simple loop (a hole) cannot be
	# offset consistently: refuse to touch the selection rather than skip it,
	# which used to leave its edges unretracted while the neighbours moved.
	var loops := {}
	var normals := {}
	var incidence := {}
	var holed := {}
	for fi in range(mesh_data.faces.size()):
		var face := mesh_data.faces[fi]
		if face == null:
			continue
		var loop := PBMeshOps._ordered_loop(face)
		if loop.size() < 3:
			for edge in face.get_edges():
				holed[_key(lookup, edge.a, edge.b)] = true
			continue
		loops[fi] = loop
		normals[fi] = PBMeshOps._face_area_normal(mesh_data, face).normalized()
		var n := loop.size()
		for i in range(n):
			var k := _key(lookup, loop[i], loop[(i + 1) % n])
			if not incidence.has(k):
				incidence[k] = []
			incidence[k].append({"fi": fi, "i": i, "va": loop[i], "vb": loop[(i + 1) % n]})
	for k: Vector2i in selected:
		if holed.has(k):
			return _fail("Bevel edges: a face touching the selection has a hole (its perimeter is not a single loop)")

	# ---- 2. valid edges (closed manifold: exactly 2 incident faces) --------
	var valid := {}
	for k: Vector2i in selected:
		var entries: Array = incidence.get(k, [])
		if entries.size() == 2:
			valid[k] = entries
	if valid.is_empty():
		return _fail("Bevel edges: cannot bevel open boundary edges")

	# ---- 3. beveled vertices + distance clamp ------------------------------
	var touched := {}
	var shortest := {}
	for k: Vector2i in valid:
		touched[k.x] = true
		touched[k.y] = true
	for fi: int in loops:
		var loop: PackedInt32Array = loops[fi]
		var n := loop.size()
		for i in range(n):
			var a: int = loop[i]
			var b: int = loop[(i + 1) % n]
			var ca: int = lookup.get(a, a)
			var cb: int = lookup.get(b, b)
			var l := mesh_data.positions[a].distance_to(mesh_data.positions[b])
			if l <= 0.0001:
				continue
			if touched.has(ca) and (not shortest.has(ca) or l < float(shortest[ca])):
				shortest[ca] = l
			if touched.has(cb) and (not shortest.has(cb) or l < float(shortest[cb])):
				shortest[cb] = l
	var amt := amount
	for c: int in shortest:
		amt = minf(amt, float(shortest[c]) * 0.38)
	if amt < 0.0005:
		return _fail("Bevel edges: bevel distance exceeds available surface")

	# An attempt that fails — or that closes with a folded seam, see below — is
	# rolled back and retried at half the distance.
	var restore_snapshot: PBMeshData = PBCommand.copy_mesh_data(mesh_data)
	var preexisting_seams := _seam_defects(mesh_data)
	var attempt := 0
	var last_error := ""
	while attempt < 16:
		attempt += 1
		var outcome := _bevel_build(mesh_data, lookup, valid, incidence, loops, normals, touched, amt, segments)
		if outcome.get("ok", false):
			# The beveled region must end up closed and consistently wound: a
			# surface that only LOOKS right (each face fine on its own, two of
			# them lying on the same side of a seam) is the corruption this op
			# must never ship. Detect it here, retry smaller, then report.
			var defects := _new_seams(mesh_data, preexisting_seams)
			if defects == 0:
				return outcome
			outcome = {"ok": false, "error": "the bevel crosses itself at this selection (%d folded seams)" % defects}
		last_error = str(outcome.get("error", ""))
		PBCommand.restore_mesh_data(mesh_data, restore_snapshot)
		if amt <= amount * 0.0005:
			break
		amt *= 0.5
	return _fail("Bevel edges: " + last_error)

## Builds the bevel surface at the given distance. Any face that cannot survive
## the offset (a face narrower than the offset needs) fails the attempt, and the
## caller retries with a smaller distance: a bevel that would cross its own
## offset lines is not representable, and shipping the crossed result is what
## used to leave non-manifold junk behind.
static func _bevel_build(mesh_data: PBMeshData, lookup: Dictionary, valid: Dictionary,
		incidence: Dictionary, loops: Dictionary, normals: Dictionary, touched: Dictionary,
		amt: float, segments: int) -> Dictionary:
		# ---- 4. corner chains --------------------------------------------------
		# corners[fi][i] = { p, prev, next, k_prev, k_next, eb_prev, eb_next,
		#                    chain: Array of point records }
		# A point record is { label, pt, src }: `label` names the ONE position that
		# this point gets (empty label = reuse the source position, i.e. a corner
		# that stays where it is).
		var corners := {}
		var reg := {}    # edge key -> { vertex rep -> Array of point records (on that edge) }

		for fi: int in loops:
			var loop: PackedInt32Array = loops[fi]
			var n := loop.size()
			var fn: Vector3 = normals[fi]
			var face_corners := {}
			for i in range(n):
				var vi: int = loop[i]
				var vrep: int = lookup.get(vi, vi)
				if not touched.has(vrep):
					continue
				var v_prev: int = loop[(i - 1 + n) % n]
				var v_next: int = loop[(i + 1) % n]
				var pos_i: Vector3 = mesh_data.positions[vi]
				var d_prev: Vector3 = mesh_data.positions[v_prev] - pos_i
				var d_next: Vector3 = mesh_data.positions[v_next] - pos_i
				var k_prev := _key(lookup, vi, v_prev)
				var k_next := _key(lookup, vi, v_next)
				var eb_prev: bool = valid.has(k_prev)
				var eb_next: bool = valid.has(k_next)
				var info := {
					"i": i, "p": vi, "vrep": vrep, "prev": v_prev, "next": v_next,
					"k_prev": k_prev, "k_next": k_next,
					"eb_prev": eb_prev, "eb_next": eb_next,
					"entries": [],
					"zero": false,
				}
				if d_prev.length_squared() < 0.00000001 or d_next.length_squared() < 0.00000001:
					# Degenerate edge at this corner: leave the corner alone.
					info["zero"] = true
					face_corners[i] = info
					continue
				d_prev = d_prev.normalized()
				d_next = d_next.normalized()
				var u_prev := _inward(fn, -d_prev)
				var u_next := _inward(fn, d_next)

				if eb_prev and eb_next:
					# Both of this face's edges at the corner move: the boundary runs
					# along each offset line until they meet, and that meeting point
					# (the miter) is also where a fillet's cylinder is tangent to the
					# face — the corner sphere touches the face there and nowhere
					# else. So the face's corner is the SAME point for chamfers and
					# fillets: a fillet differs only in the rail and cap geometry.
					var qa: Vector3 = pos_i + u_prev * amt
					var qb: Vector3 = pos_i + u_next * amt
					var miter: Variant = _line_intersection(qa, d_prev, qb, d_next)
					var pt: Vector3 = miter if miter != null else (qa + qb) * 0.5
					info["entries"].append(_pt("c%d_%d" % [fi, i], pt, vi))
				elif eb_prev:
					# Offset line of the prev edge meets the next edge: the point is
					# `amt` from the beveled edge, measured perpendicular to it.
					var denom := d_next.dot(u_prev)
					var step := amt / maxf(0.05, absf(denom))
					var edge_len: float = pos_i.distance_to(mesh_data.positions[v_next])
					step = minf(step, edge_len * 0.45)
					var q: Vector3 = pos_i + d_next * step
					var rec: Dictionary = _reg_add(reg, k_next, vrep, _pt("c%d_%d" % [fi, i], q, vi), step)
					if segments > 1:
						# The fillet's ring ends before the corner: the face's boundary
						# is split there, and the cap covers the rest.
						info["entries"].append(_pt("c%d_%d_r" % [fi, i], pos_i + d_prev * amt + u_prev * amt, vi))
					info["entries"].append(rec)
				elif eb_next:
					var denom2 := d_prev.dot(u_next)
					var step2 := amt / maxf(0.05, absf(denom2))
					var edge_len2: float = pos_i.distance_to(mesh_data.positions[v_prev])
					step2 = minf(step2, edge_len2 * 0.45)
					var q2: Vector3 = pos_i + d_prev * step2
					var rec2: Dictionary = _reg_add(reg, k_prev, vrep, _pt("c%d_%d" % [fi, i], q2, vi), step2)
					if segments > 1:
						info["entries"].append(_pt("c%d_%d_r" % [fi, i], pos_i + d_next * amt + u_next * amt, vi))
					info["entries"].append(rec2)
				else:
					# This face has no beveled edge at the corner, but the corner is a
					# beveled vertex: its boundary follows the points the neighbouring
					# faces' offsets placed on its edges, with v between them. When
					# BOTH edges carry such a point the corner is fully cut and v is
					# dropped at chain-assembly time (the cap closes the leftover
					# region) — keeping v there would make the face's own corner ear
					# and the cap cover the same triangle.
					info["entries"].append(_pt("", pos_i, vi))
					info["drop_v"] = true
				face_corners[i] = info
			if not face_corners.is_empty():
				corners[fi] = face_corners

		# Assemble each corner's boundary chain: points placed on the prev edge
		# (far to near), the corner's own points, points on the next edge (near to
		# far). Points a neighbouring face placed on a shared edge are included, so
		# both faces turn at the same place.
		for fi: int in corners:
			for i: int in corners[fi]:
				var info: Dictionary = corners[fi][i]
				if info["zero"]:
					continue
				var vrep: int = lookup.get(info["p"], info["p"])
				var pts_prev := _reg_sorted(reg, info["k_prev"], vrep, false)
				var pts_next := _reg_sorted(reg, info["k_next"], vrep, true)
				var chain: Array = []
				chain.append_array(pts_prev)
				var cut_corner: bool = info.get("drop_v", false) and not pts_prev.is_empty() and not pts_next.is_empty()
				if not cut_corner:
					chain.append_array(info["entries"])
				chain.append_array(pts_next)
				info["chain"] = _dedupe(chain)
		# ---- 5. rebuild the touched faces --------------------------------------
		# Each face gets its OWN copy of every point it uses: the position-privacy
		# invariant (calculate_normals writes per position, so sharing one between
		# faces with different normals corrupts their flat normals). The copies
		# coincide exactly because they all come from the same point record, and
		# the weld rebuild reconnects them into shared vertex groups — which is
		# what keeps dragging, moving and selecting coherent.

		# ---- 6. rebuild the touched faces --------------------------------------
		var removed := {}
		var primary: Array[PBFace] = []
		var rebuilt_fail := ""
		for fi in range(mesh_data.faces.size()):
			if not corners.has(fi):
				continue
			var loop: PackedInt32Array = loops[fi]
			var n := loop.size()
			var new_loop := PackedInt32Array()
			for i in range(n):
				if corners[fi].has(i):
					var info: Dictionary = corners[fi][i]
					if info["zero"]:
						new_loop.append(loop[i])
						continue
					for rec: Dictionary in info["chain"]:
						new_loop.append(_record_position(mesh_data, rec))
				else:
					new_loop.append(loop[i])
			var f := _face_from_indices(mesh_data, new_loop, mesh_data.faces[fi], normals[fi])
			if f == null:
				if OS.get_environment("PB_BEVEL_TRACE") != "":
					var dump := PackedStringArray()
					for idx in new_loop:
						dump.append(str(mesh_data.positions[idx]))
					print("[bevel] F%d amt=%.5f loop(%d): %s" % [fi, amt, new_loop.size(), " | ".join(dump)])
				rebuilt_fail = "face %d did not survive the bevel (degenerate corner)" % fi
				break
			removed[fi] = true
			primary.append(f)
		if not rebuilt_fail.is_empty():
			return _fail("Bevel edges: " + rebuilt_fail)

		# ---- 7. rails + bridges along each beveled edge ------------------------
		var secondary: Array[PBFace] = []
		var rails := {}     # Vector3i(key.x, key.y, vertex rep) -> Array of records (face A end -> face B end)
		var detail_fail := ""
		for k: Vector2i in valid:
			var entries: Array = valid[k]
			var fa: int = entries[0]["fi"]
			var fb: int = entries[1]["fi"]
			var n_fa: Vector3 = normals[fa]
			var n_fb: Vector3 = normals[fb]
			for c in [k.x, k.y]:
				var end_a: Dictionary = _corner_end(corners, entries[0], c, k)
				var end_b: Dictionary = _corner_end(corners, entries[1], c, k)
				if end_a.is_empty() or end_b.is_empty():
					detail_fail = "edge end has no rail anchor"
					break
				var pts: Array = [end_a]
				for s in range(1, segments):
					var t := float(s) / float(segments)
					var pt: Vector3 = PBMeshOps._arc_interp(end_a["pt"], end_b["pt"], n_fa, n_fb, t)
					pts.append(_pt("r%d_%d_%d_%d" % [k.x, k.y, c, s], pt, int(end_a["src"])))
				pts.append(end_b)
				rails[Vector3i(k.x, k.y, c)] = pts
			if not detail_fail.is_empty():
				break
			# Bridge quads: rail A and rail B both run from fa's side to fb's side.
			var rail_a: Array = rails[Vector3i(k.x, k.y, k.x)]
			var rail_b: Array = rails[Vector3i(k.x, k.y, k.y)]
			var band_normal: Vector3 = (n_fa + n_fb).normalized()
			if band_normal.length_squared() < 0.0001:
				band_normal = n_fa
			for s in range(segments):
				var quad := PackedInt32Array([
					_record_position(mesh_data, rail_a[s]), _record_position(mesh_data, rail_b[s]),
					_record_position(mesh_data, rail_b[s + 1]), _record_position(mesh_data, rail_a[s + 1]),
				])
				var f := _face_from_indices(mesh_data, quad, mesh_data.faces[fa], band_normal)
				if f == null:
					detail_fail = "a bridge quad collapsed (bevel distance too large for the edge length)"
					break
				secondary.append(f)
			if not detail_fail.is_empty():
				break
		if not detail_fail.is_empty():
			return _fail("Bevel edges: " + detail_fail)

		# ---- 8. vertex caps ----------------------------------------------------
		for c: int in touched:
			var cycle := _vertex_face_cycle(corners, loops, incidence, lookup, c)
			if cycle.is_empty():
				continue
			var ring: Array = []
			var m := cycle.size()
			for j in range(m):
				var cur: Dictionary = cycle[j]
				var info: Dictionary = corners[cur["fi"]][cur["i"]]
				var chain: Array = info["chain"]
				var entry: Array = chain
				var start: int = 0
				if not ring.is_empty():
					var tail: Dictionary = ring[ring.size() - 1]
					if chain.size() > 1 and is_same(chain[chain.size() - 1], tail):
						# The walk entered this face across its outgoing edge: follow
						# the chain the other way so the ring never doubles back.
						entry = []
						for q in range(chain.size() - 1, -1, -1):
							entry.append(chain[q])
					elif is_same(chain[0], tail):
						start = 1
				for q in range(start, entry.size()):
					_ring_push(ring, entry[q])
				var k: Vector2i = cur["k_next"]
				var rail_key := Vector3i(k.x, k.y, c)
				if not rails.has(rail_key):
					continue
				var rail: Array = rails[rail_key]
				var ordered: Array = rail
				var cur_last: Dictionary = entry[entry.size() - 1]
				if not is_same(rail[0], cur_last):
					ordered = []
					for r in range(rail.size() - 1, -1, -1):
						ordered.append(rail[r])
				# The rail's first point is this chain's last one: append the rest.
				for r in range(1, ordered.size()):
					_ring_push(ring, ordered[r])
			if ring.size() > 1 and (is_same(ring[0], ring[ring.size() - 1])
					or ring[0]["pt"].distance_to(ring[ring.size() - 1]["pt"]) < 0.000001):
				ring.remove_at(ring.size() - 1)
			if ring.size() < 3:
				continue
			# A chamfer corner whose two rails are the same segment bounds no area at
			# all: the rails pair with each other and there is nothing to cap.
			if _ring_area(ring) < 0.000000001:
				continue
			var outward := Vector3.ZERO
			for j in range(m):
				var cur_n: Vector3 = normals[cycle[j]["fi"]]
				outward += cur_n
			var cap := _fan_face(mesh_data, ring, outward.normalized(), mesh_data.faces[cycle[0]["fi"]])
			if cap == null:
					return _fail("Bevel edges: the corner at %s collapsed" % str(mesh_data.positions[c]))
			secondary.append(cap)

		# ---- 9. swap the faces in ----------------------------------------------
		return PBMeshOps._replace_faces(mesh_data, removed, primary, secondary)

# ==============================================================================
# Point records
# ==============================================================================

static func _pt(label: String, pt: Vector3, src: int) -> Dictionary:
	return {"label": label, "pt": pt, "src": src, "idx": -1}

static func _key(lookup: Dictionary, a: int, b: int) -> Vector2i:
	var ca: int = lookup.get(a, a)
	var cb: int = lookup.get(b, b)
	return Vector2i(mini(ca, cb), maxi(ca, cb))

## In-face direction perpendicular to `along`, pointing into the face.
static func _inward(normal: Vector3, along: Vector3) -> Vector3:
	var u := normal.cross(along)
	if u.length_squared() < 0.00000001:
		return normal.cross(Vector3.UP).normalized() if absf(normal.dot(Vector3.UP)) < 0.99 \
			else normal.cross(Vector3.RIGHT).normalized()
	return u.normalized()

## Intersection of the lines (a + t*da) and (b + s*db); null when they are
## parallel enough that the meeting point is not meaningful.
static func _line_intersection(a: Vector3, da: Vector3, b: Vector3, db: Vector3) -> Variant:
	var na := da.cross(db)
	var denom := na.length_squared()
	if denom < 0.000001:
		return null
	var t := (b - a).cross(db).dot(na) / denom
	return a + da * t

## Seam defects of a mesh, keyed by edge COORDINATES (not by weld-group ids,
## which are reassigned whenever the topology is rebuilt): an edge used twice in
## the same direction means two faces lie on the same side of it — a folded
## seam — and an edge used once or more than twice is an open or non-manifold
## seam.
static func _seam_defects(mesh_data: PBMeshData) -> Dictionary:
	var lookup := mesh_data.get_shared_vertex_lookup()
	var counts := {}
	var dirs := {}
	for face in mesh_data.faces:
		if face == null:
			continue
		for e in face.get_edges():
			var pa: Vector3 = mesh_data.positions[e.a]
			var pb: Vector3 = mesh_data.positions[e.b]
			var ka := _point_key(pa)
			var kb := _point_key(pb)
			var key: String = ka + "|" + kb if ka < kb else kb + "|" + ka
			counts[key] = counts.get(key, 0) + 1
			var ca: int = lookup.get(e.a, e.a)
			var cb: int = lookup.get(e.b, e.b)
			if not dirs.has(key):
				dirs[key] = []
			# The directed usage — NOT sorted: two faces on the same side of a
			# seam traverse it the same way, which is the defect being looked for.
			dirs[key].append(Vector2i(ca, cb))
	var bad := {}
	for key in counts:
		var n: int = counts[key]
		if n != 2:
			bad[key] = true
			if OS.get_environment("PB_BEVEL_TRACE") != "":
				print("[bevel]   seam %s count=%d" % [key, n])
			continue
		var ds: Array = dirs[key]
		if not (ds[0].x == ds[1].y and ds[0].y == ds[1].x):
			bad[key] = true
			if OS.get_environment("PB_BEVEL_TRACE") != "":
				print("[bevel]   seam %s SAME-DIR %s %s" % [key, str(ds[0]), str(ds[1])])
	return bad

## Seams that got WORSE than they already were: the input's own defects are the
## caller's business, the new ones are the bevel's.
static func _new_seams(mesh_data: PBMeshData, before: Dictionary) -> int:
	var after := _seam_defects(mesh_data)
	var count := 0
	for key in after:
		if not before.has(key):
			count += 1
			if OS.get_environment("PB_BEVEL_TRACE") != "":
				print("[bevel] seam %s" % key)
	return count

## Coordinate key of a point, snapped to the weld tolerance: stable across the
## weld rebuild that the op performs.
static func _point_key(p: Vector3) -> String:
	return "%d,%d,%d" % [roundi(p.x * 10000.0), roundi(p.y * 10000.0), roundi(p.z * 10000.0)]

## The face-private position for a point record: the record's source position for
## an untouched corner, a fresh copy otherwise (attributes come from the source).
static func _record_position(mesh_data: PBMeshData, rec: Dictionary) -> int:
	if str(rec["label"]).is_empty():
		return int(rec["src"])
	return PBMeshOps._dup_position_at(mesh_data, rec["pt"], int(rec["src"]))

## Area of the ring formed by point records (half the Newell vector's length).
## Zero means the ring retraces itself and bounds nothing.
static func _ring_area(ring: Array) -> float:
	var n := Vector3.ZERO
	var count := ring.size()
	for i in range(count):
		var cur: Vector3 = ring[i]["pt"]
		var nxt: Vector3 = ring[(i + 1) % count]["pt"]
		n.x += (cur.y - nxt.y) * (cur.z + nxt.z)
		n.y += (cur.z - nxt.z) * (cur.x + nxt.x)
		n.z += (cur.x - nxt.x) * (cur.y + nxt.y)
	return n.length() * 0.5

static func _reg_add(reg: Dictionary, key: Vector2i, vrep: int, rec: Dictionary, dist: float) -> Dictionary:
	if not reg.has(key):
		reg[key] = {}
	var by_vertex: Dictionary = reg[key]
	if not by_vertex.has(vrep):
		by_vertex[vrep] = []
	var list: Array = by_vertex[vrep]
	for entry: Dictionary in list:
		if absf(float(entry["dist"]) - dist) <= maxf(0.0005, dist * 0.02):
			# Two faces offset onto the same edge land on the same point: share
			# ONE position so both chains (and the rails) reference it.
			return entry["rec"]
	list.append({"rec": rec, "dist": dist})
	return rec

## Points a neighbouring face placed on this edge at this vertex, ordered along
## the face's boundary: far-to-near on the incoming edge, near-to-far on the
## outgoing one.
static func _reg_sorted(reg: Dictionary, key: Vector2i, vrep: int, near_to_far: bool) -> Array:
	var out: Array = []
	if not reg.has(key):
		return out
	var by_vertex: Dictionary = reg[key]
	if not by_vertex.has(vrep):
		return out
	var list: Array = by_vertex[vrep].duplicate()
	list.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		var dx: float = float(x["dist"])
		var dy: float = float(y["dist"])
		return dx < dy if near_to_far else dx > dy
	)
	for entry: Dictionary in list:
		out.append(entry["rec"])
	return out

static func _dedupe(chain: Array) -> Array:
	var out: Array = []
	var seen := {}
	for rec: Dictionary in chain:
		var label: String = rec["label"]
		if not label.is_empty():
			if seen.has(label):
				continue
			seen[label] = true
		out.append(rec)
	return out

static func _ring_push(ring: Array, rec: Dictionary) -> void:
	if not ring.is_empty():
		var last: Dictionary = ring[ring.size() - 1]
		# Two records can name the same place (a corner point and a neighbour's
		# offset landing together): a ring must not visit it twice, or the fan
		# emits a zero-length edge.
		if is_same(last, rec) or last["pt"].distance_to(rec["pt"]) < 0.000001:
			return
	ring.append(rec)

## The chain endpoint of `entry`'s face corner that touches edge `k`.
static func _corner_end(corners: Dictionary, entry: Dictionary, c: int, k: Vector2i) -> Dictionary:
	var fi: int = entry["fi"]
	var corner_i := _face_corner_at(corners, fi, c)
	if corner_i < 0:
		return {}
	var info: Dictionary = corners[fi][corner_i]
	var chain: Array = info.get("chain", [])
	if chain.is_empty():
		return {}
	if info["k_prev"] == k:
		return chain[0]
	if info["k_next"] == k:
		return chain[chain.size() - 1]
	return {}

static func _face_corner_at(corners: Dictionary, fi: int, c: int) -> int:
	if not corners.has(fi):
		return -1
	for i: int in corners[fi]:
		var info: Dictionary = corners[fi][i]
		if int(info["vrep"]) == c:
			return i
	return -1

## Face cycle around vertex `c` following each corner's outgoing edge.
static func _vertex_face_cycle(corners: Dictionary, loops: Dictionary, incidence: Dictionary,
		lookup: Dictionary, c: int) -> Array:
	var start_fi := -1
	var start_i := -1
	for fi: int in corners:
		var i := _face_corner_at(corners, fi, c)
		if i >= 0:
			start_fi = fi
			start_i = i
			break
	if start_fi < 0:
		return []
	var cycle: Array = []
	var cur_fi := start_fi
	var cur_i := start_i
	for _guard in range(256):
		var info: Dictionary = corners[cur_fi][cur_i]
		var k_next: Vector2i = info["k_next"]
		cycle.append({"fi": cur_fi, "i": cur_i, "k_next": k_next})
		var entries: Array = incidence.get(k_next, [])
		if entries.size() != 2:
			return []
		var other: Dictionary = entries[1] if int(entries[0]["fi"]) == cur_fi else entries[0]
		var ofi: int = other["fi"]
		var oloop: PackedInt32Array = loops.get(ofi, PackedInt32Array())
		if oloop.size() < 3:
			return []
		var oi: int = other["i"]
		if lookup.get(oloop[oi], oloop[oi]) != c:
			oi = (oi + 1) % oloop.size()
		if _face_corner_at(corners, ofi, c) != oi:
			return []
		cur_fi = ofi
		cur_i = oi
		if cur_fi == start_fi and cur_i == start_i:
			return cycle
	return []


## Corner cap: a fan from the ring's centroid. A cap is a small, near-convex
## piece of the fillet surface; a fan keeps neighbouring triangles' normals
## close, while ear-clipping a curved patch can emit triangles whose normals
## oppose each other — flat per-face shading turns that into dark facets
## (test_pb_bevel's compiled-convention assertion catches it). Falls back to the
## ear clipper for rings too concave to fan.
static func _fan_face(mesh_data: PBMeshData, ring: Array, outward: Vector3, template: PBFace) -> PBFace:
	var n := ring.size()
	if n < 3:
		return null
	var centroid := Vector3.ZERO
	var src := int(ring[0]["src"])
	for rec: Dictionary in ring:
		centroid += rec["pt"]
	centroid /= float(n)

	var loop := PackedInt32Array()
	var flip: bool = (ring[1]["pt"] - ring[0]["pt"]).cross(centroid - ring[0]["pt"]).dot(outward) < 0.0
	for i in range(n):
		var rec: Dictionary = ring[n - 1 - i] if flip else ring[i]
		loop.append(_record_position(mesh_data, rec))

	var centre_idx := PBMeshOps._dup_position_at(mesh_data, centroid, src)
	for i in range(n):
		var a: Vector3 = mesh_data.positions[centre_idx]
		var b: Vector3 = mesh_data.positions[loop[i]]
		var c: Vector3 = mesh_data.positions[loop[(i + 1) % n]]
		var cross := (b - a).cross(c - a)
		if cross.length_squared() > 0.000000000001 and cross.normalized().dot(outward) <= 0.0:
			return _face_from_indices(mesh_data, loop, template, outward)

	var indices := PackedInt32Array()
	for i in range(n):
		indices.append(centre_idx)
		indices.append(loop[i])
		indices.append(loop[(i + 1) % n])
	var f := PBFace.new(indices)
	if template != null:
		f.submesh_index = template.submesh_index
		f.uv_scale = template.uv_scale
		f.uv_offset = template.uv_offset
		f.uv_rotation = template.uv_rotation
		f.uv_use_world_space = template.uv_use_world_space
		f.uv_flip_u = template.uv_flip_u
		f.uv_flip_v = template.uv_flip_v
		f.uv_swap_uv = template.uv_swap_uv
	return f

# ==============================================================================
# Faces from explicit index loops (no position creation)
# ==============================================================================

## Builds a PBFace over the given position indices, ear-clipping the polygon in
## the plane of `expected_normal`. Returns null when the loop cannot be
## triangulated (degenerate or self-intersecting).
static func _face_from_indices(mesh_data: PBMeshData, loop_idx: PackedInt32Array,
		template: PBFace, expected_normal: Vector3) -> PBFace:
	var clean := PackedInt32Array()
	for i in range(loop_idx.size()):
		if clean.size() > 0:
			var prev_i: int = clean[clean.size() - 1]
			if loop_idx[i] == prev_i:
				continue
			# Distinct positions that sit on top of each other (a corner built
			# from two coincident ring ends) would only make degenerate
			# triangles: keep one.
			if mesh_data.positions[loop_idx[i]].distance_squared_to(mesh_data.positions[prev_i]) < 0.000000000001:
				continue
		clean.append(loop_idx[i])
	while clean.size() > 1 and (clean[0] == clean[clean.size() - 1]
			or mesh_data.positions[clean[0]].distance_squared_to(mesh_data.positions[clean[clean.size() - 1]]) < 0.000000000001):
		clean.remove_at(clean.size() - 1)
	if clean.size() < 3:
		return null

	var normal := expected_normal
	if normal.length_squared() < 0.0001:
		normal = _newell_normal(mesh_data, clean)
	if normal.length_squared() < 0.0001:
		return null
	normal = normal.normalized()
	var basis_u: Vector3
	if absf(normal.y) < 0.99:
		basis_u = Vector3.UP.cross(normal).normalized()
	else:
		basis_u = Vector3.RIGHT.cross(normal).normalized()
	var basis_v := normal.cross(basis_u).normalized()

	var poly := _project(mesh_data, clean, basis_u, basis_v)
	if _signed_area(poly) < 0.0:
		# Keep the data-side winding (CCW from outside) by walking the loop the
		# way the face's own normal asks for.
		clean.reverse()
		poly = _project(mesh_data, clean, basis_u, basis_v)

	# Godot's ear clipper happily triangulates a self-intersecting loop into
	# overlapping triangles, which is exactly how a bevel that crosses its own
	# offset lines used to ship as non-manifold junk: reject it here and let the
	# caller retry smaller.
	if not _polygon_is_simple(poly):
		return null

	var tris := Geometry2D.triangulate_polygon(poly)
	if tris.is_empty():
		return null
	var indices := PackedInt32Array()
	for t in range(0, tris.size(), 3):
		indices.append(clean[tris[t]])
		indices.append(clean[tris[t + 1]])
		indices.append(clean[tris[t + 2]])
	var f := PBFace.new(indices)
	if template != null:
		f.submesh_index = template.submesh_index
		f.uv_scale = template.uv_scale
		f.uv_offset = template.uv_offset
		f.uv_rotation = template.uv_rotation
		f.uv_use_world_space = template.uv_use_world_space
		f.uv_flip_u = template.uv_flip_u
		f.uv_flip_v = template.uv_flip_v
		f.uv_swap_uv = template.uv_swap_uv
	return f

static func _project(mesh_data: PBMeshData, loop_idx: PackedInt32Array,
		basis_u: Vector3, basis_v: Vector3) -> PackedVector2Array:
	var origin: Vector3 = mesh_data.positions[loop_idx[0]]
	var poly := PackedVector2Array()
	for idx in loop_idx:
		var d: Vector3 = mesh_data.positions[idx] - origin
		poly.append(Vector2(d.dot(basis_u), d.dot(basis_v)))
	return poly

## True when the polygon's boundary never crosses itself (adjacent edges share a
## vertex and are skipped by construction).
static func _polygon_is_simple(poly: PackedVector2Array) -> bool:
	var n := poly.size()
	for i in range(n):
		var a0 := poly[i]
		var a1 := poly[(i + 1) % n]
		if a0.distance_squared_to(a1) < 0.0000000001:
			return false
		for j in range(i + 1, n):
			if (j + 1) % n == i or (i + 1) % n == j:
				continue
			var b0 := poly[j]
			var b1 := poly[(j + 1) % n]
			if Geometry2D.segment_intersects_segment(a0, a1, b0, b1) != null:
				return false
	return true

static func _signed_area(poly: PackedVector2Array) -> float:
	var area := 0.0
	var n := poly.size()
	for i in range(n):
		var j := (i + 1) % n
		area += poly[i].x * poly[j].y - poly[j].x * poly[i].y
	return area

static func _newell_normal(mesh_data: PBMeshData, loop_idx: PackedInt32Array) -> Vector3:
	var n := Vector3.ZERO
	var count := loop_idx.size()
	for i in range(count):
		var cur: Vector3 = mesh_data.positions[loop_idx[i]]
		var nxt: Vector3 = mesh_data.positions[loop_idx[(i + 1) % count]]
		n.x += (cur.y - nxt.y) * (cur.z + nxt.z)
		n.y += (cur.z - nxt.z) * (cur.x + nxt.x)
		n.z += (cur.x - nxt.x) * (cur.y + nxt.y)
	return n.normalized()



# ==============================================================================
# Failure handling
# ==============================================================================

static func _fail(message: String) -> Dictionary:
	return {"ok": false, "error": message}
