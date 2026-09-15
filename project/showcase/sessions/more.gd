## ACT — features that landed after the original film: UV editor, bevel,
## trim, trim walls, CSG, advanced selection, poibuilderize.
##
## Appended at the END of the EDL. Existing clips are not recut.
@tool
extends RefCounted

var director: ShowcaseDirector
var d: ShowcaseDirector
var root: Node
var bench: PBMesh
var obj: PBMesh
var wall_a: PBMesh
var wall_b: PBMesh
var wall_c: PBMesh
var wall_d: PBMesh

const GLB := "/mnt/ephemeral/assets/PSX_Modular_Medieval/Market/barrel_lid_alt.glb"

func run(dr: ShowcaseDirector) -> void:
	d = dr
	d.fill_scale = 1.35
	root = EditorInterface.get_edited_scene_root()
	ShowcaseUtil.env(d.plugin, "day")
	ShowcaseUtil.grade_light(root)
	ShowcaseUtil.fresh_grid(d.plugin)
	ShowcaseUtil.use_default_material(ShowcaseUtil.CHECKER)
	bench = ShowcaseUtil.floor_slab(root, 28.0, ShowcaseUtil.mat(root, "ink"))
	await d.grid_show(false)
	await d.frames(12)
	# Row 3/4 hold CSG, Poibuilderize, Trim Walls, V-Snap.
	await d.off(func():
		await d.click_button("split", 10))
	await d.shot("more/uv", _uv)
	await d.shot("more/bevel", _bevel)
	await d.shot("more/trim", _trim)
	await d.shot("more/trim_walls", _trim_walls)
	await d.shot("more/csg", _csg)
	await d.shot("more/select_snap", _select_snap)
	await d.shot("more/poibuilderize", _poibuilderize)
	d.snapshot_regions()

func _clear() -> void:
	d.plugin.editor.active_mesh = null
	EditorInterface.get_selection().clear()
	for c in root.get_children():
		if c == bench:
			continue
		if c is PBMesh or c is MeshInstance3D or c is CSGShape3D:
			c.visible = false
			if c is Node3D:
				(c as Node3D).position += Vector3(0.0, -400.0, 0.0)
			c.name = "Parked_" + String(c.name)

func _fresh(name: String, data: PBMeshData, color := "steel", pos := Vector3.ZERO,
		fill := 0.40, az := 30.0, elev := 24.0) -> PBMesh:
	var node: PBMesh = await d.off(func():
		_clear()
		var n := ShowcaseUtil.mesh(root, name, data, pos, ShowcaseUtil.checker_mat(root, color))
		ShowcaseUtil.drop_on_ground(n)
		EditorInterface.get_selection().add_node(n)
		var f := d.framing_node(n, fill, az, elev)
		d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
		return n)
	await d.frames(6)
	return node

func _uv() -> void:
	obj = await _fresh("UvCube", PBMeshData.create_cube(2.0), "brick", Vector3.ZERO, 0.42, 28.0, 18.0)
	var f := d.framing_node(obj, 0.42, 28.0, 18.0)
	await d.click_button("face")
	await d.orbit_glide(f["center"], 28.0, 40.0, 18.0, f["dist"], Vector3(0.0, 1.0, 1.0), 20, f["aim"])
	await d.click()
	await d.click_button("uv", 18)
	await d.frames(36)
	d.check(true, "UV editor opened")
	await d.cam_swing(f["center"], 40.0, 18.0, 18.0, 24.0, f["dist"] * 1.05, 28, 1, f["aim"])

func _bevel() -> void:
	obj = await _fresh("BevelCube", PBMeshData.create_cube(2.0), "stone", Vector3.ZERO, 0.40, 32.0, 22.0)
	var f := d.framing_node(obj, 0.40, 32.0, 22.0)
	await d.click_button("edge")
	await d.orbit_glide(f["center"], 32.0, 44.0, 22.0, f["dist"], Vector3(0.0, 2.0, 1.0), 18, f["aim"])
	await d.click(Vector2.INF, 12, ["alt"])
	await d.frames(8)
	var before: int = obj.pb_mesh_data.faces.size()
	await d.click_button("bevel_edges", 16)
	await d.frames(10)
	d.check(d.plugin.tool_overlay.params_open, "bevel modal opened")
	await d.overlay_param("distance", 0.18, 18)
	await d.overlay_param("segments", 3, 16)
	await d.overlay_button("ApplyParams", 16)
	d.check(obj.pb_mesh_data.faces.size() > before, "bevel added faces")
	await d.cam_swing(f["center"], 44.0, 70.0, 22.0, 28.0, f["dist"] * 0.95, 36, 1, f["aim"])

