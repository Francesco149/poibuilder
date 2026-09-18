# PoiBuilder — Worker Orientation

You are implementing part of **PoiBuilder** (a ProBuilder-style mesh builder for
Godot, plugin folder `addons/poibuilder/`), including its retro pipeline
(exporters + a PSP homebrew renderer). The installed engine is **Godot 4.7**.

## Read the topic docs for your area BEFORE writing code

Everything about how this plugin actually works lives in `.pi/orientation/`.
It exists because agents repeatedly re-implemented behavior that was already
there (gizmo orientation, draw-on-surface placement, the overlay header) and
broke it. Do not be the next one.

| If you touch… | Read first |
|---|---|
| anything at all | `orientation/architecture.md` |
| selection, modes, picking, gizmo, drags, UV sync | `orientation/selection.md` (MANDATORY — the #1 source of reverted work) |
| extrude/inset/bevel/bridge/weld/any mesh op | `orientation/mesh_ops.md` |
| tests, or claiming anything is done | `orientation/testing.md` |
| the retro pipeline, PSP, exporters | `orientation/retro.md` |
| anything, before you invent a workaround | `orientation/footguns.md` |

## Project Layout

```
/opt/src/newbuilder/
+-- project/                    # Godot project root
|   +-- project.godot
|   +-- addons/poibuilder/      # THE PLUGIN (your work goes here)
|   |   +-- plugin.cfg
|   |   +-- poibuilder_plugin.gd   # EditorPlugin entry point
|   |   +-- core/               # Data model, math, topology, splat/paint data
|   |   +-- editor/             # Editor integration (gizmo plugin, toolbar,
|   |   |                       #   element editor, tool bridge, picking,
|   |   |                       #   shape creator, grid, actions, selection)
|   |   +-- commands/           # Undo/redo command pattern
|   |   +-- shapes/             # Primitive generators + shape params
|   |   +-- mesh_ops/           # PBMeshOps: extrude/inset/merge/weld/cut/...
|   |   +-- materials/          # Default material, textures, splat/decal shaders
|   |   +-- export/             # THE RETRO PIPELINE: map exporter, tile/light
|   |   |                       #   bakers, colliders, the .pbm writer
|   |   +-- gui/                # Docks (material/UV, paint, stamp) + overlay
|   |   +-- debug/              # PBLogger, PBTelemetry
|   +-- tests/                  # GUT test scripts (your tests go here)
|   +-- test_scenes/            # editor_gui_test (real-editor event harness),
|   |                           #   human sign-off scenes, showcase, viewer
+-- SPECIFICATION.md            # Full ProBuilder behaviour spec (37k lines)
+-- SPEC_RETRO_FORMAT.md        # The .pbm format + consumer performance rules
+-- UNITY-GODOT-MAPPING.md      # Unity->Godot API translation reference
+-- CLAUDE.md                   # Current status, conventions
+-- CHANGELOG.md                # Version-by-version history (canonical record)
+-- .pi/orientation/            # THE implementation docs (topic files, above)
+-- retro_engine/               # Retro pipeline: viewers, PSP homebrew, tools
|   +-- RETRO-AUTHORING.md     # Authoring recipes for the retro target
|   +-- psp/HARDWARE-TESTING.md, OPTIMIZATION.md  # Device measurement + engine
+-- reports/                    # Spec extraction reports (historical)
```

## Rules that apply to every worker

1. **Tests**: `./run_tests.sh` from the repo root is the only accepted way to
   RUN or to CLAIM them (raw GUT reports green even when test scripts fail to
   parse). `./run_tests.sh -gselect=test_x.gd` is for iterating only and does
   not count as "tests pass". See `orientation/testing.md`.
2. **Viewport behavior is only real if the GUI harness or a human saw it.**
   `./run_gui_tests.sh` boots a REAL editor and drives synthesized mouse/key
   events. GUT alone cannot see this layer; twice, viewport fixes that
   "looked right" shipped unverified and were not fixes.
3. **Performance claims need a PSP.** `./run_psp_hw.sh` over USB is the only
   source of truth; PPSSPP and the desktop viewers are for "does it crash" and
   "does it look right" only. Never write a perf claim that was not measured
   on hardware, and if no PSP is connected, say so rather than assuming.
4. **Never commit regenerable artifacts.** No video/audio, no rendered frame
   sequences, no screenshots, no map exports (`.glb`/`.pbm`), no built PSP
   binaries (`EBOOT.PBP`, `.prx`, `PoiRetro_PSP.zip`), no generated scenes or
   extracted textures, no logs, no test reports — even when the file is small.
   The root `.gitignore` lists every one of them; they once cost ~100 MB of
   history and the history was rewritten. About to `git add` a binary over
   ~100 KB? Stop — it is almost certainly an artifact. Put build output in a
   gitignored directory (`showcase_video/bake/`, `showcase_video/out/`) or
   `/tmp`, and commit only the SOURCE that makes it.
   ONE exception (v0.9.132): `docs/site/assets/` — the documentation
   screenshots and clip loops — IS committed. The CI workflows build the
   Pages site and the nightly addon bundle from those files, and the
   showcase-video bake they were extracted from cannot run on a CI runner.
   They are source material now: regenerate locally with
   `./docs/site/build.sh --assets` and commit the improved shots when they
   change. Everything downstream of them (`docs/site/out/`,
   `addons/poibuilder/docs-site/`) stays gitignored.
5. **Version bump every round; commit trailer every commit.** Bump `VERSION`
   (poibuilder_plugin.gd), `PLUGIN_VERSION` (pb_editor.gd), and plugin.cfg's
   `version` TOGETHER at the start of every fix/UX round — the overlay title
   is how the human verifies they are running the new build (rounds 2–3 of
   v0.9.0 skipped this and shipped fixes the human never received). Every
   commit ends with a blank line plus a `Co-authored-by` trailer naming the
   model that wrote it:
   `Co-authored-by: <provider-slug>/<model-slug> <<provider-slug>+<model-slug>@users.noreply.github.com>`
   — derive the slugs from YOUR OWN model id; never reuse another model's
   trailer.
5. **Read before you write**: this file, the topic docs for your area, and
   `CLAUDE.md`. If a task says "X is broken/missing", FIRST grep the code and
   `CHANGELOG.md` for X — the behavior usually already exists and was
   regressed, not never-written. Re-implementing it in parallel is the
   single most expensive failure mode this project has had.
6. **Verify engine APIs before using them.** The `../godot` checkout is
   4.8-dev but the installed engine is 4.7.2: check
   `../godot/doc/classes/*.xml` and (for editor internals) the C++ source
   itself. War stories: `EditorSettings.save()` does not exist;
   `EditorUndoRedoManager.add_do_method` takes different args than
   `UndoRedo`; `set_cull_mask_value()` silently rejects layers > 20;
   `Node3D.set_subgizmo_selection` REPLACES the whole selection with ONE id
   (see `orientation/selection.md` before fighting that).

## Reference Repos

- `../probuilder-ref/` — Unity ProBuilder v6.1.2 C# source (88k lines).
  Use to cross-reference algorithms and UX behavior when the spec isn't
  clear enough. (Check how ProBuilder does it before inventing; the same
  goes for Blender's source for mesh-op geometry.)
- `../cyclops-ref/` — Cyclops Level Builder Godot plugin. Pattern reference
  for Godot editor integration.
- `../godot/` — Godot engine source. First-class lookup for engine internals
  (how subgizmo selection, the transform gizmo, and editor tool buttons
  actually work — several plugin mechanisms depend on exact engine
  behavior, documented in the topic docs).

## Coding Standards

### GDScript Rules
- ALL scripts that run in editor: `@tool` annotation at top
- ALL classes: `class_name` declaration
- ALL public functions: full type annotations (params + return)
- ALL `@export` vars: typed
- Prefix: `PB` for class names (`PBMeshData`, `PBFace`, `PBMath`)
- Prefix: `pb_` for filenames (`pb_mesh_data.gd`, `pb_face.gd`)
- Prefix: `Cmd` for command classes (`CmdMoveFaces`)

### Logging
Every significant operation logs through PBLogger (NEVER `push_error()` /
`push_warning()` / bare `print()`):
```gdscript
var logger: PBLogger = PBLogger.new()
logger.info("mesh_ops", "Extruded %d faces" % count)
logger.debug("selection", "Picked vertex %d at %s" % [idx, pos])
```
Categories: `plugin`, `core`, `mesh_ops`, `selection`, `undo`, `tools`,
`render`, `io`, `telemetry`.

### Undo/Redo Pattern
```gdscript
# Every mesh modification goes through a command:
class_name CmdExtrudeFaces extends RefCounted

var command_name: String = "Extrude Faces"
var _snapshot: PBMeshData  # Pre-operation snapshot
var _target_path: NodePath

func add_to_undo_manager(undo: EditorUndoRedoManager) -> void:
    undo.create_action(command_name)
    undo.add_do_method(self, "do_it")
    undo.add_undo_method(self, "undo_it")
    undo.commit_action()
```
Topology-rewriting ops undo via WHOLE-MESH snapshots (`CmdMeshOp` with
before/after) — per-index payloads do not survive element insertion/removal.

### Coordinate System
- Godot is **right-handed Y-up** (Unity is left-handed)
- `Vector3.FORWARD = (0, 0, -1)` (Unity: `(0, 0, 1)`)
- Triangle winding: INTERNAL data is CCW-from-outside (Unity convention);
  **Godot renders CLOCKWISE front faces** (this exact doc line used to say
  "counter-clockwise" and caused two shipped winding bugs).
  `to_array_mesh()` reverses index order; normals are NEVER negated.
  Ground truth + regression tests: `project/tests/test_pb_winding.gd`.
- UV origin: bottom-left in both engines (no conversion needed)

### Editor Integration Rules (mandatory)
- Do NOT hand-roll viewport input, picking, rubber-band selection, marquees,
  drag state machines, or transform gizmos. All element interaction goes
  through the native editor via `editor/pb_gizmo_plugin.gd` subgizmos; the
  plugin's mouse path is pass-through. Interception is what broke gizmo
  drags in earlier rounds.
- Editor-only base classes (EditorNode3DGizmoPlugin etc.) cannot be
  instantiated in headless runs — keep logic in runtime-safe classes
  (`pb_element_editor.gd` is the template: the gizmo plugin is a thin
  adapter, all decisions live in the runtime-safe class).

## Testing

```bash
# From the repo root — the only accepted way to run/claim tests:
/opt/src/newbuilder/run_tests.sh          # full suite
/opt/src/newbuilder/run_tests.sh -gselect=test_pb_selection.gd   # iterating
./run_gui_tests.sh                        # real-editor event harness
```

Exit code 0 = pass. The runner fails on: editor-boot script errors, GUT
nonzero exit, ANY script error inside the run, and a suite-count mismatch
(a `test_*.gd` file on disk that GUT never discovered — the silent-skip
hole). A filtered `-gselect` run skips the count guard by definition.

**IMPORTANT:** `project.godot` has `run/main_scene` set to `res://main.tscn`.
Do NOT remove this — without it Godot pops a modal "no main scene" error
that blocks headless execution.

### Test Requirements
- Your test MUST pass via `run_tests.sh` (full suite) before you declare done
- Check the summary: the on-disk test file count must equal the discovered suite count
- Test file: `project/tests/test_<feature>.gd`, extends GutTest
- Deterministic — no random seeds, no timing dependencies
- Editor-dependent tests skip in headless:
  ```gdscript
  func _init():
      if DisplayServer.get_name() == "headless":
          skip_script = "Requires editor UI"
  ```
- A test whose FIXTURE is missing must `fail_test(...)`, never
  `pass_test("skipping")` — vacuous passes mask fixture regressions.

## Do NOT

- Modify files outside your assigned scope
- Create new directories without checking if they exist
- Use `push_error()` / `push_warning()` / bare `print()` — use PBLogger
- Use GDScript `log()` as a method name (it's a built-in for natural log)
- Skip writing tests
- Leave `TODO` or `FIXME` comments — implement fully or note in your output
- Assume editor APIs work in headless mode — guard with DisplayServer checks
- Hand-roll UI widgets the editor already has (numeric drag fields etc. —
  use the same method as the built-in Inspector)
- Silently degrade user parameters to make an algorithm succeed (the bevel
  "distance ping-pong" bug) — clamp deterministically and surface the limit
- Ship bare text-only action buttons on the toolbar — bar buttons MUST always be
  SVG icons (16x16 vector line style in icons/) unless there is a specific
  load-bearing reason for text (e.g. dynamic state readouts like Space, snap step
  label, or numeric inputs).
