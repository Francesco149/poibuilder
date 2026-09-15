---
title: First minutes
lead: One cube, one pulled face, one doorway. That is the whole pitch.
---

Work in the 3D viewport. The PoiBuilder toolbar sits directly under Godot's.

## 1. Make a cube

1. Click **New Shape** and pick **Cube**.
2. Press on the grid (or on any `PBMesh` face). Drag a rectangle. The base stays coplanar with the surface you pressed.
3. Release. Move the mouse to set height. Click to confirm.
4. [[kbd:Esc]] before that confirming click creates nothing.

:::shot create-floor.png
The same drag on the floor. Height is the third axis, along the face normal.
:::

A `PBMesh` node appears in the scene tree. Edit Params stays live until you change the topology.

## 2. Pull a face

1. Click the cube. Face mode is [[kbd:K]] (toolbar **Face**).
2. Click a side. Hover is cyan; selection is yellow.
3. Hold [[kbd:Shift]] and drag the move gizmo — that is live extrude. Or click **Extrude** on the toolbar ([[kbd:Alt]]+[[kbd:E]]).

:::shot edit-extrude.png
Shift + drag extrudes. The original face is replaced by the cap and the sides.
:::

## 3. Put a door in a wall

1. New Shape → **Door**. Drag the footprint along the wall you want it to face.
2. The params modal opens. Tick **Arched**, raise **Arch Segments** if you want a smoother curve, **Apply**.
3. Move the doorway so it sits in the wall, or [boolean it out](objects.html) with CSG Subtract.

:::shot create-door.png
Arched doorway, built from its parameters, not from a boolean.
:::

## What to try next

- [Stairs between two floors](shapes.html#a-staircase-between-two-floors)
- [Skirting in one drag](trims.html)
- [Fix a stretched ramp in the UV editor](uv.html)
- [Export a retro map](export.html)

> [gotcha] Clicking another mesh in an element mode edits *that* mesh. Object mode ([[kbd:H]] is vertex; Object is the toolbar button) is how you move several meshes at once.
