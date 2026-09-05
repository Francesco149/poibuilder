## PBActions — every PoiBuilder action as a rebindable editor shortcut.
##
## All plugin keybinds live in this ONE table and register into
## EditorSettings under "poibuilder/<id>" (EditorSettings.add_shortcut is
## the same path the engine's own ED_SHORTCUT macro uses), so they appear
## under Editor Settings → Shortcuts like any native editor command and
## survive rebinding across restarts (add_shortcut keeps events already
## loaded from the settings file).
##
## Conventions:
## - Defaults use PHYSICAL keycodes (layout-independent), matching the
##   engine's own spatial_editor shortcuts; modifier flags are exact.
## - `action_for(event, settings)` walks the table and returns the FIRST
##   match — the plugin consumes the key, so actions must not collide with
##   each other; collisions with engine shortcuts are handled by the
##   dispatcher's pass-through decisions in the plugin.
## - Headless tests inject a null `settings`: matching falls back to the
##   compiled-in defaults.
@tool
class_name PBActions
extends RefCounted

const PREFIX := "poibuilder/"

# ==============================================================================
# Action table
# ==============================================================================

## id → {label: display name, keys: [[physical_keycode, ctrl, shift, alt]]}
## An empty keys array registers the action UNBOUND (rebindable, no default).
const ACTIONS: Dictionary = {
	# Selection modes (viewport keypresses while editing).
	"select_vertex":   { "label": "Select: Vertex Mode",   "keys": [[KEY_H, 0, 0, 0]] },
	"select_edge":     { "label": "Select: Edge Mode",     "keys": [[KEY_J, 0, 0, 0]] },
	"select_face":     { "label": "Select: Face Mode",     "keys": [[KEY_K, 0, 0, 0]] },
	"select_object":   { "label": "Select: Object Mode",   "keys": [] },
	"cycle_space":     { "label": "Cycle Gizmo Space",     "keys": [[KEY_X, 0, 0, 0]] },
	# Snapping + grid.
	"toggle_snap":     { "label": "Toggle Snapping",       "keys": [[KEY_Y, 0, 0, 0]] },
	"toggle_on_grid":  { "label": "Toggle Draw On Grid",   "keys": [[KEY_G, 0, 0, 0]] },
	"toggle_grid":     { "label": "Toggle Grid Overlay",   "keys": [] },
	"subdiv_increase": { "label": "Grid: Finer (Subdiv +1)",   "keys": [[KEY_EQUAL, 0, 0, 0]] },
	"subdiv_decrease": { "label": "Grid: Coarser (Subdiv -1)", "keys": [[KEY_MINUS, 0, 0, 0]] },
	"unit_increase":   { "label": "Grid: Unit x2",         "keys": [[KEY_EQUAL, 0, 1, 0]] },
	"unit_decrease":   { "label": "Grid: Unit /2",         "keys": [[KEY_MINUS, 0, 1, 0]] },
	"grid_raise":      { "label": "Grid: Raise Elevation", "keys": [[KEY_BRACKETRIGHT, 0, 0, 0]] },
	"grid_lower":      { "label": "Grid: Lower Elevation", "keys": [[KEY_BRACKETLEFT, 0, 0, 0]] },
	"grid_reset":      { "label": "Grid: Reset Elevation", "keys": [[KEY_BACKSLASH, 0, 0, 0]] },
	"snap_selection":  { "label": "Snap Selection To Grid", "keys": [] },
	# Mesh operations (toolbar equivalents; extrude/inset keep ProBuilder's
	# Alt defaults, the rest ship unbound but rebindable).
	"op_extrude":      { "label": "Mesh Op: Extrude",         "keys": [[KEY_E, 0, 0, 1]] },
	"op_inset":        { "label": "Mesh Op: Inset",           "keys": [[KEY_I, 0, 0, 1]] },
	"op_loop_cut":     { "label": "Mesh Op: Insert Edge Loop", "keys": [] },
	"op_merge":        { "label": "Mesh Op: Merge Faces",     "keys": [] },
	"op_subdivide":    { "label": "Mesh Op: Subdivide Faces", "keys": [] },
	"op_weld":         { "label": "Mesh Op: Weld Vertices",   "keys": [] },
	"op_detach":       { "label": "Mesh Op: Detach Faces",    "keys": [] },
	"op_delete":       { "label": "Mesh Op: Delete Faces",    "keys": [] },
}

