---
title: Shapes
lead: Press on any surface, drag a base, set the height. Fifteen primitives share that language. Trim is the exception — it commits on release.
---

## The drag

1. [[btn:new_shape]] → pick a type. Nothing is created yet.
2. Press on a `PBMesh` face or on the grid. Drag the base **in that plane**.
3. The first motion **locks the drag axis** on axis-aligned surfaces.
4. Release. Move to set height along the face normal (negative grows below).
5. Click to confirm. [[kbd:Esc]] before that click creates nothing.

Modifiers during the drag:

- [[kbd:Ctrl]] locks the drag direction and facing arrow.
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

[[btn:edit_params]] reopens that modal. It is enabled only while the mesh still has a `shape_id` and has not been topology-edited. Extrude, knife, delete — anything that rewrites faces — marks it edited, and the factory parameters no longer describe the mesh.

:::shot create-params.png
Live parameter modal — adjusting step count updates the preview mesh in real time.
:::

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

Directional shapes like **Door** and **Stair** display a solid orange arrow on the base plane while you drag. For a doorway:

- **What the arrow indicates:** The arrow points in the doorway's **facing direction** — through the opening, perpendicular to the door frame (the path a character walks through). The doorway opening spans the **width** (perpendicular to the arrow), while the wall thickness is the **depth** (parallel to the arrow).
- **How the arrow is determined:** Because doors are wider than they are thick, the arrow naturally chooses the **shorter dimension** of your dragged base rectangle (unlike stairs, which follow the longer dimension along the run). The arrow points **away from the drag start** along your mouse direction, snapped to the nearest cardinal world axis on cardinal surfaces to keep the doorway square with the world.
- **Locking direction with [[kbd:Ctrl]]:** While dragging the base footprint, holding [[kbd:Ctrl]] locks the current facing direction and arrow vector. Once locked, moving the mouse resizes the base rectangle without the arrow recomputing or flipping 90° if the aspect ratio shifts.

**Example gesture — making a door face a specific way:**

If you want a doorway facing **North** (along -Z) in an East-West wall:

1. Pick [[btn:new_shape]] → **Door**, then click on the floor where you want the doorway.
2. Drag a short distance in the direction you want it to face (pull slightly **North**). The orange arrow immediately appears, pointing North along the short axis.
3. Press and hold **[[kbd:Ctrl]]** to lock that facing direction.
4. While still holding [[kbd:Ctrl]], drag laterally (**East or West**) to pull out the full doorway width (e.g. 2.5 m). Because [[kbd:Ctrl]] is held, the arrow stays locked pointing North instead of flipping sideways.
5. Release the mouse button to commit the base footprint.
6. Move the mouse upward to set the doorway height, then click to confirm.
7. The params modal opens: tick **Arched**, raise **Arch Segments** (6–8) for a rounder head, and adjust **leg_width** (the jamb width). Click **Apply**.
### A torus column base

Drag **Torus** on the floor at the column's foot. Outer radius ≈ column radius + tube. Edit Params to fatten the tube without moving the node.

### A sprite billboard

**Sprite** is a one-face card. **Auto Orient To Camera** turns it into a billboard at export. Place trees and signs with the sprite placer ([[kbd:B]]) instead if you want the carousel.

> [gotcha] Height is along the *pressed face's normal*. On a wall that is "out of the wall", not world +Y. If the preview disappears into the floor, you dragged height negative — flip the mouse.
