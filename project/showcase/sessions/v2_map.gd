## SESSION — "v2_map": a whole map, re-lit and exported, for showcase v2.
##
## The alpha demo map (AlphaDemoMapBuilder: the docs' end-to-end map) is the
## set: walls, an arched door, stairs to a roof, a splatted floor with decals,
## a scrolling-texture waterfall with mist, brazier flames, billboard trees.
## Everything in it is ordinary PoiBuilder content, live in the editor.
##
##   v2m/fly      a slow flight from the plaza to the waterfall and the door
##   v2m/env      the toolbar's Env menu: dusk, then night — one click each
##   v2m/export   Export: the retro .pbm the PSP runs
##
## Toolbar visible (the Env menu and Export live there): "viewport_ui".
##
## Render: PB_SHOWCASE_LAYOUT=showcase_video/layouts/tour.cfg \
##         ./showcase_video/render.sh v2_map
@tool
extends RefCounted

var d: ShowcaseDirector
var root: Node

func run(dr: ShowcaseDirector) -> void:
	d = dr
	root = EditorInterface.get_edited_scene_root()
	ShowcaseUtil.fresh_grid(d.plugin)
	_build_map()
	ShowcaseUtil.env(d.plugin, "day")
	# The demo map's pale stone and tiles read white at the film's usual grade.
	ShowcaseUtil.grade_light(root, 0.78, 0.30)
	await d.grid_show(false)
	d.plugin.material_dock.set_thumbnail_size(64)
	if d.plugin.mode_banner != null:
		d.plugin.mode_banner.modulate.a = 0.0
	d.plugin.animate_scrolling_textures = true
	d.plugin.call("scan_scrolling_materials")
	await d.frames(30)
	d.snapshot_regions()
	await d.lift_panel(80.0)
	d.cam_look_at(Vector3(9.0, 7.5, 13.0), Vector3(-1.0, 0.8, -1.0))
	await d.frames(20)
	for s in [["v2m/fly", _fly], ["v2m/env", _env], ["v2m/export", _export]]:
		if d.only_done():
			break
		await d.shot(s[0], s[1])
	if d.plugin.mode_banner != null:
		d.plugin.mode_banner.modulate.a = 1.0

## The demo map's content moves into the edited scene (its own environment
## nodes stay behind: the scene already has a sky and a sun the presets drive).
func _build_map() -> void:
	var map := AlphaDemoMapBuilder.build_demo_scene(false, "day")
	for c in map.get_children():
		if c is WorldEnvironment or c is DirectionalLight3D:
			continue
		map.remove_child(c)
		root.add_child(c)
		_own(c)
	map.free()

func _own(n: Node) -> void:
	n.owner = root
	for c in n.get_children():
		_own(c)

# -----------------------------------------------------------------------------

## A camera flight: high over the plaza, down past the trees, along the
## waterfall's foot, round to the arched door.
func _fly() -> void:
	var keys := [
		[Vector3(9.0, 7.5, 13.0), Vector3(-1.0, 0.8, -1.0)],
		[Vector3(1.0, 4.2, 6.5), Vector3(-6.0, 1.8, -1.0)],
		[Vector3(-2.6, 2.4, 2.8), Vector3(-7.2, 2.2, -1.2)],
		[Vector3(-1.0, 2.6, 1.0), Vector3(-2.0, 1.6, -6.8)],
		[Vector3(4.5, 5.0, 4.0), Vector3(-1.6, 1.4, -5.5)],
	]
	var n_each := [150, 150, 140, 150]
	for i in range(keys.size() - 1):
		await d.cam_lerp(keys[i][0], keys[i][1], keys[i + 1][0], keys[i + 1][1], n_each[i], 1)
	d.check(d.plugin.animate_scrolling_textures, "scrolling textures animate in the viewport")

## One click per preset: the sky, the sun and the ambient change together.
func _env() -> void:
	var a := [Vector3(10.0, 7.0, 11.0), Vector3(-1.5, 1.0, -2.5)]
	await d.cam_lerp(d.cam.global_position, d.cam.global_position - d.cam.global_transform.basis.z * 8.0,
		a[0], a[1], 60, 1)
	await d.frames(30)
	await d.env_preset("dusk", 24)
	d.check(d._env_is("dusk"), "Env menu: dusk")
	await d.frames(70)
	await d.env_preset("night", 24)
	d.check(d._env_is("night"), "Env menu: night")
	await d.cam_lerp(a[0], a[1], Vector3(7.0, 4.0, 9.0), Vector3(-3.0, 1.4, -2.0), 150, 1)

## The Export dialog: the retro map format, one click.
func _export() -> void:
	var opened := await d.open_export_dialog()
	d.check(opened, "the export dialog opened")
	var dlg = d.plugin._export_dialog
	if opened and dlg != null:
		if dlg._mode_option != null:
			dlg._mode_option.selected = 0
			dlg._on_mode_selected(0)
		dlg._txt_path.text = "res://exports/showcase_v2_demo.pbm"
		await d.frames(60)
		await d.dialog_ok(dlg, 10)
		d.check(dlg._is_exporting, "Export started (the progress bar runs)")
		# On camera: the progress bar working through the map.
		await d.frames(150)
	# Off camera: let the export finish, then prove the file exists.
	await d.off(func():
		for i in range(3600):
			if dlg == null or not dlg._is_exporting:
				break
			await d.get_tree().process_frame)
	d.check(FileAccess.file_exists("res://exports/showcase_v2_demo.pbm"), "the .pbm was written")
	if dlg != null and dlg.visible:
		dlg.hide()
	await d.frames(20)
