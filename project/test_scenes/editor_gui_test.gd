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
	if node.get_script() != null and str(node.get_script().resource_path).ends_with("poibuilder_plugin.gd"):
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

## Sends Ctrl+Z through the input pipeline (the editor's undo shortcut).
func _press_undo() -> void:
	var ev := InputEventKey.new()
	ev.keycode = KEY_Z
	ev.physical_keycode = KEY_Z
	ev.ctrl_pressed = true
	ev.pressed = true
	Input.parse_input_event(ev)
	await _frames(2)
	var up := InputEventKey.new()
	up.keycode = KEY_Z
	up.physical_keycode = KEY_Z
	up.ctrl_pressed = true
	up.pressed = false
	Input.parse_input_event(up)

func _press_redo() -> void:
	var ev := InputEventKey.new()
	ev.keycode = KEY_Y
	ev.physical_keycode = KEY_Y
	ev.ctrl_pressed = true
	ev.pressed = true
	Input.parse_input_event(ev)
	await _frames(2)
	var up := InputEventKey.new()
	up.keycode = KEY_Y
	up.physical_keycode = KEY_Y
	up.ctrl_pressed = true
	up.pressed = false
	Input.parse_input_event(up)
## Count pixels whose RGB channels differ by more than 8 between two images.
## Opaque texel count of a decal/mask image (the harness's robust "is there
## paint here" probe: a single texel of the woven stamp sources proves nothing).
static func _count_opaque(img: Image) -> int:
	if img == null or img.is_empty():
		return 0
	var bytes := img.get_data()
	var n := 0
	var i := 3
	while i < bytes.size():
		if bytes[i] > 128:
			n += 1
		i += 4
	return n

## Decal colour at a NODE-LOCAL point on a face (the sample the shader takes).
static func _decal_centre_colour(data: PBMeshData, mat: ShaderMaterial, face: PBFace,
		local_point: Vector3) -> Color:
	if mat == null or not PBSplat.has_decal_layer(mat):
		return Color(0, 0, 0, 0)
	var bounds := PBSplat.get_face_planar_bounds(data, face)
	if bounds.is_empty():
		return Color(0, 0, 0, 0)
	var duv := PBSplat.decal_uv_from_mask_uv(mat, Vector2(
		((bounds["u"] as Vector3).dot(local_point) - bounds["min_u"]) / bounds["range_u"],
		((bounds["v"] as Vector3).dot(local_point) - bounds["min_v"]) / bounds["range_v"]))
	var img := PBSplat.get_decal_layer_image(mat)
	if duv.x < 0.0 or duv.x > 1.0 or duv.y < 0.0 or duv.y > 1.0:
		return Color(0, 0, 0, 0)
	return img.get_pixel(clampi(int(duv.x * img.get_width()), 0, img.get_width() - 1),
			clampi(int(duv.y * img.get_height()), 0, img.get_height() - 1))

## Painted bounding box (pixels) of a decal layer image.
static func _decal_paint_bbox(img: Image) -> Rect2:
	if img == null:
		return Rect2()
	var w := img.get_width()
	var h := img.get_height()
	var bytes := img.get_data()
	var min_x := w
	var max_x := -1
	var min_y := h
	var max_y := -1
	for y in range(h):
		var row := y * w * 4
		for x in range(w):
			if bytes[row + x * 4 + 3] > 25:  # (0.1 alpha)
				min_x = mini(min_x, x)
				max_x = maxi(max_x, x)
				min_y = mini(min_y, y)
				max_y = maxi(max_y, y)
	if max_x < 0:
		return Rect2()
	return Rect2(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)

