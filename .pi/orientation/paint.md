# Paint & splat internals — the resolution policy and the resize contract

The user-facing paint docs live in `docs/site/pages/paint.md`. This is the
worker-facing half: what the mask resolution actually is, why it is what it is,
and the two invariants that have been broken by well-meaning "optimizations".

Entry points: `core/pb_splat.gd` (all paint math, masks, decal layer),
`editor/pb_paint_controller.gd` (stroke state, the sweep queue),
`poibuilder_plugin.gd` (`_paint_stroke_dab_along` — the interpolated walk),
`export/pb_tile_baker.gd` (the bake).

## The resolution policy (v0.9.180) — read this before touching any resolution

There are **two** resolutions and they are deliberately different. Do not
"unify" them; the split is the fix for the round's reported bugs.

| | live mask | export bake |
|---|---|---|
| constants | `TEXELS_PER_METER`/m, clamp `[MASK_MIN_RESOLUTION=128, MASK_RESOLUTION=256]` | `TEXELS_PER_METER` = 256/m |
| shape | density of the face, clamped | density of the face |
| ceiling | 256 | `PBSplat.MAX_RESOLUTION` = 2048 |
| helper | `PBSplat.live_mask_resolution_for(mesh, face)` | `PBSplat.bake_resolution(mesh, face, cap)` |
| pays | per dab, on the interactive path | once per export |

**Why the live mask is density-CLAMPED (not uniform).** Per-dab cost is the
brush's footprint in MASK PIXELS, which is `2 * radius * mask_px / face_size_m`.
A mask sized at 256 texels/m made the SAME brush progressively more expensive
the denser the face: a 0.5 m face carried 512 texels/m and cost ~20.5 ms a dab.
That is the reported "painting small faces is laggy" — really "densely-sampled
faces are laggy", with face size setting the density.

A UNIFORM 256 square was the first implementation and it was WRONG — it left
the worst case untouched (a 0.5 m face still gets 512 texels/m on a 256 mask)
and halved live fidelity on large faces. Measured (real sweep, ms/dab):

| face | master [256,512] | uniform 256 | density [128,256] |
|---|---|---|---|
| 0.5 m | 20.45 | 19.0 | **5.06** |
| 2 m | 18.77 | 4.6 | **4.59** |
| 3 m | 8.94 | 2.2 | **2.20** |
| 8 m | 1.61 | 0.5 | **0.46** |

So: density, with the FLOOR raised to 128. The ceiling bounds the per-dab walk
and the per-frame upload (256x256 R8 = 64 KB); the floor stops a small face from
being over-sampled.

**`live_mask_resolution_for` must be used at layer CREATION too.** A mask can
only GROW (`get_layer_mask_image` resizes up, never down), so creating a layer's
mask at the ceiling — which the old `DEFAULT_MASK_RES` default did — makes the
floor unreachable and the entire win invisible. `add_layer` and
`ensure_layer_for_texture` take the target for exactly this reason. If you add
a path that creates masks, pass the face's own target.

Every measurement above is a HEADLESS sweep on this machine; `run_paint_perf.sh`
(real GPU) and `trace_paint.sh` (felt latency) remain the product-level truth.

**Why the bake is NOT uniform.** Under the old shared policy a 60 m floor
baked at 512x512 = **8.5 texels/m = 11.7 cm per texel** — the "comically low
res splat mask on large faces". The bake runs once per export, so it CAN afford
density the per-dab walk cannot: it composites at the face's own 256 texels/m
up to 2048 (a 60 m floor reaches 34 texels/m, the upstream figure).

**The mask is upsampled BILINEARLY by the bake** (`_sample_mask_bilinear`),
because a 256 mask composited across a 2048 face would otherwise print 8-px
mask texel blocks along every blend edge (measured: nearest = 13 distinct
levels, bilinear = 98+ on the same ramp). The blend is a `smoothstep` of the
weight, so what the eye reads at a layer boundary is the ramp.

`MAX_RESOLUTION` is the BAKE ceiling only. Nothing on the live path may
reference it.

### The export cap trap

`_build_modern_baked_splat_mesh` used to do
`clampi(settings.max_texture_size * 4, MIN, MAX)`, and `bake_face_composite`
sized itself from the LIVE mask and then clamped to that cap — so the modern
bake inherited the live mask's density and the cap could only lower it. If you
change bake sizing, keep the two properties the tests pin: the bake SCALES with
the face, and an export's `max_texture_size` can only cap it down.

## Invariant 1 — resizing geometry must not move existing paint

`splat_bounds` is a PERSISTED object-space rect recorded on first paint. It is
NOT recomputed on rebuild: `get_face_planar_bounds()` returns it verbatim
(pass `force_geometry = true` for the live geometry — stamp anchors and decal
clipping need that, and it must not write `splat_bounds`).

Expansion happens only at PAINT time, in `_expand_splat_bounds_if_needed`:

1. union the cached bounds with the current geometry,
2. reallocate+reposition every splat mask image (`blit_rect`) so old paint stays
   at its world position,
3. **remap the DECAL WINDOW's `stamp_layer_uv_offset` / `stamp_layer_uv_scale`
   uniforms through the same old→new normalized-space transform**, and
4. update `face.splat_bounds` + the face's `splat_uvs`, flag
   `PBSplat.bounds_expanded_mesh` so the controller rebuilds the mesh.

