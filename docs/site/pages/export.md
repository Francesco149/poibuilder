---
title: Export & retro
lead: PBM is the headline product — a quick export bakes a tile-baked .pbm with vertex light for the PSP. GLB (retro-baked or modern) is one dialog away. Retro textures are sanitized on the way out.
---

Toolbar **Export...** opens the dialog: **Format** defaults to PBM (`res://exports/exported_map.pbm`), with two GLB flavors below it — everything else on the page applies per format.

## Modern GLB

Keeps authored geometry. Stamps and splat data ride as extras. Collision meshes named `Collider_*`. Use this for Godot, Blender, any glTF consumer.

## Retro baked map

The path the PSP / raylib viewers eat — and what PBM is: the same bake written straight to the binary map instead of a GLB waypoint.

What the export does:

- Subdivides faces to the texture tiling grid (optional).
- Bakes direct light, shadows, AO into **vertex colours**.
- Bakes splat paint and stamps into unique **tile** textures; unpainted tiles reuse the base.
- Writes collision hulls.
- Writes lights, billboards, particle emitters, walkable meshes, environment preset.

Output: `.glb` as transport, and/or `.pbm` (the binary map). Both land in `project/exports/` (gitignored).

:::shot map-export.png
One click to a retro .pbm map.
:::

## Texture sanitization

Retro consumers — the PSP especially — want **power-of-two** dimensions at or below **max texture size** (default 512). The export enforces that on every albedo, including:

- `PBMesh` tiles
- Ordinary MeshInstance3D props you did **not** Poibuilderize
- Particle atlases

A 300×180 import becomes a POT image ≤ 512. A 2048 atlas is downsized. Soft-alpha (blend) travels as RGBA8888; everything else prefers RGBA5551.

The dialog's "max texture size" dropdown is that clamp. Leave it at 512 unless you have measured a reason not to.

## Environment

The Env menu (Dawn / Day / Dusk / Night) relights the scene. Export stores the preset name. The PSP app can override it at runtime.

:::shot psp-court.png
The same courtyard on a Sony PSP — not an emulator.
:::

:::shot psp-hud.png
Measured on the device for the showcase map: 60 fps, 1618 tris, 20 draws. That row is that map, that camera, that build — not a promise about yours.
:::

## The retro demo engine is a proof of concept

The PSP engine in this repository (`retro_engine/psp/`) exists to answer two
questions: does the `.pbm` format hold up, and how fast is a real retro
target running it? That is all it tries to be — **a proof of concept and a
performance sanity check**, not a game engine you ship with. It has no
gameplay, no scripting, no toolchain polish, and it never will.

The contract is the **file format**, not the demo:

- The `.pbm` binary layout is fully specified in
  [`SPEC_RETRO_FORMAT.md`](https://github.com/Francesco149/poibuilder/blob/master/SPEC_RETRO_FORMAT.md) —
  write your own loader against it in your engine of choice.
- The demo engine in the repo is a **reference implementation**: read its
  loader (`retro_engine/psp/pbm_loader.c`) and renderer to see how the format
  is meant to be consumed, then take what you need.
- The raylib viewer (`retro_engine/raylib/`) shows the same format on a
  desktop target.

## Authoring for the retro target

Architecture constraints, performance measurements, and the `.pbm` byte layout are documented on GitHub:

- [Retro Authoring Guide](https://github.com/Francesco149/poibuilder/blob/master/retro_engine/RETRO-AUTHORING.md) — Godot authoring recipes and export baking rules.
- [PSP Optimization Guide](https://github.com/Francesco149/poibuilder/blob/master/retro_engine/psp/OPTIMIZATION.md) — hardware architecture, fill rates, and the 19x texture cache cliff.
- [Retro Demo Engine](https://github.com/Francesco149/poibuilder/tree/master/retro_engine) — the reference C renderer and viewer described above.

A scrolling material must not be atlas-packed; export already exempts it.

> [gotcha] PPSSPP is for "does it look right". Because host GPUs have massive caches, the emulator hides the PSP's ~8 KB texture cache cliff (a 19x drop from 480 Mfrag/s to 25 Mfrag/s on misses). Do not tune performance from the emulator.
