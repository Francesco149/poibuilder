## Tests for Session 5 Topology Operations: Bridge, Connect, Collapse, Fill Hole.
##
## Upholds PoiBuilder non-negotiable invariants:
## 1. Position-Privacy: corner positions owned exclusively per face, welds rebuilt.
## 2. CCW-from-outside internal winding with outward normals.
## 3. Watertightness where expected (edge usage counts == 2 on closed surfaces).
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
	assert_eq(bad, 0, context + ": every perimeter edge is used by exactly 2 faces")

func _assert_compiled_convention(data: PBMeshData, context: String) -> void:
	var mesh: ArrayMesh = data.to_array_mesh()
	assert_true(mesh.get_surface_count() > 0, context + ": compiles to a surface")
	if mesh.get_surface_count() == 0:
		return
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	assert_gt(verts.size(), 0, context + ": non-empty vertex buffer")
	assert_gt(idx.size(), 0, context + ": non-empty index buffer")

# ==============================================================================
# Bridge Edges Tests
# ==============================================================================

func test_bridge_edges_quad() -> void:
	var data := _cube()
	# Delete top face (face 4) to create an open 4-edge boundary
	var del_res := PBMeshOps.delete_faces(data, PackedInt32Array([4]))
	assert_true(del_res["ok"], "Delete face 4 succeeds")
	assert_eq(data.faces.size(), 5, "5 faces remain")

	# Find boundary edges (usage count == 1)
	var usage := PBMeshOps.edge_usage_counts(data)
	var common := data.get_common_edges()
	var lookup := data.get_shared_vertex_lookup()
	var boundary_eids: Array[int] = []
	for i in range(common.size()):
		var ce := common[i]
		var k := PBMeshOps._common_key(lookup, ce.a, ce.b)
		if usage.get(k, 0) == 1:
			boundary_eids.append(i)

	assert_eq(boundary_eids.size(), 4, "Top opening has 4 boundary edges")

	# Pick two opposite boundary edges
	var e0 := common[boundary_eids[0]]
	var opposite_eid := -1
	for i in range(1, boundary_eids.size()):
		var cand := common[boundary_eids[i]]
		# Disjoint if they share no common vertices
		var ca0: int = lookup.get(e0.a, e0.a)
		var ca1: int = lookup.get(e0.b, e0.b)
		var cb0: int = lookup.get(cand.a, cand.a)
		var cb1: int = lookup.get(cand.b, cand.b)
		if ca0 != cb0 and ca0 != cb1 and ca1 != cb0 and ca1 != cb1:
			opposite_eid = boundary_eids[i]
			break

	assert_ne(opposite_eid, -1, "Found opposite boundary edge")

	var bridge_res := PBMeshOps.bridge_edges(data, PackedInt32Array([boundary_eids[0], opposite_eid]))
	assert_true(bridge_res.get("ok", false), "Bridge edges succeeded")
	assert_eq(data.faces.size(), 6, "Now 6 faces after bridge")

	# Check new face normal points roughly +Y (upward)
	var new_fid: int = bridge_res["new_face_ids"][0]
	var fn: Vector3 = PBMath.normal_from_positions(data.positions, data.faces[new_fid].get_indexes())
	assert_gt(fn.y, 0.5, "Bridge face normal points upward (+Y)")

	# Verify position privacy: all positions referenced by new face are valid and duplicated
	var distinct := data.faces[new_fid].get_distinct_indexes()
	assert_eq(distinct.size(), 4, "Bridge quad has 4 distinct corners")
	_assert_compiled_convention(data, "Bridge quad")

