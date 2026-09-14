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
			var src_face: PBFace = mesh_data.faces[edge.get("face_idx", region[0])]
			PBUv.setup_extruded_face_uvs(mesh_data, side, src_face, edge["a"], edge["b"], qa, qb)
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
			var qa := _dup_position(mesh_data, quad[0], Vector3.ZERO)
			var qb := _dup_position(mesh_data, quad[1], Vector3.ZERO)
			var qc := _dup_position(mesh_data, quad[2], Vector3.ZERO)
			var qd := _dup_position(mesh_data, quad[3], Vector3.ZERO)
			var f := PBFace.new(PackedInt32Array([
				qa, qb, qc,
				qc, qd, qa,
			]))
			f.submesh_index = face.submesh_index
			f.uv_scale = face.uv_scale
			f.uv_offset = face.uv_offset
			f.uv_rotation = face.uv_rotation
			f.uv_use_world_space = face.uv_use_world_space
			f.uv_flip_u = face.uv_flip_u
			f.uv_flip_v = face.uv_flip_v
			f.uv_swap_uv = face.uv_swap_uv
			f.uv_fill = face.uv_fill
			f.uv_anchor = face.uv_anchor
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

		# Triangulate planar n-gon into non-degenerate triangles using robust planar basis
		var norm := PBMath.normal_from_positions(mesh_data.positions, nface.get_indexes())
		var basis := PBUv.get_planar_basis(norm)
		var u: Vector3 = basis["u"]
		var v: Vector3 = basis["v"]
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
		new_nface.uv_scale = nface.uv_scale
		new_nface.uv_offset = nface.uv_offset
		new_nface.uv_rotation = nface.uv_rotation
		new_nface.uv_use_world_space = nface.uv_use_world_space
		new_nface.uv_flip_u = nface.uv_flip_u
		new_nface.uv_flip_v = nface.uv_flip_v
		new_nface.uv_swap_uv = nface.uv_swap_uv
		new_nface.uv_fill = nface.uv_fill
		new_nface.uv_anchor = nface.uv_anchor
		updated_neighbor_faces.append(new_nface)
		removed[nfi] = true
	var res := _replace_faces(mesh_data, removed, new_faces, updated_neighbor_faces)
	res["new_face_ids"] = res["cap_face_ids"]
	PBUv.refresh_mesh_uvs(mesh_data)
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

		# Fan-triangulate the ordered loop, on FRESHLY DUPLICATED corners. The
		# cycle's own positions are not free to take: they are also used by the
		# neighbours the removed faces were welded to (a subdivision leaves its
		# mid-point positions shared between the pieces either side of the cut),
		# and UVs live in a PER-POSITION array — a merged face reusing them
		# rendered with whichever neighbour's projection was written last, which
		# is the "merged face goes diagonal" report. Duplicating restores the
		# position-privacy invariant; the weld rebuild at the end of the op
		# re-connects the copies by coincidence, so the face still moves as part
		# of the mesh.
		var dup := PackedInt32Array()
		for i in cycle:
			dup.append(_dup_position(mesh_data, i, Vector3.ZERO))
		var face := PBFace.new(PackedInt32Array())

		# 2D ear-clip the cycle to avoid degenerate zero-area or overlapping fan triangles.
		var cycle_3d := PackedVector3Array()
		for i in cycle:
			cycle_3d.append(mesh_data.positions[i])
		var reg_n := Vector3.ZERO
		for fi in region:
			if fi >= 0 and fi < mesh_data.faces.size() and mesh_data.faces[fi] != null:
				reg_n += PBMath.normal_from_positions(mesh_data.positions, mesh_data.faces[fi].get_indexes())
		if reg_n.length_squared() < 0.0001:
			reg_n = Vector3.UP
		else:
			reg_n = reg_n.normalized()

		var basis := PBUv.get_planar_basis(reg_n)
		var u_axis: Vector3 = basis["u"]
		var v_axis: Vector3 = basis["v"]
		var pts_2d := PackedVector2Array()
		for p in cycle_3d:
			pts_2d.append(Vector2(u_axis.dot(p), v_axis.dot(p)))

		var area2 := 0.0
		var n_pts := pts_2d.size()
		for i in range(n_pts):
			area2 += pts_2d[i].cross(pts_2d[(i + 1) % n_pts])

		var pts_for_clip := pts_2d
		var reversed := false
		if area2 < 0.0:
			pts_for_clip = pts_2d.duplicate()
			pts_for_clip.reverse()
			reversed = true

		var tris := PBShapeComplex._triangulate_2d(pts_for_clip)
		var idxs := PackedInt32Array()
		if not tris.is_empty():
			for tri in tris:
				var i0: int = tri[0]
				var i1: int = tri[1]
				var i2: int = tri[2]
				if reversed:
					i0 = n_pts - 1 - i0
					i1 = n_pts - 1 - i1
					i2 = n_pts - 1 - i2
					idxs.append_array(PackedInt32Array([dup[i0], dup[i2], dup[i1]]))
				else:
					idxs.append_array(PackedInt32Array([dup[i0], dup[i1], dup[i2]]))
		else:
			for i in range(1, dup.size() - 1):
				idxs.append_array(PackedInt32Array([dup[0], dup[i], dup[i + 1]]))
		face.set_indexes(idxs)
		# The merged face replaces its pieces, so it wears their look: the first
		# piece's material slot and auto-UV settings (a fresh face would reset a
		# face whose tiling the author had set, and the merged area would jump).
		var source: PBFace = mesh_data.faces[region[0]]
		face.submesh_index = source.submesh_index
		face.uv_offset = source.uv_offset
		face.uv_rotation = source.uv_rotation
		face.uv_scale = source.uv_scale
		face.uv_use_world_space = source.uv_use_world_space
		face.uv_flip_u = source.uv_flip_u
		face.uv_flip_v = source.uv_flip_v
		face.uv_swap_uv = source.uv_swap_uv
		face.uv_fill = source.uv_fill
		face.uv_anchor = source.uv_anchor
		merged_faces.append(face)
		for fi in region:
			removed[fi] = true
		any_merged = true

	if not any_merged:
		return _fail("Merge faces: no edge-adjacent faces in selection")

	var result := _replace_faces(mesh_data, removed, merged_faces, [])
	if not result.get("ok", false):
		return result
	# Re-project the merged faces' UVs: a corner keeps the UV it had in the piece
	# it came from, so a merged n-gon fan-triangulates into diagonal stripes the
	# moment it moves (the showcase's checkerboard made that obvious).
	for fid in result.get("cap_face_ids", PackedInt32Array()):
		if fid >= 0 and fid < mesh_data.faces.size():
			PBUv.apply_face_uvs(mesh_data, mesh_data.faces[fid])
	return result

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
			continue  # non-quad (triangle or n-gon cap): ring ends here — unsplit
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
		var hit_face: PBFace = null
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
				hit_face = face
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
		PBUv.setup_extruded_face_uvs(mesh_data, fin, hit_face, directed.a, directed.b, qa, qb)
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

## Bevels selected edges with a flat chamfer (segments = 1) or a multi-segment
## circular fillet (segments = 2..8) — see PBMeshBevel, which owns the op.
static func bevel_edges(mesh_data: PBMeshData, edge_ids: PackedInt32Array,
		amount: float, segments: int = 1) -> Dictionary:
	return PBMeshBevel.bevel_edges(mesh_data, edge_ids, amount, segments)

