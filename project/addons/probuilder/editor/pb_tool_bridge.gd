## PBToolBridge — Mirrors the plugin's OWN transform tool onto the editor.
##
## The engine draws its transform gizmo components based on its internal
## Node3DEditor tool mode: TOOL_MODE_TRANSFORM shows the combined universal
## gizmo, MOVE/ROTATE/SCALE show only their own handles, SELECT shows none.
## None of that is script-callable directly, but the tool buttons are regular
## BaseButtons whose `pressed` signal drives the editor's internal state.
##
## While a PBMesh is being edited this bridge:
## - presses the engine button matching PBEditor.tool_mode (move/rotate/scale
##   only — the universal and select buttons are DISABLED, and a disabled
##   button also ignores its keyboard shortcut, so Q/V can never switch the
##   editor into a state that hides the gizmo or shows the universal one),
## - drives the engine's "Use Local Space" toggle (T) so the transform gizmo
##   orientation follows PBEditor.orientation_space — see apply_orientation_space,
## - listens to the engine buttons' `pressed` signals to keep the plugin's
##   own tool state in sync when the user presses W/E/R.
##
## When not editing, every button is restored so the editor behaves stock.
##
## NOTE: button resolution needs a live editor tree, but all DECISIONS are
## plain logic and headless-testable with stand-in buttons.
@tool
class_name PBToolBridge
extends RefCounted

# ==============================================================================
# Engine tool button identification
# ==============================================================================

## EditorSettings shortcut paths of the engine's tool buttons.
const PATH_MOVE := "spatial_editor/tool_move"          # W
const PATH_ROTATE := "spatial_editor/tool_rotate"      # E
const PATH_SCALE := "spatial_editor/tool_scale"        # R
const PATH_UNIVERSAL := "spatial_editor/tool_transform" # Q — universal gizmo
const PATH_SELECT := "spatial_editor/tool_select"      # V
const PATH_LOCAL_COORDS := "spatial_editor/local_coords" # T — gizmo local/global

## Fallback physical keys, used when the EditorSettings shortcut instance
## cannot be matched by identity (e.g. remapped or unavailable).
const KEY_BY_PATH := {
	PATH_MOVE: KEY_W,
	PATH_ROTATE: KEY_E,
	PATH_SCALE: KEY_R,
	PATH_UNIVERSAL: KEY_Q,
	PATH_SELECT: KEY_V,
	PATH_LOCAL_COORDS: KEY_T,
}

# ==============================================================================
# Wiring
# ==============================================================================

## Called when the engine switched tools via its own buttons/shortcuts
## (W/E/R) so the plugin can mirror the tool into PBEditor.tool_mode.
var on_tool_selected: Callable = Callable()

var logger: PBLogger = null

## Resolved engine tool buttons, keyed by shortcut path.
var _buttons: Dictionary = {}
## The Node3DEditor the buttons were found under (for re-resolution).
var _n3d: Node = null

## The engine's local-coords toggle, kept separately: it is optional (the
## orientation space degrades to a logged warning without it) and is
## deliberately DISABLED while editing — programmatic set_pressed still works
## on a disabled button, while the user's T key/mouse cannot touch it.
var _local_coords_btn: BaseButton = null

## Local-coords toggle state to restore when editing ends.
var _local_coords_before_editing: bool = false

## True while apply_orientation_space is pressing the toggle; lets the
## `toggled` listener ignore our own programmatic flips.
var _applying_space: bool = false

# ==============================================================================
# Setup / teardown
# ==============================================================================

## Locate the engine's tool buttons under `n3d` (the Node3DEditor singleton).
## Safe to call again to re-resolve; returns true when all five were found.
func setup(n3d: Node) -> bool:
	_n3d = n3d
	_disconnect_buttons()
	_buttons.clear()
	_local_coords_btn = null
	if n3d == null or not is_instance_valid(n3d):
		return false

	var candidates: Array = []
	_collect_shortcut_buttons(n3d, candidates)

	for path: String in KEY_BY_PATH:
		var btn := _match_button(candidates, path)
		if btn != null:
			_buttons[path] = btn
	_local_coords_btn = _buttons.get(PATH_LOCAL_COORDS)
	if _local_coords_btn == null:
		_buttons.erase(PATH_LOCAL_COORDS)

	# Sync listeners: engine tool changed via W/E/R or its own toolbar.
	for path: String in [PATH_MOVE, PATH_ROTATE, PATH_SCALE]:
		if _buttons.has(path):
			var btn: BaseButton = _buttons[path]
			if not btn.pressed.is_connected(_on_engine_tool_pressed.bind(path)):
				btn.pressed.connect(_on_engine_tool_pressed.bind(path))

	# External local-coords flips (e.g. the View menu) must never win over the
	# plugin's orientation space while editing — re-assert ours.
	if _local_coords_btn != null:
		if not _local_coords_btn.toggled.is_connected(_on_local_coords_toggled):
			_local_coords_btn.toggled.connect(_on_local_coords_toggled)
	if logger != null:
		if _local_coords_btn != null:
			logger.info("tools", "Engine local-coords toggle found — orientation space is live")
		else:
			logger.warn("tools", "Engine local-coords toggle NOT found — gizmo space will stay world")
			_dump_button_candidates(candidates)
	return _all_tools_found()

