---
title: Interface
lead: A toolbar that never hides, a floating overlay, a material dock, a UV bottom panel.
---

:::shot toolbar.png
Every operation is one click on the persistent row under the 3D toolbar.
:::

## Toolbar rows

The bar is a sibling *below* Godot's 3D toolbar. It stays visible with nothing selected; context buttons disable instead of vanishing.

**Row 1** — tools and mesh ops, plus the Env menu.

| Group | Buttons | Notes |
|---|---|---|
| Tools | [[btn:move]], [[btn:rotate]], [[btn:scale]] | The plugin's own tool. While editing, Godot's Q/V buttons are disabled. Shortcuts [[kbd:W]] [[kbd:E]] [[kbd:R]] still work. |
| Ops | [[btn:extrude]], [[btn:inset]], [[btn:bevel]], [[btn:bridge]], [[btn:connect]], [[btn:collapse]], [[btn:fill_hole]], [[btn:knife]], [[btn:loopcut]], [[btn:merge]], [[btn:subdivide]], [[btn:weld]], [[btn:detach]], [[btn:delete]] | Grey = wrong selection. Tooltip says what it needs. |
| Env | [[btn:env::Dawn / Day / Dusk / Night]] | Relights the edited scene. |

Scale tooltip, verbatim: axis handles scale freely; the **center square** scales all axes together (Shift + center on faces insets).

**Row 2** — modes, space, shapes, docks, export.

| Control | What it does |
|---|---|
| [[btn:object]] / [[btn:vertex]] / [[btn:edge]] / [[btn:face]] / [[btn:texture]] | Selection mode. Vertex [[kbd:H]], Edge [[kbd:J]], Face [[kbd:K]], Texture [[kbd:6]]. Object is the toolbar button (unbound by default). |
| [[btn:space]] | Cycles Element / Object / World ([[kbd:X]]). |
| [[btn:new_shape]] | Always enabled. Pick a primitive, then drag. |
| [[btn:ngon]] | Draw a polygon, extrude it. |
| [[btn:edit_params]] | Live only while the selected mesh is a pristine, unedited factory shape. |
| [[btn:materials::Material]] | Focuses the Material & UV dock. |
| [[btn:uv::UV]] | Opens the 2D UV editor bottom panel. |
| [[btn:panel::Panel]] | Pins the overlay so it does not auto-hide. |
| [[btn:recover::Reset]] | Docks the overlay back to the bottom-left. |
| [[btn:settings]] | Display: grid, wireframe, selection/hover opacity. |
| [[btn:export]] | Dialog: PBM (default) or GLB — modern bake (lightmap-ready, first) / retro baked map (vertex-lit). |
| [[btn:docs]] | Opens this site (bundled `docs-site/index.html`). |

**Rows 3 & 4** (extended tools) — grid & snapping settings, selection suite, auto-smooth, object state, snapping toggles, object tools, CSG booleans, Trim Walls. They ship **visible**; fold them with the [[btn:split_rows::Extended Tools]] toggle — the state is remembered across sessions.

| Group | Controls | What it does |
|---|---|---|
| Grid & snapping | Grid, snap-step readout | Grid settings moved here when row 3 exists — it has the room for the readout. |
| Selection | [[btn:select_all::All]], [[btn:invert_selection::Invert]], [[btn:grow_selection::Grow]], [[btn:shrink_selection::Shrink]], [[btn:select_coplanar::Coplanar]], [[btn:select_similar::Similar]], [[btn:select_boundary::Boundary]], [[btn:face_loop::Loop]], [[btn:face_ring::Ring]] | Advanced selection suite. Invert [[kbd:Ctrl]]+[[kbd:I]], Grow [[kbd:Alt]]+[[kbd:G]], Shrink [[kbd:Shift]]+[[kbd:Alt]]+[[kbd:G]], Coplanar [[kbd:Alt]]+[[kbd:C]], Loop [[kbd:Alt]]+[[kbd:L]], Ring [[kbd:Alt]]+[[kbd:R]]. |
| Object state | [[btn:obj_lit::Lit]], [[btn:obj_shadow::Cast Shadows]] | Shading and shadow casting for every selected object (PBMesh, MeshInstance3D, CSG). Mixed-checkbox semantics: all on = checked, all off / mixed = unchecked, and checking synchronizes the whole selection. Rebindable as *Object: Toggle Lit / Cast Shadows*. |
| Objects | [[btn:merge_objects]], [[btn:mirror]], [[btn:center_pivot]], [[btn:freeze_transform::Freeze Xform]], [[btn:poibuilderize]] | Combine meshes, mirror across X, recenter pivot to bounds, bake transform into vertices, convert MeshInstance3D/CSG to PBMesh. |
| CSG | [[btn:csg_union]], [[btn:csg_subtract]], [[btn:csg_intersect]] | Real-time CSG booleans with full undo. Select target first, cutter last. |
| Smoothing | [[btn:smooth_auto::Auto Smooth]] | Recalculate smoothing groups by dihedral angle (45° threshold). |
| Snapping & Tools | [[btn:vertex_snap::V-Snap]], [[btn:proportional::Soft]] (proportional) + radius spinner, [[btn:trim_walls]] | Snapping to vertices, proportional editing with smooth falloff, and interactive wall-clicking trim. |
## Overlay

A compact floating panel in the viewport.

- Selection readout while something is selected.
- Drag readout while dragging.
- Params modal for shape create and bevel.
- **⚙ Edit Emitter Properties** while a placed particle emitter is in the
  selection — the fine-tuning surface for [emitters](paint.html#sprite-placer)
  (count, size, speed, spread, blending, flipbook). It works from object
  mode too; the emitter session stays open even while no mesh is selected.
- Drag it by the header. Pin with [[btn:panel::Panel]]. Recover with [[btn:recover::Reset Panel]].

Params modal rules (do not mix these up):

- **Shape create / Edit Params:** Apply commits, Cancel restores. Clicking elsewhere **cancels**.
- **Bevel:** clicking elsewhere **applies**.
- Any mode or tool change applies the open modal first.
- [[kbd:Esc]] before the confirming create-click creates nothing.

## Docks

- **Material & UV** — six modes on one dock: **Material & UV** (palette,
  per-face assignment), **Texture Paint** (the splat brush), **Stamp**
  (decals), **Sprite** (billboard placement), **Shapes** (always-armed
  primitive placement), and **Particles** (click-to-place emitters). See
  [Materials](materials.html) and [Paint & stamps](paint.html).
- **UV Editor** — bottom panel, can pop out to a window. See [UV editor](uv.html).

## Status

During creation the overlay shows a hint (base drag, then height). Extents print in metres. Directional shapes (doors, stairs) display an orange facing arrow on the base plane; holding [[kbd:Ctrl]] locks the arrow direction so lateral sizing won't flip the facing. Environment presets write a scene meta the export reads. While a placement mode is armed (paint, stamp, sprite, shapes, particles) a small banner at the top of the viewport names it and how to leave it — it is a pure readout and never eats clicks.

> [gotcha] The toolbar never hides. If a button is grey, read its tooltip — it is waiting for faces, or edges, or two objects.
