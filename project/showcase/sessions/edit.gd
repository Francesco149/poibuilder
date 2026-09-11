## ACT — direct mesh editing. One beat per capability, each on a clean object
## so the viewer sees exactly what changed: selection, edge loops, snapping,
## extrude, inset, subdivide, loop cut, merge, weld, detach, delete, knife,
## n-gon drawing.
##
## House style for a beat:
##   1. off-capture setup: clear the bench, build the object, frame the camera
##      (nothing that happens before the first captured frame is in the shot)
##   2. a toolbar click / mode change, then the pointer travels to the target
##      WHILE the camera drifts (orbit_glide keeps the pointer on the point)
##   3. the operation, then a trailing camera swing so the cut has life
@tool
extends RefCounted

var director: ShowcaseDirector
var d: ShowcaseDirector
var root: Node
var bench: PBMesh
var obj: PBMesh

const TOP := 2.0                       # a 2 m cube sitting on the bench

func run(dr: ShowcaseDirector) -> void:
	d = dr
	# Tighter than the default framing: the video is watched at README
	# size, so subjects should sit large in the frame.
	d.fill_scale = 1.35
	root = EditorInterface.get_edited_scene_root()
	ShowcaseUtil.env(d.plugin, "day")
	ShowcaseUtil.grade_light(root)
	bench = ShowcaseUtil.floor_slab(root, 34.0, ShowcaseUtil.mat(root, "ink"))
	await d.frames(20)

	await d.shot("edit/select", _select)
	await d.shot("edit/edge_loop", _edge_loop)
	await d.shot("edit/move", _move)
	await d.shot("edit/extrude", _extrude)
	await d.shot("edit/inset", _inset)
	await d.shot("edit/subdivide", _subdivide)
	await d.shot("edit/loopcut", _loopcut)
	await d.shot("edit/merge", _merge)
	await d.shot("edit/weld", _weld)
	await d.shot("edit/detach", _detach)
	await d.shot("edit/delete", _delete)
	await d.shot("edit/knife", _knife)
	await d.shot("edit/ngon", _ngon)
	d.snapshot_regions()

# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------

## Removes every demo object, leaving the bench.
func _clear() -> void:
	EditorInterface.get_selection().clear()
	for c in root.get_children():
		if c is PBMesh and c != bench:
			root.remove_child(c)
			c.free()

## Builds a fresh object, selects it, and frames the camera on it — all before
## the first captured frame of the beat.
func _fresh(name: String, data: PBMeshData, color := "steel", pos := Vector3.ZERO,
		fill := 0.40, az := 30.0, elev := 24.0) -> PBMesh:
	var node: PBMesh = await d.off(func():
		_clear()
		var n := ShowcaseUtil.mesh(root, name, data, pos, ShowcaseUtil.mat(root, color))
		ShowcaseUtil.drop_on_ground(n)
		EditorInterface.get_selection().add_node(n)
		var f := d.framing_node(n, fill, az, elev)
		d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
		return n)
	await d.frames(6)
	return node

func _look(node: Node3D, fill := 0.40, az := 30.0, elev := 24.0) -> Dictionary:
	var f := d.framing_node(node, fill, az, elev)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(3)
	return f

## World position just under the mesh's highest point (a click target on the
## top face that survives the object growing during the beat).
func _top_world(node: PBMesh, inset := 0.02) -> Vector3:
	return node.to_global(Vector3(0.0, _top_of(node) - inset, 0.0))

## Distance between the mesh vertices nearest two world points — the observable
## result of a weld, which moves corners without changing any count.
func _corner_gap(node: PBMesh, a: Vector3, b: Vector3) -> float:
	return _nearest_vertex(node, a).distance_to(_nearest_vertex(node, b))

func _nearest_vertex(node: PBMesh, world: Vector3) -> Vector3:
	var best := Vector3.ZERO
	var best_d := INF
	for p in node.pb_mesh_data.positions:
		var w: Vector3 = node.to_global(p)
		var dist := w.distance_to(world)
		if dist < best_d:
			best_d = dist
			best = w
	return best

## Highest vertex of the mesh in LOCAL space — the observable result of a move.
func _top_of(node: PBMesh) -> float:
	var top := -INF
	for p in node.pb_mesh_data.positions:
		top = maxf(top, p.y)
	return top

## The element selection size for the current mode (mirrors the editor).
func _sel_count() -> int:
	if d.active_mesh() == null:
		return 0
	return d.subgizmo_ids().size()

# -----------------------------------------------------------------------------
# beats
# -----------------------------------------------------------------------------

