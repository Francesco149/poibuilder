## The PBM writer's format contract: PBMapExporter's Retro Baked export with a
## .pbm path.
##
## The GLB->PBM converters (`retro_engine/pbm_conv.py` and
## `export/pb_pbm_converter.gd`) are retired — this writer is the format's only
## producer, so the layout promises live here. The fixture is BUILT in the test
## rather than read from a stale artifact: a format test that skipped whenever a
## pre-exported file was missing could never catch a writer regression.
extends GutTest

const TEST_PBM := "user://test_pbm_writer.pbm"
const FLAME_TEX := "res://addons/poibuilder/materials/textures/particle_flame_2x2_sheet.png"
const SMOKE_TEX := "res://addons/poibuilder/materials/textures/particle_smoke.png"

func before_all() -> void:
	_remove_test_pbm()

func after_all() -> void:
	_remove_test_pbm()

func _remove_test_pbm() -> void:
	var global := ProjectSettings.globalize_path(TEST_PBM)
	if FileAccess.file_exists(global):
		DirAccess.remove_absolute(global)

## Floor (painted: a splat layer + a decal dab) + a scrolling wall, both with
## colliders, a Spawn node, two emitters (additive cutout art and a blended
## puff) and one authored metadata node.
func _build_fixture() -> Node3D:
	var root := Node3D.new()
	root.name = "PbmWriterFixture"
	root.set_meta("poi_env_preset", "dusk")

	var spawn := Node3D.new()
	spawn.name = "Spawn"
	spawn.position = Vector3(1.5, 0.0, -2.5)
	root.add_child(spawn)

	var floor := PBMesh.new()
	floor.name = "Floor"
	floor.pb_mesh_data = PBShapeGenerators.create_plane(8.0, 8.0, 1, 1)
	floor.collider_type = PBMesh.ColliderType.ACCURATE
	root.add_child(floor)
	var fdata := floor.pb_mesh_data
	PBUv.refresh_mesh_uvs(fdata, true)
	var face := fdata.faces[0]
	var splat := PBSplat.create_splat_material(StandardMaterial3D.new())
	fdata.set_face_material(face, splat)
	var tile_tex := ImageTexture.create_from_image(
			Image.create(64, 64, false, Image.FORMAT_RGBA8))
	PBSplat.add_layer(splat, tile_tex, Color.WHITE, 0.8, PBSplat.DEFAULT_MASK_RES)
	PBSplat.paint_face_splat(fdata, face, splat, 1, Vector3.ZERO, 1.5, 0.5, 1.0, false, {})
	PBSplat.paint_decal_dab(fdata, Vector3(1.0, 0, 0), Vector3.UP, 0.0, 0.8, 0.4, 1.0,
			false, null, Color(0.8, 0.2, 0.2, 1.0))

	var wall := PBMesh.new()
	wall.name = "Wall"
	wall.pb_mesh_data = PBShapeGenerators.create_plane(8.0, 4.0, 1, 1)
	wall.collider_type = PBMesh.ColliderType.ACCURATE
	wall.rotation.x = deg_to_rad(-90.0)
	wall.position = Vector3(0, 0, -4.0)
	root.add_child(wall)
	var wdata := wall.pb_mesh_data
	PBUv.refresh_mesh_uvs(wdata, true)
	var wface := wdata.faces[0]
	var wmat := StandardMaterial3D.new()
	wmat.albedo_texture = ImageTexture.create_from_image(
			Image.create(32, 32, false, Image.FORMAT_RGBA8))
	wdata.set_face_material(wface, wmat)
	PBUv.set_scroll_speed(wmat, Vector2(0.25, -0.5))

	var flame_tex: Texture2D = load(FLAME_TEX) if ResourceLoader.exists(FLAME_TEX) else null
	var smoke_tex: Texture2D = load(SMOKE_TEX) if ResourceLoader.exists(SMOKE_TEX) else null
	assert_not_null(flame_tex, "Fixture: %s must exist" % FLAME_TEX)
	assert_not_null(smoke_tex, "Fixture: %s must exist" % SMOKE_TEX)
	if flame_tex == null or smoke_tex == null:
		root.free()
		return null
	var flame := PBParticleParams.build_node(flame_tex,
			PBParticleParams.preset_for_texture(FLAME_TEX), "Emitter_Flame")
	flame.position = Vector3(-2.0, 0.0, 1.0)
	root.add_child(flame)
	var mist := PBParticleParams.build_node(smoke_tex,
			PBParticleParams.preset_for_texture(SMOKE_TEX), "Emitter_Mist")
	mist.position = Vector3(2.0, 0.0, 1.0)
	root.add_child(mist)

	var npc := Node3D.new()
	npc.name = "DialogueNPC"
	npc.position = Vector3(3.0, 0.0, 0.0)
	npc.set_meta("poi_metadata_tag", "dialogue_npc")
	npc.set_meta("poi_metadata_payload", { "line": "hello there" })
	root.add_child(npc)
	return root

