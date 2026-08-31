## Test: PBMesh Node (MeshInstance3D Wrapper)
##
## Verifies PBMesh lifecycle, PBMeshData wrapping, ArrayMesh auto-compilation,
## scene tree integration, multi-surface handling, and convenience accessors.
extends GutTest

# ==============================================================================
# 1. Default State
# ==============================================================================

func test_default_state():
	var pb := PBMesh.new()
	autofree(pb)

	assert_null(pb.pb_mesh_data, "Default pb_mesh_data should be null")
	assert_null(pb.mesh, "Default mesh should be null")
	assert_false(pb._needs_rebuild, "Default _needs_rebuild should be false")
	assert_eq(pb.vertex_count(), 0, "Default vertex count should be 0")
	assert_eq(pb.face_count(), 0, "Default face count should be 0")
	assert_eq(pb.triangle_count(), 0, "Default triangle count should be 0")
	assert_eq(pb.index_count(), 0, "Default index count should be 0")
	assert_eq(pb.edge_count(), 0, "Default edge count should be 0")

# ==============================================================================
# 2. Set Mesh Data (Outside Scene Tree)
# ==============================================================================

func test_set_mesh_data_outside_tree():
	var pb := PBMesh.new()
	autofree(pb)

	var cube_data := PBMeshData.create_cube(1.0)
	pb.pb_mesh_data = cube_data

	assert_not_null(pb.pb_mesh_data, "pb_mesh_data should be set")
	assert_null(pb.mesh, "Mesh should NOT be compiled yet because node is not in scene tree")
	assert_true(pb._needs_rebuild, "_needs_rebuild should be true when set outside scene tree")

# ==============================================================================
# 3. Add to Tree & Rebuild
# ==============================================================================

func test_add_to_tree_and_rebuild():
	var pb := PBMesh.new()
	add_child_autofree(pb)

	var cube_data := PBMeshData.create_cube(1.0)
	pb.pb_mesh_data = cube_data
	pb.rebuild()

	assert_not_null(pb.mesh, "Mesh should not be null after rebuild in tree")
	assert_true(pb.mesh is ArrayMesh, "Mesh should be an instance of ArrayMesh")
	assert_false(pb._needs_rebuild, "_needs_rebuild should be false after rebuild")
	assert_eq(pb.mesh.get_surface_count(), 1, "Cube mesh should have 1 surface")

func test_ready_auto_rebuilds_when_added_to_tree():
	var pb := PBMesh.new()
	pb.pb_mesh_data = PBMeshData.create_cube(1.0)

	# When added to tree, _ready() is called automatically by Godot
	add_child_autofree(pb)

	assert_not_null(pb.mesh, "Mesh should be auto-compiled by _ready() when entering scene tree")
	assert_true(pb.mesh is ArrayMesh, "Mesh should be an ArrayMesh")
	assert_eq(pb.mesh.get_surface_count(), 1, "Should have 1 surface from cube")
	assert_false(pb._needs_rebuild, "_needs_rebuild should be false after ready rebuild")

# ==============================================================================
# 4. Cube via Factory Method
# ==============================================================================

func test_cube_via_factory():
	var pb := PBMesh.create_cube(2.0)
	assert_not_null(pb, "Factory should return a valid PBMesh instance")
	assert_not_null(pb.pb_mesh_data, "Factory should initialize pb_mesh_data")
	assert_eq(pb.vertex_count(), 24, "Cube PBMesh should have 24 vertices")
	assert_eq(pb.face_count(), 6, "Cube PBMesh should have 6 faces")

	add_child_autofree(pb)
	pb.rebuild()

	assert_not_null(pb.mesh, "Mesh should not be null after rebuild")
	assert_true(pb.mesh is ArrayMesh, "Mesh should be an ArrayMesh")
	assert_eq(pb.mesh.get_surface_count(), 1, "Cube should have exactly 1 surface")
	assert_eq(pb.mesh.surface_get_primitive_type(0), Mesh.PRIMITIVE_TRIANGLES, "Primitive type should be TRIANGLES")

# ==============================================================================
# 5. ArrayMesh Surface Count Matching Submesh Groups
# ==============================================================================

func test_array_mesh_surface_count_multi_submesh():
	var pb := PBMesh.create_cube(1.0)
	add_child_autofree(pb)

	# Assign faces to 3 distinct submeshes (0, 1, 2)
	pb.pb_mesh_data.faces[0].submesh_index = 0
	pb.pb_mesh_data.faces[1].submesh_index = 0
	pb.pb_mesh_data.faces[2].submesh_index = 1
	pb.pb_mesh_data.faces[3].submesh_index = 1
	pb.pb_mesh_data.faces[4].submesh_index = 2
	pb.pb_mesh_data.faces[5].submesh_index = 2

	pb.rebuild()

	assert_not_null(pb.mesh)
	assert_eq(pb.mesh.get_surface_count(), 3, "Mesh should have 3 surfaces matching the 3 submesh groups")

