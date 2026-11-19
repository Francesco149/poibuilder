## SESSION — "v2_surface": materials, UVs, paint and the placement tabs for
## showcase v2 (edl_v2*.toml).
##
## One courtyard corner dressed in front of the viewer, entirely from the
## Material & UV dock (framed with the 3D view, "viewport_dock"; the toolbar
## is hidden, face mode comes from its K shortcut):
##
##   v2s/card       a wall face selected, a card click textures it; x2 tiling
##   v2s/drop       a filtered card DRAGGED from the dock onto the pillar
##   v2s/scroll     a waterfall sheet given a scroll speed: it flows live
##                  (third, so it flows behind every later beat)
##   v2s/uv         the UV Editor tab: rotate, flip, box-project the face
##   v2s/paint      Texture Paint: two texture layers brushed onto the floor
##   v2s/stamp      Stamp: decals pressed into the floor
##   v2s/sprite     Sprite: a billboard tree placed, raised, scaled
##   v2s/particles  Particles: a flame emitter on the pillar
##
## Render: PB_SHOWCASE_LAYOUT=showcase_video/layouts/tour.cfg \
##         ./showcase_video/render.sh v2_surface
@tool
extends RefCounted

var d: ShowcaseDirector
var root: Node
var dock: PBMaterialDock
var bench: PBMesh
var court: PBMesh
var wall: PBMesh
var pillar: PBMesh
var sheet: PBMesh

const TEX := "res://addons/poibuilder/materials/textures/"
const SET_BOX := AABB(Vector3(-3.6, 0.0, -4.0), Vector3(7.2, 3.4, 7.6))

