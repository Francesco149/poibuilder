## Tests for PBMeshOps (Phase 7 core mesh operations) + CmdMeshOp undo.
##
## Geometry conventions follow test_pb_winding.gd (G1): internal data is
## CCW-from-outside, and every compiled triangle must be CW-from-outside in
## the ArrayMesh with OUTWARD normals for closed convex results.
##
## Cube face indexes (PBMeshData.create_cube): 0 front(-Z), 1 back(+Z),
## 2 left(-X), 3 right(+X), 4 top(+Y), 5 bottom(-Y).
extends GutTest

# ==============================================================================
# Helpers
# ==============================================================================

func _cube() -> PBMeshData:
	return PBMeshData.create_cube(1.0)

func _face_normal(data: PBMeshData, fi: int) -> Vector3:
	return PBMath.normal_from_positions(data.positions, data.faces[fi].get_indexes())

func _face_centroid(data: PBMeshData, fi: int) -> Vector3:
	var acc := Vector3.ZERO
	var loop := data.faces[fi].get_distinct_indexes()
	for idx in loop:
		acc += data.positions[idx]
	return acc / float(loop.size())

func _assert_watertight(data: PBMeshData, context: String) -> void:
	var counts := PBMeshOps.edge_usage_counts(data)
	var bad: int = 0
	for key in counts:
		if counts[key] != 2:
			bad += 1
	assert_eq(bad, 0, context + ": every perimeter edge is used by exactly 2 faces")

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
	assert_eq(bad_culling, 0, context + ": all triangles CW-from-outside after conversion")
	if convex:
		assert_eq(bad_outward, 0, context + ": all normals point outward (convex result)")

# ==============================================================================
# Extrude faces
# ==============================================================================

func test_extrude_single_face_topology():
	var data := _cube()
	var result := PBMeshOps.extrude_faces(data, PackedInt32Array([4]), 0.25)
	assert_true(result["ok"], "Extrude succeeds: " + str(result.get("error", "")))
	assert_eq(data.faces.size(), 10, "6 - 1 original + 1 cap + 4 sides = 10 faces")
	assert_eq(result["cap_face_ids"].size(), 1, "One cap face")
	assert_eq(result["new_face_ids"].size(), 5, "Cap + 4 side faces are new")
	assert_eq(data.positions.size(), 40,
		"20 originals + 4 cap corners + 16 side corners (position privacy)")
	assert_eq(data.shared_vertices.size(), 12, "8 brim corners + 4 cap corners (welded)")
	_assert_watertight(data, "extruded cube")

func test_extrude_single_face_geometry():
	var data := _cube()
	var result := PBMeshOps.extrude_faces(data, PackedInt32Array([4]), 0.25)
	assert_true(result["ok"])
	var cap: int = result["cap_face_ids"][0]
	var cap_normal := _face_normal(data, cap)
	assert_gt(cap_normal.dot(Vector3.UP), 0.99, "Cap still faces +Y")
	var cap_center := _face_centroid(data, cap)
	assert_almost_eq(cap_center.y, 0.75, 0.0001, "Cap lifted to y = 0.5 + 0.25")
	# The shape is now a 1 x 1.25 x 1 box: AABB height must reflect the extrude.
	var aabb := AABB(data.positions[0], Vector3.ZERO)
	for p in data.positions:
		aabb = aabb.expand(p)
	assert_almost_eq(aabb.size.y, 1.25, 0.0001, "Mesh AABB grows upward by the distance")

func test_extrude_negative_distance_goes_inward():
	var data := _cube()
	var result := PBMeshOps.extrude_faces(data, PackedInt32Array([4]), -0.25)
	assert_true(result["ok"])
	var cap: int = result["cap_face_ids"][0]
	assert_almost_eq(_face_centroid(data, cap).y, 0.25, 0.0001, "Negative distance cuts into the mesh")

func test_extrude_opposite_faces_are_two_regions():
	var data := _cube()
	var result := PBMeshOps.extrude_faces(data, PackedInt32Array([4, 5]), 0.25)
	assert_true(result["ok"])
	assert_eq(data.faces.size(), 14, "Two independent regions: 6 - 2 + 2 caps + 8 sides")
	var aabb := AABB(data.positions[0], Vector3.ZERO)
	for p in data.positions:
		aabb = aabb.expand(p)
	assert_almost_eq(aabb.size.y, 1.5, 0.0001, "Top up 0.25 AND bottom down 0.25")
	_assert_watertight(data, "opposite extrudes")

