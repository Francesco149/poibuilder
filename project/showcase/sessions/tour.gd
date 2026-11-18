## SESSION — "tour": the v2 showcase prototype (edl_v2.toml).
##
## One continuous build instead of many isolated beats. A small courtyard is
## made on camera, chapter by chapter, and each chapter starts where the last
## one stopped: the same scene, the same light, the camera easing on from its
## last pose. No resets between shots and no unrelated framings, so the cut
## carries no jump in subject, pointer or light (the old film's ~65 short
## clips each opened on a fresh set).
##
## Every interaction is the real one a user makes: shapes and materials are
## picked from the Material & UV dock's cards, the placement style from its
## Shapes tab selector, a material is DRAGGED from a card onto a face in the
## viewport, and the card size comes from the dock's slider. The UI chapters
## frame the viewport and the dock together (region "viewport_dock"), so the
## viewer sees the click in the dock land in the 3D view.
##
## Render: PB_SHOWCASE_LAYOUT=showcase_video/layouts/tour.cfg \
##         ./showcase_video/render.sh tour
@tool
extends RefCounted

var d: ShowcaseDirector
var root: Node
var bench: PBMesh
var dock: PBMaterialDock
var platform: PBMesh = null
var pillar: PBMesh = null
var wall_a: PBMesh = null
var wall_b: PBMesh = null

const TEX := "res://addons/poibuilder/materials/textures/"

## The courtyard's working area (what the wide framings hold).
const SET_BOX := AABB(Vector3(-4.2, 0.0, -4.4), Vector3(8.6, 3.0, 7.4))

func run(dr: ShowcaseDirector) -> void:
	d = dr
	d.fill_scale = 1.25
	root = EditorInterface.get_edited_scene_root()
	dock = d.plugin.material_dock
	ShowcaseUtil.env(d.plugin, "day")
	ShowcaseUtil.grade_light(root)
	ShowcaseUtil.fresh_grid(d.plugin)
	ShowcaseUtil.use_default_material(ShowcaseUtil.CHECKER)
	# The editor HOME is shared with the other sessions: start (and end) on
	# the default placement style so no other render inherits this one's.
	d.plugin.set_placement_style(PBShapeCreator.PlacementStyle.DRAG)
	bench = ShowcaseUtil.floor_slab(root, 40.0, ShowcaseUtil.mat(root, "ink"))
	await d.grid_show(false)
	# Comfortable, readable cards for the video (the slider changes it later).
	dock.set_thumbnail_size(64)
	dock.set_dock_mode(PBMaterialDock.DockMode.MATERIAL)
	# Less clutter: the floating tool panel and the placement banner stay
	# out of the picture (the cylinder's parameters are applied through the
	# plugin, see _shapes). The dock is the UI this film is about.
	d.plugin.tool_overlay.set_panel_enabled(false)
	if d.plugin.mode_banner != null:
		d.plugin.mode_banner.modulate.a = 0.0
	# The PoiBuilder toolbar rows are hidden too: everything this film does
	# goes through the dock or the viewport (face mode by its K shortcut), so
	# the pointer never leaves the picture for a toolbar click, and the
	# dock+viewport frame carries no half-cropped toolbar.
	_hide_toolbar(true)
	await d.frames(4)
	d.snapshot_regions()
	await _pose(SET_BOX, 32.0, 30.0, 0.95)
	await d.frames(20)

	await d.shot("tour/shapes", _shapes)
	await d.shot("tour/edge", _edge)
	await d.shot("tour/extrude", _extrude)
	await d.shot("tour/materials", _materials)
	await d.shot("tour/paint", _paint)
	await d.shot("tour/finale", _finale)

	d.plugin.set_placement_style(PBShapeCreator.PlacementStyle.DRAG)
	d.plugin.tool_overlay.set_panel_enabled(true)
	if d.plugin.mode_banner != null:
		d.plugin.mode_banner.modulate.a = 1.0
	_hide_toolbar(false)

# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------

func _hide_toolbar(hide: bool) -> void:
	if d.plugin.toolbar != null:
		(d.plugin.toolbar as Control).visible = not hide

## Types into the focused control (raw key events with their unicode).
func _type(text: String) -> void:
	for ch in text:
		for pressed in [true, false]:
			var ev := InputEventKey.new()
			ev.keycode = OS.find_keycode_from_string(ch.to_upper())
			ev.unicode = ch.unicode_at(0) if pressed else 0
			ev.pressed = pressed
			Input.parse_input_event(ev)
			await d.frames(1)
		await d.frames(3)

