## Tests for Phase 4/6: Editor Integration
##
## Tests PBEditor state management and PBToolbar, plus the PBElementEditor
## editing gate. Rendering/input itself is delegated to the native Godot
## editor via subgizmos — see test_pb_element_editor.gd for the full
## subgizmo behavior tests.
extends GutTest

# ==============================================================================
# PBEditor Tests
# ==============================================================================

func test_editor_default_mode():
	var ed := PBEditor.new()
	assert_eq(ed.select_mode, PBEditor.SelectMode.OBJECT, "Default mode should be OBJECT")
	assert_null(ed.active_mesh, "Default active_mesh should be null")
	assert_false(ed.is_editing(), "Should not be editing with no mesh")

func test_editor_mode_change_signal():
	var ed := PBEditor.new()
	var received_modes: Array = []
	ed.select_mode_changed.connect(func(mode): received_modes.append(mode))

	ed.select_mode = PBEditor.SelectMode.VERTEX
	assert_eq(received_modes.size(), 1, "Should receive one signal")
	assert_eq(received_modes[0], PBEditor.SelectMode.VERTEX)

	# Setting same mode should not emit
	ed.select_mode = PBEditor.SelectMode.VERTEX
	assert_eq(received_modes.size(), 1, "Same mode should not re-emit")

	ed.select_mode = PBEditor.SelectMode.EDGE
	assert_eq(received_modes.size(), 2)
	assert_eq(received_modes[1], PBEditor.SelectMode.EDGE)

func test_editor_active_mesh_enters_face_mode():
	var ed := PBEditor.new()
	var mesh := PBMesh.new()
	add_child_autofree(mesh)
	mesh.name = "TestMesh"

	ed.active_mesh = mesh
	assert_eq(ed.select_mode, PBEditor.SelectMode.FACE,
		"Selecting a PBMesh should enter FACE mode by default")
	assert_true(ed.is_editing(), "Should be editing")

func test_editor_active_mesh_null_reverts_to_object():
	var ed := PBEditor.new()
	var mesh := PBMesh.new()
	add_child_autofree(mesh)

	ed.active_mesh = mesh
	assert_eq(ed.select_mode, PBEditor.SelectMode.FACE)

	ed.active_mesh = null
	assert_eq(ed.select_mode, PBEditor.SelectMode.FACE,
		"Clearing active_mesh must REMEMBER the element mode (mode persistence)")
	assert_false(ed.is_editing())

	ed.select_mode = PBEditor.SelectMode.EDGE
	ed.active_mesh = null
	assert_eq(ed.select_mode, PBEditor.SelectMode.EDGE,
		"Mode stays as the user left it when deselecting")

func test_editor_mode_persists_across_deselect_and_reselect():
	var ed := PBEditor.new()
	var mesh := PBMesh.new()
	add_child_autofree(mesh)

	ed.active_mesh = mesh
	ed.select_mode = PBEditor.SelectMode.EDGE

	# Click off the object, then click back → still EDGE
	ed.active_mesh = null
	ed.active_mesh = mesh
	assert_eq(ed.select_mode, PBEditor.SelectMode.EDGE,
		"Re-entering a PBMesh must restore the last element mode")

	# Switch to another node (active_mesh = null) then a NEW mesh → still EDGE
	var mesh2 := PBMesh.new()
	add_child_autofree(mesh2)
	ed.active_mesh = null
	ed.active_mesh = mesh2
	assert_eq(ed.select_mode, PBEditor.SelectMode.EDGE)

	# FACE remembered too
	ed.select_mode = PBEditor.SelectMode.FACE
	ed.active_mesh = null
	ed.active_mesh = mesh
	assert_eq(ed.select_mode, PBEditor.SelectMode.FACE)

func test_editor_first_entry_defaults_to_face():
	var ed := PBEditor.new()
	var mesh := PBMesh.new()
	add_child_autofree(mesh)

	assert_eq(ed.select_mode, PBEditor.SelectMode.OBJECT,
		"A fresh editor starts in OBJECT (no mesh context)")
	ed.active_mesh = mesh
	assert_eq(ed.select_mode, PBEditor.SelectMode.FACE,
		"First entry defaults to FACE (ProBuilder behavior)")

func test_editor_active_mesh_preserves_mode():
	var ed := PBEditor.new()
	var mesh := PBMesh.new()
	add_child_autofree(mesh)

	ed.active_mesh = mesh
	ed.select_mode = PBEditor.SelectMode.EDGE

	# Selecting same mesh should not reset mode
	var mesh2 := PBMesh.new()
	add_child_autofree(mesh2)
	ed.active_mesh = mesh2
	assert_eq(ed.select_mode, PBEditor.SelectMode.EDGE,
		"Switching mesh should preserve current element mode")

