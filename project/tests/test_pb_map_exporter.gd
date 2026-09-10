## Unit tests for PBMapExporter
extends GutTest

func test_export_tree_retro_mode() -> void:
	var root := Node3D.new()
	autofree(root)

	# Light
	var light := DirectionalLight3D.new()
	light.name = "Sun"
	light.transform = Transform3D(Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), Vector3(0, 10, 0))
	root.add_child(light)

	# PBMesh cube
	var cube := PBMesh.create_cube(2.0)
	cube.name = "Floor"
	cube.collider_type = PBMesh.ColliderType.ACCURATE
	root.add_child(cube)

	# Billboard sprite
	var sprite := MeshInstance3D.new()
	sprite.name = "SpriteTree"
	sprite.set_meta("is_billboard", true)
	sprite.set_meta("is_lit", true)
	var quad_mesh := QuadMesh.new()
	sprite.mesh = quad_mesh
	root.add_child(sprite)

	var settings := PBMapExporter.ExportSettings.new()
	settings.export_mode = PBMapExporter.ExportMode.RETRO
	settings.subdivide_quads = true
	settings.bake_lighting = true
	settings.bake_textures = true
	settings.export_colliders = true
	settings.export_billboards = true

	var export_tree := PBMapExporter.build_export_tree(root, settings)
	assert_not_null(export_tree)
	autofree(export_tree)

	# Check children of export_tree
	var floor_node := export_tree.get_node_or_null("Floor") as MeshInstance3D
	assert_not_null(floor_node, "Exported tree must have 'Floor' MeshInstance3D")
	assert_not_null(floor_node.mesh, "Floor must have an ArrayMesh")
	assert_gt(floor_node.mesh.get_surface_count(), 0, "Floor must have surfaces")

	# Verify vertex colors exist on the floor mesh
	var arrays := floor_node.mesh.surface_get_arrays(0)
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	assert_gt(colors.size(), 0, "Floor mesh surface must contain baked vertex colors")

	# Check collider node
	var col_node := export_tree.get_node_or_null("Collider_Floor") as MeshInstance3D
	assert_not_null(col_node, "Exported tree must contain 'Collider_Floor'")

	# Check billboard node
	var bb_node := export_tree.get_node_or_null("SpriteTree") as MeshInstance3D
	assert_not_null(bb_node, "Exported tree must contain 'SpriteTree'")
	var bb_arrays := bb_node.mesh.surface_get_arrays(0)
	var bb_colors: PackedColorArray = bb_arrays[Mesh.ARRAY_COLOR]
	assert_gt(bb_colors.size(), 0, "Lit billboard must have vertex colors")

func test_export_tree_modern_mode() -> void:
	var root := Node3D.new()
	autofree(root)

	var cube := PBMesh.create_cube(2.0)
	cube.name = "ModernCube"
	cube.collider_type = PBMesh.ColliderType.ACCURATE
	root.add_child(cube)

	# Add stamp child
	var stamps := Node3D.new()
	stamps.name = "PBStamps"
	cube.add_child(stamps)
	var stamp := MeshInstance3D.new()
	stamp.name = "Stamp_0"
	stamp.set_meta("face_idx", 0)
	stamp.set_meta("stamp_texture_path", "res://addons/poibuilder/materials/textures/flower_patch.png")
	stamp.set_meta("anchor_center", Vector2(0, 0))
	stamp.set_meta("anchor_du", Vector2(0.1, 0.0))
	stamp.set_meta("anchor_dv", Vector2(0.0, 0.1))
	stamps.add_child(stamp)
	var settings := PBMapExporter.ExportSettings.new()
	settings.export_mode = PBMapExporter.ExportMode.MODERN
	settings.bake_lighting = false
	settings.export_colliders = true

	var export_tree := PBMapExporter.build_export_tree(root, settings)
	assert_not_null(export_tree)
	autofree(export_tree)

	var cube_node := export_tree.get_node_or_null("ModernCube") as MeshInstance3D
	assert_not_null(cube_node)
	assert_true(cube_node.has_meta("poi_stamps"), "Modern export should attach poi_stamps metadata")

	var stamps_node := cube_node.get_node_or_null("PBStamps")
	assert_not_null(stamps_node, "Modern export should preserve PBStamps container")
	assert_not_null(stamps_node.get_node_or_null("Stamp_0"), "Modern export should preserve decal quads")

