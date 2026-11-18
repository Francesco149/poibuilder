## PBRetroFx — the retro target's runtime animation and map-level records:
## per-mesh effects (lump "mesh_fx"), the author's camera path (lump
## "camera_path") and the map's own sky/fog (lump "env").
##
## Everything here is DATA a level carries; the PSP evaluates it in closed form
## (SPEC_RETRO_FORMAT.md §10-§12, pbm.h). Authoring is metadata, so a scene
## saved with it keeps it:
##
##   node.set_meta("poi_fx", {...})       any MeshInstance3D / PBMesh: morph,
##                                        additive, no_fog, decal (depth bias:
##                                        true = 48 depth units, or a number)
##   material.set_meta("poi_fx", {...})   flipbook / additive / no_fog that
##                                        should follow the material
##   marker.set_meta("poi_camera_pose", {"hold": 3.0, "travel": 5.0})
##   root.set_meta("poi_env", {...})      see env_lump()
##
## ── Morph ────────────────────────────────────────────────────────────────
## The GE blends up to 8 full vertex sets per mesh (position, colour, UV) with
## its morph-weight registers. The exporter builds those sets by applying a
## DESCRIPTOR to every vertex of the mesh, in the node's LOCAL space:
##
##   "morph": {
##     "mode": "keyframe" | "harmonic",
##     "period": 6.0, "phase": 0.0, "ease": true,     # keyframe only
##     "base": {descriptor},                         # optional: reshapes the
##                                                   # mesh's own (rest) set
##     "targets": [ {descriptor + "t"} ... ]          # keyframe: pose at loop
##                                                   # time t (0..1, ascending)
##              | [ {descriptor + "period" + "phase"} ] # harmonic: weight is
##                                                   # sin(2pi t/period + phase)
##   }
##
## Descriptor keys (all optional, applied in this order):
##   "scale": Vector3 about "pivot": Vector3
##   "rotate": {"axis": Vector3, "angle": radians, "pivot": Vector3}
##   "offset": Vector3, optionally scaled along X by
##       "offset_vary": {"amp", "freq", "phase"}: offset * (1 + amp*sin(freq*x + phase))
##       (a run-up that reaches further in some places than others)
##   "bend": {"dir": Vector3, "base": float, "height": float, "power": 2.0}
##       displacement dir * clamp((y - base) / height, 0, 1)^power — a palm or
##       a reed swaying from a planted foot. With "pivot": Vector3 and
##       "radius": float the weight is the XZ distance from the pivot instead
##       (fronds fluttering more toward their tips)
##   "y_min": float — clamp the result's height from below (a surf strip that
##       slides up a sloped beach but must stay ON the water seaward)
##   "gerstner": {"amp", "len", "dir": Vector2, "steep", "part": 0|1,
##                "fade": {"dir": Vector2, "from": d0, "to": d1}, "fade2": {...},
##                "tint": Color}
##       one quadrature half of a travelling Gerstner wave (part 0 = the cos
##       half, part 1 = the sin half; gerstner_pair() makes both). "fade" ramps
##       the amplitude along a direction (calm water at the shore), "tint" is a
##       colour DELTA scaled by the crest height (foam that rides the crests)
##   "alpha": float multiplier, "alpha_add": float
##   "color": Color multiplier (rgb)
##   "uv": Vector2 added, "uv_scale": Vector2 (about the UV origin)
@tool
class_name PBRetroFx
extends RefCounted

const META := "poi_fx"
const META_CAMERA_POSE := "poi_camera_pose"
const META_ENV := "poi_env"

const PBM_META_MESH_FX := 5
const PBM_META_CAMERA_PATH := 6
const PBM_META_ENV := 7

const MESHFX_MAGIC := 0x3158464D # "MFX1"
const MESHFX_VERSION := 1
const MESHFX_SIZE := 124
const MAX_TARGETS := 8
const MAX_FRAMES := 16

