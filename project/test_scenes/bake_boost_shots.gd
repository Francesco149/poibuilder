## bake_boost_shots.gd — what ExportSettings.bake_boost does to the baked
## retro look, measured and photographed on the alpha demo map's courtyard.
##
## Per preset (dusk = the demo's own, day = where the boost's ceiling bites),
## exports the retro GLB at boost 1 and boost 2, consumes each exactly like
## retro_bake_iterate.gd (apply_baked_vertex_colors, imported lights hidden,
## apply_retro_display — the Godot display parity-checked against the PSP),
## and photographs the poses three ways:
##   b1    boost 1 (the default since v0.9.184): tex x light
##   b2    boost 2: tex x min(2 light, 1) — the boost doubles the LIGHT and
##         saturates it at 1 before the texture multiply
##   hw2x  the boost-1 bake with the doubling AFTER the texture multiply
##         (albedo x2 on every baked surface): min(2 tex light, 1). That is
##         what modulate-2x hardware draws for the same bake — PS1/PS2
##         vertex colour 0x80 = 1.0, D3D MODULATE2X, the PSP GE's unused
##         GU_FRAGMENT_2X — overbright included.
## b2 and hw2x agree exactly wherever 2 x light <= 1, so the script also
## prints how much of each bake sits above 0.5 and how far the two images
## diverge per pose.
##
## Run under a display, through the guard:
##   DISPLAY=:0 GUARD_X11=1 tools/godot_guard.sh exec bash -c \
##     'cd /work/project && godot-mono --rendering-driver opengl3 \
##      -s res://test_scenes/bake_boost_shots.gd'
## PNGs land in res://exports/boost_shots/ (gitignored); the docs' Export page
## comparison (docs/site/assets/export-boost-*.png) is composed from them by
## tools/boost_contact.py.
extends SceneTree

const SETTLE := 40
const OUT := "res://exports/boost_shots"
const PRESETS := ["dusk", "day"]

## name -> [camera position, look-at target]
const POSES := {
	"brazier": [Vector3(-0.6, 1.5, 5.6), Vector3(-3.5, 1.2, 3.4)],
	"decal": [Vector3(3.2, 2.4, 6.8), Vector3(0.0, 0.0, 1.8)],
	"plaza": [Vector3(0.0, 1.6, 6.5), Vector3(-2.0, 1.4, -6.0)],
	"waterfall": [Vector3(-2.6, 1.7, 2.6), Vector3(-7.0, 1.9, -1.2)],
}

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	DisplayServer.window_set_size(Vector2i(1600, 900))
	var dir := ProjectSettings.globalize_path(OUT)
	DirAccess.make_dir_recursive_absolute(dir)
	for preset: String in PRESETS:
		for boost in [1.0, 2.0]:
			var err := _export(preset, boost)
			print("[boost] export %s boost %.0f: %s" % [preset, boost, error_string(err)])
			if err != OK:
				quit(1)
				return
		_print_bake_stats(preset)
		var cam := Camera3D.new()
		cam.fov = 70.0
		root.add_child(cam)
		cam.current = true
		for mode in ["b1", "b2", "hw2x"]:
			var scene := _consume(_glb(preset, 2.0 if mode == "b2" else 1.0), preset, mode == "hw2x")
			root.add_child(scene)
			for pose_name: String in POSES:
				var pose: Array = POSES[pose_name]
				cam.position = pose[0]
				cam.look_at(pose[1])
				for i in range(SETTLE):
					await process_frame
				var img := root.get_viewport().get_texture().get_image()
				img.save_png(dir.path_join("%s_%s_%s.png" % [preset, pose_name, mode]))
			root.remove_child(scene)
			scene.free()
		cam.free()
		_print_image_stats(preset, dir)
	print("[boost] done")
	quit(0)

func _glb(preset: String, boost: float) -> String:
	return "%s/demo_%s_boost%d.glb" % [OUT, preset, int(boost)]

func _export(preset: String, boost: float) -> Error:
	var demo := AlphaDemoMapBuilder.build_demo_scene(false, preset)
	AlphaDemoMapBuilder._flush_paint_textures(demo)
	AlphaDemoMapBuilder._set_owner_recursive(demo, demo)
	# The same settings retro_bake_iterate / the builder's retro export use.
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
	settings.ambient_color = PBEnvironment.get_preset(preset)["ambient_color"]
	settings.bake_boost = boost
	var err := PBMapExporter.export_map(demo, _glb(preset, boost), settings)
	demo.free()
	return err

