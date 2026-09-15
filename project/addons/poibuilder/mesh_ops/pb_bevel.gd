## PBMeshBevel — bevel (chamfer / fillet) for PBMeshData.
##
## Runtime-safe, headless-testable; entry point is PBMeshOps.bevel_edges().
##
## DESIGN — slide bevel (ProBuilder's Bevel.cs model, extended with an arc
## profile for `segments` > 1)
## ------------------------------------------------------------
## There is no offset-plane or miter math anywhere. Every surface point the
## op creates is defined by ONE local rule and computed exactly once:
##
##   slide point  sp(edge, end)  — `amt` from `end` along that edge, toward
##                                 its other endpoint. It lies ON the edge, so
##                                 every face sliding into that edge lands on
##                                 the same point; the weld rebuild keeps the
##                                 per-face copies glued.
##   tip          tip(face, v)   — a face whose BOTH perimeter edges at v are
##                                 beveled cannot slide its corner along one
##                                 of them, so the corner moves to the diagonal
##                                 inset v + d1*amt + d2*amt (equal to the true
##                                 miter at 90°, ProBuilder's rule elsewhere).
##   arc point    arc(edge, end, s) — interior point of the tangent circular
##                                 arc between the two faces' rail points in
##                                 the edge's END-CAP plane (through the
##                                 original corner, perpendicular to the edge;
##                                 the rounded profile). A rail that is a loop
##                                 corner tip slides along its OTHER beveled
##                                 edge — that along-edge part blends linearly.
##
## Corner v of a face whose perimeter edges at v carry b beveled edges:
##   b == 0 → corner is CUT: replaced by [sp(prev), sp(next)] (face +1 vertex)
##   b == 1 → corner SLIDES along its unbeveled edge: replaced by [sp(unbev)]
##   b == 2 → corner TIPS: replaced by [tip(face, v)]
## Walking the faces around v in fan order, wedge points either coincide with
## the neighbour's (both slid along the shared unbeveled edge — the same sp
## record) or are joined by the beveled edge's strip-end arc, so the surface
## closes around every vertex by construction.
##
## Strips: one quad per segment per beveled edge between the two end rails.
## Strip UVs continue the better-adjacent face's own auto mapping (seamless
## across that rail, texel density kept 1:1 down the slope); the strip faces
## are marked manual_uv so later auto refreshes keep them.
## Caps: only where a real hole remains (a ring of >= 3 distinct wedge/arc
## points). Multi-segment corners with two or more beveled edges get a DOME —
## Blender's "cutoff" vertex mesh: concentric inset rings step down toward
## the fillet sphere's apex and the innermost ring is a small flat n-gon
## (the UVs are one uniform anchored planar projection). Everything else
## keeps the flat chamfer cut: terminal caps (one beveled edge) and
## one-segment caps are a single ear-clipped n-gon. Where exactly two beveled
## edges meet and both rails run between the SAME two points (a loop corner),
## the two strips share one rail and no cap is emitted — quads only, like
## ProBuilder edge loops. The shared rail is a straight miter at one segment
## and a tangent arc in the corner plane when segments > 1 (both strips
## reference the same arc points, so the corner stays welded and closed).
##
## Distance is CLAMPED, never failed-then-shrunk: an edge whose ends carry
## wedge points is counted once per end and amt <= (length - margin) / count.
## The requested distance is honored whenever the surface allows it and
## smoothly clamped where it does not — there is no threshold above which the
## result jumps between sizes while a slider drags.
##
## Any structural failure (non-manifold selection, hole face, collapsed face,
## new folded seam) rolls the whole mesh back and reports an error.
@tool
class_name PBMeshBevel
extends RefCounted

const MIN_AMOUNT := 0.0005

