## Editor GUI test harness — REPRODUCTION testing for viewport interactions.
##
## Runs ONLY when the PB_GUI_TEST environment variable is set (the
## run_gui_tests.sh wrapper sets it). Opening this scene in a normal,
## interactive editor session does nothing — it is a plain empty Node3D.
##
## With the gate set:
##   ./run_gui_tests.sh
## (equivalent to: PB_GUI_TEST=1 xvfb-run godot-mono --editor
## --rendering-driver opengl3 res://test_scenes/editor_gui_test.tscn)
##
## The script synthesizes genuine mouse events through the input pipeline
## (Input.parse_input_event) and asserts the OBSERVABLE outcomes:
##
## 1. SELECT: with mesh A active in face mode, clicking mesh B (another
##    PBMesh) must make B the editor selection.
## 2. CREATE: arming a cube via the plugin and drag-releasing on a surface
##    must produce a preview that finalizes into a Shape_Cube node.
##
## Prints "[GUI TEST] ... PASS/FAIL" lines and quits with the failure count
## as the exit code.
@tool
extends Node3D

var _failures: int = 0

func _ready() -> void:
	if Engine.is_editor_hint() and OS.get_environment("PB_GUI_TEST") != "":
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

func _mouse_motion(pos: Vector2, shift: bool = false, left_held: bool = false) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	ev.shift_pressed = shift
	if left_held:
		ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(ev)

func _mouse_button(pos: Vector2, pressed: bool, shift: bool = false) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	ev.shift_pressed = shift
	if pressed:
		ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(ev)

