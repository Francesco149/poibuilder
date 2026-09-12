## ACT — shape creation. The drag-to-create workflow end to end: base
## rectangles drawn on ANY surface (a floor, a vertical wall, a sloped face),
## the height drag along that surface's normal, the live-preview parameter
## modal, and re-editing a placed shape's parameters.
##
## The shapes are armed through the toolbar's New Shape menu (the popup opens
## and the item is picked with the pointer), so what the viewer sees is the real
## flow, not a function call. Everything the act builds wears the soft
## checkerboard, whose 1 m squares are what make the automatic UV management
## visible when a shape is resized or its parameters are edited.
@tool
extends RefCounted

var director: ShowcaseDirector
var d: ShowcaseDirector
var root: Node
var bench: PBMesh
var wall: PBMesh
var ramp: PBMesh
var made: PBMesh = null
var stairs: PBMesh = null

const BENCH_SIZE := 40.0
const SHELF_H := 4.0                    # the wall's height

func run(dr: ShowcaseDirector) -> void:
	d = dr
	# Tighter than the default framing: the video is watched at README
	# size, so subjects should sit large in the frame.
	d.fill_scale = 1.35
	root = EditorInterface.get_edited_scene_root()
	ShowcaseUtil.env(d.plugin, "day")
	ShowcaseUtil.grade_light(root)
	ShowcaseUtil.fresh_grid(d.plugin)
	# Created shapes arrive wearing the checkerboard (the plugin's "default
	# material for new shapes", set through the same setting the dock writes),
	# so even the live preview during the drag shows real UVs.
	ShowcaseUtil.use_default_material(ShowcaseUtil.CHECKER)
	bench = ShowcaseUtil.floor_slab(root, BENCH_SIZE, ShowcaseUtil.mat(root, "ink"))
	# The bench top is coplanar with the plugin grid: hide it or the two fight.
	await d.grid_show(false)
	await d.frames(20)

	await d.shot("create/surfaces", _surfaces)
	await d.shot("create/stairs", _stairs)
	await d.shot("create/params", _edit_params)
	await d.shot("create/door", _door)
	d.snapshot_regions()

# -----------------------------------------------------------------------------

## Removes every demo object, keeping the bench and the surfaces the beats draw
## on (the wall and the ramp are part of the set, not of the beat).
func _clear_shapes() -> void:
	# PARK, don't free. A shape built through the creation flow is still
	# referenced by the editor's gizmo and by the undo action that registered it,
	# and freeing it mid-session segfaults the editor (signal 11 with no usable
	# backtrace, at this exact handoff — the surfaces beat's last shape is both
	# the active mesh and the newest undo entry). Hiding it and sinking it 400 m
	# below the bench removes it from the picture and from every ray we cast at
	# the working area, which is all this act needs: unlike the map act, the
	# create act never exports the scene.
	d.plugin.editor.active_mesh = null
	EditorInterface.get_selection().clear()
	for c in root.get_children():
		if c is PBMesh and c != bench:
			c.visible = false
			c.position += Vector3(0.0, -400.0, 0.0)
			# Rename as well: a parked node that still answers to "Shape_" is
			# counted by the next beat's "what did I just create" diff.
			c.name = "Parked_" + String(c.name)
	wall = null
	ramp = null
	made = null
	stairs = null

## The set for the "drag on any surface" beat: level ground, a VERTICAL wall and
## a SLOPED face (the prism's roof), so the three drag planes are visibly
## different. Built off-camera before the act starts.
func _build_set() -> void:
	var mat := ShowcaseUtil.checker_mat(root, "slate")
	wall = ShowcaseUtil.mesh(root, "SetWall",
		PBShapeGenerators.create_box(Vector3(7.0, SHELF_H, 0.5)), Vector3(-1.6, SHELF_H * 0.5, -2.6), mat)
	ramp = ShowcaseUtil.mesh(root, "SetRamp",
		PBShapeGenerators.create_prism(Vector3(2.6, 1.6, 3.2)), Vector3(3.0, 0.8, 0.6),
		ShowcaseUtil.checker_mat(root, "steel"))

