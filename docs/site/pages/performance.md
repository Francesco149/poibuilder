---
title: Godot-side performance
lead: The poibuilder scene as-is vs the retro-baked GLB vs the modern GLB, on gl_compatibility and Vulkan, on two machines — a desktop RTX 5060 and a five-year-old integrated Intel GPU as the worst case — with steady-state frame pacing, an ablation profile that says what the frame cost is made of, a one-line profile of what the export's time is made of, and PSP-parity checks that keep the pipelines honest. Numbers are half the loop; the other half is the interactive fly bench.
---

A map's feel is decided by frame-time DIPS and pacing, not by the average
fps a still scene reports. The benchmark flies the
[alpha demo map](walkthrough-modern.html) along a gameplay-like path —
courtyard, through the doorway into the neon room, back out, up the
stairs, across the roof — while recording the wall-clock time of every
frame. The reference implementation lives in the plugin's repository
(`project/test_scenes/frame_pacing_bench.gd`, driven by `./run_bench.sh`
there) — reference it or roll your own, the recipe is at the bottom of
this page. Three summaries per variant:

- **cold** — the first-visit pass: shader compiles and first uploads appear
  as hitches. Kept for the hitch column, never the headline.
- **warm** — the steady-state pass.
- **steady** — the warm pass minus its first second: the headline numbers
  describe the run, not the load.

Every variant is also *photographed* at five fixed poses (the repository's
`tools/bench_contact_sheet.py` grids the shots into contact sheets), and a
profile pass ablates the PB scene piece by piece — no shadows, no
emitters, no splat, no lights — to attribute the cost.

