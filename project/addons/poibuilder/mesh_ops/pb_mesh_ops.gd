## PBMeshOps — Core mesh operations (Phase 7): extrude, inset, subdivide,
## delete, detach.
##
## Runtime-safe, standalone static functions over PBMeshData (G3: no editor
## classes, fully headless-testable). All ops MUTATE the given PBMeshData and
## return a result Dictionary:
##   { "ok": bool, "error": String (when not ok),
##     "cap_face_ids": PackedInt32Array,   # extrude: the translated copies
##     "new_face_ids": PackedInt32Array,   # every face the op created
##     "detached": PBMeshData }            # detach: the extracted mesh
##
## Conventions (G1, see tests/test_pb_winding.gd):
## - Internal winding is CCW-from-outside. New faces follow the source face's
##   winding; side quads from a directed boundary edge (a→b) are emitted as
##   (a, b, b', b', a', a) which keeps outward normals (locked by tests).
## - After any topology change the weld groups are rebuilt from coincident
##   positions (explicit unwelds are not representable yet — documented in
##   PBMeshData.ensure_welds).
## - Vertex attribute arrays (textures0/colors/tangents) are extended by
##   duplicating the source vertex's attributes; UV interpolation is Phase 8.
@tool
class_name PBMeshOps
extends RefCounted

## THE POSITION-PRIVACY INVARIANT: every face owns its corner positions
## exclusively (per-face duplication, like the cube factory); faces that
## touch the same 3D corner are connected by SHARED-VERTEX WELD GROUPS, never
## by shared position indexes. New faces therefore duplicate every corner —
## sharing positions across faces with different normals corrupts flat
## normals (calculate_normals writes per position; the last face wins).

const WELD_TOLERANCE := 0.0001

# ==============================================================================
# Face operations
# ==============================================================================

## Extrudes connected face regions along their average normal by `distance`
## (negative = into the mesh). The selected faces are translated: originals
## are removed, translated copies ("caps") plus side quads across each region
## boundary edge are added — ProBuilder semantics (a cube stays 6 faces after
## extruding its top into a taller box).
## `allow_zero` permits distance 0 (caps coincide with the originals) — the
## shift+move gesture extrudes at 0 then drags the caps with the gesture.
static func extrude_faces(mesh_data: PBMeshData, face_ids: PackedInt32Array,
		distance: float, allow_zero: bool = false) -> Dictionary:
	if not _faces_valid(mesh_data, face_ids):
		return _fail("Extrude faces: invalid selection")
	if distance == 0.0 and not allow_zero:
		return _fail("Extrude faces: zero distance")

	var caps: Array[PBFace] = []
	var sides: Array[PBFace] = []
	var removed := {}
	# Positions a follow-up translate/scale gesture should move: cap corners
	# plus the sides' LIFTED corners only (the sides' base dups weld to the
	# untouched mesh — moving them would drag the neighbors along).
	var drag_positions := PackedInt32Array()

	for region: PackedInt32Array in _face_regions(mesh_data, face_ids):
		var dir := _region_normal(mesh_data, region)
		if dir.length_squared() < 0.5:
			return _fail("Extrude faces: degenerate region normal")
		var offset := dir.normalized() * distance

		# Each region face gets its own private cap copy (position privacy).
		for fi in region:
			var face := mesh_data.faces[fi]
			var cap := face.duplicate_face()
			var local := {}
			for idx in face.get_distinct_indexes():
				local[idx] = _dup_position(mesh_data, idx, offset)
			var remapped := PackedInt32Array()
			for idx in face.get_indexes():
				remapped.append(local[idx])
			cap.set_indexes(remapped)
			for idx in face.get_distinct_indexes():
				drag_positions.append(local[idx])
			caps.append(cap)
			removed[fi] = true

		# Side quads bridge each directed boundary edge to the lifted copies;
		# all four corners are fresh duplicates (position privacy).
		var submesh := _region_submesh(mesh_data, region)
		for edge in _region_boundary_edges(mesh_data, region):
			var qa := _dup_position(mesh_data, edge["a"], Vector3.ZERO)
			var qb := _dup_position(mesh_data, edge["b"], Vector3.ZERO)
			var qa2 := _dup_position(mesh_data, edge["a"], offset)
			var qb2 := _dup_position(mesh_data, edge["b"], offset)
			var side := PBFace.new(PackedInt32Array([
				qa, qb, qb2,
				qb2, qa2, qa,
			]))
			side.submesh_index = submesh
			sides.append(side)
			drag_positions.append(qa2)
			drag_positions.append(qb2)

	var result := _replace_faces(mesh_data, removed, caps, sides)
	# drag_positions were collected BEFORE _compact remapped the position
	# indexes (the removed face's corners are dropped). Stale indexes made
	# the drag union point at WALL corners — tearing walls off the mesh
	# ("missing, unselectable faces").
	var remap: Dictionary = result["position_remap"]
	var final_drag := PackedInt32Array()
	for idx in drag_positions:
		final_drag.append(remap.get(idx, idx))
	result["drag_positions"] = final_drag
	return result

