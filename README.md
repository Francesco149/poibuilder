# PoiBuilder

A free, open-source **ProBuilder / UniBuilder-style mesh building plugin for
Godot 4** — primitives, drag-to-create, and direct vertex/edge/face editing
inside the editor, auto UVs in the spirit of Unity's ProBuilder. One click export to baked glb or custom pbm format optimized for retro pipelines, tested on a real Sony PSP.

**Pure GDScript**: PoiBuilder is written 100% in standard GDScript. It runs in the standard Godot 4 editor (no Godot Mono / .NET build required) and needs **no C/C++ compilation, no GDExtension, and no native binaries** — just drop the `addons/poibuilder/` folder into any standard Godot 4 project and enable it.

https://github.com/user-attachments/assets/a2052e4c-fa6e-4c8b-a0ea-e3ae500fbac6

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


### Author Once, Target Everywhere: Modern Engines + Retro Hardware

PoiBuilder bridges the gap between **modern 3D level authoring** and **hardcore retro hardware constraints**:

- **Modern Engine Target (glTF / GLB)**: Author complex scenes using native PBR materials, multi-layer alpha splatting, decal stamps, arbitrary n-gons, and curved geometry — exported directly to standard `.glb` for modern engines (Godot 4, Unreal, Unity, WebGL).
- **Dedicated Retro Target (PoiRetro `.pbm` v3 — measured on real Sony PSP hardware)**: One-click export to a zero-overhead binary map format tailored for fixed-function hardware (PlayStation Portable MIPS Allegrex 333MHz, Dreamcast, PS2, custom retro engines). v3 adds animated UV scrolling, three-valued alpha modes and the standard `emitters` lump; v1/v2 files still load.
  - **Zero-CPU Direct DMA**: Interleaved 24-byte vertex structures (`float u,v; uint32_t color; float x,y,z;`) matching Sony GU hardware registers (`GU_TEXTURE_32BITF | GU_COLOR_8888 | GU_VERTEX_32BITF | GU_TRANSFORM_3D`), 16-byte aligned for direct display list DMA rendering with zero runtime vertex conversion.
  - **Power-of-Two 4x4 Tile Atlasing**: Packs 128x128 baked splat/stamp tiles into 512x512 atlases with edge-to-edge UV slot mapping, cutting draw calls and texture swaps by ~85% (81 $\rightarrow$ 12 calls).
  - **Load-Time Mip Chains, and the LOD policy that makes them pay (the single biggest PSP win)**: swizzled mip chains are built for every texture at load — including cutout foliage, whose chain uses an alpha-preserving combine so the silhouette does not erode — and sampled with a single-level mipmap filter. Without a chain, every minified surface pays a texture-cache miss per fragment: a 512x512 texture measures **25 Mfrag/s** against **480 Mfrag/s** for a cache-resident one, a 19x penalty. The level the hardware picks is "sharpest that averages ~1 texel/pixel", so the shipped policy biases it one step coarser and pins the baked splat/stamp meshes to one constant level. Measured on the device, at the worst view in the showcase (the foot of the waterfall): **25.2 ms → 2.79 ms per frame** when the bias moved from −1 to +1, and the stairs view 11.1 → 0.11 ms. The whole camera sweep now runs at **2.4-5.0 ms/frame (200-450 fps)**.
  - **Native 16-bit Swizzled Textures**: Direct `RGBA5551` conversion and memory swizzling (16-byte $\times$ 8-row tiles), cutting VRAM bandwidth in half and eliminating GPU texture cache thrashing.
  - **Pre-Baked Vertex Lighting & AO**: Direct sunlight, point lights, raytraced shadow casting, and Fibonacci hemisphere ambient occlusion pre-baked into 32-bit vertex colors (`0xAABBGGRR`) for rich atmospheric lighting with zero runtime lighting cost.
  - **Guardband Clipping & Spatial Chunking**: large surfaces are subdivided into spatial chunks ($\le 384$ vertices) and the near plane sits at 8cm. On-device profiling later showed the clipper was never the bottleneck for this scene — a guardband-crossing quad costs the same with clip planes on and off — so treat this as headroom, not as the reason it runs fast; textures were.
  - **Arbitrary Binary Metadata & Entity Scripting**: Extensible lump table embedding level descriptors, waypoints, and animated scripted entities (e.g. cyclic patrol spheres) directly within the map binary.
  - **Native Physical Collision**: Automatic extraction of box, trimesh, and ramp collision hulls for instant player traversal and raycasting.
  - **Standalone Homebrew Player & Viewer**: Includes native C PSP homebrew application (`EBOOT.PBP`, 60 FPS fly camera, HUD) and standalone Godot retro viewer with live physics play mode.
  - **Stateless Particle Emitters (format standard)**: an emitter is a looping, stateless stream — particle *i*'s state at time *t* is a closed form of `(t, i, seed)`, so a runtime evaluates a few flops per particle with no simulation, no allocation and one draw call per emitter. Authored as ordinary `GPUParticles3D` nodes; the file's `emitters` lump carries position/direction/spread, speed/life ranges, gravity, damping, size and colour curves, rotation/spin, wobble, flipbook grid, blend flags and the seed. Additive emitters need no sorting; blended ones are drawn back-to-front. The whole 256-particle budget measures 0.72 ms gpu / 1.14 ms cpu on the device.
  - **Known limitation — grazing-angle LOD seams**: on tiled floors viewed at a shallow angle, a step in sharpness appears where neighbouring tile quads meet, because the Graphics Engine derives texture LOD **per primitive** and the hardware has no anisotropic filtering or per-surface LOD smoothing. Ruled out by measurement: mipmapping, atlas mip bleeding, coplanar z-fighting. The practical mitigation now ships by default — the painted splat/stamp meshes are pinned to one constant mip level, which removes the step entirely for ~0.4 ms — and `retro_engine/psp/HARDWARE-TESTING.md` records the whole investigation, including the knobs (`bias`, `level_mode`, `detail_*`) and what was already ruled out. **Contributions that remove the residue without giving up per-surface LOD are welcome.**
  - **Measured, not assumed**: every performance claim in this repository comes from `./run_psp_hw.sh` running the map on a real PSP over USB — cpu/gpu split per frame, a camera sweep, per-stage ablations and synthetic calibration probes. PPSSPP cannot price a PSP frame (it rasterises on the host GPU), so it is used for correctness and visuals only. `retro_engine/psp/OPTIMIZATION.md` is the engine's full optimization inventory; `retro_engine/RETRO-AUTHORING.md` is the authoring-side recipe book; `SPEC_RETRO_FORMAT.md` §11 tells an engine author how to get the same behaviour.
