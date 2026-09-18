extends SceneTree

## Decal verification probe (run under xvfb with the opengl3 driver):
##
##   xvfb-run -a godot-mono --rendering-driver opengl3 -s res://test_scenes/decal_probe.gd
##
## Renders the stamp cases the decal layer was reported broken for — a floor, a
## 32 m floor, a wall, a floor stamp next to a perpendicular wall, a mesh scaled
## 8x and a rotated mesh — to /tmp/dec_<case>.png, and prints the numbers behind
## each one: the decal window, its texels/m, and the painted footprint's bbox +
## aspect (which is what tells a real 2:1 stamp from a smeared band). The
## assertions live in tests/test_pb_splat_and_stamp.gd; this is for looking at
## the result.

var _root: Node3D
var _cam: Camera3D
var _cases: Array = []

func _init() -> void:
	_root = Node3D.new()
	root.add_child(_root)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.25, 0.27, 0.3)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.9, 0.9, 0.95)
	e.ambient_light_energy = 1.2
	env.environment = e
	_root.add_child(env)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, -30, 0)
	_root.add_child(light)
	_cam = Camera3D.new()
	_root.add_child(_cam)
	_cases = [
		{"name": "a_floor_12_stamp2", "kind": "floor", "size": 12.0, "stamp": 2.0},
		# A 32 m floor: the case that used to give a 1 m stamp a 64 px footprint.
		{"name": "b_floor_32_stamp1", "kind": "floor", "size": 32.0, "stamp": 1.0, "view_dist": 2.2},
		{"name": "c_wallbox_8x4_stamp2", "kind": "wallbox", "size": 8.0, "stamp": 2.0},
		{"name": "d_floor_near_wall", "kind": "wallfloor", "size": 8.0, "stamp": 2.0},
		{"name": "e_floor_scaled8", "kind": "floor", "size": 1.0, "stamp": 0.25, "scale": 8.0},
		{"name": "f_tilted_plane", "kind": "tilted", "size": 8.0, "stamp": 2.0},
	]
	_run_next()