## Insets each selected face independently: the face is replaced by a shrunken
## inner face plus a ring of side quads, ALL COPLANAR with the original face
## (inset is a 2D operation; extrude the inner face afterwards for depth).
## `amount` is the fraction of the corner→centroid distance to pull in
## (0..1, clamped).
static func inset_faces(mesh_data: PBMeshData, face_ids: PackedInt32Array,
		amount: float) -> Dictionary:
	if not _faces_valid(mesh_data, face_ids):
		return _fail("Inset faces: invalid selection")
	amount = clampf(amount, 0.01, 0.95)

	var inner_faces: Array[PBFace] = []
	var ring_faces: Array[PBFace] = []
	var removed := {}

	for fi in face_ids:
		var face := mesh_data.faces[fi]
		var loop := _ordered_loop(face)
		if loop.size() < 3:
			return _fail("Inset faces: face %d has no clean perimeter loop" % fi)
		if loop.size() != face.get_distinct_indexes().size():
			return _fail("Inset faces: face %d has a hole — inset is not supported" % fi)

		var centroid := Vector3.ZERO
		for idx in loop:
			centroid += mesh_data.positions[idx]
		centroid /= float(loop.size())

		var pulled := {}
		for idx in loop:
			pulled[idx] = mesh_data.positions[idx].lerp(centroid, amount)

		# Inner face: private duplicates of the pulled corners.
		var inner_face := face.duplicate_face()
		var local := {}
		for idx in loop:
			local[idx] = _dup_position_at(mesh_data, pulled[idx], idx)
		var remapped := PackedInt32Array()
		for idx in face.get_indexes():
			remapped.append(local[idx])
		inner_face.set_indexes(remapped)
		inner_faces.append(inner_face)

		# Ring quads: fresh duplicates for all four corners.
		var n := loop.size()
		for i in range(n):
			var a: int = loop[i]
			var b: int = loop[(i + 1) % n]
			var qa := _dup_position(mesh_data, a, Vector3.ZERO)
			var qb := _dup_position(mesh_data, b, Vector3.ZERO)
			var qa2 := _dup_position_at(mesh_data, pulled[a], a)
			var qb2 := _dup_position_at(mesh_data, pulled[b], b)
			var ring := PBFace.new(PackedInt32Array([
				qa, qb, qb2,
				qb2, qa2, qa,
			]))
			ring.submesh_index = face.submesh_index
			ring_faces.append(ring)

		removed[fi] = true

	return _replace_faces(mesh_data, removed, inner_faces, ring_faces)

