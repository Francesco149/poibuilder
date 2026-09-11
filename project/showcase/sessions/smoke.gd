## Smoke session: validates the capture loop end to end (frame stepping, real
## toolbar clicks, real viewport picking, gizmo-protocol element drags, grid
## snapping) before any showcase content is authored on top of it.
##
## Session scripts MUST be @tool: the editor only instantiates tool scripts
## (GDScript.can_instantiate() is false for a plain script under
## Engine.is_editor_hint()), and the recorder runs inside the editor.
@tool
extends RefCounted

var director: ShowcaseDirector

func run(d: ShowcaseDirector) -> void:
	var root: Node = EditorInterface.get_edited_scene_root()

	var bench := PBMesh.new()
	bench.name = "Bench"
	bench.pb_mesh_data = PBShapeGenerators.create_plane(20.0, 20.0)
	root.add_child(bench)
	bench.owner = root

	var box := PBMesh.create_cube(2.0)
	box.name = "SmokeBox"
	box.position = Vector3(0, 1.0, 0)
	root.add_child(box)
	box.owner = root
	await d.frames(30)

	var sel := EditorInterface.get_selection()
	sel.clear()
	sel.add_node(box)
	await d.frames(30)

	await d.shot("smoke/orbit", _orbit.bind(d, box))
	await d.shot("smoke/create", _create.bind(d))
	await d.shot("smoke/extrude", _extrude.bind(d, box))
	await d.shot("smoke/inset", _inset.bind(d, box))
	d.snapshot_regions()

func _orbit(d: ShowcaseDirector, box: PBMesh) -> void:
	await d.cam_snap(Vector3(4.5, 3.2, 5.5), Vector3(0, 1.2, 0))
	await d.glide(d.w2s(Vector3(0, 2.2, 1.0)), 24)
	await d.cam_orbit(Vector3(0, 1.0, 0), 40.0, -55.0, 7.5, 2.8, 80)
	d.check(true, "orbit ran")

func _create(d: ShowcaseDirector) -> void:
	await d.cam_snap(Vector3(-4.5, 4.0, 6.0), Vector3(-1.5, 0.5, 0.5))
	await d.arm_shape(&"cube")
	var start := d.w2s(Vector3(-3.0, 0.0, -0.4))
	var end := d.w2s(Vector3(-1.2, 0.0, 1.6))
	await d.drag(start, end, 30)
	var lift := d.w2s(Vector3(-1.2, 1.2, 1.6))
	await d.glide(lift, 20)
	await d.click()
	await d.frames(10)
	var created: Array = []
	for c in EditorInterface.get_edited_scene_root().get_children():
		if c is PBMesh and String(c.name).begins_with("Shape_"):
			created.append(c)
	d.check(created.size() == 1, "drag-create produced one shape (%d)" % created.size())

func _extrude(d: ShowcaseDirector, box: PBMesh) -> void:
	var sel := EditorInterface.get_selection()
	sel.clear()
	sel.add_node(box)
	await d.frames(10)
	await d.cam_snap(Vector3(4.5, 3.2, 5.5), Vector3(0, 1.2, 0))
	await d.select_mode("face")
	await d.pick_world(Vector3(0, 2.0, 0))
	await d.frames(8)
	d.check(d.has_element_selection(), "top face selected by click")
	var before: int = box.pb_mesh_data.faces.size()
	await d.move_selection(Vector3(0, 1.2, 0), 40, true)
	d.check(box.pb_mesh_data.faces.size() > before, "shift+move extruded (%d -> %d faces)"
		% [before, box.pb_mesh_data.faces.size()])

func _inset(d: ShowcaseDirector, box: PBMesh) -> void:
	await d.cam_snap(Vector3(3.6, 4.2, 4.6), Vector3(0, 2.2, 0))
	await d.tool("scale")
	await d.pick_world(Vector3(0, 3.2, 0))
	await d.frames(8)
	d.check(d.has_element_selection(), "cap re-selected for inset")
	var before: int = box.pb_mesh_data.faces.size()
	await d.scale_selection_factor(0.45, 40, true)
	d.check(box.pb_mesh_data.faces.size() > before, "shift+center inset (%d -> %d faces)"
		% [before, box.pb_mesh_data.faces.size()])
