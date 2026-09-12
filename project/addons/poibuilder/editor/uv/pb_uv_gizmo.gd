## PBUvGizmo — Interactive 2D Transform Gizmo for PoiBuilder UV Editor.
##
## Provides Move, Rotate, and Scale handles in the 2D UV canvas:
## - Move tool: Center handle (free 2D), U-axis arrow, V-axis arrow.
## - Rotate tool: Circular dial with angle tracking and 15° detents.
## - Scale tool: Center uniform handle, U-axis scale box, V-axis scale box.
## - Full snapping support: Grid snapping (quantized to snap step) and angle snapping.
@tool
class_name PBUvGizmo
extends RefCounted

# ==============================================================================
# Enums & Constants
# ==============================================================================

enum ToolMode {
	MOVE = 0,
	ROTATE = 1,
	SCALE = 2,
}

enum HandleType {
	NONE = -1,
	MOVE_CENTER = 0,
	MOVE_AXIS_U = 1,
	MOVE_AXIS_V = 2,
	ROTATE_DIAL = 3,
	SCALE_UNIFORM = 4,
	SCALE_AXIS_U = 5,
	SCALE_AXIS_V = 6,
}

const HANDLE_LENGTH := 48.0      # Screen pixels for axis arms
const ARROW_HEAD_SIZE := 9.0     # Screen pixels for arrow heads
const CENTER_BOX_SIZE := 12.0    # Screen pixels for center box
const ROTATE_RADIUS := 45.0      # Screen pixels for rotation dial
const SCALE_BOX_SIZE := 8.0      # Screen pixels for scale boxes
const HIT_RADIUS := 10.0         # Tolerance in screen pixels for picking handles

const COLOR_AXIS_U := Color(0.90, 0.35, 0.35, 0.95)       # Red for U axis
const COLOR_AXIS_V := Color(0.35, 0.85, 0.45, 0.95)       # Green for V axis
const COLOR_CENTER := Color(1.00, 0.85, 0.20, 0.95)       # Yellow/amber for center
const COLOR_HOVER := Color(0.20, 0.90, 1.00, 1.00)        # Bright cyan for hover
const COLOR_RING := Color(0.40, 0.70, 1.00, 0.80)         # Soft blue for rotate ring
const COLOR_DIAL_FILL := Color(0.20, 0.60, 0.90, 0.15)    # Translucent dial fill

# ==============================================================================
# State
# ==============================================================================

var tool_mode: ToolMode = ToolMode.MOVE
var pivot_uv: Vector2 = Vector2(0.5, 0.5)

var snap_enabled: bool = true
var grid_snap_step: float = 0.125
var rotation_snap_step: float = 15.0

var is_dragging: bool = false
var active_handle: HandleType = HandleType.NONE
var hover_handle: HandleType = HandleType.NONE

# Drag session tracking
var _drag_start_mouse: Vector2 = Vector2.ZERO
var _drag_start_pivot: Vector2 = Vector2.ZERO
var _drag_start_angle: float = 0.0
var _drag_start_dist: float = 1.0

# Accumulated transform deltas relative to drag start
var current_delta_uv: Vector2 = Vector2.ZERO
var current_angle_deg: float = 0.0
var current_scale: Vector2 = Vector2.ONE

# ==============================================================================
# Hit Testing
# ==============================================================================