## Chamfer / fillet the given common-edge ids. Mutates `mesh_data`.
## Returns { "ok", "error"?, "cap_face_ids", "new_face_ids", "position_remap",
## "amount" (the clamped distance used), "max_amount" (largest representable
## distance for this selection) }.
static func bevel_edges(mesh_data: PBMeshData, edge_ids: PackedInt32Array,
		amount: float, segments: int = 1) -> Dictionary:
	if mesh_data == null or mesh_data.faces.is_empty():
		return _fail("Bevel edges: no mesh data")
	if edge_ids.is_empty():
		return _fail("Bevel edges: no edges selected")

	segments = clampi(segments, 1, 8)

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

	# ---- 1. face loops, normals, edge incidence -----------------------------
	# A face whose perimeter is not a single simple loop (a hole) cannot be
	# beveled consistently: refuse to touch the selection rather than skip it,
	# which used to leave its edges unretracted while the neighbours moved.
	var loops := {}
	var normals := {}
	var incidence := {}   # edge key -> [ { fi, va, vb }, ... ]
	var holed := {}
	for fi in range(mesh_data.faces.size()):
		var face: PBFace = mesh_data.faces[fi]
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
			incidence[k].append({"fi": fi, "va": loop[i], "vb": loop[(i + 1) % n]})
	for k: Vector2i in selected:
		if holed.has(k):
			return _fail("Bevel edges: a face touching the selection has a hole (its perimeter is not a single loop)")

	# ---- 2. valid edges (closed manifold: exactly 2 incident faces) ---------
	var valid := {}
	var edge_len := {}    # edge key -> length (from a representative face edge)
	var rep_index := {}   # vrep -> one position index of the weld group
	for k: Vector2i in selected:
		var entries: Array = incidence.get(k, [])
		if entries.size() != 2:
			continue
		var na: Vector3 = normals[entries[0]["fi"]]
		var nbv: Vector3 = normals[entries[1]["fi"]]
		# A coplanar edge has no dihedral to bevel: skip it and bevel the rest
		# (its faces still retract along it through their other edges).
		if na.dot(nbv) > 0.9999:
			continue
		valid[k] = entries
		edge_len[k] = mesh_data.positions[entries[0]["va"]].distance_to(mesh_data.positions[entries[0]["vb"]])
	if valid.is_empty():
		return _fail("Bevel edges: cannot bevel open boundary or coplanar edges")
	for k: Vector2i in valid:
		var e0: Dictionary = valid[k][0]
		rep_index[int(lookup.get(e0["va"], e0["va"]))] = e0["va"]
		rep_index[int(lookup.get(e0["vb"], e0["vb"]))] = e0["vb"]

	# ---- 3. beveled vertices + exact distance clamp -------------------------
	# An edge's length is consumed from an end when ANY wedge point is placed
	# along it from that end (slides and tips land on the same spot per end,
	# so an end counts once no matter how many faces slide into it).
	var bev_at := {}      # vrep -> count of beveled edges touching it
	for k: Vector2i in valid:
		bev_at[k.x] = int(bev_at.get(k.x, 0)) + 1
		bev_at[k.y] = int(bev_at.get(k.y, 0)) + 1

	var consumed := {}    # edge key -> { vrep_of_end: true }
	for fi: int in loops:
		var loop: PackedInt32Array = loops[fi]
		var n := loop.size()
		for i in range(n):
			var vrep: int = int(lookup.get(loop[i], loop[i]))
			if not bev_at.has(vrep):
				continue
			var k_prev := _key(lookup, loop[i], loop[(i - 1 + n) % n])
			var k_next := _key(lookup, loop[i], loop[(i + 1) % n])
			var b_prev: bool = valid.has(k_prev)
			var b_next: bool = valid.has(k_next)
			# Which edges does this corner place wedge points along?
			var slides: Array = []
			if b_prev and b_next:
				slides = [k_prev, k_next]
			elif b_prev:
				slides = [k_next]
			elif b_next:
				slides = [k_prev]
			else:
				slides = [k_prev, k_next]
			for kk: Vector2i in slides:
				if not consumed.has(kk):
					consumed[kk] = {}
				consumed[kk][vrep] = true

	var max_amount := 1.0
	for k: Vector2i in consumed:
		var l: float = edge_len.get(k, -1.0)
		if l < 0.0:
			# Leading edges are usually NOT selected, so their length comes
			# from any face that carries them — overshooting one tears the
			# slid point past the neighbouring corner.
			var ents: Array = incidence.get(k, [])
			if ents.is_empty():
				continue
			l = mesh_data.positions[ents[0]["va"]].distance_to(mesh_data.positions[ents[0]["vb"]])
		var total: int = consumed[k].size()
		if total <= 0:
			continue
		var margin := maxf(0.001, l * 0.001)
		max_amount = minf(max_amount, (l - margin) / float(total))
	if amount < MIN_AMOUNT:
		return _fail("Bevel edges: bevel distance too small")
	if max_amount < MIN_AMOUNT:
		return _fail("Bevel edges: bevel distance exceeds available surface")
	var amt := minf(amount, max_amount)

	# ---- 4. build (any failure rolls back) ----------------------------------
	var restore_snapshot: PBMeshData = PBCommand.copy_mesh_data(mesh_data)
	var preexisting_seams := _seam_defects(mesh_data)
	var outcome := _bevel_build(mesh_data, lookup, valid, loops, normals, incidence,
		bev_at, rep_index, amt, segments)
	if not outcome.get("ok", false):
		PBCommand.restore_mesh_data(mesh_data, restore_snapshot)
		return outcome
	var defects := _new_seams(mesh_data, preexisting_seams)
	if defects > 0:
		PBCommand.restore_mesh_data(mesh_data, restore_snapshot)
		return _fail("Bevel edges: the bevel crosses itself at this selection (%d folded seams)" % defects)
	# Every face the op touched carries its own auto-projection UVs: the
	# rebuilt faces' corners moved onto new position copies (their duplicated
	# corner UVs are stale), and direct textures0 consumers (exporters) do not
	# re-project the way to_array_mesh does. Manual-UV faces — including the
	# strips' continued mappings — are preserved.
	for fid: int in outcome.get("new_face_ids", PackedInt32Array()):
		if fid >= 0 and fid < mesh_data.faces.size():
			PBUv.apply_face_uvs(mesh_data, mesh_data.faces[fid])
	outcome["amount"] = amt
	outcome["max_amount"] = max_amount
	return outcome


