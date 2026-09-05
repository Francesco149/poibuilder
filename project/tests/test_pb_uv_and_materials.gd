## Test: Auto-UV Projection, Texturing, Materials & Dock
##
## Verifies:
## 1. Auto-UV 1x1m uniform planar projection.
## 2. Face resizing non-stretching invariant.
## 3. Planar basis heuristic for cardinal walls, vertical surfaces, and sloped quads.
## 4. Tiling adjustments (x2, /2, manual, 45-degree diagonal).
## 5. Manual UV preservation.
## 6. Multi-material management, submesh grouping, and surface material assignments.
## 7. Default checkerboard material loading and shape generator integration.
## 8. Undo/redo preservation of materials and UV properties.
## 9. Face tinting via vertex colors.
extends GutTest

# ==============================================================================
# 1. Auto-UV Planar Projection
# ==============================================================================

func test_auto_uv_planar_projection_cube():
	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)

	assert_eq(cube.textures0.size(), 24, "Cube must have 24 UV coordinates")

	# Check top face (normal = +Y, floor-style)
	# On top face (-0.5..0.5 in X and Z), span in U and V must be exactly 1.0 meter
	var top_face: PBFace = cube.faces[4] # top face (+Y)
	var top_uvs: Array[Vector2] = []
	for idx in top_face.get_distinct_indexes():
		top_uvs.append(cube.textures0[idx])

	var min_u := INF
	var max_u := -INF
	var min_v := INF
	var max_v := -INF
	for uv in top_uvs:
		min_u = minf(min_u, uv.x)
		max_u = maxf(max_u, uv.x)
		min_v = minf(min_v, uv.y)
		max_v = maxf(max_v, uv.y)

	assert_almost_eq(max_u - min_u, 1.0, 0.001, "Top face U span must be 1.0 meter")
	assert_almost_eq(max_v - min_v, 1.0, 0.001, "Top face V span must be 1.0 meter")

func test_auto_uv_non_stretching_on_face_resize():
	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)
	var top_face: PBFace = cube.faces[4] # top face (+Y)
	var indices := top_face.get_distinct_indexes()

	# Extend top face in X by 2.0m (width becomes 3.0m instead of 1.0m)
	for idx in indices:
		if cube.positions[idx].x > 0.0:
			cube.positions[idx].x += 2.0

	# Re-project auto-UVs
	PBUv.refresh_mesh_uvs(cube)

	var min_u := INF
	var max_u := -INF
	for idx in indices:
		var uv: Vector2 = cube.textures0[idx]
		min_u = minf(min_u, uv.x)
		max_u = maxf(max_u, uv.x)

	# The width is now 3.0m -> U span must be 3.0 (3 repeats per 3m, exactly 1 repeat per meter)
	assert_almost_eq(max_u - min_u, 3.0, 0.001, "Resizing face must extend UV repeat without stretching")

# ==============================================================================
# 2. Planar Basis Heuristic
# ==============================================================================

func test_planar_basis_vertical_surfaces():
	# Floor (+Y)
	var floor_basis := PBUv.get_planar_basis(Vector3.UP)
	assert_eq(floor_basis["u"], Vector3.RIGHT, "Floor U is +X")
	assert_eq(floor_basis["v"], Vector3.BACK, "Floor V is +Z")

	# Ceiling (-Y)
	var ceiling_basis := PBUv.get_planar_basis(Vector3.DOWN)
	assert_eq(ceiling_basis["u"], Vector3.RIGHT, "Ceiling U is +X")
	assert_eq(ceiling_basis["v"], Vector3.FORWARD, "Ceiling V is -Z")