func test_editor_active_mesh_signal():
	var ed := PBEditor.new()
	var received: Array = []
	ed.active_mesh_changed.connect(func(m): received.append(m))

	var mesh := PBMesh.new()
	add_child_autofree(mesh)
	ed.active_mesh = mesh
	assert_eq(received.size(), 1)
	assert_eq(received[0], mesh)

	ed.active_mesh = null
	assert_eq(received.size(), 2)
	assert_null(received[1])

func test_editor_mode_name():
	assert_eq(PBEditor.mode_name(PBEditor.SelectMode.OBJECT), "Object")
	assert_eq(PBEditor.mode_name(PBEditor.SelectMode.VERTEX), "Vertex")
	assert_eq(PBEditor.mode_name(PBEditor.SelectMode.EDGE), "Edge")
	assert_eq(PBEditor.mode_name(PBEditor.SelectMode.FACE), "Face")

func test_editor_orientation_space_cycles():
	var ed := PBEditor.new()
	assert_eq(ed.orientation_space, PBEditor.OrientationSpace.ELEMENT, "Default space is ELEMENT")

	ed.cycle_orientation_space()
	assert_eq(ed.orientation_space, PBEditor.OrientationSpace.OBJECT)
	ed.cycle_orientation_space()
	assert_eq(ed.orientation_space, PBEditor.OrientationSpace.WORLD)
	ed.cycle_orientation_space()
	assert_eq(ed.orientation_space, PBEditor.OrientationSpace.ELEMENT)

	var received: Array = []
	ed.orientation_space_changed.connect(func(s): received.append(s))
	ed.cycle_orientation_space()
	assert_eq(received.size(), 1)
	assert_eq(received[0], PBEditor.OrientationSpace.OBJECT)

func test_editor_tool_mode_default_and_signal():
	var ed := PBEditor.new()
	assert_eq(ed.tool_mode, PBEditor.ToolMode.MOVE, "Default tool is MOVE")

	var received: Array = []
	ed.tool_mode_changed.connect(func(t): received.append(t))

	ed.tool_mode = PBEditor.ToolMode.ROTATE
	assert_eq(received.size(), 1)
	assert_eq(received[0], PBEditor.ToolMode.ROTATE)

	# Same tool does not re-emit
	ed.tool_mode = PBEditor.ToolMode.ROTATE
	assert_eq(received.size(), 1)

func test_editor_tool_mode_is_independent_of_object_selection():
	var ed := PBEditor.new()
	var mesh := PBMesh.new()
	add_child_autofree(mesh)

	ed.active_mesh = mesh
	ed.tool_mode = PBEditor.ToolMode.SCALE
	ed.active_mesh = null
	assert_eq(ed.tool_mode, PBEditor.ToolMode.SCALE,
		"The plugin's transform tool persists across selection changes")

func test_editor_tool_mode_names():
	assert_eq(PBEditor.tool_name(PBEditor.ToolMode.MOVE), "Move")
	assert_eq(PBEditor.tool_name(PBEditor.ToolMode.ROTATE), "Rotate")
	assert_eq(PBEditor.tool_name(PBEditor.ToolMode.SCALE), "Scale")

func test_editor_hover_id_setter_emits_on_change_only():
	var ed := PBEditor.new()
	assert_eq(ed.hover_id, -1, "Default hover is -1 (nothing hovered)")

	var received: Array = []
	ed.hover_changed.connect(func(id): received.append(id))

	ed.hover_id = 4
	assert_eq(received.size(), 1)
	assert_eq(received[0], 4)
	assert_eq(ed.hover_id, 4)

	ed.hover_id = 4
	assert_eq(received.size(), 1, "Same hover id must not re-emit")

	ed.hover_id = -1
	assert_eq(received.size(), 2)
	assert_eq(received[1], -1)

# ==============================================================================
# PBToolbar Tests
# ==============================================================================

func test_toolbar_initial_state():
	var tb := PBToolbar.new()
	add_child_autofree(tb)

	# Logo, sep, Move/Rotate/Scale, sep, Vertex/Edge/Face, sep, Space,
	# sep, New Shape menu
	assert_eq(tb.get_child_count(), 13, "Toolbar should have 13 children")
	assert_true(tb._logo is TextureRect, "Toolbar should lead with the PoiBuilder logo")
	assert_eq(tb._btn_space.text, "Element", "Space button shows the current space")

func test_toolbar_icons_present():
	var tb := PBToolbar.new()
	add_child_autofree(tb)

	# Icons come from imported SVGs; after an editor import run they must be
	# loaded (text fallbacks only exist for fresh checkouts).
	for btn in [tb._btn_move, tb._btn_rotate, tb._btn_scale, tb._btn_vertex, tb._btn_edge, tb._btn_face]:
		assert_true(btn is Button, "Toolbar buttons must exist")
		if tb._logo.texture != null:
			assert_ne(btn.icon, null, "Toolbar buttons use SVG icons when icons are imported")

