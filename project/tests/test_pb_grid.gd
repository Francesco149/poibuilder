## PoiBuilder's own grid + snapping: PBGrid math, the rebindable action
## table (PBActions), and the two application points — shape creation
## (PBShapeCreator) and element drags (PBElementEditor).
##
## The model (ProBuilder parity):
## - move drags snap the translation DELTA per world component,
## - rotate drags snap the delivered angle to the rotate step (15°),
## - extrude gestures snap the cap distance along the extrude normal,
## - scale and inset stay unsnapped,
## - creation snaps the press point (cardinal surfaces, normal axis masked),
##   the base extents, and the height drag.
extends GutTest

# ==============================================================================
# PBGrid math
# ==============================================================================

func test_grid_step_is_unit_over_subdivisions():
	var g := PBGrid.new()
	assert_almost_eq(g.step(), 0.2, 0.000001, "default: 1m / 5 subdivisions = 0.2m")
	g.subdivisions = 4
	assert_almost_eq(g.step(), 0.25, 0.000001)
	g.unit = 2.0
	assert_almost_eq(g.step(), 0.5, 0.000001)

func test_snap_val_quantizes_to_nearest_step():
	var g := PBGrid.new()
	assert_almost_eq(g.snap_val(0.13), 0.2, 0.0001)
	assert_almost_eq(g.snap_val(-0.13), -0.2, 0.0001)
	assert_almost_eq(g.snap_val(0.09), 0.0, 0.0001)
	assert_almost_eq(g.snap_val(0.31), 0.4, 0.0001)

func test_snap_val_passes_through_when_disabled():
	var g := PBGrid.new()
	g.enabled = false
	assert_almost_eq(g.snap_val(0.13), 0.13, 0.000001)
	assert_true(g.snap_point(Vector3(0.13, 0, 0.26)).is_equal_approx(Vector3(0.13, 0, 0.26)))

func test_snap_point_offsets_by_origin_elevation():
	var g := PBGrid.new()
	g.origin = Vector3(0, 0.6, 0)
	var p := g.snap_point(Vector3(0.13, 0.63, -0.26))
	# y snaps relative to the elevated origin (0.6 + k·0.2)
	assert_almost_eq(p.x, 0.2, 0.0001)
	assert_almost_eq(p.y, 0.6, 0.0001, "offset snaps relative to elevation")
	assert_almost_eq(p.z, -0.2, 0.0001)

func test_snap_point_masked_keeps_wall_plane_coordinate():
	var g := PBGrid.new()
	# A wall at x = 3.35: drawing on it snaps y/z but never yanks x to the grid.
	var p := g.snap_point_masked(Vector3(3.35, 0.09, 0.11), Vector3.RIGHT)
	assert_almost_eq(p.x, 3.35, 0.0001)
	assert_almost_eq(p.y, 0.0, 0.0001)
	assert_almost_eq(p.z, 0.2, 0.0001)

func test_is_cardinal():
	assert_true(PBGrid.is_cardinal(Vector3.UP))
	assert_true(PBGrid.is_cardinal(Vector3.LEFT))
	assert_false(PBGrid.is_cardinal(Vector3(1, 1, 0.3).normalized()))

func test_elevation_raise_lower_reset():
	var g := PBGrid.new()
	watch_signals(g)
	g.raise()
	assert_almost_eq(g.elevation(), 0.2, 0.0001)
	g.raise()
	g.lower()
	assert_almost_eq(g.elevation(), 0.2, 0.0001)
	g.reset_origin()
	assert_eq(g.origin, Vector3.ZERO)
	assert_signal_emit_count(g, "changed", 4)

func test_unit_and_subdivision_adjustments_clamp():
	var g := PBGrid.new()
	g.subdivisions = 1
	g.subdivisions_down()
	assert_eq(g.subdivisions, 1, "subdivisions clamps at 1")
	g.unit_up()
	g.unit_up()
	assert_almost_eq(g.unit, 4.0, 0.0001)
	g.unit_down()
	assert_almost_eq(g.unit, 2.0, 0.0001)

