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
	ShowcaseUtil.fresh_grid(d.plugin)
	bench = ShowcaseUtil.floor_slab(root, 34.0, ShowcaseUtil.mat(root, "ink"))
	# The bench's top surface sits exactly on the plugin grid's plane, and two
	# coplanar surfaces z-fight; the grid has nothing to add here anyway (every
	# beat draws on the bench, not on the grid).
	await d.grid_show(false)
	await d.frames(20)

	await d.shot("edit/select", _select)
	await d.shot("edit/edge_loop", _edge_loop)
	await d.shot("edit/move", _move)
	await d.shot("edit/extrude", _extrude)
	await d.shot("edit/inset", _inset)
	await d.shot("edit/subdivide", _subdivide)
	await d.shot("edit/loopcut", _loopcut)
	await d.shot("edit/merge", _merge)
	await d.shot("edit/merge_ngon", _merge_nonplanar)
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
	# See create.gd: the editor's references go first and the nodes are freed at
	# end of frame, never mid-redraw.
	d.plugin.editor.active_mesh = null
	EditorInterface.get_selection().clear()
	for c in root.get_children():
		if c is PBMesh and c != bench:
			root.remove_child(c)
			c.queue_free()

## Builds a fresh object, selects it, and frames the camera on it — all before
## the first captured frame of the beat.
##
## Every object in this act wears the soft checkerboard, tinted toward the
## beat's palette colour: a flat-shaded face hides exactly what the beats are
## about (a subdivided quad and an untouched one look identical), and the
## 1 m tiling makes the auto-UV management visible when a face is resized.
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

## Highest point of a node's own box, in WORLD space.
func _box_top(node: Node3D) -> float:
	var a := d.node_aabb(node)
	return a.position.y + a.size.y

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

## World-space centre of the face the plugin currently has selected (-1 → ZERO).
func _selected_face_center() -> Vector3:
	if obj == null:
		return Vector3.ZERO
	var sel = d.plugin.editor.selection
	if sel.selected_faces.is_empty():
		return Vector3.ZERO
	return _face_center(int(sel.selected_faces[0]))

func _face_center(face_id: int) -> Vector3:
	if obj == null or face_id < 0 or face_id >= obj.pb_mesh_data.faces.size():
		return Vector3.ZERO
	var acc := Vector3.ZERO
	var idxs: PackedInt32Array = obj.pb_mesh_data.faces[face_id].get_indexes()
	for i in idxs:
		acc += obj.to_global(obj.pb_mesh_data.positions[i])
	return acc / float(maxi(1, idxs.size()))

## True when any face of `obj` still has its centre within `radius` of `point`.
func _has_face_near(point: Vector3, radius: float) -> bool:
	if obj == null:
		return false
	for fi in range(obj.pb_mesh_data.faces.size()):
		if _face_center(fi).distance_to(point) <= radius:
			return true
	return false

## World-space AABB spanning several nodes (the union of their own boxes).
func _union_aabb(nodes: Array) -> AABB:
	var box: AABB = d.node_aabb(nodes[0])
	for i in range(1, nodes.size()):
		box = box.merge(d.node_aabb(nodes[i]))
	return box

## Faces with more than four corners — the n-gons a merge produces.
func _polygon_face_count() -> int:
	var n := 0
	if obj == null:
		return 0
	for fa in obj.pb_mesh_data.faces:
		if fa.get_distinct_indexes().size() > 4:
			n += 1
	return n

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