const MFX_ADDITIVE := 1
const MFX_NO_FOG := 2
## Depth-biased toward the camera ("decal": true or a bias in depth units).
const MFX_DECAL := 4

const MORPH_NONE := 0
const MORPH_KEYFRAME := 1
const MORPH_HARMONIC := 2
## The convex form of HARMONIC (see pbm.h): what the exporter writes. Each
## distinct period becomes a TRIPLET of targets with non-negative weights.
const MORPH_CYCLIC := 3

const CAMPATH_MAGIC := 0x534D4143 # "CAMS"
const CAMPATH_MAX := 24
const ENV_MAGIC := 0x31564E45 # "ENV1"


# ════════════════════════════════════════════════════════════ authoring helpers

## A travelling Gerstner swell as the two harmonic targets that reproduce it
## exactly (sin(kx - wt) = sin kx cos wt - cos kx sin wt). `dir` is the travel
## direction in the node's local XZ plane; `steep` (0..1) pulls vertices toward
## the crests the way real swell sharpens.
static func gerstner_pair(amp: float, wavelength: float, dir: Vector2, period: float,
		steep: float = 0.5, fade: Dictionary = {}, tint: Color = Color(0, 0, 0, 0)) -> Array:
	var g := {"amp": amp, "len": wavelength, "dir": dir.normalized(), "steep": steep}
	if not fade.is_empty():
		g["fade"] = fade
	if tint != Color(0, 0, 0, 0):
		g["tint"] = tint
	var c := g.duplicate()
	c["part"] = 0
	var s := g.duplicate()
	s["part"] = 1
	# weight(C) = cos wt = sin(wt + pi/2); weight(S) = sin wt
	return [
		{"gerstner": c, "period": period, "phase": PI * 0.5},
		{"gerstner": s, "period": period, "phase": 0.0},
	]


## A sway from a planted foot: two harmonic targets bending along X and Z with
## different periods, so the motion never repeats on a visible beat.
static func sway(amount: float, base_y: float, height: float, period: float = 3.7) -> Dictionary:
	return {
		"mode": "harmonic",
		"targets": [
			{"bend": {"dir": Vector3(amount, 0, 0), "base": base_y, "height": height},
				"period": period, "phase": 0.0},
			{"bend": {"dir": Vector3(0, -amount * 0.15, amount * 0.6), "base": base_y, "height": height},
				"period": period * 1.618, "phase": 1.3},
		],
	}


## Merges the node's and the material's poi_fx (node keys win).
static func fx_for(node: Node, mat: Material) -> Dictionary:
	var out := {}
	if mat != null and mat.has_meta(META):
		var m = mat.get_meta(META)
		if m is Dictionary:
			out.merge(m, true)
	if node != null and node.has_meta(META):
		var n = node.get_meta(META)
		if n is Dictionary:
			out.merge(n, true)
	return out


static func has_morph(fx: Dictionary) -> bool:
	if not fx.has("morph"):
		return false
	var m: Dictionary = fx["morph"]
	var targets: Array = m.get("targets", [])
	return not targets.is_empty()


static func is_harmonic(fx: Dictionary) -> bool:
	return has_morph(fx) and str(fx["morph"].get("mode", "keyframe")) == "harmonic"


## Harmonic targets grouped by period (in order of first appearance): each
## group becomes one CYCLIC triplet. At most two groups fit the GE's 8 sets.
static func harmonic_groups(fx: Dictionary) -> Array:
	var groups: Array = []
	var targets: Array = fx["morph"]["targets"]
	for i in range(targets.size()):
		var per := float((targets[i] as Dictionary).get("period", 1.0))
		var found := false
		for g: Dictionary in groups:
			if absf(float(g["period"]) - per) < 0.0001:
				(g["members"] as Array).append(i)
				found = true
				break
		if not found:
			groups.append({"period": per, "members": [i]})
	if groups.size() > 2:
		PBLogger.new().warn("io", "PBRetroFx: %d distinct harmonic periods, the GE fits 2 - the rest are dropped" % groups.size())
		groups.resize(2)
	return groups