Step 3 is the one that keeps getting missed, and it is why the decal layer
"jumps to a stretched version" after resizing a face. The masks carry their
pixels; the decal layer carries a MAPPING, expressed in the very space
`splat_bounds` defines. Grow the bounds without remapping the window and the
shader samples the window at coordinates that no longer exist — the decal
stretches, then vanishes once the uv leaves [0,1]. Regression test:
`test_decal_stays_anchored_when_bounds_expand_on_a_resized_face` (it uses an
OFF-CENTRE stamp; a centred one hides the drift because the symmetric case
cancels).

## Invariant 2 — the mask is per-material, the decal layer is per-material too

A shared splat material across faces makes one face's paint appear on every
other face wearing it (`ensure_face_owned_material` exists to prevent that).
`clone_splat_material` is the ONE function that copies a layer setup (privatising
a shared material goes through it too) and it must carry the window mapping
with the decal pixels — a clone that drops it renders the content stretched
over the whole face.

## Invariant 2a — faces sharing a splat material share ONE mapping (v0.9.182)

Several faces may wear one splat material only when they map it through the
same `splat_bounds` rect on parallel planes (what splitting a painted face
leaves). `ensure_face_owned_material` keeps such sharing and privatises a face
that maps the material differently; the splat brush calls it once per face per
stroke. Consequences you must keep:
- a bounds expansion moves EVERY same-mapping sibling to the grown rect
  (`_expand_splat_bounds_if_needed` collects them before re-anchoring);
- decal writes go once per material (`_decal_targets` dedupes) — the window is
  shared;
- topology ops settle the faces they create through
  `capture_paint_sources` / `settle_derived_faces` (CmdMeshOp does it in
  `capture_after`; a new op path that bypasses CmdMeshOp must call them).

## Invariant 2b — undo snapshots are COLD (v0.9.182)

`PBCommand.copy_mesh_data` clones splat materials with `cold = true`: the
pixels live in the CPU image cache (copy-on-write) and NO ImageTexture is
created. `restore_mesh_data` turns them live again. Anything that renders a
copy directly must use `copy_mesh_data_live`. Read masks through
`get_layer_mask_image` / `get_decal_layer_image`, never by testing the
material's texture parameter for null — a cold snapshot has none. The cache is
keyed by material instance id and pruned of freed materials
(`prune_image_cache`); do not add another static image store that is never
pruned.

## Invariant 3 — a decal's upright frame is WORLD-referenced, so the write needs the node transform

`PBSplat.get_stamp_basis()` answers a WORLD question: which way is "up" as the
viewer sees it. The preview quad is a scene node in world space, so it wears
that frame directly and is right by construction.

The decal WRITERS (`paste_decal`, `paint_decal_dab`) work in the mesh's LOCAL
data. Feeding them the world basis constants as if they were local axes rotates
the paste by whatever the node's own basis contributes — a node yawed 90° got
its stamps rotated 90° against the preview (measured; the scratch map's
`Shape_Cube`). It hides on unrotated meshes, where the basis is the identity,
which is why every builder and most tests missed it.

`_decal_basis(normal, rotation_deg, node_xform)` is the single place that
resolves this: build the frame in world space, pull it back through
`node_xform.basis.inverse()`. The parameter defaults to
`Transform3D.IDENTITY`, so unrotated callers are unchanged — but **any new
write path must pass the mesh's `global_transform`**, and any new caller that
derives a rotation to feed the writers (see `migrate_legacy_stamps`) must do its
angle comparison in world space too, against the same frame.

When you touch this: a test that measures a stamp's ASPECT cannot see this bug
(a rotation preserves aspect). Measure orientation — where image +x landed
relative to the preview quad's +x — as
`test_stamp_orientation_on_a_yawed_mesh_matches_the_preview` does.

## The stroke path (where perf changes belong)

`begin_stroke` -> `apply_paint_stroke`/`apply_paint_stroke_splat` ->
`_pending_sweeps` queue -> `_drain_pending_sweeps` (frame_pre_draw, ~8 ms
budget) -> `PBSplat.paint_face_splat_segment` / `paint_face_splat`.

Things to know before optimizing here:

- **The row-skip machinery (`row_max` in `stroke_ctx`) is worth 3-7%**, measured
  against the same code with it disabled. It is kept (it is free), but it is
  NOT the reason large painting is fast. Do not write a changelog entry
  crediting it, and do not assert a ratio for it in tests.
- Sweeps are split into collinear pieces (`sweep_piece_length`) so the drain
  budget holds several per frame; the split is byte-equality pinned.
- `stroke_ctx` caches each mask's byte buffer per stroke; `Image.get_data()`
  copies the whole mask and used to run per dab.
- Ground truth for perf is `./run_paint_perf.sh` (REAL GPU, never xvfb) and
  `./trace_paint.sh` for felt latency. Headless numbers are in
  `tests/test_pb_paint_perf.gd` and are envelopes, not the product.

## Traps

- `nearest_po2` rounds UP, so 256 texels/m on a 3 m face is `nearest_po2(768)`
  = 1024 (341 texels/m), not 768. Test against the invariant
  (`>= 256 texels/m`), not a magic number you derived by hand.
- `get_layer_mask_image` only ever GROWS a mask. A scene painted under an older
  policy keeps its resolution; new paint on the same layer adopts it.
- `pb_splat.gd` is huge and the two paint walks (disc, segment) are near
  mirrors — an edit to one usually needs the same edit in the other, in both
  the axis-aligned fast path and the general path.