## Selecting a whole edge RING: shift+alt+click a vertical edge of a cube and
## the walk runs around the shape through the four vertical edges — the gesture
## a loop cut is seeded from. (Alt+click alone is the edge LOOP, which a plain
## cube's valence-3 corners stop immediately; the loop is shown where it
## exists, on the loop cut beat's own new edges.)
func _edge_loop() -> void:
	var cube := PBMeshData.create_cube(2.0)
	PBMeshOps.insert_edge_loop(cube, PackedInt32Array([2]))
	obj = await _fresh("DemoCube", cube, "steel", Vector3.ZERO, 0.38, 34.0, 24.0)
	var f := d.framing_node(obj, 0.38, 34.0, 24.0)
	await d.click_button("edge")
	# Click the horizontal edge loop across the front face at (0.0, 1.0, 1.0)
	await d.orbit_glide(f["center"], 34.0, 44.0, 24.0, f["dist"],
		Vector3(0.0, 1.0, 1.0), 24, f["aim"])
	await d.click(Vector2.INF, 14, ["alt"])
	var sel = d.plugin.editor.selection
	d.check(sel.selected_edges.size() == 4,
		"alt+click expanded the edge to its loop (%d edges)" % sel.selected_edges.size())
	# Check that the whole loop is captured for moving
	var moved: int = await d.off(func():
		return d.element_editor().element_indices(obj.pb_mesh_data, d.subgizmo_ids()[0]).size())
	d.check(moved >= 8, "the loop's corners follow the seed's drag (%d positions)" % moved)
	# Pause so the yellow highlight across the whole loop is vividly seen on the dark texture
	await d.frames(20)
	# Move the selection so the entire edge loop visibly moves, deforming the cube waist
	await d.move_selection(Vector3(0.0, 0.45, 0.0), 36)
	await d.cam_swing(f["center"] + Vector3(0.0, 0.2, 0.0), 44.0, 72.0, 24.0, 32.0, f["dist"], 40, 1, f["aim"])
	await d.click_button("face")

## Face manipulation on a doorway: the SIMPLE case first (a side quad), then
## the COMPLEX one — the front is a single n-gon that wraps the arched opening,
## so dragging it moves the whole face, hole perimeter included, in one piece.
func _move() -> void:
	var door := PBShapeComplex.create_door(3.0, 3.2, 2.4, 0.5, 1.0, true, 8)
	# The camera starts on the door's -X side: the simple quad has to be the face
	# UNDER the cursor, and from the courtyard side the doorway's front n-gon
	# hides it (a click there selects the big face instead — which is what the
	# first version of this beat did, moving the wrong face twice).
	obj = await _fresh("DemoDoor", door, "steel", Vector3.ZERO, 0.46, -38.0, 22.0)
	var f := d.framing_node(obj, 0.46, -38.0, 22.0)
	await d.click_button("face")
	# --- the simple face: a side quad
	await d.orbit_glide(f["center"], -38.0, -52.0, 22.0, f["dist"],
		Vector3(-1.5, 1.6, 0.0), 22, f["aim"])
	await d.click()
	d.check(_sel_count() == 1, "door side quad selected")
	var quads: int = obj.pb_mesh_data.faces.size()
	var side_was := _selected_face_center()
	await d.move_selection(Vector3(-0.9, 0.0, 0.0), 40)
	# The proof is where the face ENDED UP, not the plugin's mirror: the commit
	# clears the subgizmo selection, so reading it back proves nothing.
	d.check(_has_face_near(side_was + Vector3(-0.9, 0.0, 0.0), 0.25),
		"the side quad moved as one face (to %s)" % str(_selected_face_center().snappedf(0.01)))
	# --- the complex face: the front n-gon with the arch cut out of it
	var ngons := 0
	for fa in obj.pb_mesh_data.faces:
		if fa.get_distinct_indexes().size() > 4:
			ngons += 1
	d.check(ngons >= 2, "the doorway carries n-gons (%d faces over 4 corners)" % ngons)
	# ...and now swing round to the courtyard side, where the front n-gon (the
	# one wrapping the arch) is the face under the cursor.
	var f2 := d.framing_node(obj, 0.46, 26.0, 16.0)
	await d.frame_box_to(d.node_aabb(obj), 26.0, 16.0, 0.46, 30)
	await d.orbit_glide(f2["center"], 26.0, 40.0, 16.0, f2["dist"],
		Vector3(-0.4, 2.9, 0.7), 24, f2["aim"])
	await d.click()
	d.check(_sel_count() == 1, "the front n-gon selected (the whole side, hole and all)")
	await d.move_selection(Vector3(0.0, 0.0, 0.8), 44)
	d.check(obj.pb_mesh_data.faces.size() == quads,
		"the n-gon moved as one face (%d faces before and after)" % quads)
	await d.cam_swing(f2["center"] + Vector3(-0.4, 0.2, 0.4), 44.0, 20.0, 16.0, 22.0,
		f2["dist"] * 1.08, 34, 1, f2["aim"])

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
	# Slow on purpose: the ring the inset leaves is the operation's whole
	# result, and it only reads if the drag is seen contracting the cap — at the
	# old speed the clip opened after it had already happened.
	await d.frames(16)
	await d.scale_selection_factor(0.42, 84, true)
	d.check(obj.pb_mesh_data.faces.size() > before,
		"shift+centre inset (%d -> %d faces)" % [before, obj.pb_mesh_data.faces.size()])
	await d.frames(20)
	# The payoff: the inset left a RING around the inner face, so grab that face
	# and lift it — the ring is what the operation actually produced.
	await d.tool("move")
	await d.glide_world_track(_top_world(obj), 18)
	await d.click()
	d.check(_sel_count() == 1, "the inset face re-selected")
	var top0: float = _top_of(obj)
	await d.move_selection(Vector3(0.0, 0.55, 0.0), 44)
	d.check(absf(_top_of(obj) - top0) > 0.25,
		"the inset face lifted clear of its ring (%.2f -> %.2f)" % [top0, _top_of(obj)])
	await d.cam_swing(f["center"] + Vector3(0, 0.25, 0), 30.0, 46.0, 24.0, 34.0, f["dist"], 30, 1, f["aim"])

