## Tests for the plugin-owned tool modes bridge (P7 UX round).
##
## PBToolBridge mirrors PBEditor.tool_mode onto the engine's Node3DEditor
## tool buttons and pins out the universal (Q) and select (V) tools while a
## PBMesh is being edited. The engine internals are not available headless,
## so these tests exercise the bridge's decisions with stand-in buttons in a
## plain Node tree (the shortcut-instance identity pass is skipped headless;
## the physical-key fallback resolution is what runs here).
extends GutTest

## Root of the current test's stand-in button tree (fresh per test; freed by
## GUT's autofree).
var _root: Node

func _make_tool_button(path: String, key: Key) -> Button:
	var btn := Button.new()
	btn.name = "Btn_" + path
	btn.toggle_mode = true
	var sc := Shortcut.new()
	var ev := InputEventKey.new()
	ev.physical_keycode = key
	sc.events = [ev]
	btn.shortcut = sc
	btn.set_meta("path", path)
	return btn

func _make_bridge_with_buttons() -> PBToolBridge:
	# Fresh subtree per test: move(W), rotate(E), scale(R), universal(Q), select(V)
	_root = Node.new()
	_root.name = "EngineTools"
	for child_data in [["spatial_editor/tool_move", KEY_W],
			["spatial_editor/tool_rotate", KEY_E], ["spatial_editor/tool_scale", KEY_R],
			["spatial_editor/tool_transform", KEY_Q], ["spatial_editor/tool_select", KEY_V]]:
		_root.add_child(_make_tool_button(child_data[0], child_data[1]))
	add_child_autofree(_root)

	var bridge := PBToolBridge.new()
	return bridge

# ==============================================================================
# Discovery
# ==============================================================================

func test_setup_finds_all_engine_tool_buttons():
	var bridge := _make_bridge_with_buttons()
	assert_true(bridge.setup(_root), "All five tool buttons should resolve")
	assert_true(bridge.is_ready())

func test_setup_fails_gracefully_without_buttons():
	var empty_root := Node.new()
	add_child_autofree(empty_root)
	var bridge := PBToolBridge.new()
	assert_false(bridge.setup(empty_root), "No buttons → setup reports not ready")
	assert_false(bridge.is_ready())

func test_setup_finds_nested_buttons():
	var nested := Node.new()
	var move_btn := _make_tool_button("spatial_editor/tool_move", KEY_W)
	nested.add_child(move_btn)
	var deeper := Node.new()
	deeper.add_child(Node.new())
	deeper.get_child(0).add_child(_make_tool_button("spatial_editor/tool_rotate", KEY_E))
	nested.add_child(deeper)
	add_child_autofree(nested)

	var bridge := PBToolBridge.new()
	bridge.setup(nested)
	# Only MOVE and ROTATE exist → not fully ready, but MOVE was found.
	assert_false(bridge.is_ready())
	var received: Array = []
	move_btn.pressed.connect(func(): received.append("move"))
	bridge.apply_tool(PBEditor.ToolMode.MOVE)
	assert_eq(received.size(), 1, "Nested move button was found and pressed")

# ==============================================================================
# Tool application
# ==============================================================================

func test_apply_tool_presses_matching_engine_button():
	var bridge := _make_bridge_with_buttons()
	bridge.setup(_root)

	var move_btn: Button = _root.get_child(0)
	var received: Array = []
	move_btn.pressed.connect(func(): received.append("move"))

	bridge.apply_tool(PBEditor.ToolMode.MOVE)
	assert_eq(received.size(), 1, "apply_tool must press the engine's move button")

	# The engine sets the pressed state in its own handler; simulate that the
	# tool is now active — apply must become a no-op.
	move_btn.button_pressed = true
	bridge.apply_tool(PBEditor.ToolMode.MOVE)
	assert_eq(received.size(), 1, "apply_tool must not re-press the active tool")

