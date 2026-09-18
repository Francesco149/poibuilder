## frame_pacing_bench.gd — the Godot-side frame-pacing benchmark for the alpha
## demo map, comparing the three ways a map reaches a Godot player:
##
##   pb          the POIBUILDER SCENE AS IS — editable PBMesh nodes, splat
##               shader, decals, realtime lights (the "godot modern" pipeline)
##   retro_glb   the RETRO-BAKED .glb — baked tile textures, vertex lighting
##   modern_glb  the MODERN .glb — authored materials with paint baked into
##               textures, realtime lights
##
## Not a static average-fps benchmark: the camera flies a GAMEPLAY-LIKE path
## (courtyard -> through the doorway -> neon room -> out and up the stairs ->
## roof) while frame times are recorded wall-clock, so the report shows the
## DIPS and PACING — percentiles, jitter, hitch counts — which is what makes
## a game feel smooth or stuttery.
##
## Run (one Godot at a time, under the guard, on a real display):
##   DISPLAY=:0 tools/godot_guard.sh exec bash -c 'cd /work/project && \
##     godot-mono --rendering-driver opengl3 -s res://test_scenes/frame_pacing_bench.gd \
##     -- --variant=pb'
## Or just ./run_bench.sh, which exports the variants and runs all three.
## Reports land in project/exports/bench/ (gitignored).
##
## Caveats carried in the report: first-sight shader compiles are real user
## experience and NOT smoothed away (the 3 s warmup only covers the spawn
## view); vsync is off so the numbers are render-side, not compositor-cadence.
extends SceneTree

const WARMUP_SECONDS := 3.0
const CAMERA_FOV := 70.0

## The gameplay-like camera path. Each leg: [from_pos, to_pos, look_at, seconds]
## — position lerps (smoothstep) from->to while KEEPING the look-at fixed, so
## walking through the doorway swings the view the way a walking player's does.
const PATH := [
	# Spawn in the south plaza, walk the brick path toward the doorway.
	[Vector3(0.0, 1.6, 6.5), Vector3(-1.6, 1.6, 1.0), Vector3(-2.0, 1.4, -6.0), 5.0],
	# Through the arch into the neon room, up to the pedestal.
	[Vector3(-1.6, 1.6, 1.0), Vector3(-0.5, 1.6, -7.2), Vector3(-2.0, 1.3, -9.8), 3.0],
	[Vector3(-0.5, 1.6, -7.2), Vector3(-1.6, 1.6, -9.2), Vector3(-4.3, 1.0, -11.3), 3.0],
	# Turn and leave; arc up the exterior stairs to the roof.
	[Vector3(-1.6, 1.6, -9.2), Vector3(2.0, 1.6, -3.0), Vector3(0.0, 1.2, 2.0), 3.0],
	[Vector3(2.0, 1.6, -3.0), Vector3(2.75, 4.1, -6.6), Vector3(-2.0, 2.5, -9.7), 3.0],
	# Across the roof, then back down to the plaza for a last wide look.
	[Vector3(2.75, 4.1, -6.6), Vector3(-2.0, 4.3, -9.7), Vector3(-1.0, 0.5, 4.0), 3.0],
	[Vector3(-2.0, 4.3, -9.7), Vector3(1.0, 1.6, 5.5), Vector3(-2.5, 0.8, -2.0), 4.0],
]

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	var opts := _parse_args()
	DisplayServer.window_set_size(Vector2i(1280, 720))
	# Frame pacing is the subject: no compositor cadence, no fps cap.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	var map := _load_variant(opts["variant"])
	if map == null:
		quit(1)
		return
	root.add_child(map)

	var cam := Camera3D.new()
	cam.fov = CAMERA_FOV
	cam.current = true
	root.add_child(cam)

	# ── warmup: first-render shader compiles for the SPAWN view ──
	await _fly_leg(cam, PATH[0], WARMUP_SECONDS / float(PATH[0][3]))

	# ── recording: two passes over the same path. PASS 1 is "cold" — the
	# first-visit experience where mid-path shader compiles and first texture
	# uploads show up as hitches, exactly what a player walking in for the
	# first time hits. PASS 2 is "warm" steady-state. ──
	var passes: Array = [[], []]
	for pass_idx in range(passes.size()):
		var frames := PackedFloat64Array()
		var elapsed := 0.0
		var leg_idx := 0
		var leg_t := 0.0
		var total := _path_seconds()
		while elapsed < total:
			var t0 := Time.get_ticks_usec()
			await process_frame
			var dt_ms := float(Time.get_ticks_usec() - t0) / 1000.0
			frames.append(dt_ms)
			elapsed += dt_ms / 1000.0
			leg_t += dt_ms / 1000.0
			var leg: Array = PATH[leg_idx]
			var leg_dur := float(leg[3])
			if leg_t >= leg_dur and leg_idx < PATH.size() - 1:
				leg_t = 0.0
				leg_idx += 1
				leg = PATH[leg_idx]
			var k := clampf(leg_t / leg_dur, 0.0, 1.0)
			k = k * k * (3.0 - 2.0 * k) # smoothstep: game-like accelerate/decelerate
			cam.position = (leg[0] as Vector3).lerp(leg[1] as Vector3, k)
			cam.look_at(leg[2] as Vector3)
		passes[pass_idx] = _summarize(opts["variant"], frames, elapsed, map,
			"cold" if pass_idx == 0 else "warm")

	var report := {
		"variant": opts["variant"],
		"census": passes[0]["census"],
		"cold": passes[0],
		"warm": passes[1],
	}
	_write_report(report, opts["out"])
	_print_summary(report["cold"])
	_print_summary(report["warm"])
	map.free()
	quit(0)

