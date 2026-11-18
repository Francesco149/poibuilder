## SeashoreMapBuilder — the SEASHORE showcase map: an open tropical bay built
## to push the retro pipeline and the PSP renderer as far as they go, with the
## old tricks those machines were made for:
##
##   - a rolling sea: a 5-target HARDWARE MORPH (two travelling Gerstner swells
##     reproduced exactly by quadrature pairs of GE morph weights) under an
##     8-frame animated water FLIPBOOK, fading into a flat far sea and fog
##   - SURF: three keyframe-morphed foam strips that break at the waterline,
##     run up the beach and soak away, staggered in phase, each with a spray
##     BURST timed to its break (emitter burst phase)
##   - a translucent SHALLOWS layer whose vertex alpha follows the water depth
##     over the sand and rides the same swell as the open sea
##   - the SUN PATH: an ADDITIVE glitter strip (flipbook) riding the swell, plus
##     twinkling additive particles spawned in flat BOXES along it
##   - rocks hit by spray bursts and ringed with pulsing foam
##   - geometry PALMS swaying in the wind (harmonic bend morph) with BLOB
##     SHADOWS swaying in sync, a far palm line, jungle backdrop cards, a
##     distant island card in the haze, a pier with a bobbing rowboat, gulls
##   - the map's own sky/fog/near/far (lump "env") and a CAMERA PATH (the
##     profiler sweeps it; the PSP app flies it in attract mode)
##
## Everything runtime is described in PBRetroFx; this file only authors it.
## Build + export headlessly:
##   ./run_seashore.sh            (export the .pbm, stage it for the PSP)
@tool
class_name SeashoreMapBuilder
extends RefCounted

const TEX := "res://test_scenes/seashore/tex/"
const OUT_PBM := "res://exports/seashore.pbm"

## The surf's loop (seconds). Every wave-timed thing derives from it.
const SURF_PERIOD := 7.0
## Toward the sun: low over the sea, ahead-left of the beach, so the sun path
## glitters straight at the default view and the beach is still well lit.
const SUN_DIR := Vector3(-0.42, 0.62, -1.0)
const SEA_Y := 0.0
## The sun as DRAWN: same azimuth as the light, but low over the horizon so it
## sits in frame from the beach and its glitter path runs toward the camera.
## The light that bakes the sand stays high (SUN_DIR) — the old art cheat.
const SUN_VISUAL_ELEV_DEG := 13.0

## Swell: two trains rolling in toward the beach (+Z), periods from deep-water
## dispersion (T = sqrt(2 pi L / g)).
const SWELL_A := {"amp": 0.30, "len": 19.0, "dir": Vector2(0.18, 1.0), "steep": 0.65, "period": 3.5}
const SWELL_B := {"amp": 0.13, "len": 12.0, "dir": Vector2(-0.5, 1.0), "steep": 0.5, "period": 2.77}


# ═════════════════════════════════════════════════════════════ the terrain

## The waterline's Z at a given X: a gently curving bay.
static func shore_z(x: float) -> float:
	return -2.0 + 1.6 * sin(x * 0.075 + 0.6) + 0.6 * sin(x * 0.19)


## Ground height. Between 12 m out and 6 m up the beach the ground is an exact
## 1:12 PLANE across the shoreline (the surf strips slide along it), dry sand
## and dunes above, a gentle seabed below.
static func height(x: float, z: float) -> float:
	var d := z - shore_z(x)
	if d > 6.0:
		var e := d - 6.0
		var y := 0.5 + e * 0.05 + _smooth(8.0, 26.0, e) * 2.4
		y += sin(x * 0.21 + z * 0.13) * 0.25 * _smooth(4.0, 14.0, e)
		y += sin(x * 0.07 - z * 0.31) * 0.35 * _smooth(6.0, 20.0, e)
		return y
	if d < -12.0:
		return -1.0 + (d + 12.0) * 0.04
	return d / 12.0


static func ground_normal(x: float, z: float) -> Vector3:
	var e := 0.25
	var dx := height(x + e, z) - height(x - e, z)
	var dz := height(x, z + e) - height(x, z - e)
	return Vector3(-dx, 2.0 * e, -dz).normalized()