func _spot(ax := -3.0, az := -3.0, bx := 3.0, bz := 3.0, height := 4.0,
		azimuth := 36.0, elev := 30.0) -> Dictionary:
	"""Frames a working area on the bench (the region shapes are drawn into)."""
	var box := AABB(Vector3(ax, 0.0, az), Vector3(bx - ax, height, bz - az))
	return d.framing(box, 0.95, azimuth, elev)

func _created(prefix := "Shape_") -> Array:
	return ShowcaseUtil.names_of(root, prefix)

## Dresses a finished shape in the beat's own checker tint.
func _tint(node: PBMesh, color_name: String) -> void:
	if node != null:
		ShowcaseUtil.dress_material(node, ShowcaseUtil.checker_mat(root, color_name))

## Drags a base rectangle from `a` to `b` and drives the height stage to
## `height` along the surface normal. The height is READ BACK from the plugin
## (the stage is mouse-driven: see ShowcaseDirector.height_drag_to), so a beat
## cannot silently produce a flat slab — the failure that used to make the
## first shape of the film a zero-height plane.
func _drag_create(shape_id: StringName, a: Vector3, b: Vector3, height: float) -> void:
	await d.arm_shape(shape_id)
	await d.drag(d.w2s(a), d.w2s(b), 34)
	var got: float = await d.height_drag_to(height)
	# One grid step of slack: the height stage snaps, so a 3.0 m target can land
	# on 3.0 or 3.2 depending on which side the pointer stopped.
	d.check(absf(got - height) <= 0.21, "%s height drag reached %.2f m (%.2f)" % [
		String(shape_id), height, got])
	await d.click()

# -----------------------------------------------------------------------------
# beats
# -----------------------------------------------------------------------------

