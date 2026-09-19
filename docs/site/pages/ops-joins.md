---
title: Holes & joins
lead: Bridge two open edges, fill a loop, weld corners, detach a piece into its own object.
---

## Bridge

:::op bridge
Connect two boundary open edges with bridging quad faces.
:::

Connect two **boundary** (open) edges with a face. [[kbd:Alt]]+[[kbd:B]].

Select exactly two open edges. If a button is grey, one of them is welded interior.

## Connect

:::op connect
Insert an edge joining edge midpoints or selected vertices.
:::

Insert an edge joining edge midpoints or selected vertices.

## Collapse

:::op collapse
Selected vertices, edges or faces collapse to a single geometric center.
:::

Selected vertices, edges or faces collapse to a single point.

## Fill Hole

:::op fill_hole
Cap an open boundary loop with a new polygon face.
:::

Cap an open boundary loop with a new face. Select the loop (or use [[btn:select_boundary::Boundary]]) first.

## Weld

:::op weld
Selected vertices snap to their centroid and weld into one shared vertex group.
:::

Selected shared-vertex groups snap to their centroid and become one group. Positions move; indexes do not. After a weld, those corners select as one vertex — dragging will not tear them apart.

:::shot edit-weld.png
Weld vertices to their centroid.
:::

## Delete

:::op delete
Deletes selected faces, edges, or vertices from the mesh.
:::

Deletes selected faces. Orphans compact. Look through the opening and you should see the interior.

:::shot edit-delete.png
Delete faces — and look into the opening.
:::

## Detach

:::op detach
Detaches selected faces into a separate new PBMesh sibling object.
:::

Selected faces become a new `PBMesh` sibling. Undo restores them to the original (node undo, not a mesh snapshot). Move the new object away.

:::shot edit-detach.png
Detach faces into a new object — and move it away.
:::

## Use cases

### Close a subtracted doorway that went too far

Edge mode → [[btn:select_boundary::Boundary]] → [[btn:fill_hole]]. Then inset and extrude if you still want a recess.

### Split a building into chunks

Face-select a wing. **Detach**. Origin stays; move the new node. Collision follows the new mesh.

### Stop a corner tearing

If a drag splits a corner that should stay sharp-together, those vertices are not welded. Select them (vertex mode) → **Weld**.

> [gotcha] Bridge needs two *open* edges. Interior edges already have two faces; the button stays grey. Delete a face first if you meant to bridge across a hole.
