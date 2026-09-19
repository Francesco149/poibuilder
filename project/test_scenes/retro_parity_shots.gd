## retro_parity_shots.gd — renders a baked retro GLB the way EACH consumer
## does, so the pipelines can be A/B'd against a real PSP screenshot:
##   raw   engine defaults, nothing added (naive consumer)
##   retro apply_retro_display — sky + linear fog, zero added light (the PSP
##         contract; this is what a baked-map consumer should do)
##   env   the full live preset (ambient + filmic — the LIVE-scene look; on a
##         baked map this double-lights, kept here to show the delta)
## Measure mean luma of the PNGs against device screenshots for the same
## map + preset. Baseline measured 2026-09-19 (see CHANGELOG v0.9.162):
## showcase day PSP 0.450 vs retro 0.447; alpha dusk PSP 0.122 vs retro 0.123.
## Run under a display, through the guard:
##   DISPLAY=:0 GUARD_X11=1 tools/godot_guard.sh exec bash -c \
##     'cd /work/project && godot-mono --rendering-driver opengl3 \
##      -s res://test_scenes/retro_parity_shots.gd'
## PNGs land in res://exports/bench/ab/ (gitignored).
## modes: raw = engine defaults, nothing added (the naive consumer / closest
## to the PSP's tex*vcolor path); env = the PBEnvironment preset applied
## (sky ambient + filmic tonemap + fog — what the frame bench does).
## Usage inside the guard:
##   godot-mono --rendering-driver opengl3 -s res://exports/ab_render.gd
## PNGs land in res://exports/bench/ab/ ; luma stats are computed afterwards.
extends SceneTree

const SHOTS := [
	{"glb": "res://exports/showcase_retro_baked_day.glb", "preset": "day", "tag": "showcase_day"},
	{"glb": "res://exports/showcase_retro_baked_dusk.glb", "preset": "dusk", "tag": "showcase_dusk"},
	{"glb": "res://exports/alpha_demo_retro_baked.glb", "preset": "dusk", "tag": "alpha_dusk"},
]
const MODES := ["raw", "retro", "env"]
const SETTLE := 40

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	var out_dir := ProjectSettings.globalize_path("res://exports/bench/ab")
	DirAccess.make_dir_recursive_absolute(out_dir)
	for shot in SHOTS:
		for mode in MODES:
			var doc := GLTFDocument.new()
			var state := GLTFState.new()
			var err := doc.append_from_file(shot["glb"], state)
			if err != OK:
				push_error("parse failed: %s" % shot["glb"])
				continue
			var scene := doc.generate_scene(state)
			PBMapExporter.apply_baked_vertex_colors(scene)
			var spawn_pos := Vector3(0, 1.6, 6.0)
			var spawn_look := Vector3(0, 1.2, 0)
			var spawn := _find_node(scene, "Spawn")
			if spawn is Node3D:
				spawn_pos = (spawn as Node3D).global_position
				spawn_look = spawn_pos - (spawn as Node3D).global_basis.z
			if mode == "env":
				PBEnvironment.apply_preset(scene, shot["preset"])
			elif mode == "retro":
				PBEnvironment.apply_retro_display(scene, shot["preset"])
			root.add_child(scene)
			var cam := Camera3D.new()
			cam.fov = 70.0
			cam.current = true
			root.add_child(cam)
			cam.position = spawn_pos
			cam.look_at(spawn_look)
			for i in range(SETTLE):
				await process_frame
			var img := root.get_viewport().get_texture().get_image()
			var path := out_dir.path_join("%s_%s.png" % [shot["tag"], mode])
			img.save_png(path)
			print("[ab] wrote %s" % path)
			scene.free()
			cam.free()
			await process_frame
	quit(0)

func _find_node(node: Node, wanted: String) -> Node:
	if node.name.begins_with(wanted):
		return node
	for c in node.get_children():
		var hit := _find_node(c, wanted)
		if hit != null:
			return hit
	return null
