## Tests for the toolbar New Shape menu (Phase 9-lite creation entry point).
##
## The menu must be populated from PBShapeFactory and emit shape_requested;
## creation itself (node placement, undo) is editor-bound plugin logic, but
## the factory → PBMeshData path it relies on is verified here too.
extends GutTest

func _make_toolbar() -> PBToolbar:
	var tb := PBToolbar.new()
	add_child_autofree(tb)
	return tb

# ==============================================================================
# Menu wiring
# ==============================================================================

func test_new_shape_menu_exists_and_is_enabled_without_editing():
	var tb := _make_toolbar()
	tb.set_editing_active(false)
	var btn := tb.new_shape_button()
	assert_not_null(btn, "New Shape menu button must exist")
	assert_false(btn.disabled, "New Shape stays enabled with nothing selected")
	assert_true(btn is MenuButton)

func test_new_shape_menu_lists_all_factory_shapes():
	var tb := _make_toolbar()
	var popup: PopupMenu = tb.new_shape_button().get_popup()
	var ids := PBShapeFactory.get_shape_ids()
	assert_eq(popup.item_count, ids.size(), "One menu item per factory shape")

func test_picking_menu_item_emits_shape_requested():
	var tb := _make_toolbar()
	var received: Array = []
	tb.shape_requested.connect(func(id): received.append(id))
	var popup: PopupMenu = tb.new_shape_button().get_popup()

	popup.id_pressed.emit(0)
	popup.id_pressed.emit(popup.item_count - 1)
	assert_eq(received.size(), 2, "Menu picks emit shape_requested")
	assert_eq(received[0], PBShapeFactory.get_shape_ids()[0])
	assert_eq(received[1], PBShapeFactory.get_shape_ids()[PBShapeFactory.get_shape_ids().size() - 1])

func test_out_of_range_menu_id_is_ignored():
	var tb := _make_toolbar()
	var received: Array = []
	tb.shape_requested.connect(func(id): received.append(id))
	tb.new_shape_button().get_popup().id_pressed.emit(999)
	assert_eq(received.size(), 0, "Out-of-range ids must not emit")

# ==============================================================================
# Factory path behind creation
# ==============================================================================

func test_every_factory_shape_builds_valid_mesh_data():
	for shape_id in PBShapeFactory.get_shape_ids():
		var data := PBShapeFactory.create_shape(shape_id)
		assert_not_null(data, "%s generates mesh data" % shape_id)
		if data == null:
			continue
		assert_eq(data.validate(), "", "%s mesh data validates" % shape_id)

func test_unknown_shape_id_is_rejected():
	assert_null(PBShapeFactory.create_shape(&"definitely_not_a_shape"))
	assert_false(PBShapeFactory.is_valid_shape(&"definitely_not_a_shape"))