## Subdivides each selected quad into 4 quads (edge midpoints + centroid).
## Faces subdivided in the same call are connected through coincident (welded)
## midpoint positions — the position-privacy invariant forbids sharing the
## position index itself across faces.
## Unselected neighbor faces sharing split boundary edges are retriangulated into
## n-gons connected to the new midpoint vertices (each face owning its own
## duplicate positions, welded via coincident vertex groups).
static func subdivide_faces(mesh_data: PBMeshData, face_ids: PackedInt32Array) -> Dictionary:
	if not _faces_valid(mesh_data, face_ids):
		return _fail("Subdivide faces: invalid selection")

	for fi in face_ids:
		var face := mesh_data.faces[fi]
		var loop := _ordered_loop(face)
		if loop.size() != 4:
			return _fail("Subdivide faces: face %d is not a quad" % fi)

	var selected_set := {}
	for fi in face_ids:
		selected_set[fi] = true

	var lookup := mesh_data.get_shared_vertex_lookup()

	# 1. Collect boundary edges of selected faces and their 3D midpoint coordinates
	var split_edges: Dictionary = {}
	for fi in face_ids:
		var face := mesh_data.faces[fi]
		var v := _ordered_loop(face)
		for i in range(4):
			var a: int = v[i]
			var b: int = v[(i + 1) % 4]
			var ga: int = lookup.get(a, a)
			var gb: int = lookup.get(b, b)
			var key := Vector2i(mini(ga, gb), maxi(ga, gb))
			var mid_pos := mesh_data.positions[a].lerp(mesh_data.positions[b], 0.5)
			split_edges[key] = mid_pos

	var new_faces: Array[PBFace] = []
	var removed := {}

	# 2. Build the 4 sub-quads per selected face
	for fi in face_ids:
		var face := mesh_data.faces[fi]
		var v := _ordered_loop(face)

		var pv := PackedInt32Array()
		for i in range(4):
			pv.append(_dup_position(mesh_data, v[i], Vector3.ZERO))
		var m := PackedInt32Array()
		for i in range(4):
			var a: int = v[i]
			var b: int = v[(i + 1) % 4]
			var mid := mesh_data.positions[a].lerp(mesh_data.positions[b], 0.5)
			m.append(_dup_position_at(mesh_data, mid, a))
		var center := _dup_position_at(mesh_data, _face_centroid(mesh_data, face), v[0])

		var quads := [
			[pv[0], m[0], center, m[3]],
			[pv[1], m[1], center, m[0]],
			[pv[2], m[2], center, m[1]],
			[pv[3], m[3], center, m[2]],
		]
		for quad: Array in quads:
			var f := PBFace.new(PackedInt32Array([
				quad[0], quad[1], quad[2],
				quad[2], quad[3], quad[0],
			]))
			f.submesh_index = face.submesh_index
			new_faces.append(f)

		removed[fi] = true

	# 3. Retriangulate unselected neighbor faces that touch split boundary edges
	# so they become n-gons connected to the new midpoint vertices.
	var updated_neighbor_faces: Array[PBFace] = []
	for nfi in range(mesh_data.faces.size()):
		if selected_set.has(nfi):
			continue
		var nface := mesh_data.faces[nfi]
		if nface == null:
			continue
		var nloop := _ordered_loop(nface)
		if nloop.is_empty():
			continue

		var has_split_edge := false
		for j in range(nloop.size()):
			var na: int = nloop[j]
			var nb: int = nloop[(j + 1) % nloop.size()]
			var nga: int = lookup.get(na, na)
			var ngb: int = lookup.get(nb, nb)
			var key := Vector2i(mini(nga, ngb), maxi(nga, ngb))
			if split_edges.has(key):
				has_split_edge = true
				break

		if not has_split_edge:
			continue

		# Build new cycle for neighbor n-gon with midpoints inserted
		var new_cycle: Array[int] = []
		for j in range(nloop.size()):
			var na: int = nloop[j]
			var nb: int = nloop[(j + 1) % nloop.size()]
			var nga: int = lookup.get(na, na)
			var ngb: int = lookup.get(nb, nb)
			var key := Vector2i(mini(nga, ngb), maxi(nga, ngb))

			var new_na := _dup_position(mesh_data, na, Vector3.ZERO)
			new_cycle.append(new_na)

			if split_edges.has(key):
				var mid_pos: Vector3 = split_edges[key]
				var new_mid := _dup_position_at(mesh_data, mid_pos, na)
				new_cycle.append(new_mid)

		# Triangulate planar n-gon into non-degenerate triangles
		var norm := PBMath.normal_from_positions(mesh_data.positions, nface.get_indexes())
		var u := norm.cross(Vector3.UP)
		if u.length_squared() < 0.25:
			u = norm.cross(Vector3.RIGHT)
		u = u.normalized()
		var v := norm.cross(u).normalized()

		var pts2d := PackedVector2Array()
		for idx in new_cycle:
			var p: Vector3 = mesh_data.positions[idx]
			pts2d.append(Vector2(p.dot(u), p.dot(v)))

		# Ensure CCW in 2D
		var area := 0.0
		var num_pts := pts2d.size()
		for k in range(num_pts):
			var p0 := pts2d[k]
			var p1 := pts2d[(k + 1) % num_pts]
			area += (p1.x - p0.x) * (p1.y + p0.y)

		var map_indices: Array[int] = []
		for k in range(num_pts):
			map_indices.append(k)

		if area > 0:
			pts2d.reverse()
			map_indices.reverse()

		var tris := PBShapeComplex._triangulate_2d(pts2d)
		var face_idxs := PackedInt32Array()
		for tri in tris:
			var idx0: int = new_cycle[map_indices[tri[0]]]
			var idx1: int = new_cycle[map_indices[tri[1]]]
			var idx2: int = new_cycle[map_indices[tri[2]]]
			var e1: Vector3 = mesh_data.positions[idx1] - mesh_data.positions[idx0]
			var e2: Vector3 = mesh_data.positions[idx2] - mesh_data.positions[idx0]
			var cp := e1.cross(e2)
			if cp.dot(norm) < 0:
				face_idxs.append(idx0)
				face_idxs.append(idx2)
				face_idxs.append(idx1)
			else:
				face_idxs.append(idx0)
				face_idxs.append(idx1)
				face_idxs.append(idx2)

		var new_nface := PBFace.new(face_idxs)
		new_nface.submesh_index = nface.submesh_index
		updated_neighbor_faces.append(new_nface)
		removed[nfi] = true
	var res := _replace_faces(mesh_data, removed, new_faces, updated_neighbor_faces)
	res["new_face_ids"] = res["cap_face_ids"]
	return res
## Deletes the selected faces and compacts away now-orphaned vertices.
static func delete_faces(mesh_data: PBMeshData, face_ids: PackedInt32Array) -> Dictionary:
	if not _faces_valid(mesh_data, face_ids):
		return _fail("Delete faces: invalid selection")
	var removed := {}
	for fi in face_ids:
		removed[fi] = true
	return _replace_faces(mesh_data, removed, [], [])

## Removes the selected faces from `mesh_data` and returns them as a new
## PBMeshData (positions/attributes copied, welds rebuilt).
static func detach_faces(mesh_data: PBMeshData, face_ids: PackedInt32Array) -> Dictionary:
	if not _faces_valid(mesh_data, face_ids):
		return _fail("Detach faces: invalid selection")

	var detached := PBMeshData.new()
	for fi in face_ids:
		var face := mesh_data.faces[fi]
		var local := {}
		for idx in face.get_distinct_indexes():
			local[idx] = _append_copy(detached, mesh_data, idx)
		var copy := face.duplicate_face()
		var remapped := PackedInt32Array()
		for idx in face.get_indexes():
			remapped.append(local[idx])
		copy.set_indexes(remapped)
		detached.faces.append(copy)

	var removed := {}
	for fi in face_ids:
		removed[fi] = true
	var result := _replace_faces(mesh_data, removed, [], [])
	if not result["ok"]:
		return result

	_rebuild_welds(detached)
	result["detached"] = detached
	result["new_face_ids"] = PackedInt32Array()
	return result

