## Integration tests for showcase map export and retro map viewer
extends GutTest

const RETRO_GLB_PATH := "res://exports/showcase_retro_baked.glb"
const MODERN_GLB_PATH := "res://exports/showcase_modern.glb"
const SHOWCASE_TSCN_PATH := "res://test_scenes/test_map_showcase.tscn"

func test_build_and_export_showcase_map() -> void:
	var showcase_root := TestMapShowcaseBuilder.build_showcase_scene()
	assert_not_null(showcase_root)
	autofree(showcase_root)

	# Save showcase scene with player for editor inspection and interactive play
	var save_err := TestMapShowcaseBuilder.save_showcase_scene("user://test_map_showcase.tscn", true)
	assert_eq(save_err, OK, "Saving showcase scene with player must succeed")
	TestMapShowcaseBuilder.save_showcase_scene(SHOWCASE_TSCN_PATH, true)

	# 1. Export Retro Baked GLB
	var retro_settings := PBMapExporter.ExportSettings.new()
	retro_settings.export_mode = PBMapExporter.ExportMode.RETRO
	retro_settings.subdivide_quads = true
	retro_settings.grid_size = 1.0
	retro_settings.bake_lighting = true
	retro_settings.bake_shadows = true
	retro_settings.bake_ao = true
	retro_settings.bake_textures = true
	retro_settings.tile_resolution = 128
	retro_settings.export_colliders = true
	retro_settings.export_billboards = true

	var retro_err := PBMapExporter.export_map(showcase_root, RETRO_GLB_PATH, retro_settings)
	assert_eq(retro_err, OK, "Retro baked map export must succeed with OK")
	assert_true(FileAccess.file_exists(RETRO_GLB_PATH), "showcase_retro_baked.glb must exist")

	var fa_retro := FileAccess.open(RETRO_GLB_PATH, FileAccess.READ)
	assert_not_null(fa_retro)
	var retro_size := fa_retro.get_length()
	fa_retro.close()
	assert_gt(retro_size, 1000, "Retro GLB must contain valid baked geometry and textures")
	var pbm_err := PBPbmConverter.convert_glb_to_pbm(RETRO_GLB_PATH, "res://../retro_engine/psp/showcase_retro_baked.pbm", true)
	assert_eq(pbm_err, OK, "Converting showcase retro GLB to PBM must succeed")

	# 2. Export Modern GLB
	var modern_settings := PBMapExporter.ExportSettings.new()
	modern_settings.export_mode = PBMapExporter.ExportMode.MODERN
	modern_settings.bake_lighting = false
	modern_settings.export_colliders = true
	modern_settings.export_billboards = true

	var modern_err := PBMapExporter.export_map(showcase_root, MODERN_GLB_PATH, modern_settings)
	assert_eq(modern_err, OK, "Modern GLB export must succeed with OK")
	assert_true(FileAccess.file_exists(MODERN_GLB_PATH), "showcase_modern.glb must exist")

	var fa_modern := FileAccess.open(MODERN_GLB_PATH, FileAccess.READ)
	assert_not_null(fa_modern)
	var modern_size := fa_modern.get_length()
	fa_modern.close()
	assert_gt(modern_size, 1000, "Modern GLB must contain valid geometry and metadata")

func test_export_environment_presets() -> void:
	for p_name in ["dawn", "dusk", "night"]:
		var err := TestMapShowcaseBuilder.export_showcase_preset(p_name)
		assert_eq(err, OK, "Exporting preset %s must succeed" % p_name)
		var glb_path := "res://exports/showcase_retro_baked_%s.glb" % p_name
		assert_true(FileAccess.file_exists(glb_path), "GLB for preset %s must exist" % p_name)
		var pbm_path := "res://../retro_engine/psp/showcase_retro_baked_%s.pbm" % p_name
		assert_true(FileAccess.file_exists(pbm_path), "PBM for preset %s must exist" % p_name)

