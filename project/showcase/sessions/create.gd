## ACT — shape creation. The drag-to-create workflow end to end: grid-snapped
## base rectangles, the height drag along the surface normal, the live-preview
## parameter modal, and re-editing a placed shape's parameters.
##
## Shapes are armed through the toolbar's New Shape menu (the popup opens and
## the item is picked with the pointer), so what the viewer sees is the real
## flow, not a function call.
@tool
extends RefCounted

var director: ShowcaseDirector
var d: ShowcaseDirector
var root: Node
var bench: PBMesh
var made: PBMesh = null

const BENCH_SIZE := 40.0

func run(dr: ShowcaseDirector) -> void:
	d = dr
	# Tighter than the default framing: the video is watched at README
	# size, so subjects should sit large in the frame.
	d.fill_scale = 1.35
	root = EditorInterface.get_edited_scene_root()
	ShowcaseUtil.env(d.plugin, "day")
	ShowcaseUtil.grade_light(root)
	ShowcaseUtil.use_default_material("res://materials/showcase_stone.tres")
	bench = ShowcaseUtil.floor_slab(root, BENCH_SIZE, ShowcaseUtil.mat(root, "ink"))
	await d.frames(20)

	await d.shot("create/grid", _grid_cube)
	await d.shot("create/stairs", _stairs)
	await d.shot("create/door", _door)
	await d.shot("create/round", _sphere)
	await d.shot("create/params", _edit_params)
	d.snapshot_regions()

# -----------------------------------------------------------------------------

func _clear_shapes() -> void:
	EditorInterface.get_selection().clear()
	for c in root.get_children():
		if c is PBMesh and c != bench:
			root.remove_child(c)
			c.free()
	made = null

func _spot(ax := -3.0, az := -3.0, bx := 3.0, bz := 3.0, height := 4.0,
		azimuth := 36.0, elev := 30.0) -> Dictionary:
	"""Frames a working area on the bench (the region shapes are drawn into)."""
	var box := AABB(Vector3(ax, 0.0, az), Vector3(bx - ax, height, bz - az))
	return d.framing(box, 0.95, azimuth, elev)

func _created(prefix := "Shape_") -> Array:
	return ShowcaseUtil.names_of(root, prefix)

## Drags a base rectangle on the bench top and sets a height.
func _drag_create(shape_id: StringName, a: Vector3, b: Vector3, height: float,
		gap_a := 12, gap_b := 14, gap_h := 18) -> void:
	await d.arm_shape(shape_id)
	await d.drag(d.w2s(a), d.w2s(b), 34)
	await d.glide_world_track(Vector3(b.x, height, b.z), 26)
	await d.click()


# -----------------------------------------------------------------------------
# beats
# -----------------------------------------------------------------------------