## Point table: label -> Vector3, every record created exactly once. Each face
## that uses a record gets its own position COPY (position privacy), and the
## weld rebuild reconnects the coincident copies into shared groups.
static func _bevel_build(mesh_data: PBMeshData, lookup: Dictionary, valid: Dictionary,
		loops: Dictionary, normals: Dictionary, incidence: Dictionary,
		bev_at: Dictionary, rep_index: Dictionary, amt: float, segments: int) -> Dictionary:
	var pts := {}          # label -> Vector3
	var src_of := {}       # label -> source position index (attribute donor)
	var pos_cache := {}    # (owner, label) -> position index owned by that face
	var wedge := {}        # fi -> { loop_index -> [labels] } in boundary order
	var corner_of := {}    # fi -> { vrep -> loop_index }
	# Smooth shading: every face the op adds (strips, domes) wears ONE fresh
	# smoothing group, so the whole fillet shades continuously within itself —
	# across seam rails, corner rails and dome bands alike. The adjacent
	# (rebuilt) faces keep group 0, so the fillet still creases sharply where
	# it meets the untouched flat surface.
	var smooth_sg := 1
	for face in mesh_data.faces:
		if face != null:
			smooth_sg = maxi(smooth_sg, face.smoothing_group + 1)

	# ---- corner wedges + tips -------------------------------------------------
	# Slide points are created lazily here (not just for beveled edges: b==0
	# and b==1 corners slide along UNbeveled leading edges). The first face to
	# reference a (edge, end) point computes it; every later face reuses the
	# exact record, which is what keeps coincident copies weldable.
	for fi: int in loops:
		var loop: PackedInt32Array = loops[fi]
		var n := loop.size()
		var fw := {}
		var co := {}
		for i in range(n):
			var vi: int = loop[i]
			var vrep: int = int(lookup.get(vi, vi))
			if co.has(vrep):
				return _fail("Bevel edges: a face touches the same corner twice (a knife cut's splice slit can fold a face boundary onto itself) — the bevel cannot run through a self-touching face")
			co[vrep] = i
			if not bev_at.has(vrep):
				continue
			var v_prev: int = loop[(i - 1 + n) % n]
			var v_next: int = loop[(i + 1) % n]
			var k_prev := _key(lookup, vi, v_prev)
			var k_next := _key(lookup, vi, v_next)
			var b_prev: bool = valid.has(k_prev)
			var b_next: bool = valid.has(k_next)
			var labels: Array = []
			if b_prev and b_next:
				var tip_label := _tip_label(fi, vrep)
				if not pts.has(tip_label):
					var p: Vector3 = mesh_data.positions[vi]
					var d1 := (mesh_data.positions[v_prev] - p).normalized() * amt
					var d2 := (mesh_data.positions[v_next] - p).normalized() * amt
					pts[tip_label] = p + d1 + d2
					src_of[tip_label] = vi
				labels = [tip_label]
			elif b_prev:
				labels = [_ensure_sp(mesh_data, pts, src_of, k_next, vrep, vi, v_next, amt)]
			elif b_next:
				labels = [_ensure_sp(mesh_data, pts, src_of, k_prev, vrep, vi, v_prev, amt)]
			else:
				labels = [
					_ensure_sp(mesh_data, pts, src_of, k_prev, vrep, vi, v_prev, amt),
					_ensure_sp(mesh_data, pts, src_of, k_next, vrep, vi, v_next, amt),
				]
			fw[i] = labels
		if not fw.is_empty():
			wedge[fi] = fw
			corner_of[fi] = co

	# ---- loop-corner rails -----------------------------------------------------
	# Where exactly two beveled edges meet at a vertex and both rails run
	# between the SAME two wedge points, the rails become one shared straight
	# polyline and no cap is emitted (the strips glue along it).
	var seam_ends := {}    # vrep -> true
	for c: int in bev_at:
		if int(bev_at[c]) != 2:
			continue
		var pair: Array = []
		for k: Vector2i in valid:
			if k.x != c and k.y != c:
				continue
			var labels := {}
			for e: Dictionary in valid[k]:
				var wl := _wedge_label(wedge, corner_of, int(e["fi"]), c)
				if wl.is_empty():
					return _fail("Bevel edges: internal error resolving corner wedge")
				labels[wl] = true
			pair.append(labels)
		if pair.size() == 2 and _same_label_set(pair[0], pair[1]):
			seam_ends[c] = true

	# ---- shared corner rails at loop corners ----------------------------------
	# A loop corner's two strips must share ONE rail polyline (they glue along
	# it), so its interior points cannot come from either edge's own cap-plane
	# arc — those differ per edge and would tear the corner open. With more
	# than one segment the shared rail is the tangent arc in the CORNER plane
	# (through the two wedge points and the original corner): tangent to the
	# wedge faces where it meets them, bulging toward the corner like any
	# rounded profile. One segment keeps the plain straight miter.
	var corner_rail := {}   # vrep -> { s -> Vector3 }
	for c: int in seam_ends:
		if segments < 2:
			continue
		var by_label := {}
		for k: Vector2i in valid:
			if k.x != c and k.y != c:
				continue
			for e: Dictionary in valid[k]:
				var wl := _wedge_label(wedge, corner_of, int(e["fi"]), c)
				if wl.is_empty():
					return _fail("Bevel edges: internal error resolving corner wedge")
				if not by_label.has(wl):
					by_label[wl] = []
				by_label[wl].append(normals[int(e["fi"])] as Vector3)
		if by_label.size() != 2:
			continue
		var labels: Array = by_label.keys()
		var wl_a: String = labels[0]
		var wl_b: String = labels[1]
		var n_a := Vector3.ZERO
		var n_b := Vector3.ZERO
		for n in by_label[wl_a]:
			n_a += n
		for n in by_label[wl_b]:
			n_b += n
		n_a = n_a.normalized()
		n_b = n_b.normalized()
		var corner_pos: Vector3 = mesh_data.positions[int(rep_index.get(c, 0))]
		var plane_n: Vector3 = (pts[wl_a] - corner_pos).cross(pts[wl_b] - corner_pos)
		if plane_n.length_squared() < 0.000000000001:
			continue
		var per_s := {}
		for s in range(1, segments):
			per_s[s] = _arc_point(pts[wl_a], pts[wl_b], corner_pos, plane_n,
				n_a, n_b, float(s) / float(segments))
		corner_rail[c] = per_s

	# ---- rail interiors: arcs (or the shared straight seam line) ---------------
	for k: Vector2i in valid:
		var entries: Array = valid[k]
		var fa: int = entries[0]["fi"]
		var fb: int = entries[1]["fi"]
		# Direction from the edge's own endpoint POSITION indexes (the key k
		# holds weld-group ids, which are not position indexes).
		var edge_dir: Vector3 = mesh_data.positions[int(entries[0]["vb"])] \
			- mesh_data.positions[int(entries[0]["va"])]
		for c: int in [k.x, k.y]:
			var pa := _wedge_label(wedge, corner_of, fa, c)
			var pb := _wedge_label(wedge, corner_of, fb, c)
			if pa.is_empty() or pb.is_empty():
				return _fail("Bevel edges: internal error resolving rail endpoints")
			var corner: Vector3 = mesh_data.positions[int(rep_index.get(c, src_of[pa]))]
			for s in range(1, segments):
				var lbl := _arc_label(k, c, s)
				if seam_ends.has(c):
					var shared: Dictionary = corner_rail.get(c, {})
					pts[lbl] = shared.get(s, pts[pa].lerp(pts[pb], float(s) / float(segments)))
				else:
					pts[lbl] = _arc_point(pts[pa], pts[pb], corner, edge_dir,
						normals[fa], normals[fb], float(s) / float(segments))
				src_of[lbl] = src_of[pa]

	# ---- rebuild touched faces ---------------------------------------------------
	var removed := {}
	var primary: Array[PBFace] = []
	var rebuilt_by_fi := {}   # fi -> the face that replaced it (UV anchor source)
	for fi: int in loops:
		var fw: Dictionary = wedge.get(fi, {})
		if fw.is_empty():
			continue
		var loop: PackedInt32Array = loops[fi]
		var n := loop.size()
		var new_loop := PackedInt32Array()
		var owner := "face:%d" % fi
		for i in range(n):
			if fw.has(i):
				for label: String in fw[i]:
					new_loop.append(_record_position(mesh_data, pts, src_of, pos_cache, owner, label))
			else:
				new_loop.append(loop[i])
		var rebuilt := _face_from_indices(mesh_data, new_loop, mesh_data.faces[fi], normals[fi])
		if rebuilt == null:
			return _fail("Bevel edges: a face did not survive the bevel (degenerate corner)")
		removed[fi] = true
		rebuilt_by_fi[fi] = rebuilt
		primary.append(rebuilt)

	# ---- strips along each beveled edge -----------------------------------------
	var secondary: Array[PBFace] = []
	for k: Vector2i in valid:
		var entries: Array = valid[k]
		var fa: int = entries[0]["fi"]
		var fb: int = entries[1]["fi"]
		var rail_a := _rail_labels(valid, wedge, corner_of, k, k.x, segments)
		var rail_b := _rail_labels(valid, wedge, corner_of, k, k.y, segments)
		if rail_a.size() != segments + 1 or rail_b.size() != segments + 1:
			return _fail("Bevel edges: could not resolve the rail endpoints of a beveled edge")
		var band: Vector3 = (normals[fa] + normals[fb]).normalized()
		if band.length_squared() < 0.25:
			band = normals[fa]
		var owner := "strip:%d,%d" % [k.x, k.y]
		var strip_faces: Array[PBFace] = []
		var strip_idx_a: Array = []
		var strip_idx_b: Array = []
		for s in range(segments + 1):
			strip_idx_a.append(_record_position(mesh_data, pts, src_of, pos_cache, owner, rail_a[s]))
			strip_idx_b.append(_record_position(mesh_data, pts, src_of, pos_cache, owner, rail_b[s]))
		for s in range(segments):
			var quad := PackedInt32Array([
				strip_idx_a[s],
				strip_idx_b[s],
				strip_idx_b[s + 1],
				strip_idx_a[s + 1],
			])
			var f := _face_from_indices(mesh_data, quad, mesh_data.faces[fa], band)
			if f == null:
				return _fail("Bevel edges: a bevel strip quad collapsed")
			f.smoothing_group = smooth_sg
			secondary.append(f)
			strip_faces.append(f)
		# UVs: continue the better-adjacent face's own auto mapping across the
		# band (seamless along that rail, texel density kept 1:1 down the
		# slope) instead of the strip's own dominant-axis projection, whose u
		# axis flips at the 45-degree tie and whose grout phase never lines up
		# with either neighbour. On failure the strips just stay auto.
		var strip_dir: Vector3 = mesh_data.positions[int(entries[0]["vb"])] \
			- mesh_data.positions[int(entries[0]["va"])]
		var uv_map := _strip_uv_map(mesh_data, rebuilt_by_fi, fa, fb, normals,
			strip_dir, pts, rail_a, rail_b, segments)
		if not uv_map.is_empty():
			for s in range(segments + 1):
				mesh_data.textures0[strip_idx_a[s]] = uv_map[rail_a[s]]
				mesh_data.textures0[strip_idx_b[s]] = uv_map[rail_b[s]]
			for f in strip_faces:
				f.manual_uv = true

	# ---- corner caps ---------------------------------------------------------------
	for c: int in bev_at:
		if seam_ends.has(c):
			continue
		var cycle := _vertex_face_cycle(c, wedge, corner_of, loops, incidence, lookup)
		if cycle.is_empty():
			return _fail("Bevel edges: open or non-manifold boundary at the beveled corner %s"
				% str(mesh_data.positions[int(rep_index.get(c, 0))]))
		var ring: Array = []
		var outward := Vector3.ZERO
		var fan_normals: Array = []
		for entry: Dictionary in cycle:
			var fi: int = entry["fi"]
			outward += normals[fi] as Vector3
			fan_normals.append(normals[fi])
			for label: String in wedge[fi][int(entry["i"])]:
				_ring_push(ring, label, pts)
			# Crossing to the next face of the fan: when the shared edge is
			# beveled, its strip-end arc belongs to this cap ring too.
			var k_next: Vector2i = entry["k_next"]
			if valid.has(k_next):
				var entries: Array = valid[k_next]
				for s in range(1, segments):
					var fwd := 1 if entries[0]["fi"] == fi else -1
					var idx := s if fwd > 0 else segments - s
					_ring_push(ring, _arc_label(k_next, c, idx), pts)
		# Close the walk: the ring may retrace its start (a corner whose fan
		# wedges collapse to two points needs no cap at all).
		while ring.size() > 1 and (ring[0] == ring[ring.size() - 1]
				or pts[ring[0]].distance_to(pts[ring[ring.size() - 1]]) < 0.000001):
			ring.remove_at(ring.size() - 1)
		var distinct := {}
		for label: String in ring:
			distinct[label] = true
		if distinct.size() < 3:
			continue
		var area := _ring_area(ring, pts)
		if OS.get_environment("PB_BEVEL_TRACE") != "":
			var dump2 := PackedStringArray()
			for label: String in ring:
				dump2.append("%s=%s" % [label, str(pts[label])])
			print("[bevel] cap vrep %d area=%s iszero=%s lt=%s ring=%s" % [c, str(area), str(area == 0.0), str(area < 0.000000001), str(ring)])
		if area < 0.000000001:
			continue
		var cap_fi: int = cycle[0]["fi"]
		var owner := "cap:%d" % c
		var cap_loop := PackedInt32Array()
		for label: String in ring:
			cap_loop.append(_record_position(mesh_data, pts, src_of, pos_cache, owner, label))
		# Multi-segment corners get a DOME (Blender's "cutoff" vertex mesh):
		# the ring is inset in one or more concentric rings stepping down
		# toward the fillet sphere's apex and the innermost ring becomes a
		# small flat n-gon. The old fan-from-centroid cut flat triangles
		# across the curved ring and dented the corner inward. Only corners
		# with TWO OR MORE beveled edges dome (their strips' end arcs curve
		# the ring around the corner); a terminal cap (one beveled edge,
		# ring = two slides + one arc) is the flat closure of the fillet end
		# and stays a single face. One-segment caps keep the flat chamfer cut.
		var arc_edges := {}
		for label: String in ring:
			if label.begins_with("arc:"):
				arc_edges[label.split(":")[1]] = true
		if segments >= 2 and arc_edges.size() >= 2:
			var dome: Array[PBFace] = []
			if _build_cap_dome(mesh_data, ring, cap_loop, pts, fan_normals,
					mesh_data.positions[int(rep_index.get(c, 0))], amt, segments,
					mesh_data.faces[cap_fi], dome):
				for f in dome:
					f.smoothing_group = smooth_sg
					secondary.append(f)
				continue
		# Small/planar caps ear-clip; big curved caps (S > 1 real corners) fan
		# from their centroid — one symmetric patch instead of arbitrary
		# chords that dish into the corner.
		var cap: PBFace
		if ring.size() >= 5:
			cap = _fan_cap(mesh_data, cap_loop, outward.normalized(), mesh_data.faces[cap_fi])
		else:
			cap = _face_from_indices(mesh_data, cap_loop, mesh_data.faces[cap_fi], outward.normalized())
		if cap == null:
			if OS.get_environment("PB_BEVEL_TRACE") != "":
				var dump3 := PackedStringArray()
				for idx3 in cap_loop:
					dump3.append(str(mesh_data.positions[idx3]))
				print("[bevel] cap vrep %d (rep_known=%s) FAILED loop(%d): %s outward=%s" % [c, str(rep_index.has(c)), cap_loop.size(), " | ".join(dump3), str(outward.normalized())])
			return _fail("Bevel edges: the corner cap at %s collapsed"
				% str(mesh_data.positions[int(rep_index.get(c, 0))]))
		secondary.append(cap)

	return PBMeshOps._replace_faces(mesh_data, removed, primary, secondary)


