---
title: Materials
lead: Per-face materials, auto-UV that does not stretch on resize, and a dock that is also the paint bucket.
---

## The dock

Toolbar **Material** focuses the Material & UV dock.

- Palette / swatch grid of project materials.
- Click a face (face or texture mode), click a swatch — that face takes the material.
- Drag a texture from the FileSystem dock onto a face.

Texture mode ([[kbd:6]]) transforms UVs in 3D with the same gizmo. For island work, use the [2D UV editor](uv.html).

## Auto-UV

New shapes unwrap with a 1×1 m repeat. Rules the plugin keeps:

- Resize does not stretch — UVs stay locked to object space, so a 2 m wall still shows 2 tiles.
- Coplanar faces share a seam anchor, so a merged wall does not crawl.
- Diagonal faces tile along their plane, not a projected smash.

If a ramp still looks stretched, that is a projection job: [UV editor](uv.html).

## Smoothing

**Auto Smooth** (row 3) sets smoothing groups from a 45° dihedral. Hard edges stay hard; shallow joins pick up shared normals. Lighting, not geometry.

## Scroll

A material can carry a UV scroll speed. It plays in the editor viewport and **survives retro export** as per-mesh scroll. Waterfalls are a scrolling plane, not a shader graph.

:::shot paint-scroll.png
Animated materials — UV scroll in the viewport.
:::

:::video clips/paint-scroll.mp4
The sheet moves. The mesh does not.
:::

Related: [Paint & stamps](paint.html), [UV editor](uv.html).

> [gotcha] Textures that "slide" when you extrude were a bug class. Extrude is supposed to continue tiling across the new seam. If it does not, file it — do not compensate by hand-scaling UVs on every extrude.
