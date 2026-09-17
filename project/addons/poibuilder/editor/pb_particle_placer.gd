## PBParticlePlacer — Click-to-place particle emitter tool (the Particles tab).
##
## Authoring an emitter used to mean hand-building a GPUParticles3D: process
## material, colour ramp with the alpha peak in the right place, quad draw
## pass with the billboard mode the exporter reads, additive-vs-blend, the
## poi_* metadata. This tool collapses that to the sprite placer's gesture,
## producing exactly the emitter records the courtyard PSP demo plays:
##
##   1. Click a surface          -> emitter appears at the point (live GPU
##                                  particles in the editor), mouse up/down
##                                  lifts it off the surface (billboard-style
##                                  offset), click locks the offset.
##   2. Mouse left/right         -> particle count (the budget-relevant knob).
##                                  Wheel scales the particle size.
##   3. Click                    -> commit (undoable, always re-armed like the
##                                  sprite tab). Esc cancels with no leftovers.
##
## Every decision the retro runtime cares about (blend mode, ramp knee, seed,
## y-lock, atlas frames, the 64-per-emitter format cap and the 256-per-map
## measured budget) lives in PBParticleParams — this file is the gesture,
## preview and feedback layer.
@tool
class_name PBParticlePlacer
extends RefCounted

enum State {
	INACTIVE = 0,
	ARMED = 1,
	RAISE = 2,
	TUNE = 3,
}

const DRAG_THRESHOLD := 6.0
## Count changes per pixel of horizontal travel in the TUNE phase.
const COUNT_PER_PIXEL := 0.12

var state: State = State.INACTIVE

# Texture / effect selection
var last_texture: Texture2D = null
var last_values: Dictionary = {}

# Placement gesture state
var press_screen_pos: Vector2 = Vector2.ZERO
var press_surface_point: Vector3 = Vector3.ZERO
var press_surface_normal: Vector3 = Vector3.UP
var _press_pending: bool = false
var elevation: float = 0.0
var tune_start_x: float = 0.0
var tune_start_count: int = 0
var count: int = 16
var size: float = 0.0

# Node references
var scene_root_override: Node = null
var preview_node: GPUParticles3D = null
## Camera of the active placement session (for the guide ring orientation).
var camera: Camera3D = null
var plugin: EditorPlugin = null
var grid: PBGrid = null

## Green ground->emitter guide (ring + stem + direction), like the sprite
## placer's raise guide.
var _guide_line: MeshInstance3D = null

signal state_changed(new_state: State)
signal emitter_placed(node: GPUParticles3D)
signal placement_aborted()

func is_active() -> bool:
	return state != State.INACTIVE

func arm() -> void:
	abort()
	state = State.ARMED
	_press_pending = false
	state_changed.emit(state)

## The plugin's tool-switch path calls disarm — the same teardown abort does.
func disarm() -> void:
	abort()

func abort() -> void:
	_press_pending = false
	if preview_node != null and is_instance_valid(preview_node):
		if preview_node.get_parent() != null:
			preview_node.get_parent().remove_child(preview_node)
		preview_node.queue_free()
		preview_node = null
	_clear_guide_line()
	var prev_state := state
	state = State.INACTIVE
	if prev_state != State.INACTIVE:
		state_changed.emit(state)
		placement_aborted.emit()

## The hint the plugin shows for the current phase (creation row + dock).
func phase_hint() -> String:
	match state:
		State.ARMED:
			return "Particles: click a surface to place the selected emitter (Esc cancels)"
		State.RAISE:
			return "Particles: mouse up/down to lift off the surface • click to lock"
		State.TUNE:
			return "Particles: mouse left/right for particle count • wheel for size • click to commit"
	return ""

## Live readout for the overlay's extents row.
func get_extents_readout() -> String:
	match state:
		State.RAISE:
			return "Offset: %.2fm" % elevation
		State.TUNE:
			var total := PBParticleParams.total_amount(_budget_root())
			var flag := "  [!]" if total > PBParticleParams.MAP_BUDGET else ""
			return "Count %d (map %d/%d)%s • size %.2fm" % [count, total, PBParticleParams.MAP_BUDGET, flag, size]
	return ""

func _budget_root() -> Node:
	if scene_root_override != null:
		return scene_root_override
	if plugin != null and plugin.has_method("get_editor_interface"):
		return plugin.get_editor_interface().get_edited_scene_root()
	return null

# ==============================================================================
# Viewport input (same contract as PBSpritePlacer.handle_input)
# ==============================================================================