static func morph_target_count(fx: Dictionary) -> int:
	if not has_morph(fx):
		return 1
	if is_harmonic(fx):
		return 1 + 3 * harmonic_groups(fx).size()
	return mini(1 + (fx["morph"]["targets"] as Array).size(), MAX_TARGETS)


# ══════════════════════════════════════════════════════════════ evaluation

## Applies one descriptor to a local-space vertex. Returns [pos, uv, color].
static func apply_descriptor(d: Dictionary, p: Vector3, uv: Vector2, c: Color) -> Array:
	if d.is_empty():
		return [p, uv, c]
	if d.has("scale"):
		var pivot: Vector3 = d.get("pivot", Vector3.ZERO)
		p = pivot + (p - pivot) * (d["scale"] as Vector3)
	if d.has("rotate"):
		var r: Dictionary = d["rotate"]
		var rpivot: Vector3 = r.get("pivot", Vector3.ZERO)
		var axis: Vector3 = (r.get("axis", Vector3.UP) as Vector3).normalized()
		p = rpivot + (p - rpivot).rotated(axis, float(r.get("angle", 0.0)))
	if d.has("offset"):
		var off: Vector3 = d["offset"]
		if d.has("offset_vary"):
			var ov: Dictionary = d["offset_vary"]
			off *= 1.0 + float(ov.get("amp", 0.0)) * sin(float(ov.get("freq", 0.1)) * p.x + float(ov.get("phase", 0.0)))
		p += off
	if d.has("bend"):
		var b: Dictionary = d["bend"]
		var f := 0.0
		if b.has("pivot"):
			var bp: Vector3 = b["pivot"]
			f = clampf(Vector2(p.x - bp.x, p.z - bp.z).length() / maxf(float(b.get("radius", 1.0)), 0.0001), 0.0, 1.0)
		else:
			var h: float = maxf(float(b.get("height", 1.0)), 0.0001)
			f = clampf((p.y - float(b.get("base", 0.0))) / h, 0.0, 1.0)
		p += (b["dir"] as Vector3) * pow(f, float(b.get("power", 2.0)))
	if d.has("gerstner"):
		var g: Dictionary = d["gerstner"]
		var amp := float(g.get("amp", 0.1))
		for fkey in ["fade", "fade2"]:
			if not g.has(fkey):
				continue
			var fd: Dictionary = g[fkey]
			var fdir: Vector2 = (fd.get("dir", Vector2(0, 1)) as Vector2).normalized()
			var d0 := float(fd.get("from", 0.0))
			var d1 := float(fd.get("to", 1.0))
			var along := Vector2(p.x, p.z).dot(fdir)
			var ramp := clampf((along - d0) / (d1 - d0), 0.0, 1.0) if absf(d1 - d0) > 0.0001 else 1.0
			amp *= ramp * ramp * (3.0 - 2.0 * ramp)
		var dir: Vector2 = (g.get("dir", Vector2(1, 0)) as Vector2).normalized()
		var k := TAU / maxf(float(g.get("len", 4.0)), 0.01)
		var theta := k * Vector2(p.x, p.z).dot(dir)
		var q := float(g.get("steep", 0.5))
		var dy := 0.0
		var dh := 0.0
		if int(g.get("part", 0)) == 0:
			dy = amp * cos(theta)
			dh = -q * amp * sin(theta)
		else:
			dy = amp * sin(theta)
			dh = q * amp * cos(theta)
		p += Vector3(dir.x * dh, dy, dir.y * dh)
		if g.has("tint") and amp > 0.0001:
			var t: Color = g["tint"]
			var s := dy / float(g.get("amp", 0.1))
			c = Color(c.r + t.r * s, c.g + t.g * s, c.b + t.b * s, c.a + t.a * s)
	if d.has("y_min"):
		p.y = maxf(p.y, float(d["y_min"]))
	if d.has("alpha"):
		c.a *= float(d["alpha"])
	if d.has("alpha_add"):
		c.a += float(d["alpha_add"])
	if d.has("color"):
		var m: Color = d["color"]
		c = Color(c.r * m.r, c.g * m.g, c.b * m.b, c.a)
	if d.has("uv_scale"):
		uv *= d["uv_scale"] as Vector2
	if d.has("uv"):
		uv += d["uv"] as Vector2
	return [p, uv, c]