## Corner dome for a multi-segment cap (Blender's vertex mesh for beveled
## corners, which blends its edge profiles across the corner onto the fillet
## sphere): the boundary ring — the strips' end rails — is inset through
## `segments - 1` rings that SPHERICALLY BLEND it into the fillet sphere's
## apex (the surface point closest to the original corner). Ring point (r, i)
## rides the ray from the sphere's centre through the boundary point's blend
## direction, its radius easing to the sphere radius amt — an exact identity
## at the boundary and sphere-true inside, so the corner curve matches the
## strips' profiles. The innermost ring becomes a small FLAT n-gon ("flat
## triangle fan"). The dome carries one uniform planar UV projection
## (dominant-axis basis of its outward normal, anchored to the object's
## texture anchor, tiled by the template's settings) — the same convention
## as every auto-projected face, so corner patches keep 1:1 texel density on
## the world grid instead of re-projecting diagonally or smearing.
## The boundary ring's position copies are already recorded by the caller in
## `ring0_idx` (same order as `ring`); new faces are appended to `dome`.
## Returns false when the construction degenerates — the caller keeps the
## flat chamfer cap.
static func _build_cap_dome(mesh_data: PBMeshData, ring: Array, ring0_idx: PackedInt32Array,
		pts: Dictionary, fan_normals: Array, corner: Vector3, amt: float, segments: int,
		template: PBFace, dome: Array[PBFace]) -> bool:
	var count := ring.size()
	if count < 3 or ring0_idx.size() != count:
		return false
	var w := Vector3.ZERO
	for n_v in fan_normals:
		w += n_v
	w = -w.normalized()
	if w.length_squared() < 0.5:
		return false
	# Fillet sphere: tangent to every fan face's plane at depth amt, so its
	# centre sits d_c down w from the corner (faces whose normal is nearly
	# perpendicular to w don't constrain the depth and are skipped) and the
	# apex — the dome's outermost point — at d_c - amt.
	var d_sum := 0.0
	var d_count := 0
	for n_v in fan_normals:
		var dn: float = w.dot(n_v)
		if dn < -0.2:
			d_sum += -amt / dn
			d_count += 1
	if d_count == 0:
		return false
	var d_c := d_sum / float(d_count)
	var h_apex := d_c - amt
	if OS.get_environment("PB_BEVEL_TRACE") != "":
		print("[dome] count=%d w=%s d_c=%.4f h_apex=%.4f" % [count, str(w), d_c, h_apex])
	if h_apex <= 0.000001 or h_apex >= amt * 4.0:
		return false
	# Dome UVs: a uniform planar projection across the whole patch — the
	# dominant-axis basis of the dome's own outward normal, phase-locked to
	# the object's texture anchor and scaled by the template's tiling, i.e.
	# the same convention every auto-projected face uses. Continuing the
	# neighbouring strips' mappings instead produced star-shaped streaks: the
	# strips carry unrelated per-face mappings, and no single dome mapping
	# can be continuous with all of them, so the dome is its own cleanly
	# projected patch at 1:1 texel density on the world grid.
	var outward_n := -w
	var basis := PBUv.get_planar_basis(outward_n)
	var bu: Vector3 = basis["u"]
	var bv: Vector3 = basis["v"]
	var anchor_uv := Vector2.ZERO
	if not template.uv_use_world_space:
		var anchor: Vector3 = mesh_data.get_texture_anchor()
		anchor_uv = Vector2(bu.dot(anchor), bv.dot(anchor))
	var rot_rad := deg_to_rad(template.uv_rotation)
	var cos_r := cos(rot_rad)
	var sin_r := sin(rot_rad)
	var dome_uv := func(p: Vector3) -> Vector2:
		var uv := Vector2(bu.dot(p), bv.dot(p)) - anchor_uv
		if template.uv_flip_u:
			uv.x = -uv.x
		if template.uv_flip_v:
			uv.y = -uv.y
		if template.uv_swap_uv:
			var tmp := uv.x
			uv.x = uv.y
			uv.y = tmp
		if template.uv_rotation != 0.0:
			var sx := uv.x * template.uv_scale.x
			var sy := uv.y * template.uv_scale.y
			uv = Vector2(sx * cos_r - sy * sin_r, sx * sin_r + sy * cos_r) + template.uv_offset
		else:
			uv = Vector2(uv.x * template.uv_scale.x, uv.y * template.uv_scale.y) + template.uv_offset
		return uv
	# Positions + UVs. The inset rings SPHERICALLY BLEND the boundary ring
	# into the apex: ring point (r, i) rides the ray from the fillet sphere's
	# CENTRE through the boundary point's blend direction, its radius easing
	# from the boundary point's own radius to the sphere radius amt. At
	# r = 0 the formula is an exact identity, and deeper rings stay ON the
	# sphere the edge fillets are tangent to — the corner curve matches the
	# strips' profiles the way Blender's vertex mesh blends its edge profiles.
	var centre := corner + w * d_c
	var apex_dir := -w
	var dirs: Array[Vector3] = []
	var radii: Array[float] = []
	for i in range(count):
		var rel: Vector3 = pts[ring[i]] - centre
		radii.append(rel.length())
		dirs.append(rel / radii[i])
	var prev_pts: Array[Vector3] = []
	var prev_uvs: Array[Vector2] = []
	for i in range(count):
		prev_pts.append(pts[ring[i]])
		prev_uvs.append(dome_uv.call(pts[ring[i]]))
	# Every band quad gets PRIVATE copies of its four corners:
	# calculate_normals is "last triangle wins per position", so rings shared
	# between the band above and the band below — then overwritten by the
	# final face — shaded with whichever face was built last, the pinch ring
	# around the inner n-gon. Private copies give each quad its own flat
	# normal, consistent with the engine's flat shading; the weld rebuild
	# reconnects the coincident copies across bands, so the surface stays
	# watertight.
	for r in range(1, segments):
		var t := float(r) / float(segments)
		var row_pts: Array[Vector3] = []
		var row_uvs: Array[Vector2] = []
		for i in range(count):
			var dir := dirs[i].lerp(apex_dir, t).normalized()
			var p := centre + dir * lerpf(radii[i], amt, t)
			row_pts.append(p)
			row_uvs.append(dome_uv.call(p))
		for i in range(count):
			var i1 := (i + 1) % count
			var a := PBMeshOps._dup_position_at(mesh_data, prev_pts[i], ring0_idx[i])
			var b := PBMeshOps._dup_position_at(mesh_data, prev_pts[i1], ring0_idx[i])
			var c := PBMeshOps._dup_position_at(mesh_data, row_pts[i1], ring0_idx[i])
			var d := PBMeshOps._dup_position_at(mesh_data, row_pts[i], ring0_idx[i])
			mesh_data.textures0[a] = prev_uvs[i]
			mesh_data.textures0[b] = prev_uvs[i1]
			mesh_data.textures0[c] = row_uvs[i1]
			mesh_data.textures0[d] = row_uvs[i]
			var f := _face_from_indices(mesh_data, PackedInt32Array([a, b, c, d]), template, outward_n)
			if f == null:
				return false
			f.manual_uv = true
			dome.append(f)
		prev_pts = row_pts
		prev_uvs = row_uvs
	# The small flat final face ("flat triangle fan") with its own corner
	# copies, so its flat normal cannot leak into the last band's shading.
	var final_idx := PackedInt32Array()
	for i in range(count):
		var idx := PBMeshOps._dup_position_at(mesh_data, prev_pts[i], ring0_idx[i])
		mesh_data.textures0[idx] = prev_uvs[i]
		final_idx.append(idx)
	var final := _face_from_indices(mesh_data, final_idx, template, outward_n)
	if final == null:
		return false
	final.manual_uv = true
	dome.append(final)
	return true