## Mesh-op action id → the op string the toolbar/plugin pipeline expects.
const OP_ACTION_TO_OPERATION: Dictionary = {
	"op_extrude": "extrude_faces",
	"op_inset": "inset_faces",
	"op_loop_cut": "insert_edge_loop",
	"op_merge": "merge_faces",
	"op_subdivide": "subdivide_faces",
	"op_weld": "weld_vertices",
	"op_detach": "detach_faces",
	"op_delete": "delete_faces",
}

# ==============================================================================
# Registration & Conflict Resolution
# ==============================================================================

## Known stock Godot shortcuts that conflict with PoiBuilder default viewport keys:
## - H: toggles selected node visibility in editor
## - ]: moves last animation key to cursor
## - [: moves first animation key to cursor
const CONFLICTING_STOCK_SHORTCUTS: Array[String] = [
	"editor/toggle_selected_nodes_visibility",
	"animation_editor/move_last_selected_key_to_cursor",
	"animation_editor/move_first_selected_key_to_cursor",
]

## Unbinds stock Godot shortcuts that collide with PoiBuilder default keys (H, ], [)
## so viewport element selection and grid elevation work cleanly without fighting
## the editor. Warns the user via logger and editor toast.
static func unbind_conflicts(settings: Object, logger: Object = null) -> Array[String]:
	var unbound: Array[String] = []
	if settings == null:
		return unbound

	var target_keys := [KEY_H, KEY_BRACKETRIGHT, KEY_BRACKETLEFT]
	var list: Array = []
	if settings.has_method("get_shortcut_list"):
		list = Array(settings.get_shortcut_list())
	else:
		list = CONFLICTING_STOCK_SHORTCUTS.duplicate()

	for path_variant in list:
		var path := String(path_variant)
		if path.begins_with(PREFIX):
			continue
		if not settings.has_shortcut(path):
			continue
		var sc: Shortcut = settings.get_shortcut(path)
		if sc == null:
			continue
		var filtered: Array[InputEvent] = []
		var changed := false
		for ev in sc.events:
			if ev is InputEventKey:
				var k := ev as InputEventKey
				if not k.ctrl_pressed and not k.shift_pressed and not k.alt_pressed and not k.meta_pressed:
					var code := k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode
					if code in target_keys:
						changed = true
						var key_name := OS.get_keycode_string(code)
						var desc := sc.get_name() if not sc.get_name().is_empty() else path
						unbound.append("'%s' [%s]" % [desc, key_name])
						continue
			filtered.append(ev)
		if changed:
			sc.events = filtered

	if unbound.size() > 0:
		var summary := ", ".join(unbound)
		if logger != null and logger.has_method("warn"):
			logger.warn("actions", "Unbound conflicting Godot shortcut(s): %s to allow PoiBuilder viewport keys. You can rebind them in Editor Settings > Shortcuts." % summary)
		if Engine.is_editor_hint():
			# Show a toast in the editor if EditorToaster is available
			var toaster: Object = null
			if ClassDB.class_exists("EditorInterface"):
				var iface: Object = Engine.get_singleton("EditorInterface") if Engine.has_singleton("EditorInterface") else null
				if iface != null and iface.has_method("get_editor_toaster"):
					toaster = iface.get_editor_toaster()
			if toaster != null and toaster.has_method("push_toast"):
				toaster.push_toast(
					"PoiBuilder: Unbound conflicting stock shortcut(s): %s" % summary,
					1, # SEVERITY_WARNING
					"Unbound to allow PoiBuilder viewport keys (H, ], [). Rebind in Editor Settings > Shortcuts."
				)
	return unbound

