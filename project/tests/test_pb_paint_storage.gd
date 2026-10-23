## test_pb_paint_storage.gd — the memory/storage contracts of painted meshes
## (v0.9.182 scaling audit).
##
## Painting used to scale with the TOTAL paint on a mesh rather than with the
## paint a stroke touched: every undo snapshot made GPU textures for every
## mask of the mesh, and the CPU image cache kept every snapshot's pixels for
## the life of the editor. These tests pin the contracts that replaced that:
##   - undo snapshots are COLD (pixels in the CPU cache, no GPU textures) and
##     restore to LIVE materials with the snapshot's pixels;
##   - snapshots are copy-on-write and independent of later painting;
##   - the image cache forgets materials that no longer exist.
extends GutTest

## A cube whose top face carries a splat material with one painted layer
## (and optionally a decal window). Returns {mesh, data, face, mat, layer}.
func _painted_cube(with_decal: bool = false) -> Dictionary:
	var mesh := PBMesh.create_cube(2.0)
	add_child_autofree(mesh)
	var data := mesh.pb_mesh_data
	PBSplat.ensure_mesh_splat_uv(data)
	var top := -1
	for fi in range(data.faces.size()):
		if PBMath.normal_from_positions(data.positions, data.faces[fi].get_indexes()).y > 0.99:
			top = fi
	assert_gt(top, -1, "fixture: cube has a top face")
	var face := data.faces[top]
	var mat := PBSplat.ensure_face_owned_material(data, face)
	var tex := ImageTexture.create_from_image(Image.create(8, 8, false, Image.FORMAT_RGBA8))
	var layer := PBSplat.ensure_layer_for_texture(mat, tex, PBSplat.live_mask_resolution_for(data, face).x)
	PBSplat.paint_face_splat(data, face, mat, layer, Vector3(0.0, 1.0, 0.0), 0.5, 0.0, 1.0)
	if with_decal:
		PBSplat.ensure_decal_window(mat, Rect2(0.4, 0.4, 0.2, 0.2), Vector2(2.0, 2.0))
		PBSplat.get_decal_layer_image(mat).fill(Color(1, 0, 0, 1))
	return {"mesh": mesh, "data": data, "face": face, "mat": mat, "layer": layer}

func _mask_checksum(img: Image) -> int:
	var sum := 0
	for b in img.get_data():
		sum += b
	return sum

# ── Cold snapshots ──────────────────────────────────────────────────────────

func test_undo_snapshot_holds_pixels_but_no_gpu_textures() -> void:
	var f := _painted_cube(true)
	var data: PBMeshData = f["data"]
	var snap := PBCommand.copy_mesh_data(data)
	var snap_mat := snap.get_face_material(snap.faces[data.faces.find(f["face"])]) as ShaderMaterial
	assert_true(PBSplat.is_splat_material(snap_mat))
	assert_ne(snap_mat, f["mat"], "the snapshot owns its own material")
	var layer: int = f["layer"]
	assert_null(snap_mat.get_shader_parameter("layer_%d_mask" % layer),
			"a snapshot creates no GPU mask texture")
	assert_null(snap_mat.get_shader_parameter("stamp_layer_texture"),
			"a snapshot creates no GPU decal texture")
	var live_mask := PBSplat.get_layer_mask_image(f["mat"], layer)
	var snap_mask := PBSplat.get_layer_mask_image(snap_mat, layer)
	assert_not_null(snap_mask, "the snapshot's pixels are reachable through the cache")
	assert_eq(_mask_checksum(snap_mask), _mask_checksum(live_mask))
	assert_gt(_mask_checksum(snap_mask), 0, "fixture: the mask is painted")
	assert_true(PBSplat.has_decal_layer(snap_mat))
	assert_eq(PBSplat.get_decal_window(snap_mat), PBSplat.get_decal_window(f["mat"]),
			"the decal window mapping travels with the snapshot")