**Fly it yourself.** The repository's `./run_fly_bench.sh
[pb|retro_glb|modern_glb]` opens the same scene assembly with a free
camera and a frame-time overlay: a rolling graph with the 60/30 fps lines
drawn in, plus current / median / **1% low** / worst, hitches and draw
counts over a 240-frame window and the whole session. Keys 1–5 teleport to
the exact poses the contact sheets compare, so a suspicious dip in the
report can be *stood in* — jump to the neon room and watch the
shadow-casting omnis spike the graph. No repository? The same
inspection is a [fly camera](walkthrough-modern.html#9-play-it) (three
minutes, one script) plus any frame-time readout — the numbers that matter
are the median and the 1% low with vsync OFF, not the fps counter. On the
Windows box, `./run_fly_bench_win.sh` is the same thing on its GPU.

## Which one do you ship?

**Export the baked map and play that.** The PoiBuilder scene as-is is the
*authoring* format: it renders the live splat shader, live decal layers,
and every realtime light with shadows, and it is the most expensive way to
play the map on every renderer measured here. Build, test and iterate in it
as much as you like — but when you want to *play* or share, run it through
[[btn:export]]: a modern GLB for the modern pipeline (paint baked into
textures, your own realtime lights or LightmapGI on top), or the PBM/retro
GLB for retro targets.

## The three variants

| Variant | What it is |
|---|---|
| **PB scene as-is** | The editable PoiBuilder scene played directly: PBMesh runtime geometry, the splat shader, decal layers, realtime shadowed lights, 5 live GPUParticles3D emitters (including the waterfall's wide mist bank). |
| **Retro-baked GLB** | The retro bake in Godot: baked tile textures, lighting in vertex colors, **rendered unshaded with zero added lighting** (the consumer contract — see below), preset sky + fog — and the export's 5 particle emitters rebuilt from the `poi_emitter` records the GLB carries. |
| **Modern GLB** | The modern export with paint baked into textures: standard materials, realtime lights (shadow flags restored from the export's `poi_shadow` extras), full authored environment, and the same rebuilt emitters. |

The consumer contracts are part of the measurement: the retro GLB's
imported lights are hidden (its lighting lives in vertex colors — live
lights would double-light), and the modern GLB's shadows are restored from
the extras the exporter writes, because glTF lights cannot carry them.

## Two machines

The tables bracket what players actually run:

- **RTX 5060** — desktop, Windows, driver 596.36, the *native Windows*
  Godot (WSL's paravirtualized GPU is not a measurement target; the
  `run_bench_win.sh` launcher drives the Windows exe from WSL).
- **Intel UHD 630** — a ~5-year-old integrated GPU (Comet Lake desktop,
  Mesa on Linux) as the **deliberate worst case**: budget-2020-office-PC
  graphics. A map that plays here plays anywhere.

Both: 1280×720 windowed, vsync off, one GPU, one map, the same Godot 4.7.2
build, the same flight path — and every report records its GPU name
(`RenderingServer.get_video_adapter_name()`), so a benchmark result
carries its machine with it.

## Measured results — gl_compatibility

| Variant | 5060 median | 5060 1% low | 5060 worst | iGPU median | iGPU 1% low | iGPU worst |
|---|---|---|---|---|---|---|
| PB scene as-is | 1.60 ms | 1.90 ms | 5.29 ms | 16.25 ms | 27.26 ms | 31.99 ms |
| Retro-baked GLB | **1.15 ms** | 1.41 ms | 5.36 ms | **2.29 ms** | 4.21 ms | 9.39 ms |
| Modern GLB | 1.40 ms | 1.70 ms | 5.46 ms | 14.85 ms | 24.91 ms | 31.30 ms |

- **The retro bake is in a class of its own on both machines** — ~7×
  faster than the PB scene on the iGPU, ~1.4× on the 5060, where it
  renders at ~870 fps. Unshaded baked geometry is nearly free; that is
  the whole retro pipeline thesis, measured.
- **The modern bake sits close to the PB scene** — by design: this
  comparison is like-for-like, same realtime shadowed lights, same
  environment. What the modern bake buys you is control: lightmap your
  GLB, drop or bake the realtime lights, and it drops toward the retro
  number.
- **Cold hitches are one-time** first-sight shader compiles: 40 (PB) and
  28 (retro) on the 5060's NVIDIA GL driver, but the warm pass's worst
  frame is ~5 ms. On the iGPU the same cold pass hitches 2 / 45 times.

## And on Vulkan (forward_plus)?

Same map, same path, `--rendering-method forward_plus`:

| Variant | 5060 median | 5060 1% low | 5060 worst | iGPU median | iGPU 1% low | iGPU worst |
|---|---|---|---|---|---|---|
| PB scene as-is | **0.83 ms** | 1.14 ms | 2.51 ms | 22.14 ms | 34.56 ms | 38.52 ms |
| Retro-baked GLB | **0.71 ms** | 0.85 ms | 2.19 ms | **3.69 ms** | 5.93 ms | 10.58 ms |
| Modern GLB | **0.74 ms** | 0.95 ms | 2.61 ms | 19.38 ms | 29.96 ms | 36.71 ms |

**The renderer ranking flips with the GPU**, and this is why the page
keeps both columns. On the old integrated chip, gl_compatibility wins for
every variant (the PB scene by ~40%, the retro bake by ~60%) — if you are
shipping to players on old or integrated graphics, Compatibility is the
measured choice, and Vulkan buys features (SDFGI, volumetric fog), not
speed. On the modern discrete card the order reverses: forward_plus is
~1.5–2× faster everywhere (the PB scene 0.83 vs 1.60 ms, the retro bake
0.71 vs 1.15 ms). One caveat the cold column tells: NVIDIA's first-visit
Vulkan shader compiles are heavy — 100 cold hitches on the retro bake,
188 on the PB scene — so a shipped game wants a warm-up pass or pipeline
cache, or the first room stutters while the steady state is flawless.

## What is the frame made of? (ablation profile)

`--profile` flies the PB scene as-is, then once per ablation. The delta
is that feature's share of the frame — steady median, both GPUs, both
renderers (Δ vs base in parens):

| Ablation | 5060 GL | iGPU GL | 5060 Vulkan | iGPU Vulkan |
|---|---|---|---|---|
| none (base) | 1.62 ms | 16.09 ms | 0.83 ms | 21.86 ms |
| − shadow-casting lights (4) | 0.67 (−0.95) | 8.85 (−7.24) | 0.56 (−0.27) | 17.41 (−4.46) |
| − particle emitters (5) | 0.99 (−0.64) | 14.75 (−1.35) | 0.64 (−0.19) | 19.38 (−2.48) |
| − splat shader (1 material → standard) | 1.59 (−0.04) | 15.81 (−0.28) | 0.81 (−0.01) | 21.47 (−0.40) |
| − all lights (7) | 0.61 (−1.02) | 4.11 (−11.99) | 0.45 (−0.38) | 8.65 (−13.22) |

- **Shadows are the biggest single cost on every machine.** Four
  shadow-casting omnis are ~45–60% of the GL frame (draw calls explode
  from 44 to 334) and still the top Vulkan delta. An optimization pass
  that needs a win starts here: fewer shadowed lights, or bake them.
- **Particles cost ~0.6 ms (5060 GL) / ~1.4 ms (iGPU GL)** for the five
  emitters, and ~0.2–2.5 ms on Vulkan.
- **The splat shader is free** on both GPUs and both renderers (−0.01 to
  −0.40 ms) — paint is not the tax; the lighting rig is.
- The residue (no-lights floor: 0.61/0.45 ms on the 5060, 4.11/8.65 ms on
  the iGPU) is the geometry + fill itself.

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

## Measure your own map

The recipe behind every number on this page — the repository's
`run_bench.sh` / `run_bench_win.sh` / `run_fly_bench.sh` implement it and
you can use them as-is, but nothing in it is exclusive to our setup:

1. **One representative per pipeline.** The bench flies exactly THREE
   variants — the PB scene as-is, ONE retro-baked GLB, ONE modern GLB —
   and nothing else. Extra flavors are not extra evidence; questions like
   "what is the frame made of" are what the profile pass (below) answers.
2. **Fly a path, don't idle a camera.** A gameplay-like flight path
   (enter, traverse, leave, with the camera swinging like a walking
   player's) records the dips a static average-fps readout hides.
3. **Record wall-clock per frame, vsync off**, at a fixed windowed
   resolution, and summarize cold / warm / steady (trim the warm pass's
   first second). The percentiles are the message: median and 1% low,
   not average fps.
4. **Photograph fixed poses** per variant and eyeball them side by side —
   a "faster" number that renders the map wrong (missing emitters, lost
   vertex light) measured nothing.
5. **Attribute with a profile, not with more variants.** Fly the PB scene
   once per ablation — shadows off, emitters off, splat off, lights off —
   and the deltas name the cost. The export side has its own one-line
   profile now: every export run ends with
   `[export-profile] … total/split`, attributing the bake's wall time
   (tile bake vs light bake vs texture work vs serialize/write). On the
   demo map, for instance, the retro bake's ~44 s is ~79% the imported
   props' light bake, and the modern GLB's is ~98% paint bake — no
   stopwatch guessing.

```bash
./run_bench.sh                    # exports the GLB variants if missing, flies all three (GL)
./run_bench.sh --reexport         # force re-export (also re-runs the import pass)
./run_bench.sh pb                 # one variant: pb | retro_glb | modern_glb
./run_bench.sh --renderer vulkan  # the forward_plus axis
./run_bench.sh --profile          # the ablation profile (GL; add --renderer vulkan)