## One line per shortcut-less/toggle candidate under the Node3DEditor — the
## diagnostic trail when a newer/older engine moves the local-coords toggle.
func _dump_button_candidates(candidates: Array) -> void:
	for btn in candidates:
		var sc := (btn as BaseButton).get_shortcut()
		var keys: String = ""
		if sc != null:
			for ev in sc.get_events():
				var key := ev as InputEventKey
				if key != null:
					keys += "%s " % key.as_text()
		logger.info("tools", "candidate: class=%s toggle=%s shortcut=[%s] tooltip='%s'" % [
			btn.get_class(), btn.toggle_mode, keys.strip_edges(),
			str(btn.tooltip_text).left(40)])

func _all_tools_found() -> bool:
	return _buttons.has(PATH_MOVE) and _buttons.has(PATH_ROTATE) \
		and _buttons.has(PATH_SCALE) and _buttons.has(PATH_UNIVERSAL) \
		and _buttons.has(PATH_SELECT)

## Releases signal connections and restores all engine buttons to enabled.
func teardown() -> void:
	_disconnect_buttons()
	if _local_coords_btn != null and is_instance_valid(_local_coords_btn):
		if _local_coords_btn.toggled.is_connected(_on_local_coords_toggled):
			_local_coords_btn.toggled.disconnect(_on_local_coords_toggled)
		_local_coords_btn.set_pressed_no_signal(_local_coords_before_editing)
		_local_coords_btn.disabled = false
	_local_coords_btn = null
	for path: String in _buttons:
		var btn: BaseButton = _buttons[path]
		if is_instance_valid(btn):
			btn.disabled = false
	_buttons.clear()
	_n3d = null
	editing_active = false

func _disconnect_buttons() -> void:
	for path: String in [PATH_MOVE, PATH_ROTATE, PATH_SCALE]:
		if _buttons.has(path):
			var btn: BaseButton = _buttons[path]
			if is_instance_valid(btn) and btn.pressed.is_connected(_on_engine_tool_pressed.bind(path)):
				btn.pressed.disconnect(_on_engine_tool_pressed.bind(path))

func _collect_shortcut_buttons(root: Node, out: Array) -> void:
	if root == null or not is_instance_valid(root):
		return
	for child in root.get_children():
		if child is BaseButton:
			var btn := child as BaseButton
			if btn.toggle_mode and btn.get_shortcut() != null:
				out.append(btn)
		_collect_shortcut_buttons(child, out)

## Identity match against the EditorSettings shortcut instance first, then
## by physical key fallback (no modifiers).
func _match_button(candidates: Array, path: String) -> BaseButton:
	# EditorSettings is an editor-only singleton; it is absent in headless
	# runs, so guard before touching it (the physical-key fallback then
	# resolves the stand-in buttons in tests).
	var editor_settings: Object = EditorSettings if Engine.is_editor_hint() else null
	var wanted: Shortcut = null
	if editor_settings != null and editor_settings.has_method("get_shortcut"):
		wanted = editor_settings.get_shortcut(path)

	if wanted != null:
		for btn in candidates:
			if (btn as BaseButton).get_shortcut() == wanted:
				return btn

	# Fallback: match by key (covers a missing/unresolved shortcut instance;
	# harmless double-pass when identity already matched).
	var physical_key: int = KEY_BY_PATH.get(path, KEY_NONE)
	for btn in candidates:
		var sc := (btn as BaseButton).get_shortcut()
		if sc != null and _shortcut_has_key(sc, physical_key):
			return btn
	return null

## Matches the key WITHOUT modifiers, accepting physical_keycode OR keycode:
## the engine's own buttons are inconsistent across versions (4.7.2's tool
## buttons carry physical W/E/R/Q/V but a keycode-based T on the local-coords
## toggle; the -dev tree uses physical for both).
func _shortcut_has_key(sc: Shortcut, physical_key: int) -> bool:
	if physical_key == KEY_NONE:
		return false
	for event in sc.get_events():
		var key := event as InputEventKey
		if key != null \
				and (key.physical_keycode == (physical_key as Key) or key.keycode == (physical_key as Key)) \
				and key.ctrl_pressed == false and key.alt_pressed == false \
				and key.shift_pressed == false:
			return true
	return false

# ==============================================================================
# Engine tool control
# ==============================================================================

## True when the bridge found the engine buttons it needs.
func is_ready() -> bool:
	return _all_tools_found()

## Enters/leaves editing context: while editing, the universal and select
## tool buttons are disabled (their shortcuts die with them — the universal
## gizmo can never appear) and the local-coords toggle is disabled too (the
## plugin owns the gizmo orientation space while editing; T must not fight
## it). While not editing, everything is restored to stock behavior.
## The plugin's tool and space are applied separately via apply_tool() /
## apply_orientation_space().
func set_editing_active(active: bool) -> void:
	if _buttons.is_empty():
		return
	editing_active = active
	_set_restricted_allowed(not active)
	if _local_coords_btn != null and is_instance_valid(_local_coords_btn):
		if active:
			_local_coords_before_editing = _local_coords_btn.button_pressed
			_local_coords_btn.disabled = true
		else:
			_local_coords_btn.disabled = false
			_press_local_coords(_local_coords_before_editing)

