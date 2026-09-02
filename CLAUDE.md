# ProBuilder Godot Clone

A Godot 4.3+ editor plugin reimplementing Unity ProBuilder's mesh editing
capabilities. Built from a 37k-line specification extracted from ProBuilder
v6.1.2 source code.

## Quick Start

```bash
# Run all tests (ALWAYS use this — never invoke GUT directly; see G4 gate)
./run_tests.sh

# Open in editor for interactive testing
godot-mono --editor project/project.godot
# Then open: test_scenes/human_test_phase6.tscn
```

## Key Documents

- `SPECIFICATION.md` — Complete ProBuilder spec (201 sections, 711 citations)
- `UNITY-GODOT-MAPPING.md` — Unity→Godot API mapping reference
- `IMPLEMENTATION.md` — Phased implementation plan + mandatory verification gates
- `.pi/ORIENTATION.md` — Sub-agent worker orientation

## Reference Repos

- `../probuilder-ref/` — Unity ProBuilder C# source
- `../cyclops-ref/` — Cyclops Level Builder Godot plugin (pattern reference)
- `../godot/` — Godot engine source (4.8-dev, for engine internals).
  NOTE: the INSTALLED engine is 4.7.2-stable — verify APIs against
  `../godot/doc/classes/*.xml` and a real editor boot before using (G5 gate).

## Architecture

Plugin: `project/addons/probuilder/`
- `probuilder_plugin.gd` — EditorPlugin entry: registration, hover tracking,
  H/J/K/X keys. Clicks pass through untouched (the engine's own priority
  applies: the transform gizmo wins over element picking).
- `core/` — PBMeshData, PBFace, PBEdge, PBMath, PBTopology
- `editor/pb_gizmo_plugin.gd` — THE editor integration: EditorNode3DGizmoPlugin
  with SUBGIZMOS. The native editor does element picking, rubber-band
  selection, transform-gizmo drags, snapping, and
  calls back into us. Thin adapter only (editor-only classes cannot be
  instantiated in headless tests).
- `editor/pb_element_editor.gd` — Runtime-safe element logic: per-element
  origins/bases, idempotent drag math from snapshot, undo payloads, selection
  mirroring. Fully headless-testable.
- `editor/pb_editor.gd` — State: select mode (REMEMBERED across selection
  changes), the plugin's OWN tool mode (Move/Rotate/Scale — the editor's
  universal gizmo is never used), orientation space, hover id, selection.
- `editor/pb_tool_bridge.gd` — Presses the engine's Move/Rotate/Scale tool
  buttons to mirror OUR tool onto the engine's transform gizmo, and DISABLES
  the engine's Transform(Q, universal)/Select(V) buttons while editing (a
  disabled button also ignores its shortcut). Headless-testable decisions.
- `editor/pb_toolbar.gd` — Persistent toolbar row BELOW the 3D scene toolbar
  (inserted as a sibling row in the Node3DEditor's root VBox, located by
  walking up from a throwaway anchor added to CONTAINER_SPATIAL_EDITOR_MENU).
  Buttons disable when no PBMesh is selected; the row never hides.
- `gui/overlays/pb_tool_overlay.gd` — Floating in-viewport PanelContainer
  (bottom-left of the editor viewport) with tool info + live drag readout.
  NO docks: debug logging goes to the Godot console via PBLogger.
- `editor/pb_picking.gd` — Pure-logic ray/screen picking.
- `commands/` — Undo/redo command pattern (CmdMove/Rotate/ScaleElements)
- `shapes/` — Primitive shape generators
- `debug/` — PBLogger, PBTelemetry

Hover highlights: `_forward_3d_gui_input` observes mouse motion (never
consumes), picks the element under the cursor into `PBEditor.hover_id`, and
redraws the gizmo; hovered elements render YELLOW and slightly more
transparent than the cyan selected state (faces/edges/verts).

