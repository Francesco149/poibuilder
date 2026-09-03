## Tests for PBToolOverlay — the compact readout/params panel.
##
## v0.9.0 redesign: the panel carries NO op buttons (they moved to the
## persistent toolbar) and NO tool/space controls (toolbar too). It shows:
## - selection info only while something is selected,
## - the live drag readout only while a gizmo drag runs,
## - the shape-params modal (open_params / Apply / Cancel signals),
## and auto-hides unless pinned, open, or showing something.
extends GutTest

func _make_overlay() -> PBToolOverlay:
	var overlay := PBToolOverlay.new()
	add_child_autofree(overlay)
	return overlay

func _make_editor_with_cube() -> Dictionary:
	var ed := PBEditor.new()
	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)
	ed.active_mesh = mesh
	return {"ed": ed, "mesh": mesh}

# ==============================================================================
# Structure
# ==============================================================================

func test_default_null_editor_does_not_crash():
	var overlay := _make_overlay()
	overlay.refresh()
	assert_not_null(overlay.title_label, "Title label must exist")
	assert_true(overlay.title_label.text.begins_with("PoiBuilder v"),
		"Title shows the plugin version")

func test_is_panel_container_stopping_mouse():
	var overlay := _make_overlay()
	assert_eq(overlay.mouse_filter, Control.MOUSE_FILTER_STOP,
		"The panel consumes clicks on its own rect")

func test_drag_readout_defaults_to_dash():
	var overlay := _make_overlay()
	assert_not_null(overlay.drag_value_label)
	assert_eq(overlay.drag_value_label.text, "—")

func test_no_op_buttons_remain_in_the_overlay():
	var overlay := _make_overlay()
	overlay.build_ui()
	# The v0.9.0 redesign moved every op button to the persistent toolbar.
	var found_op_buttons := 0
	for node in overlay.find_children("*", "Button", true, false):
		if String(node.name).begins_with("Op"):
			found_op_buttons += 1
	assert_eq(found_op_buttons, 0, "The overlay carries no Extrude/Inset/etc buttons")

# ==============================================================================
# Selection readout (only while something is selected)
# ==============================================================================

func test_selection_row_hidden_with_nothing_selected():
	var s := _make_editor_with_cube()
	var overlay := _make_overlay()
	overlay.editor = s["ed"]
	overlay.refresh()
	assert_false(overlay._selection_row.visible,
		"No selection info when nothing is selected")

func test_selection_row_shows_active_mode_count():
	var s := _make_editor_with_cube()
	var ed: PBEditor = s["ed"]
	var overlay := _make_overlay()
	overlay.editor = ed
	ed.selection.set_faces(PackedInt32Array([0, 2]))
	overlay.refresh()
	assert_true(overlay._selection_row.visible, "Selection info shows when faces are selected")
	assert_eq(overlay._selection_mode_label.text, "Face")
	assert_eq(overlay._selection_count_label.text, "2 / 6", "Count reads selected / total")

func test_selection_row_tracks_vertex_mode():
	var s := _make_editor_with_cube()
	var ed: PBEditor = s["ed"]
	var overlay := _make_overlay()
	overlay.editor = ed
	ed.select_mode = PBEditor.SelectMode.VERTEX
	ed.selection.set_vertices(PackedInt32Array([0]))
	overlay.refresh()
	assert_eq(overlay._selection_mode_label.text, "Vertex")
	assert_eq(overlay._selection_count_label.text, "1 / 8", "Cube has 8 shared vertices")

# ==============================================================================
# Drag readout (only while a drag runs)
# ==============================================================================

func test_drag_row_visible_only_while_dragging():
	var s := _make_editor_with_cube()
	var ed: PBEditor = s["ed"]
	var overlay := _make_overlay()
	var logic := PBElementEditor.new()
	logic.editor = ed
	overlay.element_editor = logic
	overlay.refresh()
	assert_false(overlay._drag_row.visible, "No drag row while idle")

	var mesh: PBMesh = s["mesh"]
	var md: PBMeshData = mesh.pb_mesh_data
	var ids := PackedInt32Array([0])
	var start_xf := logic.get_subgizmo_transform(md, mesh, 0)
	logic.set_subgizmo_transform(mesh, ids, 0, start_xf.translated(Vector3(0.5, 0, 0)))
	overlay.refresh()
	assert_true(overlay._drag_row.visible, "Drag row shows while a gizmo drag runs")
	assert_ne(overlay.drag_value_label.text, "—", "Live readout while dragging")

	logic.commit_subgizmos(mesh, ids, false)
	overlay.refresh()
	assert_false(overlay._drag_row.visible, "Drag row hides after commit")

