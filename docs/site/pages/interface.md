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
| Tools | Move, Rotate, Scale | The plugin's own tool. While editing, Godot's Q/V buttons are disabled. Shortcuts [[kbd:W]] [[kbd:E]] [[kbd:R]] still work. |
| Ops | Extrude, Inset, Bevel, Bridge, Connect, Collapse, Fill Hole, Knife, Loop Cut, Merge, Subdiv, Weld, Detach, Del | Grey = wrong selection. Tooltip says what it needs. |
| Env | Dawn / Day / Dusk / Night | Relights the edited scene. |

Scale tooltip, verbatim: axis handles scale freely; the **center square** scales all axes together (Shift + center on faces insets).

**Row 2** — modes, space, grid, shapes, docks, export.

| Control | What it does |
|---|---|
| Object / Vertex / Edge / Face / Texture | Selection mode. Vertex [[kbd:H]], Edge [[kbd:J]], Face [[kbd:K]], Texture [[kbd:6]]. Object is the toolbar button (unbound by default). |
| Space | Cycles Element / Object / World ([[kbd:X]]). |
| Grid | Opens grid & snap settings. Readout shows the current snap step. |
| New Shape | Always enabled. Pick a primitive, then drag. |
| N-Gon | Draw a polygon, extrude it. |
| Edit Params | Live only while the selected mesh is a pristine, unedited factory shape. |
| Material | Focuses the Material & UV dock. |
| UV | Opens the 2D UV editor bottom panel. |
| Panel | Pins the overlay so it does not auto-hide. |
| Reset | Docks the overlay back to the bottom-left. |
| Settings | Display: grid, wireframe, selection/hover opacity. |
| Export | Retro baked map or modern GLB. |
| Docs | Opens this site (bundled `docs-site/index.html`). |

**Rows 3 & 4** — the ☷ **Extended Tools** toggle.

- Selection suite: All, Invert, Grow, Shrink, Coplanar, Similar, Boundary, Loop, Ring.
- Auto Smooth (45°).
- V-Snap, Soft (proportional) + radius spinner.
- Merge Objs, Mirror, Center Pivot, Freeze Xform, Poibuilderize.
- CSG Union / Subtract / Intersect.
- Trim Walls.

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

During creation the overlay shows a hint (base drag, then height). Extents print in metres. Environment presets write a scene meta the export reads.

> [gotcha] The toolbar never hides. If a button is grey, read its tooltip — it is waiting for faces, or edges, or two objects.
