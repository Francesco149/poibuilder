## Tests for the orientation-space → engine local-coords bridge (v0.8.0).
##
## The engine's transform gizmo only adopts a subgizmo's basis while its
## "Use Local Space" toggle is ON (node_3d_editor_plugin.cpp,
## update_transform_gizmo: `if (... && local_gizmo_coords) gizmo_basis =
## xf.basis;`). PBToolBridge drives that toggle so PBEditor.orientation_space
## actually orients the gizmo. The engine internals are unavailable headless,
## so these tests exercise the bridge's decisions with stand-in buttons
## (physical-key fallback resolution, as in test_pb_tool_bridge.gd).
extends GutTest

## Root of the current test's stand-in button tree (freed by GUT autofree).
var _root: Node

func _make_toggle(path: String, key: Key) -> Button:
	var btn := Button.new()
	btn.name = "Btn_" + path
	btn.toggle_mode = true
	var sc := Shortcut.new()
	var ev := InputEventKey.new()
	ev.physical_keycode = key
	sc.events = [ev]
	btn.shortcut = sc
	return btn

## Full engine tool set INCLUDING the local-coords toggle (T).
func _make_bridge_with_local() -> PBToolBridge:
	_root = Node.new()
	_root.name = "EngineTools"
	for data in [["spatial_editor/tool_move", KEY_W],
			["spatial_editor/tool_rotate", KEY_E], ["spatial_editor/tool_scale", KEY_R],
			["spatial_editor/tool_transform", KEY_Q], ["spatial_editor/tool_select", KEY_V],
			["spatial_editor/local_coords", KEY_T]]:
		_root.add_child(_make_toggle(data[0], data[1]))
	add_child_autofree(_root)
	return PBToolBridge.new()

## Only the five tool buttons, no local-coords toggle (older engine / degraded).
func _make_bridge_without_local() -> PBToolBridge:
	_root = Node.new()
	for data in [["spatial_editor/tool_move", KEY_W],
			["spatial_editor/tool_rotate", KEY_E], ["spatial_editor/tool_scale", KEY_R],
			["spatial_editor/tool_transform", KEY_Q], ["spatial_editor/tool_select", KEY_V]]:
		_root.add_child(_make_toggle(data[0], data[1]))
	add_child_autofree(_root)
	return PBToolBridge.new()

func _local_btn() -> Button:
	return _root.get_child(5)

# ==============================================================================
# Space → toggle mapping (the engine contract)
# ==============================================================================

func test_local_coords_mapping():
	assert_false(PBToolBridge.local_coords_for_space(PBEditor.OrientationSpace.WORLD),
		"WORLD must map to the engine toggle OFF (gizmo basis identity = world axes)")
	assert_true(PBToolBridge.local_coords_for_space(PBEditor.OrientationSpace.ELEMENT),
		"ELEMENT must map to the engine toggle ON (gizmo adopts subgizmo basis)")
	assert_true(PBToolBridge.local_coords_for_space(PBEditor.OrientationSpace.OBJECT),
		"OBJECT must map to the engine toggle ON (subgizmo basis = identity = node axes)")

# ==============================================================================
# Applying the space
# ==============================================================================

func test_apply_orientation_space_flips_toggle():
	var bridge := _make_bridge_with_local()
	assert_true(bridge.setup(_root))
	assert_true(bridge.has_local_coords())
	assert_false(_local_btn().button_pressed, "Engine toggle starts OFF (stock editor default)")

	assert_true(bridge.apply_orientation_space(PBEditor.OrientationSpace.ELEMENT))
	assert_true(_local_btn().button_pressed, "ELEMENT presses the toggle ON")

	assert_true(bridge.apply_orientation_space(PBEditor.OrientationSpace.WORLD))
	assert_false(_local_btn().button_pressed, "WORLD presses the toggle OFF")

	assert_true(bridge.apply_orientation_space(PBEditor.OrientationSpace.OBJECT))
	assert_true(_local_btn().button_pressed, "OBJECT presses the toggle ON")

func test_apply_orientation_space_is_noop_when_already_set():
	var bridge := _make_bridge_with_local()
	bridge.setup(_root)
	_local_btn().button_pressed = true

	var flips: Array = []
	_local_btn().toggled.connect(func(p): flips.append(p))

	bridge.apply_orientation_space(PBEditor.OrientationSpace.ELEMENT)
	assert_eq(flips.size(), 0, "Redundant press must not fire the engine's toggled handler")

func test_apply_without_local_toggle_reports_false():
	var bridge := _make_bridge_without_local()
	bridge.setup(_root)
	assert_false(bridge.has_local_coords())
	assert_false(bridge.apply_orientation_space(PBEditor.OrientationSpace.ELEMENT),
		"Degraded bridge reports the space was NOT applied")
	assert_true(bridge.is_ready(), "Tool modes still work without the space toggle")

# ==============================================================================
# Editing context: the toggle is pinned out like Q/V
# ==============================================================================

func test_editing_disables_local_toggle_and_restores_state():
	var bridge := _make_bridge_with_local()
	bridge.setup(_root)
	_local_btn().button_pressed = true  # user had local coords on before editing

	bridge.set_editing_active(true)
	assert_true(_local_btn().disabled, "Local-coords toggle disabled while editing (T pinned out)")

	_local_btn().button_pressed = false  # simulate a stray flip reaching a disabled button
	bridge.set_editing_active(false)
	assert_false(_local_btn().disabled, "Toggle re-enabled after editing")
	assert_true(_local_btn().button_pressed, "Pre-editing toggle state restored")

func test_set_editing_active_without_local_toggle_is_safe():
	var bridge := _make_bridge_without_local()
	bridge.setup(_root)
	bridge.set_editing_active(true)
	bridge.set_editing_active(false)
	assert_true(true, "No crash when the local-coords toggle is absent")

# ==============================================================================
# External flips while editing are re-asserted
# ==============================================================================

func test_external_flip_while_editing_is_reverted():
	var bridge := _make_bridge_with_local()
	bridge.setup(_root)
	bridge.editor_space = PBEditor.OrientationSpace.ELEMENT
	bridge.set_editing_active(true)
	bridge.apply_orientation_space(PBEditor.OrientationSpace.ELEMENT)
	assert_true(_local_btn().button_pressed)

	# A path that bypassed the disabled button flipped it OFF — the listener
	# must re-assert the plugin's space.
	_local_btn().button_pressed = false
	assert_true(_local_btn().button_pressed,
		"External OFF flip while editing snaps back to the plugin's space")

func test_external_flip_outside_editing_is_kept():
	var bridge := _make_bridge_with_local()
	bridge.setup(_root)
	bridge.editor_space = PBEditor.OrientationSpace.ELEMENT
	bridge.set_editing_active(false)

	_local_btn().button_pressed = true
	assert_true(_local_btn().button_pressed,
		"Outside editing the toggle is stock editor UI — user flips are kept")

func test_own_press_does_not_retrigger():
	var bridge := _make_bridge_with_local()
	bridge.setup(_root)
	bridge.editor_space = PBEditor.OrientationSpace.WORLD
	bridge.set_editing_active(true)

	var logger := PBLogger.new()
	var warns: Array = []
	logger.entry_added.connect(func(entry): if entry.level >= PBLogger.Level.WARN: warns.append(1))
	bridge.logger = logger

	bridge.apply_orientation_space(PBEditor.OrientationSpace.WORLD)
	assert_eq(warns.size(), 0, "Our own press must not count as an external flip")
	assert_false(_local_btn().button_pressed)