## Merges edge-adjacent selected faces into single n-gon faces (ProBuilder
## "Merge Faces"): interior edges disappear, one face per connected region.
## Non-coplanar faces merge too — the n-gon then acts as ONE face in face
## mode (moving it keeps the region rigid) while its edges and vertices stay
## individually editable; the surface renders fan-triangulated across the
## bend, exactly like ProBuilder. Selected faces that are isolated (no
## edge-adjacent neighbor in the selection) are left untouched. Non-convex
## regions may fan badly (v1 fan-triangulates from the loop start —
## documented limitation).
static func merge_faces(mesh_data: PBMeshData, face_ids: PackedInt32Array) -> Dictionary:
	if not _faces_valid(mesh_data, face_ids):
		return _fail("Merge faces: invalid selection")

	var regions := _face_regions(mesh_data, face_ids)
	var merged_faces: Array[PBFace] = []
	var removed := {}
	var any_merged := false

	for region in regions:
		if region.size() < 2:
			continue
		var cycle := _region_boundary_cycle(mesh_data, region)
		if cycle.is_empty():
			return _fail("Merge faces: region boundary is not a clean cycle (holes?)")

		# Fan-triangulate the ordered loop; single face owns the loop's raw
		# positions exclusively (they belonged to the removed faces).
		var face := PBFace.new(PackedInt32Array())
		var idxs := PackedInt32Array()
		for i in range(1, cycle.size() - 1):
			idxs.append_array(PackedInt32Array([cycle[0], cycle[i], cycle[i + 1]]))
		face.set_indexes(idxs)
		face.submesh_index = mesh_data.faces[region[0]].submesh_index
		merged_faces.append(face)
		for fi in region:
			removed[fi] = true
		any_merged = true

	if not any_merged:
		return _fail("Merge faces: no edge-adjacent faces in selection")

	return _replace_faces(mesh_data, removed, merged_faces, [])

## Welds (merges) the selected shared-vertex groups: every position in the
## selected groups snaps to their common centroid and the groups collapse
## into one (rebuilt from coincidence). `vertex_ids` are shared-vertex GROUP
## indexes — the subgizmo ids used by VERTEX-mode selection.
## Unlike ProBuilder's radius weld there is no distance gate: the user
## explicitly multi-selected the corners to join.
static func weld_vertices(mesh_data: PBMeshData, vertex_ids: PackedInt32Array) -> Dictionary:
	if mesh_data == null or mesh_data.shared_vertices.is_empty():
		return _fail("Weld vertices: no mesh data")
	if vertex_ids.size() < 2:
		return _fail("Weld vertices: select at least two vertices to merge")
	for vid in vertex_ids:
		if vid < 0 or vid >= mesh_data.shared_vertices.size():
			return _fail("Weld vertices: vertex id %d out of range" % vid)

	var centroid := Vector3.ZERO
	var count: int = 0
	var seen := {}
	for vid in vertex_ids:
		var sv: PBSharedVertex = mesh_data.shared_vertices[vid]
		if sv == null:
			continue
		for idx in sv.indices:
			if idx < 0 or idx >= mesh_data.positions.size() or seen.has(idx):
				continue
			seen[idx] = true
			centroid += mesh_data.positions[idx]
			count += 1
	if count < 2:
		return _fail("Weld vertices: selection resolves to a single position")

	centroid /= float(count)
	for idx in seen:
		mesh_data.positions[idx] = centroid
	_rebuild_welds(mesh_data)

	# Group count after the rebuild tells the user how many corners remain.
	var result := {"ok": true, "new_face_ids": PackedInt32Array(),
		"cap_face_ids": PackedInt32Array(), "vertex_groups": mesh_data.shared_vertices.size()}
	return result

# ==============================================================================
# Edge operations
# ==============================================================================

