# Testing — What Counts As Evidence

## The gates (`run_tests.sh`, the only accepted runner)

1. Editor boot under `--headless --editor` refreshes the class cache (new
   `class_name` scripts are only registered by a filesystem scan) and fails
   on any SCRIPT ERROR — this also boots the plugin, so registration errors
   are caught.
2. Full GUT run (`-gdir=res://tests -ginclude_subdirs`), fails on nonzero.
3. FAILS if any SCRIPT ERROR appears in the run output even when GUT is
   green (GUT silently skips unparseable test scripts — this exact hole let
   the Phase 6 normals bug reach a human).
4. Silent-skip guard: count of `test_*.gd` on disk (recursive) must equal
   the `<testsuite>` count in `tests/results.xml`. (The old guard disabled
   itself via `grep -c ... || echo 0` producing two lines — fixed; don't
   reintroduce the pattern.)

`./run_tests.sh -gselect=<filter>` passes GUT args through for ITERATING.
A filtered run skips gate 4 by definition and NEVER counts as "tests pass" —
the final claim is always a full-suite run. Raw `godot -s gut_cmdln.gd`
invocations bypass ALL FOUR gates; 37 of 77 archived sessions did this —
don't.

The GUI layer (`run_gui_tests.sh`, `project/test_scenes/editor_gui_test.gd`)
boots a REAL editor under Xvfb and drives synthesized mouse/key events
through the input pipeline, asserting selection/creation/gizmo outcomes.
GUT cannot see this layer; twice, viewport fixes that "looked right" shipped
unverified and were not fixes. Any viewport-interaction change (picking,
mode switching, drags, creation, modals) extends this harness with a case —
copy an existing block (mouse: `_window_pos`/`_motion`/`_click`; keys:
`_press_and_release_key`; assertions read `plugin.editor.*` and
`gizmo.get_subgizmo_selection()`). Known engine limit: the transform gizmo
itself cannot be engaged by synthesized events on 4.7.2 (hit-test internals)
— drag deliveries are driven through the plugin instead; state that
limitation when a change depends on engine-side gizmo composition.

Interactive launchers need an X display: this workstation is pure Wayland
(niri), `xdisplay.sh` resolves one (reuse DISPLAY / xwayland-satellite :0 /
xvfb-run fallback). A private `Xwayland :99` has no compositor behind it —
the program renders into a window nobody can see (the entire "no window
appears" bug).

## The fast loop (and its traps)

- **Iterate with `-gselect`**: `./run_tests.sh -gselect=test_pb_splat_and_stamp.gd`
  (~15 s) while changing one area; the full suite (~2 min) is for the final
  claim. The runner names the failing tests on a failure, and when the suite
  did NOT finish it prints the last suite/test reached plus the likely cause
  (crash/OOM inside the guard's cap, or a file edited mid-run).
- **Never edit a test/addon file while a suite is running.** GUT loads the
  scripts (and the class cache refresh boots the editor over them) as it goes;
  a save mid-run shows up as a phantom "a test script was skipped / suite count
  mismatch" failure. Edit, then run.
- **The guard caps memory** (~2 GB by default; `GUARD_MEM=4G ./run_tests.sh` to
  raise). A test that allocates huge images (multi-thousand-pixel splat/decal
  windows, per-growth reallocations) can OOM the run: the symptom is a
  TRUNCATED log and "did NOT finish", not a failing assertion. Keep test
  fixtures small and let the feature's own budget tests cover the big cases.
- **Headless probe scripts** (throwaway investigations, no repo litter):
  ```bash
  godot-mono --headless --path project -s /tmp/probe.gd      # logic probes
  xvfb-run -a godot-mono --rendering-driver opengl3 --path project -s /tmp/rendered.gd   # renders
  ```
  An ABSOLUTE path works — the script does not have to live in `res://`. Add
  `-s` scripts to a SceneTree with `await process_frame` and call `quit()` at
  the end of the async chain (a `quit()` in `_init` kills the coroutine before
  it runs).
- **New image assets need an import pass before a probe can `load()` them**:
  `godot-mono --headless --path project --editor --quit-after 120`. Without it
  `load()` hands back a null texture and you debug a phantom (a material with
  no albedo renders solid white). The runner's step 1 does this for the suite.
- Rendered probes are how visual claims get evidence: `project/test_scenes/`
  keeps the durable ones (`decal_probe.gd`, `emitter_probe.gd`), each printing
  the numbers behind what it drew.

## Writing tests

- Location `project/tests/test_<feature>.gd`, `extends GutTest`,
  deterministic (no random seeds, no timing).
- Model existing suites: `test_pb_edge_loop_select.gd` (seed+expansion
  selection semantics), `test_pb_element_gestures.gd` (drag deliveries +
  `GestureUndoSpy`), `test_pb_selection_conversion.gd` (mode conversion),
  `test_pb_bevel.gd` (watertightness invariants), `test_pb_winding.gd`
  (winding ground truth).
- Editor-dependent tests skip in headless via `skip_script` in `_init`.
- A missing FIXTURE is `fail_test(...)`, never `pass_test("skipping")` —
  vacuous passes mask fixture regressions (fixed in
  `test_pb_edge_loop_ring.gd`; keep it fixed).
- `project.godot`'s `run/main_scene` must stay `res://main.tscn` (without
  it Godot pops a modal "no main scene" error that blocks headless runs).
- Build artifacts (e.g. the showcase GLB some export tests read) are NOT
  tracked; a test that reads one `pending()`s on a fresh checkout and runs
  after the exporting test has run once. Document this in the test if you
  add another.

## Claiming done

- Full `./run_tests.sh` output, with your suite among the discovered count.
- If the change is viewport-visible: `./run_gui_tests.sh` (plus the new
  case), or say plainly that it needs human sign-off and provide a
  step-by-step walkthrough for the human.
- NEVER claim "tests pass" without the runner output. "Show proof, not
  claims" — a fabricated verification is worse than none (the extraction
  phase's `--verify` checker once caught 8 fabricated quotes in one report).
- Console SCRIPT ERROR/WARN in any test output is a failure, not noise.

## UID policy

`*.uid` files are gitignored; Godot regenerates them. Orphaned `.uid` files
(whose `.gd` was deleted) are local clutter — 59 were swept in v0.9.105;
don't hand-create `.uid` files, and don't commit them.
