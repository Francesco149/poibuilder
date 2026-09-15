---
title: Moving
lead: The element gizmo is Godot's own manipulator, aimed at the selection. Shift+Move extrudes. Shift+Scale insets. Snap and proportional editing are toggles.
---

## Tools

Move / Rotate / Scale on the toolbar, or [[kbd:W]] [[kbd:E]] [[kbd:R]]. These are the plugin's tools. While a `PBMesh` is being edited the engine's Transform (Q) and Select (V) buttons are disabled so they cannot fight.

## Orientation space — [[kbd:X]]

| Space | Gizmo follows |
|---|---|
| Element | The selected face/edge/vert's own basis |
| Object | The mesh node's axes |
| World | World axes |

The Space button cycles the same three.

## Gestures

- **Center square** on Scale = uniform scale.
- **Shift + center** on faces = uniform inset.
- **Shift + Move** on faces/edges = live extrude (topology at drag begin).
- **Shift + Scale** on faces = live inset.

:::shot edit-move.png
Move a side quad, then the whole arched face.
:::

## Snapping

| Control | Default | Effect |
|---|---|---|
| Snap toggle | [[kbd:Y]] | Snap element drags to the PoiBuilder grid |
| V-Snap | toolbar (row 4) | Snap the drag pivot to the nearest vertex, including other meshes |
| Soft | toolbar | Proportional editing — unselected vertices within the radius follow with falloff |
| r: spinner | 2.0 m | Influence radius |

V-Snap is a **toggle**, not a hold. (The engine's Select tool is V, and is disabled while editing.)

## Grid keys

These work with nothing selected.

| Key | Action |
|---|---|
| [[kbd:[]] / [[kbd:]]] | Lower / raise grid elevation |
| [[kbd:-]] / [[kbd:=]] | Coarser / finer subdivisions |
| [[kbd:Shift]]+[[kbd:-]] / [[kbd:Shift]]+[[kbd:=]] | Halve / double the grid unit |
| [[kbd:\\]] | Reset elevation |

Full grid behaviour: [Grid](grid.html).

## Use cases

### Doorway to exact height

Vertex mode. Turn **V-Snap** on. Drag the head of the opening until it sticks to the neighbouring slab's vertex.

### Soft-raise a terrain patch

Face or vertex mode. Turn **Soft** on, set r: to cover the mound. Move the center vertex up. Neighbours follow the falloff.

> [gotcha] Shift+Move is extrude, not "constrained move". If you wanted a planar slide, release Shift.