# ==============================================================================
# Rails, wedges, fans
# ==============================================================================

## Point labels of the rail at end `c` of beveled edge k: face A's wedge point,
## the arc interiors, face B's wedge point.
static func _rail_labels(valid: Dictionary, wedge: Dictionary, corner_of: Dictionary,
		k: Vector2i, c: int, segments: int) -> Array:
	var out: Array = []
	var entries: Array = valid[k]
	for side in range(2):
		if side == 1:
			for s in range(1, segments):
				out.append(_arc_label(k, c, s))
		var wl := _wedge_label(wedge, corner_of, int(entries[side]["fi"]), c)
		if wl.is_empty():
			return []
		out.append(wl)
	return out


## Rounded-profile point between the rail points `pa` (on face A) and `pb`
## (on face B) at end corner `corner` of beveled edge with direction
## `edge_dir`: the circular arc in the edge's end-cap plane (through the
## ORIGINAL corner, perpendicular to the edge) that is tangent to face A at
## `pa` and to face B at `pb` — the same quarter-circle fillet Blender's
## profile draws between two faces' retracted rails. Anchoring to the original
## corner (not to the rails alone) is what keeps the arc from degenerating
## when one rail is a loop-corner tip point whose offset runs partly ALONG the
## edge; that along-edge slide is blended linearly across the arc instead.
## Falls back to a straight lerp when the tangent construction degenerates.
static func _arc_point(pa: Vector3, pb: Vector3, corner: Vector3, edge_dir: Vector3,
		na: Vector3, nb: Vector3, t: float) -> Vector3:
	var dir := edge_dir.normalized()
	if dir.length_squared() < 0.5:
		return pa.lerp(pb, t)
	var q0 := pa - corner
	var q1 := pb - corner
	var e0 := q0.dot(dir)
	var e1 := q1.dot(dir)
	var u0 := q0 - dir * e0
	var u1 := q1 - dir * e1
	var n0 := na - dir * na.dot(dir)
	var n1 := nb - dir * nb.dot(dir)
	if n0.length_squared() < 0.000001 or n1.length_squared() < 0.000001:
		return pa.lerp(pb, t)
	n0 = n0.normalized()
	n1 = n1.normalized()
	# Tangent circle in the cap plane: centre = u0 - n0*R = u1 - n1*R'. Solve
	# the 2x2 system [n0 | -n1] [R, R']^T = u0 - u1 (2D cross products taken
	# against the cap-plane normal `dir`; 90-degree and tip-offset rails both
	# solve exactly, unlike a least-squares fit through the raw points).
	var a2 := -n1
	var rhs := u0 - u1
	var det := n0.cross(a2).dot(dir)
	if absf(det) < 0.000001:
		return pa.lerp(pb, t)
	var r := rhs.cross(a2).dot(dir) / det
	var centre := u0 - n0 * r
	var w0 := u0 - centre
	var w1 := u1 - centre
	var l0 := w0.length()
	var l1 := w1.length()
	if l0 < 0.000001 or l1 < 0.000001:
		return pa.lerp(pb, t)
	var angle := atan2(w0.cross(w1).dot(dir), w0.dot(w1))
	var w_t := w0.rotated(dir, angle * t)
	return corner + centre + (w_t / l0) * lerpf(l0, l1, t) + dir * lerpf(e0, e1, t)