func _run_next() -> void:
	if _cases.is_empty():
		quit()
		return
	var c: Dictionary = _cases.pop_front()
	for child in _root.get_children():
		if child is PBMesh:
			_root.remove_child(child)
			child.free()

	var size: float = c["size"]
	var mesh := PBMesh.new()
	mesh.name = "Target"
	mesh.pb_mesh_data = PBShapeGenerators.create_plane(size, size, 1, 1)
	var sc: float = c.get("scale", 0.0)
	match String(c["kind"]):
		"wallbox":
			mesh.pb_mesh_data = PBMeshData.create_cube(1.0)
			var md: PBMeshData = mesh.pb_mesh_data
			for i in range(md.positions.size()):
				var p: Vector3 = md.positions[i]
				md.positions[i] = Vector3(p.x * size, (p.y + 0.5) * (size * 0.5), p.z * 0.4)
		"tilted":
			# A rotated target: its local normal is NOT the world normal, which
			# is exactly what the world/local mix-up got wrong.
			mesh.rotation.x = deg_to_rad(-90.0)
	if sc > 0.0:
		mesh.scale = Vector3(sc, sc, sc)
	_root.add_child(mesh)
	await process_frame

	var face_idx := 0
	var world_hit: Vector3 = mesh.global_transform * Vector3.ZERO
	if String(c["kind"]) == "wallbox":
		face_idx = 0
		world_hit = mesh.global_transform * Vector3(0, size * 0.25, -0.2)
	if String(c["kind"]) == "wallfloor":
		world_hit = mesh.global_transform * Vector3(0, 0, size * 0.5 - 1.5)
	var world_normal: Vector3 = (mesh.global_transform.basis * _face_normal(mesh.pb_mesh_data, face_idx)).normalized()

	if String(c["kind"]) == "wallfloor":
		var wall := PBMesh.new()
		wall.name = "Wall"
		wall.pb_mesh_data = PBShapeGenerators.create_plane(size, 3.0, 1, 1)
		wall.rotation.x = deg_to_rad(-90.0)
		var wd: PBMeshData = wall.pb_mesh_data
		for i in range(wd.positions.size()):
			var p: Vector3 = wd.positions[i]
			wd.positions[i] = Vector3(p.x, p.z + 1.5, 0.0)
		wall.position = Vector3(0, 0, size * 0.5)
		_root.add_child(wall)

	var ctrl := PBPaintController.new()
	ctrl.setup_previews(_root)
	ctrl.stamp_texture = load("res://addons/poibuilder/materials/textures/stamp_hello_world.png")
	ctrl.stamp_scale = c["stamp"]
	ctrl.set_mode(PBPaintController.Mode.STAMP)
	ctrl.update_cursor(world_hit, world_normal, mesh, face_idx)
	ctrl.apply_stamp()
	await process_frame
	ctrl.cleanup_previews()

	print("\n=== %s (%s)" % [c["name"], c])
	print("world hit %s  world normal %s  scale %s" % [world_hit, world_normal, mesh.scale])
	_dump(mesh, face_idx, c["stamp"])
	for other in _root.get_children():
		if other is PBMesh and other != mesh:
			_dump(other, 0, c["stamp"], "  [neighbour] ")

	var aabb: AABB = mesh.get_aabb()
	var wc: Vector3 = mesh.global_transform * aabb.get_center()
	var dist: float = aabb.size.length() * 0.9 * maxf(sc, 1.0)
	if c.has("view_dist"):
		dist = c["view_dist"]
		wc = world_hit
	# Frame the PAINTED side: the camera sits along the face's own normal (a
	# wall's back is culled, so a fixed offset showed nothing for half the cases).
	var n := world_normal.normalized()
	var cam_up := Vector3.UP if absf(n.y) < 0.9 else Vector3.FORWARD
	var cam_offset := (n * 0.8 + cam_up * 0.45).normalized()
	_cam.look_at_from_position(wc + cam_offset * dist, wc)
	await process_frame
	await process_frame
	var out := root.get_viewport().get_texture().get_image()
	out.save_png("/tmp/dec_%s.png" % c["name"])
	print("[probe] saved /tmp/dec_%s.png" % c["name"])
	_run_next()

func _face_normal(data: PBMeshData, face_idx: int) -> Vector3:
	var f: PBFace = data.faces[face_idx]
	var n := PBMath.normal_from_positions(data.positions, f.get_indexes())
	return n.normalized() if n.length_squared() > 0.0001 else Vector3.UP

func _dump(node: PBMesh, face_idx: int, stamp_m: float, prefix: String = "") -> void:
	var data := node.pb_mesh_data
	var face: PBFace = data.faces[face_idx]
	var mat := data.get_face_material(face) as ShaderMaterial
	if mat == null or not PBSplat.is_splat_material(mat) or not PBSplat.has_decal_layer(mat):
		print("%sdecal: none" % prefix)
		return
	var img := PBSplat.get_decal_layer_image(mat)
	var win := PBSplat.get_decal_window(mat)
	var bounds := PBSplat.get_face_planar_bounds(data, face)
	var density := float(img.get_width()) / maxf(win.size.x * bounds["range_u"], 0.001)
	# Painted bbox in pixels: tells a real stamp (2:1 rectangle) from a smear.
	var min_x := img.get_width()
	var max_x := -1
	var min_y := img.get_height()
	var max_y := -1
	var painted := 0
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			if img.get_pixel(x, y).a > 0.1:
				painted += 1
				min_x = mini(min_x, x)
				max_x = maxi(max_x, x)
				min_y = mini(min_y, y)
				max_y = maxi(max_y, y)
	var aspect := 0.0
	if max_x >= min_x and max_y >= min_y:
		aspect = float(max_x - min_x + 1) / float(max_y - min_y + 1)
	print("%sdecal %dx%d painted=%d bbox=%dx%d aspect=%.2f (source 2.00) window=%s density=%.0f texels/m face_splat_bounds=%s" % [
		prefix, img.get_width(), img.get_height(), painted,
		max_x - min_x + 1, max_y - min_y + 1, aspect, str(win), density, str(face.splat_bounds)])
