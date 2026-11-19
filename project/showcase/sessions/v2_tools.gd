## SESSION — "v2_tools": trims, CSG and Poibuilderize for showcase v2.
##
## Same workbench idea as v2_edit: the pieces stand along +X from the first
## frame and the camera travels between them, so the takes join without a
## reset. The toolbar drives everything here (New Shape menu, Trim Walls, CSG,
## Poibuilderize), framed with the 3D view ("viewport_ui").
##
##   v2t/trim        a skirting drawn in one drag along a wall, round profile
##   v2t/trimwalls   click four walls: one trim run with mitred corners
##   v2t/csg         subtract a cylinder from a wall, Ctrl+Z, Ctrl+Shift+Z
##   v2t/import      a GLB prop -> Poibuilderize -> its faces edit natively
##
## Render: PB_SHOWCASE_LAYOUT=showcase_video/layouts/tour.cfg \
##         ./showcase_video/render.sh v2_tools
@tool
extends RefCounted

var d: ShowcaseDirector
var root: Node
var bench: PBMesh
var st: Dictionary = {}

const GAP := 13.0
const ORDER := ["trim", "trimwalls", "csg", "import"]
const PROP_GLB := "/mnt/ephemeral/assets/PSX_Modular_Medieval/Market/crate.glb"

func run(dr: ShowcaseDirector) -> void:
	d = dr
	d.fill_scale = 1.3
	root = EditorInterface.get_edited_scene_root()
	ShowcaseUtil.env(d.plugin, "day")
	ShowcaseUtil.grade_light(root)
	ShowcaseUtil.fresh_grid(d.plugin)
	ShowcaseUtil.use_default_material("res://materials/textures/wood_planks.png")
	d.plugin.set_placement_style(PBShapeCreator.PlacementStyle.DRAG)
	bench = ShowcaseUtil.floor_slab(root, 90.0, ShowcaseUtil.mat(root, "ink"))
	bench.position.x = GAP * 1.5
	await d.grid_show(false)
	d.plugin.material_dock.set_thumbnail_size(64)
	if d.plugin.mode_banner != null:
		d.plugin.mode_banner.modulate.a = 0.0
	await d.off(func():
		if not d.plugin.toolbar._extended_visible:
			await d.click_button("split", 10))
	_build()
	await d.frames(6)
	d.snapshot_regions()
	await d.lift_panel(80.0)
	var f := d.framing(_trim_box(), 0.9, 26.0, 18.0)
	d.cam_at_polar(f["center"], 26.0, 18.0, f["dist"], f["aim"])
	await d.frames(20)
	for s in [["v2t/trim", _trim], ["v2t/trimwalls", _trim_walls], ["v2t/csg", _csg],
			["v2t/import", _import]]:
		if d.only_done():
			break
		await d.shot(s[0], s[1])

func _station(name: String) -> Vector3:
	return Vector3(GAP * float(ORDER.find(name)), 0.0, 0.0)

func _at(name: String, p: Vector3) -> Vector3:
	return _station(name) + p

func _trim_box() -> AABB:
	return AABB(_at("trim", Vector3(-3.2, 0.0, -3.0)), Vector3(6.4, 3.4, 4.2))

func _box(name: String, size: Vector3, center: Vector3, color: String, rot_y := 0.0) -> PBMesh:
	var n := ShowcaseUtil.mesh(root, name, PBShapeGenerators.create_box(size), center,
		ShowcaseUtil.checker_mat(root, color))
	n.rotation_degrees = Vector3(0.0, rot_y, 0.0)
	return n

func _build() -> void:
	st["trim_wall"] = _box("TrimWall", Vector3(6.0, 3.0, 0.4), _at("trim", Vector3(0.0, 1.5, -2.2)), "slate")
	var w: Array = []
	w.append(_box("Wall1", Vector3(2.0, 3.0, 0.4), _at("trimwalls", Vector3(-2.0, 1.5, -0.2)), "slate"))
	w.append(_box("Wall2", Vector3(0.4, 3.0, 2.0), _at("trimwalls", Vector3(-1.2, 1.5, -1.0)), "slate"))
	w.append(_box("Wall3", Vector3(2.0, 3.0, 0.4), _at("trimwalls", Vector3(0.0, 1.5, -2.2)), "slate"))
	w.append(_box("Wall4", Vector3(2.0, 3.0, 0.4), _at("trimwalls", Vector3(1.707, 1.5, -1.434)), "slate", -45.0))
	st["walls"] = w
	st["csg_wall"] = _box("CsgWall", Vector3(4.0, 3.0, 0.6), _at("csg", Vector3(0.0, 1.5, 0.0)), "slate")
	var cutter := ShowcaseUtil.mesh(root, "Cutter", PBShapeCylinder.create_cylinder(0.75, 1.8, 16),
		_at("csg", Vector3(0.0, 1.5, 0.0)), ShowcaseUtil.checker_mat(root, "brick"))
	cutter.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	st["cutter"] = cutter
	st["prop"] = _load_prop()