## Tests whether a mouse screen position intersects any gizmo handle.
func hit_test(mouse_pos: Vector2, canvas: PBUvCanvas) -> HandleType:
	if canvas == null:
		return HandleType.NONE

	var pivot_screen := canvas.uv_to_screen(pivot_uv)

	match tool_mode:
		ToolMode.MOVE:
			# 1. Center box
			if mouse_pos.distance_to(pivot_screen) <= (CENTER_BOX_SIZE * 0.75 + 4.0):
				return HandleType.MOVE_CENTER

			# 2. U-axis arrow (horizontal to right)
			var u_end := pivot_screen + Vector2(HANDLE_LENGTH, 0.0)
			if _point_to_segment_dist(mouse_pos, pivot_screen, u_end) <= HIT_RADIUS:
				return HandleType.MOVE_AXIS_U

			# 3. V-axis arrow (vertical down)
			var v_end := pivot_screen + Vector2(0.0, HANDLE_LENGTH)
			if _point_to_segment_dist(mouse_pos, pivot_screen, v_end) <= HIT_RADIUS:
				return HandleType.MOVE_AXIS_V

		ToolMode.ROTATE:
			# Dial ring
			var dist := mouse_pos.distance_to(pivot_screen)
			if absf(dist - ROTATE_RADIUS) <= HIT_RADIUS:
				return HandleType.ROTATE_DIAL

		ToolMode.SCALE:
			# 1. Center / uniform scale box
			if mouse_pos.distance_to(pivot_screen) <= (CENTER_BOX_SIZE * 0.75 + 4.0):
				return HandleType.SCALE_UNIFORM

			# 2. U-axis scale handle
			var u_end := pivot_screen + Vector2(HANDLE_LENGTH, 0.0)
			if mouse_pos.distance_to(u_end) <= (SCALE_BOX_SIZE + 4.0):
				return HandleType.SCALE_AXIS_U
			if _point_to_segment_dist(mouse_pos, pivot_screen, u_end) <= HIT_RADIUS:
				return HandleType.SCALE_AXIS_U

			# 3. V-axis scale handle
			var v_end := pivot_screen + Vector2(0.0, HANDLE_LENGTH)
			if mouse_pos.distance_to(v_end) <= (SCALE_BOX_SIZE + 4.0):
				return HandleType.SCALE_AXIS_V
			if _point_to_segment_dist(mouse_pos, pivot_screen, v_end) <= HIT_RADIUS:
				return HandleType.SCALE_AXIS_V

	return HandleType.NONE

func update_hover(mouse_pos: Vector2, canvas: PBUvCanvas) -> bool:
	var prev := hover_handle
	hover_handle = hit_test(mouse_pos, canvas)
	return hover_handle != prev

# ==============================================================================
# Drag Session
# ==============================================================================

func begin_drag(handle: HandleType, mouse_pos: Vector2, canvas: PBUvCanvas) -> void:
	is_dragging = true
	active_handle = handle
	_drag_start_mouse = mouse_pos
	_drag_start_pivot = pivot_uv

	var pivot_screen := canvas.uv_to_screen(pivot_uv)
	var diff := mouse_pos - pivot_screen
	_drag_start_angle = rad_to_deg(atan2(diff.y, diff.x))
	_drag_start_dist = maxf(10.0, diff.length())

	current_delta_uv = Vector2.ZERO
	current_angle_deg = 0.0
	current_scale = Vector2.ONE