func test_extrude_adjacent_faces_extrude_as_one_region():
	var data := _cube()
	# Top (4) + front (0) share a welded edge → one region, no internal wall.
	var result := PBMeshOps.extrude_faces(data, PackedInt32Array([4, 0]), 0.25)
	assert_true(result["ok"])
	assert_eq(data.faces.size(), 12, "One region: 6 - 2 + 2 caps + 6 sides = 12")
	assert_eq(result["cap_face_ids"].size(), 2, "Two caps, zero internal wall faces")
	_assert_watertight(data, "adjacent extrude")
	# Both caps move along the REGION normal (average of +Y and -Z), so the
	# top cap rises AND shifts -Z, and the front cap shifts -Z AND rises.
	for cap in result["cap_face_ids"]:
		var center := _face_centroid(data, cap)
		assert_true(absf(center.y) > 0.5 or absf(center.z) > 0.5,
			"Cap moved along the diagonal region normal (center=%s)" % center)

func test_extrude_preserves_welded_drag_groups():
	var data := _cube()
	var result := PBMeshOps.extrude_faces(data, PackedInt32Array([4]), 0.25)
	assert_true(result["ok"])
	# The four brim corners must each weld the original rim positions with the
	# cap copies' opposite numbers... precisely: dragging one brim corner group
	# must move BOTH the extrusion side's base corner AND the cube side corner.
	var lookup := data.get_shared_vertex_lookup()
	var top_center := Vector3(0, 0.75, 0)
	var cap: int = result["cap_face_ids"][0]
	var cap_loop := data.faces[cap].get_distinct_indexes()
	for idx in cap_loop:
		var group: PackedInt32Array = data.shared_vertices[lookup[idx]].indices
		assert_eq(group.size(), 3,
			"Cap corner welds itself + the two adjacent side quads' lifted corners")
	# A brim corner (e.g. the corner nearest (-0.5, 0.5, -0.5)) welds 3+ positions.
	var brim := Vector3(-0.5, 0.5, -0.5)
	var found_group := false
	for group in data.shared_vertices:
		for idx in group.indices:
			if data.positions[idx].distance_to(brim) < 0.001:
				assert_true(group.indices.size() >= 3, "Brim corner welds cube sides + extrusion sides")
				found_group = true
				break
		if found_group:
			break
	assert_true(found_group, "Found a brim corner")

func test_extrude_invalid_input_fails():
	var data := _cube()
	assert_false(PBMeshOps.extrude_faces(data, PackedInt32Array(), 0.5)["ok"], "No faces → fail")
	assert_false(PBMeshOps.extrude_faces(data, PackedInt32Array([99]), 0.5)["ok"], "Out of range → fail")
	assert_false(PBMeshOps.extrude_faces(data, PackedInt32Array([4]), 0.0)["ok"], "Zero distance → fail")
	assert_eq(data.faces.size(), 6, "Failed ops never mutate")

# ==============================================================================
# Extrude edges
# ==============================================================================

func test_extrude_edge_creates_fin():
	var data := _cube()
	var result := PBMeshOps.extrude_edges(data, PackedInt32Array([2]), 0.25)
	assert_true(result["ok"], "Edge extrude succeeds: " + str(result.get("error", "")))
	assert_eq(data.faces.size(), 7, "6 + 1 fin quad")
	assert_eq(result["new_face_ids"].size(), 1)
	var fin: int = result["new_face_ids"][0]
	var normal := _face_normal(data, fin)
	# Edge 2 is the top-front rim, directed +X along face 0's winding; the
	# extrude direction is the adjacent average (0,1,-1). The fin normal is
	# edge_dir x move_dir = (0,1,1).
	assert_gt(normal.dot(Vector3(0, 1, 1).normalized()), 0.99, "Fin normal is edge_dir x move_dir")
	assert_eq(data.shared_vertices.size(), 10, "8 corners + 2 lifted copies")
	# Fins are open: the 3 fin-only border edges are used once; the base rim
	# edge is now used by front + top + fin (3).
	var counts := PBMeshOps.edge_usage_counts(data)
	var open: int = 0
	var overfull: int = 0
	for key in counts:
		if counts[key] == 1:
			open += 1
		elif counts[key] > 2:
			overfull += 1
	assert_eq(open, 3, "The fin's own border is open")
	assert_eq(overfull, 1, "Only the extruded rim edge is non-manifold (3 users)")

func test_extrude_edge_invalid_input_fails():
	var data := _cube()
	assert_false(PBMeshOps.extrude_edges(data, PackedInt32Array(), 0.5)["ok"])
	assert_false(PBMeshOps.extrude_edges(data, PackedInt32Array([99]), 0.5)["ok"])

# ==============================================================================
# Inset faces
# ==============================================================================

