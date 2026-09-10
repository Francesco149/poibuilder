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

1. **Always `reset` before loading a module.** `run_psp_hw.sh` does this
   automatically. A module left over from a previous run leaves the GE and the
   display controller in whatever state it died in; the next module then
   **loads, reports success, and never executes** — a black screen with no
   output, which is very easy to misread as a bug in the new build.
2. **Never `modstop` a module that is still running.** It wedges module startup
   for the rest of the session. Exit instead with the app's own
   **Start+Select**, which stops and unloads the module cleanly. (`run_psp_hw.sh`
   tries a harmless `modunld` and otherwise tells you to press Start+Select.)
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

### Breadcrumbs written by the binaries

| file (over `host0:`) | written by | contents |
|---|---|---|
| `poi_profile.txt` | the battery | per-test cpu/gpu ms, sweep, ranked list |
| `pbm_load.log` | `pbm_load` | header counts, `FATAL` reasons, `total_free`/`max_free` before and after |
| `poi_app.log` | `PSPLINK_RUN` builds only | loop-stage breadcrumbs for the first 5 frames |
| `poi_trace.txt` | L+R / Start+Select in game | worst frames with camera poses |
| `poi_render.txt` | *you* write it | runtime render overrides (see below) |

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

Two knobs, both one line in `poi_render.txt`:
- `bias=+N` — blurrier, which compresses the differences between neighbouring
  levels (measured: bias +1 costs 1.40 ms vs 2.04 at bias -0.5).
- `level_mode=const` with `bias=<level>` — one LOD everywhere, which removes the
  steps entirely and looks sharper, at the cost of aliasing on the most-minified
  surfaces. Needs a level tuned per scene, so it is not the default.

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
