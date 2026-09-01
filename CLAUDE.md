# ProBuilder Godot Clone

A Godot 4.3+ editor plugin reimplementing Unity ProBuilder's mesh editing
capabilities. Built from a 37k-line specification extracted from ProBuilder
v6.1.2 source code.

## Quick Start

```bash
# Run all headless tests
cd project && GODOT_DISABLE_LEAK_CHECKS=1 godot-mono --headless \
  -s addons/gut/gut_cmdln.gd -gdir=res://tests -ginclude_subdirs -gexit

# Open in editor for interactive testing
godot-mono --editor project/project.godot
```

## Key Documents

- `SPECIFICATION.md` — Complete ProBuilder spec (201 sections, 711 citations)
- `UNITY-GODOT-MAPPING.md` — Unity→Godot API mapping reference
- `IMPLEMENTATION.md` — Phased implementation plan (12 phases, ~70 IUs)
- `.pi/ORIENTATION.md` — Sub-agent worker orientation

## Reference Repos

- `../probuilder-ref/` — Unity ProBuilder C# source
- `../cyclops-ref/` — Cyclops Level Builder Godot plugin (pattern reference)
- `../godot/` — Godot engine source (4.7.2, for engine internals)

## Architecture

Plugin: `project/addons/probuilder/`
- `probuilder_plugin.gd` — EditorPlugin entry point
- `core/` — PBMeshData, PBFace, PBEdge, PBMath, PBTopology
- `editor/` — PBEditor, PBSelection, PBPicking, PBOverlay, PBToolbar, tools
- `commands/` — Undo/redo command pattern
- `shapes/` — Primitive shape generators
- `debug/` — PBLogger, PBTelemetry, PBDebugDock

Tests: `project/tests/` (GUT framework, headless-capable)

## Current Status

Phase 0 (Scaffolding) complete ✓
Phase 1 (Core Data Model) complete ✓
Phase 2 (Math & Topology) complete ✓
Phase 3 (Shape Generators) complete ✓
Phase 4 (Basic Editor Integration) complete ✓
Phase 5 (Element Selection & Picking) complete:
- PBSelection: Selection state management for vertices (common indices), edges (deduped by common), faces (by index) ✓
- PBPicking: CPU raycast face picking (Möller–Trumbore), screen-space edge/vertex picking, rect selection ✓
- PBOverlay: Selection rendering — selected vertices (cyan dots), edges (cyan lines), faces (cyan semi-transparent triangles) ✓
- ProBuilderPlugin: Click picking with Shift (additive) / Ctrl (subtractive), drag-rect marquee selection ✓
- Select All (Ctrl+A), Deselect All (Ctrl+D), Invert (Ctrl+Shift+A), Grow (Ctrl+=), Shrink (Ctrl+-) ✓
- Edge loop/ring selection via PBTopology (tested on cube and cylinder) ✓
- 341/341 headless tests passing (7550 assertions) ✓

Next: Phase 6 (Element Manipulation Tools)
