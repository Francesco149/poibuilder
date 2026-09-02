## Tests for the v0.9.0 toolbar: mesh-op buttons live in the persistent
## toolbar now (NOT the overlay panel), enable per selection context, emit
## operation_requested; plus the Object mode button, Edit Params gating, and
## the Panel (overlay pin) toggle.
extends GutTest

var _ed: PBEditor
var _mesh: PBMesh

func before_each() -> void:
	_ed = PBEditor.new()
	_mesh = PBMesh.create_cube(1.0)
	add_child_autofree(_mesh)
	_ed.active_mesh = _mesh

func _make_toolbar() -> PBToolbar:
	var tb := PBToolbar.new()
	add_child_autofree(tb)
	tb.editor = _ed
	return tb

func _op(tb: PBToolbar, op_name: String) -> Button:
	return tb._op_buttons[op_name]

# ==============================================================================
# Op buttons exist + emit
# ==============================================================================

func test_all_op_buttons_exist():
	var tb := _make_toolbar()
	for op_name in ["extrude_faces", "inset_faces", "insert_edge_loop", "merge_faces",
			"subdivide_faces", "weld_vertices", "detach_faces", "delete_faces"]:
		assert_true(tb._op_buttons.has(op_name), "Toolbar carries op button: " + op_name)

func test_op_buttons_emit_operation_requested():
	var tb := _make_toolbar()
	_ed.select_mode = PBEditor.SelectMode.FACE
	_ed.selection.set_faces(PackedInt32Array([0]))
	var received: Array = []
	tb.operation_requested.connect(func(op): received.append(op))
	_op(tb, "extrude_faces").pressed.emit()
	_op(tb, "inset_faces").pressed.emit()
	_op(tb, "delete_faces").pressed.emit()
	assert_eq(received.size(), 3, "Op buttons emit operation_requested")
	assert_eq(received[0], "extrude_faces")

# ==============================================================================
# Context enable/disable
# ==============================================================================

func test_face_ops_enable_only_with_face_selection():
	var tb := _make_toolbar()
	_ed.select_mode = PBEditor.SelectMode.FACE

	_ed.selection.clear_all()
	assert_true(_op(tb, "extrude_faces").disabled, "Face ops greyed without a selection")
	assert_true(_op(tb, "inset_faces").disabled)
	assert_true(_op(tb, "merge_faces").disabled)
	assert_true(_op(tb, "subdivide_faces").disabled)
	assert_true(_op(tb, "detach_faces").disabled)
	assert_true(_op(tb, "delete_faces").disabled)
	assert_true(_op(tb, "insert_edge_loop").disabled, "Loop cut needs edges")
	assert_true(_op(tb, "weld_vertices").disabled, "Weld needs 2+ vertices")

	_ed.selection.set_faces(PackedInt32Array([0, 4]))
	assert_false(_op(tb, "extrude_faces").disabled, "Face ops enable with a face selection")
	assert_false(_op(tb, "inset_faces").disabled)
	assert_false(_op(tb, "delete_faces").disabled)
	assert_true(_op(tb, "insert_edge_loop").disabled, "Loop cut stays greyed in face mode")

func test_edge_ops_enable_in_edge_mode():
	var tb := _make_toolbar()
	_ed.select_mode = PBEditor.SelectMode.EDGE
	var edges := _mesh.pb_mesh_data.get_common_edges()
	_ed.selection.set_edges([edges[2]])
	assert_false(_op(tb, "insert_edge_loop").disabled, "Loop cut enables with an edge selection")
	assert_true(_op(tb, "extrude_faces").disabled, "Face ops stay greyed in edge mode")

func test_weld_enables_with_two_vertices():
	var tb := _make_toolbar()
	_ed.select_mode = PBEditor.SelectMode.VERTEX
	_ed.selection.set_vertices(PackedInt32Array([0]))
	assert_true(_op(tb, "weld_vertices").disabled, "One vertex cannot weld")
	_ed.selection.set_vertices(PackedInt32Array([0, 3]))
	assert_false(_op(tb, "weld_vertices").disabled, "Two vertices can weld")

