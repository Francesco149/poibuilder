# PoiBuilder (Godot ProBuilder clone)

A Godot 4.3+ editor plugin reimplementing Unity ProBuilder's mesh editing
capabilities. Built from a 37k-line specification extracted from ProBuilder
v6.1.2 source code.

Naming: the plugin is **PoiBuilder** (renamed from ProBuilder in v0.8.0).
Since v0.9.19 the addon folder/file names carry the rename too:
`addons/poibuilder/` + `poibuilder_plugin.gd`. The `PB*`/`pb_*` script and
class prefixes are kept (res:// paths and .uid files reference them;
renaming classes would churn every file for no functional gain). Comments
citing "ProBuilder" behavior/math refer to Unity's ProBuilder — the spec
source — and are intentional.

## Quick Start

```bash
# Run all tests (ALWAYS use this — never invoke GUT directly; see G4 gate)
./run_tests.sh

# Open in editor for interactive testing
godot-mono --editor project/project.godot
# Retro pipeline: see retro_engine/RETRO-AUTHORING.md (authoring recipes) and
# run_viewer.sh / run_psp_hw.sh --app (viewer / real device).
#
# Build artifacts are gitignored and regenerated on demand:
#   project/exports/*.glb        -> ./run_tests.sh (test_pb_map_showcase.gd
#                                   exports all five presets) or the Export dialog
#   test_scenes/test_map_showcase.tscn -> same test, or ./showcase_map.sh
#   retro_engine/psp/EBOOT.PBP + PoiRetro_PSP.zip -> ./run_psp.sh (builds if missing)
#   showcase_video/out/*         -> ./showcase_video/build.sh
```

Interactive launchers (`./test.sh raylib|psp`, `./run_raylib.sh`) need an X
display. This workstation is pure Wayland (niri) with no Xwayland for the
session, so `xdisplay.sh` resolves one: reuse `DISPLAY`, else start
`xwayland-satellite` (compositor-integrated, `:0`), else fall back to
`xvfb-run` and say so. Starting a private `Xwayland :99` does **not** work —
it has no compositor behind it, so the program runs and renders perfectly into
a window nobody can see. That was the entire "no window appears" bug.

## Performance Claims (non-negotiable)

**A performance number is real only if it came from a PSP over USB.** Nothing
else counts as evidence:

- `./run_psp_hw.sh` is the only source of truth (cpu/gpu split, the camera sweep,
  the ablations). Run it before and after any renderer/exporter change and quote
  its rows — `retro_engine/psp/HARDWARE-TESTING.md` has the method and the
  accumulated tables.
- **PPSSPP (and any emulator, and any desktop viewer) is for correctness only**:
  does it load, does it crash, does it look right, roughly how should this
  frame's pixels sit. It rasterises on the host GPU with a huge texture cache,
  no shared memory bus and no clipper, so it happily reports 60 fps for a build
  that spends 27 ms of a 16.6 ms budget on the device. Never cite it for speed,
  and never conclude from it that a slowdown is fixed.
- **Do not build on unmeasured performance assumptions** — not in code comments,
  not in docs, not in a summary. "This should be faster" is not a result; either
  measure it or state plainly that it is unmeasured.
- **If no PSP is connected**, say so and ask the user to set one up before the
  session ends (`./setup_psplink.sh`, 30 seconds, once per device). Until the
  battery has run, mark perf-related work as unverified rather than done.
- Every optimization claim in the docs carries the device row that produced it.
  If you change a measured default (LOD bias, filter, level policy, texture
  format, emitter budget), re-measure and update the row in the same commit.

## Key Documents

- `ROADMAP.md` — Phased feature gap implementation plan (ProBuilder & UniBuilder parity: 2D UV Editor, 3D texture tool, bevel, bridge, connect, fill hole, advanced selection, booleans, trims)
- `SPECIFICATION.md` — Complete ProBuilder spec (201 sections, 711 citations)
- `UNITY-GODOT-MAPPING.md` — Unity→Godot API mapping reference
- `IMPLEMENTATION.md` — Phased implementation plan + mandatory verification gates
- `retro_engine/psp/HARDWARE-TESTING.md` — **real PSP measurement and debugging**:
  PSPLink over USB, the `./run_psp_hw.sh` loop, device diagnostics, and the
  hard-won rules (never `modstop` a live module; a resident `PoiRetro` module —
  which happens whenever an app wedges, and **Home then does nothing, since a
  wedged app never runs its exit callback** — is cleared with psplink's `reset`,
  which `run_psp_hw.sh` performs by itself; do not sit waiting for someone to
  press a button). It also documents how to verify a scrolling texture's
  direction on the device. Read this BEFORE concluding anything about PSP
  performance — PPSSPP cannot measure it, and a build that runs at 60 fps there
  can spend 27 ms of a 16.6 ms budget on the device.
