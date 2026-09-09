# PoiBuilder

A free, open-source **ProBuilder / UniBuilder-style mesh building plugin for
Godot 4** — primitives, drag-to-create, and direct vertex/edge/face editing
inside the editor, in the spirit of Unity's ProBuilder.

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

https://github.com/user-attachments/assets/bc2a71ff-8978-433f-8258-80be66e44397

## Status

Experimental but actively developed. Every phase lands with a green headless
test suite (`./run_tests.sh`), and interaction changes go through human
sign-off checklists (open `test_scenes/human_test_phase6.tscn` in the editor
and follow the printed checklist). PoiBuilder targets **Godot 4.7** (the
installed engine it is developed against); older 4.x versions are untested.

### Install

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
      live scene stats, and 4 display modes (`[1]` Full Baked, `[2]` Vertex Lighting/AO,
      `[3]` Textures Only, `[4]` High-contrast wireframe).
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
4. **Verify.** A hardened headless test suite (`run_tests.sh`, ~590 tests /
   ~9.9k assertions) must stay green, and every phase ends with a human
   sign-off checklist driving the next round of fixes. Most of the real UX
   quality comes from those sign-off rounds rather than the first pass.

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
