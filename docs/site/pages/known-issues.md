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

**Status:** three measured rounds on the reference iGPU (v0.9.169 to
v0.9.173, driven by `./run_paint_perf.sh` and the interactive
`./trace_paint.sh`). What the traces found, in order: the per-dab disc
stamping re-walked every mask pixel up to ten times (fixed: the brush
sweeps the cursor path as one capsule); picks and cap re-walks were the
next costs (fixed: allocation-free picking; near-cap trim on continuing
sweeps); one input event painted the whole accumulated path in a single
frame (fixed: sweeps queue and drain under a per-frame budget); and the
underlying scaler — reported by the painter themself — is face size:
per-sweep cost is mask texels, and a 3 m face carried a 1024x1024 mask.
Splat masks now cap at 512x512 (a 3 m face paints at 171 texels/m, 4x
less work; decal stamps keep their 256 texels/m windows, and masks in
existing scenes never shrink). The note stays until the reference laptop
re-runs the interactive trace, but the queue bounds any remaining hitch
to roughly one sweep.
