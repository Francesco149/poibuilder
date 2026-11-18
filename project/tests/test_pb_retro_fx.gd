## The retro runtime-animation records (PBRetroFx): the "mesh_fx" lump (GE
## vertex morphing, mesh flipbooks, additive / no-fog meshes), "camera_path",
## "env", and the emitter extensions (spawn box, burst phase).
##
## Builds its own fixture, exports a .pbm, parses the bytes back and checks
## them against the layouts in retro_engine/psp/pbm.h — plus the maths the
## morph targets are built from (a Gerstner quadrature pair must reproduce a
## travelling wave exactly, or the sea on the device drifts and pulses).
extends GutTest

const TEST_PBM := "user://test_retro_fx.pbm"


func after_all() -> void:
	var g := ProjectSettings.globalize_path(TEST_PBM)
	if FileAccess.file_exists(g):
		DirAccess.remove_absolute(g)


# ── the maths ─────────────────────────────────────────────────────────────

func test_gerstner_pair_is_a_travelling_wave() -> void:
	var amp := 0.3
	var wl := 12.0
	var dir := Vector2(0.6, 0.8)
	var period := 3.0
	var pair := PBRetroFx.gerstner_pair(amp, wl, dir, period, 0.5)
	assert_eq(pair.size(), 2)
	var k := TAU / wl
	var w := TAU / period
	for p: Vector3 in [Vector3(1.3, 0, -4.2), Vector3(-7.0, 0, 2.5), Vector3(0, 0, 0)]:
		var c_pos: Vector3 = PBRetroFx.apply_descriptor(pair[0], p, Vector2.ZERO, Color.WHITE)[0]
		var s_pos: Vector3 = PBRetroFx.apply_descriptor(pair[1], p, Vector2.ZERO, Color.WHITE)[0]
		for t: float in [0.0, 0.37, 1.1, 2.9]:
			# the harmonic description: weights sin(2 pi t / period + phase)
			var wc := sin(TAU * t / period + float(pair[0]["phase"]))
			var ws := sin(TAU * t / period + float(pair[1]["phase"]))
			var got := p + (c_pos - p) * wc + (s_pos - p) * ws
			var theta := k * Vector2(p.x, p.z).dot(dir.normalized()) - w * t
			assert_almost_eq(got.y, amp * cos(theta), 0.0005,
				"height at %s, t=%.2f follows a*cos(kx - wt)" % [p, t])
			var dh := -0.5 * amp * sin(theta)
			assert_almost_eq(got.x - p.x, dir.normalized().x * dh, 0.0005, "Gerstner x shift")


## The exporter writes harmonic morphs in the CONVEX cyclic form (triplets,
## non-negative weights summing to one). Blending its sets with the runtime's
## weights must give back exactly the harmonic motion, for two periods at once.
func test_cyclic_form_reproduces_harmonic_motion() -> void:
	var targets: Array = []
	targets.append_array(PBRetroFx.gerstner_pair(0.3, 12.0, Vector2(0.2, 1), 3.5, 0.6,
		{}, Color(0.2, 0.2, 0.2, 0)))
	targets.append_array(PBRetroFx.gerstner_pair(0.12, 8.0, Vector2(-0.5, 1), 2.3, 0.4))
	var fx := {"morph": {"mode": "harmonic", "targets": targets}}
	assert_eq(PBRetroFx.morph_target_count(fx), 7, "rest + two triplets")
	for p: Vector3 in [Vector3(3, 0.08, -20), Vector3(-11, 0.08, -41)]:
		var c0 := Color(0.8, 0.84, 0.88, 1.0)
		var sets := PBRetroFx.eval_targets(fx, p, Vector2(0.5, 0.5), c0)
		assert_eq(sets.size(), 7)
		for t: float in [0.0, 0.9, 2.2, 5.05]:
			# reference: the harmonic sum
			var ref_p := p
			var ref_c := c0
			for td: Dictionary in targets:
				var r := PBRetroFx.apply_descriptor(td, p, Vector2(0.5, 0.5), c0)
				var wt := sin(TAU * t / float(td["period"]) + float(td["phase"]))
				ref_p += ((r[0] as Vector3) - p) * wt
				ref_c = Color(ref_c.r + ((r[2] as Color).r - c0.r) * wt, ref_c.g, ref_c.b, ref_c.a)
			# runtime: target 0 weight 0, triplet weights (1 + cos(th - 2 pi k/3)) / 3J
			var got := Vector3.ZERO
			var got_r := 0.0
			var wsum := 0.0
			for j in range(2):
				var per := 3.5 if j == 0 else 2.3
				var th := TAU * t / per
				for kk in range(3):
					var wk := (1.0 + cos(th - TAU * kk / 3.0)) / 6.0
					assert_true(wk >= 0.0, "cyclic weights are never negative")
					wsum += wk
					got += (sets[1 + 3 * j + kk][0] as Vector3) * wk
					got_r += (sets[1 + 3 * j + kk][2] as Color).r * wk
			assert_almost_eq(wsum, 1.0, 0.0001, "the weights sum to one")
			assert_almost_eq(got.distance_to(ref_p), 0.0, 0.0005, "position at t=%.2f" % t)
			assert_almost_eq(got_r, ref_c.r, 0.0005, "crest tint rides the same algebra")