## Subdivision is a TOPOLOGY change, so the beat has to show the topology: the
## new interior edge is grabbed and dragged afterwards, which deforms the
## checker squares around it — the wireframe alone is far too quiet on video.
func _subdivide() -> void:
	obj = await _fresh("DemoSlab", PBShapeGenerators.create_box(Vector3(4.0, 0.6, 4.0)),
		"slate", Vector3.ZERO, 0.56, 30.0, 30.0)
	var f := d.framing_node(obj, 0.56, 30.0, 30.0)
	await d.click_button("face")
	await d.orbit_glide(f["center"], 30.0, 38.0, 30.0, f["dist"],
		_top_world(obj), 20, f["aim"])
	await d.click()
	d.check(_sel_count() == 1, "slab top selected")
	var before: int = obj.pb_mesh_data.faces.size()
	await d.op("subdivide_faces", 20)
	d.check(obj.pb_mesh_data.faces.size() > before,
		"subdivide: %d -> %d faces" % [before, obj.pb_mesh_data.faces.size()])
	# the new interior edge, dragged sideways: the squares either side stretch
	await d.click_button("edge")
	await d.glide_world_track(Vector3(0.0, _top_world(obj).y, 1.25), 18)
	await d.click()
	d.check(_sel_count() == 1, "an edge created by the subdivision selected")
	var pos_before: PackedVector3Array = obj.pb_mesh_data.positions.duplicate()
	await d.move_selection(Vector3(0.8, 0.0, 0.0), 40)
	var moved := 0
	for i in range(mini(pos_before.size(), obj.pb_mesh_data.positions.size())):
		if pos_before[i].distance_to(obj.pb_mesh_data.positions[i]) > 0.3:
			moved += 1
	d.check(moved >= 2, "the new edge moved (%d vertices followed it)" % moved)
	await d.cam_swing(f["center"], 38.0, 54.0, 30.0, 44.0, f["dist"], 30, 1, f["aim"])
	await d.click_button("face")