## Inserts an edge loop through the ring of quads crossed by `edge_id`
## (index into get_common_edges) — the "loop cut": each ring face is split
## into two quads by connecting its two ring edges' midpoints.
## Ring walking is PBTopology.get_edge_ring; faces with only ONE ring edge
## (ring ends at a mesh boundary or a fan cap) are left unsplit (a T-junction
## on the border edge is expected and watertight in the edge-usage sense);
## non-quad or corner-turning ring faces fail the op cleanly (nothing is
## mutated on failure).
static func insert_edge_loop(mesh_data: PBMeshData, edge_ids: PackedInt32Array) -> Dictionary:
	if mesh_data == null or mesh_data.faces.is_empty():
		return _fail("Insert edge loop: no mesh data")
	if edge_ids.is_empty():
		return _fail("Insert edge loop: no edge selected")
	var common := mesh_data.get_common_edges()
	for eid in edge_ids:
		if eid < 0 or eid >= common.size():
			return _fail("Insert edge loop: edge id %d out of range" % eid)

	# Collect the ring(s) of all seeded edges as a set of common-edge keys.
	var lookup := mesh_data.get_shared_vertex_lookup()
	var ring_keys := {}
	for eid in edge_ids:
		var ring := PBTopology.get_edge_ring(mesh_data, [common[eid]])
		if ring.is_empty():
			return _fail("Insert edge loop: seed edge %d has no ring" % eid)
		for ring_edge in ring:
			ring_keys[_common_key(lookup, ring_edge.a, ring_edge.b)] = true

	# Faces to split: those containing exactly two ring edges, opposite each
	# other in a quad loop. One-ring-edge faces are boundary ends (unsplit).
	var split_plan: Array = []  # [{face_index, entry}] (ordered loop)
	for fi in range(mesh_data.faces.size()):
		var face := mesh_data.faces[fi]
		if face == null:
			continue
		var loop := _ordered_loop(face)
		var hits: Array = []
		for i in range(loop.size()):
			var key := _common_key(lookup, loop[i], loop[(i + 1) % loop.size()])
			if ring_keys.has(key):
				hits.append(i)
		if hits.is_empty():
			continue
		if hits.size() == 1:
			continue  # ring ends here (mesh boundary or fan cap) — unsplit
		if loop.size() != 4:
			return _fail("Insert edge loop: ring face %d is not a quad" % fi)
		if hits.size() != 2:
			return _fail("Insert edge loop: face %d touches %d ring edges (expected 2)" % [fi, hits.size()])
		# The two hits must be opposite perimeter edges (i and i+2).
		if (hits[0] + 1) % 4 == hits[1] or (hits[1] + 1) % 4 == hits[0]:
			return _fail("Insert edge loop: ring turns a corner in face %d (non-opposite edges)" % fi)
		split_plan.append({"face_index": fi, "entry": hits[0]})

	if split_plan.is_empty():
		return _fail("Insert edge loop: no quads to split")

	# Split each planned face. Winding: ordered quad (v0..v3) with entry edge
	# (v0,v1) and exit (v2,v3) splits into (v0, m01, m23, v3) and
	# (m01, v1, v2, m23) — both follow the perimeter (CCW preserved).
	var new_faces: Array[PBFace] = []
	var removed := {}
	for plan: Dictionary in split_plan:
		var fi: int = plan["face_index"]
		var face := mesh_data.faces[fi]
		var loop := _ordered_loop(face)
		var e: int = plan["entry"]
		var v0: int = loop[e]
		var v1: int = loop[(e + 1) % 4]
		var v2: int = loop[(e + 2) % 4]
		var v3: int = loop[(e + 3) % 4]
		var m01 := _dup_position_at(mesh_data,
			mesh_data.positions[v0].lerp(mesh_data.positions[v1], 0.5), v0)
		var m23 := _dup_position_at(mesh_data,
			mesh_data.positions[v2].lerp(mesh_data.positions[v3], 0.5), v2)
		# Each new quad duplicates every corner (position privacy).
		for quad: Array in [[v0, m01, m23, v3], [m01, v1, v2, m23]]:
			var qa := _dup_position(mesh_data, quad[0], Vector3.ZERO)
			var qb := _dup_position(mesh_data, quad[1], Vector3.ZERO)
			var qc := _dup_position(mesh_data, quad[2], Vector3.ZERO)
			var qd := _dup_position(mesh_data, quad[3], Vector3.ZERO)
			var f := PBFace.new(PackedInt32Array([
				qa, qb, qc,
				qc, qd, qa,
			]))
			f.submesh_index = face.submesh_index
			new_faces.append(f)
		removed[fi] = true

	return _replace_faces(mesh_data, removed, new_faces, [])


## Extrudes each selected edge along the average normal of its adjacent faces
## by `distance`, adding one quad per edge (an open "fin" — edges have no
## opposite boundary to close, matching ProBuilder's edge extrude).
## `edge_ids` index into mesh_data.get_common_edges(). `allow_zero` permits
## distance 0 (the shift+move gesture extrudes at 0 then drags the fins).
static func extrude_edges(mesh_data: PBMeshData, edge_ids: PackedInt32Array,
		distance: float, allow_zero: bool = false) -> Dictionary:
	if mesh_data == null or mesh_data.faces.is_empty():
		return _fail("Extrude edges: no mesh data")
	var common := mesh_data.get_common_edges()
	if edge_ids.is_empty():
		return _fail("Extrude edges: no edges selected")
	if distance == 0.0 and not allow_zero:
		return _fail("Extrude edges: zero distance")
	for eid in edge_ids:
		if eid < 0 or eid >= common.size():
			return _fail("Extrude edges: edge id %d out of range" % eid)

	var lookup := mesh_data.get_shared_vertex_lookup()
	var new_faces: Array[PBFace] = []
	# Positions a follow-up translate gesture should move: the fins' LIFTED
	# corners only (the base dups weld to the untouched mesh).
	var drag_positions := PackedInt32Array()

	for eid in edge_ids:
		var edge := common[eid]
		var key := _common_key(lookup, edge.a, edge.b)

		# Adjacent faces + a directed (winding-consistent) copy of the edge.
		var normal_acc := Vector3.ZERO
		var directed: PBEdge = null
		var submesh := 0
		for fi in range(mesh_data.faces.size()):
			var face := mesh_data.faces[fi]
			if face == null:
				continue
			var hit: PBEdge = null
			for fe in face.get_edges():
				if _common_key(lookup, fe.a, fe.b) == key:
					hit = fe
					break
			if hit == null:
				continue
			normal_acc += _face_area_normal(mesh_data, face)
			if directed == null:
				directed = hit
				submesh = face.submesh_index

		if directed == null:
			continue
		if normal_acc.length_squared() < 0.000000001:
			continue
		var offset := normal_acc.normalized() * distance

		# All four fin corners are fresh duplicates (position privacy): the
		# base dups weld to the adjacent faces' corners via coincidence.
		var qa := _dup_position(mesh_data, directed.a, Vector3.ZERO)
		var qb := _dup_position(mesh_data, directed.b, Vector3.ZERO)
		var qa2 := _dup_position(mesh_data, directed.a, offset)
		var qb2 := _dup_position(mesh_data, directed.b, offset)
		var fin := PBFace.new(PackedInt32Array([
			qa, qb, qb2,
			qb2, qa2, qa,
		]))
		fin.submesh_index = submesh
		new_faces.append(fin)
		drag_positions.append(qa2)
		drag_positions.append(qb2)

	if new_faces.is_empty():
		return _fail("Extrude edges: no extrudable edges (degenerate normals)")

	mesh_data.faces.append_array(new_faces)
	var remap: Dictionary = _rebuild_topology(mesh_data)

	var new_ids := PackedInt32Array()
	var base: int = mesh_data.faces.size() - new_faces.size()
	for i in range(new_faces.size()):
		new_ids.append(base + i)
	var final_drag := PackedInt32Array()
	for idx in drag_positions:
		final_drag.append(remap.get(idx, idx))
	return {"ok": true, "new_face_ids": new_ids, "cap_face_ids": new_ids,
		"drag_positions": final_drag}

