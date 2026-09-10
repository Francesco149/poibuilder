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
	assert_eq(magic, PBPbmConverter.PBM_MAGIC, "Magic must be PBM2 (0x324D4250)")

	var version := f.get_32()
	assert_eq(version, PBPbmConverter.PBM_VERSION, "Version must be 2")

	var num_textures := f.get_32()
	assert_eq(num_textures, 12, "Texture count must match Oracle (12 textures: 8 base + 4 atlases)")

	var num_meshes := f.get_32()
	assert_eq(num_meshes, 18, "Mesh count must match Oracle (18 chunks)")

	var num_colliders := f.get_32()
	assert_eq(num_colliders, 8, "Collider count must match Oracle (8 colliders)")

	var num_metadata := f.get_32()
	assert_eq(num_metadata, 2, "Metadata count must be 2 (map_name + entities)")

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

	# 1. Skip textures
	for ti in range(num_textures):
		var tex_name_bytes := f.get_buffer(32)
		var w := f.get_16()
		var h := f.get_16()
		var fmt := f.get_16()
		var has_alpha := f.get_16()
		var data_size := f.get_32()
		assert_gt(w, 0)
		assert_gt(h, 0)
		assert_eq(data_size, w * h * 2, "RGBA5551 data size must be width * height * 2")
		f.seek(f.get_position() + data_size)

	# 2. Skip meshes & count vertices
	var total_verts := 0
	for mi in range(num_meshes):
		var mesh_name_bytes := f.get_buffer(32)
		var tex_id := f.get_32()
		var n_verts := f.get_32()
		total_verts += n_verts
		var mbmin_x := f.get_float(); var mbmin_y := f.get_float(); var mbmin_z := f.get_float()
		var mbmax_x := f.get_float(); var mbmax_y := f.get_float(); var mbmax_z := f.get_float()
		assert_lte(n_verts, 384, "Each spatial mesh chunk must be <= 384 vertices")
		f.seek(f.get_position() + n_verts * 24)

	assert_eq(total_verts, 3840, "Total vertex count must exactly match Oracle (3840 vertices)")

	# 3. Skip colliders
	for ci in range(num_colliders):
		var col_name_bytes := f.get_buffer(32)
		var ctype := f.get_32()
		var cbmin_x := f.get_float(); var cbmin_y := f.get_float(); var cbmin_z := f.get_float()
		var cbmax_x := f.get_float(); var cbmax_y := f.get_float(); var cbmax_z := f.get_float()
		var num_tris := f.get_32()
		f.seek(f.get_position() + num_tris * 36)

	# 4. Read metadata
	# Entry 0: map_name
	var tag0 := f.get_buffer(32).get_string_from_ascii()
	var type0 := f.get_32()
	var size0 := f.get_32()
	assert_true(tag0.begins_with("map_name"), "First metadata tag must be 'map_name'")
	assert_eq(type0, PBPbmConverter.PBM_META_STRING, "map_name type must be STRING (1)")
	var map_name_str := f.get_buffer(size0).get_string_from_utf8()
	assert_true(map_name_str.contains("PoiRetro Courtyard Showcase"), "Map name must match showcase")
	var pad0 := (4 - (size0 % 4)) % 4
	if pad0 > 0: f.seek(f.get_position() + pad0)

	# Entry 1: entities (PatrolSphere)
	var tag1 := f.get_buffer(32).get_string_from_ascii()
	var type1 := f.get_32()
	var size1 := f.get_32()
	assert_true(tag1.begins_with("entities"), "Second metadata tag must be 'entities'")
	assert_eq(type1, PBPbmConverter.PBM_META_ENTITY, "entities type must be ENTITY (3)")
	assert_eq(size1, 88, "PatrolSphere entity binary payload must be 88 bytes")

	var ent_data := f.get_buffer(size1)
	var ent_name := ent_data.slice(0, 32).get_string_from_ascii()
	assert_true(ent_name.begins_with("PatrolSphere"), "Entity name must be PatrolSphere")
	var ent_type := ent_data.decode_u32(32)
	assert_eq(ent_type, PBPbmConverter.PBM_ENTITY_PATROL_SPHERE)
	var ent_radius := ent_data.decode_float(36)
	assert_almost_eq(ent_radius, 0.35, 0.01)
	var ent_color := ent_data.decode_u32(40)
	assert_eq(ent_color, 0xFF00C8FF, "Color must be gold (0xFF00C8FF)")
	var ent_speed := ent_data.decode_float(44)
	assert_almost_eq(ent_speed, 2.5, 0.01)
	var num_pts := ent_data.decode_u32(48)
	assert_eq(num_pts, 3, "Entity must have 3 waypoints")

	f.close()
