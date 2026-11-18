## Headless entry point for ./run_seashore.sh: builds the seashore map,
## exports res://exports/seashore.pbm and saves the editor scene.
##   godot-mono --headless --path project -s res://test_scenes/seashore_export.gd
extends SceneTree


func _init() -> void:
	var t0 := Time.get_ticks_msec()
	var err := SeashoreMapBuilder.export_pbm()
	print("seashore export: ", error_string(err), " in ", Time.get_ticks_msec() - t0, " ms")
	var err2 := SeashoreMapBuilder.save_scene("res://test_scenes/seashore_map.tscn")
	print("seashore scene save: ", error_string(err2))
	quit(0 if err == OK else 1)
