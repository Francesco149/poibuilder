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
## experience and NOT smoothed away — the COLD pass keeps them, while the
## STEADY summary (the headline) trims the warm pass's first second so the
## numbers describe the run, not the load. vsync is off so the numbers are
## render-side, not compositor-cadence.
##
## Variant handling that keeps the comparison honest: the retro GLB's
## imported Light3D nodes are HIDDEN (the retro bake carries its lighting in
## vertex colors — live lights would double-light; this is the reference
## viewer's vertex-color mode), and the modern GLB's shadow flags are
## RESTORED from the poi_shadow node extras the exporter writes (glTF
## lights cannot carry them).
##
## Ablation profiling (--ablate, pb variant only): the PB scene is flown
## once as-is, then once per ablation — no_shadows / no_emitters / no_splat
## / no_lights — each on a fresh instantiate, warm pass only. The deltas
## attribute the frame cost to its sources (shadow passes, particle fill,
## the splat shader, dynamic lighting) so an optimization pass knows where
## to dig. Render counters (draw calls / primitives / objects per frame)
## ride along in every summary.
extends SceneTree

const WARMUP_SECONDS := 3.0
const STEADY_TRIM_SECONDS := 1.0 # headline numbers exclude the load tail
const CAMERA_FOV := 70.0
const ABLATIONS := ["no_shadows", "no_emitters", "no_splat", "no_lights"]

## Visual-parity poses: every variant x renderer is photographed here and the
## frames assembled into contact sheets (tools/bench_contact_sheet.py), so a
## lighting regression is SEEN next to its siblings, not just measured.
const SHOT_POSES := {
	"plaza": [Vector3(0.0, 1.6, 6.5), Vector3(-2.0, 1.4, -6.0)],
	"waterfall": [Vector3(-2.6, 1.7, 2.6), Vector3(-7.0, 1.9, -1.2)],
	"doorway": [Vector3(-1.6, 1.6, 1.0), Vector3(-2.0, 1.3, -9.8)],
	"neon": [Vector3(-1.6, 1.6, -9.2), Vector3(-4.3, 1.0, -11.3)],
	"roof": [Vector3(2.75, 4.1, -6.6), Vector3(-2.0, 2.5, -9.7)],
}
const SHOT_SETTLE_FRAMES := 40

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

	if opts["ablate"] != "":
		await _run_ablation(opts)
		return

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
	# first time hits. PASS 2 is "warm" steady-state; its STEADY summary
	# (trimmed by STEADY_TRIM_SECONDS) is the headline — perf data from the
	# run, not the load. ──
	var summaries: Array = [[], []]
	var warm_frames := PackedFloat64Array()
	for pass_idx in range(summaries.size()):
		var flown := await _fly_pass(cam)
		summaries[pass_idx] = _summarize(opts["variant"], flown["frames"], map,
			"cold" if pass_idx == 0 else "warm")
		if pass_idx == 1:
			warm_frames = flown["frames"]
	var steady_frames := warm_frames.slice(_frames_after_trim(warm_frames))
	var steady := _summarize(opts["variant"], steady_frames, map, "steady")

	var report := {
		"variant": opts["variant"],
		"renderer": RenderingServer.get_current_rendering_method(),
		"census": summaries[0]["census"],
		"cold": summaries[0],
		"warm": summaries[1],
		"steady": steady,
		"steady_trim_seconds": STEADY_TRIM_SECONDS,
	}
	_write_report(report, opts["out"])
	_print_summary(report["cold"])
	_print_summary(report["warm"])
	_print_summary(report["steady"])
	await _capture_shots(cam, opts["variant"])
	map.free()
	quit(0)

## Flies the whole path once, recording every frame's wall-clock ms.
func _fly_pass(cam: Camera3D) -> Dictionary:
	var frames := PackedFloat64Array()
	var draws := PackedInt64Array()
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
	return {"frames": frames, "elapsed": elapsed}

