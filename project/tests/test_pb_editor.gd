## Tests for Phase 4: Editor Integration
##
## Tests PBEditor state management, PBOverlay mesh generation, PBToolbar,
## and their integration. These are unit tests that run headlessly.
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

# ==============================================================================
# PBOverlay Tests
# ==============================================================================

func test_overlay_creates_wireframe_for_cube():
	var ov := PBOverlay.new()
	var mesh := PBMesh.create_cube(1.0)
	# Add to tree so children can be added
	add_child_autofree(mesh)

	ov.attach(mesh)
	ov.rebuild(PBEditor.SelectMode.FACE)

	# The wireframe overlay should exist as a child
	var wire := mesh.get_node_or_null("_pb_wireframe_overlay")
	assert_not_null(wire, "Wireframe overlay node should exist")
	assert_true(wire is MeshInstance3D, "Wireframe should be MeshInstance3D")
	assert_not_null(wire.mesh, "Wireframe should have a mesh")

	# Wireframe mesh should use PRIMITIVE_LINES
	var arr_mesh: ArrayMesh = wire.mesh as ArrayMesh
	assert_not_null(arr_mesh, "Should be ArrayMesh")
	assert_eq(arr_mesh.get_surface_count(), 1, "Should have one surface")
	assert_eq(arr_mesh.surface_get_primitive_type(0), Mesh.PRIMITIVE_LINES)

	# A cube has 6 faces × 4 edges = 24 edge segments → 48 line vertices
	# (some edges shared between faces, but face.get_edges() returns perimeter edges)
	var vertices: PackedVector3Array = arr_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	assert_gt(vertices.size(), 0, "Should have line vertices")
	# Each edge = 2 vertices, a cube has 12 unique edges, 6 faces with 4 edges each
	# but get_edges() returns boundary edges per face. For a cube each face has 4 edges,
	# and since each edge is shared by 2 faces, we get 6*4=24 edges = 48 vertices
	assert_eq(vertices.size(), 48, "Cube should have 24 edge segments (48 line vertices)")

	ov.detach()

func test_overlay_vertex_dots_in_vertex_mode():
	var ov := PBOverlay.new()
	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)

	ov.attach(mesh)
	ov.rebuild(PBEditor.SelectMode.VERTEX)

	var vert_node := mesh.get_node_or_null("_pb_vertex_overlay")
	assert_not_null(vert_node, "Vertex overlay node should exist")
	assert_not_null(vert_node.mesh, "Vertex overlay should have a mesh in VERTEX mode")

	var arr_mesh: ArrayMesh = vert_node.mesh as ArrayMesh
	assert_eq(arr_mesh.surface_get_primitive_type(0), Mesh.PRIMITIVE_POINTS)

	# A cube has 8 shared vertex groups
	var vertices: PackedVector3Array = arr_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	assert_eq(vertices.size(), 8, "Cube should show 8 vertex dots (one per shared group)")

	ov.detach()

func test_overlay_no_vertex_dots_in_face_mode():
	var ov := PBOverlay.new()
	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)

	ov.attach(mesh)
	ov.rebuild(PBEditor.SelectMode.FACE)

	var vert_node := mesh.get_node_or_null("_pb_vertex_overlay")
	assert_not_null(vert_node, "Vertex overlay node should exist")
	assert_null(vert_node.mesh, "Vertex overlay should have no mesh in FACE mode")

	ov.detach()

func test_overlay_no_vertex_dots_in_edge_mode():
	var ov := PBOverlay.new()
	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)

	ov.attach(mesh)
	ov.rebuild(PBEditor.SelectMode.EDGE)

	var vert_node := mesh.get_node_or_null("_pb_vertex_overlay")
	assert_not_null(vert_node, "Vertex overlay node should exist")
	assert_null(vert_node.mesh, "Vertex overlay should have no mesh in EDGE mode")

	ov.detach()

