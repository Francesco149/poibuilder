## SESSION — "v2_edit": the Edit chapter of showcase v2 (edl_v2*.toml).
##
## One long workbench instead of one fresh set per beat: every object the
## chapter edits is laid out along +X before the first frame, and the camera
## TRAVELS from station to station. A beat starts where the last one stopped
## (same light, same pointer, the camera easing on), so the cut can run takes
## back to back without a jump. Shots split the take for the EDL only.
##
## The PoiBuilder toolbar is the UI here (every op is a toolbar click, the
## element modes too), framed with the 3D view as "viewport_ui"; the dock is
## out of the picture. The floating panel stays on: it is the selection
## readout and the bevel's live-preview modal.
##
## Lead beat: the arched doorway's front is ONE n-gon (hole and all). It is
## hovered in each element mode, clicked as a whole, and extruded, scaled and
## extruded again into a deep flared portal.
##
## Render: PB_SHOWCASE_LAYOUT=showcase_video/layouts/tour.cfg \
##         ./showcase_video/render.sh v2_edit
@tool
extends RefCounted

var d: ShowcaseDirector
var root: Node
var bench: PBMesh
var st: Dictionary = {}          # station name -> PBMesh

## Station spacing along +X: wide enough that the neighbours stay out of a
## station's own framing, close enough that the travel between them is short.
const GAP := 16.0
const ORDER := ["door", "chimney", "loop", "slab", "house", "bevel", "weld", "cube", "knife", "ngon", "smart"]

func run(dr: ShowcaseDirector) -> void:
	d = dr
	d.fill_scale = 1.3
	root = EditorInterface.get_edited_scene_root()
	ShowcaseUtil.env(d.plugin, "day")
	ShowcaseUtil.grade_light(root)
	ShowcaseUtil.fresh_grid(d.plugin)
	ShowcaseUtil.use_default_material(ShowcaseUtil.CHECKER)
	d.plugin.set_placement_style(PBShapeCreator.PlacementStyle.DRAG)
	bench = ShowcaseUtil.floor_slab(root, 160.0, ShowcaseUtil.mat(root, "ink"))
	bench.position.x = GAP * 4.5
	await d.grid_show(false)
	d.plugin.material_dock.set_thumbnail_size(64)
	if d.plugin.mode_banner != null:
		d.plugin.mode_banner.modulate.a = 0.0
	# Rows 3/4 (Trim Walls, CSG, V-Snap...) ship visible; only unfold if folded.
	await d.off(func():
		if not d.plugin.toolbar._extended_visible:
			await d.click_button("split", 10))
	_build_stations()
	# Video readability: a stronger selection / hover fill than the editor's
	# defaults, so a selected face reads at README size (restored at the end).
	d.plugin.gizmo_plugin.apply_display_opacities(0.7, 1.0, 0.6)
	await d.frames(6)
	d.snapshot_regions()
	await d.lift_panel(80.0)
	await _select_node(st["door"])
	var f := d.framing_node(st["door"], 0.4, 24.0, 16.0)
	d.cam_at_polar(f["center"], 24.0, 16.0, f["dist"], f["aim"])
	await d.frames(20)

	for s in [["v2e/modes", _modes], ["v2e/portal", _portal], ["v2e/chimney", _chimney],
			["v2e/loopcut", _loopcut], ["v2e/subdiv", _subdiv], ["v2e/merge", _merge],
			["v2e/crease", _crease], ["v2e/bevel", _bevel], ["v2e/weld", _weld], ["v2e/cube", _cube_ops],
			["v2e/knife", _knife], ["v2e/ngon", _ngon], ["v2e/smart", _smart]]:
		if d.only_done():
			break
		await d.shot(s[0], s[1])
	d.plugin.gizmo_plugin.apply_display_opacities(0.7, 0.25, 0.25)

# -----------------------------------------------------------------------------
# the set
# -----------------------------------------------------------------------------

func _station(name: String) -> Vector3:
	return Vector3(GAP * float(ORDER.find(name)), 0.0, 0.0)

