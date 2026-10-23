## Builds the release-compatibility fixture WITH A RELEASE'S OWN CODE.
##
## Run by tools/release_fixture/make_release_fixture.sh inside a worktree of
## the release commit — never against the current tree (the point is that the
## fixture is what the RELEASE wrote). It writes a scene with painted meshes
## plus a JSON of what the release itself read back from them, and the
## current version's test (tests/test_pb_release_compat.gd) checks it reads
## the same.
##
## Only APIs the v0.9.167 release has are used here.
extends SceneTree

const OUT_SCENE := "res://release_fixture.scn"
const OUT_JSON := "res://release_fixture.json"

func _initialize() -> void:
	_run.call_deferred()

func _top(data: PBMeshData, wanted: Vector3) -> int:
	for fi in range(data.faces.size()):
		if PBMath.normal_from_positions(data.positions, data.faces[fi].get_indexes()).dot(wanted) > 0.99:
			return fi
	return -1

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

func _run() -> void:
	await process_frame
	var root := Node3D.new()
	root.name = "ReleaseFixture"
	get_root().add_child(root)
	var tex_a := load("res://addons/poibuilder/materials/textures/tiles_wet_4x4.png") as Texture2D
	var tex_b := load("res://addons/poibuilder/materials/textures/brick_path_4x4.png") as Texture2D

	# A cube with a two-layer splat + a decal stamp on top, and a painted side.
	var cube := PBMesh.create_cube(1.0)
	cube.name = "PaintedCube"
	root.add_child(cube)
	cube.owner = root
	var d := cube.pb_mesh_data
	PBSplat.ensure_mesh_splat_uv(d)
	var top := _top(d, Vector3.UP)
	var face := d.faces[top]
	var mat := PBSplat.ensure_face_owned_material(d, face)
	var la := PBSplat.ensure_layer_for_texture(mat, tex_a)
	PBSplat.paint_face_splat(d, face, mat, la, Vector3(-0.2, 0.5, -0.2), 0.25, 0.5, 1.0)
	var lb := PBSplat.ensure_layer_for_texture(mat, tex_b)
	PBSplat.paint_face_splat(d, face, mat, lb, Vector3(0.2, 0.5, 0.2), 0.2, 0.0, 1.0)
	var stamp := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	for y in range(16):
		for x in range(16):
			stamp.set_pixel(x, y, Color(1.0, 0.2, 0.1, float(x) / 15.0))
	PBSplat.paste_decal(d, Vector3(0.0, 0.5, 0.0), Vector3.UP, 0.0, 0.4, 1.0, stamp)
	var side := _top(d, Vector3.RIGHT)
	var side_face := d.faces[side]
	var side_mat := PBSplat.ensure_face_owned_material(d, side_face)
	var ls := PBSplat.ensure_layer_for_texture(side_mat, tex_a)
	PBSplat.paint_face_splat(d, side_face, side_mat, ls, Vector3(0.5, 0.0, 0.0), 0.3, 0.3, 1.0)
	PBSplat.sync_mesh_mask_textures(d)
	cube.rebuild()

	# An unpainted mesh beside it (plain material, no splat data).
	var plain := PBMesh.create_cube(1.0)
	plain.name = "PlainCube"
	plain.position = Vector3(2.0, 0.0, 0.0)
	root.add_child(plain)
	plain.owner = root

	# What the RELEASE reads back — the current version must read the same.
	var expect := {"release": "0.9.167", "commit": "de492fe", "meshes": {}}
	for pb in [cube, plain]:
		var md: PBMeshData = pb.pb_mesh_data
		var faces: Array = []
		for fi in range(md.faces.size()):
			var f := md.faces[fi]
			var m := md.get_face_material(f)
			var entry := {"index": fi, "splat": PBSplat.is_splat_material(m),
					"splat_bounds": Array(f.splat_bounds)}
			if PBSplat.is_splat_material(m):
				var sm := m as ShaderMaterial
				var layers: Array = []
				for i in range(1, PBSplat.MAX_LAYERS + 1):
					if sm.get_shader_parameter("layer_%d_enabled" % i) == true:
						var img := PBSplat.get_layer_mask_image(sm, i)
						layers.append({"slot": i, "w": img.get_width(), "h": img.get_height(),
								"nonzero": _nonzero(img, false), "hash": hash(img.get_data()),
								"texture": (sm.get_shader_parameter("layer_%d_texture" % i) as Texture2D).resource_path})
				entry["layers"] = layers
				if PBSplat.has_decal_layer(sm):
					var dimg := PBSplat.get_decal_layer_image(sm)
					var win := PBSplat.get_decal_window(sm)
					entry["decal"] = {"w": dimg.get_width(), "h": dimg.get_height(),
							"alpha_nonzero": _nonzero(dimg, true), "hash": hash(dimg.get_data()),
							"window": [win.position.x, win.position.y, win.size.x, win.size.y]}
			faces.append(entry)
		expect["meshes"][String(pb.name)] = {"positions": md.positions.size(), "faces": faces}

	var packed := PackedScene.new()
	packed.pack(root)
	var err := ResourceSaver.save(packed, OUT_SCENE, ResourceSaver.FLAG_COMPRESS)
	var f := FileAccess.open(OUT_JSON, FileAccess.WRITE)
	f.store_string(JSON.stringify(expect, "  "))
	f.close()
	print("RELEASE_FIXTURE saved=%d" % err)
	quit()