- `retro_engine/psp/OPTIMIZATION.md` — **the PSP engine's optimization
  inventory**, in the order that matters, with the measured cost of every
  decision (fill and the texture-cache cliff, the mip/LOD policy, passes, the
  per-frame CPU budget, what is deliberately not done). Read it before changing
  the renderer or the exporters.
- `retro_engine/RETRO-AUTHORING.md` — **authoring recipes for the retro
  pipeline**: the Godot → `.pbm` workflow, what the export bakes, the
  performance rules that actually bite, the knob tables (export dialog, node
  metadata, `poi_render.txt`) and the pitfalls. Read it before authoring or
  reviewing level content.
- `showcase_video/` — **the showcase video pipeline** (the README's video, built
  from data, not edited by hand):
  - `render.sh <session>` boots a real editor under Xvfb and records one
    *session* frame by frame; `project/showcase/sessions/*.gd` are the shot
    programs (the beats), `project/showcase/showcase_director.gd` is the
    recorder/driver API they are written against.
  - `edl.toml` is the timeline (crop, trim, speed, captions, transitions);
    `build.sh` bakes a segment per clip, concatenates the master, encodes the
    README cut and verifies the result.
  - `bake/` is scratch (frames, overlays, segments); `out/` holds the
    deliverables — the 720p master, the 960x540 cut the README embeds, the
    poster, and `review-sheet.png` (a contact sheet of the whole timeline, for
    reviewing a build without playing it). The README embed is a GitHub
    `user-attachments` URL, which is uploaded from the web editor: drag the cut
    in, replace the bare URL on its own line.
  - Everything downstream of the capture is Pillow + ffmpeg: restyle a caption
    or re-time a cut without re-rendering the editor.
  - `tools/showcase/cursor_check.py` verifies the drawn cursor: it drives a
    marker through each clip's REAL filtergraph and compares it with the mapper
    the renderer itself uses (`overlay.point_mapper` off `build.overlay_plan` —
    the mapper and the check share one construction so they cannot drift; that
    was the bug: the renderer's call site had dropped the clips' `into` box and
    `contain` mode while the check built a correct mapper of its own). Segment
    stamps hash the pipeline's own sources too, so a tool fix re-bakes the
    clips it affects.
- `.pi/ORIENTATION.md` — Sub-agent worker orientation: rules + the index
  into `.pi/orientation/` (the full implementation docs, one topic file per
  area: architecture, selection/gizmo, mesh ops, testing, footguns, retro).
  Read the topic file for your area before touching that area.

## Reference Repos

- `../probuilder-ref/` — Unity ProBuilder C# source
- `../cyclops-ref/` — Cyclops Level Builder Godot plugin (pattern reference)
- `../godot/` — Godot engine source (4.8-dev, for engine internals).
  NOTE: the INSTALLED engine is 4.7.2-stable — verify APIs against
  `../godot/doc/classes/*.xml` and a real editor boot before using (G5 gate).

## Architecture

Plugin: `project/addons/poibuilder/`
- `poibuilder_plugin.gd` — EditorPlugin entry: registration, hover tracking,
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
  buttons to mirror OUR tool onto the engine's transform gizmo, DISABLES
  the engine's Transform(Q)/Select(V) buttons while editing (a disabled
  button also ignores its shortcut), and drives the engine's local-coords
  toggle (T) to implement the orientation space (below). Headless-testable
  decisions.
