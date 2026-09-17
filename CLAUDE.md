# PoiBuilder (Godot ProBuilder clone)

A Godot editor plugin reimplementing Unity ProBuilder's mesh editing
capabilities. Built from a 37k-line specification extracted from ProBuilder
v6.1.2 source code.

Naming: the plugin is **PoiBuilder** (renamed from ProBuilder in v0.8.0).
Since v0.9.19 the addon folder/file names carry the rename too:
`addons/poibuilder/` + `poibuilder_plugin.gd`. The `PB*`/`pb_*` script and
class prefixes are kept (res:// paths and .uid files reference them;
renaming classes would churn every file for no functional gain). Comments
citing "ProBuilder" behavior/math refer to Unity's ProBuilder — the spec
source — and are intentional.

## The real orientation docs

**Everything about how this plugin actually works lives in
[.pi/ORIENTATION.md](.pi/ORIENTATION.md)** and its topic files under
`.pi/orientation/` (architecture, selection/gizmo, mesh ops, testing,
footguns, retro). Read the topic file for your area BEFORE touching that
area — agents repeatedly re-implemented behavior that was already there and
broke it; those docs exist so you are not the next one.

This file intentionally does NOT duplicate them. It holds only the document
index, current status, and the process rules that are not area-specific.

## Quick Start