## Every vertex set for one local-space vertex: [base, target 1, ...], each
## [pos, uv, color]. The base is the mesh's own vertex run through "base".
static func eval_targets(fx: Dictionary, p: Vector3, uv: Vector2, c: Color) -> Array:
	var m: Dictionary = fx.get("morph", {})
	var out: Array = []
	out.append(apply_descriptor(m.get("base", {}), p, uv, c))
	if not has_morph(fx):
		return out
	var targets: Array = m["targets"]
	if is_harmonic(fx):
		return _cyclic_sets(fx, out[0], targets, p, uv, c)
	for i in range(mini(targets.size(), MAX_TARGETS - 1)):
		out.append(apply_descriptor(targets[i], p, uv, c))
	return out


## HARMONIC -> CYCLIC: per period P, the targets' displacements D_i (weighted
## sin(theta + phase_i), theta = 2 pi t / P) sum to A cos theta + B sin theta
## with A = sum D_i sin(phase_i), B = sum D_i cos(phase_i). Three targets at
## phi_k = 0, 120, 240 degrees, P_k = rest + 2J (A cos phi_k + B sin phi_k),
## weighted (1 + cos(theta - phi_k)) / 3J, reproduce it exactly with
## non-negative weights summing to one. Colour and UV ride the same algebra.
static func _cyclic_sets(fx: Dictionary, base: Array, targets: Array, p: Vector3, uv: Vector2,
		c: Color) -> Array:
	var out: Array = [base]
	var groups := harmonic_groups(fx)
	var J := float(groups.size())
	var bp: Vector3 = base[0]
	var buv: Vector2 = base[1]
	var bc: Color = base[2]
	for g: Dictionary in groups:
		var a_p := Vector3.ZERO
		var b_p := Vector3.ZERO
		var a_uv := Vector2.ZERO
		var b_uv := Vector2.ZERO
		var a_c := Vector4.ZERO
		var b_c := Vector4.ZERO
		for i: int in g["members"]:
			var td: Dictionary = targets[i]
			var ph := float(td.get("phase", 0.0))
			var r := apply_descriptor(td, p, uv, c)
			var dp: Vector3 = (r[0] as Vector3) - bp
			var duv: Vector2 = (r[1] as Vector2) - buv
			var rc: Color = r[2]
			var dc := Vector4(rc.r - bc.r, rc.g - bc.g, rc.b - bc.b, rc.a - bc.a)
			a_p += dp * sin(ph); b_p += dp * cos(ph)
			a_uv += duv * sin(ph); b_uv += duv * cos(ph)
			a_c += dc * sin(ph); b_c += dc * cos(ph)
		for k in range(3):
			var phi := TAU * k / 3.0
			var cp := cos(phi) * 2.0 * J
			var sp := sin(phi) * 2.0 * J
			var oc := a_c * cp + b_c * sp
			out.append([bp + a_p * cp + b_p * sp, buv + a_uv * cp + b_uv * sp,
				Color(bc.r + oc.x, bc.g + oc.y, bc.b + oc.z, bc.a + oc.w)])
	return out


# ═══════════════════════════════════════════════════════════════ encoders

