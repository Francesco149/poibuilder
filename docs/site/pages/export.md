---
title: Export & retro
lead: One dialog, two products: a modern GLB, or a tile-baked .pbm with vertex light. Retro textures are sanitized on the way out.
---

Toolbar **Export**.

## Modern GLB

Keeps authored geometry. Stamps and splat data ride as extras. Collision meshes named `Collider_*`. Use this for Godot, Blender, any glTF consumer.

## Retro baked map

The path the PSP / raylib viewers eat.

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

## Authoring for the retro target

Deep knobs, pitfalls, and the `.pbm` byte layout live in the repo:

- `retro_engine/RETRO-AUTHORING.md`
- `SPEC_RETRO_FORMAT.md`
- `retro_engine/psp/HARDWARE-TESTING.md` — performance numbers are only real from `./run_psp_hw.sh` over USB.

A scrolling material must not be atlas-packed; export already exempts it.

> [gotcha] PPSSPP is for "does it look right". It will report 60 fps for a build that spends 27 ms on the device. Do not tune from the emulator.