func test_inset_face_topology_and_planarity():
	var data := _cube()
	var result := PBMeshOps.inset_faces(data, PackedInt32Array([4]), 0.25)
	assert_true(result["ok"], "Inset succeeds: " + str(result.get("error", "")))
	assert_eq(data.faces.size(), 10, "6 - 1 + 1 inner + 4 ring = 10")
	assert_eq(data.positions.size(), 40,
		"20 originals + 4 inner + 16 ring corners (position privacy)")
	assert_eq(data.shared_vertices.size(), 12, "8 brim + 4 inner corners (welded)")
	_assert_watertight(data, "inset")
	# Everything on the inset face stays in the y = +0.5 plane.
	for fi in result["new_face_ids"]:
		for idx in data.faces[fi].get_indexes():
			assert_almost_eq(data.positions[idx].y, 0.5, 0.0001, "Inset is planar (coplanar ring)")
		assert_gt(_face_normal(data, fi).dot(Vector3.UP), 0.99, "Ring/inner faces keep +Y")

func test_inset_extreme_amounts_clamp():
	var data := _cube()
	var result := PBMeshOps.inset_faces(data, PackedInt32Array([4]), 5.0)
	assert_true(result["ok"], "Overshoot clamps to 0.95")
	_assert_watertight(data, "clamped inset")
	assert_false(PBMeshOps.inset_faces(data, PackedInt32Array([99]), 0.25)["ok"])

# ==============================================================================
# Subdivide faces
# ==============================================================================

func test_subdivide_face_topology():
	var data := _cube()
	var result := PBMeshOps.subdivide_faces(data, PackedInt32Array([4]))
	assert_true(result["ok"], "Subdivide succeeds: " + str(result.get("error", "")))
	assert_eq(data.faces.size(), 9, "6 - 1 + 4 sub-quads")
	assert_eq(data.positions.size(), 29, "24 + 4 edge midpoints + 1 center")
	assert_eq(data.shared_vertices.size(), 13, "8 + 4 + 1")
	for fi in result["new_face_ids"]:
		assert_gt(_face_normal(data, fi).dot(Vector3.UP), 0.99, "Sub-quads stay +Y")
		var loop := data.faces[fi].get_distinct_indexes()
		assert_eq(loop.size(), 4, "Sub-faces are quads")

func test_subdivide_adjacent_faces_share_midpoints():
	var data := _cube()
	var result := PBMeshOps.subdivide_faces(data, PackedInt32Array([4, 0]))
	assert_true(result["ok"])
	assert_eq(data.faces.size(), 12, "6 - 2 + 8 sub-quads")
	# The shared top-front rim midpoint must weld both faces' copies: with 8
	# original corners plus 9 fresh midpoints/centers, at least one weld group
	# must hold positions from BOTH subdivided faces (>= 2 indices).
	var multi_groups: int = 0
	for group in data.shared_vertices:
		if group.indices.size() >= 2:
			multi_groups += 1
	assert_gt(multi_groups, 8, "Rim midpoints are welded across the two faces")

func test_subdivide_non_quad_fails():
	var data := _cube()
	data.faces.append(PBFace.new(PackedInt32Array([0, 1, 2])))  # degenerate tri face
	var result := PBMeshOps.subdivide_faces(data, PackedInt32Array([6]))
	assert_false(result["ok"], "Triangles are rejected (quads only in v1)")

# ==============================================================================
# Delete / Detach
# ==============================================================================

func test_delete_face_compacts_orphans():
	var data := _cube()
	var result := PBMeshOps.delete_faces(data, PackedInt32Array([4]))
	assert_true(result["ok"])
	assert_eq(data.faces.size(), 5)
	assert_eq(data.positions.size(), 20, "Top face's 4 private positions are compacted away")
	assert_eq(data.shared_vertices.size(), 8)
	assert_eq(data.validate(), "", "Remaining mesh validates")
	_assert_compiled_convention(data, true, "open cube")

func test_delete_all_faces_fails():
	var data := _cube()
	var result := PBMeshOps.delete_faces(data, PackedInt32Array([0, 1, 2, 3, 4, 5]))
	assert_false(result["ok"], "Deleting everything is rejected")

func test_detach_face_extracts_new_mesh():
	var data := _cube()
	var result := PBMeshOps.detach_faces(data, PackedInt32Array([4]))
	assert_true(result["ok"])
	var detached: PBMeshData = result["detached"]
	assert_eq(detached.faces.size(), 1)
	assert_eq(detached.positions.size(), 4)
	assert_eq(detached.shared_vertices.size(), 4)
	assert_eq(data.faces.size(), 5, "Source loses the detached face")
	assert_eq(data.positions.size(), 20, "Source compacts orphans")
	assert_eq(detached.validate(), "", "Detached mesh validates")
	assert_almost_eq(_face_normal(detached, 0).dot(Vector3.UP), 1.0, 0.0001,
		"Detached face keeps its orientation")

# ==============================================================================
# Selection helpers
# ==============================================================================