func test_snap_local_delta_identity_basis():
	var g := PBGrid.new()
	var d := g.snap_local_delta(Basis(), Vector3(0.13, 0, -0.34))
	assert_almost_eq(d.x, 0.2, 0.0001)
	assert_almost_eq(d.z, -0.4, 0.0001)

func test_snap_local_delta_rotated_basis_snaps_in_world():
	# A node rotated -90° about Y: its local +X is world -Z. The delta must
	# quantize against the WORLD grid, and come back in local axes.
	var g := PBGrid.new()
	var basis := Basis(Vector3.UP, deg_to_rad(-90.0))
	var d := g.snap_local_delta(basis, Vector3(0.13, 0, 0))
	assert_almost_eq(d.x, 0.2, 0.0001, "0.13 local-X (= world -Z) snaps to 0.2")

func test_snap_rotation_quantizes_angle():
	var g := PBGrid.new()
	var b := g.snap_rotation(Basis(Vector3.UP, deg_to_rad(20.0)))
	var q := b.get_rotation_quaternion()
	assert_almost_eq(rad_to_deg(q.get_angle()), 15.0, 0.001, "20° rounds to 15°")
	assert_true(q.get_axis().normalized().is_equal_approx(Vector3.UP),
		"rotation axis preserved")

func test_snap_rotation_identity_passes():
	var g := PBGrid.new()
	assert_true(g.snap_rotation(Basis()).is_equal_approx(Basis()))

# ==============================================================================
# PBActions (rebindable keybinds)
# ==============================================================================

func _key(k: Key, ctrl := false, shift := false, alt := false) -> InputEventKey:
	var e := InputEventKey.new()
	e.pressed = true
	e.physical_keycode = k
	e.ctrl_pressed = ctrl
	e.shift_pressed = shift
	e.alt_pressed = alt
	return e

func test_action_defaults_match():
	assert_eq(String(PBActions.action_for(_key(KEY_H))), "select_vertex")
	assert_eq(String(PBActions.action_for(_key(KEY_J))), "select_edge")
	assert_eq(String(PBActions.action_for(_key(KEY_K))), "select_face")
	assert_eq(String(PBActions.action_for(_key(KEY_X))), "cycle_space")
	assert_eq(String(PBActions.action_for(_key(KEY_Y))), "toggle_snap")
	assert_eq(String(PBActions.action_for(_key(KEY_G))), "toggle_on_grid")
	assert_eq(String(PBActions.action_for(_key(KEY_EQUAL))), "subdiv_increase")
	assert_eq(String(PBActions.action_for(_key(KEY_MINUS))), "subdiv_decrease")
	assert_eq(String(PBActions.action_for(_key(KEY_EQUAL, false, true))), "unit_increase")
	assert_eq(String(PBActions.action_for(_key(KEY_MINUS, false, true))), "unit_decrease")
	assert_eq(String(PBActions.action_for(_key(KEY_BRACKETLEFT))), "grid_lower")
	assert_eq(String(PBActions.action_for(_key(KEY_BRACKETRIGHT))), "grid_raise")
	assert_eq(String(PBActions.action_for(_key(KEY_BACKSLASH))), "grid_reset")
	assert_eq(String(PBActions.action_for(_key(KEY_E, false, false, true))), "op_extrude")
	assert_eq(String(PBActions.action_for(_key(KEY_I, false, false, true))), "op_inset")

func test_action_modifiers_are_exact():
	# Modifiers must match the binding exactly: bare/spec'd combos distinct.
	assert_eq(String(PBActions.action_for(_key(KEY_EQUAL, false, true))), "unit_increase")
	assert_eq(String(PBActions.action_for(_key(KEY_H, true))), "", "Ctrl+H is not Vertex mode")

func test_unknown_and_unbound_keys_match_nothing():
	assert_eq(String(PBActions.action_for(_key(KEY_F))), "", "F stays the engine's focus")
	assert_eq(String(PBActions.action_for(_key(KEY_Z))), "")
	# Unbound actions exist but match nothing:
	assert_eq(String(PBActions.action_for(_key(KEY_U))), "")