## Loop cut. Two things have to be true on camera for the operation to read:
## the cut has to be visible on EVERY side (an orbit shows all four — a cut that
## never turns the corner looks like it only touched two faces), and the new
## loop has to be a selectable, movable LOOP (alt-click expands to the chain of
## edges the cut created, all four of them; the RING of one of those edges —
## shift+alt — is the wider set that runs over the top and under the bottom).
func _loopcut() -> void:
	obj = await _fresh("DemoBox", PBShapeGenerators.create_box(Vector3(3.0, 2.0, 3.0)),
		"steel", Vector3.ZERO, 0.48, 40.0, 18.0)
	var f := d.framing_node(obj, 0.48, 40.0, 18.0)
	await d.click_button("edge")
	# Exactly the mid-point of the front-right VERTICAL edge: a corner click or
	# a face-centre click lands on whichever edge is nearest, and the ring walk
	# (and therefore the cut) depends on which edge that is.
	await d.orbit_glide(f["center"], 40.0, 48.0, 18.0, f["dist"],
		Vector3(1.5, 1.0, 1.5), 22, f["aim"])
	await d.click()
	d.check(_sel_count() == 1, "vertical edge selected")
	d.check(d.plugin.editor.selection.selected_edges.size() >= 1,
		"edge selection mirrored into the plugin")
	var before: int = obj.pb_mesh_data.faces.size()
	await d.op("insert_edge_loop", 20)
	d.check(obj.pb_mesh_data.faces.size() == before + 4,
		"loop cut split all four sides (%d -> %d faces)" % [before, obj.pb_mesh_data.faces.size()])
	# THE CUT, all the way round: a slow orbit over the four sides the cut
	# crossed, so the new mid-height edge is seen on each of them in turn.
	await d.cam_swing(f["center"], 48.0, 168.0, 18.0, 26.0, f["dist"] * 1.05, 78, 1, f["aim"])
	await d.cam_swing(f["center"], 168.0, 232.0, 26.0, 18.0, f["dist"], 40, 1, f["aim"])
	# ...then show what the cut MADE: alt-click one of the new mid-height edges.
	# Its loop runs end to end through the four 4-valence corners the cut
	# created, so the whole new loop lights up — proof the cut went round.
	await d.glide_world_track(Vector3(0.0, 1.0, 1.5), 18)
	await d.click(Vector2.INF, 8, ["alt"])
	var loop_n: int = d.plugin.editor.selection.selected_edges.size()
	d.check(loop_n == 4, "the cut's own edges select as one loop (%d edges)" % loop_n)
	# Moving the loop slides the band the cut made: the faces above and below it
	# stretch, and nothing else on the box moves.
	var top_before: float = _top_of(obj)
	await d.move_selection(Vector3(0.0, 0.35, 0.0), 46)
	d.check(absf(_top_of(obj) - top_before) < 0.01,
		"moving the loop leaves the box's own height alone (%.2f)" % _top_of(obj))
	await d.cam_swing(f["center"], 232.0, 250.0, 18.0, 30.0, f["dist"] * 1.05, 30, 1, f["aim"])
	await d.click_button("face")

