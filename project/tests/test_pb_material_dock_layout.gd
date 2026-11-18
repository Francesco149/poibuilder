## Material & UV dock layout: the size budget and the resize controls.
##
## User feedback (v0.9.186): "the Material & UV panel is too wide and takes
## too much room — being able to resize it, including the material grid,
## would be perfect". The dock used to need 498 px of width (a row of six
## text tabs) and 916 px of height (nothing scrolled). These tests hold the
## new budget and the controls that let the user size the palette.
extends GutTest

## Generous headroom over the measured values (145-226 px wide headless,
## where SpinBox is wider than the editor's EditorSpinSlider), far below
## the old 498 px floor.
const MAX_MIN_WIDTH := 260.0
const MAX_MIN_HEIGHT := 440.0

var dock: PBMaterialDock

func before_each() -> void:
	dock = PBMaterialDock.new()
	add_child_autofree(dock)
	await wait_process_frames(2)

func test_every_mode_fits_a_narrow_short_dock():
	for mode in [PBMaterialDock.DockMode.MATERIAL, PBMaterialDock.DockMode.PAINT,
			PBMaterialDock.DockMode.STAMP, PBMaterialDock.DockMode.SPRITE,
			PBMaterialDock.DockMode.SHAPE, PBMaterialDock.DockMode.PARTICLE]:
		dock.set_dock_mode(mode)
		await wait_process_frames(1)
		var min_size := dock.get_combined_minimum_size()
		assert_lt(min_size.x, MAX_MIN_WIDTH, "mode %d: minimum width %.0f px fits a narrow dock" % [mode, min_size.x])
		assert_lt(min_size.y, MAX_MIN_HEIGHT, "mode %d: minimum height %.0f px (tools scroll)" % [mode, min_size.y])

func test_tools_live_in_their_own_scroll_below_a_resizable_split():
	assert_not_null(dock._split, "palette and tools share a SplitContainer")
	assert_true(dock._split.vertical, "side dock: palette above, tools below")
	assert_true(dock._uv_and_tint_section.get_parent().get_parent() == dock._tools_scroll,
		"tool sections scroll on their own")
	assert_true(dock._scroll.is_ancestor_of(dock._material_grid), "palette grid in its own scroll")

func test_bottom_panel_layout_puts_palette_beside_tools():
	dock.set_horizontal_layout(true)
	assert_false(dock._split.vertical, "horizontal layout: side by side")
	dock.set_horizontal_layout(false)
	assert_true(dock._split.vertical, "back to stacked")

func test_thumbnail_size_resizes_cards_in_place_and_clamps():
	dock.refresh_materials()
	await wait_process_frames(1)
	var cards := dock._material_grid.get_children()
	if cards.is_empty():
		fail_test("fixture: the palette has no cards (default material missing?)")
		return
	dock.set_thumbnail_size(96)
	assert_eq(dock.get_thumbnail_size(), 96)
	for c in cards:
		assert_eq((c as Control).custom_minimum_size, Vector2(96, 96), "material card follows the size")
	for c in dock._shape_palette_grid.get_children():
		assert_eq((c as Control).custom_minimum_size, Vector2(96, 96), "shape card follows the size")
	assert_eq(dock._thumb_slider.value, 96.0, "slider mirrors the size")
	assert_gte(dock._scroll.custom_minimum_size.y, 96.0, "palette keeps at least one card row")
	dock.set_thumbnail_size(5)
	assert_eq(dock.get_thumbnail_size(), PBMaterialDock.THUMB_MIN, "clamped to the minimum")
	dock.set_thumbnail_size(10000)
	assert_eq(dock.get_thumbnail_size(), PBMaterialDock.THUMB_MAX, "clamped to the maximum")
	# Rebuilt cards (mode switch) are born at the current size.
	dock.set_thumbnail_size(48)
	dock.set_dock_mode(PBMaterialDock.DockMode.SHAPE)
	dock.set_dock_mode(PBMaterialDock.DockMode.MATERIAL)
	await wait_process_frames(1)
	for c in dock._material_grid.get_children():
		if not c.is_queued_for_deletion():
			assert_eq((c as Control).custom_minimum_size, Vector2(48, 48), "rebuilt card born at the current size")

func test_ctrl_wheel_over_the_palette_resizes_cards():
	dock.set_thumbnail_size(64)
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_WHEEL_UP
	ev.pressed = true
	ev.ctrl_pressed = true
	dock._on_palette_gui_input(ev)
	assert_eq(dock.get_thumbnail_size(), 64 + PBMaterialDock.THUMB_STEP, "Ctrl+wheel up grows the cards")
	ev.button_index = MOUSE_BUTTON_WHEEL_DOWN
	dock._on_palette_gui_input(ev)
	assert_eq(dock.get_thumbnail_size(), 64, "Ctrl+wheel down shrinks them")
	ev.ctrl_pressed = false
	dock._on_palette_gui_input(ev)
	assert_eq(dock.get_thumbnail_size(), 64, "a plain wheel is left to scrolling")

