## emitter_preview.gd — the particle-emitter preview shared by every GLB
## consumer in this repo: the retro viewer, the frame-pacing bench and the
## interactive fly bench (via BenchVariants). An exported map carries each
## emitter as an `EmitterTex_*` holder quad whose node extras hold the
## `poi_emitter` record (PBMapExporter.make_emitter_extras) — glTF has no
## particle concept, so a CONSUMER rebuilds the emitter from that record.
## This class is that rebuild: find the holders, hide them, and draw a
## camera-facing billboard mesh per emitter, advanced per frame.
##
## The rebuild is a LOOPING, STATELESS particle stream: at any scene time
## every particle is a closed form of (t, its index, the emitter's seed) —
## the same hash, the same phase slots, the same two-segment size/colour
## curves, the same flipbook frame — which is what makes it a reference for
## what the device does rather than an artist's impression of it. The C
## reference lives in retro_engine/psp/psp_render.c; SPEC_RETRO_FORMAT.md §8
## defines the semantics.
class_name EmitterPreview


## The emitter random source (identical to pbm.h's pbm_hash32 / pbm_rand).
static func hash32(x: int) -> int:
	x &= 0xFFFFFFFF
	x ^= x >> 16
	x = (x * 0x7feb352d) & 0xFFFFFFFF
	x ^= x >> 15
	x = (x * 0x846ca68b) & 0xFFFFFFFF
	x ^= x >> 16
	return x & 0xFFFFFFFF


static func rand(seed_v: int, idx: int, chan: int) -> float:
	var h := hash32(seed_v ^ ((idx * 0x9E3779B9) & 0xFFFFFFFF) ^ ((chan * 0x85EBCA6B) & 0xFFFFFFFF))
	return float(h >> 8) * (1.0 / 16777216.0)


static func _vec3(d: Dictionary, key: String, fallback: Vector3) -> Vector3:
	var v = d.get(key, null)
	if v is Array and (v as Array).size() >= 3:
		return Vector3(v[0], v[1], v[2])
	if v is Vector3:
		return v
	return fallback


static func unpack_rgba(packed: int) -> Color:
	var v: int = packed & 0xFFFFFFFF
	return Color(
		float(v & 0xFF) / 255.0,
		float((v >> 8) & 0xFF) / 255.0,
		float((v >> 16) & 0xFF) / 255.0,
		float((v >> 24) & 0xFF) / 255.0)


## Derives the per-particle constants, exactly as the loader does at load time.
static func derive_particles(rec: Dictionary) -> Array:
	var count: int = maxi(1, int(rec.get("count", 1)))
	var seed_v: int = int(rec.get("seed", 0))
	var dir: Vector3 = _vec3(rec, "dir", Vector3.UP).normalized()
	var t1 := (Vector3(0, 0, 1) if absf(dir.y) > 0.9 else Vector3.UP).cross(dir).normalized()
	var t2 := dir.cross(t1)
	var spread: float = float(rec.get("spread", 0.0))
	var life_min: float = float(rec.get("life_min", 1.0))
	var life_max: float = float(rec.get("life_max", 1.0))
	var speed_min: float = float(rec.get("speed_min", 0.0))
	var speed_max: float = float(rec.get("speed_max", 0.0))
	var size_min: float = float(rec.get("size_min", 0.1))
	var size_max: float = float(rec.get("size_max", 0.1))
	var spin_min: float = float(rec.get("spin_min", 0.0))
	var spin_max: float = float(rec.get("spin_max", 0.0))
	var angle_min: float = float(rec.get("angle_min", 0.0))
	var angle_max: float = float(rec.get("angle_max", 0.0))
	var spawn_radius: float = float(rec.get("spawn_radius", 0.0))
	var aligned: bool = (int(rec.get("flags", 0)) & 8) != 0
	var parts: Array = []
	for k in range(count):
		var theta: float = spread * sqrt(rand(seed_v, k, 7))
		var phi: float = rand(seed_v, k, 8) * TAU
		var st := sin(theta)
		var d := dir * cos(theta) + (t1 * cos(phi) + t2 * sin(phi)) * st
		var spawn := Vector3.ZERO
		if spawn_radius > 0.0:
			var cz: float = 2.0 * rand(seed_v, k, 10) - 1.0
			var sz := sqrt(maxf(0.0, 1.0 - cz * cz))
			var ang: float = rand(seed_v, k, 11) * TAU
			spawn = Vector3(sz * cos(ang), sz * sin(ang), cz) * spawn_radius * pow(rand(seed_v, k, 9), 1.0 / 3.0)
		var life: float = maxf(0.0001, lerpf(life_min, life_max, rand(seed_v, k, 0)))
		var phase: float = 0.0 if aligned else fposmod(float(k) / float(count) + rand(seed_v, k, 1) / float(count), 1.0)
		parts.append({
			"life": life,
			"inv_life": 1.0 / life,
			"phase": phase,
			"speed": lerpf(speed_min, speed_max, rand(seed_v, k, 2)),
			"size": lerpf(size_min, size_max, rand(seed_v, k, 3)),
			"spin": lerpf(spin_min, spin_max, rand(seed_v, k, 4)),
			"angle0": lerpf(angle_min, angle_max, rand(seed_v, k, 12)),
			"wobble_phase": rand(seed_v, k, 5) * TAU,
			"anim_offset": rand(seed_v, k, 6),
			"dir": d,
			"spawn": spawn,
		})
	return parts


