# Scoping a tile-based paint backend (NOT written yet)

Status: **a scope, not a plan of record.** Read this before proposing "let's
make painting tile-based". The last attempt is on the `doomed-tiled-attempt`
branch and was abandoned; this file exists so the next attempt starts from what
that one actually cost instead of from the idea again.

Read `paint.md` in `docs/site/pages/` for the SHIPPED behaviour first — the
sections below describe a future backend, and the shipped one is not it.

## What the shipped backend is (v0.9.180+)

- One splat material per painted FACE (masks are per-material images, each
  mapping to that face's persisted `splat_bounds` rect).
- A live mask per layer sized from the face, density clamped into
  128..256 px (`PBSplat.live_mask_resolution_for`). Per-dab cost is proportional
  to `2 * brush_radius * mask_px / face_size_m` — the brush's footprint in mask
  pixels — so the CLAMP is what keeps that cost bounded across face sizes (a
  fixed-size square was tried and does not help the densest faces; see
  `orientation/paint.md` for the measurements).
- The **export bake** composites at 256 texels/m of the face's own size, capped
  at 2048 (`PBSplat.bake_resolution`), and **bilinearly upsamples** the live
  mask to meet that resolution. The bake pays for density once per export; the
  live walk does not pay it per dab.
- Splat strokes sweep the cursor path as a swept capsule
  (`paint_face_splat_segment`), strokes are time-sliced under a per-frame
  budget, and mask uploads coalesce per rendered frame.

## Why "tile-based" is attractive

The idea (from the human's brief): handle ALL geometry internally as already
subdivided into tiles in the editor. Then:

1. **Proportional editing of a large surface** ("terrain style") becomes
   possible on demand, while everything else stays in simple combined faces.
2. A **maximum texture size per paint mechanic** is easy to enforce, because no
   single texture ever spans more than a tile.
3. Painting only dirties tiles, so **sparse texture reupload** is the natural
   unit: paint a footprint, upload the 1-4 tiles it touched.

All three are real wins and none of them is available in the face-material
backend — point 3 especially, because today a dab uploads the face's whole mask
image (bounded at 256x256 now, but the bake had it unbounded).

## What the abandoned attempt actually did, and why it failed

`doomed-tiled-attempt` (branched at `e7f9fa3`, commits `041f17c`..`96d2239`)
went all the way: per-tile R8 masks (`TILE_MASK_RES = 256` per 1 m grid cell),
a `Texture2DArray` display shader with a sparse per-layer tile array, deferred
per-tile compositing, incremental dirty-tile blits, and an
`_expand_splat_bounds_if_needed` that remapped the decal uniforms (this last
piece is the one thing that was CORRECT and was ported back — see the decal
window remap in `PBSplat._expand_splat_bounds_if_needed`).

It was abandoned for one reason: **strokes ran visibly behind the cursor.**
Not slower per dab on average — *laggy*, with the paint trailing the pointer.

The structural cause, and the thing any re-attempt must solve first: a tile
backend has to keep a SHADER-VISIBLE composite in sync with the per-tile
source, and the attempt kept that composite as one display image rebuilt from
the tile set. Every dab therefore paid (a) the tile walks, (b) a composite
update, and (c) a full display-image upload — and (b)+(c) are `O` of whatever
was dirty in the window, not `O` of the dab. Under a fast stroke the dirty set
grows and the per-frame cost grows with it, so latency accumulates instead of
staying bounded. Time-slicing the dabs (v0.9.172, kept in this round's line)
does not fix that: it bounds the per-frame WORK but the paint still lands
frame-late by construction.

## Measured facts the next attempt should use

All measured headless on the reference machine during the v0.9.18x round; the
numbers are in `CHANGELOG.md` with their method.

- **The GDScript pixel walk is ~0.3-0.7 us per mask pixel.** This makes per-dab
  cost a straight function of walked pixels; there is no cheap version of the
  walk in GDScript.
- **The row-skip scanline bookkeeping in the sweeps buys 3-7%** against the
  same code with it disabled (measured both ways at 256 and 512 masks). It is
  in the tree and harmless, but it is NOT the perf mechanism it was believed to
  be — do not treat it as the thing that makes large painting fast.
- **The interactive trace's own verdict** (v0.9.174) was that the majority of
  remaining paint hitches were **render/editor-side** — long frames with a
  light paint handler. A tile backend that only shrinks the handler cannot
  reach those frames. Profile with `./trace_paint.sh` BEFORE building anything:
  if the hitch attribution still says render/editor-side, the tile work will
  not improve felt latency.
- **Uploads are not the bottleneck** in the shipped backend, because they
  already coalesce per rendered frame (v0.9.168) and the mask is bounded at
  256x256 (64 KB). The tile pitch ("sparse reupload") is therefore a
  SCALABILITY argument, not a current-latency argument.
- **The bake loop is the expensive GDScript path** (~13.5 s for one 2048x2048
  face before this round's rewrite; ~10 s after removing the per-pixel
  Dictionary barycentric and the per-texel division). If tiles are introduced,
  the bake must NOT composite per tile in GDScript — that multiplies the
  expensive path.

## Re-scope: what to build, in dependency order

1. **Decide the composite contract first.** The abandoned attempt's fatal
   coupling was "tiles are the truth, one display image is derived from them,
   per dab". Either
   - (a) make the SHADER read the tiles directly (`Texture2DArray` + a tile
     index attribute, so there is no display image to rebuild at all), or
   - (b) keep the display image but update it ONLY on tile boundaries crossed
     (not per dab), and accept a bounded staleness of at most one tile.
   (a) is the honest version and what the doomed branch's last commits were
   groping toward; without it the same feedback loop comes back.
2. **Prove the latency bound on a real stroke before porting anything.** A
   prototype that paints one tile-resident layer on a 60 m face through the
   real input path, with `./trace_paint.sh` showing no trailing frames, is the
   gate. Measured, not argued.
3. **Then** the geometry story (internal subdivision for terrain-style
   proportional editing). This is the largest and least proven part; it touches
   `PBMeshData` topology, every mesh op, undo snapshots, and the selection
   contract in `selection.md`. It should be its own session, and it should not
   be attempted until (1) and (2) hold.
4. **Then** enforce the max-texture-size policy per mechanic, which becomes
   trivial once tiles are the unit.

## Non-negotiable constraints for any attempt

- `splat_bounds` and the decal WINDOW mapping are the two things that made the
  resize behaviour correct (this round's decal fix). Any tile rewrite must
  keep the world-anchored semantics: resizing geometry must not stretch or
  slide existing paint, in the mask OR the decal layer.
- The export bake's density guarantee (256 texels/m up to 2048) is a shipped
  contract now, with tests. A tile backend must meet it too.
- Old scenes must keep their paint. Masks only ever GROW in the shipped
  backend; a tile backend opening a face-material scene has to migrate rather
  than discard.
- Do not lower `MASK_RESOLUTION` to buy headroom: it is already the perf knob,
  and the blend edges are upsampled by the bake. Note also that a mask can only
  GROW, so any new path that creates one must pass the face's target or the
  clamp's floor silently stops applying.