func _build_stations() -> void:
	var mk := func(name: String, data: PBMeshData, color: String) -> PBMesh:
		var n := ShowcaseUtil.mesh(root, "V2_" + name.capitalize(), data, _station(name),
			ShowcaseUtil.checker_mat(root, color))
		ShowcaseUtil.drop_on_ground(n)
		st[name] = n
		return n
	mk.call("door", PBShapeComplex.create_door(3.0, 3.2, 2.4, 0.5, 1.0, true, 8), "slate")
	mk.call("chimney", PBMeshData.create_cube(2.0), "brick")
	mk.call("loop", PBShapeGenerators.create_box(Vector3(3.0, 2.0, 3.0)), "slate")
	mk.call("slab", PBShapeGenerators.create_box(Vector3(4.0, 0.6, 4.0)), "steel")
	mk.call("house", ShowcaseUtil.create_house(Vector3(2.4, 1.8, 3.2), 1.2), "moss")
	mk.call("bevel", PBMeshData.create_cube(2.0), "plum")
	mk.call("weld", PBMeshData.create_cube(2.0), "moss")
	mk.call("cube", PBMeshData.create_cube(2.0), "slate")
	mk.call("knife", PBShapeGenerators.create_box(Vector3(4.0, 1.0, 4.0)), "stone")
	mk.call("smart", PBShapeGenerators.create_box(Vector3(2.4, 2.4, 2.4), 3, 3, 3), "steel")

## A point given in the v1 beats' coordinates (object at the origin, resting on
## the floor) at this station.
func _at(name: String, p: Vector3) -> Vector3:
	return _station(name) + p

## Makes `node` the edited object (what a click on it in Object mode does).
func _select_node(node: Node) -> void:
	await d.off(func():
		d.plugin.editor.selection.clear_all()
		var sel := EditorInterface.get_selection()
		sel.clear()
		sel.add_node(node))
	await d.frames(4)

## Eased camera travel to a station, the edited object switching on the way.
func _travel(name: String, az: float, elev: float, fill: float, n := 54) -> Dictionary:
	var node: PBMesh = st.get(name, null)
	var box: AABB = d.node_aabb(node) if node != null else AABB(_station(name) + Vector3(-1.8, 0.0, -1.8), Vector3(3.6, 1.8, 3.6))
	if node != null:
		await _select_node(node)
	await d.frame_box_to(box, az, elev, fill, n)
	return d.framing(box, fill, az, elev)

func _sel_count() -> int:
	return d.subgizmo_ids().size() if d.active_mesh() != null else 0

func _mesh() -> PBMesh:
	return d.active_mesh() as PBMesh

func _faces(node: PBMesh) -> int:
	return node.pb_mesh_data.faces.size()

func _face_center(node: PBMesh, fi: int) -> Vector3:
	var acc := Vector3.ZERO
	var idxs: PackedInt32Array = node.pb_mesh_data.faces[fi].get_distinct_indexes()
	for i in idxs:
		acc += node.to_global(node.pb_mesh_data.positions[i])
	return acc / float(maxi(1, idxs.size()))

func _corners(node: PBMesh, fi: int) -> int:
	return node.pb_mesh_data.faces[fi].get_distinct_indexes().size()

func _selected_faces() -> Array:
	return Array(d.plugin.editor.selection.selected_faces)

## Clicks a world point; if the plugin's picker did not land on a face near
## `expect_near` (when given), the intended face is written through the
## selection protocol instead and the miss is logged — the beat must not go
## on to extrude the wrong face.
func _click_face(world: Vector3, glide_n := 20, hold: Array = [], expect_near := Vector3.INF) -> void:
	await d.glide_world_track(world, glide_n)
	await d.click(Vector2.INF, 10, hold)
	if expect_near == Vector3.INF:
		return
	var m := _mesh()
	if m == null:
		return
	var ok := false
	for fi in _selected_faces():
		if _face_center(m, int(fi)).distance_to(expect_near) < 0.6:
			ok = true
	if not ok:
		var best := -1
		var best_d := INF
		for fi in range(_faces(m)):
			var dist := _face_center(m, fi).distance_to(expect_near)
			if dist < best_d:
				best_d = dist
				best = fi
		d._log_line("face click missed near %s (got %s) — selecting face %d via the protocol" % [
			str(expect_near), str(_selected_faces()), best])
		d.apply_selection_ids(PackedInt32Array([best]))
		await d.frames(4)

