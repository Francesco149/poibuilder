# Live PSP hardware testing

How to measure and debug the PSP renderer **on the device**. Written after a
round in which the emulator said "60 fps" for a build that was doing 35 on
hardware, and in which three separate mistakes each cost a device reset.

## Why the emulator cannot answer performance questions

PPSSPP rasterises on the host GPU: it has a huge texture cache, no shared
memory bus, no GE clipper, and no texture-cache thrashing. Measured on the same
build and the same camera:

| | PPSSPP | real PSP |
|---|---|---|
| stairs view, GPU ms/frame | ~0 | **27.25** (→ 34.9 fps) |

Use PPSSPP for **correctness and visuals**. Never use it to decide that
something is fast enough, and never conclude from it that a slowdown is fixed.

## One-time setup (~30 s of device time)

```bash
./setup_psplink.sh          # builds psplinkusb, installs the udev rule, deploys to the stick
```

Then, on the PSP: **Game → Memory Stick → PSPLink**, and leave it running.
Turn the **Hold switch on** so the unit cannot suspend (see rules below).

After that the device is never touched again: no memory-stick copies, no XMB
navigation, no USB-mode toggling.

## The loop

```bash
./run_psp_hw.sh            # profiling battery: builds, resets, uploads, runs, prints the report
./run_psp_hw.sh --app      # the interactive game build instead
./run_psp_hw.sh --keep      # leave usbhostfs_pc running afterwards
```

`host0:` on the PSP is `retro_engine/psp/hwrun/` on this machine. The test
binary reads the map from `host0:` and writes its results there, so nothing is
copied to the memory stick and results need no copying back.

The battery is configured by `ms0:/poi_profile.cfg` (absent over PSPLink) or by
the defaults in `psp_prof.c`: `frames`, `warmup`, `sweep`.

## Rules that each cost a device reset to learn

1. **Reset only when a module is actually left over.** `run_psp_hw.sh` checks
   for that and resets by itself. A stale module leaves the GE and the display
   controller in whatever state it died in, and the next module then **loads,
   reports success and never executes** — a black screen with no output, easy
   to misread as a bug in the new build.

   Resetting a *healthy* device is not free: it reboots the PSP out of PSPLink,
   and if PSPLink does not come back on its own you are left at the XMB with
   nothing running. Doing that unconditionally once sent someone chasing a
   "the demo does not start" bug that was really "the harness rebooted the
   console for no reason".
2. **Never `modstop` a module that is still running.** It wedges module startup
   for the rest of the session. **Exit the app with the Home button** instead —
   the PSP's own quit dialog — and re-run. (`run_psp_hw.sh` tries a harmless
   `modunld` and otherwise tells you.)

   **Home is not a fallback you can plan around: it often does nothing.** A
   wedged app never runs its exit callback, and there is no way to press a
   button over USB. When that happens the module stays resident, `modunld`
   answers `0x80020138` (busy), and no new build can be loaded — this has
   already cost a session that sat waiting for a Home press that could not
   happen. **A resident `PoiRetro` module IS the condition `reset` exists to
   clear**, so reach for it immediately:

   ```bash
   P=/tmp/psplinkusb/pspsh/pspsh
   $P -n -e "reset"                       # clears the wedge
   for i in $(seq 1 40); do sleep 1; timeout 10 $P -n -e "modlist" 2>/dev/null \
       | grep -q "UID:" && break; done    # link is usually back within a second
   $P -n -e "modlist" | grep -i poiretro  # must print nothing before loading
   ```

   `./run_psp_hw.sh` (either mode) performs exactly this check and reset by
   itself, which is the other reason to drive the device through it rather than
   by hand. Keep the reset for a *wedged or resident* module only — resetting a
   healthy device is what rule 1 is about.
3. **Recovery does not need a power cycle**: `pspsh -n -e "reset"` clears the
   wedged state; the USB link re-establishes by itself within a second or two.
