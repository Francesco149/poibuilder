## Unit tests for PBTileBaker
extends GutTest

func test_unpainted_face_reuses_base_material() -> void:
	var mesh_node := PBMesh.create_cube(2.0)
	autofree(mesh_node)
	var mesh_data: PBMeshData = mesh_node.pb_mesh_data
	var face: PBFace = mesh_data.faces[0]

	var frags := PBFaceSubdivider.subdivide_face(mesh_data, face, 0, true, 1.0)
	assert_eq(frags.size(), 4, "2m x 2m face subdivided at 1m should have 4 fragments")

	var cache := {}
	var baked := PBTileBaker.bake_face_tiles(mesh_node, mesh_data, face, 0, frags, true, 64, cache)
	assert_eq(baked.baked_textures.size(), 0, "Unpainted face should generate 0 baked textures")
	assert_eq(baked.tile_materials.size(), 4, "All 4 fragments must have a material")

	# All 4 fragments must share the exact same base material instance
	var first_mat: Material = baked.tile_materials[frags[0]]
	assert_not_null(first_mat)
	for i in range(1, 4):
		assert_eq(baked.tile_materials[frags[i]], first_mat, "Unpainted tiles must share base material")

func test_stamped_face_bakes_only_touched_tile() -> void:
	var mesh_node := PBMesh.create_cube(2.0)
	autofree(mesh_node)
	var mesh_data: PBMeshData = mesh_node.pb_mesh_data
	var face: PBFace = mesh_data.faces[0]

	# Add a PBStamps container and a stamp positioned in one corner
	var stamps_container := Node3D.new()
	stamps_container.name = "PBStamps"
	mesh_node.add_child(stamps_container)

	var stamp_quad := MeshInstance3D.new()
	stamp_quad.name = "Stamp_0"
	# Position in top-right corner in planar space: anchor_center=(0.5, 0.5), size=(0.2, 0.2)
	stamp_quad.set_meta("face_idx", 0)
	stamp_quad.set_meta("stamp_texture_path", "res://addons/poibuilder/materials/textures/flower_patch.png")
	stamp_quad.set_meta("stamp_opacity", 1.0)
	stamp_quad.set_meta("stamp_scale", 1.0)
	stamp_quad.set_meta("stamp_rotation", 0.0)
	stamp_quad.set_meta("anchor_center", Vector2(-0.5, 0.5))
	stamp_quad.set_meta("anchor_du", Vector2(0.1, 0.0))
	stamp_quad.set_meta("anchor_dv", Vector2(0.0, 0.1))
	stamps_container.add_child(stamp_quad)

	var frags := PBFaceSubdivider.subdivide_face(mesh_data, face, 0, true, 1.0)
	assert_eq(frags.size(), 4)

	var cache := {}
	var baked := PBTileBaker.bake_face_tiles(mesh_node, mesh_data, face, 0, frags, true, 64, cache)

	# Exactly 1 tile should be baked, 3 should reuse base material
	assert_eq(baked.baked_textures.size(), 1, "Only the 1 stamped tile should generate a baked texture")

	var baked_count := 0
	var base_count := 0
	for frag in frags:
		var mat: Material = baked.tile_materials[frag]
		if mat.resource_name.begins_with("BakedTile"):
			baked_count += 1
		else:
			base_count += 1

	assert_eq(baked_count, 1, "Exactly 1 fragment must use the BakedTile material")
	assert_eq(base_count, 3, "The other 3 fragments must reuse the unpainted base material")