func test_toolbar_editor_binding_modes():
	var tb := PBToolbar.new()
	var ed := PBEditor.new()
	add_child_autofree(tb)

	tb.editor = ed

	# Default is OBJECT mode — no element buttons pressed
	assert_false(tb._btn_vertex.button_pressed)
	assert_false(tb._btn_edge.button_pressed)
	assert_false(tb._btn_face.button_pressed)

	# Change mode → buttons should update
	ed.select_mode = PBEditor.SelectMode.VERTEX
	assert_true(tb._btn_vertex.button_pressed, "Vertex button should be pressed in VERTEX mode")
	assert_false(tb._btn_edge.button_pressed)
	assert_false(tb._btn_face.button_pressed)

	ed.select_mode = PBEditor.SelectMode.EDGE
	assert_false(tb._btn_vertex.button_pressed)
	assert_true(tb._btn_edge.button_pressed, "Edge button should be pressed in EDGE mode")
	assert_false(tb._btn_face.button_pressed)

	ed.select_mode = PBEditor.SelectMode.FACE
	assert_false(tb._btn_vertex.button_pressed)
	assert_false(tb._btn_edge.button_pressed)
	assert_true(tb._btn_face.button_pressed, "Face button should be pressed in FACE mode")

func test_toolbar_editor_binding_tools_and_space():
	var tb := PBToolbar.new()
	var ed := PBEditor.new()
	add_child_autofree(tb)

	tb.editor = ed
	assert_true(tb._btn_move.button_pressed, "Default tool MOVE should be pressed")
	assert_false(tb._btn_rotate.button_pressed)
	assert_false(tb._btn_scale.button_pressed)

	ed.tool_mode = PBEditor.ToolMode.ROTATE
	assert_true(tb._btn_rotate.button_pressed, "Rotate should follow editor tool")
	assert_false(tb._btn_move.button_pressed)

	ed.orientation_space = PBEditor.OrientationSpace.WORLD
	assert_true(tb._btn_space.text.contains("World"), "Space button should show current space")

func test_toolbar_set_editing_active_disables_not_hides():
	var tb := PBToolbar.new()
	add_child_autofree(tb)

	tb.set_editing_active(false)
	assert_true(tb.visible, "The toolbar row is persistent — never hidden")
	for btn in [tb._btn_move, tb._btn_rotate, tb._btn_scale, tb._btn_space, tb._btn_vertex, tb._btn_edge, tb._btn_face]:
		assert_true(btn.disabled, "Buttons must be disabled outside editing context")

	tb.set_editing_active(true)
	for btn in [tb._btn_move, tb._btn_rotate, tb._btn_scale, tb._btn_space, tb._btn_vertex, tb._btn_edge, tb._btn_face]:
		assert_false(btn.disabled, "Buttons must be enabled while editing")

func test_toolbar_mode_button_signal():
	var tb := PBToolbar.new()
	var ed := PBEditor.new()
	add_child_autofree(tb)
	tb.editor = ed

	var received: Array = []
	tb.mode_button_pressed.connect(func(m): received.append(m))

	# Simulate pressing vertex button
	tb._btn_vertex.emit_signal("pressed")
	assert_eq(received.size(), 1)
	assert_eq(received[0], PBEditor.SelectMode.VERTEX)
	assert_eq(ed.select_mode, PBEditor.SelectMode.VERTEX,
		"Editor mode should update when button pressed")

func test_toolbar_tool_button_signal():
	var tb := PBToolbar.new()
	var ed := PBEditor.new()
	add_child_autofree(tb)
	tb.editor = ed

	var received: Array = []
	tb.tool_button_pressed.connect(func(t): received.append(t))

	tb._btn_scale.emit_signal("pressed")
	assert_eq(received.size(), 1)
	assert_eq(received[0], PBEditor.ToolMode.SCALE)
	assert_eq(ed.tool_mode, PBEditor.ToolMode.SCALE,
		"Editor tool should update when tool button pressed")

func test_toolbar_space_button_cycles():
	var tb := PBToolbar.new()
	var ed := PBEditor.new()
	add_child_autofree(tb)
	tb.editor = ed

	tb._btn_space.emit_signal("pressed")
	assert_eq(ed.orientation_space, PBEditor.OrientationSpace.OBJECT,
		"Space button should cycle the orientation space")

# ==============================================================================
# PBGizmoPlugin Editing Gate Tests
# ==============================================================================

func test_element_editor_is_editing_gate():
	var ed := PBEditor.new()
	var logic := PBElementEditor.new()
	logic.editor = ed
	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)
	ed.active_mesh = mesh
	ed.select_mode = PBEditor.SelectMode.FACE

	assert_true(logic.is_editing_node(mesh), "Editing when mesh is active and mode != OBJECT")

	ed.select_mode = PBEditor.SelectMode.OBJECT
	assert_false(logic.is_editing_node(mesh), "Not editing in OBJECT mode")

	var mesh2 := PBMesh.new()
	add_child_autofree(mesh2)
	ed.select_mode = PBEditor.SelectMode.FACE
	assert_false(logic.is_editing_node(mesh2), "Not editing a different mesh")
