---
title: Selecting
lead: Five modes. Cyan hover, yellow selection. Switching modes converts the selection. Advanced ops grow, shrink, and walk loops.
---

## Modes

| Mode | Default key | What you pick |
|---|---|---|
| [[btn:object]] | toolbar (unbound) | Whole `PBMesh` nodes |
| Vertex | [[kbd:H]] | Shared vertices (welded corners move together) |
| Edge | [[kbd:J]] | Common edges |
| Face | [[kbd:K]] | Faces, including n-gons |
| Texture | [[kbd:6]] | Faces, but the gizmo transforms UVs |

:::shot select-modes.png
Face, edge and vertex modes on the same cube.
:::

Hover is **cyan**. Selection is **yellow**.

## Click language

- Click replaces the selection (the engine's subgizmo API holds one seed id; the plugin expands it).
- [[kbd:Shift]]+click adds.
- Drag a rubber-band in empty space.
- Edge loop: [[kbd:Alt]]+click or double-click. Shift+Alt+click / Shift+double-click is the **ring** (the edges a loop cut consumes).

## Mode-switch conversion

Select a face, press [[kbd:J]]. You now have that face's edges. This is ProBuilder parity. Ops that create faces select their output.

Object mode moves several meshes. Entering an element mode **narrows editing to the last-clicked mesh**.

## Texture mode — move UVs in the 3D view

Texture mode ([[kbd:6]]) picks faces like face mode, but the move/rotate/scale gizmo transforms the selected faces' **UVs**, not their geometry: slide a texture along a wall, spin a floor's grain, scale a repeating tile — without opening any panel. Face-mode gestures like Shift+move extrude do not fire here; every drag is a pure UV transform, and the whole drag undoes as one step.

Details worth knowing:

- The gizmo acts around the selection's UV centre, so rotate/scale pivot on what you selected.
- A face you have texture-moved becomes **manual**: auto-UV stops re-anchoring it, so your placement survives edits and resizes. Geometry changes still carry the UVs along.
- Texture mode is the quick 3D-side tool. For island-level work — projections, seam sewing, texel density — use the [2D UV editor](uv.html).

:::shot select-texture.png
Texture mode: the gizmo slides the brick texture across the selected wall faces.
:::

## Advanced suite (row 3)

:::op grow_selection
Expands the active selection outward by one ring of adjacent elements.
:::

:::op select_coplanar
Flood-selects all adjacent coplanar faces sharing the same geometric plane.
:::

:::op face_loop
Selects the full quad-strip face loop passing through the selected face.
:::

| Button | Default key | Effect |
|---|---|---|
| All | — | Every element of the current mode |
| Invert | [[kbd:Ctrl]]+[[kbd:I]] | Invert |
| Grow | [[kbd:Alt]]+[[kbd:G]] | Expand one ring |
| Shrink | [[kbd:Shift]]+[[kbd:Alt]]+[[kbd:G]] | Contract by the boundary |
| Coplanar | [[kbd:Alt]]+[[kbd:C]] | Adjacent coplanar faces |
| Similar | — | Faces sharing the material |
| Boundary | — | Open boundary edges |
| Loop | [[kbd:Alt]]+[[kbd:L]] | Face loop along a quad strip |
| Ring | [[kbd:Alt]]+[[kbd:R]] | Perpendicular face ring |


:::shot select-smart.png
Smart selection helpers: face loops, grow, shrink, coplanar, and invert.
:::
## Use cases

### Retexture one wall

Face mode. Click one wall face. [[btn:select_coplanar::Coplanar]]. The whole plane selects, even if it is several quads. Assign a material from the dock.

### Find a leak in a floor

Select a floor face. [[btn:grow_selection::Grow]] repeatedly. If the selection crawls up a wall, that edge is connected — a hole or a T-junction you did not mean.

### Fill a hole

[[btn:select_boundary::Boundary]] in edge mode, or select the open loop, then [Fill Hole](ops-joins.html).

> [gotcha] After multi-selecting objects, an element-mode click edits the last-clicked mesh only. Switch to Object if you meant to move both.
