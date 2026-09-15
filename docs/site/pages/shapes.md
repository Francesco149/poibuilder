---
title: Shapes
lead: Press on any surface, drag a base, set the height. Fifteen primitives share that language. Trim is the exception — it commits on release.
---

## The drag

1. **New Shape** → pick a type. Nothing is created yet.
2. Press on a `PBMesh` face or on the grid. Drag the base **in that plane**.
3. The first motion **locks the drag axis** on axis-aligned surfaces.
4. Release. Move to set height along the face normal (negative grows below).
5. Click to confirm. [[kbd:Esc]] before that click creates nothing.

Modifiers during the drag:

- [[kbd:Ctrl]] locks the drag direction.
- [[kbd:Alt]] shows the height plane.
- [[kbd:G]] toggles draw-on-grid (start on the plugin grid even over a mesh).

:::shot create-wall.png
The same drag on a wall: the box grows along the wall's normal, not "up in the world".
:::

:::video clips/create-floor.mp4
Floor, then wall, then a slope — one gesture, three planes.
:::

## Params modal

Shapes with parameters the drag cannot express (step count, arch, sides…) open a live-preview modal after the click. **Apply** keeps them, **Cancel** restores the placement values. Either way the node is selected.

**Edit Params** reopens that modal. It is enabled only while the mesh still has a `shape_id` and has not been topology-edited. Extrude, knife, delete — anything that rewrites faces — marks it edited, and the factory parameters no longer describe the mesh.

## The fifteen

| Shape | Use it for | Parameters (defaults) |
|---|---|---|
| Cube | Blocking, floors, walls | width / height / depth |
| Stair | Straight runs between floors | size + steps (6), sides |
| Curved stair | Spiral / quarter-turn | width 1.5 m, height 2 m, inner radius 0.5 m, curvature 180°, steps 8, sides |
| Prism | Roofs, ramps | size |
| Cylinder | Columns | radius 0.5 m, height 1 m, sides 8 |
| Plane | Floors, water sheets | width / depth 1 m |
| Door | Openings, arched gateways | 3 × 2.5 × 1 m, opening 2 m, frame 0.5 m, arched, 6 arch segments |
| Pipe | Hollow columns, ducts | radius 0.5 m, height 1 m, thickness 0.125 m, sides 8 |
| Cone | Caps, roofs | radius 0.5 m, height 1 m, sides 8 |
| Sprite | Billboards, trees, signs | width / height 1 m, lit, cast shadow, auto-orient |
| Arch | Openings, bridges | radius 1 m, depth 0.5 m, thickness 0.3 m, sides 8, sweep 180° |
| Sphere | Props, lights' stand-ins | radius 0.5 m, subdivisions 2 |
| Torus | Column bases, rails | outer 0.5 m, tube 0.15 m |
| N-gon | Custom prism from the N-Gon tool | radius 1 m, height 2 m, sides 6 |
| Trim | Skirting, cornice, dado — [own page](trims.html) | profile, length, height 0.15 m, depth 0.05 m, arc segments, upside down, flip side |

N-Gon is also a drawing tool: click points, [[kbd:Enter]] to set height.

:::shot shapes-lineup.png
The primitive lineup, each generated from parameters.
:::

## Use cases

### A staircase between two floors

1. New Shape → Stair. Drag from the lower slab toward the upper, along the run.
2. Height = floor-to-floor. Apply.
3. Raise **Steps** until the treads meet the landing. Edit Params if you already confirmed.
4. Sides on = closed stringers. Off = open treads.

:::shot create-stairs.png
Live step count. The preview is the mesh you will keep.
:::

### An arched doorway

Drag **Door** with the long side along the wall. Tick **Arched**. Raise **Arch Segments** for a rounder head. Frame width is **leg_width**.

### A torus column base

Drag **Torus** on the floor at the column's foot. Outer radius ≈ column radius + tube. Edit Params to fatten the tube without moving the node.

### A sprite billboard

**Sprite** is a one-face card. **Auto Orient To Camera** turns it into a billboard at export. Place trees and signs with the sprite placer ([[kbd:B]]) instead if you want the carousel.

> [gotcha] Height is along the *pressed face's normal*. On a wall that is "out of the wall", not world +Y. If the preview disappears into the floor, you dragged height negative — flip the mouse.
