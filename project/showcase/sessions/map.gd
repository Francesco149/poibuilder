## ACT — building the retro showcase map in the editor.
##
## The same courtyard the PSP runs in the next act, assembled piece by piece
## with the creation flow: floor, perimeter walls, an arched doorway cut into
## the north wall, the grand stairs and their balcony, pillars, a ramp, then the
## surface work (brick path, decal) and finally the retro export.
##
## Each beat drag-creates its piece with the real gesture, so the viewer sees
## the map being built rather than appearing.
@tool
extends RefCounted

var director: ShowcaseDirector
var d: ShowcaseDirector
var root: Node
var bench: PBMesh
var pieces: Array[PBMesh] = []

const TILES := "res://addons/poibuilder/materials/textures/tiles_light_4x4.png"
# A darker ceramic for the floor: the walls wear the light tile, and two
# near-white surfaces meeting at a corner read as one undifferentiated blob.
const FLOOR_TILES := "res://addons/poibuilder/materials/textures/tiles_wet_4x4.png"
const BRICK := "res://addons/poibuilder/materials/textures/brick_path_4x4.png"
const STAMP := "res://addons/poibuilder/materials/textures/stamp_hello_world.png"

const COURT := 12.0                    # courtyard footprint (metres)
const WALL_H := 4.2
const WALL_T := 0.5

func run(dr: ShowcaseDirector) -> void:
	d = dr
	# Tighter than the default framing: the video is watched at README
	# size, so subjects should sit large in the frame.
	d.fill_scale = 1.35
	root = EditorInterface.get_edited_scene_root()
	ShowcaseUtil.env(d.plugin, "day")
	ShowcaseUtil.grade_light(root)
	ShowcaseUtil.use_default_material("res://materials/showcase_stone.tres")
	bench = ShowcaseUtil.floor_slab(root, 90.0, ShowcaseUtil.mat(root, "ink"))
	await d.frames(16)
	await d.shot("map/floor", _floor)
	await d.shot("map/arch", _arch)
	await d.shot("map/stairs", _stairs)
	await d.shot("map/pillars", _pillars)
	await d.shot("map/paint", _paint)
	await d.shot("map/export", _export)
	await d.shot("map/night", _night)
	d.snapshot_regions()

# -----------------------------------------------------------------------------

## Frames the courtyard working area from a chosen corner.
func _court_view(az := 38.0, elev := 26.0, fill := 0.86, height := 6.0) -> Dictionary:
	var box := AABB(Vector3(-COURT * 0.5 - 3.0, 0.0, -COURT * 0.5 - 3.0),
		Vector3(COURT + 6.0, height, COURT + 6.0))
	return d.framing(box, fill, az, elev)

## Drag-creates a piece on the ground plane and remembers it. `pre_apply` runs
## while the shape's parameter modal is open (e.g. to toggle a boolean).
func _place(shape_id: StringName, name_hint: String, a: Vector3, b: Vector3,
		height: float, color := "stone", pre_apply: Callable = Callable(),
		dress := "") -> PBMesh:
	var before := ShowcaseUtil.names_of(root, "Shape_")
	# Move onto the work area BEFORE the gesture: a courtyard-wide view hides the
	# piece being built, and the piece is what the beat is about.
	var lo := a.min(b) - Vector3(2.2, 0.0, 2.2)
	var span := (b - a).abs() + Vector3(4.4, height + 2.2, 4.4)
	await d.frame_box_to(AABB(lo, span), 36.0, 26.0, 0.55, 24)
	await d.arm_shape(shape_id)
	await d.drag(d.w2s(a), d.w2s(b), 26)
	await d.glide_world_track(Vector3(b.x, height, b.z), 18)
	await d.click()
	await d.frames(8)
	if d.plugin.tool_overlay.params_open:
		if pre_apply.is_valid():
			await pre_apply.call()
		await d.overlay_button("ApplyParams", 12)
	var after := ShowcaseUtil.names_of(root, "Shape_")
	for n in after:
		if not before.has(n):
			n.name = name_hint
			if dress != "":
				ShowcaseUtil.dress(n, dress)
			pieces.append(n)
			return n
	return null

func _all_aabb() -> AABB:
	var box := AABB(Vector3(-COURT, 0, -COURT), Vector3(COURT * 2, WALL_H, COURT * 2))
	return box

# -----------------------------------------------------------------------------
# beats
# -----------------------------------------------------------------------------

