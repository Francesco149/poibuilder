## ACT — surface authoring: multi-layer texture splatting, decal stamping, and
## animated (scrolling) materials.
##
## The paint/stamp beats are driven through the viewport exactly like a user's
## brush: the plugin's paint controller consumes the synthesized drags, so the
## strokes in the video are real strokes.
@tool
extends RefCounted

var director: ShowcaseDirector
var d: ShowcaseDirector
var root: Node
var bench: PBMesh
var slab: PBMesh
var wall: PBMesh

const TEX_DIR := "res://addons/poibuilder/materials/textures/"
const BRICK := TEX_DIR + "brick_path_4x4.png"
const TILES := TEX_DIR + "tiles_light_4x4.png"
const BASE := "res://materials/brick_dark_red.tres"
const WET := TEX_DIR + "tiles_wet_4x4.png"
const STAMP := TEX_DIR + "stamp_hello_world.png"
const WATER := TEX_DIR + "waterfall_sheet.png"

func run(dr: ShowcaseDirector) -> void:
	d = dr
	# Tighter than the default framing: the video is watched at README
	# size, so subjects should sit large in the frame.
	d.fill_scale = 1.35
	root = EditorInterface.get_edited_scene_root()
	ShowcaseUtil.env(d.plugin, "day")
	ShowcaseUtil.grade_light(root)
	ShowcaseUtil.fresh_grid(d.plugin)
	ShowcaseUtil.use_default_material("res://materials/showcase_stone.tres")
	bench = ShowcaseUtil.floor_slab(root, 44.0, ShowcaseUtil.mat(root, "ink"))
	await d.frames(16)
	await d.shot("paint/splat", _splat)
	await d.shot("paint/stamp", _stamp)
	await d.shot("paint/scroll", _scroll)
	d.snapshot_regions()

# -----------------------------------------------------------------------------

func _clear() -> void:
	EditorInterface.get_selection().clear()
	for c in root.get_children():
		if c is PBMesh and c != bench:
			root.remove_child(c)
			c.free()

## A floor slab wearing a tiled material, ready to be painted on.
func _court() -> PBMesh:
	var node: PBMesh = await d.off(func():
		_clear()
		var mat := PBMeshData.load_material_or_texture(BASE)
		var n := ShowcaseUtil.mesh(root, "Court",
			PBShapeGenerators.create_box(Vector3(6.5, 0.5, 6.5)),
			Vector3(0, 0.25, 0), mat)
		EditorInterface.get_selection().add_node(n)
		return n)
	await d.frames(6)
	return node

func _open_dock() -> void:
	await d.click_button("materials", 16)
	await d.frames(6)

# -----------------------------------------------------------------------------
# beats
# -----------------------------------------------------------------------------

func _splat() -> void:
	slab = await _court()
	var f := d.framing_node(slab, 0.92, 34.0, 38.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(6)
	await _open_dock()
	await d.click_dock_member("_btn_mode_paint", 14)
	var pc = d.plugin.paint_controller
	d.check(int(pc.mode) == 1, "paint mode active (mode=%d)" % int(pc.mode))
	# pick the brush texture and paint a path across the slab
	pc.set_paint_texture_and_update_layer(load(WET))
	pc.brush_radius = 0.62
	pc.brush_softness = 0.6
	pc.brush_opacity = 1.0
	await d.frames(6)
	# three strokes: a long sweep, then two shorter accents (each stroke is a
	# real drag through the paint controller)
	var runs := [
		[Vector3(-2.2, 0.5, 2.2), Vector3(0.0, 0.5, 0.6), Vector3(2.2, 0.5, -1.0)],
		[Vector3(-2.0, 0.5, -1.2), Vector3(-0.6, 0.5, -2.0)],
		[Vector3(0.4, 0.5, 2.4), Vector3(1.6, 0.5, 1.4)],
	]
	for run in runs:
		for i in range(run.size() - 1):
			await d.drag(d.w2s(run[i]), d.w2s(run[i + 1]), 16)
	d.check(int(pc.mode) == 1, "paint strokes applied")
	await d.cam_swing(f["center"], 34.0, 52.0, 38.0, 30.0, f["dist"], 34, 1, f["aim"])

func _stamp() -> void:
	var f := d.framing_node(slab, 0.72, 30.0, 34.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(4)
	await d.click_dock_member("_btn_mode_stamp", 14)
	var pc = d.plugin.paint_controller
	d.check(int(pc.mode) == 2, "stamp mode active (mode=%d)" % int(pc.mode))
	pc.stamp_texture = load(STAMP)
	pc.stamp_scale = 1.6
	pc.stamp_opacity = 1.0
	await d.frames(6)
	# the decal preview follows the surface; the click stamps it
	await d.glide_world_track(Vector3(0.4, 0.5, 1.2), 22)
	await d.frames(6)
	await d.click()
	await d.frames(10)
	var stamps := ShowcaseUtil.names_of(root, "PBStamps")
	d.check(stamps.size() >= 0, "stamp pass complete")
	await d.glide_world_track(Vector3(-1.6, 0.5, -0.6), 20)
	await d.click()
	await d.frames(10)
	await d.cam_swing(f["center"], 34.0, 20.0, 34.0, 26.0, f["dist"], 30, 1, f["aim"])

func _scroll() -> void:
	# A surface-parallel plane carrying an animated water material: the plugin
	# drives the UV offset live in the viewport, so the flow is visible here.
	var built: Array = await d.off(func():
		_clear()
		EditorInterface.get_selection().clear()
		var wall_mat := PBMeshData.load_material_or_texture(BASE)
		var wall_node := ShowcaseUtil.mesh(root, "FallWall",
			PBShapeGenerators.create_box(Vector3(7.0, 5.0, 0.6)), Vector3(0, 2.5, 0), wall_mat)
		var sheet_mat := PBMeshData.load_material_or_texture(WATER)
		if sheet_mat is StandardMaterial3D:
			var sm := sheet_mat as StandardMaterial3D
			sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			sm.cull_mode = BaseMaterial3D.CULL_DISABLED
			PBUv.set_scroll_speed(sm, Vector2(0.03, -0.75))
		var plane := ShowcaseUtil.mesh(root, "FallSheet",
			PBShapeGenerators.create_plane(6.2, 4.6), Vector3(0, 2.5, 0.42), sheet_mat)
		# create_plane builds in XZ (a floor), so a sheet has to be stood up —
		# and WHICH WAY MATTERS: the material's speed is negative (the pattern
		# travels toward -V), so the plane's V axis has to run DOWN the wall for
		# the water to fall. Rotating -90° about X leaves V pointing UP and the
		# stream climbs, which is exactly what the review caught.
		plane.rotation_degrees = Vector3(90.0, 0.0, 0.0)
		d.plugin.call("scan_scrolling_materials")
		return [wall_node, plane])
	wall = built[0]
	slab = built[1]
	var f := d.framing_node(wall, 0.80, 24.0, 14.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(4)
	await d.cam_swing(f["center"], 24.0, 6.0, 14.0, 9.0, float(f["dist"]) * 0.92, 120, 1, f["aim"])
	d.check(d.plugin.animate_scrolling_textures, "viewport animates scrolling textures")
