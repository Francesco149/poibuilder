## Tests for Phase 6 (IU P6-06): Tool Properties Dock
##
## Tests PBToolPropertiesDock panel displaying active tool properties,
## selection mode, selection counts, and live transform readouts.
extends GutTest

# ==============================================================================
# 1. Null / Default State Tests
# ==============================================================================

func test_default_null_editor_does_not_crash():
	var dock := PBToolPropertiesDock.new()
	add_child_autofree(dock)
	dock.refresh()

	assert_not_null(dock.title_label, "Title label must exist")
	assert_eq(dock.title_label.text, "Tool Properties", "Title must be 'Tool Properties'")

	assert_not_null(dock.tool_label, "Tool label must exist")
	assert_true(dock.tool_label.text.contains("Select"), "Default tool label must show Select")

	assert_not_null(dock.mode_label, "Mode label must exist")
	assert_true(dock.mode_label.text.contains("Object"), "Default mode label must show Object")

	assert_not_null(dock.selection_label, "Selection label must exist")
	assert_true(dock.selection_label.text.contains("V:0 E:0 F:0"), "Default selection should be V:0 E:0 F:0")

	assert_not_null(dock.settings_label, "Settings label must exist")
	assert_eq(dock.settings_label.text, "—", "Default settings line should be dash '—'")

func test_bind_editor_no_tool_follows_editor_mode():
	var dock := PBToolPropertiesDock.new()
	add_child_autofree(dock)
	var editor := PBEditor.new()
	editor.select_mode = PBEditor.SelectMode.VERTEX

	dock.editor = editor

	assert_true(dock.tool_label.text.contains("Select"), "Tool should be Select with no active tool")
	assert_true(dock.mode_label.text.contains("Vertex"), "Mode should follow editor (Vertex)")
	assert_true(dock.selection_label.text.contains("V:0 E:0 F:0"), "Selection counts should be zero")
	assert_eq(dock.settings_label.text, "—", "Settings should be dash '—'")

# ==============================================================================
# 2. Tool Switching Tests
# ==============================================================================

func test_set_active_tool_move():
	var dock := PBToolPropertiesDock.new()
	add_child_autofree(dock)
	var editor := PBEditor.new()
	dock.editor = editor

	editor.active_tool = PBToolMove.new()
	dock.refresh()

	assert_true(dock.tool_label.text.contains("Move"), "Tool label must show Move after switching to Move tool")

func test_set_active_tool_rotate():
	var dock := PBToolPropertiesDock.new()
	add_child_autofree(dock)
	var editor := PBEditor.new()
	dock.editor = editor

	editor.active_tool = PBToolRotate.new()
	dock.refresh()

	assert_true(dock.tool_label.text.contains("Rotate"), "Tool label must show Rotate after switching to Rotate tool")

func test_set_active_tool_scale():
	var dock := PBToolPropertiesDock.new()
	add_child_autofree(dock)
	var editor := PBEditor.new()
	dock.editor = editor

	editor.active_tool = PBToolScale.new()
	dock.refresh()

	assert_true(dock.tool_label.text.contains("Scale"), "Tool label must show Scale after switching to Scale tool")

func test_set_active_tool_null_reverts_to_select():
	var dock := PBToolPropertiesDock.new()
	add_child_autofree(dock)
	var editor := PBEditor.new()
	dock.editor = editor

	editor.active_tool = PBToolMove.new()
	assert_true(dock.tool_label.text.contains("Move"))

	editor.active_tool = null
	dock.refresh()

	assert_true(dock.tool_label.text.contains("Select"), "Tool label must revert to Select when active_tool is null")

# ==============================================================================
# 3. Selection Counts
# ==============================================================================

func test_selection_counts_face_mode():
	var dock := PBToolPropertiesDock.new()
	add_child_autofree(dock)
	var editor := PBEditor.new()
	dock.editor = editor

	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)
	editor.active_mesh = mesh
	editor.select_mode = PBEditor.SelectMode.FACE

	editor.selection.set_faces(PackedInt32Array([0]))
	dock.refresh()

	assert_true(dock.selection_label.text.contains("F:1"), "Selection line must show F:1")
	assert_true(dock.selection_label.text.contains("V:0 E:0 F:1"), "Selection line should show V:0 E:0 F:1")

func test_selection_counts_vertex_mode():
	var dock := PBToolPropertiesDock.new()
	add_child_autofree(dock)
	var editor := PBEditor.new()
	dock.editor = editor

	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)
	editor.active_mesh = mesh
	editor.select_mode = PBEditor.SelectMode.VERTEX

	editor.selection.set_vertices(PackedInt32Array([0, 1]))
	dock.refresh()

	assert_true(dock.selection_label.text.contains("V:2"), "Selection line must show V:2")
	assert_true(dock.selection_label.text.contains("V:2 E:0 F:0"), "Selection line should show V:2 E:0 F:0")

func test_selection_counts_edge_mode():
	var dock := PBToolPropertiesDock.new()
	add_child_autofree(dock)
	var editor := PBEditor.new()
	dock.editor = editor

	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)
	editor.active_mesh = mesh
	editor.select_mode = PBEditor.SelectMode.EDGE

	var edge := PBEdge.new(0, 1)
	editor.selection.set_edges([edge])
	dock.refresh()

	assert_true(dock.selection_label.text.contains("E:1"), "Selection line must show E:1")

# ==============================================================================
# 4. Live Transform Readout Tests
# ==============================================================================