func _trim() -> void:
	await d.off(func():
		_clear()
		wall_a = ShowcaseUtil.mesh(root, "TrimWall",
			PBShapeGenerators.create_box(Vector3(6.0, 3.0, 0.4)),
			Vector3(0.0, 1.5, -2.2), ShowcaseUtil.checker_mat(root, "slate"))
		ShowcaseUtil.drop_on_ground(wall_a)
		wall_a.position.y = 1.5)
	var box := AABB(Vector3(-3.2, 0.0, -3.0), Vector3(6.4, 3.4, 4.2))
	var f := d.framing(box, 0.9, 26.0, 18.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(6)
	await d.arm_shape(&"trim")
	await d.glide_world_track(Vector3(-2.2, 0.0, -2.0), 14)
	await d.drag(d.w2s(Vector3(-2.2, 0.0, -2.0)), d.w2s(Vector3(2.2, 0.0, -2.0)), 32)
	await d.frames(16)
	if d.plugin.tool_overlay.params_open:
		await d.overlay_param("profile", 4, 14)
		await d.overlay_param_check("upside_down", true)
		await d.frames(12)
		await d.overlay_button("ApplyParams", 14)
	await d.cam_swing(f["center"], 26.0, -10.0, 18.0, 14.0, f["dist"] * 0.92, 32, 1, f["aim"])

func _trim_walls() -> void:
	await d.off(func():
		_clear()
		var mat := ShowcaseUtil.checker_mat(root, "slate")
		wall_a = ShowcaseUtil.mesh(root, "RoomN", PBShapeGenerators.create_box(Vector3(6.0, 3.0, 0.4)), Vector3(0.0, 1.5, -3.0), mat)
		wall_b = ShowcaseUtil.mesh(root, "RoomS", PBShapeGenerators.create_box(Vector3(6.0, 3.0, 0.4)), Vector3(0.0, 1.5, 3.0), mat)
		wall_c = ShowcaseUtil.mesh(root, "RoomW", PBShapeGenerators.create_box(Vector3(0.4, 3.0, 6.0)), Vector3(-3.0, 1.5, 0.0), mat)
		wall_d = ShowcaseUtil.mesh(root, "RoomE", PBShapeGenerators.create_box(Vector3(0.4, 3.0, 6.0)), Vector3(3.0, 1.5, 0.0), mat)
		for w in [wall_a, wall_b, wall_c, wall_d]:
			ShowcaseUtil.drop_on_ground(w)
			w.position.y = 1.5)
	var box := AABB(Vector3(-4.0, 0.0, -4.0), Vector3(8.0, 3.6, 8.0))
	var f := d.framing(box, 0.86, 40.0, 28.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(6)
	await d.click_button("trim_walls", 16)
	await d.frames(8)
	# Click inner faces in order around the room.
	for p in [Vector3(0.0, 1.2, -2.78), Vector3(2.78, 1.2, 0.0), Vector3(0.0, 1.2, 2.78), Vector3(-2.78, 1.2, 0.0)]:
		await d.glide_world_track(p, 12)
		await d.click()
		await d.frames(8)
	await d.key(KEY_ENTER)
	await d.frames(24)
	await d.cam_swing(f["center"], 40.0, 70.0, 28.0, 18.0, f["dist"] * 0.9, 36, 1, f["aim"])

func _csg() -> void:
	var wall: PBMesh = await _fresh("CsgWall", PBShapeGenerators.create_box(Vector3(4.0, 3.0, 0.6)), "stone", Vector3.ZERO, 0.46, 20.0, 12.0)
	var cutter: PBMesh = await d.off(func():
		var n := ShowcaseUtil.mesh(root, "CsgCutter",
			PBShapeCylinder.create_cylinder(0.7, 1.6, 16),
			Vector3(0.0, 1.5, 0.0), ShowcaseUtil.checker_mat(root, "brick"))
		n.rotation_degrees = Vector3(90.0, 0.0, 0.0)
		return n)
	var f := d.framing_node(wall, 0.5, 24.0, 14.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(8)
	await d.off(func():
		EditorInterface.get_selection().clear()
		EditorInterface.get_selection().add_node(wall)
		EditorInterface.get_selection().add_node(cutter))
	await d.frames(8)
	var before: int = wall.pb_mesh_data.faces.size()
	await d.click_button("csg_subtract", 20)
	await d.frames(16)
	d.check(wall.pb_mesh_data.faces.size() != before or not cutter.is_inside_tree(),
		"CSG subtract changed the wall or removed the cutter")
	await d.cam_swing(f["center"], 24.0, -20.0, 14.0, 10.0, f["dist"] * 0.9, 32, 1, f["aim"])

func _select_snap() -> void:
	var stair := PBShapeComplex.create_stairs(Vector3(3.0, 2.4, 4.0), 8, true)
	obj = await _fresh("SnapStairs", stair, "steel", Vector3.ZERO, 0.48, 210.0, 16.0)
	var f := d.framing_node(obj, 0.48, 210.0, 16.0)
	await d.click_button("face")
	await d.orbit_glide(f["center"], 210.0, 200.0, 16.0, f["dist"], Vector3(0.0, 0.3, 1.4), 18, f["aim"])
	await d.click()
	await d.click_button("select_coplanar", 14)
	await d.frames(10)
	await d.click_button("grow_selection", 12)
	await d.frames(12)
	await d.cam_swing(f["center"], 200.0, 230.0, 16.0, 22.0, f["dist"] * 0.95, 28, 1, f["aim"])

func _poibuilderize() -> void:
	await d.off(func():
		_clear()
		var imported: Node = null
		if FileAccess.file_exists(GLB):
			var doc := GLTFDocument.new()
			var state := GLTFState.new()
			if doc.append_from_file(GLB, state) == OK:
				imported = doc.generate_scene(state)
		if imported == null:
			var mi := MeshInstance3D.new()
			mi.name = "Prop"
			var box := BoxMesh.new()
			box.size = Vector3(1.2, 1.4, 1.2)
			mi.mesh = box
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(0.55, 0.38, 0.22)
			mi.material_override = mat
			imported = mi
		imported.name = "ImportedProp"
		root.add_child(imported)
		imported.owner = root
		if imported is Node3D:
			ShowcaseUtil.drop_on_ground(imported as Node3D)
		var target: Node = imported
		if imported.get_child_count() > 0:
			for c in imported.get_children():
				if c is MeshInstance3D:
					target = c
					break
		EditorInterface.get_selection().clear()
		EditorInterface.get_selection().add_node(target)
		var f := d.framing_node(target as Node3D, 0.55, 30.0, 18.0)
		d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"]))
	await d.frames(10)
	await d.click_button("poibuilderize", 18)
	await d.frames(16)
	var made: PBMesh = null
	for c in root.get_children():
		if c is PBMesh and c != bench and (c as PBMesh).visible:
			made = c
	d.check(made != null, "Poibuilderize produced a PBMesh")
	if made != null:
		EditorInterface.get_selection().clear()
		EditorInterface.get_selection().add_node(made)
		await d.click_button("face")
		var f2 := d.framing_node(made, 0.55, 36.0, 16.0)
		d.cam_at_polar(f2["center"], f2["az"], f2["elev"], f2["dist"], f2["aim"])
		await d.orbit_glide(f2["center"], 36.0, 48.0, 16.0, f2["dist"], made.global_position + Vector3(0.0, 0.6, 0.4), 16, f2["aim"])
		await d.click()
		await d.move_selection(Vector3(0.0, 0.35, 0.0), 28)
		await d.cam_swing(f2["center"], 48.0, 20.0, 16.0, 22.0, f2["dist"] * 1.05, 28, 1, f2["aim"])