# ==============================================================================
# Visibility rules
# ==============================================================================

func test_visibility_auto_hides_without_anything_to_show():
	var s := _make_editor_with_cube()
	var ed: PBEditor = s["ed"]
	var overlay := _make_overlay()
	overlay.editor = ed
	overlay.refresh()
	assert_false(overlay.visible, "Panel hides when nothing is selected and not pinned")

	overlay.pinned = true
	assert_true(overlay.visible, "Pinned panel shows whenever a mesh is selected")

func test_visibility_with_selection_unpinned():
	var s := _make_editor_with_cube()
	var ed: PBEditor = s["ed"]
	var overlay := _make_overlay()
	overlay.editor = ed
	ed.selection.set_faces(PackedInt32Array([0]))
	overlay.refresh()
	assert_true(overlay.visible, "Selection info makes the panel show even unpinned")

func test_visibility_without_mesh():
	var overlay := _make_overlay()
	overlay.editor = PBEditor.new()
	overlay.pinned = true
	overlay.refresh()
	assert_false(overlay.visible, "Pinned panel still hides with no active mesh")

func test_params_modal_forces_visibility():
	var s := _make_editor_with_cube()
	var overlay := _make_overlay()
	overlay.editor = s["ed"]
	overlay.open_params("Test Shape", [], {})
	assert_true(overlay.visible, "An open params modal always shows the panel")
	overlay.close_params()
	assert_false(overlay.visible, "Closing the modal re-evaluates visibility")

# ==============================================================================
# Collapse
# ==============================================================================

func test_collapse_hides_body_only():
	var overlay := _make_overlay()
	assert_true(overlay._body.visible)
	overlay._on_collapse_pressed()
	assert_false(overlay._body.visible, "Collapsed panel hides its body")
	overlay._on_collapse_pressed()
	assert_true(overlay._body.visible, "Re-expanding shows the body again")

func test_open_params_expands_collapsed_panel():
	var overlay := _make_overlay()
	overlay._on_collapse_pressed()
	overlay.open_params("Cube", [{"name": "width", "label": "Width", "min": 0.1,
		"max": 10.0, "step": 0.1, "suffix": "m"}], {"width": 2.0})
	assert_true(overlay._body.visible, "Opening the modal expands the body")

# ==============================================================================
# Params session
# ==============================================================================

func test_open_params_builds_one_control_per_def():
	var overlay := _make_overlay()
	overlay.open_params("Cube",
		[{"name": "width", "label": "Width", "min": 0.1, "max": 10.0, "step": 0.1, "suffix": "m"},
		 {"name": "steps", "label": "Steps", "min": 1, "max": 64, "step": 1, "suffix": ""}],
		{"width": 2.0, "steps": 6})
	assert_true(overlay.params_open)
	assert_eq(overlay._param_spinboxes.size(), 2, "One control per param def")
	assert_almost_eq(overlay._param_spinboxes["width"].value, 2.0, 0.0001)
	assert_almost_eq(overlay._param_spinboxes["steps"].value, 6.0, 0.0001)
	assert_true(overlay._params_section.visible)

func test_param_change_emits_signal():
	var overlay := _make_overlay()
	overlay.open_params("Cube", [{"name": "width", "label": "Width", "min": 0.1,
		"max": 10.0, "step": 0.1, "suffix": "m"}], {"width": 2.0})
	var received: Array = []
	overlay.param_changed.connect(func(name, value): received.append([name, value]))
	overlay._param_spinboxes["width"].value = 3.5
	assert_eq(received.size(), 1, "SpinBox edits emit param_changed while open")
	assert_eq(received[0][0], "width")
	assert_almost_eq(received[0][1], 3.5, 0.0001)

func test_apply_and_cancel_signals():
	var overlay := _make_overlay()
	overlay.open_params("Cube", [], {})
	var applied := [false]
	var cancelled := [false]
	overlay.params_applied.connect(func(): applied[0] = true)
	overlay.params_canceled.connect(func(): cancelled[0] = true)
	overlay.params_applied.emit()
	overlay.params_canceled.emit()
	assert_true(applied[0])
	assert_true(cancelled[0])