## Merge, part one: coplanar quads become ONE face — and the proof is grabbing
## that face and moving it, which leaves the untouched quads behind.
func _merge() -> void:
	obj = await _fresh("DemoSlab", PBShapeGenerators.create_box(Vector3(4.0, 0.6, 4.0)),
		"brick", Vector3.ZERO, 0.56, 26.0, 32.0)
	var f := d.framing_node(obj, 0.56, 26.0, 32.0)
	await d.click_button("face")
	await d.orbit_glide(f["center"], 26.0, 32.0, 32.0, f["dist"],
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
	# grab what the merge produced and lift it: one face, moving as one
	var merged: int = _polygon_face_count()
	d.check(merged >= 1, "the merge produced an n-gon (%d polygons over 4 corners)" % merged)
	await d.glide_world_track(Vector3(-0.7, _top_world(obj).y, 0.7), 16)
	await d.click()
	d.check(_sel_count() == 1, "the merged face selected")
	var after: int = obj.pb_mesh_data.faces.size()
	await d.move_selection(Vector3(0.0, 0.45, 0.0), 44)
	d.check(obj.pb_mesh_data.faces.size() == after,
		"the merged face moved as one (%d faces before and after)" % after)
	await d.cam_swing(f["center"] + Vector3(0, 0.2, 0), 32.0, 50.0, 32.0, 40.0, f["dist"], 30, 1, f["aim"])

## Merge, part two: two faces AT AN ANGLE. A prism's roof is the honest example
## of the shape this is for — two quads meeting along the ridge, which merge into
## one bent face that then moves as a single face.
##
## The prism stands on a PLINTH (a plain cube of the same footprint): when the
## merged roof is dragged up, the prism's own walls stretch above a base that
## does not move, so "both slopes moved together" is visible as the column
## growing — the shape of the change, not just a face count. The two clicks that
## pick the slopes are the slowest part of the beat and stay on screen: one
## slope, a full swing around the ridge, then shift+click the far slope, so the
## viewer sees exactly which two faces the merge consumes.
func _merge_nonplanar() -> void:
	obj = await _fresh("DemoHouse",
		ShowcaseUtil.create_house(Vector3(2.4, 1.8, 3.2), 1.2), "moss",
		Vector3.ZERO, 0.52, 28.0, 22.0)
	var f := d.framing_node(obj, 0.52, 28.0, 22.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(10)

	# 1. Start in VERTEX mode: select the front roof apex and move it inwards
	# to create a shallow crease angle for the gable triangle.
	await d.click_button("vertex")
	var apex_world := obj.to_global(Vector3(0.0, 2.1, 1.6))
	await d.orbit_glide(f["center"], 28.0, 32.0, 22.0, f["dist"],
		apex_world, 24, f["aim"])
	await d.click()
	d.check(_sel_count() == 1, "the front roof apex vertex selected")
	await d.move_selection(Vector3(0.0, 0.0, -0.6), 36)
	d.check(obj.to_global(Vector3(0.0, 2.1, 1.0)).distance_to(apex_world) > 0.4,
		"apex moved inward to create shallow angle")

	# 2. Switch to FACE mode: select both the shallow gable triangle and the quad wall below it.
	await d.click_button("face")
	var tri_world := obj.to_global(Vector3(0.0, 1.3, 1.4))
	var quad_world := obj.to_global(Vector3(0.0, 0.0, 1.6))
	await d.orbit_glide(f["center"], 32.0, 28.0, 22.0, f["dist"],
		tri_world, 20, f["aim"])
	await d.click()
	d.check(_sel_count() == 1, "the tilted gable triangle selected")
	await d.glide_world_track(quad_world, 18)
	await d.click(Vector2.INF, 10, ["shift"])
	d.check(_sel_count() >= 2, "both the tilted triangle and quad selected")

	# 3. Merge across the crease into one bent n-gon.
	var before: int = obj.pb_mesh_data.faces.size()
	await d.op("merge_faces", 24)
	d.check(obj.pb_mesh_data.faces.size() < before,
		"the triangle and quad merged into one face (%d -> %d faces)" % [before, obj.pb_mesh_data.faces.size()])
	d.check(_polygon_face_count() >= 1, "the merge produced a bent n-gon")

	# 4. Showcase moving the merged bent face as one piece.
	await d.glide_world_track(quad_world + Vector3(0, 0.3, 0), 18)
	await d.click()
	d.check(_sel_count() == 1, "the bent n-gon selected")
	var after: int = obj.pb_mesh_data.faces.size()
	await d.move_selection(Vector3(0.0, 0.25, 0.7), 48)
	d.check(obj.pb_mesh_data.faces.size() == after,
		"the bent n-gon moved as one face (%d faces before and after)" % after)
	await d.cam_swing(f["center"] + Vector3(0, 0.3, 0.3), 28.0, 48.0, 22.0, 28.0,
		f["dist"] * 1.06, 40, 1, f["aim"])
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

## Detach, then PROVE it detached: the new object is selected and its face is
## dragged away from the hole it left behind.
func _detach() -> void:
	obj = await _fresh("DemoCube", PBMeshData.create_cube(2.0), "steel", Vector3.ZERO, 0.40, 30.0, 24.0)
	var f := d.framing_node(obj, 0.40, 30.0, 24.0)
	await d.click_button("face")
	await d.orbit_glide(f["center"], 30.0, 38.0, 24.0, f["dist"],
		Vector3(0.0, _top_world(obj).y, 0.0), 22, f["aim"])
	await d.click()
	d.check(_sel_count() == 1, "top face selected for detach")
	var before: int = obj.pb_mesh_data.faces.size()
	await d.op("detach_faces", 22)
	d.check(obj.pb_mesh_data.faces.size() < before,
		"the source lost the face (%d -> %d)" % [before, obj.pb_mesh_data.faces.size()])
	# The detached sibling is named "<source>_Detached" (the plugin's own
	# naming), so match on the suffix rather than on a prefix.
	var made: Array = []
	for c in root.get_children():
		if String(c.name).contains("_Detached"):
			made.append(c)
	d.check(made.size() == 1, "detach spawned a new node (%d)" % made.size())
	if made.is_empty():
		return
	# Select the new object and drag its face up and away: what was a face of
	# the cube is now a mesh of its own, and the cube has a hole.
	var piece: PBMesh = made[0]
	var center := (piece.global_transform * (piece as MeshInstance3D).get_aabb()).get_center()
	await d.off(func():
		var sel := EditorInterface.get_selection()
		sel.clear()
		sel.add_node(piece))
	await d.frames(6)
	var g := d.framing(AABB(center - Vector3(1.6, 0.2, 1.6), Vector3(3.2, 3.4, 3.2)), 0.62, 30.0, 20.0)
	await d.frame_box_to(AABB(center - Vector3(1.6, 0.2, 1.6), Vector3(3.2, 3.4, 3.2)),
		30.0, 20.0, 0.62, 26)
	await d.glide_world_track(center, 16)
	await d.click()
	d.check(_sel_count() == 1, "the detached face selected as its own object")
	await d.move_selection(Vector3(0.0, 1.3, 0.6), 48)
	d.check(String(d.active_mesh().name).contains("_Detached"),
		"the piece that moved is the detached object (%s)" % String(d.active_mesh().name))
	await d.cam_swing(g["center"] + Vector3(0, 0.5, 0), 30.0, 52.0, 20.0, 34.0, float(g["dist"]), 34, 1, g["aim"])

## Delete, with the result on camera: two faces go (the top and the front) and
## the camera drops to look INTO the opening they leave. The check is not the
## face count alone — the face that was selected has to be the one that is
## gone, which is what "it never seems to delete the face" actually meant.
func _delete() -> void:
	obj = await _fresh("DemoCube", PBMeshData.create_cube(2.0), "brick", Vector3.ZERO, 0.40, 30.0, 24.0)
	var f := d.framing_node(obj, 0.40, 30.0, 24.0)
	await d.click_button("face")
	for target in [Vector3(0.0, _top_world(obj).y, 0.0), Vector3(0.0, TOP * 0.5, 1.0)]:
		var was: int = obj.pb_mesh_data.faces.size()
		await d.glide_world_track(target, 18)
		await d.click()
		d.check(_sel_count() == 1, "a face is selected for the delete")
		var gone := _selected_face_center()
		await d.op("delete_faces", 20)
		d.check(obj.pb_mesh_data.faces.size() == was - 1,
			"delete removed one face (%d -> %d)" % [was, obj.pb_mesh_data.faces.size()])
		d.check(not _has_face_near(gone, 0.4),
			"the face that was selected is the one that is gone")
	await d.cam_look_at(f["center"] + Vector3(2.6, 2.9, 2.6), f["center"] + Vector3(0, 0.4, 0))
	await d.frames(4)
	await d.cam_swing(f["center"] + Vector3(0, 0.4, 0), 45.0, 20.0, 42.0, 22.0,
		f["dist"] * 1.05, 34, 1, f["aim"])

func _knife() -> void:
	obj = await _fresh("DemoSlab", PBShapeGenerators.create_box(Vector3(4.0, 1.0, 4.0)),
		"slate", Vector3.ZERO, 0.52, 26.0, 38.0)
	var f := d.framing_node(obj, 0.52, 26.0, 38.0)
	await d.click_button("knife_tool", 14)
	# two points across the top face, then Enter cuts it in two
	# Three points: the first click only arms the plane, so a two-click path can
	# leave the cutter with a single vertex ("closed cut requires at least 3").
	# The path has to START and END on the face's own edges: a cut that stops
	# short of the boundary only splits the wall it touches (the "isn't cutting
	# all the way through" report), while an edge-to-edge path divides the face.
	var top: float = _top_world(obj).y
	var path := [
		Vector3(-2.0, top, -1.3),      # on the west edge
		Vector3(-0.7, top, -0.1),
		Vector3(0.3, top, 1.1),
		Vector3(1.3, top, -0.2),
		Vector3(2.0, top, 1.0),        # on the east edge
	]
	for i in range(path.size()):
		await d.glide_world_track(path[i], 14)
		await d.click(Vector2.INF, 4)
	var before: int = obj.pb_mesh_data.faces.size()
	await d.key(KEY_ENTER)
	await d.frames(8)
	d.check(obj.pb_mesh_data.faces.size() > before,
		"knife cut: %d -> %d faces" % [before, obj.pb_mesh_data.faces.size()])
	# ...and the two halves are separate faces now, so one of them extrudes. It
	# has to be the one the camera looks OVER: lifting the near half stands a
	# wall between the lens and the cut, which is the clip's whole subject (the
	# camera sits at +X/+Z, so the piece behind the path is the far one).
	await d.click_button("face")
	await d.glide_world_track(Vector3(0.6, top, -1.5), 16)
	await d.click()
	d.check(_sel_count() == 1, "one side of the cut selected")
	d.check(_selected_face_center().z < 0.0,
		"the far half is the one selected (centre z=%.2f)" % _selected_face_center().z)
	await d.move_selection(Vector3(0.0, 0.9, 0.0), 44, true)
	d.check(obj.pb_mesh_data.faces.size() > before + 1,
		"the cut half extruded (%d faces)" % obj.pb_mesh_data.faces.size())
	await d.cam_swing(f["center"], 30.0, 52.0, 38.0, 26.0, f["dist"] * 1.1, 34, 1, f["aim"])

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