static func pack_color(c: Color) -> int:
	var r := int(clampf(c.r, 0.0, 1.0) * 255.0)
	var g := int(clampf(c.g, 0.0, 1.0) * 255.0)
	var b := int(clampf(c.b, 0.0, 1.0) * 255.0)
	var a := int(clampf(c.a, 0.0, 1.0) * 255.0)
	return r | (g << 8) | (b << 16) | (a << 24)


## One PbmMeshFx record + its morph vertex data (targets 1..N-1, each a full
## copy of the mesh's vertex list in file order). `targets` is the per-target
## vertex dictionaries the writer built ({u, v, color, x, y, z}); target 0 is
## the mesh itself and is not repeated. `frame_ids` are the flipbook's texture
## table indices.
static func encode_record(mesh_index: int, fx: Dictionary, targets: Array,
		frame_ids: Array) -> PackedByteArray:
	var n_targets := targets.size() if has_morph(fx) else 1
	var nv: int = (targets[0] as Array).size() if not targets.is_empty() else 0
	var morph_bytes := (n_targets - 1) * nv * 24
	var buf := PackedByteArray()
	buf.resize(MESHFX_SIZE + morph_bytes)
	buf.encode_u32(0x00, mesh_index)
	var flags := 0
	if bool(fx.get("additive", false)):
		flags |= MFX_ADDITIVE
	if bool(fx.get("no_fog", false)):
		flags |= MFX_NO_FOG
	var decal_units := 0
	if fx.has("decal") and not (fx["decal"] is bool and not fx["decal"]):
		flags |= MFX_DECAL
		decal_units = 48 if fx["decal"] is bool else clampi(int(fx["decal"]), 1, 4096)
	buf.encode_u16(0x04, flags)
	var mode := MORPH_NONE
	var m: Dictionary = fx.get("morph", {})
	if n_targets > 1:
		mode = MORPH_CYCLIC if is_harmonic(fx) else MORPH_KEYFRAME
	buf[0x06] = mode
	buf[0x07] = n_targets
	buf.encode_float(0x08, float(m.get("period", 1.0)))
	buf.encode_float(0x0C, float(m.get("phase", 0.0)))
	var tl: Array = m.get("targets", [])
	var groups: Array = harmonic_groups(fx) if mode == MORPH_CYCLIC else []
	for i in range(MAX_TARGETS):
		var kt := 0.0
		var kp := 0.0
		if i >= 1 and i < n_targets:
			if mode == MORPH_CYCLIC:
				# the phases are folded into the triplet's geometry
				kt = float(groups[(i - 1) / 3]["period"])
			elif i - 1 < tl.size():
				kt = float((tl[i - 1] as Dictionary).get("t", float(i) / float(n_targets)))
		buf.encode_float(0x10 + i * 4, kt)
		buf.encode_float(0x30 + i * 4, kp)
	buf[0x50] = 1 if bool(m.get("ease", true)) else 0
	var nf := mini(frame_ids.size(), MAX_FRAMES)
	buf[0x51] = nf
	buf.encode_u16(0x52, decal_units)
	var fb: Dictionary = fx.get("flipbook", {})
	buf.encode_float(0x54, float(fb.get("fps", 0.0)) if nf > 0 else 0.0)
	for i in range(MAX_FRAMES):
		buf.encode_s16(0x58 + i * 2, int(frame_ids[i]) if i < nf else -1)
	buf.encode_u32(0x78, morph_bytes)
	var off := MESHFX_SIZE
	for t in range(1, n_targets):
		for v: Dictionary in targets[t]:
			buf.encode_float(off, v["u"]); buf.encode_float(off + 4, v["v"])
			buf.encode_u32(off + 8, v["color"])
			buf.encode_float(off + 12, v["x"]); buf.encode_float(off + 16, v["y"])
			buf.encode_float(off + 20, v["z"])
			off += 24
	return buf


