# PoiBuilder v0.9.185 — release notes (DRAFT)

Changes since **v0.9.167**, the current `nightly` / Asset Library release.
This is still an **alpha**.

## Before you upgrade

- **Your v0.9.167 maps keep working.** They load and paint exactly as before.
  This is now an automated test against a scene the v0.9.167 release itself
  wrote, not a promise.
- **Saving makes the map smaller, and newer-only.** Paint masks are now stored
  compressed. An old map shrinks the first time you save it (the demo map went
  from 48 MB to 9.3 MB). A map saved with this version needs this version or
  newer to open its paint: on v0.9.167 its paint would come up blank. Keep a
  copy if you might need to go back.
- **Export "Bake Boost" now defaults to 1.0 (was 2.0).** Retro exports (PBM
  and retro-baked GLB) now ship the bake as computed. The old 2.0 doubled the
  baked light and capped it at the texture's own colour. That lifts a dark
  dusk or night map, but it flattens a daylit one: every surface lit past
  half shows its bare texture, so the shading and most cast shadows
  disappear. To keep your previous look, set **Bake Boost** to 2.0 in the
  Export dialog. The docs' Export page has side-by-side shots of the demo
  courtyard, and explains how 2.0 compares with an old-school modulate-2x:
  identical in the shadows, but it never overbrights.
- **Duplicated objects saved with an older version are split when you open
  the map.** If you duplicated a PoiBuilder object and then edited the copy,
  the two were secretly sharing one mesh (see Highlights). Opening the map now
  gives each its own copy, and both show what that shared mesh last held.
  Check duplicated objects whose copy you re-textured or reshaped.
- **Maps painted on v0.9.167 or earlier:** their masks can be up to 2048×2048
  per face, which makes the brush slow on big faces. Select the meshes and
  press **Optimize Paint** (Material dock, paint section) to shrink them to the
  size the brush uses now. Detail finer than the new mask texel is lost, and
  it is a single undo step.

## Highlights

- **Painting is several times faster**, measured on an Intel UHD 630
  integrated GPU, the slowest machine we test on. Strokes sweep the cursor
  path instead of stamping dozens of overlapping dabs (3–4× on big faces).
  Small faces paint about 4× faster than before. The work is spread across
  frames so the editor stays responsive, and fast strokes are continuous
  instead of dotted. A trace of real painting on that GPU now runs at the
  editor's frame rate (16.4 ms median, 21.3 ms at the 99th percentile), so the
  "small faces are laggy" known issue is closed. The first stroke of a session
  can still stall once for under a second.
- **Big maps hold up.** A mesh with more than 256 painted faces no longer
  silently drops faces. Rebuilding such a mesh is ~9× faster. Picking under
  the cursor no longer slows down as the map grows (500 objects: 10 ms →
  0.6 ms per paint pick).
- **Duplicates and pastes are independent.** Ctrl+D (or copy-paste within a
  scene) used to leave the copy *linked* to the original's mesh data, so
  editing one quietly changed the other. Re-texturing a copied scrolling plane
  stopped the original from scrolling, and both exported with the same
  texture. Pasting into a *different* scene was worse: editing the paste
  edited the scene you copied it from, and that scene's next save kept the
  change. Every copy now gets its own mesh data and paint, and a paste into
  another scene gets its own copies of that scene's materials. To keep
  several copies of an object in sync, save it as its own scene and
  instance it.

## Fixed

**Painting and stamps**
- A stamp lands where its preview shows it on a rotated object (it was
  turned by the object's own rotation).
- The decal layer no longer jumps or stretches after you resize a face and
  paint it again.
- Extrude, inset, subdivide and bevel no longer smear a painted face's paint
  onto the new faces they create. Split pieces of a painted face keep painting
  as one surface.
- Brushing a face that shares its material with other faces no longer
  repaints those faces too.
- Detach keeps the detached part's materials and paint (it used to fall back
  to the default material).
- Mesh operations keep your UV2 / lightmap unwrap (the first extrude used to
  drop it for the whole mesh).
- Large faces export their paint at full resolution: a 60 m floor baked at
  8.5 texels/m and now bakes at 34.
- The modern GLB's baked paint keeps each layer's blend-edge softness (it
  used the default for every layer).
- The brush keeps its documented priority: the selected object wins under
  the cursor.

**Scrolling textures**
- A save no longer stores whatever point the editor's scroll animation had
  reached (every save drifted the texture's offset and showed up as a diff),
  and exports read the authored offset.
- Changing the scroll speed of a texture copy no longer changes the
  original's speed in GLB exports.

**Export and retro**
- A transparent plane (a waterfall sheet, water) no longer casts a dark baked
  shadow that the editor never showed.
- Poibuilderized props keep their own UVs through the retro tile bake (atlas
  regions such as a barrel's metal hoops sampled the wrong part of the
  texture).
- Curved stairs dragged deeper than wide had their walkable ramp collider
  mirrored: the inner lane walked through the steps, and the other lanes got
  stuck at the bottom. Fixed in the editor and in exported colliders.
- PSP demo engine: the Hold switch now also freezes the camera.

**Modeling**
- Trim Walls: a pilaster no longer counts as part of the wall behind it,
  closed rings no longer have one malformed corner, overlapping wall blocks
  close their ring, and corners stay mitred within each wall run.
- Shape creation no longer snaps onto hidden objects. The nearest surface
  under the cursor always wins.

## Performance

- Undo history no longer keeps a GPU copy of every paint mask per stroke. On
  the demo courtyard each decal stroke kept 27.6 MB, and freed images
  accumulated for the whole session.
- PoiBuilder meshes no longer run a script every frame, in the editor or in
  your shipped game.
- The modern GLB "Bake into textures" export is 2.5× faster, with
  byte-identical output.

## Changed

- Export **Bake Boost** default: 2.0 → 1.0 (see "Before you upgrade").
- The live paint mask is sized from the face, between 128 and 256 px. The
  export bake still composites at 256 texels/m, so exported paint stays sharp.
- New **Optimize Paint** button (see "Before you upgrade").

## Known issues

- **A stamp cannot span two objects.** It covers several faces of one mesh,
  but stops at object boundaries. Workaround: merge the objects first.
- **Trim Walls at Top placement around doors and arches** does not produce
  one continuous cornice. Use Bottom placement for loops with openings (see
  the Trims page).

Full details: `CHANGELOG.md` (v0.9.168 – v0.9.185).