func test_retro_map_viewer_loads_and_inspects_showcase() -> void:
	# Verify retro GLB exists (built by test above)
	assert_true(FileAccess.file_exists(RETRO_GLB_PATH), "Showcase retro GLB must exist for viewer test")

	# Instantiate the retro map viewer scene
	var viewer_scene: PackedScene = load("res://test_scenes/retro_map_viewer.tscn")
	assert_not_null(viewer_scene, "retro_map_viewer.tscn must load cleanly")

	var viewer: Node3D = viewer_scene.instantiate()
	assert_not_null(viewer, "Viewer scene must instantiate")
	add_child_autofree(viewer)

	# Load the baked showcase map into the viewer
	var load_success: bool = viewer.load_map(RETRO_GLB_PATH)
	assert_true(load_success, "Viewer must load showcase_retro_baked.glb cleanly")

	assert_gt(viewer.total_vertices, 100, "Viewer must report vertices from loaded map")
	assert_gt(viewer.total_triangles, 50, "Viewer must report triangles from loaded map")
	assert_gt(viewer.loaded_mesh_instances.size(), 0, "Viewer must hold loaded mesh instances")

	# Test all 4 display modes without errors
	viewer.set_display_mode(1) # FULL_BAKED
	assert_eq(viewer.current_mode, 1)

	viewer.set_display_mode(2) # VERTEX_COLORS_ONLY
	assert_eq(viewer.current_mode, 2)

	viewer.set_display_mode(3) # TEXTURES_ONLY
	assert_eq(viewer.current_mode, 3)

	viewer.set_display_mode(4) # WIREFRAME
	assert_eq(viewer.current_mode, 4)
	assert_gt(viewer.wireframe_mesh_instances.size(), 0, "Wireframe mesh instances must be generated")
	for w_mi in viewer.wireframe_mesh_instances:
		assert_true(w_mi.visible, "Wireframe overlays must be visible in mode 4")
		assert_not_null(w_mi.mesh, "Wireframe overlay must have a mesh")
		assert_gt(w_mi.mesh.get_surface_count(), 0, "Wireframe mesh must have at least one surface")

	# Test cycling wireframe styles
	assert_eq(viewer.wireframe_style, 0) # DARK_SLATE
	viewer.cycle_wireframe_style()
	assert_eq(viewer.wireframe_style, 1) # VERTEX_LIGHT
	viewer.cycle_wireframe_style()
	assert_eq(viewer.wireframe_style, 2) # TEXTURES
	viewer.cycle_wireframe_style()
	assert_eq(viewer.wireframe_style, 0) # Back to DARK_SLATE

	# Switch back to full baked and verify overlays are hidden
	viewer.set_display_mode(1)
	assert_eq(viewer.current_mode, 1)
	for w_mi in viewer.wireframe_mesh_instances:
		assert_false(w_mi.visible, "Wireframe overlays must be hidden in mode 1")

func test_showcase_vertex_colors_and_surfaces() -> void:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(RETRO_GLB_PATH, state)
	assert_eq(err, OK)
	var scene := doc.generate_scene(state)
	assert_not_null(scene)
	autofree(scene)

	for child in scene.get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).mesh != null:
			var mi := child as MeshInstance3D
			if mi.name.begins_with("Collider_"):
				continue
			if mi.name == "CourtyardFloor":
				print("DEBUG CourtyardFloor total surface count: ", mi.mesh.get_surface_count())
			for s in range(mi.mesh.get_surface_count()):
				var arrays := mi.mesh.surface_get_arrays(s)
				var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
				if not cols.is_empty():
					var max_r := 0.0
					for c in cols:
						max_r = maxf(max_r, c.r)
					assert_gt(max_r, 0.1, "Mesh %s surface %d must have nonzero lit vertex colors, got max_r=%.3f" % [mi.name, s, max_r])

func test_retro_export_enforces_power_of_two_textures() -> void:
	# Test enforce_pot_image logic
	var non_pot := Image.create(75, 130, false, Image.FORMAT_RGBA8)
	var pot_clamped := PBTileBaker.enforce_pot_image(non_pot, 512)
	assert_eq(pot_clamped.get_width(), 128, "75 should round to power of two 128")
	assert_eq(pot_clamped.get_height(), 256, "130 should round to power of two 256")

	var oversize := Image.create(2048, 1024, false, Image.FORMAT_RGBA8)
	var clamped := PBTileBaker.enforce_pot_image(oversize, 512)
	assert_eq(clamped.get_width(), 512, "Width must clamp to max 512")
	assert_eq(clamped.get_height(), 512, "Height must clamp to max 512")

	# Inspect all images extracted from the retro baked GLB
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(RETRO_GLB_PATH, state)
	assert_eq(err, OK)
	var textures: Array[Texture2D] = state.get_images()
	assert_gt(textures.size(), 0, "Retro GLB must contain embedded textures")
	for tex in textures:
		var img := tex.get_image()
		assert_not_null(img)
		var w := img.get_width()
		var h := img.get_height()
		# Verify width and height are powers of 2
		assert_true((w & (w - 1)) == 0, "Image width %d must be power of 2" % w)
		assert_true((h & (h - 1)) == 0, "Image height %d must be power of 2" % h)
		assert_lte(w, 512, "Image width %d must not exceed max size 512" % w)
		assert_lte(h, 512, "Image height %d must not exceed max size 512" % h)

