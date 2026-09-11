## End-to-end unit test: Authoring custom entities & metadata in Godot scene -> PBM export -> Verification
extends GutTest

const TEST_AUTHORED_PBM := "res://exports/test_custom_authored.pbm"

func before_all() -> void:
	if FileAccess.file_exists(TEST_AUTHORED_PBM):
		DirAccess.remove_absolute(TEST_AUTHORED_PBM)

func after_all() -> void:
	if FileAccess.file_exists(TEST_AUTHORED_PBM):
		DirAccess.remove_absolute(TEST_AUTHORED_PBM)
func test_end_to_end_godot_entity_authoring_to_pbm() -> void:
	# 1. Build a custom scene tree in Godot demonstrating entity authoring
	var scene_root := Node3D.new()
	scene_root.name = "MyCustomDungeon"
	scene_root.set_meta("map_name", "The Sunken Vault")
	autofree(scene_root)

	# 1a. Base floor cube
	var floor_box := PBMesh.create_cube(4.0)
	floor_box.name = "FloorSlab"
	scene_root.add_child(floor_box)

	# 1b. Player Spawn Point (Marker3D)
	var spawn_marker := Marker3D.new()
	spawn_marker.name = "PlayerSpawn_DungeonEntrance"
	spawn_marker.position = Vector3(1.5, 2.0, 3.5)
	spawn_marker.rotation = Vector3(0, 0.785, 0) # 45 deg
	spawn_marker.set_meta("camera_fov", 75.0)
	scene_root.add_child(spawn_marker)

	# 1c. Walkable Mesh Navigation Surface (invisible navigation quad)
	var walkable_mesh_inst := MeshInstance3D.new()
	walkable_mesh_inst.name = "Walkable_DungeonPath"
	var am := ArrayMesh.new()
	var arrs: Array = []
	arrs.resize(Mesh.ARRAY_MAX)
	arrs[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-2, 0, -2), Vector3(2, 0, -2), Vector3(2, 0, 2),
		Vector3(-2, 0, -2), Vector3(2, 0, 2),  Vector3(-2, 0, 2)
	])
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrs)
	walkable_mesh_inst.mesh = am
	scene_root.add_child(walkable_mesh_inst)

	# 1d. Cutscene / Event Trigger Area (Area3D)
	var trigger_node := Area3D.new()
	trigger_node.name = "Trigger_VaultDoor"
	trigger_node.position = Vector3(0.0, 1.0, -3.0)
	trigger_node.set_meta("event", "open_vault_cutscene")
	trigger_node.set_meta("dialogue_id", "vault_lore_01")
	trigger_node.set_meta("oneshot", true)
	scene_root.add_child(trigger_node)

	# 1e. Particle Emitter (GPUParticles3D: the standard "emitters" lump)
	var emitter_node := GPUParticles3D.new()
	emitter_node.name = "Emitter_CampfireSparks"
	emitter_node.position = Vector3(2.0, 0.5, -1.0)
	emitter_node.amount = 45
	emitter_node.lifetime = 2.0
	var emitter_pm := ParticleProcessMaterial.new()
	emitter_pm.direction = Vector3(0.0, 3.0, 0.0)
	emitter_pm.spread = 25.0
	emitter_pm.initial_velocity_min = 1.0
	emitter_pm.initial_velocity_max = 2.0
	emitter_node.process_material = emitter_pm
	var emitter_quad := QuadMesh.new()
	emitter_quad.size = Vector2(0.4, 0.4)
	emitter_node.draw_pass_1 = emitter_quad
	scene_root.add_child(emitter_node)

	# 1f. Physics Rigid Bodies (Ball Pit container)
	var ball_pit_node := Node3D.new()
	ball_pit_node.name = "BallPit_Arena"
	ball_pit_node.position = Vector3(0.0, 0.0, 0.0)
	ball_pit_node.set_meta("count", 24)
	ball_pit_node.set_meta("radius", 0.25)
	ball_pit_node.set_meta("mass", 1.5)
	ball_pit_node.set_meta("restitution", 0.85)
	scene_root.add_child(ball_pit_node)

	# 1g. Arbitrary Custom Metadata Entity (Dialogue NPC)
	var npc_marker := Marker3D.new()
	npc_marker.name = "NPC_Elder"
	npc_marker.position = Vector3(-1.5, 1.0, 0.0)
	npc_marker.set_meta("poi_metadata_tag", "dialogue_npc")
	npc_marker.set_meta("npc_name", "Elder Olaru")
	npc_marker.set_meta("quest_id", 101)
	npc_marker.set_meta("greeting", "Welcome to the Sunken Vault.")
	scene_root.add_child(npc_marker)

	# 2. Export scene tree directly to PBMv2 via Godot plugin
	var settings := PBMapExporter.ExportSettings.new()
	settings.export_mode = PBMapExporter.ExportMode.RETRO
	settings.bake_lighting = false # fast unit test
	settings.bake_textures = false
	var global_pbm := ProjectSettings.globalize_path(TEST_AUTHORED_PBM)
	var err := PBMapExporter.export_retro_pbm(scene_root, global_pbm, settings)
	assert_eq(err, OK, "Exporting custom authored Godot scene to PBM must succeed with OK")
	assert_true(FileAccess.file_exists(TEST_AUTHORED_PBM), "Custom PBM file must exist on disk")

	# 3. Read back PBM binary and verify that all custom entities were dynamically discovered and serialized
	var f := FileAccess.open(TEST_AUTHORED_PBM, FileAccess.READ)
	assert_not_null(f)

	var magic := f.get_32()
	assert_eq(magic, PBMapExporter.PBM_MAGIC, "Magic must be PBM3 (0x334D4250)")

	var version := f.get_32()
	assert_eq(version, PBMapExporter.PBM_VERSION, "Version must be 3")

	var num_textures := f.get_32()
	var num_meshes := f.get_32()
	var num_colliders := f.get_32()
	var num_metadata := f.get_32()
	assert_gt(num_metadata, 0, "Custom metadata entries must be present")

	# Skip spawn and bounds floats
	f.seek(64)

	# Skip textures
	for ti in range(num_textures):
		f.seek(f.get_position() + 32 + 2 + 2 + 2 + 2)
		var dsize := f.get_32()
		f.seek(f.get_position() + dsize)

	# Skip meshes (v3 header = 32 name + 4 tex_id + 4 num_vertices + 6 bounds floats + 2 scroll floats)
	for mi in range(num_meshes):
		f.seek(f.get_position() + 32 + 4)
		var nv := f.get_32()
		f.seek(f.get_position() + 24 + 8 + nv * 24)

	# Skip colliders
	for ci in range(num_colliders):
		f.seek(f.get_position() + 32 + 4 + 24)
		var nt := f.get_32()
		f.seek(f.get_position() + nt * 36)

	# Parse metadata table
	var metadata_lumps: Dictionary = {}
	for mi in range(num_metadata):
		var tag := f.get_buffer(32).get_string_from_ascii().split("\u0000")[0].strip_edges()
		var mtype := f.get_32()
		var msize := f.get_32()
		var mdata := f.get_buffer(msize)
		var pad := (4 - (msize % 4)) % 4
		if pad > 0: f.seek(f.get_position() + pad)
		metadata_lumps[tag] = { "type": mtype, "size": msize, "data": mdata }
	# 3a. Map Name
	assert_true(metadata_lumps.has("map_name"))
	var loaded_map_name: String = (metadata_lumps["map_name"]["data"] as PackedByteArray).get_string_from_utf8()
	assert_true(loaded_map_name.contains("The Sunken Vault"), "Map name must match authored metadata")

	# 3b. Player Spawn
	assert_true(metadata_lumps.has("player_spawn"))
	var spawn_json = JSON.parse_string(metadata_lumps["player_spawn"]["data"].get_string_from_utf8())
	assert_true(spawn_json is Dictionary)
	assert_almost_eq(spawn_json["position"][0], 1.5, 0.01)
	assert_almost_eq(spawn_json["position"][1], 2.0, 0.01)
	assert_almost_eq(spawn_json["position"][2], 3.5, 0.01)
	assert_almost_eq(spawn_json["camera_fov"], 75.0, 0.01)

	# 3c. Walkable Mesh
	assert_true(metadata_lumps.has("walkable_mesh"))
	assert_eq(metadata_lumps["walkable_mesh"]["size"], 72, "Walkable mesh must contain 2 triangles (72 bytes)")

	# 3d. Triggers
	assert_true(metadata_lumps.has("triggers"))
	var triggers_arr = JSON.parse_string(metadata_lumps["triggers"]["data"].get_string_from_utf8())
	assert_true(triggers_arr is Array and triggers_arr.size() >= 1)
	var trig_dict: Dictionary = triggers_arr[0]
	assert_eq(trig_dict["id"], "Trigger_VaultDoor")
	assert_eq(trig_dict["event"], "open_vault_cutscene")
	assert_eq(trig_dict["dialogue_id"], "vault_lore_01")
	assert_eq(trig_dict["oneshot"], true)

	# 3e. Particle Emitter: the standard binary lump, not a JSON recipe.
	assert_true(metadata_lumps.has("emitters"))
	assert_eq(metadata_lumps["emitters"]["type"], PBMapExporter.PBM_META_EMITTER)
	var em_bytes: PackedByteArray = metadata_lumps["emitters"]["data"]
	assert_eq(em_bytes.decode_u32(0), 0x54494D45, "The lump must start with the EMIT magic")
	assert_eq(em_bytes.decode_u32(8), 1, "One authored emitter")
	var em_base := 16
	assert_eq(em_bytes.slice(em_base, em_base + 22).get_string_from_ascii(), "Emitter_CampfireSparks")
	assert_almost_eq(em_bytes.decode_float(em_base + 0x18), 2.0, 0.01, "Position X comes from the node")
	assert_almost_eq(em_bytes.decode_float(em_base + 0x40), 2.0, 0.01, "Lifetime maps to life_max")
	assert_eq(em_bytes.decode_u16(em_base + 0x98), 45, "`amount` maps to the particle count")
	assert_almost_eq(em_bytes.decode_float(em_base + 0x30), deg_to_rad(25.0), 0.001,
		"Spread crosses over in radians")

	# 3f. Rigid Bodies (Ball Pit)
	assert_true(metadata_lumps.has("rigid_bodies"))
	var pit_dict = JSON.parse_string(metadata_lumps["rigid_bodies"]["data"].get_string_from_utf8())
	assert_eq(pit_dict["count"], 24)
	assert_almost_eq(pit_dict["radius"], 0.25, 0.01)
	assert_almost_eq(pit_dict["mass"], 1.5, 0.01)
	assert_almost_eq(pit_dict["restitution"], 0.85, 0.01)

	# 3g. Arbitrary Custom Node Metadata Tag (Dialogue NPC)
	assert_true(metadata_lumps.has("dialogue_npc"), "Custom metadata lump 'dialogue_npc' must be extracted")
	var npc_dict = JSON.parse_string(metadata_lumps["dialogue_npc"]["data"].get_string_from_utf8())
	assert_eq(npc_dict["name"], "NPC_Elder")
	assert_eq(npc_dict["npc_name"], "Elder Olaru")
	assert_eq(npc_dict["quest_id"], 101)
	assert_true(npc_dict["greeting"].contains("Sunken Vault"))

	f.close()
