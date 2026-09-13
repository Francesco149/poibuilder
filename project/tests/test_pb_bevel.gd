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

# ==============================================================================
# Unit Tests
# ==============================================================================

func test_bevel_single_edge_chamfer():
	var cube := _cube()
	# Bevel edge 0 with amount 0.2, 1 segment (chamfer)
	var res := PBMeshOps.bevel_edges(cube, PackedInt32Array([0]), 0.2, 1)
	assert_true(res.get("ok", false), "Beveling single edge should succeed")
	assert_eq(cube.faces.size(), 7, "Single edge bevel on cube adds 1 bridge face (6 -> 7 faces)")
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
	# 6 octagons + 12 * 2 quads + 8 corner caps = 38 faces
	assert_eq(cube.faces.size(), 38, "Beveled cube with 2 segments produces 38 faces")
	_assert_watertight(cube, "Beveled cube 2 segments")
	_assert_compiled_convention(cube, true, "Beveled cube 2 segments")

func test_bevel_multi_segment_three_and_four():
	var cube3 := _cube()
	var all_edges := PackedInt32Array()
	for i in range(cube3.get_common_edges().size()):
		all_edges.append(i)

	var res3 := PBMeshOps.bevel_edges(cube3, all_edges, 0.2, 3)
	assert_true(res3.get("ok", false), "Multi-segment bevel (seg=3) should succeed")
	assert_eq(cube3.faces.size(), 50, "Beveled cube with 3 segments produces 50 faces")
	_assert_watertight(cube3, "Beveled cube 3 segments")

	var cube4 := _cube()
	var res4 := PBMeshOps.bevel_edges(cube4, all_edges, 0.2, 4)
	assert_true(res4.get("ok", false), "Multi-segment bevel (seg=4) should succeed")
	assert_eq(cube4.faces.size(), 62, "Beveled cube with 4 segments produces 62 faces")
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