func test_restoring_a_cold_snapshot_makes_live_textures_with_its_pixels() -> void:
	var f := _painted_cube(true)
	var data: PBMeshData = f["data"]
	var layer: int = f["layer"]
	var face_idx := data.faces.find(f["face"])
	var before := _mask_checksum(PBSplat.get_layer_mask_image(f["mat"], layer))
	var snap := PBCommand.copy_mesh_data(data)
	# Paint more after the snapshot: the snapshot must not see it (COW).
	PBSplat.paint_face_splat(data, f["face"], f["mat"], layer, Vector3(0.6, 1.0, 0.6), 0.4, 0.0, 1.0)
	assert_ne(_mask_checksum(PBSplat.get_layer_mask_image(f["mat"], layer)), before,
			"fixture: the second dab changed the live mask")
	var snap_mat := snap.get_face_material(snap.faces[face_idx]) as ShaderMaterial
	assert_eq(_mask_checksum(PBSplat.get_layer_mask_image(snap_mat, layer)), before,
			"painting after the snapshot leaves the snapshot untouched")
	PBCommand.restore_mesh_data(data, snap)
	var restored := data.get_face_material(data.faces[face_idx]) as ShaderMaterial
	var tex = restored.get_shader_parameter("layer_%d_mask" % layer)
	assert_true(tex is ImageTexture, "a restored material is LIVE again (GPU mask texture)")
	assert_true(restored.get_shader_parameter("stamp_layer_texture") is ImageTexture,
			"and its decal texture")
	assert_eq(_mask_checksum(PBSplat.get_layer_mask_image(restored, layer)), before,
			"restore brings back the snapshot's pixels")

func test_live_copy_is_renderable() -> void:
	var f := _painted_cube()
	var copy := PBCommand.copy_mesh_data_live(f["data"])
	var mat := copy.get_face_material(copy.faces[(f["data"] as PBMeshData).faces.find(f["face"])]) as ShaderMaterial
	assert_true(mat.get_shader_parameter("layer_%d_mask" % int(f["layer"])) is ImageTexture,
			"copy_mesh_data_live is for copies that are rendered as-is")

func test_snapshot_shape_params_do_not_share_nested_containers() -> void:
	var data := PBMeshData.create_cube(1.0)
	data.shape_params = {"paths": [{"points": PackedVector3Array([Vector3.ZERO])}]}
	var snap := PBCommand.copy_mesh_data(data)
	(data.shape_params["paths"] as Array).append({"points": PackedVector3Array()})
	assert_eq((snap.shape_params["paths"] as Array).size(), 1,
			"mutating the live params' nested array must not reach the snapshot")

func test_preview_texture_reads_a_cold_snapshot() -> void:
	var f := _painted_cube()
	var snap := PBCommand.copy_mesh_data(f["data"])
	var snap_mat := snap.get_face_material(snap.faces[(f["data"] as PBMeshData).faces.find(f["face"])])
	var live_prev := PBSplat.build_preview_texture(f["mat"], 32).get_image()
	var snap_prev := PBSplat.build_preview_texture(snap_mat, 32).get_image()
	assert_eq(hash(snap_prev.get_data()), hash(live_prev.get_data()),
			"the UV-editor composite is the same for a live material and its cold snapshot")

# ── The CPU image cache forgets dead materials ──────────────────────────────

func test_image_cache_drops_freed_materials() -> void:
	PBSplat.prune_image_cache()
	var start := PBSplat._cpu_image_cache.size()
	var mats: Array = []
	for i in range(10):
		var m := PBSplat.create_splat_material()
		PBSplat.add_layer(m, null, Color.WHITE, 0.8, 16)
		mats.append(m)
	assert_eq(PBSplat._cpu_image_cache.size(), start + 10, "fixture: ten cached materials")
	mats.clear()  # the last references go: the materials are freed
	var dropped := PBSplat.prune_image_cache()
	assert_eq(dropped, 10, "every freed material's images are dropped")
	assert_eq(PBSplat._cpu_image_cache.size(), start)