func apply_drag(mouse_pos: Vector2, canvas: PBUvCanvas, shift_pressed: bool, ctrl_pressed: bool) -> Dictionary:
	if not is_dragging or canvas == null:
		return {}

	var pivot_screen := canvas.uv_to_screen(_drag_start_pivot)

	match active_handle:
		HandleType.MOVE_CENTER, HandleType.MOVE_AXIS_U, HandleType.MOVE_AXIS_V:
			var mouse_delta_screen := mouse_pos - _drag_start_mouse
			var raw_delta_uv := mouse_delta_screen / canvas.zoom

			if active_handle == HandleType.MOVE_AXIS_U:
				raw_delta_uv.y = 0.0
			elif active_handle == HandleType.MOVE_AXIS_V:
				raw_delta_uv.x = 0.0

			var snapped_delta := raw_delta_uv
			if snap_enabled or ctrl_pressed:
				var target_pos := _drag_start_pivot + raw_delta_uv
				var snapped_target := Vector2(
					roundf(target_pos.x / grid_snap_step) * grid_snap_step,
					roundf(target_pos.y / grid_snap_step) * grid_snap_step
				)
				if active_handle == HandleType.MOVE_AXIS_U:
					snapped_delta.x = snapped_target.x - _drag_start_pivot.x
				elif active_handle == HandleType.MOVE_AXIS_V:
					snapped_delta.y = snapped_target.y - _drag_start_pivot.y
				else:
					snapped_delta = snapped_target - _drag_start_pivot

			current_delta_uv = snapped_delta
			pivot_uv = _drag_start_pivot + snapped_delta
			return {
				"type": "move",
				"delta": current_delta_uv,
				"pivot": _drag_start_pivot
			}

		HandleType.ROTATE_DIAL:
			var diff := mouse_pos - pivot_screen
			var cur_angle := rad_to_deg(atan2(diff.y, diff.x))
			var raw_angle := cur_angle - _drag_start_angle

			var snapped_angle := raw_angle
			if snap_enabled or ctrl_pressed:
				snapped_angle = roundf(raw_angle / rotation_snap_step) * rotation_snap_step

			current_angle_deg = snapped_angle
			return {
				"type": "rotate",
				"angle": current_angle_deg,
				"pivot": _drag_start_pivot
			}

		HandleType.SCALE_UNIFORM, HandleType.SCALE_AXIS_U, HandleType.SCALE_AXIS_V:
			var cur_diff := mouse_pos - pivot_screen
			var raw_scale := Vector2.ONE

			if active_handle == HandleType.SCALE_UNIFORM or shift_pressed:
				var ratio := cur_diff.length() / maxf(1.0, _drag_start_dist)
				raw_scale = Vector2(ratio, ratio)
			elif active_handle == HandleType.SCALE_AXIS_U:
				var sx := maxf(0.01, cur_diff.x / HANDLE_LENGTH)
				raw_scale = Vector2(sx, 1.0)
			elif active_handle == HandleType.SCALE_AXIS_V:
				var sy := maxf(0.01, cur_diff.y / HANDLE_LENGTH)
				raw_scale = Vector2(1.0, sy)

			if snap_enabled or ctrl_pressed:
				var snap_res := 0.125
				raw_scale.x = maxf(0.01, roundf(raw_scale.x / snap_res) * snap_res)
				raw_scale.y = maxf(0.01, roundf(raw_scale.y / snap_res) * snap_res)

			current_scale = raw_scale
			return {
				"type": "scale",
				"scale": current_scale,
				"pivot": _drag_start_pivot
			}

	return {}

func commit_drag() -> void:
	is_dragging = false
	active_handle = HandleType.NONE
	current_delta_uv = Vector2.ZERO
	current_angle_deg = 0.0
	current_scale = Vector2.ONE

# ==============================================================================
# Rendering
# ==============================================================================

func draw(canvas: PBUvCanvas) -> void:
	if canvas == null:
		return

	var p_screen := canvas.uv_to_screen(pivot_uv)

	match tool_mode:
		ToolMode.MOVE:
			_draw_move_gizmo(canvas, p_screen)
		ToolMode.ROTATE:
			_draw_rotate_gizmo(canvas, p_screen)
		ToolMode.SCALE:
			_draw_scale_gizmo(canvas, p_screen)

func _draw_move_gizmo(canvas: PBUvCanvas, p: Vector2) -> void:
	var hov_c := (hover_handle == HandleType.MOVE_CENTER or active_handle == HandleType.MOVE_CENTER)
	var hov_u := (hover_handle == HandleType.MOVE_AXIS_U or active_handle == HandleType.MOVE_AXIS_U)
	var hov_v := (hover_handle == HandleType.MOVE_AXIS_V or active_handle == HandleType.MOVE_AXIS_V)

	# U-axis arm (X)
	var u_end := p + Vector2(HANDLE_LENGTH, 0.0)
	var col_u := COLOR_HOVER if hov_u else COLOR_AXIS_U
	canvas.draw_line(p, u_end, col_u, 2.0)
	_draw_arrowhead(canvas, u_end, Vector2(1.0, 0.0), col_u)

	# V-axis arm (Y)
	var v_end := p + Vector2(0.0, HANDLE_LENGTH)
	var col_v := COLOR_HOVER if hov_v else COLOR_AXIS_V
	canvas.draw_line(p, v_end, col_v, 2.0)
	_draw_arrowhead(canvas, v_end, Vector2(0.0, 1.0), col_v)

	# Center square
	var col_c := COLOR_HOVER if hov_c else COLOR_CENTER
	var half_box := CENTER_BOX_SIZE * 0.5
	var center_rect := Rect2(p - Vector2(half_box, half_box), Vector2(CENTER_BOX_SIZE, CENTER_BOX_SIZE))
	canvas.draw_rect(center_rect, col_c)
	canvas.draw_rect(center_rect, Color(0.1, 0.1, 0.1, 0.8), false, 1.0)