func _pose(box: AABB, az: float, elev: float, fill: float) -> void:
	var f := d.framing(box, fill, az, elev)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(2)

func _created() -> Array:
	return ShowcaseUtil.names_of(root, "Shape_")

func _newest(before: Array) -> PBMesh:
	for n in _created():
		if not before.has(n):
			return n
	return null

## A palette card whose name contains `needle` (cards carry their lowercase
## name and file name as meta, the same key the dock's filter matches).
func _card(needle: String) -> Control:
	for c in dock._material_grid.get_children():
		if c is Control and (c as Control).visible and not c.is_queued_for_deletion() \
				and str(c.get_meta("pb_card_name", "")).contains(needle):
			return c
	return null

## Picks an OptionButton item the way a user does: click it open, walk the
## highlight down to the item, Enter. Keys go straight to the open popup
## (ShowcaseDirector.key() would grab the viewport's focus and close it).
## Falls back to selecting through the API (and logs it).
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
		d._log_line("option '%s' set via api (popup pick missed)" % ob.name)
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

## Top centre of a mesh's highest face, in world space (the click target for
## the platform; created nodes keep their origin at mid-height).
func _top_point(node: PBMesh, offset := Vector3.ZERO) -> Vector3:
	var box := d.node_aabb(node)
	return Vector3(box.get_center().x, box.end.y - 0.01, box.get_center().z) + offset

## Base drag + height on the drag flow, then the confirming click.
func _drag_shape(a: Vector3, b: Vector3, height: float) -> void:
	await d.drag(d.w2s(a), d.w2s(b), 30, false, 1)
	var got: float = await d.height_drag_to(height)
	d.check(absf(got - height) <= 0.21, "height reached %.2f m (%.2f)" % [height, got])
	await d.click()

## Edge-first: start click, edge-end click, depth click, height click.
func _edge_shape(a: Vector3, b: Vector3, depth_pt: Vector3, height: float) -> void:
	await d.click(d.w2s(a), 4)
	await d.glide(d.w2s(b), 30, 1)
	await d.click(Vector2.INF, 4)
	d.check(int(d.plugin.shape_creator.edge_stage) == PBShapeCreator.EDGE_DEPTH,
		"the edge locked (stage %d)" % int(d.plugin.shape_creator.edge_stage))
	await d.glide(d.w2s(depth_pt), 22, 1)
	await d.click(Vector2.INF, 4)
	d.check(d.plugin.shape_creator.state == PBShapeCreator.State.HEIGHT, "depth confirmed, height next")
	var got: float = await d.height_drag_to(height)
	d.check(absf(got - height) <= 0.21, "wall height %.2f m (%.2f)" % [height, got])
	await d.click()

# -----------------------------------------------------------------------------
# chapters
# -----------------------------------------------------------------------------

## Shapes from the dock: the Shapes tab, a card, a drag on the floor. Then a
## second card (a cylinder) whose parameter modal previews live.
func _shapes() -> void:
	await d.click_dock_member("_btn_mode_shape", 10)
	d.check(dock.dock_mode == PBMaterialDock.DockMode.SHAPE, "Shapes tab open")
	await d.click_control(dock._shape_card_buttons[&"cube"], 10)
	var before := _created()
	await _drag_shape(Vector3(-2.4, 0.0, -1.0), Vector3(2.4, 0.0, 2.2), 0.6)
	platform = _newest(before)
	d.check(platform != null, "platform drawn from the dock's cube card")
	if platform != null:
		ShowcaseUtil.dress_material(platform, ShowcaseUtil.checker_mat(root, "steel"))
	await d.frames(10)
	await d.click_control(dock._shape_card_buttons[&"cylinder"], 10)
	before = _created()
	await _drag_shape(Vector3(2.9, 0.0, 1.0), Vector3(3.7, 0.0, 1.8), 2.4)
	await d.frames(10)
	if d.plugin.tool_overlay.params_open or d.plugin.shape_creator.state == PBShapeCreator.State.PARAMS:
		d.plugin.call("_on_params_applied")
		await d.frames(6)
	pillar = _newest(before)
	d.check(pillar != null, "pillar drawn from the cylinder card")
	if pillar != null:
		ShowcaseUtil.dress_material(pillar, ShowcaseUtil.checker_mat(root, "stone"))
	var f := d.framing(SET_BOX, 0.95, 32.0, 30.0)
	await d.cam_swing(f["center"], 32.0, 24.0, 30.0, 28.0, float(f["dist"]), 30, 1, f["aim"])