## Index of the first frame whose cumulative time is past the trim: everything
## before it is load/spawn tail, not run.
func _frames_after_trim(frames: PackedFloat64Array) -> int:
	var acc := 0.0
	for i in range(frames.size()):
		acc += frames[i] / 1000.0
		if acc >= STEADY_TRIM_SECONDS:
			return i + 1
	return frames.size()

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
	if variant == "retro_glb":
		# The bake's lighting lives in COLOR_0; Godot's importer does not
		# enable the albedo-from-vertex-color flag for JSON-authored
		# materials, so without this the baked map renders black once the
		# (double-lighting) imported lights are hidden.
		PBMapExporter.apply_baked_vertex_colors(generated)
	var note := ""
	if variant == "retro_glb":
		# Viewer parity: the retro bake carries its lighting in VERTEX COLORS.
		# The GLB also transports the light nodes (a consumer may want them for
		# dynamic objects), but leaving them live here double-lights every
		# surface — the reference viewer hides them in its vertex-color mode,
		# and so does the bench.
		var hidden := [0] # lambdas capture locals by value: count in a cell
		_apply_to_lights(generated, func(l: Light3D) -> void:
			l.visible = false
			hidden[0] += 1)
		note = " (import lights hidden: %d — vertex-lit scene)" % hidden[0]
	else:
		# glTF lights carry no shadow flags; the exporter tags shadow-casting
		# lights with poi_shadow node extras. Restore the authored look.
		var restored := [0]
		_apply_to_lights(generated, func(l: Light3D) -> void:
			if l.has_meta("extras") and (l.get_meta("extras") as Dictionary).get("poi_shadow", false):
				l.shadow_enabled = true
				restored[0] += 1)
		note = " (shadows restored from poi_shadow extras: %d)" % restored[0]
	# The display environment a consumer should show. The retro GLB is FULLY
	# BAKED — its lighting lives in the vertex colors, so the consumer adds
	# NOTHING (no ambient, linear tonemap): sky + the preset's linear fog,
	# exactly what the PSP draws (apply_retro_display). The modern GLB keeps
	# live materials, so it gets the full authored environment back. The
	# preset name rides the export root's extras either way.
	var preset := "day"
	if generated.has_meta("extras"):
		preset = str((generated.get_meta("extras") as Dictionary).get("poi_env_preset", preset))
	elif generated.has_meta("poi_env_preset"):
		preset = str(generated.get_meta("poi_env_preset"))
	if generated is Node3D:
		if variant == "retro_glb":
			PBEnvironment.apply_retro_display(generated as Node3D, preset)
			note += " [retro display env: %s]" % preset
		else:
			PBEnvironment.apply_preset(generated as Node3D, preset)
			note += " [env preset: %s]" % preset
	var census2 := {"mesh": 0, "particles": 0, "lights": 0}
	_census(generated, census2)
	print("[bench] variant=%s meshes=%d emitters=%d lights=%d%s" % [
		variant, census2["mesh"], census2["particles"], census2["lights"], note])
	return generated

func _apply_to_lights(node: Node, fn: Callable) -> void:
	if node is Light3D:
		fn.call(node)
	for c in node.get_children():
		_apply_to_lights(c, fn)

## Photographs SHOT_POSES (or a given subset) into exports/bench/shots/ named
## <renderer>_<variant>_<pose>.png — tools/bench_contact_sheet.py grids them.
func _capture_shots(cam: Camera3D, variant: String, poses: Array = []) -> void:
	var dir := ProjectSettings.globalize_path("res://exports/bench/shots")
	DirAccess.make_dir_recursive_absolute(dir)
	var method := RenderingServer.get_current_rendering_method()
	var tag := "vulkan" if method.contains("forward") else "gl"
	var wanted: Array = poses if not poses.is_empty() else SHOT_POSES.keys()
	for pose_name: String in wanted:
		var pose: Array = SHOT_POSES[pose_name]
		cam.position = pose[0]
		cam.look_at(pose[1])
		for i in range(SHOT_SETTLE_FRAMES):
			await process_frame
		var img := root.get_viewport().get_texture().get_image()
		var path := dir.path_join("%s_%s_%s.png" % [tag, variant, pose_name])
		var err := img.save_png(path)
		print("[bench] shot %s (%s)" % [path, error_string(err)])

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
	var opts := {"variant": "pb", "seconds": "0", "out": "", "ablate": ""}
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--variant="):
			opts["variant"] = arg.get_slice("=", 1)
		elif arg.begins_with("--out="):
			opts["out"] = arg.get_slice("=", 1)
		elif arg.begins_with("--ablate"):
			opts["ablate"] = arg.get_slice("=", 1) if "=" in arg else ",".join(ABLATIONS)
	return opts

