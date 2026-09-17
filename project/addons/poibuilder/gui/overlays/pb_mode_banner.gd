## PBModeBanner — small top-center hint over the 3D scene.
##
## A plain Label in the same style as the cursor size readout (white text,
## black outline) showing how to leave the active placement mode. Pure
## readout: MOUSE_FILTER_IGNORE, clicks pass through to the scene. Kept
## centered on the top edge by repositioning whenever the text or the host
## control resizes — anchors fought the dynamic width and could leave the
## label hanging off the viewport's left edge.
@tool
class_name PBModeBanner
extends Label

func _init() -> void:
	name = "PBModeBanner"
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_theme_color_override("font_color", Color.WHITE)
	add_theme_color_override("font_outline_color", Color.BLACK)
	add_theme_constant_override("outline_size", 8)
	add_theme_font_size_override("font_size", 14)
	z_index = 90

func _ready() -> void:
	var host := _host_control()
	if host != null and not host.resized.is_connected(_reposition):
		host.resized.connect(_reposition)

## The label is parented to the 3D viewport host (a plain Control).
func _host_control() -> Control:
	return get_parent() as Control

## Shows the banner with `text`, or hides it when empty. `accent` is unused
## (kept for call compatibility) — the style matches the size overlay.
func set_hint(text: String, _accent: Color = Color.WHITE) -> void:
	self.text = text
	visible = text != ""
	_reposition.call_deferred()

func _reposition() -> void:
	var host := _host_control()
	if host == null:
		return
	reset_size()
	position = Vector2(maxf(4.0, (host.size.x - size.x) * 0.5), 8.0)
