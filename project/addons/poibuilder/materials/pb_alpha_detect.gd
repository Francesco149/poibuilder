## PBAlphaDetect — Decides, from a texture's PIXELS, how its material should
## draw, and applies that to materials that declare no transparency.
##
## Why this exists: the retro exporters pick a texture's alpha handling from
## its PIXELS, not from the material (PBMapExporter._narrow_alpha_mode — an
## asset's declared mode is only ever narrowed). A water texture over a plane
## therefore bakes transparent on the PSP while the Godot preview — whose
## palette wrapper leaves transparency DISABLED — shows an opaque quad. The
## detection below mirrors the exporter's exact decision so the editor
## preview and the bake agree WITHOUT the author enabling anything:
##   no alpha channel                -> opaque (leave DISABLED)
##   alpha, every texel 1-bit        -> cutout (ALPHA_SCISSOR — also shadows)
##   alpha with in-between values    -> soft blend (TRANSPARENCY_ALPHA)
##
## The image decode runs once per texture (static cache); thresholds are the
## exporter's own (a < 250 counts as transparent, 4 < a < 250 is "soft").
@tool
class_name PBAlphaDetect
extends RefCounted

enum Mode { OPAQUE, CUTOUT, BLEND }

## Texture RID -> Mode. Editor-session cache; textures are immutable in
## practice (an edited image reimports as a new resource/RID).
static var _cache: Dictionary = {}

## Classifies a texture's alpha in the exporter's terms.
static func classify_texture(tex: Texture2D) -> Mode:
	if tex == null:
		return Mode.OPAQUE
	var key := tex.get_rid()
	if _cache.has(key):
		return _cache[key]
	var mode := Mode.OPAQUE
	var img := tex.get_image()
	if img != null and not img.is_empty():
		if img.is_compressed():
			img = img.duplicate()
			img.decompress()
		match img.detect_alpha():
			Image.ALPHA_NONE:
				mode = Mode.OPAQUE
			Image.ALPHA_BLEND:
				# In-between alpha values exist: a genuine soft ramp.
				mode = Mode.BLEND
			_:
				# 1-bit channel: alpha exists but every texel is 0/255.
				mode = Mode.CUTOUT
	_cache[key] = mode
	return mode

## Ensures a material DRAWS the transparency its texture carries. Materials
## that already declare a mode are untouched (never downgraded); opaque-art
## materials are untouched. When the material lives on disk (a saved .tres)
## the change is applied to a detached duplicate so the shared resource is
## never rewritten — the duplicate is returned; otherwise the same material
## is returned after in-place mutation.
static func ensure_transparency(mat: Material) -> Material:
	if mat == null or not (mat is StandardMaterial3D):
		return mat
	var sm := mat as StandardMaterial3D
	if sm.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
		return mat
	if sm.albedo_texture == null:
		return mat
	var mode := classify_texture(sm.albedo_texture)
	if mode == Mode.OPAQUE:
		return mat
	var target := BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR if mode == Mode.CUTOUT \
			else BaseMaterial3D.TRANSPARENCY_ALPHA
	if not sm.resource_path.is_empty():
		var dup := sm.duplicate() as StandardMaterial3D
		dup.resource_path = ""
		dup.transparency = target
		return dup
	sm.transparency = target
	return sm

## Test hook: clears the per-session texture cache.
static func clear_cache() -> void:
	_cache.clear()
