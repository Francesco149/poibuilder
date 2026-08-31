# ProBuilder Godot Implementation Protocol

## Overview

This document defines the phased implementation plan for building a ProBuilder
clone as a Godot 4.3+ editor plugin. The work is decomposed into small,
independently testable implementation units (IUs) sized for Gemini 3.7 Flash
sub-agents. Each IU produces working code with headless smoke tests.

The plugin is named **ProBuilder** (internal class prefix: `PB`).

## Principles

1. **Small bites.** Each IU touches ≤5 files and takes ≤30 minutes for a
   Flash worker. No IU depends on more than 2 prior IUs.
2. **Headless testable.** Every IU includes a GDScript test runnable via
   `godot-mono --headless`. No focus stealing, no GUI windows.
3. **Human sign-off gates.** After each phase, a single command launches the
   editor with a pre-built test scene for visual verification.
4. **Debug-first.** Telemetry/logging infrastructure is built in Phase 0
   before any feature code. Every operation logs to a ring buffer inspectable
   via a debug dock.
5. **Cross-reference.** Workers consult `SPECIFICATION.md` for behavior,
   `UNITY-GODOT-MAPPING.md` for API translation, `../probuilder-ref/` for
   source details, and `../cyclops-ref/` for Godot plugin patterns.

## Directory Structure

```
newbuilder/
├── project/                          # Godot project root
│   ├── project.godot
│   ├── addons/
│   │   └── probuilder/              # The plugin
│   │       ├── plugin.cfg
│   │       ├── probuilder_plugin.gd # Main EditorPlugin entry
│   │       ├── core/                # Data model, math, mesh representation
│   │       │   ├── pb_mesh_data.gd  # PBMeshData Resource
│   │       │   ├── pb_face.gd       # PBFace Resource
│   │       │   ├── pb_edge.gd       # PBEdge
│   │       │   ├── pb_shared_vertex.gd
│   │       │   ├── pb_math.gd       # Math utilities
│   │       │   ├── pb_mesh_ops.gd   # Mesh operations (extrude, bevel, etc.)
│   │       │   └── pb_topology.gd   # WingedEdge, traversal
│   │       ├── editor/              # Editor integration
│   │       │   ├── pb_editor.gd     # Editor state, mode management
│   │       │   ├── pb_selection.gd  # Selection state + picking
│   │       │   ├── pb_input.gd      # Input handling
│   │       │   ├── pb_toolbar.gd    # Toolbar UI
│   │       │   ├── pb_overlay.gd    # Wireframe/selection overlay rendering
│   │       │   └── tools/           # Individual tools
│   │       │       ├── pb_tool.gd   # Base tool class
│   │       │       ├── pb_tool_move.gd
│   │       │       ├── pb_tool_rotate.gd
│   │       │       ├── pb_tool_scale.gd
│   │       │       ├── pb_tool_cut.gd
│   │       │       └── pb_tool_shape.gd
│   │       ├── commands/            # Undo/redo command pattern
│   │       │   ├── pb_command.gd    # Base command
│   │       │   ├── cmd_move_elements.gd
│   │       │   └── ...
│   │       ├── shapes/              # Shape generators
│   │       │   ├── pb_shape_cube.gd
│   │       │   ├── pb_shape_cylinder.gd
│   │       │   └── ...
│   │       ├── gui/                 # Dock panels, dialogs
│   │       │   ├── docks/
│   │       │   └── dialogs/
│   │       ├── shaders/             # Overlay shaders, picking shader
│   │       ├── icons/               # Tool icons
│   │       ├── debug/               # Debug/telemetry infrastructure
│   │       │   ├── pb_logger.gd
│   │       │   ├── pb_telemetry.gd
│   │       │   └── pb_debug_dock.gd
│   │       └── export/              # OBJ, PLY, STL, GLTF export
│   ├── tests/                       # GUT test scripts
│   │   ├── test_pb_face.gd
│   │   ├── test_pb_mesh_data.gd
│   │   └── ...
│   └── test_scenes/                 # Pre-built scenes for human verification
│       ├── human_test_phase1.tscn
│       └── ...
├── SPECIFICATION.md                 # Assembled spec (37k lines)
├── UNITY-GODOT-MAPPING.md           # API mapping reference
├── IMPLEMENTATION.md                # This file
├── reports/                         # Spec extraction reports
└── ...
```