4. **Suspend kills the USB link**, after which the shell is unresponsive.
   `scePowerIdleTimerDisable()` was tried as a guard and **removed** — it hung
   startup from a PSPLink-loaded module. Use the Hold switch.
   **But Hold blocks the controller**: with it on, every button reads 0 and the
   only set bit is `PSP_CTRL_HOLD` (0x20000), so an app looks like it has no
   working input. Hold ON is right for unattended profiling runs; Hold OFF is
   required to interact with an app. The HUD's `in: x,y btn NNNN` readout tells
   you which state you are in — check it before debugging "the controls".

7. **Read the input readout before touching the control code.** `in: 117,117 btn
   20000` with an app that ignores buttons is the Hold switch, not a bug in the
   input handling.
5. **Keep module BSS small.** PSPLink loads modules into the kernel partition;
   a 512 KB maximum free block was observed. The display list is 128 KB (a frame
   emits a few KB), and large scratch buffers (the profiler's triangle probe,
   the frame trace ring) are heap-allocated rather than static. A 1.8 MB BSS
   simply failed to load (`0x800200D9`).
6. **Verify the staged binary is current** before blaming a build:
   `strings hwrun/poiretro_psp_app.prx | grep "<new string>"`.

## Unplugging / replugging is fine (and expected)

Unplugging the PSP to go and look at the screen, then plugging it back in, is a
normal part of using this. It is handled:

- `usbhostfs_pc` reconnects on its own — it logs `Found Sony PSP device ...` for
  each re-enumeration and resumes.
- It is supervised with `restart: on-failure`, so if the device vanishes mid
  transfer and the process dies, it comes back and reconnects.
- `run_psp_hw.sh` detects the PSP leaving USB during a run (via `lsusb`, on the
  host, so it perturbs nothing) and reports it instead of waiting out the
  timeout.

The one thing an unplug costs you is the *current* run: results are written to
`host0:`, which **is** the USB link, so they are gone. The app keeps running on
the device; replug and re-run.

## Diagnostics toolbox

`pspsh -n -e "<cmd>"`, with `P=/tmp/psplinkusb/pspsh/pspsh`:

| command | what it answers |
|---|---|
| `modlist` / `modinfo <uid>` | is it loaded; segment addresses and sizes |
| `thlist` | does the module have a live thread (`user_main`) |
| `thinfo <uid>` | **Status** and **RunClocks**. Frozen `RunClocks` between two samples = blocked, not looping |
| `thctx <uid>` | register dump. `Real EPC` in the kernel range plus `Context EPC 0x7F800001` = parked in a kernel wait |
| `exlist` | module exceptions (`Bus error (data)` = a bad dereference) |
| `meminfo` | partitions, `TOTALFREE`/`MAXFREE` before allocating anything |
| `scrshot host0:/x.bmp` | the **real framebuffer** as a 480x272 24-bit BMP — the only way to see the device screen from here |
| `savemem addr len host0:/x.bin` | raw memory dump (slow; avoid large reads) |
| `reset` | recovery, and the standard pre-load step |

### Reading the screen

```bash
P=/tmp/psplinkusb/pspsh/pspsh
$P -n -e "scrshot host0:/shot.bmp"     # lands in hwrun/
python3 retro_engine/bmp_scrshot.py hwrun/shot.bmp --crop 230,205,330,240 --zoom 8
```

Then **read the PNG directly** (no `?q=` query) so the image is actually
inspected rather than described by another model.

`scrshot` also prints `frame_addr` and `pixel_format`. Use them: if they show
psplink's values (`0x44000000`, `pixel_format 3`) rather than ours
(`0x4044000`, `pixel_format 1` = 5551), the app never took the display — that
alone distinguishes "our renderer is broken" from "nothing is running".

### Verifying a scrolling texture on the device

A scrolling texture that is wrong looks exactly like one that is frozen, and a
sign error is invisible in any single frame. Two captures of the app (no input,
so the camera is static) are enough:

