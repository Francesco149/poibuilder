## Tests for Phase 6 (IU P6-06): Tool Properties Dock
##
## Tests PBToolPropertiesDock displaying selection mode, orientation space,
## selection counts, and the live transform readout fed by PBElementEditor.
extends GutTest

# ==============================================================================
# 1. Null / Default State Tests
# ==============================================================================

func test_default_null_editor_does_not_crash():
	var dock := PBToolPropertiesDock.new()
	add_child_autofree(dock)
	dock.refresh()

	assert_not_null(dock.title_label, "Title label must exist")
	assert_eq(dock.title_label.text, "ProBuilder", "Title must be 'ProBuilder'")

	assert_not_null(dock.mode_label, "Mode label must exist")
	assert_true(dock.mode_label.text.contains("Object"), "Default mode label must show Object")

	assert_not_null(dock.selection_label, "Selection label must exist")
	assert_true(dock.selection_label.text.contains("V:0 E:0 F:0"), "Default selection should be V:0 E:0 F:0")

	assert_not_null(dock.settings_label, "Settings label must exist")
	assert_eq(dock.settings_label.text, "—", "Default settings line should be dash '—'")

func test_bind_editor_follows_editor_mode():
	var dock := PBToolPropertiesDock.new()
	add_child_autofree(dock)
	var editor := PBEditor.new()
	editor.select_mode = PBEditor.SelectMode.VERTEX

	dock.editor = editor

	assert_true(dock.mode_label.text.contains("Vertex"), "Mode should follow editor (Vertex)")
	assert_true(dock.mode_label.text.contains("Element"), "Space should default to Element")
	assert_true(dock.selection_label.text.contains("V:0 E:0 F:0"), "Selection counts should be zero")
	assert_eq(dock.settings_label.text, "—", "Settings should be dash '—'")

# ==============================================================================
# 2. Mode / Space / Selection Display
# ==============================================================================

func test_mode_and_space_display():
	var dock := PBToolPropertiesDock.new()
	add_child_autofree(dock)
	var editor := PBEditor.new()
	dock.editor = editor

	editor.select_mode = PBEditor.SelectMode.FACE
	assert_true(dock.mode_label.text.contains("Face"), "Mode should show Face")

	editor.orientation_space = PBEditor.OrientationSpace.WORLD
	assert_true(dock.mode_label.text.contains("World"), "Space should show World after cycling")

func test_selection_counts_display():
	var dock := PBToolPropertiesDock.new()
	add_child_autofree(dock)
	var editor := PBEditor.new()
	dock.editor = editor

	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)
	editor.active_mesh = mesh
	editor.selection.set_faces(PackedInt32Array([0, 3]))
	dock.refresh()

	assert_true(dock.selection_label.text.contains("F:2"), "Face count should show 2")

# ==============================================================================
# 3. Live Drag Readout via PBGizmoPlugin
# ==============================================================================

func test_drag_readout_translation():
	var dock := PBToolPropertiesDock.new()
	add_child_autofree(dock)
	var editor := PBEditor.new()
	dock.editor = editor

	var logic := PBElementEditor.new()
	logic.editor = editor
	dock.element_editor = logic
	assert_eq(dock.settings_label.text, "—", "Idle gizmo should show dash")

	logic._emit_drag_update(true, Vector3(0.5, 0, 0), Vector3.ZERO, Vector3.ONE)
	dock.refresh()
	assert_true(dock.settings_label.text.contains("Delta"), "Active translation drag should show Delta")

	# Rotate readout wins when rotation present
	logic._emit_drag_update(true, Vector3.ZERO, Vector3(0, 45, 0), Vector3.ONE)
	dock.refresh()
	assert_true(dock.settings_label.text.contains("Rotation"), "Active rotation drag should show Rotation")

	# Scale readout when scale present
	logic._emit_drag_update(true, Vector3.ZERO, Vector3.ZERO, Vector3(2, 2, 2))
	dock.refresh()
	assert_true(dock.settings_label.text.contains("Scale"), "Active scale drag should show Scale")

	# Commit (active=false) resets to dash
	logic._emit_drag_update(false, Vector3.ZERO, Vector3.ZERO, Vector3.ONE)
	dock.refresh()
	assert_eq(dock.settings_label.text, "—", "Committed drag should reset readout")

func test_signal_auto_refresh_on_editor_changes():
	var dock := PBToolPropertiesDock.new()
	add_child_autofree(dock)
	var editor := PBEditor.new()
	dock.editor = editor

	editor.select_mode = PBEditor.SelectMode.EDGE
	assert_true(dock.mode_label.text.contains("Edge"),
		"Dock should auto-refresh on select_mode_changed without manual refresh()")

func test_signal_auto_refresh_on_drag_update():
	var dock := PBToolPropertiesDock.new()
	add_child_autofree(dock)
	var editor := PBEditor.new()
	dock.editor = editor

	var logic := PBElementEditor.new()
	logic.editor = editor
	dock.element_editor = logic

	# No manual refresh() — the drag_updated signal must refresh the dock
	logic._emit_drag_update(true, Vector3(1, 2, 3), Vector3.ZERO, Vector3.ONE)
	assert_true(dock.settings_label.text.contains("Delta"),
		"Dock should auto-refresh on element_drag_updated")