func test_get_and_set_param_values():
	var overlay := _make_overlay()
	overlay.open_params("Cube", [{"name": "width", "label": "Width", "min": 0.1,
		"max": 10.0, "step": 0.1, "suffix": "m"}], {"width": 2.0})
	var values := overlay.get_param_values()
	assert_almost_eq(values["width"], 2.0, 0.0001)

	var received: Array = []
	overlay.param_changed.connect(func(_n, _v): received.append(1))
	overlay.set_param_values({"width": 1.0})
	assert_almost_eq(overlay.get_param_values()["width"], 1.0, 0.0001,
		"set_param_values snaps the control")
	assert_eq(received.size(), 0, "set_param_values must NOT emit param_changed (cancel path)")

func test_close_params_clears_controls():
	var overlay := _make_overlay()
	overlay.open_params("Cube", [{"name": "width", "label": "Width", "min": 0.1,
		"max": 10.0, "step": 0.1, "suffix": "m"}], {"width": 2.0})
	overlay.close_params()
	assert_false(overlay.params_open)
	assert_false(overlay._params_section.visible)
	assert_eq(overlay._param_spinboxes.size(), 0, "Controls are cleared on close")

func test_spinbox_click_drag_support():
	var overlay := _make_overlay()
	overlay.open_params("Cube", [{"name": "width", "label": "Width", "min": 0.1,
		"max": 10.0, "step": 0.1, "suffix": "m"}], {"width": 2.0})
	var spin: SpinBox = overlay._param_spinboxes["width"]
	assert_not_null(spin)
	var le := spin.get_line_edit()
	assert_not_null(le)
	assert_eq(le.mouse_default_cursor_shape, Control.CURSOR_HSIZE, "Cursor should be horizontal resize drag")
	assert_true(spin.select_all_on_focus, "select_all_on_focus should be enabled")

	# Simulate click-drag rightwards:
	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_LEFT
	mb.pressed = true
	mb.global_position = Vector2(100, 100)
	le.gui_input.emit(mb)

	var mm := InputEventMouseMotion.new()
	mm.global_position = Vector2(150, 100) # dx = +50px
	le.gui_input.emit(mm)

	var mb_up := InputEventMouseButton.new()
	mb_up.button_index = MOUSE_BUTTON_LEFT
	mb_up.pressed = false
	mb_up.global_position = Vector2(150, 100)
	le.gui_input.emit(mb_up)

	assert_gt(spin.value, 2.0, "Dragging right should have increased the spinbox value")

# ==============================================================================
# Pin plumbing
# ==============================================================================

func test_pinned_setter_updates_visibility():
	var s := _make_editor_with_cube()
	var overlay := _make_overlay()
	overlay.editor = s["ed"]
	overlay.refresh()
	assert_false(overlay.visible)
	overlay.pinned = true
	assert_true(overlay.visible, "Setting pinned re-evaluates visibility immediately")

# ==============================================================================
# Dragging, Clamping, and Recovery
# ==============================================================================

func test_overlay_header_drag_reaches_bottom_and_clamps():
	var parent := Control.new()
	parent.size = Vector2(800, 600)
	add_child_autofree(parent)

	var overlay := PBToolOverlay.new()
	parent.add_child(overlay)
	overlay.build_ui()
	overlay.size = Vector2(200, 100)
	overlay.reset_to_default_position()

	# Simulate left-click on header
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(50, 10)
	overlay._on_header_gui_input(press)
	assert_true(overlay._panel_dragging)

	# Simulate dragging mouse down towards the bottom of the parent (by 400px)
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(0, 400)
	overlay._on_header_gui_input(motion)

	# The panel must be allowed to reach the bottom padding edge without snapping up
	var max_allowed_y: float = parent.size.y - overlay.size.y - PBToolOverlay.PADDING
	assert_almost_eq(overlay.position.y, max_allowed_y, 1.0,
		"Panel can reach the true bottom of the viewport with padding")
	assert_lte(overlay.position.y + overlay.size.y, parent.size.y,
		"Panel never exceeds bottom edge of viewport")

