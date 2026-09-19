## export_bench_variants.gd — export the frame-pacing bench's GLB variants
## (the retro bake and the modern bake of the alpha demo map) headlessly.
## Run from the project directory:
##
##   godot --headless -s <path-to-this-file>
##
## Used by run_bench.sh (Linux, inside the guard container) and
## run_bench_win.sh (Windows, native Godot). The freshly written .glb files
## still need an import pass (`--headless --editor --quit-after 100`) before
## a plain run can load() them — the launchers do that part.
extends SceneTree

func _init() -> void:
	var results := AlphaDemoMapBuilder.export_bench_variants()
	for k in results:
		print("export %s: %s" % [k, error_string(results[k])])
	var failed := false
	for k in results:
		if results[k] != OK:
			failed = true
	quit(1 if failed else 0)
