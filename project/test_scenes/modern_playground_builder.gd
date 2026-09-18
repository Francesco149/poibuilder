## Modern Playground Builder — assembles res://playground.tscn for modern.sh.
##
## Runs INSIDE the generated /tmp/poibuilder_modern project (see modern.sh):
##   godot-mono --headless --path <proj> -s res://build_modern_playground.gd
##
## The playground shows the three things this pipeline converged on:
##   1. a PBMesh floor GRID carrying a live splat stack — painted blend patches
##      plus a decal stamped ACROSS face borders (a stamp is pixels, so it may
##      span tiles; the same goes for the wall's poster),
##   2. UV2 unwrapped for LightmapGI on both meshes with GI mode Static —
##      paint and baked lighting coexist on one surface because masks live in
##      their own vertex channel (CUSTOM0) and UV2 belongs to the unwrap,
##   3. interesting lighting to bake: a warm key light, a cool fill, an emissive
##      strip and a sky, so the indirect bounce reads clearly on the floor.
##
## The lightmap itself is baked in the EDITOR (GPU bake, no headless path):
##   godot-mono --editor --path <proj> res://playground.tscn
##   select the LightmapGI node -> Inspector -> "Bake Lightmaps"
## then walk the scene with ./modern.sh --play.
extends SceneTree

const STATUES := [
	{"path": "res://modern_assets/marble_bust_01_4k/marble_bust_01_4k.gltf", "pos": Vector3(-2.5, 0, -2.5), "scale": 1.0},
	{"path": "res://modern_assets/gothic_statue_4k/gothic_statue_4k.gltf", "pos": Vector3(2.5, 0, -2.5), "scale": 1.0},
]

const FLOOR_SIZE := 18.0
const FLOOR_SEGMENTS := 6
const WALL_HEIGHT := 4.5
const WALL_Z := -9.0

func _init() -> void:
	var base: PackedScene = load("res://playground_base.tscn")
	if base == null:
		push_error("playground_base.tscn missing — modern.sh must copy main.tscn first")
		quit(1)
		return
	var root := base.instantiate()
	root.name = "Main"

	var old_floor := root.get_node_or_null("Floor")
	if old_floor != null:
		root.remove_child(old_floor)
		old_floor.queue_free()

	_build_floor(root)
	_build_wall(root)
	_build_lighting(root)
	_build_lightmap_gi(root)

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
		# Dynamic GI: the statues are lit by the lightmap probes, not by a bake.
		for child in prop.get_children():
			if child is MeshInstance3D:
				(child as MeshInstance3D).gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
		_own(prop, root)
		print("instanced ", prop.name)

	var hint := Label3D.new()
	hint.name = "BakeHint"
	hint.text = "LightmapGI demo: select the LightmapGI node and press \"Bake Lightmaps\"\nthen re-run ./modern.sh --play. Splat paint and baked lighting share the floor."
	hint.font_size = 64
	hint.pixel_size = 0.008
	hint.modulate = Color(1, 0.9, 0.6)
	hint.position = Vector3(0, 2.2, 3.0)
	hint.rotation_degrees = Vector3(-35, 180, 0)
	hint.no_depth_test = false
	hint.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	root.add_child(hint)
	_own(hint, root)

	var packed := PackedScene.new()
	packed.pack(root)
	ResourceSaver.save(packed, "res://playground.tscn")
	print("saved res://playground.tscn")
	print("next: open the editor, select the LightmapGI node, press Bake Lightmaps")
	quit(0)

func _build_floor(root: Node) -> void:
	# A grid (not a single slab): the decal below is stamped across face borders,
	# which only a multi-face surface can show off.
	var floor_mesh := PBMesh.new()
	floor_mesh.name = "ModernFloor"
	floor_mesh.pb_mesh_data = PBShapeGenerators.create_plane(FLOOR_SIZE, FLOOR_SIZE, FLOOR_SEGMENTS, FLOOR_SEGMENTS)
	root.add_child(floor_mesh)
	floor_mesh.owner = root

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
		# A blended patch in the middle of the floor (the splat brush in spirit).
		for f in md.faces:
			if f != null:
				PBSplat.paint_face_splat(md, f, splat_mat, slot, Vector3(0, 0, 0), 2.0, 0.7, 0.9)
		print("splat patch painted (layer ", slot, ")")

	# The stamped banner: a wide PNG (hello world is 4:1) laid across the floor
	# centre — it spans four grid faces, which is the point.
	var banner_path := "res://addons/poibuilder/materials/textures/stamp_hello_world.png"
	if ResourceLoader.exists(banner_path):
		var banner := (load(banner_path) as Texture2D).get_image()
		var painted := PBSplat.paste_decal(md, Vector3(0, 0, 2.0), Vector3.UP, 0.0, 6.0, 1.0, banner)
		print("banner decal painted across ", painted, " face(s)")

	# A moss patch near a corner, to show a second decal in the same layer.
	var moss_path := "res://addons/poibuilder/materials/textures/flower_patch.png"
	if ResourceLoader.exists(moss_path):
		var moss := (load(moss_path) as Texture2D).get_image()
		print("moss decal painted across ",
				PBSplat.paste_decal(md, Vector3(-5.0, 0, -4.0), Vector3.UP, 25.0, 3.0, 0.9, moss), " face(s)")

	# Paint and lightmaps together: UV2 is the unwrap, masks are CUSTOM0.
	var err := PBUvOps.unwrap_lightmap_uv2(md, Transform3D.IDENTITY, 0.05)
	print("floor UV2 unwrap: ", error_string(err), " hint ", md.lightmap_size_hint)
	floor_mesh.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	PBSplat.sync_mask_textures(splat_mat)