## Shift+click a face into the selection. A click that lands on the gizmo
## (its arrows reach across neighbouring faces) is a drag, not a pick: if the
## face did not join, it is added through the selection protocol (logged).
func _add_face(world: Vector3, glide_n := 18) -> void:
	var before := _selected_faces()
	await _click_face(world, glide_n, ["shift"])
	var m := _mesh()
	if m == null or _selected_faces().size() > before.size():
		return
	var best := -1
	var best_d := INF
	for fi in range(_faces(m)):
		var dist := _face_center(m, fi).distance_to(world)
		if dist < best_d:
			best_d = dist
			best = fi
	var ids := PackedInt32Array(before)
	if best >= 0 and not ids.has(best):
		ids.append(best)
	d._log_line("shift-click near %s did not add a face — adding %d via the protocol" % [str(world), best])
	d.apply_selection_ids(ids)
	await d.frames(4)

## Exactly one face selected: a plain click inside a multi-selection keeps
## the selection (it is the start of a drag), so the pick is enforced.
func _only_face(world: Vector3) -> void:
	await _click_face(world, 16, [], world)
	if _selected_faces().size() == 1:
		return
	var m := _mesh()
	var best := -1
	var best_d := INF
	for fi in range(_faces(m)):
		var dist := _face_center(m, fi).distance_to(world)
		if dist < best_d:
			best_d = dist
			best = fi
	d._log_line("click kept a %d-face selection — picking face %d via the protocol" % [_selected_faces().size(), best])
	d.apply_selection_ids(PackedInt32Array([best]))
	await d.frames(4)

## The face of `node` with the most corners whose centre lies furthest along
## `dir` (the doorway's front n-gon, the cap an extrude produced...).
func _extreme_face(node: PBMesh, dir: Vector3, min_corners := 3) -> int:
	var best := -1
	var best_v := -INF
	for fi in range(_faces(node)):
		if _corners(node, fi) < min_corners:
			continue
		var v := _face_center(node, fi).dot(dir)
		if v > best_v + 0.001:
			best_v = v
			best = fi
	return best

# -----------------------------------------------------------------------------
# beats
# -----------------------------------------------------------------------------

## Vertex, edge, face: the same doorway hovered in each mode, then the whole
## front (one n-gon that wraps the arch) picked with a single click.
func _modes() -> void:
	var door: PBMesh = st["door"]
	var f := d.framing_node(door, 0.4, 24.0, 16.0)
	await d.click_button("vertex", 8)
	await d.glide_world_track(_at("door", Vector3(-1.5, 3.2, 0.5)), 22)
	await d.frames(10)
	await d.glide_world_track(_at("door", Vector3(-1.0, 0.0, 0.5)), 26)
	await d.frames(8)
	await d.click_button("edge", 8)
	await d.glide_world_track(_at("door", Vector3(-0.9, 2.0, 0.5)), 20)
	await d.frames(8)
	await d.glide_world_track(_at("door", Vector3(0.0, 3.2, 0.5)), 24)
	await d.frames(8)
	await d.click_button("face", 8)
	# The lintel: one hover lights the WHOLE front, arch perimeter included.
	await d.glide_world_track(_at("door", Vector3(-0.5, 2.85, 0.5)), 22)
	await d.frames(24)
	var front := _extreme_face(door, Vector3(0, 0, 1), 5)
	await _click_face(_at("door", Vector3(-0.5, 2.85, 0.5)), 6, [], _face_center(door, front))
	d.check(_sel_count() == 1 and _corners(door, int(_selected_faces()[0])) > 4,
		"one click selected the front n-gon (%d corners)" % (_corners(door, int(_selected_faces()[0])) if not _selected_faces().is_empty() else 0))
	await d.frames(20)
	await d.cam_swing(f["center"], 24.0, 32.0, 16.0, 17.0, f["dist"], 30, 1, f["aim"])