static func mesh_fx_lump(records: Array[PackedByteArray]) -> Dictionary:
	var buf := PackedByteArray()
	buf.resize(16)
	buf.encode_u32(0, MESHFX_MAGIC)
	buf.encode_u32(4, MESHFX_VERSION)
	buf.encode_u32(8, records.size())
	buf.encode_u32(12, 0)
	for r in records:
		buf.append_array(r)
	return {"tag": "mesh_fx", "type": PBM_META_MESH_FX, "data": buf}


## The camera path: every Node3D under `root` carrying poi_camera_pose, in
## tree order. Yaw/pitch follow the PSP app's convention (yaw 0 looks down -Z,
## positive pitch looks up). Empty dictionary when the map has none.
static func camera_path_lump(root: Node) -> Dictionary:
	var poses: Array[Node3D] = []
	_collect_poses(root, poses)
	if poses.is_empty():
		return {}
	var n := mini(poses.size(), CAMPATH_MAX)
	var buf := PackedByteArray()
	buf.resize(16 + n * 44)
	buf.encode_u32(0, CAMPATH_MAGIC)
	buf.encode_u32(4, 1)
	buf.encode_u32(8, n)
	buf.encode_u32(12, 0)
	for i in range(n):
		var node := poses[i]
		var xf := node.global_transform if node.is_inside_tree() else _world_xf(node)
		var fwd := -xf.basis.z.normalized()
		var cfg: Dictionary = node.get_meta(META_CAMERA_POSE)
		var off := 16 + i * 44
		var nb := str(node.name).to_ascii_buffer()
		nb.resize(16)
		nb[15] = 0
		for k in range(16):
			buf[off + k] = nb[k]
		buf.encode_float(off + 16, xf.origin.x)
		buf.encode_float(off + 20, xf.origin.y)
		buf.encode_float(off + 24, xf.origin.z)
		buf.encode_float(off + 28, atan2(fwd.x, -fwd.z))
		buf.encode_float(off + 32, asin(clampf(fwd.y, -1.0, 1.0)))
		buf.encode_float(off + 36, float(cfg.get("hold", 2.0)))
		buf.encode_float(off + 40, float(cfg.get("travel", 4.0)))
	return {"tag": "camera_path", "type": PBM_META_CAMERA_PATH, "data": buf}


## The map's sky colour and fog (root meta poi_env):
##   {"clear": Color, "fog": bool, "fog_near": float, "fog_far": float,
##    "fog_color": Color, "far": float, "near": float}
static func env_lump(root: Node) -> Dictionary:
	if root == null or not root.has_meta(META_ENV):
		return {}
	var e: Dictionary = root.get_meta(META_ENV)
	var buf := PackedByteArray()
	buf.resize(40)
	buf.encode_u32(0, ENV_MAGIC)
	buf.encode_u32(4, pack_color(e.get("clear", Color(0.5, 0.7, 0.9))) & 0xFFFFFF)
	buf.encode_u32(8, 1 if bool(e.get("fog", false)) else 0)
	buf.encode_float(12, float(e.get("fog_near", 40.0)))
	buf.encode_float(16, float(e.get("fog_far", 200.0)))
	buf.encode_u32(20, pack_color(e.get("fog_color", Color(0.7, 0.8, 0.9))) & 0xFFFFFF)
	buf.encode_float(24, float(e.get("far", 0.0)))
	buf.encode_float(28, float(e.get("near", 0.0)))
	return {"tag": "env", "type": PBM_META_ENV, "data": buf}


static func _collect_poses(node: Node, out: Array[Node3D]) -> void:
	if node is Node3D and node.has_meta(META_CAMERA_POSE):
		out.append(node as Node3D)
	for c in node.get_children():
		_collect_poses(c, out)


static func _world_xf(node: Node3D) -> Transform3D:
	var xf := node.transform
	var p := node.get_parent()
	while p != null:
		if p is Node3D:
			xf = (p as Node3D).transform * xf
		p = p.get_parent()
	return xf
