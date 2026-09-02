## Tests for the floating in-viewport Tool Overlay (P7 UX round).
##
## The PBToolOverlay replaces the docked panels: same state readouts (mode,
## tool, orientation space, selection counts, live transform readout fed by
## PBElementEditor), but as a floating PanelContainer parented to the 3D
## editor viewport.
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

	assert_not_null(overlay.mode_label, "Mode label must exist")
	assert_true(overlay.mode_label.text.contains("Object"), "Default mode label must show Object")

	assert_not_null(overlay.selection_label, "Selection label must exist")
	assert_true(overlay.selection_label.text.contains("V:0 E:0 F:0"), "Default selection should be V:0 E:0 F:0")

	assert_not_null(overlay.settings_label, "Settings label must exist")
	assert_eq(overlay.settings_label.text, "—", "Default settings line should be dash '—'")

func test_bind_editor_follows_editor_mode():
	var overlay := PBToolOverlay.new()
	add_child_autofree(overlay)
	var editor := PBEditor.new()
	editor.select_mode = PBEditor.SelectMode.VERTEX

	overlay.editor = editor

	assert_true(overlay.mode_label.text.contains("Vertex"), "Mode should follow editor (Vertex)")
	assert_true(overlay.mode_label.text.contains("Move"), "Tool should default to Move")
	assert_true(overlay.mode_label.text.contains("Element"), "Space should default to Element")
	assert_true(overlay.selection_label.text.contains("V:0 E:0 F:0"), "Selection counts should be zero")
	assert_eq(overlay.settings_label.text, "—", "Settings should be dash '—'")

# ==============================================================================
# 2. Mode / Tool / Space / Selection Display
# ==============================================================================

func test_mode_tool_and_space_display():
	var overlay := PBToolOverlay.new()
	add_child_autofree(overlay)
	var editor := PBEditor.new()
	overlay.editor = editor

	editor.select_mode = PBEditor.SelectMode.FACE
	assert_true(overlay.mode_label.text.contains("Face"), "Mode should show Face")

	editor.tool_mode = PBEditor.ToolMode.ROTATE
	assert_true(overlay.mode_label.text.contains("Rotate"), "Tool should show Rotate")

	editor.orientation_space = PBEditor.OrientationSpace.WORLD
	assert_true(overlay.mode_label.text.contains("World"), "Space should show World after cycling")

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

	assert_true(overlay.selection_label.text.contains("F:2"), "Face count should show 2")

# ==============================================================================
# 3. Live Drag Readout via PBElementEditor
# ==============================================================================

func test_drag_readout_translation():
	var overlay := PBToolOverlay.new()
	add_child_autofree(overlay)
	var editor := PBEditor.new()
	overlay.editor = editor

	var logic := PBElementEditor.new()
	logic.editor = editor
	overlay.element_editor = logic
	assert_eq(overlay.settings_label.text, "—", "Idle gizmo should show dash")

	logic._emit_drag_update(true, Vector3(0.5, 0, 0), Vector3.ZERO, Vector3.ONE)
	overlay.refresh()
	assert_true(overlay.settings_label.text.contains("Delta"), "Active translation drag should show Delta")

	# Rotate readout wins when rotation present
	logic._emit_drag_update(true, Vector3.ZERO, Vector3(0, 45, 0), Vector3.ONE)
	overlay.refresh()
	assert_true(overlay.settings_label.text.contains("Rotation"), "Active rotation drag should show Rotation")

	# Scale readout when scale present
	logic._emit_drag_update(true, Vector3.ZERO, Vector3.ZERO, Vector3(2, 2, 2))
	overlay.refresh()
	assert_true(overlay.settings_label.text.contains("Scale"), "Active scale drag should show Scale")

	# Commit (active=false) resets to dash
	logic._emit_drag_update(false, Vector3.ZERO, Vector3.ZERO, Vector3.ONE)
	overlay.refresh()
	assert_eq(overlay.settings_label.text, "—", "Committed drag should reset readout")

func test_signal_auto_refresh_on_editor_changes():
	var overlay := PBToolOverlay.new()
	add_child_autofree(overlay)
	var editor := PBEditor.new()
	overlay.editor = editor

	editor.select_mode = PBEditor.SelectMode.EDGE
	assert_true(overlay.mode_label.text.contains("Edge"),
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
	assert_true(overlay.settings_label.text.contains("Delta"),
		"Overlay should auto-refresh on element_drag_updated")

# ==============================================================================
# 4. It is an overlay, not a dock
# ==============================================================================

func test_is_panel_container():
	var overlay := PBToolOverlay.new()
	add_child_autofree(overlay)
	assert_true(overlay is PanelContainer, "Tool overlay must be a floating panel")

	# Mouse events over the panel are consumed, not passed to the scene.
	assert_eq(overlay.mouse_filter, Control.MOUSE_FILTER_STOP,
		"Overlay must stop mouse events over its rect")
