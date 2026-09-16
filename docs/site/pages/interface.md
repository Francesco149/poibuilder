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
| Tools | [[icon:move]] Move, [[icon:rotate]] Rotate, [[icon:scale]] Scale | The plugin's own tool. While editing, Godot's Q/V buttons are disabled. Shortcuts [[kbd:W]] [[kbd:E]] [[kbd:R]] still work. |
| Ops | [[icon:extrude]] Extrude, [[icon:inset]] Inset, [[icon:bevel]] Bevel, [[icon:bridge]] Bridge, [[icon:connect]] Connect, [[icon:collapse]] Collapse, [[icon:fill_hole]] Fill Hole, [[icon:knife]] Knife, [[icon:loop_cut]] Loop Cut, [[icon:merge]] Merge, [[icon:subdivide]] Subdiv, [[icon:weld]] Weld, [[icon:detach]] Detach, [[icon:delete]] Del | Grey = wrong selection. Tooltip says what it needs. |
| Env | [[icon:env]] Dawn / Day / Dusk / Night | Relights the edited scene. |

Scale tooltip, verbatim: axis handles scale freely; the **center square** scales all axes together (Shift + center on faces insets).

**Row 2** — modes, space, grid, shapes, docks, export.

| Control | What it does |
|---|---|
| [[icon:object]] Object / [[icon:vertex]] Vertex / [[icon:edge]] Edge / [[icon:face]] Face / [[icon:texture]] Texture | Selection mode. Vertex [[kbd:H]], Edge [[kbd:J]], Face [[kbd:K]], Texture [[kbd:6]]. Object is the toolbar button (unbound by default). |
| [[icon:space]] Space | Cycles Element / Object / World ([[kbd:X]]). |
| Grid | Opens grid & snap settings. Readout shows the current snap step. |
| [[icon:new_shape]] New Shape | Always enabled. Pick a primitive, then drag. |
| [[icon:ngon]] N-Gon | Draw a polygon, extrude it. |
| [[icon:edit_params]] Edit Params | Live only while the selected mesh is a pristine, unedited factory shape. |
| [[icon:materials]] Material | Focuses the Material & UV dock. |
| [[icon:uv]] UV | Opens the 2D UV editor bottom panel. |
| [[icon:panel]] Panel | Pins the overlay so it does not auto-hide. |
| [[icon:panel_reset]] Reset | Docks the overlay back to the bottom-left. |
| [[icon:settings]] Settings | Display: grid, wireframe, selection/hover opacity. |
| [[icon:docs]] Export | Retro baked map or modern GLB. |
| [[icon:docs]] Docs | Opens this site (bundled `docs-site/index.html`). |

**Rows 3 & 4** — the [[icon:split_rows]] **Extended Tools** toggle.

| Group | Controls | What it does |
|---|---|---|
| Selection | [[icon:all]] All, [[icon:invert]] Invert, [[icon:grow]] Grow, [[icon:shrink]] Shrink, [[icon:coplanar]] Coplanar, [[icon:similar]] Similar, [[icon:boundary]] Boundary, [[icon:loop]] Loop, [[icon:ring]] Ring | Advanced selection suite. Invert [[kbd:Ctrl]]+[[kbd:I]], Grow [[kbd:Alt]]+[[kbd:G]], Shrink [[kbd:Shift]]+[[kbd:Alt]]+[[kbd:G]], Coplanar [[kbd:Alt]]+[[kbd:C]], Loop [[kbd:Alt]]+[[kbd:L]], Ring [[kbd:Alt]]+[[kbd:R]]. |
| Objects | [[icon:merge_objects]] Merge Objs, [[icon:mirror]] Mirror, [[icon:center_pivot]] Center Pivot, [[icon:freeze]] Freeze Xform, [[icon:poibuilderize]] Poibuilderize | Combine meshes, mirror across X, recenter pivot to bounds, bake transform into vertices, convert MeshInstance3D/CSG to PBMesh. |
| CSG | [[icon:csg_union]] CSG Union, [[icon:csg_subtract]] CSG Subtract, [[icon:csg_intersect]] CSG Intersect | Real-time CSG booleans with full undo. Select target first, cutter last. |
| Smoothing | [[icon:auto_smooth]] Auto Smooth | Recalculate smoothing groups by dihedral angle (45° threshold). |
| Snapping & Tools | V-Snap, Soft (proportional) + radius spinner, [[icon:trim_walls]] Trim Walls | Snapping to vertices, proportional editing with smooth falloff, and interactive wall-clicking trim. |
## Overlay

A compact floating panel in the viewport.

- Selection readout while something is selected.
- Drag readout while dragging.
- Params modal for shape create and bevel.
- Drag it by the header. Pin with **Panel**. Recover with the reset button.

Params modal rules (do not mix these up):

- **Shape create / Edit Params:** Apply commits, Cancel restores. Clicking elsewhere **cancels**.
- **Bevel:** clicking elsewhere **applies**.
- Any mode or tool change applies the open modal first.
- [[kbd:Esc]] before the confirming create-click creates nothing.

## Docks

- **Material & UV** — palette, per-face assignment, splat layers, stamps, scroll speed.
- **UV Editor** — bottom panel, can pop out to a window. See [UV editor](uv.html).

## Status

During creation the overlay shows a hint (base drag, then height). Extents print in metres. Directional shapes (doors, stairs) display an orange facing arrow on the base plane; holding [[kbd:Ctrl]] locks the arrow direction so lateral sizing won't flip the facing. Environment presets write a scene meta the export reads.

> [gotcha] The toolbar never hides. If a button is grey, read its tooltip — it is waiting for faces, or edges, or two objects.
