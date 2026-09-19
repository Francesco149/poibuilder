---
title: Install
lead: Copy the addon folder into a Godot 4.7 project and enable the plugin. Nothing else to compile.
---

> PoiBuilder is in **alpha** (first release). Expect rough edges, and expect
> breaking changes to saved scenes until 1.0 — pick the newest build you can.

## Requirements

- **Godot 4.7** (standard or .NET — the plugin is pure GDScript).
- A 3D scene. The toolbar lives under the spatial editor.

## Which download should I get?

**GitHub Releases are the recommended source** — they are cut directly from
this repository and carry the full addon plus the offline documentation. The
plugin is also published on the Godot **Asset Library** (in-editor **AssetLib**
tab); that listing mirrors the releases but can lag a few days behind.

- Releases: [github.com/Francesco149/poibuilder/releases](https://github.com/Francesco149/poibuilder/releases)
- Nightly (auto-built from master, marked pre-release): the `nightly` tag on the same releases page.

## I already installed it — is it enabled?

If you installed from a release zip **or** through the AssetLib tab, there is
nothing else to download. Just check it is enabled:

1. **Project → Project Settings → Plugins** → **PoiBuilder** must show a check.
2. Open a 3D scene. PoiBuilder's toolbar rows appear under the engine's 3D toolbar.
3. The [[btn:docs]] button at the right end of that toolbar opens the manual —
   offline from the copy bundled inside the plugin, or these online pages when
   no local copy exists.

If the toolbar row never appears: the plugin is disabled, or the scene is not
3D. That is the whole checklist.

## Installing from a release zip (recommended)

1. Download the zip from
   [Releases](https://github.com/Francesco149/poibuilder/releases) —
   `PoiBuilder-vX.Y.Z.zip` (or `PoiBuilder-nightly.zip` for the nightly).
2. Extract it into your Godot project folder — the zip contains
   `addons/poibuilder/`, so extracting at the project root puts it next to
   `project.godot`.
3. Wait for Godot to finish its first import of the addon (the spinner in
   the bottom-right; on a fresh project it imports the addon's icons and
   shaders).
4. **Project → Project Settings → Plugins** → enable **PoiBuilder**.
5. Open a 3D scene. The toolbar rows appear; the [[btn:docs]] button opens this
   manual offline from `addons/poibuilder/docs-site/`.

> [tip] On a fresh import you may see console messages like
> `Condition "p_enabled && addon_name_to_plugin.has(addon_path)" is true`,
> `!tasks.has(p_task)` from `progress_dialog.cpp`, or
> `Task 'reimport' already exists`. These come from Godot 4.7's own
> first-import machinery when a plugin is enabled while that first scan is
> still running — they are benign: the import completes and the plugin ends
> up enabled exactly once. Waiting for the first import to finish before
> enabling (step 3 above) avoids them entirely, and the messages are
> largely fixed in newer Godot versions.

## Installing from the Godot Asset Library

1. In Godot, open the **AssetLib** tab, search for **PoiBuilder**.
2. Download and install; keep the listed files checked so `addons/poibuilder/`
   lands in your project.
3. Enable the plugin as above.

The Asset Library serves a snapshot of this repository, so the offline docs
copy is not included in that download — the toolbar **Docs** button opens the
online documentation instead. Use a release zip if you want the offline copy.

## Reading these docs online without installing

These pages are built from the same repository. When you are ready to try the
plugin, grab a release zip (above) — the install is the two-step extract plus
enable, and the offline docs ride along inside the addon.

## From this repository

The plugin *is* `project/addons/poibuilder/`. Clone the repo, open
`project/project.godot` in Godot 4.7 and enable the plugin the same way. This
is the bleeding edge — nightly-quality, untested between commits.

## What appears

- Persistent toolbar rows under the 3D toolbar (four rows; the extended
  Rows 3 & 4 ship visible and can be folded with the **Extended Tools**
  toggle). They never hide. Buttons disable outside a PoiBuilder context.
- A floating overlay in the viewport (selection readout, params modal). Pin it with [[btn:panel::Panel]]; recover it with [[btn:recover::Reset Panel]] if it leaves the screen.
- A **Material & UV** dock on the right.
- A **UV Editor** bottom panel, opened from the toolbar [[btn:uv::UV]] button.
- An **Export** dialog.

The overlay title reads `PoiBuilder vX.Y.Z`. If the version does not match the docs you are reading, you are on a different build.

## First action

[New Shape](shapes.html) is always enabled. You do not need a selection to create. Open the menu, pick **Cube**, drag on the grid.

Continue in [First minutes](first-minutes.html).

## Uninstall

Disable the plugin, then delete `addons/poibuilder/`. Overlay position and grid settings live in Editor Settings under `poibuilder/` — they survive until you clear them.

> [gotcha] Godot 4.8-dev APIs are not the target. The installed engine is 4.7.2. If a script error mentions a missing editor method, you are on the wrong Godot.
