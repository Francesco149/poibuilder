## bench_variants.gd — the ONE scene assembly for the benchmark's three
## variants of the alpha demo map, shared by every consumer that flies it:
##
##   pb          the POIBUILDER SCENE AS IS — editable PBMesh nodes, splat
##               shader, decals, realtime lights (the "godot modern" pipeline)
##   retro_glb   the RETRO-BAKED .glb — baked tile textures, lighting in
##               vertex colors, rendered unshaded (the consumer contract)
##   modern_glb  the MODERN .glb — authored materials with paint baked into
##               textures, realtime lights
##
## Shared by frame_pacing_bench.gd (the headless path bench) and fly_bench.gd
## (the interactive fly bench) so a number and a picture always describe the
## same scene. The consumer contracts live here too: the retro GLB's imported
## lights are HIDDEN (its lighting is in vertex colors — live lights would
## double-light) and its materials get albedo-from-COLOR_0 + unshaded via
## PBMapExporter.apply_baked_vertex_colors(); the modern GLB's shadow flags
## are RESTORED from the poi_shadow node extras (glTF lights cannot carry
## them); both get the display environment the export's extras name.
class_name BenchVariants

const VARIANT_NAMES := ["pb", "retro_glb", "modern_glb"]

## Human-readable names for HUDs and tables.
static func display_name(variant: String) -> String:
	match variant:
		"pb": return "PB scene as-is"
		"retro_glb": return "Retro-baked GLB"
		"modern_glb": return "Modern GLB"
	return variant

## Instantiates one variant and returns the map root (or null after printing
## why not). Prints a census line so every run is honest about what each
## variant contains.
static func load_variant(variant: String) -> Node3D:
	var path := ""
	match variant:
		"pb":
			path = "res://test_scenes/alpha_demo_map.tscn"
		"retro_glb":
			path = "res://exports/alpha_demo_retro_baked.glb"
		"modern_glb":
			path = "res://exports/alpha_demo_modern.glb"
		_:
			push_error("unknown variant '%s' (%s)" % [variant, ", ".join(VARIANT_NAMES)])
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
		census(inst, census)
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
		apply_to_lights(generated, func(l: Light3D) -> void:
			l.visible = false
			hidden[0] += 1)
		note = " (import lights hidden: %d — vertex-lit scene)" % hidden[0]
	else:
		# glTF lights carry no shadow flags; the exporter tags shadow-casting
		# lights with poi_shadow node extras. Restore the authored look.
		var restored := [0]
		apply_to_lights(generated, func(l: Light3D) -> void:
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
	census(generated, census2)
	print("[bench] variant=%s meshes=%d emitters=%d lights=%d%s" % [
		variant, census2["mesh"], census2["particles"], census2["lights"], note])
	return generated

static func apply_to_lights(node: Node, fn: Callable) -> void:
	if node is Light3D:
		fn.call(node)
	for c in node.get_children():
		apply_to_lights(c, fn)

static func census(node: Node, out: Dictionary) -> void:
	if node is MeshInstance3D:
		out["mesh"] += 1
	elif node is GPUParticles3D:
		out["particles"] += 1
	elif node is Light3D:
		out["lights"] += 1
	for c in node.get_children():
		census(c, out)