# ==============================================================================
# Selection helpers
# ==============================================================================

## Maps PBEdge selection entries (raw position pairs) to their ids in
## get_common_edges(), matching by shared-group pair on both sides.
static func common_edge_ids(mesh_data: PBMeshData, edges: Array[PBEdge]) -> PackedInt32Array:
	var result := PackedInt32Array()
	if mesh_data == null:
		return result
	var lookup := mesh_data.get_shared_vertex_lookup()
	var wanted := {}
	for edge in edges:
		if edge != null:
			wanted[_common_key(lookup, edge.a, edge.b)] = true
	var common := mesh_data.get_common_edges()
	for i in range(common.size()):
		if wanted.has(_common_key(lookup, common[i].a, common[i].b)):
			result.append(i)
	return result

## Perimeter edge usage counts (common-edge key → number of faces using it).
## A closed manifold surface has exactly 2 everywhere — used by tests.
static func edge_usage_counts(mesh_data: PBMeshData) -> Dictionary:
	var counts := {}
	var lookup := mesh_data.get_shared_vertex_lookup()
	for face in mesh_data.faces:
		if face == null:
			continue
		for edge in face.get_edges():
			var key := _common_key(lookup, edge.a, edge.b)
			counts[key] = counts.get(key, 0) + 1
	return counts

# ==============================================================================
# Internals
# ==============================================================================

static func _fail(reason: String) -> Dictionary:
	return {"ok": false, "error": reason}

## Walks the directed boundary edges of a face region into one ordered cycle
## of raw position indexes (following shared-group keys). Returns [] when the
## boundary does not close into a single cycle (e.g. a region with a hole).
static func _region_boundary_cycle(mesh_data: PBMeshData, region: PackedInt32Array) -> PackedInt32Array:
	var boundary := _region_boundary_edges(mesh_data, region)
	if boundary.is_empty():
		return PackedInt32Array()
	var lookup := mesh_data.get_shared_vertex_lookup()
	var by_start := {}  # group key of start -> {a, b}
	for edge in boundary:
		by_start[_common_key(lookup, edge["a"], edge["a"])] = edge

	var cycle := PackedInt32Array([boundary[0]["a"], boundary[0]["b"]])
	var guard: int = boundary.size() + 1
	while cycle.size() < guard:
		var tail: int = cycle[cycle.size() - 1]
		var tail_key := _common_key(lookup, tail, tail)
		if not by_start.has(tail_key):
			return PackedInt32Array()
		var nxt: Dictionary = by_start[tail_key]
		var nb: int = nxt["b"]
		if _common_key(lookup, nb, nb) == _common_key(lookup, cycle[0], cycle[0]):
			return cycle  # closed
		cycle.append(nb)
	return PackedInt32Array()

static func _faces_valid(mesh_data: PBMeshData, face_ids: PackedInt32Array) -> bool:
	if mesh_data == null or face_ids.is_empty():
		return false
	for fi in face_ids:
		if fi < 0 or fi >= mesh_data.faces.size() or mesh_data.faces[fi] == null:
			return false
	return true

static func _common_key(lookup: Dictionary, a: int, b: int) -> Vector2i:
	var ca: int = lookup.get(a, a)
	var cb: int = lookup.get(b, b)
	return Vector2i(mini(ca, cb), maxi(ca, cb))

## Coordinate-based edge key: identifies a physical edge by its endpoint
## COORDINATES (tolerance-snapped), not by weld-group pairs. Weld groups
## over-merge after zero-distance extrudes (every swept corner coincides at
## seed and one group absorbs the base corner, the lifted corner, the cap
## corner and the original corner), which conflates distinct physical edges
## and made the boundary detection drop walls of chained extrudes.
static func _coord_edge_key(mesh_data: PBMeshData, a: int, b: int) -> String:
	var pa: Vector3 = mesh_data.positions[a]
	var pb: Vector3 = mesh_data.positions[b]
	var ka := Vector3(snappedf(pa.x, 0.0001), snappedf(pa.y, 0.0001), snappedf(pa.z, 0.0001))
	var kb := Vector3(snappedf(pb.x, 0.0001), snappedf(pb.y, 0.0001), snappedf(pb.z, 0.0001))
	if ka < kb:
		return "%s|%s" % [ka, kb]
	return "%s|%s" % [kb, ka]