## Extrudes that build: the selected n-gon pulled out (the arch deepens
## with it), then the two top quads that leaves: extrude, scale out (a
## cornice), extrude again, taper (a roof) — the classic ProBuilder chain.
func _portal() -> void:
	var door: PBMesh = st["door"]
	var front0 := _extreme_face(door, Vector3(0, 0, 1), 5)
	var z0 := _face_center(door, front0).z
	# 1. Shift+drag the whole front n-gon out.
	var faces0 := _faces(door)
	await d.glide(d.drag_cursor_for(Vector3.ZERO), 14)
	await d.frames(6)
	await d.move_selection(Vector3(0.0, 0.0, 0.8), 50, true)
	var cap := _extreme_face(door, Vector3(0, 0, 1), 5)
	var pulled := _face_center(door, cap).z - z0
	d.check(_faces(door) > faces0 and pulled > 0.7,
		"Shift+drag extruded the n-gon %.2f m (%d -> %d faces)" % [pulled, faces0, _faces(door)])
	await d.frames(12)
	# 2. The top is two quads now; the second click lands well clear of the
	# gizmo the first one raised.
	var roof_box := d.node_aabb(door)
	roof_box.size.y += 1.8
	await d.frame_box_to(roof_box, 34.0, 28.0, 0.62, 44)
	var t1 := _at("door", Vector3(-1.1, 3.2, z0 + pulled * 0.6))
	var t2 := _at("door", Vector3(1.1, 3.2, -0.3))
	await _click_face(t1, 20)
	await _add_face(t2, 18)
	d.check(_sel_count() == 2, "both top quads selected (%d)" % _sel_count())
	await d.frames(10)
	var faces1 := _faces(door)
	# extrude a short band...
	await d.glide(d.drag_cursor_for(Vector3.ZERO), 12)
	await d.move_selection(Vector3(0.0, 0.4, 0.0), 36, true)
	# ...scale it out into a cornice...
	await d.click_button("scale", 8)
	await d.scale_selection_factor(1.14, 36)
	# ...extrude again, and taper it into a roof.
	await d.click_button("move", 8)
	await d.glide(d.drag_cursor_for(Vector3.ZERO), 10)
	await d.move_selection(Vector3(0.0, 1.0, 0.0), 40, true)
	await d.click_button("scale", 8)
	await d.scale_selection_factor(0.45, 44)
	await d.click_button("move", 8)
	d.check(_faces(door) > faces1 + 6 and d.node_aabb(door).end.y > 4.4,
		"the top became a cornice and a roof (%d -> %d faces, top %.2f)" % [faces1, _faces(door), d.node_aabb(door).end.y])
	await d.frames(14)
	var g := d.framing(d.node_aabb(door).grow(0.2), 0.62, 34.0, 28.0)
	await d.cam_swing(g["center"], 34.0, 70.0, 28.0, 16.0, g["dist"], 90, 1, g["aim"])
	await d.cam_swing(g["center"], 70.0, 12.0, 16.0, 12.0, g["dist"] * 1.04, 90, 1, g["aim"])