```bash
P=/tmp/psplinkusb/pspsh/pspsh
for i in 1 2 3 4; do $P -n -e "scrshot host0:/hw_$i.bmp"; done   # ~0.1-0.3 s apart

python3 - <<'EOF'
from PIL import Image
import numpy as np
f = [np.asarray(Image.open(f"hw_{i}.bmp").convert("L")).astype(float) for i in (1,2,3,4)]
x0, x1, y0, y1 = 318, 372, 82, 132      # a window of pure scrolling surface
def best(a, b, rng=30):
    return sorted(((dy, float(np.abs(a - np.roll(b, dy, axis=0)).mean()))
                   for dy in range(-rng, rng+1)), key=lambda t: t[1])
for i in range(3):
    c = best(f[i][y0:y1, x0:x1], f[i+1][y0:y1, x0:x1])
    print(f"dy {c[0][0]:+d} (err {c[0][1]:.2f}) vs zero-shift {dict(c)[0]:.2f}")
EOF
```

Rules that make the answer trustworthy:

- **Validate the sign with a synthetic control first**: `np.roll(a, +6)` is
  content moved DOWN, and the correlation reports `dy = -6`. This repository
  shipped a waterfall that climbed its wall because the sign was assumed
  instead of measured.
- A real match drops the error well below the zero-shift value (e.g. 9.1 vs
  12.9). If the best error equals the zero-shift error, nothing moved in that
  window — pick a window that covers only the scrolling surface, not the whole
  region around it.
- The pattern is quasi-periodic vertically, so the *magnitude* can lock onto a
  multiple of the repeat. The **sign** is what this measures; the magnitude
  follows from the speed and the interval.
- The window must exclude anything else that moves: the scripted patrol sphere
  crosses the water in the showcase map, and it will happily pin the
  correlation at zero.

`./run_psp_headless.sh` does the same check in PPSSPP (two captures with a
frozen camera, `screenshot_psp.png` / `screenshot_psp_scroll.png`) for a first
look, but PPSSPP's frame captures are not pixel-stable between different frame
indices — use the device, or a same-frame A/B against a map with zeroed scroll
speeds, before believing a direction.

### Breadcrumbs written by the binaries

| file (over `host0:`) | written by | contents |
|---|---|---|
| `poi_profile.txt` | the battery | per-test cpu/gpu ms, sweep, ranked list |
| `pbm_load.log` | `pbm_load` | header counts, `FATAL` reasons, `total_free`/`max_free` before and after |
| `poi_app.log` | `PSPLINK_RUN` builds only | loop-stage breadcrumbs for the first 5 frames |
| `poi_trace.txt` | L+R in game | worst frames with camera poses |
| `poi_render.txt` | *you* write it | runtime render overrides (see below) |

### Never do `host0:` file I/O on a path the player can trigger

`host0:` opens **block** while the USB link is down, and the app has no way to
time that out. A trace dump that tried `host0:` first, from inside the quit
path, froze the game on exit once the link had dropped — the Home button still
worked (it does no I/O), which made it look like the quit chord was broken.

Rule: anything reachable while someone is playing writes to the memory stick
(`ms0:`) first and treats `host0:` as a fallback. Only the profiling battery,
which by definition runs with a live link, writes `host0:` first.

### Runtime render overrides — no rebuild

The app reads `host0:/poi_render.txt` once at startup:

```
filter=linear     # linear (trilinear) | mip_lin | nearest | asym
bias=-1           # negative = sharper; also the constant level when level_mode=const
mips=0            # 1 = use the load-time mip chain
level_mode=const  # auto (per-primitive derivative) | const (one level everywhere)
skip_mesh=Foo     # drop any mesh whose name contains this (isolate a draw)
```

Edit the file, re-run, screenshot. This is how the tile-seam and blur issues
were A/B'd without a build per data point.

## Particles (standard lump "emitters", SPEC §8)

The emitter feature is measured like everything else here — on the device, with
40-frame averages after a warmup, and with an A/B on the same camera.

### What each row is

