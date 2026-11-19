## SESSION — "v2_create": the Create chapter of showcase v2 (edl_v2*.toml).
##
## One set, built up in front of the viewer: a back wall and a ramp stand on
## the floor from the first frame, and every shape is drawn into that set from
## the Material & UV dock's Shapes tab. A beat starts where the last stopped
## (same camera, same pointer), so the cut can run the takes back to back.
##
##   v2c/cube      Shapes tab -> cube card -> drag on the floor, pull the height
##   v2c/surfaces  the same drag on the wall (grows out along its normal) and
##                 on the ramp's slope
##   v2c/stairs    stairs card -> drag -> live parameter modal (steps) -> Apply
##   v2c/reedit    select the placed stairs, Edit Shape Properties, more steps
##   v2c/door      door card -> drag -> arched in the modal -> Apply
##   v2c/edge      Placement: edge-first; two walls at angles a drag cannot draw
##   v2c/lineup    a dolly along every primitive the Shapes tab holds
##
## Framing: the 3D view with the dock ("viewport_dock"); the PoiBuilder
## toolbar is hidden (nothing here needs it) and the floating panel is on,
## because the parameter modal lives in it.
##
## Render: PB_SHOWCASE_LAYOUT=showcase_video/layouts/tour.cfg \
##         ./showcase_video/render.sh v2_create
@tool
extends RefCounted

var d: ShowcaseDirector
var root: Node
var dock: PBMaterialDock
var bench: PBMesh
var wall: PBMesh
var ramp: PBMesh
var stairs: PBMesh = null
var door: PBMesh = null
var lineup: Array[PBMesh] = []

## The courtyard the beats draw into (what the wide framings hold).
const SET_BOX := AABB(Vector3(-6.0, 0.0, -4.3), Vector3(14.0, 3.2, 7.0))
const LINEUP_X := 34.0
const LINEUP_GAP := 3.6

func run(dr: ShowcaseDirector) -> void:
	d = dr
	d.fill_scale = 1.25
	root = EditorInterface.get_edited_scene_root()
	dock = d.plugin.material_dock
	ShowcaseUtil.env(d.plugin, "day")
	ShowcaseUtil.grade_light(root)
	ShowcaseUtil.fresh_grid(d.plugin)
	# New shapes arrive in a mid-tone checker: the plain soft checker blows out
	# to white under the day light (and a regenerated shape drops its tint).
	ShowcaseUtil.use_default_material("res://materials/showcase_checker_steel.tres")
	d.plugin.set_placement_style(PBShapeCreator.PlacementStyle.DRAG)
	bench = ShowcaseUtil.floor_slab(root, 120.0, ShowcaseUtil.mat(root, "ink"))
	bench.position.x = 14.0
	wall = ShowcaseUtil.mesh(root, "BackWall", PBShapeGenerators.create_box(Vector3(12.0, 3.2, 0.5)),
		Vector3(0.0, 1.6, -4.0), ShowcaseUtil.checker_mat(root, "slate"))
	ramp = ShowcaseUtil.mesh(root, "Ramp", PBShapeGenerators.create_prism(Vector3(2.6, 1.6, 3.2)),
		Vector3(6.8, 0.8, 1.4), ShowcaseUtil.checker_mat(root, "plum"))
	_build_lineup()
	await d.grid_show(false)
	dock.set_thumbnail_size(64)
	dock.set_dock_mode(PBMaterialDock.DockMode.MATERIAL)
	if d.plugin.mode_banner != null:
		d.plugin.mode_banner.modulate.a = 0.0
	_hide_toolbar(true)
	await d.frames(4)
	d.snapshot_regions()
	await d.lift_panel(80.0)
	var f := d.framing(SET_BOX, 0.8, 30.0, 28.0)
	d.cam_at_polar(f["center"], 30.0, 28.0, f["dist"], f["aim"])
	await d.frames(20)

	for s in [["v2c/cube", _cube], ["v2c/surfaces", _surfaces], ["v2c/stairs", _stairs],
			["v2c/reedit", _reedit], ["v2c/door", _door], ["v2c/edge", _edge],
			["v2c/lineup", _lineup]]:
		if d.only_done():
			break
		await d.shot(s[0], s[1])

	d.plugin.set_placement_style(PBShapeCreator.PlacementStyle.DRAG)
	if d.plugin.mode_banner != null:
		d.plugin.mode_banner.modulate.a = 1.0
	_hide_toolbar(false)

# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------

func _hide_toolbar(hide: bool) -> void:
	if d.plugin.toolbar != null:
		(d.plugin.toolbar as Control).visible = not hide

func _created() -> Array:
	return ShowcaseUtil.names_of(root, "Shape_")