## Bevels the selected faces by chamfering/filleting their boundary edges —
## exactly how ProBuilder implements face bevel ("select all perimeter edges of
## the face and run BevelEdges"): the faces retract by `amount` and a bridge
## band (one quad per segment) grows around the selection's boundary. Interior
## edges of a multi-face region are not beveled, and unselected neighbor faces
## stay untouched, so nothing can tear.
static func bevel_faces(mesh_data: PBMeshData, face_ids: PackedInt32Array,
		amount: float, segments: int = 1) -> Dictionary:
	if mesh_data == null or face_ids.is_empty():
		return _fail("Bevel faces: no faces selected")

	# Validate before touching anything: a face whose perimeter is not a single
	# simple loop (a hole, e.g. a closed knife cut) cannot be inset consistently.
	for fi in face_ids:
		if fi < 0 or fi >= mesh_data.faces.size():
			return _fail("Bevel faces: invalid face id %d" % fi)
		var face: PBFace = mesh_data.faces[fi]
		if face == null or _ordered_loop(face).size() < 3:
			return _fail("Bevel faces: face %d has a hole (its perimeter is not a single loop)" % fi)

	var boundary := face_perimeter_common_edge_ids(mesh_data, face_ids)
	if boundary.is_empty():
		return _fail("Bevel faces: the selection has no perimeter edges to bevel")
	return PBMeshBevel.bevel_edges(mesh_data, boundary, amount, segments)

# ==============================================================================
# Topology Operations (Session 5): Bridge, Connect, Collapse, Fill Hole
# ==============================================================================

## Connects two boundary edges across a gap with a new polygon face (quad or triangle).
## edge_ids contains exactly 2 common edge IDs (indices into mesh_data.get_common_edges()).
static func bridge_edges(mesh_data: PBMeshData, edge_ids: PackedInt32Array) -> Dictionary:
	if mesh_data == null or mesh_data.faces.is_empty():
		return _fail("Bridge edges: no mesh data")
	if edge_ids.size() != 2:
		return _fail("Bridge edges requires exactly 2 edges selected")

	var common := mesh_data.get_common_edges()
	var eid_a := edge_ids[0]
	var eid_b := edge_ids[1]
	if eid_a < 0 or eid_a >= common.size() or eid_b < 0 or eid_b >= common.size():
		return _fail("Bridge edges: edge index out of range")
	if eid_a == eid_b:
		return _fail("Bridge edges requires 2 distinct edges")

	var edge_a := common[eid_a]
	var edge_b := common[eid_b]
	var lookup := mesh_data.get_shared_vertex_lookup()

	var key_a := _common_key(lookup, edge_a.a, edge_a.b)
	var key_b := _common_key(lookup, edge_b.a, edge_b.b)

	# Find adjacent faces and verify boundary status (1 connecting face)
	var adj_faces_a: Array[PBFace] = []
	var adj_faces_b: Array[PBFace] = []
	for face in mesh_data.faces:
		if face == null:
			continue
		for fe in face.get_edges():
			var f_key := _common_key(lookup, fe.a, fe.b)
			if f_key == key_a:
				adj_faces_a.append(face)
			if f_key == key_b:
				adj_faces_b.append(face)

	if adj_faces_a.size() != 1 or adj_faces_b.size() != 1:
		return _fail("Bridge edges requires open boundary edges (1 connecting face each)")
	if adj_faces_a[0] == adj_faces_b[0]:
		return _fail("Face already exists between these two edges")

	var face_a: PBFace = adj_faces_a[0]
	var face_b: PBFace = adj_faces_b[0]
	var submesh: int = face_a.submesh_index

	var ca_a: int = lookup.get(edge_a.a, edge_a.a)
	var ca_b: int = lookup.get(edge_a.b, edge_a.b)
	var cb_a: int = lookup.get(edge_b.a, edge_b.a)
	var cb_b: int = lookup.get(edge_b.b, edge_b.b)

	var shares_vertex := (ca_a == cb_a or ca_a == cb_b or ca_b == cb_a or ca_b == cb_b)
	var new_face: PBFace = null

	var ref_n: Vector3 = (_face_area_normal(mesh_data, face_a) + _face_area_normal(mesh_data, face_b)).normalized()
	if ref_n.length_squared() < 0.0001:
		ref_n = Vector3.UP

	if shares_vertex:
		# Triangle bridge
		var shared_src: int = -1
		var other_a: int = -1
		var other_b: int = -1
		if ca_a == cb_a:
			shared_src = edge_a.a
			other_a = edge_a.b
			other_b = edge_b.b
		elif ca_a == cb_b:
			shared_src = edge_a.a
			other_a = edge_a.b
			other_b = edge_b.a
		elif ca_b == cb_a:
			shared_src = edge_a.b
			other_a = edge_a.a
			other_b = edge_b.b
		else:
			shared_src = edge_a.b
			other_a = edge_a.a
			other_b = edge_b.a

		var qa := _dup_position(mesh_data, shared_src, Vector3.ZERO)
		var qb := _dup_position(mesh_data, other_a, Vector3.ZERO)
		var qc := _dup_position(mesh_data, other_b, Vector3.ZERO)

		var pa := mesh_data.positions[qa]
		var pb := mesh_data.positions[qb]
		var pc := mesh_data.positions[qc]
		var tri_n := (pb - pa).cross(pc - pa)
		if tri_n.dot(ref_n) < 0.0:
			new_face = PBFace.new(PackedInt32Array([qa, qc, qb]))
		else:
			new_face = PBFace.new(PackedInt32Array([qa, qb, qc]))
	else:
		# Quad bridge with planar untwist
		var pa0 := mesh_data.positions[edge_a.a]
		var pa1 := mesh_data.positions[edge_a.b]
		var pb0 := mesh_data.positions[edge_b.a]
		var pb1 := mesh_data.positions[edge_b.b]

		var src_a0 := edge_a.a
		var src_a1 := edge_a.b
		var src_b0 := edge_b.a
		var src_b1 := edge_b.b

		# Check untwist in planar projection
		var plane_n := (pb0 - pa0).cross(pa1 - pa0)
		if plane_n.length_squared() < 0.0001:
			plane_n = ref_n
		else:
			plane_n = plane_n.normalized()

		var basis := PBUv.get_planar_basis(plane_n)
		var u_axis: Vector3 = basis["u"]
		var v_axis: Vector3 = basis["v"]

		var p2_a0 := Vector2(u_axis.dot(pa0), v_axis.dot(pa0))
		var p2_a1 := Vector2(u_axis.dot(pa1), v_axis.dot(pa1))
		var p2_b0 := Vector2(u_axis.dot(pb0), v_axis.dot(pb0))
		var p2_b1 := Vector2(u_axis.dot(pb1), v_axis.dot(pb1))

		# Line segment intersection test between diagonal cross candidates
		var isect := PBMath.get_line_segment_intersect(p2_a0, p2_b0, p2_a1, p2_b1)
		if isect.get("intersects", false):
			var tmp_p := pb0
			pb0 = pb1
			pb1 = tmp_p
			var tmp_s := src_b0
			src_b0 = src_b1
			src_b1 = tmp_s

		var q0 := _dup_position(mesh_data, src_a0, Vector3.ZERO)
		var q1 := _dup_position(mesh_data, src_a1, Vector3.ZERO)
		var q2 := _dup_position(mesh_data, src_b1, Vector3.ZERO)
		var q3 := _dup_position(mesh_data, src_b0, Vector3.ZERO)

		var quad_n := (pa1 - pa0).cross(pb0 - pa0)
		if quad_n.dot(ref_n) < 0.0:
			new_face = PBFace.new(PackedInt32Array([
				q0, q3, q2,
				q2, q1, q0,
			]))
		else:
			new_face = PBFace.new(PackedInt32Array([
				q0, q1, q2,
				q2, q3, q0,
			]))

	new_face.submesh_index = submesh
	PBUv.apply_face_uvs(mesh_data, new_face)
	mesh_data.faces.append(new_face)
	_rebuild_topology(mesh_data)

	var new_ids := PackedInt32Array([mesh_data.faces.size() - 1])
	return {"ok": true, "new_face_ids": new_ids}

