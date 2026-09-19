## retro_bake_iterate.gd — the FAST loop for tuning the baked retro look of
## the alpha demo map. One rendered process: rebuild the demo scene in
## memory, export ONLY the retro GLB, re-parse it through the exact consumer
## path the frame bench uses (apply_baked_vertex_colors, imported lights
## hidden, apply_retro_display), and photograph the five fixed poses.
## ~40 s end to end; no flights, no other variants, no Vulkan.
##
##   DISPLAY=:0 GUARD_X11=1 tools/godot_guard.sh exec bash -c \
##     'cd /work/project && godot-mono --rendering-driver opengl3 \
##      -s res://test_scenes/retro_bake_iterate.gd'
##
## Shots overwrite exports/bench/shots/gl_retro_glb_*.png, so
## `python3 tools/bench_contact_sheet.py` regenerates the GL sheet after.
## Compare against a device screenshot (./deploy_psp.sh <map>.pbm) — the PSP
## is the arbiter of what the bake should look like.
extends SceneTree

const SETTLE := 40
const OUT := "res://exports/bench/shots"

const POSES := {
	"plaza": [Vector3(0.0, 1.6, 6.5), Vector3(-2.0, 1.4, -6.0)],
	"waterfall": [Vector3(-2.6, 1.7, 2.6), Vector3(-7.0, 1.9, -1.2)],
	"doorway": [Vector3(-1.6, 1.6, 1.0), Vector3(-2.0, 1.3, -9.8)],
	"neon": [Vector3(-1.6, 1.6, -9.2), Vector3(-4.3, 1.0, -11.3)],
	"roof": [Vector3(2.75, 4.1, -6.6), Vector3(-2.0, 2.5, -9.7)],
}

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	# 1. Build + export the retro GLB (the same settings export_bench_variants uses).
	var demo := AlphaDemoMapBuilder.build_demo_scene(false)
	AlphaDemoMapBuilder._flush_paint_textures(demo)
	AlphaDemoMapBuilder._set_owner_recursive(demo, demo)
	var settings := PBMapExporter.ExportSettings.new()
	settings.export_mode = PBMapExporter.ExportMode.RETRO
	settings.subdivide_quads = true
	settings.grid_size = 1.0
	settings.bake_lighting = true
	settings.bake_shadows = true
	settings.bake_ao = true
	settings.bake_textures = true
	settings.tile_resolution = 128
	settings.export_colliders = true
	settings.export_billboards = true
	settings.ambient_color = PBEnvironment.get_preset("dusk")["ambient_color"]
	var err := PBMapExporter.export_map(demo, "res://exports/alpha_demo_retro_baked.glb", settings)
	demo.free()
	print("[iter] export retro glb: ", error_string(err))
	if err != OK:
		quit(1)
		return

	# 2. Consume it exactly like the frame bench does.
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	err = doc.append_from_file("res://exports/alpha_demo_retro_baked.glb", state)
	if err != OK:
		push_error("parse failed")
		quit(1)
		return
	var scene := doc.generate_scene(state)
	PBMapExporter.apply_baked_vertex_colors(scene)
	_apply_to_lights(scene, func(l: Light3D) -> void: l.visible = false)
	PBEnvironment.apply_retro_display(scene, "dusk")
	root.add_child(scene)

	var cam := Camera3D.new()
	cam.fov = 70.0
	cam.current = true
	root.add_child(cam)

	# 3. Photograph the fixed poses.
	var dir := ProjectSettings.globalize_path(OUT)
	DirAccess.make_dir_recursive_absolute(dir)
	for pose_name: String in POSES:
		var pose: Array = POSES[pose_name]
		cam.position = pose[0]
		cam.look_at(pose[1])
		for i in range(SETTLE):
			await process_frame
		var img := root.get_viewport().get_texture().get_image()
		var path := dir.path_join("gl_retro_glb_%s.png" % pose_name)
		img.save_png(path)
		print("[iter] shot %s" % path)
	print("[iter] done")
	quit(0)

func _apply_to_lights(node: Node, fn: Callable) -> void:
	if node is Light3D:
		fn.call(node)
	for c in node.get_children():
		_apply_to_lights(c, fn)