func handle_input(camera: Camera3D, event: InputEvent, surface_hit: Dictionary, _host_control: Control) -> int:
	const PASS := 0
	const STOP := 1

	self.camera = camera
	if state == State.INACTIVE:
		return PASS

	if event is InputEventKey and event.pressed:
		var k := event as InputEventKey
		if k.keycode == KEY_ESCAPE:
			abort()
			return STOP

	match state:
		State.ARMED:
			if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
				if event.pressed:
					if surface_hit.is_empty():
						return PASS
					press_surface_point = surface_hit["point"]
					press_surface_normal = surface_hit["normal"]
					press_screen_pos = event.position
					_press_pending = true
					return STOP
				else:
					if _press_pending:
						_press_pending = false
						_start_raise_phase()
						return STOP

		State.RAISE:
			if event is InputEventMouseMotion:
				elevation = maxf(0.0, elevation - event.relative.y * 0.012)
				if grid != null and grid.enabled:
					elevation = grid.snap_val(elevation)
				_update_preview_transform()
				return STOP
			elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
				tune_start_x = event.position.x
				tune_start_count = count
				state = State.TUNE
				state_changed.emit(state)
				return STOP

		State.TUNE:
			if event is InputEventMouseMotion:
				var delta_x: float = event.position.x - tune_start_x
				count = clampi(tune_start_count + int(round(delta_x * COUNT_PER_PIXEL)), 1, PBParticleParams.MAX_PER_EMITTER)
				if preview_node != null and is_instance_valid(preview_node):
					preview_node.amount = count
				return STOP
			elif event is InputEventMouseButton and event.pressed:
				if event.button_index == MOUSE_BUTTON_WHEEL_UP:
					size = clampf(size * 1.1, 0.05, PBParticleParams.MAX_QUAD_HEIGHT)
					PBParticleParams.apply_values(preview_node, current_values(), last_texture)
					_update_guide_line()
					_update_overlay_readout()
					return STOP
				elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
					size = clampf(size / 1.1, 0.05, PBParticleParams.MAX_QUAD_HEIGHT)
					PBParticleParams.apply_values(preview_node, current_values(), last_texture)
					_update_guide_line()
					_update_overlay_readout()
					return STOP
				elif event.button_index == MOUSE_BUTTON_LEFT:
					finalize_placement()
					return STOP

	return PASS

func current_values() -> Dictionary:
	var values := last_values.duplicate()
	values["count"] = float(count)
	values["size"] = size
	return values

# ==============================================================================
# Placement phases
# ==============================================================================

func _start_raise_phase() -> void:
	state = State.RAISE
	elevation = 0.0
	count = int(last_values.get("count", 16.0))
	size = float(last_values.get("size", 0.5))
	_spawn_preview_node()
	_update_preview_transform()
	state_changed.emit(state)

func _emitter_name(scene_root: Node) -> String:
	var base := "Emitter_Flame"
	if last_texture != null:
		base = "Emitter_%s" % last_texture.resource_path.get_file().get_basename().capitalize().replace(" ", "")
	if scene_root == null:
		return base
	if scene_root.get_node_or_null(NodePath(base)) == null:
		return base
	var i := 2
	while scene_root.get_node_or_null(NodePath("%s%d" % [base, i])) != null:
		i += 1
	return "%s%d" % [base, i]

func _spawn_preview_node() -> void:
	if preview_node != null and is_instance_valid(preview_node):
		if preview_node.get_parent() != null:
			preview_node.get_parent().remove_child(preview_node)
		preview_node.queue_free()
		preview_node = null
	_clear_guide_line()

	var scene_root: Node = scene_root_override
	if scene_root == null and plugin != null and plugin.has_method("get_editor_interface"):
		scene_root = plugin.get_editor_interface().get_edited_scene_root()

	preview_node = PBParticleParams.build_node(last_texture, current_values(), _emitter_name(scene_root))
	# Generous visibility AABB (local): particles that leave it are culled.
	var reach := maxf(2.0, float(last_values.get("speed", 0.5)) * float(last_values.get("lifetime", 1.0)) + size * 2.0)
	preview_node.visibility_aabb = AABB(Vector3(-1, -1, -1) * reach, Vector3(2, 2, 2) * reach)

	if scene_root != null:
		scene_root.add_child(preview_node)
		_ensure_guide_line(scene_root)

## Immediate-mode placement aid: ring on the surface, stem up to the emitter
## origin, short arrow along the emission direction. No depth test + high
## render priority so it never drowns under the surface it rises from (the
## same rule as the sprite raise guide).
func _ensure_guide_line(scene_root: Node) -> void:
	if _guide_line != null and is_instance_valid(_guide_line):
		return
	_guide_line = MeshInstance3D.new()
	# Editor tooling must never export — the billboard rules key on names like
	# "sprite*"/"tree*", and emitter holders are skipped via poi_emitter_holder
	# meta; both defenses go on.
	_guide_line.name = "EmitterGuideLine"
	_guide_line.set_meta("poi_emitter_guide", true)
	var mesh := ImmediateMesh.new()
	_guide_line.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.2, 1.0, 0.35, 1.0)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.render_priority = 10
	mat.disable_receive_shadows = true
	_guide_line.material_override = mat
	_guide_line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if scene_root != null:
		scene_root.add_child(_guide_line)

