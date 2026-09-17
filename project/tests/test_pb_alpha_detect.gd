## Tests for PBAlphaDetect (pixel-based transparency detection) and
## PBApplyPrep (apply-time material preparation: transparency + scroll carry).
##
## The exporter picks a texture's alpha handling from its pixels; these tests
## pin the editor-side helpers to the same decision so a water plane previews
## transparent in Godot exactly when the PSP bake draws it blended.
extends GutTest

func _make_image(w: int, h: int, alphas: Array) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in range(h):
		for x in range(w):
			var a: float = alphas[(y * w + x) % alphas.size()]
			img.set_pixel(x, y, Color(1.0, 0.5, 0.25, a))
	return img

func before_each() -> void:
	PBAlphaDetect.clear_cache()

func test_opaque_texture_classifies_opaque() -> void:
	var tex := ImageTexture.create_from_image(_make_image(4, 4, [1.0]))
	assert_eq(PBAlphaDetect.classify_texture(tex), PBAlphaDetect.Mode.OPAQUE)

func test_binary_alpha_classifies_cutout() -> void:
	var tex := ImageTexture.create_from_image(_make_image(4, 4, [0.0, 1.0]))
	assert_eq(PBAlphaDetect.classify_texture(tex), PBAlphaDetect.Mode.CUTOUT)

func test_soft_alpha_classifies_blend() -> void:
	var tex := ImageTexture.create_from_image(_make_image(4, 4, [0.0, 1.0, 0.5]))
	assert_eq(PBAlphaDetect.classify_texture(tex), PBAlphaDetect.Mode.BLEND)

func test_ensure_transparency_sets_modes_and_never_downgrades() -> void:
	# Soft alpha -> TRANSPARENCY_ALPHA (water).
	var water := StandardMaterial3D.new()
	water.albedo_texture = ImageTexture.create_from_image(_make_image(4, 4, [0.0, 1.0, 0.5]))
	var out := PBAlphaDetect.ensure_transparency(water)
	assert_eq(out, water, "Runtime material is mutated in place")
	assert_eq(out.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA)

	# Binary alpha -> ALPHA_SCISSOR (foliage; also renders in the shadow pass).
	var leaf := StandardMaterial3D.new()
	leaf.albedo_texture = ImageTexture.create_from_image(_make_image(4, 4, [0.0, 1.0]))
	assert_eq(PBAlphaDetect.ensure_transparency(leaf).transparency,
		BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR)

	# Opaque art -> untouched.
	var brick := StandardMaterial3D.new()
	brick.albedo_texture = ImageTexture.create_from_image(_make_image(4, 4, [1.0]))
	assert_eq(PBAlphaDetect.ensure_transparency(brick).transparency,
		BaseMaterial3D.TRANSPARENCY_DISABLED)

	# An explicit mode is never downgraded (an authored scissor stays scissor
	# even over soft art).
	var authored := StandardMaterial3D.new()
	authored.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	authored.albedo_texture = ImageTexture.create_from_image(_make_image(4, 4, [0.5]))
	assert_eq(PBAlphaDetect.ensure_transparency(authored).transparency,
		BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR)

func test_ensure_transparency_duplicates_saved_material() -> void:
	# A saved .tres must never be rewritten in place: the change lands on a
	# detached duplicate.
	var soft := StandardMaterial3D.new()
	soft.albedo_texture = ImageTexture.create_from_image(_make_image(4, 4, [0.5]))
	soft.resource_path = "res://test_fake_water.tres"
	var out := PBAlphaDetect.ensure_transparency(soft)
	assert_ne(out, soft, "Saved material is duplicated, not mutated")
	assert_true(out.resource_path.is_empty(), "Duplicate is detached from disk")
	assert_eq(out.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA)
	assert_eq(soft.transparency, BaseMaterial3D.TRANSPARENCY_DISABLED, "Original untouched")

func test_apply_prep_carries_scroll_speed() -> void:
	var previous := StandardMaterial3D.new()
	PBUv.set_scroll_speed(previous, Vector2(0.3, -0.6))
	var incoming := StandardMaterial3D.new()
	incoming.albedo_texture = ImageTexture.create_from_image(_make_image(4, 4, [1.0]))

	var out := PBApplyPrep.prepare(incoming, previous)
	assert_ne(out, incoming, "Scroll carry happens on a copy")
	assert_eq(PBUv.get_scroll_speed(out), Vector2(0.3, -0.6), "Previous speed carried over")
	assert_eq(PBUv.get_scroll_speed(incoming), Vector2.ZERO, "Incoming material untouched")

func test_apply_prep_does_not_override_incoming_scroll() -> void:
	var previous := StandardMaterial3D.new()
	PBUv.set_scroll_speed(previous, Vector2(1.0, 0.0))
	var incoming := StandardMaterial3D.new()
	PBUv.set_scroll_speed(incoming, Vector2(0.0, 2.0))
	var out := PBApplyPrep.prepare(incoming, previous)
	assert_eq(out, incoming, "Incoming scroll wins — no copy needed")
	assert_eq(PBUv.get_scroll_speed(out), Vector2(0.0, 2.0))

func test_apply_prep_no_previous_scroll_is_identity() -> void:
	var previous := StandardMaterial3D.new()
	var incoming := StandardMaterial3D.new()
	incoming.albedo_texture = ImageTexture.create_from_image(_make_image(4, 4, [0.0, 1.0]))
	var out := PBApplyPrep.prepare(incoming, previous)
	# No scroll to carry, but transparency is still detected from pixels.
	assert_eq(out.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR)

func test_apply_prep_enables_transparency_on_apply() -> void:
	# The water-plane report: applying a wrapper whose transparency is
	# DISABLED over transparent art must land transparent on the faces.
	var previous := StandardMaterial3D.new()
	var incoming := StandardMaterial3D.new()
	incoming.albedo_texture = ImageTexture.create_from_image(_make_image(4, 4, [0.0, 0.6, 1.0]))
	var out := PBApplyPrep.prepare(incoming, previous)
	assert_eq(out.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA,
		"Soft-alpha art applies as a blending material")