## Testing Strategy

### Headless Smoke Tests (Autonomous)

Every IU writes tests using GUT (Godot Unit Test framework).

```bash
# Run all tests headlessly
godot-mono --headless -s addons/gut/gut_cmdln.gd \
  -gdir=res://tests -ginclude_subdirs -gexit

# Run specific test
godot-mono --headless -s addons/gut/gut_cmdln.gd \
  -gtest=res://tests/test_pb_mesh_data.gd -gexit
```

Test categories:
1. **Unit tests** — Pure data model: create mesh data, verify arrays, test
   math functions. No editor dependency.
2. **Integration tests** — Mesh operations: create a cube, extrude a face,
   verify resulting vertex count and positions.
3. **Serialization tests** — Save/load PBMeshData resource, verify round-trip.

Tests that need the editor (plugin activation, docks, tools) are marked
`skip_script` in headless mode and verified during human sign-off.

### Human Sign-Off Tests (Interactive)

After each phase, a test scene and script are ready:

```bash
# Launch Godot with test scene for Phase 1 human verification
godot-mono --editor project/project.godot
# Then: open test_scenes/human_test_phase1.tscn
# Follow checklist printed to console
```

Each human test scene includes an autoload script that prints a verification
checklist to the console when the scene is loaded.

### Telemetry & Debug Infrastructure

Built in Phase 0:

```gdscript
# pb_logger.gd — Ring buffer logger
class_name PBLogger extends RefCounted

enum Level { DEBUG, INFO, WARN, ERROR }

var entries: Array[Dictionary] = []  # {time, level, category, message}
var max_entries: int = 10000

func log(category: String, message: String, level: Level = Level.INFO):
    entries.append({
        "time": Time.get_ticks_msec(),
        "level": level,
        "category": category,
        "message": message
    })
    if entries.size() > max_entries:
        entries.pop_front()
    if level >= Level.WARN:
        push_warning("[PB/%s] %s" % [category, message])

func dump_to_file(path: String):
    var f = FileAccess.open(path, FileAccess.WRITE)
    for e in entries:
        f.store_line("%d [%s] %s: %s" % [e.time, Level.keys()[e.level], e.category, e.message])
```

Categories: `core`, `mesh_ops`, `selection`, `undo`, `tools`, `render`, `io`.

The debug dock (visible in editor when plugin active) shows:
- Live log tail (filterable by category/level)
- Mesh stats: vertex count, face count, edge count, submesh count
- Selection state: mode, selected element count, active element
- Operation timing: last operation name + duration in ms
- Memory: estimated mesh data size

## Implementation Phases

### Phase 0: Scaffolding & Infrastructure

**Goal:** Empty plugin loads in editor, debug system works, GUT runs headlessly.

| IU | Description | Test | Depends |
|----|-------------|------|---------|
| P0-01 | Godot project + plugin.cfg + empty EditorPlugin | Plugin appears in Project Settings > Plugins | — |
| P0-02 | PBLogger + PBTelemetry classes | Unit test: log entries, ring buffer overflow, dump to file | — |
| P0-03 | GUT addon setup + first test scaffold | `godot-mono --headless` runs test, exits 0 | P0-01 |
| P0-04 | Debug dock panel (shows log tail) | Human: dock visible when plugin enabled | P0-01, P0-02 |

**Human sign-off:** Enable plugin, see debug dock, verify empty log output.

### Phase 1: Core Data Model

