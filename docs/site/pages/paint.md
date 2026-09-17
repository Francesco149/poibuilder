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

While placing: drag to **raise** the billboard off the surface — a green line marks the ground anchor and the overlay shows the offset in metres — then move left/right to **scale** (the overlay shows width x height in metres plus the scale multiplier).

## Asset categories

Sprites, stamps and paint textures live in separate pickers — a tree image never shows up in the stamp picker. Classification is by folder (`.../sprites/`, `.../stamps/`, `.../particles/`, `.../textures/`), then by name prefix (`sprite_`, `stamp_`, `particle_`, `tree_`, ...). Add your own by dropping files into `res://materials/sprites/`, `res://materials/stamps/` or `res://materials/textures/` — the plugin's bundled folder is never touched.

## Scroll

Covered on [Materials](materials.html). A waterfall is a plane with scroll speed, plus an optional particle emitter at the lip.

:::shot map-waterfall.png
Scrolling sheets on a wall panel.
:::

> [gotcha] A scrolling face is **not** packed into the retro tile atlas — an offset would drag it across the slot. Export keeps it as its own texture. Do not also splat-paint that face; paint is baked to a static tile.

> [gotcha] Splat paint lives in a custom shader plus per-face masks, which a modern **.glb export cannot carry**: the exported surface keeps the layer's base texture, but the painted blend itself is lost. Keep the scene in Godot (or the PoiBuilder viewer), use the retro export (bakes paint into unique tiles), or run `./bake_splat.sh <scene.tscn>` to bake the paint into the scene itself — which also frees UV2 for lightmaps.

To see what a face's paint looks like up close, the UV editor's **UV2 (Splat — read-only)** channel shows the composited paint for the selected face — see [UV editor](uv.html).
