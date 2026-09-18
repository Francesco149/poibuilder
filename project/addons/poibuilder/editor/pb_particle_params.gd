## PBParticleParams — The authoring model for retro particle emitters.
##
## An emitter in the scene is an ordinary GPUParticles3D (a quad draw pass +
## a ParticleProcessMaterial); the retro exporter maps it field-by-field onto
## the format's emitter record (PBMapExporter._emitter_from_node). This class
## is the SINGLE SOURCE of that construction: the placement tool builds its
## preview and final nodes through it, and the overlay's Edit Emitter
## Properties modal reads and writes nodes through it — so a placed emitter,
## a hand-tuned one, and the exported record cannot drift apart.
##
## PSP budgets (measured; see retro_engine/RETRO-AUTHORING.md §4.3 and
## SPEC_RETRO_FORMAT.md §8): the format caps 256 particles per map (~0.72 ms
## GPU on hardware) and PBMapExporter clamps 64 per emitter. Particle FILL is
## the real cost, so the size knob tops out where a quad starts owning the
## screen. These are soft caps surfaced in the UI, not silent rewrites: the
## exporter still clamps the count it writes.
@tool
class_name PBParticleParams
extends RefCounted

## Hard per-emitter cap (the exporter clamps to the same number).
const MAX_PER_EMITTER := 64
## Format-wide soft budget across all emitters of a map.
const MAP_BUDGET := 256
## Quad-height ceiling for the placement/properties knobs: a bigger particle
## is a fill-rate decision an author should make deliberately (blended mist
## at point-blank range was the worst measured frame in the showcase).
const MAX_QUAD_HEIGHT := 4.0

## ── Presets ─────────────────────────────────────────────────────────────────
## One preset per shipped particle texture family; the placement palette is
## particle TEXTURES, and the preset gives each a sane starting effect (the
## same shapes the courtyard demo's brazier / embers / mist emitters use).
## Keyed by substring of the texture file name, first match wins.
const PRESETS := {
	"flame": {
		"additive": true, "y_locked": false,
		"count": 24, "lifetime": 0.9, "size": 0.55,
		"speed": 1.1, "spread": 14.0, "rise": 0.35,
		"opacity": 1.0,
		"color_start": Color(1.0, 0.85, 0.4, 0.0),
		"color_mid": Color(1.0, 0.55, 0.15, 1.0),
		"color_end": Color(0.6, 0.1, 0.05, 0.0),
	},
	"smoke": {
		"additive": false, "y_locked": true,
		"count": 12, "lifetime": 2.2, "size": 1.2,
		"speed": 0.5, "spread": 25.0, "rise": -0.05,
		"opacity": 0.55,
		"color_start": Color(0.75, 0.75, 0.78, 0.0),
		"color_mid": Color(0.75, 0.75, 0.78, 1.0),
		"color_end": Color(0.7, 0.7, 0.72, 0.0),
	},
	"glow": {
		"additive": true, "y_locked": false,
		"count": 16, "lifetime": 1.2, "size": 0.25,
		"speed": 0.8, "spread": 30.0, "rise": 0.1,
		"opacity": 1.0,
		"color_start": Color(1.0, 0.95, 0.75, 0.0),
		"color_mid": Color(1.0, 0.9, 0.6, 1.0),
		"color_end": Color(0.8, 0.5, 0.2, 0.0),
	},
}

## The preset for a texture path (file-name substring match; the generic
## "glow" preset is the fallback — additive, small, cheap: the PSP-friendly
## default). A COPY: the presets are constants, and callers (the dock, the
## properties modal) tweak values on the returned dictionary.
static func preset_for_texture(path: String) -> Dictionary:
	var lower := String(path).to_lower()
	for key in PRESETS:
		if lower.contains(key):
			return PRESETS[key].duplicate()
	return PRESETS["glow"].duplicate()

## ── Overlay param defs (the "fine adjustments" modal) ───────────────────────