**Goal:** `PBMeshData` resource can represent a cube, serialize, and round-trip.

Spec sections: A01 (Fields, Mesh Representation, Rebuild), A02 (Face, Edge,
Vertex, SharedVertex).

| IU | Description | Test | Depends |
|----|-------------|------|---------|
| P1-01 | PBFace resource (indices, submesh, smoothing, UV settings) | Unit: create face, verify properties | P0-03 |
| P1-02 | PBEdge struct, PBSharedVertex | Unit: edge equality, shared vertex lookup | P0-03 |
| P1-03 | PBMeshData resource (positions, faces, UVs, colors, shared vertices) | Unit: construct manually, verify counts | P1-01, P1-02 |
| P1-04 | PBMeshData → ArrayMesh compilation (ToMesh equivalent) | Unit: compile cube data → ArrayMesh, verify surface count, vertex count | P1-03 |
| P1-05 | PBMeshData serialization round-trip | Unit: save .tres, load, compare all arrays | P1-03 |
| P1-06 | SharedVertex lookup cache + coincident vertex queries | Unit: build lookup, query coincident verts | P1-03 |
| P1-07 | PBMesh node (extends MeshInstance3D, holds PBMeshData, auto-compiles) | Unit: add to scene tree, verify mesh updates | P1-04 |

**Human sign-off:** Open test scene with PBMesh cube node. Verify it renders
correctly in viewport. Rotate camera around it.

### Phase 2: Math & Topology Utilities

**Goal:** Math library and WingedEdge topology ready for mesh operations.

Spec sections: A03 (Enums, math functions), A04 (Projection, snapping), L01
(WingedEdge).

| IU | Description | Test | Depends |
|----|-------------|------|---------|
| P2-01 | PBMath: normal calculation, triangulation, area, centroid | Unit: known geometry → expected values | P0-03 |
| P2-02 | PBMath: plane intersection, ray-plane, point-in-polygon | Unit: edge cases (parallel, coplanar) | P2-01 |
| P2-03 | PBMath: projection utilities (VectorToProjectionAxis, planar project) | Unit: cardinal + non-cardinal normals | P2-01 |
| P2-04 | PBTopology: WingedEdge construction from PBMeshData | Unit: cube → 12 winged edges, verify next/prev/opposite | P1-03, P2-01 |
| P2-05 | PBTopology: edge loop traversal, edge ring traversal | Unit: cylinder → expected loop, expected ring | P2-04 |
| P2-06 | PBMath: snapping (grid snap, angle snap) | Unit: snap values to grid sizes | P2-01 |

**Human sign-off:** N/A (pure computation, fully covered by headless tests).

### Phase 3: Shape Generators

**Goal:** All primitive shapes can be created as PBMeshData.

Spec sections: D01 (Shape primitives).

| IU | Description | Test | Depends |
|----|-------------|------|---------|
| P3-01 | Cube/Box generator (with width/height/depth segments) | Unit: verify vertex count, face count, normals | P1-03 |
| P3-02 | Cylinder generator (radius, height, segments, caps) | Unit: verify topology, cap faces | P1-03 |
| P3-03 | Sphere generator (radius, segments, stacks) | Unit: verify vertex count formula | P1-03 |
| P3-04 | Plane generator (width, height, w-segments, h-segments) | Unit: grid subdivision count | P1-03 |
| P3-05 | Prism, Stairs, Arch, Pipe, Cone, Torus generators | Unit: each shape verifies counts | P1-03 |
| P3-06 | Shape factory: string ID → generator function | Unit: all IDs resolve | P3-01..P3-05 |

**Human sign-off:** Test scene with one of each shape. Visual inspection in editor.

### Phase 4: Basic Editor Integration

**Goal:** Plugin loads, PBMesh appears in node list, selected PBMesh shows
wireframe overlay.

Spec sections: G01 (Wireframe, overlay), H01 (Toolbar), K01 (Interaction).