| row | what it draws |
|---|---|
| `scene_spawn` / `abi_noemit_spawn` | the showcase at the spawn view, with and without the map's emitters |
| `abi_emit_add_spawn` | only the additive emitters (brazier flipbook + embers, 32 particles) |
| `abi_emit_blend_spawn` | only the blended emitter (waterfall mist, 14 soft puffs) |
| `particles_16_s` / `_64_s` / `_256_s` | 16/64/256 moving additive particles in an empty frame (the format's whole per-map budget is 256) |
| `pfill_glow_add` / `pfill_glow_blend` / `pfill_smoke_blend` | four STATIONARY particles covering half the screen, the same coverage in all three: built-in 32x32 RGBA5551 glow, additive; the same, alpha-blended; the map's 64x64 RGBA8888 soft-alpha art |

`poi_render.txt` takes `particles=<bitmask>`: `1` blended emitters, `2` additive,
`3` both (the default), `0` off — the app then reproduces the ablation on the
camera the player is actually looking at. `poi_render.txt` is read at startup.

### Measured

| what | gpu | cpu |
|---|---|---|
| clear + swap (the floor) | 0.29 ms | 0.02 ms |
| 16 moving particles | 0.29 (nothing) | 0.15 |
| 64 moving particles | 0.44 | 0.35 |
| 256 moving particles (the whole budget) | **0.72** | **1.14** |
| 4 stationary particles, half-screen coverage, glow, additive | 0.46 | 0.10 |
| …same, alpha-blended | 0.46 | 0.11 |
| …same, the 64x64 RGBA8888 soft-alpha art | 0.46 | 0.11 |

**Particle fill costs what opaque fill costs**: ~430 Mfrag/s here versus 490
Mfrag/s for the `fill2d` probes, and the blend mode and the texture format make
no measurable difference at this size. Cost tracks the on-screen AREA of the
particles, not their count.

### The one expensive configuration

At the spawn view the showcase's emitters cost **+1.7 ms gpu / +0.5 ms cpu**, and
the split says it is entirely the *blended* emitter: the additive pair measures
free (6.76 vs 6.84 with no emitters at all), while the 14 blended mist puffs cost
8.61. The same delta appears in the interactive app's own HUD (+0.5 cpu, +1.7
gpu), i.e. it is reproducible in two independent measurements.

The mechanism is not yet identified: the coverage of those puffs (~tens of
thousands of fragments) accounts for ~0.05 ms of fill at the measured rate, and
neither the 8888 format nor blending is expensive per fragment (`pfill_*` above).
Recorded so it is not re-investigated from scratch — and the practical guidance
is unaffected: keep blended emitters small or distant, and prefer additive for
anything close to the camera.

### Two ways this measurement lied before it was right

* The first fill probe mutated a *zeroed* `RenderCfg` (the guard read
  `if (!cfg.particles)`, which a default config never satisfies). With
  `use_textures = 0` and `use_mips = 0` it sampled a 512x512 atlas as a particle
  texture with no mip chain and reported 16.6 ms for four small quads — the
  documented 19x minification penalty, not the particle cost. A probe must own a
  real `render_cfg_default()`.
* The same probe reused the `tex` field as both "additive" flag and texture id,
  so the "additive vs blend" comparison silently drew the same configuration
  twice. Rows that differ by name must differ in fact.

### Reading the particles on the device

`scrshot` captures the real framebuffer; the showcase's brazier sits above the
left pillar and the mist column stands in front of the waterfall. The HUD line
is a single 60-character row (480 px / 8 px per glyph) — a longer format string
silently loses its last digits (a full particle count read as "Parts: 4" that
way).

## The waterfall foot: the LOD cliff (found, fixed, regression-guarded)

The report was precise and worth recording as it arrived: *"standing right in
front of the base of the waterfall the gpu time increases to a massive 25 ms —
only for that one spot. The flame particles have near zero overhead, and even
if the mist is off screen it still spikes."* The app's HUD at `pos 4.6 1.3 -2.3`
confirmed **gpu 24.7-24.8 ms / 36 fps**, rock steady across three captures.