## UVs for one bevel strip band: the anchor face's auto mapping (the face
## whose auto U axis runs along the edge; equal alignment goes to the bigger
## face) continues across the band — seamless along its rail, as if the edge
## were straightened out. Each auto axis that runs TRANSVERSE to the edge has
## its far rail re-measured by the rail-to-rail chord at the face's texel
## rate: a planar continuation alone compresses the band by cos of the
## dihedral, and for a vertical corner (both walls' transverse phases
## coincide at the corner) it cancels to a constant — stretched slivers.
## The axis parallel to the edge continues exactly and is left alone, so it
## stays phase-true with both walls along the rails.
## `rebuilt` maps the face indexes of the two adjacent faces to their rebuilt
## replacements (the UV source). Returns { point label -> uv }, or {} when the
## continuation cannot be solved — the caller leaves the strip auto-projected.
static func _strip_uv_map(mesh_data: PBMeshData, rebuilt: Dictionary, fi_a: int, fi_b: int,
		normals: Dictionary, edge_dir: Vector3, pts: Dictionary,
		rail_a: Array, rail_b: Array, segments: int) -> Dictionary:
	var face_a: PBFace = rebuilt.get(fi_a)
	var face_b: PBFace = rebuilt.get(fi_b)
	if face_a == null or face_b == null:
		return {}
	# Anchor choice: the face whose auto U axis runs along the edge; equal
	# alignment (the usual top-vs-side wall) goes to the bigger face, since
	# that is the one the eye reads as the reference.
	var basis_a := PBUv.get_planar_basis(normals[fi_a])
	var basis_b := PBUv.get_planar_basis(normals[fi_b])
	var along_a := absf((basis_a["u"] as Vector3).dot(edge_dir))
	var along_b := absf((basis_b["u"] as Vector3).dot(edge_dir))
	var a_is_anchor := along_a > along_b + 0.001
	if absf(along_a - along_b) <= 0.001:
		a_is_anchor = PBMeshOps._face_area_normal(mesh_data, mesh_data.faces[fi_a]).length() \
			>= PBMeshOps._face_area_normal(mesh_data, mesh_data.faces[fi_b]).length()
	var anchor_fi: int = fi_a if a_is_anchor else fi_b
	var anchor_affine := _face_affine_uv(mesh_data, rebuilt[anchor_fi], normals[anchor_fi])
	if anchor_affine.is_empty():
		return {}
	var u_axis: Vector3 = basis_a["u"] if a_is_anchor else basis_b["u"]
	var v_axis: Vector3 = basis_a["v"] if a_is_anchor else basis_b["v"]
	var edge_n := edge_dir.normalized()
	var u_transverse := absf(u_axis.dot(edge_n)) < 0.5
	var v_transverse := absf(v_axis.dot(edge_n)) < 0.5
	var template: PBFace = mesh_data.faces[anchor_fi]
	var axis_simple := template.uv_rotation == 0.0 and not template.uv_swap_uv

	var map := {}
	var near_wedge := 0 if a_is_anchor else segments   # rail index of the anchor's wedge
	var far_wedge := segments if a_is_anchor else 0
	for end_i in range(2):
		var near_lbl: String = rail_a[near_wedge] if end_i == 0 else rail_b[near_wedge]
		var far_lbl: String = rail_a[far_wedge] if end_i == 0 else rail_b[far_wedge]
		var uv_near: Vector2 = anchor_affine["uv"].call(pts[near_lbl])
		var uv_far: Vector2 = anchor_affine["uv"].call(pts[far_lbl])
		var chord: float = pts[far_lbl].distance_to(pts[near_lbl])
		if chord > 0.000001 and axis_simple:
			var chord_dir: Vector3 = (pts[far_lbl] - pts[near_lbl]) / chord
			if u_transverse:
				var usign := signf(u_axis.dot(chord_dir))
				if usign == 0.0:
					usign = 1.0
				uv_far.x = uv_near.x + usign * chord * template.uv_scale.x
			if v_transverse:
				var vsign := signf(v_axis.dot(chord_dir))
				if vsign == 0.0:
					vsign = 1.0
				uv_far.y = uv_near.y + vsign * chord * template.uv_scale.y
		map[near_lbl] = uv_near
		map[far_lbl] = uv_far
		var rail: Array = rail_a if end_i == 0 else rail_b
		for s in range(1, segments):
			var t := float(s) / float(segments)
			var uv: Vector2 = anchor_affine["uv"].call(pts[rail[s]])
			if u_transverse:
				uv.x = lerpf(uv_near.x, uv_far.x, t)
			if v_transverse:
				uv.y = lerpf(uv_near.y, uv_far.y, t)
			map[rail[s]] = uv
	return map


