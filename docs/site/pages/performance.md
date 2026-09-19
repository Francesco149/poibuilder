---
title: Godot-side performance
lead: The poibuilder scene as-is vs the retro-baked GLB vs the modern GLB, on gl_compatibility and Vulkan — steady-state frame pacing, an ablation profile that says what the cost is made of, and PSP-parity checks that keep the pipelines honest.
---

A map's feel is decided by frame-time DIPS and pacing, not by the average
fps a still scene reports. The bundled benchmark
(`project/test_scenes/frame_pacing_bench.gd`, driven by `./run_bench.sh`)
flies the [alpha demo map](walkthrough-modern.html) along a gameplay-like
path — courtyard, through the doorway into the neon room, back out, up the
stairs, across the roof — while recording the wall-clock time of every
frame. Three summaries per variant:

- **cold** — the first-visit pass: shader compiles and first uploads appear
  as hitches. Kept for the hitch column, never the headline.
- **warm** — the steady-state pass.
- **steady** — the warm pass minus its first second: the headline numbers
  describe the run, not the load.

Every variant is also *photographed* at five fixed poses
(`tools/bench_contact_sheet.py` grids the shots into contact sheets), and
`./run_bench.sh --profile` ablates the PB scene piece by piece — no
shadows, no emitters, no splat, no lights — to attribute the cost.

## Which one do you ship?

**Export the baked map and play that.** The PoiBuilder scene as-is is the
*authoring* format: it renders the live splat shader, live decal layers,
and every realtime light with shadows, and it is the most expensive way to
play the map on every renderer measured here. Build, test and iterate in it
as much as you like — but when you want to *play* or share, run it through
**Export...**: a modern GLB for the modern pipeline (paint baked into
textures, your own realtime lights or LightmapGI on top), or the PBM/retro
GLB for retro targets.

## The three variants