## ── ablation profiling ───────────────────────────────────────────────────────
## One process, one camera path, several scenes: the PB scene flown as-is,
## then once per ablation on a fresh instantiate. The DELTA of each row against
## the base is that feature's share of the frame — the "where to optimize" map.
func _run_ablation(opts: Dictionary) -> void:
	var cam := Camera3D.new()
	cam.fov = CAMERA_FOV
	cam.current = true
	root.add_child(cam)

	var rows: Array = []
	var ablations: Array = ABLATIONS if opts["ablate"] == "" \
			else Array(String(opts["ablate"]).split(","))
	for ablation in ["base"] + ablations:
		var map := _load_variant("pb")
		if map == null:
			quit(1)
			return
		root.add_child(map)
		var applied := _apply_ablation(map, ablation)
		# Warmup at the spawn view (shader compiles are not what we measure),
		# then ONE warm pass — the steady question is "what does the run cost".
		await _fly_leg(cam, PATH[0], WARMUP_SECONDS / float(PATH[0][3]))
		var flown := await _fly_pass(cam)
		var steady_frames: PackedFloat64Array = (flown["frames"] as PackedFloat64Array) \
			.slice(_frames_after_trim(flown["frames"]))
		var summary := _summarize(ablation, steady_frames, map, "steady")
		summary["ablation_removed"] = applied
		rows.append(summary)
		print("[profile] %-11s median %6.2f ms | 1%% low %6.2f | jitter %4.2f | draws %d | removed: %s" % [
			ablation, summary["median_ms"], summary["p99_ms"], summary["jitter_ms"],
			summary["avg_draw_calls"], applied])
		await _capture_shots(cam, "ablation_" + ablation, ["plaza", "neon"])
		map.free()
	var base: Dictionary = rows[0]
	for row: Dictionary in rows:
		row["delta_ms_vs_base"] = row["median_ms"] - base["median_ms"]
	_print_profile(rows)
	_write_report({"variant": "pb", "profile": "ablation", "rows": rows},
		"res://exports/bench/pb_profile.json")
	quit(0)

## Applies one ablation to the live PB scene and returns what was removed.
func _apply_ablation(map: Node3D, ablation: String) -> String:
	match ablation:
		"base":
			return "nothing (reference)"
		"no_shadows":
			var n := [0]
			_apply_to_lights(map, func(l: Light3D) -> void:
				if l.shadow_enabled:
					l.shadow_enabled = false
					n[0] += 1)
			return "%d shadow-casting lights" % n[0]
		"no_emitters":
			var n := _free_emitters(map)
			return "%d particle emitters" % n
		"no_splat":
			var n := 0
			var stack: Array[Node] = [map]
			while not stack.is_empty():
				var node: Node = stack.pop_back()
				if node is PBMesh and (node as PBMesh).pb_mesh_data != null:
					var pb := node as PBMesh
					var swapped := false
					for mi in range(pb.pb_mesh_data.materials.size()):
						var mat := pb.pb_mesh_data.materials[mi]
						if mat != null and PBSplat.is_splat_material(mat):
							pb.pb_mesh_data.materials[mi] = PBMapExporter._standard_from_splat(mat)
							swapped = true
							n += 1
					if swapped:
						pb.rebuild()
				for c in node.get_children():
					stack.append(c)
			return "%d splat materials -> standard" % n
		"no_lights":
			var n := [0]
			_apply_to_lights(map, func(l: Light3D) -> void:
				if l.visible:
					l.visible = false
					n[0] += 1)
			return "%d lights" % n[0]
	push_error("unknown ablation '%s' (%s)" % [ablation, ", ".join(ABLATIONS)])
	return "UNKNOWN"

func _free_emitters(node: Node) -> int:
	var n := 0
	for c in node.get_children():
		if c is GPUParticles3D:
			c.visible = false
			c.emitting = false
			n += 1
		n += _free_emitters(c)
	return n

func _print_profile(rows: Array) -> void:
	var base: Dictionary = rows[0]
	print("[profile] base median %.2f ms; deltas attribute the frame cost:" % base["median_ms"])
	for row: Dictionary in rows:
		if row == base:
			continue
		print("[profile]   without %-12s %6.2f ms  (%+.2f vs base)" % [
			row["ablation"], row["median_ms"], row["delta_ms_vs_base"]])

func _summarize(variant: String, frames: PackedFloat64Array, map: Node3D,
		pass_name: String) -> Dictionary:
	var sorted := Array(frames)
	sorted.sort()
	var n := sorted.size()
	var sum := 0.0
	for v in sorted:
		sum += v
	var elapsed := sum / 1000.0
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
		"avg_draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"avg_primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		"objects_in_frame": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
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
	print("[bench] %-10s avg %5.1f fps (%5.2f ms) | median %5.2f | 1%% low %5.2f | worst %6.2f ms | jitter %4.2f | >16.7ms %4.1f%% | >33.3ms %3.1f%% | hitches %d | draws %d" % [
		r["variant"], r["avg_fps"], r["avg_ms"], r["median_ms"], r["p99_ms"],
		r["worst_ms"], r["jitter_ms"], r["pct_over_16_7ms"], r["pct_over_33_3ms"],
		r["hitches_2x_median"], r["avg_draw_calls"]])