func _newest(before: Array) -> PBMesh:
	for n in _created():
		if not before.has(n):
			return n
	return null

func _tint(node: PBMesh, color: String) -> void:
	if node != null:
		ShowcaseUtil.dress_material(node, ShowcaseUtil.checker_mat(root, color))

## Base drag + height on the drag flow (the closed-loop height helper), then
## the confirming click. Returns the created node.
func _drag_shape(a: Vector3, b: Vector3, height: float, n := 32) -> PBMesh:
	var before := _created()
	await d.glide(d.w2s(a), 16)
	await d.drag(d.w2s(a), d.w2s(b), n, false, 1)
	var got: float = await d.height_drag_to(height)
	d.check(absf(got - height) <= 0.21, "height reached %.2f m (%.2f)" % [height, got])
	await d.click()
	await d.frames(4)
	return _newest(before)

func _shape_card(id: StringName) -> void:
	var card: Control = dock._shape_card_buttons[id]
	# The shape palette scrolls: bring a card below the fold into view first,
	# the way a wheel over the palette would.
	var sc := card.get_parent()
	while sc != null and not (sc is ScrollContainer):
		sc = sc.get_parent()
	if sc != null and not (sc as ScrollContainer).get_global_rect().encloses(card.get_global_rect()):
		await d.glide((sc as ScrollContainer).get_global_rect().get_center(), 12)
		(sc as ScrollContainer).ensure_control_visible(card)
		await d.frames(10)
	await d.click_control(card, 10)
	d.check(d.plugin.shape_creator.shape_id == id, "the %s card armed its shape" % String(id))

func _build_lineup() -> void:
	var ids := PBMaterialDock.shape_palette_ids()
	var colors := ["stone", "slate", "brick", "steel", "moss", "plum"]
	var i := 0
	for id in ids:
		if id == &"trim" or id == &"plane":
			continue
		var data := PBShapeFactory.create_shape(id, Vector3(2.4, 2.4, 2.4))
		if data == null:
			continue
		var node := ShowcaseUtil.mesh(root, "Gallery_" + String(id), data,
			Vector3(LINEUP_X + float(i) * LINEUP_GAP, 0.0, 0.0), ShowcaseUtil.checker_mat(root, colors[i % colors.size()]))
		ShowcaseUtil.drop_on_ground(node)
		lineup.append(node)
		i += 1

# -----------------------------------------------------------------------------
# beats
# -----------------------------------------------------------------------------

## The Shapes tab, the cube card, a box drawn on the floor.
func _cube() -> void:
	await d.click_dock_member("_btn_mode_shape", 12)
	d.check(dock.dock_mode == PBMaterialDock.DockMode.SHAPE, "Shapes tab open")
	await _shape_card(&"cube")
	await d.frame_box_to(AABB(Vector3(-6.0, 0.0, -4.3), Vector3(7.0, 3.2, 7.0)), 30.0, 26.0, 0.62, 36)
	var box := await _drag_shape(Vector3(-5.2, 0.0, 0.4), Vector3(-3.0, 0.0, 2.6), 1.6)
	d.check(box != null, "a box drawn on the floor")
	_tint(box, "steel")
	await d.frames(16)

## The same drag on the vertical wall, then on the ramp's slope: each shape
## grows out along the normal of the surface it was drawn on.
func _surfaces() -> void:
	var wpt := Vector3(-2.2, 1.7, -3.75)
	var on_wall := await _drag_shape(wpt + Vector3(-0.8, -0.6, 0.0), wpt + Vector3(0.8, 0.6, 0.0), 0.9)
	d.check(on_wall != null and d.node_aabb(on_wall).end.z > -3.0,
		"the wall drag grew a box out of the wall (front z=%.2f)" % (d.node_aabb(on_wall).end.z if on_wall != null else 0.0))
	_tint(on_wall, "brick")
	await d.frames(8)
	# the ramp's +X slope (ridge at x=6.8 down to the floor at x=8.1)
	await d.frame_box_to(AABB(Vector3(4.0, 0.0, -1.0), Vector3(5.0, 2.8, 5.0)), 22.0, 22.0, 0.6, 40)
	var slope := Vector3(7.45, 0.8, 1.4)
	var on_slope := await _drag_shape(slope + Vector3(-0.38, 0.47, -0.7), slope + Vector3(0.38, -0.47, 0.7), 0.8)
	d.check(on_slope != null and d.node_aabb(on_slope).position.y > 0.05,
		"the slope drag sits ON the slope (min y=%.2f)" % (d.node_aabb(on_slope).position.y if on_slope != null else 0.0))
	_tint(on_slope, "moss")
	await d.frames(16)

