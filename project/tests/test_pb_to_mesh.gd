## Test: PBMeshData ArrayMesh Compilation (ToMesh)
##
## Verifies to_array_mesh(), calculate_normals(), get_normals(),
## multi-surface mapping by submesh_index, and existing ArrayMesh reuse.
extends GutTest

# ==============================================================================
# 1. Cube Compilation & Basic Properties
# ==============================================================================

func test_cube_to_array_mesh():
	var cube := PBMeshData.create_cube(1.0)
	var mesh := cube.to_array_mesh()

	assert_not_null(mesh, "Compiled ArrayMesh should not be null")
	assert_true(mesh is ArrayMesh, "Result should be an instance of ArrayMesh")
	assert_eq(mesh.get_surface_count(), 1, "Default cube should have exactly 1 surface")
	assert_eq(mesh.surface_get_primitive_type(0), Mesh.PRIMITIVE_TRIANGLES, "Primitive type must be PRIMITIVE_TRIANGLES")

func test_cube_surface_counts_and_arrays():
	var cube := PBMeshData.create_cube(1.0)
	var mesh := cube.to_array_mesh()

	var arrays: Array = mesh.surface_get_arrays(0)
	assert_not_null(arrays, "Surface arrays should not be null")
	assert_eq(arrays.size(), Mesh.ARRAY_MAX, "Surface arrays size must be ARRAY_MAX")

	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

	assert_eq(verts.size(), 24, "Cube surface must have 24 vertex positions")
	assert_eq(normals.size(), 24, "Cube surface must have 24 normals")
	assert_eq(uvs.size(), 24, "Cube surface must have 24 UVs")
	assert_eq(indices.size(), 36, "Cube surface must have 36 triangle indices")

# ==============================================================================
# 2. Surface & Submesh Grouping
# ==============================================================================

func test_single_surface_all_faces_submesh_zero():
	var cube := PBMeshData.create_cube(1.0)
	for face in cube.faces:
		face.submesh_index = 0

	var mesh := cube.to_array_mesh()
	assert_eq(mesh.get_surface_count(), 1, "All faces at submesh 0 must create 1 surface")

func test_multi_surface_submesh_grouping():
	var cube := PBMeshData.create_cube(1.0)
	# Assign 2 faces each to submeshes 0, 1, 2
	cube.faces[0].submesh_index = 0
	cube.faces[1].submesh_index = 0
	cube.faces[2].submesh_index = 1
	cube.faces[3].submesh_index = 1
	cube.faces[4].submesh_index = 2
	cube.faces[5].submesh_index = 2

	var mesh := cube.to_array_mesh()
	assert_eq(mesh.get_surface_count(), 3, "Cube with 3 distinct submesh indices should create 3 surfaces")

	# Each submesh has 2 quad faces = 4 triangles = 12 indices
	for s_idx in range(3):
		var arrays: Array = mesh.surface_get_arrays(s_idx)
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		assert_eq(indices.size(), 12, "Surface %d should have 12 indices" % s_idx)
		assert_eq(verts.size(), 24, "Surface %d should share the 24 vertex array" % s_idx)

func test_multi_surface_non_contiguous_submesh_indices():
	var cube := PBMeshData.create_cube(1.0)
	# Assign submesh index 3 and 7 (non-contiguous, non-zero start)
	for i in range(3):
		cube.faces[i].submesh_index = 3
	for i in range(3, 6):
		cube.faces[i].submesh_index = 7

	var mesh := cube.to_array_mesh()
	assert_eq(mesh.get_surface_count(), 2, "Non-contiguous submeshes (3, 7) should produce 2 surfaces")

	var arr0: Array = mesh.surface_get_arrays(0)
	var arr1: Array = mesh.surface_get_arrays(1)
	assert_eq(arr0[Mesh.ARRAY_INDEX].size(), 18, "First surface (submesh 3) should have 18 indices (3 quads)")
	assert_eq(arr1[Mesh.ARRAY_INDEX].size(), 18, "Second surface (submesh 7) should have 18 indices (3 quads)")

# ==============================================================================
# 3. Normal Calculation
# ==============================================================================