func test_apply_tool_ignores_universal_and_select():
	var bridge := _make_bridge_with_buttons()
	bridge.setup(_root)

	var universal_btn: Button = _root.get_child(3)
	var select_btn: Button = _root.get_child(4)
	var received: Array = []
	universal_btn.pressed.connect(func(): received.append("universal"))
	select_btn.pressed.connect(func(): received.append("select"))

	bridge.apply_tool(PBEditor.ToolMode.MOVE)
	bridge.apply_tool(PBEditor.ToolMode.ROTATE)
	bridge.apply_tool(PBEditor.ToolMode.SCALE)
	assert_eq(received.size(), 0, "Only move/rotate/scale may ever be pressed")

# ==============================================================================
# Editing context (universal/select pinning)
# ==============================================================================

func test_editing_disables_universal_and_select_only():
	var bridge := _make_bridge_with_buttons()
	bridge.setup(_root)

	bridge.set_editing_active(true)
	assert_true((_root.get_child(3) as Button).disabled, "Universal (Q) button disabled while editing")
	assert_true((_root.get_child(4) as Button).disabled, "Select (V) button disabled while editing")
	assert_false((_root.get_child(0) as Button).disabled, "Move stays enabled while editing")
	assert_false((_root.get_child(1) as Button).disabled, "Rotate stays enabled while editing")
	assert_false((_root.get_child(2) as Button).disabled, "Scale stays enabled while editing")

	bridge.set_editing_active(false)
	for i in range(5):
		assert_false((_root.get_child(i) as Button).disabled, "Leaving editing restores all buttons")

func test_disabled_button_shows_nothing_in_editing():
	# A disabled button ignores its shortcut in the engine (BaseButton
	# shortcut_input checks is_disabled) — this test documents that the bridge
	# relies on `disabled`, not on visibility (the engine toolbar stays put).
	var bridge := _make_bridge_with_buttons()
	bridge.setup(_root)
	bridge.set_editing_active(true)
	var universal_btn: Button = _root.get_child(3)
	assert_true(universal_btn.visible, "Button is disabled, not hidden")
	assert_true(universal_btn.disabled)

# ==============================================================================
# Engine → plugin sync
# ==============================================================================

func test_engine_button_press_syncs_to_callback():
	var bridge := _make_bridge_with_buttons()
	bridge.setup(_root)

	var received: Array = []
	bridge.on_tool_selected = func(tool): received.append(tool)

	# User presses W in the engine → its button fires
	(_root.get_child(0) as Button).emit_signal("pressed")
	assert_eq(received.size(), 1)
	assert_eq(received[0], PBEditor.ToolMode.MOVE)

	(_root.get_child(1) as Button).emit_signal("pressed")
	assert_eq(received.size(), 2)
	assert_eq(received[1], PBEditor.ToolMode.ROTATE)

	# Universal/select buttons are NOT synced (plugin never owns those tools)
	(_root.get_child(3) as Button).emit_signal("pressed")
	(_root.get_child(4) as Button).emit_signal("pressed")
	assert_eq(received.size(), 2, "Only move/rotate/scale sync back")

func test_teardown_restores_and_disconnects():
	var bridge := _make_bridge_with_buttons()
	bridge.setup(_root)

	var received: Array = []
	bridge.on_tool_selected = func(tool): received.append(tool)

	bridge.teardown()
	for i in range(5):
		assert_false((_root.get_child(i) as Button).disabled, "teardown re-enables everything")

	(_root.get_child(0) as Button).emit_signal("pressed")
	assert_eq(received.size(), 0, "teardown disconnects the sync listeners")

func test_teardown_then_apply_is_safe():
	var bridge := _make_bridge_with_buttons()
	bridge.setup(_root)
	bridge.teardown()
	bridge.apply_tool(PBEditor.ToolMode.MOVE)
	bridge.set_editing_active(true)
	assert_true(true, "No crash when using a torn-down bridge")
