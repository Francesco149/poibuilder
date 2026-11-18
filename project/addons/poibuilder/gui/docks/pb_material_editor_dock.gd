## The Material & UV dock's native EditorDock shell (Godot 4.6+).
##
## Registering through EditorDock (instead of the deprecated
## add_control_to_dock) gives the dock what every built-in dock has: the
## user can move it to any slot, float it, or put it in the BOTTOM panel, and
## the editor remembers where it went. In the bottom panel the content lays
## the palette and the tools out side by side (_update_layout).
##
## Deliberately NOT a class_name: the plugin only loads this script after
## checking ClassDB for EditorDock, so an engine without it never parses it.
@tool
extends EditorDock

var content: PBMaterialDock = null

func _update_layout(layout: int) -> void:
	if content != null and is_instance_valid(content):
		content.set_horizontal_layout(layout == DOCK_LAYOUT_HORIZONTAL)