func test_bridge_edges_triangle() -> void:
	var data := _cube()
	# Delete top face (4) to create an open boundary
	PBMeshOps.delete_faces(data, PackedInt32Array([4]))
	assert_eq(data.faces.size(), 5, "5 faces remain")

	# Find two boundary edges from DIFFERENT faces that share a vertex
	var usage := PBMeshOps.edge_usage_counts(data)
	var common := data.get_common_edges()
	var lookup := data.get_shared_vertex_lookup()
	var boundary_eids: Array[int] = []
	for i in range(common.size()):
		var ce := common[i]
		var k := PBMeshOps._common_key(lookup, ce.a, ce.b)
		if usage.get(k, 0) == 1:
			boundary_eids.append(i)

	var eid_a := -1
	var eid_b := -1
	for i in range(boundary_eids.size()):
		var ea := common[boundary_eids[i]]
		var ca0: int = lookup.get(ea.a, ea.a)
		var ca1: int = lookup.get(ea.b, ea.b)
		var face_a := -1
		for fi in range(data.faces.size()):
			for fe in data.faces[fi].get_edges():
				if PBMeshOps._common_key(lookup, fe.a, fe.b) == PBMeshOps._common_key(lookup, ea.a, ea.b):
					face_a = fi
					break
			if face_a != -1:
				break

		for j in range(i + 1, boundary_eids.size()):
			var eb := common[boundary_eids[j]]
			var cb0: int = lookup.get(eb.a, eb.a)
			var cb1: int = lookup.get(eb.b, eb.b)
			if ca0 == cb0 or ca0 == cb1 or ca1 == cb0 or ca1 == cb1:
				var face_b := -1
				for fi in range(data.faces.size()):
					for fe in data.faces[fi].get_edges():
						if PBMeshOps._common_key(lookup, fe.a, fe.b) == PBMeshOps._common_key(lookup, eb.a, eb.b):
							face_b = fi
							break
					if face_b != -1:
						break
				if face_a != face_b:
					eid_a = boundary_eids[i]
					eid_b = boundary_eids[j]
					break
		if eid_a != -1:
			break

	assert_ne(eid_a, -1, "Found two boundary edges from different faces sharing a vertex")
	var res := PBMeshOps.bridge_edges(data, PackedInt32Array([eid_a, eid_b]))
	assert_true(res.get("ok", false), "Triangle bridge succeeds")
	var new_fid: int = res["new_face_ids"][0]
	assert_eq(data.faces[new_fid].get_distinct_indexes().size(), 3, "New face is a triangle")
	_assert_compiled_convention(data, "Bridge triangle")
func test_bridge_edges_rejections() -> void:
	var data := _cube()
	# Closed cube: all edges have 2 adjacent faces (not boundary)
	var res_closed := PBMeshOps.bridge_edges(data, PackedInt32Array([0, 1]))
	assert_false(res_closed.get("ok", false), "Closed cube edges rejected (requires boundary edges)")

	# Invalid count
	var res_1 := PBMeshOps.bridge_edges(data, PackedInt32Array([0]))
	assert_false(res_1.get("ok", false), "Single edge rejected")

	var res_3 := PBMeshOps.bridge_edges(data, PackedInt32Array([0, 1, 2]))
	assert_false(res_3.get("ok", false), "3 edges rejected")

# ==============================================================================
# Connect Edges Tests
# ==============================================================================

func test_connect_edges_quad_split() -> void:
	var data := _cube()
	# In top face (face 4), pick 2 opposite edges
	var top_face := data.faces[4]
	var edges := top_face.get_edges()
	assert_eq(edges.size(), 4, "Top face has 4 edges")

	var common := data.get_common_edges()
	var lookup := data.get_shared_vertex_lookup()
	var eid0 := -1
	var eid2 := -1
	var k0 := PBMeshOps._common_key(lookup, edges[0].a, edges[0].b)
	var k2 := PBMeshOps._common_key(lookup, edges[2].a, edges[2].b)
	for i in range(common.size()):
		var ck := PBMeshOps._common_key(lookup, common[i].a, common[i].b)
		if ck == k0:
			eid0 = i
		if ck == k2:
			eid2 = i

	assert_ne(eid0, -1, "Found common edge 0")
	assert_ne(eid2, -1, "Found common edge 2")

	var res := PBMeshOps.connect_edges(data, PackedInt32Array([eid0, eid2]))
	assert_true(res.get("ok", false), "Connect opposite edges succeeded")
	# Top face split into 2 quads: 6 - 1 + 2 = 7 faces (or more with neighbor conform)
	assert_true(data.faces.size() >= 7, "Face count increased after split")

	# Check all faces have valid normals and area
	for fi in range(data.faces.size()):
		var fn: Vector3 = PBMath.normal_from_positions(data.positions, data.faces[fi].get_indexes())
		assert_gt(fn.length_squared(), 0.1, "Face %d has valid normal" % fi)

	_assert_compiled_convention(data, "Connect edges quad split")