func test_calculate_normals_cube_outward_directions():
	var cube := PBMeshData.create_cube(1.0)
	var normals: PackedVector3Array = cube.calculate_normals()

	assert_eq(normals.size(), 24, "Should calculate 24 normals for cube")

	# Face 0: Front face (Z = -0.5), vertices 0..3 -> outward normal (0, 0, -1)
	for v in range(0, 4):
		assert_almost_eq(normals[v].x, 0.0, 0.001, "Front face vertex %d normal.x should be 0" % v)
		assert_almost_eq(normals[v].y, 0.0, 0.001, "Front face vertex %d normal.y should be 0" % v)
		assert_almost_eq(normals[v].z, -1.0, 0.001, "Front face vertex %d normal.z should be -1" % v)

	# Face 1: Back face (Z = +0.5), vertices 4..7 -> outward normal (0, 0, 1)
	for v in range(4, 8):
		assert_almost_eq(normals[v].x, 0.0, 0.001, "Back face vertex %d normal.x should be 0" % v)
		assert_almost_eq(normals[v].y, 0.0, 0.001, "Back face vertex %d normal.y should be 0" % v)
		assert_almost_eq(normals[v].z, 1.0, 0.001, "Back face vertex %d normal.z should be 1" % v)

	# Face 2: Left face (X = -0.5), vertices 8..11 -> outward normal (-1, 0, 0)
	for v in range(8, 12):
		assert_almost_eq(normals[v].x, -1.0, 0.001, "Left face vertex %d normal.x should be -1" % v)
		assert_almost_eq(normals[v].y, 0.0, 0.001, "Left face vertex %d normal.y should be 0" % v)
		assert_almost_eq(normals[v].z, 0.0, 0.001, "Left face vertex %d normal.z should be 0" % v)

	# Face 3: Right face (X = +0.5), vertices 12..15 -> outward normal (1, 0, 0)
	for v in range(12, 16):
		assert_almost_eq(normals[v].x, 1.0, 0.001, "Right face vertex %d normal.x should be 1" % v)
		assert_almost_eq(normals[v].y, 0.0, 0.001, "Right face vertex %d normal.y should be 0" % v)
		assert_almost_eq(normals[v].z, 0.0, 0.001, "Right face vertex %d normal.z should be 0" % v)

	# Face 4: Top face (Y = +0.5), vertices 16..19 -> outward normal (0, 1, 0)
	for v in range(16, 20):
		assert_almost_eq(normals[v].x, 0.0, 0.001, "Top face vertex %d normal.x should be 0" % v)
		assert_almost_eq(normals[v].y, 1.0, 0.001, "Top face vertex %d normal.y should be 1" % v)
		assert_almost_eq(normals[v].z, 0.0, 0.001, "Top face vertex %d normal.z should be 0" % v)

	# Face 5: Bottom face (Y = -0.5), vertices 20..23 -> outward normal (0, -1, 0)
	for v in range(20, 24):
		assert_almost_eq(normals[v].x, 0.0, 0.001, "Bottom face vertex %d normal.x should be 0" % v)
		assert_almost_eq(normals[v].y, -1.0, 0.001, "Bottom face vertex %d normal.y should be -1" % v)
		assert_almost_eq(normals[v].z, 0.0, 0.001, "Bottom face vertex %d normal.z should be 0" % v)

func test_get_normals_caching_and_invalidation():
	var cube := PBMeshData.create_cube(1.0)
	var n1 := cube.get_normals()
	assert_eq(n1.size(), 24)

	# Same reference cached
	var n2 := cube.get_normals()
	assert_eq(n2.size(), 24)

	# Invalidate caches clears normals
	cube.invalidate_caches()
	var n3 := cube.get_normals()
	assert_eq(n3.size(), 24)

# ==============================================================================
# 4. Mesh Reuse
# ==============================================================================

func test_reuse_existing_mesh():
	var existing_mesh := ArrayMesh.new()

	# First compile a cube into existing_mesh (1 surface)
	var cube := PBMeshData.create_cube(1.0)
	var res1 := cube.to_array_mesh(existing_mesh)
	assert_same(res1, existing_mesh, "Should return the exact same ArrayMesh instance passed in")
	assert_eq(existing_mesh.get_surface_count(), 1, "Should have 1 surface from cube")

	# Now compile a multi-surface mesh into the SAME existing_mesh
	cube.faces[0].submesh_index = 0
	cube.faces[1].submesh_index = 1
	var res2 := cube.to_array_mesh(existing_mesh)
	assert_same(res2, existing_mesh, "Should return the same ArrayMesh instance on reuse")
	assert_eq(existing_mesh.get_surface_count(), 2, "Reused mesh should clear previous surfaces and have 2 surfaces")

# ==============================================================================
# 5. Edge Cases: Empty Mesh & Single Triangle
# ==============================================================================