## Edge-first placement (opt-in): the Shapes tab's Placement selector, then
## two walls at angles nothing axis-aligned could draw. Each wall: click the
## start, click the edge's end (the wall's direction), pull its thickness,
## then its height.
func _edge() -> void:
	await d.click_control(dock._shape_card_buttons[&"cube"], 6)
	await _pick_option(dock._opt_placement_style, PBShapeCreator.PlacementStyle.EDGE)
	d.check(d.plugin.shape_creator.placement_style == PBShapeCreator.PlacementStyle.EDGE,
		"edge-first placement selected in the dock")
	var before := _created()
	await _edge_shape(Vector3(-3.8, 0.0, -2.0), Vector3(-0.2, 0.0, -3.9),
		Vector3(-1.9, 0.0, -2.5), 2.6)
	wall_a = _newest(before)
	before = _created()
	await _edge_shape(Vector3(0.6, 0.0, -3.9), Vector3(3.9, 0.0, -1.6),
		Vector3(2.4, 0.0, -2.3), 2.6)
	wall_b = _newest(before)
	d.check(wall_a != null and wall_b != null, "two angled walls drawn edge-first")
	if wall_a != null:
		ShowcaseUtil.dress_material(wall_a, ShowcaseUtil.checker_mat(root, "slate"))
	if wall_b != null:
		ShowcaseUtil.dress_material(wall_b, ShowcaseUtil.checker_mat(root, "plum"))
	if wall_a != null:
		var xa := wall_a.global_transform.basis.x.normalized()
		d.check(absf(xa.dot(Vector3(3.6, 0.0, -1.9).normalized())) > 0.99,
			"the first wall follows its clicked edge")
	var f := d.framing(SET_BOX, 0.95, 24.0, 28.0)
	await d.cam_swing(f["center"], 24.0, 12.0, 28.0, 24.0, float(f["dist"]), 26, 1, f["aim"])

## A face, lifted: back to Material & UV (placement ends), face mode, the
## platform's top face, Shift+drag to extrude it into a dais.
func _extrude() -> void:
	await _pick_option(dock._opt_placement_style, PBShapeCreator.PlacementStyle.DRAG)
	await d.click_dock_member("_btn_mode_mat", 8)
	if platform == null:
		d.check(false, "platform exists for the extrude")
		return
	await d.frame_box_to(d.node_aabb(platform).grow(1.2), 28.0, 30.0, 0.7, 30)
	var top := _top_point(platform)
	await d.pick_world(top, 6)
	await d.key(KEY_K)
	d.check(d.plugin.editor.select_mode == PBEditor.SelectMode.FACE, "K switched to face mode")
	await d.pick_world(top, 8)
	var faces_before: int = platform.pb_mesh_data.faces.size()
	var top_before := d.node_aabb(platform).end.y
	# The drag starts ON the face's pivot: the editor verifies an extrude
	# against the live cursor, measured from where the drag began, so a
	# pointer that jumps onto the pivot at the first drag frame reads as a
	# pull along the normal (v1 of this beat sank the cap into the floor).
	await d.glide(d.drag_cursor_for(Vector3.ZERO), 10)
	await d.move_selection(Vector3(0.0, 0.6, 0.0), 40, true)
	var top_after := d.node_aabb(platform).end.y
	d.check(platform.pb_mesh_data.faces.size() > faces_before and absf(top_after - top_before - 0.6) < 0.25,
		"Shift+drag extruded the top face UP (%d -> %d faces, top %.2f -> %.2f)"
		% [faces_before, platform.pb_mesh_data.faces.size(), top_before, top_after])
	await d.frames(16)