func test_connect_edges_multi_centroid() -> void:
	var data := _cube()
	var top_face := data.faces[4]
	var edges := top_face.get_edges()
	var common := data.get_common_edges()
	var lookup := data.get_shared_vertex_lookup()

	var all_eids := PackedInt32Array()
	for e in edges:
		var k := PBMeshOps._common_key(lookup, e.a, e.b)
		for i in range(common.size()):
			if PBMeshOps._common_key(lookup, common[i].a, common[i].b) == k:
				all_eids.append(i)
				break

	assert_eq(all_eids.size(), 4, "Collected all 4 edges of top face")
	var res := PBMeshOps.connect_edges(data, all_eids)
	assert_true(res.get("ok", false), "Multi-edge centroid connect succeeded")
	# Radiates around centroid
	assert_true(data.faces.size() >= 9, "Centroid split creates 4 sub-faces on top")
	_assert_compiled_convention(data, "Connect edges centroid")

# ==============================================================================
# Connect Vertices Tests
# ==============================================================================

func test_connect_vertices_diagonal() -> void:
	var data := _cube()
	# Top face (face 4) has 4 distinct vertices
	var loop := PBMeshOps._ordered_loop(data.faces[4])
	assert_eq(loop.size(), 4, "Top face has 4 ordered vertices")

	# Diagonal vertices: loop[0] and loop[2]
	var v0 := loop[0]
	var v2 := loop[2]

	var res := PBMeshOps.connect_vertices(data, PackedInt32Array([v0, v2]))
	assert_true(res.get("ok", false), "Connect diagonal vertices succeeded")
	assert_eq(data.faces.size(), 7, "Top quad split into 2 triangles (total 7 faces)")

	# Check both new triangles have outward normal +Y
	for fi in res["new_face_ids"]:
		var fn: Vector3 = PBMath.normal_from_positions(data.positions, data.faces[fi].get_indexes())
		assert_gt(fn.y, 0.8, "Subdivided triangle has +Y outward normal")

	_assert_watertight(data, "Connect vertices diagonal")
	_assert_compiled_convention(data, "Connect vertices diagonal")

func test_connect_vertices_adjacent_rejection() -> void:
	var data := _cube()
	var loop := PBMeshOps._ordered_loop(data.faces[4])
	# Adjacent vertices along perimeter: loop[0] and loop[1]
	var v0 := loop[0]
	var v1 := loop[1]

	var res := PBMeshOps.connect_vertices(data, PackedInt32Array([v0, v1]))
	assert_false(res.get("ok", false), "Adjacent vertices rejected (already connected by an edge)")
	assert_eq(data.faces.size(), 6, "Mesh unchanged on rejection")

# ==============================================================================
# Collapse Elements Tests
# ==============================================================================

func test_collapse_edge() -> void:
	var data := _cube()
	# Collapse common edge 0
	var res := PBMeshOps.collapse_elements(data, 2, PackedInt32Array([0]), false) # mode 2 = EDGE
	assert_true(res.get("ok", false), "Collapse edge succeeded")
	# The 2 faces sharing edge 0 become triangles; mesh remains manifold
	assert_gt(data.faces.size(), 0, "Surviving faces present")
	_assert_compiled_convention(data, "Collapse edge")

func test_collapse_vertices_to_centroid() -> void:
	var data := _cube()
	# Select 2 vertices of top face
	var loop := PBMeshOps._ordered_loop(data.faces[4])
	var p0 := data.positions[loop[0]]
	var p1 := data.positions[loop[1]]
	var expected_mid := (p0 + p1) * 0.5

	var res := PBMeshOps.collapse_elements(data, 1, PackedInt32Array([loop[0], loop[1]]), false) # mode 1 = VERTEX
	assert_true(res.get("ok", false), "Collapse vertices succeeded")
	var target_pos: Vector3 = res["target_position"]
	assert_lt(target_pos.distance_to(expected_mid), 0.001, "Collapsed to centroid midpoint")
	_assert_compiled_convention(data, "Collapse vertices to centroid")

