---
title: Objects & CSG
lead: Merge, mirror, pivots, freeze. Poibuilderize turns any MeshInstance3D or CSG into an editable mesh. Booleans pick the target first and the cutter last.
---

Row 4 of the toolbar (Extended Tools).

## Object ops

:::op merge_objects
Combines multiple selected PBMesh nodes into one, baking relative transforms.
:::

| Button | Effect |
|---|---|
| Merge Objs | Selected `PBMesh` nodes become one |
| Mirror | Geometry across X |
| Center Pivot | Pivot to bounding-box center |
| Freeze Xform | Bake the transform into vertex positions, reset the node transform |
| Poibuilderize | Convert selected MeshInstance3D or CSGShape3D (including CSGCombiner3D) into a `PBMesh` |

## Object state — Lit & Cast Shadows

Row 3 (Extended Tools) carries two toggles that apply to the whole scene
selection — any `PBMesh`, `MeshInstance3D` or CSG node:

- [[btn:obj_lit::Lit]] — shading on/off. Unlit objects render at full brightness and
  ignore scene lights.
- [[btn:obj_shadow::Cast Shadows]] — shadow casting on/off.

Both follow mixed-checkbox semantics: all selected objects on = checked,
all off (or mixed) = unchecked, and checking it synchronizes every selected
object. They are rebindable in Editor Settings (*Object: Toggle Lit / Cast
Shadows*).

Typical use: unshadow a scrolling water plane before a retro export, or
unlight a glow strip so it reads emissive.

## Poibuilderize

:::op poibuilderize
Converts any standard MeshInstance3D or CSG node into an editable native PBMesh.
:::

Imported GLBs and Godot primitives are not editable as faces until you convert them.

1. Instance the GLB. Make the instance local / editable children.
2. Select the `MeshInstance3D` (or a CSG node).
3. [[btn:poibuilderize]]. A new `PBMesh` appears with per-triangle corners, welds rebuilt, materials copied.
4. Pull a face. It is a PoiBuilder mesh now.


:::shot poibuilderize.png
Import any GLB, convert with one click, and edit its faces natively.
:::
Heavy meshes stay heavy — every triangle is a face. Collapsing and merging after convert is the usual cleanup.

A MeshInstance3D you **do not** convert still **exports** to retro `.pbm`. Textures are sanitized (power-of-two, clamped to max size) on the way out. Convert only if you need to edit faces.

## CSG booleans

:::op csg_subtract
Subtracts the cutter mesh from the target mesh with full scene Undo/Redo.
:::

| Button | Tooltip rule |
|---|---|
| Union | Solid union. Select target first, cutter last |
| Subtract | Subtract the **last-selected** from the **first-selected** |
| Intersect | Solid intersection. Target first, cutter last |

Works across PoiBuilder meshes, ordinary MeshInstance3D, and CSG nodes. Operands must be **watertight**; a failure names the open-boundary count in the Output log.

Undo puts the cutter back in the tree (the node was removed on do, referenced on undo).

:::shot csg-booleans.png
CSG boolean subtraction with real undo — non-destructive and reversible.
:::

### Use case — a round window

1. Wall cube (target). Cylinder through it (cutter).
2. Select the wall, Shift-select the cylinder.
3. [[btn:csg_subtract]]. Hole. Ctrl+Z — the cylinder returns.

> [gotcha] CSG did nothing? Read the Output log. Open boundaries abort the op. Fill Hole / weld the mesh, or Poibuilderize a CSG primitive that is already closed.

> [gotcha] "My GLB has no gizmo" — it is not a `PBMesh` yet. Poibuilderize it. Clicks on a MeshInstance3D go to Godot's object gizmo, not face picking.