func run(dr: ShowcaseDirector) -> void:
	d = dr
	d.fill_scale = 1.25
	root = EditorInterface.get_edited_scene_root()
	dock = d.plugin.material_dock
	ShowcaseUtil.env(d.plugin, "day")
	ShowcaseUtil.grade_light(root)
	ShowcaseUtil.fresh_grid(d.plugin)
	ShowcaseUtil.use_default_material(ShowcaseUtil.CHECKER)
	bench = ShowcaseUtil.floor_slab(root, 60.0, ShowcaseUtil.mat(root, "ink"))
	# The wet tiles: mid-toned, so painted layers read on them (the light tiles
	# blow out to white, and a splat material does not carry a tint).
	court = ShowcaseUtil.mesh(root, "Court", PBShapeGenerators.create_box(Vector3(7.2, 0.4, 7.2)),
		Vector3(0.0, 0.2, 0.0), PBMeshData.load_material_or_texture(TEX + "tiles_wet_4x4.png"))
	wall = ShowcaseUtil.mesh(root, "Wall", PBShapeGenerators.create_box(Vector3(7.2, 3.4, 0.5)),
		Vector3(0.0, 2.1, -3.85), ShowcaseUtil.checker_mat(root, "stone"))
	pillar = ShowcaseUtil.mesh(root, "Pillar", PBShapeGenerators.create_box(Vector3(0.9, 2.2, 0.9)),
		Vector3(2.4, 1.5, -1.6), ShowcaseUtil.checker_mat(root, "slate"))
	# The waterfall sheet: a plane stood up just in front of the wall's left half.
	var water := PBMeshData.load_material_or_texture(TEX + "waterfall_sheet.png")
	if water is StandardMaterial3D:
		(water as StandardMaterial3D).transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		(water as StandardMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED
	sheet = ShowcaseUtil.mesh(root, "FallSheet", PBShapeGenerators.create_plane(2.0, 3.2),
		Vector3(-2.2, 2.0, -3.55), water)
	sheet.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	await d.grid_show(false)
	dock.set_thumbnail_size(64)
	dock.set_dock_mode(PBMaterialDock.DockMode.MATERIAL)
	if d.plugin.mode_banner != null:
		d.plugin.mode_banner.modulate.a = 0.0
	(d.plugin.toolbar as Control).visible = false
	d.plugin.gizmo_plugin.apply_display_opacities(0.7, 1.0, 0.6)
	await d.frames(4)
	d.snapshot_regions()
	await d.lift_panel(80.0)
	var f := d.framing(SET_BOX, 0.95, 28.0, 26.0)
	d.cam_at_polar(f["center"], 28.0, 26.0, f["dist"], f["aim"])
	await d.frames(20)

	# The scroll beat comes THIRD: the waterfall sheet is in frame for the
	# whole chapter, and a still "waterfall" behind every later beat read as
	# a bug. Once it flows, it flows behind the UV, paint and placement beats.
	for s in [["v2s/card", _card_click], ["v2s/drop", _drop], ["v2s/scroll", _scroll],
			["v2s/uv", _uv], ["v2s/paint", _paint], ["v2s/stamp", _stamp],
			["v2s/sprite", _sprite], ["v2s/particles", _particles]]:
		if d.only_done():
			break
		await d.shot(s[0], s[1])

	d.plugin.paint_controller.mode = PBPaintController.Mode.NONE
	(d.plugin.toolbar as Control).visible = true
	if d.plugin.mode_banner != null:
		d.plugin.mode_banner.modulate.a = 1.0
	d.plugin.gizmo_plugin.apply_display_opacities(0.7, 0.25, 0.25)

# -----------------------------------------------------------------------------

func _card(needle: String) -> Control:
	for c in dock._material_grid.get_children():
		if c is Control and (c as Control).visible and not c.is_queued_for_deletion() \
				and str(c.get_meta("pb_card_name", "")).contains(needle):
			return c
	return null

func _select_node(node: Node) -> void:
	await d.off(func():
		d.plugin.editor.selection.clear_all()
		EditorInterface.get_selection().clear()
		EditorInterface.get_selection().add_node(node))
	await d.frames(4)

func _face_mode() -> void:
	if d.plugin.editor.select_mode != PBEditor.SelectMode.FACE:
		await d.key(KEY_K)
	d.check(d.plugin.editor.select_mode == PBEditor.SelectMode.FACE, "face mode (K)")

func _wears(node: PBMesh, needle: String) -> bool:
	for fi in node.pb_mesh_data.faces:
		var m := node.pb_mesh_data.get_face_material(fi)
		if m == null:
			continue
		var key := (m.resource_name + " " + m.resource_path + " " + str(m.get_meta("source_texture_path", ""))).to_lower()
		if m is StandardMaterial3D and (m as StandardMaterial3D).albedo_texture != null:
			key += " " + (m as StandardMaterial3D).albedo_texture.resource_path.to_lower()
		if key.contains(needle):
			return true
	return false

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

## Where the editor's bottom bar shows `title` (a Button in older layouts, a
## TabBar tab in 4.7's dock-based bottom panel); INF when it is not on screen.
func _bottom_tab(title: String) -> Vector2:
	var stack: Array = [EditorInterface.get_base_control()]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is TabBar and (n as Control).is_visible_in_tree():
			var tb := n as TabBar
			for i in range(tb.tab_count):
				if tb.get_tab_title(i) == title:
					return tb.get_global_rect().position + tb.get_tab_rect(i).get_center()
		elif n is Button and (n as Button).text == title and (n as Control).is_visible_in_tree():
			return (n as Control).get_global_rect().get_center()
		for c in n.get_children():
			stack.append(c)
	var seen: Array = []
	var stack2: Array = [EditorInterface.get_base_control()]
	while not stack2.is_empty():
		var n2: Node = stack2.pop_back()
		if n2 is TabBar:
			for i in range((n2 as TabBar).tab_count):
				seen.append("tab:" + (n2 as TabBar).get_tab_title(i))
		elif n2 is BaseButton and n2 is Button and "UV" in (n2 as Button).text:
			seen.append("button:%s visible=%s" % [(n2 as Button).text, str((n2 as Control).is_visible_in_tree())])
		for c in n2.get_children():
			stack2.append(c)
	d._log_line("no '%s' on the bottom bar; candidates: %s" % [title, ", ".join(seen)])
	return Vector2.INF

func _card_names() -> String:
	var out: Array = []
	for c in dock._material_grid.get_children():
		if c is Control and (c as Control).visible:
			out.append(str(c.get_meta("pb_card_name", "?")))
	return ", ".join(out)

func _win_pos(c: Control) -> Vector2:
	return c.get_global_rect().get_center()

# -----------------------------------------------------------------------------
# beats
# -----------------------------------------------------------------------------

## A wall face, then a card: the face wears it. x2 halves the tiling.
func _card_click() -> void:
	await _select_node(wall)
	await _face_mode()
	await d.frame_box_to(AABB(Vector3(-3.6, 0.4, -4.1), Vector3(7.2, 3.4, 3.0)), 18.0, 14.0, 0.85, 40)
	var face_pt := Vector3(0.6, 2.2, -3.6)
	await d.glide_world_track(face_pt, 20)
	await d.click()
	d.check(not d.plugin.editor.selection.selected_faces.is_empty(), "the wall's front face selected")
	await d.frames(10)
	var brick := _card("brick")
	d.check(brick != null, "a brick card is in the palette")
	if brick != null:
		await d.glide(_win_pos(brick), 22)
		await d.click(Vector2.INF, 16)
	d.check(_wears(wall, "brick"), "a card click textured the wall face")
	await d.frames(20)
	await d.click_control(dock._btn_x2, 18)
	await d.frames(24)

## Filter the palette, then drag a card from the dock onto the pillar.
func _drop() -> void:
	await d.frame_box_to(AABB(Vector3(0.6, 0.4, -3.0), Vector3(3.6, 2.4, 3.0)), 30.0, 20.0, 0.85, 40)
	await d.click_control(dock._filter_edit, 6)
	await _type("light")
	await d.frames(12)
	var wood := _card("tiles_light")
	if wood == null:
		d._log_line("filter text '%s'; visible cards: %s" % [dock._filter_edit.text, _card_names()])
	d.check(wood != null, "filtering found the light-tiles card")
	if wood != null:
		var drop_at := d.w2s(Vector3(2.4, 1.6, -1.15))
		await d.glide(_win_pos(wood), 18)
		await d.drag(_win_pos(wood), drop_at, 46, false, 1)
		await d.frames(14)
	d.check(_wears(pillar, "tiles_light"), "the card dropped on the pillar dressed its face")
	dock._filter_edit.clear()
	dock._apply_palette_filter()
	await d.frames(16)

## The UV Editor tab with the pillar's front face selected: rotate, flip,
## box-project, and the 3D view follows each click.
func _uv() -> void:
	# The brick face: a directional texture, so a rotation or a flip reads.
	await _select_node(wall)
	await _face_mode()
	await d.frame_box_to(AABB(Vector3(-3.6, 0.4, -4.1), Vector3(7.2, 3.4, 3.0)), 18.0, 14.0, 0.6, 30)
	await d.glide_world_track(Vector3(0.6, 2.2, -3.6), 18)
	await d.click()
	await d.frames(8)
	var uv: PBUvEditorPanel = d.plugin.uv_editor_panel
	var tab_at := _bottom_tab("UV Editor")
	# Godot 4.7's bottom bar does not expose the tab as a control the pointer
	# can find; then the panel opens through the plugin (logged), and the cut
	# starts once it is open.
	if tab_at != Vector2.INF:
		await d.glide(tab_at, 22)
		await d.click(Vector2.INF, 20)
	if not uv.is_visible_in_tree():
		d.fallback("bottom-bar click did not open the UV Editor — opening it through the plugin")
		d.plugin.focus_uv_editor()
		await d.frames(12)
	d.check(uv.is_visible_in_tree(), "the UV editor is open")
	if uv.canvas != null:
		uv.canvas.frame_unit_square()
	await d.frames(10)
	for b in [uv._btn_rot_cw, uv._btn_flip_u, uv._btn_rot_cw, uv._btn_proj_box]:
		if b != null and (b as Control).is_visible_in_tree():
			await d.glide(_win_pos(b), 16)
			await d.click(Vector2.INF, 28)
	d.check(uv.is_visible_in_tree(), "the UV editor stayed open through the edits")
	await d.frames(20)
	if tab_at != Vector2.INF:
		await d.glide(_bottom_tab("UV Editor"), 18)
		await d.click(Vector2.INF, 16)
	if uv.is_visible_in_tree():
		d.plugin.hide_bottom_panel()
		await d.frames(6)
	d.check(not uv.is_visible_in_tree(), "the UV editor closed again")
	await d.frames(8)

## Texture Paint: two texture cards, strokes on the floor — each its own layer.
func _paint() -> void:
	await d.off(func():
		EditorInterface.get_selection().clear()
		EditorInterface.get_selection().add_node(court))
	await d.frame_box_to(AABB(Vector3(-3.6, 0.0, -2.8), Vector3(7.2, 0.6, 6.4)), 26.0, 46.0, 0.9, 40)
	await d.click_dock_member("_btn_mode_paint", 12)
	var pc = d.plugin.paint_controller
	d.check(int(pc.mode) == PBPaintController.Mode.PAINT, "paint mode from the dock")
	pc.brush_radius = 0.55
	pc.brush_softness = 0.6
	var y := 0.4
	var layers := [
		["brick_path", [[Vector3(-2.8, y, 2.8), Vector3(-0.8, y, 0.8), Vector3(0.0, y, -1.6), Vector3(-0.6, y, -2.8)]]],
		["grass", [[Vector3(1.0, y, 2.8), Vector3(2.8, y, 1.4)], [Vector3(-3.0, y, -0.6), Vector3(-2.0, y, -2.4)]]],
	]
	for layer in layers:
		var card := _card(layer[0])
		if card == null:
			d._log_line("no '%s' paint card — using the first texture card" % layer[0])
			card = dock._material_grid.get_child(0) if dock._material_grid.get_child_count() > 0 else null
		if card != null:
			await d.glide(_win_pos(card), 20)
			await d.click(Vector2.INF, 12)
		for stroke in layer[1]:
			for i in range(stroke.size() - 1):
				await d.drag(d.w2s(stroke[i]), d.w2s(stroke[i + 1]), 20, false, 0)
	await d.frames(20)

## Stamp: a decal card, two clicks — pressed into the floor as pixels.
func _stamp() -> void:
	await d.click_dock_member("_btn_mode_stamp", 12)
	var pc = d.plugin.paint_controller
	d.check(int(pc.mode) == PBPaintController.Mode.STAMP, "stamp mode from the dock")
	var card := _card("hello")
	if card == null:
		d._log_line("no hello-world stamp card; stamp cards: %s" % _card_names())
		card = _card("stamp")
	if card != null:
		await d.glide(_win_pos(card), 20)
		await d.click(Vector2.INF, 12)
	pc.stamp_scale = 1.4
	for p in [Vector3(1.4, 0.4, 0.4), Vector3(-1.6, 0.4, 1.6)]:
		await d.glide_world_track(p, 24)
		await d.frames(8)
		await d.click(Vector2.INF, 14)
	d.check(ShowcaseUtil.has_decal_paint(court), "stamps landed as painted pixels")
	await d.frames(16)

## Sprite: a billboard card; click the floor, raise, scale.
func _sprite() -> void:
	await d.click_dock_member("_btn_mode_sprite", 12)
	var card := _card("tree")
	d.check(card != null, "a tree sprite card")
	if card != null:
		await d.glide(_win_pos(card), 20)
		await d.click(Vector2.INF, 12)
	var before := root.get_child_count()
	var base := Vector3(-1.3, 0.4, -2.2)
	await d.glide_world_track(base, 24)
	await d.click(Vector2.INF, 10)
	await d.glide(d.w2s(base + Vector3(0.0, 0.3, 0.0)), 14)
	await d.click(Vector2.INF, 10)
	await d.glide(d.w2s(base + Vector3(0.0, 0.3, 0.0)) + Vector2(70.0, 0.0), 20)
	await d.click(Vector2.INF, 14)
	d.check(root.get_child_count() > before, "a billboard was placed (%d -> %d nodes)" % [before, root.get_child_count()])
	await d.frames(16)

## Particles: the flame card, then the emitter on the pillar's top.
func _particles() -> void:
	await d.click_dock_member("_btn_mode_particle", 12)
	var card := _card("flame")
	d.check(card != null, "a flame particle card")
	if card != null:
		await d.glide(_win_pos(card), 20)
		await d.click(Vector2.INF, 12)
	var top := Vector3(2.4, 2.6, -1.6)
	await d.frame_box_to(AABB(Vector3(1.2, 0.4, -2.8), Vector3(2.4, 3.6, 2.4)), 30.0, 14.0, 0.8, 36)
	var before := root.get_child_count()
	await d.glide_world_track(top, 20)
	await d.click(Vector2.INF, 10)
	await d.glide(d.w2s(top + Vector3(0.0, 0.15, 0.0)), 12)
	await d.click(Vector2.INF, 10)
	await d.click(Vector2.INF, 14)
	d.check(root.get_child_count() > before, "an emitter was placed")
	await d.frames(90)

## Scroll: the waterfall sheet's face gets a V speed; the sheet flows live.
func _scroll() -> void:
	await d.click_dock_member("_btn_mode_mat", 10)
	await d.key(KEY_ESCAPE)
	await _select_node(sheet)
	await _face_mode()
	await d.frame_box_to(AABB(Vector3(-3.6, 0.4, -4.1), Vector3(4.0, 3.4, 2.0)), 20.0, 10.0, 0.85, 40)
	await d.glide_world_track(Vector3(-2.2, 2.0, -3.55), 18)
	await d.click()
	# The sheet is a single alpha-blended quad standing 5 cm off the wall; if
	# the pick went through it to the wall, select the sheet's face directly.
	if d.active_mesh() != sheet or d.plugin.editor.selection.selected_faces.is_empty():
		d.fallback("sheet click picked %s — selecting the sheet's face via the protocol" % [
			String(d.active_mesh().name) if d.active_mesh() != null else "<none>"])
		await _select_node(sheet)
		d.apply_selection_ids(PackedInt32Array([0]))
		await d.frames(6)
	d.check(d.active_mesh() == sheet and not d.plugin.editor.selection.selected_faces.is_empty(), "the sheet's face selected")
	var sv: Range = dock._spin_scroll_v
	if sv != null:
		await d.glide(_win_pos(sv), 18)
		await d.click(Vector2.INF, 6)
		sv.value = -0.75
		await d.frames(10)
	await d.click_control(dock._btn_scroll_apply, 16)
	d.check(d.plugin.animate_scrolling_textures, "the viewport animates scrolling textures")
	await d.off(func():
		EditorInterface.get_selection().clear()
		d.plugin.editor.active_mesh = null)
	var f := d.framing(SET_BOX, 0.95, 20.0, 18.0)
	await d.cam_swing(f["center"], 20.0, 40.0, 18.0, 24.0, f["dist"], 150, 1, f["aim"])
