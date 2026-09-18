---
title: Godot-side performance
lead: The poibuilder scene as-is vs the retro-baked GLB vs the modern GLB — measured as frame pacing on a gameplay-like camera path, not as a static average-fps number.
---

A map's feel is decided by frame-time DIPS and pacing, not by the average
fps a still scene reports. The bundled benchmark
(`project/test_scenes/frame_pacing_bench.gd`, driven by `./run_bench.sh`)
flies the [alpha demo map](walkthrough-modern.html) along a gameplay-like
path — courtyard, through the doorway into the neon room, back out, up the
stairs, across the roof — while recording the wall-clock time of every
frame. The path is flown twice per variant: a **cold** pass (first-visit
experience, shader compiles and first uploads included) and a **warm** pass
(steady state).

## The three variants

| Variant | What it is |
|---|---|
| **PB scene as-is** | The editable PoiBuilder scene played directly: PBMesh runtime geometry, the splat shader, decal layers, realtime shadowed lights, 4 live GPUParticles3D emitters. This is "the godot modern pipeline, using the poibuilder scene as is". |
| **Retro-baked GLB** | The retro bake transported as glTF: baked tile textures, vertex lighting, plain meshes. |
| **Modern GLB** | The modern export with paint baked into textures: standard materials, realtime lights, colliders. |

## Which one do you ship?

**Export the baked map and play that.** The PoiBuilder scene as-is is the
*authoring* format — it carries the live splat shader, live decal layers and
every realtime light, and that is exactly what makes it the most expensive
way to render the map (~2.3× the baked GLB's median frame time above). So:
build, test and iterate in the PoiBuilder scene as much as you like, but
when you want to *play* or share the map, run it through **Export...** and
play the result — a modern GLB for the modern pipeline (paint baked into
textures, your own realtime lights or LightmapGI on top), or the PBM/retro
GLB for retro targets. The exported map looks the same and runs
dramatically faster.

## Measured results

Intel UHD 630 (integrated, Mesa), Godot **gl_compatibility**, 1280×720
windowed, vsync off, one GPU. Numbers from the demo map described above —
the map is the variable, the machine is the baseline:

| Variant | avg fps | median | 1% low | worst | jitter (σ) | >16.7 ms | hitches (2× median) |
|---|---|---|---|---|---|---|---|
| PB scene, cold | 39.5 | 24.7 ms | 38.4 ms | 89 ms | 5.3 | 97.0% | 1 |
| PB scene, warm | 39.6 | 25.0 ms | 37.5 ms | 46 ms | 4.9 | 96.1% | 0 |
| Retro GLB, cold | 88.7 | 11.0 ms | 20.6 ms | 196 ms | 5.2 | 4.7% | 17 |
| Retro GLB, warm | 89.1 | 10.9 ms | 20.0 ms | 28 ms | 3.4 | 5.1% | 13 |
| Modern GLB, cold | 98.6 | 9.5 ms | 18.7 ms | 96 ms | 3.7 | 2.8% | 23 |
| Modern GLB, warm | 99.3 | 9.4 ms | 18.9 ms | 29 ms | 3.4 | 2.9% | 24 |

How to read it:

- **The GLBs hold 60 fps with headroom.** Their medians (9–11 ms) leave a
  third of the 16.7 ms budget spare; only 3–5% of frames cross the 60 Hz
  line, and the warm passes never dip past 29 ms. The 1% low (~19–20 ms)
  is where the worst sustained moments live — still inside a 50 fps floor.
- **The PB scene as-is is GPU-bound at ~2.3× the cost** (median ~25 ms).
  That is the price of what it carries and the GLBs do not: the splat
  shader over the full-screen courtyard, three shadow-casting omnis in the
  closed room, and 4 live emitters. It is completely steady though — cold
  and warm passes are within noise of each other, and the worst single
  frame in the warm pass is 46 ms. On a discrete GPU the same scene clears
  60 fps comfortably; on the integrated chip it plays like a demanding
  indie scene, not like the GLBs.
- **Cold-pass hitches are real but one-time.** The GLB variants hit a
  burst of >2× median frames on first sight of new materials (the 196 ms
  worst on the retro cold pass is a shader-compile hitch); by the warm
  pass the retro worst collapses to 28 ms. Godot's pipeline cache keeps
  most of that on later runs.
- **Caveats an honest report carries:** the GLB transports do not replay
  the emitters or the scrolling textures (a consumer implements those from
  the [format recipes](export.html) — the demo viewer shows the reference);
  the two GLB variants carry equivalent lighting to the PB scene, so the
  delta is geometry/material cost plus the live features, not missing
  lights.

The PSP side is a different question with its own measurements — the
device's frame budget, fill-rate cliff and per-map budgets live in the
[PSP Optimization Guide](https://github.com/Francesco149/poibuilder/blob/master/retro_engine/psp/OPTIMIZATION.md);
device numbers are signed off for the reference maps.

## Re-run it

```bash
./run_bench.sh               # exports the GLB variants if missing, flies all three
./run_bench.sh --reexport    # force re-export (also re-runs the import pass)
./run_bench.sh pb            # one variant: pb | retro_glb | modern_glb
```

Reports land in `project/exports/bench/<variant>.json` — full per-frame
arrays, not just the summary. Every Godot run is containerized and
memory-capped through `tools/godot_guard.sh`, runs strictly one at a time,
and needs the display passthrough (`GUARD_X11=1`, handled by the script).

> [gotcha] Do not compare these numbers against PPSSPP or the PSP — they
> answer "how does a modern Godot project pay for this map", on desktop
> hardware, with the desktop renderer. Device claims need the device.