## Inset, extrude, inset, extrude down: a hollow chimney from a plain cube.
func _chimney() -> void:
	var c: PBMesh = st["chimney"]
	await _travel("chimney", 30.0, 30.0, 0.34)
	var top := _at("chimney", Vector3(0.0, 2.0, 0.0))
	await _click_face(top, 18, [], top)
	await d.frames(8)
	await d.click_button("scale", 8)
	var faces0 := _faces(c)
	await d.scale_selection_factor(0.55, 52, true)
	d.check(_faces(c) > faces0, "Shift+scale inset the top (%d -> %d faces)" % [faces0, _faces(c)])
	await d.frames(8)
	await d.click_button("move", 8)
	if _sel_count() == 0:
		await _click_face(top, 12, [], top)
	await d.glide(d.drag_cursor_for(Vector3.ZERO), 10)
	await d.move_selection(Vector3(0.0, 1.3, 0.0), 46, true)
	await d.frames(8)
	var top2 := _at("chimney", Vector3(0.0, 3.3, 0.0))
	d.check(d.node_aabb(c).end.y > 3.1, "the inner face extruded into a stack (top %.2f)" % d.node_aabb(c).end.y)
	await d.frame_box_to(d.node_aabb(c), 30.0, 44.0, 0.40, 30)
	await d.click_button("scale", 8)
	if _sel_count() == 0:
		await _click_face(top2, 12, [], top2)
	await d.scale_selection_factor(0.7, 40, true)
	await d.frames(6)
	await d.click_button("move", 8)
	if _sel_count() == 0:
		await _click_face(top2, 12, [], top2)
	await d.glide(d.drag_cursor_for(Vector3.ZERO), 10)
	await d.move_selection(Vector3(0.0, -0.9, 0.0), 40, true)
	d.check(d.node_aabb(c).end.y > 3.1, "the rim stays, the hole goes down (top %.2f)" % d.node_aabb(c).end.y)
	await d.frames(10)
	var g := d.framing_node(c, 0.40, 30.0, 44.0)
	await d.cam_swing(g["center"], 30.0, 58.0, 44.0, 52.0, g["dist"], 56, 1, g["aim"])

## Loop cut on a vertical edge: the cut turns all four corners (an orbit shows
## each side), then Alt+click selects the new loop and it slides up as one.
func _loopcut() -> void:
	var box: PBMesh = st["loop"]
	var f: Dictionary = await _travel("loop", 40.0, 18.0, 0.48)
	await d.click_button("edge", 8)
	await d.glide_world_track(_at("loop", Vector3(1.5, 1.0, 1.5)), 20)
	await d.click()
	d.check(_sel_count() == 1, "a vertical edge selected")
	var before := _faces(box)
	await d.op("insert_edge_loop", 20)
	d.check(_faces(box) == before + 4, "the loop cut split all four sides (%d -> %d)" % [before, _faces(box)])
	await d.cam_swing(f["center"], 40.0, 160.0, 18.0, 26.0, f["dist"], 84, 1, f["aim"])
	await d.cam_swing(f["center"], 160.0, 42.0, 26.0, 20.0, f["dist"], 72, 1, f["aim"])
	await d.glide_world_track(_at("loop", Vector3(0.0, 1.0, 1.5)), 18)
	await d.click(Vector2.INF, 10, ["alt"])
	var loop_n: int = d.plugin.editor.selection.selected_edges.size()
	d.check(loop_n == 4, "Alt+click selected the cut's whole loop (%d edges)" % loop_n)
	await d.frames(14)
	await d.move_selection(Vector3(0.0, 0.5, 0.0), 44)
	await d.frames(8)
	await d.cam_swing(f["center"], 42.0, 56.0, 20.0, 28.0, f["dist"], 34, 1, f["aim"])
	await d.click_button("face", 8)

## Subdivide the slab's top into four, then Shift+drag one quarter up: the
## split is what lets a quarter of the face become a block of its own.
func _subdiv() -> void:
	var slab: PBMesh = st["slab"]
	await _travel("slab", 30.0, 34.0, 0.56)
	var y := d.node_aabb(slab).end.y
	await _click_face(_at("slab", Vector3(0.6, y, 0.6)), 18, [], _at("slab", Vector3(0.0, y, 0.0)))
	var before := _faces(slab)
	await d.op("subdivide_faces", 20)
	d.check(_faces(slab) > before, "subdivide: %d -> %d faces" % [before, _faces(slab)])
	await d.frames(10)
	var q := _at("slab", Vector3(1.0, y, 1.0))
	await d.clear_element_selection()
	await _click_face(q, 18, [], q)
	await d.frames(8)
	var f1 := _faces(slab)
	await d.glide(d.drag_cursor_for(Vector3.ZERO), 10)
	await d.move_selection(Vector3(0.0, 0.7, 0.0), 44, true)
	d.check(_faces(slab) > f1, "one quarter extruded into a block (%d -> %d)" % [f1, _faces(slab)])
	await d.frames(12)

