## PBModeBanner — small top-center hint label floating over the 3D scene.
##
## Shows which persistent viewport mode the Material dock currently drives
## (Texture Paint / Stamp / Sprite placement / Shape placement) and how to
## leave it ("select the Material & UV tab to exit"). Pure readout: it never
## consumes mouse input (MOUSE_FILTER_IGNORE), so clicks pass through to the
## scene and the engine untouched.
@tool
class_name PBModeBanner
extends PanelContainer

var _label: Label

func _init() -> void:
	name = "PBModeBanner"
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_CENTER_TOP)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_END
	offset_top = 8.0

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.11, 0.15, 0.88)
	style.set_corner_radius_all(6)
	style.set_border_width_all(1)
	style.border_color = Color(0.2, 0.85, 1.0, 0.8)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 4.0
	style.content_margin_bottom = 4.0
	add_theme_stylebox_override("panel", style)

	_label = Label.new()
	_label.name = "HintLabel"
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("font_size", 12)
	_label.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	_label.add_theme_constant_override("outline_size", 4)
	add_child(_label)

## Shows the banner with `text` (accent-colored), or hides it when empty.
func set_hint(text: String, accent: Color = Color(0.2, 0.85, 1.0)) -> void:
	_label.text = text
	visible = text != ""
	var style := get_theme_stylebox("panel") as StyleBoxFlat
	if style != null:
		style.border_color = Color(accent.r, accent.g, accent.b, 0.8)
	_label.add_theme_color_override("font_color", Color(accent.r, accent.g, accent.b).lerp(Color.WHITE, 0.75))
	# Re-center around the top-middle anchor after the text changed our size.
	reset_size()
	_update_layout.call_deferred()

func _update_layout() -> void:
	# PRESET_CENTER_TOP anchored at offset_top: with grow BOTH the control
	# stays horizontally centered while its size tracks the text.
	offset_top = 8.0
	offset_bottom = 8.0 + size.y
