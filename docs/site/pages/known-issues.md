---
title: Known issues (alpha)
lead: Rough edges we know about, where they bite, and the workaround — documented instead of discovered.
---

PoiBuilder is in its first alpha. These are known, confirmed, and queued for
fixes after the alpha — each says where it bites and what to do in the
meantime. If you hit something not on this page, check the
[FAQ](faq.html) first, then file it.

## A stamp cannot span two objects

**Where:** decal stamps (all targets).

A stamp paints pixels into the decal layer of a MESH — it may span several
FACES of that mesh freely (floor tiles, up a staircase side), but it stops
at mesh boundaries. Placing a stamp across two separately-created objects
is not possible today.

**Workaround:** merge the objects first ([Merge Objs](objects.html)) or
create the surface as one mesh (one floor with [inset](ops.html) work).
Duplicate the stamp per object as a last resort.

## Painting small faces is laggy

**Where:** splat/decal painting in the editor — **old / integrated GPUs
only**. On the machines used for the current benchmark baseline (an RTX
5060 desktop) this is NOT observable: small faces paint as smoothly as big
ones at any brush size. It shows up on the five-year-old integrated-GPU
laptop that serves as the worst-case machine in the
[performance](performance.html) table.

Brushing over a small face (a 0.5 m tile, a trim strip) runs noticeably
below the smoothness of big faces.

**Workaround:** paint the small faces in one continuous pass rather than
many separate dabs; where possible, paint detail on a larger face and let
the UV tiling carry it.

**Status:** the root cause was found and removed in v0.9.180, and it was not
"small faces" but the density the face carried: per-dab cost is the brush's
footprint in MASK PIXELS = `2 * radius * mask_px / face_size_m`, and a mask
sized at 256 texels/m meant a 0.5 m face carried 512 texels/m (measured ~20 ms
per dab) while a 3 m face carried 171. The live splat mask is now sized from the
face with the density clamped into 128..256 px, so a 0.5 m face paints on
128x128 — **4.04x faster than before** — and a 2-8 m face 3.4-4.1x faster,
with nothing slower. The mask upload also has a hard 64 KB ceiling. Large faces
do not lose quality from it: the EXPORT bake composites at the face's own
256 texels/m up to 2048, upsampling the live mask bilinearly so blend edges stay
smooth.

The earlier rounds are still in the tree and still helped (the brush sweeps the
cursor path as one capsule instead of stamping ~25 overlapping discs; picking
is allocation-free; sweeps queue and drain under a per-frame budget). Note that
the scanline "row-skip" bookkeeping those rounds added was measured at **3-7%**
in v0.9.180 — it is not what made large painting fast, and the changelog no
longer says it was. The note stays until the reference laptop re-runs the
interactive trace: the last trace's verdict was that most remaining hitches
were render/editor-side (the iGPU viewport redraw), which no paint-path change
can shrink.