## Connected groups of selected faces (shared physical edges). Whole regions
## extrude together so adjacent selected faces never grow internal walls.
static func _face_regions(mesh_data: PBMeshData, face_ids: PackedInt32Array) -> Array:
	var edge_faces := {}
	for fi in face_ids:
		for edge in mesh_data.faces[fi].get_edges():
			var key := _coord_edge_key(mesh_data, edge.a, edge.b)
			if not edge_faces.has(key):
				edge_faces[key] = PackedInt32Array()
			edge_faces[key].append(fi)

	var visited := {}
	var regions: Array = []
	for fi in face_ids:
		if visited.has(fi):
			continue
		var region := PackedInt32Array()
		var queue := PackedInt32Array([fi])
		visited[fi] = true
		while not queue.is_empty():
			var cur: int = queue[queue.size() - 1]
			queue.remove_at(queue.size() - 1)
			region.append(cur)
			for edge in mesh_data.faces[cur].get_edges():
				for nf in edge_faces.get(_coord_edge_key(mesh_data, edge.a, edge.b), PackedInt32Array()):
					if not visited.has(nf):
						visited[nf] = true
						queue.append(nf)
		regions.append(region)
	return regions

## Area-weighted outward normal of a face region (sum of triangle cross
## products — CCW-from-outside data makes this point outward).
static func _region_normal(mesh_data: PBMeshData, region: PackedInt32Array) -> Vector3:
	var acc := Vector3.ZERO
	for fi in region:
		acc += _face_area_normal(mesh_data, mesh_data.faces[fi])
	return acc

static func _face_area_normal(mesh_data: PBMeshData, face: PBFace) -> Vector3:
	var acc := Vector3.ZERO
	var idxs := face.get_indexes()
	var p := mesh_data.positions
	for t in range(0, idxs.size() - 2, 3):
		if idxs[t] >= p.size() or idxs[t + 1] >= p.size() or idxs[t + 2] >= p.size():
			continue
		acc += (p[idxs[t + 1]] - p[idxs[t]]).cross(p[idxs[t + 2]] - p[idxs[t]])
	return acc

## Directed boundary edges of a face region: perimeter edges used by exactly
## ONE region face, oriented along that face's winding. Output entries:
## {a: int, b: int} (raw position indices).
static func _region_boundary_edges(mesh_data: PBMeshData, region: PackedInt32Array) -> Array:
	var usage := {}
	var directed := {}
	for fi in region:
		for edge in mesh_data.faces[fi].get_edges():
			var key := _coord_edge_key(mesh_data, edge.a, edge.b)
			usage[key] = usage.get(key, 0) + 1
			directed[key] = [edge.a, edge.b]
	var result: Array = []
	for key in usage:
		if usage[key] == 1:
			result.append({"a": directed[key][0], "b": directed[key][1]})
	return result

static func _region_submesh(mesh_data: PBMeshData, region: PackedInt32Array) -> int:
	return mesh_data.faces[region[0]].submesh_index

## Face centroid of the distinct perimeter vertices.
static func _face_centroid(mesh_data: PBMeshData, face: PBFace) -> Vector3:
	var loop := face.get_distinct_indexes()
	var centroid := Vector3.ZERO
	var count: int = 0
	for idx in loop:
		if idx >= 0 and idx < mesh_data.positions.size():
			centroid += mesh_data.positions[idx]
			count += 1
	return centroid / float(count) if count > 0 else Vector3.ZERO

## Ordered perimeter cycle of a face (face.get_edges() entries are directed
## along the winding — each (a→b) continues at b). Returns [] when the walk
## does not close cleanly (non-manifold face border).
static func _ordered_loop(face: PBFace) -> PackedInt32Array:
	var edges := face.get_edges()
	if edges.is_empty():
		return PackedInt32Array()
	var next_of := {}
	for edge in edges:
		next_of[edge.a] = edge.b
	var loop := PackedInt32Array([edges[0].a])
	var guard: int = next_of.size() + 1
	while loop.size() <= guard:
		var tail: int = loop[loop.size() - 1]
		if not next_of.has(tail):
			return PackedInt32Array()
		var nxt: int = next_of[tail]
		if nxt == loop[0]:
			return loop
		if nxt in loop:
			return PackedInt32Array()
		loop.append(nxt)
	return PackedInt32Array()

## Appends a new position to `target` copying position `src_idx` (and its
## attributes) from `src`. Returns the new position index.
static func _append_copy(target: PBMeshData, src: PBMeshData, src_idx: int) -> int:
	var vc: int = target.positions.size()
	target.positions.append(src.positions[src_idx])
	if src.textures0.size() == src.positions.size() and target.textures0.size() == vc:
		target.textures0.append(src.textures0[src_idx])
	if src.colors.size() == src.positions.size() and target.colors.size() == vc:
		target.colors.append(src.colors[src_idx])
	if src.tangents.size() == src.positions.size() * 4 and target.tangents.size() == vc * 4:
		for f in range(4):
			target.tangents.append(src.tangents[src_idx * 4 + f])
	return target.positions.size() - 1

## Appends a copy of position `idx` moved by `offset`, duplicating vertex
## attributes. Returns the new position index.
static func _dup_position(mesh_data: PBMeshData, idx: int, offset: Vector3) -> int:
	return _dup_position_at(mesh_data, mesh_data.positions[idx] + offset, idx)