```bash
# Run all tests (ALWAYS use this — never invoke GUT directly; see
# .pi/orientation/testing.md for why)
./run_tests.sh
./run_gui_tests.sh          # real-editor event harness for viewport behavior
./scratch.sh [--play]       # disposable editor playground (FPS controller)
./deploy_psp.sh             # newest scratch .pbm -> real PSP, interactive
./test_baked_glb.sh         # retro-baked .glb in the interactive viewer
./test_modern_glb.sh        # modern .glb in the viewer, FPS play mode
./modern.sh [--play]        # 4k-asset modern-workflow playground
./bake_splat.sh <scene>     # bake splats down, free UV2 for lightmaps
# Human smoke-test cheat sheet (hand this to the tester): SMOKE-TESTS.md

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
display: `./xdisplay.sh` resolves one (reuse `DISPLAY`, else
`xwayland-satellite`, else `xvfb-run` and say so). A private `Xwayland :99`
does **not** work — no compositor behind it, so the window is invisible.

## Key Documents

- `.pi/ORIENTATION.md` — **worker orientation + index into
  `.pi/orientation/`** (the implementation docs: architecture,
  selection/gizmo, mesh ops, testing, footguns, retro). Start here.
- `ROADMAP.md` — phased feature-gap implementation plan (ProBuilder &
  UniBuilder parity sessions)
- `docs/DOCUMENTATION-ROADMAP.md` — the plan for the end-user documentation
  (static HTML bundled with the extension) and the next showcase-video
  refresh; written to be mechanically executable across sessions
- `SPECIFICATION.md` — complete ProBuilder spec (201 sections, 711 citations)
- `SPEC_RETRO_FORMAT.md` — the `.pbm` format + consumer performance rules
- `UNITY-GODOT-MAPPING.md` — Unity→Godot API mapping reference
- `IMPLEMENTATION.md` — phased implementation plan + mandatory verification gates
- `CHANGELOG.md` — version-by-version history (canonical record)
- `retro_engine/psp/HARDWARE-TESTING.md` — real-PSP measurement: PSPLink over
  USB, the `./run_psp_hw.sh` loop, device diagnostics, hard-won rules. Read
  BEFORE concluding anything about PSP performance.
- `retro_engine/psp/OPTIMIZATION.md` — the PSP engine's optimization
  inventory with the measured cost of every decision. Read before changing
  the renderer or the exporters.
- `retro_engine/RETRO-AUTHORING.md` — authoring recipes for the retro
  pipeline: the Godot → `.pbm` workflow, what the export bakes, the knobs,
  the pitfalls.
- `showcase_video/` — **the showcase video pipeline** (the README's video,
  built from data, not edited by hand): `render.sh <session>` boots a real
  editor under Xvfb and records one *session* frame by frame;
  `project/showcase/sessions/*.gd` are the shot programs (the beats),
  `project/showcase/showcase_director.gd` is the recorder/driver API they
  are written against. `edl.toml` is the timeline (crop, trim, speed,
  captions, transitions); `build.sh` bakes a segment per clip, concatenates
  the master, encodes the README cut and verifies the result. `bake/` is
  scratch; `out/` holds the deliverables (720p master, the 960x540 README
  cut, the poster, `review-sheet.png` for reviewing without playing). The
  README embed is a GitHub `user-attachments` URL uploaded from the web
  editor. Everything downstream of capture is Pillow + ffmpeg: restyle a
  caption or re-time a cut without re-rendering the editor.
  `tools/showcase/cursor_check.py` verifies the drawn cursor through each
  clip's REAL filtergraph (shared construction with the renderer's mapper so
  they cannot drift); segment stamps hash the pipeline's sources so a tool
  fix re-bakes the clips it affects.
- `poibuilder-manifest.json` — feature/tool inventory consumed by tooling.

## Reference Repos

- `../probuilder-ref/` — Unity ProBuilder C# source
- `../cyclops-ref/` — Cyclops Level Builder Godot plugin (pattern reference)
- `../godot/` — Godot engine source (for engine internals).
  NOTE: the INSTALLED engine is 4.7.2-stable — verify APIs against
  `../godot/doc/classes/*.xml` and a real editor boot before using.

## Current Status

- Current version: **v0.9.142** (core phases 0–7, feature-gap sessions 1–9,
  plus the Trim Walls click-walls tool).
- All headless tests passing (`./run_tests.sh`; 1081 tests, 20.6k+ assertions
  across 66 suites) plus the real-editor GUI harness (`./run_gui_tests.sh`,
  failures=0).
- Feature surface: primitives + drag-to-create (incl. one-drag Trim and the
  Trim Walls wall-picker with mitres), object/vertex/edge/face/texture modes
  with selection conversion, native-subgizmo transforms with orientation
  spaces, mesh ops (extrude, inset, loop cut, weld, detach, bevel, bridge,
  connect, collapse, fill hole, knife), advanced selection suite (grow/shrink,
  coplanar, similar, boundary, face loop/ring), precision snapping (hold-V
  vertex snap, proportional editing), object tools (merge, mirror, pivots,
  freeze, Poibuilderize from MeshInstance3D/CSG incl. CSGCombiner3D), CSG
  booleans (union/subtract/intersect) with clean undo, smoothing groups &
  auto-smooth, dedicated 2D UV editor, material dock with splatting/decal
  stamps/sprite placer, retro PSP hardware exporter + viewers.
- Full historical development log: [CHANGELOG.md](CHANGELOG.md).

## Process rules (not duplicated in the orientation)

- **The README.md is a purely HUMAN-FACING doc**: do not read it for context
  and do not factor it into how you work on the project. The only exception
  is updating the feature checklist when features are completed, when
  explicitly asked to edit it. Everything an agent needs lives in CLAUDE.md,
  the `.pi/orientation/` docs, and SPECIFICATION.md.
- **Version bump + commit trailer**: see rule 5 in `.pi/ORIENTATION.md`.
- **Tests / evidence**: `./run_tests.sh` is the only accepted way to run or
  claim them; viewport behavior only counts if the GUI harness (or a human)
  saw it; perf claims need a real PSP. Full contracts:
  `.pi/orientation/testing.md` and `.pi/orientation/retro.md`.
- **Generated artifacts are never committed**: the full list, the measured
  reason (~100 MB of history once rewritten), and the regeneration commands
  are in rule 4 of `.pi/ORIENTATION.md`. If a `git add` is about to stage
  something over ~100 KB, it is an artifact — commit the source instead.
- **Winding**: internal data CCW-from-outside; Godot renders CW front faces;
  `to_array_mesh()` reverses index order, normals never negated — locked by
  `tests/test_pb_winding.gd`. Do not "fix" winding without reading it and
  `.pi/orientation/architecture.md` first.
- **Selection contract**: the engine's subgizmo selection is authoritative
  while editing; one-id replace semantics; multi-element semantics ride seed
  ids + expansion maps. Full contract: `.pi/orientation/selection.md`.
  Switching element modes CONVERTS the selection (ProBuilder parity); ops
  that create faces select their output.