func _path_seconds() -> float:
	var total := 0.0
	for leg in PATH:
		total += float(leg[3])
	return total

## Instantiates one variant and returns the map root (or null after printing
## why not). Also prints a census so the report is honest about what each
## variant contains.
func _load_variant(variant: String) -> Node3D:
	var path := ""
	match variant:
		"pb":
			path = "res://test_scenes/alpha_demo_map.tscn"
		"retro_glb":
			path = "res://exports/alpha_demo_retro_baked.glb"
		"modern_glb":
			path = "res://exports/alpha_demo_modern.glb"
		_:
			push_error("unknown variant '%s' (pb | retro_glb | modern_glb)" % variant)
			return null
	if variant == "pb":
		if not ResourceLoader.exists(path):
			push_error("%s missing — run run_demo_map.sh first" % path)
			return null
		var scene: PackedScene = load(path)
		if scene == null:
			push_error("%s did not load" % path)
			return null
		var inst: Node = scene.instantiate()
		var player := inst.get_node_or_null("Player")
		if player != null:
			inst.remove_child(player)
			player.free()
		var census := {"mesh": 0, "particles": 0, "lights": 0}
		_census(inst, census)
		print("[bench] variant=%s meshes=%d emitters=%d lights=%d" % [
			variant, census["mesh"], census["particles"], census["lights"]])
		return inst
	# The exported GLBs live under res://exports/ behind its .gdignore —
	# deliberately invisible to the import system — so they are parsed with
	# GLTFDocument directly, the same thing the retro viewer does.
	if not FileAccess.file_exists(path):
		push_error("%s missing — export it first (run_bench.sh does both)" % path)
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(path, state)
	if err != OK:
		push_error("%s failed to parse (err %d)" % [path, err])
		return null
	var generated := doc.generate_scene(state)
	if generated == null:
		push_error("%s produced no scene" % path)
		return null
	var census2 := {"mesh": 0, "particles": 0, "lights": 0}
	_census(generated, census2)
	print("[bench] variant=%s meshes=%d emitters=%d lights=%d" % [
		variant, census2["mesh"], census2["particles"], census2["lights"]])
	return generated