func _update_guide_line() -> void:
	if _guide_line == null or not is_instance_valid(_guide_line):
		return
	var mesh := _guide_line.mesh as ImmediateMesh
	if mesh == null:
		return
	mesh.clear_surfaces()
	if state != State.RAISE and state != State.TUNE:
		_guide_line.visible = false
		return
	_guide_line.visible = true
	var origin := press_surface_point + press_surface_normal * elevation

	# 1. Ring on the surface (12 segments) around the anchor. The ring's
	# plane is the surface; its phase rotates toward the camera so the
	# ellipse always reads as a ring, not a line.
	var to_cam: Vector3 = (camera.global_position if camera != null and camera.is_inside_tree()
			else press_surface_point + Vector3(0, 1, 2)) - press_surface_point
	var flat := to_cam - press_surface_normal * to_cam.dot(press_surface_normal)
	var side: Vector3 = press_surface_normal.cross(flat).normalized() if flat.length_squared() > 0.0001 \
			else press_surface_normal.cross(Vector3.RIGHT).normalized()
	if side.length_squared() < 0.0001:
		side = Vector3.RIGHT
	var other := press_surface_normal.cross(side).normalized()
	var ring_r := 0.22
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in range(13):
		var ang := float(i) / 12.0 * TAU
		mesh.surface_add_vertex(press_surface_point + (side * cos(ang) + other * sin(ang)) * ring_r)
	mesh.surface_end()

	# 2. Stem: anchor -> emitter origin.
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	mesh.surface_add_vertex(press_surface_point)
	mesh.surface_add_vertex(origin)
	mesh.surface_end()

	# 3. Arrowhead along the emission axis (world up by convention): a short
	# stem with two crossed wings at the tip.
	var tip := origin + Vector3.UP * (0.25 + size * 0.4)
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	mesh.surface_add_vertex(origin)
	mesh.surface_add_vertex(tip)
	mesh.surface_add_vertex(tip + Vector3(-0.06, -0.08, 0.0))
	mesh.surface_add_vertex(tip)
	mesh.surface_add_vertex(tip + Vector3(0.06, -0.08, 0.0))
	mesh.surface_add_vertex(tip)
	mesh.surface_add_vertex(tip + Vector3(0.0, -0.08, -0.06))
	mesh.surface_add_vertex(tip)
	mesh.surface_add_vertex(tip + Vector3(0.0, -0.08, 0.06))
	mesh.surface_add_vertex(tip)
	mesh.surface_end()

func _clear_guide_line() -> void:
	if _guide_line != null and is_instance_valid(_guide_line):
		_guide_line.queue_free()
	_guide_line = null

func _update_preview_transform() -> void:
	if preview_node == null or not is_instance_valid(preview_node):
		return
	var pos := press_surface_point + press_surface_normal * elevation
	if preview_node.is_inside_tree():
		preview_node.global_transform = Transform3D(Basis.IDENTITY, pos)
	else:
		preview_node.transform = Transform3D(Basis.IDENTITY, pos)
	_update_guide_line()
	_update_overlay_readout()

func _update_overlay_readout() -> void:
	if plugin != null and "tool_overlay" in plugin and plugin.tool_overlay != null:
		plugin.tool_overlay.set_creation_extents(get_extents_readout())

func finalize_placement() -> void:
	if preview_node == null or not is_instance_valid(preview_node):
		abort()
		return

	var node := preview_node
	preview_node = null
	state = State.INACTIVE
	_clear_guide_line()

	var scene_root: Node = null
	if plugin != null and plugin.has_method("get_editor_interface"):
		scene_root = plugin.get_editor_interface().get_edited_scene_root()

	if plugin != null and plugin.has_method("get_undo_redo"):
		var undo = plugin.get_undo_redo()
		if undo != null and scene_root != null:
			undo.create_action("Add Particle Emitter", UndoRedo.MERGE_DISABLE, node)
			undo.add_do_method(plugin, "_attach_detached", node, scene_root)
			undo.add_do_method(plugin, "_own_node", node)
			undo.add_do_reference(node)
			undo.add_undo_method(plugin, "_detach_node", node)
			undo.commit_action()
		else:
			if node.get_parent() == null and scene_root != null:
				scene_root.add_child(node)
				node.owner = scene_root
	else:
		if node.get_parent() == null and scene_root != null:
			scene_root.add_child(node)
			node.owner = scene_root

	if plugin != null and plugin.has_method("get_editor_interface"):
		var sel := plugin.get_editor_interface().get_selection()
		if sel != null:
			sel.clear()
			sel.add_node(node)

	state_changed.emit(state)
	emitter_placed.emit(node)
