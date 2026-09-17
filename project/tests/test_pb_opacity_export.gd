## Tests for the Face Opacity export path: the tint (vertex colors, alpha
## included) must survive the light bake into the exported vertex colours, so
## a face dimmed with the dock's Opacity control fades on the PSP too. The
## device multiplies vertex alpha into the blended pass (GU_TFX_MODULATE,
## GU_TCC_RGBA) — but only for surfaces whose texture alpha mode blends, which
## is why the dock flips the material alongside the alpha write.
extends GutTest

func _settings() -> PBMapExporter.ExportSettings:
	var settings := PBMapExporter.ExportSettings.new()
	settings.export_mode = PBMapExporter.ExportMode.RETRO
	settings.subdivide_quads = true
	settings.bake_lighting = true
	settings.bake_textures = false
	settings.export_colliders = false
	settings.export_billboards = true
	return settings

## Every vertex colour on the exported mesh carries the tint's alpha.
func _assert_surface_alpha(mesh: Mesh, expected_a: float, context: String) -> void:
	assert_gt(mesh.get_surface_count(), 0, context + ": surfaces exist")
	for s in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(s)
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		assert_gt(colors.size(), 0, context + ": baked vertex colors exist")
		for c in colors:
			assert_almost_eq(c.a, expected_a, 0.01, context + ": vertex alpha survives the bake")

func test_face_tint_alpha_reaches_retro_vertex_colors() -> void:
	var root := Node3D.new()
	autofree(root)

	var cube := PBMesh.create_cube(2.0)
	cube.name = "OpacityCube"
	root.add_child(cube)

	# Dim EVERY face to 50% (the dock writes alpha on the selected faces'
	# corners; whole-object opacity is the same write on all faces).
	var data := cube.pb_mesh_data
	data.colors.resize(data.positions.size())
	data.colors.fill(Color(1.0, 1.0, 1.0, 0.5))

	var export_tree := PBMapExporter.build_export_tree(root, _settings())
	assert_not_null(export_tree)
	autofree(export_tree)

	var node := export_tree.get_node_or_null("OpacityCube") as MeshInstance3D
	assert_not_null(node, "Exported cube present")
	# Alpha is untouched by the light accumulation (light alpha is 1), so
	# every exported vertex must carry exactly the 0.5 tint alpha.
	_assert_surface_alpha(node.mesh, 0.5, "50% face opacity")

func test_full_opacity_mesh_keeps_opaque_vertex_colors() -> void:
	var root := Node3D.new()
	autofree(root)

	var cube := PBMesh.create_cube(2.0)
	cube.name = "OpaqueCube"
	root.add_child(cube)

	var export_tree := PBMapExporter.build_export_tree(root, _settings())
	autofree(export_tree)
	var node := export_tree.get_node_or_null("OpaqueCube") as MeshInstance3D
	assert_not_null(node)
	_assert_surface_alpha(node.mesh, 1.0, "default mesh")

func test_billboard_material_alpha_bakes_into_vertex_colors() -> void:
	var root := Node3D.new()
	autofree(root)

	var sprite := MeshInstance3D.new()
	sprite.name = "SpriteFaded"
	sprite.set_meta("is_billboard", true)
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.5)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 1.0, 1.0, 0.4)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	quad.material = mat
	sprite.mesh = quad
	root.add_child(sprite)

	var settings := _settings()
	var export_tree := PBMapExporter.build_export_tree(root, settings)
	assert_not_null(export_tree)
	autofree(export_tree)

	var node := export_tree.get_node_or_null("SpriteFaded") as MeshInstance3D
	assert_not_null(node, "Exported billboard present")
	_assert_surface_alpha(node.mesh, 0.4, "40% billboard")