func test_overlay_clamp_on_parent_resize():
	var parent := Control.new()
	parent.size = Vector2(800, 600)
	add_child_autofree(parent)

	var overlay := PBToolOverlay.new()
	parent.add_child(overlay)
	overlay.build_ui()
	overlay.size = Vector2(200, 100)
	overlay.position = Vector2(500, 450)
	overlay._custom_position_set = true

	# Parent shrinks to 400x300 — overlay at (500, 450) is now out of bounds
	parent.size = Vector2(400, 300)
	overlay.clamp_to_viewport()

	assert_lte(overlay.position.x + overlay.size.x, parent.size.x,
		"Clamped panel X stays inside parent bounds")
	assert_lte(overlay.position.y + overlay.size.y, parent.size.y,
		"Clamped panel Y stays inside parent bounds")
	assert_gte(overlay.position.x, PBToolOverlay.PADDING)
	assert_gte(overlay.position.y, PBToolOverlay.PADDING)

func test_overlay_reset_to_default_position():
	var parent := Control.new()
	parent.size = Vector2(800, 600)
	add_child_autofree(parent)

	var overlay := PBToolOverlay.new()
	parent.add_child(overlay)
	overlay.build_ui()
	overlay.position = Vector2(400, 200)
	overlay._custom_position_set = true

	overlay.reset_to_default_position()
	assert_false(overlay._custom_position_set,
		"Reset clears custom position flag")
	assert_eq(overlay.position.x, PBToolOverlay.DEFAULT_OFFSET,
		"Reset restores default horizontal offset")

func test_overlay_is_offscreen_and_recovery():
	var parent := Control.new()
	parent.size = Vector2(800, 600)
	add_child_autofree(parent)

	var overlay := PBToolOverlay.new()
	parent.add_child(overlay)
	overlay.build_ui()
	overlay.size = Vector2(200, 100)

	# Move completely outside parent bounds
	overlay.position = Vector2(-300, -200)
	assert_true(overlay.is_offscreen(), "Panel outside parent rect must report is_offscreen")

	# Recovery resets it
	overlay.ensure_visible_and_clamped()
	assert_false(overlay.is_offscreen(), "Recovery must bring panel back inside visible area")

func test_bottom_left_anchor_growth():
	var parent := Control.new()
	parent.size = Vector2(800, 600)
	add_child_autofree(parent)

	var overlay := PBToolOverlay.new()
	parent.add_child(overlay)
	overlay.build_ui()
	overlay.size = Vector2(165, 40)
	overlay.reset_to_default_position()

	var initial_bottom: float = overlay.position.y + overlay.size.y

	# When content height expands (e.g. to 140px), the bottom-left corner stays pinned
	overlay.size = Vector2(165, 140)
	overlay._update_position_from_bottom_left()

	assert_almost_eq(overlay.position.y + overlay.size.y, initial_bottom, 0.001,
		"Bottom edge remains anchored when panel height expands")

	# When content height shrinks back (e.g. to 40px), bottom edge stays pinned
	overlay.size = Vector2(165, 40)
	overlay._update_position_from_bottom_left()

	assert_almost_eq(overlay.position.y + overlay.size.y, initial_bottom, 0.001,
		"Bottom edge remains anchored when panel height shrinks")

func test_panel_enabled_master_toggle():
	var s := _make_editor_with_cube()
	var ed: PBEditor = s["ed"]
	var overlay := _make_overlay()
	overlay.editor = ed
	ed.selection.set_faces(PackedInt32Array([0]))
	overlay.refresh()
	assert_true(overlay.visible, "With selection, panel is visible when enabled")

	# Disabling panel_enabled strictly hides the panel
	overlay.panel_enabled = false
	assert_false(overlay.visible, "Disabling panel_enabled strictly hides the panel even with selection")

	# Re-enabling shows it again
	overlay.panel_enabled = true
	assert_true(overlay.visible, "Re-enabling panel_enabled restores visibility")

func test_empty_panel_auto_collapsed():
	var s := _make_editor_with_cube()
	var ed: PBEditor = s["ed"]
	var overlay := _make_overlay()
	overlay.editor = ed
	overlay.pinned = true
	overlay.refresh()
	# No elements selected: empty panel auto-collapses body
	assert_false(overlay._body.visible, "Empty panel body is auto-collapsed to header")
	assert_eq(overlay._collapse_btn.text, "▸", "Collapse button shows right arrow when auto-collapsed")

	# Selecting an element expands it
	ed.selection.set_faces(PackedInt32Array([0]))
	overlay.refresh()
	assert_true(overlay._body.visible, "Selecting an element expands the panel body")
	assert_eq(overlay._collapse_btn.text, "▾", "Collapse button shows down arrow when expanded")