func test_collapse_vertices_to_first() -> void:
	var data := _cube()
	var loop := PBMeshOps._ordered_loop(data.faces[4])
	var p0 := data.positions[loop[0]]

	var res := PBMeshOps.collapse_elements(data, 1, PackedInt32Array([loop[0], loop[1]]), true) # collapse_to_first = true
	assert_true(res.get("ok", false), "Collapse to first succeeded")
	var target_pos: Vector3 = res["target_position"]
	assert_lt(target_pos.distance_to(p0), 0.001, "Collapsed to first vertex position")

func test_collapse_face() -> void:
	var data := _cube()
	# Collapse top face (face 4)
	var res := PBMeshOps.collapse_elements(data, 3, PackedInt32Array([4]), false) # mode 3 = FACE
	assert_true(res.get("ok", false), "Collapse face succeeded")
	# Top face eliminated; 5 faces remain forming an apex pyramid
	assert_eq(data.faces.size(), 5, "5 faces remain after collapsing top face into apex")
	_assert_compiled_convention(data, "Collapse face")

# ==============================================================================
# Fill Hole Tests
# ==============================================================================

func test_fill_hole_cube() -> void:
	var data := _cube()
	# Delete top face (face 4)
	PBMeshOps.delete_faces(data, PackedInt32Array([4]))
	assert_eq(data.faces.size(), 5, "5 faces with open top hole")

	# Find boundary edges
	var usage := PBMeshOps.edge_usage_counts(data)
	var common := data.get_common_edges()
	var lookup := data.get_shared_vertex_lookup()
	var boundary_eids: Array[int] = []
	for i in range(common.size()):
		var ce := common[i]
		var k := PBMeshOps._common_key(lookup, ce.a, ce.b)
		if usage.get(k, 0) == 1:
			boundary_eids.append(i)

	assert_eq(boundary_eids.size(), 4, "4 boundary edges forming square hole")

	# Call fill_hole with one of the boundary edges
	var res := PBMeshOps.fill_hole(data, PackedInt32Array([boundary_eids[0]]))
	assert_true(res.get("ok", false), "Fill hole succeeded")
	assert_eq(data.faces.size(), 6, "Mesh now has 6 faces again")

	# Verify new cap face normal points outward (+Y)
	var new_fid: int = res["new_face_ids"][0]
	var cap_normal: Vector3 = PBMath.normal_from_positions(data.positions, data.faces[new_fid].get_indexes())
	assert_gt(cap_normal.y, 0.9, "Capped hole normal points outward (+Y)")

	# Verify watertightness: sealed cube has edge usage 2 everywhere!
	_assert_watertight(data, "Fill hole cube")
	_assert_compiled_convention(data, "Fill hole cube")

func test_fill_hole_all_holes() -> void:
	var data := _cube()
	# Delete top face (4) and bottom face (5)
	PBMeshOps.delete_faces(data, PackedInt32Array([4, 5]))
	assert_eq(data.faces.size(), 4, "4 wall faces remain (open top and bottom)")

	# Call fill_hole with empty edge_ids -> fills all holes on the mesh!
	var res := PBMeshOps.fill_hole(data)
	assert_true(res.get("ok", false), "Fill all holes succeeded")
	assert_eq(data.faces.size(), 6, "Both top and bottom holes capped, 6 faces total")
	_assert_watertight(data, "Fill all holes")
	_assert_compiled_convention(data, "Fill all holes")

func test_fill_hole_rejection_no_holes() -> void:
	var data := _cube()
	# Closed mesh has no holes
	var res := PBMeshOps.fill_hole(data)
	assert_false(res.get("ok", false), "Fill hole rejected on closed manifold mesh")

