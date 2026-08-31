# ProBuilder Godot — Worker Orientation

You are implementing part of a ProBuilder clone as a Godot 4.3+ editor plugin.

## Project Layout

```
/opt/src/newbuilder/
├── project/                    # Godot project root
│   ├── project.godot
│   ├── addons/probuilder/      # THE PLUGIN (your work goes here)
│   │   ├── plugin.cfg
│   │   ├── probuilder_plugin.gd
│   │   ├── core/               # Data model, math, mesh ops
│   │   ├── editor/             # Editor integration, tools
│   │   ├── commands/           # Undo/redo command pattern
│   │   ├── shapes/             # Shape generators
│   │   ├── gui/                # Dock panels, dialogs
│   │   ├── shaders/            # Overlay and picking shaders
│   │   ├── debug/              # PBLogger, PBTelemetry, PBDebugDock
│   │   └── export/             # OBJ, PLY, STL exporters
│   ├── tests/                  # GUT test scripts (your tests go here)
│   └── test_scenes/            # Human verification scenes
├── SPECIFICATION.md            # Full ProBuilder spec (37k lines)
├── UNITY-GODOT-MAPPING.md      # Unity→Godot API translation reference
├── IMPLEMENTATION.md           # Phased implementation plan with IU details
└── reports/                    # Spec extraction reports (JSON)
```

## Reference Repos

- `../probuilder-ref/` — Unity ProBuilder v6.1.2 C# source (88k lines).
  Use to cross-reference algorithms when the spec isn't clear enough.
- `../cyclops-ref/` — Cyclops Level Builder Godot plugin. Use as a pattern
  reference for Godot editor integration. Key files:
  - `godot/addons/cyclops_level_builder/cyclops_level_builder.gd` — main plugin
  - `godot/addons/cyclops_level_builder/commands/` — undo/redo pattern
  - `godot/addons/cyclops_level_builder/nodes/cyclops_block.gd` — mesh node
  - `godot/addons/cyclops_level_builder/math/convex_volume.gd` — mesh data

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
- Triangle winding: **counter-clockwise** for front faces (Unity: clockwise)
- UV origin: bottom-left in both engines (no conversion needed)

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
cd /opt/src/newbuilder/project

# Run all tests
GODOT_DISABLE_LEAK_CHECKS=1 godot-mono --headless \
  -s addons/gut/gut_cmdln.gd -gdir=res://tests -ginclude_subdirs -gexit

# Run one test file
GODOT_DISABLE_LEAK_CHECKS=1 godot-mono --headless \
  -s addons/gut/gut_cmdln.gd -gtest=res://tests/test_my_feature.gd -gexit
```

Exit code 0 = all pass. Exit code 1 = failures.

### Test Requirements
- Your test MUST pass headlessly before you declare done
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