## "Drag on any surface": the floor first (with the height dragged well up so
## the box stands in the frame), then the same gesture on a VERTICAL wall, then
## on a sloped face — each one growing along that surface's own normal.
func _surfaces() -> void:
	await d.off(func():
		_clear_shapes()
		_build_set())
	var f := d.framing(AABB(Vector3(-3.4, 0.0, -3.4), Vector3(7.4, 4.4, 7.4)), 0.98, 34.0, 30.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(8)
	# 1. the floor: a 2.4 m square dragged out, then the height dragged up
	await d.glide_world_track(Vector3(-2.4, 0.0, 0.0), 16)
	await _drag_create(&"cube", Vector3(-2.6, 0.0, 0.4), Vector3(-0.2, 0.0, 2.8), 2.4)
	var shapes := _created()
	d.check(shapes.size() == 1, "floor drag created one shape (%d)" % shapes.size())
	if shapes.size() > 0:
		made = shapes[0]
		_tint(made, "steel")
		await d.frames(6)
	# 2. the vertical wall: the same drag on a face that points at the camera,
	#    so the box grows out of the wall along its normal
	var wall_pt := Vector3(-1.6, 1.4, -2.35)
	await d.frame_box_to(AABB(Vector3(-3.6, 0.0, -3.6), Vector3(7.0, 4.6, 5.0)), 24.0, 22.0, 0.86, 34)
	await d.glide_world_track(wall_pt, 16)
	await _drag_create(&"cube", wall_pt + Vector3(-0.9, -0.8, 0.0), wall_pt + Vector3(0.9, 0.8, 0.0), 1.4)
	var on_wall := _created()
	d.check(on_wall.size() == 2, "the wall drag created a second shape (%d)" % on_wall.size())
	var wall_shape: PBMesh = null
	for n in on_wall:
		if n != made:
			wall_shape = n
			_tint(n, "brick")
			await d.frames(8)
	# 3. the sloped face: the prism's incline, which the drag follows in its own
	#    plane and grows along its own normal
	# the ramp's +X slope, in its own plane (ridge down to the floor edge)
	var slope := Vector3(3.65, 0.8, 0.6)
	await d.frame_box_to(AABB(Vector3(-0.6, 0.0, -1.6), Vector3(5.6, 2.6, 3.6)), 30.0, 16.0, 0.82, 34)
	await d.glide_world_track(slope, 16)
	await _drag_create(&"cube", slope + Vector3(-0.44, 0.55, -0.7), slope + Vector3(0.44, -0.55, 0.7), 1.0)
	var all := _created()
	d.check(all.size() == 3, "the slope drag created a third shape (%d)" % all.size())
	var slope_shape: PBMesh = null
	for n in all:
		if n != made and n != wall_shape:
			slope_shape = n
			_tint(n, "moss")
	d.check(slope_shape != null, "the third shape sits ON the slope, not on the floor")
	await d.frames(8)
	await d.frames(8)

func _stairs() -> void:
	await d.off(func():
		_clear_shapes())
	# Framed a little wider than the others: this beat drags from the NEAR corner
	# to the FAR one (so the stairs climb away from the camera), and at the
	# tighter framing the far corner projected outside the viewport — the drag's
	# release never reached the plugin and the beat built nothing.
	var f := _spot(-2.8, -3.8, 2.8, 3.8, 3.6, 30.0, 26.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(6)
	# The stairs climb along their facing, which this drag puts toward +Z, and the
	# cameras below sit on the -Z side to look at the fronts of the treads (the
	# first version framed them from +Z, i.e. straight at the staircase's back).
	# Do NOT flip this drag to "climb away": pressing at the near corner and
	# releasing at the far one left the release outside the viewport, and the beat
	# then built nothing at all.
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
		_tint(made, "stone")
		stairs = made
		# A step's-eye view: the staircase is only readable as steps from the
		# side, low down, where each tread and riser stands proud of the next.
		var f2 := d.framing_node(made, 0.66, 206.0, 14.0)
		await d.cam_at_polar(f2["center"], f2["az"], f2["elev"], f2["dist"], f2["aim"])
		await d.cam_swing(f2["center"], 206.0, 230.0, 14.0, 26.0, float(f2["dist"]) * 0.94, 44, 1, f2["aim"])

func _door() -> void:
	await d.off(func():
		_clear_shapes())
	var f := _spot(-2.2, -3.0, 2.2, 3.0, 3.6, 26.0, 22.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(6)
	# Drag the footprint ALONG an axis: the doorway's facing is chosen across the
	# base rect's dominant side, and a world-aligned drag is what puts its front
	# (+Z) toward the camera instead of edge-on, where it reads as a cube.
	await _drag_create(&"door", Vector3(-1.8, 0.0, -1.7), Vector3(1.8, 0.0, -0.7), 3.0)
	await d.frames(8)
	d.check(d.plugin.tool_overlay.params_open, "parameter modal opened for the door")
	await d.overlay_param_check("arched", true)
	await d.frames(12)
	await d.overlay_button("ApplyParams", 14)
	var shapes := _created()
	d.check(shapes.size() == 1, "arched door created (%d)" % shapes.size())
	if shapes.size() > 0:
		made = shapes[0]
		_tint(made, "slate")
		var f2 := d.framing_node(made, 0.7, 16.0, 12.0)
		await d.cam_at_polar(f2["center"], f2["az"], f2["elev"], f2["dist"], f2["aim"])
		await d.cam_swing(f2["center"], 16.0, -18.0, 12.0, 20.0, float(f2["dist"]) * 0.96, 44, 1, f2["aim"])

## Re-editing a placed shape: the stairs' parameters are reopened and the step
## count doubled, watched from the low side angle where every new tread appears.
func _edit_params() -> void:
	if stairs == null:
		d.check(false, "the stairs from the previous beat are still in the scene")
		return
	await d.off(func():
		EditorInterface.get_selection().clear()
		EditorInterface.get_selection().add_node(stairs))
	var before: int = int(stairs.pb_mesh_data.shape_params.get("steps", 0))
	var f := d.framing_node(stairs, 0.66, 202.0, 13.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(6)
	await d.click_button("edit_params", 16)
	await d.frames(8)
	d.check(d.plugin.tool_overlay.params_open, "Edit Params re-opened the shape's parameters")
	# The modal previews live, so the steps arrive one batch at a time.
	await d.overlay_param("steps", 16, 20)
	await d.frames(16)
	await d.overlay_button("ApplyParams", 16)
	var after: int = int(stairs.pb_mesh_data.shape_params.get("steps", 0))
	d.check(after > before, "step count applied (%d -> %d steps)" % [before, after])
	await d.cam_swing(f["center"], 202.0, 178.0, 13.0, 24.0, float(f["dist"]) * 0.94, 40, 1, f["aim"])
