## GUT post-run hook (run_tests.sh passes it with -gpost_run_script): reports
## the run's memory figures so the runner can fail a suite that creeps toward
## the guard's memory cap BEFORE it is OOM-killed mid-run. An OOM kill names
## whichever test happened to tip it over (v0.9.182: a 60 m decal test died
## for memory two unrelated suites had retained), and the truncated log hides
## the summary.
##
## Static memory is what Godot itself allocated (images, meshes, scripts); the
## process also carries the engine, the .NET runtime and the allocator's
## overhead, which is why the runner's budget is a fraction of the cap.
extends GutHookScript

func run() -> void:
	print("PB_MEMORY_PEAK_MB=%d" % (OS.get_static_memory_peak_usage() / 1048576))
	print("PB_MEMORY_END_MB=%d" % (OS.get_static_memory_usage() / 1048576))
	# The splat caches must not outlive their materials: after a final sweep,
	# what is left is the live working set, and nothing may sit queued for a
	# frame that a headless run never draws.
	PBSplat.prune_image_cache()
	print("PB_SPLAT_IMAGE_CACHE=%d" % PBSplat._cpu_image_cache.size())
	print("PB_SPLAT_PENDING_UPLOADS=%d" % PBSplat._pending_uploads.size())