func test_move_tool_drag_readout():
	var dock := PBToolPropertiesDock.new()
	add_child_autofree(dock)
	var editor := PBEditor.new()
	dock.editor = editor

	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)
	editor.active_mesh = mesh
	editor.select_mode = PBEditor.SelectMode.FACE
	editor.selection.set_faces(PackedInt32Array([0]))

	var tool := PBToolMove.new()
	editor.active_tool = tool

	# Begin drag ray at face 0 (hits (0, 0, -0.5))
	var ok: bool = tool.begin_drag(Vector3(0.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	assert_true(ok, "begin_drag must succeed")

	# Update drag ray (hits (1, 0, -0.5) -> delta (1, 0, 0))
	tool.update_drag(Vector3(1.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))

	dock.refresh()

	assert_true(dock.settings_label.text.begins_with("Delta:"),
		"Settings label should begin with 'Delta:', got: %s" % dock.settings_label.text)
	assert_true(dock.settings_label.text.contains("(1.0, 0.0, 0.0)") or dock.settings_label.text.contains("(1, 0, 0)"),
		"Settings label should show delta (1, 0, 0), got: %s" % dock.settings_label.text)

func test_rotate_tool_drag_readout():
	var dock := PBToolPropertiesDock.new()
	add_child_autofree(dock)
	var editor := PBEditor.new()
	dock.editor = editor

	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)
	editor.active_mesh = mesh
	editor.select_mode = PBEditor.SelectMode.FACE
	editor.selection.set_faces(PackedInt32Array([0]))

	var tool := PBToolRotate.new()
	editor.active_tool = tool

	var ok: bool = tool.begin_drag(Vector3(0.0, 1.0, -5.0), Vector3(0.0, 0.0, 1.0))
	assert_true(ok, "begin_drag must succeed")

	tool.update_drag(Vector3(1.0, 0.0, -5.0), Vector3(0.0, 0.0, 1.0))
	dock.refresh()

	assert_true(dock.settings_label.text.begins_with("Rotation:"),
		"Settings label should begin with 'Rotation:', got: %s" % dock.settings_label.text)
	assert_true(dock.settings_label.text.ends_with("deg"),
		"Settings label should end with 'deg', got: %s" % dock.settings_label.text)

func test_scale_tool_drag_readout():
	var dock := PBToolPropertiesDock.new()
	add_child_autofree(dock)
	var editor := PBEditor.new()
	dock.editor = editor

	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)
	editor.active_mesh = mesh
	editor.select_mode = PBEditor.SelectMode.FACE
	editor.selection.set_faces(PackedInt32Array([0]))

	var tool := PBToolScale.new()
	editor.active_tool = tool

	var ok: bool = tool.begin_drag(Vector3(0.0, 1.0, -5.0), Vector3(0.0, 0.0, 1.0))
	assert_true(ok, "begin_drag must succeed")

	tool.update_drag(Vector3(0.0, 2.0, -5.0), Vector3(0.0, 0.0, 1.0))
	dock.refresh()

	assert_true(dock.settings_label.text.begins_with("Scale:"),
		"Settings label should begin with 'Scale:', got: %s" % dock.settings_label.text)
	assert_true(dock.settings_label.text.contains("(2.0, 2.0, 2.0)") or dock.settings_label.text.contains("(2, 2, 2)"),
		"Settings label should show scale (2, 2, 2), got: %s" % dock.settings_label.text)

# ==============================================================================
# 5. Signal Integration Tests
# ==============================================================================

func test_signal_auto_refresh_on_active_tool_changed():
	var dock := PBToolPropertiesDock.new()
	add_child_autofree(dock)
	var editor := PBEditor.new()
	dock.editor = editor

	assert_true(dock.tool_label.text.contains("Select"))

	# Change active_tool — dock should refresh automatically via signal
	editor.active_tool = PBToolMove.new()
	assert_true(dock.tool_label.text.contains("Move"), "Tool label should auto-update to Move")

	editor.active_tool = PBToolRotate.new()
	assert_true(dock.tool_label.text.contains("Rotate"), "Tool label should auto-update to Rotate")

	editor.active_tool = PBToolScale.new()
	assert_true(dock.tool_label.text.contains("Scale"), "Tool label should auto-update to Scale")

	editor.active_tool = null
	assert_true(dock.tool_label.text.contains("Select"), "Tool label should auto-update to Select")

func test_signal_auto_refresh_on_select_mode_and_selection_changed():
	var dock := PBToolPropertiesDock.new()
	add_child_autofree(dock)
	var editor := PBEditor.new()
	dock.editor = editor

	editor.select_mode = PBEditor.SelectMode.EDGE
	assert_true(dock.mode_label.text.contains("Edge"), "Mode label should auto-update to Edge")

	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)
	editor.active_mesh = mesh

	editor.selection.add_face(0)
	assert_true(dock.selection_label.text.contains("F:1"), "Selection label should auto-update on element_selection_changed")

# ==============================================================================
# 6. Scene Instantiation & Off-Tree Lifecycle Tests
# ==============================================================================

func test_scene_instantiate():
	var scene := preload("res://addons/probuilder/gui/docks/pb_tool_properties_dock.tscn")
	var dock: PBToolPropertiesDock = scene.instantiate()
	add_child_autofree(dock)

	assert_not_null(dock, "Dock scene should instantiate as PBToolPropertiesDock")
	assert_eq(dock.title_label.text, "Tool Properties")
	assert_true(dock.tool_label.text.contains("Select"))

func test_refresh_and_build_ui_before_ready():
	var dock := PBToolPropertiesDock.new()
	# Call refresh without add_child (before _ready)
	dock.refresh()

	assert_not_null(dock.tool_label, "UI should be built by refresh() if called before _ready()")
	assert_true(dock.tool_label.text.contains("Select"))
	assert_eq(dock.settings_label.text, "—")

	# Now add to tree
	add_child_autofree(dock)
	assert_true(dock.tool_label.text.contains("Select"))
