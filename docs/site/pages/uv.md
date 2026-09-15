---
title: UV editor
lead: A dedicated 2D canvas. Click a face in 3D, the island lights up. Drag in 2D, the 3D face updates.
---

Toolbar **UV** opens the bottom panel. Pop-out detaches it to a floating window.

:::shot uv-editor.png
Dedicated 2D UV canvas with bidirectional live sync.
:::

## Canvas

- Pan, zoom, a unit quad, optional texture underlay and tiling.
- Wireframe of the islands.
- Element modes on the UV toolbar: Vertex / Edge / Face / Island.
- Channels UV1 / UV2.
- Snap toggle + step.
- Frame Selection / Frame Unit Quad.

## Transforms

Move / Rotate / Scale tools on the 2D toolbar. Flip U, Flip V, rotate 90° CW/CCW. Sew, split, collapse, stitch.

## Projections

| Button | What it does |
|---|---|
| Planar | Project along a chosen axis onto the selection |
| Box | Six-axis box map |
| Fit | Pack the island into 0–1 |
| Unwrap | Angle-based unwrap |

Texel density: read with Get, apply with Set, spinner in texels/metre.

## Selection sync

Both directions:

1. Click a wall in the 3D view — its island highlights on the canvas.
2. Drag that island — the 3D face's texture moves.

Texture mode ([[kbd:6]]) is the 3D-side equivalent for quick rotates without opening the panel.

## Use case — a stretched ramp

1. Select the ramp face. UV panel → **Planar** (or **Box** if it wraps).
2. Scale the island until the brick is square. Underlay on, so you can see the texture.
3. If two ramps should match, Get texel on the good one, Set on the other.

Export PNG dumps the current island layout for an external painter.

> [gotcha] Auto-UV already handles axis-aligned walls. Open this editor for ramps, cylinders, and anything you merged across a crease.