Tests: `project/tests/` (GUT framework, headless-capable).
NEVER claim "tests pass" without run_tests.sh output — GUT silently skips
unparseable test scripts and still reports green.

## Current Status

Phase 0 (Scaffolding) complete ✓
Phase 1 (Core Data Model) complete ✓
Phase 2 (Math & Topology) complete ✓
Phase 3 (Shape Generators) complete ✓
Phase 4 (Basic Editor Integration) complete ✓
Phase 5 (Element Selection & Picking) complete ✓
Phase 6 (Element Manipulation) — REWRITTEN on native subgizmos after failing
first human sign-off. The hand-rolled input/drag/overlay/gizmo stack
(teleporting drags, double box-select, stuck marquee, gizmo fights) was
deleted and replaced by the editor's own machinery. Conventions fixed:
- Winding: internal data CCW-from-outside (Unity); to_array_mesh reverses
  index order for Godot's CW front faces; normals stay OUTWARD (never
  negated). Ground-truth regression tests: tests/test_pb_winding.gd.
- Cylinder caps were wound backwards since P3 — fixed and now covered.
- 411/411 headless tests passing (run_tests.sh; 8845 assertions) ✓
- Element gizmo = Godot's own transform gizmo at the element pivot, with
  Element/Object/World space toggle (X key) ✓

Phase 7 UX round (v0.7.0, after Phase 6 sign-off) complete ✓
- Persistent plugin toolbar row BELOW the 3D scene toolbar (not inside it);
  always visible, buttons disabled outside ProBuilder context.
- The plugin manages its OWN tool modes (Move/Rotate/Scale, remembered) and
  the editor's universal gizmo is unreachable while editing: the bridge
  disables the engine's Transform(Q)/Select(V) buttons and forces the engine
  tool matching ours, so the element gizmo always shows exactly one tool's
  handles. W/E/R stay live and sync back into the plugin toolbar.
- Element mode persistence: clicking off the object (or selecting another
  node) and coming back re-enters the last element mode.
- Yellow hover highlights for faces/edges/verts, slightly more transparent
  than the cyan selected state.
- Click priority: the transform gizmo outranks element picking (the Phase 6
  click-interception was removed; the engine's native order applies).
- The docked panels are gone: tool info lives in a floating overlay panel in
  the viewport (bottom-left); logging is console-only via PBLogger.

Known limitation: programmatic multi-element selection (select-all / grow /
shrink / invert) is NOT exposed to gizmo drags — the engine's script-side
subgizmo selection API is single-id (clears+replaces). Multi-select works
natively via click, shift-click, and rubber band. Revisit if the engine
exposes a multi-id API.

Known limitation: the orange selection box around the selected node is
engine-native (Node3DEditorViewport draws it for EVERY selected Node3D from
the node's AABB merged recursively with all VisualInstance3D descendants).
It cannot be suppressed per-node in Godot 4.7: any child MeshInstance3D
re-creates it, and a zero custom AABB breaks mesh culling. It already hugs
the edited mesh (the child-node overlay inflation was removed in the P6
rewrite). An upstream engine flag would be the proper fix.

Next: Phase 7 (Core Mesh Operations) — after human sign-off of this UX round
(human_test_phase6.tscn prints the updated checklist).

## Key Conventions

- Internal mesh data uses CCW-from-outside winding (Unity convention) —
  PBMath.cross-based normals point OUTWARD.
- Godot renders CW front faces. to_array_mesh() reverses each triangle's
  index order; the normals array is passed through UNCHANGED (outward).
  This is locked by test_pb_winding.gd against BoxMesh ground truth — do not
  "fix" winding or normals without updating that file and reading it first.
- The editor's subgizmo selection is the authoritative element selection
  while editing; PBSelection mirrors it (engine → us, in _redraw).
- Element transforms compose as rel = target_xf * start_xf⁻¹ applied to the
  drag-start snapshot — idempotent under the engine's per-id delivery.
