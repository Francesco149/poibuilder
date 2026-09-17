# PoiBuilder

A free, open-source **ProBuilder / UniBuilder-style mesh building plugin for
Godot 4** — primitives, drag-to-create, and direct vertex/edge/face editing
inside the editor, auto UVs in the spirit of Unity's ProBuilder. One click export to baked glb or custom pbm format optimized for retro pipelines, tested on a real Sony PSP.

**Pure GDScript**: PoiBuilder is written 100% in standard GDScript. It runs in the standard Godot 4 editor (no Godot Mono / .NET build required) and needs **no C/C++ compilation, no GDExtension, and no native binaries** — just drop the `addons/poibuilder/` folder into any standard Godot 4 project and enable it.

https://github.com/user-attachments/assets/17a064a9-4f35-439b-8e7c-d5ee7284c5e2

> **This is an AI-assisted hobby project.** PoiBuilder was written mainly for
> my own use, because I wanted a free and open source UniBuilder equivalent
> for Godot. It is developed with the help of AI coding agents, and while it
> is very usable, **I make no guarantees about support, maintenance, or
> polish.** The code is all here — use it, improve on it, or reference it to
> build your own.

If you want an actually maintained and polished product that achieves the
same thing, keep an eye on **UniBuilder** (upcoming):
**https://calinleafshade.itch.io/unibuilder**

Another open source Godot level builder in a similar spirit is **GoBuild**:
**https://github.com/marcel-b-roodt/GoBuild**

## The PBM retro pipeline

The bridge between modern level authoring and retro hardware is the
**PoiRetro `.pbm` v3 map format** — one click bakes a playable map for
fixed-function targets (PSP, Dreamcast, PS2, custom engines); v1/v2 files
still load.

**In the file format and the addon** (any engine can consume these):

- **Bake everything offline**: direct/point/spot lighting, ray-traced shadows
  and multi-sample ambient occlusion baked into vertex colors; unique painted
  textures baked into power-of-two 4x4 tile atlases (unpainted tiles share
  base textures); grid-aligned quad subdivision turns stairs and doorways
  into clean quads with zero sliver fans.
- **Collision hulls** (box, trimesh, ramp) extracted automatically for
  player traversal and raycasting.
- **Animated UV scrolling**: speed authored on the material, live in the
  editor viewport, carried through GLB, replayed identically by any consumer.
- **Stateless particle emitters** (standard `emitters` lump): authored as
  ordinary `GPUParticles3D`; particle *i* at time *t* is a closed form of
  `(t, i, seed)` — a runtime costs a few flops per particle, no simulation,
  one draw call per emitter. Additive emitters need no sorting; blended ones
  are drawn back-to-front.
- **Arbitrary binary metadata lumps**: level descriptors, waypoints,
  spawn points, triggers, walkable nav meshes.
- **Three-valued alpha modes** (opaque / cutout / blend) per texture, so
  foliage silhouettes and waterfall sheets survive the bake.
- **Modern target too**: the same scene exports to standard `.glb` with
  native PBR materials for Godot 4, Unreal, Unity, or WebGL.

**In the bundled PSP demo engine** (`retro_engine/psp`, plain C, measured on
real hardware — a reference consumer of the format, not a requirement):

- Zero-CPU rendering: 24-byte interleaved vertices matching Sony GU registers,
  16-byte aligned for direct display-list DMA; 16-bit swizzled `RGBA5551`
  textures halve VRAM bandwidth.
- Load-time mip chains (alpha-preserving for cutouts) with a measured
  single-level LOD policy: the worst showcase view went **25.2 ms → 2.79 ms
  per frame**, the whole camera sweep runs at 2.4–5.0 ms/frame (200–450 fps).
  Known limitation: a grazing-angle LOD step between tile quads (per-primitive
  LOD, no anisotropic filtering); painted meshes pin to one mip level by
  default to remove it.
- Pre-baked vertex lighting with zero runtime light cost, native collision,
  stateless emitters at 0.72 ms GPU / 1.14 ms CPU for a 256-particle budget,
  and a 60 FPS fly/walk player with HUD.
- **Measured, not assumed**: every perf claim comes from `./run_psp_hw.sh`
  on a real PSP over USB. PPSSPP cannot price a frame (it rasterises on the
  host GPU) and is used for correctness only. See
  `retro_engine/psp/OPTIMIZATION.md` (engine inventory),
  `retro_engine/psp/HARDWARE-TESTING.md` (measurement), and
  `SPEC_RETRO_FORMAT.md` §11 (how to write your own consumer).