func _load_prop() -> Node3D:
	var mi: MeshInstance3D = null
	if FileAccess.file_exists(PROP_GLB):
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		if doc.append_from_buffer(FileAccess.get_file_as_bytes(PROP_GLB), "", state) == OK:
			var scn := doc.generate_scene(state)
			for c in scn.get_children() if scn != null else []:
				if c is MeshInstance3D:
					scn.remove_child(c)
					mi = c
					break
				elif c is ImporterMeshInstance3D and (c as ImporterMeshInstance3D).mesh != null:
					mi = MeshInstance3D.new()
					mi.mesh = (c as ImporterMeshInstance3D).mesh.get_mesh()
					break
	if mi == null:
		d._log_line("prop GLB missing — a CylinderMesh stands in")
		mi = MeshInstance3D.new()
		mi.mesh = CylinderMesh.new()
	mi.name = "ImportedCrate"
	root.add_child(mi)
	mi.owner = root
	mi.transform = Transform3D.IDENTITY
	mi.scale = Vector3.ONE * 1.6
	mi.position = _at("import", Vector3.ZERO)
	var aabb := mi.global_transform * mi.get_aabb()
	mi.position.y -= aabb.position.y
	return mi

func _select_nodes(nodes: Array) -> void:
	await d.off(func():
		d.plugin.editor.selection.clear_all()
		var sel := EditorInterface.get_selection()
		sel.clear()
		for n in nodes:
			sel.add_node(n))
	await d.frames(4)

func _newest_pb(exclude: Array) -> PBMesh:
	var out: PBMesh = null
	for c in root.get_children():
		if c is PBMesh and c != bench and not exclude.has(c) and (c as PBMesh).visible:
			out = c
	return out

# -----------------------------------------------------------------------------

## A skirting in one drag: Trim from the New Shape menu, a drag along the
## wall's foot, the round profile in the modal.
func _trim() -> void:
	var known := root.get_children()
	await d.arm_shape(&"trim")
	var a := _at("trim", Vector3(-2.4, 0.0, -2.0))
	var b := _at("trim", Vector3(2.4, 0.0, -2.0))
	await d.glide_world_track(a, 16)
	await d.drag(d.w2s(a), d.w2s(b), 40, false, 1)
	await d.frames(14)
	d.check(d.plugin.tool_overlay.params_open, "the trim's modal opened")
	if d.plugin.tool_overlay.params_open:
		await d.overlay_param("profile", 2, 16)
		await d.overlay_param("height", 0.3, 14)
		await d.overlay_param("depth", 0.14, 14)
		await d.overlay_button("ApplyParams", 14)
	var trim := _newest_pb(known)
	d.check(trim != null, "a trim run was built")
	if trim != null:
		ShowcaseUtil.dress_material(trim, ShowcaseUtil.mat(root, "steel"))
	await d.key(KEY_ESCAPE)
	await d.cam_swing(_at("trim", Vector3(1.6, 0.22, -2.0)), 26.0, 70.0, 18.0, 11.0, 1.6, 70, 1)
	await d.frames(16)

## Trim Walls: click four walls in order, Enter — one run, mitred at every
## corner (inside, outside and a 45° bend).
func _trim_walls() -> void:
	var known := root.get_children()
	var box := AABB(_at("trimwalls", Vector3(-3.2, 0.0, -2.8)), Vector3(5.6, 3.2, 3.2))
	await d.frame_box_to(box, 30.0, 22.0, 0.82, 60)
	await d.click_button("trim_walls", 14)
	if d.plugin.tool_overlay.params_open:
		await d.overlay_param("profile", 2, 12)
		await d.overlay_param("height", 0.30, 10)
		await d.overlay_param("depth", 0.12, 10)
	for p in [Vector3(-2.0, 1.2, 0.0), Vector3(-1.0, 1.2, -1.0), Vector3(0.0, 1.2, -2.0), Vector3(1.7, 1.2, -1.3)]:
		await d.glide_world_track(_at("trimwalls", p), 16)
		await d.click(Vector2.INF, 14)
	await d.key(KEY_ENTER)
	await d.frames(16)
	var tw := _newest_pb(known)
	d.check(tw != null, "Trim Walls built the run")
	if tw != null:
		ShowcaseUtil.dress_material(tw, ShowcaseUtil.mat(root, "steel"))
	await d.cam_swing(_at("trimwalls", Vector3(-1.0, 0.2, -0.2)), 30.0, 62.0, 18.0, 11.0, 1.5, 72, 1)
	await d.cam_swing(_at("trimwalls", Vector3(0.4, 0.3, -1.4)), 62.0, 40.0, 11.0, 20.0, 3.6, 60, 1)

