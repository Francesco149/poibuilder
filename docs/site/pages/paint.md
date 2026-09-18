---
title: Paint & stamps
lead: Up to eight splat layers per face, a paintable decal layer for stamps, and a sprite placer on B.
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

A stamp is a PNG painted **into the surface**, not a node hovering over it. Click to paste one (no dragging): it lands in the face's **decal layer** at 256 texels/m — the same uniform density as the splat masks — and it keeps its own colors and alpha 1:1.

Because it is pixels, a stamp can **span several faces**: overhang a floor tile's edge, wrap the corner of a wall, cover a whole staircase side. Stamps are projected along the surface normal, so a face nearly perpendicular to the stamp plane (a wall a floor stamp runs into) receives a stretched smear rather than a bend.

Erase parts of it with the brush: in the paint panel set **Paint into → Decal layer** and enable **Erase**. The same brush (with **Paint into → Decal layer**, Erase off) paints the selected palette texture as pixels, which is how you touch up or extend a decal by hand. **Clear Decal Layer** wipes all of it at once. Every one of those actions is undoable.

Retro export **bakes** stamps into unique tiles; unpainted tiles reuse the base texture. Modern `.glb` export either bakes the whole stack into per-face textures or ships it as data — see [Splatting in a modern .glb](modern_glb_splat.html).

:::shot paint-stamp.png
A stamp painted across two faces, then partly erased.
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

> [gotcha] A modern **.glb export** cannot carry a custom shader. Choose **Modern paint → Bake into textures** (each painted face becomes its own texture — any engine shows your paint) or **Include splat data** (masks and decal channels ship as sidecar PNGs plus a `poi_splat` record in the material extras; see [Splatting in a modern .glb](modern_glb_splat.html) for the consumer recipe). To flatten paint inside Godot itself, run `./bake_splat.sh <scene.tscn>`.

> [note] **Splat paint and LightmapGI now coexist on one mesh.** Masks travel in their own vertex channel (CUSTOM0), so UV2 — the channel a lightmap unwrap lives in — is never touched by painting. Unwrap it from the UV editor's **Lightmap** button (it also flips the mesh to *GI Mode: Static*), bake the LightmapGI, and keep painting: the paint will not disturb the bake's UVs.

To see what a face's paint looks like up close, the UV editor's **Splat masks** channel shows the composited paint for the selected face (read-only — that space is written by painting, not by hand). **UV1 (Texture)** and **UV2 (Lightmap)** are both editable channels — see [UV editor](uv.html).