func _floor() -> void:
	var f := _court_view(40.0, 30.0, 0.9, 6.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(6)
	var slab := await _place(&"cube", "CourtFloor",
		Vector3(-COURT * 0.5, 0.0, -COURT * 0.5), Vector3(COURT * 0.5, 0.0, COURT * 0.5),
		0.5, "stone")
	d.check(slab != null, "courtyard floor built")
	if slab != null:
		ShowcaseUtil.dress(slab, FLOOR_TILES)
	await d.cam_swing(f["center"], 40.0, 30.0, 30.0, 38.0, f["dist"], 34, 1, f["aim"])

func _arch() -> void:
	var f := _court_view(20.0, 24.0, 0.9, 7.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(6)
	# four walls, then an arched doorway in the north one
	var t: float = WALL_T
	var h: float = COURT * 0.5
	await _place(&"cube", "WallNorth",
		Vector3(-h, 0.0, -h - t), Vector3(-1.7, 0.0, -h), WALL_H, "stone",
		Callable(), TILES)
	# the doorway is arched from inside its own parameter modal
	var door := await _place(&"door", "Archway",
		Vector3(-1.6, 0.0, -h - t), Vector3(1.6, 0.0, -h), WALL_H, "stone",
		func(): await d.overlay_param_check("arched", true, 12))
	await _place(&"cube", "WallNorth2",
		Vector3(1.7, 0.0, -h - t), Vector3(h, 0.0, -h), WALL_H, "stone",
		Callable(), TILES)
	d.check(door != null, "arched doorway placed in the north wall")
	await d.cam_swing(f["center"], 20.0, 34.0, 24.0, 20.0, f["dist"], 34, 1, f["aim"])

func _stairs() -> void:
	var f := _court_view(30.0, 22.0, 0.9, 8.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(6)
	var h: float = COURT * 0.5
	await _place(&"cube", "WallEast",
		Vector3(h, 0.0, -h), Vector3(h + WALL_T, 0.0, h), WALL_H, "stone",
		Callable(), TILES)
	var stairs := await _place(&"stair", "GrandStairs",
		Vector3(3.6, 0.0, 1.6), Vector3(5.6, 0.0, 5.2), 2.6, "stone",
		Callable(), TILES)
	await _place(&"cube", "Balcony",
		Vector3(3.0, 0.0, 4.6), Vector3(6.4, 0.0, 8.2), 2.6, "stone",
		Callable(), TILES)
	d.check(stairs != null, "grand stairs built")
	await d.cam_swing(f["center"], 30.0, 18.0, 22.0, 30.0, f["dist"], 34, 1, f["aim"])

func _pillars() -> void:
	var f := _court_view(46.0, 20.0, 0.9, 8.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(6)
	var a := await _place(&"cylinder", "PillarA", Vector3(-4.6, 0.0, 3.4), Vector3(-3.4, 0.0, 4.6),
		4.0, "stone")
	var b := await _place(&"cylinder", "PillarB", Vector3(4.0, 0.0, 3.4), Vector3(5.2, 0.0, 4.6),
		4.0, "stone")
	await _place(&"prism", "RampEast", Vector3(-6.0, 0.0, -2.0), Vector3(-3.2, 0.0, 1.0),
		1.4, "stone", Callable(), BRICK)
	d.check(a != null and b != null, "pillars raised")
	await d.cam_swing(f["center"], 46.0, 26.0, 20.0, 34.0, f["dist"], 36, 1, f["aim"])

func _paint() -> void:
	var f := _court_view(34.0, 32.0, 0.86, 6.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(6)
	# select the floor and paint the brick path down the middle of the court
	var floor_node: PBMesh = null
	for p in pieces:
		if p != null and String(p.name) == "CourtFloor":
			floor_node = p
	if floor_node == null:
		d.check(false, "courtyard floor is still in the scene")
		return
	d.plugin.editor.active_mesh = floor_node
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(floor_node)
	await d.frames(6)
	await d.click_button("materials", 14)
	await d.click_dock_member("_btn_mode_paint", 14)
	var pc = d.plugin.paint_controller
	pc.set_paint_texture_and_update_layer(load(BRICK))
	pc.brush_radius = 1.15
	pc.brush_softness = 0.75
	pc.brush_opacity = 1.0
	await d.frames(6)
	var path_pts := [Vector3(0.0, 0.5, 6.6), Vector3(0.0, 0.5, 2.0), Vector3(0.0, 0.5, -2.0),
		Vector3(0.0, 0.5, -6.0)]
	for i in range(path_pts.size() - 1):
		await d.drag(d.w2s(path_pts[i]), d.w2s(path_pts[i + 1]), 16)
	d.check(int(pc.mode) == 1, "brick path painted down the courtyard")
	# a decal on the floor by the doorway
	await d.click_dock_member("_btn_mode_stamp", 14)
	pc.stamp_texture = load(STAMP)
	pc.stamp_scale = 2.6
	pc.stamp_opacity = 1.0
	await d.glide_world_track(Vector3(0.0, 0.5, -3.2), 20)
	await d.frames(6)
	await d.click()
	await d.frames(10)
	await d.cam_swing(f["center"], 34.0, 16.0, 32.0, 42.0, f["dist"], 34, 1, f["aim"])

func _export() -> void:
	# time of day, then the retro export dialog
	var f := _court_view(38.0, 24.0, 0.9, 9.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(6)
	var opened := await d.open_export_dialog()
	var dlg = d.plugin._export_dialog
	if opened and dlg != null:
		# Retro mode + a destination inside the project, then Export.
		if dlg._mode_option != null:
			dlg._mode_option.selected = 0
		dlg._txt_path.text = "res://exports/showcase_map.glb"
		await d.frames(24)               # let the dialog be read before it is used
		await d.dialog_ok(dlg, 16)
		await d.frames(48)               # progress bar runs while the map bakes
	await d.cam_swing(f["center"], 38.0, 60.0, 24.0, 34.0, f["dist"], 40, 1, f["aim"])

## One click changes the whole time of day: the toolbar's Env menu swaps the
## environment AND the sun, so the composed courtyard turns into the night map
## the device renders in the next act.
func _night() -> void:
	var f := _court_view(38.0, 22.0, 0.92, 9.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(8)
	await d.env_preset("night")
	await d.frames(24)
	await d.cam_swing(f["center"], 38.0, 22.0, 22.0, 15.0, float(f["dist"]) * 0.86, 70, 1, f["aim"])