## Whether the engine's local-coords toggle must be ON for `space`
## (a PBEditor.OrientationSpace value).
##
## THE ENGINE CONTRACT (node_3d_editor_plugin.cpp, update_transform_gizmo):
## the transform gizmo only adopts a subgizmo's basis when the editor's
## local-coords toggle is on — otherwise the gizmo basis stays identity
## (world). There is no other script-accessible way to orient the engine's
## transform gizmo:
## - WORLD → OFF: the engine keeps the identity (world) gizmo basis.
## - ELEMENT/OBJECT → ON: the gizmo basis becomes node_global *
##   get_subgizmo_transform(id).basis, and the engine pre-converts drag
##   motion through the gizmo basis — so the element_basis() values become
##   live for both display and drag math.
static func local_coords_for_space(space: int) -> bool:
	return space != PBEditor.OrientationSpace.WORLD

## Presses the engine's local-coords toggle to match `space` (a
## PBEditor.OrientationSpace value). The engine's `toggled` handler then
## calls its own update_transform_gizmo(), re-orienting the gizmo over the
## selected subgizmos. Returns true when the toggle was found.
##
## Skips redundant flips (a toggle press always costs the engine a gizmo
## rebuild). Intentionally does NOT bail when the button is disabled: while
## editing we disable the toggle to pin out the user's T key, and a disabled
## button still accepts programmatic set_pressed (unlike user input).
func apply_orientation_space(space: int) -> bool:
	if _local_coords_btn == null or not is_instance_valid(_local_coords_btn):
		return false
	_press_local_coords(local_coords_for_space(space))
	return true

## True when the orientation space can actually be applied (the engine's
## local-coords toggle was found at setup).
func has_local_coords() -> bool:
	return _local_coords_btn != null and is_instance_valid(_local_coords_btn)

func _press_local_coords(pressed: bool) -> void:
	if _local_coords_btn == null or not is_instance_valid(_local_coords_btn):
		return
	if _local_coords_btn.button_pressed == pressed:
		return
	_applying_space = true
	_local_coords_btn.button_pressed = pressed
	_applying_space = false

## The toggle flipped without us doing it (View menu, a leftover drag restore,
## an engine version that re-enables the disabled button) while editing —
## re-assert the plugin's space so the engine state and the overlay readout
## never diverge. Outside editing the toggle is stock editor UI: leave it be.
func _on_local_coords_toggled(_pressed: bool) -> void:
	if _applying_space or not editing_active:
		return
	if logger != null:
		logger.warn("tools", "Engine local-coords flipped externally — re-asserting orientation space")
	apply_orientation_space(editor_space)

## Whether the bridge currently holds the editing context (kept in sync by
## set_editing_active).
var editing_active: bool = false

## The space currently configured in the plugin (kept in sync by
## PoiBuilderPlugin whenever PBEditor.orientation_space changes, and on
## entering editing) — what _on_local_coords_toggled re-asserts.
var editor_space: int = PBEditor.OrientationSpace.ELEMENT

func _set_restricted_allowed(allowed: bool) -> void:
	for path: String in [PATH_UNIVERSAL, PATH_SELECT]:
		if _buttons.has(path):
			var btn: BaseButton = _buttons[path]
			if is_instance_valid(btn):
				btn.disabled = not allowed

## Presses the engine button for `tool` (a PBEditor.ToolMode value). A no-op
## when the engine is already in that tool (button pressed state reflects the
## engine's internal tool mode because the editor sets it on every switch).
func apply_tool(tool: int) -> void:
	var path := _path_for_tool(tool)
	if path.is_empty() or not _buttons.has(path):
		return
	var btn: BaseButton = _buttons[path]
	if not is_instance_valid(btn) or btn.disabled:
		return
	if btn.button_pressed:
		return
	# Fire the engine's own handler; it updates the internal tool mode and
	# the pressed states of ALL tool buttons.
	btn.emit_signal("pressed")

func _path_for_tool(tool: int) -> String:
	match tool:
		PBEditor.ToolMode.MOVE:
			return PATH_MOVE
		PBEditor.ToolMode.ROTATE:
			return PATH_ROTATE
		PBEditor.ToolMode.SCALE:
			return PATH_SCALE
	return ""

func _on_engine_tool_pressed(path: String) -> void:
	if not on_tool_selected.is_valid():
		return
	match path:
		PATH_MOVE:
			on_tool_selected.call(PBEditor.ToolMode.MOVE)
		PATH_ROTATE:
			on_tool_selected.call(PBEditor.ToolMode.ROTATE)
		PATH_SCALE:
			on_tool_selected.call(PBEditor.ToolMode.SCALE)