func _census(node: Node, out: Dictionary) -> void:
	if node is MeshInstance3D:
		out["mesh"] += 1
	elif node is GPUParticles3D:
		out["particles"] += 1
	elif node is Light3D:
		out["lights"] += 1
	for c in node.get_children():
		_census(c, out)

## Flies ONE leg of the path over `seconds_scale * leg duration` of real time
## (the warmup reuses this at reduced scale).
func _fly_leg(cam: Camera3D, leg: Array, seconds_scale: float) -> void:
	var dur := float(leg[3]) * seconds_scale
	var t := 0.0
	while t < dur:
		var t0 := Time.get_ticks_usec()
		await process_frame
		t += float(Time.get_ticks_usec() - t0) / 1000.0
		var k: float = clampf(t / dur, 0.0, 1.0)
		cam.position = (leg[0] as Vector3).lerp(leg[1] as Vector3, k)
		cam.look_at(leg[2] as Vector3)

func _parse_args() -> Dictionary:
	var opts := {"variant": "pb", "seconds": "0", "out": ""}
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--variant="):
			opts["variant"] = arg.get_slice("=", 1)
		elif arg.begins_with("--out="):
			opts["out"] = arg.get_slice("=", 1)
	return opts

func _summarize(variant: String, frames: PackedFloat64Array, elapsed: float, map: Node3D,
		pass_name: String) -> Dictionary:
	var sorted := Array(frames)
	sorted.sort()
	var n := sorted.size()
	var sum := 0.0
	for v in sorted:
		sum += v
	var avg := sum / float(n)
	var median: float = sorted[n / 2]
	var p95: float = sorted[int(n * 0.95)]
	var p99: float = sorted[mini(int(n * 0.99), n - 1)]
	var worst: float = sorted[n - 1]
	var varsum := 0.0
	for v in sorted:
		varsum += (v - avg) * (v - avg)
	var stddev := sqrt(varsum / float(n))
	var over_167 := 0
	var over_333 := 0
	var hitches := 0
	for v in sorted:
		if v > 16.7:
			over_167 += 1
		if v > 33.3:
			over_333 += 1
		if v > median * 2.0:
			hitches += 1
	var census := {"mesh": 0, "particles": 0, "lights": 0}
	_census(map, census)
	return {
		"variant": variant,
		"pass": pass_name,
		"frames": n,
		"seconds": elapsed,
		"avg_ms": avg,
		"avg_fps": 1000.0 / avg,
		"median_ms": median,
		"p95_ms": p95,
		"p99_ms": p99,       # the "1% low" frame time
		"worst_ms": worst,
		"jitter_ms": stddev,
		"pct_over_16_7ms": 100.0 * over_167 / n,
		"pct_over_33_3ms": 100.0 * over_333 / n,
		"hitches_2x_median": hitches,
		"census": census,
		"frames_ms": Array(frames),
	}

func _write_report(report: Dictionary, out_path: String) -> void:
	if out_path.is_empty():
		out_path = "res://exports/bench/%s.json" % report["variant"]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://exports/bench"))
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		push_error("cannot write %s" % out_path)
		return
	f.store_string(JSON.stringify(report, "  "))
	f.close()
	print("[bench] report -> %s" % ProjectSettings.globalize_path(out_path))

func _print_summary(r: Dictionary) -> void:
	print("[bench] %-10s avg %5.1f fps (%5.2f ms) | median %5.2f | 1%% low %5.2f | worst %6.2f ms | jitter %4.2f | >16.7ms %4.1f%% | >33.3ms %3.1f%% | hitches %d" % [
		r["variant"], r["avg_fps"], r["avg_ms"], r["median_ms"], r["p99_ms"],
		r["worst_ms"], r["jitter_ms"], r["pct_over_16_7ms"], r["pct_over_33_3ms"],
		r["hitches_2x_median"]])