func test_descriptor_ops() -> void:
	var r: Array = PBRetroFx.apply_descriptor({"offset": Vector3(0, 1, 2), "y_min": 0.5,
		"alpha": 0.5, "uv": Vector2(0.25, 0)}, Vector3(1, -3, 0), Vector2(0.1, 0.2), Color(1, 1, 1, 0.8))
	assert_eq(r[0], Vector3(1, 0.5, 2), "offset then the y_min clamp")
	assert_almost_eq((r[2] as Color).a, 0.4, 0.0001, "alpha multiplies")
	assert_almost_eq((r[1] as Vector2).x, 0.35, 0.0001, "uv adds")
	var bent: Vector3 = PBRetroFx.apply_descriptor({"bend": {"dir": Vector3(1, 0, 0), "base": 0.0,
		"height": 4.0}}, Vector3(0, 2, 0), Vector2.ZERO, Color.WHITE)[0]
	assert_almost_eq(bent.x, 0.25, 0.0001, "bend weight is ((y - base) / height)^2")
	var rot: Vector3 = PBRetroFx.apply_descriptor({"rotate": {"axis": Vector3.UP, "angle": PI * 0.5,
		"pivot": Vector3(1, 0, 0)}}, Vector3(2, 0, 0), Vector2.ZERO, Color.WHITE)[0]
	assert_almost_eq(rot.distance_to(Vector3(1, 0, -1)), 0.0, 0.0001, "rotate about the pivot")


# ── the bytes ─────────────────────────────────────────────────────────────