- `editor/pb_toolbar.gd` — Persistent toolbar row BELOW the 3D scene toolbar.
  PLACEMENT IS VERSION-SENSITIVE: Node3DEditor must be located by walking the
  anchor's real ancestor path — in 4.7 the Node3DEditor IS the layout VBox
  (`VBoxContainer *vbc = this;`, get_class() still says "Node3DEditor"), so
  NEVER search descendants by "VBoxContainer" class (that found a hidden snap
  dialog's VBox = the invisible-toolbar bug). The row is inserted as a
  sibling AFTER the engine's toolbar MarginContainer; the engine's own VBox
  layout then sizes the row and pushes the viewports down. Icon buttons (SVGs
  in icons/), disabled when no PBMesh is selected; the row never hides.
  Carries: tools (Move/Rotate/Scale), modes (Object/Vertex/Edge/Face), space
  cycler, ALL mesh-op buttons (enable per selection context), New Shape menu,
  Edit Params (pristine factory shapes only), and the Panel (overlay pin)
  toggle.
- `gui/overlays/pb_tool_overlay.gd` — Floating in-viewport PanelContainer
  (bottom-left) in standard panel language. COMPACT BY DEFAULT: carries NO
  op buttons and NO tool/space controls (toolbar has them) — it shows the
  SELECTION readout only while something is selected, the live drag readout
  only while a drag runs, and the shape-params MODAL (Apply/Cancel, live
  preview). Auto-hides otherwise; draggable by its header, collapsible to
  the header, pinned via the toolbar Panel toggle. Clicks on it are
  consumed; everything else passes to the scene. NO docks: debug logging
  goes to the Godot console via PBLogger.
- `editor/pb_shape_creator.gd` — Drag-to-create state machine (runtime-safe,
  headless-testable): ARMED → BASE (LMB drag on any surface, coplanar to the
  pressed plane; floor vs wall extent mapping) → HEIGHT (mouse adjusts the
  3rd dimension along the normal, LMB click confirms) → PARAMS (overlay
  modal; Cancel restores session values). ESC before the confirming click
  aborts with NOTHING created (the preview node never enters undo).
- `shapes/pb_shape_params.gd` — Per-shape parameter defs (name/label/min/
  max/step/default/kind), defaults, build() dispatch to the generators, and
  apply_drag_extents() mapping the base drag + height onto size dims.
- `editor/pb_picking.gd` — Pure-logic ray/screen picking.
- `editor/uv/` — Dedicated 2D UV Editor: `pb_uv_canvas.gd` (interactive 2D canvas,
  pan/zoom, grid, texture underlay, wireframe, selection), `pb_uv_editor_panel.gd`
  (bottom dock container, toolbar, pop-out window, selection sync).
- `commands/` — Undo/redo command pattern (CmdMove/Rotate/ScaleElements)
- `shapes/` — Primitive shape generators (+ `pb_shape_params.gd`: per-shape
  parameter defs, defaults, and the drag-extent mapping)
- `mesh_ops/` — PBMeshOps: topology operations (extrude, inset, subdivide, loop
  cut, merge, weld, delete, detach, knife cuts), headless-static
- `materials/` — the default material and shipped textures, the splat/decal
  shaders, and the paint/splat data model (`core/pb_splat.gd`)
- `export/` — THE RETRO PIPELINE: `pb_map_exporter.gd` (ExportSettings, the
  async export, the glTF writer, light/tile baking, colliders) and
  `pb_pbm_converter.gd` (the GDScript `.pbm` writer, byte-compatible with the
  Python oracle `retro_engine/pbm_conv.py`)
- `gui/` — docks (Material & UV / paint / stamp) and the in-viewport overlay
- `debug/` — PBLogger, PBTelemetry

Hover highlights: `_forward_3d_gui_input` observes mouse motion (never
consumes), picks the element under the cursor into `PBEditor.hover_id`, and
redraws the gizmo; hover is CYAN and selection YELLOW (since v0.9.0) —
yellow reads as "selected", cyan as "under your cursor".

Orientation space (Element/Object/World, X key or Space button): the engine's
transform gizmo only adopts a subgizmo's basis while the editor's own
local-coords toggle ("Use Local Space", T) is ON — otherwise its basis stays
identity (world axes). There is no other script-accessible hook
(`update_transform_gizmo()` in node_3d_editor_plugin.cpp). So PBToolBridge
finds that toggle button (shortcut identity, fallback physical T) and presses
it: WORLD → OFF, ELEMENT/OBJECT → ON. The engine's `toggled` handler then
calls its own update_transform_gizmo() and also pre-converts drag motion
through the gizmo basis, so element_basis() becomes live for display AND
drag math. While editing the toggle is DISABLED (like Q/V) so T can't fight
the plugin; a stray external flip is re-asserted via the `toggled` listener.

Tests: `project/tests/` (GUT framework, headless-capable).
NEVER claim "tests pass" without run_tests.sh output — GUT silently skips
unparseable test scripts and still reports green.

## Current Status

- Current version: **v0.9.107** (core phases 0–7, feature gap sessions 1–9 complete).
- All headless tests passing (`./run_tests.sh`; 988 tests, 19.9k+ assertions
  across 64 suites) plus the real-editor GUI harness (`./run_gui_tests.sh`, 0 failures).
- Architecture: native subgizmos, orientation space (Element/Object/World, X key), mesh ops (extrude, inset, loop cut, weld, detach, bevel, bridge, connect, collapse, fill hole), advanced selection (coplanar, similar, boundary, face loop/ring), precision snapping (Hold V vertex snap, proportional editing), object tools (merge, mirror, pivot tools, probuilderize), CSG booleans (union, subtract, intersect), smoothing groups & auto-smooth, architectural moulding/trims, UV/material editor, retro PSP hardware exporter.
- Full historical development log and version-by-version notes are archived in [CHANGELOG.md](CHANGELOG.md).


## Key Conventions

- GENERATED ARTIFACTS ARE NEVER COMMITTED (mandatory): if a script in this
  repo can produce it, it does not belong in git. That covers video and audio
  files, rendered frame sequences, screenshots, map exports (`.glb`, `.pbm`),
  built PSP binaries (`EBOOT.PBP`, `*.prx`, `PoiRetro_PSP.zip`), generated
  scenes and extracted textures (`test_map_showcase.tscn`, `*_albedo.png`),
  device logs, and test reports. The reason is measured, not stylistic: the
  files above were committed before v0.9.78 and cost ~100 MB of history for
  artifacts a reader never needs (the README video alone was 9 MB of it), so
  the whole history was rewritten to drop them. The root `.gitignore` lists
  every one of them with the command that regenerates it; build output goes
  under a gitignored dir (`showcase_video/bake/`, `showcase_video/out/`) or
  `/tmp`. The only tracked binaries are the authored textures, materials and
  fonts the plugin ships. If a `git add` is about to stage something over
  ~100 KB, it is an artifact — commit the source instead, and if a fresh
  clone needs the file, add the regeneration step to the docs.
- COMMIT SIGNING (mandatory): every commit must end with a blank line plus
  a `Co-authored-by` trailer naming the model that produced it, in the
  format used across the history:
  `Co-authored-by: <provider-slug>/<model-slug> <<provider-slug>+<model-slug>@users.noreply.github.com>`
  e.g. `Co-authored-by: zai-coding-plan/glm-5.3-flash <zai-coding-plan+glm-5.3-flash@users.noreply.github.com>`.
  Derive the slugs from YOUR OWN model id (lowercase, provider path prefix);
  never reuse another model's trailer.
- VERSION BUMP EVERY SIGN-OFF ROUND (mandatory): bump `VERSION` in
  poibuilder_plugin.gd, `PLUGIN_VERSION` in pb_editor.gd, and
  plugin.cfg's `version` TOGETHER at the start of every fix/UX round. The
  overlay title is how the human verifies they are running the new build —
  rounds 2 and 3 of v0.9.0 skipped this and shipped fixes the human never
  received (they rightly checked "is it 0.9.0?" and it was).
- REPRODUCE BEFORE CLAIMING: for viewport-interaction bugs (click picking,
  gizmo behavior, creation flow), do not rely on static code reading — use
  `./run_gui_tests.sh` (editor_gui_test.tscn: boots a REAL editor under
  Xvfb and drives synthesized mouse events through the input pipeline,
  asserting selection and creation outcomes). Extend that scene with a new
  test case for every regression it catches. GUT alone cannot see this
  layer; twice, view-port fixes that "looked right" shipped unverified and
  were not fixes.
- The README.md is a purely HUMAN-FACING doc: do not read it for context and
  do not factor it into how you work on the project. The ONLY exception is
  updating the feature checklist when features are completed, when
  explicitly asked to edit it. Everything an agent needs lives here in
  CLAUDE.md, SPECIFICATION.md, and IMPLEMENTATION.md.
- Internal mesh data uses CCW-from-outside winding (Unity convention) —
  PBMath.cross-based normals point OUTWARD.
- Godot renders CW front faces. to_array_mesh() reverses each triangle's
  index order; the normals array is passed through UNCHANGED (outward).
  This is locked by test_pb_winding.gd against BoxMesh ground truth — do not
  "fix" winding or normals without updating that file and reading it first.
- The editor's subgizmo selection is the authoritative element selection
  while editing; PBSelection mirrors it (engine → us, in _redraw). The
  engine's script API can only REPLACE the subgizmo selection with ONE id —
  multi-element semantics (loops, UV groups, mode-switch conversion) ride
  seed ids + expansion maps in PBElementEditor. Full contract:
  `.pi/orientation/selection.md`. Switching element modes CONVERTS the
  selection (ProBuilder parity); ops that create faces select their output.
- Element transforms compose as rel = target_xf * start_xf⁻¹ applied to the
  drag-start snapshot — idempotent under the engine's per-id delivery.
