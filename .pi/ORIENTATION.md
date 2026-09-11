# PoiBuilder — Worker Orientation

You are implementing part of **PoiBuilder** (a ProBuilder-style mesh builder for
Godot, plugin folder `addons/poibuilder/`), including its retro pipeline
(exporters + a PSP homebrew renderer). The installed engine is **Godot 4.7**.

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
|   |   |                       #   shape creator, grid, actions)
|   |   +-- commands/           # Undo/redo command pattern
|   |   +-- shapes/             # Primitive generators + shape params
|   |   +-- mesh_ops/           # PBMeshOps: extrude/inset/merge/weld/cut/...
|   |   +-- materials/          # Default material, textures, splat/decal shaders
|   |   +-- export/             # THE RETRO PIPELINE: map exporter, tile/light
|   |   |                       #   bakers, colliders, PBPbmConverter (.pbm)
|   |   +-- gui/                # Docks (material/UV, paint, stamp) + overlay
|   |   +-- debug/              # PBLogger, PBTelemetry
|   +-- tests/                  # GUT test scripts (your tests go here)
|   +-- test_scenes/            # Human sign-off scenes, showcase, retro viewer
+-- SPECIFICATION.md            # Full ProBuilder behaviour spec (37k lines)
+-- SPEC_RETRO_FORMAT.md        # The .pbm format + consumer performance rules
+-- UNITY-GODOT-MAPPING.md      # Unity->Godot API translation reference
+-- CLAUDE.md                   # Current status, conventions, round history
+-- IMPLEMENTATION.md           # Historical IU plan (not the current state)
+-- retro_engine/               # Retro pipeline: exporters, viewers, PSP homebrew
|   +-- pbm_conv.py            # Python GLB->PBM oracle (parity reference)
|   +-- RETRO-AUTHORING.md     # Authoring recipes for the retro target
|   +-- psp/HARDWARE-TESTING.md, OPTIMIZATION.md  # Device measurement + engine
+-- reports/                    # Spec extraction reports (historical)
```

## Rules that apply to every worker

1. **Tests**: `./run_tests.sh` from the repo root is the only accepted way to
   run them (raw GUT reports green even when test scripts fail to parse).
2. **Performance claims need a PSP.** `./run_psp_hw.sh` over USB is the only
   source of truth; PPSSPP and the desktop viewers are for "does it crash" and
   "does it look right" only. Never write a perf claim that was not measured on
   hardware, and if no PSP is connected, say so rather than assuming.
3. **Read before you write**: `CLAUDE.md` (conventions + the round history that
   explains why the code looks unusual), then the architecture notes and the
   retro docs listed above for the area you are touching.

## Reference Repos

- `../probuilder-ref/` — Unity ProBuilder v6.1.2 C# source (88k lines).
  Use to cross-reference algorithms when the spec isn't clear enough.
- `../cyclops-ref/` — Cyclops Level Builder Godot plugin. Use as a pattern
  reference for Godot editor integration. Key files:
  - `godot/addons/cyclops_level_builder/cyclops_level_builder.gd` — main plugin
  - `godot/addons/cyclops_level_builder/commands/` — undo/redo pattern
  - `godot/addons/cyclops_level_builder/nodes/cyclops_block.gd` — mesh node
  - `godot/addons/cyclops_level_builder/math/convex_volume.gd` — mesh data

- `../godot/` — Godot engine source code (4.7.2). Use when you need to
  understand engine internals — e.g. how ArrayMesh surfaces work, how
  EditorPlugin lifecycle methods are called, or how ImmediateMesh renders.

## Key Documents to Read

1. **UNITY-GODOT-MAPPING.md** — Read FIRST. Maps every Unity concept to Godot.
2. **IMPLEMENTATION.md** — Your IU's phase and dependencies.
3. **SPECIFICATION.md** — The spec sections relevant to your IU (line ranges
   given in your task prompt).

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
Every significant operation must log through PBLogger:
```gdscript
# Get logger from plugin or create locally for tests
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

func do_it() -> void:
    # Apply the operation

func undo_it() -> void:
    # Restore _snapshot
```

### Coordinate System
- Godot is **right-handed Y-up** (Unity is left-handed)
- `Vector3.FORWARD = (0, 0, -1)` (Unity: `(0, 0, 1)`)
- Triangle winding: INTERNAL data is CCW-from-outside (Unity convention);
  **Godot renders CLOCKWISE front faces** (see the ArrayMesh docs note —
  this is the opposite of what you'd guess, and this exact doc line used to
  say "counter-clockwise", which caused two shipped winding bugs).
  `to_array_mesh()` reverses index order; normals are NEVER negated.
  Ground truth + regression tests: `project/tests/test_pb_winding.gd`.
- UV origin: bottom-left in both engines (no conversion needed)

### Editor Integration Rules (mandatory — see IMPLEMENTATION.md gates)
- Do NOT hand-roll viewport input, picking, rubber-band selection, marquees,
  or drag state machines. All element interaction goes through the native
  editor via `editor/pb_gizmo_plugin.gd` subgizmos; the plugin's mouse path
  is pass-through.
- Editor-only base classes (EditorNode3DGizmoPlugin etc.) cannot be
  instantiated in headless runs — keep logic in runtime-safe classes
  (`pb_element_editor.gd` is the template).
- The `../godot` checkout is 4.8-dev but the installed engine is 4.7.2.
  Verify editor APIs against `../godot/doc/classes/*.xml` and a real editor
  boot before using them.

## Testing

### Writing Tests
```gdscript
# tests/test_my_feature.gd
extends GutTest

func test_something():
    var data = PBMeshData.new()
    # ... set up
    assert_eq(data.vertex_count(), 8, "Cube should have 8 vertices")
```

### Running Tests
```bash
# From the repo root — THE ONLY accepted way to run tests:
/opt/src/newbuilder/run_tests.sh

# It refreshes the class cache, runs GUT, fails on ANY script error, and
# fails if any test script was silently skipped. Raw GUT invocations report
# green even when test scripts fail to parse — never use them to claim done.
```

Exit code 0 = all pass. Exit code 1 = failures.

**IMPORTANT:** `project.godot` has `run/main_scene` set to `res://main.tscn`.
Do NOT remove this — without it Godot pops a modal "no main scene" error
that blocks headless execution. If you create new scenes, do not change the
main scene setting.

### Test Requirements
- Your test MUST pass via run_tests.sh before you declare done (GUT alone
  silently skips unparseable test scripts and still reports green)
- Check the run summary: your test file must appear in results.xml
- Test file goes in `project/tests/`
- Test file name: `test_<feature>.gd`
- Tests must be deterministic — no random seeds, no timing dependencies
- Tests that need the editor (GUI, docks) should skip in headless:
  ```gdscript
  var skip_script
  func _init():
      if DisplayServer.get_name() == "headless":
          skip_script = "Requires editor UI"
  ```

## Building Meshes in Godot

```gdscript
# Create an ArrayMesh from vertex data:
var arrays = []
arrays.resize(Mesh.ARRAY_MAX)
arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([...])
arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([...])
arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([...])
arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([...])

var mesh = ArrayMesh.new()
mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
# Each add_surface_from_arrays call = one submesh/material slot
```

## Do NOT

- Modify files outside your assigned IU scope
- Create new directories without checking if they exist
- Use `push_error()` / `push_warning()` — use PBLogger instead
- Use GDScript `log()` as a method name (it's a built-in for natural log)
- Skip writing tests
- Leave `TODO` or `FIXME` comments — implement fully or note in your output
- Assume editor APIs work in headless mode — guard with DisplayServer checks