## Status

Experimental but actively developed. Every phase lands with a green headless
test suite (`./run_tests.sh`), and interaction changes go through human
sign-off checklists (open `test_scenes/human_test_phase6.tscn` in the editor
and follow the printed checklist). PoiBuilder targets **Godot 4.7** (the
installed engine it is developed against); older 4.x versions are untested.

### Install

PoiBuilder is pure GDScript — it works on both standard Godot and Godot .NET without compiling any extensions:
1. Copy `project/addons/poibuilder/` into your project (or open this
   repository's `project/` directly).
2. Enable **PoiBuilder** in *Project Settings → Plugins*.
3. Select any `PBMesh` node (or create one via the **New Shape** menu in the
   toolbar under the 3D viewport) and start editing.

## Feature checklist

What we have today vs. what we'd want for the desired UniBuilder-style
workflow.

**Currently works:**

- [x] **14 primitives** (cube, stairs, curved stairs, prism, cylinder, plane,
      door, pipe, cone, sprite, arch, sphere, torus, ngon)
- [x] **ProBuilder-style drag creation**: drag the base coplanar to any surface
      (floor, walls, on top of objects) or the grid, release, move to set the
      height along the surface normal, click to confirm; axis-aligned
      snapping; ESC aborts without creating anything
- [x] **Shape parameter modals** with live preview (steps, sides, radius, ...)
      plus an Edit Params button for pristine shapes
- [x] **Object / vertex / edge / face selection modes** with hover + selection
      highlights (cyan hover, yellow selection), rubber-band multi-select,
      occlusion-aware picking
- [x] **Edge loop select** (Alt+click or double-click)
- [x] **Move / rotate / scale via native editor gizmos** at the element pivot,
      with Element / Object / World orientation spaces
- [x] **Center square scale handle** for uniform pivot-centered scaling, plus
      Shift+Center for uniform face insetting
- [x] **Smart drag gestures**: Shift+Move extrudes faces/edges, Shift+Scale
      insets faces (aspect locked)
- [x] **Mesh ops**: extrude faces/edges, inset, loop cut, subdivide, merge
      (including non-coplanar regions), weld vertices, delete, detach
      (keeps the source transform) — all undoable
- [x] **Knife tool & N-gon shape extrusion**: interactive multi-point polygon
      drawing on any surface with grid/vertex snapping; edge-to-edge face cuts,
      interior hole cuts, and direct 3D n-gon prism extrusion
- [x] **Auto-UV projection & texturing**: uniform 1x1m meter repeat heuristic
      across walls, floors, and slopes; textures never stretch when geometry is
      resized; persistent object-space texture anchor keeps coplanar seams aligned;
      45° diagonal tiling with corner-anchoring; seam-continuous extrude UVs
- [x] **Toggleable Material & UV Dock**: thumbnail palette, swatch grid,
      per-face material assignment, and drag-and-drop materials from the dock or
      FileSystem onto 3D faces
- [x] **Multi-layer texture splatting & decal stamping**: up to 8 terrain-style
      blend layers per face with non-stretching persistent bounds; high-resolution
      billboard decal stamping with upright orientation; stamp delete tool;
      billboard sprite placement tool with 5-texture carousel
- [x] **PoiBuilder grid & snapping**: custom procedural infinite-horizon cyan
      grid (`RenderingServer`), adjustable unit / subdivisions / elevation
      (`[` and `]` keys with auto-repeat), draw-on-grid mode, and bidirectional
      engine snap synchronization in Object mode
- [x] **Retro Map Export Pipeline (`PBMapExporter`)**:
      - **Retro Baked Tilemap Mode**: exports fully baked maps tailored for classic
        engines (Quake, GoldSrc, custom software renderers).
      - **Grid-Aligned Quad Subdivision (`PBFaceSubdivider`)**: subdivides geometry
        along the 1m texture grid. Clean 2D perimeter slicing decomposes stepped stairs
        into 8 clean rectangular step columns and doorways into clean quads with
        zero radiating corner fans and zero slivers.
      - **Tile-Based Texture Baking (`PBTileBaker`)**: unique composite textures are
        baked only for painted/stamped areas; unpainted tiles share base textures.
      - **Vertex Color Lighting Bake (`PBLightBaker`)**: direct lighting (Directional,
        Omni, Spot), sharp ray-traced shadows, and multi-sample Fibonacci hemisphere
        ambient occlusion (AO) baked into vertex colors.
      - **Modern GLB Export**: exports native geometry with decal child quads and
        metadata tags (`poi_stamps`, `poi_paint`).
      - **Dedicated Export Dialog & Toolbar Button**.
- [x] **Standalone Retro Map Viewer (`run_viewer.sh`)**: free-flight WASD camera,
      live scene stats, 5 display modes (`[1]` Full Baked, `[2]` Vertex Lighting/AO,
      `[3]` Textures Only, `[4]` High-contrast wireframe with 3 styles, `[5]` Collider
      inspection) plus a first-person **play mode** (`P`) that spawns a character
      against the exported colliders
- [x] **Animated UV scrolling textures** (PBM 3.0): speed authored on the material,
      live in the editor viewport, carried through the GLB round trip (`poi_uv_scroll`)
      and replayed identically in the viewer and on the device — including soft-alpha
      blend modes through the whole pipeline
- [x] **Particle emitters as part of the retro format** (`emitters` standard lump):
      authored as `GPUParticles3D`, exported as stateless emitter records, rendered
      with one draw call each and measured on PSP hardware
- [x] **PSP renderer with a measured LOD policy**: load-time mip chains (alpha-preserving
      for cutouts), a single-level mipmap filter with a +1 level bias, and per-mesh
      pinning for painted splat/stamp detail — the fixes behind the waterfall view going
      from 25 ms to 2.8 ms per frame on device
- [x] **Full undo/redo** through the editor's own history, incl. whole gestures
- [x] **Persistent toolbar** (tools, modes, ops, shape menu, grid, material, export)
      + a compact, draggable, collapsible overlay panel
- [x] **Node transforms respected throughout**; half-size manipulator gizmo by default

**Remaining future roadmap:**

- [ ] Additional mesh ops: bevel edges, connect edges, bridge faces, fill hole,
      mirror geometry
- [ ] Mirror / symmetry mode and array/duplicate tooling
- [ ] Soft selection and proportional editing
- [ ] Comfort on large meshes (>10k faces)
- [ ] UX hardening, documentation, and general polish
## How this project is built

The unusual part: **PoiBuilder is developed almost entirely by AI coding
agents**, directed and sign-off-tested by a human. The process:

1. **Spec.** A Gemini-produced specification (`SPECIFICATION.md`) was
   extracted from the Unity ProBuilder v6.1.2 source: ~37k lines, 201
   sections, 711 citations. It turned out to be genuinely useful — the fine
   semantic details (winding conventions, what "extrude" means to the data
   model, selection UX minutiae) would have taken enormous effort to
   rediscover by black-boxing ProBuilder.
2. **Plan.** `IMPLEMENTATION.md` breaks the work into phases (core data
   model → math/topology → shape generators → editor integration → element
   picking → manipulation → mesh ops → UX rounds), each gated by mandatory
   verification steps.
3. **Implement.** A rotating cast of frontier models (Claude, Grok, GLM and
   others) implements phases and fix rounds in agent sessions. Each commit
   carries a `Co-authored-by` trailer documenting exactly which model wrote
   it — the git history doubles as an experiment log.
4. **Verify.** A hardened headless test suite (`run_tests.sh`, currently **834
   tests / ~15.9k assertions** across 54 files, and it fails if any test script
   was silently skipped) must stay green, and every phase ends with a human
   sign-off checklist driving the next round of fixes. Most of the real UX
   quality comes from those sign-off rounds rather than the first pass. Retro
   and PSP work additionally goes through the **device battery** on real
   hardware — see "Measured, not assumed" above.

**Brick walls we hit (and how they fell):**

- The first hand-rolled input/gizmo/overlay stack fought the editor's own
  selection, transform gizmo, and rubber-band machinery. It was deleted and
  rebuilt on Godot's native subgizmo API (`EditorNode3DGizmoPlugin`), which
  gave picking, multi-select, gizmo drags, snapping, and undo for free.
- Unity-style CCW winding vs. Godot's CW front faces (and per-position
  normals) caused inverted/invisible geometry until pinned by a ground-truth
  regression test; the convention is now locked and documented.
- Element identity subtleties: edges/vertices must be compared through weld
  groups (coincident position groups), never raw position indexes — half the
  cube's edges were literally unselectable until that was understood.
- Engine quirks: the transform gizmo only adopts a subgizmo's basis while
  the editor's "Use Local Space" toggle is on; the 3D toolbar layout is
  version-sensitive; mutating an ArrayMesh in place doesn't refresh the
  viewport; `EditorUndoRedoManager` needs a custom context object or actions
  land in the wrong undo history. Each is documented in `CLAUDE.md`.
- GUT silently skips test scripts that fail to parse while still reporting
  green — the test runner now detects that (this exact hole once let a
  normals bug reach a human sign-off).

**For agents:** don't take workflow cues from this README — everything you
need is in `CLAUDE.md`, `SPECIFICATION.md`, `IMPLEMENTATION.md`, and
`UNITY-GODOT-MAPPING.md`.

## License

MIT — see [LICENSE](LICENSE).
