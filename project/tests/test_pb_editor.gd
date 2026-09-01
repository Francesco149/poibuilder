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
	assert_eq(ed.select_mode, PBEditor.SelectMode.OBJECT,
		"Clearing active_mesh should revert to OBJECT mode")
	assert_false(ed.is_editing())

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

# ==============================================================================
# PBToolbar Tests
# ==============================================================================

func test_toolbar_initial_state():
	var tb := PBToolbar.new()
	add_child_autofree(tb)

	# Should have children: separator, label, vertex, edge, face buttons
	assert_eq(tb.get_child_count(), 5, "Toolbar should have 5 children")
	assert_true(tb._label is Label)
	assert_eq(tb._label.text, "ProBuilder")

func test_toolbar_editor_binding():
	var tb := PBToolbar.new()
	var ed := PBEditor.new()
	add_child_autofree(tb)

	tb.editor = ed

	# Default is OBJECT mode — no buttons pressed
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

func test_toolbar_activate_deactivate():
	var tb := PBToolbar.new()
	add_child_autofree(tb)

	tb.deactivate()
	assert_false(tb.visible, "Should be hidden after deactivate")

	tb.activate()
	assert_true(tb.visible, "Should be visible after activate")

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
