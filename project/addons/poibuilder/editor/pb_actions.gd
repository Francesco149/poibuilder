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
# Registration
# ==============================================================================

## Registers every action into the EditorSettings shortcut store. Safe to
## call repeatedly (plugin reloads): user-rebound events survive (the engine
## keeps events loaded from the settings file over fresh defaults).
static func register(settings: Object) -> void:
	if settings == null or not settings.has_method("add_shortcut"):
		return
	for id: String in ACTIONS:
		var path := PREFIX + id
		if settings.has_shortcut(path):
			continue
		settings.add_shortcut(path, _make_shortcut(id))

static func _make_shortcut(id: String) -> Shortcut:
	var sc := Shortcut.new()
	var events: Array[InputEvent] = []
	for spec: Array in ACTIONS[id]["keys"]:
		events.append(make_event(spec))
	sc.events = events
	return sc

## Builds the InputEventKey for a table entry [physical_key, ctrl, shift, alt].
static func make_event(spec: Array) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = spec[0] as Key
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
	if not key_event.pressed or key_event.echo:
		return &""
	if settings != null and settings.has_method("is_shortcut"):
		for id: String in ACTIONS:
			var path := PREFIX + id
			if settings.has_shortcut(path) and settings.is_shortcut(path, key_event):
				return StringName(id)
	else:
		for id: String in ACTIONS:
			for spec: Array in ACTIONS[id]["keys"]:
				if _match_default(key_event, spec):
					return StringName(id)
	return &""

## Default-table matching: physical keycode (layout-independent), with the
## keycode as fallback, and EXACT modifier equality.
static func _match_default(event: InputEventKey, spec: Array) -> bool:
	var key_match: bool = event.physical_keycode == spec[0] or event.keycode == spec[0]
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