func _settings() -> PBMapExporter.ExportSettings:
	var settings := PBMapExporter.ExportSettings.new()
	settings.export_mode = PBMapExporter.ExportMode.RETRO
	settings.subdivide_quads = true
	settings.grid_size = 1.0
	settings.bake_lighting = true
	settings.bake_shadows = true
	settings.bake_ao = true
	settings.bake_textures = true
	settings.tile_resolution = 128
	settings.export_colliders = true
	settings.export_billboards = true
	return settings

## Every triangle vertex the export tree's DRAWN meshes carry, one PBM vertex
## per index (the writer splits shared corners). Colliders and emitter texture
## carriers are not drawn geometry.
func _tree_vertex_budget(tree: Node) -> Dictionary:
	var verts := 0
	var colliders := 0
	var pending: Array[Node] = [tree]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		if node is MeshInstance3D:
			var mi := node as MeshInstance3D
			if String(mi.name).begins_with("Collider_"):
				colliders += 1
			elif not mi.has_meta("poi_emitter_holder") and mi.mesh != null and not (mi.mesh is ImmediateMesh):
				for s in range(mi.mesh.get_surface_count()):
					var arrays := mi.mesh.surface_get_arrays(s)
					var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
					var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
					verts += indices.size() if not indices.is_empty() else positions.size()
		for child in node.get_children():
			pending.append(child)
	return { "verts": verts, "colliders": colliders }