func test_op_action_mapping():
	assert_eq(PBActions.OP_ACTION_TO_OPERATION["op_extrude"], "extrude_faces")
	assert_eq(PBActions.OP_ACTION_TO_OPERATION["op_inset"], "inset_faces")

func test_unpressed_and_echo_events_never_match():
	var e := _key(KEY_H)
	e.pressed = false
	assert_eq(String(PBActions.action_for(e)), "")
	var echo := _key(KEY_H)
	echo.echo = true
	assert_eq(String(PBActions.action_for(echo)), "")

class FakeEditorSettings:
	var shortcuts: Dictionary = {}
	func add_shortcut(path: String, sc: Shortcut) -> void:
		shortcuts[path] = sc
	func has_shortcut(path: String) -> bool:
		return shortcuts.has(path)
	func get_shortcut(path: String) -> Shortcut:
		return shortcuts.get(path, null)
	func get_shortcut_list() -> PackedStringArray:
		return PackedStringArray(shortcuts.keys())
	func is_shortcut(path: String, event: InputEvent) -> bool:
		var sc: Shortcut = shortcuts.get(path, null)
		return sc != null and sc.matches_event(event)

func test_unbind_conflicting_stock_shortcuts():
	var settings := FakeEditorSettings.new()
	var h_sc := Shortcut.new()
	var h_ev := _key(KEY_H)
	h_sc.events = [h_ev]
	settings.add_shortcut("editor/toggle_selected_nodes_visibility", h_sc)

	var rbrac_sc := Shortcut.new()
	var rbrac_ev := _key(KEY_BRACKETRIGHT)
	rbrac_sc.events = [rbrac_ev]
	settings.add_shortcut("animation_editor/move_last_selected_key_to_cursor", rbrac_sc)

	var lbrac_sc := Shortcut.new()
	var lbrac_ev := _key(KEY_BRACKETLEFT)
	lbrac_sc.events = [lbrac_ev]
	settings.add_shortcut("animation_editor/move_first_selected_key_to_cursor", lbrac_sc)

	var save_sc := Shortcut.new()
	var save_ev := InputEventKey.new()
	save_ev.physical_keycode = KEY_S
	save_ev.ctrl_pressed = true
	save_sc.events = [save_ev]
	settings.add_shortcut("scene/save", save_sc)

	var logger := PBLogger.new()
	var unbound := PBActions.unbind_conflicts(settings, logger)
	assert_eq(unbound.size(), 3)
	assert_true(h_sc.events.is_empty(), "H shortcut was unbound")
	assert_true(rbrac_sc.events.is_empty(), "] shortcut was unbound")
	assert_true(lbrac_sc.events.is_empty(), "[ shortcut was unbound")
	assert_eq(save_sc.events.size(), 1, "Ctrl+S remained untouched")

	PBActions.register(settings, logger)
	assert_true(settings.has_shortcut("poibuilder/select_vertex"))
	assert_true(settings.has_shortcut("poibuilder/grid_raise"))
	assert_true(settings.has_shortcut("poibuilder/grid_lower"))
	assert_eq(String(PBActions.action_for(h_ev, settings)), "select_vertex")
	assert_eq(String(PBActions.action_for(rbrac_ev, settings)), "grid_raise")
	assert_eq(String(PBActions.action_for(lbrac_ev, settings)), "grid_lower")
# ==============================================================================
# Creation snapping (PBShapeCreator + PBGrid)
# ==============================================================================

func test_creator_press_snaps_on_cardinal_floor():
	var c := PBShapeCreator.new()
	c.grid = PBGrid.new()
	c.arm(&"cube")
	c.begin(Vector3(0.13, 0, 0.26), Vector3.UP, Vector3(0, 0, 1))
	assert_almost_eq(c.base_start.x, 0.2, 0.0001)
	assert_almost_eq(c.base_start.z, 0.2, 0.0001, "press point snaps to the grid")
	assert_almost_eq(c.base_start.y, 0.0, 0.0001, "plane axis keeps the surface height")