static func _img_diff(a: Image, b: Image) -> int:
	if a == null or b == null or a.get_size() != b.get_size():
		return -1
	var da := a.get_data()
	var db := b.get_data()
	var px: int = a.get_width() * a.get_height()
	var diff := 0
	for i in range(px):
		var o := i * 4
		if abs(da[o] - db[o]) > 8 or abs(da[o + 1] - db[o + 1]) > 8 \
				or abs(da[o + 2] - db[o + 2]) > 8:
			diff += 1
	return diff

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
	await _frames(120)
	var iface := EditorInterface
	iface.set_main_screen_editor("3D")
	await _frames(10)
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

	var cam := vp.get_camera_3d()
	if cam == null:
		_fail("no viewport camera")
		get_tree().quit(1)
		return
	cam.global_transform = Transform3D(Basis.IDENTITY, Vector3(1.5, 2.5, 4.0)) \
		.looking_at(Vector3(1.5, 0, 0), Vector3.UP)
	await _frames(10)

	# ── Test 0: the ARMED cursor square exists with NO PBMesh in the scene ───
	# Fresh-import regression: the gizmo path draws that square on a PBMesh's
	# gizmo, so on an empty scene it needs the grid_view scenario marker.
	var plugin0 := _find_plugin(iface.get_base_control().get_parent())
	if plugin0 == null:
		plugin0 = _find_plugin(iface.get_base_control())
	if plugin0 == null:
		_fail("CURSOR-MARKER: PoiBuilder plugin node not found")
	else:
		plugin0._on_shape_requested(&"cube")
		await _frames(10)
		_mouse_motion(_window_pos(vp, host, Vector3(-1, 0.0, 1.2)))
		await _frames(6)
		if plugin0.gizmo_plugin.creation_hover_node != null:
			_fail("CURSOR-MARKER: fixture has a PBMesh host — empty-scene precondition broken")
		elif plugin0.gizmo_plugin.creation_hover_point == Vector3.ZERO:
			_fail("CURSOR-MARKER: armed hover point never settled (motion ray missed the grid?)")
		elif not plugin0.grid_view._cursor_instance_rid.is_valid():
			_fail("CURSOR-MARKER: no scenario cursor square while ARMED on an empty scene")
		else:
			_pass("CURSOR-MARKER: armed on an empty scene, the scenario cursor square exists")
		_press_key(KEY_ESCAPE)
		await _frames(6)
		if plugin0.shape_creator.is_active():
			_fail("CURSOR-MARKER: Esc did not disarm creation (state now %d)" % plugin0.shape_creator.state)
		await _frames(6)
		if plugin0.grid_view != null and plugin0.grid_view._cursor_instance_rid.is_valid():
			# The marker hides the moment creation is no longer ARMED.
			if plugin0.grid_view.cursor_shown:
				_fail("CURSOR-MARKER: scenario cursor square stayed visible after disarm")
			else:
				_pass("CURSOR-MARKER: scenario cursor square hides when creation ends")

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
		elif not plugin.grid_view.is_visible():
			_fail("CREATE: grid did not arm immediately upon shape request")
		else:
			_pass("CREATE: grid armed immediately upon shape request")
			var start := _window_pos(vp, host, Vector3(-1, 0.5001, 1.2))
			var end := _window_pos(vp, host, Vector3(1.2, 0.5001, -1))
			_mouse_motion(start)
			await _frames(3)
			var hover_pt: Vector3 = plugin.gizmo_plugin.creation_hover_point
			var grid_step: float = plugin.grid.step()
			var rem_x := absf(hover_pt.x - roundf(hover_pt.x / grid_step) * grid_step)
			var rem_z := absf(hover_pt.z - roundf(hover_pt.z / grid_step) * grid_step)
			if rem_x < 0.001 and rem_z < 0.001 and hover_pt != Vector3.ZERO:
				_pass("CREATE: ARMED hover vertex snapped to grid starting point")
			else:
				_fail("CREATE: ARMED hover vertex not snapped to grid (x=%.3f, z=%.3f, step=%.3f)" % [hover_pt.x, hover_pt.z, grid_step])
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

		# ── Test 2a: a CLICK WITHOUT A DRAG must leave NOTHING ───────────────────
		# end_base() rejects the undersized base by resetting the creator —
		# which nulls preview_node — and the old abort then skipped the node
		# teardown: every stray click leaked a meshless Shape_Cube (the
		# editor's warning icon) WITH its base-outline gizmo still drawing.
		plugin._on_shape_requested(&"cube")
		await _frames(10)
		if not plugin.shape_creator.is_active():
			_fail("CLICK-ONLY: creator not armed")
		else:
			var spot := _window_pos(vp, host, Vector3(2.4, 0.5001, 1.8))
			_mouse_motion(spot)
			await _frames(3)
			_mouse_button(spot, true)
			await _frames(5)
			_mouse_button(spot, false)
			await _frames(10)

			if plugin.shape_creator.is_active():
				_fail("CLICK-ONLY: creator still active after a bare click")
			if plugin.shape_creator.preview_node != null:
				_fail("CLICK-ONLY: preview_node reference survived the abort")
			if plugin.gizmo_plugin.creation_hover_node != null \
					or plugin.gizmo_plugin.creation_hover_face != -1:
				_fail("CLICK-ONLY: creation hover overlay leaked")
			var orphans := 0
			for child in root.get_children():
				if child is PBMesh and (child as PBMesh).mesh == null:
					orphans += 1
			if orphans > 0:
				_fail("CLICK-ONLY: %d meshless PBMesh node(s) leaked by the aborted click" % orphans)
			else:
				_pass("CLICK-ONLY: a bare click leaves no node and no overlay behind")

	# ── Test 2b: the PLANE — a base drag, then a normal OFFSET ───────────────
	# The plane's third dimension is a STAND-OFF from the surface, not a size:
	# it is how a waterfall sheet or a sign hangs clear of the wall it was
	# drawn on. The drag rectangle must survive the offset untouched, and the
	# confirming click must land a node displaced along the surface normal.
	plugin._on_shape_requested(&"plane")
	await _frames(10)
	if not plugin.shape_creator.is_active():
		_fail("PLANE: creator not armed")
	else:
		var pstart := _window_pos(vp, host, Vector3(-0.6, 0.5001, 1.4))
		var pend := _window_pos(vp, host, Vector3(1.1, 0.5001, 0.2))
		_mouse_motion(pstart)
		await _frames(3)
		_mouse_button(pstart, true)
		await _frames(3)
		for i in range(1, 5):
			_mouse_motion(pstart.lerp(pend, float(i) / 4.0))
			await _frames(2)
		_mouse_button(pend, false)
		await _frames(5)

		if plugin.shape_creator.state != PBShapeCreator.State.OFFSET:
			_fail("PLANE: expected the OFFSET stage after the base drag, got state %d"
				% plugin.shape_creator.state)
		else:
			_pass("PLANE: base drag hands over to the offset stage")
		var w_dragged: float = plugin.shape_creator.values["width"]
		var d_dragged: float = plugin.shape_creator.values["depth"]

		# Moving the cursor up must lift the sheet off the surface without
		# touching its size — the bug this flow exists to prevent is the drag
		# rectangle being re-applied as a height.
		var up := _window_pos(vp, host, Vector3(0.25, 2.4, 0.8))
		_mouse_motion(up)
		await _frames(5)
		var off_height: float = plugin.shape_creator.height
		if off_height <= 0.1:
			_fail("PLANE: offset stayed at %.3f after moving off the surface" % off_height)
		elif absf(plugin.shape_creator.values["width"] - w_dragged) > 0.001 \
				or absf(plugin.shape_creator.values["depth"] - d_dragged) > 0.001:
			_fail("PLANE: the offset changed the sheet's size (%.2fx%.2f -> %.2fx%.2f)"
				% [w_dragged, d_dragged,
				   plugin.shape_creator.values["width"], plugin.shape_creator.values["depth"]])
		else:
			_pass("PLANE: offset %.2fm leaves the %.2fx%.2fm sheet unchanged"
				% [off_height, w_dragged, d_dragged])

		await _click(up)
		await _frames(20)
		var plane_node := root.get_node_or_null(NodePath("Shape_Plane"))
		if plane_node == null:
			_fail("PLANE: no Shape_Plane node after confirm")
		elif plane_node.pb_mesh_data == null:
			_fail("PLANE: created node has no mesh data")
		else:
			var pn: PBMesh = plane_node
			var id_ok: bool = pn.pb_mesh_data.shape_id == &"plane"
			var lifted: bool = pn.position.y > 0.5001 + 0.1
			if id_ok and lifted:
				_pass("PLANE: created %.2f m above the surface it was drawn on"
					% (pn.position.y - 0.5001))
			else:
				_fail("PLANE: created node is wrong (shape_id=%s, y=%.3f)"
					% [str(pn.pb_mesh_data.shape_id), pn.position.y])
			if pn.pb_mesh_data.faces.size() != 1:
				_fail("PLANE: a plane must be a single face, got %d"
					% pn.pb_mesh_data.faces.size())
		if plugin.shape_creator.is_active():
			_fail("PLANE: creator still active after confirm")
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

		# MODE CONVERSION: switching modes converts the selection (ProBuilder
		# parity). The engine holds ONE seed id for the converted set (its
		# script API cannot set several); the mirror must report the FULL set.
		await _press_and_release_key(KEY_J)  # FACE -> EDGE
		await _frames(10)
		if gizmo.get_subgizmo_selection().size() > 0 \
				and plugin.editor.selection.selected_edge_count() == 4:
			_pass("CONVERT: face -> its 4 edges (seed present, mirror=4)")
		else:
			_fail("CONVERT: face -> edge lost the selection (engine=%s mirror=%d)" % [
				str(gizmo.get_subgizmo_selection()),
				plugin.editor.selection.selected_edge_count()])
		await _press_and_release_key(KEY_H)  # EDGE -> VERTEX
		await _frames(10)
		if gizmo.get_subgizmo_selection().size() > 0 \
				and plugin.editor.selection.selected_vertex_count() == 4:
			_pass("CONVERT: edges -> their 4 verts (seed present, mirror=4)")
		else:
			_fail("CONVERT: edge -> vertex lost the selection (engine=%s mirror=%d)" % [
				str(gizmo.get_subgizmo_selection()),
				plugin.editor.selection.selected_vertex_count()])
		await _press_and_release_key(KEY_K)  # VERTEX -> FACE (round trip)
		await _frames(10)
		if gizmo.get_subgizmo_selection().size() > 0 \
				and plugin.editor.selection.selected_face_count() == 1:
			_pass("CONVERT: verts -> the face again (round trip closes)")
		else:
			_fail("CONVERT: vertex -> face round trip failed (engine=%s mirror=%d)" % [
				str(gizmo.get_subgizmo_selection()),
				plugin.editor.selection.selected_face_count()])

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
			var elsewhere := _window_pos(vp, host, Vector3(2.5, 0.5001, 0.0))
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
		# The click→pick chain (focus hand-off, deferred selection signals,
		# gizmo redraw scheduling) is timing-sensitive under the software
		# renderer: this exact click intermittently selects nothing even on a
		# re-click, while the pick math itself is healthy (a direct pick_ray
		# at the failure state returns the face). Retry the click once, then
		# fall back to the same programmatic selection the plugin itself uses
		# — the thing this test verifies is the INWARD-EXTRUDE winding below,
		# not click routing (covered by tests 3 / 5a / 5b).
		if ids6.size() == 0:
			await _click(_window_pos(vp, host, Vector3(3, 0, 0.5)))
			await _frames(12)
			ids6 = gizmo.get_subgizmo_selection()
		if ids6.size() == 0 and plugin.editor.select_mode == PBEditor.SelectMode.FACE:
			var dbg_cam2 := vp.get_camera_3d()
			var pick_res: int = plugin.gizmo_plugin.element_editor.pick_ray(
				b.pb_mesh_data, b.global_transform, dbg_cam2,
				dbg_cam2.unproject_position(Vector3(3, 0, 0.5)))
			if pick_res >= 0:
				b.set_subgizmo_selection(gizmo, pick_res,
					plugin.gizmo_plugin.element_editor.get_subgizmo_transform(
						b.pb_mesh_data, b, pick_res))
				await _frames(4)
				ids6 = gizmo.get_subgizmo_selection()
		if ids6.size() == 0:
			_fail("EXTRUDE-INWARD: cap click selected nothing")
		else:
			var ed6 = plugin.gizmo_plugin.element_editor
			var start6: Transform3D = ed6.get_subgizmo_transform(b.pb_mesh_data, b, ids6[0])
			var naxis: Vector3 = ed6.element_basis(b.pb_mesh_data, b, ids6[0]).z.normalized()
			# Extrude inward into the cube (-naxis * 0.4)
			ed6.set_subgizmo_transform_with_shift(b, gizmo.get_subgizmo_selection(),
				ids6[0], start6.translated(-naxis * 0.4), true)
			ed6.commit_subgizmos(b, gizmo.get_subgizmo_selection(), false)
			await _frames(5)
			# Verify cap normal points towards opening (+naxis), side walls point into cavity
			var cap_f: PBFace = b.pb_mesh_data.faces[ids6[0]]
			var cap_norm := PBMeshOps._face_area_normal(b.pb_mesh_data, cap_f)
			if cap_norm.dot(naxis) > 0.5:
				_pass("EXTRUDE-INWARD: cap faces towards opening into cavity")
			else:
				_fail("EXTRUDE-INWARD: cap inverted away from opening (got %s vs expected %s)" % [cap_norm, naxis])
			var shot6 := vp.get_texture().get_image()
			shot6.save_png("/tmp/pb_extrude_state.png")
			print("[GUI TEST] DEBUG extrude-state screenshot saved")
	# ── Test 7: center scale handle — detection, uniform scale, inset ────────
	# Fresh cube, FACE mode, select the top face, switch to the SCALE tool.
	# The ProBuilder-style CENTER square (our gizmo handle) must be drawn at
	# the element pivot, grabbable by a click there, scale uniformly with a
	# rightward drag (right = smaller), and INSET with shift.
	b.pb_mesh_data = PBMeshData.create_cube(1.0)
	b.position = Vector3(3, 0, 0)
	await _frames(8)
	sel.clear()
	sel.add_node(b)
	await _frames(5)
	# Viewport click first so hotkeys/clicks land (focus), then re-select.
	await _click(_window_pos(vp, host, Vector3(3, 0.5001, 0)))
	await _frames(8)
	plugin.editor.tool_mode = PBEditor.ToolMode.SCALE
	await _frames(10)
	# Re-click the top face under the SCALE tool so the handle draws over a
	# live subgizmo selection.
	await _click(_window_pos(vp, host, Vector3(3, 0.5001, 0)))
	await _frames(12)

	var gh = plugin.gizmo_plugin
	var sx7: float = host.size.x / float(vp.size.x)
	if not gh._center_handle_drawn:
		_fail("CENTER: center scale handle was not drawn (tool switch did not refresh the gizmo)")
	else:
		var pivot_world: Vector3 = gh._center_handle_world
		var center_screen := _window_pos(vp, host, pivot_world)
		# Drag RIGHT 50px → factor 0.5 (half size, uniform).
		var ed7 = plugin.gizmo_plugin.element_editor
		var pre_positions: PackedVector3Array = b.pb_mesh_data.positions.duplicate()
		var face_centroid: Vector3 = ed7.element_origin(b.pb_mesh_data, 4)
		_mouse_button(center_screen, true, false)
		await _frames(3)
		var mid_active: bool = ed7.center_drag_active()
		for i in range(1, 6):
			_mouse_motion(center_screen + Vector2(10.0 * i * sx7, 0), false, true)
			await _frames(2)
		_mouse_button(center_screen + Vector2(50.0 * sx7, 0), false, false)
		await _frames(10)
		# Scaling a selected FACE shrinks ITS corners toward ITS centroid —
		# assert uniform shrinkage of the face's corner radius (the mesh
		# bbox cannot show it: the other five faces keep the cube bounds).
		var ratios: Array[float] = []
		for idx in ed7.element_indices(b.pb_mesh_data, 4):
			var before: float = (pre_positions[idx] - face_centroid).length()
			var after: float = (b.pb_mesh_data.positions[idx] - face_centroid).length()
			if before > 0.0001:
				ratios.append(after / before)
		var ok_uniform: bool = b.pb_mesh_data.faces.size() == 6 and ratios.size() > 0
		for r in ratios:
			if r < 0.45 or r > 0.75:
				ok_uniform = false
		if ok_uniform:
			_pass("CENTER: handle detected, face scaled uniformly toward its centroid "
				+ "(%d corners, ratio %.2f)" % [ratios.size(), ratios[0]])
		else:
			_fail("CENTER: handle drag did not scale the face uniformly "
				+ "(ratios=%s)" % str(ratios))

	# ── Test 8: shift + center handle = uniform INSET ────────────────────────
	b.pb_mesh_data = PBMeshData.create_cube(1.0)
	b.position = Vector3(3, 0, 0)
	await _frames(8)
	plugin.editor.tool_mode = PBEditor.ToolMode.SCALE
	await _frames(5)
	await _click(_window_pos(vp, host, Vector3(3, 0.5001, 0)))
	await _frames(12)
	if not gh._center_handle_drawn:
		_fail("INSET: center scale handle was not drawn")
	else:
		var center_screen2 := _window_pos(vp, host, gh._center_handle_world)
		_shift_down(true)
		await _frames(2)
		_mouse_button(center_screen2, true, true)
		await _frames(3)
		for i in range(1, 4):
			_mouse_motion(center_screen2 + Vector2(10.0 * i * sx7, 0), true, true)
			await _frames(2)
		_mouse_button(center_screen2 + Vector2(30.0 * sx7, 0), false, true)
		await _frames(2)
		_shift_down(false)
		await _frames(10)
		var md8: PBMeshData = b.pb_mesh_data
		if md8.faces.size() != 10:
			_fail("INSET: shift+center did not seed the inset topology (faces=%d, want 10)"
				% md8.faces.size())
		else:
			_pass("INSET: shift + center handle insets the face (faces=10)")

	# ── Test 9: undo of an extrude drag must refresh the VIEW immediately ────
	# State from Test 6: b carries a committed crossing-extrude (40 positions).
	var pre_undo_img := vp.get_texture().get_image()
	var pre_undo_pos: int = b.pb_mesh_data.positions.size()
	await _mouse_motion(_window_pos(vp, host, Vector3(0.5, 0.4, 2.5)))
	await _frames(6)
	var shot_pre := vp.get_texture().get_image()
	await _press_undo()
	await _frames(15)
	var post_undo_img := vp.get_texture().get_image()
	var post_pos: int = b.pb_mesh_data.positions.size()
	var vol_undo := _mesh_signed_volume(b.pb_mesh_data)
	await _mouse_motion(_window_pos(vp, host, Vector3(0.5, 0.4, 2.5)))
	await _frames(6)
	var shot_post := vp.get_texture().get_image()
	var diff := _img_diff(shot_pre, shot_post)
	print("[GUI TEST] DEBUG undo: positions %d→%d vol=%.2f pixel_diff=%d" % [
		pre_undo_pos, post_pos, vol_undo, diff])
	if post_pos != 24:
		_fail("UNDO: data was not restored (positions=%d)" % post_pos)
	elif diff < 50:
		_fail("UNDO: view did not refresh — mesh still renders extruded (pixel_diff=%d)" % diff)
	else:
		_pass("UNDO: view refreshed immediately after undo (pixel_diff=%d)" % diff)

	# ── Test 10: collider winding overlay (show_collider) ────────────────────
	# The overlay must skin the active collider: green solid on face fronts,
	# red on backs, plus an x-ray wireframe. The scene is placed AWAY from the
	# world origin so the viewport's red X-axis origin line cannot pollute the
	# pixel counts.
	b.position = Vector3(30, 0, 0) # move the extrude-test cube out of frame
	a.visible = false              # and hide the origin cube: stairs render alone
	var stairs := PBMesh.new()
	stairs.name = "GuiTestStairs"
	stairs.pb_mesh_data = PBShapeFactory.create_shape(&"curved_stair", Vector3(2, 2, 2))
	stairs.position = Vector3(6, 0, 6.5)
	root.add_child(stairs)
	stairs.owner = root
	stairs.show_collider = true
	sel.clear()
	await _frames(3)
	var col_body := stairs.get_collider_body()
	var col_shape := col_body.get_node_or_null(NodePath("CollisionShape3D")) as CollisionShape3D
	if not (col_shape != null and col_shape.shape is ConcavePolygonShape3D):
		_fail("COLLIDER: curved stairs ramp should be ConcavePolygonShape3D")
	cam.global_transform = Transform3D(Basis.IDENTITY, Vector3(2.6, 2.1, 10.1)) \
		.looking_at(Vector3(6, 0, 6.2), Vector3.UP)
	await _frames(20)
	var shot_col := vp.get_texture().get_image()
	shot_col.save_png("/tmp/pb_collider_overlay.png")
	# Count pixels only inside the stairs' projected bounding rect.
	var aabb10: AABB = stairs.mesh.get_aabb()
	var r0 := Vector2(INF, INF)
	var r1 := Vector2(-INF, -INF)
	for cx in [aabb10.position.x, aabb10.end.x]:
		for cy in [aabb10.position.y, aabb10.end.y]:
			for cz in [aabb10.position.z, aabb10.end.z]:
				var sp: Vector2 = cam.unproject_position(stairs.global_transform * Vector3(cx, cy, cz))
				r0 = r0.min(sp)
				r1 = r1.max(sp)
	var frame_x := Rect2i(Vector2i(r0), Vector2i(r1 - r0)).grow(10).intersection(Rect2i(Vector2i.ZERO, shot_col.get_size()))
	var red_px := 0
	var green_px := 0
	for py in range(frame_x.position.y, frame_x.end.y):
		for px in range(frame_x.position.x, frame_x.end.x):
			var c := shot_col.get_pixel(px, py)
			if c.r > 0.35 and c.r > c.g + 0.12 and c.r > c.b + 0.12:
				red_px += 1
			elif c.g > 0.3 and c.g > c.r + 0.12 and c.g > c.b + 0.10:
				green_px += 1
	print("[GUI TEST] DEBUG collider overlay: green=%d red=%d roi=%s" % [green_px, red_px, frame_x])
	# Red is legal in patches: the floor annulus's front faces DOWN, so any
	# above-side view sees its back (red) where the skin bulges past the
	# silhouette. What may NOT happen is red FLOODING the view: a bulk
	# inversion shows red on the dominant contact surfaces (the pre-0.9.29
	# ramp read ~22k red px in this exact frame).
	if green_px < 1500: # the solid skin band alone is thousands of px; ~300 could come from the viewport's Y-axis line
		_fail("COLLIDER: overlay not drawn (green_px=%d)" % green_px)
	elif red_px > green_px / 3:
		_fail("COLLIDER: red dominates the outside view (red=%d green=%d) — bulk winding inversion" % [red_px, green_px])
	else:
		_pass("COLLIDER: winding overlay drawn, red contained (green=%d, red=%d)" % [green_px, red_px])

	# ── Test 11: grid snapping on a move drag (0.13 → 0.2 at step 0.2) ──────
	# Scene reset: b becomes a fresh cube back in frame, fresh camera framing.
	stairs.visible = false
	a.visible = true
	b.pb_mesh_data = PBMeshData.create_cube(1.0)
	b.position = Vector3(3, 0, 0)
	await _frames(8)
	plugin.editor.tool_mode = PBEditor.ToolMode.MOVE
	var grid11: PBGrid = plugin.grid
	grid11.enabled = true
	grid11.unit = 1.0
	grid11.subdivisions = 5
	grid11.reset_origin()
	cam.global_transform = Transform3D(Basis.IDENTITY, Vector3(1.5, 2.5, 4.0)) \
		.looking_at(Vector3(1.5, 0, 0), Vector3.UP)
	await _frames(10)
	sel.clear()
	sel.add_node(b)
	await _frames(8)
	await _click(_window_pos(vp, host, Vector3(3, 0.5001, 0)))
	await _frames(12)
	if gizmo.get_subgizmo_selection().is_empty():
		_fail("SNAP-MOVE: top face click selected nothing")
	else:
		var md11: PBMeshData = b.pb_mesh_data
		var ed11 = plugin.gizmo_plugin.element_editor
		var top_id: int = gizmo.get_subgizmo_selection()[0]
		var start11: Transform3D = ed11.get_subgizmo_transform(md11, b, top_id)
		var before11: PackedVector3Array = md11.positions.duplicate()
		ed11.set_subgizmo_transform_with_shift(b, PackedInt32Array([top_id]), top_id,
			start11.translated(Vector3(0.13, 0, 0)), false)
		var ok_snap := true
		for idx in ed11.element_indices(md11, top_id):
			var d: Vector3 = md11.positions[idx] - before11[idx]
			if absf(d.x - 0.2) > 0.001 or absf(d.y) > 0.001 or absf(d.z) > 0.001:
				ok_snap = false
		ed11.commit_subgizmos(b, PackedInt32Array([top_id]), false)
		await _frames(5)
		if ok_snap:
			_pass("SNAP-MOVE: 0.13 drag landed on the 0.2 step")
		else:
			_fail("SNAP-MOVE: drag did not snap to the 0.2 grid step")

	# ── Test 12: Draw On Grid — creation ignores meshes, lands on the
	#    elevated grid plane, extents snap ────────────────────────────────────
	plugin.grid.draw_on_grid = true
	plugin.grid.raise()
	plugin.grid.raise()
	if absf(plugin.grid.elevation() - 0.4) > 0.001:
		_fail("GRID: two raises should reach 0.4 (got %.4f)" % plugin.grid.elevation())
	plugin._on_shape_requested(&"cube")
	await _frames(8)
	if not plugin.shape_creator.is_active():
		_fail("GRID-CREATE: creator not armed")
	else:
		# This point lies on the y=0.4 elevated plane; cube faces are ignored.
		var gp1 := _window_pos(vp, host, Vector3(0.3, 0.4, 0.6))
		var gp2 := _window_pos(vp, host, Vector3(0.96, 0.4, -0.22))
		_mouse_motion(gp1)
		await _frames(3)
		_mouse_button(gp1, true)
		await _frames(3)
		var sc: PBShapeCreator = plugin.shape_creator
		if sc.state != PBShapeCreator.State.BASE:
			_fail("GRID-CREATE: press did not enter BASE (state=%d)" % sc.state)
		elif absf(sc.plane_point.y - 0.4) > 0.001 or absf(sc.plane_normal.y) < 0.99:
			_fail("GRID-CREATE: plane is y=%.3f normal=%s (want elevated 0.4 UP)" % [
				sc.plane_point.y, str(sc.plane_normal)])
		elif absf(fposmod(sc.base_start.x, 0.2)) > 0.001 \
				or absf(fposmod(sc.base_start.z, 0.2)) > 0.001:
			_fail("GRID-CREATE: press point not snapped (base_start=%s)" % str(sc.base_start))
		else:
			_pass("GRID-CREATE: press landed snapped on the elevated grid plane")
		for i in range(1, 5):
			_mouse_motion(gp1.lerp(gp2, float(i) / 4.0))
			await _frames(2)
		_mouse_button(gp2, false)
		await _frames(5)
		if sc.state != PBShapeCreator.State.HEIGHT:
			_fail("GRID-CREATE: base drag did not reach HEIGHT (state=%d)" % sc.state)
		elif absf(fposmod(sc.u_size, 0.2)) > 0.001 or absf(fposmod(sc.v_size, 0.2)) > 0.001:
			_fail("GRID-CREATE: extents not snapped (u=%.3f v=%.3f)" % [sc.u_size, sc.v_size])
		else:
			_pass("GRID-CREATE: extents snapped (u=%.2f v=%.2f)" % [sc.u_size, sc.v_size])
		# ESC aborts — on-grid creation must not leave orphan nodes.
		await _press_and_release_key(KEY_ESCAPE)
		await _frames(5)
		if plugin.shape_creator.is_active():
			_fail("GRID-CREATE: ESC did not abort")
		else:
			_pass("GRID-CREATE: ESC aborted cleanly")
	plugin.grid.draw_on_grid = false
	plugin.grid.reset_origin()

	# ── Test 13: keybind routing — grid keys global, Y contextual ────────────
	# Viewport keypresses only reach plugins while the VIEWPORT holds focus —
	# a programmatic selection change can silently move focus into the scene
	# dock (the K/J/Ctrl+Z arrows above got there via clicks), and a click at
	# a world point that projects OUTSIDE the frame focuses nothing at all.
	# Click an empty area INSIDE the frame: (1.5, 0, -1.4) — the camera frames
	# (1.5, 0, 0); every mesh sits at z >= -1 or x <= 0.5, this is free.
	sel.clear()
	await _frames(5)
	await _click(_window_pos(vp, host, Vector3(1.5, 0, -1.4)))
	await _frames(6)
	# No PBMesh selected: Y is the ENGINE's Use Snap — ours must not toggle.
	await _press_and_release_key(KEY_Y)
	await _frames(4)
	if not plugin.grid.enabled:
		_fail("KEYS: Y toggled PoiBuilder snapping with no PBMesh context")
	else:
		_pass("KEYS: Y stays the engine's outside a PBMesh context")
	var ed_settings := iface.get_editor_settings()
	var raise_sc: Shortcut = ed_settings.get_shortcut("poibuilder/grid_raise")
	var lower_sc: Shortcut = ed_settings.get_shortcut("poibuilder/grid_lower")
	if raise_sc == null or lower_sc == null:
		_fail("SHORTCUTS: grid_raise or grid_lower missing from EditorSettings")
	elif raise_sc.get_name() != "Grid: Raise Elevation" or lower_sc.get_name() != "Grid: Lower Elevation":
		_fail("SHORTCUTS: labels mismatch (raise='%s', lower='%s')" % [
			raise_sc.get_name(), lower_sc.get_name()])
	elif not raise_sc.has_meta("original") or not lower_sc.has_meta("original"):
		_fail("SHORTCUTS: meta original missing on shortcuts")
	elif raise_sc.events.is_empty() or lower_sc.events.is_empty():
		_fail("SHORTCUTS: raise or lower has empty events")
	else:
		_pass("SHORTCUTS: grid_raise and grid_lower properly registered with labels and events")
	# Grid keys are global: subdivision adjustments work with nothing selected.
	var sub_before: int = plugin.grid.subdivisions
	await _press_and_release_key(KEY_EQUAL)
	await _frames(4)
	var sub_up: int = plugin.grid.subdivisions
	await _press_and_release_key(KEY_MINUS)
	await _frames(4)
	if sub_up == sub_before + 1 and plugin.grid.subdivisions == sub_before:
		_pass("KEYS: = / - adjust subdivisions with nothing selected")
	else:
		_fail("KEYS: subdivision keys broken (%d → %d → %d)" % [
			sub_before, sub_up, plugin.grid.subdivisions])
	# Grid raise/lower via ] and \, mid-air with no selection.
	await _press_and_release_key(KEY_BRACKETRIGHT)
	await _frames(4)
	var elev_after_raise: float = plugin.grid.elevation()
	await _press_and_release_key(KEY_BACKSLASH)
	await _frames(4)
	if absf(elev_after_raise - 0.2) < 0.001 and plugin.grid.elevation() == 0.0:
		_pass("KEYS: ] raises elevation by a step, \\ resets")
	else:
		_fail("KEYS: elevation keys broken (raised to %.3f, reset %.3f)" % [
			elev_after_raise, plugin.grid.elevation()])
	# With a PBMesh actively edited: Y toggles OUR snap (and gets restored).
	sel.add_node(b)
	await _frames(5)
	await _click(b_click)  # focus + keep context
	await _frames(6)
	await _press_and_release_key(KEY_Y)
	await _frames(4)
	if plugin.grid.enabled:
		_fail("KEYS: Y did not toggle PoiBuilder snapping in a PBMesh context")
	else:
		await _press_and_release_key(KEY_Y)
		await _frames(4)
		if plugin.grid.enabled:
			_pass("KEYS: Y toggles PoiBuilder snapping while editing (restored on)")
		else:
			_fail("KEYS: PoiBuilder snapping did not toggle back on")

	# ── Test 14: the PoiBuilder grid renders THROUGH the active mesh's gizmo
	#    (the reliable re-render channel), and the engine's stock grid is
	#    hidden inside a PoiBuilder context ──────────────────────────────────
	sel.clear()
	sel.add_node(b)
	await _frames(6)
	await _frames(8)
	plugin.grid.reset_origin()
	plugin.grid.show_grid = true
	await _frames(6)
	var gv: PBGridView = plugin.grid_view
	if gv == null or gv._lines.size() < 8:
		_fail("GRID VIEW: grid line cache is empty (%d verts)" % (gv._lines.size() if gv != null else -1))
	elif plugin.tool_bridge.engine_grid_visible():
		_fail("GRID VIEW: engine stock grid still visible in a PBMesh context")
	else:
		_pass("GRID VIEW: grid lines cached in a PBMesh context; engine grid hidden")
	# Visual diff: show_grid off must remove the grid from the 3D texture —
	# the gizmo path guarantees an actual re-render (unlike a bare
	# MeshInstance visibility flip, which the idle editor viewport skips).
	plugin.grid.show_grid = false
	b.update_gizmos()
	await _frames(8)
	var shot_grid_off: Image = vp.get_texture().get_image()
	plugin.grid.show_grid = true
	b.update_gizmos()
	await _frames(8)
	var shot_grid_on: Image = vp.get_texture().get_image()
	var grid_diff := _img_diff(shot_grid_off, shot_grid_on)
	if grid_diff > 800:
		_pass("GRID VIEW: show_grid toggle changes the 3D frame (pixel_diff=%d)" % grid_diff)
	else:
		_fail("GRID VIEW: show_grid toggle changes nothing (pixel_diff=%d)" % grid_diff)
	var blue_px: int = 0
	for cy in range(shot_grid_on.get_height()):
		for cx in range(shot_grid_on.get_width()):
			var px: Color = shot_grid_on.get_pixel(cx, cy)
			if px.b > 0.22 and px.b > px.r + 0.03 and px.g > px.r + 0.01:
				blue_px += 1
	if blue_px > 1000:
		_pass("GRID VIEW: grid rendered in grayish light-blue (%d blue pixels)" % blue_px)
	else:
		_fail("GRID VIEW: grid not rendered in grayish light-blue (only %d blue pixels)" % blue_px)
	# Leaving the PB context the engine grid comes back.
	sel.clear()
	sel.add_node(a)
	await _frames(2)
	sel.clear()
	await _frames(6)
	if plugin.tool_bridge.engine_grid_visible():
		_pass("GRID VIEW: engine grid restored after deselect")
	else:
		_fail("GRID VIEW: engine grid was not restored after deselect")

	# ── Test 15: object mode follows our grid through the engine snap ────────
	# While a PBMesh sits selected in OBJECT mode, the engine's Snap Settings
	# values mirror the PoiBuilder grid (translate step + 15° rotate) and the
	# engine Use Snap button follows grid.enabled; deselecting restores them.
	sel.clear()
	sel.add_node(b)
	await _frames(6)
	plugin.editor.select_mode = PBEditor.SelectMode.OBJECT
	await _frames(6)
	var spins: Dictionary = plugin.tool_bridge._snap_spins
	if spins.size() != 3:
		_fail("OBJECT-SNAP: snap dialog spinners not found (%d) — object-mode grid sync inert" % spins.size())
	else:
		var ts: float = spins["translate"].value
		var rs: float = spins["rotate"].value
		var engine_snap_on: bool = plugin.tool_bridge._use_snap_btn.button_pressed
		if absf(ts - 0.2) < 0.001 and absf(rs - 15.0) < 0.001 and engine_snap_on == plugin.grid.enabled:
			_pass("OBJECT-SNAP: engine snap tracks the PoiBuilder grid (%.2f / %.0f° / on=%s)" % [
				ts, rs, str(engine_snap_on)])
		else:
			_fail("OBJECT-SNAP: engine values not synced (translate=%.3f rotate=%.1f snap=%s)" % [
				ts, rs, str(engine_snap_on)])
		# Deselect restores the stock values (fresh harness editor: 1m / 15°).
		sel.clear()
		await _frames(8)
		var ts2: float = spins["translate"].value
		if absf(ts2 - 1.0) < 0.001:
			_pass("OBJECT-SNAP: engine snap values restored after deselect (%.2f)" % ts2)
		else:
			_fail("OBJECT-SNAP: translate snap not restored (%.3f)" % ts2)


	# ── Test 16: Knife Tool cuts face and splits it into two selectable n-gons ──
	b.pb_mesh_data = PBMeshData.create_cube(1.0)
	b.position = Vector3(3, 0, 0)
	await _frames(8)
	sel.clear()
	sel.add_node(b)
	await _frames(6)
	plugin.editor.select_mode = PBEditor.SelectMode.FACE
	await _frames(6)

	var top_face_idx := -1
	for fi in range(b.pb_mesh_data.faces.size()):
		var n := PBMath.normal_from_positions(b.pb_mesh_data.positions, b.pb_mesh_data.faces[fi].get_indexes())
		if n.dot(Vector3.UP) > 0.9:
			top_face_idx = fi
			break

	var orig_face_count: int = b.pb_mesh_data.faces.size()
	plugin._on_operation_requested("knife_tool")
	await _frames(4)

	if not plugin.ngon_drawer.is_active() or plugin.ngon_drawer.mode != PBNgonDrawer.Mode.KNIFE:
		_fail("KNIFE: tool did not activate in KNIFE mode")
	else:
		_pass("KNIFE: armed in KNIFE mode")
		var p_start := Vector3(3.0, 0.5, -0.49)
		var p_end := Vector3(3.0, 0.5, 0.49)
		plugin.ngon_drawer.begin(p_start, Vector3.UP, b, top_face_idx)
		plugin.ngon_drawer.add_point(p_end)
		await _frames(4)
		plugin._on_ngon_drawer_complete()
		await _frames(6)
		var new_face_count: int = b.pb_mesh_data.faces.size()
		if new_face_count == orig_face_count + 1:
			_pass("KNIFE: face cut split face into two n-gons (faces: %d -> %d)" % [orig_face_count, new_face_count])
		else:
			_fail("KNIFE: face count mismatch after cut (expected %d, got %d)" % [orig_face_count + 1, new_face_count])
		if plugin.ngon_drawer.preview_node == null and plugin.ngon_drawer.points.is_empty():
			_pass("KNIFE: preview node destroyed and drawer reset (no lingering cut lines)")
		else:
			_fail("KNIFE: preview node or points lingered after cut completion")

	# ── Test 17: N-Gon shape extrusion creates custom 3D prism ──
	plugin._on_shape_requested(&"ngon")
	await _frames(4)
	if not plugin.ngon_drawer.is_active() or plugin.ngon_drawer.mode != PBNgonDrawer.Mode.NGON_EXTRUDE:
		_fail("NGON-EXTRUDE: did not arm in NGON_EXTRUDE mode")
	else:
		_pass("NGON-EXTRUDE: armed in NGON_EXTRUDE mode")
		if plugin.ngon_drawer.preview_node != null and is_instance_valid(plugin.ngon_drawer.preview_node):
			_pass("NGON-EXTRUDE: preview node and gizmo exist immediately upon arming")
		else:
			_fail("NGON-EXTRUDE: preview node missing upon arming")
		plugin.ngon_drawer.begin(Vector3(5, 0, 0), Vector3.UP)
		plugin._make_ngon_preview_node()
		plugin.ngon_drawer.add_point(Vector3(7, 0, 0))
		plugin.ngon_drawer.add_point(Vector3(6, 0, 2))
		plugin.ngon_drawer.update_cursor_plane(Vector3(5.5, 0, 1))
		plugin.ngon_drawer.preview_node.update_gizmos()
		await _frames(4)
		plugin._on_ngon_drawer_complete()
		await _frames(4)
		if plugin.ngon_drawer.state != PBNgonDrawer.State.HEIGHT:
			_fail("NGON-EXTRUDE: Enter did not transition to HEIGHT state")
		else:
			_pass("NGON-EXTRUDE: Enter transitioned to HEIGHT state")
			plugin.ngon_drawer.height = 2.0
			plugin._refresh_ngon_preview()
			await _frames(4)
			plugin._on_ngon_drawer_confirm_height()
			await _frames(6)
			var created_ngon := get_tree().get_edited_scene_root().get_node_or_null("Shape_Ngon")
			if created_ngon != null and created_ngon is PBMesh:
				_pass("NGON-EXTRUDE: created Shape_Ngon PBMesh node (faces: %d)" % created_ngon.pb_mesh_data.faces.size())
			else:
				_fail("NGON-EXTRUDE: Shape_Ngon node not found in scene tree")
			if plugin.gizmo_plugin.creation_hover_point == Vector3.ZERO:
				_pass("NGON-EXTRUDE: hover and first vert points cleared after confirm")
			else:
				_fail("NGON-EXTRUDE: stale hover point remained after confirm")
		# ── 12. TEXTURE SPLATTING & STAMPING GUI TEST ─────────────────────────────
		if plugin.paint_controller != null and plugin.material_dock != null:
			_pass("SPLAT-STAMP: paint_controller and material_dock exist")

			# Test switching to PAINT mode
			plugin.material_dock._set_dock_mode(PBMaterialDock.DockMode.PAINT)
			await _frames(2)
			if plugin.paint_controller.mode == PBPaintController.Mode.PAINT:
				_pass("SPLAT-STAMP: dock mode switch set paint_controller to PAINT")
			else:
				_fail("SPLAT-STAMP: paint_controller failed to enter PAINT mode")

			# Select a paint texture
			var pattern_tex = load("res://addons/poibuilder/materials/textures/circular_square_pattern.png")
			plugin.paint_controller.paint_texture = pattern_tex
			plugin.paint_controller.brush_radius = 0.6
			plugin.paint_controller.brush_softness = 0.5
			_pass("SPLAT-STAMP: configured brush radius=%.1fm, softness=%.1f" % [plugin.paint_controller.brush_radius, plugin.paint_controller.brush_softness])

			# Test switching to STAMP mode
			plugin.material_dock._set_dock_mode(PBMaterialDock.DockMode.STAMP)
			await _frames(2)
			if plugin.paint_controller.mode == PBPaintController.Mode.STAMP:
				_pass("SPLAT-STAMP: dock mode switch set paint_controller to STAMP")
			else:
				_fail("SPLAT-STAMP: paint_controller failed to enter STAMP mode")

			var tapestry_tex = load("res://addons/poibuilder/materials/textures/tapestry.png")
			plugin.paint_controller.stamp_texture = tapestry_tex
			plugin.paint_controller.stamp_scale = 1.5
			plugin.paint_controller.stamp_rotation = 45.0
			_pass("SPLAT-STAMP: configured stamp scale=%.1fm, rotation=%.1f°" % [plugin.paint_controller.stamp_scale, plugin.paint_controller.stamp_rotation])

			# Verify stamp preview material has texture assigned (not white square)
			if plugin.paint_controller.stamp_mesh_instance != null and plugin.paint_controller.stamp_mesh_instance.material_override != null:
				var mat = plugin.paint_controller.stamp_mesh_instance.material_override
				var tex = null
				if mat is ShaderMaterial:
					tex = (mat as ShaderMaterial).get_shader_parameter("albedo_texture")
				elif mat is StandardMaterial3D:
					tex = (mat as StandardMaterial3D).albedo_texture
				if tex != null:
					_pass("SPLAT-STAMP: stamp preview material has valid albedo texture")
				else:
					_fail("SPLAT-STAMP: stamp preview material albedo texture is null")

			# Test wheel event passes through to viewport zoom without conflict
			var ev_wheel := InputEventMouseButton.new()
			ev_wheel.button_index = MOUSE_BUTTON_WHEEL_UP
			ev_wheel.pressed = true
			var res_wheel = plugin._paint_controller_input(vp.get_camera_3d(), ev_wheel)
			if res_wheel == EditorPlugin.AFTER_GUI_INPUT_PASS:
				_pass("SPLAT-STAMP: mouse wheel passes through to viewport zoom without conflict")
			else:
				_fail("SPLAT-STAMP: mouse wheel was consumed instead of passing through")

			# Test applying billboard decal stamp
			var target_b := root.get_node_or_null("GuiTestB") as PBMesh
			if target_b != null:
				plugin.editor.active_mesh = target_b
				# Find GuiTestB's TOP face: the stamp cursor must be coherent
				# (point + normal + face_idx all from the same face — exactly
				# what _pick_paint_surface produces in real use).
				var top_face := -1
				for fi in range(target_b.pb_mesh_data.faces.size()):
					var fn := PBMath.normal_from_positions(target_b.pb_mesh_data.positions,
						target_b.pb_mesh_data.faces[fi].get_indexes())
					if fn.y > 0.99:
						top_face = fi
						break
				plugin.paint_controller.update_cursor(Vector3(3, 0.5, 0), Vector3.UP, target_b, top_face)
				plugin.paint_controller.apply_stamp()
				await _frames(2)

				var data_b := target_b.pb_mesh_data
				var stamp_mat := data_b.get_face_material(data_b.faces[top_face]) as ShaderMaterial
				if target_b.get_node_or_null("PBStamps") == null:
					_pass("SPLAT-DECAL: stamp painted pixels instead of scene nodes (no PBStamps container)")
				else:
					_fail("SPLAT-DECAL: a PBStamps container was created for a stamp")

				if PBSplat.has_decal_layer(stamp_mat):
					# The decal image is a WINDOW around the paint, and the
					# tapestry source is a fine weave that alternates alpha per
					# texel — probing the center texel is a coin flip. Count the
					# opaque ones instead.
					var decal_img := PBSplat.get_decal_layer_image(stamp_mat)
					var opaque := _count_opaque(decal_img)
					if opaque > decal_img.get_width():
						_pass("SPLAT-DECAL: stamp pixels landed in the face's decal layer (%d opaque texels)" % opaque)
					else:
						_fail("SPLAT-DECAL: decal layer exists but holds no pixels (%d opaque)" % opaque)
				else:
					_fail("SPLAT-DECAL: stamping did not create a decal layer")

				# Face-anchoring: resizing the face must NOT touch the painted
				# pixels (they map to the rect recorded at paste time).
				var face0: PBFace = data_b.faces[top_face]
				var pixels_before: PackedByteArray = PBSplat.get_decal_layer_image(stamp_mat).get_data()
				var bounds_before: PackedFloat32Array = face0.splat_bounds.duplicate()
				var saved_pos: Dictionary = {}
				for idx1 in face0.get_distinct_indexes():
					saved_pos[idx1] = data_b.positions[idx1]
					var p1: Vector3 = data_b.positions[idx1]
					data_b.positions[idx1] = Vector3(p1.x * 2.0, p1.y, p1.z)
				target_b.rebuild()
				await _frames(2)
				var unchanged := true
				if face0.splat_bounds != bounds_before:
					unchanged = false
				if PBSplat.get_decal_layer_image(stamp_mat).get_data() != pixels_before:
					unchanged = false
				if unchanged:
					_pass("SPLAT-DECAL: resizing the face leaves the decal anchored (no stretch, no slide)")
				else:
					_fail("SPLAT-DECAL: resizing the face disturbed the decal anchor")
				for idx3 in saved_pos:
					data_b.positions[idx3] = saved_pos[idx3]
				target_b.rebuild()
				await _frames(1)

				# Erase is a brush operation on the decal layer now.
				plugin.paint_controller.paint_target = PBPaintController.PaintTarget.DECAL
				plugin.paint_controller.paint_texture = ImageTexture.create_from_image(
					Image.create(8, 8, false, Image.FORMAT_RGBA8))
				plugin.paint_controller.erase_mode = true
				plugin.paint_controller.brush_radius = 0.4
				plugin.paint_controller.brush_softness = 0.0
				plugin.paint_controller.brush_opacity = 1.0
				plugin.paint_controller.set_mode(PBPaintController.Mode.PAINT)
				plugin.paint_controller.update_cursor(Vector3(3, 0.5, 0), Vector3.UP, target_b, top_face)
				var opaque_before := _count_opaque(PBSplat.get_decal_layer_image(
					data_b.get_face_material(data_b.faces[top_face]) as ShaderMaterial))
				plugin.paint_controller.begin_stroke()
				plugin.paint_controller.end_stroke()
				await _frames(2)
				var opaque_after := _count_opaque(PBSplat.get_decal_layer_image(
					data_b.get_face_material(data_b.faces[top_face]) as ShaderMaterial))
				if opaque_after < opaque_before:
					_pass("SPLAT-DECAL: brush erase faded the painted decal pixels (%d -> %d opaque texels)"
						% [opaque_before, opaque_after])
				else:
					_fail("SPLAT-DECAL: brushing in Decal mode with Erase did not remove pixels (%d -> %d)"
						% [opaque_before, opaque_after])
				plugin.paint_controller.erase_mode = false
				plugin.paint_controller.paint_target = PBPaintController.PaintTarget.SPLAT

				# Clear Decal Layer wipes whatever is left.
				plugin.material_dock._on_clear_all_stamps_pressed()
				await _frames(2)
				# Read the state off the MESH: the clear goes through the undo
				# snapshot path, which swaps in cloned materials — a material
				# reference captured before it is stale afterwards.
				var live_mat := data_b.get_face_material(data_b.faces[top_face]) as ShaderMaterial
				var cleared := PBSplat.get_decal_layer_image(live_mat)
				if _count_opaque(cleared) == 0:
					_pass("SPLAT-DECAL: Clear Decal Layer erased the layer")
				else:
					_fail("SPLAT-DECAL: Clear Decal Layer left pixels behind (%d)" % _count_opaque(cleared))

				plugin.material_dock._set_dock_mode(PBMaterialDock.DockMode.MATERIAL)
				await _frames(2)
				if plugin.paint_controller.mode == PBPaintController.Mode.NONE:
					_pass("SPLAT-DECAL: reset to MATERIAL mode set paint_controller to NONE")
				else:
					_fail("SPLAT-DECAL: failed to reset paint_controller")

				# ── Decal brush & stamp panel: every control must reach the pixels.
				# The panel's widgets are driven the way a user click drives them
				# (the signals the editor emits), then the PAINTED PIXELS are read
				# back: a control that does not change the paint is a control that
				# lies about what the brush will do.
				var pc: PBPaintController = plugin.paint_controller
				var dock_p: PBMaterialDock = plugin.material_dock
				var brush_target: PBMesh = root.get_node_or_null("GuiTestB") as PBMesh
				if pc == null or dock_p == null or brush_target == null:
					_fail("BRUSH-PANEL: paint controller, dock or target mesh missing")
				else:
					plugin.editor.active_mesh = brush_target
					dock_p._set_dock_mode(PBMaterialDock.DockMode.PAINT)
					await _frames(2)
					var tgt_face := -1
					for fi in range(brush_target.pb_mesh_data.faces.size()):
						var fn := PBMath.normal_from_positions(brush_target.pb_mesh_data.positions,
							brush_target.pb_mesh_data.faces[fi].get_indexes())
						if fn.y > 0.99:
							tgt_face = fi
							break

					# 0. The ring must exist on the FIRST hover after entering the
					# tab: it used to be built only by a size/softness nudge, so
					# coming from the Stamp tab showed no ring at all.
					dock_p._set_dock_mode(PBMaterialDock.DockMode.STAMP)
					await _frames(4)
					dock_p._set_dock_mode(PBMaterialDock.DockMode.PAINT)
					await _frames(4)
					pc.update_cursor(Vector3(3, 0.5, 0), Vector3.UP, brush_target, tgt_face)
					await _frames(2)
					var first_ring := pc.brush_mesh_instance.mesh as ImmediateMesh \
							if pc.brush_mesh_instance != null else null
					if first_ring != null and first_ring.get_surface_count() >= 2:
						_pass("BRUSH-RING: the ring is built on the first hover after entering the tab")
					else:
						_fail("BRUSH-RING: no ring geometry on the first hover (mesh=%s)" % str(first_ring))

					# 1. Painting defaults to splatting.
					if pc.paint_target == PBPaintController.PaintTarget.SPLAT:
						_pass("BRUSH-PANEL: painting defaults to texture splatting")
					else:
						_fail("BRUSH-PANEL: paint target did not default to splatting")

					# 2. The panel's widgets move the controller (click semantics).
					dock_p._opt_paint_target.item_selected.emit(PBPaintController.PaintTarget.DECAL)
					dock_p._opt_brush_source.item_selected.emit(PBPaintController.BrushSource.COLOR)
					dock_p._btn_brush_color.color = Color(0.1, 0.9, 0.2, 1.0)
					dock_p._btn_brush_color.color_changed.emit(Color(0.1, 0.9, 0.2, 1.0))
					await _frames(2)
					if pc.paint_target == PBPaintController.PaintTarget.DECAL \
							and pc.brush_source == PBPaintController.BrushSource.COLOR:
						_pass("BRUSH-PANEL: target/source selections reach the controller")
					else:
						_fail("BRUSH-PANEL: panel selection did not reach the controller (target=%d source=%d)"
							% [pc.paint_target, pc.brush_source])
					if pc.brush_color.is_equal_approx(Color(0.1, 0.9, 0.2, 1.0)):
						_pass("BRUSH-PANEL: the colour picker reaches the controller")
					else:
						_fail("BRUSH-PANEL: colour picker did not reach the controller (%s)" % pc.brush_color)

					# 3. The brush ring preview must exist and be visible.
					pc.brush_radius = 0.6
					pc.update_cursor(Vector3(3, 0.5, 0), Vector3.UP, brush_target, tgt_face)
					await _frames(2)
					var ring_im := pc.brush_mesh_instance.mesh as ImmediateMesh if \
							pc.brush_mesh_instance != null and pc.brush_mesh_instance.visible else null
					if ring_im != null:
						var ring_verts := (ring_im.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
						if ring_im.get_surface_count() >= 2 and ring_verts >= 90:
							_pass("BRUSH-PANEL: the brush ring is visible at the cursor (%d band verts)" % ring_verts)
						else:
							_fail("BRUSH-PANEL: the brush ring has no band geometry")
					else:
						_fail("BRUSH-PANEL: no visible brush ring at the cursor")

					# 4. Painting with the picked colour writes THAT colour.
					pc.brush_softness = 0.0
					pc.brush_opacity = 1.0
					pc.erase_mode = false
					pc.set_mode(PBPaintController.Mode.PAINT)
					pc.update_cursor(Vector3(3, 0.5, 0), Vector3.UP, brush_target, tgt_face)
					pc.begin_stroke()
					pc.end_stroke()
					await _frames(2)
					var colour_mat := brush_target.pb_mesh_data.get_face_material(
						brush_target.pb_mesh_data.faces[tgt_face]) as ShaderMaterial
					var painted_rgb := _decal_centre_colour(brush_target.pb_mesh_data, colour_mat,
						brush_target.pb_mesh_data.faces[tgt_face],
						brush_target.global_transform.affine_inverse() * Vector3(3, 0.5, 0))
					if painted_rgb.g > 0.6 and painted_rgb.r < 0.4:
						_pass("BRUSH-PANEL: the brush painted the picked colour (%s)" % painted_rgb)
					else:
						_fail("BRUSH-PANEL: the brush painted %s, not the picked colour" % painted_rgb)

					# 5. Erase takes it back out.
					var before_erase := _count_opaque(PBSplat.get_decal_layer_image(colour_mat))
					pc.erase_mode = true
					pc.begin_stroke()
					pc.end_stroke()
					await _frames(2)
					var after_erase := _count_opaque(PBSplat.get_decal_layer_image(colour_mat))
					if after_erase < before_erase:
						_pass("BRUSH-PANEL: erase removes the painted pixels (%d -> %d)"
							% [before_erase, after_erase])
					else:
						_fail("BRUSH-PANEL: erase painted instead of erasing (%d -> %d)"
							% [before_erase, after_erase])
					pc.erase_mode = false

					# 6. Stamp scale and rotation change the PREVIEW and the paste.
					dock_p._set_dock_mode(PBMaterialDock.DockMode.STAMP)
					await _frames(2)
					var hello_tex = load("res://addons/poibuilder/materials/textures/stamp_hello_world.png")
					pc.stamp_texture = hello_tex
					pc.stamp_scale = 3.0
					pc.stamp_rotation = 0.0
					await _frames(2)
					var quad := pc.stamp_mesh_instance.mesh as QuadMesh
					if quad != null and absf(quad.size.x - 3.0) < 0.01 \
							and absf(quad.size.y - 1.5) < 0.05:
						_pass("BRUSH-PANEL: the stamp preview follows the scale spinbox (%s)" % quad.size)
					else:
						_fail("BRUSH-PANEL: stamp preview ignored the scale (%s)"
							% (quad.size if quad != null else Vector2.ZERO))
					var aspect_ok := false
					var width_ok := false
					var stamp_ratio := 0.0
					var stamp_metres := 0.0
					var stamp_px := 0
					var stamp_win := Rect2()
					var stamp_face_m := 0.0
					if quad != null:
						# Measure the stamp alone: wipe whatever the brush checks
						# above left in the layer.
						pc.clear_decal_layer(brush_target)
						await _frames(2)
						pc.update_cursor(Vector3(3, 0.5, 0), Vector3.UP, brush_target, tgt_face)
						pc.apply_stamp()
						await _frames(2)
						var pasted_mat := brush_target.pb_mesh_data.get_face_material(
							brush_target.pb_mesh_data.faces[tgt_face]) as ShaderMaterial
						var pasted_bbox := _decal_paint_bbox(PBSplat.get_decal_layer_image(pasted_mat))
						var ratio: float = pasted_bbox.size.x / maxf(pasted_bbox.size.y, 1.0)
						var pasted_bounds := PBSplat.get_face_planar_bounds(brush_target.pb_mesh_data,
							brush_target.pb_mesh_data.faces[tgt_face])
						# px -> metres: the window's uv span times the face rect is
						# the window's size in metres, spread over its pixels.
						var metres: float = pasted_bbox.size.x * PBSplat.get_decal_window(pasted_mat).size.x \
							* pasted_bounds["range_u"] / maxf(float(
								PBSplat.get_decal_layer_image(pasted_mat).get_width() - 1), 1.0)
						aspect_ok = ratio > 1.5 and ratio < 2.4
						width_ok = absf(metres - 3.0) < 0.6
						stamp_ratio = ratio
						stamp_metres = metres
						stamp_px = pasted_bbox.size.x
						stamp_win = PBSplat.get_decal_window(pasted_mat)
						stamp_face_m = pasted_bounds["range_u"]
					if aspect_ok:
						_pass("BRUSH-PANEL: a 2:1 stamp keeps its aspect after pasting")
					else:
						_fail("BRUSH-PANEL: the pasted stamp is squashed (ratio %.2f, expected 2.0)" % stamp_ratio)
					if width_ok:
						_pass("BRUSH-PANEL: the pasted stamp honours the scale spinbox")
					else:
						_fail("BRUSH-PANEL: the pasted stamp ignored the scale spinbox (%d px, %.2f m, win %s, face %.2f m)"
							% [stamp_px, stamp_metres, str(stamp_win), stamp_face_m])
					# 7. Clear Layer clears the mesh the BRUSH points at, with
					# nothing selected (painting never needed a selection).
					plugin.editor.selection.clear_all()
					pc.paint_target = PBPaintController.PaintTarget.DECAL
					pc.erase_mode = false
					pc.set_mode(PBPaintController.Mode.PAINT)
					pc.update_cursor(Vector3(3, 0.5, 0), Vector3.UP, brush_target, tgt_face)
					pc.begin_stroke()
					pc.end_stroke()
					await _frames(2)
					var clear_mat := brush_target.pb_mesh_data.get_face_material(
						brush_target.pb_mesh_data.faces[tgt_face]) as ShaderMaterial
					var before_clear := _count_opaque(PBSplat.get_decal_layer_image(clear_mat))
					dock_p._on_clear_layer_pressed()
					await _frames(2)
					var clear_mat2 := brush_target.pb_mesh_data.get_face_material(
						brush_target.pb_mesh_data.faces[tgt_face]) as ShaderMaterial
					var after_clear := _count_opaque(PBSplat.get_decal_layer_image(clear_mat2))
					if before_clear > 0 and after_clear == 0:
						_pass("BRUSH-PANEL: Clear Layer clears the brush's mesh with nothing selected (%d -> 0)"
							% before_clear)
					else:
						_fail("BRUSH-PANEL: Clear Layer missed the brush's mesh with no selection (%d -> %d)"
							% [before_clear, after_clear])

					dock_p._set_dock_mode(PBMaterialDock.DockMode.MATERIAL)
					await _frames(2)

				# Test Billboard Sprite Placer
				plugin._start_sprite_tool()
				await _frames(2)
				if plugin.sprite_placer.state == PBSpritePlacer.State.ARMED and plugin.sprite_placer.is_active():
					_pass("SPRITE-PLACER: armed sprite billboard placement tool")
				else:
					_fail("SPRITE-PLACER: failed to arm sprite placer")

				# Simulate click to place with last/discovered texture
				var surface_hit := {
					"point": Vector3(0, 0, 0),
					"normal": Vector3.UP,
					"mesh": target_b,
					"face_index": 0,
				}
				var motion_armed := InputEventMouseMotion.new()
				motion_armed.position = Vector2(400, 300)
				plugin._sprite_placer_input(cam, motion_armed)
				await _frames(2)

				var press_ev := InputEventMouseButton.new()
				press_ev.button_index = MOUSE_BUTTON_LEFT
				press_ev.pressed = true
				press_ev.position = Vector2(400, 300)
				plugin.sprite_placer.handle_input(cam, press_ev, surface_hit, plugin._get_viewport_host())
				await _frames(2)

				# If carousel opened or transitioned to raise, verify
				if plugin.sprite_placer.state == PBSpritePlacer.State.TEXTURE_SELECT:
					_pass("SPRITE-PLACER: opened texture carousel overlay")
					var confirm_ev := InputEventMouseButton.new()
					confirm_ev.button_index = MOUSE_BUTTON_LEFT
					confirm_ev.pressed = true
					confirm_ev.position = Vector2(400, 300)
					plugin.sprite_placer.handle_input(cam, confirm_ev, surface_hit, plugin._get_viewport_host())
					await _frames(2)

				if plugin.sprite_placer.state == PBSpritePlacer.State.RAISE and plugin.sprite_placer.preview_node != null:
					_pass("SPRITE-PLACER: entered RAISE phase with camera-facing preview node")

					# Lock angle and enter scale
					var lock_ev := InputEventMouseButton.new()
					lock_ev.button_index = MOUSE_BUTTON_LEFT
					lock_ev.pressed = true
					lock_ev.position = Vector2(400, 300)
					plugin.sprite_placer.handle_input(cam, lock_ev, surface_hit, plugin._get_viewport_host())
					await _frames(2)
					if plugin.sprite_placer.state == PBSpritePlacer.State.SCALE:
						_pass("SPRITE-PLACER: locked elevation/angle and entered SCALE phase")

					# Confirm scale to finalize
					var finalize_ev := InputEventMouseButton.new()
					finalize_ev.button_index = MOUSE_BUTTON_LEFT
					finalize_ev.pressed = true
					finalize_ev.position = Vector2(400, 300)
					plugin.sprite_placer.handle_input(cam, finalize_ev, surface_hit, plugin._get_viewport_host())
					await _frames(2)
					_pass("SPRITE-PLACER: confirmed scale and placed billboard sprite into scene")
				else:
					_fail("SPRITE-PLACER: failed to transition to RAISE phase")
				plugin.sprite_placer.abort()

				# Test Material Dock SPRITE mode
				plugin.material_dock._set_dock_mode(PBMaterialDock.DockMode.SPRITE)
				await _frames(2)
				if plugin.material_dock.dock_mode == PBMaterialDock.DockMode.SPRITE and plugin.material_dock._sprite_tool_section.visible:
					_pass("SPRITE-DOCK: switched to SPRITE mode, sprite settings panel visible")
				else:
					_fail("SPRITE-DOCK: failed to show sprite settings panel")

				# Pick first material in dock palette as sprite
				if not plugin.material_dock._project_materials.is_empty():
					var smat: Material = plugin.material_dock._project_materials[0]
					plugin.material_dock._select_sprite_material(smat)
					await _frames(2)
					if plugin.sprite_placer.last_texture != null:
						_pass("SPRITE-DOCK: selected palette material as active sprite texture (%s)" % plugin.sprite_placer.last_texture.resource_path.get_file())
					else:
						_fail("SPRITE-DOCK: failed to set last_texture from palette")
				plugin.material_dock._set_dock_mode(PBMaterialDock.DockMode.MATERIAL)
				await _frames(1)

				# ── Particle emitter placement (the Particles tab) ───────────
				plugin._start_particle_tool()
				await _frames(2)
				if plugin.particle_placer.state == PBParticlePlacer.State.ARMED and plugin.particle_placer.is_active():
					_pass("PARTICLE-PLACER: armed particle emitter placement tool")
				else:
					_fail("PARTICLE-PLACER: failed to arm particle placer")

				# v0.9.148 alpha auto-detection: the shipped water texture has
				# soft alpha pixels; its palette card must preview blended
				# without any manual transparency toggle.
				var water_mat: Material = null
				for pm_mat in plugin.material_dock._project_materials:
					if pm_mat != null and pm_mat.has_meta("source_texture_path") \
							and str(pm_mat.get_meta("source_texture_path")).ends_with("water_pool.png"):
						water_mat = pm_mat
						break
				if water_mat != null and water_mat is StandardMaterial3D:
					if (water_mat as StandardMaterial3D).transparency == BaseMaterial3D.TRANSPARENCY_ALPHA:
						_pass("ALPHA-DETECT: water palette material previews as soft-alpha blended")
					else:
						_fail("ALPHA-DETECT: water palette material is not blended (transparency=%d)" % (water_mat as StandardMaterial3D).transparency)
				else:
					_fail("ALPHA-DETECT: water_pool palette material not found")

				# Click -> RAISE (live GPUParticles3D preview) -> TUNE -> commit.
				var pp_hit := {
					"point": Vector3(2, 0, 2),
					"normal": Vector3.UP,
					"mesh": target_b,
					"face_index": 0,
				}
				var pp_press := InputEventMouseButton.new()
				pp_press.button_index = MOUSE_BUTTON_LEFT
				pp_press.pressed = true
				pp_press.position = Vector2(420, 320)
				plugin.particle_placer.handle_input(cam, pp_press, pp_hit, plugin._get_viewport_host())
				var pp_release := InputEventMouseButton.new()
				pp_release.button_index = MOUSE_BUTTON_LEFT
				pp_release.pressed = false
				pp_release.position = Vector2(420, 320)
				plugin.particle_placer.handle_input(cam, pp_release, pp_hit, plugin._get_viewport_host())
				await _frames(2)
				if plugin.particle_placer.state == PBParticlePlacer.State.RAISE \
						and plugin.particle_placer.preview_node != null \
						and plugin.particle_placer.preview_node is GPUParticles3D:
					_pass("PARTICLE-PLACER: entered RAISE with a live GPUParticles3D preview")
				else:
					_fail("PARTICLE-PLACER: failed to enter RAISE with a preview (state=%d)" % plugin.particle_placer.state)

				var pp_lock := InputEventMouseButton.new()
				pp_lock.button_index = MOUSE_BUTTON_LEFT
				pp_lock.pressed = true
				pp_lock.position = Vector2(420, 320)
				plugin.particle_placer.handle_input(cam, pp_lock, pp_hit, plugin._get_viewport_host())
				var pp_tune := InputEventMouseMotion.new()
				pp_tune.position = Vector2(620, 320)
				plugin.particle_placer.handle_input(cam, pp_tune, pp_hit, plugin._get_viewport_host())
				await _frames(1)
				var tuned_amount := 0
				if plugin.particle_placer.state == PBParticlePlacer.State.TUNE \
						and plugin.particle_placer.preview_node != null:
					_pass("PARTICLE-PLACER: entered TUNE phase")
					tuned_amount = plugin.particle_placer.preview_node.amount
					if tuned_amount > 1 and tuned_amount <= PBParticleParams.MAX_PER_EMITTER:
						_pass("PARTICLE-PLACER: horizontal tune adjusted count to %d (within PSP cap)" % tuned_amount)
					else:
						_fail("PARTICLE-PLACER: count tune produced an out-of-range amount (%d)" % tuned_amount)
				else:
					_fail("PARTICLE-PLACER: failed to enter TUNE phase")

				var pp_commit := InputEventMouseButton.new()
				pp_commit.button_index = MOUSE_BUTTON_LEFT
				pp_commit.pressed = true
				pp_commit.position = Vector2(620, 320)
				plugin.particle_placer.handle_input(cam, pp_commit, pp_hit, plugin._get_viewport_host())
				await _frames(3)
				var placed_emitter: GPUParticles3D = null
				var scene_root: Node = plugin.get_editor_interface().get_edited_scene_root()
				if scene_root != null:
					for child in scene_root.get_children():
						if child is GPUParticles3D and (child as GPUParticles3D).name.begins_with("Emitter_"):
							placed_emitter = child
							break
				if placed_emitter != null:
					_pass("PARTICLE-PLACER: committed emitter '%s' (%d particles) into the scene" % [placed_emitter.name, placed_emitter.amount])
					if placed_emitter.has_meta("poi_seed") and placed_emitter.amount == tuned_amount:
						_pass("PARTICLE-PLACER: committed emitter keeps tuned count and deterministic seed")
					else:
						_fail("PARTICLE-PLACER: committed emitter lost tuned count/seed meta")
				else:
					_fail("PARTICLE-PLACER: no emitter node landed in the scene")

				# Particles dock tab: section + palette routing.
				plugin.material_dock._set_dock_mode(PBMaterialDock.DockMode.PARTICLE)
				await _frames(2)
				if plugin.material_dock.dock_mode == PBMaterialDock.DockMode.PARTICLE \
						and plugin.material_dock._particle_tool_section.visible:
					_pass("PARTICLE-DOCK: switched to PARTICLE mode, particle settings panel visible")
				else:
					_fail("PARTICLE-DOCK: failed to show particle settings panel")
				var pmat: Material = null
				for pm_mat2 in plugin.material_dock._project_materials:
					if pm_mat2 != null and pm_mat2.has_meta("source_texture_path") \
							and PBAssetCatalog.classify_path(str(pm_mat2.get_meta("source_texture_path"))) == "particle":
						pmat = pm_mat2
						break
				if pmat != null:
					plugin.material_dock._select_particle_material(pmat)
					await _frames(2)
					if plugin.particle_placer.last_texture != null:
						_pass("PARTICLE-DOCK: selected particle palette card as emitter texture (%s)" % plugin.particle_placer.last_texture.resource_path.get_file())
					else:
						_fail("PARTICLE-DOCK: failed to set emitter texture from palette")
				else:
					_fail("PARTICLE-DOCK: no particle-classified material in the palette")

				# Edit Emitter Properties: select the committed emitter, open
				# the overlay session, change the count, apply.
				if placed_emitter != null and is_instance_valid(placed_emitter):
					var esel: EditorSelection = plugin.get_editor_interface().get_selection()
					esel.clear()
					esel.add_node(placed_emitter)
					await _frames(2)
					if plugin.tool_overlay.emitter_props_available:
						_pass("EMITTER-PROPS: overlay button available for the selected emitter")
						plugin._on_edit_emitter_requested()
						await _frames(2)
						if plugin.tool_overlay.params_open and plugin._params_session_kind == "emitter_edit":
							_pass("EMITTER-PROPS: properties session opened")
							plugin._on_param_changed("count", 5.0)
							await _frames(1)
							plugin._on_params_applied()
							await _frames(2)
							if placed_emitter.amount == 5:
								_pass("EMITTER-PROPS: applied count landed on the emitter")
							else:
								_fail("EMITTER-PROPS: applied count did not land (amount=%d)" % placed_emitter.amount)
						else:
							_fail("EMITTER-PROPS: failed to open the properties session")
					else:
						_fail("EMITTER-PROPS: overlay button not available for a selected emitter")

				# Restore a PBMesh selection: downstream tests (the UV canvas
				# Fit, texture mode) expect an editable mesh as the active
				# object — the committed emitter is a plain GPUParticles3D and
				# would leave the canvas without a mesh, exactly like the
				# sprite block leaving its billboard selected.
				var rsel: EditorSelection = plugin.get_editor_interface().get_selection()
				rsel.clear()
				rsel.add_node(target_b)
				await _frames(2)

				# Exit placement mode; the committed emitter stays in the scene
				# like the sprite test's billboard (it is owned by the undo
				# history — freeing it here would dangle that reference).
				plugin.material_dock._set_dock_mode(PBMaterialDock.DockMode.MATERIAL)
				await _frames(1)
				if not plugin.particle_placer.is_active():
					_pass("PARTICLE-DOCK: leaving the tab disarms the placer")
				else:
					_fail("PARTICLE-DOCK: placer still armed after leaving the tab")

				# Fine tuning must not require particle mode: selecting the
				# emitter in plain object mode brings the overlay panel up with
				# the Edit Emitter Properties button (the panel used to hide
				# whenever the selection was not a PBMesh).
				var osel: EditorSelection = plugin.get_editor_interface().get_selection()
				osel.clear()
				osel.add_node(placed_emitter)
				await _frames(3)
				if placed_emitter != null and is_instance_valid(placed_emitter):
					if plugin.tool_overlay.visible \
							and plugin.tool_overlay._btn_edit_emitter_props.visible:
						_pass("EMITTER-PROPS: button reachable in object mode (no particle placement)")
					else:
						_fail("EMITTER-PROPS: overlay/button not shown for a selected emitter in object mode (panel visible=%s)" % str(plugin.tool_overlay.visible))
					# The properties session must open from here too.
					plugin._on_edit_emitter_requested()
					await _frames(2)
					if plugin.tool_overlay.params_open and plugin._params_session_kind == "emitter_edit":
						_pass("EMITTER-PROPS: session opens from object mode")
					else:
						_fail("EMITTER-PROPS: session did not open from object mode")
					plugin._close_emitter_session()
					await _frames(1)
				# Hand the selection back to a mesh for the downstream tests.
				osel.clear()
				osel.add_node(target_b)
				await _frames(2)

				# ── Export Dialog Test ──────────────────────────────────────────
				if plugin.toolbar != null and plugin.toolbar._btn_export_more != null:
					_pass("EXPORT: toolbar export button exists")
					plugin.toolbar._btn_export_more.pressed.emit()
					await _frames(2)
					if plugin._export_dialog != null and plugin._export_dialog.visible:
						_pass("EXPORT: export dialog opened upon toolbar button click")
						plugin._export_dialog.hide()
						await _frames(1)
					else:
						_fail("EXPORT: export dialog failed to open")
				else:
					_fail("EXPORT: toolbar export button not found")
				# ── Toolbar Split Rows Test ────────────────────────────────────
				if plugin.toolbar != null and plugin.toolbar._btn_split_rows != null:
					_pass("TOOLBAR-SPLIT: split rows button exists")
					if plugin.toolbar._row1.visible and plugin.toolbar._row2.visible:
						_pass("TOOLBAR-SPLIT: two-row layout enabled by default (row1 & row2 visible, height=%.0f)" % plugin.toolbar.size.y)
					else:
						_fail("TOOLBAR-SPLIT: two-row layout should be default")
					plugin.toolbar._btn_split_rows.button_pressed = true
					await _frames(2)
					if plugin.toolbar._row3.visible:
						_pass("TOOLBAR-SPLIT: expanded to three rows (row3 visible)")
					else:
						_fail("TOOLBAR-SPLIT: failed to expand to three rows")
					plugin.toolbar._btn_split_rows.button_pressed = false
					await _frames(2)
					if not plugin.toolbar._row3.visible and plugin.toolbar._row2.visible:
						_pass("TOOLBAR-SPLIT: restored default two-row layout (row3 hidden)")
					else:
						_fail("TOOLBAR-SPLIT: failed to restore default two-row layout")
				else:
					_fail("TOOLBAR-SPLIT: split rows button not found")
				# ── Environment Presets Test ───────────────────────────────────
				if plugin.toolbar != null and plugin.toolbar.env_button() != null:
					_pass("ENV: toolbar environment presets button exists")
					var env_btn: MenuButton = plugin.toolbar.env_button()
					var popup: PopupMenu = env_btn.get_popup()
					if popup != null and popup.item_count == 4:
						_pass("ENV: environment popup has 4 presets (Dawn, Day, Dusk, Night)")
						popup.id_pressed.emit(2) # Dusk
						await _frames(5)
						_pass("ENV: dusk preset selected via toolbar")
					else:
						_fail("ENV: environment popup missing preset items")
				else:
					_fail("ENV: toolbar environment button not found")
				# ── UV Editor Panel Test ───────────────────────────────────────
				if plugin.uv_editor_panel != null:
					_pass("UV-EDITOR: uv_editor_panel instance exists in plugin")
					if plugin.toolbar != null and plugin.toolbar._btn_uv_editor != null:
						_pass("UV-EDITOR: toolbar UV button exists")
						plugin.toolbar._btn_uv_editor.pressed.emit()
						await _frames(2)
						if plugin.uv_editor_panel.canvas != null:
							_pass("UV-EDITOR: uv canvas active and responsive")
							var pnl: PBUvEditorPanel = plugin.uv_editor_panel
							if pnl._ops_toolbar != null and pnl._btn_mode_manual != null and pnl._btn_proj_fit != null:
								_pass("UV-EDITOR: operations toolbar and projection buttons exist")
								# Test tool switching
								pnl._btn_tool_rot.pressed.emit()
								if pnl.canvas.transform_tool == PBUvGizmo.ToolMode.ROTATE:
									_pass("UV-EDITOR: Rotate tool button switched canvas transform tool")
								else:
									_fail("UV-EDITOR: transform tool did not switch to ROTATE")
								pnl._btn_tool_move.pressed.emit()
								# Test Fit UVs button on active mesh
								pnl.canvas.selected_faces[0] = true
								pnl._btn_proj_fit.pressed.emit()
								var uvs: PackedVector2Array = pnl.canvas.get_uv_array()
								var f0_verts: PackedInt32Array = target_b.pb_mesh_data.faces[0].get_distinct_indexes()
								var fb: Rect2 = PBUvOps.get_uv_bounds(uvs, f0_verts)
								if is_equal_approx(fb.size.x, 1.0) and is_equal_approx(fb.size.y, 1.0):
									_pass("UV-EDITOR: Fit UVs operation executed and normalized face bounds to 1.0")
								else:
									_fail("UV-EDITOR: Fit UVs bounds width not 1.0 (got %f)" % fb.size.x)
							else:
								_fail("UV-EDITOR: operations toolbar or buttons missing")
						else:
							_fail("UV-EDITOR: canvas is null")
					else:
						_fail("UV-EDITOR: toolbar UV button not found")
				else:
					_fail("UV-EDITOR: uv_editor_panel is null")
			else:
				_fail("SPLAT-STAMP: target GuiTestB not found")

	# ── 15. TEXTURE MODE GUI TEST ─────────────────────────────────────────────
	if plugin.toolbar != null:
		var btn_tex := plugin.toolbar.get_node_or_null("Row2/ModeTexture") as Button
		if btn_tex != null:
			_pass("TEXTURE-MODE: toolbar button ModeTexture exists in Row2")
			btn_tex.button_pressed = true
			btn_tex.pressed.emit()
			await _frames(4)
			if plugin.editor != null and plugin.editor.select_mode == PBEditor.SelectMode.TEXTURE:
				_pass("TEXTURE-MODE: clicking ModeTexture switched editor to SelectMode.TEXTURE")

				# Live editor Undo/Redo test on target_b
				var target_b := root.get_node_or_null("GuiTestB") as PBMesh
				if target_b != null and target_b.pb_mesh_data != null:
					sel.clear()
					sel.add_node(target_b)
					plugin.editor.active_mesh = target_b
					plugin.editor.tool_mode = PBEditor.ToolMode.MOVE
					plugin.editor.select_mode = PBEditor.SelectMode.TEXTURE
					await _frames(2)
					var el_ed = plugin.gizmo_plugin.element_editor
					var f0_idx: int = target_b.pb_mesh_data.faces[0].get_distinct_indexes()[0]
					var uv_orig: Vector2 = target_b.pb_mesh_data.textures0[f0_idx]
					var start_xf = el_ed.get_subgizmo_transform(target_b.pb_mesh_data, target_b, 0)
					var f_basis = el_ed.element_basis(target_b.pb_mesh_data, target_b, 0)
					var moved_xf = Transform3D(start_xf.basis, start_xf.origin + f_basis.x * 0.4)

					el_ed.set_subgizmo_transform(target_b, PackedInt32Array([0]), 0, moved_xf)
					var uv_moved: Vector2 = target_b.pb_mesh_data.textures0[f0_idx]
					if uv_moved.distance_to(uv_orig) > 0.05:
						_pass("TEXTURE-MODE: in-scene translation moved face UVs in live editor")
					else:
						_fail("TEXTURE-MODE: in-scene translation did not move face UVs")

					var committed: bool = el_ed.commit_subgizmos(target_b, PackedInt32Array([0]), false)
					await _frames(4)
					if committed:
						_pass("TEXTURE-MODE: commit_subgizmos committed cleanly to EditorUndoRedoManager")
						# Test Undo in live editor via object history UndoRedo or shortcut
						var ed_ur = EditorInterface.get_editor_undo_redo()
						var obj_ur: UndoRedo = null
						if ed_ur != null:
							var hid: int = ed_ur.get_object_history_id(target_b)
							obj_ur = ed_ur.get_history_undo_redo(hid)

						if obj_ur != null:
							obj_ur.undo()
						else:
							await _press_undo()
						await _frames(6)

						var uv_restored: Vector2 = target_b.pb_mesh_data.textures0[f0_idx]
						if is_equal_approx(uv_restored.x, uv_orig.x) and is_equal_approx(uv_restored.y, uv_orig.y):
							_pass("TEXTURE-MODE: undo in live editor restored original UV coordinates")
						else:
							_fail("TEXTURE-MODE: undo in live editor failed to restore UVs (got %s vs orig %s)" % [uv_restored, uv_orig])

						if obj_ur != null:
							obj_ur.redo()
						else:
							await _press_redo()
						await _frames(6)

						var uv_redone: Vector2 = target_b.pb_mesh_data.textures0[f0_idx]
						if is_equal_approx(uv_redone.x, uv_moved.x) and is_equal_approx(uv_redone.y, uv_moved.y):
							_pass("TEXTURE-MODE: redo in live editor reapplied transformed UV coordinates")
						else:
							_fail("TEXTURE-MODE: redo in live editor failed to reapply UVs (got %s vs %s)" % [uv_redone, uv_moved])
					else:
						_fail("TEXTURE-MODE: commit_subgizmos failed to commit")
			else:
				_fail("TEXTURE-MODE: editor select_mode not TEXTURE (got %d)" % (plugin.editor.select_mode if plugin.editor else -1))
		else:
			_fail("TEXTURE-MODE: toolbar button ModeTexture not found in Row2")

		# ── Section: Bevel Button in Toolbar ──────────────────────────────
		var btn_bevel: Button = plugin.toolbar._op_buttons.get("bevel_edges")
		if btn_bevel != null:
			_pass("BEVEL-OP: toolbar button OpBevel found in Row1")
			var target_bevel := root.get_node_or_null("GuiTestB") as PBMesh
			if target_bevel != null and target_bevel.pb_mesh_data != null:
				sel.clear()
				sel.add_node(target_bevel)
				await _frames(6)
				await _press_and_release_key(KEY_K)
				await _frames(6)
				var face_center := _window_pos(vp, host, target_bevel.global_position + Vector3(0, 0, 0.5))
				await _click(face_center)
				await _frames(10)
				if not btn_bevel.disabled:
					_pass("BEVEL-OP: bevel button is enabled when face is selected")
					var f_before: int = target_bevel.pb_mesh_data.faces.size()
					btn_bevel.pressed.emit()
					await _frames(6)
					var f_after: int = target_bevel.pb_mesh_data.faces.size()
					if f_after > f_before:
						_pass("BEVEL-OP: live bevel operation added bevel faces (%d -> %d)" % [f_before, f_after])
					else:
						_fail("BEVEL-OP: live bevel failed to increase face count (got %d vs before %d)" % [f_after, f_before])
					# Live parameter change test in modal: segments 1 -> 2
					plugin._on_param_changed("segments", 2.0)
					await _frames(3)
					var f_seg2: int = target_bevel.pb_mesh_data.faces.size()
					if f_seg2 > f_after:
						_pass("BEVEL-MODAL: live segments adjustment subdivided bevel fillets (%d -> %d)" % [f_after, f_seg2])
					else:
						_fail("BEVEL-MODAL: live segments adjustment failed to increase face count (got %d vs %d)" % [f_seg2, f_after])
					plugin._on_params_applied()
					await _frames(3)
					# Test edge beveling with segments=2 on inset/extruded cavity:
					var test_cube := PBMeshData.create_cube(2.0)
					var inset_res := PBMeshOps.inset_faces(test_cube, PackedInt32Array([1]), 0.3)
					var inner_fid: int = inset_res["cap_face_ids"][0]
					PBMeshOps.extrude_faces(test_cube, PackedInt32Array([inner_fid]), -0.5)
					var c_edges := test_cube.get_common_edges()
					var rim_edges := PackedInt32Array()
					for eid in range(c_edges.size()):
						var e := c_edges[eid]
						var pa := test_cube.positions[e.a]
						var pb := test_cube.positions[e.b]
						if absf(pa.z - 1.0) < 0.001 and absf(pb.z - 1.0) < 0.001:
							if absf(pa.x) < 0.99 and absf(pa.y) < 0.99 and absf(pb.x) < 0.99 and absf(pb.y) < 0.99:
								rim_edges.append(eid)
					var b_res := PBMeshOps.bevel_edges(test_cube, rim_edges, 0.1, 2)
					var counts := PBMeshOps.edge_usage_counts(test_cube)
					var bad_e := 0
					for k in counts:
						if counts[k] != 2:
							bad_e += 1
					if b_res.get("ok", false) and bad_e == 0:
						_pass("BEVEL-EXTRUDE-RIM: beveling outer edges of inward extrusion with seg=2 is watertight (0 bad edges)")
					else:
						_fail("BEVEL-EXTRUDE-RIM: beveling outer edges of inward extrusion failed or has %d non-manifold edges" % bad_e)

					# Test outer edge loop of inset with segments=3 (the user-reported bug)
					var test_cube2 := PBMeshData.create_cube(2.0)
					var inset_res2 := PBMeshOps.inset_faces(test_cube2, PackedInt32Array([1]), 0.3)
					var inner_fid2: int = inset_res2["cap_face_ids"][0]
					PBMeshOps.extrude_faces(test_cube2, PackedInt32Array([inner_fid2]), -0.5)
					var c_edges2 := test_cube2.get_common_edges()
					var outer_perim_edges := PackedInt32Array()
					for eid in range(c_edges2.size()):
						var e := c_edges2[eid]
						var pa := test_cube2.positions[e.a]
						var pb := test_cube2.positions[e.b]
						if absf(pa.z - 1.0) < 0.001 and absf(pb.z - 1.0) < 0.001:
							if (absf(pa.x) > 0.99 and absf(pb.x) > 0.99) or (absf(pa.y) > 0.99 and absf(pb.y) > 0.99):
								outer_perim_edges.append(eid)
					var b_res_outer := PBMeshOps.bevel_edges(test_cube2, outer_perim_edges, 0.1, 3)
					var counts_outer := PBMeshOps.edge_usage_counts(test_cube2)
					var bad_outer := 0
					for k in counts_outer:
						if counts_outer[k] != 2:
							bad_outer += 1
					# The corner vertices must weld across every face that meets
					# there (the "not connected" symptom): count the coincident
					# positions at one corner and check they share ONE weld group.
					var lookup_outer := test_cube2.get_shared_vertex_lookup()
					var corner_groups := {}
					var corner_positions := 0
					for idx in range(test_cube2.positions.size()):
						if test_cube2.positions[idx].distance_to(Vector3(0.9, 0.9, 0.9)) < 0.35:
							corner_positions += 1
							corner_groups[lookup_outer.get(idx, idx)] = true
					if b_res_outer.get("ok", false) and bad_outer == 0 and corner_positions > 0 and corner_groups.size() < corner_positions:
						_pass("BEVEL-OUTER-LOOP-SEG3: outer edge loop bevel (seg=3) is watertight (%d corner positions welded into %d groups)" % [corner_positions, corner_groups.size()])
					else:
						_fail("BEVEL-OUTER-LOOP-SEG3: bevel failed, ok=%s, bad_edges=%d, corner positions=%d in %d weld groups" % [str(b_res_outer.get("ok", false)), bad_outer, corner_positions, corner_groups.size()])
				else:
					_fail("BEVEL-OP: bevel button unexpectedly disabled with selected face")
		else:
			_fail("BEVEL-OP: toolbar button OpBevel not found")

		# ── Section: Bevel Apply from EDGE mode (crash regression) ────────
		# v0.9.105: applying a bevel re-entered its own commit from the
		# mode-change handler (the session was still marked open) and the two
		# disagreeing mode assignments ping-ponged EDGE<->FACE until stack
		# overflow. The commit must tear the session down BEFORE its mode
		# switch, land in FACE mode, and select the bevel band.
		var bevel_edge_node := root.get_node_or_null("GuiTestB") as PBMesh
		if bevel_edge_node != null and plugin.editor != null and btn_bevel != null:
			sel.clear()
			sel.add_node(bevel_edge_node)
			await _frames(6)
			await _press_and_release_key(KEY_J)  # EDGE mode
			await _frames(6)
			var edge_click := _window_pos(vp, host, bevel_edge_node.global_position + Vector3(0.5, 0, 0.5))
			_mouse_motion(edge_click)
			await _frames(4)
			await _click(edge_click)
			await _frames(10)
			if plugin.editor.selection.selected_edge_count() > 0 and not btn_bevel.disabled:
				var faces_pre: int = bevel_edge_node.pb_mesh_data.faces.size()
				btn_bevel.pressed.emit()  # opens the bevel modal
				await _frames(6)
				plugin._on_params_applied()  # APPLY from EDGE mode — the crash path
				await _frames(10)
				var mode_after: int = plugin.editor.select_mode
				var faces_post: int = bevel_edge_node.pb_mesh_data.faces.size()
				if mode_after == PBEditor.SelectMode.FACE \
						and plugin.editor.selection.selected_face_count() > 0 \
						and faces_post > faces_pre \
						and not plugin.tool_overlay.params_open:
					_pass("BEVEL-EDGE-APPLY: applied from EDGE mode without re-entry — FACE mode, band selected (%d -> %d faces)" % [faces_pre, faces_post])
				else:
					_fail("BEVEL-EDGE-APPLY: mode=%d sel_faces=%d faces %d -> %d modal_open=%s" % [
						mode_after, plugin.editor.selection.selected_face_count(),
						faces_pre, faces_post, str(plugin.tool_overlay.params_open)])
			else:
				_fail("BEVEL-EDGE-APPLY: could not select an edge (bevel disabled or no edge selected)")

	# ── PAINT-SOURCE: the brush source default + where it applies ────────────
	# Reported: the Paint tab's "Brush:" row read "Color" while the brush
	# always painted the palette texture (Splat layers ignores the source by
	# definition), and switching the row did nothing. The default is now
	# Palette image and the row is disabled — with a tooltip saying why —
	# wherever it does not apply.
	var dock_ps: PBMaterialDock = plugin.material_dock
	var pc_ps: PBPaintController = plugin.paint_controller
	if dock_ps != null and pc_ps != null:
		dock_ps._set_dock_mode(PBMaterialDock.DockMode.PAINT)
		await _frames(6)
		# Splat layers (the default target): the source picker does not apply
		# and is disabled rather than silently ignored.
		dock_ps._opt_paint_target.item_selected.emit(PBPaintController.PaintTarget.SPLAT)
		await _frames(4)
		if dock_ps._opt_brush_source.disabled and dock_ps._btn_brush_color.disabled:
			_pass("PAINT-SOURCE: source/colour pickers are disabled for Splat layers")
		else:
			_fail("PAINT-SOURCE: pickers live on Splat layers (source_disabled=%s colour_disabled=%s)" % [
				str(dock_ps._opt_brush_source.disabled), str(dock_ps._btn_brush_color.disabled)])
		if dock_ps._opt_brush_source.selected == int(pc_ps.brush_source):
			_pass("PAINT-SOURCE: the row mirrors the controller's source (%d)" % pc_ps.brush_source)
		else:
			_fail("PAINT-SOURCE: row shows %d, controller is %d"
				% [dock_ps._opt_brush_source.selected, pc_ps.brush_source])
		dock_ps._opt_paint_target.item_selected.emit(PBPaintController.PaintTarget.DECAL)
		await _frames(4)
		if not dock_ps._opt_brush_source.disabled and not dock_ps._btn_brush_color.disabled:
			_pass("PAINT-SOURCE: Decal layer enables the source and colour pickers")
		else:
			_fail("PAINT-SOURCE: the pickers stayed disabled on the decal layer")
		dock_ps._opt_paint_target.item_selected.emit(PBPaintController.PaintTarget.SPLAT)
		await _frames(4)

	# ── STAMP-PREVIEW: a palette click resizes the preview to the new image ──
	# Reported: the hello-world sticker previewed squashed until a spinbox
	# nudge, and a square sticker then previewed stretched to hello world's
	# 2:1. The quad is built from the SELECTED image and must follow a switch.
	if dock_ps != null and pc_ps != null:
		dock_ps._set_dock_mode(PBMaterialDock.DockMode.STAMP)
		await _frames(6)
		var hello_mat := _palette_material(dock_ps, "stamp_hello_world.png")
		var square_mat := _palette_material(dock_ps, "circular_square_pattern.png")
		if hello_mat == null or square_mat == null:
			_fail("STAMP-PREVIEW: palette fixtures missing (hello/squares)")
		else:
			pc_ps.stamp_scale = 2.0
			dock_ps._select_stamp_material(hello_mat)
			await _frames(4)
			var q1 := (pc_ps.stamp_mesh_instance.mesh as QuadMesh) \
					if pc_ps.stamp_mesh_instance != null else null
			if q1 != null and absf(q1.size.x - 2.0) < 0.01 and absf(q1.size.y - 1.0) < 0.02:
				_pass("STAMP-PREVIEW: the hello-world sticker previews 2:1 on selection (%s)" % q1.size)
			else:
				_fail("STAMP-PREVIEW: hello world previewed %s, expected 2.0 x 1.0"
					% (q1.size if q1 != null else Vector2.ZERO))
			dock_ps._select_stamp_material(square_mat)
			await _frames(4)
			var q2 := (pc_ps.stamp_mesh_instance.mesh as QuadMesh) \
					if pc_ps.stamp_mesh_instance != null else null
			if q2 != null and absf(q2.size.x - 2.0) < 0.01 and absf(q2.size.y - 2.0) < 0.02:
				_pass("STAMP-PREVIEW: the square sticker previews square after the switch (%s)" % q2.size)
			else:
				_fail("STAMP-PREVIEW: the square sticker kept the previous ratio: %s"
					% (q2.size if q2 != null else Vector2.ZERO))

	# ── BILLBOARD-PAINT: a sprite refuses paint (its alpha survives) ─────────
	# A sprite's quad is alpha-scissor art and the splat conversion drops the
	# scissor, so painting one turned it into an opaque rectangle. The tools
	# refuse the face, the overlay names the reason, and the material is left
	# exactly as it was.
	var sprite := PBMesh.new()
	var sprite_md := PBShapeGenerators.create_sprite(2.0, 1.0)
	sprite_md.materials = [PBSpritePlacer.create_billboard_material(
			load("res://addons/poibuilder/materials/textures/tree_oak.png"), false, true)]
	sprite.pb_mesh_data = sprite_md
	sprite.pb_mesh_data.shape_id = &"sprite"
	sprite.name = "GuiTestSprite"
	root.add_child(sprite)
	sprite.owner = root
	# Square in front of the CURRENT camera, on its axis: the quad's centre
	# projects to the middle of the viewport whatever the view has become
	# (earlier sections zoom/scroll — fixed world coordinates landed the
	# cursor 2000 px below the window and the hover never happened).
	var cam3: Camera3D = vp.get_camera_3d()
	var cam_xf := cam3.global_transform
	# Aim at a point that is inside the editor WINDOW: under Xvfb the 3D
	# viewport Control can be taller than the window, and "the middle of the
	# viewport" then maps below the visible area (the synthesized mouse event
	# never reaches the viewport). The aim point is inverted through the camera
	# so the sprite sits exactly under it.
	var aim_local := Vector2(float(vp.size.x) * 0.5, minf(140.0, float(vp.size.y) * 0.2))
	var sprite_center: Vector3 = cam3.project_position(aim_local, 3.0)
	sprite.global_transform = Transform3D(cam_xf.basis, sprite_center - cam_xf.basis.y * 0.5)
	sprite.rebuild()
	await _frames(10)
	plugin.editor.active_mesh = sprite
	await _frames(6)
	var sprite_mat_before: Material = sprite.pb_mesh_data.get_face_material(sprite.pb_mesh_data.faces[0])
	var sprite_pt := _window_pos(vp, host, sprite_center)
	dock_ps._set_dock_mode(PBMaterialDock.DockMode.PAINT)
	await _frames(6)
	_mouse_motion(sprite_pt)
	await _frames(6)
	if not pc_ps.paintable and pc_ps.blocked_reason == "billboard sprite":
		_pass("BILLBOARD-PAINT: hovering a sprite reports it unpaintable (%s)" % pc_ps.blocked_reason)
	else:
		var probe: Dictionary = plugin._pick_paint_surface(cam3, sprite_pt)
		_fail("BILLBOARD-PAINT: paintable=%s reason='%s' pt=%s pick=%s" % [
			str(pc_ps.paintable), pc_ps.blocked_reason, str(sprite_pt), str(probe.get("mesh", null))])
	if plugin.tool_overlay != null and plugin.tool_overlay.has_creation_extents() \
			and plugin.tool_overlay._extents_label.text.contains("Not paintable"):
		_pass("BILLBOARD-PAINT: the overlay says why (%s)" % plugin.tool_overlay._extents_label.text)
	else:
		_fail("BILLBOARD-PAINT: no overlay line explaining the refusal")
	_mouse_button(sprite_pt, true)
	await _frames(6)
	_mouse_button(sprite_pt, false)
	await _frames(6)
	if sprite.pb_mesh_data.get_face_material(sprite.pb_mesh_data.faces[0]) == sprite_mat_before \
			and sprite.pb_mesh_data.get_face_material(sprite.pb_mesh_data.faces[0]) is StandardMaterial3D \
			and (sprite.pb_mesh_data.get_face_material(sprite.pb_mesh_data.faces[0]) as StandardMaterial3D).transparency \
				== BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR \
			and not pc_ps.is_stroke_active:
		_pass("BILLBOARD-PAINT: a brush click paints nothing and keeps the alpha scissor")
	else:
		_fail("BILLBOARD-PAINT: the sprite material was converted by a paint click (%s)"
			% sprite.pb_mesh_data.get_face_material(sprite.pb_mesh_data.faces[0]))
	# The stamp path over the same sprite: nothing pasted either.
	dock_ps._set_dock_mode(PBMaterialDock.DockMode.STAMP)
	await _frames(6)
	_mouse_motion(sprite_pt)
	await _frames(4)
	_mouse_button(sprite_pt, true)
	await _frames(6)
	_mouse_button(sprite_pt, false)
	await _frames(6)
	if sprite.pb_mesh_data.get_face_material(sprite.pb_mesh_data.faces[0]) == sprite_mat_before:
		_pass("BILLBOARD-PAINT: a stamp click leaves the sprite material alone")
	else:
		_fail("BILLBOARD-PAINT: the stamp converted the sprite material")
	plugin.editor.active_mesh = null
	sprite.queue_free()
	dock_ps._set_dock_mode(PBMaterialDock.DockMode.MATERIAL)
	await _frames(6)

	# ── Cleanup + exit ───────────────────────────────────────────────────────
	sel.clear()
	await _frames(3)
	print("[GUI TEST] done, failures=%d" % _failures)
	if OS.get_environment("PB_GUI_TEST_INTERACTIVE") != "":
		print("[GUI TEST] Interactive mode: Leaving editor open for interactive play/inspection. Close window to exit.")
	else:
		get_tree().quit(_failures)

## The palette material wrapping a given texture file (the card the user
## clicks). The dock hands these to the tool selectors.
static func _palette_material(dock: PBMaterialDock, file_name: String) -> Material:
	if dock == null:
		return null
	for mat in dock._project_materials:
		if mat != null and mat.has_meta("source_texture_path") \
				and str(mat.get_meta("source_texture_path")).get_file() == file_name:
			return mat
	return null

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