## The preview material mirrors the emitter's own contract: unshaded, vertex
## colour as albedo (that is where the fade lives), depth writes off, and the
## emitter's blend mode. The blend mode comes from the emitter RECORD's
## additive flag, not from the holder's material: glTF has no additive blend,
## so an ADD emitter's material round-trips through the .glb as plain alpha
## blend (alphaMode BLEND), and trusting it turns additive glow dots into
## dark balls.
static func preview_material(rec: Dictionary, src_mat: Material) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	if (int(rec.get("flags", 0)) & 1) != 0:  # PBM_EMIT_ADDITIVE
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	elif src_mat is StandardMaterial3D:
		mat.blend_mode = (src_mat as StandardMaterial3D).blend_mode
	else:
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	if src_mat is StandardMaterial3D:
		mat.albedo_texture = (src_mat as StandardMaterial3D).albedo_texture
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return mat


## The billboards for scene time `t`. `emit_time` is the preview's own clock —
## the preview mesh is world-space geometry, so the node carrying it must sit
## at an identity transform (the holders do, and so does this class's rig).
static func build_mesh(rec: Dictionary, parts: Array, t: float, cam_right: Vector3, cam_up: Vector3) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var origin := _vec3(rec, "pos", Vector3.ZERO)
	var gravity := _vec3(rec, "gravity", Vector3.ZERO)
	var damping: float = float(rec.get("damping", 0.0))
	var knee: float = clampf(float(rec.get("knee", 0.5)), 0.05, 0.95)
	var size_mid: float = float(rec.get("size_mid", 1.0))
	var size_end: float = float(rec.get("size_end", 1.0))
	var aspect: float = float(rec.get("aspect", 1.0))
	var wobble_amp: float = float(rec.get("wobble_amp", 0.0))
	var wobble_freq: float = float(rec.get("wobble_freq", 0.0))
	var c_start := unpack_rgba(int(rec.get("color_start", -1)))
	var c_mid := unpack_rgba(int(rec.get("color_mid", -1)))
	var c_end := unpack_rgba(int(rec.get("color_end", -1)))
	var flags: int = int(rec.get("flags", 0))
	var cols_n: int = maxi(1, int(rec.get("atlas_cols", 1)))
	var rows_n: int = maxi(1, int(rec.get("atlas_rows", 1)))
	var loops: int = maxi(1, int(rec.get("anim_loops", 1)))
	var frames: int = cols_n * rows_n
	var axis: Vector3 = _vec3(rec, "dir", Vector3.UP).normalized()
	var w1: Vector3 = (Vector3(0, 0, 1) if absf(axis.y) > 0.9 else Vector3.UP).cross(axis).normalized()
	var w2: Vector3 = axis.cross(w1)

	for p in parts:
		var age: float = fposmod(t * float(p["inv_life"]) + float(p["phase"]), 1.0)
		var tau: float = age * float(p["life"])
		var size: float = float(p["size"]) * (lerpf(1.0, size_mid, age / knee) if age < knee
			else lerpf(size_mid, size_end, (age - knee) / (1.0 - knee)))
		var pos: Vector3 = origin + (p["spawn"] as Vector3)
		if damping > 0.0:
			var decay := exp(-damping * tau)
			var k1: float = (1.0 - decay) / damping
			var k2: float = (tau - k1) / damping
			pos += (p["dir"] as Vector3) * float(p["speed"]) * k1 + gravity * k2
		else:
			pos += (p["dir"] as Vector3) * float(p["speed"]) * tau + gravity * 0.5 * tau * tau
		if wobble_amp > 0.0:
			var w: float = TAU * wobble_freq * tau + float(p["wobble_phase"])
			pos += (w1 * sin(w) + w2 * cos(w)) * wobble_amp

		var col: Color = (c_start.lerp(c_mid, age / knee) if age < knee
			else c_mid.lerp(c_end, (age - knee) / (1.0 - knee)))
		var ang: float = float(p["angle0"]) + float(p["spin"]) * tau
		var rx: Vector3 = cam_right
		var uy: Vector3 = cam_up
		if (flags & 2) != 0:  # PBM_EMIT_Y_LOCKED
			var fwd: Vector3 = -cam_right.cross(cam_up)  # camera forward, from the basis
			rx = Vector3(fwd.z, 0.0, -fwd.x).normalized()
			uy = rx.cross(fwd).normalized()
		var rh: Vector3 = (rx * cos(ang) + uy * sin(ang)) * size * aspect * 0.5
		var uh: Vector3 = (uy * cos(ang) - rx * sin(ang)) * size * 0.5

		var u0 := 0.0
		var v0 := 0.0
		var du := 1.0
		var dv := 1.0
		if frames > 1:
			var af: float = fposmod(age * float(loops) + float(p["anim_offset"]), 1.0)
			var fr: int = mini(frames - 1, int(af * float(frames)))
			var cx_i: int = fr % cols_n
			var cy_i: int = fr / cols_n
			u0 = float(cx_i) / float(cols_n)
			v0 = float(cy_i) / float(rows_n)
			du = 1.0 / float(cols_n)
			dv = 1.0 / float(rows_n)

		var c0 := pos - rh - uh
		var c1 := pos + rh - uh
		var c2 := pos + rh + uh
		var c3 := pos - rh + uh
		var quad := PackedVector3Array([c3, c2, c1, c3, c1, c0])
		var quv := PackedVector2Array([
			Vector2(u0, v0), Vector2(u0 + du, v0), Vector2(u0 + du, v0 + dv),
			Vector2(u0, v0), Vector2(u0 + du, v0 + dv), Vector2(u0, v0 + dv)])
		for qi in range(6):
			verts.append(quad[qi])
			uvs.append(quv[qi])
			cols.append(col)

	var am := ArrayMesh.new()
	if verts.is_empty():
		return am
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return am