## Holds/releases the SHIFT key at the Input level (drives
## Input.is_key_pressed, which the plugin's gesture decision reads).
func _shift_down(down: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = KEY_SHIFT
	ev.physical_keycode = KEY_SHIFT
	ev.pressed = down
	Input.parse_input_event(ev)

## Window position of the transform gizmo's arrow grabber for `axis_world`
## (a world-space unit direction from the gizmo origin). Replicates the
## engine's gizmo-scale math (node_3d_editor_viewport.cpp): the grabber
## sphere sits at GIZMO_ARROW_OFFSET (1.4) + GIZMO_ARROW_SIZE/2 (0.175)
## = 1.575 gizmo units along the arrow, one gizmo unit being
## gizmo_size / pixels_per_world_unit (capped by viewport height / 400).
func _gizmo_arrow_pos(vp: SubViewport, host: Control, origin: Vector3, axis_world: Vector3,
		gizmo_size: float = 40.0) -> Vector2:
	var cam := vp.get_camera_3d()
	var cam_xf := cam.global_transform
	var camz := -cam_xf.basis.z.normalized()
	var camy := -cam_xf.basis.y.normalized()
	var gizmo_d: float = maxf(absf(Plane(camz, cam_xf.origin).distance_to(origin)), 0.00001)
	var base: Vector3 = cam_xf.origin + camz * gizmo_d
	var p0: Vector2 = cam.unproject_position(base)
	var p1: Vector2 = cam.unproject_position(base + camy)
	var dd: float = maxf(absf(p0.y - p1.y), 0.00001)
	var vp_host := vp.get_parent()
	var vp_height: float = (vp_host as Control).size.y if vp_host is Control else 600.0
	var gizmo_scale: float = (gizmo_size / dd) * minf(400.0, vp_height) / 400.0
	var grabber_world: Vector3 = origin + axis_world.normalized() * (1.575 * gizmo_scale)
	return _window_pos(vp, host, grabber_world)

## Signed volume enclosed by the mesh (divergence theorem over the internal
## CCW-from-outside triangles). A closed outward surface is positive;
## inside-out (inverted) faces drag it toward/past zero.
static func _mesh_signed_volume(mesh_data: PBMeshData) -> float:
	var p := mesh_data.positions
	var vol: float = 0.0
	for face in mesh_data.faces:
		if face == null:
			continue
		var idxs := face.get_indexes()
		for t in range(0, idxs.size() - 2, 3):
			var a: Vector3 = p[idxs[t]]
			var b: Vector3 = p[idxs[t + 1]]
			var c: Vector3 = p[idxs[t + 2]]
			vol += a.dot(b.cross(c))
	return vol / 6.0

static func _mesh_bbox(mesh_data: PBMeshData) -> AABB:
	var aabb := AABB()
	var first := true
	for pos in mesh_data.positions:
		if first:
			aabb = AABB(pos, Vector3.ZERO)
			first = false
		else:
			aabb = aabb.expand(pos)
	return aabb

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
			# The hovered-face highlight must be gone once the base drag is
			# out (the cursor is drawing the rect, not picking a face).
			if plugin.gizmo_plugin.creation_hover_face != -1:
				_fail("CREATE: face hover highlight still on during the BASE drag")
			else:
				_pass("CREATE: face hover cleared during the BASE drag")

			_mouse_button(end, false)
			await _frames(5)

			# The preview MUST have a gizmo during BASE — without one nothing
			# (outline, box, picking) can exist. Regression guard for the
			# ownerless-preview bug.
			var pv = plugin.shape_creator.preview_node
			if pv == null or plugin.gizmo_plugin.gizmo_for_node(pv) == null:
				_fail("CREATE: preview node has no gizmo during BASE (ownerless?)")

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

	# ── Test 3: ELEMENT picking — face click, hover, edge click ─────────────
	# The user's broken layer: builder modes must select elements and hover
	# must show overlays. Model the scene-graph path: select B explicitly.
	sel.clear()
	sel.add_node(b)
	await _frames(10)
	await _press_and_release_key(KEY_K)  # FACE mode
	await _frames(10)

	var gizmo = plugin.gizmo_plugin.gizmo_for_node(b)
	if gizmo == null:
		_fail("ELEMENT: no PoiBuilder gizmo on GuiTestB")
	else:
		# Hover B's camera-facing face center → hover_id must be set.
		var face_center := _window_pos(vp, host, b.global_position + Vector3(0, 0, 0.5))
		_mouse_motion(face_center)
		await _frames(6)
		if plugin.editor.hover_id >= 0:
			_pass("ELEMENT: hover picks a face (hover_id=%d)" % plugin.editor.hover_id)
		else:
			_fail("ELEMENT: hover picks nothing (hover_id=-1)")

		# Click that face → engine subgizmo selection must be non-empty.
		await _click(face_center)
		await _frames(15)
		var subgizmos: PackedInt32Array = gizmo.get_subgizmo_selection()
		if subgizmos.size() > 0 and plugin.editor.selection.selected_face_count() > 0:
			_pass("ELEMENT: face click selects (ids=%s, mirror=%d)" % [
				str(subgizmos), plugin.editor.selection.selected_face_count()])
		else:
			_fail("ELEMENT: face click selects nothing (engine=%s mirror=%d)" % [
				str(subgizmos), plugin.editor.selection.selected_face_count()])

		# EDGE mode: click the vertical edge nearest the camera.
		await _press_and_release_key(KEY_J)
		await _frames(10)
		var edge_mid := _window_pos(vp, host, b.global_position + Vector3(0.5, 0, 0.5))
		_mouse_motion(edge_mid)
		await _frames(6)
		var hover_edge: int = plugin.editor.hover_id
		await _click(edge_mid)
		await _frames(15)
		var edge_ids: PackedInt32Array = gizmo.get_subgizmo_selection()
		if edge_ids.size() > 0 and plugin.editor.selection.selected_edge_count() > 0:
			_pass("ELEMENT: edge click selects (hover=%d ids=%s)" % [hover_edge, str(edge_ids)])
		else:
			_fail("ELEMENT: edge click selects nothing (hover=%d engine=%s mirror=%d)" % [
				hover_edge, str(edge_ids), plugin.editor.selection.selected_edge_count()])

	# ── Test 4: creation BASE outline actually DREW lines ────────────────────
	if plugin.gizmo_plugin.creation_outline_draws > 0:
		_pass("CREATE: BASE outline drew %d time(s)" % plugin.gizmo_plugin.creation_outline_draws)
	else:
		_fail("CREATE: BASE outline branch never drew")

	# ── Test 4b: stairs params modal auto-dismisses on a click elsewhere ─────
	plugin._on_shape_requested(&"stair")
	await _frames(10)
	if not plugin.shape_creator.is_active():
		_fail("STAIR: creator not armed")
	else:
		var s1 := _window_pos(vp, host, Vector3(-1.5, 0.5001, 1.5))
		var s2 := _window_pos(vp, host, Vector3(-0.5, 0.5001, 0.8))
		_mouse_motion(s1)
		await _frames(3)
		_mouse_button(s1, true)
		await _frames(3)
		for i in range(1, 4):
			_mouse_motion(s1.lerp(s2, float(i) / 3.0))
			await _frames(2)
		_mouse_button(s2, false)
		await _frames(5)
		var top2 := _window_pos(vp, host, Vector3(-1, 2.2, 0))
		_mouse_motion(top2)
		await _frames(5)
		await _click(top2)  # confirming click → PARAMS modal opens (stairs)
		await _frames(15)
		if not plugin.tool_overlay.params_open:
			_fail("STAIR: params modal did not open at the confirming click")
		else:
			# Any viewport click elsewhere must auto-apply and hand the
			# session over — no dead modal state.
			var elsewhere := _window_pos(vp, host, Vector3(0.2, 0.5001, 1.8))
			await _click(elsewhere)
			await _frames(15)
			if plugin.tool_overlay.params_open:
				_fail("STAIR: params modal still open after a click elsewhere")
			elif plugin.shape_creator.is_active():
				_fail("STAIR: creation session still active after the modal dismissed")
			else:
				var stair_node := root.get_node_or_null(NodePath("Shape_Stair"))
				if stair_node == null:
					_fail("STAIR: no Shape_Stair node after auto-apply")
				else:
					_pass("STAIR: modal auto-applied on a click elsewhere, node kept")

	# ── Test 5: extrude gesture pipeline (real selection + deliveries) ───────
	# The engine's transform gizmo cannot be engaged by synthesized events on
	# 4.7.2 (hit-test internals), so the drag DELIVERIES the engine would send
	# are driven straight through the plugin: real click-selection, then
	# absolute subgizmo transforms along a world axis, then commit. This is
	# the plugin-side of the shift+drag extrude gesture.
	# A viewport click first: after the stair test the SCENE DOCK owns the
	# keyboard focus, and the K press would never reach the viewport.
	await _click(_window_pos(vp, host, Vector3(3, 0.5001, 0)))
	await _frames(8)
	await _press_and_release_key(KEY_K)  # FACE mode
	await _frames(5)

	# ── 5a: top face, drag deliveries toward +X must move the cap +X ──
	sel.clear()
	sel.add_node(b)
	await _frames(8)
	await _click(_window_pos(vp, host, Vector3(3, 0.5001, 0)))
	await _frames(12)
	var ids5: PackedInt32Array = gizmo.get_subgizmo_selection()
	if ids5.size() == 0:
		_fail("EXTRUDE: top face click selected nothing")
	else:
		var ed5 = plugin.gizmo_plugin.element_editor
		var start_xf: Transform3D = ed5.get_subgizmo_transform(b.pb_mesh_data, b, ids5[0])
		# First delivery carries shift → decides EXTRUDE_MOVE and extrudes(0).
		ed5.set_subgizmo_transform_with_shift(b, gizmo.get_subgizmo_selection(),
			ids5[0], start_xf.translated(Vector3(0.15, 0, 0)), true)
		for step in range(1, 6):
			ed5.set_subgizmo_transform_with_shift(b, gizmo.get_subgizmo_selection(),
				ids5[0], start_xf.translated(Vector3(0.15 + 0.1 * step, 0, 0)), true)
		var max_x_a: float = _mesh_bbox(b.pb_mesh_data).position.x + _mesh_bbox(b.pb_mesh_data).size.x
		ed5.commit_subgizmos(b, gizmo.get_subgizmo_selection(), false)
		await _frames(5)
		var bbox5 := _mesh_bbox(b.pb_mesh_data)
		var max_x: float = bbox5.position.x + bbox5.size.x
		if max_x > 1.0 and max_x > max_x_a - 0.01:
			_pass("EXTRUDE: cap followed +X deliveries (max_x=%.2f)" % max_x)
		else:
			_fail("EXTRUDE: cap did not follow +X deliveries (max_x=%.2f, mid=%.2f)"
				% [max_x, max_x_a])

	# ── 5b: FRONT face (basis flips X and Z), drag −Z must move the cap −Z ──
	b.pb_mesh_data = PBMeshData.create_cube(1.0)
	b.position = Vector3(3, 0, 0)
	await _frames(8)
	await _click(_window_pos(vp, host, Vector3(3, 0, 0.5)))
	await _frames(12)
	var ids5b: PackedInt32Array = gizmo.get_subgizmo_selection()
	if ids5b.size() == 0:
		_fail("EXTRUDE-FRONT: front face click selected nothing")
	else:
		var ed5b = plugin.gizmo_plugin.element_editor
		var start_xf_b: Transform3D = ed5b.get_subgizmo_transform(b.pb_mesh_data, b, ids5b[0])
		# The engine delivers ABSOLUTE node-local transforms; for a world-space
		# drag along −Z (the front face's outward normal is −Z is wrong — the
		# visible front face normal is +Z here; drag +Z then) the target is
		# start translated by the world delta. Use +Z (out of the visible face).
		ed5b.set_subgizmo_transform_with_shift(b, gizmo.get_subgizmo_selection(),
			ids5b[0], start_xf_b.translated(Vector3(0, 0, 0.15)), true)
		for step in range(1, 6):
			ed5b.set_subgizmo_transform_with_shift(b, gizmo.get_subgizmo_selection(),
				ids5b[0], start_xf_b.translated(Vector3(0, 0, 0.15 + 0.1 * step)), true)
		ed5b.commit_subgizmos(b, gizmo.get_subgizmo_selection(), false)
		await _frames(5)
		var bbox5b := _mesh_bbox(b.pb_mesh_data)
		var max_z: float = bbox5b.position.z + bbox5b.size.z
		if max_z > 1.0:
			_pass("EXTRUDE-FRONT: cap followed +Z deliveries (max_z=%.2f)" % max_z)
		else:
			_fail("EXTRUDE-FRONT: cap did not follow +Z deliveries (max_z=%.2f)" % max_z)

		# ── Test 6: deliveries BACK through zero keep the sides outward ─
		# Fresh cube, pick a face, extrude it and drag it back through its
		# own base plane (along the face's basis Z — the direction the side
		# quads were wound for). They must flip winding (stay visible)
		# instead of rendering inside-out ("missing faces").
		b.pb_mesh_data = PBMeshData.create_cube(1.0)
		b.position = Vector3(3, 0, 0)
		await _frames(8)
		sel.clear()
		sel.add_node(b)
		await _frames(5)
		await _click(_window_pos(vp, host, Vector3(3, 0, 0.5)))
		await _frames(12)
		var ids6: PackedInt32Array = gizmo.get_subgizmo_selection()
		if ids6.size() == 0:
			_fail("CROSSZERO: cap click selected nothing")
		else:
			var ed6 = plugin.gizmo_plugin.element_editor
			var start6: Transform3D = ed6.get_subgizmo_transform(b.pb_mesh_data, b, ids6[0])
			var naxis: Vector3 = ed6.element_basis(b.pb_mesh_data, b, ids6[0]).z.normalized()
			var vol_before := _mesh_signed_volume(b.pb_mesh_data)
			ed6.set_subgizmo_transform_with_shift(b, gizmo.get_subgizmo_selection(),
				ids6[0], start6.translated(naxis * 0.3), true)
			for step in range(1, 7):
				ed6.set_subgizmo_transform_with_shift(b, gizmo.get_subgizmo_selection(),
					ids6[0], start6.translated(naxis * (0.3 - 0.35 * step)), true)
			ed6.commit_subgizmos(b, gizmo.get_subgizmo_selection(), false)
			await _frames(5)
			var vol := _mesh_signed_volume(b.pb_mesh_data)
			if vol < vol_before * 0.6:
				_fail("CROSSZERO: sides inverted — faces render missing (vol=%.2f, was %.2f)"
					% [vol, vol_before])
			else:
				_pass("CROSSZERO: sides stayed outward after crossing zero (vol=%.2f, was %.2f)"
					% [vol, vol_before])

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

func _press_and_release_key(keycode: Key) -> void:
	_press_key(keycode)
	await _frames(2)