func test_creator_press_masked_on_wall():
	var c := PBShapeCreator.new()
	c.grid = PBGrid.new()
	c.arm(&"cube")
	c.begin(Vector3(3.35, 0.09, 0.11), Vector3.RIGHT, Vector3(0, 0, 1))
	assert_almost_eq(c.base_start.x, 3.35, 0.0001, "wall x stays exact (masked)")
	assert_almost_eq(c.base_start.y, 0.0, 0.0001)
	assert_almost_eq(c.base_start.z, 0.2, 0.0001)

func test_creator_press_exact_on_non_cardinal_surface():
	var c := PBShapeCreator.new()
	c.grid = PBGrid.new()
	c.arm(&"cube")
	var n := Vector3(1, 1, 0.4).normalized()
	c.begin(Vector3(0.13, 0.26, 0.35), n, Vector3(0, 0, 1))
	assert_almost_eq(c.base_start.x, 0.13, 0.0001, "arbitrary surfaces keep the exact press point")

func test_creator_base_extents_snap():
	var c := PBShapeCreator.new()
	c.grid = PBGrid.new()
	c.arm(&"cube")
	# With the camera looking down -Z the drag's u axis seeds to world -Z:
	# the -Z extent is u, the +X extent is v.
	c.begin(Vector3.ZERO, Vector3.UP, Vector3(0, 0, 1))
	c.update_base(Vector3(0.31, 0, -0.74))
	assert_almost_eq(c.u_size, 0.8, 0.0001, "u extent (-Z: 0.74) quantizes to 0.8")
	assert_almost_eq(c.v_size, 0.4, 0.0001, "v extent (+X: 0.31) quantizes to 0.4")

func test_creator_height_snaps():
	var c := PBShapeCreator.new()
	c.grid = PBGrid.new()
	c.arm(&"cube")
	c.begin(Vector3.ZERO, Vector3.UP, Vector3(0, 0, 1))
	c.update_base(Vector3(0.6, 0, 0.6))
	assert_true(c.end_base(), "0.6 x 0.6 base is big enough")
	c.update_height_point(Vector3(0, 0.33, 0))
	assert_almost_eq(c.height, 0.4, 0.0001)

func test_creator_unsnapped_when_grid_disabled():
	var c := PBShapeCreator.new()
	c.grid = PBGrid.new()
	c.grid.enabled = false
	c.arm(&"cube")
	c.begin(Vector3(0.13, 0, 0.26), Vector3.UP, Vector3(0, 0, 1))
	assert_almost_eq(c.base_start.x, 0.13, 0.0001)
	# The press point stays exact, so the extents measure from there.
	c.update_base(c.base_start + Vector3(0.31, 0, -0.74))
	assert_almost_eq(c.u_size + c.v_size, 1.05, 0.0001, "extents pass through exactly")

func test_creator_press_on_elevated_grid():
	var c := PBShapeCreator.new()
	c.grid = PBGrid.new()
	c.grid.origin = Vector3(0, 0.6, 0)
	c.arm(&"cube")
	c.begin(Vector3(0.13, 0.6, 0.26), Vector3.UP, Vector3(0, 0, 1))
	assert_almost_eq(c.base_start.y, 0.6, 0.0001, "elevation preserved (y masked)")
	assert_almost_eq(c.base_start.x, 0.2, 0.0001)

# ==============================================================================
# Element drag snapping (PBElementEditor + PBGrid)
# ==============================================================================

var _camera: Camera3D

func before_each() -> void:
	# Element drags need a live camera only for the EXTRUDE mouse-verification
	# path; headless tests stay on the engine-rel path (mouse never tracked).
	_camera = null

func _make_setup(mode: PBEditor.SelectMode, tool: PBEditor.ToolMode) -> Dictionary:
	var ed := PBEditor.new()
	ed.tool_mode = tool
	var logic := PBElementEditor.new()
	logic.editor = ed
	logic.grid = PBGrid.new()
	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)
	ed.active_mesh = mesh
	ed.select_mode = mode
	return {"ed": ed, "logic": logic, "mesh": mesh}

