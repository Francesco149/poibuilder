# PoiBuilder End-User Documentation — Execution Roadmap

This is the plan for writing the **full end-user documentation** (a static
HTML site bundled with the extension) and the **next showcase-video refresh**.
It is written to be mechanically executable by an agent across multiple
sessions: every page has a content spec, a source-of-truth table, and an
acceptance checklist. Follow the sessions in order; each one ends green
without needing the next.

**Status marker for every session:** `[ ]` not started, `[x]` done (update
this file in the same commit). When a session's work changes behavior, also
bump the version and log it in `CHANGELOG.md` per the project convention.

---

## 0. Goals and hard constraints

1. **Audience**: a Godot 4 user who has never used ProBuilder/UniBuilder.
   Task-first ("how do I make a doorway with trim"), not code-first. The
   reader never sees class names except `PBMesh` (the node type they will
   see in the scene tree).
2. **Format**: static HTML, no JS frameworks, no external CDN requests
   (the site must work offline inside an extension ZIP). One CSS file. A
   single sidebar nav shared by all pages.
3. **Bundling**: the BUILT site ships inside the extension distribution
   (e.g. `addons/poibuilder/docs-site/` in the ZIP, linked from the
   Project Settings → Plugins description and the toolbar Help entry).
   The built output is a REGENERABLE ARTIFACT and is **never committed**
   (project rule: if a script can produce it, it does not belong in git).
   Only the SOURCES are committed: Markdown pages, CSS, and the build
   script.
4. **Language**: English, second person, present tense. Every feature page
   follows the same skeleton: What it is → When to use it → Step by step →
   Parameters → Keys → Gotchas.
5. **Screenshots and GIFs are regenerated, not hand-managed**: a capture
   script (session 2) records them through the existing Xvfb harness the
   same way `showcase_video/render.sh` does; the images live in a
   gitignored `docs/site/assets/` and are rebuilt by
   `docs/site/build.sh --assets` whenever stale. Never hand-commit a PNG
   (rule 4 of `.pi/ORIENTATION.md`).

## 1. Build system (session 1)

- [ ] Create `docs/site/` with:
  - `pages/*.md` — one Markdown file per page (the inventory below).
  - `template.html` — one layout: header (version string injected from
    `plugin.cfg`), sidebar nav (generated from `pages/` order file
    `nav.txt`), content body, prev/next links.
  - `build.py` — **stdlib-only** Python: Markdown → HTML. Do not add a
    dependency on pip packages; if tables or fenced code are awkward with
    the stdlib, vendor a single-file Markdown converter into
    `docs/site/vendor/` with its license header, or write the ~200-line
    subset needed (headings, paragraphs, lists, tables, fenced code, bold/
    italic/links/images). Deterministic output (sorted dict iteration, no
    timestamps) so rebuilds don't churn the tree.
  - `build.sh` — runs `build.py` into a **gitignored** `out/`, and
    `--assets` re-captures screenshots first. Print a link check summary:
    every internal link and every image must resolve, else exit nonzero
    (wire this into the acceptance of every later session).
- [ ] Add `docs/site/out/` and `docs/site/assets/` to `.gitignore` with a
      comment naming the regenerating command.
- [ ] Acceptance: `./docs/site/build.sh` produces a browsable site from one
      placeholder page; the link check passes; `git status` shows no build
      output; a second build is byte-identical.

## 2. Screenshot capture harness (session 2)

Reuse the showcase machinery instead of inventing: `showcase_video/render.sh`
boots a real editor under Xvfb and drives sessions from
`project/showcase/sessions/*.gd` against `showcase_director.gd`.

- [ ] Add `docs/site/capture_sessions/*.gd` — one tiny session per screenshot
      (arrange the scene, position the camera, call the director's frame
      grab). A screenshot is a one-frame session; captions are added in
      Markdown, not baked into images.
- [ ] `docs/site/build.sh --assets` runs each capture session into
      `docs/site/assets/<name>.png` (720p, UI visible, the editor theme the
      plugin ships with).
