## Tests for weld_vertices (v0.8.0): merge selected shared-vertex groups at
## their centroid. Vertex ids are shared-vertex GROUP indexes (the VERTEX-mode
## subgizmo ids), NOT raw position indexes.
extends GutTest

func _cube() -> PBMeshData:
	return PBMeshData.create_cube(1.0)

func _corner_groups(data: PBMeshData, point: Vector3) -> PackedInt32Array:
	# Group indexes whose representative position matches `point`.
	var result := PackedInt32Array()
	for gi in range(data.shared_vertices.size()):
		var sv: PBSharedVertex = data.shared_vertices[gi]
		if sv != null and not sv.indices.is_empty() \
				and data.positions[sv.indices[0]].distance_to(point) < 0.001:
			result.append(gi)
	return result

func test_weld_two_corners_snaps_to_centroid():
	var data := _cube()
	var top_front_left := _corner_groups(data, Vector3(-0.5, 0.5, -0.5))
	var top_front_right := _corner_groups(data, Vector3(0.5, 0.5, -0.5))
	assert_eq(top_front_left.size(), 1)
	assert_eq(top_front_right.size(), 1)

	var ids := PackedInt32Array([top_front_left[0], top_front_right[0]])
	var result := PBMeshOps.weld_vertices(data, ids)
	assert_true(result["ok"], "Weld succeeds: " + str(result.get("error", "")))
	assert_eq(data.shared_vertices.size(), 7, "8 corners - 2 + 1 merged = 7")
	assert_eq(data.faces.size(), 6, "Faces are untouched by welding")
	# The two corners' positions all moved to the centroid.
	var centroid := Vector3(0, 0.5, -0.5)
	for idx in data.positions.size():
		var p := data.positions[idx]
		if p.y > 0.49 and p.z < -0.49:  # former top-front corners
			assert_almost_eq(p.x, 0.0, 0.0001, "Both corners snapped to the centroid")
	assert_eq(data.validate(), "", "Welded mesh validates")

func test_weld_groups_positions_move_together_after_drag():
	var data := _cube()
	var a := _corner_groups(data, Vector3(-0.5, 0.5, -0.5))[0]
	var b := _corner_groups(data, Vector3(0.5, 0.5, -0.5))[0]
	PBMeshOps.weld_vertices(data, PackedInt32Array([a, b]))
	# The merged group must contain positions from BOTH former corners (6).
	var merged := PackedInt32Array()
	for sv in data.shared_vertices:
		if data.positions[sv.indices[0]].distance_to(Vector3(0, 0.5, -0.5)) < 0.001:
			merged = sv.indices
	assert_eq(merged.size(), 6, "Merged group holds both corners' face-private positions")

func test_weld_requires_two_or_more():
	var data := _cube()
	var one := _corner_groups(data, Vector3(-0.5, 0.5, -0.5))
	assert_false(PBMeshOps.weld_vertices(data, PackedInt32Array())["ok"], "Empty selection fails")
	assert_false(PBMeshOps.weld_vertices(data, one)["ok"], "Single vertex fails")
	assert_eq(data.shared_vertices.size(), 8, "Failed welds never mutate")

func test_weld_out_of_range_fails():
	var data := _cube()
	assert_false(PBMeshOps.weld_vertices(data, PackedInt32Array([0, 99]))["ok"])

func test_weld_all_top_corners_collapses_the_top_edge_loop():
	var data := _cube()
	var ids := PackedInt32Array()
	for p in [Vector3(-0.5, 0.5, -0.5), Vector3(0.5, 0.5, -0.5),
			Vector3(0.5, 0.5, 0.5), Vector3(-0.5, 0.5, 0.5)]:
		ids.append(_corner_groups(data, p)[0])
	var result := PBMeshOps.weld_vertices(data, ids)
	assert_true(result["ok"])
	assert_eq(data.shared_vertices.size(), 5, "8 - 4 + 1 top-center group")
	# The top face degenerates to a point fan — still a valid mesh structure.
	assert_eq(data.validate(), "", "Degenerate-but-structured mesh validates")
