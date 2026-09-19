---
title: Mesh operations
lead: Topology-rewriting ops undo as a whole-mesh snapshot. Ops that create faces select their output.
---

All of these live on toolbar row 1. Grey means the current selection cannot feed the op.

## Extrude

:::op extrude
Extrudes selected faces outward along normals, or pulls edge fins to extend boundaries.
:::

**When:** pull a wall, a rim, a new storey.

- Faces: the originals are removed; you get a cap plus side quads (ProBuilder region extrude).
- Edges: fins along the average adjacent normal.
- Live: [[kbd:Shift]]+Move.
- Key: [[kbd:Alt]]+[[kbd:E]].

:::shot edit-extrude.png
Shift + drag to extrude.
:::

:::video clips/edit-extrude.mp4
The cap leaves, the sides fill in.
:::

## Inset

:::op inset
Insets selected faces, creating an outer border and shrinking the inner face.
:::

**When:** a window recess, a panel, a frame.

- Planar ring around the selected faces.
- Live: [[kbd:Shift]]+Scale on faces.
- Key: [[kbd:Alt]]+[[kbd:I]].

:::shot edit-inset.png
The ring it leaves, then the face lifted out of it.
:::

## Loop cut

:::op loopcut
Inserts an edge loop crossing a selected quad strip, turning corners cleanly.
:::

Select an edge that **crosses** a quad strip (a ring edge). [[btn:loopcut]] inserts a loop through that ring. Faces with only one ring edge (fans, boundaries) stay unsplit — a T-junction is expected. Corner turns that cannot walk fail cleanly.

:::shot edit-loopcut.png
The loop turns all four corners of the box.
:::

## Subdivide

:::op subdivide
Splits selected quad faces into four sub-quads and inserts new interior edges.
:::

Selected quads become four. Then drag the new edge.

:::shot edit-subdiv.png
Subdivide, then drag the edge it created.
:::

## Merge faces

:::op merge
Collapses adjacent coplanar faces into a single flat n-gon.
:::

Edge-adjacent selected faces collapse into one n-gon per region, fan-triangulated. Coplanar is the common case; you can also merge across a crease into a bent n-gon.

:::shot edit-merge.png
Merge coplanar faces, then move them as one.
:::

## Knife

:::op knife
Cuts across faces along an interactive clicked path, splitting geometry.
:::

Click points across a face (edge-to-edge, or an interior hole). [[kbd:Enter]] completes the cut. Restricts points to the current face; edges can belong to more than one candidate.

:::shot edit-knife.png
Cut a face along a drawn path.
:::

## N-gon prism

:::op ngon
Click points on any surface to draw a custom polygon base, Enter to extrude height.
:::

Toolbar [[btn:ngon]]: click a polygon on a surface, [[kbd:Enter]], drag height. Any floor plan becomes a volume.

:::shot edit-ngon.png
Draw any polygon and extrude it.
:::

## Bevel

Own page: [Bevel](bevel.html). [[kbd:Ctrl]]+[[kbd:B]].

## Universal rules

- Topology-rewriting ops undo as **whole-mesh snapshots**. There is no per-vertex undo payload that survives insertion.
- Ops that create faces **select those faces**.
- Welds make coincident corners one selectable vertex — see [Holes & joins](ops-joins.html).

> [gotcha] Loop Cut wants a *ring* edge (the thing the loop crosses), not a loop edge (the thing the cut creates). Alt+click is the loop; Shift+Alt+click is the ring.