func _draw_rotate_gizmo(canvas: PBUvCanvas, p: Vector2) -> void:
	var hov := (hover_handle == HandleType.ROTATE_DIAL or active_handle == HandleType.ROTATE_DIAL)
	var col := COLOR_HOVER if hov else COLOR_RING

	# Translucent background circle
	canvas.draw_circle(p, ROTATE_RADIUS, COLOR_DIAL_FILL)

	# Ring outline
	canvas.draw_arc(p, ROTATE_RADIUS, 0, TAU, 48, col, 2.0, true)

	# Crosshairs at center
	var cross_size := 6.0
	canvas.draw_line(p - Vector2(cross_size, 0), p + Vector2(cross_size, 0), col, 1.5)
	canvas.draw_line(p - Vector2(0, cross_size), p + Vector2(0, cross_size), col, 1.5)

	# Handle indicator on ring
	var angle_rad := deg_to_rad(current_angle_deg)
	var handle_pt := p + Vector2(cos(angle_rad), sin(angle_rad)) * ROTATE_RADIUS
	canvas.draw_circle(handle_pt, 4.5, col)
	canvas.draw_circle(handle_pt, 2.5, Color.WHITE)

func _draw_scale_gizmo(canvas: PBUvCanvas, p: Vector2) -> void:
	var hov_c := (hover_handle == HandleType.SCALE_UNIFORM or active_handle == HandleType.SCALE_UNIFORM)
	var hov_u := (hover_handle == HandleType.SCALE_AXIS_U or active_handle == HandleType.SCALE_AXIS_U)
	var hov_v := (hover_handle == HandleType.SCALE_AXIS_V or active_handle == HandleType.SCALE_AXIS_V)

	# U-axis scale arm
	var u_end := p + Vector2(HANDLE_LENGTH, 0.0)
	var col_u := COLOR_HOVER if hov_u else COLOR_AXIS_U
	canvas.draw_line(p, u_end, col_u, 2.0)
	var half_s := SCALE_BOX_SIZE * 0.5
	var u_box := Rect2(u_end - Vector2(half_s, half_s), Vector2(SCALE_BOX_SIZE, SCALE_BOX_SIZE))
	canvas.draw_rect(u_box, col_u)
	canvas.draw_rect(u_box, Color(0.1, 0.1, 0.1, 0.8), false, 1.0)

	# V-axis scale arm
	var v_end := p + Vector2(0.0, HANDLE_LENGTH)
	var col_v := COLOR_HOVER if hov_v else COLOR_AXIS_V
	canvas.draw_line(p, v_end, col_v, 2.0)
	var v_box := Rect2(v_end - Vector2(half_s, half_s), Vector2(SCALE_BOX_SIZE, SCALE_BOX_SIZE))
	canvas.draw_rect(v_box, col_v)
	canvas.draw_rect(v_box, Color(0.1, 0.1, 0.1, 0.8), false, 1.0)

	# Center uniform box
	var col_c := COLOR_HOVER if hov_c else COLOR_CENTER
	var half_box := CENTER_BOX_SIZE * 0.5
	var center_rect := Rect2(p - Vector2(half_box, half_box), Vector2(CENTER_BOX_SIZE, CENTER_BOX_SIZE))
	canvas.draw_rect(center_rect, col_c)
	canvas.draw_rect(center_rect, Color(0.1, 0.1, 0.1, 0.8), false, 1.0)

func _draw_arrowhead(canvas: PBUvCanvas, tip: Vector2, direction: Vector2, color: Color) -> void:
	var perp := Vector2(-direction.y, direction.x)
	var p1 := tip
	var p2 := tip - direction * ARROW_HEAD_SIZE + perp * (ARROW_HEAD_SIZE * 0.5)
	var p3 := tip - direction * ARROW_HEAD_SIZE - perp * (ARROW_HEAD_SIZE * 0.5)
	canvas.draw_colored_polygon(PackedVector2Array([p1, p2, p3]), color)

func _point_to_segment_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len2 := ab.length_squared()
	if len2 < 0.0001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	var proj := a + ab * t
	return p.distance_to(proj)