## Inserts a new edge connecting the center points of selected edges across adjacent faces.
## Quads split into two quads when opposite edges are connected.
## Faces with 3+ edges split radiating around their centroid.
static func connect_edges(mesh_data: PBMeshData, edge_ids: PackedInt32Array) -> Dictionary:
	if mesh_data == null or mesh_data.faces.is_empty():
		return _fail("Connect edges: no mesh data")
	if edge_ids.is_empty():
		return _fail("Connect edges: no edges selected")

	var common := mesh_data.get_common_edges()
	var lookup := mesh_data.get_shared_vertex_lookup()

	var selected_keys := {}
	for eid in edge_ids:
		if eid >= 0 and eid < common.size():
			var ce := common[eid]
			selected_keys[_common_key(lookup, ce.a, ce.b)] = true

	if selected_keys.is_empty():
		return _fail("Connect edges: invalid edge selection")

	# Group selected edges by face
	var touched := {} # face_idx -> Array[Dictionary with {edge: PBEdge, key: Vector2i}]
	for fi in range(mesh_data.faces.size()):
		var f: PBFace = mesh_data.faces[fi]
		if f == null:
			continue
		for fe in f.get_edges():
			var k := _common_key(lookup, fe.a, fe.b)
			if selected_keys.has(k):
				if not touched.has(fi):
					touched[fi] = []
				touched[fi].append({"edge": fe, "key": k})

	if touched.is_empty():
		return _fail("Connect edges: selected edges do not touch any faces")

	# Weed out edges that won't connect across faces (isolated 1-edge touches)
	var affected := {}
	for fi in touched:
		var edge_list: Array = touched[fi]
		if edge_list.size() > 1:
			affected[fi] = edge_list
		else:
			var k: Vector2i = edge_list[0]["key"]
			var has_connecting_neighbor := false
			for other_fi in touched:
				if other_fi != fi and touched[other_fi].size() > 1:
					for other_item in touched[other_fi]:
						if other_item["key"] == k:
							has_connecting_neighbor = true
							break
				if has_connecting_neighbor:
					break
			if has_connecting_neighbor:
				affected[fi] = edge_list

	if affected.is_empty():
		return _fail("Connect edges: no connecting edge pairs found (requires at least 2 edges on a face or connected across faces)")

	var removed := {}
	var added: Array[PBFace] = []

	for fi in affected:
		var face: PBFace = mesh_data.faces[fi]
		var target_edges: Array = affected[fi]
		removed[fi] = true

		var loop: PackedInt32Array = _ordered_loop(face)
		if loop.size() < 3:
			continue

		var f_normal := _face_area_normal(mesh_data, face).normalized()
		if f_normal.length_squared() < 0.0001:
			f_normal = Vector3.UP

		var face_target_keys := {}
		for item in target_edges:
			face_target_keys[item["key"]] = true

		var n_verts: int = loop.size()
		if target_edges.size() == 2 and n_verts == 4:
			# Quad split: 2 opposite edges of a quad
			var split_indices: Array[int] = []
			for i in range(n_verts):
				var va: int = loop[i]
				var vb: int = loop[(i + 1) % n_verts]
				var k := _common_key(lookup, va, vb)
				if face_target_keys.has(k):
					split_indices.append(i)

			if split_indices.size() == 2:
				var i0: int = split_indices[0]
				var i1: int = split_indices[1]
				var m0 := (mesh_data.positions[loop[i0]] + mesh_data.positions[loop[(i0 + 1) % n_verts]]) * 0.5
				var m1 := (mesh_data.positions[loop[i1]] + mesh_data.positions[loop[(i1 + 1) % n_verts]]) * 0.5

				var q_m0a := _dup_position_at(mesh_data, m0, loop[i0])
				var q_m0b := _dup_position_at(mesh_data, m0, loop[i0])
				var q_m1a := _dup_position_at(mesh_data, m1, loop[i1])
				var q_m1b := _dup_position_at(mesh_data, m1, loop[i1])

				var part1_src: Array[int] = []
				var cur := (i0 + 1) % n_verts
				while cur != (i1 + 1) % n_verts:
					part1_src.append(loop[cur])
					cur = (cur + 1) % n_verts

				var part2_src: Array[int] = []
				cur = (i1 + 1) % n_verts
				while cur != (i0 + 1) % n_verts:
					part2_src.append(loop[cur])
					cur = (cur + 1) % n_verts

				var poly1_pts := PackedVector3Array([m0])
				var poly1_idx := PackedInt32Array([q_m0a])
				for s_idx in part1_src:
					poly1_pts.append(mesh_data.positions[s_idx])
					poly1_idx.append(_dup_position(mesh_data, s_idx, Vector3.ZERO))
				poly1_pts.append(m1)
				poly1_idx.append(q_m1a)

				var poly2_pts := PackedVector3Array([m1])
				var poly2_idx := PackedInt32Array([q_m1b])
				for s_idx in part2_src:
					poly2_pts.append(mesh_data.positions[s_idx])
					poly2_idx.append(_dup_position(mesh_data, s_idx, Vector3.ZERO))
				poly2_pts.append(m0)
				poly2_idx.append(q_m0b)

				var f1 := _build_polygon_face_with_normal(mesh_data, poly1_pts, poly1_idx, f_normal, face.submesh_index)
				var f2 := _build_polygon_face_with_normal(mesh_data, poly2_pts, poly2_idx, f_normal, face.submesh_index)
				if f1 != null:
					added.append(f1)
				if f2 != null:
					added.append(f2)
				continue

		# Multi-edge split or single-edge neighbor conform
		var centroid := Vector3.ZERO
		for idx in loop:
			centroid += mesh_data.positions[idx]
		centroid /= float(n_verts)

		var midpoints: Dictionary = {} # edge_index -> Vector3
		for i in range(n_verts):
			var va: int = loop[i]
			var vb: int = loop[(i + 1) % n_verts]
			var k := _common_key(lookup, va, vb)
			if face_target_keys.has(k):
				midpoints[i] = (mesh_data.positions[va] + mesh_data.positions[vb]) * 0.5

		if midpoints.size() >= 2:
			var split_pts := PackedVector3Array()
			var split_dups := PackedInt32Array()
			for i in range(n_verts):
				split_pts.append(mesh_data.positions[loop[i]])
				split_dups.append(loop[i])
				if midpoints.has(i):
					split_pts.append(midpoints[i])
					split_dups.append(loop[i])

			var n_split := split_pts.size()
			for i in range(n_split):
				var p0 := centroid
				var p1 := split_pts[i]
				var p2 := split_pts[(i + 1) % n_split]
				var q0 := _dup_position_at(mesh_data, p0, loop[0])
				var q1 := _dup_position_at(mesh_data, p1, split_dups[i])
				var q2 := _dup_position_at(mesh_data, p2, split_dups[(i + 1) % n_split])
				var tri_pts := PackedVector3Array([p0, p1, p2])
				var tri_idx := PackedInt32Array([q0, q1, q2])
				var nf := _build_polygon_face_with_normal(mesh_data, tri_pts, tri_idx, f_normal, face.submesh_index)
				if nf != null:
					added.append(nf)
		else:
			var split_pts := PackedVector3Array()
			var split_idx := PackedInt32Array()
			for i in range(n_verts):
				split_pts.append(mesh_data.positions[loop[i]])
				split_idx.append(_dup_position(mesh_data, loop[i], Vector3.ZERO))
				if midpoints.has(i):
					split_pts.append(midpoints[i])
					split_idx.append(_dup_position_at(mesh_data, midpoints[i], loop[i]))
			var nf := _build_polygon_face_with_normal(mesh_data, split_pts, split_idx, f_normal, face.submesh_index)
			if nf != null:
				added.append(nf)

	if added.is_empty():
		return _fail("Connect edges: failed to construct sub-faces")

	var replace_res := _replace_faces(mesh_data, removed, added, [])
	_rebuild_topology(mesh_data)

	return {"ok": true, "new_face_ids": replace_res.get("new_face_ids", PackedInt32Array())}