func _build_wall(root: Node) -> void:
	var wall := PBMesh.create_cube(1.0)
	wall.name = "ModernWall"
	for i in range(wall.pb_mesh_data.positions.size()):
		var p: Vector3 = wall.pb_mesh_data.positions[i]
		wall.pb_mesh_data.positions[i] = Vector3(p.x * FLOOR_SIZE, p.y * WALL_HEIGHT, p.z * 0.3)
	root.add_child(wall)
	wall.position = Vector3(0, WALL_HEIGHT * 0.5, WALL_Z)
	wall.owner = root

	var md := wall.pb_mesh_data
	var base_mat := StandardMaterial3D.new()
	base_mat.albedo_color = Color(0.62, 0.6, 0.58)
	base_mat.roughness = 0.85
	base_mat.albedo_texture = _first_texture("res://modern_assets/coastal_cliff_02_4k/textures")
	var splat_mat := PBSplat.create_splat_material(base_mat)
	for f in md.faces:
		if f != null:
			md.set_face_material(f, splat_mat)

	# Poster on the wall's front face (-Z side): the face nearest the camera.
	var poster_path := "res://addons/poibuilder/materials/textures/stamp_hello_world.png"
	if ResourceLoader.exists(poster_path):
		var poster := (load(poster_path) as Texture2D).get_image()
		var face_idx := _face_facing(md, Vector3.FORWARD)
		if face_idx >= 0:
			var face := md.faces[face_idx]
			var center := Vector3.ZERO
			for idx in face.get_distinct_indexes():
				center += md.positions[idx]
			center /= float(face.get_distinct_indexes().size())
			print("wall poster painted across ",
					PBSplat.paste_decal(md, center, Vector3.FORWARD, 0.0, 3.0, 1.0, poster), " face(s)")

	var err := PBUvOps.unwrap_lightmap_uv2(md, Transform3D.IDENTITY, 0.05)
	print("wall UV2 unwrap: ", error_string(err), " hint ", md.lightmap_size_hint)
	wall.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	PBSplat.sync_mask_textures(splat_mat)

func _build_lighting(root: Node) -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_color = Color(1.0, 0.93, 0.82)
	sun.light_energy = 1.1
	sun.rotation_degrees = Vector3(-38, 32, 0)
	sun.shadow_enabled = true
	sun.light_bake_mode = Light3D.BAKE_STATIC
	root.add_child(sun)
	_own(sun, root)

	# A warm bounce light close to the floor: its indirect contribution is what
	# makes a baked lightmap read as "fancy" instead of flat.
	var warm := OmniLight3D.new()
	warm.name = "WarmBounce"
	warm.position = Vector3(-3.0, 1.4, -1.5)
	warm.light_color = Color(1.0, 0.62, 0.32)
	warm.light_energy = 4.0
	warm.omni_range = 9.0
	warm.shadow_enabled = true
	warm.light_bake_mode = Light3D.BAKE_STATIC
	root.add_child(warm)
	_own(warm, root)

	# Cool fill from the other side for colour contrast in the bounce.
	var cool := OmniLight3D.new()
	cool.name = "CoolFill"
	cool.position = Vector3(4.0, 2.2, 1.0)
	cool.light_color = Color(0.45, 0.65, 1.0)
	cool.light_energy = 3.0
	cool.omni_range = 10.0
	cool.light_bake_mode = Light3D.BAKE_STATIC
	root.add_child(cool)
	_own(cool, root)

	# An emissive strip above the wall: baked emission is the third light source.
	var strip := MeshInstance3D.new()
	strip.name = "LightStrip"
	var box := BoxMesh.new()
	box.size = Vector3(7.0, 0.08, 0.08)
	strip.mesh = box
	strip.position = Vector3(0, 3.6, WALL_Z + 0.6)
	var strip_mat := StandardMaterial3D.new()
	strip_mat.albedo_color = Color(0.2, 0.9, 0.95)
	strip_mat.emission_enabled = true
	strip_mat.emission = Color(0.3, 0.95, 1.0)
	strip_mat.emission_energy_multiplier = 6.0
	strip.material_override = strip_mat
	root.add_child(strip)
	_own(strip, root)

func _build_lightmap_gi(root: Node) -> void:
	var lgi := LightmapGI.new()
	lgi.name = "LightmapGI"
	lgi.quality = LightmapGI.BAKE_QUALITY_MEDIUM
	lgi.bounces = 3
	lgi.bounce_indirect_energy = 1.2
	lgi.directional = true
	lgi.use_denoiser = true
	lgi.texel_scale = 1.0
	lgi.generate_probes_subdiv = LightmapGI.GENERATE_PROBES_SUBDIV_8
	# The light_data resource must already live at a res:// path: the editor's
	# bake writes the atlas next to it without prompting for a file.
	var data := LightmapGIData.new()
	var data_path := "res://playground.lmbake"
	var err := ResourceSaver.save(data, data_path)
	if err == OK:
		lgi.light_data = load(data_path)
	else:
		push_warning("could not pre-create %s (%s) — the editor bake will ask for a path" % [data_path, error_string(err)])
	root.add_child(lgi)
	_own(lgi, root)

## The face whose normal points most along `dir`.
func _face_facing(md: PBMeshData, dir: Vector3) -> int:
	var best := -1
	var best_dot := -2.0
	for fi in range(md.faces.size()):
		var face := md.faces[fi]
		if face == null:
			continue
		var n := PBMath.normal_from_positions(md.positions, face.get_indexes())
		if n.length_squared() < 0.0001:
			continue
		var d := n.normalized().dot(dir)
		if d > best_dot:
			best_dot = d
			best = fi
	return best

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
