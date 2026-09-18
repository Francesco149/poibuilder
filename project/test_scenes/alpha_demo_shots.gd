## alpha_demo_shots.gd — captures the documentation screenshots of the ALPHA
## DEMO MAP by playing it in a real (GPU) run and photographing a fixed set of
## camera poses. Run under a display (Xwayland :0), never headless:
##
##   tools/godot_guard.sh exec bash -c \
##     'cd /work/project && godot-mono --rendering-driver opengl3 -s res://test_scenes/alpha_demo_shots.gd'
##
## PNGs land in /tmp/poibuilder_demo_shots/ (an artifact, never committed);
## docs/site/build.sh copies the ones it needs into docs/site/assets/.
extends SceneTree

const OUT_DIR := "res://exports/demo_shots"
const SETTLE_FRAMES := 40

## name -> [camera position, look-at target]
const SHOTS := {
	"demo-overview": [Vector3(11.5, 8.5, 13.5), Vector3(-1.5, 1.0, -4.0)],
	"demo-waterfall": [Vector3(-2.6, 1.7, 2.6), Vector3(-7.0, 1.9, -1.2)],
	"demo-door": [Vector3(-2.0, 1.6, 1.5), Vector3(-2.0, 1.7, -6.75)],
	"demo-neon-room": [Vector3(0.9, 1.6, -7.4), Vector3(-4.3, 0.8, -11.3)],
	"demo-neon-pedestal": [Vector3(-4.4, 1.5, -7.3), Vector3(-0.8, 0.8, -10.7)],
	"demo-stairs": [Vector3(5.6, 2.1, -1.2), Vector3(2.3, 3.1, -7.8)],
	"demo-splat-decal": [Vector3(3.2, 2.4, 6.8), Vector3(0.0, 0.0, 1.8)],
	"demo-roof-view": [Vector3(1.6, 4.7, -11.3), Vector3(-1.0, 0.4, 3.5)],
}

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	# A fixed 16:9 window: the shots are documentation assets, and the WM's
	# own window size gave a portrait viewport last time.
	DisplayServer.window_set_size(Vector2i(1600, 900))
	var err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	if err != OK:
		push_error("cannot mkdir %s: %s" % [OUT_DIR, error_string(err)])
		quit(1)
		return
	var scene: PackedScene = load("res://test_scenes/alpha_demo_map.tscn")
	if scene == null:
		push_error("alpha_demo_map.tscn missing — run run_demo_map.sh first")
		quit(1)
		return
	var map := scene.instantiate()
	# The shipped scene carries a first-person player; the photo pass uses its
	# own tripod camera instead. Free the player BEFORE the map enters the
	# tree — once inside, its _ready runs and wants its Camera3D child.
	var player := map.get_node_or_null("Player")
	if player != null:
		map.remove_child(player)
		player.free()
	root.add_child(map)
	await process_frame
	await process_frame

	var cam := Camera3D.new()
	cam.fov = 70.0
	cam.current = true
	root.add_child(cam)

	var failures := 0
	for shot_name: String in SHOTS:
		var pose: Array = SHOTS[shot_name]
		cam.position = pose[0]
		cam.look_at(pose[1])
		for i in range(SETTLE_FRAMES):
			await process_frame
		var img := root.get_viewport().get_texture().get_image()
		var path := ProjectSettings.globalize_path(OUT_DIR).path_join(shot_name + ".png")
		var save_err := img.save_png(path)
		if save_err != OK:
			push_error("save failed: %s (%s)" % [path, error_string(save_err)])
			failures += 1
		else:
			print("shot %s -> %s (%dx%d)" % [shot_name, path, img.get_width(), img.get_height()])
	print("alpha demo shots: %d captured, %d failed" % [SHOTS.size() - failures, failures])
	quit(1 if failures > 0 else 0)