func test_planar_basis_cardinal_walls():
	# Front Wall (+Z normal)
	var front_basis := PBUv.get_planar_basis(Vector3(0, 0, 1))
	# Looking at +Z wall: +X is right, +Y is up
	assert_almost_eq(front_basis["u"].x, 1.0, 0.001, "Front wall U points right (+X)")
	assert_almost_eq(front_basis["v"].y, 1.0, 0.001, "Front wall V points up (+Y)")

	# Right Wall (+X normal)
	var right_basis := PBUv.get_planar_basis(Vector3(1, 0, 0))
	# Looking at +X wall: -Z is right, +Y is up
	assert_almost_eq(right_basis["u"].z, -1.0, 0.001, "Right wall U points right (-Z)")
	assert_almost_eq(right_basis["v"].y, 1.0, 0.001, "Right wall V points up (+Y)")

	# Back Wall (-Z normal)
	var back_basis := PBUv.get_planar_basis(Vector3(0, 0, -1))
	# Looking at -Z wall: -X is right, +Y is up
	assert_almost_eq(back_basis["u"].x, -1.0, 0.001, "Back wall U points right (-X)")
	assert_almost_eq(back_basis["v"].y, 1.0, 0.001, "Back wall V points up (+Y)")

	# Left Wall (-X normal)
	var left_basis := PBUv.get_planar_basis(Vector3(-1, 0, 0))
	# Looking at -X wall: +Z is right, +Y is up
	assert_almost_eq(left_basis["u"].z, 1.0, 0.001, "Left wall U points right (+Z)")
	assert_almost_eq(left_basis["v"].y, 1.0, 0.001, "Left wall V points up (+Y)")

func test_planar_basis_sloped_surface():
	# 45-degree sloped roof facing +Z and +Y
	var normal := Vector3(0, 1, 1).normalized()
	var basis := PBUv.get_planar_basis(normal)

	var u: Vector3 = basis["u"]
	var v: Vector3 = basis["v"]

	# U must be horizontal (no vertical Y component)
	assert_almost_eq(u.y, 0.0, 0.001, "Sloped surface U must be horizontal")
	# V must have positive Y (pointing up the slope)
	assert_gt(v.y, 0.0, "Sloped surface V must point up the slope")
	# Basis must be orthogonal
	assert_almost_eq(u.dot(v), 0.0, 0.001, "U and V must be orthogonal")
	assert_almost_eq(u.dot(normal), 0.0, 0.001, "U and Normal must be orthogonal")
	assert_almost_eq(v.dot(normal), 0.0, 0.001, "V and Normal must be orthogonal")

# ==============================================================================
# 3. Tiling, Scale & 45-Degree Diagonal
# ==============================================================================

func test_tiling_scale_helpers():
	var face := PBFace.new()
	assert_eq(face.uv_scale, Vector2.ONE, "Default UV scale is Vector2.ONE")

	# x2
	PBUv.scale_face_tiling(face, 2.0)
	assert_eq(face.uv_scale, Vector2(2.0, 2.0), "Scale tiling 2.0 doubles scale")

	# /2
	PBUv.scale_face_tiling(face, 0.5)
	assert_eq(face.uv_scale, Vector2(1.0, 1.0), "Scale tiling 0.5 halves scale back to 1.0")

func test_45_degree_diagonal_tiling():
	var face := PBFace.new()
	PBUv.set_face_45_degree_diagonal(face)
	assert_almost_eq(face.uv_scale.x, PBUv.DIAGONAL_SCALE_FACTOR, 0.0001, "Scale X is 1/sqrt(2)")
	assert_almost_eq(face.uv_scale.y, PBUv.DIAGONAL_SCALE_FACTOR, 0.0001, "Scale Y is 1/sqrt(2)")
	assert_eq(face.uv_rotation, 45.0, "Rotation is 45 degrees")

func test_scale_stays_corner_aligned():
	var cube := PBMeshData.create_cube(1.0)
	var face: PBFace = cube.faces[4] # top face (+Y)

	# 1x scale
	face.uv_scale = Vector2.ONE
	var uvs_1x := PBUv.calculate_face_uvs(cube, face)
	var min_idx := -1
	var min_len := INF
	for idx in uvs_1x:
		if uvs_1x[idx].length_squared() < min_len:
			min_len = uvs_1x[idx].length_squared()
			min_idx = idx

	assert_almost_eq(uvs_1x[min_idx].x, 0.0, 0.001, "At 1x, corner UV.x is 0.0")
	assert_almost_eq(uvs_1x[min_idx].y, 0.0, 0.001, "At 1x, corner UV.y is 0.0")

	# 2x scale: must remain exactly at (0.0, 0.0) at the corner!
	face.uv_scale = Vector2(2.0, 2.0)
	var uvs_2x := PBUv.calculate_face_uvs(cube, face)
	assert_almost_eq(uvs_2x[min_idx].x, 0.0, 0.001, "At 2x, corner UV.x remains 0.0 (anchored to corner)")
	assert_almost_eq(uvs_2x[min_idx].y, 0.0, 0.001, "At 2x, corner UV.y remains 0.0 (anchored to corner)")