func test_pbm_writer_layout_and_contracts() -> void:
	var root := _build_fixture()
	if root == null:
		fail_test("Fixture could not be built")
		return
	add_child_autofree(root)

	var settings := _settings()
	var global_pbm := ProjectSettings.globalize_path(TEST_PBM)
	var err := PBMapExporter.export_retro_pbm(root, global_pbm, settings)
	assert_eq(err, OK, "The exporter's PBM writer must return OK")
	assert_true(FileAccess.file_exists(global_pbm), "The .pbm must exist on disk")

	var tree := PBMapExporter.build_export_tree(root, _settings())
	assert_not_null(tree, "Fixture: the export tree must build")
	autofree(tree)
	var budget := _tree_vertex_budget(tree)

	var f := FileAccess.open(global_pbm, FileAccess.READ)
	assert_not_null(f, "The .pbm must be readable")

	assert_eq(f.get_32(), PBMapExporter.PBM_MAGIC, "Magic must be PBM3")
	assert_eq(f.get_32(), PBMapExporter.PBM_VERSION, "Version must be 3")
	var num_textures := f.get_32()
	var num_meshes := f.get_32()
	var num_colliders := f.get_32()
	var num_metadata := f.get_32()
	assert_gte(num_textures, 2, "The painted floor + scrolling wall must register textures")

	# Header spawn: the authored Spawn node, not a bounds-derived guess.
	var spawn_x := f.get_float()
	var spawn_y := f.get_float()
	var spawn_z := f.get_float()
	assert_almost_eq(spawn_x, 1.5, 0.01, "The header spawn comes from the Spawn node")
	assert_almost_eq(spawn_z, -2.5, 0.01)
	assert_almost_eq(f.get_float(), 0.0, 0.01, "…and its yaw")
	f.get_float(); f.get_float(); f.get_float()   # bounds_min
	f.get_float(); f.get_float(); f.get_float()   # bounds_max

	# 1. Texture table: pixel-size/format consistency, and the alpha contract
	#    (a soft-alpha texture cannot ride the 16-bit 5551 format).
	var atlas_ids: Dictionary = {}
	var tex_alpha_by_id: Dictionary = {}
	var tex_fmt_by_id: Dictionary = {}
	for ti in range(num_textures):
		var tex_name := f.get_buffer(32).get_string_from_ascii().split("\u0000")[0]
		if tex_name.begins_with("TileAtlas"):
			atlas_ids[ti] = true
		var w := f.get_16()
		var h := f.get_16()
		var fmt := f.get_16()
		var alpha_mode := f.get_16()
		var data_size := f.get_32()
		tex_alpha_by_id[ti] = alpha_mode
		tex_fmt_by_id[ti] = fmt
		assert_gt(w, 0)
		assert_gt(h, 0)
		var bytes_per_pixel := 4 if fmt == PBMapExporter.PBM_TEX_FMT_RGBA8888 else 2
		assert_eq(data_size, w * h * bytes_per_pixel,
			"Texture '%s' data size must match its pixel format" % tex_name)
		if alpha_mode == PBMapExporter.PBM_ALPHA_BLEND:
			assert_eq(fmt, PBMapExporter.PBM_TEX_FMT_RGBA8888,
				"Blended texture '%s' needs the 8-bit alpha of RGBA8888" % tex_name)
		f.seek(f.get_position() + data_size)

	# 2. Meshes: spatial chunks of at most 384 vertices, no vertex lost, and a
	#    scrolling mesh never references a tile atlas (an offset would drag its
	#    tile across the atlas slot).
	var total_verts := 0
	var scrolling := 0
	for mi in range(num_meshes):
		f.get_buffer(32)
		var tex_id := f.get_32()
		var n_verts := f.get_32()
		total_verts += n_verts
		f.get_float(); f.get_float(); f.get_float()
		f.get_float(); f.get_float(); f.get_float()
		var scroll := Vector2(f.get_float(), f.get_float())
		if scroll != Vector2.ZERO:
			scrolling += 1
			assert_false(atlas_ids.has(tex_id),
				"A scrolling mesh must reference a standalone texture")
		assert_lte(n_verts, 384, "Each spatial chunk must be <= 384 vertices")
		f.seek(f.get_position() + n_verts * 24)

	assert_eq(scrolling, 1, "The scrolling wall exports one scrolling mesh")
	assert_eq(total_verts, int(budget["verts"]),
		"Every drawn vertex of the export tree must reach the PBM (chunking is spatial, never lossy)")

	# 3. Colliders: one entry per collider node.
	assert_eq(num_colliders, int(budget["colliders"]),
		"One collider entry per Collider_ node in the export tree")
	for ci in range(num_colliders):
		f.get_buffer(32)
		f.get_32()
		f.get_float(); f.get_float(); f.get_float()
		f.get_float(); f.get_float(); f.get_float()
		var num_tris := f.get_32()
		assert_gt(num_tris, 0, "A collider carries triangles")
		f.seek(f.get_position() + num_tris * 36)

	# 4. Metadata: the scene's own lumps only. The exporter used to fabricate a
	#    demo walkable quad, an archway trigger, a ball pit and a PatrolSphere
	#    entity into EVERY map — smoke-test data that must never ship.
	var meta_tags: Dictionary = {}
	for mi in range(num_metadata):
		var tag := f.get_buffer(32).get_string_from_ascii().strip_edges()
		var mtype := f.get_32()
		var msize := f.get_32()
		var mdata := f.get_buffer(msize)
		var pad := (4 - (msize % 4)) % 4
		if pad > 0:
			f.seek(f.get_position() + pad)
		meta_tags[tag] = { "type": mtype, "size": msize, "data": mdata }

	assert_eq(meta_tags["map_name"]["data"].get_string_from_utf8(), "PbmWriterFixture",
		"The map name comes from the scene root, not a demo title")
	assert_eq(meta_tags["env_preset"]["data"].get_string_from_utf8(), "dusk",
		"The environment preset travels from the scene (poi_env_preset)")
	assert_true(meta_tags.has("player_spawn"), "The spawn lump is always present")
	var spawn_json = JSON.parse_string(meta_tags["player_spawn"]["data"].get_string_from_utf8())
	assert_true(spawn_json is Dictionary and spawn_json.has("position"))

	for demo_tag in ["walkable_mesh", "triggers", "rigid_bodies", "entities"]:
		assert_false(meta_tags.has(demo_tag),
			"A map never carries the exporter's leftover demo '%s' lump" % demo_tag)

	assert_true(meta_tags.has("dialogue_npc"),
		"An authored poi_metadata_tag node still exports its lump")
	var npc_json = JSON.parse_string(meta_tags["dialogue_npc"]["data"].get_string_from_utf8())
	assert_true(npc_json is Dictionary and npc_json.get("line") == "hello there",
		"The authored payload round-trips")

	# 5. Emitters: the standard lump's normative layout (16-byte header + 176
	#    bytes per record), the flags the authored nodes imply, and each
	#    emitter's texture traveling with the alpha its art needs.
	assert_true(meta_tags.has("emitters"), "Both authored emitters export a lump")
	assert_eq(meta_tags["emitters"]["type"], PBMapExporter.PBM_META_EMITTER)
	var em: PackedByteArray = meta_tags["emitters"]["data"]
	assert_eq(em.decode_u32(0), 0x54494D45, "Emitter lump magic must be EMIT")
	assert_eq(em.decode_u32(4), 1, "Emitter lump version must be 1")
	var em_count := em.decode_u32(8)
	assert_eq(em_count, 2, "The fixture authors two emitters")
	assert_eq(em.size(), 16 + em_count * PBMapExporter.PBM_EMITTER_SIZE_BYTES,
		"Lump size must be its header plus 176 bytes per emitter")

	var flame_off := 16
	assert_eq(em.slice(flame_off, flame_off + 13).get_string_from_ascii(), "Emitter_Flame")
	var flame_flags := em.decode_u16(flame_off + 0x9A)
	assert_ne(flame_flags & PBMapExporter.PBM_EMIT_ADDITIVE, 0, "The flame preset is additive")
	assert_gt(em.decode_u16(flame_off + 0x98), 0, "The particle count must be set")
	assert_almost_eq(em.decode_float(flame_off + 0x18), -2.0, 0.01,
		"The emitter position comes from the authored node")
	var flame_tex_id := int(em.decode_u32(flame_off + 0x94))
	assert_gte(flame_tex_id, 0, "The flame art must be a real texture entry")
	# Emitter art rides RGBA8888 whatever its alpha is: additive particles are a
	# falloff of light, and 5551's 5-bit channels truncate the dim outer gradient
	# into a hard-edged disc (a halo ring that slices through overlapping
	# particles — measured on the device).
	assert_eq(tex_fmt_by_id[flame_tex_id], PBMapExporter.PBM_TEX_FMT_RGBA8888,
		"Emitter art keeps its RGB precision in the 8-bit format")
	assert_eq(tex_alpha_by_id[flame_tex_id], PBMapExporter.PBM_ALPHA_BLEND,
		"…with the alpha mode the draw material declares")

	var mist_off := 16 + PBMapExporter.PBM_EMITTER_SIZE_BYTES
	assert_eq(em.slice(mist_off, mist_off + 12).get_string_from_ascii(), "Emitter_Mist")
	assert_eq(em.decode_u16(mist_off + 0x9A) & PBMapExporter.PBM_EMIT_ADDITIVE, 0,
		"The mist preset blends rather than adding")
	var mist_tex_id := int(em.decode_u32(mist_off + 0x94))
	assert_eq(tex_alpha_by_id[mist_tex_id], PBMapExporter.PBM_ALPHA_BLEND,
		"A soft puff needs the 8-bit alpha of a blend texture")
	assert_eq(tex_fmt_by_id[mist_tex_id], PBMapExporter.PBM_TEX_FMT_RGBA8888)

	f.close()