| Variant | What it is |
|---|---|
| **PB scene as-is** | The editable PoiBuilder scene played directly: PBMesh runtime geometry, the splat shader, decal layers, realtime shadowed lights, 5 live GPUParticles3D emitters (including the waterfall's wide mist bank). |
| **Retro-baked GLB** | The retro bake in Godot: baked tile textures, lighting in vertex colors, **rendered unshaded with zero added lighting** (the consumer contract — see below), preset sky + fog. |
| **Modern GLB** | The modern export with paint baked into textures: standard materials, realtime lights (shadow flags restored from the export's `poi_shadow` extras), full authored environment, colliders. |

The consumer contracts are part of the measurement: the retro GLB's
imported lights are hidden (its lighting lives in vertex colors — live
lights would double-light), and the modern GLB's shadows are restored from
the extras the exporter writes, because glTF lights cannot carry them.

## Measured results — gl_compatibility

Intel UHD 630 (integrated, Mesa), Godot **gl_compatibility**, 1280×720
windowed, vsync off, one GPU, one map:

| Variant | steady median | 1% low | steady worst | jitter (σ) | draws/frame | cold hitches |
|---|---|---|---|---|---|---|
| PB scene as-is | 25.2 ms | 42.8 ms | 58 ms | 6.1 | 334 | 2 |
| Retro-baked GLB | **5.7 ms** | 11.5 ms | 20 ms | 2.4 | 131 | 53 |
| Modern GLB | 21.7 ms | 34.2 ms | 41 ms | 4.8 | 191 | 1 |

- **The retro bake is in a class of its own** — 4.4× faster than the PB
  scene, with steady worst frames under 21 ms. Unshaded baked geometry is
  nearly free; that is the whole retro pipeline thesis, measured.
- **The modern bake sits close to the PB scene** (1.16×) — by design: this
  comparison is like-for-like now, same realtime shadowed lights, same
  environment. What the modern bake buys you is control: lightmap your
  GLB, drop or bake the realtime lights, and it drops toward the retro
  number.
- **Cold hitches are one-time.** The retro GLB's 50-odd cold hitches are
  first-sight shader compiles; the warm pass's worst frame is 20 ms.

## And on Vulkan (forward_plus)?

Same map, same path, `--rendering-method forward_plus`:

| Variant | steady median | 1% low | steady worst | jitter (σ) | draws/frame |
|---|---|---|---|---|---|
| PB scene as-is | 35.4 ms | 52.5 ms | 58 ms | 6.7 | 269 |
| Retro-baked GLB | **7.6 ms** | 14.5 ms | 21 ms | 2.9 | 147 |
| Modern GLB | 27.7 ms | 44.0 ms | 57 ms | 5.8 | 142 |

On this integrated Intel GPU, **gl_compatibility beats Vulkan for every
variant** — the PB scene by ~40%, the retro bake by ~35%. If you are
shipping to players on old or integrated graphics, the Compatibility
renderer is the measured choice for PoiBuilder maps; Vulkan/forward_plus
buys features (SDFGI, volumetric fog), not speed, on this class of
hardware.

## What is the frame made of? (ablation profile)

`./run_bench.sh --profile` flies the PB scene as-is, then once per
ablation. The delta is that feature's share of the frame:

| Ablation | GL steady median | Δ vs base | Vulkan steady median | Δ vs base |
|---|---|---|---|---|
| none (base) | 25.2 ms | — | 35.6 ms | — |
| − shadow-casting lights (4) | 13.6 ms | **−11.6** | 24.9 ms | **−10.8** |
| − particle emitters (5) | 22.4 ms | −2.8 | 29.9 ms | −5.8 |
| − splat shader (1 material → standard) | 25.3 ms | +0.1 | 33.2 ms | −2.4 |
| − all lights (7) | 8.6 ms | −16.5 | 15.1 ms | −20.5 |

- **Shadows are half the frame.** Four shadow-casting omnis cost ~12 ms on
  both renderers (draw calls explode from 44 to 334). An optimization pass
  that needs a win starts here: fewer shadowed lights, or bake them.
- **Particles cost ~3 ms (GL) / ~6 ms (Vulkan)** for the five emitters.
- **The splat shader is free** on GL and ~2 ms on Vulkan — paint is not
  the tax; the lighting rig is.
- The residue (no-lights floor: 8.6 / 15.1 ms) is the geometry + fill
  itself.

## Pipeline parity (the baked map must not depend on the renderer)

The retro bake is only "done" if every consumer renders it the same. The
device and Godot are A/B'd per preset by mean luminance
(`project/test_scenes/retro_parity_shots.gd` vs a device screenshot of the
same map — alpha demo, dusk): **PSP 0.122 vs Godot-retro-display 0.123**;
the courtyard reference at day: **PSP 0.450 vs 0.447**. That parity holds
only under the consumer contract above — adding Godot lighting to a fully
baked map double-lights it (the live preset measured +54% mean luminance
at day), and the naive import even renders it black, because the bake's
light rides in COLOR_0, which Godot's importer does not apply without
`apply_baked_vertex_colors()` (the exporter ships this helper). The baked
colors themselves carry a **modulate-2x boost** (ExportSettings
`bake_boost`, default 2.0, saturating): the old-school lift that brightens
shadows and mid-tones of dusk/night bakes while sunlit areas ride the
clamp.

The PSP side is a different question with its own measurements — the
device's frame budget, fill-rate cliff and per-map budgets live in the
[PSP Optimization Guide](https://github.com/Francesco149/poibuilder/blob/master/retro_engine/psp/OPTIMIZATION.md);
the demo map plays the retro bake on the device at 60 fps (137 draws).

## Re-run it

```bash
./run_bench.sh                    # exports the GLB variants if missing, flies all three (GL)
./run_bench.sh --reexport         # force re-export (also re-runs the import pass)
./run_bench.sh pb                 # one variant: pb | retro_glb | modern_glb
./run_bench.sh --renderer vulkan  # the forward_plus axis
./run_bench.sh --profile          # the ablation profile (GL; add --renderer vulkan)
python3 tools/bench_contact_sheet.py   # grid exports/bench/shots/* into sheets
```

Reports land in `project/exports/bench/<renderer>_<variant>.json` — full
per-frame arrays, not just the summary. Every Godot run is containerized and
memory-capped through `tools/godot_guard.sh`, runs strictly one at a time on
a real display (`GUARD_X11=1`, handled by the script).

> [gotcha] Do not compare these numbers against PPSSPP or the PSP — they
> answer "how does a modern Godot project pay for this map", on desktop
> hardware, with the desktop renderer. Device claims need the device.