| IU | Description | Test | Depends |
|----|-------------|------|---------|
| P4-01 | Plugin registers PBMesh custom type, toolbar container | Human: Add Node shows PBMesh | P1-07 |
| P4-02 | Selection detection: plugin._handles(), mode switching | Human: select PBMesh → toolbar appears | P4-01 |
| P4-03 | Wireframe overlay rendering via ImmediateMesh | Human: selected PBMesh shows edges | P4-02, P1-07 |
| P4-04 | Mode toolbar (Object/Vertex/Edge/Face mode buttons) | Human: click buttons, mode changes | P4-02 |
| P4-05 | Vertex/Edge/Face highlight rendering per mode | Human: vertices show as dots, edges highlight | P4-03, P4-04 |

**Human sign-off:** Create PBMesh cube. Select it. Toggle modes. Verify
wireframe, vertex dots, edge/face highlighting. **This is the first major
visual checkpoint.**

Command: `godot-mono --editor project/project.godot`
Checklist script prints instructions to console.

### Phase 5: Element Selection & Picking

**Goal:** Click to select vertices/edges/faces. Rect select. Selection rendering.

Spec sections: E01 (Picker rendering), E02 (Scene picking), E03 (Selection
actions).

| IU | Description | Test | Depends |
|----|-------------|------|---------|
| P5-01 | Raycast picking: click → nearest vertex/edge/face | Headless: synthetic ray → expected element | P4-05, P2-01 |
| P5-02 | Selection state management (add, remove, toggle, clear) | Unit: selection ops on PBMeshData | P5-01 |
| P5-03 | Selection rendering (highlight selected elements) | Human: click face → it highlights | P5-02, P4-05 |
| P5-04 | Shift-click additive, Ctrl-click subtractive selection | Human: multi-select works | P5-03 |
| P5-05 | Rect selection via SubViewport color picking | Human: drag rect → selects enclosed | P5-03 |
| P5-06 | Select edge loop, select edge ring (uses WingedEdge) | Headless: cylinder → double-click → expected loop | P2-05, P5-02 |
| P5-07 | Select All, Deselect All, Invert Selection, Grow/Shrink | Unit: each action on known selection | P5-02 |

**Human sign-off:** Interactive selection in all modes. Rect select. Loop/ring select.

### Phase 6: Element Manipulation Tools

**Goal:** Move, rotate, scale selected elements with undo.

Spec sections: F01 (Move/Rotate/Scale), K01 (Undo).

| IU | Description | Test | Depends |
|----|-------------|------|---------|
| P6-01 | PBCommand base + EditorUndoRedoManager integration | Unit: do/undo round-trip | P0-03 |
| P6-02 | CmdMoveElements: translate selected verts/edges/faces | Headless: move face, verify positions, undo, verify restored | P6-01, P5-02 |
| P6-03 | Move tool: drag handle in viewport, live preview | Human: drag face, see it move | P6-02, P4-05 |
| P6-04 | CmdRotateElements + rotate tool | Human: rotate selected elements | P6-01, P5-02 |
| P6-05 | CmdScaleElements + scale tool | Human: scale selected elements | P6-01, P5-02 |
| P6-06 | Tool properties dock (shows active tool settings) | Human: dock updates when tool changes | P6-03 |

**Human sign-off:** Move/rotate/scale faces on a cube. Undo each. Verify
tool properties dock updates.

### Phase 7: Core Mesh Operations

**Goal:** Extrude, inset, bevel, connect, bridge, loop cut.

Spec sections: B01 (Extrude, Inset), B02 (Connect, Bridge, Subdivide,
InsertEdgeLoop), B03 (Delete, Detach, Merge, Collapse, Split, Weld, Bevel).