## Affine map (raw plane coords -> rendered UV) of a rebuilt face, solved from
## three of its corners; points on the face's plane evaluate exactly, so the
## result inherits anchoring, flips, swap, scale, rotation and offset verbatim
## from PBUv.calculate_face_uvs. Returns {} when the solve is degenerate,
## else { "uv": Callable(Vector3) -> Vector2 }.
static func _face_affine_uv(mesh_data: PBMeshData, face: PBFace, normal: Vector3) -> Dictionary:
	var basis := PBUv.get_planar_basis(normal)
	var u_axis: Vector3 = basis["u"]
	var v_axis: Vector3 = basis["v"]
	var uvs := PBUv.calculate_face_uvs(mesh_data, face)
	var corners := face.get_distinct_indexes()
	var raws: Array[Vector2] = []
	var wants: Array[Vector2] = []
	for idx in corners:
		if not uvs.has(idx):
			return {}
		raws.append(Vector2(u_axis.dot(mesh_data.positions[idx]), v_axis.dot(mesh_data.positions[idx])))
		wants.append(uvs[idx])
	if raws.size() < 3:
		return {}
	var i1 := 1
	var i2 := 2
	var best := -1.0
	for i in range(1, raws.size()):
		for j in range(i + 1, raws.size()):
			var cr := absf((raws[i] - raws[0]).cross(raws[j] - raws[0]))
			if cr > best:
				best = cr
				i1 = i
				i2 = j
	var d1 := raws[i1] - raws[0]
	var d2 := raws[i2] - raws[0]
	var det := d1.cross(d2)
	if absf(det) < 0.000001:
		return {}
	var e1 := (wants[i1] - wants[0])
	var e2 := (wants[i2] - wants[0])
	# Row-major M with uv = M·raw + t, solved from M·d1 = e1 and M·d2 = e2.
	var inv_det := 1.0 / det
	var m00 := (e1.x * d2.y - d1.y * e2.x) * inv_det
	var m01 := (d1.x * e2.x - e1.x * d2.x) * inv_det
	var m10 := (e1.y * d2.y - d1.y * e2.y) * inv_det
	var m11 := (d1.x * e2.y - e1.y * d2.x) * inv_det
	var t_vec := wants[0] - Vector2(m00 * raws[0].x + m01 * raws[0].y, m10 * raws[0].x + m11 * raws[0].y)
	var uv := func(p: Vector3) -> Vector2:
		var raw := Vector2(u_axis.dot(p), v_axis.dot(p))
		return Vector2(m00 * raw.x + m01 * raw.y, m10 * raw.x + m11 * raw.y) + t_vec
	return {"uv": uv}


## The slide point on edge `k` at weld-group end `end`, created on first use
## from the requesting face's corner `vi` and its perimeter neighbour along
## the edge. Every later face reuses the exact record, which is what keeps the
## coincident per-face copies weldable.
static func _ensure_sp(mesh_data: PBMeshData, pts: Dictionary, src_of: Dictionary,
		k: Vector2i, end: int, vi: int, v_other: int, amt: float) -> String:
	var lbl := _sp_label(k, end)
	if pts.has(lbl):
		return lbl
	var p: Vector3 = mesh_data.positions[vi]
	var dir := (mesh_data.positions[v_other] - p).normalized()
	pts[lbl] = p + dir * amt
	src_of[lbl] = vi
	return lbl


## The single wedge label face `fi` contributes at corner `c` (a rail-end face
## always has exactly one). Empty string when there is no such corner record.
static func _wedge_label(wedge: Dictionary, corner_of: Dictionary, fi: int, c: int) -> String:
	if not wedge.has(fi) or not corner_of.has(fi):
		return ""
	var co: Dictionary = corner_of[fi]
	if not co.has(c):
		return ""
	var labels: Array = wedge[fi][co[c]]
	if labels.size() != 1:
		return ""
	return labels[0]