## CSG: the wall and the cutter selected, Subtract; Ctrl+Z puts it back,
## Ctrl+Shift+Z cuts again.
func _csg() -> void:
	var wall: PBMesh = st["csg_wall"]
	var cutter: PBMesh = st["cutter"]
	var f := d.framing_node(wall, 0.52, 24.0, 14.0)
	await d.frame_box_to(d.node_aabb(wall), 24.0, 14.0, 0.52, 60)
	await d.click_button("object", 8)
	await d.glide_world_track(_at("csg", Vector3(-1.4, 2.2, 0.3)), 18)
	await d.click()
	await d.glide_world_track(_at("csg", Vector3(0.0, 1.5, 0.9)), 18)
	await d.click(Vector2.INF, 10, ["shift"])
	var sel := EditorInterface.get_selection().get_selected_nodes()
	if not (sel.has(wall) and sel.has(cutter)):
		d._log_line("object clicks selected %s — selecting wall + cutter through the editor" % str(sel))
		await _select_nodes([wall, cutter])
	d.check(EditorInterface.get_selection().get_selected_nodes().size() == 2, "wall and cutter selected")
	var before := wall.pb_mesh_data.faces.size()
	await d.click_button("csg_subtract", 18)
	if wall.pb_mesh_data.faces.size() == before and cutter.is_inside_tree() and cutter.visible:
		d.plugin.call("_on_operation_requested", "csg_subtract")
		await d.frames(14)
		d._log_line("CSG subtract driven through the plugin (button click missed)")
	var cut := wall.pb_mesh_data.faces.size()
	d.check(cut != before, "subtract cut the wall (%d -> %d faces)" % [before, cut])
	await d.frames(40)
	await d.key(KEY_Z, {"ctrl": true})
	await d.frames(10)
	if wall.pb_mesh_data.faces.size() == cut:
		var ur := EditorInterface.get_editor_undo_redo()
		var h := ur.get_history_undo_redo(ur.get_object_history_id(wall))
		if h != null and h.has_undo():
			h.undo()
		d._log_line("undo driven through the history (Ctrl+Z missed)")
	d.check(wall.pb_mesh_data.faces.size() == before, "Ctrl+Z restored the wall (%d faces)" % wall.pb_mesh_data.faces.size())
	await d.frames(40)
	await d.key(KEY_Z, {"ctrl": true, "shift": true})
	await d.frames(10)
	if wall.pb_mesh_data.faces.size() == before:
		var ur2 := EditorInterface.get_editor_undo_redo()
		var h2 := ur2.get_history_undo_redo(ur2.get_object_history_id(wall))
		if h2 != null and h2.has_redo():
			h2.redo()
		d._log_line("redo driven through the history (Ctrl+Shift+Z missed)")
	d.check(wall.pb_mesh_data.faces.size() == cut, "redo cut it again (%d faces)" % wall.pb_mesh_data.faces.size())
	await d.frames(20)
	await d.cam_swing(f["center"], 24.0, -24.0, 14.0, 10.0, f["dist"] * 0.92, 70, 1, f["aim"])

## Poibuilderize: an imported GLB prop becomes an editable PoiBuilder mesh;
## a face is selected and pulled like any other.
func _import() -> void:
	var prop: Node3D = st["prop"]
	var known := root.get_children()
	await _select_nodes([prop])
	var box := (prop as MeshInstance3D).global_transform * (prop as MeshInstance3D).get_aabb()
	await d.frame_box_to(box, 28.0, 20.0, 0.42, 60)
	await d.click_button("poibuilderize", 20)
	var made := _newest_pb(known)
	if made == null:
		await _select_nodes([prop])
		d.plugin.call("_perform_poibuilderize")
		await d.frames(12)
		made = _newest_pb(known)
		d._log_line("poibuilderize driven through the plugin (button click missed)")
	d.check(made != null, "Poibuilderize produced a PBMesh")
	if made == null:
		return
	await _select_nodes([made])
	await d.click_button("face", 10)
	# The crate is open-topped: its front wall is the face to grab.
	var cbox := d.node_aabb(made)
	var pt := Vector3(cbox.get_center().x - cbox.size.x * 0.15, cbox.get_center().y, cbox.end.z - 0.01)
	await d.glide_world_track(pt, 18)
	await d.click()
	if d.subgizmo_ids().is_empty():
		d._log_line("prop face click missed")
	d.check(not d.subgizmo_ids().is_empty(), "a face of the imported prop is selected")
	await d.frames(12)
	var faces0: int = made.pb_mesh_data.faces.size()
	await d.glide(d.drag_cursor_for(Vector3.ZERO), 10)
	# A plain move: an extrude of an imported face reports a degenerate
	# region normal (reported in v0.9.189's notes), and the film shows what works.
	var zmax0 := d.node_aabb(made).end.z
	await d.move_selection(Vector3(0.0, 0.0, 0.5), 44)
	d.check(d.node_aabb(made).end.z > zmax0 + 0.3, "the crate's wall moved out (front %.2f -> %.2f)" % [zmax0, d.node_aabb(made).end.z])
	await d.frames(10)
	var f := d.framing(d.node_aabb(made), 0.5, 32.0, 20.0)
	await d.cam_swing(f["center"], 32.0, 70.0, 20.0, 28.0, f["dist"], 60, 1, f["aim"])