- [ ] Acceptance: `--assets` rebuilds all images deterministically from an
      empty assets dir; committing the tree without `assets/` still builds
      (links break loudly — that's the check working).

## 3. Page inventory and content specs (sessions 3–10)

Order = sidebar order (`nav.txt`). For every page the source-of-truth table
lists where the FACTS come from — copy from these, never invent; if a page
needs a fact none of the sources have, that's a bug to file, not a gap to
paper over.

### 3.1 Welcome & Install (session 3)
- Facts: `README.md` (install steps, Godot version), `plugin.cfg`.
- Content: what PoiBuilder is (ProBuilder/UniBuilder-style building inside
  the Godot editor); install (copy `addons/poibuilder/`, enable in
  Project Settings → Plugins); what appears (the toolbar row under the 3D
  toolbar, the overlay panel, the Material & UV dock); creating the first
  cube via New Shape and moving a face — the 60-second win; a link to the
  bundled video; where the docs live (offline).
- Gotcha to state: pure GDScript, works on standard Godot and .NET; targets
  Godot 4.7.

### 3.2 Interface tour (session 3)
- Facts: `editor/pb_toolbar.gd` (every button's tooltip is canonical),
  `gui/overlays/pb_tool_overlay.gd`, `orientation/architecture.md`,
  `orientation/selection.md`.
- Content: annotated screenshot of the toolbar rows (tools, modes, ops,
  extended Row 3/Row 4 toggles, shapes group incl. Trim Walls, docks,
  export); the floating overlay panel (selection readout, drag readout,
  params modal, drag by header, pin via Panel toggle, recover button);
  the Material & UV dock; the status hints (creation hints, extents
  readout); environment presets button.
- Gotchas: the toolbar never hides; disabled buttons mean "wrong selection
  context for this op" — the tooltip says what context is needed.

### 3.3 Creating shapes (session 3)
- Facts: `editor/pb_shape_creator.gd` doc comment, `shapes/pb_shape_params.gd`
  (`get_param_defs` is the canonical parameter list per shape),
  `orientation/architecture.md`.
- Content: the drag language (press on any surface — PBMesh face or grid —
  drag the base coplanar, release, move to set height, click to confirm;
  Ctrl locks the drag direction; Alt shows the height plane; Esc aborts with
  nothing created); draw-on-grid mode (G); the 15 primitives with a one-line
  use case each (cube, stairs, curved stairs, prism, cylinder, plane, door,
  pipe, cone, sprite, arch, sphere, torus, ngon, trim); the params modal
  (live preview, Apply/Cancel, Esc semantics); Edit Params (only for
  pristine, unedited shapes — say why); snap-to-surface starting points.
- Use cases to walk through: a staircase between two floors; an arched
  doorway; a torus column base; a sprite billboard.

### 3.4 Selecting things (session 4)
- Facts: `orientation/selection.md` (THE contract), `editor/pb_actions.gd`
  (keys), `editor/pb_selection_ops.gd`.
- Content: the five modes (Object H?/J/K/6 — object/vertex/edge/face/texture;
  state the actual keys from `pb_actions.gd`); hover vs selection colors
  (cyan hover, yellow selection); click, shift-click, rubber-band;
  edge loop select (Alt+click / double-click); mode-switch CONVERSION
  (selecting a face then pressing J selects its edges — ProBuilder parity);
  the advanced suite: All, Invert (Ctrl+I? — copy from actions), Grow, Shrink,
  Coplanar, Similar, Boundary, Loop, Ring (toolbar buttons + keys);
  multi-object selection semantics — object mode moves several meshes,
  entering an element mode narrows editing to the last-clicked mesh.
- Use case: select all coplanar faces of one wall to retexture it; grow a
  floor selection to find a leak; select a boundary edge loop before Fill Hole.

### 3.5 Moving things (session 4)
- Facts: `orientation/selection.md` (drag protocol), `pb_tool_bridge.gd`,
  `pb_actions.gd`.
- Content: Move/Rotate/Scale on vertices/edges/faces via the gizmo; the
  Element/Object/World space cycler (X) and what each means; the center
  square handle (uniform scale; Shift+center = uniform face inset);
  Shift+Move = live extrude, Shift+Scale = live inset; snapping: Y toggles
  snap, hold-V vertex snap across meshes, proportional editing toggle +
  radius spinner (what falloff does to a "soft" move); grid keys
  ([ ] elevation, +/- subdivision, Ctrl +/- unit, \ reset).
- Use case: pull a doorway up to exact grid height with vertex snap;
  soften-raise a terrain patch with proportional editing.

### 3.6 Mesh operations (sessions 5–6 — biggest pages)
- Facts: `.pi/orientation/mesh_ops.md`, `mesh_ops/*.gd` doc comments,
  `CHANGELOG.md` entries per op, toolbar tooltips.
- One page per group, each op = What/When/Steps/Keys/Gotcha:
  - **Structural**: Extrude (faces/edges, the Shift+Move gesture, edge
    fins), Inset, Loop Cut (select an edge crossing a quad ring), Subdivide,
    Merge Faces (n-gons), Knife (multi-point cuts: edge-to-edge, interior
    holes), N-gon prism.
  - **Holes & joins**: Bridge (two boundary edges), Connect, Collapse,
    Fill Hole, Weld (vertices at centroid), Delete, Detach (into a new
    object).
  - **Bevel** deserves its own sub-page: distance + segments, live modal,
    face bevel vs edge bevel, the rounded-dome corner behavior, "keeps
    selection on the new band".
- Universal gotchas to document: welds make edges/vertices selectable as
  one (coincident corners); topology-rewriting ops undo as whole-mesh
  snapshots; ops that create faces select their output.

### 3.7 Trims (session 6)
- Facts: the Unibuilder spec paragraphs (in `SPECIFICATION.md`/`ROADMAP.md`
  history), `editor/pb_shape_creator.gd` `_trim_placement` doc comment,
  `editor/pb_trim_walls_tool.gd` doc comment (both are written as user-facing
  contracts already).
- **Trim (one drag)**: drag on the floor from the wall — the strip stands up
  flush on the edge you started from; the longer side of the drag is the
  length; depth is never dragged (retyped in the panel; the project remembers
  the last depth); six profiles (Flat, Chamfer, Round, Cove, Ogee, Stepped);
  Upside Down turns a skirting into its cornice twin; Flip Side; drawn on a
  wall it lies flat with its bottom on the drag's lower edge.
- **Trim Walls**: arm from the toolbar; parameters appear immediately;
  click wall faces on any PoiBuilder mesh in any order (teal hover, amber
  chosen); click again to drop, Backspace drops last, Enter / double-click /
  Apply commits, Esc cancels; mitred corners at any angle; overlapping walls
  carry trim on the visible run only; a perimeter closes into a ring; a
  doorway breaks the run at the jambs; Placement Bottom/Top + Offset
  (skirting on the slab even when wall cubes reach below it; cornice tucks
  under the ceiling); result is ONE object whose Edit Params stays live for
  the same walls.
- Use case: dress a room — skirting all round (click 4 walls, Enter), a
  cornice at the ceiling (Placement Top), a dado rail between (Offset).

### 3.8 Materials, UVs and painting (session 7)
- Facts: `gui/docks/pb_material_dock.gd`, `editor/uv/*.gd`, `materials/`,
  `core/pb_splat.gd`, CHANGELOG (auto-UV rules).
- Content: the material dock (palette, swatch grid, per-face assignment,
  drag-and-drop from FileSystem onto faces); auto-UV (1×1 m repeat, no
  stretching on resize, coplanar seam anchoring, diagonal tiling);
  multi-layer splatting (up to 8 layers per face, paint mode);
  decal stamps (high-res billboards, upright, stamp delete); the sprite
  placer (B, carousel, raise, scale); animated UV scrolling (speed on the
  material, lives through export); **the 2D UV editor** — opening it,
  pan/zoom, texture underlay, wireframe, face/island selection sync, 2D
  transforms, projections, pop-out window; smoothing groups & auto-smooth
  (45°) — what smoothing does to lighting.
- Use case: fix a stretched texture on a ramp (UV editor + projection);
  paint a grass-to-rock blend; put a poster on a wall (stamp); make a
  waterfall (scrolling UV plane).

### 3.9 Object tools & CSG (session 7)
- Facts: `editor/pb_object_ops.gd` doc comments, `mesh_ops/pb_csg.gd`,
  toolbar tooltips (they encode the operand rules).
- Content: Merge Objects, Mirror, Center Pivot / Set Pivot to Selection,
  Freeze Transform; **Poibuilderize** — turn any MeshInstance3D (a GLB you
  dragged in: instantiate → editable children → copy the MeshInstance3D →
  select → Poibuilderize) or a Godot CSG shape (including CSGCombiner3D)
  into an editable mesh; CSG booleans — select target FIRST then cutter
  LAST (Subtract removes the last-selected from the first-selected),
  works across PoiBuilder/mesh/CSG nodes, undo puts the cutter back.
- Gotchas: CSG booleans require watertight operands (the error names the
  open boundary count); Poibuilderize duplicates per-triangle corners
  (heavy meshes stay heavy).

### 3.10 Grid, export & retro (session 8)
- Facts: `editor/pb_grid.gd`, `export/` docs, `retro_engine/RETRO-AUTHORING.md`
  (adapt, don't duplicate — link the deep content), SPEC_RETRO_FORMAT intro.
- Content: the PoiBuilder grid (unit, subdivisions, elevation, draw-on-grid,
  engine snap sync); the Export dialog (modern GLB; retro baked tilemap with
  tile baking, vertex lighting + AO, collision hulls); the retro `.pbm`
  pipeline in one overview page that hands off to RETRO-AUTHORING.md content
  (authoring knobs, what the export bakes, performance rules); environment
  presets; where exports land (gitignored, regenerated).

### 3.11 Keys reference + FAQ (session 8)
- Facts: `editor/pb_actions.gd` (the ENTIRE table — generate this page FROM
  the action table in `build.py`? No: actions are rebindable in Editor
  Settings; generate a static table at build time by parsing
  `pb_actions.gd`, and say "rebindable in Editor Settings → Shortcuts").
- FAQ/troubleshooting: "a button is greyed out" (selection context); "my
  click selected the wrong thing after multi-select" (element modes edit the
  last-clicked mesh); "CSG did nothing" (read the Output log — watertight
  check); "my GLB has no gizmo" (Poibuilderize it first); "undo removed my
  cutter" (it comes back with CSG undo); "the overlay disappeared" (Panel
  toggle / recover button); "textures stretch" (auto-UV + UV editor).

## 4. Polish and bundling (session 9)

- [ ] Responsive-ish layout (max-width column, collapsible sidebar via CSS
      only), print stylesheet (Godot users print PDFs more than anyone).
- [ ] Version stamp on every page; "docs built for PoiBuilder X.Y" matches
      `plugin.cfg` at package time.
- [ ] Link the site: a "Docs" button (SVG icon, 16×16, per the toolbar icon
      rule) that opens the bundled `index.html` with `OS.shell_open`, and a
      line in the plugin description.
- [ ] Acceptance: fresh clone → `./docs/site/build.sh` → the ZIP
      (`addons/poibuilder/` + `docs-site/`) is a working offline site; every
      page passes the link check; zero console errors in a browser.

## 5. Writing rules a weaker agent must not skip

1. Every keybind and button name is COPIED from `pb_actions.gd` /
   `pb_toolbar.gd` tooltips in the same session — never from memory, never
   from an older doc page (they rebind and rename).
2. Every step-by-step is EXECUTED once in the editor (or driven through the
   capture harness) before it is written down; a step that can't be
   reproduced is a doc bug, not a user error.
3. Screenshots show the CURRENT build (the overlay title shows the version —
   match it or re-capture).
4. No marketing adjectives; "fast", "easy", "powerful" are banned. Measured
   claims only, and retro performance claims keep their device row.
5. Each page ends with: next-page link, related keys, and the two or three
   gotchas most likely to cost a support question.

---

## 6. Showcase video refresh (parallel track — independent sessions)

The current README video predates the UV editor. All additions below are new
segments in the existing pipeline (`showcase_video/edl.toml` + sessions in
`project/showcase/sessions/*.gd`, rendered by `render.sh`, baked by
`build.sh`, reviewed via `review-sheet.png` — re-time or restyle without
re-rendering the editor).

- [ ] **UV editor tour (the big gap — ~20 s)**: select a wall face → open
      the UV dock → show the canvas with texture underlay → rotate/scale the
      island → show selection sync both ways (click a face in 3D, the island
      highlights; drag in 2D, the 3D face updates) → projection button on a
      ramp. Caption: "Dedicated 2D UV editor — seams under control".
- [ ] **Bevel (~8 s)**: select an edge loop → Bevel → drag distance in the
      modal, raise segments to a rounded fillet → Apply. Caption: "Bevel
      with live preview".
- [ ] **Trim, one drag (~8 s)**: drag along a wall base → release → the
      adjust panel flips the profile Ogee → Upside Down → Apply. Caption:
      "Skirting in one drag; six profiles".
- [ ] **Trim Walls (~15 s)**: arm the tool → click four wall faces around a
      room (teal→amber flashes) → Enter → the mitred ring appears; then
      Placement Top → the cornice tucks under the ceiling slab; click a
      doorway wall to show the jamb break. Captions: "Click walls, mitred
      corners", "Cornices tuck under the slab".
- [ ] **CSG booleans (~10 s)**: cube wall + cylinder cutter → select target,
      shift-select cutter → Subtract → hole appears → Ctrl+Z → cutter returns
      whole (this shot documents the fixed undo). Caption: "Booleans with
      real undo".
- [ ] **Advanced selection + snapping (~10 s)**: select coplanar on a
      staircase → grow by one ring → hold-V snap a vertex to the neighbor
      mesh → proportional soft-raise of a floor patch. Caption: "Select
      smart, snap exact, soften freely".
- [ ] **Poibuilderize (~8 s)**: drag a GLB in, select the MeshInstance3D,
      click Poibuilderize, pull a face. Caption: "Import anything, edit it
      natively".
- [ ] Re-cut the master: keep total ≤ 2.5 min; the new segments slot after
      the existing creation/editing beats and before the export/retro beats;
      regenerate the poster and review sheet; re-upload the README embed and
      swap the `user-attachments` URL.

---

## 7. Alpha gate (what "alpha" means here)

The feature surface is alpha-complete already (creation, editing, ops,
selection, materials/UV, trims, CSG, export). Alpha release checklist, in
order: sessions 1–2 (site builds), 3.1–3.5 (core pages), the video refresh
segments for Trim Walls + UV editor, 3.11 (keys + FAQ), then packaging
(session 9). Sessions 5–8 pages can land after the alpha ships — the bundled
site is versioned with the plugin, not frozen.