./run_fly_bench.sh                # INTERACTIVE: fly the PB scene, graph + 1% lows
./run_fly_bench.sh retro_glb --renderer vulkan

./run_bench_win.sh                # the same bench, native Windows Godot (the 5060 box)
./run_bench_win.sh --renderer vulkan --profile
./run_fly_bench_win.sh            # interactive fly, on the Windows desktop

python3 tools/bench_contact_sheet.py   # grid exports/bench/shots/* into sheets
```

The Windows launchers live on the Windows-filesystem copy of the repo (a
Windows exe cannot use a `\\wsl.localhost` cwd) and find their Godot under
`Documents\_devtools\Godot_v4*`. One caveat keeps the exports honest: the
export step rebuilds the demo map, and the builder's pack props (the
market barrels) live outside the repo at `/mnt/ephemeral` on the dev
machine — a Windows-side export silently bakes a map WITHOUT them, so the
Windows box benches the GLBs rsynced over from the dev machine (the
launcher exports only when they are missing; the builder now screams if
the prop library is gone).

Reports land in `project/exports/bench/<renderer>_<variant>.json` (the
5060's copies ride alongside as `win5060_*.json`) — full per-frame arrays,
not just the summary. Every Linux Godot run is containerized and
memory-capped through `tools/godot_guard.sh`, runs strictly one at a time
on a real display (`GUARD_X11=1`, handled by the script).

> [gotcha] Do not compare these numbers against PPSSPP or the PSP — they
> answer "how does a modern Godot project pay for this map", on desktop
> hardware, with the desktop renderer. Device claims need the device.
