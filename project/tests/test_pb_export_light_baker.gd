## Unit tests for PBLightBaker
extends GutTest

func test_lighting_disabled_returns_white() -> void:
	var positions := PackedVector3Array([Vector3.ZERO, Vector3.UP])
	var normals := PackedVector3Array([Vector3.UP, Vector3.UP])
	var cols := PBLightBaker.bake_vertex_colors(positions, normals, Transform3D.IDENTITY, [], null, false)
	assert_eq(cols.size(), 2)
	assert_eq(cols[0], Color.WHITE)
	assert_eq(cols[1], Color.WHITE)

func test_directional_light_lights_facing_surfaces() -> void:
	var light := DirectionalLight3D.new()
	autofree(light)
	# Point light downwards (-Y), so to_light is +Y
	light.transform = Transform3D(Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), Vector3.ZERO)
	light.light_color = Color.WHITE
	light.light_energy = 1.0

	var positions := PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
	var normals := PackedVector3Array([Vector3.UP, Vector3.DOWN]) # Top face vs Bottom face

	var cols := PBLightBaker.bake_vertex_colors(positions, normals, Transform3D.IDENTITY, [light], null, true, false, false)
	assert_gt(cols[0].r, cols[1].r, "Top-facing vertex should be brighter than bottom-facing vertex")
	assert_gt(cols[0].r, 0.5, "Top-facing vertex should receive strong direct light")

func test_shadow_casting() -> void:
	var root := Node3D.new()
	autofree(root)

	# Light pointing down from Y=10
	var light := DirectionalLight3D.new()
	light.name = "Sun"
	light.position = Vector3(0, 10, 0)
	light.transform = Transform3D(Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), Vector3(0, 10, 0))
	light.light_color = Color.WHITE
	light.light_energy = 1.0
	root.add_child(light)

	# Caster box at Y=2, size 2x2
	var caster := PBMesh.create_cube(2.0)
	caster.name = "Caster"
	caster.position = Vector3(0, 2, 0)
	root.add_child(caster)

	var grid := PBLightBaker.build_spatial_grid(root)
	assert_gt(grid.all_triangles.size(), 0, "Spatial grid must contain triangles from caster box")

	# Test 2 points on floor (Y=0, normal=UP):
	# Point 0: at (0, 0, 0) directly under caster -> in shadow
	# Point 1: at (10, 0, 0) far away from caster -> lit
	var positions := PackedVector3Array([Vector3(0, 0, 0), Vector3(10, 0, 0)])
	var normals := PackedVector3Array([Vector3.UP, Vector3.UP])

	var cols := PBLightBaker.bake_vertex_colors(positions, normals, Transform3D.IDENTITY, [light], grid, true, true, false)
	assert_gt(cols[1].r, cols[0].r, "Unshadowed point (10, 0, 0) must be brighter than shadowed point (0, 0, 0)")

func test_ambient_occlusion_in_corner() -> void:
	var root := Node3D.new()
	autofree(root)

	# Floor box: size 4.0, position (0, -2, 0)
	var floor_box := PBMesh.create_cube(4.0)
	floor_box.position = Vector3(0, -2, 0)
	root.add_child(floor_box)

	# Wall box: size 4.0, position (-2, 2, 0)
	var wall_box := PBMesh.create_cube(4.0)
	wall_box.position = Vector3(-2, 2, 0)
	root.add_child(wall_box)

	var grid := PBLightBaker.build_spatial_grid(root)

	# Vertex in corner at (0.1, 0.05, 0) vs Vertex out in open at (1.5, 0.05, 0)
	var positions := PackedVector3Array([Vector3(0.1, 0.05, 0), Vector3(1.5, 0.05, 0)])
	var normals := PackedVector3Array([Vector3.UP, Vector3.UP])

	# Bake AO only (no direct lights)
	var cols := PBLightBaker.bake_vertex_colors(positions, normals, Transform3D.IDENTITY, [], grid, true, false, true, 16, 1.5, 1.0)
	assert_gt(cols[1].r, cols[0].r, "Open floor vertex should be brighter (less AO) than corner vertex")

func test_billboard_lighting() -> void:
	var light := DirectionalLight3D.new()
	autofree(light)
	light.transform = Transform3D(Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), Vector3.ZERO)
	light.light_color = Color(1.0, 0.8, 0.6)
	light.light_energy = 1.0

	var unlit_node := MeshInstance3D.new()
	autofree(unlit_node)
	unlit_node.set_meta("is_lit", false)

	var unlit_cols := PBLightBaker.bake_billboard_colors(unlit_node, [light], null, true)
	assert_eq(unlit_cols[0], Color.WHITE, "Unlit billboard must have white vertex colors")

	var lit_node := MeshInstance3D.new()
	autofree(lit_node)
	lit_node.set_meta("is_lit", true)

	var lit_cols := PBLightBaker.bake_billboard_colors(lit_node, [light], null, true)
	assert_ne(lit_cols[0], Color.WHITE, "Lit billboard must have baked lighting colors")
	assert_gt(lit_cols[0].r, 0.3, "Lit billboard should receive light")