| IU | Description | Test | Depends |
|----|-------------|------|---------|
| P7-01 | Extrude faces (along normal, by distance) | Headless: extrude cube face → 10 faces, verify | P6-01, P2-04 |
| P7-02 | Extrude edges | Headless: extrude edge → new face | P7-01 |
| P7-03 | Inset faces | Headless: inset → verify inner face + side faces | P6-01 |
| P7-04 | Bevel edges | Headless: bevel cube edge → chamfer, verify topology | P6-01, P2-04 |
| P7-05 | Connect edges/vertices | Headless: connect opposite edges → new edge | P6-01, P2-04 |
| P7-06 | Bridge edges | Headless: bridge two edge loops → new faces | P6-01 |
| P7-07 | Subdivide faces | Headless: subdivide quad → 4 quads | P6-01 |
| P7-08 | Insert edge loop | Headless: loop cut cylinder → verify new edge ring | P6-01, P2-05 |
| P7-09 | Delete faces/edges/vertices | Headless: delete face, verify remaining | P6-01 |
| P7-10 | Detach faces | Headless: detach → new PBMesh with extracted faces | P6-01 |
| P7-11 | Merge vertices, Collapse edges, Split vertices, Weld | Headless: each op, verify counts | P6-01 |

**Human sign-off:** Extrude, inset, bevel a cube interactively. Visual
inspection of results. Undo all operations.

### Phase 8: UV & Texturing

**Goal:** Auto UV, manual UV editing, UV editor dock.

Spec sections: C01 (UV Editor), C02 (Auto/Manual UV).

| IU | Description | Test | Depends |
|----|-------------|------|---------|
| P8-01 | Auto UV projection (planar, box, face normal based) | Headless: project cube → expected UVs | P1-03, P2-03 |
| P8-02 | UV manipulation: offset, rotate, scale, flip | Headless: transform UVs, verify | P8-01 |
| P8-03 | UV editor dock (2D viewport showing UV layout) | Human: dock shows UV layout | P8-01, P4-01 |
| P8-04 | UV editor: select UV vertices, move/rotate/scale | Human: interactive UV editing | P8-03 |
| P8-05 | UV stitching and unwrapping | Headless: stitch adjacent faces | P8-01, P2-04 |

**Human sign-off:** Apply textured material to cube. Open UV editor. Edit
UVs. Verify texture updates in viewport.

### Phase 9: Shape Drawing Tool

**Goal:** Click-drag to draw shapes directly in viewport.

Spec sections: D02 (Draw shape tool, state machines), D03 (PolyShape).

| IU | Description | Test | Depends |
|----|-------------|------|---------|
| P9-01 | Draw shape tool: click to place, drag to size, release | Human: draw a box in viewport | P3-06, P6-01 |
| P9-02 | Shape tool settings (shape type, segments, etc.) | Human: change shape in tool properties | P9-01, P6-06 |
| P9-03 | Edit shape tool (resize existing shape via handles) | Human: drag shape handles | P9-01 |
| P9-04 | PolyShape tool (click vertices to define polygon, extrude) | Human: draw poly, extrude | P9-01 |

**Human sign-off:** Draw several shapes via the tool. Edit shape handles.
Draw a polygon shape and extrude it.

### Phase 10: Cut Tool

**Goal:** Cut tool for splitting faces with edge insertion.

Spec sections: F02 (Cut tool).

| IU | Description | Test | Depends |
|----|-------------|------|---------|
| P10-01 | Cut tool: click vertices/edges to define cut path | Human: cut across face | P5-01, P6-01 |
| P10-02 | Cut tool: snapping to vertices and edge midpoints | Human: snap indicators | P10-01, P2-06 |
| P10-03 | Cut tool: complete cut → split face into two | Headless: programmatic cut, verify topology | P10-01 |

**Human sign-off:** Cut a cube face diagonally. Verify two resulting faces.

### Phase 11: Advanced Operations & Special Editors

**Goal:** Smoothing groups, vertex colors, object operations, export.

Spec sections: B04, I01, I02, J01, M01.

