## fly_bench.gd — the INTERACTIVE half of the frame-pacing bench: the same
## three variants of the alpha demo map assembled by bench_variants.gd, the
## same 1280×720 vsync-off methodology as frame_pacing_bench.gd — but YOU
## fly. A free camera (the retro viewer's scheme) plus a frame-time overlay:
## a rolling graph and the numbers that make smoothness legible — current /
## median / 1% low (p99) / worst frame times, hitches, draw counts, over a
## 240-frame rolling window AND the whole session.
##
## The point is standing where the numbers come from: jump to the neon room
## (key 4) and watch the shadow-casting omnis spike the graph; step back out
## (key 1) and watch it fall. Where frame_pacing_bench.gd WRITES the report,
## this one lets you feel why the report says what it says.
##
## Run (one command, exports the GLB variants first if missing):
##   ./run_fly_bench.sh [pb | retro_glb | modern_glb] [--renderer vulkan]
##
## Keys (fly mode only — the Player node is removed, like in the bench):
##   click       capture the mouse        Esc   release mouse; again = quit
##   WASD + mouse  fly                    Shift   turbo (×3)
##   Space / E     up                     Q / C   down
##   wheel         move speed 1..50
##   1..5          jump to the bench's photo poses (plaza, waterfall,
##                 doorway, neon, roof) — the five views the contact
##                 sheets compare
##   R             back to the spawn view
##   H / Tab       toggle the whole HUD   G   toggle the graph
extends SceneTree

## The bench's spawn view (frame_pacing_bench.gd's PATH[0] start).
const SPAWN_POSE := [Vector3(0.0, 1.6, 6.5), Vector3(-2.0, 1.4, -6.0)]
## Teleport targets (keys 1..5): frame_pacing_bench.gd's SHOT_POSES, so an
## interactive session visits exactly the views the contact sheets compare.
const POIS := [
	["plaza", Vector3(0.0, 1.6, 6.5), Vector3(-2.0, 1.4, -6.0)],
	["waterfall", Vector3(-2.6, 1.7, 2.6), Vector3(-7.0, 1.9, -1.2)],
	["doorway", Vector3(-1.6, 1.6, 1.0), Vector3(-2.0, 1.3, -9.8)],
	["neon", Vector3(-1.6, 1.6, -9.2), Vector3(-4.3, 1.0, -11.3)],
	["roof", Vector3(2.75, 4.1, -6.6), Vector3(-2.0, 2.5, -9.7)],
]

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	var variant := "pb"
	var selftest := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--variant="):
			variant = arg.get_slice("=", 1)
		elif arg.begins_with("--selftest="):
			selftest = arg.get_slice("=", 1)
	DisplayServer.window_set_size(Vector2i(1280, 720))
	# Same methodology as frame_pacing_bench.gd: raw render-side frame times —
	# no compositor cadence, no fps cap.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	var map := BenchVariants.load_variant(variant)
	if map == null:
		quit(1)
		return
	root.add_child(map)

	var cam := Camera3D.new()
	cam.fov = 70.0
	cam.current = true
	root.add_child(cam)
	_set_pose(cam, SPAWN_POSE)

	var layer := CanvasLayer.new()
	root.add_child(layer)
	var rig: Control = load("res://test_scenes/fly_rig.gd").new()
	rig.setup(cam, variant, RenderingServer.get_video_adapter_name(),
		SPAWN_POSE, POIS)
	layer.add_child(rig)

	DisplayServer.window_set_title("poibuilder fly bench — %s" % BenchVariants.display_name(variant))

	if selftest != "":
		# Dev/CI: fly nothing, just prove the rig boots, records and draws,
		# screenshot the HUD, and leave. This is how a headless session
		# (Linux guard container, or the Windows bench box over ssh) still
		# verifies the interactive tool without a human flying it.
		for i in range(120):
			await process_frame
		var img := root.get_viewport().get_texture().get_image()
		var err := img.save_png(selftest)
		print("[fly] selftest shot %s (%s)" % [selftest, error_string(err)])
		quit(0 if err == OK else 1)
		return
	print("[fly] %s | %s | %s" % [BenchVariants.display_name(variant),
		RenderingServer.get_current_rendering_method(),
		RenderingServer.get_video_adapter_name()])
	print("[fly] ready — click the window to capture the mouse, WASD to fly, Esc twice to quit")

static func _set_pose(cam: Camera3D, pose: Array) -> void:
	cam.position = pose[0]
	var look := ((pose[1] as Vector3) - (pose[0] as Vector3)).normalized()
	cam.rotation = Vector3(asin(clampf(look.y, -1.0, 1.0)), atan2(-look.x, -look.z), 0.0)
