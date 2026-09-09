## Integration tests for showcase map export and retro map viewer
extends GutTest

const RETRO_GLB_PATH := "res://test_scenes/showcase_retro_baked.glb"
const MODERN_GLB_PATH := "res://test_scenes/showcase_modern.glb"
const SHOWCASE_TSCN_PATH := "res://test_scenes/test_map_showcase.tscn"

func test_build_and_export_showcase_map() -> void:
	var showcase_root := TestMapShowcaseBuilder.build_showcase_scene()
	assert_not_null(showcase_root)
	autofree(showcase_root)

	# Save showcase scene with player for editor inspection and interactive play
	var save_err := TestMapShowcaseBuilder.save_showcase_scene(SHOWCASE_TSCN_PATH, true)
	assert_eq(save_err, OK, "Saving showcase scene with player must succeed")

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
