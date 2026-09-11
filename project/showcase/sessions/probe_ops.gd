## Focused probe: reproduce the edit session's subdivide beat twice in a row —
## a fresh object each time, created and freed exactly as the beats do.
@tool
extends RefCounted

var director: ShowcaseDirector
var d: ShowcaseDirector
var root: Node
var bench: PBMesh

func run(dr: ShowcaseDirector) -> void:
	d = dr
	root = EditorInterface.get_edited_scene_root()
	bench = ShowcaseUtil.floor_slab(root, 30.0, ShowcaseUtil.mat(root, "ink"))
	await d.frames(10)
	await _beat("first")
	await _beat("second")
	await _beat("third")

func _clear() -> void:
	EditorInterface.get_selection().clear()
	for c in root.get_children():
		if c is PBMesh and c != bench:
			root.remove_child(c)
			c.free()

func _beat(tag: String) -> void:
	var node: PBMesh = await d.off(func():
		_clear()
		var n := ShowcaseUtil.mesh(root, "DemoSlab",
			PBShapeGenerators.create_box(Vector3(4.0, 0.6, 4.0)), Vector3.ZERO,
			ShowcaseUtil.mat(root, "steel"))
		ShowcaseUtil.drop_on_ground(n)
		EditorInterface.get_selection().add_node(n)
		var f := d.framing_node(n, 0.52, 26.0, 34.0)
		d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
		return n)
	await d.frames(8)
	await d.clear_element_selection()
	print("[probe:%s] ids after clear = %s" % [tag, str(d.plugin.editor.selection.selected_faces)])
	await d.click_button("face", 8)
	await d.glide_world_track(Vector3(0.0, 0.58, 0.0), 16)
	await d.click()
	var active = d.active_mesh()
	print("[probe:%s] ids = %s" % [tag, str(d.plugin.editor.selection.selected_faces)])
	print("[probe:%s] obj_id=%d active_id=%d same=%s faces=%d sel=%d" % [tag,
		node.get_instance_id(), active.get_instance_id() if active != null else -1,
		str(node == active), node.pb_mesh_data.faces.size(),
		d.plugin.editor.selection.selected_faces.size()])
	var btn: Button = d.toolbar_button("subdivide_faces")
	btn.pressed.connect(func():
		var act = d.active_mesh()
		var sel = d.plugin.editor.selection
		print("[probe:%s] AT PRESS: sel_ids=%s sel_mesh_same=%s active=%s active_faces=%d" % [tag,
			str(sel.selected_faces),
			str(sel.mesh_data == act.pb_mesh_data),
			String(act.name) if act != null else "<none>",
			act.pb_mesh_data.faces.size() if act != null else -1]))
	await d.op("subdivide_faces", 14)
	print("[probe:%s] op() result faces=%d" % [tag, node.pb_mesh_data.faces.size()])
	print("[probe:%s] after op faces=%d (active=%s)" % [tag,
		node.pb_mesh_data.faces.size(),
		String(active.name) if active != null else "<none>"])
	await d.frames(6)