## Finds the emitter holders in an imported map: zero-size quads named
## `EmitterTex_*` whose node extras carry the `poi_emitter` record.
static func find_holders(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D and node.has_meta("extras") \
				and (node.get_meta("extras") as Dictionary).has("poi_emitter"):
			out.append(node as MeshInstance3D)
		for c in node.get_children():
			stack.append(c)
	return out


## Builds the preview MeshInstance3D for one holder (hidden holder, billboard
## mesh filled in by tick()). `parent` receives the preview node; the record's
## vertices are world-space, so `parent` must sit at an identity transform.
static func make_preview(holder: MeshInstance3D, parent: Node) -> Dictionary:
	var extras: Dictionary = holder.get_meta("extras")
	var rec: Dictionary = extras["poi_emitter"]
	holder.visible = false
	var mi := MeshInstance3D.new()
	mi.name = "EmitterPreview_%s" % holder.name.trim_prefix("EmitterTex_")
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var src_mat: Material = null
	if holder.mesh != null and holder.mesh.get_surface_count() > 0:
		src_mat = holder.mesh.surface_get_material(0)
	else:
		src_mat = holder.material_override
	mi.material_override = preview_material(rec, src_mat)
	parent.add_child(mi)
	return { "mi": mi, "rec": rec, "parts": derive_particles(rec) }


## One-click wiring for a loaded GLB scene: rebuilds every emitter record as a
## preview under a rig node added as `root`'s child and returns the rig (null
## if the map carries no emitters). The rig advances its own clock in
## _process and rebuilds the billboard meshes against the active camera —
## consumers just add the scene to the tree and fly.
static func attach(root: Node) -> Rig:
	var holders := find_holders(root)
	if holders.is_empty():
		return null
	var rig := Rig.new()
	rig.name = "EmitterPreviewRig"
	root.add_child(rig)
	for holder in holders:
		rig.previews.append(make_preview(holder, rig))
	return rig


## Advances every preview to scene time `t` from `cam`'s basis. Static so a
## consumer with its own clock (the retro viewer's scroll-freeze) can drive
## previews made by make_preview() directly.
static func tick(previews: Array, t: float, cam: Camera3D) -> void:
	var right := cam.global_transform.basis.x
	var up := cam.global_transform.basis.y
	for ep in previews:
		var mi: MeshInstance3D = ep["mi"]
		if mi == null or not is_instance_valid(mi):
			continue
		mi.mesh = build_mesh(ep["rec"], ep["parts"], t, right, up)


## The per-map node EmitterPreview.attach() leaves behind: a self-contained
## clock + camera tracker that keeps the billboard meshes current. Lives as a
## child of the map root, so freeing the map frees the previews too.
class Rig extends Node:
	var previews: Array[Dictionary] = []
	var emit_time: float = 0.0

	func _process(delta: float) -> void:
		if previews.is_empty():
			return
		emit_time += delta
		var cam := get_viewport().get_camera_3d()
		if cam == null:
			return
		EmitterPreview.tick(previews, emit_time, cam)
