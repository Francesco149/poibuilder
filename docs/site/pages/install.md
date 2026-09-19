---
title: Install
lead: Get the addon into your project — AssetLib import, a copied folder, or a library download — then enable the plugin in Project Settings. Nothing else to compile.
---

> PoiBuilder is in **alpha** (first release). Expect rough edges, and expect
> breaking changes to saved scenes until 1.0 — pick the newest build you can.

## Requirements

- **Godot 4.x** (standard or .NET — the plugin is pure GDScript).
  Developed and extensively tested on **Godot 4.7** (4.7.2). Surface-level
  testing on **Godot 4.6 stable** passes; older 4.x versions are untested.
- A 3D scene. The toolbar lives under the spatial editor.

## The three ways to install

All three end at the same place — `addons/poibuilder/` inside your project.
Pick whichever fits how you already work:

1. **AssetLib tab → Import** *(recommended)*. Download a release zip from
   [Releases](https://github.com/Francesco149/poibuilder/releases), then in
   Godot open the **AssetLib** tab, click **Import…**, and pick the zip.
   Release zips are cut directly from this repository and carry the offline
   documentation (the toolbar **Docs** button works offline).
2. **Copy the folder to the project.** Extract a release zip (or copy
   `addons/poibuilder/` from the repository's `project/`) so it sits next to
   your `project.godot`. Same result as the Import path, minus the dialog.
3. **Search the Asset Library.** In the **AssetLib** tab, search
   **PoiBuilder**, press **Download**, keep the listed files checked. The
   library listing is a snapshot: it is **not guaranteed to be up to date**
   with bleeding-edge changes, and it does not include the offline docs copy
   (the **Docs** button opens the online manual instead).

> [gotcha] **Whichever way you installed, the plugin does not turn itself
> on.** Open **Project → Project Settings → Plugins** and tick
> **Enable** next to PoiBuilder. No enable, no toolbar — this is the
> single most common "it installed but nothing happened" report.

Nightly builds (auto-built from master, marked pre-release) live under the
`nightly` tag on the same
[releases page](https://github.com/Francesco149/poibuilder/releases).

## After enabling — is it working?

1. **Project → Project Settings → Plugins** → **PoiBuilder** must show a check.
2. Open a 3D scene. PoiBuilder's toolbar rows appear under the engine's 3D toolbar.
3. The [[btn:docs]] button at the right end of that toolbar opens the manual —
   offline from the copy bundled inside the plugin (release zip installs), or
   these online pages when no local copy exists.

If the toolbar row never appears: the plugin is disabled, or the scene is not
3D. That is the whole checklist.

## Installing from a release zip, step by step

(Paths 1 and 2 above, spelled out.)

1. Download the zip from
   [Releases](https://github.com/Francesco149/poibuilder/releases) —
   `PoiBuilder-vX.Y.Z.zip` (or `PoiBuilder-nightly.zip` for the nightly).
   Either import it through the **AssetLib → Import…** dialog, or extract it
   at your project root so `addons/poibuilder/` lands next to `project.godot`.
2. Wait for Godot to finish its first import of the addon (the spinner in
   the bottom-right; on a fresh project it imports the addon's icons and
   shaders).
3. **Project → Project Settings → Plugins** → enable **PoiBuilder**.
4. Open a 3D scene. The toolbar rows appear; the [[btn:docs]] button opens this
   manual offline from `addons/poibuilder/docs-site/`.

> [tip] On a fresh import you may see console messages like
> `Condition "p_enabled && addon_name_to_plugin.has(addon_path)" is true`,
> `!tasks.has(p_task)` from `progress_dialog.cpp`, or
> `Task 'reimport' already exists`. These come from Godot's own
> first-import machinery when a plugin is enabled while that first scan is
> still running — they are benign: the import completes and the plugin ends
> up enabled exactly once. Waiting for the first import to finish before
> enabling (step 2 above) avoids them entirely, and the messages are
> largely fixed in newer Godot versions.

## Reading these docs online without installing

These pages are built from the same repository. When you are ready to try the
plugin, grab a release zip (above) — the install is the extract plus enable,
and the offline docs ride along inside the addon.

## From this repository

The plugin *is* `project/addons/poibuilder/`. Clone the repo, open
`project/project.godot` in Godot and enable the plugin the same way. This
is the bleeding edge — nightly-quality, untested between commits.

## What appears

- Persistent toolbar rows under the 3D toolbar (four rows; the extended
  Rows 3 & 4 ship visible and can be folded with the **Extended Tools**
  toggle). They never hide. Buttons disable outside a PoiBuilder context —
  the [[btn:export]] and [[btn:docs]] buttons are always available.
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

> [gotcha] Godot 4.8-dev APIs are not the target. The development engine is 4.7.2; 4.6 stable is surface-tested. If a script error mentions a missing editor method on another version, that is the first suspect.
