## Tests for the overlay OPERATIONS section (Phase 7): op buttons exist,
## enable per selection context, emit operation_requested, and expose the
## numeric params the plugin reads (extrude distance, inset amount).
extends GutTest

func _make_overlay_with_selection() -> Array:
	var overlay := PBToolOverlay.new()
	add_child_autofree(overlay)
	var editor := PBEditor.new()
	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)
	editor.active_mesh = mesh
	overlay.editor = editor
	return [overlay, editor, mesh]

# ==============================================================================
# Section existence
# ==============================================================================

func test_operations_controls_exist():
	var overlay: PBToolOverlay = _make_overlay_with_selection()[0]
	for btn: Button in [overlay.extrude_faces_btn, overlay.inset_btn,
			overlay.subdivide_btn, overlay.merge_btn, overlay.delete_btn,
			overlay.detach_btn, overlay.extrude_edges_btn]:
		assert_not_null(btn, "Op button must exist")
		assert_true(btn is Button)
	assert_not_null(overlay.extrude_distance_spin, "Extrude distance SpinBox must exist")
	assert_not_null(overlay.inset_amount_spin, "Inset amount SpinBox must exist")

func test_numeric_params_expose_spin_values():
	var overlay: PBToolOverlay = _make_overlay_with_selection()[0]
	overlay.extrude_distance_spin.value = 1.5
	overlay.inset_amount_spin.value = 0.4
	# SpinBox normalizes values through its step (float noise) — compare loosely.
	assert_almost_eq(overlay.extrude_distance, 1.5, 0.051, "Plugin reads the extrude distance")
	assert_almost_eq(overlay.inset_amount, 0.4, 0.051, "Plugin reads the inset amount")
	# Defaults stay sane when the UI was never built
	var bare := PBToolOverlay.new()
	assert_almost_eq(bare.extrude_distance, 0.25, 0.0001, "Default extrude distance")
	assert_almost_eq(bare.inset_amount, 0.25, 0.0001, "Default inset amount")

# ==============================================================================
# Context enablement
# ==============================================================================

func test_face_ops_enable_only_with_face_selection():
	var setup := _make_overlay_with_selection()
	var overlay: PBToolOverlay = setup[0]
	var editor: PBEditor = setup[1]

	editor.select_mode = PBEditor.SelectMode.FACE
	overlay.refresh()
	for btn: Button in [overlay.extrude_faces_btn, overlay.inset_btn,
			overlay.subdivide_btn, overlay.merge_btn, overlay.delete_btn,
			overlay.detach_btn]:
		assert_true(btn.disabled, "%s must be disabled with an empty selection" % btn.name)
	assert_true(overlay.extrude_edges_btn.disabled, "Edge extrude disabled without edges")

	editor.selection.set_faces(PackedInt32Array([0, 4]))
	overlay.refresh()
	for btn: Button in [overlay.extrude_faces_btn, overlay.inset_btn,
			overlay.subdivide_btn, overlay.merge_btn, overlay.delete_btn,
			overlay.detach_btn]:
		assert_false(btn.disabled, "%s must enable when faces are selected" % btn.name)
	assert_true(overlay.extrude_edges_btn.disabled, "Edge extrude still disabled (no edges)")

func test_edge_extrude_enables_with_edge_selection():
	var setup := _make_overlay_with_selection()
	var overlay: PBToolOverlay = setup[0]
	var editor: PBEditor = setup[1]
	var mesh: PBMesh = setup[2]

	editor.select_mode = PBEditor.SelectMode.EDGE
	var edges := mesh.pb_mesh_data.get_common_edges()
	editor.selection.set_edges([edges[0], edges[1]] as Array[PBEdge])
	overlay.refresh()
	assert_false(overlay.extrude_edges_btn.disabled, "Edge extrude enables with edges")
	assert_true(overlay.extrude_faces_btn.disabled, "Face ops stay disabled in edge mode")

# ==============================================================================
# operation_requested signal
# ==============================================================================

func test_op_buttons_emit_operation_requested():
	var overlay: PBToolOverlay = _make_overlay_with_selection()[0]
	var received: Array = []
	overlay.operation_requested.connect(func(op): received.append(op))

	overlay.extrude_faces_btn.pressed.emit()
	overlay.inset_btn.pressed.emit()
	overlay.subdivide_btn.pressed.emit()
	overlay.merge_btn.pressed.emit()
	overlay.delete_btn.pressed.emit()
	overlay.detach_btn.pressed.emit()
	overlay.extrude_edges_btn.pressed.emit()
	overlay.loop_cut_btn.pressed.emit()

	assert_eq(received, ["extrude_faces", "inset_faces", "subdivide_faces",
		"merge_faces", "delete_faces", "detach_faces", "extrude_edges",
		"insert_edge_loop"] as Array,
		"Each button emits its op name")

# ==============================================================================
# MeshOp plumbing behind the buttons (selection → op → selection reset)
# ==============================================================================

func test_common_edge_ids_from_selection_roundtrip():
	var mesh := PBMesh.create_cube(1.0)
	add_child_autofree(mesh)
	var data := mesh.pb_mesh_data
	var edges := data.get_common_edges()

	var ids := PBMeshOps.common_edge_ids(data, [edges[2], edges[7]] as Array[PBEdge])
	assert_eq(ids.size(), 2)
	assert_has(ids, 2)
	assert_has(ids, 7)

func test_delete_via_command_restores_on_undo():
	# The plugin wraps ops in CmdMeshOp; verify the round trip it relies on.
	var data := PBMeshData.create_cube(1.0)
	var cmd := CmdMeshOp.new(data, "Delete Faces")
	var result := PBMeshOps.delete_faces(data, PackedInt32Array([4]))
	assert_true(result["ok"])
	cmd.capture_after()
	cmd.add_to_undo_manager(null)  # null manager must be a safe no-op

	cmd.undo_it()
	assert_eq(data.faces.size(), 6, "Undo restores the deleted face")
	cmd.do_it()
	assert_eq(data.faces.size(), 5, "Redo re-deletes")