The scene drawn there is the *same* 1526 triangles and 25-27 draw calls as the
spawn view (which runs at 8.7). So the cost had to be per-fragment, and the
battery now has the camera for it (`waterfall`, plus `wf_*` rows that ablate one
thing at a time on that exact pose):

| row | what it removes | gpu ms |
|---|---|---|
| `wf_base` | — (the old default) | 25.12 |
| `wf_noemit` | both emitters | 22.75 |
| `wf_blend_only` / `wf_add_only` | one emitter half each | 25.20 / 22.69 |
| `wf_noscroll` | animated UV scroll | 24.67 |
| `wf_noclip` / `wf_nodepth` / `wf_nocull` | clip planes / depth test / culling | 25.10 / 25.12 / 28.18 |
| `wf_skip_allwater` | all five water surfaces | 15.98 |
| `wf_skip_wetwall` | the tiled wall behind the fall | 14.84 |
| `wf_notex` | texture sampling | **0.69** |
| `wf_tex64` | a cache-resident 64x64 stand-in for every texture | **2.96** |

**Not the particles** (+2 ms of 25), **not the scrolling textures** (nothing at
all), **not clipping or depth** — texture sampling, and specifically the GE's
texture cache.

### The mechanism, and why "sharper" was the bug

The texture cache is ~8 KB. A fragment whose sampled mip level fits costs
~2 ns (481 Mfrag/s); one that misses costs ~37 ns (27 Mfrag/s) — the same 19x
the no-mip case pays, and the same rate the `fill2d_1x_tex512` probe reports.
The level the hardware picks from the UV derivatives is the sharpest that still
averages ~1 texel/pixel, so at that level **the sampled footprint IS the
surface's on-screen area**: 75 000 pixels of wall means ~75 000 texels of the
chosen level (~150 KB for a 16-bit texture). Only close, screen-filling
surfaces reach that — which is exactly the geometry of standing under a
waterfall — and the cliff between fitting and not fitting is sharp.