## The stairs card: a drag, then the live parameter modal (steps), Apply.
func _stairs() -> void:
	await _shape_card(&"stair")
	await d.frame_box_to(AABB(Vector3(-2.4, 0.0, -4.0), Vector3(5.0, 3.0, 6.6)), 30.0, 26.0, 0.62, 40)
	# From near to far: the stairs face away from the drag start, so they climb
	# toward the wall and the treads face the camera.
	var before := _created()
	await d.glide(d.w2s(Vector3(0.9, 0.0, 1.0)), 16)
	await d.drag(d.w2s(Vector3(0.9, 0.0, 1.0)), d.w2s(Vector3(-0.7, 0.0, -2.6)), 34, false, 1)
	var got: float = await d.height_drag_to(1.8)
	d.check(absf(got - 1.8) <= 0.21, "stairs height %.2f" % got)
	await d.click()
	await d.frames(10)
	d.check(d.plugin.tool_overlay.params_open, "the stairs' parameter modal opened")
	await d.overlay_param("steps", 6, 18)
	await d.overlay_param("steps", 9, 18)
	await d.overlay_param("steps", 12, 22)
	await d.overlay_button("ApplyParams", 14)
	stairs = _newest(before)
	d.check(stairs != null, "stairs placed")
	_tint(stairs, "steel")
	await d.frames(12)

## Re-edit a placed shape: out of placement (Material & UV tab), click the
## stairs, Edit Shape Properties, more steps — the stairs rebuild live.
func _reedit() -> void:
	if stairs == null:
		d.check(false, "stairs exist to re-edit")
		return
	await d.click_dock_member("_btn_mode_mat", 10)
	await d.frame_box_to(d.node_aabb(stairs).grow(0.8), 62.0, 18.0, 0.6, 40)
	var pick := d.node_aabb(stairs).get_center() + Vector3(0.0, 0.0, 0.4)
	await d.glide_world_track(pick, 18)
	await d.click()
	if EditorInterface.get_selection().get_selected_nodes().find(stairs) < 0:
		d.fallback("stairs click did not select them — selecting through the editor")
		await d.off(func():
			EditorInterface.get_selection().clear()
			EditorInterface.get_selection().add_node(stairs))
	await d.frames(10)
	await d.overlay_button("EditShapeProperties", 12)
	d.check(d.plugin.tool_overlay.params_open, "Edit Shape Properties reopened the modal")
	var s0 := int(stairs.pb_mesh_data.shape_params.get("steps", 0))
	await d.overlay_param("steps", 16, 18)
	await d.overlay_param("steps", 20, 24)
	await d.overlay_button("ApplyParams", 14)
	var s1 := int(stairs.pb_mesh_data.shape_params.get("steps", 0))
	_tint(stairs, "steel")
	d.check(s1 > s0, "steps re-edited (%d -> %d)" % [s0, s1])
	var f := d.framing(d.node_aabb(stairs).grow(0.8), 0.6, 62.0, 18.0)
	await d.cam_swing(f["center"], 62.0, 40.0, 18.0, 24.0, f["dist"], 40, 1, f["aim"])

## The door card: a drag across the opening, arched in the modal, Apply.
func _door() -> void:
	await d.click_dock_member("_btn_mode_shape", 10)
	await _shape_card(&"door")
	await d.frame_box_to(AABB(Vector3(1.6, 0.0, -0.6), Vector3(4.0, 3.2, 2.4)), 22.0, 16.0, 0.58, 40)
	var before := _created()
	await d.glide(d.w2s(Vector3(1.9, 0.0, 0.3)), 14)
	await d.drag(d.w2s(Vector3(1.9, 0.0, 0.3)), d.w2s(Vector3(5.3, 0.0, 1.2)), 32, false, 1)
	var got: float = await d.height_drag_to(3.0)
	d.check(absf(got - 3.0) <= 0.21, "door height %.2f" % got)
	await d.click()
	await d.frames(10)
	d.check(d.plugin.tool_overlay.params_open, "the door's parameter modal opened")
	await d.overlay_param_check("arched", true, 18)
	await d.frames(14)
	await d.overlay_button("ApplyParams", 14)
	door = _newest(before)
	d.check(door != null, "arched doorway placed")
	_tint(door, "slate")
	var f := d.framing(d.node_aabb(door).grow(0.4), 0.58, 22.0, 16.0)
	await d.cam_swing(f["center"], 22.0, 6.0, 16.0, 12.0, f["dist"], 44, 1, f["aim"])