func _grid_cube() -> void:
	await d.off(func(): _clear_shapes())
	var f := _spot(-2.4, -2.4, 2.4, 2.4, 3.0, 38.0, 30.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(6)
	# the pointer sweeps the grid first: snapping is visible before the drag
	await d.glide_world_track(Vector3(-1.6, 0.0, -1.6), 18)
	await d.arm_shape(&"cube")
	await d.drag(d.w2s(Vector3(-1.6, 0.0, -1.6)), d.w2s(Vector3(1.6, 0.0, 1.6)), 34)
	await d.glide_world_track(Vector3(1.6, 2.4, 1.6), 26)
	await d.click()
	var shapes := _created()
	d.check(shapes.size() == 1, "grid drag created one shape (%d)" % shapes.size())
	if shapes.size() > 0:
		made = shapes[0]
		var f2 := d.framing_node(made, 0.46, 38.0, 26.0)
		await d.cam_swing(f2["center"], 38.0, 58.0, 26.0, 20.0, f2["dist"], 40, 1, f2["aim"])

func _stairs() -> void:
	await d.off(func(): _clear_shapes())
	var f := _spot(-2.0, -3.0, 2.0, 3.0, 3.6, 30.0, 26.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(6)
	await _drag_create(&"stair", Vector3(-1.6, 0.0, -2.4), Vector3(1.6, 0.0, 2.4), 3.0)
	await d.frames(8)
	d.check(d.plugin.tool_overlay.params_open, "parameter modal opened for the stairs")
	# the modal previews live: change the step count, then apply
	await d.overlay_param("steps", 10)
	await d.frames(10)
	await d.overlay_button("ApplyParams", 14)
	var shapes := _created()
	d.check(shapes.size() == 1, "stairs created (%d)" % shapes.size())
	if shapes.size() > 0:
		made = shapes[0]
		var f2 := d.framing_node(made, 0.46, 34.0, 22.0)
		await d.cam_swing(f2["center"], 34.0, 22.0, 22.0, 30.0, f2["dist"], 44, 1, f2["aim"])

func _door() -> void:
	await d.off(func(): _clear_shapes())
	var f := _spot(-2.2, -3.0, 2.2, 3.0, 3.6, 26.0, 22.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(6)
	await _drag_create(&"door", Vector3(-1.8, 0.0, -2.6), Vector3(1.8, 0.0, 0.4), 3.0)
	await d.frames(8)
	d.check(d.plugin.tool_overlay.params_open, "parameter modal opened for the door")
	await d.overlay_param_check("arched", true)
	await d.frames(12)
	await d.overlay_button("ApplyParams", 14)
	var shapes := _created()
	d.check(shapes.size() == 1, "arched door created (%d)" % shapes.size())
	if shapes.size() > 0:
		made = shapes[0]
		var f2 := d.framing_node(made, 0.46, 30.0, 18.0)
		await d.cam_swing(f2["center"], 30.0, 16.0, 18.0, 24.0, f2["dist"], 44, 1, f2["aim"])

func _sphere() -> void:
	await d.off(func(): _clear_shapes())
	var f := _spot(-2.0, -2.0, 2.0, 2.0, 3.0, 40.0, 26.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(6)
	# round shapes resize RELATIVELY during the height drag: the pointer grows
	# the radius instead of stacking a third dimension
	await d.arm_shape(&"sphere")
	await d.drag(d.w2s(Vector3(-1.1, 0.0, -1.1)), d.w2s(Vector3(1.1, 0.0, 1.1)), 32)
	await d.glide_world_track(Vector3(1.1, 1.6, 1.1), 30)
	await d.click()
	await d.frames(8)
	if d.plugin.tool_overlay.params_open:
		await d.overlay_button("ApplyParams", 14)
	var shapes := _created()
	d.check(shapes.size() == 1, "sphere created (%d)" % shapes.size())
	if shapes.size() > 0:
		made = shapes[0]
		var f2 := d.framing_node(made, 0.46, 40.0, 20.0)
		await d.cam_swing(f2["center"], 40.0, 64.0, 20.0, 14.0, f2["dist"], 46, 1, f2["aim"])

func _edit_params() -> void:
	# A pristine shape can be re-opened and its parameters changed after the
	# fact: the same modal, seeded with the shape's stored values.
	await d.off(func():
		_select_only(made))
	var f := d.framing_node(made, 0.46, 44.0, 24.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(6)
	await d.click_button("edit_params", 16)
	await d.frames(8)
	d.check(d.plugin.tool_overlay.params_open, "Edit Params re-opened the shape's parameters")
	await d.overlay_param("radius", 1.4)
	await d.frames(14)
	await d.overlay_button("ApplyParams", 16)
	var s := made.pb_mesh_data.shape_params
	d.check(absf(float(s.get("radius", 0.0)) - 1.4) < 0.35,
		"radius parameter applied (%.2f)" % float(s.get("radius", 0.0)))
	await d.cam_swing(f["center"], 44.0, 24.0, 24.0, 30.0, f["dist"], 40, 1, f["aim"])

func _select_only(node: Node) -> void:
	if node == null:
		return
	var sel := EditorInterface.get_selection()
	sel.clear()
	sel.add_node(node)
