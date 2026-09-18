---
title: Known issues (alpha)
lead: Rough edges we know about, where they bite, and the workaround — documented instead of discovered.
---

PoiBuilder is in its first alpha. These are known, confirmed, and queued for
fixes after the alpha — each says where it bites and what to do in the
meantime. If you hit something not on this page, check the
[FAQ](faq.html) first, then file it.

## Billboards render unlit on the PSP, even when set to lit

**Where:** retro export on the device.

A billboard placed with the sprite placer (or a `sprite*`-named
MeshInstance3D) carries its lit flag, and the editor honours it — but the
PSP build currently draws every billboard UNLIT, so foliage and other lit
billboards stay at full brightness in dusk/night scenes while everything
around them darkens.

**Workaround:** light billboards' surroundings so full brightness reads as
intentional, or prefer emissive-style art on the retro target. The modern
GLB and the live Godot scene are not affected.

## A transparent scrolling plane can cast an unexpected shadow on the PSP

**Where:** retro export on the device.

A plane with a transparent (blended) scrolling texture — a waterfall sheet,
a smoke plane — can generate a shadow on the device that the editor never
shows. The editor renders the plane as transparent; the retro bake can
treat its silhouette as an occluder, so a dark patch appears where nothing
in the editor suggested one.

**Workaround:** turn off **Cast Shadows** for scrolling/transparent planes
(row 3 toggle — select the plane, uncheck it) before exporting to the retro
target. Visually verify on the device via `./run_viewer.sh` + PPSSPP
(look-correctness only), or the hardware loop.

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

**Where:** splat/decal painting in the editor.

Brushing over a small face (a 0.5 m tile, a trim strip) runs noticeably
below the smoothness of big faces — the per-stroke cost is dominated by
fixed work (mask texture sync) that does not scale down with the face.

**Workaround:** paint the small faces in one continuous pass rather than
many separate dabs; where possible, paint detail on a larger face and let
the UV tiling carry it. Fix queued — the paint pipeline is being reworked
towards incremental stroke upload.

## Paint stroke rate is not uniform (dotted lines at speed)

**Where:** splat/decal brush.

Dab spacing is tied to stroke events, not to distance travelled, and the
rate is not adjustable — drag quickly and the stroke comes out DOTTED, like
a series of stamps, instead of a continuous line.

**Workaround:** drag slowly, or paint the line in overlapping dabs.
Interpolation-by-distance (which makes fast drags continuous) and a
stroke-rate control are planned for the same paint rework as the small-face
lag above.

## A poibuilderized mesh can export with mangled UVs to the PSP

**Where:** retro export, after Poibuilderize.

A mesh converted with **Poibuilderize** (for example a barrel GLB whose top
you extruded) can look correct in the Godot editor — right materials, right
UVs, right tiling — and still export with mangled UVs to the `.pbm` on some
parts (reported on a barrel's metal rim: the hoops sample the wrong atlas
region on the device while the body is fine).

The cause is in the conversion of multi-mesh/multi-material glTF subtrees:
face corners are rebuilt from triangles, and a UV island that spans a
material boundary can survive in the editor but lose its per-region mapping
during the retro tile bake.

**Workaround (either):**
- Leave props you do not need to face-edit UNCONVERTED — plain
  MeshInstance3D nodes export with their textures sanitized and place
  correctly (that is what the demo map's barrels do).
- If you must edit it, re-assign the affected faces a dedicated material
  (Texture mode + [UV editor](uv.html) planar re-projection) before
  exporting.

Until this is fixed, verify a converted prop's retro bake in the viewer
before committing to it.
