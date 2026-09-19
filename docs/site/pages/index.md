---
title: Build the room. Export the map.
lead: PoiBuilder is a ProBuilder-style mesh builder that lives in the Godot 4 editor. Drag shapes on any surface, edit vertices, paint, then export a modern GLB or a retro map measured on a PSP.
hero: true
---

<div class="cards">
<a class="card" href="first-minutes.html"><strong>60 seconds</strong><span>A cube, a pulled face, a doorway. The first win.</span></a>
<a class="card" href="walkthrough-modern.html"><strong>Build a map</strong><span>Empty project → splats, decals, waterfall, particles, neon lightmap room → play and export. End to end.</span></a>
<a class="card" href="walkthrough-retro.html"><strong>Go retro</strong><span>The same map as a .pbm — verify it, then implement the format in your engine from the spec and the reference renderer.</span></a>
<a class="card" href="ops.html"><strong>Mesh ops</strong><span>Extrude, inset, bevel, knife, loop cut, weld, detach. Shift+Move extrudes live.</span></a>
<a class="card" href="uv.html"><strong>UV editor</strong><span>A dedicated 2D canvas, selection synced both ways, projections for ramps.</span></a>
<a class="card" href="export.html"><strong>Retro export</strong><span>Tile-baked .pbm with vertex light, running on a Sony PSP.</span></a>
</div>

:::video clips/poibuilder-showcase-960.mp4
The full showcase film: the courtyard built start to finish in the editor, then the same map running on a real PSP.
:::

> **Alpha.** PoiBuilder is in its first alpha release. Grab the newest build
> from [Releases](https://github.com/Francesco149/poibuilder/releases) (or the
> Asset Library) — see [Install](install.html). Saved scenes may still break
> between alphas until 1.0.

## What you are looking at

PoiBuilder is a Godot 4 editor plugin. You enable it, and a toolbar appears under the 3D viewport. From there you create `PBMesh` nodes — editable meshes that keep faces, UVs, materials and collision in one place.

It is pure GDScript. It runs on standard Godot and Godot .NET. Development and heavy testing happen on **Godot 4.7**; surface-level testing on **Godot 4.6 stable** passes (see [Install](install.html)).

Typical work:

1. Drag a floor, walls, stairs, a door.
2. Pull faces, cut loops, bevel edges, fill holes.
3. Assign materials, paint blends, stamp a poster, scroll a waterfall.
4. Nudge how a texture sits on a face from the 3D view itself — texture mode ([[kbd:6]]) moves the face's UVs with the same gizmo.
5. Place particle emitters and billboards from the dock.
6. Poibuilderize a GLB prop you dragged in, boolean a hole with CSG.
7. Export a modern GLB, or a retro `.pbm` with textures sanitized for the PSP.

The [walkthroughs](walkthrough-modern.html) do all of it in one pass on one map —
with screenshots of the finished result.

## Two ways to read these docs

- **Start here** — [Install](install.html), then [First minutes](first-minutes.html). One cube. One pulled face.
- **Reference** — every tool, every default key, every gotcha. Use the sidebar. The [keys](keys.html) table is generated from the plugin's action list.

The film of the plugin building a courtyard (and the same map on a PSP) is the README embed. Short clips on later pages are cut from that capture.

## Where the docs live

These pages are static HTML. No CDN. They work offline.

- Bundled with the addon at `addons/poibuilder/docs-site/index.html` — the toolbar [[btn:docs]] button opens them.
- GitHub Pages, built from the same Markdown.

> [gotcha] A greyed-out toolbar button is not broken. It is the wrong selection for that op; the tooltip names the context it wants.