func test_empty_mesh_to_array_mesh():
	var empty_data := PBMeshData.new()
	var mesh := empty_data.to_array_mesh()

	assert_not_null(mesh, "Should return non-null ArrayMesh even for empty PBMeshData")
	assert_eq(mesh.get_surface_count(), 0, "Empty mesh data should result in 0 surfaces")

func test_empty_faces_with_positions():
	var data := PBMeshData.new()
	data.positions = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	data.faces = []

	var mesh := data.to_array_mesh()
	assert_not_null(mesh)
	assert_eq(mesh.get_surface_count(), 0, "Mesh with positions but no faces should result in 0 surfaces")

func test_single_triangle():
	var data := PBMeshData.new()
	# Triangle with vertices in XY plane, indices [0,1,2].
	# Internal CCW winding: cross product (edge1×edge2) yields (0,0,+1).
	# to_array_mesh reverses the INDEX order (Godot CW front faces) but
	# normals keep the geometric outward direction — (0,0,+1).
	data.positions = PackedVector3Array([
		Vector3(0, 0, 0),
		Vector3(1, 0, 0),
		Vector3(0, 1, 0)
	])
	data.faces = [
		PBFace.new(PackedInt32Array([0, 1, 2]))
	]

	var mesh := data.to_array_mesh()
	assert_eq(mesh.get_surface_count(), 1, "Single triangle must produce 1 surface")

	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

	assert_eq(verts.size(), 3, "Surface vertex count should be 3")
	assert_eq(indices.size(), 3, "Surface index count should be 3")
	assert_eq(normals.size(), 3, "Surface normal count should be 3")

	# Normals keep the outward direction — they are NOT negated.
	# (Negating them was the Phase 6 normals bug: inward-facing shading.)
	for n in normals:
		assert_almost_eq(n.x, 0.0, 0.001)
		assert_almost_eq(n.y, 0.0, 0.001)
		assert_almost_eq(n.z, 1.0, 0.001, "Normal should keep the outward +Z direction")

	# The indices must be reversed for Godot's CW front faces
	assert_eq(indices[0], 2, "Reversed winding: output tri starts at internal index 2")
	assert_eq(indices[1], 1)
	assert_eq(indices[2], 0)

func test_single_triangle_reversed_winding():
	var data := PBMeshData.new()
	data.positions = PackedVector3Array([
		Vector3(0, 0, 0),
		Vector3(1, 0, 0),
		Vector3(0, 1, 0)
	])
	# Clockwise winding [0, 2, 1]
	data.faces = [
		PBFace.new(PackedInt32Array([0, 2, 1]))
	]

	var normals := data.calculate_normals()
	assert_eq(normals.size(), 3)
	for n in normals:
		assert_almost_eq(n.x, 0.0, 0.001)
		assert_almost_eq(n.y, 0.0, 0.001)
		assert_almost_eq(n.z, -1.0, 0.001, "Clockwise triangle normal should point towards -Z")

# ==============================================================================
# 6. Optional Attributes: Colors, UVs, Tangents
# ==============================================================================

func test_optional_attributes_compilation():
	var data := PBMeshData.new()
	data.positions = PackedVector3Array([
		Vector3(0, 0, 0),
		Vector3(1, 0, 0),
		Vector3(0, 1, 0)
	])
	data.textures0 = PackedVector2Array([
		Vector2(0, 0),
		Vector2(1, 0),
		Vector2(0, 1)
	])
	data.colors = PackedColorArray([
		Color.RED,
		Color.GREEN,
		Color.BLUE
	])
	data.tangents = PackedFloat32Array([
		1.0, 0.0, 0.0, 1.0,
		1.0, 0.0, 0.0, 1.0,
		1.0, 0.0, 0.0, 1.0
	])
	data.faces = [
		PBFace.new(PackedInt32Array([0, 1, 2]))
	]

	var mesh := data.to_array_mesh()
	assert_eq(mesh.get_surface_count(), 1)

	var arrays: Array = mesh.surface_get_arrays(0)
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var tangs: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]

	assert_not_null(uvs, "UV array should be present")
	assert_eq(uvs.size(), 3, "UV array should have 3 elements")
	assert_eq(uvs[1], Vector2(1, 0))

	assert_not_null(cols, "Colors array should be present")
	assert_eq(cols.size(), 3, "Colors array should have 3 elements")
	assert_eq(cols[0], Color.RED)

	assert_not_null(tangs, "Tangents array should be present")
	assert_eq(tangs.size(), 12, "Tangents array should have 12 float elements (3 verts * 4)")
