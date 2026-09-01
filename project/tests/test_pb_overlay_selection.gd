extends GutTest

## Tests for PBOverlay selection rendering integration.
## Verifies that overlay correctly renders selection highlights
## for vertices, edges, and faces.


func test_overlay_face_selection_rendering() -> void:
	var ov := PBOverlay.new()
	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)

	var sel := PBSelection.new(mesh.pb_mesh_data)
	sel.add_face(0)

	ov.attach(mesh)
	ov.rebuild(PBEditor.SelectMode.FACE, sel)

	var sel_node := mesh.get_node_or_null("_pb_selection_overlay")
	assert_not_null(sel_node, "Selection overlay node should exist")
	assert_not_null(sel_node.mesh, "Face selection should generate mesh")

	var arr_mesh: ArrayMesh = sel_node.mesh as ArrayMesh
	assert_eq(arr_mesh.surface_get_primitive_type(0), Mesh.PRIMITIVE_TRIANGLES,
		"Selected faces should be rendered as triangles")

	var verts: PackedVector3Array = arr_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	assert_gt(verts.size(), 0, "Should have triangle vertices for selected face")

	ov.detach()


func test_overlay_face_no_selection() -> void:
	var ov := PBOverlay.new()
	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)

	var sel := PBSelection.new(mesh.pb_mesh_data)
	# No faces selected

	ov.attach(mesh)
	ov.rebuild(PBEditor.SelectMode.FACE, sel)

	var sel_node := mesh.get_node_or_null("_pb_selection_overlay")
	assert_not_null(sel_node, "Selection overlay node should exist")
	assert_null(sel_node.mesh, "No faces selected should result in no mesh")

	ov.detach()


func test_overlay_edge_selection_rendering() -> void:
	var ov := PBOverlay.new()
	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)

	var sel := PBSelection.new(mesh.pb_mesh_data)
	var edges: Array[PBEdge] = mesh.pb_mesh_data.faces[0].get_edges()
	sel.add_edge(edges[0])

	ov.attach(mesh)
	ov.rebuild(PBEditor.SelectMode.EDGE, sel)

	var sel_node := mesh.get_node_or_null("_pb_selection_overlay")
	assert_not_null(sel_node, "Selection overlay node should exist")
	assert_not_null(sel_node.mesh, "Edge selection should generate mesh")

	var arr_mesh: ArrayMesh = sel_node.mesh as ArrayMesh
	assert_eq(arr_mesh.surface_get_primitive_type(0), Mesh.PRIMITIVE_LINES,
		"Selected edges should be rendered as lines")

	var verts: PackedVector3Array = arr_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	assert_eq(verts.size(), 2, "One selected edge should produce 2 line vertices")

	ov.detach()


func test_overlay_vertex_selection_rendering() -> void:
	var ov := PBOverlay.new()
	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)

	var sel := PBSelection.new(mesh.pb_mesh_data)
	sel.add_vertex(0)
	sel.add_vertex(1)

	ov.attach(mesh)
	ov.rebuild(PBEditor.SelectMode.VERTEX, sel)

	# Unselected vertex overlay
	var vert_node := mesh.get_node_or_null("_pb_vertex_overlay")
	assert_not_null(vert_node)
	assert_not_null(vert_node.mesh, "Should have unselected vertex mesh")
	var unselected_mesh: ArrayMesh = vert_node.mesh as ArrayMesh
	var unselected_verts: PackedVector3Array = unselected_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	# 8 total shared vertices - 2 selected = 6 unselected
	assert_eq(unselected_verts.size(), 6, "Should have 6 unselected vertex dots")

	# Selected vertex overlay
	var sel_vert_node := mesh.get_node_or_null("_pb_selected_vertex_overlay")
	assert_not_null(sel_vert_node)
	assert_not_null(sel_vert_node.mesh, "Should have selected vertex mesh")
	var selected_mesh: ArrayMesh = sel_vert_node.mesh as ArrayMesh
	var selected_verts: PackedVector3Array = selected_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	assert_eq(selected_verts.size(), 2, "Should have 2 selected vertex dots")

	ov.detach()


func test_overlay_vertex_all_selected() -> void:
	var ov := PBOverlay.new()
	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)

	var sel := PBSelection.new(mesh.pb_mesh_data)
	sel.select_all(PBEditor.SelectMode.VERTEX)

	ov.attach(mesh)
	ov.rebuild(PBEditor.SelectMode.VERTEX, sel)

	# All vertices selected — unselected should be empty
	var vert_node := mesh.get_node_or_null("_pb_vertex_overlay")
	assert_null(vert_node.mesh, "No unselected vertices should result in no mesh")

	# Selected vertex overlay should show all 8
	var sel_vert_node := mesh.get_node_or_null("_pb_selected_vertex_overlay")
	assert_not_null(sel_vert_node.mesh)
	var selected_mesh: ArrayMesh = sel_vert_node.mesh as ArrayMesh
	var selected_verts: PackedVector3Array = selected_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	assert_eq(selected_verts.size(), 8, "All 8 vertices should be selected")

	ov.detach()


func test_overlay_multi_face_selection() -> void:
	var ov := PBOverlay.new()
	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)

	var sel := PBSelection.new(mesh.pb_mesh_data)
	sel.add_face(0)
	sel.add_face(1)
	sel.add_face(2)

	ov.attach(mesh)
	ov.rebuild(PBEditor.SelectMode.FACE, sel)

	var sel_node := mesh.get_node_or_null("_pb_selection_overlay")
	assert_not_null(sel_node.mesh)
	var arr_mesh: ArrayMesh = sel_node.mesh as ArrayMesh
	var verts: PackedVector3Array = arr_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	# Each face has 2 triangles = 6 vertices, 3 faces = 18
	assert_eq(verts.size(), 18, "3 selected faces should produce 18 triangle vertices")

	ov.detach()


func test_overlay_null_selection_still_works() -> void:
	# Backward compat: calling rebuild without selection should not crash
	var ov := PBOverlay.new()
	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)

	ov.attach(mesh)
	ov.rebuild(PBEditor.SelectMode.FACE)  # No selection param
	ov.rebuild(PBEditor.SelectMode.VERTEX)
	ov.rebuild(PBEditor.SelectMode.EDGE)

	# Wireframe should still work
	var wire := mesh.get_node_or_null("_pb_wireframe_overlay")
	assert_not_null(wire)
	assert_not_null(wire.mesh)

	ov.detach()


func test_overlay_mode_switch_clears_previous() -> void:
	var ov := PBOverlay.new()
	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)

	var sel := PBSelection.new(mesh.pb_mesh_data)
	sel.add_face(0)

	ov.attach(mesh)

	# Render face selection
	ov.rebuild(PBEditor.SelectMode.FACE, sel)
	var sel_node := mesh.get_node_or_null("_pb_selection_overlay")
	assert_not_null(sel_node.mesh, "Should have face selection mesh")

	# Switch to vertex mode — should clear face selection overlay
	ov.rebuild(PBEditor.SelectMode.VERTEX, sel)
	assert_null(sel_node.mesh, "Face selection should be cleared in vertex mode")

	ov.detach()
