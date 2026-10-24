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