func test_image_cache_prunes_itself_while_snapshots_churn() -> void:
	var f := _painted_cube(true)
	PBSplat.prune_image_cache()
	var start := PBSplat._cpu_image_cache.size()
	# A long editing session: many strokes' worth of snapshots, each dropped
	# when its undo step falls away.
	for i in range(PBSplat.CACHE_PRUNE_INTERVAL * 3):
		var snap := PBCommand.copy_mesh_data(f["data"])
		snap = null
	assert_lt(PBSplat._cpu_image_cache.size(), start + PBSplat.CACHE_PRUNE_INTERVAL + 1,
			"dead snapshots never pile up past one prune interval")

# ── Privatising a shared splat material ─────────────────────────────────────

func test_owned_material_copy_keeps_pixels_and_decal_window() -> void:
	var f := _painted_cube(true)
	var data: PBMeshData = f["data"]
	var other := data.faces[(data.faces.find(f["face"]) + 1) % data.faces.size()]
	data.set_face_material(other, f["mat"])  # now shared by two faces
	var owned := PBSplat.ensure_face_owned_material(data, other)
	assert_ne(owned, f["mat"], "the second face gets a private copy")
	var layer: int = f["layer"]
	assert_eq(_mask_checksum(PBSplat.get_layer_mask_image(owned, layer)),
			_mask_checksum(PBSplat.get_layer_mask_image(f["mat"], layer)), "with the same pixels")
	assert_eq(PBSplat.get_decal_window(owned), PBSplat.get_decal_window(f["mat"]),
			"and the decal window mapping")
	assert_true(owned.get_shader_parameter("layer_%d_mask" % layer) is ImageTexture,
			"a privatised material is live")

# ── Compressed storage (PBMaskTexture) ──────────────────────────────────────

const SAVE_DIR := "user://pb_storage_tests"