## Merge two of those quads into one face, then lift it as one.
func _merge() -> void:
	var slab: PBMesh = st["slab"]
	var f := d.framing_node(slab, 0.56, 30.0, 34.0)
	# The slab's own top (the quarter block the last beat raised now tops
	# its bounding box).
	var y := 0.6
	# Off the gizmo's X arrow: the first pick raises it along z = -1.
	var a := _at("slab", Vector3(-1.3, y, -0.5))
	var b := _at("slab", Vector3(1.0, y, -1.6))
	await d.clear_element_selection()
	await _click_face(a, 18)
	await _add_face(b, 18)
	d.check(_sel_count() >= 2, "two quads selected (%d)" % _sel_count())
	await d.frames(10)
	var before := _faces(slab)
	await d.op("merge_faces", 20)
	d.check(_faces(slab) < before, "merge: %d -> %d faces" % [before, _faces(slab)])
	await d.frames(10)
	await _only_face(_at("slab", Vector3(-1.0, y, -1.0)))
	await d.move_selection(Vector3(0.0, 0.5, 0.0), 44)
	await d.frames(8)
	await d.cam_swing(f["center"], 30.0, 50.0, 34.0, 38.0, f["dist"], 40, 1, f["aim"])

## Merge across a crease: a gable triangle and the wall below it become one
## bent n-gon that moves as one face.
func _crease() -> void:
	var house: PBMesh = st["house"]
	var f: Dictionary = await _travel("house", 28.0, 22.0, 0.52)
	await d.click_button("vertex", 8)
	var apex := house.to_global(Vector3(0.0, 2.1, 1.6))
	await d.glide_world_track(apex, 20)
	await d.click()
	d.check(_sel_count() == 1, "the front apex selected")
	await d.move_selection(Vector3(0.0, 0.0, -0.6), 36)
	await d.click_button("face", 8)
	var tri := house.to_global(Vector3(0.0, 1.3, 1.4))
	var quad := house.to_global(Vector3(0.0, 0.0, 1.6))
	await _click_face(tri, 18)
	await _add_face(quad, 16)
	d.check(_sel_count() >= 2, "the tilted gable and the wall selected (%d)" % _sel_count())
	var before := _faces(house)
	await d.op("merge_faces", 22)
	d.check(_faces(house) < before, "merged across the crease (%d -> %d)" % [before, _faces(house)])
	await _click_face(quad + Vector3(0, 0.3, 0), 16)
	await d.move_selection(Vector3(0.0, 0.25, 0.7), 46)
	await d.frames(6)
	await d.cam_swing(f["center"], 28.0, 50.0, 22.0, 28.0, f["dist"], 44, 1, f["aim"])

## Bevel the top edges with the live-preview modal: distance, then segments.
func _bevel() -> void:
	var cube: PBMesh = st["bevel"]
	var f: Dictionary = await _travel("bevel", 34.0, 26.0, 0.36)
	var top := _at("bevel", Vector3(0.0, 2.0, 0.0))
	await _click_face(top, 18, [], top)
	await d.frames(6)
	# Face -> edge mode converts the selection to the face's four edges.
	await d.click_button("edge", 12)
	d.check(d.plugin.editor.selection.selected_edges.size() >= 4,
		"the top face became its four edges (%d)" % d.plugin.editor.selection.selected_edges.size())
	var before := _faces(cube)
	await d.click_button("bevel_edges", 14)
	if not d.plugin.tool_overlay.params_open:
		d.plugin.call("_on_operation_requested", "bevel_edges")
		await d.frames(10)
		d._log_line("bevel modal opened via the plugin (button click missed)")
	d.check(d.plugin.tool_overlay.params_open, "the bevel modal is open")
	await d.overlay_param("distance", 0.2, 14)
	await d.overlay_param("distance", 0.4, 18)
	await d.overlay_param("segments", 4, 16)
	await d.overlay_param("segments", 8, 22)
	await d.overlay_button("ApplyParams", 16)
	d.check(_faces(cube) > before, "bevel applied (%d -> %d faces)" % [before, _faces(cube)])
	await d.click_button("face", 8)
	await d.cam_swing(f["center"], 34.0, 74.0, 26.0, 12.0, f["dist"] * 0.9, 60, 1, f["aim"])

