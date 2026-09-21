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

**Status:** measured on the reference iGPU at last (v0.9.169, the
`./run_paint_perf.sh` bench: fast strokes driven through the real input
path on the Intel UHD 630). The v0.9.168 upload coalescing was real but
not the story: the profiled cost was the per-dab pixel walk itself —
stamping a disc per spacing step re-walked the same mask pixels up to ten
times each (1.59 M pixel visits, ~0.5 s of frozen editor for one fast
2.4 m stroke on a 3 m face at the default brush). The splat brush now
sweeps the cursor path as one capsule per motion event (weights by
distance-to-segment; identical falloff, replace and erase semantics,
pinned against dense disc stamping in `test_pb_splat_segment.gd`), with a
constant-weight band fast path for the axis-aligned strokes that dominate
builder maps. Same worst-case stroke: ~0.16 s — a 3–4x cut, and normal
fast drags (~10–30 cm per motion event) land at roughly 30–45 ms per
event on the same machine. The note stays: a pathological flick still
costs a couple of frames, and the decal brush's stamp rhythm is untouched
by design. The remaining lever (time-slicing the stroke across frames) is
queued behind correctness work.