## Appends a new position `at`, duplicating vertex `src` attributes.
static func _dup_position_at(mesh_data: PBMeshData, at: Vector3, src: int) -> int:
	var vc: int = mesh_data.positions.size()
	mesh_data.positions.append(at)
	if mesh_data.textures0.size() == vc:
		mesh_data.textures0.append(mesh_data.textures0[src])
	if mesh_data.colors.size() == vc:
		mesh_data.colors.append(mesh_data.colors[src])
	if mesh_data.tangents.size() == vc * 4:
		for f in range(4):
			mesh_data.tangents.append(mesh_data.tangents[src * 4 + f])
	return mesh_data.positions.size() - 1

## Replaces the faces in `removed` with `primary` + `secondary` and rebuilds
## topology. Result face ids are FINAL-array indexes: "cap_face_ids" = the
## primary faces, "new_face_ids" = primary + secondary.
##
## PRIMARY FACES TAKE OVER THE REMOVED SLOTS (ascending removed order) rather
## than appending at the end: the editor's subgizmo selection still holds the
## ORIGINAL face ids, and a mid-drag topology op (shift+drag extrude) must
## keep those ids resolving to the replacement faces — with append-at-end the
## engine's drag machinery re-resolves the selected id to an unrelated wall
## mid-gesture and the delivered motion inverts/jumps ("extrude doesn't
## follow the mouse"). Extrude/inset produce exactly one primary per removed
## face, so the in-place mapping is 1:1 for them; extras are appended.
static func _replace_faces(mesh_data: PBMeshData, removed: Dictionary,
		primary: Array[PBFace], secondary: Array[PBFace]) -> Dictionary:
	var remaining := mesh_data.faces.size() - removed.size()
	if remaining == 0 and primary.is_empty() and secondary.is_empty():
		return _fail("Operation would leave an empty mesh")

	var final: Array[PBFace] = []
	var primary_ids := PackedInt32Array()
	var pi := 0
	for i in range(mesh_data.faces.size()):
		if removed.has(i) and pi < primary.size():
			final.append(primary[pi])
			primary_ids.append(final.size() - 1)
			pi += 1
		elif not removed.has(i):
			final.append(mesh_data.faces[i])
	while pi < primary.size():
		final.append(primary[pi])
		primary_ids.append(final.size() - 1)
		pi += 1

	var secondary_ids := PackedInt32Array()
	for face in secondary:
		final.append(face)
		secondary_ids.append(final.size() - 1)

	mesh_data.faces = final
	var remap := _rebuild_topology(mesh_data)

	var all_ids := PackedInt32Array(primary_ids)
	for sid in secondary_ids:
		all_ids.append(sid)
	return {"ok": true, "cap_face_ids": primary_ids, "new_face_ids": all_ids,
		"position_remap": remap}

## Post-op topology repair: compact orphaned positions, rebuild weld groups
## from coincident positions, invalidate caches.
static func _rebuild_topology(mesh_data: PBMeshData) -> Dictionary:
	var remap := _compact(mesh_data)
	_rebuild_welds(mesh_data)
	return remap

static func _rebuild_welds(mesh_data: PBMeshData) -> void:
	mesh_data.shared_vertices = PBMeshData.build_welds_from_positions(
		mesh_data.positions, WELD_TOLERANCE)
	mesh_data.invalidate_caches()

## Drops position indices no face references, remapping faces and attributes.
## Returns the old->new position remap it applied (empty when nothing was
## dropped) so callers can remap position indexes captured before the op.
static func _compact(mesh_data: PBMeshData) -> Dictionary:
	var referenced := {}
	for face in mesh_data.faces:
		if face == null:
			continue
		for idx in face.get_indexes():
			referenced[idx] = true

	var old_count: int = mesh_data.positions.size()
	var remap := {}
	var new_positions := PackedVector3Array()
	for i in range(old_count):
		if referenced.has(i):
			remap[i] = new_positions.size()
			new_positions.append(mesh_data.positions[i])
	if new_positions.size() == old_count:
		return remap

	mesh_data.positions = new_positions
	if mesh_data.textures0.size() == old_count:
		mesh_data.textures0 = _remap_packed_vector2(mesh_data.textures0, remap)
	if mesh_data.colors.size() == old_count:
		mesh_data.colors = _remap_packed_color(mesh_data.colors, remap)
	if mesh_data.tangents.size() == old_count * 4:
		mesh_data.tangents = _remap_packed_float32(mesh_data.tangents, remap, 4)
	for face in mesh_data.faces:
		if face == null:
			continue
		var remapped := PackedInt32Array()
		for idx in face.get_indexes():
			remapped.append(remap.get(idx, idx))
		face.set_indexes(remapped)
	return remap

static func _remap_packed_vector2(src: PackedVector2Array, remap: Dictionary) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in range(src.size()):
		if remap.has(i):
			out.append(src[i])
	return out

static func _remap_packed_color(src: PackedColorArray, remap: Dictionary) -> PackedColorArray:
	var out := PackedColorArray()
	for i in range(src.size()):
		if remap.has(i):
			out.append(src[i])
	return out

static func _remap_packed_float32(src: PackedFloat32Array, remap: Dictionary, stride: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for i in range(src.size() / stride):
		if remap.has(i):
			for f in range(stride):
				out.append(src[i * stride + f])
	return out