## Weld: two top corners meet in the middle — the cube becomes a wedge.
func _weld() -> void:
	var cube: PBMesh = st["weld"]
	var f: Dictionary = await _travel("weld", 32.0, 26.0, 0.36)
	await d.click_button("vertex", 8)
	var ca := _at("weld", Vector3(-1.0, 2.0, 1.0))
	var cb := _at("weld", Vector3(1.0, 2.0, 1.0))
	var n := await d.select_points([ca, cb])
	d.check(n >= 2, "two corners selected (%d)" % n)
	await d.frames(10)
	var gap := func() -> float:
		var best_a := INF
		var best_b := INF
		var pa := Vector3.ZERO
		var pb := Vector3.ZERO
		for p in cube.pb_mesh_data.positions:
			var w: Vector3 = cube.to_global(p)
			if w.distance_to(ca) < best_a:
				best_a = w.distance_to(ca)
				pa = w
			if w.distance_to(cb) < best_b:
				best_b = w.distance_to(cb)
				pb = w
		return snappedf(pa.distance_to(pb), 0.05)
	var g0: float = gap.call()
	await d.op_verify("weld_vertices", gap, 20)
	d.check(gap.call() < g0 * 0.6, "weld closed the corner gap (%.2f -> %.2f)" % [g0, gap.call()])
	await d.click_button("face", 8)
	await d.cam_swing(f["center"], 32.0, 58.0, 26.0, 22.0, f["dist"], 50, 1, f["aim"])

## Delete the top (look inside the box), then detach the front face as its
## own object and lift it away.
func _cube_ops() -> void:
	var cube: PBMesh = st["cube"]
	var f: Dictionary = await _travel("cube", 32.0, 30.0, 0.36)
	var top := _at("cube", Vector3(0.0, 2.0, 0.0))
	await _click_face(top, 18, [], top)
	var was := _faces(cube)
	await d.op("delete_faces", 18)
	d.check(_faces(cube) == was - 1, "delete removed the top (%d -> %d)" % [was, _faces(cube)])
	await d.cam_swing(f["center"], 32.0, 44.0, 30.0, 48.0, f["dist"], 44, 1, f["aim"])
	var front := _at("cube", Vector3(0.0, 1.0, 1.0))
	await _click_face(front, 16, [], front)
	var before := _faces(cube)
	await d.op("detach_faces", 18)
	d.check(_faces(cube) < before, "detach took the face (%d -> %d)" % [before, _faces(cube)])
	var piece: PBMesh = null
	for ch in root.get_children():
		if String(ch.name).contains("_Detached"):
			piece = ch
	d.check(piece != null, "detach made a new object")
	if piece != null:
		await _select_node(piece)
		await _click_face(d.node_aabb(piece).get_center(), 14)
		await d.move_selection(Vector3(0.0, 0.6, 1.4), 44)
	await d.cam_swing(f["center"], 44.0, 30.0, 48.0, 30.0, f["dist"] * 1.1, 50, 1, f["aim"])

## Knife a path across the slab, then extrude the far half.
func _knife() -> void:
	var slab: PBMesh = st["knife"]
	var f: Dictionary = await _travel("knife", 26.0, 38.0, 0.52)
	await d.click_button("knife_tool", 12)
	var top := d.node_aabb(slab).end.y
	# The ends sit 3 cm inside the edges (the knife snaps them on): a click
	# exactly on the edge can graze past the slab and start the cut elsewhere.
	var path := [Vector3(-1.97, top, -1.3), Vector3(-0.7, top, -0.1), Vector3(0.3, top, 1.1),
		Vector3(1.3, top, -0.2), Vector3(1.97, top, 1.0)]
	for p in path:
		await d.glide_world_track(_at("knife", p), 14)
		await d.click(Vector2.INF, 4)
	var before := _faces(slab)
	await d.key(KEY_ENTER)
	await d.frames(10)
	d.check(_faces(slab) > before, "knife cut: %d -> %d faces" % [before, _faces(slab)])
	await d.click_button("face", 8)
	await _click_face(_at("knife", Vector3(0.6, top, -1.5)), 16)
	await d.move_selection(Vector3(0.0, 0.9, 0.0), 44, true)
	d.check(_faces(slab) > before + 1, "the far half extruded (%d faces)" % _faces(slab))
	await d.cam_swing(f["center"], 26.0, 48.0, 38.0, 28.0, f["dist"] * 1.05, 40, 1, f["aim"])

