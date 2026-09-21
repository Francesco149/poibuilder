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
below the smoothness of big faces — the per-stroke cost is dominated by
fixed work (mask texture sync) that does not scale down with the face,
and the weak iGPU is where that fixed cost starts to show.

**Workaround:** paint the small faces in one continuous pass rather than
many separate dabs; where possible, paint detail on a larger face and let
the UV tiling carry it.

**Status:** the first step of the paint rework shipped (v0.9.168) — mask
and decal uploads now coalesce per rendered frame instead of running once
per dab, which removes the redundant sync a stroke used to pay on every
mouse event. The note stays until the whole pipeline has been re-measured
on the reference iGPU machine.
