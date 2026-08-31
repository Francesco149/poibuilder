@tool
extends EditorPlugin
class_name ProBuilderPlugin

var logger: PBLogger = PBLogger.new()
var debug_dock_panel: PBDebugDock
var debug_dock: Control

func _get_plugin_name() -> String:
	return "ProBuilder"

func _enter_tree():
	logger.info("plugin", "ProBuilder plugin entering tree")

	# Register custom types
	# (will be populated in Phase 1+)

	# Debug dock
	debug_dock_panel = preload("res://addons/probuilder/debug/pb_debug_dock.tscn").instantiate()
	debug_dock_panel.logger = logger
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, debug_dock_panel)
	debug_dock = debug_dock_panel

	logger.info("plugin", "ProBuilder plugin initialized")

func _exit_tree():
	if logger:
		logger.info("plugin", "ProBuilder plugin exiting tree")

	if debug_dock:
		remove_control_from_docks(debug_dock)
		debug_dock.queue_free()
		debug_dock = null

func _handles(object: Object) -> bool:
	# Will be expanded when PBMesh is defined
	return false

func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	return AFTER_GUI_INPUT_PASS

func _forward_3d_draw_over_viewport(viewport_control: Control):
	pass