## Edge-first placement: the Placement selector, then two walls whose first
## edge is clicked at an angle — the wall follows it.
func _edge() -> void:
	await d.click_dock_member("_btn_mode_shape", 8)
	await _shape_card(&"cube")
	await _pick_option(dock._opt_placement_style, PBShapeCreator.PlacementStyle.EDGE)
	d.check(d.plugin.shape_creator.placement_style == PBShapeCreator.PlacementStyle.EDGE,
		"edge-first placement selected in the dock")
	# A clear patch of floor beside the set: two walls meeting in a V, each
	# drawn from an edge clicked at an angle no axis-aligned drag can give.
	var area := AABB(Vector3(16.4, 0.0, -2.0), Vector3(7.2, 2.4, 4.0))
	await d.frame_box_to(area, 14.0, 30.0, 0.62, 60)
	var before := _created()
	await _edge_shape(Vector3(17.0, 0.0, 1.2), Vector3(19.7, 0.0, -1.3), Vector3(18.6, 0.0, -0.6), 2.2)
	var wa := _newest(before)
	before = _created()
	await _edge_shape(Vector3(20.3, 0.0, -1.3), Vector3(23.0, 0.0, 1.2), Vector3(21.4, 0.0, -0.6), 2.2)
	var wb := _newest(before)
	d.check(wa != null and wb != null, "two angled walls drawn edge-first")
	_tint(wa, "plum")
	_tint(wb, "plum")
	if wa != null:
		var xa := wa.global_transform.basis.x.normalized()
		d.check(absf(xa.dot(Vector3(2.7, 0.0, -2.5).normalized())) > 0.99, "the wall follows its clicked edge")
	await _pick_option(dock._opt_placement_style, PBShapeCreator.PlacementStyle.DRAG)
	await d.click_dock_member("_btn_mode_mat", 8)
	await d.off(func():
		EditorInterface.get_selection().clear()
		d.plugin.editor.active_mesh = null)
	var f := d.framing(area, 0.62, 14.0, 30.0)
	await d.cam_swing(f["center"], 14.0, 38.0, 30.0, 22.0, f["dist"], 70, 1, f["aim"])

## Every primitive in the Shapes tab, generated from parameters: the camera
## leaves the courtyard and trucks along the row.
func _lineup() -> void:
	var n := lineup.size()
	var span := float(n - 1) * LINEUP_GAP
	var a_eye := Vector3(LINEUP_X - 8.0, 3.6, 9.5)
	var a_tgt := Vector3(LINEUP_X + 3.0, 1.1, 0.0)
	var b_eye := Vector3(LINEUP_X + span + 6.0, 3.0, 8.0)
	var b_tgt := Vector3(LINEUP_X + span - 3.5, 1.1, 0.0)
	var eye0 := d.cam.global_position
	var tgt0 := eye0 + -d.cam.global_transform.basis.z * 12.0
	await d.cam_lerp(eye0, tgt0, a_eye, a_tgt, 70, 1)
	await d.cam_lerp(a_eye, a_tgt, b_eye, b_tgt, 300, 1)
	d.check(n >= 10, "the lineup holds %d primitives" % n)

# -----------------------------------------------------------------------------

## Edge-first: start click, edge-end click, depth click, height click.
func _edge_shape(a: Vector3, b: Vector3, depth_pt: Vector3, height: float) -> void:
	await d.glide(d.w2s(a), 16)
	await d.click(Vector2.INF, 4)
	await d.glide(d.w2s(b), 30, 1)
	await d.click(Vector2.INF, 4)
	d.check(int(d.plugin.shape_creator.edge_stage) == PBShapeCreator.EDGE_DEPTH,
		"the edge locked (stage %d)" % int(d.plugin.shape_creator.edge_stage))
	await d.glide(d.w2s(depth_pt), 22, 1)
	await d.click(Vector2.INF, 4)
	var got: float = await d.height_drag_to(height)
	d.check(absf(got - height) <= 0.21, "wall height %.2f (%.2f)" % [height, got])
	await d.click()

## Picks an OptionButton item the way a user does (see tour.gd).
func _pick_option(ob: OptionButton, item_id: int) -> void:
	var idx := ob.get_item_index(item_id)
	if ob.selected == idx:
		return
	await d.click_control(ob, 8)
	var popup := ob.get_popup()
	if popup.visible:
		for i in range(4):
			if popup.get_focused_item() == idx:
				break
			await _raw_key(KEY_DOWN if popup.get_focused_item() < idx else KEY_UP)
			await d.frames(6)
		await d.frames(6)
		await _raw_key(KEY_ENTER)
		await d.frames(8)
	if ob.selected != idx:
		ob.select(idx)
		ob.item_selected.emit(idx)
		d.fallback("option '%s' set via api (popup pick missed)" % ob.name)
	if popup.visible:
		popup.hide()
	await d.frames(4)

func _raw_key(k: Key) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = k
		ev.physical_keycode = k
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await d.frames(2)