## Inserts an edge between two non-adjacent vertices on a face, splitting the face.
## If 3+ vertices on a face are selected, subdivides the face connecting them to their centroid.
static func connect_vertices(mesh_data: PBMeshData, vertex_ids: PackedInt32Array) -> Dictionary:
	if mesh_data == null or mesh_data.faces.is_empty():
		return _fail("Connect vertices: no mesh data")
	if vertex_ids.size() < 2:
		return _fail("Connect vertices requires at least 2 vertices selected")

	var lookup := mesh_data.get_shared_vertex_lookup()
	var selected_common := {}
	for vid in vertex_ids:
		if vid >= 0 and vid < mesh_data.positions.size():
			selected_common[lookup.get(vid, vid)] = true

	if selected_common.size() < 2:
		return _fail("Connect vertices: select at least 2 distinct vertex positions")

	# Find faces containing 2 or more of the selected vertices
	var splits := {} # face_idx -> Array[int] (indices into face's ordered loop)
	for fi in range(mesh_data.faces.size()):
		var face: PBFace = mesh_data.faces[fi]
		if face == null:
			continue
		var loop: PackedInt32Array = _ordered_loop(face)
		if loop.size() < 3:
			continue
		var matched: Array[int] = []
		for i in range(loop.size()):
			var cv: int = lookup.get(loop[i], loop[i])
			if selected_common.has(cv):
				matched.append(i)
		if matched.size() >= 2:
			splits[fi] = matched

	if splits.is_empty():
		return _fail("Connect vertices: selected vertices must share at least one face")

	var removed := {}
	var added: Array[PBFace] = []

	for fi in splits:
		var face: PBFace = mesh_data.faces[fi]
		var matched_loop_idxs: Array[int] = splits[fi]
		var loop: PackedInt32Array = _ordered_loop(face)
		var n_verts := loop.size()
		var f_normal := _face_area_normal(mesh_data, face).normalized()
		if f_normal.length_squared() < 0.0001:
			f_normal = Vector3.UP

		if matched_loop_idxs.size() == 2:
			var i0: int = mini(matched_loop_idxs[0], matched_loop_idxs[1])
			var i1: int = maxi(matched_loop_idxs[0], matched_loop_idxs[1])

			# Reject if vertices are already connected by an edge along the perimeter
			if i1 - i0 == 1 or (i0 == 0 and i1 == n_verts - 1):
				continue

			removed[fi] = true

			var poly1_pts := PackedVector3Array()
			var poly1_idx := PackedInt32Array()
			var cur := i0
			while true:
				poly1_pts.append(mesh_data.positions[loop[cur]])
				poly1_idx.append(_dup_position(mesh_data, loop[cur], Vector3.ZERO))
				if cur == i1:
					break
				cur = (cur + 1) % n_verts

			var poly2_pts := PackedVector3Array()
			var poly2_idx := PackedInt32Array()
			cur = i1
			while true:
				poly2_pts.append(mesh_data.positions[loop[cur]])
				poly2_idx.append(_dup_position(mesh_data, loop[cur], Vector3.ZERO))
				if cur == i0:
					break
				cur = (cur + 1) % n_verts

			var f1 := _build_polygon_face_with_normal(mesh_data, poly1_pts, poly1_idx, f_normal, face.submesh_index)
			var f2 := _build_polygon_face_with_normal(mesh_data, poly2_pts, poly2_idx, f_normal, face.submesh_index)
			if f1 != null:
				added.append(f1)
			if f2 != null:
				added.append(f2)
		else:
			removed[fi] = true
			var centroid := Vector3.ZERO
			for li in matched_loop_idxs:
				centroid += mesh_data.positions[loop[li]]
			centroid /= float(matched_loop_idxs.size())

			var m_count := matched_loop_idxs.size()
			for k in range(m_count):
				var start_idx: int = matched_loop_idxs[k]
				var end_idx: int = matched_loop_idxs[(k + 1) % m_count]
				var poly_pts := PackedVector3Array([centroid])
				var poly_idx := PackedInt32Array([_dup_position_at(mesh_data, centroid, loop[start_idx])])
				var cur := start_idx
				while true:
					poly_pts.append(mesh_data.positions[loop[cur]])
					poly_idx.append(_dup_position(mesh_data, loop[cur], Vector3.ZERO))
					if cur == end_idx:
						break
					cur = (cur + 1) % n_verts
				var nf := _build_polygon_face_with_normal(mesh_data, poly_pts, poly_idx, f_normal, face.submesh_index)
				if nf != null:
					added.append(nf)

	if added.is_empty():
		return _fail("Connect vertices: vertices are already connected by edges")

	var replace_res := _replace_faces(mesh_data, removed, added, [])
	_rebuild_topology(mesh_data)

	return {"ok": true, "new_face_ids": replace_res.get("new_face_ids", PackedInt32Array())}

## Collapses selected vertices, edges, or faces into a single point.
## Mode: PBEditor.SelectMode (1: VERTEX, 2: EDGE, 3: FACE).
## If collapse_to_first is true, collapses to the first element's position; otherwise to the centroid.
static func collapse_elements(mesh_data: PBMeshData, mode: int, element_ids: PackedInt32Array,
		collapse_to_first: bool = false) -> Dictionary:
	if mesh_data == null or mesh_data.faces.is_empty():
		return _fail("Collapse elements: no mesh data")
	if element_ids.is_empty():
		return _fail("Collapse elements: no elements selected")

	var lookup := mesh_data.get_shared_vertex_lookup()
	var target_indices := PackedInt32Array()

	if mode == 1: # VERTEX
		for vid in element_ids:
			if vid >= 0 and vid < mesh_data.positions.size():
				var cg: int = lookup.get(vid, vid)
				for i in range(mesh_data.positions.size()):
					if lookup.get(i, i) == cg:
						target_indices.append(i)
	elif mode == 2: # EDGE
		var common := mesh_data.get_common_edges()
		for eid in element_ids:
			if eid >= 0 and eid < common.size():
				var ce := common[eid]
				var ca: int = lookup.get(ce.a, ce.a)
				var cb: int = lookup.get(ce.b, ce.b)
				for i in range(mesh_data.positions.size()):
					var c: int = lookup.get(i, i)
					if c == ca or c == cb:
						target_indices.append(i)
	elif mode == 3: # FACE
		for fid in element_ids:
			if fid >= 0 and fid < mesh_data.faces.size():
				var f: PBFace = mesh_data.faces[fid]
				if f != null:
					for idx in f.get_distinct_indexes():
						var cg: int = lookup.get(idx, idx)
						for i in range(mesh_data.positions.size()):
							if lookup.get(i, i) == cg:
								target_indices.append(i)

	if target_indices.is_empty():
		return _fail("Collapse elements: no valid vertices found")

	var target_pos := Vector3.ZERO
	if collapse_to_first:
		target_pos = mesh_data.positions[target_indices[0]]
	else:
		var sum_pos := Vector3.ZERO
		var distinct_pts := {}
		for idx in target_indices:
			var p := mesh_data.positions[idx]
			var k := Vector3(snappedf(p.x, 0.0001), snappedf(p.y, 0.0001), snappedf(p.z, 0.0001))
			if not distinct_pts.has(k):
				distinct_pts[k] = true
				sum_pos += p
		target_pos = sum_pos / float(maxi(1, distinct_pts.size()))

	for idx in target_indices:
		mesh_data.positions[idx] = target_pos

	# Eliminate degenerate triangles
	var surviving_faces: Array[PBFace] = []
	for face in mesh_data.faces:
		if face == null:
			continue
		var raw_idxs := face.get_indexes()
		var valid_tris := PackedInt32Array()
		for i in range(0, raw_idxs.size(), 3):
			var i0 := raw_idxs[i]
			var i1 := raw_idxs[i + 1]
			var i2 := raw_idxs[i + 2]
			var p0 := mesh_data.positions[i0]
			var p1 := mesh_data.positions[i1]
			var p2 := mesh_data.positions[i2]
			if p0.distance_to(p1) > 0.0005 and p1.distance_to(p2) > 0.0005 and p2.distance_to(p0) > 0.0005:
				valid_tris.append_array(PackedInt32Array([i0, i1, i2]))

		if not valid_tris.is_empty():
			face.set_indexes(valid_tris)
			surviving_faces.append(face)

	if surviving_faces.is_empty():
		return _fail("Collapse elements: all mesh geometry collapsed")

	mesh_data.faces = surviving_faces
	_rebuild_topology(mesh_data)

	return {"ok": true, "target_position": target_pos}

