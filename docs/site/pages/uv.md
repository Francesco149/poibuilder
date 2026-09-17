---
title: UV editor
lead: A dedicated 2D canvas. Click a face in 3D, the island lights up. Drag in 2D, the 3D face updates.
---

Toolbar **UV** opens the bottom panel. Pop-out detaches it to a floating window.

:::op uv
Opens the dedicated 2D UV canvas panel in the bottom dock or a floating window.
:::

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

## UV2 — the splat debug view

The second channel is not a second unwrap. The texture splatting system owns UV2: every face's splat masks are authored in face-planar coordinates, normalized so each face fills the whole 0–1 square. The UV2 view draws that square for the selected face's material — the base texture with every painted layer and stamp composited on top.

That explains the odd look on elongated faces: a splat in the middle of a long wall shows as a centered blot in a square, because the square *is* the face's splat bounding area. The status line shows its real-world size (e.g. `Splat area 4.00 × 0.50 m`) so you can read the true proportions.

> [gotcha] UV2 is **read-only** here, by design. Selection works so you can inspect paint; the transform, projection, seam and texel tools go inert while UV2 is up. Splat paint is edited by painting in the viewport — see [Painting](paint.html) — never by dragging UVs.

### UV2 and lightmaps

Godot's LightmapGI bakes with UV2, so which channel owns it matters:

- **No splat paint on the mesh** — UV2 is yours. Unwrap it (or import a lightmap set from a DCC) and rebuilds leave it untouched.
- **Splat-painted mesh** — the splat system regenerates UV2 on every rebuild. Splatting and lightmap UV2 are mutually exclusive *per mesh*; a lightmap unwrap on a painted mesh would be silently overwritten.

To lightmap splat-painted geometry, keep the paint on a separate mesh, or bake the paint down first — the **retro export** does it at export time, and `./bake_splat.sh <scene.tscn>` does it in place (paint becomes plain baked tile textures, splat data and UV2 are cleared, then LightmapGI just works).

## Use case — a stretched ramp

1. Select the ramp face. UV panel → **Planar** (or **Box** if it wraps).
2. Scale the island until the brick is square. Underlay on, so you can see the texture.
3. If two ramps should match, Get texel on the good one, Set on the other.

Export PNG dumps the current island layout for an external painter.

> [gotcha] Auto-UV already handles axis-aligned walls. Open this editor for ramps, cylinders, and anything you merged across a crease.