## Registers every action into the EditorSettings shortcut store and unbinds
## conflicting engine shortcuts. Safe to call repeatedly.
static func register(settings: Object, logger: Object = null) -> void:
	if settings == null or not settings.has_method("add_shortcut"):
		return
	unbind_conflicts(settings, logger)
	for id: String in ACTIONS:
		var path := PREFIX + id
		var def_sc := _make_shortcut(id)
		if not settings.has_shortcut(path):
			settings.add_shortcut(path, def_sc)
		var sc: Shortcut = settings.get_shortcut(path)
		if sc != null:
			# Ensure human-readable display label ("Grid: Raise Elevation", etc.)
			if sc.get_name().is_empty() or sc.get_name() == id:
				sc.set_name(ACTIONS[id]["label"])
			# Ensure meta("original") is always set so EditorSettingsDialog displays it!
			if not sc.has_meta("original"):
				sc.set_meta("original", sc.events.duplicate(true))
			# Ensure empty shortcuts receive default events
			if sc.events.is_empty() and ACTIONS[id]["keys"].size() > 0:
				sc.events = def_sc.events.duplicate(true)
				sc.set_meta("original", def_sc.events.duplicate(true))

static func _make_shortcut(id: String) -> Shortcut:
	var sc := Shortcut.new()
	if ACTIONS.has(id) and ACTIONS[id].has("label"):
		sc.set_name(ACTIONS[id]["label"])
	var events: Array[InputEvent] = []
	for spec: Array in ACTIONS[id]["keys"]:
		events.append(make_event(spec))
	sc.events = events
	return sc
## Builds the InputEventKey for a table entry [physical_key, ctrl, shift, alt].
static func make_event(spec: Array) -> InputEventKey:
	var ev := InputEventKey.new()
	var code := spec[0] as Key
	ev.keycode = code
	ev.physical_keycode = code
	ev.key_label = code
	ev.ctrl_pressed = bool(spec[1])
	ev.shift_pressed = bool(spec[2])
	ev.alt_pressed = bool(spec[3])
	return ev

# ==============================================================================
# Matching
# ==============================================================================

## Returns the action id matching `event` ("" when none). Prefers the live
## EditorSettings store (user rebinds); headless callers pass no settings and
## match against the compiled-in defaults.
static func action_for(event: InputEvent, settings: Object = null) -> StringName:
	if not (event is InputEventKey):
		return &""
	var key_event := event as InputEventKey
	if not key_event.pressed:
		return &""
	if settings != null and settings.has_method("is_shortcut"):
		for id: String in ACTIONS:
			var path := PREFIX + id
			if settings.has_shortcut(path) and settings.is_shortcut(path, key_event):
				var act := StringName(id)
				if not key_event.echo or act == &"grid_raise" or act == &"grid_lower":
					return act
		# Fallback: if settings shortcut matching missed due to keycode vs physical_keycode layout mismatch
		for id: String in ACTIONS:
			for spec: Array in ACTIONS[id]["keys"]:
				if _match_default(key_event, spec):
					var act := StringName(id)
					if not key_event.echo or act == &"grid_raise" or act == &"grid_lower":
						return act
	else:
		for id: String in ACTIONS:
			for spec: Array in ACTIONS[id]["keys"]:
				if _match_default(key_event, spec):
					var act := StringName(id)
					if not key_event.echo or act == &"grid_raise" or act == &"grid_lower":
						return act
	return &""
## Default-table matching: physical keycode (layout-independent), with the
## keycode as fallback, and EXACT modifier equality.
static func _match_default(event: InputEventKey, spec: Array) -> bool:
	var target := spec[0] as Key
	var key_match: bool = event.physical_keycode == target or event.keycode == target or event.key_label == target
	return key_match \
		and event.ctrl_pressed == bool(spec[1]) \
		and event.shift_pressed == bool(spec[2]) \
		and event.alt_pressed == bool(spec[3])

## Human-readable current binding ("Shift+_ , H") for tooltips.
static func binding_text(id: StringName, settings: Object = null) -> String:
	var path := PREFIX + String(id)
	if settings != null and settings.has_method("get_shortcut") \
			and settings.has_shortcut(path):
		var sc: Shortcut = settings.get_shortcut(path)
		if sc != null:
			return sc.get_as_text()
	var texts: Array[String] = []
	for spec: Array in ACTIONS[String(id)]["keys"]:
		texts.append(make_event(spec).as_text())
	return " + ".join(texts)