## Draw any polygon with the N-gon tool, then pull its height.
func _ngon() -> void:
	var f: Dictionary = await _travel("ngon", 24.0, 38.0, 0.62)
	await d.click_button("ngon", 12)
	for p in [Vector3(-1.2, 0.0, -1.0), Vector3(1.1, 0.0, -1.2), Vector3(1.4, 0.0, 0.6),
			Vector3(0.0, 0.0, 1.4), Vector3(-1.3, 0.0, 0.8)]:
		await d.glide_world_track(_at("ngon", p), 12)
		await d.click(Vector2.INF, 4)
	await d.key(KEY_ENTER)
	await d.frames(6)
	# The height follows the pointer up the screen; read it back, like a user
	# watching the readout, and stop at ~1.4 m.
	var dr = d.plugin.ngon_drawer
	for i in range(60):
		if float(dr.height) >= 1.35:
			break
		d.cursor += Vector2(0.0, -5.0)
		d._send_motion()
		await d.frames(1)
	d.check(absf(float(dr.height) - 1.4) < 0.25, "n-gon height %.2f m" % float(dr.height))
	await d.frames(10)
	await d.click()
	await d.frames(6)
	var made := ShowcaseUtil.names_of(root, "Shape_Ngon")
	d.check(made.size() >= 1, "n-gon prism created (%d)" % made.size())
	if made.size() > 0:
		ShowcaseUtil.dress_material(made[0], ShowcaseUtil.checker_mat(root, "plum"))
		var g := d.framing_node(made[0], 0.42, 24.0, 30.0)
		await d.cam_swing(g["center"], 24.0, 50.0, 30.0, 22.0, g["dist"], 50, 1, g["aim"])

## Smart selection on a 3x3x3 box: face loop, grow, shrink, coplanar, invert.
func _smart() -> void:
	var box: PBMesh = st["smart"]
	var f: Dictionary = await _travel("smart", 34.0, 22.0, 0.44)
	await d.click_button("face", 8)
	var front := _at("smart", Vector3(0.0, 1.2, 1.2))
	# Every plain click lands on a face that is NOT selected: a click inside a
	# multi-selection keeps it (it is the start of a drag).
	await _click_face(front, 18, [], front)
	await d.frames(8)
	await d.click_button("select_coplanar", 18)
	d.check(_selected_faces().size() == 9, "coplanar: the 9 front faces (%d)" % _selected_faces().size())
	await d.click_button("invert_selection", 18)
	d.check(_selected_faces().size() == 45, "invert: the other 45 (%d)" % _selected_faces().size())
	await d.frames(10)
	var side := _at("smart", Vector3(0.8, 1.2, 1.2))
	await _click_face(side, 16, [], side)
	d.check(_selected_faces().size() == 1, "a front face picked again (%d)" % _selected_faces().size())
	await d.click_button("select_face_loop", 18)
	d.check(_selected_faces().size() == 12, "face loop: 12 faces (%d)" % _selected_faces().size())
	await d.click_button("grow_selection", 18)
	d.check(_selected_faces().size() > 12, "grow (%d)" % _selected_faces().size())
	await d.click_button("shrink_selection", 18)
	d.check(_selected_faces().size() < 36, "shrink (%d)" % _selected_faces().size())
	await d.frames(10)
	await d.cam_swing(f["center"], 34.0, 76.0, 22.0, 30.0, f["dist"] * 0.95, 50, 1, f["aim"])