func _save_and_reload(node: Node, file_name: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	var path := SAVE_DIR.path_join(file_name)
	var packed := PackedScene.new()
	assert_eq(packed.pack(node), OK, "fixture: the scene packs")
	assert_eq(ResourceSaver.save(packed, path), OK, "fixture: the scene saves")
	var text := FileAccess.get_file_as_string(path)
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var inst := loaded.instantiate()
	add_child_autofree(inst)
	return {"text": text, "size": text.length(), "root": inst}

func _painted_floor(segs: int) -> PBMesh:
	var mesh := PBMesh.new()
	mesh.name = "PaintedFloor"
	add_child_autofree(mesh)
	var data := PBShapeGenerators.create_plane(float(segs) * 2.0, float(segs) * 2.0, segs, segs)
	mesh.pb_mesh_data = data
	# A placeholder layer albedo: the only raw images in the file must be ones
	# the test did not make (none).
	var tex := PlaceholderTexture2D.new()
	for face in data.faces:
		var mat := PBSplat.ensure_face_owned_material(data, face)
		PBSplat.ensure_face_splat_bounds(data, face)
		var layer := PBSplat.ensure_layer_for_texture(mat, tex, PBSplat.live_mask_resolution_for(data, face).x)
		PBSplat.paint_face_splat(data, face, mat, layer,
				PBMath.average(data.positions, face.get_distinct_indexes()), 0.6, 0.5, 1.0)
	PBSplat.sync_mesh_mask_textures(data)  # headless: textures from the CPU cache
	mesh.rebuild()
	return mesh

func test_masks_save_compressed_and_reload_pixel_exact() -> void:
	var mesh := _painted_floor(2)
	var data := mesh.pb_mesh_data
	var before: Array = []
	for f in data.faces:
		var m := data.get_face_material(f) as ShaderMaterial
		assert_true(m.get_shader_parameter("layer_1_mask") is PBMaskTexture, "masks are PBMaskTextures")
		before.append(hash(PBSplat.get_layer_mask_image(m, 1).get_data()))
	var out := _save_and_reload(mesh, "masks_roundtrip.tscn")
	assert_false((out["text"] as String).contains('type="Image"'), "no raw Image sub-resources in the file")
	assert_true((out["text"] as String).contains("packed = {"), "the masks are stored packed")
	var reloaded := (out["root"] as PBMesh).pb_mesh_data
	for i in range(reloaded.faces.size()):
		var m := reloaded.get_face_material(reloaded.faces[i]) as ShaderMaterial
		assert_eq(hash(PBSplat.get_layer_mask_image(m, 1).get_data()), before[i], "face %d's mask survives the round trip" % i)

## The budget that catches a storage regression: each painted face cost ~87 KB
## of raw mask in a .tscn (86.6 MB for 400 faces with two layers). Packed, a
## soft 0.6 m dab on a 2 m face is ~8 KB of mask; with the face's material
## and geometry ~10.5 KB in all.
func test_a_painted_floor_stays_inside_its_scene_budget() -> void:
	var mesh := _painted_floor(10)
	var out := _save_and_reload(mesh, "floor_budget.tscn")
	var per_face_kb := float(out["size"]) / 1024.0 / 100.0
	assert_lt(per_face_kb, 16.0, "%.1f KB per painted face (raw masks were ~87 KB)" % per_face_kb)

func test_old_scenes_plain_masks_convert_before_a_save() -> void:
	var f := _painted_cube(true)
	var mat: ShaderMaterial = f["mat"]
	var layer: int = f["layer"]
	# What a v0.9.181-and-older scene loads as: plain ImageTextures.
	var mask_hash := hash(PBSplat.get_layer_mask_image(mat, layer).get_data())
	mat.set_shader_parameter("layer_%d_mask" % layer, ImageTexture.create_from_image(PBSplat.get_layer_mask_image(mat, layer)))
	mat.set_shader_parameter("stamp_layer_texture", ImageTexture.create_from_image(PBSplat.get_decal_layer_image(mat)))
	assert_eq(PBSplat.adopt_compressed_storage(mat), 2, "mask and decal convert")
	assert_true(mat.get_shader_parameter("layer_%d_mask" % layer) is PBMaskTexture)
	assert_true(mat.get_shader_parameter("stamp_layer_texture") is PBMaskTexture)
	assert_eq(hash(PBSplat.get_layer_mask_image(mat, layer).get_data()), mask_hash, "same pixels")
	assert_eq(PBSplat.adopt_compressed_storage(mat), 0, "already converted: nothing to do")

func test_a_plain_image_texture_scene_still_loads_and_paints() -> void:
	# The v0.9.167 release's format: masks are plain ImageTextures.
	var f := _painted_cube()
	var mesh: PBMesh = f["mesh"]
	var mat: ShaderMaterial = f["mat"]
	var layer: int = f["layer"]
	mat.set_shader_parameter("layer_%d_mask" % layer, ImageTexture.create_from_image(PBSplat.get_layer_mask_image(mat, layer)))
	var out := _save_and_reload(mesh, "release_format.tscn")
	assert_true((out["text"] as String).contains('type="Image"'), "fixture: saved in the old raw form")
	var data := (out["root"] as PBMesh).pb_mesh_data
	var top := -1
	for fi in range(data.faces.size()):
		if PBSplat.is_splat_material(data.get_face_material(data.faces[fi])):
			top = fi
	var m2 := data.get_face_material(data.faces[top]) as ShaderMaterial
	var before := PBSplat.get_layer_mask_image(m2, layer).get_data()
	var painted := 0
	for b in before:
		if b > 0:
			painted += 1
	assert_gt(painted, 0, "the old-format paint is there after loading")
	assert_true(PBSplat.paint_face_splat(data, data.faces[top], m2, layer, Vector3(-0.6, 1.0, -0.6), 0.3, 0.0, 1.0),
			"and it paints")