func test_overlay_detach_removes_children():
	var ov := PBOverlay.new()
	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)

	ov.attach(mesh)
	ov.rebuild(PBEditor.SelectMode.FACE)

	# Should have overlay children
	assert_not_null(mesh.get_node_or_null("_pb_wireframe_overlay"))
	assert_not_null(mesh.get_node_or_null("_pb_vertex_overlay"))

	ov.detach()
	# After frame, children should be queued for free
	# Since queue_free is deferred, the nodes still exist this frame but will be freed
	# For the test, just verify the overlay state is reset
	assert_null(ov._current_mesh, "Current mesh should be null after detach")

func test_overlay_attach_null():
	var ov := PBOverlay.new()
	ov.attach(null)
	assert_null(ov._current_mesh, "Should handle null attach gracefully")

func test_overlay_rebuild_without_attach():
	var ov := PBOverlay.new()
	# Should not crash
	ov.rebuild(PBEditor.SelectMode.FACE)
	assert_null(ov._current_mesh, "Should handle rebuild without attach gracefully")

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
# Integration Tests
# ==============================================================================

func test_full_workflow_select_mesh_change_modes():
	var ed := PBEditor.new()
	var ov := PBOverlay.new()
	var tb := PBToolbar.new()
	add_child_autofree(tb)

	tb.editor = ed

	# Create a PBMesh with a cube
	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)

	# Simulate selecting the mesh
	ed.active_mesh = mesh
	assert_eq(ed.select_mode, PBEditor.SelectMode.FACE, "Should auto-enter FACE mode")

	# Attach overlay
	ov.attach(mesh)
	ov.rebuild(ed.select_mode)

	# Verify wireframe exists
	var wire := mesh.get_node_or_null("_pb_wireframe_overlay")
	assert_not_null(wire)
	assert_not_null(wire.mesh)

	# Switch to vertex mode
	ed.select_mode = PBEditor.SelectMode.VERTEX
	ov.rebuild(ed.select_mode)

	# Verify vertex dots
	var vert := mesh.get_node_or_null("_pb_vertex_overlay")
	assert_not_null(vert)
	assert_not_null(vert.mesh, "Should have vertex dots in VERTEX mode")

	# Switch to edge mode
	ed.select_mode = PBEditor.SelectMode.EDGE
	ov.rebuild(ed.select_mode)
	assert_null(vert.mesh, "Should clear vertex dots in EDGE mode")

	# Deselect mesh
	ed.active_mesh = null
	ov.detach()
	assert_eq(ed.select_mode, PBEditor.SelectMode.OBJECT)

	assert_false(ed.is_editing())

func test_overlay_with_cylinder():
	var ov := PBOverlay.new()
	var data := PBShapeCylinder.create_cylinder(0.5, 1.0, 12, 1, 1)
	var mesh := PBMesh.new()
	mesh.pb_mesh_data = data
	add_child_autofree(mesh)

	ov.attach(mesh)
	ov.rebuild(PBEditor.SelectMode.VERTEX)

	var vert_node := mesh.get_node_or_null("_pb_vertex_overlay")
	assert_not_null(vert_node)
	assert_not_null(vert_node.mesh, "Should have vertex dots for cylinder")

	var arr_mesh: ArrayMesh = vert_node.mesh as ArrayMesh
	var vertices: PackedVector3Array = arr_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	# Cylinder with 12 sides, 1 height segment, caps: should have vertices
	assert_gt(vertices.size(), 0, "Should have vertex dots")

	ov.detach()

func test_overlay_with_shape_factory_shapes():
	# Test that overlay works with various shapes from the factory
	var ov := PBOverlay.new()

	for shape_id in PBShapeFactory.get_shape_ids():
		var data := PBShapeFactory.create_shape(shape_id, Vector3.ONE)
		if data == null:
			continue
		var mesh := PBMesh.new()
		mesh.pb_mesh_data = data
		add_child_autofree(mesh)

		ov.attach(mesh)
		ov.rebuild(PBEditor.SelectMode.FACE)

		var wire := mesh.get_node_or_null("_pb_wireframe_overlay")
		assert_not_null(wire, "Shape '%s' should have wireframe" % shape_id)
		assert_not_null(wire.mesh, "Shape '%s' wireframe should have mesh" % shape_id)

		ov.detach()