## Features (the addon)

**Building & mesh editing**

- 14 primitives (cube, stairs, curved stairs, prism, cylinder, plane, door,
  pipe, cone, sprite, arch, sphere, torus, n-gon) with drag-to-create on any
  surface or the grid: drag the base, move to set height, click to confirm;
  parameter modals with live preview and re-editable pristine shapes.
- Object / vertex / edge / face selection modes with hover + selection
  highlights, rubber-band multi-select, occlusion-aware picking, and
  mode-switch selection conversion (ProBuilder parity).
- Move/rotate/scale through the editor's native gizmos at the element pivot
  (Element / Object / World spaces), center scale handle, Shift+Move extrude,
  Shift+Scale inset.
- Mesh ops: extrude, inset, bevel (multi-segment), loop cut, subdivide,
  merge, weld, bridge, connect, collapse, fill hole, knife, delete, detach —
  all with live previews and full undo.
- Advanced selection: all / invert / grow / shrink, coplanar, similar,
  boundary, face loop & ring.
- Architectural trim: one-drag trim strips in six profiles, plus a Trim Walls
  tool that sweeps mitred trim along clicked wall faces (floor/ceiling-aware,
  doorway jambs break the run).
- Object tools: merge, mirror, center pivot, freeze transform,
  Poibuilderize (convert MeshInstance3D or CSG into an editable mesh), CSG
  booleans (union / subtract / intersect), smoothing groups & auto-smooth.
- Precision: toggleable grid snap, hold-V vertex snap, proportional (soft)
  editing with adjustable radius.

**Materials, UVs & dressing**

- Auto-UV projection: uniform 1 m repeat heuristic, textures never stretch on
  resize, persistent anchor keeps seams aligned, 45° diagonal tiling.
- Material & UV dock: palette, per-face assignment, drag-and-drop from the
  FileSystem, tiling/offset/angle controls, face tint.
- Multi-layer texture splatting (8 blend layers per face) and decal stamping
  with live preview, wheel-rotate and ctrl-wheel scale.
- Billboard sprite placement: always-armed sprite tab — pick a texture, click
  a surface, raise, scale; texture carousel on drag.
- Dedicated 2D UV editor: pan/zoom canvas, texture underlay, island/face
  selection sync, pop-out window.
- Animated UV scrolling with live viewport preview.

**Workflow**

- Persistent toolbar (tools, modes, ops, shapes, grid, docks, export) plus a
  draggable in-viewport readout/params panel; quick Lit / Cast Shadows
  toggles for selected objects; rebindable shortcuts for everything under
  Editor Settings → Shortcuts.
- Custom infinite cyan grid with adjustable unit/subdivisions/elevation and
  draw-on-grid mode.
- Export dialog: PBM (direct), retro-baked GLB, or modern GLB.
- Retro map viewer: 5 display modes, first-person play mode against exported
  colliders.

## Status

Experimental but actively developed. Every phase lands with a green headless
test suite (`./run_tests.sh`), and interaction changes go through human
sign-off. PoiBuilder targets **Godot 4.7** (the engine it is developed
against); older 4.x versions are untested.

### Install

1. Copy `project/addons/poibuilder/` into your project (or open this
   repository's `project/` directly).
2. Enable **PoiBuilder** in *Project Settings → Plugins*.
3. Create a shape via the **New Shape** menu in the toolbar under the 3D
   viewport and start editing.

## How this project is built

PoiBuilder is developed almost entirely by AI coding agents, directed and
sign-off-tested by a human: a 37k-line specification was extracted from the
Unity ProBuilder v6.1.2 source (`SPECIFICATION.md`), work is phased in
`IMPLEMENTATION.md`, and every commit carries a `Co-authored-by` trailer
naming the model that wrote it — the git history doubles as an experiment
log. A hardened headless suite (`run_tests.sh`, ~1100 tests / 21k
assertions, fails loudly if any test script was silently skipped) must stay
green, and retro performance claims require real PSP measurements.

**For agents:** don't take workflow cues from this README — everything you
need is in `CLAUDE.md`, `SPECIFICATION.md`, `IMPLEMENTATION.md`, and
`UNITY-GODOT-MAPPING.md`.

## License

MIT — see [LICENSE](LICENSE).