static func _same_label_set(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for key in a:
		if not b.has(key):
			return false
	return true


## Face fan around beveled vertex c in outgoing-edge order. Each entry is
## { fi, i, k_next }. Empty when the fan is open or non-manifold.
static func _vertex_face_cycle(c: int, wedge: Dictionary, corner_of: Dictionary,
		loops: Dictionary, incidence: Dictionary, lookup: Dictionary) -> Array:
	var start_fi := -1
	var want := 0
	for fi: int in wedge:
		if corner_of[fi].has(c):
			want += 1
			if start_fi < 0:
				start_fi = fi
	if start_fi < 0:
		return []
	var cycle: Array = []
	var cur_fi := start_fi
	for _guard in range(256):
		var i: int = corner_of[cur_fi][c]
		var k_next := _outgoing_edge_key(loops[cur_fi], lookup, c)
		if k_next == Vector2i.ZERO:
			return []
		cycle.append({"fi": cur_fi, "i": i, "k_next": k_next})
		var entries: Array = incidence.get(k_next, [])
		if entries.size() != 2:
			return []
		var nxt_fi: int = int(entries[0]["fi"]) if int(entries[1]["fi"]) == cur_fi else int(entries[1]["fi"])
		if not wedge.has(nxt_fi) or not corner_of[nxt_fi].has(c):
			return []
		if nxt_fi == start_fi:
			return cycle if cycle.size() == want else []
		cur_fi = nxt_fi
	return []


## Key of the perimeter edge that leaves corner c along face `loop`'s winding.
static func _outgoing_edge_key(loop: PackedInt32Array, lookup: Dictionary, c: int) -> Vector2i:
	var n := loop.size()
	for i in range(n):
		if int(lookup.get(loop[i], loop[i])) == c:
			return _key(lookup, loop[i], loop[(i + 1) % n])
	return Vector2i.ZERO


static func _ring_push(ring: Array, label: String, pts: Dictionary) -> void:
	if not ring.is_empty():
		var last: String = ring[ring.size() - 1]
		if last == label or pts[last].distance_to(pts[label]) < 0.000001:
			return
	ring.append(label)


## Newell area of a label ring (half the vector's length) — zero when the ring
## retraces itself and bounds nothing.
static func _ring_area(ring: Array, pts: Dictionary) -> float:
	var acc := Vector3.ZERO
	var count := ring.size()
	for i in range(count):
		var cur: Vector3 = pts[ring[i]]
		var nxt: Vector3 = pts[ring[(i + 1) % count]]
		acc.x += (cur.y - nxt.y) * (cur.z + nxt.z)
		acc.y += (cur.z - nxt.z) * (cur.x + nxt.x)
		acc.z += (cur.x - nxt.x) * (cur.y + nxt.y)
	return acc.length() * 0.5


static func _arc_label(k: Vector2i, c: int, s: int) -> String:
	return "arc:%d,%d:%d:%d" % [k.x, k.y, c, s]


static func _sp_label(k: Vector2i, c: int) -> String:
	return "sp:%d,%d:%d" % [k.x, k.y, c]


static func _tip_label(fi: int, c: int) -> String:
	return "tip:%d:%d" % [fi, c]


## The face-private position for a point record: one copy per (owner, label).
static func _record_position(mesh_data: PBMeshData, pts: Dictionary, src_of: Dictionary,
		pos_cache: Dictionary, owner: String, label: String) -> int:
	var key := owner + "|" + label
	if pos_cache.has(key):
		return pos_cache[key]
	var idx := PBMeshOps._dup_position_at(mesh_data, pts[label], int(src_of[label]))
	pos_cache[key] = idx
	return idx


# ==============================================================================
# Faces from explicit index loops
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
	# overlapping triangles; reject that here and let the caller fail cleanly.
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


## Corner cap as a fan from the ring centroid: the centroid becomes one new
## position and the ring triangulates around it (its perimeter stays the ring,
## since interior fan edges cancel in PBFace.get_edges). Returns null when the
## ring is degenerate.
static func _fan_cap(mesh_data: PBMeshData, loop_idx: PackedInt32Array,
		outward: Vector3, template: PBFace) -> PBFace:
	var clean := PackedInt32Array()
	for i in range(loop_idx.size()):
		if clean.size() > 0:
			if loop_idx[i] == clean[clean.size() - 1]:
				continue
			if mesh_data.positions[loop_idx[i]].distance_squared_to(mesh_data.positions[clean[clean.size() - 1]]) < 0.000000000001:
				continue
		clean.append(loop_idx[i])
	while clean.size() > 1 and (clean[0] == clean[clean.size() - 1]
			or mesh_data.positions[clean[0]].distance_squared_to(mesh_data.positions[clean[clean.size() - 1]]) < 0.000000000001):
		clean.remove_at(clean.size() - 1)
	if clean.size() < 3:
		return null
	var ring_normal := _newell_normal(mesh_data, clean)
	if ring_normal.length_squared() < 0.000000000001:
		return null
	if ring_normal.dot(outward) < 0.0:
		clean.reverse()
	var centroid := PBMath.average(mesh_data.positions, clean)
	var centre_idx := PBMeshOps._dup_position_at(mesh_data, centroid, clean[0])
	var indices := PackedInt32Array()
	for i in range(clean.size()):
		indices.append(centre_idx)
		indices.append(clean[i])
		indices.append(clean[(i + 1) % clean.size()])
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


## True when the polygon's boundary never crosses itself (adjacent edges share
## a vertex and are skipped by construction).
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
# Seam safety net
# ==============================================================================

## Seam defects of a mesh, keyed by edge COORDINATES: an edge used twice in the
## same direction means two faces lie on the same side of it — a folded seam —
## and an edge used once or more than twice is an open or non-manifold seam.
static func _seam_defects(mesh_data: PBMeshData) -> Dictionary:
	var lookup := mesh_data.get_shared_vertex_lookup()
	var counts := {}
	var dirs := {}
	var face_owners := {}
	var face_owners_all := {}
	for face in mesh_data.faces:
		if face == null:
			continue
		var face_tag := -1
		if OS.get_environment("PB_BEVEL_TRACE") != "":
			face_tag = mesh_data.faces.find(face)
		for e in face.get_edges():
			var pa: Vector3 = mesh_data.positions[e.a]
			var pb: Vector3 = mesh_data.positions[e.b]
			var ka := _point_key(pa)
			var kb := _point_key(pb)
			var key: String = ka + "|" + kb if ka < kb else kb + "|" + ka
			counts[key] = counts.get(key, 0) + 1
			if face_tag >= 0:
				if not face_owners_all.has(key):
					face_owners_all[key] = []
				face_owners_all[key].append(face_tag)
			var ca: int = lookup.get(e.a, e.a)
			var cb: int = lookup.get(e.b, e.b)
			if not dirs.has(key):
				dirs[key] = []
			# The directed usage — NOT sorted: two faces on the same side of a
			# seam traverse it the same way, which is the defect being looked for.
			dirs[key].append(Vector2i(ca, cb))
			if face_tag >= 0 and not face_owners.has(key):
				face_owners[key] = []
			if face_tag >= 0:
				face_owners[key].append(face_tag)
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
				var who: Array = face_owners.get(key, [])
				for wi in range(who.size()):
					var wfi: int = who[wi]
					var wf: PBFace = mesh_data.faces[wfi]
					var dump := PackedStringArray()
					if wf != null:
						for vi2 in PBMeshOps._ordered_loop(wf):
							dump.append(str(mesh_data.positions[vi2]))
					print("[bevel]     face %d normal=%s loop: %s" % [wfi, str(PBMeshOps._face_area_normal(mesh_data, wf).normalized()), " | ".join(dump)])
					var owns := face_owners_all.get(key, [])
					print("[bevel]     (faces on edge: %s)" % str(owns))
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


## Coordinate key of a point, snapped to the weld tolerance.
static func _point_key(p: Vector3) -> String:
	return "%d,%d,%d" % [roundi(p.x * 10000.0), roundi(p.y * 10000.0), roundi(p.z * 10000.0)]


static func _key(lookup: Dictionary, a: int, b: int) -> Vector2i:
	var ca: int = lookup.get(a, a)
	var cb: int = lookup.get(b, b)
	return Vector2i(mini(ca, cb), maxi(ca, cb))


# ==============================================================================
# Failure handling
# ==============================================================================

static func _fail(message: String) -> Dictionary:
	return {"ok": false, "error": message}