func test_ops_disable_without_active_mesh():
	var tb := PBToolbar.new()
	add_child_autofree(tb)
	var ed2 := PBEditor.new()
	tb.editor = ed2
	ed2.select_mode = PBEditor.SelectMode.FACE
	ed2.selection.set_faces(PackedInt32Array([0]))
	assert_true(_op(tb, "extrude_faces").disabled,
		"Without an active mesh nothing is enabled (ed2 has no mesh)")

# ==============================================================================
# Object mode button (#9: object mode is its own mode)
# ==============================================================================

func test_object_mode_button_exists_and_follows_editor():
	var tb := _make_toolbar()
	assert_not_null(tb._btn_object, "The mode group carries an Object button")
	_ed.select_mode = PBEditor.SelectMode.OBJECT
	assert_true(tb._btn_object.button_pressed, "Object button pressed in OBJECT mode")
	_ed.select_mode = PBEditor.SelectMode.FACE
	assert_false(tb._btn_object.button_pressed)
	assert_true(tb._btn_face.button_pressed)

func test_object_button_switches_editor_mode():
	var tb := _make_toolbar()
	_ed.select_mode = PBEditor.SelectMode.FACE
	tb._btn_object.emit_signal("pressed")
	assert_eq(_ed.select_mode, PBEditor.SelectMode.OBJECT,
		"Clicking Object enters object mode")

func test_mode_buttons_enabled_in_object_mode():
	var tb := _make_toolbar()
	_ed.select_mode = PBEditor.SelectMode.OBJECT
	tb.set_editing_active(_ed.active_mesh != null)
	assert_false(tb._btn_face.disabled, "Element mode buttons stay enabled in OBJECT mode")
	assert_false(tb._btn_object.disabled, "Object button stays enabled in OBJECT mode")

# ==============================================================================
# Edit Params gating
# ==============================================================================

func test_edit_params_disabled_for_unmarked_mesh():
	var tb := _make_toolbar()
	assert_true(tb._btn_edit_params.disabled,
		"A mesh without shape bookkeeping cannot re-edit params")

func test_edit_params_enabled_for_pristine_shape():
	var tb := _make_toolbar()
	var data := _mesh.pb_mesh_data
	data.shape_id = &"cube"
	data.shape_params = {"width": 1.0, "height": 1.0, "depth": 1.0}
	data.shape_edited = false
	# In the editor the shape fields change right before this refresh runs
	# (signal-driven); tests trigger it manually.
	tb._on_selection_info_changed()
	assert_false(tb._btn_edit_params.disabled,
		"A pristine factory shape can re-edit params")

func test_edit_params_disabled_after_geometry_edit():
	var tb := _make_toolbar()
	var data := _mesh.pb_mesh_data
	data.shape_id = &"cube"
	data.shape_params = {"width": 1.0, "height": 1.0, "depth": 1.0}
	data.shape_edited = true
	tb._on_selection_info_changed()
	assert_true(tb._btn_edit_params.disabled,
		"An edited mesh cannot regenerate (edits would be destroyed)")

func test_edit_params_button_emits_request():
	var tb := _make_toolbar()
	var data := _mesh.pb_mesh_data
	data.shape_id = &"cube"
	data.shape_params = {}
	data.shape_edited = false
	var received: Array = []
	tb.edit_params_requested.connect(func(): received.append(1))
	tb._btn_edit_params.pressed.emit()
	assert_eq(received.size(), 1)

# ==============================================================================
# Panel (overlay pin) toggle
# ==============================================================================

func test_panel_toggle_emits_overlay_toggled():
	var tb := _make_toolbar()
	var received: Array = []
	tb.overlay_toggled.connect(func(p): received.append(p))
	tb._btn_overlay.button_pressed = true
	assert_eq(received.size(), 1)
	assert_true(received[0], "Panel toggle emits the pinned state")

func test_set_overlay_pinned_syncs_button():
	var tb := _make_toolbar()
	tb.set_overlay_pinned(true)
	assert_true(tb._btn_overlay.button_pressed, "Toolbar reflects the overlay pin state")