static func _smooth(a: float, b: float, x: float) -> float:
	var t := clampf((x - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


static func sun_dir() -> Vector3:
	return SUN_DIR.normalized()


static func sun_visual_dir() -> Vector3:
	var h := Vector3(SUN_DIR.x, 0, SUN_DIR.z).normalized()
	var e := deg_to_rad(SUN_VISUAL_ELEV_DEG)
	return h * cos(e) + Vector3.UP * sin(e)


# ═══════════════════════════════════════════════════════════ mesh plumbing

## Collects triangles for one ArrayMesh surface. Godot's front faces are
## clockwise; add_tri orders every triangle against the normal it should face,
## so callers never think about winding (the exporter flips for the PSP).
class Builder:
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var uv := PackedVector2Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()

	func vert(p: Vector3, n: Vector3, t: Vector2, c: Color = Color.WHITE) -> int:
		pos.append(p)
		nrm.append(n)
		uv.append(t)
		col.append(c)
		return pos.size() - 1

	func tri(a: int, b: int, c: int) -> void:
		var face_n := (pos[b] - pos[a]).cross(pos[c] - pos[a])
		var want := nrm[a] + nrm[b] + nrm[c]
		if face_n.dot(want) > 0.0:
			idx.append_array([a, c, b])
		else:
			idx.append_array([a, b, c])

	func quad(a: int, b: int, c: int, d: int) -> void:
		tri(a, b, c)
		tri(a, c, d)

	func mesh() -> ArrayMesh:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = pos
		arrays[Mesh.ARRAY_NORMAL] = nrm
		arrays[Mesh.ARRAY_TEX_UV] = uv
		arrays[Mesh.ARRAY_COLOR] = col
		arrays[Mesh.ARRAY_INDEX] = idx
		var am := ArrayMesh.new()
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		return am


static func _mat(name_str: String, tex: String, transparency: int = BaseMaterial3D.TRANSPARENCY_DISABLED,
		unshaded: bool = false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.resource_name = name_str
	if ResourceLoader.exists(TEX + tex):
		m.albedo_texture = load(TEX + tex)
	m.transparency = transparency
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_BACK if transparency == BaseMaterial3D.TRANSPARENCY_DISABLED \
		else BaseMaterial3D.CULL_DISABLED
	if unshaded:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return m


static func _frames(prefix: String, n: int) -> Array:
	var out: Array = []
	for i in range(n):
		var p := TEX + "%s%d.png" % [prefix, i]
		if ResourceLoader.exists(p):
			out.append(load(p))
	return out


static func _node(root: Node3D, name_str: String, b: Builder, mat: Material,
		vc_mode: String = "", fx: Dictionary = {}) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name_str
	mi.mesh = b.mesh()
	mi.material_override = mat
	if vc_mode != "":
		mi.set_meta("poi_vertex_color", vc_mode)
	if not fx.is_empty():
		mi.set_meta(PBRetroFx.META, fx)
	root.add_child(mi)
	return mi


## The swell as morph targets (both trains), faded in from the shallows.
static func swell_targets(tint_a: Color = Color(0, 0, 0, 0), tint_b: Color = Color(0, 0, 0, 0)) -> Array:
	var fade := {"dir": Vector2(0, -1), "from": 12.0, "to": 30.0}
	var t: Array = []
	t.append_array(PBRetroFx.gerstner_pair(SWELL_A["amp"], SWELL_A["len"], SWELL_A["dir"],
		SWELL_A["period"], SWELL_A["steep"], fade, tint_a))
	t.append_array(PBRetroFx.gerstner_pair(SWELL_B["amp"], SWELL_B["len"], SWELL_B["dir"],
		SWELL_B["period"], SWELL_B["steep"], fade, tint_b))
	return t


# ═══════════════════════════════════════════════════════════════ the scene

static func build_scene() -> Node3D:
	var root := Node3D.new()
	root.name = "SeashoreMap"
	PBEnvironment.apply_preset(root, "day")
	root.set_meta("poi_env_preset", "day")
	var sun := PBEnvironment.find_sun(root)
	if sun != null:
		# the light travels AWAY from the sun: its -Z axis is -sun_dir
		sun.transform = Transform3D(Basis.looking_at(-sun_dir(), Vector3.UP), sun.position)
		sun.light_color = Color(1.0, 0.95, 0.86)
		sun.light_energy = 1.2

	var horizon := _sky_horizon_color()
	root.set_meta(PBRetroFx.META_ENV, {
		"clear": horizon, "fog": true, "fog_near": 90.0, "fog_far": 440.0,
		"fog_color": horizon, "far": 430.0, "near": 0.3,
	})

	# Draw order matters only inside the alpha pass now (the opaque pass writes
	# depth): sky first, sea, land; then translucent water, foam, glints.
	_build_sky(root)
	_build_sea(root)
	_build_terrain(root)
	_build_rocks(root)
	_build_pier(root)
	_build_palms(root)
	_build_backdrop(root)
	_build_shallows(root)
	_build_surf(root)
	_build_sun_path(root)
	_build_emitters(root)
	_build_camera_path(root)
	return root


static func _sky_horizon_color() -> Color:
	var p := TEX + "sky.png"
	if not ResourceLoader.exists(p):
		return Color(0.78, 0.86, 0.93)
	var img: Image = (load(p) as Texture2D).get_image()
	if img.is_compressed():
		img.decompress()
	var acc := Color(0, 0, 0, 0)
	var n := 0
	for y in range(img.get_height() - 10, img.get_height() - 2):
		for x in range(0, img.get_width(), 4):
			acc += img.get_pixel(x, y)
			n += 1
	acc /= float(n)
	return Color(acc.r, acc.g, acc.b, 1.0)


# ── sky ───────────────────────────────────────────────────────────────────

static func _build_sky(root: Node3D) -> void:
	var b := Builder.new()
	var center := Vector3(0, -30, 0)
	var r := 400.0
	var segs := 28
	var elev := [-4.0, 4.0, 11.0, 20.0, 32.0, 48.0, 66.0, 90.0]
	var rows: Array = []
	for e: float in elev:
		var row: Array = []
		var er := deg_to_rad(e)
		for s in range(segs + 1):
			var az := TAU * float(s) / segs
			var dir := Vector3(sin(az) * cos(er), sin(er), -cos(az) * cos(er))
			# the painting covers 0..55 degrees of elevation; the zenith keeps
			# its top row
			var v := clampf(1.0 - float(e) / 55.0, 0.03, 0.985)
			var tint := Color(1, 1, 1).lerp(Color(0.9, 0.95, 1.0), clampf(float(e) / 90.0, 0, 1))
			row.append(b.vert(center + dir * r, -dir, Vector2(float(s) / segs * 3.0, v), tint))
		rows.append(row)
	for i in range(rows.size() - 1):
		for s in range(segs):
			b.quad(rows[i][s], rows[i][s + 1], rows[i + 1][s + 1], rows[i + 1][s])
	var m := _mat("SkyDome", "sky.png", BaseMaterial3D.TRANSPARENCY_DISABLED, true)
	PBUv.set_scroll_speed(m, Vector2(0.0015, 0.0))
	_node(root, "SkyDome", b, m, "unlit", {"no_fog": true})

	# the sun: an additive glow and a wide soft halo, both outside the fog,
	# well inside the dome (the 16-bit depth step out there is metres)
	var sd := sun_visual_dir()
	for spec in [["SunGlow", 48.0, 1.0], ["SunHalo", 160.0, 0.32]]:
		var q := Builder.new()
		var c: Vector3 = sd * 260.0
		var right := sd.cross(Vector3.UP).normalized()
		var up := right.cross(sd).normalized()
		var h: float = spec[1] * 0.5
		var col := Color(1, 0.96, 0.85, spec[2])
		var a := q.vert(c - right * h - up * h, -sd, Vector2(0, 1), col)
		var bb := q.vert(c + right * h - up * h, -sd, Vector2(1, 1), col)
		var cc := q.vert(c + right * h + up * h, -sd, Vector2(1, 0), col)
		var d := q.vert(c - right * h + up * h, -sd, Vector2(0, 0), col)
		q.quad(a, bb, cc, d)
		_node(root, spec[0], q, _mat(spec[0], "sun_glow.png", BaseMaterial3D.TRANSPARENCY_ALPHA, true),
			"unlit", {"additive": true, "no_fog": true})

	# the island in the haze: a soft card whose bottom edge is the waterline
	var ib := Builder.new()
	var ic := Vector3(-150, 0, -300)
	var to_c := Vector3(-ic.x, 0, -ic.z).normalized()
	var right := Vector3(-to_c.z, 0, to_c.x)
	var w := 150.0
	var h := 37.0
	var colr := Color(0.86, 0.92, 0.95)
	var i0 := ib.vert(ic - right * w * 0.5, to_c, Vector2(0, 1), colr)
	var i1 := ib.vert(ic + right * w * 0.5, to_c, Vector2(1, 1), colr)
	var i2 := ib.vert(ic + right * w * 0.5 + Vector3(0, h, 0), to_c, Vector2(1, 0), colr)
	var i3 := ib.vert(ic - right * w * 0.5 + Vector3(0, h, 0), to_c, Vector2(0, 0), colr)
	ib.quad(i0, i1, i2, i3)
	_node(root, "Island", ib, _mat("Island", "island.png", BaseMaterial3D.TRANSPARENCY_ALPHA, true), "unlit")



# ── sea ───────────────────────────────────────────────────────────────────

## The near sea's grid. Anything that must ride the swell EXACTLY (the sun
## path) is built on these same vertices: the GE interpolates the morphed
## surface linearly between them, so a mesh sampling the wave anywhere else
## disagrees with the drawn sea by up to the swell's amplitude.
const SEA_CELL := 4.0
const SEA_NEAR_END := -84.0

static func sea_grid_xs() -> Array:
	var xs: Array = []
	var x := -100.0
	while x <= 100.0:
		xs.append(x)
		x += SEA_CELL
	return xs


static func sea_grid_zs() -> Array:
	var zs: Array = []
	var z := -12.0
	while z >= SEA_NEAR_END:
		zs.append(z)
		z -= SEA_CELL
	return zs


static func _build_sea(root: Node3D) -> void:
	var frames := _frames("sea_f", 8)
	# Near sea: the morphing swell. 4 m cells (3+ samples per wavelength).
	var b := Builder.new()
	var xs := sea_grid_xs()
	var zs := sea_grid_zs()
	var rows: Array = []
	for zz in zs:
		var row: Array = []
		for xx in xs:
			row.append(b.vert(Vector3(xx, SEA_Y, zz), Vector3.UP, Vector2(xx / 7.0, zz / 7.0),
				Color(0.8, 0.84, 0.88)))
		rows.append(row)
	for i in range(rows.size() - 1):
		for j in range(xs.size() - 1):
			b.quad(rows[i][j], rows[i][j + 1], rows[i + 1][j + 1], rows[i + 1][j])
	var targets := swell_targets(Color(0.2, 0.22, 0.2, 0), Color(0.08, 0.09, 0.08, 0))
	# far edge: back to flat where the near sea meets the far one
	for t: Dictionary in targets:
		t["gerstner"]["fade2"] = {"dir": Vector2(0, 1), "from": SEA_NEAR_END, "to": SEA_NEAR_END + 20.0}
	var sea_mat := _mat("SeaNear", "sea_f0.png", BaseMaterial3D.TRANSPARENCY_DISABLED, true)
	_node(root, "SeaNear", b, sea_mat, "unlit", {
		"morph": {"mode": "harmonic", "targets": targets},
		"flipbook": {"frames": frames, "fps": 7.0},
	})

	# Far sea: flat, big cells, the same flipbook (world-space UVs line up).
	var f := Builder.new()
	var rects := [
		Rect2(-420, -420, 840, 336),   # x0, z0, w, d (z0 = far edge)
		Rect2(-420, -84, 320, 72),
		Rect2(100, -84, 320, 72),
	]
	for r: Rect2 in rects:
		var nx := maxi(2, int(r.size.x / 70.0))
		var nz := maxi(2, int(r.size.y / 70.0))
		var grid: Array = []
		for iz in range(nz + 1):
			var row: Array = []
			for ix in range(nx + 1):
				var px := r.position.x + r.size.x * ix / nx
				var pz := r.position.y + r.size.y * iz / nz
				row.append(f.vert(Vector3(px, SEA_Y, pz), Vector3.UP, Vector2(px / 7.0, pz / 7.0),
					Color(0.8, 0.84, 0.88)))
			grid.append(row)
		for iz in range(nz):
			for ix in range(nx):
				f.quad(grid[iz][ix], grid[iz][ix + 1], grid[iz + 1][ix + 1], grid[iz + 1][ix])
	_node(root, "SeaFar", f, _mat("SeaFar", "sea_f0.png", BaseMaterial3D.TRANSPARENCY_DISABLED, true),
		"unlit", {"flipbook": {"frames": frames, "fps": 7.0}})


# ── terrain ───────────────────────────────────────────────────────────────

static func _terrain_rows() -> Array:
	var zs: Array = [-26.0, -21.0, -17.0, -14.5, -12.5]
	var z := -11.0
	while z < 9.0:
		zs.append(z)
		z += 1.25
	z = 9.0
	while z <= 44.0:
		zs.append(z)
		z += 2.5
	return zs


static func _build_terrain(root: Node3D) -> void:
	var xs: Array = []
	var x := -60.0
	while x <= 60.0:
		xs.append(x)
		x += 3.0
	var zs := _terrain_rows()
	var grass_from := 16.5   # MUST be one of _terrain_rows(): both meshes share that row
	for part in ["Sand", "Grass"]:
		var b := Builder.new()
		var rows: Array = []
		for zz: float in zs:
			if part == "Sand" and zz > grass_from + 0.01:
				continue
			if part == "Grass" and zz < grass_from - 0.01:
				continue
			var row: Array = []
			for xx: float in xs:
				var y := height(xx, zz)
				var d := zz - shore_z(xx)
				var tint := Color.WHITE
				# wet sand band above the waterline, darker toward the water
				var wet := _smooth(4.5, -0.5, d)
				tint = tint.lerp(Color(0.68, 0.64, 0.6), wet * 0.85)
				# underwater: the sand goes teal and dim with depth
				if y < 0.0:
					tint = tint.lerp(Color(0.42, 0.62, 0.66), clampf(-y * 1.2, 0, 1))
				if part == "Grass":
					tint = Color(1, 1, 1).lerp(Color(0.85, 0.82, 0.7), clampf((grass_from + 4.0 - zz) / 4.0, 0, 1))
				var uvs := Vector2(xx / 4.0, zz / 4.0) if part == "Sand" else Vector2(xx / 3.0, zz / 3.0)
				row.append(b.vert(Vector3(xx, y, zz), ground_normal(xx, zz), uvs, tint))
			rows.append(row)
		for i in range(rows.size() - 1):
			for j in range(xs.size() - 1):
				b.quad(rows[i][j], rows[i][j + 1], rows[i + 1][j + 1], rows[i + 1][j])
		var tex := "sand.png" if part == "Sand" else "grass.png"
		_node(root, "Beach" + part, b, _mat("Beach" + part, tex), "multiply")


# ── rocks ─────────────────────────────────────────────────────────────────

## A chunky low-poly boulder: a noise-displaced icosahedron (one subdivision,
## 80 faces), faceted on purpose — per-face UVs projected on the face's
## dominant axis, vertices tinted toward the water colour below the surface.
static func _rock(b: Builder, center: Vector3, size: Vector3, seed_v: int, yaw: float) -> void:
	var t := (1.0 + sqrt(5.0)) / 2.0
	var v: Array[Vector3] = [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]
	var f: Array = [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4],
		[11, 10, 2], [10, 7, 6], [7, 1, 8], [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
		[4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]]
	var mid := {}
	var faces: Array = []
	for tri: Array in f:
		var m: Array = []
		for k in range(3):
			var a: int = tri[k]
			var c: int = tri[(k + 1) % 3]
			var key := Vector2i(mini(a, c), maxi(a, c))
			if not mid.has(key):
				v.append((v[a] + v[c]) * 0.5)
				mid[key] = v.size() - 1
			m.append(mid[key])
		faces.append([tri[0], m[0], m[2]])
		faces.append([tri[1], m[1], m[0]])
		faces.append([tri[2], m[2], m[1]])
		faces.append([m[0], m[1], m[2]])
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var pts: Array[Vector3] = []
	var basis := Basis(Vector3.UP, yaw)
	for p in v:
		var n := p.normalized()
		var bump := 1.0 + rng.randf_range(-0.16, 0.18)
		var q := n * bump
		q.y = q.y if q.y > -0.3 else -0.3 + (q.y + 0.3) * 0.3   # flat-ish bottoms
		pts.append(center + basis * (q * size))
	for tri: Array in faces:
		var a: Vector3 = pts[tri[0]]
		var bb: Vector3 = pts[tri[1]]
		var c: Vector3 = pts[tri[2]]
		var n := (bb - a).cross(c - a).normalized()
		if n.dot((a + bb + c) / 3.0 - center) < 0.0:
			n = -n
		var ids: Array = []
		for p: Vector3 in [a, bb, c]:
			var uv := Vector2(p.x, p.y) if absf(n.z) > maxf(absf(n.x), absf(n.y)) \
				else (Vector2(p.z, p.y) if absf(n.x) > absf(n.y) else Vector2(p.x, p.z))
			var tint := Color(0.95, 0.93, 0.9)
			if p.y < 0.15:
				tint = tint.lerp(Color(0.32, 0.5, 0.52), clampf((0.15 - p.y) * 1.3, 0.0, 1.0))
			elif p.y < 0.6:
				tint = tint.lerp(Color(0.55, 0.5, 0.45), (0.6 - p.y) / 0.45 * 0.6)  # wet band
			ids.append(b.vert(p, n, uv / 2.5, tint))
		b.tri(ids[0], ids[1], ids[2])


const ROCKS := [
	# center, size, yaw — the right-hand headland (on the sand and in the surf)
	[Vector3(30, 0.6, 2), Vector3(4.5, 3.2, 3.8), 0.3],
	[Vector3(36, 1.5, 7), Vector3(6.5, 5.5, 6.0), 1.1],
	[Vector3(44, 2.5, 12), Vector3(8.0, 8.0, 7.5), 0.6],
	[Vector3(41, 0.2, -4), Vector3(5.0, 3.6, 4.2), 2.0],
	[Vector3(27.5, -0.4, -7.5), Vector3(2.6, 1.9, 2.3), 0.9],
	[Vector3(33, -0.6, -12), Vector3(3.4, 2.6, 3.0), 1.7],
	[Vector3(50, 1.0, 0), Vector3(7.0, 6.0, 6.0), 0.2],
	# the left headland, past the pier
	[Vector3(-44, 0.8, 4), Vector3(6.0, 4.5, 5.5), 0.4],
	[Vector3(-52, 1.8, 10), Vector3(8.5, 7.0, 7.0), 2.4],
	[Vector3(-47, -0.3, -6), Vector3(4.0, 2.6, 3.5), 1.4],
	[Vector3(-58, 0.5, -2), Vector3(7.0, 5.0, 6.0), 0.8],
]

## Rocks that stand in the surf: splash bursts and foam rings.
const SURF_ROCKS := [4, 5, 9]


static func _build_rocks(root: Node3D) -> void:
	# two meshes, so the frustum cull can drop a whole headland
	for side in ["East", "West"]:
		var b := Builder.new()
		for i in range(ROCKS.size()):
			var r: Array = ROCKS[i]
			if (side == "East") != ((r[0] as Vector3).x > 0.0):
				continue
			_rock(b, r[0], r[1], 100 + i, r[2])
		_node(root, "Rocks" + side, b, _mat("Rock", "rock.png"), "multiply")


# ── pier and boat ─────────────────────────────────────────────────────────

const PIER_X := -24.0

static func _build_pier(root: Node3D) -> void:
	var planks := _mat("Planks", "planks.png")
	var deck := PBMesh.new()
	deck.name = "PierDeck"
	deck.pb_mesh_data = PBShapeGenerators.create_box(Vector3(2.6, 0.22, 24.0))
	deck.position = Vector3(PIER_X, 1.35, -3.0)
	deck.pb_mesh_data.materials = [planks]
	deck.collider_type = PBMesh.ColliderType.OFF
	root.add_child(deck)
	var zp := 8.0
	var k := 0
	while zp >= -14.5:
		for sx: float in [-1.1, 1.1]:
			var post := PBMesh.new()
			post.name = "PierPost_%d" % k
			k += 1
			var gy := height(PIER_X + sx, zp)
			var top := 1.3
			var h := top - (gy - 0.4)
			post.pb_mesh_data = PBShapeGenerators.create_box(Vector3(0.26, h, 0.26))
			post.position = Vector3(PIER_X + sx, top - h * 0.5, zp)
			post.pb_mesh_data.materials = [planks]
			post.collider_type = PBMesh.ColliderType.OFF
			root.add_child(post)
		zp -= 4.5

	# the rowboat moored off the pier's end: a hull of planks bobbing and
	# rolling on three harmonic targets — a rigid body moving on GE morphs
	var b := Builder.new()
	var c := Vector3(PIER_X + 3.2, 0.05, -12.5)
	var L := 1.7
	var W := 0.7
	var D := 0.5
	var stations := [-1.0, -0.6, 0.0, 0.6, 1.0]
	var prev: Array = []
	for s: float in stations:
		var half_w := W * sqrt(maxf(0.0, 1.0 - s * s * 0.92))
		var z := c.z + s * L
		var keel := c.y - D * (1.0 - s * s * 0.5)
		var gun := c.y + 0.25 + 0.12 * s * s
		var ring := [
			b.vert(Vector3(c.x - half_w, gun, z), Vector3(-1, 0.2, 0), Vector2(0, s)),
			b.vert(Vector3(c.x, keel, z), Vector3(0, -1, 0), Vector2(0.5, s)),
			b.vert(Vector3(c.x + half_w, gun, z), Vector3(1, 0.2, 0), Vector2(1, s)),
			# inside faces (seen from above): separate verts, normals up
			b.vert(Vector3(c.x - half_w * 0.9, gun - 0.02, z), Vector3(0.3, 1, 0), Vector2(0, s)),
			b.vert(Vector3(c.x, keel + 0.1, z), Vector3(0, 1, 0), Vector2(0.5, s)),
			b.vert(Vector3(c.x + half_w * 0.9, gun - 0.02, z), Vector3(-0.3, 1, 0), Vector2(1, s)),
		]
		if not prev.is_empty():
			b.quad(prev[0], ring[0], ring[1], prev[1])
			b.quad(prev[1], ring[1], ring[2], prev[2])
			b.quad(prev[3], ring[3], ring[4], prev[4])
			b.quad(prev[4], ring[4], ring[5], prev[5])
		prev = ring
	_node(root, "Rowboat", b, _mat("Boat", "planks.png"), "", {
		"morph": {"mode": "harmonic", "targets": [
			{"offset": Vector3(0, 0.1, 0), "period": 3.3, "phase": 0.0},
			# roll and pitch share a period (the GE fits two periods per mesh)
			# and differ in phase, so the hull still wobbles off-axis
			{"rotate": {"axis": Vector3(0, 0, 1), "angle": 0.09, "pivot": c}, "period": 4.6, "phase": 1.0},
			{"rotate": {"axis": Vector3(1, 0, 0), "angle": 0.05, "pivot": c}, "period": 4.6, "phase": 2.6},
		]},
	})


# ── palms ─────────────────────────────────────────────────────────────────

const PALMS := [
	# base, height, lean (horizontal, metres at the top), sway amplitude
	[Vector3(-9, 0, 13), 8.5, Vector2(1.6, -2.2), 0.22],
	[Vector3(-4, 0, 16.5), 9.6, Vector2(-0.8, -1.6), 0.26],
	[Vector3(5, 0, 12), 7.4, Vector2(-1.2, -2.6), 0.2],
	[Vector3(11, 0, 17), 10.2, Vector2(0.9, -1.4), 0.28],
	[Vector3(19, 0, 11.5), 8.0, Vector2(-2.2, -1.8), 0.22],
	[Vector3(-17, 0, 9.5), 7.8, Vector2(1.0, -2.6), 0.2],
	[Vector3(-31, 0, 15), 9.0, Vector2(1.8, -1.0), 0.24],
	[Vector3(26, 0, 16), 9.2, Vector2(-1.4, -1.2), 0.24],
]


static func _build_palms(root: Node3D) -> void:
	var bark := _mat("PalmBark", "bark.png")
	var frond := _mat("PalmFrond", "frond.png", BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR)
	var shadow := _mat("BlobShadow", "blob_shadow.png", BaseMaterial3D.TRANSPARENCY_ALPHA, true)
	var sd := sun_dir()
	for i in range(PALMS.size()):
		var spec: Array = PALMS[i]
		var base: Vector3 = spec[0]
		base.y = height(base.x, base.z) - 0.2
		var H: float = spec[1]
		var lean: Vector2 = spec[2]
		var amp: float = spec[3]
		var curve := func(t: float) -> Vector3:
			return base + Vector3(lean.x * t * t, H * t, lean.y * t * t)
		var top: Vector3 = curve.call(1.0)
		# one sway for the whole tree: the trunk bends from its foot, the crown
		# and the shadow follow its top with the SAME weights (same periods and
		# phases), so they stay attached without sharing a mesh
		var per1 := 3.6 + 0.37 * i
		var per2 := per1 * 1.618
		var ph1 := 0.9 * i
		var ph2 := 1.7 * i + 0.5
		var ax := Vector3(amp, 0, amp * 0.3)
		var az := Vector3(-amp * 0.3, 0, amp * 0.8)

		var tb := Builder.new()
		var sides := 7
		var segs := 8
		for s in range(segs + 1):
			var t := float(s) / segs
			var cpos: Vector3 = curve.call(t)
			var rad := lerpf(0.24, 0.15, t) * (1.18 if s == 0 else 1.0)
			for k in range(sides + 1):
				var a := TAU * k / sides
				var n := Vector3(cos(a), 0, sin(a))
				tb.vert(cpos + n * rad, n, Vector2(float(k) / sides, t * H / 1.4))
		for s in range(segs):
			for k in range(sides):
				var r0 := s * (sides + 1) + k
				var r1 := (s + 1) * (sides + 1) + k
				tb.quad(r0, r0 + 1, r1 + 1, r1)
		_node(root, "PalmTrunk_%d" % i, tb, bark, "", {"morph": {"mode": "harmonic", "targets": [
			{"bend": {"dir": ax, "base": base.y, "height": H}, "period": per1, "phase": ph1},
			{"bend": {"dir": az, "base": base.y, "height": H}, "period": per2, "phase": ph2},
		]}})

		# the crown: drooping fronds, each a 4-segment strip (the texture's
		# stem along U)
		var cb := Builder.new()
		var nf := 9
		var flen_max := 0.0
		for fi in range(nf):
			var ang := TAU * fi / nf + i * 0.7 + (0.25 if fi % 2 else 0.0)
			var dir := Vector3(cos(ang), 0, sin(ang))
			var side := Vector3(-dir.z, 0, dir.x)
			var flen := 3.4 + 0.9 * sin(fi * 2.3 + i)
			flen_max = maxf(flen_max, flen)
			var lift := 0.7 + 0.4 * cos(fi * 1.7)
			var prev_l := -1
			var prev_r := -1
			for si in range(5):
				var s := float(si) / 4.0
				var p := top + dir * (s * flen) + Vector3(0, lift * s - 2.0 * s * s, 0)
				var w := 0.55 * sin(PI * clampf(s * 0.9 + 0.1, 0, 1)) + 0.12
				var n := Vector3(0, 1, 0).lerp(-dir, 0.25).normalized()
				var l := cb.vert(p - side * w, n, Vector2(s, 0.0))
				var r := cb.vert(p + side * w, n, Vector2(s, 1.0))
				if prev_l >= 0:
					cb.quad(prev_l, prev_r, r, l)
				prev_l = l
				prev_r = r
		_node(root, "PalmCrown_%d" % i, cb, frond, "", {"morph": {"mode": "harmonic", "targets": [
			{"offset": ax, "bend": {"dir": Vector3(0, 0.22, 0), "pivot": top, "radius": flen_max},
				"period": per1, "phase": ph1},
			{"offset": az, "bend": {"dir": Vector3(0, -0.16, 0), "pivot": top, "radius": flen_max},
				"period": per2, "phase": ph2},
		]}})

		# blob shadow: the crown projected along the sun onto the sand, plus
		# a soft trunk streak; the far end sways with the crown
		var gnd := top - sd * (top.y - base.y) / sd.y
		var sb := Builder.new()
		_ground_quad(sb, gnd, 2.6, 2.0, Color(1, 1, 1, 0.5))
		_ground_strip(sb, base, gnd, 0.35, Color(1, 1, 1, 0.38))
		_node(root, "PalmShadow_%d" % i, sb, shadow, "unlit", {"decal": 16, "morph": {"mode": "harmonic", "targets": [
			{"bend": {"dir": Vector3(ax.x, 0, ax.z), "pivot": base, "radius": (gnd - base).length()},
				"period": per1, "phase": ph1},
			{"bend": {"dir": Vector3(az.x, 0, az.z), "pivot": base, "radius": (gnd - base).length()},
				"period": per2, "phase": ph2},
		]}})


## A soft blob draped over the ground (3x3 grid following the height field).
static func _ground_quad(b: Builder, c: Vector3, hx: float, hz: float, col: Color) -> void:
	var ids: Array = []
	for iz in range(3):
		for ix in range(3):
			var px := c.x + (ix - 1) * hx
			var pz := c.z + (iz - 1) * hz
			ids.append(b.vert(Vector3(px, height(px, pz) + 0.06, pz), Vector3.UP,
				Vector2(ix * 0.5, iz * 0.5), col))
	for iz in range(2):
		for ix in range(2):
			var a: int = ids[iz * 3 + ix]
			b.quad(a, ids[iz * 3 + ix + 1], ids[(iz + 1) * 3 + ix + 1], ids[(iz + 1) * 3 + ix])


static func _ground_strip(b: Builder, a: Vector3, z_end: Vector3, w: float, col: Color) -> void:
	var dir := Vector3(z_end.x - a.x, 0, z_end.z - a.z)
	var side := Vector3(-dir.z, 0, dir.x).normalized() * w
	var prev: Array = []
	for k in range(4):
		var t := float(k) / 3.0
		var p := a.lerp(z_end, t * 0.8)
		var l := p - side
		var r := p + side
		var cur := [
			b.vert(Vector3(l.x, height(l.x, l.z) + 0.05, l.z), Vector3.UP, Vector2(0.5, 0.05), col),
			b.vert(Vector3(r.x, height(r.x, r.z) + 0.05, r.z), Vector3.UP, Vector2(0.5, 0.95), col),
		]
		# the blob texture's centre column is the darkest: sample it
		if not prev.is_empty():
			b.quad(prev[0], prev[1], cur[1], cur[0])
		prev = cur


# ── backdrop: shrubs, far palms, jungle wall, island ──────────────────────

static func _crossed(b: Builder, foot: Vector3, w: float, h: float, yaw: float, col: Color = Color.WHITE) -> void:
	for k in range(2):
		var a := yaw + k * PI * 0.5
		var r := Vector3(cos(a), 0, sin(a)) * (w * 0.5)
		var n := Vector3(-sin(a), 0.6, cos(a)).normalized()
		var v0 := b.vert(foot - r, n, Vector2(0, 1), col)
		var v1 := b.vert(foot + r, n, Vector2(1, 1), col)
		var v2 := b.vert(foot + r + Vector3(0, h, 0), n, Vector2(1, 0), col)
		var v3 := b.vert(foot - r + Vector3(0, h, 0), n, Vector2(0, 0), col)
		b.quad(v0, v1, v2, v3)


static func _build_backdrop(root: Node3D) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	# jungle wall: cutout cards on a curve behind the dunes, two layers
	var jb := Builder.new()
	for layer in range(2):
		var zc := 40.0 + layer * 9.0
		var hgt := 16.0 + layer * 4.0
		var n := 8
		for i in range(n):
			var x0 := -84.0 + i * 168.0 / n
			var x1 := x0 + 168.0 / n + 2.0
			var z0 := zc - 0.004 * x0 * x0
			var z1 := zc - 0.004 * x1 * x1
			var y0 := height(x0, z0) - 1.0
			var y1 := height(x1, z1) - 1.0
			var u0 := float(i) * 0.5 + layer * 0.37
			var col := Color(1, 1, 1) if layer == 0 else Color(0.8, 0.86, 0.9)
			var nrm := Vector3(0, 0.3, -1).normalized()
			var a := jb.vert(Vector3(x0, y0, z0), nrm, Vector2(u0, 1), col)
			var bb := jb.vert(Vector3(x1, y1, z1), nrm, Vector2(u0 + 0.5, 1), col)
			var c := jb.vert(Vector3(x1, y1 + hgt, z1), nrm, Vector2(u0 + 0.5, 0), col)
			var d := jb.vert(Vector3(x0, y0 + hgt, z0), nrm, Vector2(u0, 0), col)
			jb.quad(a, bb, c, d)
	_node(root, "JungleWall", jb, _mat("Jungle", "jungle.png", BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR), "unlit")

	# far palm line (crossed cards) with a gentle sway
	var fb := Builder.new()
	for i in range(22):
		var x := -58.0 + i * 5.3 + rng.randf_range(-1.5, 1.5)
		var z := rng.randf_range(25.0, 33.0)
		var h := rng.randf_range(8.0, 12.0)
		_crossed(fb, Vector3(x, height(x, z) - 0.2, z), h * 0.5, h, rng.randf() * PI)
	_node(root, "FarPalms", fb, _mat("FarPalm", "palm_far.png", BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR), "",
		{"morph": {"mode": "harmonic", "targets": [
			{"bend": {"dir": Vector3(0.35, 0, 0.1), "base": 1.0, "height": 12.0}, "period": 4.3, "phase": 0.0},
		]}})

	# shrubs along the sand/grass seam and around the palms
	var sb := Builder.new()
	for i in range(26):
		var x := rng.randf_range(-40, 34)
		var z := rng.randf_range(15.5, 22.0)
		var s := rng.randf_range(1.2, 2.4)
		_crossed(sb, Vector3(x, height(x, z) - 0.1, z), s * 1.3, s, rng.randf() * PI)
	_node(root, "Shrubs", sb, _mat("Shrub", "shrub.png", BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR))


# ── shallows ──────────────────────────────────────────────────────────────

static func _build_shallows(root: Node3D) -> void:
	var b := Builder.new()
	var xs: Array = []
	var x := -100.0
	while x <= 100.0:
		xs.append(x)
		x += 4.0
	var ds := [0.8, 0.0, -0.8, -1.8, -3.0, -4.5, -6.5, -9.0, -12.0]
	var rows: Array = []
	for d: float in ds:
		var row: Array = []
		for xx: float in xs:
			var z := shore_z(xx) + d
			var depth := -height(xx, z)
			var a := clampf(0.12 + depth * 0.9, 0.0, 1.0)
			var tint := Color(1.0, 1.0, 1.0).lerp(Color(0.76, 0.8, 0.86), clampf(depth, 0, 1))
			row.append(b.vert(Vector3(xx, SEA_Y + 0.03, z), Vector3.UP, Vector2(xx / 7.0, z / 7.0),
				Color(tint.r, tint.g, tint.b, a)))
		rows.append(row)
	# last row: straight, under the near sea's first row
	var last: Array = []
	for xx: float in xs:
		last.append(b.vert(Vector3(xx, SEA_Y + 0.03, -16.0), Vector3.UP, Vector2(xx / 7.0, -16.0 / 7.0),
			Color(0.76, 0.8, 0.86, 1.0)))
	rows.append(last)
	for i in range(rows.size() - 1):
		for j in range(xs.size() - 1):
			b.quad(rows[i][j], rows[i][j + 1], rows[i + 1][j + 1], rows[i + 1][j])
	var m := _mat("Shallows", "shallow_f0.png", BaseMaterial3D.TRANSPARENCY_ALPHA, true)
	PBUv.set_scroll_speed(m, Vector2(0.0, 0.025))
	_node(root, "Shallows", b, m, "unlit", {"decal": 16,
		"morph": {"mode": "harmonic", "targets": swell_targets()},
		"flipbook": {"frames": _frames("shallow_f", 8), "fps": 7.0},
	})


# ── surf ──────────────────────────────────────────────────────────────────

## When (in the surf loop, 0..1) a strip's foam line reaches the waterline —
## the break. The spray bursts are timed to it.
const SURF_BREAK_T := 0.2


static func surf_phase(strip: int) -> float:
	return SURF_PERIOD * float(strip) / 3.0


static func _build_surf(root: Node3D) -> void:
	var foam := _mat("SurfFoam", "surf_foam.png", BaseMaterial3D.TRANSPARENCY_ALPHA, true)
	var lead := [-4.0, -4.6, -3.7]
	for s in range(3):
		var b := Builder.new()
		var xs: Array = []
		var x := -50.0
		while x <= 50.0:
			xs.append(x)
			x += 2.5
		# rows: the bright leading line, the lacy body, the fading tail
		var rows_d := [0.0, -0.9, -3.0]
		var rows_a := [1.0, 0.85, 0.0]
		var rows: Array = []
		for ri in range(3):
			var row: Array = []
			for xx: float in xs:
				var d: float = lead[s] + rows_d[ri]
				var z := shore_z(xx) + d
				# ON the 1:12 plane even below the water: the morph slides the
				# strip along it and y_min keeps the seaward part afloat
				var y := d / 12.0 + 0.07
				row.append(b.vert(Vector3(xx, y, z), Vector3.UP,
					Vector2(xx / 7.0 + s * 0.31, float(ri) / 2.0),
					Color(1, 1, 1, rows_a[ri])))
			rows.append(row)
		for i in range(2):
			for j in range(xs.size() - 1):
				b.quad(rows[i][j], rows[i][j + 1], rows[i + 1][j + 1], rows[i + 1][j])
		var slope := Vector3(0, 1.0 / 12.0, 1.0)
		var vary := {"amp": 0.22, "freq": 0.11 + 0.03 * s, "phase": 1.7 * s}
		_node(root, "Surf_%d" % s, b, foam, "unlit", {"decal": 16, "morph": {
			"mode": "keyframe", "period": SURF_PERIOD, "phase": surf_phase(s), "ease": true,
			"base": {"alpha": 0.0, "y_min": 0.07},
			"targets": [
				{"t": SURF_BREAK_T + 0.04, "offset": slope * 4.0, "y_min": 0.07, "alpha": 1.0,
					"uv": Vector2(0.05, 0)},
				{"t": 0.56, "offset": slope * 8.6, "offset_vary": vary, "y_min": 0.07, "alpha": 0.8,
					"uv": Vector2(0.12, 0)},
				{"t": 0.84, "offset": slope * 7.0, "offset_vary": vary, "y_min": 0.07, "alpha": 0.0,
					"uv": Vector2(0.16, 0)},
			]}})

	# foam rings around the rocks standing in the surf: swell up when a wave
	# hits, drain back
	for ri in SURF_ROCKS:
		var r: Array = ROCKS[ri]
		var c: Vector3 = r[0]
		var size: Vector3 = r[1]
		var rad := maxf(size.x, size.z) * 0.95
		var b := Builder.new()
		var segs := 16
		var inner: Array = []
		var outer: Array = []
		for k in range(segs + 1):
			var a := TAU * k / segs
			var dir := Vector3(cos(a), 0, sin(a))
			inner.append(b.vert(Vector3(c.x, 0.06, c.z) + dir * rad * 0.8, Vector3.UP,
				Vector2(float(k) / segs * 4.0, 0.0), Color(1, 1, 1, 1)))
			outer.append(b.vert(Vector3(c.x, 0.06, c.z) + dir * rad * 1.5, Vector3.UP,
				Vector2(float(k) / segs * 4.0, 1.0), Color(1, 1, 1, 0)))
		for k in range(segs):
			b.quad(inner[k], inner[k + 1], outer[k + 1], outer[k])
		var hit := _rock_hit_time(c)
		var pc := Vector3(c.x, 0.06, c.z)
		_node(root, "RockFoam_%d" % ri, b, foam, "unlit", {"morph": {
			"mode": "keyframe", "period": SURF_PERIOD, "phase": -hit, "ease": true,
			"base": {"alpha": 0.35},
			"targets": [
				{"t": 0.1, "scale": Vector3(1.3, 1, 1.3), "pivot": pc, "alpha": 1.0},
				{"t": 0.5, "scale": Vector3(1.55, 1, 1.55), "pivot": pc, "alpha": 0.45},
			]}})


## When a wave reaches a rock in the surf (seconds into the surf loop): the
## surf strip nearest in phase, a little before it breaks on the beach.
static func _rock_hit_time(c: Vector3) -> float:
	var s := int(absf(c.x * 7.0 + c.z)) % 3
	return fposmod(SURF_BREAK_T * SURF_PERIOD * 0.6 - surf_phase(s), SURF_PERIOD)


# ── the sun path ──────────────────────────────────────────────────────────

static func _sun_path_alpha(p: Vector3, origin: Vector3, along: Vector3, side: Vector3) -> float:
	var sv := (p - origin).dot(along)
	if sv < 0.0:
		return 0.0
	var w := 3.0 + sv * 0.16
	var lat := absf((p - origin).dot(side)) / w
	if lat >= 1.0:
		return 0.0
	var fade := _smooth(0.0, 22.0, sv) * (1.0 - 0.6 * _smooth(120.0, 330.0, sv))
	return fade * (1.0 - lat) * (1.0 - lat)


static func _build_sun_path(root: Node3D) -> void:
	var sd := sun_visual_dir()
	var along := Vector3(sd.x, 0, sd.z).normalized()
	var side := Vector3(-along.z, 0, along.x)
	var origin := Vector3(0, 0, shore_z(0) - 8.0)
	var lift := 0.08
	var col := Color(1, 0.95, 0.8)

	# Over the near sea: the sea's own grid cells under the band, same
	# vertices, same triangulation, lifted 8 cm — and the sea's morph targets,
	# so it rides the swell exactly as drawn.
	var b := Builder.new()
	var xs := sea_grid_xs()
	var zs := sea_grid_zs()
	var ids := {}
	for i in range(zs.size() - 1):
		for j in range(xs.size() - 1):
			var corners := [Vector2i(j, i), Vector2i(j + 1, i), Vector2i(j + 1, i + 1), Vector2i(j, i + 1)]
			var any := false
			for c: Vector2i in corners:
				if _sun_path_alpha(Vector3(xs[c.x], 0, zs[c.y]), origin, along, side) > 0.01:
					any = true
			if not any:
				continue
			var q: Array = []
			for c: Vector2i in corners:
				if not ids.has(c):
					var p := Vector3(xs[c.x], SEA_Y + lift + 0.1, zs[c.y])
					var a := _sun_path_alpha(p, origin, along, side)
					var uvp := Vector2((p - origin).dot(side) / 5.0, (p - origin).dot(along) / 5.0)
					ids[c] = b.vert(p, Vector3.UP, uvp, Color(col.r, col.g, col.b, a))
				q.append(ids[c])
			b.quad(q[0], q[1], q[2], q[3])
	var m := _mat("SunPath", "glint_f0.png", BaseMaterial3D.TRANSPARENCY_ALPHA, true)
	var glints := _frames("glint_f", 4)
	# FLAT, lifted over the swell by the decal bias instead of riding it. A
	# morphing copy of the sea's grid (exact data: path = sea + 8 cm under the
	# runtime's weights) never reaches the screen under PPSSPP while every
	# other morphing mesh does — open item, to settle on hardware. 96 depth
	# units put it ~2 m in front at 20 m, which clears the crests there.
	_node(root, "SunPath", b, m, "unlit", {
		"additive": true, "no_fog": true, "decal": 96,
		"flipbook": {"frames": glints, "fps": 5.0},
	})

	# Over the far (flat) sea: a plain band from the near sea's edge out.
	var fb := Builder.new()
	var s0 := (Vector3(0, 0, SEA_NEAR_END) - origin).dot(along) / maxf(-along.z, 0.01)
	var stations := [s0, s0 + 30.0, s0 + 80.0, 230.0, 330.0]
	var rows: Array = []
	for st: float in stations:
		var w := 3.0 + st * 0.16
		var row: Array = []
		for k in range(5):
			var lat := (float(k) / 4.0 - 0.5) * 2.0
			var p := origin + along * st + side * (lat * w)
			# clip the first row to the near sea's far edge (no overlap)
			if p.z > SEA_NEAR_END:
				p += along * ((p.z - SEA_NEAR_END) / -along.z)
			p.y = SEA_Y + lift
			var a := _sun_path_alpha(p, origin, along, side)
			row.append(fb.vert(p, Vector3.UP, Vector2((p - origin).dot(side) / 5.0, (p - origin).dot(along) / 5.0),
				Color(col.r, col.g, col.b, a)))
		rows.append(row)
	for i in range(rows.size() - 1):
		for k in range(4):
			fb.quad(rows[i][k], rows[i][k + 1], rows[i + 1][k + 1], rows[i + 1][k])
	_node(root, "SunPathFar", fb, m, "unlit", {
		"additive": true, "no_fog": true, "decal": 96,
		"flipbook": {"frames": glints, "fps": 5.0},
	})


# ── particles ─────────────────────────────────────────────────────────────

static func _emitter(root: Node3D, name_str: String, pos: Vector3, tex: String, amount: int,
		life: float, size: float, additive: bool, cols: int = 1, rows: int = 1) -> GPUParticles3D:
	var p := TestMapShowcaseBuilder.create_emitter(name_str, pos, TEX + tex, amount, life, size,
		additive, false, cols, rows)
	root.add_child(p)
	return p


static func _ramp(pm: ParticleProcessMaterial, c0: Color, c1: Color, c2: Color, knee: float) -> void:
	var g := Gradient.new()
	g.set_color(0, c0)
	g.set_color(1, c2)
	g.add_point(knee, c1)
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_ramp = gt


static func _scale_curve(pm: ParticleProcessMaterial, s0: float, s1: float, s2: float, knee: float) -> void:
	var c := Curve.new()
	c.max_value = maxf(maxf(s0, s1), s2)
	c.add_point(Vector2(0, s0))
	c.add_point(Vector2(knee, s1))
	c.add_point(Vector2(1, s2))
	var ct := CurveTexture.new()
	ct.curve = c
	pm.scale_curve = ct


static func _build_emitters(root: Node3D) -> void:
	# spray along each surf strip's break line, a burst per wave
	for s in range(3):
		for half: int in [-1, 1]:
			var bx := 24.0 * half
			var e := _emitter(root, "Spray_%d_%s" % [s, "W" if half < 0 else "E"],
				Vector3(bx, 0.15, shore_z(bx) - 0.6), "spray_2x2_sheet.png", 18, SURF_PERIOD, 1.0, false, 2, 2)
			e.one_shot = true
			# the burst fires at the strip's break: t_break = BREAK*P - phase
			var t_break := fposmod(SURF_BREAK_T * SURF_PERIOD - surf_phase(s), SURF_PERIOD)
			e.set_meta("poi_burst_phase", fposmod(-t_break / SURF_PERIOD, 1.0))
			var pm := e.process_material as ParticleProcessMaterial
			pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
			pm.emission_box_extents = Vector3(21.0, 0.1, 1.6)
			pm.direction = Vector3(0, 1, 0.35)
			pm.spread = 28.0
			pm.initial_velocity_min = 1.2
			pm.initial_velocity_max = 2.8
			pm.gravity = Vector3(0, -4.0, 0)
			pm.damping_min = 0.7
			pm.damping_max = 0.9
			_ramp(pm, Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.85), Color(1, 1, 1, 0.0), 0.06)
			_scale_curve(pm, 0.6, 1.6, 2.6, 0.06)
			# the burst's life is the surf period, but it is only visible for
			# ~2 s: 4 flipbook cycles play clump -> tatters while it is
			pm.anim_speed_min = 4.0
			pm.anim_speed_max = 4.0

	# rock splashes, timed to the wave reaching each rock
	for ri in SURF_ROCKS:
		var r: Array = ROCKS[ri]
		var c: Vector3 = r[0]
		var e := _emitter(root, "RockSplash_%d" % ri, Vector3(c.x, 0.4, c.z + 1.0), "spray_2x2_sheet.png",
			16, SURF_PERIOD, 1.3, false, 2, 2)
		e.one_shot = true
		var t_hit := _rock_hit_time(c) + 0.25
		e.set_meta("poi_burst_phase", fposmod(-t_hit / SURF_PERIOD, 1.0))
		var pm := e.process_material as ParticleProcessMaterial
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		pm.emission_box_extents = Vector3((r[1] as Vector3).x * 0.5, 0.2, 0.6)
		pm.direction = Vector3(0, 1, 0.25)
		pm.spread = 30.0
		pm.initial_velocity_min = 3.5
		pm.initial_velocity_max = 6.0
		pm.gravity = Vector3(0, -9.0, 0)
		pm.damping_min = 0.5
		pm.damping_max = 0.6
		_ramp(pm, Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.95), Color(1, 1, 1, 0.0), 0.05)
		_scale_curve(pm, 0.5, 1.5, 2.4, 0.05)
		pm.anim_speed_min = 5.0
		pm.anim_speed_max = 5.0

	# sun glitter: tiny additive flashes in flat boxes along the sun path
	var sd := sun_dir()
	var along := Vector3(sd.x, 0, sd.z).normalized()
	var origin := Vector3(0, 0, shore_z(0) - 8.0)
	var k := 0
	for dist: float in [16.0, 34.0, 60.0]:
		var c := origin + along * dist
		var e := _emitter(root, "Glints_%d" % k, Vector3(c.x, 0.2, c.z), "sun_glow.png", 16, 0.7, 0.35, true)
		k += 1
		var pm := e.process_material as ParticleProcessMaterial
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		pm.emission_box_extents = Vector3(3.0 + dist * 0.12, 0.05, 5.0 + dist * 0.12)
		pm.initial_velocity_min = 0.0
		pm.initial_velocity_max = 0.05
		pm.gravity = Vector3.ZERO
		pm.lifetime_randomness = 0.5
		_ramp(pm, Color(1, 0.97, 0.85, 0.0), Color(1, 0.97, 0.85, 1.0), Color(1, 0.97, 0.85, 0.0), 0.5)
		_scale_curve(pm, 0.3, 1.0 + dist * 0.02, 0.2, 0.5)

	# gulls: a lazy flock wheeling over the bay (2-frame flap flipbook)
	# Gulls fly straight lines from the box: keep the cone FLAT (15 degrees,
	# a hair upward) and the lives short enough that the steepest one still
	# clears the dunes — an 80-degree cone flew a few into the sand.
	var g := _emitter(root, "Gulls", Vector3(-5, 19, -28), "gull_2x1_sheet.png", 7, 13.0, 0.9, false, 2, 1)
	var gp := g.process_material as ParticleProcessMaterial
	gp.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	gp.emission_box_extents = Vector3(35, 3, 18)
	gp.direction = Vector3(1, 0.06, 0.15)
	gp.spread = 15.0
	gp.initial_velocity_min = 2.0
	gp.initial_velocity_max = 3.5
	gp.gravity = Vector3(0, 0.05, 0)
	gp.damping_min = 0.0
	gp.damping_max = 0.0
	gp.angle_min = 0.0
	gp.angle_max = 0.0
	gp.angular_velocity_min = 0.0
	gp.angular_velocity_max = 0.0
	_ramp(gp, Color(1, 1, 1, 0.0), Color(1, 1, 1, 1.0), Color(1, 1, 1, 0.0), 0.5)
	_scale_curve(gp, 1.0, 1.0, 1.0, 0.5)
	g.set_meta("poi_wobble_amp", 2.2)
	g.set_meta("poi_wobble_freq", 0.09)
	g.set_meta("poi_y_locked", true)
	gp.anim_speed_min = 18.0   # wing beats per lifetime (the format's anim_loops)
	gp.anim_speed_max = 18.0


# ── camera path / spawn ───────────────────────────────────────────────────

static func _pose(root: Node3D, name_str: String, pos: Vector3, look: Vector3, hold: float,
		travel: float) -> void:
	var m := Marker3D.new()
	m.name = name_str
	m.transform = Transform3D(Basis.looking_at(look.normalized(), Vector3.UP), pos)
	root.add_child(m)
	m.set_meta(PBRetroFx.META_CAMERA_POSE, {"hold": hold, "travel": travel})


static func _build_camera_path(root: Node3D) -> void:
	var sd := sun_dir()
	_pose(root, "Beach", Vector3(0, 1.7, 9.5), Vector3(0, -0.06, -1), 4.0, 6.0)
	_pose(root, "Surf", Vector3(7, 1.1, 2.0), Vector3(-1, -0.18, -0.55), 4.0, 6.0)
	_pose(root, "Rocks", Vector3(19, 2.2, -0.5), Vector3(1, -0.22, -0.75), 4.0, 6.0)
	_pose(root, "Overlook", Vector3(30, 10.5, 16), Vector3(-1, -0.42, -0.85), 4.0, 7.0)
	_pose(root, "Pier", Vector3(PIER_X - 1.0, 2.7, -5.0), Vector3(0.45, -0.28, -1), 4.0, 7.0)
	_pose(root, "Palms", Vector3(-6, 1.7, 3.0), Vector3(0.2, 0.32, 1), 4.0, 6.0)
	var sv := sun_visual_dir()
	_pose(root, "Glitter", Vector3(-1, 1.3, -0.5), Vector3(sv.x, 0.1, sv.z), 5.0, 6.0)

	var spawn := Marker3D.new()
	spawn.name = "PlayerSpawn"
	spawn.position = Vector3(0, 1.7, 9.5)
	root.add_child(spawn)


# ═══════════════════════════════════════════════════════════════ export

static func export_settings() -> PBMapExporter.ExportSettings:
	var s := PBMapExporter.ExportSettings.new()
	s.export_mode = PBMapExporter.ExportMode.RETRO
	s.subdivide_quads = true
	s.grid_size = 1.0
	s.bake_lighting = true
	s.bake_shadows = false   # blob shadows: vertex-resolution shadows can't draw a palm
	s.bake_ao = false
	s.bake_textures = true
	s.tile_resolution = 128
	s.max_texture_size = 256
	s.export_colliders = false
	s.export_billboards = true
	s.ambient_color = Color(0.5, 0.56, 0.64)
	return s


static func export_pbm(path: String = OUT_PBM) -> Error:
	var root := build_scene()
	_set_owner_recursive(root, root)
	var err := PBMapExporter.export_map(root, path, export_settings())
	root.free()
	return err


static func save_scene(path: String) -> Error:
	var root := build_scene()
	_set_owner_recursive(root, root)
	var packed := PackedScene.new()
	var err := packed.pack(root)
	if err == OK:
		err = ResourceSaver.save(packed, path)
	root.free()
	return err


static func _set_owner_recursive(node: Node, scene_owner: Node) -> void:
	for child in node.get_children():
		child.owner = scene_owner
		_set_owner_recursive(child, scene_owner)