func _quad_mesh(size: float, segs: int) -> ArrayMesh:
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var uv := PackedVector2Array()
	var idx := PackedInt32Array()
	for iz in range(segs + 1):
		for ix in range(segs + 1):
			pos.append(Vector3(-size * 0.5 + size * ix / segs, 0, -size * 0.5 + size * iz / segs))
			nrm.append(Vector3.UP)
			uv.append(Vector2(float(ix) / segs, float(iz) / segs))
	for iz in range(segs):
		for ix in range(segs):
			var a := iz * (segs + 1) + ix
			idx.append_array([a, a + 1, a + segs + 2, a, a + segs + 2, a + segs + 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nrm
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return am


func _tex(c: Color) -> ImageTexture:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return ImageTexture.create_from_image(img)


func _fixture() -> Node3D:
	var root := Node3D.new()
	root.name = "RetroFxFixture"
	root.set_meta(PBRetroFx.META_ENV, {"clear": Color(0.5, 0.6, 0.7), "fog": true, "fog_near": 30.0,
		"fog_far": 300.0, "fog_color": Color(0.8, 0.85, 0.9), "far": 420.0, "near": 0.3})

	var sea := MeshInstance3D.new()
	sea.name = "Sea"
	sea.mesh = _quad_mesh(8.0, 4)
	var sm := StandardMaterial3D.new()
	sm.albedo_texture = _tex(Color(0.1, 0.3, 0.6))
	sea.material_override = sm
	sea.set_meta("poi_vertex_color", "unlit")
	sea.set_meta(PBRetroFx.META, {
		"morph": {"mode": "harmonic", "targets": PBRetroFx.gerstner_pair(0.4, 6.0, Vector2(0, 1), 3.0)},
		"flipbook": {"frames": [_tex(Color(0.1, 0.3, 0.6)), _tex(Color(0.2, 0.4, 0.7)),
			_tex(Color(0.3, 0.5, 0.8))], "fps": 6.0},
	})
	root.add_child(sea)

	var surf := MeshInstance3D.new()
	surf.name = "Surf"
	surf.mesh = _quad_mesh(4.0, 1)
	var fm := StandardMaterial3D.new()
	var foam_img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	foam_img.fill(Color(1, 1, 1, 0.5))
	fm.albedo_texture = ImageTexture.create_from_image(foam_img)
	fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	surf.material_override = fm
	surf.set_meta(PBRetroFx.META, {"additive": true, "no_fog": true, "decal": 20, "morph": {
		"mode": "keyframe", "period": 5.0, "phase": 1.0,
		"targets": [{"t": 0.3, "offset": Vector3(0, 0, 2)}, {"t": 0.7, "offset": Vector3(0, 0, 3), "alpha": 0.0}],
	}})
	root.add_child(surf)

	for spec in [["PoseA", Vector3(0, 2, 5), Vector3(0, 0, -1)], ["PoseB", Vector3(3, 4, 0), Vector3(-1, -1, 0)]]:
		var m := Marker3D.new()
		m.name = spec[0]
		m.transform = Transform3D(Basis.looking_at((spec[2] as Vector3).normalized(), Vector3.UP), spec[1])
		m.set_meta(PBRetroFx.META_CAMERA_POSE, {"hold": 2.5, "travel": 4.0})
		root.add_child(m)

	var e := TestMapShowcaseBuilder.create_emitter("Spray", Vector3(0, 0.2, 0),
		"res://addons/poibuilder/materials/textures/particle_smoke.png", 12, 4.0, 0.6, false)
	e.one_shot = true
	e.set_meta("poi_burst_phase", 0.25)
	var pm := e.process_material as ParticleProcessMaterial
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(5, 0.1, 1.5)
	root.add_child(e)
	return root


func _parse(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	assert_not_null(f, "the export wrote a file")
	var out := {"textures": [], "meshes": [], "meta": {}}
	f.get_32(); f.get_32()
	var ntex := f.get_32()
	var nmesh := f.get_32()
	var ncol := f.get_32()
	var nmeta := f.get_32()
	f.get_buffer(40)
	for i in range(ntex):
		var name := f.get_buffer(32).get_string_from_ascii()
		f.get_16(); f.get_16(); f.get_16(); f.get_16()
		f.get_buffer(f.get_32())
		out["textures"].append(name)
	for i in range(nmesh):
		var m := {"name": f.get_buffer(32).get_string_from_ascii()}
		m["tex"] = f.get_32()
		var nv := f.get_32()
		m["nv"] = nv
		m["min"] = Vector3(f.get_float(), f.get_float(), f.get_float())
		m["max"] = Vector3(f.get_float(), f.get_float(), f.get_float())
		f.get_float(); f.get_float()
		var ys := PackedFloat32Array()
		for v in range(nv):
			f.get_float(); f.get_float(); f.get_32(); f.get_float()
			ys.append(f.get_float())
			f.get_float()
		m["ys"] = ys
		out["meshes"].append(m)
	for i in range(ncol):
		f.get_buffer(32); f.get_32(); f.get_buffer(24)
		f.get_buffer(f.get_32() * 36)
	for i in range(nmeta):
		var tag := f.get_buffer(32).get_string_from_ascii()
		var mtype := f.get_32()
		var size := f.get_32()
		out["meta"][tag] = {"type": mtype, "data": f.get_buffer(size)}
		f.get_buffer((4 - size % 4) % 4)
	return out


func test_lumps_round_trip() -> void:
	var root := _fixture()
	var s := PBMapExporter.ExportSettings.new()
	s.export_mode = PBMapExporter.ExportMode.RETRO
	s.bake_lighting = false
	s.export_colliders = false
	var err := PBMapExporter.export_map(root, TEST_PBM, s)
	root.free()
	assert_eq(err, OK, "export")
	var pbm := _parse(ProjectSettings.globalize_path(TEST_PBM))
	var meta: Dictionary = pbm["meta"]

	# ── mesh_fx ──
	assert_true(meta.has("mesh_fx"), "a map with poi_fx carries the mesh_fx lump")
	var d: PackedByteArray = meta["mesh_fx"]["data"]
	assert_eq(meta["mesh_fx"]["type"], PBRetroFx.PBM_META_MESH_FX)
	assert_eq(d.decode_u32(0), PBRetroFx.MESHFX_MAGIC)
	assert_eq(d.decode_u32(4), PBRetroFx.MESHFX_VERSION)
	var count := d.decode_u32(8)
	assert_eq(count, 2, "one record per fx mesh chunk")
	var off := 16
	var meshes: Array = pbm["meshes"]
	var seen := {}
	for r in range(count):
		var mi := d.decode_u32(off)
		var mesh: Dictionary = meshes[mi]
		var n := d[off + 7]
		var morph_bytes := d.decode_u32(off + 0x78)
		assert_eq(morph_bytes, (n - 1) * int(mesh["nv"]) * 24,
			"%s: the targets are whole copies of the mesh" % mesh["name"])
		if String(mesh["name"]).begins_with("Sea"):
			seen["sea"] = true
			assert_eq(d[off + 6], PBRetroFx.MORPH_CYCLIC, "harmonic morphs export in the convex form")
			assert_eq(n, 4, "rest + one triplet (one period)")
			for kk in range(1, 4):
				assert_almost_eq(d.decode_float(off + 0x10 + kk * 4), 3.0, 0.0001, "triplet period")
			assert_eq(d[off + 0x51], 3, "three flipbook frames")
			assert_almost_eq(d.decode_float(off + 0x54), 6.0, 0.0001)
			var ids := {}
			for k in range(3):
				var tid := d.decode_s16(off + 0x58 + k * 2)
				assert_true(tid >= 0 and tid < (pbm["textures"] as Array).size(), "frame %d is a real texture" % k)
				ids[tid] = true
			assert_eq(ids.size(), 3, "the frames are three distinct textures")
			assert_eq(d.decode_s16(off + 0x58 + 3 * 2), -1, "unused frame slots are -1")
			# target 1 of the first vertex: y = amp * cos(k z) (the cos half)
			var ys: PackedFloat32Array = mesh["ys"]
			var t1_y := d.decode_float(off + PBRetroFx.MESHFX_SIZE + 16)
			assert_ne(t1_y, ys[0], "the target is displaced from the rest pose")
			assert_true(float(mesh["max"].y) >= 0.39, "bounds cover the crests (the runtime culls by them)")
		else:
			seen["surf"] = true
			assert_eq(d[off + 6], PBRetroFx.MORPH_KEYFRAME)
			assert_eq(d.decode_u16(off + 4), PBRetroFx.MFX_ADDITIVE | PBRetroFx.MFX_NO_FOG | PBRetroFx.MFX_DECAL)
			assert_eq(d.decode_u16(off + 0x52), 20, "the decal bias rides the spare field")
			assert_almost_eq(d.decode_float(off + 0x08), 5.0, 0.0001, "period")
			assert_almost_eq(d.decode_float(off + 0x0C), 1.0, 0.0001, "phase")
			assert_almost_eq(d.decode_float(off + 0x14), 0.3, 0.0001, "pose 1 time")
			assert_almost_eq(d.decode_float(off + 0x18), 0.7, 0.0001, "pose 2 time")
			assert_true(float(mesh["max"].z) >= 4.9, "bounds cover the furthest pose")
		off += PBRetroFx.MESHFX_SIZE + morph_bytes
	assert_eq(off, d.size(), "records + morph data fill the lump exactly")
	assert_true(seen.has("sea") and seen.has("surf"))

	# ── camera_path ──
	assert_true(meta.has("camera_path"))
	var c: PackedByteArray = meta["camera_path"]["data"]
	assert_eq(c.decode_u32(0), PBRetroFx.CAMPATH_MAGIC)
	assert_eq(c.decode_u32(8), 2)
	assert_eq(c.slice(16, 21).get_string_from_ascii(), "PoseA")
	assert_almost_eq(c.decode_float(16 + 24), 5.0, 0.0001, "pos z")
	assert_almost_eq(c.decode_float(16 + 28), 0.0, 0.0001, "looking down -Z is yaw 0")
	assert_almost_eq(c.decode_float(60 + 28), -PI * 0.5, 0.0001, "looking down -X is yaw -pi/2")
	assert_almost_eq(c.decode_float(60 + 32), -PI * 0.25, 0.0001, "pitch 45 deg down")
	assert_almost_eq(c.decode_float(16 + 36), 2.5, 0.0001, "hold")

	# ── env ──
	assert_true(meta.has("env"))
	var ev: PackedByteArray = meta["env"]["data"]
	assert_eq(ev.size(), 40)
	assert_eq(ev.decode_u32(0), PBRetroFx.ENV_MAGIC)
	assert_eq(ev.decode_u32(8), 1, "fog on")
	assert_almost_eq(ev.decode_float(24), 420.0, 0.001, "far plane")
	assert_almost_eq(ev.decode_float(28), 0.3, 0.0001, "near plane")

	# ── emitter extensions ──
	var em: PackedByteArray = meta["emitters"]["data"]
	var e0 := 16
	var flags := em.decode_u16(e0 + 0x9A)
	assert_true((flags & PBMapExporter.PBM_EMIT_SPAWN_BOX) != 0, "box emission exports as a spawn box")
	assert_true((flags & PBMapExporter.PBM_EMIT_BURST_PHASE) != 0, "poi_burst_phase sets the flag")
	assert_true((flags & PBMapExporter.PBM_EMIT_PHASE_ALIGN) != 0, "a burst is a one-shot")
	assert_eq(em[e0 + 0x9F], 64, "burst phase 0.25 of the lifetime = 64/256")
	assert_almost_eq(em.decode_float(e0 + 0xA4), 5.0, 0.0001, "box half extent x")
	assert_almost_eq(em.decode_float(e0 + 0xAC), 1.5, 0.0001, "box half extent z")
