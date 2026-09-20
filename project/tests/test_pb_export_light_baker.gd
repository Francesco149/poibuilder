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

## A quad PBMesh named nothing sprite-like, carrying `mat`, standing at y=1.
## The floor is an opaque cube whose top sits at y=0, so a shadow ray from just
## above the floor straight up crosses exactly the quad.
func _shadow_scene_with_quad(mat: Material, quad_name: String) -> PBLightBaker.SpatialGrid:
	var root := Node3D.new()
	autofree(root)
	var floor_box := PBMesh.create_cube(4.0)
	floor_box.name = "Floor"
	floor_box.position = Vector3(0, -2, 0)
	root.add_child(floor_box)

	var quad := PBMesh.new()
	quad.name = quad_name
	quad.pb_mesh_data = PBShapeGenerators.create_sprite(2.0, 2.0)
	quad.pb_mesh_data.materials = [mat]
	quad.position = Vector3(0, 1, 0)
	# Lay the quad horizontal (a ceiling over the floor point): the sprite
	# generator builds a VERTICAL quad in the X-Y plane, and a vertical shadow
	# ray would travel IN that plane and never cross it.
	quad.rotation_degrees = Vector3(90, 0, 0)
	root.add_child(quad)
	quad.rebuild()

	return PBLightBaker.build_spatial_grid(root)

func test_blended_plane_does_not_occlude_shadow_bake() -> void:
	# The "waterfall shadow" known issue: a blended scrolling plane must let
	# the bake's light through. It used to enter the shadow grid as a full
	# opaque occluder whenever its material was NOT on material_override —
	# a PBMesh's face materials were never checked at all.
	var blended := StandardMaterial3D.new()
	blended.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var grid := _shadow_scene_with_quad(blended, "SmokePlane")
	var trans := grid.get_shadow_transmission(Vector3(0, 0.05, 0), Vector3.UP, 10.0)
	assert_eq(trans, 1.0, "A blended plane must not darken the bake under it")

func test_opaque_plane_still_occludes_shadow_bake() -> void:
	# Control for the blended case: the same quad with an opaque material is a
	# real occluder.
	var opaque := StandardMaterial3D.new()
	var grid := _shadow_scene_with_quad(opaque, "Wall")
	var trans := grid.get_shadow_transmission(Vector3(0, 0.05, 0), Vector3.UP, 10.0)
	assert_eq(trans, 0.0, "An opaque plane must still occlude the bake")

func test_waterfall_named_blended_plane_keeps_soft_transmission() -> void:
	# The is_water opt-in deliberately lets half the light through per plane.
	var blended := StandardMaterial3D.new()
	blended.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var grid := _shadow_scene_with_quad(blended, "WaterfallSheet")
	var trans := grid.get_shadow_transmission(Vector3(0, 0.05, 0), Vector3.UP, 10.0)
	assert_almost_eq(trans, 0.5, 0.01, "A Waterfall-named plane keeps its 0.5 transmission")

func test_plain_mesh_blended_surface_material_does_not_occlude() -> void:
	# An imported glTF-style plane: the blended material lives in the mesh
	# SURFACE slot, not material_override — the old override-only check never
	# saw it and the plane baked a full opaque shadow.
	var root := Node3D.new()
	autofree(root)
	var floor_box := PBMesh.create_cube(4.0)
	floor_box.name = "Floor"
	floor_box.position = Vector3(0, -2, 0)
	root.add_child(floor_box)

	var mi := MeshInstance3D.new()
	mi.name = "MistPlane"
	var qm := QuadMesh.new()
	qm.size = Vector2(2, 2)
	mi.mesh = qm
	var blended := StandardMaterial3D.new()
	blended.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qm.material = blended
	mi.position = Vector3(0, 1, 0)
	mi.rotation_degrees = Vector3(90, 0, 0)
	root.add_child(mi)

	var grid := PBLightBaker.build_spatial_grid(root)
	var trans := grid.get_shadow_transmission(Vector3(0, 0.05, 0), Vector3.UP, 10.0)
	assert_eq(trans, 1.0, "A blended surface-material plane must not darken the bake under it")

func test_placed_sprite_bakes_silhouette_shadow_triangles() -> void:
	# A placed sprite (PBMesh, shape_id "sprite") must enter the shadow grid as
	# an ALPHA-SILHOUETTE occluder sampled from its texture — not as an opaque
	# full-quad rectangle (the old plain-PBMesh fallback).
	var root := Node3D.new()
	autofree(root)
	var sprite := PBMesh.new()
	sprite.name = "Billboard_Sprite"
	sprite.pb_mesh_data = PBShapeGenerators.create_sprite(2.0, 4.0)
	var img := Image.create(16, 32, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 1))
	var tex := ImageTexture.create_from_image(img)
	sprite.pb_mesh_data.materials = [PBSpritePlacer.create_billboard_material(tex, false, true)]
	sprite.pb_mesh_data.shape_id = &"sprite"
	root.add_child(sprite)
	sprite.rebuild()  # the real placement flow rebuilds — surface material exists

	var grid := PBLightBaker.build_spatial_grid(root)
	var silhouette := 0
	var total := 0
	for tri in grid.all_triangles:
		total += 1
		if tri.has_alpha:
			silhouette += 1
	assert_gt(total, 0, "Sprite geometry must reach the shadow grid")
	assert_eq(silhouette, total, "Every sprite triangle must carry its alpha silhouette")