## The dock and the viewport together. A face on a wall, then a card click
## puts the material on it; a card DRAGGED onto the dais lands on the face
## under the drop; the size slider makes every card smaller.
func _materials() -> void:
	await d.frame_box_to(SET_BOX, 22.0, 24.0, 0.92, 28)
	if wall_a != null:
		# The wall's broad face that looks toward the courtyard (+Z side of
		# its forward axis, which edge-first points at the pulled depth).
		# (The wall is ~0.4 m thick; a point just in front of its centre puts
		# the click on that face from the courtyard camera.)
		var fwd := wall_a.global_transform.basis.z.normalized()
		var face_pt := d.node_aabb(wall_a).get_center() + fwd * 0.3
		await d.pick_world(face_pt, 8)
		var am = d.plugin.editor.active_mesh
		d._log_line("wall click: active=%s faces=%s brick_card=%s" % [
			String(am.name) if am != null else "<none>",
			str(d.plugin.editor.selection.selected_faces), str(_card("brick") != null)])
	var brick := _card("brick")
	if brick != null:
		await d.click_control(brick, 14)
	d.check(wall_a != null and _wears(wall_a, "brick"), "a card click dressed the selected wall face")
	# The filter finds the card (it was below the fold of the palette), then
	# the card is dragged from the dock onto the dais.
	await d.click_control(dock._filter_edit, 6)
	await _type("wood")
	await d.frames(10)
	var wood := _card("wood")
	d.check(wood != null and wood.get_global_rect().intersects(dock._scroll.get_global_rect()),
		"filtering for 'wood' brought its card into view")
	var mats_before := _material_count(platform)
	if wood != null and platform != null:
		var drop_at := d.w2s(_top_point(platform, Vector3(0.5, 0.0, 0.3)))
		await d.glide(wood.get_global_rect().get_center(), 18)
		await d.drag(wood.get_global_rect().get_center(), drop_at, 44, false, 1)
		await d.frames(12)
	d.check(platform != null and _material_count(platform) > mats_before,
		"a card dropped onto the dais dressed that face (%d -> %d materials)" % [mats_before, _material_count(platform)])
	dock._filter_edit.clear()
	dock._apply_palette_filter()
	await d.frames(8)
	var slider: HSlider = dock._thumb_slider
	var r := slider.get_global_rect()
	var before := dock.get_thumbnail_size()
	var grab_x := r.position.x + r.size.x * (float(before - PBMaterialDock.THUMB_MIN)
		/ float(PBMaterialDock.THUMB_MAX - PBMaterialDock.THUMB_MIN))
	await d.glide(Vector2(grab_x, r.get_center().y), 16)
	await d.drag(Vector2(grab_x, r.get_center().y), Vector2(r.position.x + 2.0, r.get_center().y), 24, false, 1)
	d.check(dock.get_thumbnail_size() < before, "the slider shrank the cards (%d -> %d px)" % [before, dock.get_thumbnail_size()])
	await d.frames(20)

func _material_count(node: PBMesh) -> int:
	if node == null:
		return 0
	var seen := {}
	for f in node.pb_mesh_data.faces:
		seen[node.pb_mesh_data.get_face_material(f)] = true
	return seen.size()

func _wears(node: PBMesh, needle: String) -> bool:
	for f in node.pb_mesh_data.faces:
		var m := node.pb_mesh_data.get_face_material(f)
		if m == null:
			continue
		var key := (m.resource_name + " " + m.resource_path + " " + str(m.get_meta("source_texture_path", ""))).to_lower()
		if m is StandardMaterial3D and (m as StandardMaterial3D).albedo_texture != null:
			key += " " + (m as StandardMaterial3D).albedo_texture.resource_path.to_lower()
		if key.contains(needle):
			return true
	return false

## Painting from the dock: the Paint tab, a texture card, strokes on the dais.
func _paint() -> void:
	if platform == null:
		d.check(false, "platform exists for painting")
		return
	await d.off(func():
		EditorInterface.get_selection().clear()
		EditorInterface.get_selection().add_node(platform))
	await d.frame_box_to(d.node_aabb(platform).grow(0.6), 34.0, 46.0, 0.8, 26)
	await d.click_dock_member("_btn_mode_paint", 10)
	var wet := _card("tiles_wet")
	if wet != null:
		await d.click_control(wet, 10)
	var pc = d.plugin.paint_controller
	d.check(int(pc.mode) == 1, "paint mode from the dock (mode=%d)" % int(pc.mode))
	pc.brush_radius = 0.55
	pc.brush_softness = 0.6
	await d.frames(4)
	var y := d.node_aabb(platform).end.y - 0.02
	var strokes := [
		[Vector3(-2.0, y, 1.8), Vector3(-0.4, y, 0.4), Vector3(1.6, y, -0.4)],
		[Vector3(0.6, y, 1.9), Vector3(1.9, y, 1.0)],
	]
	for stroke in strokes:
		for i in range(stroke.size() - 1):
			await d.drag(d.w2s(stroke[i]), d.w2s(stroke[i + 1]), 18, false, 0)
	await d.frames(12)

## Out of the tools, the light turns, one slow look at what was made.
func _finale() -> void:
	await d.click_dock_member("_btn_mode_mat", 6)
	await d.off(func():
		EditorInterface.get_selection().clear()
		d.plugin.editor.active_mesh = null)
	var f := d.framing(SET_BOX, 0.9, 40.0, 22.0)
	await d.cam_swing(f["center"], 40.0, -30.0, 22.0, 16.0, float(f["dist"]), 220, 1, f["aim"])
