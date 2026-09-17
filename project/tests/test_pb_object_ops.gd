extends GutTest

## Tests for PBObjectOps: merge, mirror, pivot, freeze transform, and probuilderize.

var cube_a: PBMesh
var cube_b: PBMesh

func before_each() -> void:
	cube_a = autofree(PBMesh.new())
	cube_a.pb_mesh_data = PBMeshData.create_cube(1.0)
	cube_a.rebuild()

	cube_b = autofree(PBMesh.new())
	cube_b.pb_mesh_data = PBMeshData.create_cube(1.0)
	cube_b.position = Vector3(3.0, 0.0, 0.0)
	cube_b.rebuild()

# ==============================================================================
# Merge Objects
# ==============================================================================

func test_merge_meshes() -> void:
	var success := PBObjectOps.merge_meshes(cube_a, [cube_b])
	assert_true(success, "Merge meshes should succeed")
	assert_eq(cube_a.pb_mesh_data.faces.size(), 12, "Merged cube should have 12 faces (6 + 6)")
	assert_eq(cube_a.pb_mesh_data.positions.size(), 48, "Merged cube should have 48 vertices (24 + 24)")

	# Check that donor positions were shifted by (3, 0, 0)
	var found_shifted := false
	for p in cube_a.pb_mesh_data.positions:
		if p.x > 2.0:
			found_shifted = true
			break
	assert_true(found_shifted, "Donor vertices should be offset by donor's relative transform")

# ==============================================================================
# Mirror Object
# ==============================================================================

func test_mirror_mesh_data() -> void:
	var md: PBMeshData = cube_a.pb_mesh_data
	var success := PBObjectOps.mirror_mesh_data(md, Vector3.AXIS_X)
	assert_true(success, "Mirror should succeed")

	# Check that every face still has an outward-facing normal
	for fi in range(md.faces.size()):
		var f: PBFace = md.faces[fi]
		var norm: Vector3 = PBMath.normal_from_positions(md.positions, f.get_indexes())
		var centroid: Vector3 = PBMath.average(md.positions, f.get_distinct_indexes())
		assert_gt(norm.dot(centroid), 0.0, "Face %d normal should point outward after mirror" % fi)

# ==============================================================================
# Pivot Tools
# ==============================================================================

func test_center_pivot() -> void:
	# Offset all positions by (5, 5, 5)
	var md: PBMeshData = cube_a.pb_mesh_data
	for i in range(md.positions.size()):
		md.positions[i] += Vector3(5.0, 5.0, 5.0)

	var success := PBObjectOps.center_pivot(cube_a)
	assert_true(success, "Center pivot should succeed")
	assert_almost_eq(cube_a.position.x, 5.0, 0.001, "Node position should be compensated by +5 on X")
	assert_almost_eq(cube_a.position.y, 5.0, 0.001, "Node position should be compensated by +5 on Y")
	assert_almost_eq(cube_a.position.z, 5.0, 0.001, "Node position should be compensated by +5 on Z")

	# Bounding box of vertices should now be centered at origin
	var avg := PBMath.average(md.positions)
	assert_almost_eq(avg.length(), 0.0, 0.001, "Vertex positions should now be centered at origin")

func test_freeze_transform() -> void:
	cube_a.transform.origin = Vector3(2.0, 3.0, 4.0)
	cube_a.transform.basis = Basis.from_scale(Vector3(2.0, 2.0, 2.0))

	var success := PBObjectOps.freeze_transform(cube_a)
	assert_true(success, "Freeze transform should succeed")
	assert_true(cube_a.transform.is_equal_approx(Transform3D.IDENTITY), "Transform should reset to identity")

	# Vertices of a unit cube scaled by 2 and translated by (2, 3, 4) should span [1, 3] on X
	var min_x := INF
	var max_x := -INF
	for p in cube_a.pb_mesh_data.positions:
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
	assert_almost_eq(min_x, 1.0, 0.001)
	assert_almost_eq(max_x, 3.0, 0.001)

# ==============================================================================
# Probuilderize
# ==============================================================================

func test_probuilderize_box_mesh() -> void:
	var mi: MeshInstance3D = autofree(MeshInstance3D.new())
	var box := BoxMesh.new()
	box.size = Vector3(1.0, 1.0, 1.0)
	mi.mesh = box

	var result: PBMesh = autofree(PBObjectOps.probuilderize(mi))
	assert_not_null(result, "Probuilderize should return PBMesh")
	assert_not_null(result.pb_mesh_data, "PBMesh should have valid pb_mesh_data")
	# BoxMesh has 12 triangles (2 per cube side)
	assert_eq(result.pb_mesh_data.faces.size(), 12, "BoxMesh should convert to 12 triangular faces")
	assert_eq(result.pb_mesh_data.positions.size(), 36, "12 triangles * 3 corners = 36 vertices (Position-Privacy)")

	# Verify winding: all faces must have outward normals
	var md: PBMeshData = result.pb_mesh_data
	for fi in range(md.faces.size()):
		var f: PBFace = md.faces[fi]
		var norm: Vector3 = PBMath.normal_from_positions(md.positions, f.get_indexes())
		var centroid: Vector3 = PBMath.average(md.positions, f.get_distinct_indexes())
		assert_gt(norm.dot(centroid), 0.0, "Face %d normal must point outward" % fi)

func test_poibuilderize_csg_box() -> void:
	var csg_box := CSGBox3D.new()
	csg_box.size = Vector3(2.0, 2.0, 2.0)
	get_tree().root.add_child(csg_box)
	var result: PBMesh = autofree(PBObjectOps.poibuilderize_csg(csg_box))
	get_tree().root.remove_child(csg_box)
	csg_box.free()

	assert_not_null(result, "Poibuilderize CSG should return PBMesh")
	assert_not_null(result.pb_mesh_data)
	assert_gt(result.pb_mesh_data.faces.size(), 0)
	assert_gt(result.pb_mesh_data.positions.size(), 0)

func test_poibuilderize_preserves_tangents() -> void:
	# Hand-built triangle with explicit tangents — the modern-asset case:
	# normal-mapped GLTF imports carry tangents that must survive conversion,
	# or the material's normal map breaks on the converted PBMesh.
	var verts := PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)])
	var indices := PackedInt32Array([0, 1, 2])
	var uvs := PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(0, 1)])
	var normals := PackedVector3Array([Vector3(0, 0, 1), Vector3(0, 0, 1), Vector3(0, 0, 1)])
	var tangents := PackedFloat32Array([1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = indices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TANGENT] = tangents
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mi := MeshInstance3D.new()
	mi.mesh = am
	var result: PBMesh = autofree(PBObjectOps.poibuilderize(mi))
	mi.free()

	assert_not_null(result, "Poibuilderize should return PBMesh")
	var md: PBMeshData = result.pb_mesh_data
	assert_eq(md.tangents.size(), md.positions.size() * 4,
			"Poibuilderize must preserve per-vertex tangents (4 floats per corner)")
	assert_almost_eq(float(md.tangents[3]), 1.0, 0.001, "Tangent values (incl. W handedness) must survive")
