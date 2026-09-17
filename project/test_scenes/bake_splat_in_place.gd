## Bake Splat In Place — converts a scene's splat paint to baked tile textures.
##
## The "switch to lightmaps" path: after this runs, painted PBMeshes carry
## plain StandardMaterial3Ds with baked composite tiles, splat data is gone,
## and UV2 is free for a LightmapGI unwrap (Godot also auto-generates UV2 at
## bake time). Geometry UV1 is rewritten into tile slots — by design.
##
## Run inside the project that owns the scene (scratch/modern/main):
##   godot-mono --headless --path <proj> -s res://bake_splat_in_place.gd -- res://playground.tscn
extends SceneTree

func _init() -> void:
	var scene_path := ""
	var args := OS.get_cmdline_user_args()
	for a in args:
		if not a.begins_with("-"):
			scene_path = a
	if scene_path.is_empty():
		print("Usage: -s res://bake_splat_in_place.gd -- res://path/to/scene.tscn")
		quit(1)
		return
	if not ResourceLoader.exists(scene_path):
		print("Scene not found: ", scene_path)
		quit(1)
		return

	var ps: PackedScene = load(scene_path)
	if ps == null:
		print("Failed to load ", scene_path)
		quit(1)
		return
	var root := ps.instantiate()

	var baked := 0
	var skipped := 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is PBMesh:
			var report: Dictionary = PBTileBaker.bake_pb_mesh_in_place(node)
			if not report["ok"]:
				print("FAILED: ", node.name)
				_root_free(root)
				quit(1)
				return
			if report["had_splat"]:
				baked += 1
				print("baked %s: %d faces, %d materials, %d baked textures" %
						[node.name, report["faces"], report["materials"], report["baked_textures"]])
			else:
				skipped += 1

	print("done: %d mesh(es) baked, %d had nothing to bake" % [baked, skipped])
	if baked == 0:
		_root_free(root)
		quit(0)
		return

	var packed := PackedScene.new()
	var err := packed.pack(root)
	if err != OK:
		print("pack failed: ", error_string(err))
		_root_free(root)
		quit(1)
		return
	err = ResourceSaver.save(packed, scene_path)
	if err != OK:
		print("save failed: ", error_string(err))
		_root_free(root)
		quit(1)
		return
	print("saved ", scene_path, " — splat data cleared, UV2 free for lightmaps")
	_root_free(root)
	quit(0)

func _root_free(root: Node) -> void:
	root.free()