| IU | Description | Test | Depends |
|----|-------------|------|---------|
| P11-01 | Smoothing groups editor | Human: assign groups, verify smooth shading | P1-01 |
| P11-02 | Vertex color painting | Human: paint colors on mesh | P5-02 |
| P11-03 | Object merge, mirror, center pivot | Headless: merge two PBMeshes → one | P1-03 |
| P11-04 | OBJ export | Headless: export cube → parse OBJ file, verify | P1-04 |
| P11-05 | PLY, STL export | Headless: export → verify file format | P1-04 |
| P11-06 | GLTF export (via Godot's GLTFDocument) | Headless: export → verify file exists | P1-04 |
| P11-07 | ProBuilderize (convert regular MeshInstance3D → PBMesh) | Headless: import mesh → PBMeshData | P1-03 |
| P11-08 | CSG boolean operations (union, subtract, intersect) | Headless: bool two cubes → verify | P1-03, P2-01 |

**Human sign-off:** Smoothing groups visual test. Export cube to OBJ, open
in external viewer. ProBuilderize an imported mesh.

### Phase 12: Polish & Preferences

**Goal:** Settings system, keyboard shortcuts, UI polish.

Spec sections: A03 (Preferences), H02 (Settings, menus).

| IU | Description | Test | Depends |
|----|-------------|------|---------|
| P12-01 | Settings/preferences system (ConfigFile based) | Unit: save/load settings | P0-03 |
| P12-02 | Keyboard shortcut system (configurable keybindings) | Unit: shortcut lookup | P12-01 |
| P12-03 | Menu system (right-click context menus) | Human: right-click → operation menu | All tools |
| P12-04 | Scene info overlay (vertex/face count in viewport) | Human: stats visible in corner | P4-05 |
| P12-05 | Material palette dock | Human: drag material to face | P1-01, P4-01 |

## Sub-Agent Setup

### Agent Types

1. **`worker`** — Implements one IU. Gets spec section extracts, mapping
   reference, and the specific IU task. Writes code + tests. Runs headless
   test to verify.

2. **`scout`** — Read-only recon. Used to extract specific spec sections or
   find patterns in the reference repos before handing to workers.

3. **`researcher`** — Web research for Godot API questions that arise during
   implementation.

### Worker Task Template

Each worker receives a prompt structured as:

```
You are implementing IU {iu_id}: {description}

## Context Files
- Read: project/addons/probuilder/{relevant_files}
- Read: UNITY-GODOT-MAPPING.md (sections {relevant_sections})
- Read: SPECIFICATION.md (lines {start}-{end}) for spec section {spec_section}
- Reference: ../cyclops-ref/godot/addons/cyclops_level_builder/{pattern_file}

## Task
{Precise description of what to implement}

## Required Output
1. Create/modify: {file_list}
2. Create test: tests/{test_file}
3. Run: godot-mono --headless -s addons/gut/gut_cmdln.gd -gtest=res://tests/{test_file} -gexit
4. Test must pass with exit code 0.

## Constraints
- Follow patterns in existing codebase (check project/addons/probuilder/)
- All classes use @tool annotation
- All public methods have type annotations
- Log significant operations via PBLogger
- Do not modify files outside your scope
```

### Orchestration Rules

1. **Max 2 workers in parallel** — prevents merge conflicts in overlapping files.
2. **Workers within same phase can parallelize** if they touch different files.
3. **Cross-phase workers MUST NOT run in parallel** — later phases depend on
   earlier phases' file output.
4. **Verify before accepting** — orchestrator runs the headless test independently
   after worker claims success.
5. **Reject theater** — if worker claims "all tests pass" but didn't show
   test output, reject and re-run.

## Human Sign-Off Protocol

After each phase, the orchestrator:

1. Commits all work to git with descriptive messages
2. Prints a summary of what was implemented
3. Provides the exact command to launch the human test:
   ```
   cd /opt/src/newbuilder/project
   godot-mono --editor .
   # Open: test_scenes/human_test_phaseN.tscn
   ```
4. Lists the specific things to verify
5. Stops and waits for human feedback

The human can:
- **Approve** — proceed to next phase
- **Request changes** — specific issues to fix before proceeding
- **Escalate** — deeper problems requiring spec re-examination

## Spec Section → IU Mapping

For workers to find the right spec content:

| Spec Section | SPECIFICATION.md Lines (approx) | IUs |
|-------------|------|-----|
| A01: Core data structures | 66-440 | P1-01 to P1-07 |
| A02: Face, Edge, Vertex types | 440-900 | P1-01, P1-02 |
| A03: Enums, preferences | 900-2200 | P2-01, P12-01 |
| A04: Math, projection, snapping | 2200-3600 | P2-01 to P2-06 |
| B01: Extrude, Inset, Offset | 3600-5200 | P7-01 to P7-03 |
| B02: Connect, Bridge, Subdivide | 5200-7200 | P7-05 to P7-08 |
| B03: Delete, Detach, Merge, Bevel | 7200-10200 | P7-04, P7-09 to P7-11 |
| B04: Mesh transforms | 10200-11800 | P6-02 to P6-05 |
| C01: UV Editor | 11800-14200 | P8-03, P8-04 |
| C02: Auto/Manual UV | 14200-16700 | P8-01, P8-02, P8-05 |
| D01: Shape primitives | 16700-21400 | P3-01 to P3-06 |
| D02: Draw shape tool | 21400-24000 | P9-01 to P9-03 |
| D03: PolyShape, Bezier | 24000-25600 | P9-04 |
| E01: Selection picker | 25600-27200 | P5-05 |
| E02: Scene picking | 27200-29400 | P5-01, P5-06 |
| E03: Selection actions | 29400-30800 | P5-04, P5-07 |
| F01: Move/Rotate/Scale tools | 30800-32200 | P6-03 to P6-05 |
| F02: Cut tool | 32200-33200 | P10-01 to P10-03 |
| F03: Texture tools | 33200-34000 | P8-02 |
| G01: Wireframe, overlays | 34000-35400 | P4-03, P4-05 |
| G02: Shaders | 35400-36000 | P4-03, P5-05 |
| H01: Toolbar, overlays | 36000-36800 | P4-04, P12-04 |
| H02: Editor core, settings | 36800-37200 | P12-01 to P12-03 |
| I01: Merge, mirror, export | 37200-37600 | P11-03 |
| I02: Export, import, materials | 37600-37800 | P11-04 to P11-07 |
| J01: Special editors | 37800-37900 | P11-01, P11-02 |
| K01: Undo, interaction | 37900-37930 | P6-01 |
| L01: WingedEdge | Lines from report | P2-04, P2-05 |
| M01: CSG | Lines from report | P11-08 |

## Dependency Graph

```
P0-01 ──→ P0-03 ──→ P1-01 ──→ P1-03 ──→ P1-04 ──→ P1-07
  │                    │         │                     │
  ├──→ P0-02 → P0-04  └──→ P1-02 ┘         ┌─→ P3-01..06
  │                              │           │
  │                    P1-05 ←───┘    P1-06 ←┘
  │
  │    P2-01 → P2-02 → P2-03
  │      │
  │      └──→ P2-04 → P2-05    P2-06
  │             │
  └──→ P4-01 → P4-02 → P4-03 → P4-04 → P4-05
                                           │
              P5-01 ←─────────────────────┘
                │
         P5-02 → P5-03 → P5-04,05,06,07
                    │
              P6-01 → P6-02 → P6-03..06
                │
           P7-01..11 (all need P6-01 + topology)
```

Phases 0-3 are heavily parallelizable (data model + math + shapes).
Phases 4-5 are sequential (editor integration builds on itself).
Phases 6-12 can partially parallelize within each phase.