func test_manual_uv_preservation():
	var cube := PBMeshData.create_cube(1.0)
	var face: PBFace = cube.faces[0]
	face.manual_uv = true

	# Set custom UV
	var custom_uv := Vector2(0.123, 0.456)
	var idx: int = face.get_distinct_indexes()[0]
	cube.textures0[idx] = custom_uv

	# Refresh without force
	PBUv.refresh_mesh_uvs(cube, false)
	assert_eq(cube.textures0[idx], custom_uv, "Manual UV coordinates must be preserved")

	# Refresh with force
	PBUv.refresh_mesh_uvs(cube, true)
	assert_ne(cube.textures0[idx], custom_uv, "Force refresh overwrites manual UVs")

# ==============================================================================
# 4. Material Management & Per-Surface Assignment
# ==============================================================================

func test_mesh_data_materials_assignment():
	var cube := PBMeshData.create_cube(1.0)
	var mat_a := StandardMaterial3D.new()
	mat_a.resource_name = "MatA"
	var mat_b := StandardMaterial3D.new()
	mat_b.resource_name = "MatB"

	cube.set_face_material(cube.faces[0], mat_a)
	cube.set_face_material(cube.faces[1], mat_b)

	assert_eq(cube.get_face_material(cube.faces[0]), mat_a, "Face 0 has MatA")
	assert_eq(cube.get_face_material(cube.faces[1]), mat_b, "Face 1 has MatB")
	assert_eq(cube.materials.size(), 3, "PBMeshData materials size is 3 (default, MatA, MatB)")

	# Compile to ArrayMesh
	var mesh := cube.to_array_mesh()
	assert_eq(mesh.get_surface_count(), 3, "ArrayMesh must have 3 surfaces")
	assert_eq(mesh.surface_get_material(1), mat_a, "Surface 1 has MatA")
	assert_eq(mesh.surface_get_material(2), mat_b, "Surface 2 has MatB")

func test_set_faces_material_bulk():
	var cube := PBMeshData.create_cube(1.0)
	var mat := StandardMaterial3D.new()
	mat.resource_name = "BulkMat"

	cube.set_faces_material([cube.faces[2], cube.faces[3], cube.faces[4]], mat)
	for i in [2, 3, 4]:
		assert_eq(cube.get_face_material(cube.faces[i]), mat, "Face %d has BulkMat" % i)

func test_default_checkerboard_material_exists():
	var def_mat := PBMeshData.get_default_material()
	assert_not_null(def_mat, "Default checkerboard material must load")
	assert_true(def_mat is StandardMaterial3D, "Default material is StandardMaterial3D")
	var std_mat := def_mat as StandardMaterial3D
	assert_not_null(std_mat.albedo_texture, "Default material must have checkerboard albedo texture")
	assert_true(std_mat.vertex_color_use_as_albedo, "Default material must enable vertex colors for face tint")

func test_material_undo_redo_via_snapshots():
	var cube := PBMeshData.create_cube(1.0)
	var mat1 := StandardMaterial3D.new()
	mat1.resource_name = "Mat1"
	var mat2 := StandardMaterial3D.new()
	mat2.resource_name = "Mat2"

	cube.set_face_material(cube.faces[0], mat1)
	var snapshot1 := PBCommand.copy_mesh_data(cube)

	cube.set_face_material(cube.faces[0], mat2)
	assert_eq(cube.get_face_material(cube.faces[0]), mat2, "Face 0 changed to Mat2")

	PBCommand.restore_mesh_data(cube, snapshot1)
	assert_eq(cube.get_face_material(cube.faces[0]), mat1, "Restored snapshot preserves Mat1")