func test_bridge_edges_cube_deleted_face_image_1() -> void:
	var data := _cube()
	# Replicate Image #1: Front face (face 0, at Z = -0.5) is deleted
	PBMeshOps.delete_faces(data, PackedInt32Array([0]))
	assert_eq(data.faces.size(), 5, "5 faces remain after deleting front face")

	var lookup := data.get_shared_vertex_lookup()
	var common := data.get_common_edges()

	# Find the left boundary edge (on Face 2, at X = -0.5, Z = -0.5)
	# and the right boundary edge (on Face 3, at X = +0.5, Z = -0.5)
	var eid_left := -1
	var eid_right := -1
	for i in range(common.size()):
		var ce := common[i]
		var p0 := data.positions[ce.a]
		var p1 := data.positions[ce.b]
		if absf(p0.z - (-0.5)) < 0.01 and absf(p1.z - (-0.5)) < 0.01:
			if absf(p0.x - (-0.5)) < 0.01 and absf(p1.x - (-0.5)) < 0.01:
				eid_left = i
			elif absf(p0.x - 0.5) < 0.01 and absf(p1.x - 0.5) < 0.01:
				eid_right = i

	assert_ne(eid_left, -1, "Found left boundary edge")
	assert_ne(eid_right, -1, "Found right boundary edge")

	# Bridge the left and right boundary edges
	var res := PBMeshOps.bridge_edges(data, PackedInt32Array([eid_left, eid_right]))
	assert_true(res.get("ok", false), "Bridge edges succeeded across front opening")
	assert_eq(data.faces.size(), 6, "Mesh has 6 faces again")

	# The new bridge face MUST have normal pointing OUTWARD towards -Z (NOT inward towards +Z)!
	var new_fid: int = res["new_face_ids"][0]
	var fn: Vector3 = PBMath.normal_from_positions(data.positions, data.faces[new_fid].get_indexes())
	assert_lt(fn.z, -0.9, "Bridge face normal MUST point OUTWARD (-Z), not inward (+Z)")
	_assert_compiled_convention(data, "Image 1 bridge test")

func test_extrude_hole_edges_outward_normal() -> void:
	var data := _cube()
	# Cut a square hole into top face (face 4)
	var sq := PackedVector3Array([
		Vector3(-0.2, 0.5, -0.2),
		Vector3(0.2, 0.5, -0.2),
		Vector3(0.2, 0.5, 0.2),
		Vector3(-0.2, 0.5, 0.2),
	])
	var cut_res := PBMeshOps.cut_face(data, 4, sq, true)
	assert_true(cut_res.get("ok", false), "Cut face succeeded")

	# Find the inner cut face (the one with area 0.4x0.4 = 0.16)
	var inner_fid := -1
	for fi in range(data.faces.size()):
		var area: float = PBMath.polygon_area(data.positions, data.faces[fi].get_indexes())
		if absf(area - 0.16) < 0.02:
			inner_fid = fi
			break
	assert_ne(inner_fid, -1, "Found inner cut face")

	# Delete the inner cut face, leaving the outer face with a hole
	PBMeshOps.delete_faces(data, PackedInt32Array([inner_fid]))

	# Find boundary edges of the hole (usage count == 1, all at Y = 0.5, within X:[-0.2, 0.2], Z:[-0.2, 0.2])
	var usage := PBMeshOps.edge_usage_counts(data)
	var common := data.get_common_edges()
	var lookup := data.get_shared_vertex_lookup()
	var hole_eids := PackedInt32Array()
	for i in range(common.size()):
		var ce := common[i]
		var k := PBMeshOps._common_key(lookup, ce.a, ce.b)
		if usage.get(k, 0) == 1:
			var p0 := data.positions[ce.a]
			var p1 := data.positions[ce.b]
			if absf(p0.y - 0.5) < 0.01 and absf(p1.y - 0.5) < 0.01:
				if maxf(absf(p0.x), absf(p0.z)) <= 0.21 and maxf(absf(p1.x), absf(p1.z)) <= 0.21:
					hole_eids.append(i)

	assert_eq(hole_eids.size(), 4, "Found 4 boundary edges around the hole")

	# Extrude the hole edges DOWN into the cube (distance = -0.5)
	var ext_res := PBMeshOps.extrude_edges(data, hole_eids, -0.5)
	assert_true(ext_res.get("ok", false), "Extrude hole edges succeeded")

	# Verify that the extruded fin walls face INTO the hole (front-facing from inside the hole)!
	for nfid in ext_res["new_face_ids"]:
		var fn: Vector3 = PBMath.normal_from_positions(data.positions, data.faces[nfid].get_indexes())
		var c := Vector3.ZERO
		var idxs := data.faces[nfid].get_distinct_indexes()
		for idx in idxs:
			c += data.positions[idx]
		c /= float(maxi(1, idxs.size()))
		# Vector pointing from face center to hole center (X=0, Z=0)
		var to_hole_center := Vector3(-c.x, 0, -c.z).normalized()
		# Normal must point toward the hole center (into the cavity), not away from it!
		assert_gt(fn.dot(to_hole_center), 0.5, "Fin normal must face INTO the cavity/hole")
