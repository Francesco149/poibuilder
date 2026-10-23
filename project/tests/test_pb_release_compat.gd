## test_pb_release_compat.gd — maps made on the PUBLIC RELEASE keep working.
##
## The next release must load maps saved by the current public one (the
## `nightly` release, v0.9.167 = de492fe, which the Asset Library mirrors).
## tests/fixtures/release_v0_9_167 holds a scene that release WROTE with its
## own code, and the values that release read back from it; this suite loads
## it with the current code and requires the same answers — then renders,
## paints, saves (in the new compressed form) and undoes on top of it.
extends GutTest

const FIXTURE_DIR := "res://tests/fixtures/release_v0_9_167"
var _expect: Dictionary = {}

func before_all() -> void:
	var text := FileAccess.get_file_as_string(FIXTURE_DIR.path_join("release_fixture.json"))
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary:
		_expect = parsed

func _load_fixture() -> Node:
	var path := FIXTURE_DIR.path_join("release_fixture.scn")
	if _expect.is_empty() or not ResourceLoader.exists(path):
		fail_test("the release fixture is missing (%s) — see its README" % FIXTURE_DIR)
		return null
	var scene := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var root := scene.instantiate()
	add_child_autofree(root)
	return root

func _mesh(root: Node, mesh_name: String) -> PBMesh:
	return root.find_child(mesh_name, true, false) as PBMesh

func _nonzero(img: Image, channel_alpha: bool) -> int:
	var n := 0
	var data := img.get_data()
	if channel_alpha:
		for i in range(3, data.size(), 4):
			if data[i] > 0:
				n += 1
	else:
		for b in data:
			if b > 0:
				n += 1
	return n

func test_every_mesh_and_face_comes_back() -> void:
	var root := _load_fixture()
	if root == null:
		return
	for mesh_name in _expect["meshes"]:
		var want: Dictionary = _expect["meshes"][mesh_name]
		var pb := _mesh(root, mesh_name)
		assert_not_null(pb, "%s loads as a PBMesh" % mesh_name)
		if pb == null:
			continue
		var md := pb.pb_mesh_data
		assert_eq(md.positions.size(), int(want["positions"]), "%s positions" % mesh_name)
		assert_eq(md.faces.size(), (want["faces"] as Array).size(), "%s faces" % mesh_name)
		for fw in want["faces"]:
			var f := md.faces[int(fw["index"])]
			assert_eq(PBSplat.is_splat_material(md.get_face_material(f)), bool(fw["splat"]),
					"%s face %d paint state" % [mesh_name, int(fw["index"])])
			assert_eq(Array(f.splat_bounds), fw["splat_bounds"], "%s face %d mask rect" % [mesh_name, int(fw["index"])])

func test_masks_and_decals_read_back_exactly_what_the_release_wrote() -> void:
	var root := _load_fixture()
	if root == null:
		return
	var checked := 0
	for mesh_name in _expect["meshes"]:
		var md := _mesh(root, mesh_name).pb_mesh_data
		for fw in _expect["meshes"][mesh_name]["faces"]:
			if not bool(fw["splat"]):
				continue
			var sm := md.get_face_material(md.faces[int(fw["index"])]) as ShaderMaterial
			for lw in fw.get("layers", []):
				var img := PBSplat.get_layer_mask_image(sm, int(lw["slot"]))
				assert_eq(img.get_size(), Vector2i(int(lw["w"]), int(lw["h"])), "mask size")
				assert_eq(_nonzero(img, false), int(lw["nonzero"]), "mask coverage")
				assert_eq(hash(img.get_data()), int(lw["hash"]), "mask pixels, byte for byte")
				assert_eq((sm.get_shader_parameter("layer_%d_texture" % int(lw["slot"])) as Texture2D).resource_path,
						lw["texture"], "layer texture")
				checked += 1
			if fw.has("decal"):
				var dw: Dictionary = fw["decal"]
				var dimg := PBSplat.get_decal_layer_image(sm)
				assert_eq(dimg.get_size(), Vector2i(int(dw["w"]), int(dw["h"])), "decal window size")
				assert_eq(hash(dimg.get_data()), int(dw["hash"]), "decal pixels, byte for byte")
				var win := PBSplat.get_decal_window(sm)
				assert_eq([win.position.x, win.position.y, win.size.x, win.size.y], dw["window"], "decal window mapping")
				checked += 1
	assert_gt(checked, 2, "fixture: masks and a decal were checked")

func test_the_release_scene_renders_every_face() -> void:
	var root := _load_fixture()
	if root == null:
		return
	for mesh_name in _expect["meshes"]:
		var pb := _mesh(root, mesh_name)
		var tris := 0
		for m in pb.get_render_meshes():
			for s in range(m.get_surface_count()):
				tris += (m.surface_get_arrays(s)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		assert_eq(tris, pb.pb_mesh_data.index_count() / 3, "%s renders every triangle" % mesh_name)

func test_the_release_scene_paints_saves_and_undoes() -> void:
	var root := _load_fixture()
	if root == null:
		return
	var pb := _mesh(root, "PaintedCube")
	var md := pb.pb_mesh_data
	var fw: Dictionary = {}
	for f in _expect["meshes"]["PaintedCube"]["faces"]:
		if f.has("decal"):
			fw = f
	var face := md.faces[int(fw["index"])]
	var sm := md.get_face_material(face) as ShaderMaterial
	var slot := int(fw["layers"][0]["slot"])
	var release_hash := int(fw["layers"][0]["hash"])
	var snapshot := PBCommand.copy_mesh_data(md)
	assert_true(PBSplat.paint_face_splat(md, face, sm, slot, Vector3(0.3, 0.5, -0.3), 0.15, 0.0, 1.0),
			"the release's mask takes new paint")
	var painted_hash := hash(PBSplat.get_layer_mask_image(sm, slot).get_data())
	assert_ne(painted_hash, release_hash, "the dab changed it")
	# Save: the old plain textures move to the compressed form first.
	assert_gt(PBSplat.adopt_mesh_compressed_storage(md), 0, "release masks convert before a save")
	DirAccess.make_dir_recursive_absolute("user://pb_release_compat")
	var packed := PackedScene.new()
	assert_eq(packed.pack(root), OK)
	assert_eq(ResourceSaver.save(packed, "user://pb_release_compat/resaved.tscn"), OK)
	var again := (ResourceLoader.load("user://pb_release_compat/resaved.tscn", "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	add_child_autofree(again)
	var md2 := _mesh(again, "PaintedCube").pb_mesh_data
	var sm2 := md2.get_face_material(md2.faces[int(fw["index"])]) as ShaderMaterial
	assert_eq(hash(PBSplat.get_layer_mask_image(sm2, slot).get_data()), painted_hash,
			"re-saved in the new format, the paint is byte-identical")
	assert_eq(hash(PBSplat.get_decal_layer_image(sm2).get_data()), int(fw["decal"]["hash"]),
			"and so is the release's decal")
	# Undo of that dab brings the release's pixels back.
	PBCommand.restore_mesh_data(md, snapshot)
	var restored := md.get_face_material(md.faces[int(fw["index"])]) as ShaderMaterial
	assert_eq(hash(PBSplat.get_layer_mask_image(restored, slot).get_data()), release_hash,
			"undo restores exactly what the release saved")
