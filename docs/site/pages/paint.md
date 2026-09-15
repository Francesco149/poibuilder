---
title: Paint & stamps
lead: Up to eight splat layers per face, decal stamps clipped to the face, and a sprite placer on B.
---

## Splatting

The Material dock's paint mode. Up to **8 layers** per face. Brush the blend between two (or more) albedos — grass into rock, dirt into tile.

:::shot paint-splat.png
Multi-layer texture splatting.
:::

:::video clips/paint-splat.mp4
The brush writes weights, not new geometry.
:::

## Decal stamps

High-res billboards, upright, clipped to the face they sit on. Place a poster, a sign, a moss patch. Delete the stamp node (under `PBStamps`) to remove it. Retro export **bakes** stamps into unique tiles; unpainted tiles reuse the base texture.

:::shot paint-stamp.png
Decal stamps, clipped to the face.
:::

## Sprite placer

[[kbd:B]] arms the placer. A carousel of billboard textures, raise and scale while placing. Good for trees, candles, distant props. Name prefix `sprite`/`billboard`/`tree`/… also marks a MeshInstance3D as a billboard at export.

## Scroll

Covered on [Materials](materials.html). A waterfall is a plane with scroll speed, plus an optional particle emitter at the lip.

:::shot map-waterfall.png
Scrolling sheets on a wall panel.
:::

> [gotcha] A scrolling face is **not** packed into the retro tile atlas — an offset would drag it across the slot. Export keeps it as its own texture. Do not also splat-paint that face; paint is baked to a static tile.