## Detects open boundary loops touching selected edges and caps each with a new polygon face.
## If edge_ids is empty, caps all open boundary loops found on the mesh.
static func fill_hole(mesh_data: PBMeshData, edge_ids: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	if mesh_data == null or mesh_data.faces.is_empty():
		return _fail("Fill hole: no mesh data")

	var lookup := mesh_data.get_shared_vertex_lookup()
	var common := mesh_data.get_common_edges()

	var usage := {} # key -> int
	var directed_half_edges := {} # key -> {a: int, b: int, face: PBFace}
	for face in mesh_data.faces:
		if face == null:
			continue
		for fe in face.get_edges():
			var k := _common_key(lookup, fe.a, fe.b)
			usage[k] = usage.get(k, 0) + 1
			directed_half_edges[k] = {"a": fe.a, "b": fe.b, "face": face}

	var boundary_keys := {}
	for k in usage:
		if usage[k] == 1:
			boundary_keys[k] = true

	if boundary_keys.is_empty():
		return _fail("Fill hole: no open boundary holes found on mesh")

	var target_keys := {}
	if not edge_ids.is_empty():
		for eid in edge_ids:
			if eid >= 0 and eid < common.size():
				var ce := common[eid]
				target_keys[_common_key(lookup, ce.a, ce.b)] = true

	var next_hop := {} # common_vertex -> {next_common: int, src_a: int, src_b: int, face: PBFace}
	for k in boundary_keys:
		var d: Dictionary = directed_half_edges[k]
		var ca: int = lookup.get(d["a"], d["a"])
		var cb: int = lookup.get(d["b"], d["b"])
		next_hop[cb] = {"next_common": ca, "src_a": d["b"], "src_b": d["a"], "face": d["face"], "key": k}

	var visited_keys := {}
	var added_faces: Array[PBFace] = []

	for start_cb in next_hop:
		var info: Dictionary = next_hop[start_cb]
		if visited_keys.has(info["key"]):
			continue

		var cycle_common: Array[int] = []
		var cycle_src: Array[int] = []
		var cycle_faces: Array[PBFace] = []
		var cycle_keys: Array[Vector2i] = []
		var cur: int = start_cb
		var guard: int = next_hop.size() + 2

		while guard > 0 and next_hop.has(cur):
			guard -= 1
			var step: Dictionary = next_hop[cur]
			cycle_common.append(cur)
			cycle_src.append(step["src_a"])
			cycle_faces.append(step["face"])
			cycle_keys.append(step["key"])
			cur = step["next_common"]
			if cur == start_cb:
				break

		for k in cycle_keys:
			visited_keys[k] = true

		if cycle_common.size() < 3 or cur != start_cb:
			continue

		if not target_keys.is_empty():
			var matches := false
			for k in cycle_keys:
				if target_keys.has(k):
					matches = true
					break
			if not matches:
				continue

		var loop_pts := PackedVector3Array()
		var loop_dups := PackedInt32Array()
		for s_idx in cycle_src:
			loop_pts.append(mesh_data.positions[s_idx])
			loop_dups.append(_dup_position(mesh_data, s_idx, Vector3.ZERO))

		var loop_n := PBMath.normal_from_positions(loop_pts)
		if loop_n.length_squared() < 0.0001:
			loop_n = _face_area_normal(mesh_data, cycle_faces[0]).normalized()

		var cap := _build_polygon_face_with_normal(mesh_data, loop_pts, loop_dups, loop_n, cycle_faces[0].submesh_index)
		if cap != null:
			added_faces.append(cap)

	if added_faces.is_empty():
		return _fail("Fill hole: no matching open holes found")

	mesh_data.faces.append_array(added_faces)
	_rebuild_topology(mesh_data)

	var new_ids := PackedInt32Array()
	var base_idx := mesh_data.faces.size() - added_faces.size()
	for i in range(added_faces.size()):
		new_ids.append(base_idx + i)

	return {"ok": true, "new_face_ids": new_ids}

static func _build_polygon_face_with_normal(mesh_data: PBMeshData, pts_3d: PackedVector3Array,
		corner_indices: PackedInt32Array, ref_normal: Vector3, submesh: int) -> PBFace:
	var n := pts_3d.size()
	if n < 3:
		return null
	var tri_indexes := PackedInt32Array()
	if n == 3:
		tri_indexes = PackedInt32Array([0, 1, 2])
	elif n == 4:
		tri_indexes = PackedInt32Array([0, 1, 2, 2, 3, 0])
	else:
		var basis := PBUv.get_planar_basis(ref_normal)
		var u_axis: Vector3 = basis["u"]
		var v_axis: Vector3 = basis["v"]
		var pts_2d := PackedVector2Array()
		for p in pts_3d:
			pts_2d.append(Vector2(u_axis.dot(p), v_axis.dot(p)))
		var area2 := 0.0
		for i in range(n):
			area2 += pts_2d[i].cross(pts_2d[(i + 1) % n])
		var pts_for_clip := pts_2d
		var reversed := false
		if area2 < 0.0:
			pts_for_clip = pts_2d.duplicate()
			pts_for_clip.reverse()
			reversed = true
		var raw_tris := PBShapeComplex._triangulate_2d(pts_for_clip)
		for t in raw_tris:
			var i0: int = t[0]
			var i1: int = t[1]
			var i2: int = t[2]
			if reversed:
				i0 = n - 1 - i0
				i1 = n - 1 - i1
				i2 = n - 1 - i2
				tri_indexes.append_array(PackedInt32Array([i0, i2, i1]))
			else:
				tri_indexes.append_array(PackedInt32Array([i0, i1, i2]))

	var final_indexes := PackedInt32Array()
	for local_idx in tri_indexes:
		final_indexes.append(corner_indices[local_idx])

	var fn := PBMath.normal_from_positions(mesh_data.positions, final_indexes)
	if fn.dot(ref_normal) < 0.0:
		var reversed_final := PackedInt32Array()
		for i in range(0, final_indexes.size(), 3):
			reversed_final.append(final_indexes[i])
			reversed_final.append(final_indexes[i + 2])
			reversed_final.append(final_indexes[i + 1])
		final_indexes = reversed_final

	var face := PBFace.new(final_indexes)
	face.submesh_index = submesh
	PBUv.apply_face_uvs(mesh_data, face)
	return face

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

## Maps perimeter boundary edges of the given face region to their ids in
## get_common_edges().
static func face_perimeter_common_edge_ids(mesh_data: PBMeshData, face_ids: PackedInt32Array) -> PackedInt32Array:
	var result := PackedInt32Array()
	if mesh_data == null or face_ids.is_empty():
		return result
	var boundary_edges: Array = _region_boundary_edges(mesh_data, face_ids)
	if boundary_edges.is_empty():
		return result
	var lookup := mesh_data.get_shared_vertex_lookup()
	var wanted := {}
	for be in boundary_edges:
		wanted[_common_key(lookup, be.a, be.b)] = true
	var common := mesh_data.get_common_edges()
	for i in range(common.size()):
		if wanted.has(_common_key(lookup, common[i].a, common[i].b)):
			result.append(i)
	return result

## Returns the common edge ids for all edges belonging to the given faces.
## Unlike face_perimeter_common_edge_ids (which only returns the region boundary edges),
## this returns every edge of every selected face, so selecting all faces of a closed
## mesh selects all of its edges for beveling.
static func face_edges_common_ids(mesh_data: PBMeshData, face_ids: PackedInt32Array) -> PackedInt32Array:
	var result := PackedInt32Array()
	if mesh_data == null or face_ids.is_empty():
		return result
	var lookup := mesh_data.get_shared_vertex_lookup()
	var wanted := {}
	for fi in face_ids:
		if fi < 0 or fi >= mesh_data.faces.size():
			continue
		var f := mesh_data.faces[fi]
		if f == null:
			continue
		for edge in f.get_edges():
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

## Cuts a face with a path of 3D points.
## - Edge-to-edge cut: if cut_points start and end on the boundary edges or
##   vertices, splits the face into two n-gon PBFace instances along the path.
## - Closed-loop cut: if cut_points form an interior loop (or is_closed is true),
##   cuts that shape into the face, producing an inner n-gon face and a
##   surrounding outer n-gon face.
## Both resulting faces are clean PBFace instances selectable as individual faces.
static func cut_face(
	mesh_data: PBMeshData,
	face_index: int,
	cut_points: PackedVector3Array,
	is_closed: bool = false
) -> Dictionary:
	if mesh_data == null or face_index < 0 or face_index >= mesh_data.faces.size():
		return _fail("Cut face: invalid face index")
	if cut_points.size() < 2:
		return _fail("Cut face: path must have at least 2 points")
	var face: PBFace = mesh_data.faces[face_index]
	if face == null or face.get_indexes().is_empty():
		return _fail("Cut face: empty face")
	var loop := _ordered_loop(face)
	if loop.size() < 3:
		return _fail("Cut face: face boundary is not a simple loop")

	var normal := _face_area_normal(mesh_data, face).normalized()
	if normal.length_squared() < 0.0001:
		return _fail("Cut face: zero area face")
	var up := Vector3.UP if absf(normal.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var u_axis := normal.cross(up).normalized()
	var v_axis := normal.cross(u_axis).normalized()
	var origin := mesh_data.positions[loop[0]]

	var to_2d := func(p3: Vector3) -> Vector2:
		var d := p3 - origin
		return Vector2(d.dot(u_axis), d.dot(v_axis))

	var to_3d := func(p2: Vector2) -> Vector3:
		return origin + u_axis * p2.x + v_axis * p2.y

	var loop_2d := PackedVector2Array()
	for idx in loop:
		loop_2d.append(to_2d.call(mesh_data.positions[idx]))
	var loop_area := _polygon_area_2d(loop_2d)
	if loop_area < 0.0:
		u_axis = -u_axis
		v_axis = normal.cross(u_axis).normalized()
		loop_2d.clear()
		for idx in loop:
			loop_2d.append(to_2d.call(mesh_data.positions[idx]))
		loop_area = _polygon_area_2d(loop_2d)

	var raw_cut_2d := PackedVector2Array()
	for p3 in cut_points:
		raw_cut_2d.append(to_2d.call(p3))
	var cut_2d := PackedVector2Array()
	for pt in raw_cut_2d:
		if cut_2d.is_empty() or cut_2d[cut_2d.size() - 1].distance_to(pt) > 0.0001:
			cut_2d.append(pt)
	if cut_2d.size() < 2:
		return _fail("Cut face: cut points collapsed to < 2 distinct points")

	var snap_thresh: float = 0.15  # 15cm tolerance to snap to perimeter edges
	var boundary_indices: Array[int] = []
	for k in range(cut_2d.size()):
		var info := _find_best_edge_for_point_2d(loop_2d, cut_2d[k])
		if float(info["dist"]) <= snap_thresh:
			boundary_indices.append(k)
			cut_2d[k] = info["snapped"]

	# Multi-slice condition:
	# 1) Open cut with >= 2 boundary hits (e.g. zig-zag or edge-to-edge)
	# 2) Closed cut that touches boundaries at 2 or more distinct points (e.g. Image #1)
	var is_multi_slice := false
	if not is_closed and boundary_indices.size() >= 2:
		is_multi_slice = true
	elif is_closed and boundary_indices.size() > 2:
		# More than start and end (which are coincident)
		is_multi_slice = true

	if is_multi_slice:
		# Split adjacent faces for all boundary split points
		var n_loop := loop_2d.size()
		for b_k in boundary_indices:
			var b_info := _find_best_edge_for_point_2d(loop_2d, cut_2d[b_k])
			if not bool(b_info["is_vertex"]):
				var edge_idx: int = b_info["edge_idx"]
				var pa := mesh_data.positions[loop[edge_idx]]
				var pb := mesh_data.positions[loop[(edge_idx + 1) % n_loop]]
				var split_p := to_3d.call(cut_2d[b_k])
				_split_edge_in_adjacent_faces(mesh_data, face_index, pa, pb, split_p)

		# Sequentially slice polygons across all boundary chains
		var current_polys: Array[PackedVector2Array] = [loop_2d]
		for b_step in range(boundary_indices.size() - 1):
			var start_idx: int = boundary_indices[b_step]
			var end_idx: int = boundary_indices[b_step + 1]
			if start_idx == end_idx:
				continue
			var chain := PackedVector2Array()
			for c_i in range(start_idx, end_idx + 1):
				chain.append(cut_2d[c_i])
			if chain.size() < 2:
				continue
			if chain[0].distance_to(chain[chain.size() - 1]) < 0.001:
				continue

			var mid_pt := chain[1] if chain.size() > 2 else (chain[0] + chain[1]) * 0.5
			var target_poly_idx := -1
			for p_i in range(current_polys.size()):
				var poly := current_polys[p_i]
				var e0 := _find_best_edge_for_point_2d(poly, chain[0])
				var e1 := _find_best_edge_for_point_2d(poly, chain[chain.size() - 1])
				if float(e0["dist"]) <= 0.08 and float(e1["dist"]) <= 0.08:
					if chain.size() <= 2 or Geometry2D.is_point_in_polygon(mid_pt, poly):
						target_poly_idx = p_i
						break

			if target_poly_idx >= 0:
				var target_poly: PackedVector2Array = current_polys[target_poly_idx]
				current_polys.remove_at(target_poly_idx)
				var e0 := _find_best_edge_for_point_2d(target_poly, chain[0])
				var e1 := _find_best_edge_for_point_2d(target_poly, chain[chain.size() - 1])
				var parts := _split_polygon_by_path_2d(target_poly, chain, e0, e1)
				if parts.size() >= 2:
					current_polys.append(parts[0])
					current_polys.append(parts[1])
				else:
					current_polys.append(target_poly)

		if current_polys.size() < 2:
			return _fail("Cut face: could not slice face boundary")

		var new_faces: Array[PBFace] = []
		for poly in current_polys:
			if _polygon_area_2d(poly) < 0.0:
				poly.reverse()
			var tris := PBShapeComplex._triangulate_2d(poly)
			if tris.is_empty():
				continue
			var base_idx := mesh_data.positions.size()
			for p2 in poly:
				mesh_data.positions.append(to_3d.call(p2))
				mesh_data.textures0.append(Vector2(p2.x, p2.y))
			var idxs := PackedInt32Array()
			for t in tris:
				var cp: float = (poly[t[1]] - poly[t[0]]).cross(poly[t[2]] - poly[t[0]])
				if absf(cp) < 0.00001:
					continue
				if cp > 0.0:
					idxs.append_array(PackedInt32Array([base_idx + int(t[0]), base_idx + int(t[1]), base_idx + int(t[2])]))
				else:
					idxs.append_array(PackedInt32Array([base_idx + int(t[0]), base_idx + int(t[2]), base_idx + int(t[1])]))
			if idxs.is_empty():
				continue
			var nf := PBFace.new(idxs)
			nf.submesh_index = face.submesh_index
			nf.smoothing_group = face.smoothing_group
			nf.manual_uv = face.manual_uv
			new_faces.append(nf)

		if new_faces.is_empty():
			return _fail("Cut face: triangulation failed on sliced pieces")

		var res := _replace_faces(mesh_data, {face_index: true}, new_faces, [])
		_rebuild_topology(mesh_data)
		return res
	else:
		# Closed loop cut inside the face
		if cut_2d.size() < 3:
			return _fail("Cut face: closed cut requires at least 3 vertices")
		if cut_2d[0].distance_to(cut_2d[cut_2d.size() - 1]) < 0.0001:
			cut_2d.remove_at(cut_2d.size() - 1)
		if cut_2d.size() < 3:
			return _fail("Cut face: closed cut requires at least 3 vertices")

		var hole_poly := cut_2d.duplicate()
		if _polygon_area_2d(hole_poly) < 0.0:
			hole_poly.reverse()

		var tris_inner := PBShapeComplex._triangulate_2d(hole_poly)
		if tris_inner.is_empty():
			return _fail("Cut face: triangulation failed on inner shape")

		var base_inner := mesh_data.positions.size()
		for p2 in hole_poly:
			mesh_data.positions.append(to_3d.call(p2))
			mesh_data.textures0.append(Vector2(p2.x, p2.y))
		var idxs_inner := PackedInt32Array()
		for t in tris_inner:
			var cp: float = (hole_poly[t[1]] - hole_poly[t[0]]).cross(hole_poly[t[2]] - hole_poly[t[0]])
			if absf(cp) < 0.00001:
				continue
			if cp > 0.0:
				idxs_inner.append_array(PackedInt32Array([base_inner + int(t[0]), base_inner + int(t[1]), base_inner + int(t[2])]))
			else:
				idxs_inner.append_array(PackedInt32Array([base_inner + int(t[0]), base_inner + int(t[2]), base_inner + int(t[1])]))
		var face_inner := PBFace.new(idxs_inner)
		face_inner.submesh_index = face.submesh_index
		face_inner.smoothing_group = face.smoothing_group
		face_inner.manual_uv = face.manual_uv

		var outer_spliced := _cut_hole_into_polygon_2d(loop_2d, hole_poly)
		if outer_spliced.is_empty():
			return _fail("Cut face: failed to splice hole into outer boundary")
		var tris_outer := PBShapeComplex._triangulate_2d(outer_spliced)
		if tris_outer.is_empty():
			return _fail("Cut face: triangulation failed on outer face")

		var base_outer := mesh_data.positions.size()
		for p2 in outer_spliced:
			mesh_data.positions.append(to_3d.call(p2))
			mesh_data.textures0.append(Vector2(p2.x, p2.y))
		var idxs_outer := PackedInt32Array()
		for t in tris_outer:
			var cp: float = (outer_spliced[t[1]] - outer_spliced[t[0]]).cross(outer_spliced[t[2]] - outer_spliced[t[0]])
			if absf(cp) < 0.00001:
				continue
			if cp > 0.0:
				idxs_outer.append_array(PackedInt32Array([base_outer + int(t[0]), base_outer + int(t[1]), base_outer + int(t[2])]))
			else:
				idxs_outer.append_array(PackedInt32Array([base_outer + int(t[0]), base_outer + int(t[2]), base_outer + int(t[1])]))
		var face_outer := PBFace.new(idxs_outer)
		face_outer.submesh_index = face.submesh_index
		face_outer.smoothing_group = face.smoothing_group
		face_outer.manual_uv = face.manual_uv

		var res := _replace_faces(mesh_data, {face_index: true}, [face_inner, face_outer], [])
		_rebuild_topology(mesh_data)
		return res

static func _polygon_area_2d(poly: PackedVector2Array) -> float:
	var area := 0.0
	var n := poly.size()
	for i in range(n):
		var j := (i + 1) % n
		area += poly[i].x * poly[j].y - poly[j].x * poly[i].y
	return area * 0.5

static func _point_to_segment_distance_2d(p: Vector2, a: Vector2, b: Vector2) -> Dictionary:
	var ab := b - a
	var ab_len2 := ab.length_squared()
	if ab_len2 < 0.00000001:
		return {"dist": p.distance_to(a), "closest": a, "t": 0.0}
	var t := clampf((p - a).dot(ab) / ab_len2, 0.0, 1.0)
	var closest := a + ab * t
	return {"dist": p.distance_to(closest), "closest": closest, "t": t}

static func _find_best_edge_for_point_2d(loop: PackedVector2Array, pt: Vector2) -> Dictionary:
	var best_dist := INF
	var best_edge := -1
	var best_closest := pt
	var best_t: float = 0.0
	var is_vert := false
	var vert_idx := -1
	var n := loop.size()
	for i in range(n):
		var j := (i + 1) % n
		var res := _point_to_segment_distance_2d(pt, loop[i], loop[j])
		var d: float = res["dist"]
		if d < best_dist:
			best_dist = d
			best_edge = i
			best_closest = res["closest"]
			best_t = res["t"]
			var t: float = res["t"]
			if t <= 0.001:
				is_vert = true
				vert_idx = i
			elif t >= 0.999:
				is_vert = true
				vert_idx = j
			else:
				is_vert = false
				vert_idx = -1
	return {
		"edge_idx": best_edge,
		"snapped": best_closest,
		"is_vertex": is_vert,
		"vert_idx": vert_idx,
		"dist": best_dist,
		"t": best_t
	}

static func _clean_polygon_2d(poly: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in poly:
		if out.is_empty() or out[out.size() - 1].distance_to(p) > 0.0005:
			out.append(p)
	if out.size() > 1 and out[0].distance_to(out[out.size() - 1]) < 0.0005:
		out.remove_at(out.size() - 1)
	return out

static func _split_polygon_by_path_2d(
	loop_2d: PackedVector2Array,
	cut_2d: PackedVector2Array,
	start_info: Dictionary,
	end_info: Dictionary
) -> Array[PackedVector2Array]:
	var n := loop_2d.size()
	var i: int = start_info["edge_idx"]
	var j: int = end_info["edge_idx"]
	var c0: Vector2 = cut_2d[0]
	var c1: Vector2 = cut_2d[cut_2d.size() - 1]
	var t0: float = start_info["t"]
	var t1: float = end_info["t"]

	# Build augmented perimeter cycle with c0 and c1 cleanly inserted
	var aug := PackedVector2Array()
	for k in range(n):
		aug.append(loop_2d[k])
		if i == j and k == i:
			if t0 < t1:
				if t0 > 0.001 and t0 < 0.999:
					aug.append(c0)
				if t1 > 0.001 and t1 < 0.999:
					aug.append(c1)
			else:
				if t1 > 0.001 and t1 < 0.999:
					aug.append(c1)
				if t0 > 0.001 and t0 < 0.999:
					aug.append(c0)
		else:
			if k == i and t0 > 0.001 and t0 < 0.999:
				aug.append(c0)
			elif k == j and t1 > 0.001 and t1 < 0.999:
				aug.append(c1)

	var cleaned_aug := _clean_polygon_2d(aug)
	var m := cleaned_aug.size()
	if m < 3:
		return []

	# Find indices of c0 and c1 in cleaned_aug
	var idx0 := -1
	var idx1 := -1
	var d0 := INF
	var d1 := INF
	for k in range(m):
		var dist0 := cleaned_aug[k].distance_to(c0)
		if dist0 < d0:
			d0 = dist0
			idx0 = k
		var dist1 := cleaned_aug[k].distance_to(c1)
		if dist1 < d1:
			d1 = dist1
			idx1 = k

	if idx0 == idx1 or idx0 < 0 or idx1 < 0:
		return []

	# Arc 1: along augmented perimeter from idx0 to idx1
	var arc1 := PackedVector2Array()
	var curr := idx0
	while true:
		arc1.append(cleaned_aug[curr])
		if curr == idx1:
			break
		curr = (curr + 1) % m

	# Arc 2: along augmented perimeter from idx1 to idx0
	var arc2 := PackedVector2Array()
	curr = idx1
	while true:
		arc2.append(cleaned_aug[curr])
		if curr == idx0:
			break
		curr = (curr + 1) % m

	# Poly A: Arc 1 + reversed cut interior points (c1 -> c0)
	var poly_A := PackedVector2Array(arc1)
	for k in range(cut_2d.size() - 2, 0, -1):
		poly_A.append(cut_2d[k])

	# Poly B: Arc 2 + forward cut interior points (c0 -> c1)
	var poly_B := PackedVector2Array(arc2)
	for k in range(1, cut_2d.size() - 1):
		poly_B.append(cut_2d[k])

	poly_A = _clean_polygon_2d(poly_A)
	poly_B = _clean_polygon_2d(poly_B)
	return [poly_A, poly_B]

static func _segments_intersect_2d(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> bool:
	var d1 := (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
	var d2 := (b.x - a.x) * (d.y - a.y) - (b.y - a.y) * (d.x - a.x)
	var d3 := (d.x - c.x) * (a.y - c.y) - (d.y - c.y) * (a.x - c.x)
	var d4 := (d.x - c.x) * (b.y - c.y) - (d.y - c.y) * (b.x - c.x)
	if ((d1 > 0.00001 and d2 < -0.00001) or (d1 < -0.00001 and d2 > 0.00001)) and \
	   ((d3 > 0.00001 and d4 < -0.00001) or (d3 < -0.00001 and d4 > 0.00001)):
		return true
	return false

static func _cut_hole_into_polygon_2d(outer_2d: PackedVector2Array, hole_2d: PackedVector2Array) -> PackedVector2Array:
	var n_out := outer_2d.size()
	var n_hole := hole_2d.size()
	if n_out < 3 or n_hole < 3:
		return PackedVector2Array()

	var best_dist := INF
	var best_b := 0
	var best_a := 0

	for a in range(n_hole):
		var ha := hole_2d[a]
		for b in range(n_out):
			var vb := outer_2d[b]
			var dist := ha.distance_to(vb)
			if dist < 0.0001 or dist >= best_dist:
				continue
			var intersects := false
			for i in range(n_out):
				var i_next := (i + 1) % n_out
				if i == b or i_next == b:
					continue
				if _segments_intersect_2d(vb, ha, outer_2d[i], outer_2d[i_next]):
					intersects = true
					break
			if intersects:
				continue
			for j in range(n_hole):
				var j_next := (j + 1) % n_hole
				if j == a or j_next == a:
					continue
				if _segments_intersect_2d(vb, ha, hole_2d[j], hole_2d[j_next]):
					intersects = true
					break
			if not intersects:
				best_dist = dist
				best_b = b
				best_a = a

	var merged := PackedVector2Array()
	for k in range(0, best_b + 1):
		merged.append(outer_2d[k])
	for k in range(n_hole + 1):
		var h_idx := (best_a - k + n_hole) % n_hole
		merged.append(hole_2d[h_idx])
	merged.append(outer_2d[best_b])
	for k in range(best_b + 1, n_out):
		merged.append(outer_2d[k])

	return merged

static func _split_edge_in_adjacent_faces(
	mesh_data: PBMeshData,
	ignore_face_idx: int,
	p_a: Vector3,
	p_b: Vector3,
	p_split: Vector3
) -> void:
	for fi in range(mesh_data.faces.size()):
		if fi == ignore_face_idx:
			continue
		var f := mesh_data.faces[fi]
		if f == null:
			continue
		var idxs := f.get_indexes()
		var n_tris := idxs.size() / 3
		var found_tri := -1
		var edge_i0 := -1
		var edge_i1 := -1
		var opposite_i := -1

		for t in range(n_tris):
			var i0: int = idxs[t * 3]
			var i1: int = idxs[t * 3 + 1]
			var i2: int = idxs[t * 3 + 2]
			var p0: Vector3 = mesh_data.positions[i0]
			var p1: Vector3 = mesh_data.positions[i1]
			var p2: Vector3 = mesh_data.positions[i2]

			if (p0.distance_to(p_a) < 0.001 and p1.distance_to(p_b) < 0.001) or (p0.distance_to(p_b) < 0.001 and p1.distance_to(p_a) < 0.001):
				found_tri = t; edge_i0 = i0; edge_i1 = i1; opposite_i = i2; break
			if (p1.distance_to(p_a) < 0.001 and p2.distance_to(p_b) < 0.001) or (p1.distance_to(p_b) < 0.001 and p2.distance_to(p_a) < 0.001):
				found_tri = t; edge_i0 = i1; edge_i1 = i2; opposite_i = i0; break
			if (p2.distance_to(p_a) < 0.001 and p0.distance_to(p_b) < 0.001) or (p2.distance_to(p_b) < 0.001 and p0.distance_to(p_a) < 0.001):
				found_tri = t; edge_i0 = i2; edge_i1 = i0; opposite_i = i1; break

		if found_tri >= 0:
			var new_v_idx := mesh_data.positions.size()
			mesh_data.positions.append(p_split)
			var uv0: Vector2 = mesh_data.textures0[edge_i0] if edge_i0 < mesh_data.textures0.size() else Vector2.ZERO
			var uv1: Vector2 = mesh_data.textures0[edge_i1] if edge_i1 < mesh_data.textures0.size() else Vector2.ZERO
			var total_dist := p_a.distance_to(p_b)
			var t_factor := p_a.distance_to(p_split) / total_dist if total_dist > 0.0001 else 0.5
			mesh_data.textures0.append(uv0.lerp(uv1, t_factor))

			var new_idxs := PackedInt32Array()
			for t in range(n_tris):
				if t == found_tri:
					new_idxs.append_array(PackedInt32Array([edge_i0, new_v_idx, opposite_i]))
					new_idxs.append_array(PackedInt32Array([new_v_idx, edge_i1, opposite_i]))
				else:
					new_idxs.append_array(PackedInt32Array([idxs[t * 3], idxs[t * 3 + 1], idxs[t * 3 + 2]]))
			f.set_indexes(new_idxs)
			f.invalidate_cache()

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
			directed[key] = {"a": edge.a, "b": edge.b, "face_idx": fi}
	var result: Array = []
	for key in usage:
		if usage[key] == 1:
			result.append(directed[key])
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