func test_export_map_to_glb_file() -> void:
	var root := Node3D.new()
	autofree(root)

	var cube := PBMesh.create_cube(2.0)
	cube.name = "TestCube"
	root.add_child(cube)

	var out_path := "user://test_map_export.glb"
	if FileAccess.file_exists(out_path):
		DirAccess.remove_absolute(out_path)

	var settings := PBMapExporter.ExportSettings.new()
	settings.export_mode = PBMapExporter.ExportMode.RETRO
	settings.subdivide_quads = true
	settings.bake_lighting = false

	var err := PBMapExporter.export_map(root, out_path, settings)
	assert_eq(err, OK, "export_map should return OK")
	assert_true(FileAccess.file_exists(out_path), "Exported GLB file must exist on disk")

	var fa := FileAccess.open(out_path, FileAccess.READ)
	assert_not_null(fa)
	assert_gt(fa.get_length(), 100, "GLB file must contain valid non-empty data")
	fa.close()

	# Clean up test file
	DirAccess.remove_absolute(out_path)

func test_ensure_export_dir_creates_gdignore() -> void:
	var test_dir := "res://test_export_temp"
	var test_path := test_dir.path_join("map.glb")
	PBMapExporter.ensure_export_dir(test_path)
	assert_true(DirAccess.dir_exists_absolute(test_dir), "Export dir must be created")
	assert_true(FileAccess.file_exists(test_dir.path_join(".gdignore")), ".gdignore must exist to prevent auto-import")
	# Cleanup
	DirAccess.remove_absolute(test_dir.path_join(".gdignore"))
	DirAccess.remove_absolute(test_dir)

func test_cleanup_intermediate_files() -> void:
	var test_dir := "user://test_cleanup_dir"
	DirAccess.make_dir_recursive_absolute(test_dir)
	var glb_path := test_dir.path_join("test_map.glb")
	var f := FileAccess.open(glb_path, FileAccess.WRITE)
	f.store_string("glb data")
	f.close()

	var loose_tex := test_dir.path_join("test_map_BakedTile_0_0_0_albedo.png")
	f = FileAccess.open(loose_tex, FileAccess.WRITE)
	f.store_string("png data")
	f.close()

	var loose_import := test_dir.path_join("test_map_BakedTile_0_0_0_albedo.png.import")
	f = FileAccess.open(loose_import, FileAccess.WRITE)
	f.store_string("import data")
	f.close()

	var unrelated := test_dir.path_join("unrelated_texture.png")
	f = FileAccess.open(unrelated, FileAccess.WRITE)
	f.store_string("keep me")
	f.close()

	var cleaned := PBMapExporter.cleanup_intermediate_files(glb_path)
	assert_eq(cleaned, 2, "Must clean 2 intermediate files")
	assert_false(FileAccess.file_exists(loose_tex), "Loose extracted texture must be removed")
	assert_false(FileAccess.file_exists(loose_import), "Loose texture .import must be removed")
	assert_true(FileAccess.file_exists(glb_path), "GLB file itself must be kept")
	assert_true(FileAccess.file_exists(unrelated), "Unrelated file must be kept")

	# Cleanup
	DirAccess.remove_absolute(glb_path)
	DirAccess.remove_absolute(unrelated)
	DirAccess.remove_absolute(test_dir)

func test_export_retro_pbm_format() -> void:
	var root := Node3D.new()
	var pb := PBMesh.new()
	pb.name = "TestCube"
	pb.pb_mesh_data = PBShapeGenerators.create_box(Vector3(2, 2, 2))
	root.add_child(pb)
	add_child_autofree(root)

	var pbm_path := "user://test_export_retro.pbm"
	var settings := PBMapExporter.ExportSettings.new()
	settings.bake_lighting = false
	settings.bake_textures = false

	var err := PBMapExporter.export_retro_pbm(root, pbm_path, settings)
	assert_eq(err, OK, "PBM export must return OK")
	assert_true(FileAccess.file_exists(pbm_path), "PBM file must exist on disk")

	var f := FileAccess.open(pbm_path, FileAccess.READ)
	assert_not_null(f)
	var magic := f.get_32()
	assert_eq(magic, PBMapExporter.PBM_MAGIC, "Magic must match PBM3")
	var ver := f.get_32()
	assert_eq(ver, PBMapExporter.PBM_VERSION, "Version must match 3")
	var n_tex := f.get_32()
	var n_mesh := f.get_32()
	assert_gt(n_mesh, 0, "Must have at least 1 mesh exported")
	f.close()

	# Cleanup
	DirAccess.remove_absolute(pbm_path)