# ==============================================================================
# 6. Vertex Counts Match Between PBMeshData and Compiled ArrayMesh
# ==============================================================================

func test_vertex_counts_match():
	var pb := PBMesh.create_cube(1.0)
	add_child_autofree(pb)
	pb.rebuild()

	var array_mesh: ArrayMesh = pb.mesh as ArrayMesh
	assert_not_null(array_mesh)
	assert_eq(array_mesh.get_surface_count(), 1)

	var surface_arrays: Array = array_mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = surface_arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = surface_arrays[Mesh.ARRAY_INDEX]

	assert_eq(verts.size(), pb.pb_mesh_data.positions.size(), "Surface vertex count should equal PBMeshData positions count")
	assert_eq(verts.size(), 24, "Cube surface vertex count should be 24")
	assert_eq(indices.size(), 36, "Cube surface index count should be 36")

# ==============================================================================
# 7. Null Mesh Data
# ==============================================================================

func test_null_mesh_data():
	var pb := PBMesh.create_cube(1.0)
	add_child_autofree(pb)
	pb.rebuild()

	assert_not_null(pb.mesh, "Mesh should initially be compiled")

	# Set pb_mesh_data to null while inside tree
	pb.pb_mesh_data = null

	assert_null(pb.mesh, "Setting pb_mesh_data to null while in tree should clear mesh to null")
	assert_false(pb._needs_rebuild, "_needs_rebuild should be false after clearing to null")
	assert_eq(pb.vertex_count(), 0, "vertex_count() should return 0 when pb_mesh_data is null")
	assert_eq(pb.face_count(), 0, "face_count() should return 0 when pb_mesh_data is null")

func test_rebuild_with_null_mesh_data_outside_tree():
	var pb := PBMesh.new()
	autofree(pb)
	pb.rebuild()

	assert_null(pb.mesh, "Rebuild with null pb_mesh_data should leave mesh as null")
	assert_false(pb._needs_rebuild, "_needs_rebuild should be false")

# ==============================================================================
# 8. Replace Mesh Data
# ==============================================================================

func test_replace_mesh_data():
	var pb := PBMesh.create_cube(1.0)
	add_child_autofree(pb)
	pb.rebuild()

	assert_eq(pb.vertex_count(), 24, "Initial cube should have 24 vertices")
	assert_eq(pb.face_count(), 6, "Initial cube should have 6 faces")
	assert_eq(pb.mesh.get_surface_count(), 1, "Initial mesh should have 1 surface")

	# Create a custom triangle PBMeshData
	var tri_data := PBMeshData.new()
	tri_data.positions = PackedVector3Array([
		Vector3(0, 0, 0),
		Vector3(1, 0, 0),
		Vector3(0, 1, 0)
	])
	tri_data.faces = [
		PBFace.new(PackedInt32Array([0, 1, 2]))
	]

	# Replace pb_mesh_data while node is inside tree (setter should auto-rebuild)
	pb.pb_mesh_data = tri_data

	assert_eq(pb.vertex_count(), 3, "New vertex count should be 3")
	assert_eq(pb.face_count(), 1, "New face count should be 1")
	assert_not_null(pb.mesh, "Mesh should remain non-null")
	assert_eq(pb.mesh.get_surface_count(), 1, "Triangle mesh should have 1 surface")

	var arrays: Array = (pb.mesh as ArrayMesh).surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	assert_eq(verts.size(), 3, "ArrayMesh vertex count should be updated to 3")

# ==============================================================================
# 9. Convenience Accessors
# ==============================================================================

func test_convenience_accessors():
	var pb := PBMesh.create_cube(1.0)
	autofree(pb)

	assert_eq(pb.vertex_count(), 24, "Cube vertex_count() must be 24")
	assert_eq(pb.face_count(), 6, "Cube face_count() must be 6")
	assert_eq(pb.triangle_count(), 12, "Cube triangle_count() must be 12 (6 faces * 2 tris)")
	assert_eq(pb.index_count(), 36, "Cube index_count() must be 36 (6 faces * 6 indices)")
	assert_eq(pb.edge_count(), 24, "Cube edge_count() must be 24 (6 faces * 4 edges)")

func test_convenience_accessors_null_data():
	var pb := PBMesh.new()
	autofree(pb)

	assert_eq(pb.vertex_count(), 0, "Null data vertex_count() must be 0")
	assert_eq(pb.face_count(), 0, "Null data face_count() must be 0")
	assert_eq(pb.triangle_count(), 0, "Null data triangle_count() must be 0")
	assert_eq(pb.index_count(), 0, "Null data index_count() must be 0")
	assert_eq(pb.edge_count(), 0, "Null data edge_count() must be 0")