func _select() -> void:
	obj = await _fresh("DemoCube", PBMeshData.create_cube(2.0), "steel", Vector3.ZERO, 0.38, 30.0, 22.0)
	var f := d.framing_node(obj, 0.38, 30.0, 22.0)
	await d.click_button("face")
	await d.orbit_glide(f["center"], 30.0, 40.0, 22.0, f["dist"],
		Vector3(0.0, 1.0, 1.0), 22, f["aim"])
	await d.glide_world_track(Vector3(1.0, 1.0, 0.2), 14)
	await d.glide_world_track(Vector3(0.2, TOP, 0.0), 16)
	await d.click()
	d.check(_sel_count() == 1, "one face selected")
	await d.swing_framing(d.framing_node(obj, 0.38, 40.0, 22.0), 30, 12.0, -2.0)

func _edge_loop() -> void:
	obj = await _fresh("DemoCube", PBMeshData.create_cube(2.0), "brick", Vector3.ZERO, 0.38, 34.0, 24.0)
	var f := d.framing_node(obj, 0.38, 34.0, 24.0)
	await d.click_button("edge")
	await d.orbit_glide(f["center"], 34.0, 44.0, 24.0, f["dist"],
		Vector3(1.0, 0.0, 1.0), 24, f["aim"])
	await d.click(Vector2.INF, 12, ["alt"])
	var sel = d.plugin.editor.selection
	d.check(sel.selected_edges.size() >= 4,
		"alt+click expanded the edge to its ring (%d edges)" % sel.selected_edges.size())
	await d.swing_framing(d.framing_node(obj, 0.38, 44.0, 24.0), 34, 14.0, -3.0)
	await d.click_button("face")

func _move() -> void:
	obj = await _fresh("DemoCube", PBMeshData.create_cube(2.0), "slate", Vector3.ZERO, 0.40, 28.0, 24.0)
	var f := d.framing_node(obj, 0.40, 28.0, 24.0)
	await d.click_button("face")
	await d.orbit_glide(f["center"], 28.0, 36.0, 24.0, f["dist"],
		Vector3(0.0, TOP, 0.0), 22, f["aim"])
	await d.click()
	d.check(_sel_count() == 1, "top face selected for the move")
	await d.click_button("move")
	var top0: float = _top_of(obj)
	await d.move_selection(Vector3(0.0, 0.7, 0.0), 46)
	d.check(absf(_top_of(obj) - top0) > 0.05,
		"geometry moved (top %.2f -> %.2f)" % [top0, _top_of(obj)])
	await d.cam_swing(f["center"] + Vector3(0, 0.35, 0), 36.0, 26.0, 24.0, 21.0,
		f["dist"] * 1.06, 26, 1, f["aim"])

func _extrude() -> void:
	obj = await _fresh("DemoCube", PBMeshData.create_cube(2.0), "steel", Vector3.ZERO, 0.34, 30.0, 22.0)
	var f := d.framing_node(obj, 0.34, 30.0, 22.0)
	await d.click_button("face")
	await d.orbit_glide(f["center"], 30.0, 38.0, 22.0, f["dist"],
		Vector3(0.0, TOP, 0.0), 22, f["aim"])
	await d.click()
	d.check(_sel_count() == 1, "top face selected for the extrude")
	var before: int = obj.pb_mesh_data.faces.size()
	await d.move_selection(Vector3(0.0, 1.4, 0.0), 54, true)
	d.check(obj.pb_mesh_data.faces.size() > before,
		"shift+drag extruded (%d -> %d faces)" % [before, obj.pb_mesh_data.faces.size()])
	await d.cam_swing(f["center"] + Vector3(0, 0.7, 0), 38.0, 26.0, 22.0, 19.0,
		f["dist"] * 1.4, 28, 1, f["aim"])

