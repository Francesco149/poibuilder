## Editor GUI test harness — REPRODUCTION testing for viewport interactions.
##
## Open this scene in a REAL (non-headless) editor session:
##   xvfb-run godot-mono --editor --rendering-driver opengl3 \
##       res://test_scenes/editor_gui_test.tscn
## The script synthesizes genuine mouse events through the input pipeline
## (Input.parse_input_event) and asserts the OBSERVABLE outcomes:
##
## 1. SELECT: with mesh A active in face mode, clicking mesh B (another
##    PBMesh) must make B the editor selection (the round-3 regression).
## 2. CREATE: arming a cube via the plugin and drag-releasing on a surface
##    must produce a preview that finalizes into a Shape_Cube node.
##
## Prints "[GUI TEST] ... PASS/FAIL" lines and quits with the failure count
## as the exit code.
@tool
extends Node3D

var _failures: int = 0

func _ready() -> void:
	if Engine.is_editor_hint():
		_run.call_deferred()

func _fail(msg: String) -> void:
	_failures += 1
	printerr("[GUI TEST] FAIL: " + msg)

func _pass(msg: String) -> void:
	print("[GUI TEST] PASS: " + msg)

func _frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame

func _find_plugin(node: Node) -> Node:
	if node.get_script() != null and str(node.get_script().resource_path).ends_with("probuilder_plugin.gd"):
		return node
	for child in node.get_children():
		var found := _find_plugin(child)
		if found != null:
			return found
	return null

func _window_pos(vp: SubViewport, host: Control, world: Vector3) -> Vector2:
	var local: Vector2 = vp.get_camera_3d().unproject_position(world)
	var sx: float = host.size.x / float(vp.size.x)
	var sy: float = host.size.y / float(vp.size.y)
	return host.global_position + Vector2(local.x * sx, local.y * sy)

func _mouse_motion(pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	Input.parse_input_event(ev)

func _mouse_button(pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	Input.parse_input_event(ev)

func _click(pos: Vector2) -> void:
	_mouse_motion(pos)
	await _frames(2)
	_mouse_button(pos, true)
	await _frames(2)
	_mouse_button(pos, false)
	await _frames(2)

func _run() -> void:
	await _frames(30)
	var iface := EditorInterface
	var vp: SubViewport = iface.get_editor_viewport_3d(0)
	if vp == null:
		_fail("no 3D viewport")
		get_tree().quit(1)
		return
	var host := vp.get_parent().get_parent() as Control
	if host == null:
		_fail("unexpected viewport layout")
		get_tree().quit(1)
		return
	var root := iface.get_edited_scene_root()
	if root == null:
		_fail("no edited scene root")
		get_tree().quit(1)
		return

	# ── Setup: two cubes, camera framing both ────────────────────────────────
	var a := PBMesh.create_cube(1.0)
	a.name = "GuiTestA"
	a.position = Vector3.ZERO
	root.add_child(a)
	a.owner = root
	var b := PBMesh.create_cube(1.0)
	b.name = "GuiTestB"
	b.position = Vector3(3, 0, 0)
	root.add_child(b)
	b.owner = root

	var cam := vp.get_camera_3d()
	if cam == null:
		_fail("no viewport camera")
		get_tree().quit(1)
		return
	cam.global_transform = Transform3D(Basis.IDENTITY, Vector3(1.5, 2.5, 4.0)) \
		.looking_at(Vector3(1.5, 0, 0), Vector3.UP)
	await _frames(10)

	# Initial state: A selected, FACE mode (via the plugin's K hotkey).
	var sel := iface.get_selection()
	sel.clear()
	sel.add_node(a)
	await _frames(10)
	_press_key(KEY_K)
	await _frames(10)

	# ── Test 1: click B while A is active ────────────────────────────────────
	var b_click := _window_pos(vp, host, b.global_position + Vector3(0, 0, 0.5))
	await _click(b_click)
	await _frames(20)

	var selected: Array[Node] = sel.get_selected_nodes()
	if selected.size() == 1 and selected[0] == b:
		_pass("SELECT: clicking GuiTestB made it the editor selection")
	else:
		var names: Array = []
		for n in selected:
			names.append(n.name)
		_fail("SELECT: expected [GuiTestB], got %s" % str(names))

	# ── Test 2: drag-create a cube on A's top face ───────────────────────────
	# EditorPlugin nodes live under the EditorNode — the base control's parent.
	var plugin := _find_plugin(iface.get_base_control().get_parent())
	if plugin == null:
		plugin = _find_plugin(iface.get_base_control())
	if plugin == null:
		_fail("PoiBuilder plugin node not found")
	else:
		plugin._on_shape_requested(&"cube")
		await _frames(10)
		if not plugin.shape_creator.is_active():
			_fail("CREATE: creator not armed after shape request")
		else:
			var start := _window_pos(vp, host, Vector3(-1, 0.5001, 1.2))
			var end := _window_pos(vp, host, Vector3(1.2, 0.5001, -1))
			_mouse_motion(start)
			await _frames(3)
			_mouse_button(start, true)
			await _frames(3)
			for i in range(1, 5):
				_mouse_motion(start.lerp(end, float(i) / 4.0))
				await _frames(2)
			await _frames(3)

			# BASE phase invariants: the preview node exists, stays VISIBLE
			# (an invisible Node3D loses its gizmo — the round-3 outline bug)
			# and carries NO rendered mesh (outline only).
			if plugin.shape_creator.preview_node != null:
				if not plugin.shape_creator.preview_node.visible:
					_fail("CREATE: preview node invisible during BASE (gizmo would not draw)")
				elif plugin.shape_creator.preview_node.mesh != null:
					_fail("CREATE: preview renders a solid mesh during BASE (outline-only expected)")
				else:
					_pass("CREATE: BASE phase is outline-only (visible node, no mesh)")

			_mouse_button(end, false)
			await _frames(5)

			if plugin.shape_creator.state != PBShapeCreator.State.HEIGHT:
				_fail("CREATE: expected HEIGHT state after base drag, got %d"
					% plugin.shape_creator.state)
			elif plugin.shape_creator.preview_node == null:
				_fail("CREATE: no preview node after base drag")
			else:
				_pass("CREATE: base drag produced a HEIGHT-state preview")
			# Height: move (this also triggers the first HEIGHT refresh — the
			# solid preview mesh appears here), then confirm with a click.
			var top := _window_pos(vp, host, Vector3(0, 2.5, 0))
			_mouse_motion(top)
			await _frames(5)
			if plugin.shape_creator.preview_node != null \
					and plugin.shape_creator.preview_node.mesh == null:
				_fail("CREATE: preview has no mesh at the height stage")
			await _click(top)
			await _frames(20)

			var created := root.get_node_or_null(NodePath("Shape_Cube"))
			if created != null:
				_pass("CREATE: Shape_Cube node exists after confirm")
			else:
				_fail("CREATE: no Shape_Cube node after confirm")

			if plugin.shape_creator.is_active():
				_fail("CREATE: creator still active after confirm")
				plugin._creation_abort("test cleanup")

	# ── Cleanup + exit ───────────────────────────────────────────────────────
	sel.clear()
	await _frames(3)
	print("[GUI TEST] done, failures=%d" % _failures)
	get_tree().quit(_failures)

func _press_key(keycode: Key) -> void:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.physical_keycode = keycode
	ev.pressed = true
	Input.parse_input_event(ev)
	var up := InputEventKey.new()
	up.keycode = keycode
	up.physical_keycode = keycode
	up.pressed = false
	Input.parse_input_event(up)