func _consume(glb: String, preset: String, hw2x: bool) -> Node3D:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(glb, state) != OK:
		push_error("parse failed: %s" % glb)
		return Node3D.new()
	var scene := doc.generate_scene(state) as Node3D
	PBMapExporter.apply_baked_vertex_colors(scene)
	for light in scene.find_children("*", "Light3D", true, false):
		(light as Light3D).visible = false
	PBEnvironment.apply_retro_display(scene, preset)
	if hw2x:
		_double_after_texture(scene)
	return scene

## The hardware modulate-2x stage on the Godot display: albedo x2 multiplies
## AFTER the texture x vertex-colour product, so the result is
## min(2 tex light, 1) (probed: a 0.502 texture under light 0.75 reads 0.753,
## above the texture itself). Only BAKED surfaces get it — an unlit surface's
## all-white colours stand for 1.0, which a 2x pipeline would store as 0.5.
func _double_after_texture(scene: Node) -> void:
	for node in scene.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		for s in range(mi.mesh.get_surface_count()):
			if not _surface_is_baked(mi.mesh, s):
				continue
			var mat := mi.get_active_material(s) as BaseMaterial3D
			if mat == null:
				continue
			var dup := mat.duplicate() as BaseMaterial3D
			dup.albedo_color = Color(mat.albedo_color.r * 2.0, mat.albedo_color.g * 2.0,
					mat.albedo_color.b * 2.0, mat.albedo_color.a)
			mi.set_surface_override_material(s, dup)

func _surface_is_baked(mesh: Mesh, s: int) -> bool:
	if (mesh.surface_get_format(s) & Mesh.ARRAY_FORMAT_COLOR) == 0:
		return false
	var cols: PackedColorArray = mesh.surface_get_arrays(s)[Mesh.ARRAY_COLOR]
	for c in cols:
		if c.r < 0.999 or c.g < 0.999 or c.b < 0.999:
			return true
	return false

## Where boost 2 and hardware modulate-2x CAN differ: baked channel values
## above 0.5 in the boost-1 bake (the boost saturates them at the texture's
## colour; the hardware draws them up to 2x brighter).
func _print_bake_stats(preset: String) -> void:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(_glb(preset, 1.0), state) != OK:
		return
	var scene := doc.generate_scene(state)
	var total := 0
	var above := 0
	var vert_above := 0
	var verts := 0
	var sum := 0.0
	for node in scene.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null or String(mi.name).begins_with("Collider_"):
			continue
		for s in range(mi.mesh.get_surface_count()):
			if not _surface_is_baked(mi.mesh, s):
				continue
			for c: Color in mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_COLOR]:
				verts += 1
				var any := false
				for v in [c.r, c.g, c.b]:
					total += 1
					sum += v
					if v > 0.5:
						above += 1
						any = true
				if any:
					vert_above += 1
	scene.free()
	print("[boost] %s bake: %d baked vertices, mean light %.3f; channels > 0.5: %.1f%%, vertices with any channel > 0.5: %.1f%%"
			% [preset, verts, sum / maxi(total, 1), 100.0 * above / maxi(total, 1), 100.0 * vert_above / maxi(verts, 1)])

func _print_image_stats(preset: String, dir: String) -> void:
	for pose_name: String in POSES:
		var imgs := {}
		for mode in ["b1", "b2", "hw2x"]:
			imgs[mode] = Image.load_from_file(dir.path_join("%s_%s_%s.png" % [preset, pose_name, mode]))
		var w: int = imgs["b1"].get_width()
		var h: int = imgs["b1"].get_height()
		var luma := {"b1": 0.0, "b2": 0.0, "hw2x": 0.0}
		var differ := 0
		var brighter := 0
		var n := 0
		for y in range(0, h, 3):
			for x in range(0, w, 3):
				n += 1
				for mode in luma:
					var c: Color = imgs[mode].get_pixel(x, y)
					luma[mode] += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
				var b2: Color = imgs["b2"].get_pixel(x, y)
				var hw: Color = imgs["hw2x"].get_pixel(x, y)
				var d := maxf(absf(b2.r - hw.r), maxf(absf(b2.g - hw.g), absf(b2.b - hw.b)))
				if d > 8.0 / 255.0:
					differ += 1
					if hw.get_luminance() > b2.get_luminance():
						brighter += 1
		print("[boost] %s %-9s mean luma b1 %.3f  b2 %.3f  hw2x %.3f | b2 vs hw2x: %.1f%% of pixels differ by > 8/255 (%.1f%% of those brighter on hw2x)"
				% [preset, pose_name, luma["b1"] / n, luma["b2"] / n, luma["hw2x"] / n,
				100.0 * differ / n, 100.0 * brighter / maxi(differ, 1)])