func _inset() -> void:
	# The extruded cap from the previous beat is still there; select it again.
	await d.tool("scale")
	var cap_world := _top_world(obj)
	var f := d.framing_node(obj, 0.34, 30.0, 24.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(3)
	await d.glide_world_track(cap_world, 20)
	await d.click()
	d.check(_sel_count() == 1, "extruded cap re-selected")
	var before: int = obj.pb_mesh_data.faces.size()
	await d.scale_selection_factor(0.42, 52, true)
	d.check(obj.pb_mesh_data.faces.size() > before,
		"shift+centre inset (%d -> %d faces)" % [before, obj.pb_mesh_data.faces.size()])
	await d.cam_swing(f["center"], 30.0, 42.0, 24.0, 28.0, f["dist"], 26, 1, f["aim"])

func _subdivide() -> void:
	obj = await _fresh("DemoSlab", PBShapeGenerators.create_box(Vector3(4.0, 0.6, 4.0)),
		"slate", Vector3.ZERO, 0.52, 30.0, 32.0)
	var f := d.framing_node(obj, 0.52, 30.0, 32.0)
	await d.click_button("face")
	await d.orbit_glide(f["center"], 30.0, 38.0, 32.0, f["dist"],
		_top_world(obj), 20, f["aim"])
	await d.click()
	d.check(_sel_count() == 1, "slab top selected")
	var before: int = obj.pb_mesh_data.faces.size()
	await d.op("subdivide_faces", 20)
	d.check(obj.pb_mesh_data.faces.size() > before,
		"subdivide: %d -> %d faces" % [before, obj.pb_mesh_data.faces.size()])
	await d.cam_swing(f["center"], 38.0, 52.0, 32.0, 26.0, f["dist"], 30, 1, f["aim"])

func _loopcut() -> void:
	obj = await _fresh("DemoBox", PBShapeGenerators.create_box(Vector3(3.0, 2.0, 3.0)),
		"steel", Vector3.ZERO, 0.40, 40.0, 20.0)
	var f := d.framing_node(obj, 0.40, 40.0, 20.0)
	await d.click_button("edge")
	# Exactly the mid-point of the front-right VERTICAL edge: a corner click or
	# a face-centre click lands on whichever edge is nearest, and the ring walk
	# (and therefore the cut) depends on which edge that is.
	await d.orbit_glide(f["center"], 40.0, 48.0, 20.0, f["dist"],
		Vector3(1.5, 1.0, 1.5), 22, f["aim"])
	await d.click()
	d.check(_sel_count() == 1, "vertical edge selected")
	d.check(d.plugin.editor.selection.selected_edges.size() >= 1,
		"edge selection mirrored into the plugin")
	var before: int = obj.pb_mesh_data.faces.size()
	await d.op("insert_edge_loop", 20)
	d.check(obj.pb_mesh_data.faces.size() > before,
		"loop cut: %d -> %d faces" % [before, obj.pb_mesh_data.faces.size()])
	await d.cam_swing(f["center"], 48.0, 60.0, 20.0, 26.0, f["dist"], 26, 1, f["aim"])
	await d.click_button("face")

func _merge() -> void:
	obj = await _fresh("DemoSlab", PBShapeGenerators.create_box(Vector3(4.0, 0.6, 4.0)),
		"brick", Vector3.ZERO, 0.52, 26.0, 34.0)
	var f := d.framing_node(obj, 0.52, 26.0, 34.0)
	await d.click_button("face")
	await d.orbit_glide(f["center"], 26.0, 32.0, 34.0, f["dist"],
		_top_world(obj), 18, f["aim"])
	await d.click()
	await d.op("subdivide_faces", 16)          # 4 coplanar quads to merge back
	var before: int = obj.pb_mesh_data.faces.size()
	await d.glide_world_track(Vector3(-0.7, _top_world(obj).y, 0.7), 14)
	var picked := await d.select_points([
		Vector3(-0.7, _top_world(obj).y, 0.7),
		Vector3(0.7, _top_world(obj).y, 0.7)])
	d.check(picked == 2, "two adjacent faces selected (%d)" % picked)
	await d.op("merge_faces", 20)
	d.check(obj.pb_mesh_data.faces.size() < before,
		"merge: %d -> %d faces" % [before, obj.pb_mesh_data.faces.size()])
	await d.cam_swing(f["center"], 32.0, 44.0, 34.0, 28.0, f["dist"], 26, 1, f["aim"])

func _weld() -> void:
	obj = await _fresh("DemoCube", PBMeshData.create_cube(2.0), "slate", Vector3.ZERO, 0.40, 34.0, 24.0)
	var f := d.framing_node(obj, 0.40, 34.0, 24.0)
	await d.click_button("vertex")
	await d.orbit_glide(f["center"], 34.0, 40.0, 24.0, f["dist"],
		Vector3(-1.0, TOP, 1.0), 22, f["aim"])
	var corner_a := Vector3(-1.0, TOP, 1.0)
	var corner_b := Vector3(1.0, TOP, 1.0)
	var verts := await d.select_points([corner_a, corner_b])
	d.check(verts >= 2, "two vertices selected (%d)" % verts)
	# A weld moves corners together; it adds and removes nothing, so the
	# observable result is the GAP between them closing.
	var gap_before := _corner_gap(obj, corner_a, corner_b)
	await d.op_verify("weld_vertices",
		func(): return snappedf(_corner_gap(obj, corner_a, corner_b), 0.05), 20)
	var gap_after := _corner_gap(obj, corner_a, corner_b)
	d.check(gap_after < gap_before * 0.6,
		"weld closed the corner gap (%.2f -> %.2f)" % [gap_before, gap_after])
	await d.cam_swing(f["center"], 40.0, 54.0, 24.0, 28.0, f["dist"], 26, 1, f["aim"])
	await d.click_button("face")

func _detach() -> void:
	obj = await _fresh("DemoCube", PBMeshData.create_cube(2.0), "steel", Vector3.ZERO, 0.40, 30.0, 24.0)
	var f := d.framing_node(obj, 0.40, 30.0, 24.0)
	await d.click_button("face")
	await d.orbit_glide(f["center"], 30.0, 38.0, 24.0, f["dist"],
		Vector3(0.0, 1.0, 1.0), 22, f["aim"])
	await d.click()
	d.check(_sel_count() == 1, "face selected for detach")
	await d.op("detach_faces", 22)
	# The detached sibling is named "<source>_Detached" (the plugin's own
	# naming), so match on the suffix rather than on a prefix.
	var made := []
	for c in root.get_children():
		if String(c.name).contains("_Detached"):
			made.append(c)
	d.check(made.size() == 1, "detach spawned a new node (%d)" % made.size())
	await d.cam_swing(f["center"], 38.0, 52.0, 24.0, 28.0, f["dist"], 30, 1, f["aim"])

func _delete() -> void:
	obj = await _fresh("DemoCube", PBMeshData.create_cube(2.0), "brick", Vector3.ZERO, 0.40, 30.0, 24.0)
	var f := d.framing_node(obj, 0.40, 30.0, 24.0)
	await d.click_button("face")
	await d.orbit_glide(f["center"], 30.0, 38.0, 24.0, f["dist"],
		Vector3(0.0, 1.0, 1.0), 22, f["aim"])
	await d.click()
	var before: int = obj.pb_mesh_data.faces.size()
	await d.op("delete_faces", 20)
	d.check(obj.pb_mesh_data.faces.size() < before,
		"delete: %d -> %d faces" % [before, obj.pb_mesh_data.faces.size()])
	await d.cam_swing(f["center"], 38.0, 50.0, 24.0, 28.0, f["dist"], 26, 1, f["aim"])

func _knife() -> void:
	obj = await _fresh("DemoSlab", PBShapeGenerators.create_box(Vector3(4.0, 1.0, 4.0)),
		"slate", Vector3.ZERO, 0.52, 26.0, 38.0)
	var f := d.framing_node(obj, 0.52, 26.0, 38.0)
	await d.click_button("knife_tool", 14)
	# two points across the top face, then Enter cuts it in two
	# Three points: the first click only arms the plane, so a two-click path can
	# leave the cutter with a single vertex ("closed cut requires at least 3").
	var cut := [-1.7, 0.0, 1.7]
	await d.orbit_glide(f["center"], 26.0, 30.0, 38.0, f["dist"],
		Vector3(cut[0], _top_world(obj).y, 0.0), 24, f["aim"])
	await d.click()
	await d.glide_world_track(Vector3(cut[1], _top_world(obj).y, 0.35), 14)
	await d.click()
	await d.glide_world_track(Vector3(cut[2], _top_world(obj).y, 0.7), 14)
	await d.click()
	var before: int = obj.pb_mesh_data.faces.size()
	await d.key(KEY_ENTER)
	await d.frames(6)
	d.check(obj.pb_mesh_data.faces.size() > before,
		"knife cut: %d -> %d faces" % [before, obj.pb_mesh_data.faces.size()])
	await d.cam_swing(f["center"], 30.0, 48.0, 38.0, 28.0, f["dist"], 30, 1, f["aim"])

func _ngon() -> void:
	await d.off(func(): _clear())
	var f := d.framing(AABB(Vector3(-1.8, 0.0, -1.8), Vector3(3.6, 1.8, 3.6)), 0.62, 24.0, 38.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(4)
	await d.click_button("ngon", 14)
	var pts := [Vector3(-1.2, 0.0, -1.0), Vector3(1.1, 0.0, -1.2), Vector3(1.4, 0.0, 0.6),
		Vector3(0.0, 0.0, 1.4), Vector3(-1.3, 0.0, 0.8)]
	for p in pts:
		await d.glide_world_track(p, 12)
		await d.click(Vector2.INF, 4)
	await d.key(KEY_ENTER)
	await d.frames(6)
	await d.glide_world_track(Vector3(0.0, 1.4, 0.0), 24)
	await d.click()
	await d.frames(6)
	var made := ShowcaseUtil.names_of(root, "Shape_Ngon")
	d.check(made.size() >= 1, "n-gon prism created (%d)" % made.size())
	if made.size() > 0:
		obj = made[0]
		var f2 := d.framing_node(obj, 0.42, 30.0, 24.0)
		await d.cam_swing(f2["center"], 30.0, 54.0, 24.0, 20.0, f2["dist"], 44, 1, f2["aim"])
