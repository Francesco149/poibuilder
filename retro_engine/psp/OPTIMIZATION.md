# PoiRetro PSP renderer — the optimization inventory

What this engine does to be fast on a PlayStation Portable, in the order that
matters, with the measured cost of each decision. Everything here was measured
**on a real PSP** with the device battery (`./run_psp_hw.sh`); the method,
the raw tables and the failure modes are in `HARDWARE-TESTING.md`, and the
per-feature authoring consequences are in `../RETRO-AUTHORING.md`.

Read this before changing the renderer or the exporter: most of the traps below
cost a device session to find, and several were found only after a build that
"looked right" was measured.

---

## 0. The machine, and the three numbers that shape everything

| what | measured |
|---|---|
| fill, untextured | **487-490 Mfrag/s** |
| fill, textured **and cache-resident** | **480 Mfrag/s** |
| fill, textured, texture **does not fit the ~8 KB texture cache** | **25-27 Mfrag/s** — a 19x per-fragment penalty |
| draw call | ~0.94 µs |
| triangles | ~2.2 M tris/s |
| clear + swap (the per-frame floor) | 0.29-0.32 ms |
| guardband clipper (large clipped quad, clip planes on vs off) | 0.26 vs 0.26 ms — free |

Three consequences:

1. **Fill dominates.** A screen is 130 560 fragments = ~0.27 ms untextured. Any
   design question ("more particles? a bigger mesh? another layer?") is a
   fragment question first, and a vertex/normal question a distant second.
2. **The texture cache is the cliff.** Whether a surface's sampled mip level
   fits ~8 KB decides between ~2 ns and ~37 ns per fragment. Nothing else in
   this engine has a 19x in it. Section 3 is the whole story.
3. **State changes are cheap but not free.** 25-28 draw calls and a handful of
   texture switches cost tens of microseconds; they are visible only because the
   whole frame is ~2-5 ms.

---

## 1. Where the frame actually goes (current build, showcase map)

The camera sweep of the battery (40-frame averages, cpu + gpu, best ≈ 16.67 ms
budget = 60 fps) — the complete table, worst first:

| view | gpu ms | frame ms | fps headroom |
|---|---|---|---|
| waterfall foot (the app's worst) | 2.73 | 4.92 | 203 |
| waterfall foot, lower eye | 2.58 | 4.47 | 224 |
| ramp | 1.62 | 3.70 | 270 |
| above courtyard, looking down | 0.94 | 3.55 | 282 |
| spawn | 0.60 | 3.28 | 305 |
| floor at a grazing angle | 0.64 | 2.99 | 334 |
| floor grazing, lower | 0.28 | 2.78 | 360 |
| stairs (low eye) | 0.11 | 2.37 | 423 |
| below the floor, looking up | 0.11 | 2.33 | 430 |
| arch | 0.11 | 2.31 | 433 |
| sky | 0.11 | 2.29 | 438 |
| stairs | 0.11 | 2.24 | 447 |
| foliage | 0.46 | 2.22 | 451 |
| balcony | 0.11 | 2.18 | 459 |
| courtyard corner | 0.11 | 2.02 | 494 |

The **CPU is the floor**: ~2.0-2.7 ms of display-list construction runs in every
one of these views, and the GE is idle for most of it. That is deliberate — the
scene is static, so per-frame CPU work is only "walk the meshes and emit".

---

## 2. Geometry and submission

- **One interleaved vertex format, straight into the display list.**
  `PspVertex` is 24 bytes: `float u, v; uint32_t color; float x, y, z;` —
  exactly `GU_TEXTURE_32BITF | GU_COLOR_8888 | GU_VERTEX_32BITF |
  GU_TRANSFORM_3D`. The GE reads it with no conversion, and the geometry is
  transformed/multiplied by hardware.
- **Triangles are the primitive; quads are an authoring concept.** The exporters
  triangulate at export.
- **No per-frame allocation, no vertex buffers to bind, no index buffers.**
  Meshes are one `sceGuDrawArray` each, from a pointer into the map's
  load-time allocation. Emitter quads are the exception: they are generated per
  frame into the display list via `sceGuGetMemory` (that is what makes particles
  possible without a vertex buffer pool).
- **Spatial chunking (≤384 vertices per mesh)** by the exporters. This was
  introduced for the clipper and turned out to matter more for *bounds
  locality*: a 12 x 12 m floor as one draw call was measured at 27 ms in a view
  where the same floor chunked was 0.58 ms (the win was the mip chain, but the
  chunking is what keeps a single mesh from being the whole cost of the frame).
- **Backface culling on** (`GU_CULL_FACE`, CCW front faces). Worth ~3 ms at the
  waterfall foot if disabled (`wf_nocull` 28.18 vs 25.10 in the pre-LOD-fix
  build) — i.e. it is not a micro-optimization, it is half the opaque fill.
- **Near plane 8 cm + `GU_CLIP_PLANES`.** Measured free (a guardband-crossing
  quad costs 0.26 ms with clip planes on and off), kept because the tight near
  plane keeps large floor quads out of the clip volume in tight spaces, and the
  hardware clipper then has almost nothing to split.
- **Depth: tested, never written** (see §6 for why, and what it costs).

---

## 3. Textures — where every one of these milliseconds is

### 3.1 Formats and layout

| decision | why |
|---|---|
| `RGBA5551`, 2 bytes/texel, **swizzled** | half the memory bandwidth of 32-bit, and the swizzle is what makes the texture cache usable at all (64-byte blocks cover 2D neighbourhoods) |
| `RGBA8888`, 4 bytes/texel, **unswizzled** | only when 8 bits of alpha are needed (soft-alpha surfaces: water, mist). The GE's 16-bit swizzle layout does not apply, and the loader builds the level chain linear instead |
| one texture per material, power-of-two, ≤512 | the GE takes power-of-two sizes; the cache arithmetic (below) is what actually bounds size |

### 3.2 Mip chains: the single biggest win in the engine

The GE picks one mip level per **primitive** from that primitive's own UV
derivatives. If the level it wants does not fit the ~8 KB texture cache, every
fragment pays a main-memory fetch: **25-27 Mfrag/s instead of 480** (measured;
the same 19x the no-mip case pays). `fill2d_1x_tex512` (one full-screen quad on
a 512 texture, level 0) = 4.85 ms; the same quad on a cache-resident 64x64
texture = 1.09 ms for *four* screens.

What the chain costs and buys, in order of when it was learned:

- **Chains are built at load** for every 16-bit power-of-two texture, down to
  16x16, one swizzled 64-byte-aligned buffer per level, each level its own GE
  `sceGuTexImage` register. No runtime generation.
- **The minification filter must be a mipmap filter.** `GU_LINEAR` and friends
  ignore the chain entirely — `GU_LINEAR_MIPMAP_NEAREST` is the shipped
  minification filter (one level, 4 taps), magnification stays `LINEAR`.
- **Trilinear was dropped**: it doubles the fetch set (two levels) for a
  level-crossing smoothness that per-primitive LOD steps through anyway.
  Measured at the waterfall foot: trilinear 25.21 ms vs single-level 14.61 ms
  at the same bias.
- **The LOD bias is a cliff, not a dial.** The shipped default is bias +1 (one
  level coarser than "sharpest that still averages ~1 texel/pixel"). The old
  -1.0 ("trades a little softness for detail") sampled one level past the cache
  boundary and cost **10x-100x** at close range: waterfall foot 25.21 → 2.79 ms,
  stairs 11.12 → 0.11 ms, spawn 8.76 → 0.43 ms. See §3.4.
- **Alpha-aware downsampling.** Opaque and blend textures use a box filter
  (alpha-weighted for blend, so fading edges do not darken). **CUTOUT** textures
  use an ANY-opaque-wins combine: a plain box filter erodes a 1-bit silhouette
  away by the fourth level, which is why cutouts used to ship with no chain at
  all — and paid the 19x cliff on 256x512 foliage. With the alpha-preserving
  combine: foliage view 6.09 → 0.46 ms, silhouette intact (it dilates half a
  texel per level instead of eroding).

### 3.3 Atlases and UV animation

- Baked splat/stamp tiles live in 512x512 atlases of 128x128 slots, packed
  edge-to-edge, and are sampled with **`GU_CLAMP`** (a tile must not wrap into
  its neighbour). Tiling base materials keep `GU_REPEAT`.
- **UV scrolling is one register** (`sceGuTexOffset`), written only for meshes
  whose offset actually moved this frame (the last values are cached, so a
  scene with no animated meshes emits nothing). The offset is wrapped into one
  repeat before it reaches the 12-bit register. Measured cost: nothing
  (`wf_noscroll` is within noise of the baseline).

### 3.4 The per-mesh LOD policy (micromanagement that pays)

The level-mode registers are **per draw call**, so the renderer can spend
sharpness where it shows:

- Global: `PBFILT_MIP_LIN` + `tex_lod_bias = +1`.
- Meshes matching `detail_mesh=` (default `TileAtlas` — the baked splat/stamp
  tiles) sample **one constant level** (`detail_const`, default 1). That is the
  only setting that removes the level step the hardware puts between
  neighbouring primitives, and it is what turns a smeared, seamed painted floor
  into a crisp one for ~0.45 ms: grazing floor 0.57 ms (shipped) vs 0.12
  (per-primitive) vs 1.68 (pinned to level 0). Every view stays inside budget.
- Runtime knobs (no rebuild): `bias=`, `filter=`, `level_mode=`, `detail_mesh=`,
  `detail_bias=`, `detail_const=`, `cutout_mips=`, `mips=` in `poi_render.txt`.

---

## 4. Passes and state discipline

- **Two passes**: opaque (no blend, alpha test off) then alpha (cutout +
  blend, alpha test on). The split exists because blended fragments must not be
  ordered by draw order *within* the opaque set, and because alpha-tested
  cutouts reject fully transparent fragments early.
- **Alpha test thresholds are per-mode**: `GU_GREATER 0x10` for cutouts (the
  hard silhouette), `0x00` for blends (only fully transparent texels are
  discarded). With `0x00` a blended surface still rejects its invisible texels,
  which is what keeps early-Z meaningful for it.
- **Emitters are drawn last, blended first**: blended emitters are sorted
  back-to-front (insertion sort over ≤64 particles — the whole point of the
  stateless particle model is that this is the only per-particle work on the
  CPU), additive emitters are drawn unsorted because additive blending is
  order-independent.
- **Texture state is cached** (`last_tex_id`): a static frame with 24 meshes
  emits only the switches the material order actually requires. The UV-offset
  cache starts invalid on purpose — a display list does not reset GE registers,
  and a stale offset from the previous frame painted the whole scene once.
- **The HUD uses the 2D pipe** (`GU_SPRITES`, `GU_TRANSFORM_2D`), so it neither
  disturbs 3D state nor needs a matrix stack.

---

## 5. Per-frame CPU work (and why it is nearly constant)

- The display list is 128 KB, allocated once; a frame emits a few KB of
  commands. `sceGuSync` splits the frame into **cpu** (building the list) and
  **gpu** (waiting for the GE) — the battery reports both, and at ~2.5 ms cpu
  the scene is CPU-bound in most views today.
- **Particles are closed-form.** Particle *i*'s state at time *t* is a function
  of `(t, i, emitter seed)`: no simulation, no per-particle state, no
  allocation, one `sin`/`cos` pair per particle out of a table. Per-particle
  constants are derived once at load. This is also what makes the look
  reproducible between the Godot viewer and the device.
- **No culling pass, no sorting of opaque meshes, no per-frame bounds maths.**
  The scene is static; the exporters pre-computed the draw order (transparent
  surfaces are emitted in the order the blend needs, which is documented in
  `SPEC_RETRO_FORMAT.md`).
- Emitter-level and per-particle culls exist and are cheap: a bounding sphere
  against the frustum planes, and a projected-size cull that drops particles
  thinner than ~1.5 px (which would otherwise scatter texture fetches for a
  handful of pixels).

---

## 6. What is deliberately NOT done

| not done | why |
|---|---|
| runtime lighting, shadow maps, light probes | all lighting and AO is **baked into vertex colours** at export. Zero runtime cost, and the look matches the Godot preview |
| runtime texture compression / generation | everything is pre-converted (5551/8888, swizzle, chains, atlases, POT) — the 333 MHz CPU has no headroom for decode |
| **depth writes** | the renderer tests depth but never writes it (`sceGuDepthMask(GU_FALSE)` in every pass). Consequence: no fragment is ever rejected, and **draw order decides occlusion** — which is exactly what the exporters arrange for (opaque meshes ordered so the visible surface is drawn last; transparent surfaces in blend order). Enabling writes is measured free on this content (arch 0.114 vs 0.114 ms; waterfall 2.749 vs 2.735; grazing floor 0.688 vs 0.683) and is a one-knob experiment (`depth_write=1`), but it makes the *coplanar* floor layers (base material quad + baked tile quads at the same height) z-fight, which the current arrangement hides. Change it only with captures of the layered floor in hand |
| trilinear filtering | 1.7x the fill cost of single-level sampling for a smoothness nobody sees at these texel densities |
| anisotropic filtering | the hardware has none; the grazing-angle seam it would fix is documented as a known limitation |
| a depth prepass / render-to-texture effects | eDRAM is 2 MB and the frame is 480x272; there is no budget or need |
| dynamic geometry, skinned meshes, morphing | the format is static maps + scripted entities + particles |

---

## 7. Budget: what an author may actually spend

- **Particles: 256 per map** (the format's cap). Measured: 16 particles
  0.15 ms gpu / 0.29 cpu; 64 particles 0.35 / 0.44; **256 particles 0.72 gpu /
  1.14 cpu** — the whole particle budget costs about a fifth of the frame.
- **Blended vs additive**: additive is order-independent (no sort) and measured
  free at the spawn view; **blended** particles cost their fill like any other
  surface and, before the LOD work, cost 19x more than they should. Keep blended
  emitters small or distant, or make sure their texture fits the cache
  (the shipped policies do this for you as long as the emitter texture is small
  and power-of-two).
- **Fill is the budget**: a full screen of opaque fill is 0.27 ms, so the scene
  above spends ~2-10 screens of fill. Adding a screen-filling surface costs
  ~0.3 ms; adding a *minified* one used to cost 5 ms.
- The knobs, per view, are all in `poi_render.txt` (`bias`, `filter`,
  `level_mode`, `detail_*`, `cutout_mips`, `mips`, `particles`, `uv_scroll`,
  `skip_mesh`) and every one of them is measurable in one battery run.

---

## 8. How to change this engine safely

1. **Measure, do not reason.** The emulator is for "does it crash" and "does it
   look right"; it cannot price fill or texture-cache behaviour. Numbers come
   from `./run_psp_hw.sh` on a real device, or they are not numbers.
2. **Hold the pixel count fixed and change one thing.** "Textures off" is not
   evidence about the cache; substituting a cache-resident texture at identical
   coverage is.
3. **Use the existing rows before adding probes.** The battery already has the
   per-state ablations (`wf_*`, `fg_*`, `fol_*`, `dw_*`, `abi_*`) and the
   synthetic calibration probes (`clear_only`, `fill2d_*`, `min512_*`,
   `drawcalls_256`, `tris_4096`, `particles_*`, `pfill_*`). A regression guard
   for a fixed bug is a row that keeps the OLD configuration in the table —
   `wf_old_default`, `fol_cutoutnomip`, `fg_nomips` all exist for that reason.
4. **The cliffs are sharp.** The texture-cache boundary is a step function: a
   change that moves a surface across it is worth 10x, and a change that does
   not is worth nothing. Never tune the bias or a texture size by taste.