func _face_id_by_normal(md: PBMeshData, n: Vector3) -> int:
	for i in range(md.faces.size()):
		var fn := PBMath.normal_from_positions(md.positions, md.faces[i].get_indexes())
		if fn.dot(n) > 0.99:
			return i
	return -1

func _drag_face_to(s: Dictionary, face_id: int, target: Transform3D, shift := false) -> void:
	## Drives the engine delivery protocol: one absolute target per id.
	var logic: PBElementEditor = s["logic"]
	var mesh: PBMesh = s["mesh"]
	var ids := PackedInt32Array([face_id])
	logic.set_subgizmo_transform_with_shift(mesh, ids, face_id, target, shift)
	logic.commit_subgizmos(mesh, ids, false)

func test_move_drag_delta_snaps_to_step():
	var s := _make_setup(PBEditor.SelectMode.FACE, PBEditor.ToolMode.MOVE)
	var mesh: PBMesh = s["mesh"]
	var top := _face_id_by_normal(mesh.pb_mesh_data, Vector3.UP)
	assert_true(top >= 0)
	var logic: PBElementEditor = s["logic"]
	var start := logic.get_subgizmo_transform(mesh.pb_mesh_data, mesh, top)
	var before: PackedVector3Array = mesh.pb_mesh_data.positions.duplicate()
	_drag_face_to(s, top, start.translated(Vector3(0.13, 0, 0)))
	for idx in logic.element_indices(mesh.pb_mesh_data, top):
		assert_almost_eq(mesh.pb_mesh_data.positions[idx].x - before[idx].x, 0.2, 0.0001,
			"0.13 drag snaps to a 0.2 step")
		assert_almost_eq(mesh.pb_mesh_data.positions[idx].y - before[idx].y, 0.0, 0.0001)

func test_move_drag_unsnapped_when_disabled():
	var s := _make_setup(PBEditor.SelectMode.FACE, PBEditor.ToolMode.MOVE)
	var mesh: PBMesh = s["mesh"]
	var top := _face_id_by_normal(mesh.pb_mesh_data, Vector3.UP)
	var logic: PBElementEditor = s["logic"]
	logic.grid.enabled = false
	var start := logic.get_subgizmo_transform(mesh.pb_mesh_data, mesh, top)
	var before: PackedVector3Array = mesh.pb_mesh_data.positions.duplicate()
	_drag_face_to(s, top, start.translated(Vector3(0.13, 0, 0)))
	for idx in logic.element_indices(mesh.pb_mesh_data, top):
		assert_almost_eq(mesh.pb_mesh_data.positions[idx].x - before[idx].x, 0.13, 0.0001)

func test_rotate_drag_snaps_to_15_degrees():
	var s := _make_setup(PBEditor.SelectMode.FACE, PBEditor.ToolMode.ROTATE)
	var mesh: PBMesh = s["mesh"]
	var top := _face_id_by_normal(mesh.pb_mesh_data, Vector3.UP)
	var logic: PBElementEditor = s["logic"]
	var start := logic.get_subgizmo_transform(mesh.pb_mesh_data, mesh, top)
	var before: PackedVector3Array = mesh.pb_mesh_data.positions.duplicate()
	# A 20° delivery lands on the nearest 15° mark.
	var rot := Transform3D(Basis(Vector3.UP, deg_to_rad(20.0)) * start.basis, start.origin)
	_drag_face_to(s, top, rot)
	var expected := Basis(Vector3.UP, deg_to_rad(15.0))
	for idx in logic.element_indices(mesh.pb_mesh_data, top):
		var want := expected * before[idx]
		var got: Vector3 = mesh.pb_mesh_data.positions[idx]
		assert_true(got.distance_to(want) < 0.001,
			"corner at %s should rotate to %s" % [str(got), str(want)])