static func get_param_defs() -> Array:
	return [
		{"name": "count", "label": "Particles", "min": 1.0, "max": float(MAX_PER_EMITTER), "step": 1.0,
			"tooltip": "Simultaneous particles. 64 is the per-emitter format cap; the whole map budgets 256 (measured 0.72 ms GPU on PSP)."},
		{"name": "size", "label": "Particle Size", "min": 0.05, "max": MAX_QUAD_HEIGHT, "step": 0.05, "suffix": "m",
			"tooltip": "Quad height in metres; the width follows the texture's aspect (a sheet cell's, when the flipbook knobs are set). Screen AREA is the cost on PSP, not the count — keep big particles deliberate."},
		{"name": "speed", "label": "Speed", "min": 0.0, "max": 8.0, "step": 0.05, "suffix": "m/s",
			"tooltip": "Initial speed along the emission cone."},
		{"name": "lifetime", "label": "Lifetime", "min": 0.1, "max": 8.0, "step": 0.05, "suffix": "s",
			"tooltip": "Seconds a particle lives."},
		{"name": "spread", "label": "Spread", "min": 0.0, "max": 180.0, "step": 1.0, "suffix": "°",
			"tooltip": "Cone half-angle. 180° = spherical."},
		{"name": "rise", "label": "Rise / Gravity", "min": -4.0, "max": 4.0, "step": 0.05, "suffix": "m/s²",
			"tooltip": "Upward acceleration (negative = fall)."},
		{"name": "opacity", "label": "Opacity", "min": 0.05, "max": 1.0, "step": 0.01,
			"tooltip": "Peak opacity of a particle (multiplies the texture's alpha)."},
		{"name": "additive", "label": "Additive", "kind": "bool",
			"tooltip": "Additive blending: fire/glow/sparks. Order-independent on PSP — the cheap default. Off = soft alpha blend (mist), which needs sorting."},
		{"name": "y_locked", "label": "Lock Upright", "kind": "bool",
			"tooltip": "Cylinder billboard: quads stay world-upright instead of facing the camera (the mist emitter's look)."},
		{"name": "atlas_cols", "label": "Sheet Columns", "min": 1.0, "max": 8.0, "step": 1.0,
			"tooltip": "Flipbook columns. The texture must BE a sprite sheet: each particle shows one cell (tex_width / columns wide, e.g. 192x64 with 3 columns = three 64x64 frames), and the quad takes the cell's aspect. 1 = the whole image is one frame."},
		{"name": "atlas_rows", "label": "Sheet Rows", "min": 1.0, "max": 8.0, "step": 1.0,
			"tooltip": "Flipbook rows (tex_height / rows per cell). 1 = a single row of frames."},
	]

## ── Node construction (shared by placement + properties) ────────────────────

## Builds a complete emitter node. `values` uses get_param_defs()'s names;
## missing keys fall back to the preset. Deterministic: a fixed seed is set
## AND mirrored to `poi_seed` meta, which the exporter prefers, so the editor
## preview and the device play the same field.
static func build_node(texture: Texture2D, values: Dictionary, emitter_name: String) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = emitter_name
	apply_values(p, values, texture)
	return p

## Reads a placed emitter back into the params vocabulary (the properties
## modal's starting values).
static func values_from_node(node: GPUParticles3D) -> Dictionary:
	var out := {}
	if node == null:
		return out
	var pm := node.process_material as ParticleProcessMaterial
	out["count"] = float(node.amount)
	var quad_h := 0.5
	var cols := 1
	var rows := 1
	var additive := false
	var draw_mat: Material = node.material_override
	if draw_mat == null and node.draw_pass_1 != null and node.draw_pass_1.get_surface_count() > 0:
		draw_mat = node.draw_pass_1.surface_get_material(0)
	if node.draw_pass_1 is QuadMesh:
		quad_h = (node.draw_pass_1 as QuadMesh).size.y
	if draw_mat is StandardMaterial3D:
		var sm := draw_mat as StandardMaterial3D
		additive = sm.blend_mode == BaseMaterial3D.BLEND_MODE_ADD
		if sm.billboard_mode == BaseMaterial3D.BILLBOARD_PARTICLES:
			cols = maxi(1, sm.particles_anim_h_frames)
			rows = maxi(1, sm.particles_anim_v_frames)
	out["size"] = quad_h
	out["additive"] = 1.0 if additive else 0.0
	out["atlas_cols"] = float(cols)
	out["atlas_rows"] = float(rows)
	out["y_locked"] = 1.0 if (node.has_meta("poi_y_locked") and bool(node.get_meta("poi_y_locked"))) else 0.0
	if pm != null:
		out["speed"] = pm.initial_velocity_max
		out["lifetime"] = node.lifetime
		out["spread"] = pm.spread
		out["rise"] = pm.gravity.y
		out["opacity"] = pm.color.a
	return out