func test_common_edge_ids_maps_raw_edges():
	var data := _cube()
	var common := data.get_common_edges()
	var ids := PBMeshOps.common_edge_ids(data, [common[2], common[5]])
	assert_eq(ids.size(), 2)
	assert_has(ids, 2)
	assert_has(ids, 5)
	# A raw pair from a DIFFERENT face sharing the same welded corner pair maps
	# to the same common id: rebuild the raw edge from face 4's winding.
	var top_face := data.faces[4]
	var face_edges := top_face.get_edges()
	var raw_edge: PBEdge = face_edges[2]
	var ids_from_raw := PBMeshOps.common_edge_ids(data, [raw_edge])
	assert_eq(ids_from_raw.size(), 1, "Raw edge resolves through the weld lookup")

func test_edge_usage_counts_cube_is_manifold():
	var counts := PBMeshOps.edge_usage_counts(_cube())
	assert_eq(counts.size(), 12)
	var non_manifold: int = 0
	for key in counts:
		if counts[key] != 2:
			non_manifold += 1
	assert_eq(non_manifold, 0, "Every cube edge is shared by exactly 2 faces")

# ==============================================================================
# Winding conventions (G1) on op results
# ==============================================================================

func test_extrude_result_matches_boxmesh_convention():
	var data := _cube()
	assert_true(PBMeshOps.extrude_faces(data, PackedInt32Array([4]), 0.25)["ok"])
	_assert_compiled_convention(data, true, "extruded cube")

func test_inset_result_matches_convention():
	var data := _cube()
	assert_true(PBMeshOps.inset_faces(data, PackedInt32Array([4]), 0.25)["ok"])
	_assert_compiled_convention(data, true, "inset cube")

func test_subdivide_result_matches_convention():
	var data := _cube()
	assert_true(PBMeshOps.subdivide_faces(data, PackedInt32Array([4]))["ok"])
	_assert_compiled_convention(data, true, "subdivided cube")

# ==============================================================================
# Attribute preservation
# ==============================================================================

func test_duplicated_positions_carry_uv_attributes():
	var data := _cube()
	var result := PBMeshOps.extrude_faces(data, PackedInt32Array([4]), 0.25)
	assert_true(result["ok"])
	assert_eq(data.textures0.size(), data.positions.size(), "UVs duplicated with every new position")

func test_compact_remaps_uv_attributes():
	var data := _cube()
	assert_true(PBMeshOps.delete_faces(data, PackedInt32Array([4]))["ok"])
	assert_eq(data.textures0.size(), 20, "UV array compacted with positions")

# ==============================================================================
# CmdMeshOp undo/redo
# ==============================================================================

class FakeUndo extends RefCounted:
	var do_object: Object = null
	var do_method: String = ""
	var undo_object: Object = null
	var undo_method: String = ""
	var action_name: String = ""
	var committed: bool = false

	func create_action(name: String, _merge_mode: int = 0) -> void:
		action_name = name

	func add_do_method(object: Object, method: String) -> void:
		do_object = object
		do_method = method

	func add_undo_method(object: Object, method: String) -> void:
		undo_object = object
		undo_method = method

	func commit_action(_execute: bool = true) -> void:
		committed = true

func test_cmd_mesh_op_undo_redo_roundtrip():
	var data := _cube()
	var pristine := PBCommand.copy_mesh_data(data)

	var cmd := CmdMeshOp.new(data, "Extrude Faces")
	assert_eq(cmd.before.positions.size(), 24, "Before-snapshot taken at construction")
	assert_true(cmd.is_noop(), "Nothing captured yet → noop guard")

	var result := PBMeshOps.extrude_faces(data, PackedInt32Array([4]), 0.25)
	assert_true(result["ok"])
	cmd.capture_after()
	assert_false(cmd.is_noop(), "After-capture makes the command submittable")
	assert_eq(data.faces.size(), 10)

	cmd.undo_it()
	assert_eq(data.faces.size(), 6, "Undo restores the pristine topology")
	for i in range(pristine.positions.size()):
		assert_eq(pristine.positions[i], data.positions[i], "Undo restores positions")

	cmd.do_it()
	assert_eq(data.faces.size(), 10, "Redo re-applies the extrude")
	assert_eq(data.validate(), "", "Redo result validates")

func test_cmd_mesh_op_undo_manager_registration():
	var data := _cube()
	var cmd := CmdMeshOp.new(data, "Inset Faces")
	PBMeshOps.inset_faces(data, PackedInt32Array([4]), 0.25)
	cmd.capture_after()

	var fake := FakeUndo.new()
	cmd.add_to_undo_manager(fake)
	assert_eq(fake.action_name, "Inset Faces")
	assert_true(fake.committed)
	assert_eq(fake.do_object, cmd)
	assert_eq(fake.do_method, "do_it")
	assert_eq(fake.undo_method, "undo_it")
