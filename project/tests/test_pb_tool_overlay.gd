## Tests for the floating in-viewport Tool Panel (P7 UX round 2).
##
## The PBToolOverlay replaces the docked panels with a floating panel built
## from standard panel language: section headers and label/value rows with
## real controls (tool buttons, orientation space OptionButton), plus the
## live transform readout fed by PBElementEditor.
extends GutTest

# ==============================================================================
# 1. Null / Default State Tests
# ==============================================================================

func test_default_null_editor_does_not_crash():
	var overlay := PBToolOverlay.new()
	add_child_autofree(overlay)
	overlay.refresh()

	assert_not_null(overlay.title_label, "Title label must exist")
	assert_true(overlay.title_label.text.begins_with("ProBuilder v"),
		"Title must show the versioned plugin name so stale builds are detectable")

	assert_not_null(overlay.mode_value_label, "Mode value label must exist")
	assert_eq(overlay.mode_value_label.text, "Object", "Default mode readout is Object")

	assert_eq(overlay.vertices_value_label.text, "0 / 0", "Vertex counts default to zero")
	assert_eq(overlay.edges_value_label.text, "0 / 0", "Edge counts default to zero")
	assert_eq(overlay.faces_value_label.text, "0 / 0", "Face counts default to zero")

	assert_eq(overlay.drag_value_label.text, "—", "Drag readout should default to dash")

func test_bind_editor_follows_editor_state():
	var overlay := PBToolOverlay.new()
	add_child_autofree(overlay)
	var editor := PBEditor.new()
	editor.select_mode = PBEditor.SelectMode.VERTEX

	overlay.editor = editor

	assert_eq(overlay.mode_value_label.text, "Vertex", "Mode readout should follow editor")
	assert_true(overlay._btn_move.button_pressed, "Transform tool should default to Move")
	assert_eq(overlay.space_option.selected, PBEditor.OrientationSpace.ELEMENT,
		"Space picker should default to Element")

# ==============================================================================
# 2. Panel language: sections, rows, real controls
# ==============================================================================

func test_is_panel_container_stopping_mouse():
	var overlay := PBToolOverlay.new()
	add_child_autofree(overlay)
	assert_true(overlay is PanelContainer, "Tool overlay must be a floating panel")
	assert_eq(overlay.mouse_filter, Control.MOUSE_FILTER_STOP,
		"Overlay must stop mouse events over its rect")

func test_mode_tool_and_space_follow_editor():
	var overlay := PBToolOverlay.new()
	add_child_autofree(overlay)
	var editor := PBEditor.new()
	overlay.editor = editor

	editor.select_mode = PBEditor.SelectMode.FACE
	assert_eq(overlay.mode_value_label.text, "Face", "Mode readout should show Face")

	editor.tool_mode = PBEditor.ToolMode.ROTATE
	assert_true(overlay._btn_rotate.button_pressed, "Rotate button should follow editor tool")
	assert_false(overlay._btn_move.button_pressed, "Move button should unpress")

	editor.orientation_space = PBEditor.OrientationSpace.WORLD
	assert_eq(overlay.space_option.selected, PBEditor.OrientationSpace.WORLD,
		"Space picker should follow editor space")

func test_space_picker_controls_editor():
	var overlay := PBToolOverlay.new()
	add_child_autofree(overlay)
	var editor := PBEditor.new()
	overlay.editor = editor

	overlay.space_option.item_selected.emit(1)
	assert_eq(editor.orientation_space, PBEditor.OrientationSpace.OBJECT,
		"Picking a space in the panel must set the editor's orientation space")

func test_tool_buttons_control_editor():
	var overlay := PBToolOverlay.new()
	add_child_autofree(overlay)
	var editor := PBEditor.new()
	overlay.editor = editor

	overlay._btn_scale.emit_signal("pressed")
	assert_eq(editor.tool_mode, PBEditor.ToolMode.SCALE,
		"Panel tool button must set the editor's tool")

# ==============================================================================
# 3. Selection counts
# ==============================================================================

func test_selection_counts_display():
	var overlay := PBToolOverlay.new()
	add_child_autofree(overlay)
	var editor := PBEditor.new()
	overlay.editor = editor

	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)
	editor.active_mesh = mesh
	editor.selection.set_faces(PackedInt32Array([0, 3]))
	overlay.refresh()

	assert_eq(overlay.faces_value_label.text, "2 / 6",
		"Face counts should show selected against cube total (2 of 6)")
	assert_eq(overlay.vertices_value_label.text, "0 / 8", "Cube has 8 shared vertices")
	assert_eq(overlay.edges_value_label.text, "0 / 12", "Cube has 12 common edges")

# ==============================================================================
# 4. Live Drag Readout via PBElementEditor
# ==============================================================================

func test_drag_readout_translation():
	var overlay := PBToolOverlay.new()
	add_child_autofree(overlay)
	var editor := PBEditor.new()
	overlay.editor = editor

	var logic := PBElementEditor.new()
	logic.editor = editor
	overlay.element_editor = logic
	assert_eq(overlay.drag_value_label.text, "—", "Idle gizmo should show dash")

	logic._emit_drag_update(true, Vector3(0.5, 0, 0), Vector3.ZERO, Vector3.ONE)
	overlay.refresh()
	assert_true(overlay.drag_value_label.text.contains("Delta"), "Active translation drag should show Delta")

	# Rotate readout wins when rotation present
	logic._emit_drag_update(true, Vector3.ZERO, Vector3(0, 45, 0), Vector3.ONE)
	overlay.refresh()
	assert_true(overlay.drag_value_label.text.contains("Rotation"), "Active rotation drag should show Rotation")

	# Scale readout when scale present
	logic._emit_drag_update(true, Vector3.ZERO, Vector3.ZERO, Vector3(2, 2, 2))
	overlay.refresh()
	assert_true(overlay.drag_value_label.text.contains("Scale"), "Active scale drag should show Scale")

	# Commit (active=false) resets to dash
	logic._emit_drag_update(false, Vector3.ZERO, Vector3.ZERO, Vector3.ONE)
	overlay.refresh()
	assert_eq(overlay.drag_value_label.text, "—", "Committed drag should reset readout")

func test_signal_auto_refresh_on_editor_changes():
	var overlay := PBToolOverlay.new()
	add_child_autofree(overlay)
	var editor := PBEditor.new()
	overlay.editor = editor

	editor.select_mode = PBEditor.SelectMode.EDGE
	assert_eq(overlay.mode_value_label.text, "Edge",
		"Overlay should auto-refresh on select_mode_changed without manual refresh()")

func test_signal_auto_refresh_on_drag_update():
	var overlay := PBToolOverlay.new()
	add_child_autofree(overlay)
	var editor := PBEditor.new()
	overlay.editor = editor

	var logic := PBElementEditor.new()
	logic.editor = editor
	overlay.element_editor = logic

	# No manual refresh() — the drag_updated signal must refresh the overlay
	logic._emit_drag_update(true, Vector3(1, 2, 3), Vector3.ZERO, Vector3.ONE)
	assert_true(overlay.drag_value_label.text.contains("Delta"),
		"Overlay should auto-refresh on element_drag_updated")
