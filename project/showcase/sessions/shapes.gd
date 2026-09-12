## ACT — the primitive library. Every shape the plugin can generate, laid out on
## one bench, then three hero orbits.
##
## The lineup is built before the beat (the interesting part is seeing them all
## at once), and the camera does the work: a long arc across the collection,
## then a close orbit of the shapes whose silhouette says the most.
@tool
extends RefCounted

var director: ShowcaseDirector
var d: ShowcaseDirector
var root: Node
var bench: PBMesh
var nodes: Array[PBMesh] = []

## id, palette colour, scale multiplier
const LINEUP := [
	[&"cube", "stone", 1.0],
	[&"prism", "slate", 1.0],
	[&"cylinder", "brick", 1.0],
	[&"cone", "steel", 1.0],
	[&"pipe", "slate", 1.0],
	[&"sphere", "moss", 1.0],
	[&"torus", "plum", 1.0],
	[&"stair", "brick", 0.85],
	[&"curved_stair", "stone", 0.85],
	[&"arch", "steel", 1.0],
	[&"door", "slate", 0.9],
]

func run(dr: ShowcaseDirector) -> void:
	d = dr
	# Tighter than the default framing: the video is watched at README
	# size, so subjects should sit large in the frame.
	d.fill_scale = 1.35
	root = EditorInterface.get_edited_scene_root()
	ShowcaseUtil.fresh_grid(d.plugin)
	ShowcaseUtil.env(d.plugin, "day")
	ShowcaseUtil.grade_light(root)
	bench = ShowcaseUtil.floor_slab(root, 60.0, ShowcaseUtil.mat(root, "ink"))
	await d.frames(16)
	await d.off(_build_lineup)
	await d.shot("shapes/lineup", _lineup)
	await d.shot("shapes/torus", _torus)
	await d.shot("shapes/stairs", _stairs)
	await d.shot("shapes/door", _door)
	d.snapshot_regions()

func _build_lineup() -> void:
	EditorInterface.get_selection().clear()
	# One row, walked by the camera: the shapes are small in a wide shot, so the
	# dolly (not the framing) is what gives each primitive its moment.
	var spacing := 3.6
	for i in range(LINEUP.size()):
		var entry: Array = LINEUP[i]
		var id: StringName = entry[0]
		var col: String = entry[1]
		var scale: float = entry[2]
		var data := PBShapeFactory.create_shape(id, Vector3(2.8, 2.8, 2.8) * scale)
		if data == null:
			continue
		var pos := Vector3((float(i) - float(LINEUP.size() - 1) * 0.5) * spacing, 0.0, 0.0)
		var node := ShowcaseUtil.mesh(root, "Gallery_" + String(id), data, pos,
			ShowcaseUtil.mat(root, col))
		ShowcaseUtil.drop_on_ground(node)
		nodes.append(node)

func _row_span() -> float:
	return float(LINEUP.size() - 1) * 3.6

func _lineup() -> void:
	var span := _row_span()
	# a truck move along the row: starts angled into the near end, ends looking
	# back down the line
	var a_eye := Vector3(-span * 0.5 - 9.0, 3.4, 9.0)
	var a_tgt := Vector3(-span * 0.5 + 3.0, 1.2, 0.0)
	var b_eye := Vector3(span * 0.5 + 7.0, 2.9, 7.5)
	var b_tgt := Vector3(span * 0.5 - 3.0, 1.2, 0.0)
	d.cam_look_at(a_eye, a_tgt)
	await d.frames(6)
	await d.cam_lerp(a_eye, a_tgt, b_eye, b_tgt, 318, 1)
	d.check(nodes.size() == LINEUP.size(),
		"gallery holds every primitive (%d of %d)" % [nodes.size(), LINEUP.size()])

## Shows only shape `index` (the others sit in the same row and would block the
## orbit — the hero shots are about one primitive at a time).
func _solo(index: int) -> void:
	for i in range(nodes.size()):
		nodes[i].visible = (i == index)

func _hero(index: int, fill := 0.5, az0 := 30.0, az1 := 96.0, elev := 20.0,
		elev1 := 12.0, n := 130, focus := Vector3.ZERO) -> void:
	if index >= nodes.size():
		d.check(false, "gallery has shape %d" % index)
		return
	await d.off(func(): _solo(index))
	var node := nodes[index]
	# Aim a little above the ground so the orbit stays level with the body.
	var box := d.node_aabb(node)
	box.position.y += focus.y
	var f := d.framing(box, fill, az0, elev)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(6)
	await d.cam_swing(f["center"], az0, az1, elev, elev1, f["dist"], n, 1, f["aim"])

func _torus() -> void:
	await _hero(6, 0.62, 26.0, 112.0, 32.0, 14.0, 140)
	d.check(nodes.size() == LINEUP.size(),
		"gallery holds every primitive (%d of %d)" % [nodes.size(), LINEUP.size()])

func _stairs() -> void:
	await _hero(8, 0.62, 44.0, -30.0, 22.0, 34.0, 140)

func _door() -> void:
	await _hero(10, 0.62, 34.0, -20.0, 18.0, 30.0, 140)
