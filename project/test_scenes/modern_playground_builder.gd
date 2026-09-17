## Modern Playground Builder — assembles res://playground.tscn for modern.sh.
##
## Runs INSIDE the generated /tmp/poibuilder_modern project (see modern.sh):
##   godot-mono --headless --path <proj> -s res://build_modern_playground.gd
## Loads the scratch base (FPS player + environment from main.tscn), instances
## the machine-local 4k GLTF props, splat-paints a PBMesh floor, and saves the
## scene as res://playground.tscn for interactive poking (editor or --play).
extends SceneTree

const STATUES := [
	{"path": "res://modern_assets/marble_bust_01_4k/marble_bust_01_4k.gltf", "pos": Vector3(-2.0, 0, -2.0), "scale": 1.0},
	{"path": "res://modern_assets/gothic_statue_4k/gothic_statue_4k.gltf", "pos": Vector3(2.0, 0, -2.0), "scale": 1.0},
]

func _init() -> void:
	var base: PackedScene = load("res://playground_base.tscn")
	if base == null:
		push_error("playground_base.tscn missing — modern.sh must copy main.tscn first")
		quit(1)
		return
	var root := base.instantiate()
	root.name = "Main"

	# The base floor is a plain MeshInstance3D — replace it with an editable
	# PBMesh slab that carries a live splat patch, so paint + the UV editor's
	# UV2 debug view can be exercised in-context.
	var old_floor := root.get_node_or_null("Floor")
	if old_floor != null:
		root.remove_child(old_floor)
		old_floor.queue_free()

	var floor_mesh := PBMesh.create_cube(1.0)
	floor_mesh.name = "ModernFloor"
	for i in range(floor_mesh.pb_mesh_data.positions.size()):
		var p: Vector3 = floor_mesh.pb_mesh_data.positions[i]
		floor_mesh.pb_mesh_data.positions[i] = Vector3(p.x * 16.0, p.y * 0.2, p.z * 16.0)
	root.add_child(floor_mesh)
	floor_mesh.position = Vector3(0, -0.1, 0)
	floor_mesh.owner = root

	# Splat material on the whole floor: 4k statue stone as a paintable layer
	var md := floor_mesh.pb_mesh_data
	var base_mat := StandardMaterial3D.new()
	base_mat.albedo_color = Color(0.55, 0.53, 0.5)
	base_mat.roughness = 0.9
	base_mat.albedo_texture = _first_texture("res://modern_assets/marble_bust_01_4k/textures")
	var splat_mat := PBSplat.create_splat_material(base_mat)
	for f in md.faces:
		if f != null:
			md.set_face_material(f, splat_mat)
	var stone_diff := "res://modern_assets/gothic_statue_4k/textures/gothic_statue_diff_4k.jpg"
	if ResourceLoader.exists(stone_diff):
		var slot := PBSplat.add_layer(splat_mat, load(stone_diff))
		# Paint a blended patch in the middle of the floor
		for f in md.faces:
			if f != null:
				PBSplat.paint_face_splat(md, f, splat_mat, slot, Vector3(0, 0, 0), 2.0, 0.7, 0.9)
		# Headless saves sample ImageTexture.get_image(), which is stale after
		# update() — rebuild the GPU textures from the CPU cache first.
		PBSplat.sync_mask_textures(splat_mat)
		print("splat patch painted (layer ", slot, ")")

	# Props
	for info in STATUES:
		if not ResourceLoader.exists(info["path"]):
			print("skip missing prop: ", info["path"])
			continue
		var ps: PackedScene = load(info["path"])
		if ps == null:
			continue
		var prop := ps.instantiate()
		prop.name = String(info["path"].get_file()).replace(".gltf", "")
		prop.position = info["pos"]
		prop.scale = Vector3.ONE * float(info["scale"])
		root.add_child(prop)
		_own(prop, root)
		print("instanced ", prop.name)

	var packed := PackedScene.new()
	packed.pack(root)
	ResourceSaver.save(packed, "res://playground.tscn")
	print("saved res://playground.tscn")
	quit(0)

## pack() only includes nodes whose owner is the scene root — code-built
## children must be claimed explicitly or they are silently dropped.
func _own(node: Node, owner: Node) -> void:
	node.owner = owner
	for child in node.get_children():
		_own(child, owner)

func _first_texture(dir_path: String) -> Texture2D:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return null
	for f in dir.get_files():
		if f.ends_with(".jpg") or f.ends_with(".png"):
			var tex := load(dir_path + "/" + f)
			if tex is Texture2D:
				return tex
	return null
