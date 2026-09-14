extends SceneTree

## Renders beveled meshes to PNGs for visual inspection (run under xvfb with
## the opengl3 driver — headless cannot render). Checker cases expose UV
## continuation; flat cases expose geometry (rounding, seams).

var _cam: Camera3D
var _root: Node3D
var _cases: Array = []

func _checker_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	var img := Image.create(256, 256, false, Image.FORMAT_RGB8)
	for y in range(256):
		for x in range(256):
			var c := Color(0.85, 0.85, 0.85) if (int(x / 128.0) + int(y / 128.0)) % 2 == 0 else Color(0.2, 0.2, 0.22)
			if x % 128 < 4 or y % 128 < 4:
				c = Color(0.9, 0.75, 0.2)
			img.set_pixel(x, y, c)
	m.albedo_texture = ImageTexture.create_from_image(img)
	m.roughness = 1.0
	return m

func _flat_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.72, 0.74, 0.78)
	m.roughness = 1.0
	return m

func _init() -> void:
	_cases = [
		{"name": "single_edge_s1_check", "kind": "single", "segs": 1, "amt": 0.3, "check": true, "view": Vector3(0.6, 1.4, -1.8)},
		{"name": "single_edge_s4_check", "kind": "single", "segs": 4, "amt": 0.3, "check": true, "view": Vector3(0.6, 1.4, -1.8)},
		{"name": "single_edge_s4_flat", "kind": "single", "segs": 4, "amt": 0.3, "check": false, "view": Vector3(0.6, 1.4, -1.8)},
		{"name": "loop_inner_s1_check", "kind": "inset", "segs": 1, "amt": 0.15, "inner": true, "check": true, "view": Vector3(0.5, 1.6, 1.7)},
		{"name": "loop_inner_s4_check", "kind": "inset", "segs": 4, "amt": 0.15, "inner": true, "check": true, "view": Vector3(0.5, 1.6, 1.7)},
		{"name": "loop_inner_s4_flat", "kind": "inset", "segs": 4, "amt": 0.15, "inner": true, "check": false, "view": Vector3(0.5, 1.6, 1.7)},
		{"name": "loop_outer_s4_flat", "kind": "inset", "segs": 4, "amt": 0.15, "inner": false, "check": false, "view": Vector3(0.5, 1.6, 1.7)},
		{"name": "cube_all_s4_flat", "kind": "all", "segs": 4, "amt": 0.3, "check": false, "view": Vector3(0.7, 0.6, 1.0)},
		{"name": "cube_all_s4_check", "kind": "all", "segs": 4, "amt": 0.3, "check": true, "view": Vector3(0.7, 0.6, 1.0)},
	]
	_root = Node3D.new()
	root.add_child(_root)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.25, 0.27, 0.3)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.8, 0.8, 0.85)
	e.ambient_light_energy = 1.0
	env.environment = e
	_root.add_child(env)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, -30, 0)
	_root.add_child(light)
	_cam = Camera3D.new()
	_root.add_child(_cam)
	_run_next()

func _run_next() -> void:
	if _cases.is_empty():
		quit()
		return
	var case: Dictionary = _cases.pop_front()
	var data: PBMeshData
	var ids: PackedInt32Array
	match case["kind"]:
		"single":
			data = PBMeshData.create_cube(2.0)
			ids = PackedInt32Array([0])
		"inset":
			data = PBMeshData.create_cube(2.0)
			var ir := PBMeshOps.inset_faces(data, PackedInt32Array([4]), 0.35)
			PBMeshOps.extrude_faces(data, PackedInt32Array([ir["cap_face_ids"][0]]), -0.6)
			ids = _ids_for(data, 1.0, bool(case["inner"]))
		"all":
			data = PBMeshData.create_cube(2.0)
			ids = PackedInt32Array()
			for eid in range(data.get_common_edges().size()):
				ids.append(eid)
	var res := PBMeshOps.bevel_edges(data, ids, case["amt"], case["segs"])
	print("[probe] %s: ok=%s err=%s faces=%d" % [case["name"], str(res.get("ok")), str(res.get("error", "")), data.faces.size()])
	for c in _root.get_children():
		if c is MeshInstance3D:
			_root.remove_child(c)
			c.free()
	if not res.get("ok", false):
		_run_next()
		return
	var mesh := MeshInstance3D.new()
	mesh.mesh = data.to_array_mesh()
	mesh.material_override = _checker_mat() if case["check"] else _flat_mat()
	_root.add_child(mesh)
	var aabb := mesh.get_aabb()
	var center := aabb.get_center()
	var view: Vector3 = case.get("view", Vector3(0.9, 0.7, 1.3))
	_cam.look_at_from_position(center + view.normalized() * aabb.size.length() * 0.85, center)
	await process_frame
	await process_frame
	var img := root.get_viewport().get_texture().get_image()
	img.save_png("/tmp/bevel_%s.png" % case["name"])
	print("[probe] saved /tmp/bevel_%s.png" % case["name"])
	_run_next()

func _ids_for(data: PBMeshData, filter_y: float, inner: bool) -> PackedInt32Array:
	var ids := PackedInt32Array()
	for eid in range(data.get_common_edges().size()):
		var e := data.get_common_edges()[eid]
		var pa: Vector3 = data.positions[e.a]
		var pb: Vector3 = data.positions[e.b]
		if absf(pa.y - filter_y) > 0.001 or absf(pb.y - filter_y) > 0.001:
			continue
		var a_out: bool = absf(pa.x) > 0.99 or absf(pa.z) > 0.99
		var b_out: bool = absf(pb.x) > 0.99 or absf(pb.z) > 0.99
		if a_out == inner and b_out == inner:
			ids.append(eid)
	return ids