func test_filter_hides_non_matching_cards():
	dock.refresh_materials()
	await wait_process_frames(1)
	var cards: Array = []
	for c in dock._material_grid.get_children():
		if not c.is_queued_for_deletion():
			cards.append(c)
	if cards.size() < 2:
		fail_test("fixture: need at least two palette cards, got %d" % cards.size())
		return
	var target: String = str(cards[0].get_meta("pb_card_name")).split(" ")[0]
	dock._filter_edit.text = target
	dock._filter_edit.text_changed.emit(target)
	var shown := 0
	for c in cards:
		if c.visible:
			shown += 1
			assert_true(str(c.get_meta("pb_card_name")).contains(target.to_lower()), "a shown card matches")
	assert_gt(shown, 0, "the matching card stays")
	assert_lt(shown, cards.size(), "non-matching cards hide")
	dock._filter_edit.text = ""
	dock._filter_edit.text_changed.emit("")
	for c in cards:
		assert_true(c.visible, "clearing the filter shows everything")

func test_mode_row_is_one_exclusive_group_and_compacts_to_icons():
	var group: ButtonGroup = dock._btn_mode_mat.button_group
	assert_not_null(group, "mode buttons share a ButtonGroup")
	for b in [dock._btn_mode_paint, dock._btn_mode_stamp, dock._btn_mode_sprite,
			dock._btn_mode_shape, dock._btn_mode_particle]:
		assert_eq(b.button_group, group, "every mode button is in the group")
	assert_true(dock._mode_row is HFlowContainer, "the mode row wraps instead of forcing width")
	# Headless has no editor icons: give one button an icon to exercise the
	# compact path, which drops captions only where an icon remains.
	dock._btn_mode_paint.icon = PlaceholderTexture2D.new()
	dock.size = Vector2(200, 400)
	dock._update_compact_modes()
	assert_eq(dock._btn_mode_paint.text, "", "narrow: icon-only")
	assert_eq(dock._btn_mode_mat.text, "Material", "no icon: the caption stays")
	assert_false(dock._btn_mode_paint.tooltip_text.is_empty(), "the tooltip still names the mode")
	dock.size = Vector2(500, 400)
	dock._update_compact_modes()
	assert_eq(dock._btn_mode_paint.text, "Paint", "wide: captions back")

func test_long_captions_clip_instead_of_widening_the_dock():
	assert_true(dock._btn_diagonal.clip_text, "long standalone button clips")
	assert_eq(dock._btn_diagonal.text_overrun_behavior, TextServer.OVERRUN_TRIM_ELLIPSIS)
	assert_false(dock._btn_diagonal.tooltip_text.is_empty(), "full text stays in the tooltip")
	assert_eq(dock._btn_scroll_clear.size_flags_horizontal & Control.SIZE_EXPAND, Control.SIZE_EXPAND,
		"a clipped button in a row expands (else it collapses to an ellipsis)")

## Status readouts must wrap, not widen: the Optimize Paint result in the
## button's row once set the dock's minimum width to 257 px in the editor.
func test_optimize_readout_wraps_instead_of_widening():
	dock.set_dock_mode(PBMaterialDock.DockMode.PAINT)
	dock._lbl_optimize_result.text = "12 mask(s): 400.0 MB -> 0.1 MB, a long readout that must wrap"
	await wait_process_frames(1)
	assert_lt(dock.get_combined_minimum_size().x, MAX_MIN_WIDTH, "a long readout does not widen the dock")

func test_paint_grid_rows_pair_up_and_dropdowns_fill_their_cell():
	var grid := dock._spin_paint_layer.get_parent() as GridContainer
	assert_not_null(grid, "layer spinner lives in the paint grid")
	var idx := dock._spin_paint_layer.get_index()
	assert_eq(idx % 2, 1, "the layer spinner sits in the value column")
	assert_true(grid.get_child(idx - 1) is Label, "and has its label")
	assert_eq(grid.get_child_count() % 2, 0, "every grid row is label + value")
	for ob in [dock._opt_paint_target, dock._opt_brush_source]:
		assert_eq(ob.size_flags_horizontal & Control.SIZE_EXPAND, Control.SIZE_EXPAND,
			"%s expands to fill its cell" % ob.name)