## Writes `values` onto the node in place (live preview while dragging a
## spinner; the plugin wraps the before/after into one undo action).
static func apply_values(node: GPUParticles3D, values: Dictionary, texture: Texture2D) -> void:
	if node == null:
		return
	var count := int(clampf(float(values.get("count", 16.0)), 1.0, MAX_PER_EMITTER))
	var lifetime := maxf(float(values.get("lifetime", 1.0)), 0.1)
	node.amount = count
	node.lifetime = lifetime
	node.one_shot = false
	node.local_coords = false
	node.preprocess = 1.0
	# Deterministic playback: the preview and the exported record share the
	# seed (the exporter prefers the poi_seed meta).
	var seed_value := absi(hash(str(node.name))) & 0x7FFFFFFF
	if node.has_meta("poi_seed"):
		seed_value = int(node.get_meta("poi_seed")) & 0x7FFFFFFF
	node.use_fixed_seed = true
	node.seed = seed_value
	node.set_meta("poi_seed", seed_value)
	var y_locked := float(values.get("y_locked", 0.0)) > 0.5
	node.set_meta("poi_y_locked", y_locked)

	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = clampf(float(values.get("spread", 14.0)), 0.0, 180.0)
	pm.initial_velocity_min = float(values.get("speed", 0.5)) * 0.45
	pm.initial_velocity_max = float(values.get("speed", 0.5))
	pm.gravity = Vector3(0.0, clampf(float(values.get("rise", 0.35)), -50.0, 50.0), 0.0)
	pm.damping_min = 0.4
	pm.damping_max = 0.9
	pm.scale_min = 0.7
	pm.scale_max = 1.25
	pm.angle_min = -20.0
	pm.angle_max = 20.0
	pm.angular_velocity_min = -40.0
	pm.angular_velocity_max = 40.0
	# Fade in, hold, fade out: the ramp's alpha peak at 0.35 is the knee the
	# exporter writes (PBMapExporter._emitter_knee), so the runtime's
	# two-segment colour/size interpolation matches this gradient.
	var opacity := clampf(float(values.get("opacity", 1.0)), 0.05, 1.0)
	var tint := Color(1.0, 1.0, 1.0, opacity)
	var c_start: Color = values.get("color_start", Color(1, 1, 1, 0.0))
	var c_mid: Color = values.get("color_mid", Color(1, 1, 1, 1.0))
	var c_end: Color = values.get("color_end", Color(1, 1, 1, 0.0))
	var ramp := Gradient.new()
	ramp.set_color(0, c_start)
	ramp.set_color(1, c_end)
	ramp.add_point(0.35, c_mid)
	var gt := GradientTexture1D.new()
	gt.gradient = ramp
	pm.color_ramp = gt
	pm.color = tint

	# Rise and swell over the lifetime; the exporter samples this at 0/knee/1.
	var sc := Curve.new()
	sc.add_point(Vector2(0.0, 0.55))
	sc.add_point(Vector2(0.35, 1.0))
	sc.add_point(Vector2(1.0, 1.35))
	var sct := CurveTexture.new()
	sct.curve = sc
	pm.scale_curve = sct
	node.process_material = pm

	var quad_h := clampf(float(values.get("size", 0.5)), 0.05, MAX_QUAD_HEIGHT)
	var cols := int(clampf(float(values.get("atlas_cols", 1.0)), 1.0, 8.0))
	var rows := int(clampf(float(values.get("atlas_rows", 1.0)), 1.0, 8.0))
	# The quad shows ONE frame of the sheet, so its width follows the FRAME's
	# aspect (tex_w/cols : tex_h/rows), not the image's: a 3-column sheet of
	# square frames is a 3:1 image, and a square quad stretched each frame 3x
	# (the "columns make the particles stretch" report). The exporter reads the
	# same aspect off the QuadMesh, so editor, viewer and device agree.
	var frame_aspect := 1.0
	if texture != null and texture.get_width() > 0 and texture.get_height() > 0:
		var frame_w := float(texture.get_width()) / float(cols)
		var frame_h := float(texture.get_height()) / float(rows)
		if frame_w > 0.0 and frame_h > 0.0:
			frame_aspect = frame_w / frame_h
	var qm := QuadMesh.new()
	qm.size = Vector2(quad_h * frame_aspect, quad_h)
	var sm := StandardMaterial3D.new()
	if texture != null:
		sm.albedo_texture = texture
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if float(values.get("additive", 1.0)) > 0.5 \
			else BaseMaterial3D.BLEND_MODE_MIX
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# The sprite-sheet grid must be declared in BILLBOARD_PARTICLES mode —
	# that is what the exporter reads as the flipbook. anim_speed = 1 plays
	# (and exports as) exactly one flipbook cycle per particle lifetime.
	if cols > 1 or rows > 1:
		sm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		sm.particles_anim_h_frames = cols
		sm.particles_anim_v_frames = rows
		sm.particles_anim_loop = true
		pm.anim_speed_min = 1.0
		pm.anim_speed_max = 1.0
	else:
		sm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	sm.vertex_color_use_as_albedo = true
	qm.material = sm
	node.draw_pass_1 = qm

## ── Map budget ──────────────────────────────────────────────────────────────

## Total simultaneous particles across every emitter under `root`.
static func total_amount(root: Node) -> int:
	var total := 0
	if root == null:
		return 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is GPUParticles3D:
			total += (n as GPUParticles3D).amount
		for c in n.get_children():
			stack.append(c)
	return total

## The dock/placement readout: "x / 256 map budget", flagged when over.
static func budget_readout(root: Node) -> String:
	var total := total_amount(root)
	if total > MAP_BUDGET:
		return "Particles: %d / %d map budget — OVER (PSP cost grows with screen area; export clamps per emitter)" % [total, MAP_BUDGET]
	return "Particles: %d / %d map budget" % [total, MAP_BUDGET]