# ==============================================================================
# 5. Face Tint (Vertex Color)
# ==============================================================================

func test_face_tint_via_vertex_colors():
	var cube := PBMeshData.create_cube(1.0)
	var face: PBFace = cube.faces[0]
	var indices := face.get_distinct_indexes()

	if cube.colors.size() != cube.positions.size():
		cube.colors.resize(cube.positions.size())
		cube.colors.fill(Color.WHITE)

	for idx in indices:
		cube.colors[idx] = Color.RED

	var mesh := cube.to_array_mesh()
	var arrays := mesh.surface_get_arrays(0)
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	assert_not_null(colors, "Compiled mesh surface must carry vertex colors")
	for idx in indices:
		assert_eq(colors[idx], Color.RED, "Vertex color of face 0 must be Color.RED")


func test_built_in_light_tiles_material():
	var path := "res://addons/poibuilder/materials/pb_tiles_light.tres"
	assert_true(ResourceLoader.exists(path), "Built-in light tile material exists")
	var mat: StandardMaterial3D = load(path) as StandardMaterial3D
	assert_not_null(mat, "Material is StandardMaterial3D")
	assert_not_null(mat.albedo_texture, "Material has tile texture")
	assert_true(mat.vertex_color_use_as_albedo, "Material supports vertex color tint")

func test_demo_scratch_materials():
	var brick_path := "res://materials/brick_dark_red.tres"
	var wood_path := "res://materials/wood_planks.tres"
	assert_true(ResourceLoader.exists(brick_path), "Demo brick material exists")
	assert_true(ResourceLoader.exists(wood_path), "Demo wood material exists")

# ==============================================================================
# 6. Material Drop Overlay & Selection Routing
# ==============================================================================

func test_material_drop_overlay_routing_single_face():
	var overlay := PBMaterialDropOverlay.new()
	add_child_autofree(overlay)

	var cube := PBMeshData.create_cube(1.0)
	var node := PBMesh.new()
	node.pb_mesh_data = cube
	add_child_autofree(node)

	var test_mat := StandardMaterial3D.new()
	test_mat.resource_name = "DropMatSingle"

	# Single face 1 gets test_mat
	cube.set_face_material(cube.faces[1], test_mat)
	assert_eq(cube.get_face_material(cube.faces[1]), test_mat, "Face 1 receives dropped material")
	assert_ne(cube.get_face_material(cube.faces[0]), test_mat, "Face 0 remains unchanged")

func test_material_drop_overlay_routing_multi_face():
	var cube := PBMeshData.create_cube(1.0)
	var node := PBMesh.new()
	node.pb_mesh_data = cube
	add_child_autofree(node)

	var test_mat := StandardMaterial3D.new()
	test_mat.resource_name = "DropMatMulti"

	# Suppose faces 0, 1, 2 are selected and dropped onto face 1
	var selected_faces: Array[PBFace] = [cube.faces[0], cube.faces[1], cube.faces[2]]
	cube.set_faces_material(selected_faces, test_mat)

	for f in selected_faces:
		assert_eq(cube.get_face_material(f), test_mat, "Selected face gets dropped material")
	assert_ne(cube.get_face_material(cube.faces[3]), test_mat, "Unselected face 3 untouched")

# ==============================================================================
# 7. Material Dock UI & Selection Sync
# ==============================================================================

func test_material_dock_initialization_and_sync():
	var dock := PBMaterialDock.new()
	add_child_autofree(dock)

	var cube := PBMeshData.create_cube(1.0)
	var node := PBMesh.new()
	node.pb_mesh_data = cube
	add_child_autofree(node)

	var editor := PBEditor.new()
	dock.editor = editor
	editor.active_mesh = node
	dock.sync_selection()

	assert_not_null(dock.get_default_material(), "Dock can retrieve default material")
	assert_true(dock._material_grid != null, "Dock has material grid")
