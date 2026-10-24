## GUT pre-run hook (run_tests.sh passes it with -gpre_run_script): the suite
## is a running SceneTree outside the editor, so every scrolling PBMesh a test
## put in the tree would start PBScrollRuntime and animate its material's
## uv1_offset under the test (exports read that offset). The suite is not a
## game: the runtime is off, and test_pb_scroll_runtime.gd turns it on for
## itself.
extends GutHookScript

func run() -> void:
	PBScrollRuntime.enabled = false