func test_ramp_collider_export() -> void:
	var stairs_data := PBShapeFactory.create_shape(&"stair", Vector3(2.0, 3.0, 4.0))
	stairs_data.shape_params = {"steps": 6}
	var pb := PBMesh.new()
	pb.name = "TestStairs"
	pb.pb_mesh_data = stairs_data
	pb.collider_type = PBMesh.ColliderType.RAMP
	add_child_autofree(pb)

	var parent := Node3D.new()
	add_child_autofree(parent)
	PBMapExporter._export_collider_mesh(pb, parent)

	assert_eq(parent.get_child_count(), 1, "Should export one collider mesh")
	var col_mi := parent.get_child(0) as MeshInstance3D
	assert_not_null(col_mi)
	assert_eq(col_mi.name, "Collider_TestStairs")
	assert_not_null(col_mi.mesh)

	# Straight stairs ramp collider is a clean triangular prism with exactly 8 triangles (24 vertices),
	# whereas the visual stepped stairs have dozens of step facets.
	var arrs := col_mi.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrs[Mesh.ARRAY_VERTEX]
	assert_eq(verts.size(), 24, "Ramp collider mesh should export a clean 8-triangle prism (24 vertices)")

	var viewer_scene := load("res://test_scenes/retro_map_viewer.tscn") as PackedScene
	var viewer = viewer_scene.instantiate()
	add_child_autofree(viewer)

	# Load the retro showcase map
	var loaded: bool = viewer.load_map(RETRO_GLB_PATH)
	assert_true(loaded, "Should load showcase retro map")

	# 1. Test Mode 5 (COLLIDERS_ONLY)
	viewer.set_display_mode(5) # COLLIDERS_ONLY
	assert_eq(viewer.current_mode, 5)

	var visual_count := 0
	var col_count := 0
	for mi in viewer.loaded_mesh_instances:
		if mi.name.begins_with("Collider_"):
			col_count += 1
			assert_true(mi.visible, "Collider mesh %s must be visible in Mode 5" % mi.name)
		else:
			visual_count += 1
			assert_false(mi.visible, "Visual mesh %s must be hidden in Mode 5" % mi.name)

	assert_gt(col_count, 0, "Showcase map must have collider meshes")
	assert_gt(visual_count, 0, "Showcase map must have visual meshes")

	# Verify collider wireframes are visible
	assert_gt(viewer.collider_wireframe_instances.size(), 0, "Must have collider wireframe overlays")
	for cw in viewer.collider_wireframe_instances:
		assert_true(cw.visible, "Collider wireframe overlays must be visible in Mode 5")

	# 2. Test Play Mode
	assert_false(viewer.is_play_mode, "Should not start in play mode")
	viewer.enter_play_mode()
	assert_true(viewer.is_play_mode, "Should enter play mode")
	assert_not_null(viewer.player, "Player character must be instantiated")
	assert_true(viewer.player is CharacterBody3D, "Player must be a CharacterBody3D")
	assert_true(viewer.player_cam.current, "Player camera must be active in play mode")
	assert_false(viewer.camera.current, "Fly camera must be inactive in play mode")

	# Verify physics world
	assert_not_null(viewer.physics_world, "Physics world container must exist")
	assert_gt(viewer.physics_world.get_child_count(), 0, "Physics world must have StaticBody3D collision nodes")
	var first_body = viewer.physics_world.get_child(0) as StaticBody3D
	assert_not_null(first_body, "Child must be StaticBody3D")
	assert_not_null(first_body.get_node_or_null("CollisionShape"), "StaticBody3D must have CollisionShape")

	# Exit Play Mode
	viewer.exit_play_mode()
	assert_false(viewer.is_play_mode, "Should exit play mode")
	assert_true(viewer.camera.current, "Fly camera must be restored after exiting play mode")
	assert_false(viewer.player_cam.current, "Player camera must be deactivated")