The renderer shipped a `-1.0` LOD bias ("trades a little softness back for
detail", chosen when the scene was cheaper and the budget had room). One level
sharper is enough to push every close surface off that cliff:

| config at the waterfall foot | gpu ms | frame ms |
|---|---|---|
| trilinear, bias −1.0 — the replaced default | 25.21 | 27.8 |
| mip_linear, bias −1.0 | 14.61 | 16.9 |
| mip_linear, bias 0.0 | 11.20 | 13.3 |
| mip_linear, bias +0.5 | 4.32 | 6.3 |
| **mip_linear, bias +1.0 — shipped** | **2.79** | **4.8** |
| trilinear, bias +1.0 | 4.63 | 6.6 |
| mip_linear, bias +2.0 | 1.02 | 2.6 |
| const level 3 / const level 0 | 1.49 / 43.83 | 3.4 / 46.3 |

At the two views the map is judged on, the same one-line change reads:

| view | replaced default | shipped |
|---|---|---|
| spawn | 8.76 | 0.43 |
| stairs | 11.12 | 0.11 |
| waterfall foot | 25.12 | 2.79 |

`poi_render.txt` reproduces any row without a rebuild (`filter=`, `bias=`,
`level_mode=`); `bias=0` is visibly sharper and still fits at the worst view
(11.2 ms / 75 fps), `bias=2` is what a weaker machine would want. **Do not
raise the bias back toward −1 "for sharpness" without re-measuring**: this is a
cache boundary, not a smooth quality/cost trade, and the whole map is 10-100x
slower on the wrong side of it.

Authoring rule that follows: a surface that fills the screen at ~1 texel per
pixel is the expensive case. Tiling a texture more densely per metre (smaller
repeat on screen) is the content-side lever; the level bias is the renderer-side
one.

## Two surface classes with their own LOD policy (follow-up round)

### Foliage paid the cache penalty the bias cannot reach

CUTOUT textures (tree/bush/flower sprites, the 1-bit-alpha particle art) used to
ship with **no mip chain at all** — halving a 1-bit alpha erodes the silhouette,
so the loader refused to build one — which means they sampled level 0 forever:
256x512 to 512x512 of texture, minified, at a cache miss per fragment. That is
also why they looked "unaffected by the LOD bias": with no chain there is no
level for a bias to select from.

Fix: build them a chain with an **alpha-preserving (ANY-opaque-wins) combine**.
The silhouette dilates by half a texel per level instead of eroding, and the
chain collapses the fetch footprint like every other texture:

| row (foliage view, sprites 2-6 m away) | gpu ms |
|---|---|
| `fol_cutoutnomip` (the old level-0-only behaviour) | 6.09 |
| `fol_base` (alpha-preserving chain) | **0.46** |

Visually identical at that range (captures compared side by side): the chain
only engages as a sprite recedes, which is where it also removes the shimmer the
old build had. Costs ~1/3 more texture memory for the cutout textures (~345 KB
in this map); the loader still fails loudly if the heap runs out.
`cutout_mips=0` restores the old behaviour at runtime for an A/B.

### The splat/tile seams are per-primitive LOD steps, and they are tunable per mesh

The reported symptom was "the splatted parts have visible seams". Reproduced at
a grazing floor view and pinned down by ablation: with `mips=0` (every fragment
samples level 0) the painted path is **perfectly continuous — no bands at all**,
and a *constant* level removes them too. So they are the hardware's
per-primitive LOD: the GE picks one level per triangle from that triangle's own
UV derivatives, and a floor crosses several levels across a few metres, so
neighbouring baked tiles differ by one step and the step is a visible band once
the level is coarse.

The renderer now applies a **per-mesh LOD policy**: meshes matching
`detail_mesh=` (default `TileAtlas`, the baked splat/stamp tiles) get
`detail_bias` (default -1: one level sharper than the rest of the scene) — or,
when `detail_const` is set, ONE constant level for the whole mesh, which is the
only setting that removes the step between neighbouring primitives entirely.

| row (grazing floor view) | gpu ms | frame ms |
|---|---|---|
| `fg_base` (shipped: atlas tiles one level sharper) | 0.12 | 2.49 |
| `fg_detailoff` (no policy) | 0.12 | 2.48 |
| `fg_detail_const1` (atlas tiles pinned to level 1) | 0.50 | 3.15 |
| `fg_nomips` (no chains at all, for scale) | 26.23 | 29.25 |

All of it is well inside budget — the detail meshes cover a small part of the
screen, so sharpness there is nearly free. The capture pair shows it: the
shipped policy reads sharper than the un-special-cased one (confirmed by eye on
the device), and `detail_const=1` removes the steps with no visible aliasing at
that view. Widen the policy with `detail_mesh=TilesMaterial` (or any substring
of a mesh or texture name) if the base tiling floor wants the same treatment.

All four knobs are live in `poi_render.txt` — no rebuild: `cutout_mips=`,
`detail_mesh=`, `detail_bias=`, `detail_const=`.



## Grazing-angle seams on tiled surfaces (investigated, partly inherent)

Thin lines at tile boundaries on a floor seen at a shallow angle. What was
ruled out, so it does not get re-investigated:

- **Not mipmapping** — they persist with `mips=0`, which instead brings
  aliasing/shimmer.
- **Not atlas mip bleeding** — slots are 128 px, the box filter halves on even
  boundaries, and levels therefore never mix across slots.
- **Not the atlas UV remap** once fixed (the half-texel inset WAS a real,
  separate seam bug; see CLAUDE.md v0.9.63).
- **Not coplanar z-fighting** between the base floor material and the baked tile
  quads: dropping one layer with `skip_mesh=FloorSplatMat` leaves the lines
  unchanged (and leaves holes, so the layers are adjacent, not stacked).

What remains is the **GE's per-primitive LOD**: the level is derived from each
triangle's own UV derivatives, so adjacent tile quads land on different levels
and a step in sharpness appears along their shared edge. It changes as the
camera moves, which reads as flickering. The PSP has no anisotropic filtering
and no per-surface LOD smoothing, so this is structural to tiled textures on
this hardware.

**Status: a hardware limitation with a now-tunable severity, not a bug with a
known fix.** The investigations above list what has been ruled out so the same
ground is not re-covered. The per-mesh detail policy above is the practical
mitigation — `detail_bias` (default -1) keeps the painted tiles sharper than the
rest of the scene, and `detail_const=<level>` removes the neighbouring-primitive
step entirely on whichever meshes it matches (`detail_mesh=`); both were
verified by capture at a grazing floor view. If you find a technique that
removes the step *without* giving up per-surface LOD, it belongs here.

Three knobs, all one line in `poi_render.txt`:
- `bias=+N` — blurrier, which compresses the differences between neighbouring
  levels (measured: bias +1 costs 1.40 ms vs 2.04 at bias -0.5).
- `level_mode=const` with `bias=<level>` — one LOD everywhere, which removes the
  steps entirely and looks sharper, at the cost of aliasing on the most-minified
  surfaces. Needs a level tuned per scene, so it is not the default.
- `detail_const=<level>` — the same, but only for the meshes `detail_mesh=`
  matches, which is the version that costs nothing measurable (0.50 vs 0.12 ms
  at the grazing floor view).

## Profiling methodology

Every frame is split:

- **cpu** — building the display list (GE idle, CPU busy)
- **gpu** — `sceGuSync` waiting for the GE to finish that list
- **wall** — elapsed time including the vblank-paced swap

`gpu` is the number that matters for GPU-side cost; `wall` is vsync-quantised
and will flatter a frame that is just over budget.

The battery pairs each measurement with **ablations** that change one GE state
at a time (`abi_notex`, `abi_tex64`, `abi_nomip`, `abi_trilinear`, `abi_bias_*`,
`abi_nodepth`, `abi_nocull`, `abi_noclip`, `abi_near050`, `abi_noalpha`,
`abi_nohud`, …) plus **synthetic probes** that calibrate the machine
(`clear_only`, `fill2d_*`, `fill3d_*`, `min512_*`, `drawcalls_256`, `tris_4096`).

`python3 retro_engine/pbm_profile_report.py hwrun/poi_profile.txt` turns the log
into deltas, the sweep worst-first, probe calibration and a CPU/GPU-bound call.

Key discipline: **hold the pixel count fixed and change one thing.** "Textures
off" is not evidence about texture *cache* behaviour; substituting a
cache-resident texture at identical coverage is.

## What the hardware actually costs (measured)

| probe | result |
|---|---|
| clear + swap (per-frame floor) | 0.32 ms |
| untextured full-screen fill | 487 Mfrag/s |
| full-screen fill, cache-resident 64x64 texture | 480 Mfrag/s |
| full-screen fill, 512x512 texture, **no mip chain** | **25 Mfrag/s** (19x penalty) |
| draw call | ~0.94 µs (19 calls ≈ 18 µs) |
| triangle throughput (`tris_4096`) | ~2.2 M tris/s |
| guardband clipper (big quad, clip planes on vs off) | 0.26 vs 0.26 ms — **free** |
| scene, with mip chain (worst of 11 poses) | 3.04 ms → 328 fps of headroom |

The 19x texture-cache penalty is the single most important number here: it is
why the renderer must sample a mip chain, and why every measurement must be
taken on the device.

## Checklist: "the module loads but nothing happens"

1. `scrshot` — is anything on screen at all? Check `pixel_format` (1 = ours).
2. `modlist` — still loaded? `thlist` — does `user_main` exist?
3. `thinfo` twice — is `RunClocks` advancing? Frozen = blocked.
4. `exlist` — a `Bus error` means a bad pointer, not a hang.
5. Read the breadcrumb files: `pbm_load.log` (asset/loader), `poi_app.log`
   (loop stages).
6. If the app never reached its first line: suspect the *device state*, not the
   build — `reset` and try again before changing any code.
