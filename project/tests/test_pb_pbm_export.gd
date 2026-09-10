## Unit tests for PBPbmConverter & PBMv2 format validation
extends GutTest

const TEST_GLB_PATH := "res://exports/showcase_retro_baked.glb"
const TEST_PBM_PATH := "res://exports/test_gdscript_export.pbm"

func before_all() -> void:
	if FileAccess.file_exists(TEST_PBM_PATH):
		DirAccess.remove_absolute(TEST_PBM_PATH)

func after_all() -> void:
	if FileAccess.file_exists(TEST_PBM_PATH):
		DirAccess.remove_absolute(TEST_PBM_PATH)

func test_gdscript_pbm_export_against_oracle() -> void:
	if not FileAccess.file_exists(TEST_GLB_PATH):
		pass_test("Skipping test: showcase_retro_baked.glb not found.")
		return

	# Run GDScript converter
	var global_glb := ProjectSettings.globalize_path(TEST_GLB_PATH)
	var global_pbm := ProjectSettings.globalize_path(TEST_PBM_PATH)
	var err := PBPbmConverter.convert_glb_to_pbm(global_glb, global_pbm, true)
	assert_eq(err, OK, "PBPbmConverter must return OK")
	assert_true(FileAccess.file_exists(TEST_PBM_PATH), "PBM file must exist on disk")

	# Read binary and validate structure against Python oracle
	var f := FileAccess.open(TEST_PBM_PATH, FileAccess.READ)
	assert_not_null(f, "PBM file must be readable")

	var magic := f.get_32()
	assert_eq(magic, PBPbmConverter.PBM_MAGIC, "Magic must be PBM3 (0x334D4250)")

	var version := f.get_32()
	assert_eq(version, PBPbmConverter.PBM_VERSION, "Version must be 3")

	var num_textures := f.get_32()
	# Texture COUNT is not asserted exactly: how many images the glTF writer
	# embeds depends on Godot's resource cache (a texture loaded as a file-backed
	# resource is named after the file, an in-memory one after its material), so
	# the total drifts by one or two between sessions. What the format contract
	# actually pins is asserted below: formats, alpha modes, and that scrolling
	# meshes never reference an atlas.
	assert_gte(num_textures, 12, "Texture table must be present")

	var num_meshes := f.get_32()
	assert_eq(num_meshes, 24, "Mesh count must match Oracle (24 chunks)")
	var num_colliders := f.get_32()
	assert_eq(num_colliders, 9, "Collider count must match Oracle (9 colliders)")

	var num_metadata := f.get_32()
	assert_eq(num_metadata, 7, "Metadata count must be 7 (map_name, spawn, walkable, triggers, particles, rigid_bodies, entities)")
	var spawn_x := f.get_float()
	var spawn_y := f.get_float()
	var spawn_z := f.get_float()
	assert_almost_eq(spawn_x, 0.0, 0.01)
	assert_almost_eq(spawn_y, 1.6, 0.01)
	assert_almost_eq(spawn_z, 4.2, 0.01)
	var spawn_rot := f.get_float()

	var bmin_x := f.get_float(); var bmin_y := f.get_float(); var bmin_z := f.get_float()
	var bmax_x := f.get_float(); var bmax_y := f.get_float(); var bmax_z := f.get_float()
	assert_lt(bmin_x, bmax_x)

	# 1. Walk the texture table. Two things the format contract pins here:
	#    - a scrolling mesh must not reference a tile atlas (an offset would
	#      drag its tile across the atlas slot),
	#    - a blended (soft alpha) texture must travel as RGBA8888, because the
	#      5551 format has one alpha bit and can only cut a texel out.
	var atlas_ids: Dictionary = {}
	var tex_names: Dictionary = {}
	var tex_alpha_modes: Dictionary = {}
	var tex_formats: Dictionary = {}
	for ti in range(num_textures):
		var tex_name_bytes := f.get_buffer(32)
		var tex_name := tex_name_bytes.get_string_from_ascii().split("\u0000")[0]
		tex_names[ti] = tex_name
		if tex_name.begins_with("TileAtlas"):
			atlas_ids[ti] = true
		var w := f.get_16()
		var h := f.get_16()
		var fmt := f.get_16()
		var alpha_mode := f.get_16()
		var data_size := f.get_32()
		tex_alpha_modes[tex_name] = alpha_mode
		tex_formats[tex_name] = fmt
		assert_gt(w, 0)
		assert_gt(h, 0)
		var bytes_per_pixel := 4 if fmt == PBPbmConverter.PBM_TEX_FMT_RGBA8888 else 2
		assert_eq(data_size, w * h * bytes_per_pixel,
			"Texture data size must match its pixel format (texture '%s')" % tex_name)
		if alpha_mode == PBPbmConverter.PBM_ALPHA_BLEND:
			assert_eq(fmt, PBPbmConverter.PBM_TEX_FMT_RGBA8888,
				"A blended texture needs the 8-bit alpha of RGBA8888 (texture '%s')" % tex_name)
		f.seek(f.get_position() + data_size)

	# 2. Skip meshes & count vertices.
	# v3 mesh header: 32 name + 4 tex_id + 4 num_vertices + 6 bounds floats + 2 UV-scroll floats.
	var total_verts := 0
	var scrolling_meshes := 0
	var scroll_speeds: Array[Vector2] = []
	for mi in range(num_meshes):
		var mesh_name_bytes := f.get_buffer(32)
		var tex_id := f.get_32()
		var n_verts := f.get_32()
		total_verts += n_verts
		var mbmin_x := f.get_float(); var mbmin_y := f.get_float(); var mbmin_z := f.get_float()
		var mbmax_x := f.get_float(); var mbmax_y := f.get_float(); var mbmax_z := f.get_float()
		var scroll_u := f.get_float()
		var scroll_v := f.get_float()
		if scroll_u != 0.0 or scroll_v != 0.0:
			scrolling_meshes += 1
			scroll_speeds.append(Vector2(snappedf(scroll_u, 0.001), snappedf(scroll_v, 0.001)))
			assert_false(atlas_ids.has(tex_id),
				"Scrolling mesh %s must reference a standalone texture, not an atlas"
					% mesh_name_bytes.get_string_from_ascii().split("\u0000")[0])
		assert_lte(n_verts, 384, "Each spatial mesh chunk must be <= 384 vertices")
		f.seek(f.get_position() + n_verts * 24)

	assert_eq(total_verts, 4290, "Total vertex count must exactly match Oracle (4290 vertices)")

	# The waterfall demo's five surfaces must come through as scrolling meshes,
	# at the speeds authored in the Godot scene. The sign is a direction, and
	# with the reference implementation (§5.1 of the format spec) NEGATIVE V
	# travels down a wall and away from a wall on the floor — which is why the
	# falling sheet, the pool and the churn are all negative, and only the
	# billboard spray (whose own V runs down its face) is positive.
	# Compared as a set: the texture an exporter names an embedded image after
	# is not stable across sessions, the physics is.
	assert_eq(scrolling_meshes, 5, "The showcase waterfall must export 5 scrolling meshes")
	var expected_speeds: Array[Vector2] = [
		Vector2(0.04, -0.75),   # sheet: falls down the wall
		Vector2(0.0, -1.15),    # core: falls faster (parallax)
		Vector2(0.02, -0.03),   # pool: drifts away from the wall
		Vector2(0.0, -0.3),     # foam: spreads away from the impact point
		Vector2(0.0, 0.35),     # spray: climbs off the impact point
	]
	assert_eq(scroll_speeds.size(), expected_speeds.size())
	for want in expected_speeds:
		var found: bool = false
		for got in scroll_speeds:
			if got.is_equal_approx(want):
				found = true
				break
		assert_true(found, "Expected a scrolling mesh at %s, exported set is %s"
			% [str(want), str(scroll_speeds)])

	# Alpha modes are a per-texture contract: every BLEND texture must carry the
	# 8-bit alpha RGBA8888 provides (asserted in the texture loop above), and the
	# scene must contain the three blended water surfaces and the hard-edged
	# cutouts — counted, not named, for the reason given with num_textures.
	var blend_count := 0
	var cutout_count := 0
	for name in tex_alpha_modes:
		if tex_alpha_modes[name] == PBPbmConverter.PBM_ALPHA_BLEND:
			blend_count += 1
		elif tex_alpha_modes[name] == PBPbmConverter.PBM_ALPHA_CUTOUT:
			cutout_count += 1
	assert_eq(blend_count, 3, "Sheet, core and spray must export as soft-alpha blends")
	assert_gte(cutout_count, 3, "The foliage billboards must export as cutouts")

	# 3. Skip colliders
	for ci in range(num_colliders):
		var col_name_bytes := f.get_buffer(32)
		var ctype := f.get_32()
		var cbmin_x := f.get_float(); var cbmin_y := f.get_float(); var cbmin_z := f.get_float()
		var cbmax_x := f.get_float(); var cbmax_y := f.get_float(); var cbmax_z := f.get_float()
		var num_tris := f.get_32()
		f.seek(f.get_position() + num_tris * 36)

	# 4. Read metadata table (7 entries)
	var meta_tags: Dictionary = {}
	for mi in range(num_metadata):
		var tag := f.get_buffer(32).get_string_from_ascii().strip_edges()
		var mtype := f.get_32()
		var msize := f.get_32()
		var mdata := f.get_buffer(msize)
		var pad := (4 - (msize % 4)) % 4
		if pad > 0: f.seek(f.get_position() + pad)
		meta_tags[tag] = { "type": mtype, "size": msize, "data": mdata }

	# Verify map_name
	assert_true(meta_tags.has("map_name"))
	assert_eq(meta_tags["map_name"]["type"], PBPbmConverter.PBM_META_STRING)
	assert_true(meta_tags["map_name"]["data"].get_string_from_utf8().contains("PoiRetro Courtyard Showcase"))

	# Verify player_spawn
	assert_true(meta_tags.has("player_spawn"))
	assert_eq(meta_tags["player_spawn"]["type"], PBPbmConverter.PBM_META_JSON)
	var spawn_json = JSON.parse_string(meta_tags["player_spawn"]["data"].get_string_from_utf8())
	assert_true(spawn_json is Dictionary and spawn_json.has("position"))

	# Verify walkable_mesh
	assert_true(meta_tags.has("walkable_mesh"))
	assert_eq(meta_tags["walkable_mesh"]["size"], 72, "Walkable mesh must be 72 bytes (2 triangles * 36 bytes)")

	# Verify triggers
	assert_true(meta_tags.has("triggers"))
	var triggers_json = JSON.parse_string(meta_tags["triggers"]["data"].get_string_from_utf8())
	assert_true(triggers_json is Array and triggers_json.size() >= 1)

	# Verify particle_emitters
	assert_true(meta_tags.has("particle_emitters"))
	var particles_json = JSON.parse_string(meta_tags["particle_emitters"]["data"].get_string_from_utf8())
	assert_true(particles_json is Array and particles_json.size() >= 1)

	# Verify rigid_bodies (ball pit)
	assert_true(meta_tags.has("rigid_bodies"))
	var rigid_json = JSON.parse_string(meta_tags["rigid_bodies"]["data"].get_string_from_utf8())
	assert_true(rigid_json is Dictionary and rigid_json.get("type") == "ball_pit")

	# Verify entities (PatrolSphere)
	assert_true(meta_tags.has("entities"))
	assert_eq(meta_tags["entities"]["type"], PBPbmConverter.PBM_META_ENTITY)
	assert_eq(meta_tags["entities"]["size"], 88)
	var ent_data: PackedByteArray = meta_tags["entities"]["data"]
	assert_eq(ent_data.decode_u32(32), PBPbmConverter.PBM_ENTITY_PATROL_SPHERE)
	assert_almost_eq(ent_data.decode_float(36), 0.35, 0.01)
	assert_eq(ent_data.decode_u32(40), 0xFF00C8FF)
	assert_almost_eq(ent_data.decode_float(44), 2.5, 0.01)
	assert_eq(ent_data.decode_u32(48), 3)
	f.close()
