## PBApplyPrep — Prepares a material the moment it is APPLIED to faces.
##
## Two properties travel with the FACE, not the palette card, and an ordinary
## "apply material" used to destroy both:
##
## 1. Scrolling texture: the scroll speed lives on the face's material
##    (PBUv — the retro exporters split meshes by material). Applying a fresh
##    palette card onto a scrolling face replaced the animated material with
##    a static one: the waterfall stopped. The previous face's speed is now
##    carried onto the incoming material (on a copy — the palette card itself
##    must stay shareable and untouched).
##
## 2. Texture transparency: the retro exporters enable alpha from a texture's
##    PIXELS, so a water plane bakes transparent on the PSP even though the
##    Godot preview showed it opaque. PBAlphaDetect gives the incoming
##    material the same handling before it lands (see that class).
##
## Pure statics: the plugin's apply path and the tests share one definition.
@tool
class_name PBApplyPrep
extends RefCounted

## Returns the material to actually assign to the faces: `incoming` prepared
## with detected transparency, carrying `previous`'s scroll speed when the
## incoming material does not scroll of its own. Returns `incoming` itself
## when nothing needs changing; any mutated variant is a detached duplicate,
## so shared resources (saved .tres, palette wrappers) are never rewritten.
static func prepare(incoming: Material, previous: Material) -> Material:
	if incoming == null:
		return null
	var out := PBAlphaDetect.ensure_transparency(incoming)
	var carry := PBUv.get_scroll_speed(previous)
	if carry == Vector2.ZERO or PBUv.has_scroll(out) or not (out is StandardMaterial3D):
		return out
	var dup := out.duplicate() as StandardMaterial3D
	dup.resource_path = ""
	PBUv.set_scroll_speed(dup, carry)
	return dup