func test_extrude_cap_distance_snaps():
	var s := _make_setup(PBEditor.SelectMode.FACE, PBEditor.ToolMode.MOVE)
	var mesh: PBMesh = s["mesh"]
	var top := _face_id_by_normal(mesh.pb_mesh_data, Vector3.UP)
	var logic: PBElementEditor = s["logic"]
	var start := logic.get_subgizmo_transform(mesh.pb_mesh_data, mesh, top)
	# Shift+move extrudes; a 0.33 pull snaps the cap height to 0.4 (0.5 + 0.4).
	_drag_face_to(s, top, start.translated(Vector3(0, 0.33, 0)), true)
	var max_y := -INF
	for p in mesh.pb_mesh_data.positions:
		max_y = maxf(max_y, p.y)
	assert_almost_eq(max_y, 0.9, 0.001, "cap top = 0.5 + snapped 0.4")

# ==============================================================================
# PBGridView line builder (drives the gizmo-drawn grid)
# ==============================================================================

func test_grid_view_builds_and_caches():
	var g := PBGrid.new()
	var view := PBGridView.new(g)
	var cam := Camera3D.new()
	add_child_autofree(cam)
	cam.position = Vector3(0, 8, 10)
	cam.rotation_degrees = Vector3(-50, 0, 0)
	assert_true(view.update(cam), "first update rebuilds")
	assert_gt(view._lines.size(), 100, "subdivision + axis lines exist")
	assert_false(view.update(cam), "same focus = cached, no churn")
	# Elevation shifts the whole lattice by the new origin.
	g.raise()
	assert_true(view.update(cam), "grid change rebuilds")
	for p in view._lines:
		assert_almost_eq(p.y, 0.2, 0.001, "every line lies on the elevated plane")

func test_grid_view_fades_far_lines():
	var g := PBGrid.new()
	var view := PBGridView.new(g)
	var cam := Camera3D.new()
	add_child_autofree(cam)
	cam.position = Vector3(6, 24, 6)  # high camera → wide extent
	cam.rotation = Basis.from_euler(Vector3(-1.0, 0.8, 0.0)).get_euler()
	assert_true(view.update(cam))
	var focus := PBGridView._focus_cam(PBGridView._cam_transform(cam), g.origin.y)
	# Fade gates on SEGMENT MIDPOINT distance from the focus.
	var max_mid_d := 0.0
	for seg in range(0, view._lines.size(), 2):
		var mid := (view._lines[seg] + view._lines[seg + 1]) * 0.5
		max_mid_d = maxf(max_mid_d, Vector2(mid.x - focus.x, mid.z - focus.z).length())
	var near_alpha := -1.0
	var far_alpha := 1.0
	for seg in range(0, view._lines.size(), 2):
		var mid := (view._lines[seg] + view._lines[seg + 1]) * 0.5
		var dmid := Vector2(mid.x - focus.x, mid.z - focus.z).length()
		var a: float = view._colors[seg].a
		if dmid < 6.0:
			near_alpha = maxf(near_alpha, a)
		if dmid > 0.95 * max_mid_d:
			far_alpha = minf(far_alpha, a)
	assert_gt(view._lines.size(), 100, "high camera draws a wide-extent grid")
	assert_gt(near_alpha, 0.1, "near lines are visible")
	assert_lt(far_alpha, 0.05, "horizon lines have dissolved")

func test_extrude_unsnapped_when_disabled():
	var s := _make_setup(PBEditor.SelectMode.FACE, PBEditor.ToolMode.MOVE)
	var mesh: PBMesh = s["mesh"]
	var top := _face_id_by_normal(mesh.pb_mesh_data, Vector3.UP)
	var logic: PBElementEditor = s["logic"]
	logic.grid.enabled = false
	var start := logic.get_subgizmo_transform(mesh.pb_mesh_data, mesh, top)
	_drag_face_to(s, top, start.translated(Vector3(0, 0.33, 0)), true)
	var max_y := -INF
	for p in mesh.pb_mesh_data.positions:
		max_y = maxf(max_y, p.y)
	assert_almost_eq(max_y, 0.83, 0.001, "0.5 + 0.33 exact")
