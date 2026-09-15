---
title: Grid
lead: PoiBuilder has its own grid. Element drags, extrude, and shape creation snap to it. The engine grid hides while you are in a PoiBuilder context.
---

## What you see

A cyan line mesh in the 3D viewport, not a node in the scene. Elevation is session-only; unit and subdivisions persist in Editor Settings (`poibuilder/grid/*`).

While any PoiBuilder context is active (mesh selected, creation armed, draw-on-grid, elevated grid) the engine's stock grid hides.

## Keys

| Key | Action |
|---|---|
| [[kbd:Y]] | Toggle snapping |
| [[kbd:G]] | Draw on grid — start a shape on the plugin grid even over a mesh |
| [[kbd:[]] [[kbd:]]] | Elevation down / up |
| [[kbd:-]] [[kbd:=]] | Subdivisions coarser / finer |
| [[kbd:Shift]]+[[kbd:-]] [[kbd:Shift]]+[[kbd:=]] | Unit ÷2 / ×2 |
| [[kbd:\\]] | Reset elevation |

The toolbar Grid button opens the settings panel (unit, subdivisions, elevation, draw-on-grid). The readout shows the current snap step, and the elevation when it is not zero.

Object mode can sync engine snap to this grid. Element mode always uses the plugin grid.

See also [Moving](transform.html) for V-Snap and proportional editing.
