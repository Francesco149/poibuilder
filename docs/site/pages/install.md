---
title: Install
lead: Copy the addon folder into a Godot 4.7 project and enable the plugin. Nothing else to compile.
---

## Requirements

- **Godot 4.7** (standard or .NET — the plugin is pure GDScript).
- A 3D scene. The toolbar lives under the spatial editor.

## From a release zip

1. Download `PoiBuilder-nightly.zip` (or a versioned release) from GitHub.
2. Extract it into your Godot project folder. You should have `addons/poibuilder/` next to `project.godot`.
3. Project → Project Settings → Plugins → enable **PoiBuilder**.
4. Open a 3D scene. A second toolbar row appears under the engine's 3D toolbar.

## From this repository

The plugin *is* `project/addons/poibuilder/`. Open `project/project.godot` in Godot 4.7 and enable the plugin the same way.

## What appears

- A persistent toolbar row under the 3D toolbar. It never hides. Buttons disable outside a PoiBuilder context.
- A floating overlay in the viewport (selection readout, params modal). Pin it with **Panel**; recover it with the reset button if it leaves the screen.
- A **Material & UV** dock on the right.
- A **UV Editor** bottom panel, opened from the toolbar **UV** button.
- An **Export** dialog.

The overlay title reads `PoiBuilder vX.Y.Z`. If the version does not match the docs you are reading, you are on a different build.

## First action

[New Shape](shapes.html) is always enabled. You do not need a selection to create. Open the menu, pick **Cube**, drag on the grid.

Continue in [First minutes](first-minutes.html).

## Uninstall

Disable the plugin, then delete `addons/poibuilder/`. Overlay position and grid settings live in Editor Settings under `poibuilder/` — they survive until you clear them.

> [gotcha] Godot 4.8-dev APIs are not the target. The installed engine is 4.7.2. If a script error mentions a missing editor method, you are on the wrong Godot.
