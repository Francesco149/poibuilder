# PoiBuilder Changelog & Historical Status Notes

Historical record of development phases, sign-off rounds, and version notes (v0.7.0 through v0.9.105).
Active project instructions and conventions live in [CLAUDE.md](CLAUDE.md).

## v0.9.162 — the benchmark grows up: steady-state, ablations, Vulkan, PSP parity; the bake gets modulate-2x

### The baked map has a consumer contract now — and it was being violated everywhere

The retro bake carries its lighting in COLOR_0. Three things followed from
taking that seriously:

- **Shadow flags travel.** glTF's KHR_lights_punctual has no shadow field,
  so a shadow-casting light tags its export node with `poi_shadow` extras
  and a consumer restores `shadow_enabled` from them. The modern GLB's
  "wrong lighting" in the benchmark was exactly this gap.
- **The retro GLB consumer adds ZERO lighting.** `PBEnvironment.
  apply_retro_display(root, preset)` is the display contract: preset sky +
  the PSP's linear depth fog (fog_start/fog_end now mirror the device
  table), black ambient, linear tonemap. Applying the live preset on top
  double-lights the bake (+54% mean luminance at day, measured). The frame
  bench and the reference viewer follow it.
- **Vertex colors need two flags to render.** Godot's importer neither
  enables albedo-from-vertex-color for JSON-authored materials nor shades
  the bake — and the bake's vertex colors are PREBADED LIGHT, so a shaded
  material renders the map black the moment no live lights remain (the
  black-scene regression). `PBMapExporter.apply_baked_vertex_colors(root)`
  sets unshaded + albedo-from-color for the consumer; the parity tool
  proves it: alpha demo dusk mean luminance PSP 0.122 vs Godot 0.123,
  courtyard day 0.450 vs 0.447.

### The benchmark tells the truth about the run, the load, and the cost

- **steady** summary: the warm pass minus its first second — the headline
  numbers are the run, not loading spikes; the cold pass survives for
  hitch counts.
- **Ablation profile** (`./run_bench.sh --profile`): the PB scene flown
  base / no_shadows / no_emitters / no_splat / no_lights. On the Intel UHD
  630 baseline, shadows are HALF the frame (−11.6 ms GL, −10.8 Vulkan;
  draw calls 44 -> 334), particles ~3 ms, the splat shader ~free.
- **Renderer axis** (`--renderer vulkan`): forward_plus measured SLOWER
  than gl_compatibility for every variant on this integrated GPU (PB 35.4
  vs 25.2 ms) — Compatibility is the measured choice for low-end graphics.
- **Visual parity shots**: five fixed poses per variant per renderer,
  gridded by `tools/bench_contact_sheet.py` into contact sheets — a
  lighting regression is now SEEN, not just inferred from numbers
  (run_bench.sh re-exports through the new poi_env_preset root extras;
  reports land in `exports/bench/<renderer>_<variant>.json`).

Headlines (steady): GL — PB 25.2 ms, retro GLB **5.7 ms** (unshaded bakes
are nearly free; 4.4x the PB scene), modern GLB 21.7 ms. Vulkan — 35.4 /
7.6 / 27.7 ms.

### Modulate-2x: ExportSettings.bake_boost, default 2.0

The old-school lift, exactly as retro hardware's modulate stage did it:
baked vertex colors are multiplied by `bake_boost` (default 2.0, saturating
at 1.0) in the retro GLB, modern vertex-light bake, and the .pbm bytes —
brighter shadows and mid-tones for dusk/night bakes while sunlit areas
ride the clamp. The demo map's retro output plays on the device at 60 fps
with it (137 draws). Dialog knob: "Bake Boost".

### The demo map's neon room was un-shippable dark — twice

The closed room's interior albedo (0.42 sRGB = 0.15 linear) could never
read brighter than 0.15 in the retro pipeline, where surface brightness is
albedo x vertex color capped at 1.0 — the bake came out black with no
shadow silhouettes no matter how much light it computed. The envelope is
now ~0.62 sRGB (still the dark look), the neon omnis run hotter with
ranges that stay INSIDE the room (their old 8-9 m ranges also leaked neon
onto the courtyard through shadow-map bias — visible in the modern GLB).

## v0.9.161 — the demo waterfall earns its screenshot; the docs explain scrolling

### The waterfall is now the layer-stack showcase

The alpha demo map's falls was the barebones one: a dark streak smear on a
bare wall, a point-source mist puff smaller than the water, and a spray
billboard doing all the work. It is rebuilt as the thing the walkthrough
preaches — a stack of simple layers, each doing one job, all of it
retro-exportable:

- a stone **lip** the water pours from (it used to start mid-wall), with a
  slow **apron** crawling across the top towards the edge,
- a full-width bright **veil** (the pool texture) under the streak **sheet**
  — without it the streak textures' transparent-black body reads as a dark
  smear at dusk — plus two narrow side **trickles** on their own signed
  speeds and the fast **core** in front (parallax sells the depth),
- a bigger ripple **pool** with a bright impact-**foam** ribbon and a wide
  faint **swell** behind it, two climbing **spray** billboards at different
  rates, and a low teal uplight in the mist,
- the **mist bank** is one emitter whose EMISSION SPHERE spans the sheet's
  width (40 faint sprites, tint riding the retro emitter record) — a point
  emitter reads as a puff no matter the quad size — and a thin **wisp**
  emitter drifts up the wall face,
- **wet-stain stamps** ring the pool on the floor (`stamp_wet_stain.png`, a
  new source texture): a decal used as material, not a sticker.

Device row: the rebuilt map loads and plays on the real PSP at 60 fps
(149 draws, 3648 tris, GPU 0.10 ms — `./deploy_psp.sh
project/exports/alpha_demo_retro_baked.pbm`). Emitters total 78 particles
across 5 emitters, well under the ~256-per-map budget.

### The docs tell the truth about scrolling textures

The old gotcha ("a scrolling face is NOT packed into the retro tile atlas —
but also do not splat-paint one") read as if the export dropped the
animation. It doesn't: the SPEED travels as data (per-mesh `uv_scroll_u/v`
in PBM, `poi_uv_scroll` `[u, v]` extras on the material in BOTH GLB flavors
— verified in the exported files), and only the one-line consumer recipe
(`uv(t) = uv(0) + t * speed`) is the player's job. New "Scrolling textures"
section on the export page (retro points at the reference PSP renderer as
the proven implementation), rewritten gotchas on the walkthrough, paint and
materials pages, and the perf page's caveat now names the mechanism and the
11 verified material records instead of vague "format recipes".

### Bench re-measured on the new map

Same harness, heavier falls (5 emitters, 7 lights): PB scene median
26.1–26.6 ms, retro GLB 12.0–12.2, modern GLB 10.4–10.5 — the PB-vs-GLB
ratio moves from ~2.3x to ~2.5x and every page quoting the old number was
updated.

## v0.9.160 — the GLB flavors say what they are; the docs say which one to ship

### The export dialog steers GLB users to the modern optimized bake

The modern `.glb` export has had a baked-splat path since v0.9.151
(`Modern paint: Bake into textures`, compositing splat layers AND the decal
channel into per-face textures), and the frame-pacing benchmark's modern
variant was already measured with it (`splat_mode = BAKE`,
`bake_lighting = false` in `export_bench_variants`). The dialog now makes
that path the obvious default instead of a hidden knob:

- The format list reorders to **PBM (default) → GLB — Modern Bake
  (lightmap-ready) → GLB — Retro Baked Map (vertex-lit)**: the modern bake
  is the first GLB flavor, and PBM stays the overall default.
- Every format switch re-parks the paint mode on **Bake into textures**, so
  selecting the modern GLB always lands on the optimized bake (paint baked,
  lighting left to realtime lights / LightmapGI — the retro flavors keep
  baking vertex light and keep the paint switch disabled).
- Each format entry carries a tooltip naming exactly what it produces.
- The old "(live materials)" label is gone — with the bake as the default it
  described only the INCLUDE minority path.

Test: `test_export_dialog_defaults_to_pbm` now pins the new order, the
modern-bake defaults, and the INCLUDE reset.

### The docs say it outright: ship the baked map

The performance page gained a "Which one do you ship?" section and the FAQ,
first-minutes, walkthrough and export pages now all state the same rule:
the PoiBuilder scene as-is is the authoring format — building, testing,
iterating — and it renders ~2.3× the baked GLB's frame time on the
benchmark baseline. When you want to play or share the map, export it
(modern GLB or PBM) and play the baked result.

### The addon zip carries the license

`LICENSE` (MIT) now lives in `addons/poibuilder/` next to `plugin.cfg`, so
the nightly zip (and any manual copy of the folder) ships the license text
with the code.

## v0.9.159 — the alpha docs sweep: demo map, frame-pacing benchmark, known issues

The alpha-release documentation round. The website gained the two things it
was missing — end-to-end walkthroughs and a "what still hurts" page — plus
the tooling that made them honest, and one exporter crash fix the new map
flushed out.

### nil splat layer params crashed the modern-GLB bake (fix + regression test)

`collect_face_paint_state` passed shader parameters straight through, and a
splat layer enabled WITHOUT ever setting its `layer_N_color` /
`layer_N_roughness` params (legal: the shader declares defaults; scripted
authoring does this) produced a present-but-NIL dict entry. Every consumer
reads it with `dict.get("color", Color.WHITE)` — whose default only covers a
MISSING key — so `PBTileBaker.bake_face_composite`'s typed
`var l_col: Color = ...` died and the modern export aborted mid-bake.
The paint state now coalesces nils to the shader's own defaults
(WHITE / 0.8). Test: `test_collect_paint_state_coalesces_unset_layer_params`.

### The alpha demo map (`AlphaDemoMapBuilder` + `./run_demo_map.sh`)

A scripted map that exercises every core feature, used by the walkthroughs
and by the benchmark: courtyard floor splat (2 blended albedos + stamped
decals), an arched doorway, exterior stairs to a walkable roof, the layered
scrolling-texture waterfall with its mist emitter, brazier flame/embers,
billboards, and the closed neon room — UV2-unwrapped, GI-Static, BAKE_STATIC
coloured lights, emissive strips, and the PSX_Modular_Medieval barrels
(props by valsekamerplant, itch.io) as plain imported MeshInstance3D.
`alpha_demo_shots.gd` photographs the map in a real GPU run; the docs'
walkthrough screenshots come from it.

### The frame-pacing benchmark (`frame_pacing_bench.gd` + `./run_bench.sh`)

Not a static average-fps test: the demo map is flown along a gameplay-like
path (courtyard → through the door → neon room → out and up the stairs →
roof) while every frame's wall-clock time is recorded, cold pass and warm
pass, reporting median / 1% low / worst / jitter / hitches for the PB scene
as-is vs the retro-baked GLB vs the modern GLB. Headline (Intel UHD 630,
gl_compatibility, 720p, vsync off): GLBs ~89–99 fps with sub-30 ms worst
frames; the PB scene as-is is GPU-bound at ~40 fps (median 24.5 ms, fully
steady, no warm-up drift). The GLB variants parse via GLTFDocument like the
retro viewer — export targets live behind `.gdignore` and are invisible to
the import system.

### The .gdignore lesson, written into the exporter

Exporting into `res://test_scenes/` dropped a `.gdignore` there
(`ensure_export_dir` writes one into every target dir), which made the
editor's class scan skip the whole directory — `TestMapShowcaseBuilder`
disappeared from the class cache and `test_pb_map_showcase` was silently
skipped (the runner's suite-count guard caught it: 72 files, 71 suites).
The bench GLBs went back to `res://exports/` and the constraint is
documented in `export_bench_variants`.

### godot_guard.sh: opt-in display/GPU/asset passthrough

`GUARD_X11=1` mounts the host's X socket dir, passes `DISPLAY` through
every exec, and adds `/dev/dri` + keep-groups so rendered runs (shots,
benchmark) run on the real GPU instead of falling back to llvmpipe inside
the container. `GUARD_ASSETS=1` mounts `/mnt/ephemeral` read-only so
builders can instance pack props. Still exactly one capped container, runs
still fail closed when the cap cannot be enforced.

### Docs: current, with walkthroughs and known issues

- New pages: **Build a map (modern)** — empty project to finished, played,
  exported map with screenshots; **Export to PSP / retro** — the .pbm bake,
  device verification, and implementing the format in your own engine from
  SPEC_RETRO_FORMAT.md + the reference renderer; **Known issues (alpha)** —
  PSP-unlit billboards, PSP shadows on transparent scrolling planes, stamps
  not spanning two objects, small-face paint lag, dotted strokes at speed,
  mangled retro UVs after Poibuilderize — each with its workaround;
  **Godot-side performance** — the benchmark methodology and the measured
  table; **Splat in a modern .glb** — the sidecar recipe finally published
  as a page (the link had been dangling).
- Refreshed: interface (row-3 Lit/Cast Shadows toggles, the six dock modes,
  Edit Emitter Properties, the mode banner), materials (dock modes, palette
  dedupe), objects (object state), paint (transparent surfaces refuse
  paint), index (walkthrough cards), faq/first-minutes/export cross-links.
- Toolbar locator updated to the current rows: Grid on row 3, the object
  state toggles on row 3, Export... in row 2. The Grid and Export buttons
  got SVG icons (icon_grid.svg / icon_export.svg) instead of text, per the
  toolbar icon rule.

## v0.9.158 — free sheet knobs with brief docs, the flame is a 2x2 sheet, and emitter props in object mode

### The sheet knobs are free again; the docs carry the rule instead
The "rows/cols cut my particles" round ended with a misunderstanding on the
human's side (they had not registered the knobs as flipbook controls for
sprite sheets), and v0.9.157's answer — grey the knobs out on non-sheet
textures — was heavier than the problem. Reverted to plain documentation:
the knobs stay adjustable on ANY texture, the tooltips say what they are for
("for sprite sheets with more than 1 frame"), and the properties readout adds
one brief pointer when a grid is sampling a single-frame image ("…this image
is a single frame — the grid samples it in slices"). Dock help text, SPEC
8.6 and RETRO-AUTHORING 4.3 updated to match.

### particle_flame.png is (and always was) a 2x2 sheet — it ships as one now
`gen_particle_textures.py` drew the original flame as a 2x2 flipbook of
32x32 frames (the courtyard brazier already walked it at 2 x 2), but the file
carried no sheet marker and its preset armed no grid. It is now
`particle_flame_2x2_sheet.png` (same uid, references updated), and a sheet
may name its own grid: `_<cols>x<rows>_sheet` is parsed when the texture is
picked, so the flame arms 2 x 2 while the row sheets keep their 4 x 1 default.
`values_from_node`/`sheet_readout` unchanged; exporter parity pinned by test.

### Edit Emitter Properties works from object mode
Fine-tuning a placed emitter no longer requires entering particle placement:
the overlay panel used to hide itself whenever the selection was not a PBMesh
(`update_visibility` only considered `active_mesh`), which buried the
Edit Emitter Properties button the moment you selected a bare GPUParticles3D.
A selected emitter is now content on its own — the panel shows with the
button, and the session opens from there. The GUI harness selects the emitter
after leaving the Particles tab and asserts both.

## v0.9.157 — the sheet knobs only grid declared sheets (the "rows/cols cut my particles" report)

### The flipbook grid is inert on non-sheet textures
The report: with a glow emitter selected, raising Sheet Columns sliced the
64x64 glow into narrow fragments — each particle a fraction of the art, worse
the higher the knobs went. That is all a flipbook grid CAN do: the format
samples the texture as a cols x rows grid, one cell per particle, cycling over
the lifetime, so on a single-frame image any grid >1x1 is a slicing
instruction. The previous round made the modal's readout say so; this round
makes the knobs stop doing it. The `_sheet` file-name marker — the same one
`preset_for_texture` arms 4x1 from — is the declaration that an image is laid
out as cells:

- `PBParticleParams.is_sheet_texture` is the rule; `apply_values` clamps the
  grid to 1x1 on anything else (the quad takes the whole image's aspect, the
  exporter record follows the material, so editor, viewer and device agree).
- `values_from_node` reports the rendered truth: a legacy hand-sliced node
  opens in the properties modal — and re-saves on its next edit — as one whole
  frame.
- The properties modal greys the two spinners out for non-sheet emitters
  (SpinBox is a Range with no `disabled`; `editable = false` is the engine's
  full read-only — typing and arrows both dead, disabled style drawn). A
  snap-back in the param-changed path keeps spinners, node and readout at 1x1
  even if a grid change slips through. The dock's help text teaches the rule,
  and SPEC_RETRO_FORMAT 8.6 / RETRO-AUTHORING 4.3 record it.
- Rendered proof (`test_scenes/emitter_probe.gd`): case f renders the shipped
  glow with Columns = 2 requested as WHOLE round discs (was: sliced wedges
  like the report's screenshot); case b shows a real 3x1 sheet still
  flipbooking one full cell per particle; new case g renders the glow additive
  — how the preset actually appears in the editor and on the device.
- Tests: the flipbook fixture sheets are now declared via `_sheet` paths (the
  rule under test), a new `test_sheet_knobs_cannot_slice_a_single_frame` pins
  clamp + readback + exporter parity, and the GUI harness asserts the greyed
  spinners in a real editor ("EMITTER-PROPS: sheet knobs disabled to match the
  texture").

### The probe's dark rim is the blended preview, not the art
The f-case render shows a dark ring at each particle's rim: the probe forces
BLENDED mode so the frame grid reads (overlapping additive quads sum to
white), and the glow's alpha is 1-bit BY DESIGN — additive art keeps its
falloff in the RGB channels so it stays RGBA5551 on the device
(`gen_particle_textures.py` documents the convention). Straight-alpha
filtering of that edge band dims it into a visible ring only in blended mode;
in additive — the editor preview's and the PSP's path for the glow preset —
black edge texels add nothing, and probe case g shows the clean falloff.

### PSPLink harness: the PSP-side USB re-activation watchdog
Landed this round (commit `50eae25`): patch 0003 adds a watchdog thread to
`usbhostfs.prx` that cycles `sceUsbDeactivate`/`sceUsbActivate` when no host
has claimed the link for two 15s intervals — a software replug that resets the
activation patience and unfreezes timeout-less transfer waits, so the
always-on daemon claims a fresh activation every ~15-30s, forever. The
give-up state that used to need a PSPLink relaunch on the device is gone.
`psp_install_prx.sh` installs the patched module onto the memory stick
(backing up the old one); `setup_psplink.sh` applies patches per-patch with
marker verification; `run_psp_hw.sh` only sends `reset` into a live link.

## v0.9.156 — one writer for the map format, no demo lumps, and sheets that show what the knobs do

### The GLB->PBM converters and the raylib demo are retired
`retro_engine/pbm_conv.py`, `export/pb_pbm_converter.gd` and the raylib engine
(`retro_engine/raylib/`, `run_raylib.sh`) existed to prove the format could
carry this content; both had fallen behind the exporter. `PBMapExporter` is now
the only `.pbm` writer: a `.pbm` destination routes straight to
`export_retro_pbm` (the export dialog and the showcase bake already did), the
PSP scripts print what to bake instead of shelling out to a converter, and the
format's byte-layout test builds its own fixture scene instead of converting a
pre-exported GLB (it used to *skip* when that artifact was missing — a vacuous
pass on any fresh checkout).

Moving to one writer surfaced two gaps it had never carried:
- **`env_preset`** (day/dawn/dusk/night) was the converter's lump, guessed from
  the GLB's file name. The exporter now emits it from the scene root's
  `poi_env_preset` — stamped by the toolbar's environment buttons — so the
  device keeps the sky the author picked.
- **`map_name`** fell back to a hard-coded demo title; it is now the scene's own
  name, or the export file's.

### Exports carry no demo data
Every map used to ship a fabricated ground quad (`walkable_mesh`), a
`cutscene_archway` trigger, a ball pit, and a `PatrolSphere` entity — smoke-test
lumps that proved the format could carry arbitrary binary. All four are gone
from the writer and the oracle. What remains scene-driven is untouched:
`Walkable_*`/navmesh nodes, `Trigger_*` nodes, `BallPit_*`/`poi_rigid_body`, the
`Spawn` node, the standard `emitters` lump, and **any** custom lump a node asks
for with `poi_metadata_tag` (raw bytes, strings or JSON payloads) — dropping
arbitrary metadata into a `.pbm` is still a one-node affair.

### The writer's own format test caught a real payload bug
Textures whose source image still carried mip levels were written with the whole
chain (`data_size` 33% larger than `width * height * bytes-per-pixel`, which the
format pins): the device builds its own mip chain from the base level, so those
bytes were garbage in the file. `_register_texture` now strips the chain.

### Emitter sheets: art that shows what the knobs do
`Sheet Columns/Rows` sample one cell of a sprite sheet, and none of the shipped
particle textures *was* a sheet — so the knobs could only ever slice a
single-frame glow into squares. Two 4-cell sheets now ship
(`particle_flame_sheet.png`, `particle_smoke_sheet.png`, generated by
`retro_engine/gen_particle_sheets.py`), and picking one arms the knobs for it
(Sheet Columns = 4). The properties modal's hint already spells the current
selection out: `Sheet 4 x 1 = 4 frames of 64 x 64 px: one cell per particle, one
cycle per lifetime.` Rendered proof: `test_scenes/emitter_probe.gd` and the
sheet render in the round's notes — one flame cell per particle, cycling through
the four poses across the lifetime.

### Failing tests say what failed
`run_tests.sh` used to print `GUT exited nonzero` plus a wall of `[Failed]`
lines (and nothing at all when the run died mid-way). It now names the failing
suites and tests, distinguishes a timeout from an exit, and when the suite did
NOT finish it prints the last suite/test reached, the log tail and the likely
cause — a crash/OOM inside the guard's memory cap, or a test/addon file edited
while the suite was loading it (both hit this round). It also strips GUT's ANSI
colours first: every line starts with a colour reset, so `^\* ` never matched
until it did. `.pi/orientation/testing.md` gained the fast-loop notes: the
`-gselect` iteration flow, absolute-path probe scripts
(`godot-mono --headless --path project -s /tmp/probe.gd`), the import pass a new
image asset needs before a probe can load it, the memory cap, and the mid-run
edit trap.

Verified: 1153/1153 headless tests (72 suites), GUI harness failures=0
(130 checks), the rewritten PBM writer test (116 assertions over a self-built
fixture), and the sheet emitters rendered through probe scenes.

## v0.9.155 — decals stop being clipped and blocky, and the PBM export stops dropping geometry

Five reports (plus the emitter question) from the paint/particle round.

### The decal brush cut off at the texture's edge as it grew
A colour dab is composited as a prebuilt sprite, and that sprite was built at
the **requested** 256 texels/m while the window's density can be lower — so on a
face whose window had dropped to ~125 texels/m the sprite was drawn ~2x too
large in window pixels, its soft falloff ran past the window edge and was
**clipped mid-fade** (measured: an 11 m stroke's last dabs landed on the
window's final column at alpha 111/255 instead of fading to 0). The sprite is
now built at the window's real density. Locked by
`test_decal_stroke_fades_out_inside_the_window`, which fails on the old code
with the paint touching the window's last column.

### Big faces: decals were half the density they needed
The decal window was capped at 2048 px per axis, so a big face's painted span
collapsed its density — a 60 m floor with a 25 m painted bbox ran at ~70
texels/m, about half the base texture's density, and every decal on that face
read blocky next to the surface around it (a splat layer keeps its look because
the mask only carries blend weights; the decal carries the content). The cap is
now 4096 px per axis **plus an 8 M texel budget** (32 MB RGBA8 — the same order
the eight 2048² splat masks already spend), and sizes round to 64 px instead of
powers of two (a po2 step doubled the budget's texels whenever a span sat just
past one). A 19 m painted span now keeps ~140 texels/m instead of 100.
`PBSplat.decal_density()` reports what a face ended up with, and the overlay's
readout shows it while the Stamp tab hovers: `Decal: 133 texels/m — low for this
face (the window is capped; a smaller painted span is sharper)`.

### PBM export: geometry was silently dropped past 256 surfaces
Godot's ArrayMesh refuses a 257th surface and only **logs** it: everything past
the cap vanished from the map. The retro bake makes one surface per painted
**tile**, so a large painted floor hit it — the reported errors came with a
60 m floor whose export tree held one 256-surface node and ~70 "MAX_MESH_
SURFACES" errors, most of its paint missing on the device. Surfaces now pour
into as many nodes as it takes (`MAX_SURFACES_PER_EXPORT_MESH` = 128, nodes
numbered `Floor`, `Floor_2`, …): the same floor exports 325 surfaces across
three nodes. The modern bake (one surface per painted face) and the light-bake
re-emit go through the same chunker.
Found with it: the re-emit passed a bogus `flags` mask, so surfaces carrying a
float CUSTOM0 (the splat masks) were **dropped** whenever lighting was baked
over them — `_custom_channel_flags()` now carries each custom channel's real
type.

### PBM export: no more demo data
Every export carried a hard-coded "PatrolSphere" entity lump — a leftover test
of carrying arbitrary binary metadata — in the Godot exporter, the GDScript
converter and the Python oracle alike. All three no longer emit it (the format
still supports `entities` for scenes that ask for one with `poi_metadata_tag`);
the PBM test that pinned the demo lump now asserts its absence.

### The brush ring is built when the tab is entered
Only the stamp path built its preview mesh on a mode change, so entering the
Paint tab from the Stamp tab showed **no ring until a size/softness nudge**
happened to rebuild it. `set_mode()` now builds the mesh for the mode being
entered. Covered by a unit test and a GUI-harness check that hovers right after
switching tabs.

### Emitters: the sheet knobs explain themselves
The properties modal's hint line now states what Sheet Columns/Rows currently
select — `Sheet 4 x 3 = 12 frames of 16 x 21 px: one cell per particle, one
cycle per lifetime.` — instead of leaving "why is my glow sliced into squares?"
to be guessed at. The knobs need a texture that IS a sprite sheet: the flipbook
shows one cell per particle and walks the cells over the particle's lifetime
(one full cycle per lifetime, whatever the frame count).

Verified: 1152/1152 headless tests (72 suites; +5 this round) and the GUI
harness failures=0. The scratch scene from the report exports with **zero
MAX_MESH_SURFACES errors** and all 325 floor surfaces present (was 256 + 69
errors).

## v0.9.154 — a sprite keeps its alpha, stickers keep their shape, emitters keep their cells

Five reports from the paint/particles round.

### Transparent surfaces are not paintable
Painting a billboard sprite replaced its material with a splat shader, and the
splat shader carries albedo/colour/roughness only — the **alpha scissor lived on
the material that was thrown away**, so the sprite's silhouette turned into an
opaque rectangle with undo as the only way back. `PBSplat.paint_block_reason` /
`face_paint_block_reason` now refuse transparent materials and billboard sprites
before anything is converted: the brush ring goes grey over them, the overlay's
readout says "Not paintable: billboard sprite — painting would drop its alpha",
a stroke or stamp click is a no-op, and faces inside a stamp's footprint are
skipped one by one (a stamp may span faces). Opaque and already-splat-painted
faces are unaffected.

### Sticker previews follow the selected image
The stamp preview's quad is sized from the image's aspect ratio, but only the
*texture* was re-bound on a palette click — the quad kept the previous image's
proportions. The hello-world sticker therefore previewed squashed until a spinbox
nudge, and a square sticker afterwards previewed stretched to hello world's 2:1
until the next nudge. `stamp_texture` now rebuilds the quad (and the material)
on every switch.

### Emitter sprite sheets: the quad is the CELL, not the image
`Sheet Columns/Rows` sample one cell of a flipbook out of the texture, but the
draw quad was always square, so a cell that was not square was stretched back to
1:1 (a 3-column sheet of square cells stretched each cell 3x — the "columns make
the particles stretch and clip" report). The quad's width now follows the
**cell's** aspect (tex_w/cols : tex_h/rows), which the exporter already reads off
the QuadMesh (`aspect` in the emitter record), so the editor preview, the retro
viewer and the device agree. The knobs' tooltips state the sheet semantics
(1 = the whole image is one cell). Single-frame textures are unchanged at 1:1
and now keep their own aspect when it is not square. `test_scenes/emitter_probe.gd`
renders the cases (a 3-cell sheet of red/green/blue cells shows one cell per
particle and a different mix a second later; a 3-column sheet of tall cells
comes out narrow instead of stretched).

### Billboards get their own names
The second sprite was created under the same "Billboard_Sprite" name, so Godot
deduplicated the collision with its non-human-readable form
(`@MeshInstance3D@7`) — a name that no longer reads as a billboard in the scene
tree. Sprites are now named Billboard_Sprite, Billboard_Sprite2, … (the emitter
placer's rule).

### The brush-source row says what it does
The Paint tab's **Brush: Color | Palette image** row only drives the decal
brush; the default **Splat layers** target always paints the palette texture, so
the row read "Color" while the brush painted a texture and switching it changed
nothing. The default source is now **Palette image**, and the source + colour
pickers are **disabled with a tooltip** while "Paint into: Splat layers" is
selected (they enable again for the decal layer). The panel's hint says the
same in one line.

Verified: 1147/1147 headless tests (72 suites; +7 for the guard, the preview
switch, the sheet cells, the naming and the source default) and the real-editor
GUI harness (failures=0), which now drives the palette clicks, the paint
hovers/clicks over a real sprite and the dock's enable/disable states.

## v0.9.153 — the paint & stamp panel actually drives the brush

Reported against v0.9.152: every control in the paint panel did nothing
(painting was always the default red, "Palette image" and the colour picker
changed nothing, Erase kept painting, the stamp's scale/rotation were ignored)
and the hello-world stamp came out squashed.

### The whole panel was silently dead
`_on_paint_controller_changed` takes a `_syncing` re-entrancy guard, then pushes
the controller into the widgets — and the layer spinbox assignment used
`editable`, which `EditorSpinSlider` does not have. That threw, and a GDScript
runtime error aborts the function BEFORE the guard is cleared, so from the first
controller change onward `_syncing` stayed true — and every widget handler in
the panel checks it. The brush kept its default red, the target/source/colour/
erase selections never arrived, and the stamp panel's scale and rotation were
inert. The refresh now runs in its own function (nothing inside it can strand
the guard) and uses `read_only`.

The real-editor harness now drives the panel's own signals and asserts the
PAINTED PIXELS — target/source/colour/erase, the ring, and the stamp's preview,
scale and aspect — which is what caught this. The old checks read the
controller directly, so they passed while the panel was dead.

### The squashed stamp
A stamp whose axes do not line up with the face's — a rotated stamp, or a face
whose planar basis differs from the canvas basis (a tilted ramp) — was built
into a sprite sized by its UNROTATED extents, so the content was clipped inside
it. A 2:1 plate at 90 degrees measured 1.42 x 1.50 m; it now measures
1.0 x 2.0 m, and every rotation keeps the stamp's full footprint.

### Also
- The brush ring is a 6%-wide band with a crosshair instead of a 1-px line
  loop, which was invisible on a big scene viewed from any distance. It still
  marks the true brush radius.
- **Clear Layer / Clear Decal Layer** act on the mesh the brush is pointed at
  (the paint tools never needed a selection), and the decal clear covers the
  whole mesh: a decal layer is one image per material, so a face selection has
  nothing to narrow.
- The Paint panel's colour row has its own label — the picker was landing in the
  grid's label column and pushing every row after it out of alignment, and the
  layer spinbox is disabled (rather than editable) when painting Decal.

## v0.9.152 — decal layer: uniform density, real resampling, a colour brush

Second pass on the stamp/decal layer, driven by "very pixelated on the floor,
completely broken on the wall".

### The pixelation: nearest-neighbour pastes on a stretched whole-face image
- The decal image is now a **window cropped to the painted area** at a fixed
  256 texels/m — the same density the splat masks use — instead of one image
  stretched over the face's whole planar rect, which collapsed to 64 texels/m
  on a 32 m floor (a 1 m stamp had a 64 px footprint). The window grows in
  powers of two as paint spreads and keeps the density until 8 m of painted
  span, where it gives way rather than allocating unbounded memory. Paint that
  is already on the face never moves: the window only ever grows.
- The source image is **resampled to the footprint once per paste** (bilinear
  up, mip-blended down) instead of nearest-sampled per layer texel: a 256 px
  PNG landing in an 85 px footprint aliased into exactly the blocks the report
  showed. Mip level data is stripped from the source first (an imported PNG
  arrives as 174764 bytes for a 131072-byte base level; the old loop happened
  to index only the base level).

### The broken wall: a degenerate projection, and a world/local mix-up
- A decal no longer paints faces its plane is not roughly parallel to
  (`DECAL_MIN_FACE_ALIGNMENT` -0.2 → 0.35). A floor stamp used to project its
  middle rows down a perpendicular wall as horizontal streaks.
- The paint controller now converts the pick's **world** normal into the mesh's
  local space before a decal write (the point was converted, the normal was
  not): on any moved or rotated mesh the decal basis was outside the face's
  plane — the same smear. Brush and stamp sizes, and the decal density, also
  follow the mesh's own scale now, so a mesh scaled 4x paints at full density.
- Both are locked by regression tests that fail on the old code paths
  (rotated-mesh aspect, perpendicular-face bleed).

### The decal layer is properly paintable
- New **colour brush**: paint a flat colour with the usual radius / softness /
  opacity / erase controls plus the editor's colour picker, in the Paint tab
  ("Brush: Color | Palette image" — the palette image still dabs as before).
- The brush ring wears the colour it paints; "Clear Layer" clears the decal
  layer when the brush targets Decal; the Stamp tab's "erase parts of it with
  the brush in Decal mode" hint is now a button that opens that brush (it
  described a brush the user had no way to find).
- A stamp is ONE click (`click, not drag — a fixed pattern on a wall or a
  floor`), so the paste can no longer walk the footprint pixel by pixel in
  GDScript: a 4.32 m banner took 1.2 s and an 8 m stamp 3.4 s, per click. When
  the stamp's axes line up with the face's — rotation 0 on an axis-aligned
  face, the normal case — the sprite is a crop + resize in C++ and the paste is
  one blend call: measured 79/261/1221/3350 ms -> 8/14/64/161 ms for 1/2/4.32/
  8 m stamps. A rotated stamp builds its sprite once and caches it, so only the
  first of a given size/rotation pays (130 ms for 2 m, ~1.1 s for 4.32 m) and
  repeats are ~5 ms.
- The footprint's own bounding box drives the window and the pixel walk, not a
  circumscribed square: a 4:1 banner walked 4x its pixels, and its window is
  1024x512 now instead of 1024x1024.
- Brush dabs composite a cached sprite with one `Image.blend_rect()` call
  instead of walking pixels: at a 0.5 m radius, 67 ms -> 3.5 ms per colour dab
  and 53 ms -> 3.2 ms per palette-image dab (the sprite is built once per
  stroke). Erase stays on the per-pixel loop — no C++ image op fades a
  destination alpha — at 39 ms for the same footprint, the class the splat
  brush has always run in. Sprites are skipped above 1024 px an axis, where a
  huge radius would cost more memory than the loop costs time.

### The courtyard demo lost its stamps
- The showcase builder still built `PBStamps` node quads, which the exporter
  skips by name: the demo shipped a map with no stamps at all. Both stamps
  (floor sign, ramp decal) are painted into the decal layer now, and the scene
  builder flushes painted pixels into their GPU textures before a headless save
  (an ImageTexture that only saw `update()` serializes stale pixels there).
- `test_pb_map_showcase.gd` asserts the built map carries decal paint, so the
  demo cannot silently lose them again.

### Also
- Modern sidecars (`poi_splat`) write the decal window rect as `decal_rect`;
  records without it still mean "the whole face rect". The tile baker and the
  modern face-composite baker map the decal through the window.
- The shader's decal uniforms default to the identity, so scenes painted by
  earlier builds render exactly as before.
- Legacy `pb_decal_shader.gdshader` stays on purpose: scenes saved by older
  builds reference it by path, and `migrate_legacy_stamps` re-pastes them into
  the decal layer on load.

## v0.9.151 — splat/decals: masks off UV2, stamps as painted pixels, modern-GLB paint modes

Three changes that all come from one insight: UV2 was never the right place for
splat masks, and scene nodes were never the right shape for stamps.

### Splat masks leave UV2 (paint and lightmaps now coexist)
- Mask coordinates moved from UV2 to the **CUSTOM0 vertex attribute**
  (`PBMeshData.splat_uvs`; the shader reads a `splat_uv` varying). UV2 is author
  data again — a LightmapGI unwrap survives painting, and the rebuild never
  touches `textures1`.
- New UV editor shape: **UV1** and **UV2** are both editable; the mask debug
  view is its own read-only **Splat masks** channel. New **Lightmap** button
  unwraps UV2 (xatlas) with a per-face vertex split + a COLOR tag so the
  write-back survives the engine's vertex merge, stores the atlas size hint and
  flips the mesh to GI mode Static.
- Verified with a real editor LightmapGI bake on a splat-painted, CUSTOM0-masked
  floor: the atlas bakes, the paint renders with it. (Earlier the two were
  mutually exclusive; the bake-down path existed only because of that.)

### Stamps became painted pixels (the decal layer)
- A stamp is now a paste into a per-material **decal layer** (RGBA image mapped
  1:1 over each face's planar rect), not a `PBStamps` child node. No node to
  desync, nothing to leak into exports, and undo/redo covers it like any paint.
- **Multi-face**: a paste projects onto every face its oriented footprint
  touches, so a stamp can overhang an edge, span a floor's tiles or wrap a
  corner. Faces are given their own splat material on write, so painting one
  face no longer bleeds onto every face sharing the material.
- **Footprints keep the image's aspect ratio**: a 4:1 banner lands (and
  previews) 4:1 — the old square decal quads squished them horizontally.
- Brush gains a target selector (**Splat layers / Decal layer**): in Decal mode
  it paints the palette texture as pixels along the stroke and **Erase** fades
  the layer, which is how parts of a stamp are removed. STAMP_DELETE mode and
  the decal-quad machinery are gone.
- Legacy scenes: `PBStamps` records are re-pasted into the decal layer on load
  in the editor and the container is dropped.
- Retro export composites the decal layer into the tile bake instead of decal
  nodes; **the regenerated `showcase_retro_baked.pbm` is byte-identical to the
  pre-change export** (verified).

### Modern `.glb` paint: bake or include
- New export option **Modern paint**: *Bake into textures* (default) composites
  each painted face into its own texture at the live mask resolution and
  rewrites its UV1 into mask space; *Include splat data* ships the live stack —
  mask coordinates as `TEXCOORD_2`, masks/layers/decals as sidecar PNGs, a
  `poi_splat` record in the material extras — with
  `docs/modern_glb_splat.md` (consumer recipe + reference shader) and
  `PBSplatImport.rebuild_from_extras()` for the Godot round trip.

### Verification
- `./run_tests.sh`: 1132 tests / 21355 assertions, 72 suites ✓ (5 new suites'
  worth of contracts: UV2 coexistence, lightmap unwrap, decal rasterizer,
  modern bake/include round trip).
- `./run_gui_tests.sh`: 110 checks, failures=0 ✓ (real editor, decal paste /
  erase / clear driven through the dock).
- Real PSP (`./run_psp_hw.sh`): stairs 3.37 ms, worst view 5.95 ms — inside the
  16.67 ms budget; the retro path is unchanged by design (byte-identical map,
  PSP engine untouched).

## Current Status

Phase 0 (Scaffolding) complete ✓
Phase 1 (Core Data Model) complete ✓
Phase 2 (Math & Topology) complete ✓
Phase 3 (Shape Generators) complete ✓
Phase 4 (Basic Editor Integration) complete ✓
Phase 5 (Element Selection & Picking) complete ✓
Phase 6 (Element Manipulation) — REWRITTEN on native subgizmos after failing
first human sign-off. The hand-rolled input/drag/overlay/gizmo stack
(teleporting drags, double box-select, stuck marquee, gizmo fights) was
deleted and replaced by the editor's own machinery. Conventions fixed:
- Winding: internal data CCW-from-outside (Unity); to_array_mesh reverses
  index order for Godot's CW front faces; normals stay OUTWARD (never
  negated). Ground-truth regression tests: tests/test_pb_winding.gd.
- Cylinder caps were wound backwards since P3 — fixed and now covered.
- 411/411 headless tests passing (run_tests.sh; 8845 assertions) ✓
- Element gizmo = Godot's own transform gizmo at the element pivot, with
  Element/Object/World space toggle (X key) ✓

Phase 7 UX round (v0.7.0, after Phase 6 sign-off) complete ✓
- Persistent plugin toolbar row BELOW the 3D scene toolbar (not inside it);
  always visible, buttons disabled outside ProBuilder context.
- The plugin manages its OWN tool modes (Move/Rotate/Scale, remembered) and
  the editor's universal gizmo is unreachable while editing: the bridge
  disables the engine's Transform(Q)/Select(V) buttons and forces the engine
  tool matching ours, so the element gizmo always shows exactly one tool's
  handles. W/E/R stay live and sync back into the plugin toolbar.
- Element mode persistence: clicking off the object (or selecting another
  node) and coming back re-enters the last element mode.
- Yellow hover highlights for faces/edges/verts, slightly more transparent
  than the selected state.
- Click priority: the transform gizmo outranks element picking (the Phase 6
  click-interception was removed; the engine's native order applies).
- The docked panels are gone: tool info lives in a floating overlay panel in
  the viewport (bottom-left); logging is console-only via PBLogger.

v0.8.0 round complete ✓
- The orientation space ACTUALLY works now (it previously only changed
  PBElementEditor.element_basis, which the engine ignored for gizmo
  display unless the editor's local-coords toggle was on — the user-visible
  symptom was "always world space"). See the Orientation space paragraph
  above for the engine contract.
- Selection is YELLOW, slightly more opaque than hover (was cyan).
- Plugin renamed to PoiBuilder (see naming note at top).
- Phase 7 mesh ops (PBMeshOps, headless-static): extrude faces (region-
  based, ProBuilder semantics: originals removed + caps + side quads),
  extrude edges (fins along adjacent average normal), inset (planar ring),
  subdivide quads (4 sub-quads), delete faces (orphan compaction), detach
  faces (spawns a sibling PBMesh with full node undo via add_do_reference).
  The overlay panel grew an OPERATIONS section (buttons enable per
  selection context; extrude distance + inset amount SpinBoxes); undo
  uses full-mesh snapshots (CmdMeshOp) since ops rewrite topology.
  Insert edge loop (loop cut): PBTopology.get_edge_ring walk; faces with 2
  opposite ring edges split at edge midpoints, 1-ring-edge faces (boundary /
  fan caps) stay unsplit (T-junction expected), corner turns fail cleanly.
  Merge faces: coplanar + edge-adjacent selected faces collapse into one
  n-gon per region (fan-triangulated; T-junction collinear corners are
  KEPT — collapsing them is a future vertex-weld op).
  Weld vertices: selected shared-vertex groups snap to their centroid and
  collapse into one group (positions move, indexes don't — no remap).
- Shape creation (Phase 9-lite): the persistent toolbar's New Shape menu
  (ALWAYS enabled — creation needs no selection) emits shape_requested; the
  plugin builds via PBShapeFactory, places a new PBMesh 3m in front of the
  editor camera, undo via add_do_reference node pattern, auto-selects it.

v0.9.0 round complete ✓ (sign-off fixes + ProBuilder creation UX)
- Undo renders immediately: PBMesh.rebuild() builds a FRESH ArrayMesh every
  time (mutating the old one in place left the MeshInstance3D stale until
  something touched the node — "undo doesn't visually un-extrude").
- The edge/element gizmo side is locked at CLICK time: pick_ray records the
  pick-side face only from the click path; hover passes record_side=false
  and can never re-orient the gizmo.
- Hover is CYAN, selection YELLOW (faces, edges, vertices); the EDGE-mode
  base wireframe is a thinner cyan stroke (half offset, one stack pair).
- Edge selection spreads (#14, ProBuilder's own gesture pair): alt+click or
  double-click selects the edge LOOP (the end-to-end chain through 4-valence
  corners — the edges a loop cut CREATES); shift+alt+click or shift+double-click
  selects the edge RING (the parallel edges crossed by the quad strip — what a
  loop cut CONSUMES). The ENGINE selection stays the seed id (script API is
  single-id); PBElementEditor.selected_loops expands it for dragging, highlight,
  and the PBSelection mirror. Two rapid PLAIN clicks = double click; a plain
  re-click drops the spread.
- Drag gestures (PBElementEditor.DragGesture, decided once at drag begin
  from tool+shift):
  - SCALE without shift = UNIFORM_SCALE (locked aspect ratio; the factor is
    the stretch of the gizmo's own x-axis under the conjugated rel).
    Shift+scale on edges/verts stays free (the override).
  - SHIFT+MOVE on faces/edges = EXTRUDE_MOVE: PBMeshOps.extrude_*(0,
    allow_zero) runs at drag begin (results carry "drag_positions" — caps +
    lifted corners only, never the welded originals); commit/cancel swap
    WHOLE-MESH snapshots (signal drag_topology_committed → plugin clears the
    stale subgizmo selection).
  - SHIFT+SCALE on faces = INSET_SCALE: a minimal inset(0.01) seeds real
    topology at begin; the drag lerps each inner face's corners toward the
    pre-op centroid — UNIFORM amount (aspect fixed, #13). Bases bind POST-op
    inner-face indexes to PRE-op corners (the op remaps indexes!).
- OBJECT is its own mode (#9): toolbar Object button; explicit OBJECT
  persists across mesh switches; set_active_mesh only auto-enters the
  element mode when coming from NOTHING selected. Clicking another mesh in
  an element mode auto-picks the element under the cursor (deferred
  _auto_pick_element → set_subgizmo_selection, single-id engine API) — no
  transient whole-object gizmo.
- Ops moved from the overlay to the persistent toolbar; the toolbar also
  gained Edit Params (enabled only while the selected mesh's data has
  shape_id and not shape_edited) and the Panel toggle.
- Manipulator gizmo size halved by default (EditorSettings
  editors/3d/manipulator_gizmo_size 80→40, applied only while untouched).
- ProBuilder-style shape creation (#12): New Shape arms PBShapeCreator (NOTHING
  spawns; the overlay shows a guidance hint row, since a sticky armed session
  otherwise swallows clicks invisibly). LMB-drag on any PBMesh face (or the
  y=0 grid as fallback) draws a base coplanar with the pressed plane — BASE
  phase shows only the cyan base-rect outline, the mesh stays hidden; the
  drag axis LOCKS on first motion, snapping to the nearest world axis on
  axis-aligned surfaces (axis-aligned creation; arbitrary faces follow the
  drag in their plane). Release, move to set the height along the normal
  (negative grows below); LMB click confirms. ONE extent mapping for every
  surface: u → width, v → depth, the normal extent → the height param — the
  placement basis points local Y along the face normal, so phase 2 grows
  ALONG the face on walls exactly like it grows up on floors. The params
  modal only opens for shapes with drag-inexpressible parameters
  (PBShapeParams.needs_params_modal; cube/prism/plane/sprite finalize at the
  click — Edit Params covers later changes); for parameterized shapes it is
  a live-preview modal (Apply commits, Cancel restores placement values;
  either way the node is selected and the plugin returns to the remembered
  element mode). ESC before the confirm aborts with nothing created. During
  creation: hovered faces highlight cyan (thick edges + fill at selection
  opacity), the preview draws cyan box bounds (on-top) and an ORANGE facing
  arrow for stairs (+Z local). Undo registers at the confirming click (do =
  own/attach, undo = detach) WITH a custom context node — see below.
- EditorUndoRedoManager: every action that touches scene nodes MUST pass the
  custom_context object to create_action (plugin + element editor do) —
  without it actions land in the GLOBAL history and add_do_reference errors
  with "UndoRedo history mismatch" while Ctrl+Z never removes created nodes.
- VIEWPORT CLICK-PICKING RUNS THROUGH GIZMO COLLISION MESHES ONLY
  (Node3DEditorViewport._select_ray → EditorNode3DGizmo.intersect_ray →
  collision_triangles; there is NO mesh raycast fallback). PBMesh never
  emits property-change notifications for its rebuilt ArrayMesh, so the
  stock MeshInstance3D gizmo's triangles go stale — PBGizmoPlugin._redraw
  therefore adds collision triangles (node.mesh.generate_triangle_mesh) on
  every redraw (skipped mid-drag). Removing that block makes every PBMesh
  except the initially-selected one unpickable by clicking.
- GIZMOS ATTACH ONLY TO OWNED NODES (Node3DEditor::_request_gizmo:
  `sp->get_owner() && edited_scene->is_ancestor_of(sp)`), and Node3D caches
  `gizmos_requested` after the FIRST attempt — a node that enters the tree
  ownerless NEVER gets gizmos, even after owner is set later. No gizmo
  means: no overlays, no collision triangles (unpickable by click), no
  subgizmos (uneditable), and clicks fall through to the engine's deselect
  path. THE PREVIEW NODE THEREFORE GETS owner AT CREATION
  (_make_preview_node), and _on_active_mesh_changed self-heals gizmo-less
  PBMeshes by re-firing the editor's deferred group call
  `_spatial_editor_group` / `_request_gizmo_for_id`. This was the root
  cause of three rounds of "selection/creation broken" reports.
- ENGINE-TOOL POLICY (_update_engine_tool, the single place that drives the
  engine's tool buttons): OBJECT mode → our Move/Rotate/Scale drives the
  whole-node gizmo (toolbar tool buttons must switch it visibly). Element
  mode WITH a subgizmo selection → our tool drives the element gizmo;
  element mode with NO selection → the engine idles in its SELECT tool
  (PBToolBridge.press_engine_select_tool — a programmatic pressed works on
  the disabled button), so builder mode never shows the whole-object gizmo.
  The flip is DEFERRED (call_deferred) because element-selection changes
  are mirrored from inside _redraw. Subgizmo click/rubber-band picking is
  NOT tool-gated in the engine, so element selection works under the select
  tool; the engine's W/E/R presses mirror into editor.tool_mode in all
  modes.
- The plugin calls set_input_event_forwarding_always_enabled() so
  _forward_3d_gui_input runs with NOTHING selected (creation is armed from
  the menu; the engine otherwise only forwards viewport input to plugins
  whose _handles() matches the currently edited object).
- PBEditor tracks _object_mode_explicit: an EXPLICIT object mode survives
  deselect + reselect; only the implicit fresh-editor OBJECT mode hands over
  to the remembered element mode on first selection.
- PBMeshData gained serialized shape bookkeeping: shape_id, shape_params,
  shape_edited (copied/restored with every snapshot; set by any committed
  element edit or mesh op). PBShapeParams rebuilds data from a values dict.

POSITION-PRIVACY INVARIANT (mesh ops, locked by test_pb_mesh_ops.gd):
every face owns its corner positions exclusively; faces meeting at a 3D
corner are connected by weld groups, NEVER by shared position indexes.
New faces duplicate every corner. Sharing positions across faces with
different normals corrupts flat normals (calculate_normals writes per
position — the last face wins). Consequence: new faces multiply positions
(an extruded cube face = 20 originals + 4 cap + 16 side positions); weld
groups keep dragging correct. Post-op topology repair: compact orphans +
rebuild welds from coincident positions (PBMeshOps._rebuild_topology).

Known limitation: programmatic multi-element selection (select-all / grow /
shrink / invert) is NOT exposed to gizmo drags — the engine's script-side
subgizmo selection API is single-id (clears+replaces). Multi-select works
natively via click, shift-click, and rubber band. Revisit if the engine
exposes a multi-id API.

Known limitation: the orange selection box around the selected node is
engine-native (Node3DEditorViewport draws it for EVERY selected Node3D from
the node's AABB merged recursively with all VisualInstance3D descendants).
It cannot be suppressed per-node in Godot 4.7: any child MeshInstance3D
re-creates it, and a zero custom AABB breaks mesh culling. It already hugs
the edited mesh (the child-node overlay inflation was removed in the P6
rewrite). An upstream engine flag would be the proper fix.

v0.9.4 round complete ✓ (second-sign-off fixes; requires editor restart to
load — verify the overlay title)
- Click-picking + creation VERIFIED in a real editor via run_gui_tests.sh
  (see the reproduce-before-claiming convention above).
- SCALE UX reworked per sign-off: axis/plane handles scale FREELY (the
  forced-ratio UNIFORM gesture was removed — it also caused "twisted
  geometry" flicker during inset via unstable engine-rel factor
  extraction). A CENTER SQUARE HANDLE (gizmo-plugin handle API:
  add_handles + _get/_set/_commit_handle in PBGizmoPlugin; drag state in
  PBElementEditor.begin/apply/commit_center_drag, DragGesture.CENTER_SCALE
  / CENTER_INSET) scales all axes together; Shift + center on faces insets
  uniformly. The factor is a screen-radius ratio about the pivot — smooth,
  no engine deliveries involved.
- Collision triangles are cached per mesh instance in node meta
  (pb_pick_mesh_id / pb_pick_tmesh) — hover-frequency redraws no longer
  rebuild the TriangleMesh.

v0.9.5 round complete ✓ — ROOT CAUSE of "selection/creation broken" found
via the extended GUI harness: the creation preview entered the scene tree
WITHOUT an owner, and the editor never attaches gizmos to ownerless nodes
(and never re-requests after owner is set). Owner is now set at preview
creation; gizmo-less active meshes self-heal on selection. Harness now
also covers ELEMENT picking (hover, face click, edge click) and asserts
the BASE outline actually drew (creation_outline_draws counter).

v0.9.13 round complete ✓ — creation UX for round shapes, arrow gating,
door shell + arch, and the sprite placement flow:
- ROUND-SHAPE HEIGHT DRAG: apply_drag_extents sized radius-style shapes
  (sphere/torus/arch — no height param) by max(base extent, height), so the
  height drag (1) did nothing until it exceeded the base rect, (2) never
  shrank, and (3) placement_transform's negative-height flip (anchor TOP
  face) yanked the whole shape underground — "sphere starts underground then
  snaps up, torus stuck at a low 3rd dimension, arch crawls and jams at a
  minimum". Now the creator snapshots base_values at release and the height
  drag resizes RELATIVELY (PBShapeParams.height_drag_param: value = base +
  rate·height, rate picked so the shape's TOP tracks the cursor 1:1: sphere
  radius +0.5·h, torus tube_radius +0.5·h, arch radius +1.0·h). Negative
  drags SHRINK; stays_on_surface shapes never flip below the plane (only
  height-param shapes keep ProBuilder's grow-below). The "base drag only"
  sentinel moved from height<0 to NAN (negative is a real signed drag now).
- TORUS WINDING: create_torus quads walked +theta,+phi whose cross points
  INTO the tube — inside-out mesh. Reversed to p0,p3,p2,p1; regression
  test asserts every face normal points away from the tube's spine.
- CREATION ARROW: the gizmo drew it for EVERY shape in BASE and HEIGHT.
  Both draws are now gated on PBShapeParams.facing_direction != ZERO
  (stairs/curved_stair +Z high side, door +Z front); symmetric shapes get
  no arrow.
- DOOR: create_door never emitted the legs' outer walls (±X) or the lintel
  top (+Y) — hollow from the side/above. Added all three (wound outward,
  verified by test). Semantics fix: opening_height was the LINTEL height
  (2m "opening height" on a 2.5m door left a 0.5m slot); it now measures
  the opening from the bottom edge. New arched param (KIND_BOOL → CheckBox
  in the params modal; stored 0/1) with adjustable arch_segments (1..32):
  an ellipse arc spanning the opening (true semicircle when the opening is
  ≥ half-width tall, else springing from the floor), tunnel + spandrel
  fill; apex-adjacent spandrels emit TRIANGLES (the arc touches the
  opening top there — quads carried zero-area triangles, zero normals).
  Face counts: flat 16, arched 15+3N.
- SPRITE PLACEMENT: height_drags_offset(sprite) switches the flow to
  click-to-anchor (State.OFFSET — no base rect, defaults kept) → mouse
  displaces along the surface normal (clamped ≥ 0, quad stays
  surface-parallel) → click confirms. Billboard/auto-face-camera is future
  work.

v0.9.12 round complete ✓ — chained-extrude walls, from the third LOGGED
sign-off (the log's seed line `sides=2` on a quad wall was the tell):
- COORDINATE-BASED BOUNDARY DETECTION: after a zero-distance extrude the
  weld rebuild merges EVERY corner copy that coincides at seed time — the
  tube's top and bottom rim corners land in the SAME weld groups. The
  region logic keyed edges by weld-group pairs, so the next extrude of a
  tube wall conflated its top and bottom edges into one key and created
  only 2 of its 4 side walls ("top and bottom faces missing", 8 open
  boundary edges). _face_regions and _region_boundary_edges now key edges
  by COORDINATE (tolerance-snapped endpoint pair), which is
  over-merge-proof. Reproduced and verified headlessly (sides 2 -> 4,
  open edges 8 -> 0).
- Also in this round: extrude-cap flip on sweep reversal, per-wall side
  orientation for sideways sweeps, the render-triangle audit, and the
  drag_positions compact remap (see v0.9.11).

v0.9.11 round complete ✓ — THE "missing faces" root cause, from the
second LOGGED sign-off (the v0.9.10 audit line `inward_wound_faces=[8]`
was the smoking gun):
- STALE drag_positions THROUGH COMPACT: extrude_faces collected
  drag_positions (the corners the gesture moves) BEFORE _replace_faces
  ran _compact — which drops the removed face's corners and REMAPS every
  later position index. The returned union was stale by the shift:
  union entries pointed at WALL corners and base dups, so the drag tore
  walls off the mesh and left the cap partially unmoved — "2 faces
  missing (front and top), unselectable". _compact now RETURNS its
  remap; _replace_faces exposes it as result["position_remap"];
  extrude_faces and extrude_edges remap drag_positions through it.
  Regression test: after the gesture, no open boundary edges and no
  union index out of range.
- PER-WALL ORIENTATION: a sideways cap sweep folds individual side walls
  through the plane (their winding flips one wall at a time — the old
  all-or-nothing crossing flag missed exactly one wall, matching the
  audit's inward_wound_faces=[8]). Each wall's winding is now checked
  per frame against outward = translated-center radial + extrude normal,
  and flipped independently. The CAP flips when the sweep reverses
  against the extrude normal (the cap leads the sweep). Harness audits
  are clean for sideways, normal-axis, and crossing extrudes.
- RENDER-TRIANGLE AUDIT: _restore_full_mesh logs the compiled ArrayMesh's
  triangle count and any triangles whose RENDERED winding points outward
  (Godot CW: correct rendered normals point INTO the mesh — flag > +0.05
  outward, the opposite sign of the data-side audit). This splits
  "missing faces" into data bugs vs render bugs definitively.
- The data audit's signed volume is calibrated (tetra sum / 6).

v0.9.10 round complete ✓ — from the second LOGGED sign-off (the v0.9.9 log
proved the engine rel now tracks the cursor exactly on the element-space
normal-axis drag — the in-place cap fix worked; the remaining reports
were the inset hole and the arrow):
- INSET RING HOLE (the "additional faces not visible"): the ring faces'
  INNER corners are separate position duplicates of the pulled corners;
  they were NOT in the drag union, so once the drag shrank the inner face
  past the seed amount a HOLE opened between the ring and the inner face
  (screenshot: inner face floating with a dark gap). _begin_inset now
  maps every ring corner to the base/pre-corner it mirrors (position
  match at seed), and both inset gestures lerp the ring corners with the
  same amount. Regression tests: edge_usage_counts must be 2 everywhere
  mid-drag (no boundary edges) for CENTER_INSET and INSET_SCALE.
- ARROW LOCK: the facing arrow stops re-pointing at the base release
  (update_height_point no longer runs the nudge heuristic) — height
  motion must not rotate the shape's facing. Test updated.
- FACE ORIENTATION AUDIT: every topology-gesture commit logs
  `[PB/audit] face orientation: F/V/signed_volume/inward_wound_faces` —
  a concrete per-face inversion answer for any future "missing faces"
  report (negative outwardness dot = wound inward).

v0.9.9 round complete ✓ — the user's v0.9.8 log proved the engine rel
INVERTS mid-drag (rel −0.63 vs cursor +0.65) and the center handle was
undetectable; both root causes found and fixed:
- IN-PLACE CAP IDS (THE extrude bug): `_replace_faces` now writes primary
  faces (caps/inner faces) INTO THE REMOVED SLOTS (ascending removed
  order) instead of appending at the end. The shift+drag extrude seeds
  its topology op MID-DRAG; with append-at-end the editor's still-held
  subgizmo id re-resolved to an unrelated wall, the engine's per-frame
  gizmo recomputation jumped, and the delivered motion inverted ("doesn't
  follow the mouse, moves backwards"). With in-place slots the id keeps
  resolving to the cap (coincident with the original at seed time), and
  the engine's deliveries track the cursor. The mouse-verification
  fallback from v0.9.7 remains as a safety net.
- CENTER HANDLE BILLBOARD (THE detection bug): add_handles(billboard=
  true) makes the engine rotate the handle's LOCAL OFFSET around the NODE
  ORIGIN toward the camera — for the hit test AND the drawn point. With a
  pivot away from the node origin (any face on a moved/created mesh) the
  handle rendered and detected at a DISPLACED position. billboard=false
  pins it to the true pivot. (Harness tests passed despite this because
  the harness camera was nearly axis-aligned — the offset happened to
  align with camera up.)
- INSET_SCALE GESTURE: shift+scale handles on faces now INSETS (spec:
  VertexManipulationTool — "Shift + Scale ... shrinks the new faces
  inward toward their centroids"). The gesture seeds the same zero-width
  inset as the center handle and drives the amount from the dominant
  scale component of the delivered rel (clamped −1..0.95). Center-handle
  shift+inset unchanged.

v0.9.8 round complete ✓ — fixes from the first LOGGED sign-off (the user
supplied console output; the log immediately paid for itself):
- UNDO STALE VIEW ROOT CAUSE: CmdMeshOp.do_it/undo_it restored the
  PBMeshData but NEVER rebuilt the node — the restored geometry only
  reached the screen when a later drag forced a rebuild. CmdMeshOp now
  carries the node, and _apply_snapshot (do/undo) restores + invalidates
  + rebuild + update_gizmos. The plugin passes the node and the logger.
- LOG FORMAT STRINGS: GDScript's % binds to the LAST string literal of a
  "..." + "..." % [...] chain — multi-line formatted log messages printed
  raw placeholders and hid every critical value ("not all arguments
  converted" / "a number is required" errors). All logger calls now keep
  the format string in ONE literal. RULE: never let % [...] span a +
  concatenation.
- UNDO LOGGING: CmdMeshOp do/undo, _restore_full_mesh, _apply_positions,
  and the plugin's _restore_mesh_snapshot all log their application
  (and skipped-restore warnings) so undo traces are visible.
- EXTRUDE VERIFIED AGAINST THE CURSOR: the user's log showed the engine
  delivering SANE rels for the element-space normal-axis drag, so the
  mouse-driven override from v0.9.7 became a VERIFIED FALLBACK: the
  engine rel is trusted unless its distance along the extrude normal
  disagrees with the cursor projection by > max(0.1 m, 35 % of the
  cursor's distance) — then the cursor drives the cap and the takeover
  is logged. The user's log lines to watch: apply EXTRUDE_MOVE
  (rel_origin vs motion), EXTRUDE MISMATCH warnings.
- CREATION ARROW BARBS: the barbs carried an out-of-plane component and
  rendered as a degenerate standing "Y"; they are now a backward V lying
  in the dragged surface plane.

v0.9.7 round complete ✓ — extrude workflow + center-handle fixes from the
fourth sign-off:
- EXTRUDE IS MOUSE-DRIVEN: PBElementEditor.track_mouse() is fed every
  viewport motion by the plugin; EXTRUDE_MOVE computes the cap distance as
  the cursor travel projected onto the extrude normal's screen axis
  (px-per-world measured along that axis). This is the guaranteed workflow
  (element gizmo, shift+grab the normal axis → the cap follows the cursor
  along the normal), is identical in every orientation space, and bypasses
  the engine's transform composition entirely — 4.7.2 delivers a
  basis-relative composition for subgizmo drags that does not track the
  mouse on permuted/flipped element bases. The mouse path engages only
  after a real motion event during the drag; synthetic deliveries (tests)
  fall back to the engine rel. Move-family gestures apply rel.origin ONLY
  (pure translation) and log a loud REL BASIS NOT IDENTITY warning when
  the engine's composition carries a basis — the smoking-gun detector for
  composition mismatches.
- RICH DEBUG LOGGING (console, [PB/drag|handle|pick|plugin] tags): drag
  BEGIN line (gesture, mode, tool, space, per-id start origins/bases),
  first delivery (id, target origin/basis, shift), per-apply motion lines,
  extrude seed details (node+world normal, caps/sides/union,
  px-per-world), REL BASIS warnings, crossing-flip events, center-handle
  drawn/grabbed/factor/committed lines, shift-press suppressions, and
  params-modal auto-dismiss reasons. When a viewport bug report arrives,
  ASK FOR THE CONSOLE LOG — the drag trace identifies the broken layer.
- CENTER HANDLE DETECTION: switching the tool did not redraw the element
  gizmo, so the center square handle did not exist after MOVE↔SCALE until
  an unrelated hover change forced a redraw. _on_tool_mode_changed now
  refreshes the gizmo. Harness-verified: grab, uniform face scaling
  (corners shrink toward the face centroid — the mesh bbox CANNOT show it),
  and shift+center inset (faces 6→10) all work end-to-end.
- EXTRUDE-UNDO STALE VIEW: not reproducible in the GUI harness — a new
  pixel-diff test (Ctrl+Z through synthesized keys, screenshot diff)
  proves the view refreshes with the data restore (941 px change). The
  logging above will capture whatever differs on the reporter's machine.

v0.9.6 round complete ✓ — creation UX + extrude fixes from the third
sign-off report:
- PARAMS MODAL AUTO-DISMISS: any viewport press or key while the modal is
  open APPLIES it and lets the same event pass through — the click keeps
  acting on the scene (select a face of the placed shape, start the next
  shape). ESC still cancels. A New Shape pick while an EDIT-params session
  is open commits it; selecting a different node in any dock dismisses
  too. No dead modal state can outlive the user's attention.
- HOVER vs BASE DRAG: the cyan face highlight is cleared at base-drag
  begin and never re-picked during BASE (the cursor is drawing the rect).
- EXTRUDE: (a) SHIFT+press on an ALREADY-SELECTED element returns -1 from
  _subgizmos_intersect_ray — the engine's shift-click toggle would erase
  the selection and kill the shift+drag extrude gesture; returning -1
  keeps the selection so the following drag extrudes (ProBuilder
  semantics; trade-off: shift+click no longer deselects a selected
  element). (b) CROSSING ZERO: extrude-drag side quads are wound for the
  original direction, so dragging the cap back through its base plane
  rendered them inside-out ("missing faces"); PBElementEditor now records
  the side faces + region normal at gesture begin and flips their winding
  live when the displacement along the normal goes negative (idempotent
  replay from the drag-start snapshot). Verified in the GUI harness by a
  signed-volume assertion (divergence theorem: inverted faces collapse it
  toward zero — 1.65 → 0.55 before the fix, grows linearly after).
- CENTER SCALE HANDLE: the factor is now a LINEAR horizontal screen delta
  (1% per pixel: drag right = smaller, drag left = bigger) — the old
  radius ratio divided by the press-to-pivot distance, which is ~0 when
  the handle is grabbed dead-on, exploding the scale.
- DRAG SMOOTHNESS (~45% faster per motion on a 400-face mesh; see
  tests/bench_drag.gd): to_array_mesh() now uses get_normals() (the cache
  was being ignored — normals re-ran on every rebuild); PBMeshData
  update_normals_for(union) recomputes only the drag union's normals;
  position-only drags keep the common-edge and weld caches hot (they are
  index-based); the plugin's element_drag_updated handler redraws only on
  the drag START transition (the delivery path already redraws per
  motion); PBElementEditor caches the last rel and skips identical
  redeliveries.
- CREATION FLOW: releasing the base drag rebuilds the preview IMMEDIATELY
  — a flat slab sitting ON the surface (height 0), no below-surface pop
  at the first mouse move.
- FACING ARROW + PLACEMENT BASIS: PBShapeCreator.facing is a world-space
  in-plane direction following the heuristic "the dimension (u/v) that
  received the biggest delta in the last significant movement, pointing
  away from the drag start" (dead zone 0.04; lateral moves during the
  HEIGHT stage re-point it — "nudge while placing"). The placement basis
  orients local +Z along facing, so stairs rise toward the arrow; the
  u/v→width/depth extent mapping swaps when the forward points along u.
  The arrow draws during BASE (on the plane at rect_center) and
  HEIGHT/PARAMS (local +Z from the AABB base center) for EVERY shape.
- CREATION OVERLAYS DRAW ON TOP: create_material()'s variants are chosen
  by the NODE'S selected state and the UNSELECTED variant renders at 30%
  alpha with depth test ON — creation overlays on the unselected preview
  came out faint and hidden behind geometry. The outline/arrow now use
  direct StandardMaterial3Ds (unshaded, full alpha, no_depth_test,
  max render priority) drawn as thick line stacks, plus YELLOW SQUARE
  vertex gizmos (GL points): one under the cursor while ARMED (on the
  hovered node's gizmo), drag start+end during BASE, and start+end+
  lifted end during HEIGHT.
- GUI HARNESS LESSONS (general): synthesized InputEventMouseMotion MUST
  set button_mask while a button is held — without it the engine treats
  every drag as released and ALL drag tests silently no-op (this masked
  every drag test until now). Keyboard focus can sit in the SCENE DOCK
  after programmatic node selection — H/J/K hotkeys sent before a
  viewport click are lost. The 4.7.2 transform gizmo cannot be engaged by
  synthesized clicks even at exact projected grabber positions (its
  hit-test differs from the 4.8 sources); the extrude tests therefore
  drive the plugin's delivery path directly against real click-made
  selections.

v0.9.18 round complete ✓ — the merged door sides became TRUE simple
polygons and the fill overlay learned n-gons (from the fifth sign-off:
"selection overlay is a mess of triangles; extruding these faces results
in the extrusion having all the extra layers when they should inherit the
merged faces"):
- KEY GEOMETRY INSIGHT: the door's opening is a NOTCH touching the bottom
  edge — the front/back sides are not faces-with-holes at all, they are
  ONE SIMPLE CONCAVE POLYGON each. create_door now ear-clips that polygon
  (PBShapeComplex._triangulate_2d, concave-safe, corner-dedup for
  floor-springing arches whose arc endpoints coincide with the rim
  corners; the back face re-uses the front's triangulation with each
  triangle's winding flipped — the ear clip needs CCW input). Result: the
  perimeter carries NO collinear chains — 13 edges on the stock door
  (2 rim + 2 jamb + 6 arc + 2 sides + 1 top) — the outer walls/top are
  plain full-size quads, and extruding a side yields EXACTLY one wall per
  true edge (1 cap + 13 walls) with the new edges persisting. Face
  counts unchanged (flat 8, arched N+7); vertex counts dropped (flat 40,
  arched 70).
- FILL OVERLAY: build_face_fill_mesh used to fan from the centroid over
  the perimeter — spills triangles outside any concave or n-gon face
  (the "mess of triangles"). It now emits the face's OWN triangulation
  offset along the normal, which is correct by construction for every
  face shape.
- 400-door randomized sweep: zero defects (watertight, no over-used
  edges, no zero normals). 625/625 + GUI harness green.

v0.9.17 round complete ✓ — the v0.9.16 region-select was WRONG and is
GONE, replaced by real welded geometry in the door generator (from the
fourth sign-off follow-up: "they need to be welded as if the faces were
merged — wireframe gone, extrudes normally... a stock door should be 1
n-gon face per side (and quads for the non-hole sides) but each side
extrudes normally and the edges from extruding stay. Other shapes behave
like before"):
- WHY THE v0.9.16 APPROACH WAS WRONG: selection-time coplanar expansion
  joined faces that merely HAPPEN to be coplanar — after extruding a
  cube's top, the new front wall is coplanar with (and edge-connected to)
  the cube's front face, so both selected and moved as one ("can't select
  the extruded part"), and every extrude chained into the body. Lesson
  recorded: NEVER encode shape-specific topology semantics into the
  shared selection layer — welding is a property of the GEOMETRY a
  generator emits. All region machinery (expand_face_ids, the PBMeshData
  region cache) is removed; selection, drags, and ops are per-face again.
- MERGED DOOR GEOMETRY: create_door now emits ONE face per side via
  PBShapeComplex._add_polygon_face — a per-face vertex pool turns a list
  of coplanar pieces into a single PBFace whose triangle list shares
  pool vertices; PBFace._cache_edges cancels interior edges (appearing
  twice) so the face's derived perimeter is its TRUE boundary: front and
  back are n-gons AROUND the opening (outer rect chain + hole outline),
  outer walls/top are merged faces of their split pieces (their boundary
  sub-edge chains still pair 1:1 with the front/back perimeter — the
  T-junction-free pairing from v0.9.15 is preserved at the SUB-EDGE
  level), jambs/lintel/tunnel stay single quads. Face counts: flat 8,
  arched N+7 (13 @ 6). Wireframe shows only true boundaries; clicking a
  side grabs the whole side; extruding it creates ONE cap + one wall per
  perimeter sub-edge (24 on the stock door) around BOTH the outer rect
  and the hole, and the new edges persist. The extrude gesture path,
  weld rebuild at commit, and undo snapshots all work unchanged on the
  merged faces.
- HOLE-FACE GUARD: inset_faces (and the loop-cut quad check) now fail
  cleanly on faces whose perimeter is more than one cycle
  (loop.size() != distinct count) — a polygon with a hole cannot inset.
- Tests: door counts updated; test_door_front_is_one_ngon_with_hole_
  perimeter (perimeter pairs 1:1 or sits on the rim) and
  test_door_front_extrudes_normally (1 cap + 24 walls, rim unchanged);
  region tests removed. 625/625 + GUI harness green.

v0.9.16 round complete ✓ — "weld all the faces so each side selects as 1
face" + the door's height drag, from the fourth sign-off:
- COPLANAR REGION SELECT (FACE mode): a clicked face now stands for its
  connected coplanar region — PBMeshData.get_coplanar_face_region (BFS
  over full coordinate-shared edges, same-plane only, lazy-cached,
  invalidated with the caches). The door's split shell therefore behaves
  like one face per side: the FRONT/BACK each select as ONE region around
  the arch hole (18 faces @ N=6), each outer wall's 3 pieces merge, the
  top wall's 8 pieces merge; cube faces are regions of one (unchanged;
  the tunnel/jamb faces stay single — adjacent arc quads are not
  coplanar). Expansion points: _begin_drag (the drag's union + mesh-op
  seeds — so shift+move EXTRUDES THE WHOLE REGION with walls around the
  hole boundary too), commit_subgizmos (undo payload covers exactly the
  moved set), begin_center_drag, _draw_selected_faces (the fill covers
  the whole side), the center-handle pivot, and the toolbar ops.
  element_origin stays per-seed-face (the gizmo sits on the grabbed
  face). This is only tear-free BECAUSE the shell is T-junction-free
  (v0.9.15): region moves are covered by test_door_region_move_never_tears
  (open-edge invariant: an open edge must carry the moved union or sit on
  the untouched bottom rim — the pre-move rim height is what counts; a
  moved leg piece can dip below it).
- DOOR CREATION MAPPING: the dominant-step facing heuristic (built for
  stairs) ran for the door too — a wide, thin base drag mapped the THIN
  extent onto width and the door grew as a 0.3m-wide tunnel, so the
  height drag seemed dead ("the door height should adjust when sizing
  the 3rd dimension"). PBShapeParams.facing_across_dominant(&"door"):
  the creator overrides the facing to run ACROSS the dominant extent
  (sign away from the drag start), making width = the bigger drag and
  the placement deterministic in either drag order; the height drag now
  visibly grows a standing door. Tests: test_door_drag_maps_width_to_
  the_dominant_extent, test_door_drag_mapping_is_drag_order_independent.

v0.9.15 round complete ✓ — the door shell rebuilt T-JUNCTION-FREE (the
real "outer walls leave one vert behind" root cause; the v0.9.14 weld
rebuild was necessary but not sufficient — on pristine meshes it also
removed the accidental stale-group over-merging that had been papering
over the tears, which is why the door looked MORE broken after 0.9.14):
- The old shell carried ~54 T-junctions — verts lying ON another face's
  edge without being its corner: the outer wall was one tall quad while
  the leg/header faces met it at the opening-top line (yo), the header
  band's bottom edge carried every spandrel top corner, the top wall's
  front edge carried the header corners. A weld group only moves
  CORNERS, so grabbing a frame face moved those junction verts (via
  their own faces) while the face whose edge they sat on stayed — the
  junction vert "left behind", triangular tears along the wall ("the
  edge loop tangent to the top of the arch" IS the yo line — the arch
  is tangent to it at the apex). THE FIX: every face edge is now shared
  IN FULL with exactly one neighbor — legs split at the arch spring
  line (when jambs exist), outer walls split at every y-level a
  front/back face starts/ends at, the header band becomes one strip per
  arc segment, the top wall splits at every strip boundary; the arc's
  endpoints/apex snap EXACTLY onto the shared lines (float fuzz = a
  T-junction). Face counts: flat 16→20, arched 15+3N→6N+22 (58 @ N=6).
  Degenerate-rise guard: rise < 0.0001 builds the flat variant.
  REGRESSION LOCK: test_door_shell_is_tjunction_free (coordinate-edge
  usage ≤ 2 everywhere; the ONLY open edges are the 8 bottom-rim
  segments — the shell has no bottom face by design) and
  test_door_face_grab_never_tears (EVERY face's weld union moves, welds
  rebuild, and the shell stays closed — a tear would add open edges).
  400-door randomized sweep: zero defects. Reveal faces (tunnel/jamb/
  lintel) legitimately face INTO the opening — the per-commit
  inward_wound_faces audit flags them by design on doors.

v0.9.14 round complete ✓ — the stale-weld root cause behind BOTH the
door-shell tear and the broken first extrude, the cylinder/pipe radius
drag, and the debug gate:
- STALE WELD GROUPS AFTER TOPOLOGY GESTURES (the door hole + the first-
  extrude symptoms, one root): a zero-distance extrude/inset seed merges
  every seed-time-coincident corner into ONE weld group; the drag then
  moves only the cap/lifted dups, but the group still lists the unmoved
  bases. Consequences on the NEXT grab: the union carried the bases
  ("moving the extruded face moves the whole extruded part" — cube cap
  union was 28 positions instead of 12), the group-pair dedup collapsed
  the cap's edges out of get_common_edges ("after extruding, no edges are
  created"; cube edge list 16 instead of 20), and a dragged neighbor's
  union scattered into stale dups that tore coincident corners open
  ("outer walls leave one vert behind, triangular hole at the arch
  tangent" — the door leg extrude's cap dups leaked into the header
  grab's union, 19 positions instead of 13, and the spandrel top corner
  at the opening-top tangent line stayed while its quad moved). FIX:
  commit_subgizmos rebuilds the welds from post-drag coincidence
  (PBMeshData.rebuild_welds) before snapshotting the after-state; undo is
  whole-mesh snapshots, so both directions stay consistent. Repro'd
  headlessly (edge counts, union sizes, watertight-by-coordinate) and
  through the real gesture commit path; regression:
  test_extrude_commit_rebuilds_welds_edges_and_cap_union.
- CYLINDER/PIPE/CONE RADIUS FROM THE BASE DRAG: apply_drag_extents
  mapped the drag footprint onto radius only inside the no-height-param
  branch, so height-param round shapes kept radius at the default 0.5
  while the base drag ran ("pipe/cylinder radius doesn't adjust with the
  initial drag"). The footprint block now runs for every shape with a
  radius/outer_radius param (the u/v extents persist through the height
  phase, so the radius keeps tracking the base rect).
- POIBUILDER_DEBUG GATE: PBLogger.verbose (static, read once from the
  environment) drops INFO/DEBUG entirely — no ring entry, no signal, no
  print — unless POIBUILDER_DEBUG is set to a non-empty value other than
  "0". WARN/ERROR always print (that is the "ask for the console log"
  channel when a bug report arrives; TELL THE REPORTER to run with
  POIBUILDER_DEBUG=1 for the full drag trace). The per-motion hot sites
  (drag apply lines, center-handle redraw lines, the per-commit face-
  orientation and render-triangle audits) ALSO check the flag so their
  format strings are never built. Tests that assert on INFO entries set
  PBLogger.verbose = true themselves.

v0.9.76 round complete ✓ — documentation pass, hardware-truth rules, and a
runner that recovers from a wedged PSP by itself:
- TWO NEW DOCS (the deliverables of this round):
  * `retro_engine/psp/OPTIMIZATION.md` — the PSP engine's optimization
    inventory, in the order that matters, with the measured cost of every
    decision: the three numbers that shape everything (fill, the cache cliff,
    state changes), where the frame actually goes, geometry/submission,
    textures (formats, swizzle, alpha-aware chains, the LOD policy), passes and
    state discipline, per-frame CPU work, what is deliberately NOT done (with
    reasons, including the depth-write finding below), the authoring budget, and
    how to change the engine safely (measure on hardware, hold coverage, use the
    existing rows, the cliffs are steps not slopes).
  * `retro_engine/RETRO-AUTHORING.md` — Godot recipes for building levels that
    treat the retro pipeline as first-class: setup, the loop in rework-avoiding
    order, what the export bakes (with the consequences), the performance rules
    that actually bite (texel-density matching, counting screens of fill,
    particles, draw calls), the knob tables (export dialog, node metadata,
    `poi_render.txt`), pitfalls, and a ship checklist.
- SPEC_RETRO_FORMAT.md §11 rewritten from four clipping rules into "getting the
  most out of the format": a consumer-side MUST list for textures (chains +
  the right filter + alpha-aware downsampling + swizzle rules), the recommended
  LOD policy with its cliff, fill budgeting in screens, geometry/submission
  facts (draw calls and triangles are cheap; chunking is NOT a culling
  mechanism — the runtime draws every chunk every frame), the depth model,
  particles, and "the shortest version" for a new engine. Compliance items
  fixed: cutouts DO carry an alpha-preserving chain now, and a single-cell
  emitter texture SHOULD be sampled through its chain (both items said the
  opposite). The format table now states which two formats the reference
  exporters emit and that the other two must be REJECTED rather than
  mis-sampled — the loader does exactly that now (it previously bound any
  non-5551 texture as 8888, silently).
- RUNNER HARDENED (`run_psp_hw.sh`): resets the device before every profiling
  load (measured: 2 of 4 runs wedged when loading onto a device a previous
  module had exited on, 0 of 6 after a reset), verifies that the profiler
  actually started writing, and retries the whole attempt up to 3 times with a
  fresh reset; `--no-reset` exists for the debug case. App mode now checks
  scrshot's `frame_addr` to confirm the app took the display and reloads once if
  it did not. It also stages without leaking `poi_render.txt` between runs.
- DEPTH WRITE FINDING (documented, default unchanged): the renderer tests depth
  but never writes it, so draw order decides occlusion — which is what the
  exporters arrange for. Writing depth is measured free (0.114 vs 0.114 ms;
  2.749 vs 2.735; 0.688 vs 0.683) and is now a one-knob experiment
  (`depth_write=1`) with `dw_*` battery rows; it stays off because the coplanar
  floor layers resolve by draw order today (LEQUAL + equal depth) and depth
  writes make that ordering load-bearing. A capture with depth writes on showed
  no z-fighting, so the change is plausible — it just needs the layered floor
  verified deliberately, not in a docs round.
- STALENESS SWEEP: README (v2 → v3 retro target, the real mip/LOD policy, the
  measured numbers, the mitigated seam limitation, 834/15.9k tests, the new
  checklist entries, and a "measured, not assumed" section), CLAUDE.md
  (Performance Claims rule, Key Documents, architecture list completed,
  backlog line replaced with the next scheduled work), IMPLEMENTATION.md
  (marked historical, stale directory tree and raw-GUT commands removed),
  `UNITY-GODOT-MAPPING.md` (dock API claim corrected, target 4.7),
  `.pi/ORIENTATION.md` (rewritten: PoiBuilder, current layout, three worker
  rules), `PROTOCOL.md` (marked historical: the extraction is complete).
- THE RULE, for the record: **performance numbers are real only from a PSP over
  USB**. PPSSPP and the desktop viewers answer "does it crash" and "does it look
  right". If no PSP is connected, ask the user to set one up before the session
  ends and mark perf work unverified. (Added to CLAUDE.md's new "Performance
  Claims" section and to the worker orientation.)
- Next: a proper showcase video (the current one barely shows anything).

v0.9.75 round complete ✓ — cutout textures get alpha-preserving mip chains, and
painted-detail meshes get their own LOD policy (both from the same follow-up:
"are the sharp billboards not taking a significant part of the texture cache
budget? they seem unaffected by lod bias" + "is it possible to micromanage lod
bias so the decals and texture splats stay sharper at a distance? right now the
splatted parts have visible seams"):
- CUTOUT TEXTURES HAD NO MIP CHAIN AT ALL — the whole answer to the first
  question. Halving a 1-bit alpha erodes a silhouette, so the loader built no
  chain for CUTOUT, so foliage sprites (tree/bush/flower, 256x512 to 512x512)
  and the 1-bit particle art sampled LEVEL 0 forever: minified, a texture-cache
  miss per fragment — and no LOD bias can reach them, because there is no level
  to select. Fix: build the chain with an alpha-preserving ANY-opaque-wins
  combine (the silhouette dilates by half a texel per level instead of
  eroding). Measured at a foliage view with the sprites 2-6 m out:
  `fol_cutoutnomip` 6.09 ms -> `fol_base` 0.46 ms, and visually identical at
  that range (captures compared); costs ~1/3 more texture memory for those
  textures (~345 KB here, load still fails loudly on OOM). `cutout_mips=0`
  restores the old behaviour at runtime for an A/B.
- THE SPLAT SEAMS ARE PER-PRIMITIVE LOD STEPS, pinned by ablation rather than
  argued: at a grazing floor view with `mips=0` (every fragment samples level 0)
  the painted path is perfectly continuous — NO bands — and a constant level
  removes them too. The GE picks one level per triangle from that triangle's own
  UV derivatives, and a floor crosses several levels across a few metres, so
  neighbouring baked tiles differ by a step; invisible at level 0-1, a visible
  band once the level is coarse.
- PER-MESH LOD POLICY, the "micromanagement" that was asked for: meshes
  matching `detail_mesh=` (default `TileAtlas` — the baked splat/stamp tiles)
  sample ONE CONSTANT mip level, `detail_const` (default 1, chosen at sign-off
  off a device A/B). That is the only setting that removes the level step
  between neighbouring primitives entirely, and it is what takes the painted
  floor from a smeared, seamed look to crisp: at the grazing floor view,
  `fg_base` (const 1) 0.57 ms gpu / 3.07 ms frame against `fg_const0` 1.68 /
  4.71 (the sharpest possible, 3x the cost), `fg_const2` 0.12 / 2.57, and
  `fg_perprim` 0.11 / 2.37 (the old seamed behaviour). `detail_const=-1`
  restores per-primitive mode, in which `detail_bias` (default -1) applies
  instead. The policy is applied per draw call in both mesh passes (the
  level-mode registers are per draw) and the emitter path explicitly resets to
  the global policy so a particle texture can never inherit a mesh's. Every
  view with the shipped default is inside budget: spawn 0.55 gpu (3.36 frame),
  arch/stairs/stairs_low/corner/balcony 0.11-0.12, grazing floor 0.57,
  waterfall foot 2.71 (4.99 frame, 200 fps). Sign-off: decided by eye on the
  device ("the last version had the best sharpness with basically no cost").
- New live knobs (no rebuild): `cutout_mips=`, `detail_mesh=`, `detail_bias=`,
  `detail_const=` in poi_render.txt. New battery camera presets `foliage` and
  `floorgraz` with `fol_*` / `fg_*` rows guard both findings; the report tool and
  HARDWARE-TESTING.md carry the tables.
- HAZARD (cost a device recovery this round): scripted capture loops that
  reset-and-reload the module repeatedly can leave the display controller in a
  black-screen state that a single `reset` clears — do ONE load per capture and
  check scrshot's `frame_addr`/`pixel_format` before trusting a frame, rather
  than retrying a load in a loop.

v0.9.74 round complete ✓ — the waterfall-foot slowdown: the LOD bias was over
the GE's texture-cache cliff (reported from the device, found with the battery,
fixed, guarded):
- THE REPORT: standing right in front of the waterfall base the app's HUD read
  **gpu 24.7-24.8 ms / 36 fps** (three captures, rock steady) while every other
  view read ~7 ms — and it stayed expensive while looking away from the mist.
  Reproduced exactly on the device: the battery's new `waterfall` camera preset
  (4.6 1.3 -2.3) measures `wf_base` = **25.12 ms**.
- WHAT IT IS NOT (ablatated one state at a time on that pose — the scene there
  is the SAME 1526 tris / 25-27 draws as the 8.7 ms spawn view, so everything
  is per-fragment): particles `wf_noemit` 22.75 (only ~2 ms of 25 — the mist
  costs, the flame is free, as the report said), scrolling `wf_noscroll` 24.67
  (NOTHING — answered the "is it the scrolling texture" question), clip planes
  25.10, depth test 25.12, culling 28.18. Skinnying it out:
  `wf_notex` **0.69**, `wf_tex64` (a cache-resident 64x64 stand-in for every
  texture, identical coverage) **2.96**. Texture sampling, specifically the
  GE's ~8 KB texture cache.
- THE MECHANISM, and why "sharper" WAS the bug: a fragment whose sampled mip
  level fits the cache costs ~2 ns (481 Mfrag/s); one that misses costs ~37 ns
  (27 Mfrag/s) — the same 19x the no-mip case pays. The level the hardware
  picks from the UV derivatives is the sharpest that still averages ~1 texel
  per pixel, so at that level the sampled footprint IS the surface's on-screen
  AREA: 75 000 px of wall = ~75 000 texels of the chosen level (~150 KB for a
  16-bit texture). Only close, screen-filling surfaces reach that — the exact
  geometry of standing under a waterfall — and the cliff is sharp. The shipped
  `tex_lod_bias = -1.0` ("trades a little softness back for detail", chosen
  when the scene was cheaper and "quality was affordable") sampled one level
  past it, and one level is the whole cliff:
      bias -1 + trilinear  25.21 ms   (the replaced default)
      bias -1 + mip_linear 14.61
      bias  0 + mip_linear 11.20      (sharpest that still fits: 75 fps)
      bias +0.5            4.32
      bias +1              2.79       <- shipped
      bias +2              1.02
      const level 0        43.83      const level 3/4  1.49 / 0.87
- THE FIX (psp_render.c, render_cfg_default): `PBFILT_MIP_LIN` (one mip level;
  trilinear doubles the fetch set for a level-crossing smoothness that
  per-primitive LOD steps anyway) + `tex_lod_bias = +1.0`. Verified on the
  device, same poses: waterfall foot **25.20 -> 2.77 ms** (4.80 ms/frame, 208
  fps), spawn 8.76 -> 0.42, stairs 11.12 -> 0.11 (CPU-bound at 470). In the app
  itself at the reported spot: **gpu 24.84 -> 2.69 ms, 36.0 -> 59.9 fps**.
  Visual cost, checked against the pre-fix capture of the same pose: a mild
  softening (visible on close tiled walls); `poi_render.txt` takes `bias=0`
  for a sharper look (11.2 ms / 75 fps at the worst view) and `bias=2` for a
  weaker machine. Do not move it back toward -1 without re-measuring — this is
  a cache boundary, not a smooth quality/cost trade.
- INSTRUMENTS (kept, they are the regression harness): battery camera presets
  `waterfall` / `waterfall_lo`; `wf_*` rows — per-state ablations (bias/level/
  filter/nomip/tex64/notex/vertcol/wire/noemit/blend-only/add-only/noscroll/
  noclip/nodepth/nocull/noalpha) plus per-surface `skip_mesh` rows for the wet
  wall, sheet, core, spray, pool, foam and the atlas/floor/tile layers;
  `wf_old_default` keeps the REPLACED policy as a live row so the guard is one
  comparison (2.77 vs 25.20 ms); `ProfTest.skip` + a public
  `psp_render_skip_mesh()`; the report tool grew an "LOD policy at the
  waterfall foot" section and a worst-view line in the verdict.
- HARNESS: `run_psp_hw.sh` now recovers from the documented wedge by itself
  (module resident + no output after 30 s = loaded-but-never-ran, the state the
  previous run leaves behind: reset, reload, continue). Two of four runs died
  on that before the change; it is now one unattended command.
- Lesson worth keeping: "textures are expensive" was measurable and took three
  device runs; "the scene is the same 1526 triangles everywhere" is what turned
  a vague slowdown into a per-fragment question. HARDWARE-TESTING.md carries
  the full table and the authoring rule that follows (a surface that fills the
  screen at ~1 texel/px is the expensive case; the level bias is the renderer
  lever, the tiling density is the content lever).

v0.9.73 round complete ✓ — particles become a standard part of the retro
format: stateless looping emitters, authored as GPUParticles3D, measured on real
hardware:
- THE MODEL: an emitter is a LOOPING, STATELESS stream — particle i's state at
  scene time t is a closed form of (t, i, seed). Its age cycles through its own
  lifetime, its position is the analytic ballistic solution (or the analytic
  damped one when the emitter drags), its size and colour are two-segment curves
  through a knee, and its rotation and flipbook frame follow the age. There is no
  per-particle state, no allocation and no integration anywhere; the per-particle
  constants are derived ONCE at load. The field is deterministic — seed plus the
  specified hash (`pbm_rand`, published with the format) reproduce it exactly —
  which is what lets the viewer preview and the device agree.
- THE FORMAT (SPEC_RETRO_FORMAT.md §8): a STANDARD LUMP — `"emitters"`, metadata
  type 4, the first payload whose layout the specification itself defines — with
  a 16-byte header (`EMIT` magic, its own version) and 176-byte records. No
  version bump: the metadata chunk (v2) is extensible, and a loader that does not
  know the tag skips it. Records carry position/direction/spread, speed and life
  ranges, gravity, damping, size (birth range + knee/end multipliers + aspect),
  initial rotation and spin, wobble, spawn radius, three colours, texture id and
  flipbook grid, flags (additive / Y-locked / velocity-aligned / phase-aligned
  burst) and a seed.
- AUTHORING: emitters are ordinary GPUParticles3D nodes; the exporter maps the
  process material and the draw-pass quad field by field (§8.6). The flipbook
  grid comes from the MATERIAL's `particles_anim_h/v_frames` (Godot only honours
  them in BILLBOARD_PARTICLES mode) and `anim_speed` counts complete cycles per
  lifetime — the same unit as `anim_loops`. `poi_*` node metadata overrides the
  fields Godot has no concept for (Y-locked, wobble, knee, seed, additive).
- RENDERING: camera / Y-locked / velocity-aligned billboards, two triangles per
  particle, ONE draw call per emitter; blended emitters sort back-to-front and
  additive ones are never sorted (order independence is why additive is the cheap
  default); emitters are unlit, depth-tested, never depth-writing, never culled.
  Flipbook cells sample with a half-texel inset. A SINGLE-CELL emitter uses the
  load-time mip chain, a multi-cell flipbook stays on level 0 (a mip level would
  average neighbouring frames into one another) and leans on a size cull.
- BOTH EXPORT ROUTES AGREE: the lump is byte-identical from the Python oracle and
  the GDScript converter (diffed on the showcase's two PBMs). The GLB route
  carries the record in node `extras` on a zero-size holder quad whose material
  puts the particle texture in the file; the converters and the PBM writer skip
  that holder as geometry.
- MEASURED ON DEVICE (40-frame averages; HARDWARE-TESTING.md has the tables):
  256 moving particles — the whole per-map budget — cost 0.72 ms gpu / 1.14 ms
  cpu. Particle fill runs at ~430 Mfrag/s, i.e. the same as opaque fill, and
  neither the blend mode nor RGBA8888-vs-5551 changes that at particle sizes. At
  the spawn view the showcase's additive emitters measure FREE (6.76 ms versus
  6.84 ms with every emitter disabled) while the 14 blended mist puffs cost
  +1.7 ms — reproduced independently in the app's own HUD. The mechanism is
  unidentified (their coverage accounts for ~0.05 ms at the measured rate) and is
  recorded as such so it is not re-investigated from scratch; the practical
  guidance stands: keep blended emitters small or distant, prefer additive near
  the camera.
- VERIFICATION BUGS WORTH KEEPING: the emitter-level cull negated the forward
  distance, so EVERY emitter was skipped — found by reading the emulator
  screenshot's "Parts: 0", not by reading the code. The HUD line ran past the
  480 px screen, so a full "Parts: 46" displayed as "Parts: 4" (one line, 60
  glyphs, or the last digits are lost). And a fill probe that mutated a zeroed
  RenderCfg measured the 19x minification penalty while claiming to measure
  particles: a probe must own a real `render_cfg_default()`.
- Tests: 834/834 GUT — the export parity test asserts the lump layout, the flags,
  the flipbook grid and the texture formats. Device battery gained
  `particles_16/64/256`, `pfill_glow_add/blend`, `pfill_smoke_blend`,
  `abi_noemit_*` and `abi_emit_*_spawn`; `poi_render.txt` gained
  `particles=<bitmask>` (1 blended, 2 additive, 3 both, 0 off).

v0.9.72 round complete ✓ — bright courtyard tiles vs dark wet wall restored, seamless water textures with soft alpha, in-editor live scrolling textures, standard specification & 60 FPS showcase video:
- DEMO MAP BRIGHT TILES VS DARK WET WALL RESTORED:
  * Root cause of courtyard geometry appearing dark gray on PSP: `WetTilesMaterial` shared `tiles_light_4x4.png` with courtyard geometry while applying a `baseColorFactor` dark slate tint; both `pbm_conv.py` and `PBPbmConverter.gd` stored a single texture per source image, and seeing a tint on `WetTilesMaterial` permanently multiplied the shared `tiles_light_4x4` pixels by `(0.55, 0.62, 0.70)`, turning the entire geometry (pillars, stairs, balcony, ramp, doorway) dark gray on PSP while the floor splatting (baked into `TileAtlas`) stayed white.
  * Implemented dedicated `tiles_wet_4x4.png` for `WetTilesMaterial` with clean white albedo.
  * Fixed converter architecture in both `pbm_conv.py` and `PBPbmConverter.gd`: base textures are now keyed by `(image_index, tint_vector)` so multiple materials sharing an image with different `baseColorFactor` values never cross-contaminate or overwrite each other.
- SEAMLESS WATER & WAVES TEXTURES WITH EDGE BLENDING & SOFT ALPHA:
  * Root cause of seam lines at waterfall base: `water_pool.png` and `water_foam.png` generated non-integer wave and noise frequencies with non-periodic vertical fading, producing huge wrap differences (wrap diff Y = 42.5 on foam, wrap diff X/Y = 30+ on pool).
  * Regenerated all water textures (`gen_water_textures.py`) using integer-frequency harmonic waves and periodic noise with toroidal Gaussian filtering (`_toroidal_blur`), eliminating boundary seam jumps entirely (wrap diff < 1.5 matching normal spatial gradients).
  * Soft alpha edge blending: `Waterfall_Pool` and `Waterfall_Foam` now use `_water_material_props(..., true)` (`PBM_ALPHA_BLEND`), rendering in Pass 2 with soft blending so courtyard tiles show through underneath and foam churn blends without harsh rectangular boundaries.
- IN-EDITOR LIVE SCROLLING TEXTURE ANIMATION:
  * `PBMaterialDock` gained an "Animate in Viewport" checkbox under Scrolling Texture (persisted in `EditorSettings` under `poibuilder/editor/animate_scrolling_textures`).
  * `poibuilder_plugin.gd` tracks materials with `PBUv.has_scroll(mat)` and continuously advances `uv1_offset` in `_process(delta)` at 60 FPS while editing, allowing authors to immediately inspect texture flow in the 3D viewport. Offsets reset cleanly on teardown.
- STANDARDIZED SCROLLING TEXTURE SPECIFICATION:
  * Updated `SPEC_RETRO_FORMAT.md` Section 5.1 and added Section N01 to `SPECIFICATION.md`.
  * Guaranteed minimal universal common denominator: 2D linear translation offset $uv(t) = uv_0 + t \cdot (v_u, v_v)$.
  * Stored in material metadata `poi_uv_scroll`, glTF `extras.poi_uv_scroll`, and PBM binary `uv_scroll_u` / `uv_scroll_v`.
- POLISHED 60 FPS SHOWCASE VIDEO & REAL PSP VERIFICATION:
  * Re-exported all showcase presets (`showcase_retro_baked.glb`, `showcase_retro_baked.pbm`, and dawn/day/dusk/night).
  * Verified on real Sony PSP hardware via `./run_psp_hw.sh`: scene_stairs locked at 13.34ms (74.9 FPS), spawn 8.99ms (111.2 FPS), below_up 6.60ms (151.5 FPS), ramp 3.44ms (290.7 FPS), all within 16.67ms 60 FPS budget.
  * Authored `showcase_movie_generator.gd/.tscn` with high-visibility software mouse cursor, click ripple pulses, and glassmorphism lower-third action cards.
  * Recorded 1080p 60 FPS movie with native Godot Movie Maker and composited with Sony PSP hardware playback footage into `/home/headpats/Videos/Recordings/poibuilder-showcase-complete-60fps.mp4` (47.8s, 1920x1080, 60.0 FPS).
- Tests: 834/834 GUT unit tests passing, 53/53 GUI harness tests passing with zero failures.

v0.9.71 round complete ✓ — pre-particle performance restored on real PSP, shadow casting, orientation snapping & clean scratch playground:
- CLEAN HARDWARE BASELINE RESTORED (psp_render.c, pbm_loader.h/c):
  * Completely removed dynamic particle simulation loops, emitter structures, and allocations from the PSP engine.
  * Verified on real Sony PSP hardware via `./run_psp_hw.sh`: GPU time locked at ~2.5ms across the scene (below_up = 4.82ms,
    ramp = 1.63ms, balcony = 0.59ms, corner/sky_up = 0.10ms; all camera poses well within the 16.67ms 60 FPS budget).
  * Removed all extraneous emitters from the archway point light.
- REAPPLIED RESTORED FEATURES:
  * `scratch.sh`: creates a clean, empty playground with a 60mx60m floor using the project default dark 2x2 checkerboard (`pb_default_material.tres`) and player.
  * Shadow-casting billboards: implemented silhouette alpha shadow casting for billboards in `pb_light_baker.gd` and `pb_math.gd`.
  * Gizmo orientation-aware snapping: implemented element gizmo axis snapping in `pb_element_editor.gd` with unit test `test_extrude_and_move_sloped_face_snapping`.
  * Time of day environment presets: restored `PBEnvironment` presets (Dawn, Day, Dusk, Night), toolbar `Env` button, overlay display settings selector, and multi-preset runners (`run_presets.sh`).
  * Water textures: kept the high-fidelity water textures (`water_pool.png` caustic web, `water_foam.png`, `waterfall_sheet.png`, `waterfall_core.png`) and `WetTilesMaterial` on `WaterfallWall`, with bright ceramic tiles (`tiles_light_4x4.png`) on courtyard geometry.
- Tests: 832/832 GUT unit tests passing, 53/53 GUI harness tests, all 4 environment presets smoke-tested on both engines.

v0.9.65 round complete ✓ — scroll DIRECTION fixes from the first device/viewer
pass (the human watched both renderers side by side):
- THE GODOT VIEWER SUBTRACTED THE OFFSET and the PSP advanced it, so for the
  same file value the two renderers animated in OPPOSITE directions: the human
  saw the waterfall climb its wall in `run_viewer.sh` while the PSP had it
  falling. The viewer now advances the offset with the speed, the same form the
  GE's register uses (`uv1_offset = base + speed * t`). The general lesson is
  written into the spec §5.1 as an implementation RULE ("advance the offset with
  the speed") rather than a derivation: the naive reasoning about what an offset
  does to a sampled image is exactly what produced the bug, and it is invisible
  in any static frame.
- THE BASE (pool + foam) SPED THE WRONG WAY ON THE PSP — both now negative
  (`pool -0.03`, `foam -0.30`), matching the viewer's toward-the-viewer drift
  the human called correct. With the sheet's `-0.75` this leaves ONE simple
  rule for the whole composition: negative V falls down a wall and travels away
  from a wall on the floor; the only positive value left is the spray
  billboard, whose own V runs down its face.
- Verification note worth keeping: on the device's spawn view the pool scrolls
  almost straight INTO the screen (its V axis points at the camera), so its
  motion is sub-pixel there and a screen-space correlation over device captures
  cannot see it. The emulator's orbit camera looks down at the pool and shows
  the flip cleanly (same-camera before/after montage). Correlating periodic
  water textures is unreliable in general — the three-frame montage judged by
  eye is the method that actually worked, for the human and for this round.

v0.9.64 round complete ✓ — scrolling textures end to end (PBM 3.0), soft
alpha through the whole pipeline, and the plane reshaped into a
surface-decoration tool:
- PBM 3.0 (BREAKING, version + magic bumped, v1/v2 still load): the mesh
  header grew 64 -> 72 bytes with `uv_scroll_u` / `uv_scroll_v`, and the
  texture header's `has_alpha` became a three-valued `alpha_mode`
  (NONE/CUTOUT/BLEND). The failure that forced the bump is worth remembering:
  the SPEC documented a 72-byte mesh header with `float reserved[2]` while
  every writer and the loader used 64, and both sides had "passed" for
  releases. Now the doc and the code agree, and the loader sizes the header
  from the file version (v<3 reads 64 bytes and leaves the meshes static).
- SCROLL SEMANTICS: `uv_scroll_u/v` are the VELOCITY OF THE PATTERN across the
  surface, in texture repeats per second, along the surface's own UV axes
  (V up on a wall, +Z on a floor) — so falling water is NEGATIVE V and churn
  spreading away from the wall is POSITIVE V. GET THE SIGN WRONG AND IT IS
  INVISIBLE IN A STATIC FRAME: the first demo shipped with the water climbing
  the wall. The GE's `sceGuTexOffset` is documented as an offset ADDED to the
  texture coordinate, and MEASURED on hardware an increasing offset moves the
  pattern toward +V — i.e. the doc's reading is backwards for this purpose.
  The file keeps the pattern-velocity meaning; the renderer writes the offset
  and the sign relation is recorded in `apply_uv_scroll` and §5.1 of the spec.
  Measurement recipe (also in run_psp_headless.sh + the spec): the benchmark
  now freezes its orbit at frame 60 and captures AGAIN 20 frames later, so two
  frames of the same camera isolate the animation; correlate the scrolling
  mesh's pixels (the correlation returns dy = -motion; validate with a
  synthetic shift before trusting it — this was got wrong once too). PPSSPP's
  frame captures are NOT pixel-stable between different frame indices, so a
  same-frame A/B against a map with zeroed scroll speeds is the artifact-free
  control.
- GE STATE LEAKS ACROSS FRAMES: a display list does not reset registers, so a
  texture offset left by the previous frame's last animated mesh is still live
  when the next frame starts. The per-frame offset cache therefore starts
  INVALID (-1) and always emits on the first mesh; starting it at 0,0 painted
  the whole static scene through the stale offset.
- SOFT ALPHA (the "wetness" feature): `alpha_mode = BLEND` textures travel as
  RGBA8888 (5551 has ONE alpha bit — it can cut a texel out, not fade it),
  keep their mip chain (averaged alpha is exactly what a blended surface
  wants), and draw with a zero alpha-test threshold so early-Z still works.
  CUTOUT keeps the old behaviour byte for byte (alpha-tested, NO mip chain:
  box-filtering a 1-bit alpha erodes the silhouette). The loader builds an
  UNSWIZZLED mip chain for 32-bit textures (the 16-bit swizzle layout does not
  apply; the GE takes a base/size register per level either way).
  Godot's transparency drives it: Alpha -> BLEND, Alpha Scissor/Hash ->
  CUTOUT; in glTF it is `alphaMode` (BLEND/MASK/absent), which is also how the
  GLB converters read it. `_get_or_create_base_material` now carries
  transparency across its copy (it used to silently drop it), and PBTileBaker
  refuses to bake a scrolling or non-opaque face (a baked tile is an opaque
  5551 crop and cannot express either).
- ONE AUTHORING KNOB, THREE CONSUMERS: the speed lives on the MATERIAL
  (Material & UV dock → Scrolling Texture: Speed U/V + Apply/Clear), because
  that is the unit the exporters split meshes by; applying it duplicates a
  shared material rather than animating faces the user did not select. From
  there the same value reaches (a) `_write_pbm_from_tree` (native .pbm),
  (b) the GLB material `extras` as `{"poi_uv_scroll": [u, v]}` for
  pbm_conv.py and PBPbmConverter.gd, and (c) the retro viewer, which replays
  the animation with `uv1_offset` so the Godot preview matches the device.
  Converters bucket meshes by (texture, scroll) — two materials sharing one
  texture but scrolling at different speeds must not merge, or one animation
  is lost — and neither atlases a scrolling or blended texture.
- THE PLANE IS NOW THE SURFACE-DECORATION SHAPE (it was janky: a flat grid
  you sized by dragging a height that meant nothing, while sprites covered
  billboards). It drags its base rect out PARALLEL to the surface like every
  other shape, then the mouse offsets it ALONG THE SURFACE NORMAL (clamped
  >= 0) and the click confirms — the same OFFSET stage the sprite introduced,
  reached by a drag instead of a click. Size comes from the base rect alone,
  which is what makes it the natural host for a scrolling sheet hanging in
  front of a wall. GUI harness covers it: "PLANE: offset 2.40m leaves the
  1.60x2.20m sheet unchanged" + "created 1.90 m above the surface".
- THE VIEWER'S ARGS NEVER WORKED: `OS.get_cmdline_args()` excludes everything
  after a bare `--` (that is `get_cmdline_user_args()`), so `--screenshot=`,
  `--map=`, `--cam_pos=`, `--mode=` were silently ignored — every documented
  invocation. It parses both lists now. The animation itself was dead too:
  `uv1_offset` is a Vector3 and the code subtracted a Vector2 from it, so the
  script errored on every frame and the waterfall never moved. Both fixed;
  `--scroll_time=<s>` pins the animation to a fixed scene time for
  deterministic A/B captures.
- TEXTURES: the water art was regenerated (gen_water_textures.py) after the
  first pass read as "a bunch of dots". It is now layered torrents in the
  spirit of cosmic2d's waterwall: long ropes with real gaps where the wall
  shows through, per-rope variation along the length, off-centre highlight
  patches, and foam heads on the fast inner layer. Objective check while
  authoring: `_shift_diff` measures how much the image changes for a given
  scroll step — a vertically uniform rope scores ~0 and reads as frozen no
  matter how correct the animation is, which is exactly how one version of
  this sheet shipped.
- DEMO: the courtyard waterfall is 6 scrolling surfaces (sheet + faster core,
  ripple pool, foam ribbon, spray billboard, on a wall panel), all authored
  through the ordinary material workflow. Pool/foam/spray hug the impact point
  (the first pass left a visible dry gap under the fall). Device numbers:
  59.9 fps locked, cpu 0.72 / gpu 0.01 ms in the emulator benchmark, 4578
  verts, 26 draws.
- Tests: 828/828 GUT (the PBM parity test now pins the alpha modes, the
  format-aware texture sizes, the scroll directions and the never-atlas rule),
  GUI harness green including the new plane flow.

v0.9.63 round complete ✓ — PSP frame cost found and fixed on REAL HARDWARE
(not the emulator), plus the live-hardware debugging harness:
- WHY THE EMULATOR COULD NOT FIND IT: PPSSPP rasterises on the host GPU with a
  huge texture cache, no memory bus and no clipper, so it reports 60 fps for a
  build that spends 27 ms of a 16.6 ms budget on the device. The v0.9.62
  near-plane/chunking work targeted stages that this round shows were never
  loaded — which is why it bought ~20% and then stopped. Emulator = correctness
  and visuals only. See retro_engine/psp/HARDWARE-TESTING.md.
- THE HARNESS (`setup_psplink.sh` once, then `run_psp_hw.sh`): PSPLink over USB
  lets the host execute ELFs on the device and maps a host directory to host0:,
  so builds, maps and RESULTS never touch the memory stick and no XMB
  navigation is involved. HARD-TESTING.md documents the device commands, the
  breadcrumb files, and the rules each learned the hard way: ALWAYS `reset`
  before loading a module (a leftover module leaves the GE wedged such that the
  next one loads, reports success and never executes — black screen); NEVER
  `modstop` a LIVE module (wedges module startup; exit with Start+Select
  instead); recovery is psplink's own `reset`, not a power cycle; suspend drops
  the USB link so use the Hold switch; keep module BSS small (PSPLink's kernel
  partition had a 512 KB max free block, and a 1.8 MB BSS would not load at
  all). Diagnostics that mattered: `scrshot` (the real framebuffer as a BMP,
  with `pixel_format`/`frame_addr` telling you whether OUR display is up),
  `thinfo` RunClocks sampled twice (frozen = blocked, not looping), `exlist`,
  and file breadcrumbs.
- THE ROOT CAUSE, hardware-measured with the pixel count held fixed:
  untextured full-screen fill runs at 487 Mfrag/s, the same fill from a
  cache-resident 64x64 texture at 480 Mfrag/s, and from a 512x512 texture with
  NO MIP CHAIN at 25 Mfrag/s — a 19x per-fragment penalty. The map tiles
  512-texel textures across a metre (12x12 UV repeats), so nearly every fragment
  was minified, and the code ran `sceGuTexFilter(GU_LINEAR, GU_NEAREST)` — note
  the argument order: that is LINEAR *minification*. Four taps scattered tens of
  texels apart, a texture-cache miss per tap, per pixel. Reproduced exactly:
  stairs view 27.25 ms/frame = 34.9 fps (reported "35-40"), same view with a mip
  chain 0.58 ms = 568 fps.
- RULED OUT BY MEASUREMENT (do not re-litigate without new numbers): the
  guardband clipper is free (big clipped quad 0.26 ms with clip planes on AND
  off; only 12 of ~1300 triangles are near-plane split at those views);
  fill rate is not close (165k fragments/frame at 1.2-1.6x overdraw); the CPU is
  1.2-1.6 ms/frame of a 16.6 ms budget.
- FIXES: (1) load-time MIP CHAINS for opaque 16-bit power-of-two textures, one
  swizzled 64-byte-aligned buffer per level down to 16x16, sampled with a
  *mipmap* min filter (the plain filters ignore the chain); alpha textures are
  excluded because their 1-bit alpha makes any level fully transparent once half
  its texels are. (2) pbm_load FAILS LOUDLY: every failure path used to break out
  of its loop or skip a read, desyncing the file and producing a map that
  reported success, rendered nothing and showed a zeroed HUD (the "0 tris 0
  verts 0 draws" report); short reads and allocation failures are now fatal,
  a post-load check rejects vertex-less meshes, and diagnostics + free-memory
  figures go to host0:/pbm_load.log. (3) ATLAS SEAM FIX: the converter inset each
  tile half a texel inside its 128x128 atlas slot, so neighbouring tiles never
  met and the pattern shifted at every seam — visible as a grid of thin lines on
  the floor at grazing angles, independent of mipmapping. Slots now map
  edge-to-edge, and the renderer CLAMPs tile-atlas sampling (base materials still
  REPEAT). (4) Filtering defaults: trilinear minification + LINEAR magnification
  with a -1.0 LOD bias (blends adjacent mip levels, which is what removes the
  level discontinuity between neighbouring tiles; the bias buys sharpness back).
  Costs 4.36 ms worst-case versus 3.37 for mip-nearest and 1.40 for a blurrier
  bias — all far inside budget, so quality was affordable.
- FINAL DEVICE NUMBERS: 59.9 fps locked in-game (cpu 1.81 ms, gpu 0.09 ms with
  the pre-quality settings; gpu ~3.1 ms with trilinear), worst of 11 camera poses
  3.04 ms/frame. Everything is now limited by the 60 Hz vsync, not by the GE.
- ALSO IN THIS ROUND, from a second look at the device: the atlas half-texel
  inset (above) fixed the regular seam grid, and the remaining grazing-angle
  lines were identified as the GE's PER-PRIMITIVE LOD — the level comes from each
  triangle's own UV derivatives, so adjacent tile quads land on different levels
  and step in sharpness along their shared edge, flickering as the camera moves.
  Not mipmapping (persists with mips off), not atlas bleeding, not coplanar
  z-fighting with the base floor layer (`skip_mesh=FloorSplatMat` leaves them
  unchanged). Structural to tiled textures on a GE with no anisotropic filtering;
  the escape hatches are `bias=+N` (blurrier, compresses the steps) and
  `level_mode=const` (one LOD everywhere, removes them, mild aliasing) — both
  live in host0:/poi_render.txt. STATUS: known PSP-hardware limitation, not a bug
  with a known fix — recorded in retro_engine/psp/HARDWARE-TESTING.md along with
  everything ruled out, so it is not re-investigated from scratch; contributors
  are invited to propose a technique.
- HUD: the control hints were only drawn when the map had NO entity, so on any
  map with one they were invisible and the controls looked missing. They are now
  always shown, along with a live `in: x,y btn NNNN` input readout — which is how
  the real cause was found: the PSP's HOLD switch sets PSP_CTRL_HOLD (0x20000)
  and suppresses every button, so with Hold on the app legitimately receives no
  input. Hold ON is for unattended runs; Hold OFF to interact.
- QUIT PATH vs THE USB LINK: the trace dump ran inside the Start+Select quit
  handler and tried `host0:` first; `host0:` opens BLOCK while the PSPLink link
  is down, so quitting after the link dropped froze the game. Home still worked
  (no I/O), which read as "the quit chord is broken". The trace now writes to
  `ms0:` first with `host0:` only as a fallback, Start+Select is gone (Home is
  the exit), and the rule is: nothing reachable while someone is playing does
  `host0:` I/O. Only the profiling battery, which runs with a live link, does.
- HARNESS RESET IS CONDITIONAL: `run_psp_hw.sh` used to reset psplink before
  every load "to be safe". That reboots a healthy PSP out of PSPLink and, if it
  does not come back on its own, leaves it at the XMB with nothing running --
  reported as "it reset the psp but didn't run the demo". It now resets only
  when a stale module is actually resident, which is the only condition the
  reset exists to clear.
- Version bump convention applied (0.9.62 -> 0.9.63 in poibuilder_plugin.gd,
  pb_editor.gd, plugin.cfg).

v0.9.62 round complete ✓ — PSP hardware clipping & near-plane optimization, formalized PBMv2 specification, breaking version signaling, arbitrary binary metadata & entity scripting, and native GDScript converter:
- PSP CLIPPING & NEAR-PLANE OPTIMIZATION (`main.c`, `pbm_conv.py`, `PBPbmConverter.gd`):
  - Root cause of 24 FPS floor-clipping slowdown and 35-40 FPS stairs drops:
    1. Perspective near plane was previously set to `0.5f` (50cm). In tight spaces or when looking up at the floor from below, this placed a large volume of the 12m courtyard floor inside the near-clipping volume, forcing the hardware clipper to divide dozens of quads and re-triangulate in a serialized pipeline.
    2. The courtyard floor was previously merged into one single 1,152-vertex draw call spanning from (-6, -6) to (+6, +6), so the GE was forced to transform all 1,152 vertices every frame and feed every partially overlapping polygon into clipping.
  - Implemented 8cm near plane: `sceGumPerspective(65.0f, 16.0f / 9.0f, 0.08f, 200.0f)` reduces the near-clipping volume by >80%, keeping floor and stair treads cleanly in front of the near plane.
  - Enabled hardware Z-clipping: `sceGuEnable(GU_CLIP_PLANES)` ensures near-plane triangles are clipped cleanly by hardware without driver fallback or discarded triangle artifacts.
  - Spatial mesh chunking: both Python oracle (`pbm_conv.py`) and GDScript exporter (`pb_pbm_converter.gd`) now subdivide large surfaces into spatial chunks of $\le 384$ vertices (128 triangles), giving each chunk a tight bounding box and preventing massive single-mesh draw calls from overwhelming the hardware clipper.
- FORMALIZED PBMv2 RETRO MAP SPECIFICATION (`SPEC_RETRO_FORMAT.md`, `pbm.h`, `pbm_loader.h`, `pbm_loader.c`):
  - Authored dense, exhaustive specification in `SPEC_RETRO_FORMAT.md` covering file architecture, Little-Endian layout, 64-byte `PbmHeader`, texture swizzling, 24-byte interleaved vertex format matching Sony GU DMA specifications, collider chunk, metadata chunk, and entity scripting conventions.
  - Incremented format version to 2 (`PBM_MAGIC = 0x324D4250` / `"PBM2"`).
  - Explicit version breaking change signaling: `pbm_loader.c` validates `version` against supported range (`1..2`), emitting explicit fatal diagnostic `[PBM] Error: Incompatible map version %u! (Loader supports up to v%u). FATAL: Breaking format change detected.` when reading future/incompatible formats, and cleanly rejects without memory corruption.
- ARBITRARY BINARY METADATA & SCRIPTED ENTITY ENGINE (`pbm.h`, `pbm_loader.c`, `main.c`, `pbm_conv.py`, `pb_pbm_converter.gd`):
  - Implemented 40-byte `PbmMetadataHeader` (`char tag[32]`, `uint32_t type`, `uint32_t data_size`) with 4-byte aligned binary payload storage. Supports `RAW`, `STRING`, `JSON`, and `ENTITY` payload types.
  - Proof of concept:
    1. Map name metadata: encoded tag `"map_name"` (`"PoiRetro Courtyard Showcase"`), parsed by `pbm_loader.c` and displayed live on the HUD.
    2. Scripted entity: encoded tag `"entities"` with `PbmEntityPatrolSphere` (88 bytes: radius 0.35m, color `0xFF00C8FF` gold, speed 2.5 m/s, 3 cyclic 3D waypoints).
    3. PSP 3D runtime execution: `main.c` animates the sphere position continuously along the cyclic 3-point route ($W_0 \rightarrow W_1 \rightarrow W_2 \rightarrow W_0$) based on delta time and renders a shaded 3D sphere mesh at the interpolated coordinate in Pass 1, displaying live entity coordinates on the HUD.
- NATIVE GDSCRIPT PBM CONVERTER & ORACLE VERIFICATION (`PBPbmConverter.gd`, `pb_map_exporter.gd`, `test_pb_pbm_export.gd`):
  - Ported entire GLB-to-PBMv2 conversion pipeline to pure GDScript in `PBPbmConverter.gd` (`convert_glb_to_pbm`) and added forwarder to `PBMapExporter`: parses GLB binary chunks, extracts buffers, deduplicates baked tiles, packs 128x128 tiles into 512x512 4x4 atlases with half-texel UV slot clamping, converts textures to `RGBA5551`, packs 24-byte interleaved vertices, extracts colliders, and serializes metadata.
  - Oracle verification test in `test_pb_pbm_export.gd`: converts `showcase_retro_baked.glb` in GDScript and verifies 100% binary structural parity against the Python oracle (12 textures, 18 mesh chunks, 3,840 vertices, 8 colliders, 2 metadata entries).
- README FEATURE HIGHLIGHT:
  - Added dense feature description directly below the demo video in `README.md` highlighting dual-pipeline authoring (modern glTF/GLB + dedicated retro `.pbm` proved on PSP).
- Tests: 827/827 GUT unit tests passing (+1), 50/50 GUI harness tests passing (0 failures).

v0.9.61 round complete ✓ — n-gon grid snapping alignment, overlay modal lifecycle hardening, & PSP retro export renderer:
- N-GON TOOL GRID SNAPPING OFFSET FIX (`PBNgonDrawer`, `poibuilder_plugin.gd`):
  - Root cause of n-gon tool being offset on both axes: `PBNgonDrawer.begin()` previously stored the raw un-snapped ray hit as `plane_point`. Furthermore, `_snap_to_grid()` calculated `d = p - plane_point` and snapped in-plane along U/V axes relative to `plane_point`, permanently locking the raw click point's fractional offset onto every single placed vertex. On confirm, it placed the node origin at the floating-point centroid, drifting gizmo and vertex coordinates off-grid.
  - Implemented `PBNgonDrawer.snap_starting_point(point, normal, p_mesh, p_face)`: on cardinal surfaces (floors and walls), snaps points directly to the world grid via `grid.snap_point_masked(point, normal)` before setting `plane_point`.
  - Updated `_snap_to_grid()`: cardinal surfaces snap directly to absolute world grid ticks via `grid.snap_point_masked(p, n)`, producing 100% exact grid alignment on both axes with zero fractional offset.
  - Node placement alignment: `confirm_height()` now pivots on `poly[0]` (snapped to the grid), ensuring local vertex coordinates are exact multiples of the grid step with the node origin resting cleanly on a grid intersection.
- OVERLAY MODAL LIFECYCLE & STALE PANEL HARDENING (`PBToolOverlay`, `poibuilder_plugin.gd`):
  - Root cause of stale panels and permanently stuck sprite parameters: (1) `open_params()` called `toolbar.set_overlay_pinned(true)`, permanently flipping the user's pin toggle so the panel stayed visible indefinitely; (2) `_on_params_canceled()` under `_params_session_kind == "edit"` omitted `tool_overlay.close_params()`, clearing the session kind to `""` while leaving `params_open = true`, locking Apply/Cancel buttons into no-ops and permanently trapping the modal on screen; (3) `_forward_3d_gui_input()` lacked modal input handling when `_params_session_kind == "edit"`, ignoring viewport clicks and Escape keys; (4) in `update_visibility()`, `can_edit_props` alone forced the unpinned overlay to appear whenever an unedited shape was selected.
  - Hardened modal lifecycle:
    - In `_forward_3d_gui_input()`: when any parameter modal is open, Escape cancels, Enter applies, and any viewport click outside the panel or keypress auto-dismisses the modal cleanly and passes through to the scene.
    - Switching tools (`_on_shape_requested`, `_start_sprite_tool`, `_start_knife_tool`, `_start_ngon_shape_tool`), switching modes (`_on_tool_mode_changed`, `_on_select_mode_changed`), or deselecting/changing selection immediately dismisses and applies/cancels open modals.
    - `_on_params_canceled()` calls `tool_overlay.close_params()` unconditionally across all branches, guaranteeing `params_open` never leaks.
    - Removed `toolbar.set_overlay_pinned(true)` from `open_params()`: opening a modal displays as a modal without mutating the user's manual pin setting; closing the modal auto-hides the overlay if unpinned.
    - In `PBToolOverlay.refresh()`: self-heals stale `params_open` by auto-closing if the active mesh is null and no creation session is running.
    - In `PBToolOverlay.update_visibility()`: `can_edit_props` no longer forces an unpinned overlay to pop up uninvited on pristine shapes (the toolbar's "Edit Params" button remains accessible on-demand).
- RETRO EXPORT PIPELINE & SONY PSP HOMEBREW RENDERER (`PBMapExporter`, `pbm_conv.py`, `retro_engine/psp/`):
  - Retro hardware analysis (PlayStation Portable — MIPS Allegrex 333MHz, 32MB RAM, 2MB eDRAM):
    - GLB snags on retro hardware: 81 separate PNG images take minutes to decompress with zlib on a 333MHz CPU; 81 uncompressed 128x128 RGBA8888 textures take 5.2MB (exceeding 2MB VRAM); parsing complex glTF JSON schemas and bufferView strides fragments 32MB RAM; separate non-interleaved float attribute streams require runtime re-interleaving.
  - Custom Retro Map binary format (`.pbm` — PoiBuilder Retro Map):
    - Compact 64-byte `PbmHeader` with magic `PBM1` (0x314D4250), version, counts, spawn point, and scene AABB.
    - Raw uncompressed texture table in `PbmTextureHeader` supporting 16-bit RGBA5551 (halving memory to 2.59MB for 81 textures) and 32-bit RGBA8888, directly uploadable to `sceGuTexImage` without decompression.
    - 24-byte interleaved vertex format `PbmVertex` (`float u, v; uint32_t color; float x, y, z;`), matching Sony GU hardware vertex specification `GU_TEXTURE_32BITF | GU_COLOR_8888 | GU_VERTEX_32BITF | GU_TRANSFORM_3D` for single-call DMA rendering via `sceGumDrawArray()`.
    - Collision table preserving bounding boxes and triangle meshes.
  - Standalone converter & Godot export:
    - Added `retro_engine/pbm_conv.py`: converts any exported `.glb` into `.pbm` with power-of-two texture quantization, tile atlasing (packing 73 discrete 128x128 baked tiles into four 512x512 atlases, reducing textures and draw calls from 81 to 12) with half-texel clamped UV slot remapping (eliminating the `% 1.0` UV collapse that flattened splatted and decal'd areas), and draw-call batching.
    - Integrated native `.pbm` export in `PBMapExporter.export_retro_pbm()` with texture deduplication and added `.pbm` file filter in `PBExportDialog`.
  - Complete PSP homebrew application (`retro_engine/psp/`):
    - `main.c`: Sony GU double-buffered 480x272 setup, smooth Gouraud shading, texture modulation with baked vertex lighting + AO, and interactive fly camera.
    - Real PSP D-Cache writeback & dynamic vertex allocation fix: on real MIPS Allegrex hardware, `text_verts` was previously a shared static array overwritten across draw calls before `sceGuDrawArray` executed, causing lines 1 and 2 to be blank. Switched to `sceGuGetMemory()` to allocate vertex memory dynamically inside the display list stream, guaranteeing independent vertex slices and rendering all 3 HUD lines.
    - Texture swizzling & fillrate optimization: swizzled 16-bit textures in RAM into 16x8 byte tiles on load and enabled `sceGuTexMode(psm, 0, 0, 1)`, eliminating texture cache thrashing and memory bus congestion when getting close to large textures (e.g. the 512x512 cylinder). Direct `sceGuDrawArray()` calls with single `sceGumUpdateMatrix()` push eliminate all redundant CPU matrix multiplications.
    - Geometry restoration & guardband clipping: removed CPU frustum culling that was falsely discarding on-screen meshes (restoring 100% of all 81 meshes / 3,840 vertices). Switched framebuffer to 16-bit `GU_PSM_5551` (halving eDRAM write bandwidth) and enabled fast 4096x4096 hardware guardband clipping with clean near plane (0.5m) and far plane (500m), eliminating the 20 FPS clipping slowdown when looking at partially off-screen floor polygons.
    - Per-frame depth testing & two-pass rendering: `draw_text_gu()` previously disabled depth test and left it disabled for frame 2 onward, breaking Z-ordering (prism drawing on top of cylinder). Restored per-frame `sceGuEnable(GU_DEPTH_TEST)` with `GU_LEQUAL` and `sceGuDepthMask(GU_FALSE)`. Implemented two-pass rendering: Pass 1 renders solid opaque geometry with `sceGuDisable(GU_BLEND)` and depth testing (eliminating eDRAM read-modify-write and enabling early-Z rejection, eliminating framerate drops near large meshes); Pass 2 renders billboards with alpha testing and blending.
    - Single-analog camera control scheme: Square = move faster (2.5x turbo boost); holding Triangle transforms the analog stick into a full 360° look/tilt stick (pitch + yaw); analog stick without Triangle flies forward/backward and strafes left/right; LT/RT turn left/right; X flies up, Circle flies down; Start resets camera, Start+Select quits to XMB.
    - Billboard alpha cutout restoration: added `has_alpha` flag to `PbmTextureHeader` and preserved billboard names in `pbm_conv.py`/`PBMapExporter.gd`. In `main.c`, `is_transparent_mesh()` checks both `tex->has_alpha` and billboard names, enabling hardware alpha testing (`sceGuEnable(GU_ALPHA_TEST)`, `sceGuAlphaFunc(GU_GREATER, 0x10, 0xFF)`) to discard transparent fragments before depth write, restoring full billboard transparency and cutout foliage.
    - Home button exit callback & button chord: registered `setup_callbacks()` exit thread via `sceKernelCreateCallback` / `sceKernelRegisterExitCallback`, making the Home button trigger the standard PSP XMB quit dialog; also added `Start + Select` chord to quit immediately.
    - Omnilight chromaticity preservation (`PBLightBaker.gd`, `retro_map_viewer.gd`): replaced independent RGB channel clamping with proportional chromaticity-preserving tonemapping when light exceeds 1.0, preserving the rich amber/orange torchlight on the front face of the archway instead of bleaching to white. In `retro_map_viewer.gd`, hid imported dynamic lights in `FULL_BAKED` mode so both Godot and PSP viewers render 1:1 identical baked lighting.
    - Hardware 2D on-screen HUD & FPS counter: embedded 8x8 bitmap font rendered natively via Sony GE command stream (`GU_SPRITES` with `GU_TRANSFORM_2D`), displaying live FPS, triangle/vertex counts, and controls hint with drop shadow on graphical PPSSPP (Vulkan, OpenGL, D3D) and real PSP hardware.
    - Interactive fly camera & test separation: default build (`poiretro_psp.elf` / `EBOOT.PBP`) is a continuous flythrough with Analog stick movement/strafe, LT/RT yaw, X up, Circle down, and Triangle/Square pitch. Separate test binary (`poiretro_psp_test.elf`, `make test_build`) handles automated 120-frame orbital benchmark and screenshot capture for headless verification.
    - Ready-to-copy real PSP homebrew package: `build_psp.sh` creates `package/PSP/GAME/PoiRetro/` (`EBOOT.PBP`, `showcase_retro_baked.pbm`, `README.txt`) and packages `PoiRetro_PSP.zip` (356 KB) ready for root extraction onto any homebrew-enabled PSP Memory Stick.
- Tests: 826/826 GUT unit tests passing (+4), 50/50 GUI harness tests passing (0 failures).

v0.9.60 round complete ✓ — door base bounds extension, non-auto-imported exports dir & cleanup, & Ctrl direction lock:
- DOOR BASE EXTENSION & FRAME EXPANSION (`PBShapeParams.apply_drag_extents`):
  - Root cause of doors failing to fill dragged base area: `apply_drag_extents` previously clamped door `width` via `max_door_w = maxf(3.0, dh * 1.5)`. When height was small (e.g. 1.0m to 2.0m) or during initial BASE phase, dragging a wide base area (e.g. 6m or 10m) resulted in a door clamped to 3m that floated in the middle of the selected rectangle and only expanded once height exceeded `u_size / 1.5`.
  - Implemented base bounds extension: `values["width"] = maxf(0.5, u_size)` ensures the door's total width and its side faces (parallel to the door facing direction, ±X) always span the exact bounds of the dragged base area.
  - If the door opening is restricted by a short height (`values["width"] > max_opening_w + 1.0`), `values["leg_width"]` extends dynamically to `(values["width"] - max_opening_w) * 0.5`. This keeps the doorway arch cleanly proportioned with vertical jambs in the center while outer frame legs stretch to the bounds. As height increases, `leg_width` smoothly returns to the default 0.5m.
- NON-AUTO-IMPORTED EXPORT DIRECTORY & INTERMEDIATE CLEANUP (`PBMapExporter`, `PBExportDialog`):
  - Root cause of 400+ loose `exported_*_albedo.png` texture files flooding the project: Godot's built-in GLTF scene importer defaults to `embedded_image_handling = 1` (Extract Textures). When `.glb` files were exported directly into `res://` (or `test_scenes/`), Godot detected the new GLB and extracted all embedded PNG textures into the directory, creating individual `.png` and `.png.import` files.
  - Changed default export path to `res://exports/exported_map.glb`.
  - Added `PBMapExporter.ensure_export_dir(file_path)`: creates the destination directory and writes a `.gdignore` file inside it if under `res://`, preventing Godot's `EditorFileSystem` from scanning or auto-importing exported maps and unpacked textures.
  - Added `PBMapExporter.cleanup_intermediate_files(file_path)`: deletes any loose extracted textures matching `<base_name>_*.png`, `<base_name>_*.png.import`, and related loose baked tile artifacts.
  - Added `cleanup_intermediate_files: bool = true` in `ExportSettings` and checkbox in `PBExportDialog`. Can be disabled via setting or `POIBUILDER_KEEP_INTERMEDIATE=1` environment variable for debugging from scripts.
  - Cleaned up loose extracted textures from demo map and test scenes; moved showcase GLBs to `res://exports/`.
- CTRL DIRECTION LOCK DURING SHAPE CREATION (`PBShapeCreator`, `poibuilder_plugin.gd`):
  - Added `var lock_direction: bool = false` in `PBShapeCreator`. When active, `_update_facing()` skips re-evaluating the dynamic facing heuristic and preserves the current `facing` vector.
  - Wired modifier tracking into `_creation_input`: holding `Ctrl` (`event.ctrl_pressed` / `Input.is_key_pressed(KEY_CTRL)`) locks the direction to the current orientation, allowing base rectangles to be resized freely without unexpected 90° flips or reversed climbing directions.
  - Updated creation hint overlay to display `(Ctrl: lock direction, Esc cancels)`.
- ARMED CREATION HOVER VERTEX SNAPPING (`poibuilder_plugin.gd`, `PBShapeCreator.snap_starting_point`):
  - Root cause of vertex indicator smoothly following mouse before drag instead of snapping: `_update_creation_hover` previously only ran snapping when `ngon_drawer` was armed; for `shape_creator` it left `best_point` as the raw un-snapped ray hit. Upon pressing LMB, `shape_creator.begin()` snapped the start point to the grid tick, causing an unexpected visual jump from the cursor position to the snapped origin.
  - Implemented `PBShapeCreator.snap_starting_point(surface_point, surface_normal)`: unified single source of truth for start-point snapping. While ARMED with grid snapping enabled, `_update_creation_hover` snaps `best_point` to the exact grid tick that clicking will use (`grid.snap_point_masked(p, n)` on cardinal surfaces).
  - Result: before dragging, the yellow vertex square snaps cleanly to the upcoming click starting point in real time.
- CYLINDER & PIPE SINGLE N-GON CAPS (`PBShapeCylinder.create_cylinder`, `PBShapeCylinder.create_pipe`):
  - Cylinder: top and bottom caps previously generated `div` separate triangular `PBFace` pie-slices. Now generated as 1 single n-gon `PBFace` each; internal radial fan edges cancel out via `PBFace._cache_edges()`, leaving only the true outer circle perimeter. Clicking top or bottom selects the entire cap as 1 face.
  - Pipe: top and bottom rims previously generated `side_count` separate quad `PBFace`s. Now generated as 1 single annular n-gon `PBFace` each; internal radial and diagonal edges cancel out, leaving the true outer and inner circle perimeters.
  - `PBTopology.edge_ring_next`: restricted ring stepping strictly to quads (`i == 1`). Edge rings on cylinder barrels stop cleanly at the caps without jumping across non-quad n-gons.
- MULTI-OBJECT PAINT STROKE UNDO (`PBPaintController`):
  - Root cause of mesh corruption ("floor comes up" / object displacement on undo): `begin_stroke()` previously captured a single `stroke_snapshot_before` of whichever mesh the stroke started on. When the cursor crossed over to another mesh (e.g. from floor to cube), dabs painted onto the second mesh, but on `end_stroke()` the action registered the second mesh with the first mesh's before snapshot. Undoing applied the floor's geometry onto the cube.
  - Implemented `_stroke_meshes: Dictionary`: tracks all meshes touched during a stroke independently (`{mesh: {before: PBMeshData, dirty: bool}}`), capturing each mesh's pre-stroke state before its first dab.
  - `end_stroke()` commits a multi-mesh undo action registering dedicated before/after snapshot pairs for each modified mesh. Undoing restores each mesh's own geometry without cross-contamination.
- 2X2 CHECKERBOARD & BACK-FACE HORIZONTAL UV FLIP (`checkerboard_2x2.png`, `PBMeshData.create_cube`, `PBShapeGenerators.create_box`):
  - Reverted default checkerboard texture to the standard 2x2 grid (512x512 POT, 256px per tile).
  - Flipped UVs horizontally (`1.0 - u`) on the back vertical face (Face 1, Z = +h): at the left seam ($X = -h$), Left face has $U=1.0$ and Back face now has $U=1.0$; at the right seam ($X = +h$), Right face has $U=0.0$ and Back face now has $U=0.0$. The pattern lines up seamlessly with the Top, Left, and Right faces.
- ALT CREATION HEIGHT PLANE (`PBShapeCreator`, `PBGizmoPlugin`, `poibuilder_plugin.gd`):
  - Added `show_height_plane` flag on `PBShapeCreator`, toggled by holding `Alt` during `State.HEIGHT`.
  - `PBGizmoPlugin._draw_creation_preview` renders a 4000m x 4000m double-sided unshaded white plane at 0.25 opacity (`Color(1.0, 1.0, 1.0, 0.25)`) with depth test enabled at the shape's live height elevation, slicing through nearby scene geometry to make alignment immediately visible.
- LIVE CURSOR EXTENTS OVERLAY (`PBShapeCreator.get_cursor_extents_text`, `poibuilder_plugin.gd`):
  - Added live `(x, y, z)` text overlay displayed directly next to the mouse cursor during shape placement in bold white text with a thick 8px black outline.
  - Shows base box dimensions during BASE state as `(X, Y, 0.00)` and updates live during HEIGHT state to `(X, Y, Z)` with height as the Z component, rounded to 2 decimal places.
  - Automatically positions next to the cursor, clamps to viewport boundaries, and clears upon shape confirmation or abort. Also mirrors into `_extents_row` in `PBToolOverlay`.
- DEFAULT SHAPE MATERIAL APPLIES TO NEW SHAPES (`PBMaterialDock`, `PBMeshData.get_default_material`, `PBMeshData.load_material_or_texture`):
  - Root cause of "Set as Default for New Shapes" failing to apply to new shapes: (1) `PBMeshData.get_default_material()` hardcoded loading `pb_default_material.tres` and never checked `EditorSettings`; (2) `PBMaterialDock` created in-memory wrapper materials for project textures without tracking source paths, so the context menu's check `if not _context_material.resource_path.is_empty()` evaluated to false and skipped saving the setting; (3) even when saved, loading a `.png` via `ResourceLoader.load() as Material` returned null.
  - Implemented `PBMeshData.load_material_or_texture(path)`: loads `.tres` materials directly or wraps textures (`.png`, `.jpg`, `.webp`) in a `StandardMaterial3D` (`roughness = 0.8`, `vertex_color_use_as_albedo = true`, `texture_filter = LINEAR_WITH_MIPMAPS`).
  - `PBMeshData.get_default_material()` now reads `"poibuilder/materials/default_material_path"` from `EditorSettings` and loads the user's selected material or texture.
  - `PBMaterialDock` tracks texture paths via `mat.set_meta("source_texture_path", full_path)` and calls `PBMeshData.invalidate_default_material()` upon setting a new default. Newly placed shapes now automatically receive the user-chosen default material.
- SHAPE CREATION GRID SNAP OVERSHOOT FIX (`PBShapeParams`, `PBToolOverlay`):
  - Root cause of stairs (and other shapes) slightly overshooting the grid snap on creation on all sides: `PBShapeParams._size_defs()` and parameter definitions had `min_v = 0.05` with `_step_for()` returning `0.5` or `0.1`. In Godot C++ (`Range::_calc_value`), ranges with a non-zero `min` compute `p_val = _snapped(p_val - min, step) + min`. Because `min = 0.05` is not a multiple of `0.1` or `0.5`, every single dimension passed to the placement modal was phase-shifted by `+0.05m` (e.g. 5.00m became 5.05m, 4.00m became 4.05m, 3.50m became 3.55m). This caused the mesh to be oversized by +0.05m on height, +0.025m on top/bottom depth, and +0.025m on right/left width.
  - Updated all spatial parameter minimums to `0.1m` and `_step_for(span)` to return `0.1m` for spans $\le 100\text{m}$.
  - In `PBToolOverlay.open_params`: if `fmod(min, step) != 0`, sets `spin.min_value = 0.0` and clamps `value` in `_on_param_value_changed`, completely preventing Godot's `Range` from introducing any phase shift.
  - Result: newly created stairs, boxes, and shapes land with 100% exact grid-aligned boundaries (zero overshoot).
- Tests: 822/822 GUT unit tests passing (+12), 50/50 GUI harness tests passing (0 failures).

v0.9.59 round complete ✓ — absolute grid snapping for element moves, AABB placement alignment, & parameter step tuning:
- ABSOLUTE GRID SNAPPING FOR ELEMENT MOVES (`PBElementEditor._snap_move_motion`):
  - Root cause of elements landing "in between two ticks": `pb_element_editor.gd` previously used incremental delta snapping (`grid.snap_local_delta`), which only quantized the relative displacement delta. If an element began with a fractional or off-grid position (e.g. door frame offset $x = -2.15\text{m}$ or curved stair step $x = -7.05\text{m}$), delta snapping permanently preserved the off-grid offset, moving in $+0.2\text{m}$ steps that never aligned with grid lines.
  - Implemented `_snap_move_motion`: derives the element's world-space target pivot (`start_pivot_world + world_motion`) and snaps it to the absolute world grid via `grid.snap_point()`, calculating the exact displacement needed to land the pivot on grid lines. Snapping is applied exclusively along active motion axes so un-dragged axes do not jump.
  - Result: dragging any off-grid face, edge, or vertex snaps its landing position directly onto the grid ticks (e.g. $-2.000\text{m}, -1.800\text{m}, -1.600\text{m}$), allowing clean alignment with adjacent structures and walls.
- SHAPE CREATION AABB CENTERING OFFSET (`PBShapeCreator.placement_transform`):
  - Added `center_offset = basis * Vector3(aabb_center.x, 0, aabb_center.z)` in `placement_transform`: accounts for shapes whose local mesh center differs from their origin, ensuring the base rectangle dragged on the grid aligns its edges to the grid start and end points without fractional displacement.
- PARAMETER STEP RESOLUTION TUNING (`PBShapeParams._step_for`):
  - Updated `_step_for` to `0.1\text{m}` for spans $\le 10\text{m}$ (matching doc-comment and default grid increments), preventing odd $0.05\text{m}$ steps from introducing fractional half-dimensions ($0.275\text{m}, 2.05\text{m}$).
- Tests: 810/810 GUT unit tests passing (`test_element_drag_absolute_grid_snapping`), 49/49 GUI harness tests passing (0 failures).

v0.9.58 round complete ✓ — material fallback for unmapped submesh indices & in-memory splat mask cache:
- UNMAPPED SUBMESH MATERIAL FALLBACK (`PBMeshData.get_face_material`, `PBTileBaker._get_or_create_base_material`):
  - Root cause of untextured tiles on cut+extrude shapes: `get_face_material()` previously returned `null` whenever a face's `submesh_index` exceeded `materials.size()`, and `_get_or_create_base_material(null)` created a flat gray untextured material (`Color(0.8, 0.8, 0.8)`). In contrast, Godot editor's `to_array_mesh()` automatically fell back to `materials[0]` (or `get_default_material()`), causing a visual mismatch where textured faces in the editor exported as flat untextured gray caps.
  - `get_face_material()` now mirrors `to_array_mesh()` by falling back to `materials[0]` and `get_default_material()` when a submesh slot is unassigned or out of bounds. `_get_or_create_base_material()` also defaults null source materials to `PBMeshData.get_default_material()`.
  - Verified in `exported_map.glb`: cut+extrude cube front caps export fully textured with matching checkerboard tiles.
- IN-MEMORY SPLAT MASK CACHE & SCENE FILE SIZE OPTIMIZATION (`pb_splat.gd`):
  - Root cause of 32.35 MiB `.tscn` warning: `pb_splat.gd` previously saved uncompressed 2048x2048 `Image` instances into `ShaderMaterial` metadata (`set_meta("layer_%d_mask_image")`), which Godot serialized as plain text Base64 blobs duplicating the `ImageTexture` parameter data and bloating text scene files by 32+ MiB.
  - Replaced metadata storage with `_cpu_image_cache` (in-memory Dictionary keyed by material instance ID): guarantees zero GPU readback during painting without writing megabytes of uncompressed binary text to disk on save. Automatically strips legacy metadata from loaded materials.
  - Cleaned `/home/headpats/poibuilder-demo-map/playground.tscn` of duplicate metadata image blobs, cutting file size from 32.36 MB down to 16.36 MB.
- Tests: 809/809 GUT unit tests passing, 49/49 GUI harness tests passing (0 failures).

v0.9.57 round complete ✓ — collider inspection mode (wireframe), first-person play mode, ramp collider export & default 2-row toolbar:
- COLLIDER INSPECTION MODE (`DisplayMode.COLLIDERS_ONLY` / Key 5, `test_scenes/retro_map_viewer.gd`):
  - Added Mode 5 to standalone map viewer for verifying collider correctness in exported maps.
  - In Mode 5, visual meshes are hidden while all collider meshes (`Collider_*`) are rendered with translucent emerald-green fill (`Color(0.1, 0.85, 0.45, 0.4)`) and dedicated bright lime-green wireframe lines (`Color(0.2, 1.0, 0.5)`).
  - Makes collider geometry, ramps, and facet orientations immediately inspectable without visual mesh interference.
  - Non-collider modes (1-4) automatically hide collider meshes and collider wireframes.
- FIRST-PERSON PLAY MODE (`KEY_P` / UI Button, `test_scenes/retro_map_viewer.gd`):
  - Interactive play mode to physically test colliders, slopes, and stairs with live character collision.
  - Generates a live `PhysicsWorld` containing `StaticBody3D` nodes with trimesh collision shapes for all `Collider_*` meshes (fallback to non-billboard visual meshes if none exist).
  - Spawns a playable `CharacterBody3D` controller (Capsule: radius 0.4m, height 1.8m) at fly camera position with first-person `Camera3D` at eye level (1.6m).
  - Full controls: WASD movement (walk 5.5 m/s, Shift sprint 11.0 m/s), Space jump (5.5 m/s), gravity (15.0 m/s²), mouse look with pitch clamping, and slope snapping (`floor_snap_length = 0.3`, `floor_max_angle = 50°`).
  - Respawn with `KEY_R` (auto-respawn if falling below $y = -40$).
  - Pressing `P` seamlessly switches between fly camera and physical player without reloading.
  - Works simultaneously with ANY view mode (including Mode 5 so the player can test colliders while seeing them).
  - CLI argument `--play=1` starts directly in play mode.
- RAMP COLLIDER GEOMETRY EXPORT (`PBMapExporter._export_collider_mesh`):
  - Straight stairs and curved stairs with `collider_type == RAMP` now export their true smooth triangular prism / helicoid ramp mesh for `Collider_*` instead of visual stepped geometry.
- DEFAULT TWO-ROW TOOLBAR (`PBToolbar`, `poibuilder_plugin.gd`):
  - Defaulted `two_rows = true` out of the box so the toolbar only requires ~550px minimum width instead of 1016px, allowing Godot's 3D viewport and dock splitters to resize freely without hitting a minimum width lock.
  - Left-aligned split button allows single-row toggle on wide displays with persistence in `EditorSettings`.
- Tests: 809/809 GUT unit tests passing (`test_ramp_collider_export`, `test_viewer_colliders_only_and_play_mode`), 49/49 GUI harness tests passing (0 failures).

v0.9.56 round complete ✓ — two-row split toolbar with auto-detection & left-aligned toggle:
- TWO-ROW TOOLBAR LAYOUT & AUTO-DETECTION (`PBToolbar`, `poibuilder_plugin.gd`):
  - Changed `PBToolbar` from `HBoxContainer` to `VBoxContainer` managing two horizontal rows (`Row1` and `Row2`).
  - Left-aligned Split Rows toggle button (`SplitRowsToggle`, `icon_split_rows.svg` / "☷") positioned right next to the PoiBuilder logo on the far left so it is always accessible and never cut off on narrow screens.
  - Rebalanced 50/50 rows:
    - Row 1 (~420px): Logo, Split Rows button, Move/Rotate/Scale tools, and all 9 Mesh Operation buttons.
    - Row 2 (~550px): Object/Vertex/Edge/Face select modes, Orientation Space cycler, Grid settings & readout, New Shape menu, N-Gon tool, Edit Params, Overlay Panel toggle & recovery, Material & UV dock button, Display Settings button, and Map Export button.
    - In single-row mode, all groups are laid out in the classic sequential order (`Tools -> Modes -> Space -> Grid -> Ops -> Shapes -> Overlay -> Docks -> Export`).
  - Auto-detection: `NOTIFICATION_RESIZED` automatically enables 2-row layout when window/viewport width drops below `AUTO_SPLIT_THRESHOLD` (1050px) and restores single-row when wide.
  - User interaction: Left-click toggles 1 vs 2 rows (manual override), right-click resets to Auto. Setting persists across restarts via `EditorSettings` (`poibuilder/toolbar/rows_mode` and `poibuilder/toolbar/two_rows`).
  - Tests: `test_toolbar_split_rows_toggle` and `test_toolbar_auto_split_on_width` in `test_pb_editor.gd` (808/808 GUT tests passing); GUI integration test in `editor_gui_test.gd` (49/49 passing).
v0.9.55 round complete ✓ — normalized collinearity check in grid subdivision:
- GRID SUBDIVISION CORNER RESTORATION (`PBFaceSubdivider.simplify_collinear_2d`):
  - Root cause of dropped triangles: `simplify_collinear_2d` evaluated raw unnormalized cross product (`absf(cross) > 0.0001`). When grid clipping produced small boundary edge segments, the cross product $|v_1 \times v_2| = d_1 \cdot d_2 \cdot \sin(\theta)$ at a true 90-degree corner evaluated to $< 0.0001$, incorrectly filtering out true geometric corners as "collinear" and dropping complementary triangles.
  - Updated to evaluate normalized angular collinearity $\sin(\theta) = |v_1 \times v_2| / (|v_1| \cdot |v_2|)$ with dot product direction check ($v_1 \cdot v_2 > 0$).
  - 100% of face area preserved across all cells, producing completely watertight exported meshes.

v0.9.54 round complete ✓ — pre-bake showcase launcher, retro viewer wireframe, POT texture clamp, & toolbar restore:
- POIBUILDER TOOLBAR RESTORE (`poibuilder_plugin.gd`):
  - Root cause of missing toolbar: during v0.9.53 export dialog integration, the call to `_add_toolbar_row_below_3d_toolbar()` in `_enter_tree()` was accidentally dropped, leaving the toolbar instantiated but unparented (and tool bridge inactive). Restored the call and added a resilient fallback to `CONTAINER_SPATIAL_EDITOR_MENU` if container layout walking fails.
  - Restored full toolbar visibility and tool bridge across all projects (scratch project, test map, main project). 49/49 editor GUI tests passing with 0 failures.
- RETRO MAP VIEWER WIREFRAME FIX (`test_scenes/retro_map_viewer.gd`):
  - Resolved wireframe invisibility and fading out on floors and walls in `gl_compatibility` mode: replaced ineffective native `debug_draw` with dedicated normal-extruded wireframe line meshes (`ArrayMesh` with `PRIMITIVE_LINES`).
  - Root cause of disappearing lines: `VERTEX` in spatial shaders is object-local, so normalizing and subtracting in `vertex()` shifted vertices towards the local object origin (into the wall on $+X$ and horizontally across the floor) rather than towards the camera.
  - Wireframe generation now extracts surface geometric normals (`ARRAY_NORMAL`); the unshaded spatial shader offsets vertices 6mm along `NORMAL` (`VERTEX += normalize(NORMAL) * normal_offset;`), guaranteeing lines cleanly sit above faces without z-fighting, grazing-angle fading, or view-axis distortion.
  - 3 cycleable wireframe styles (Key 4 toggles/cycles with live HUD readout):
    - Style 0: Dark Slate (Topology) — high-contrast blueprint slate base (`Color(0.12, 0.14, 0.18)`), optimal for checking raw quad/triangle subdivision.
    - Style 1: Vertex Lighting (AO/Shadows) — dimmed baked vertex lighting base (`Color(0.35, 0.38, 0.42)`), inspecting topology alongside lighting/shadows.
    - Style 2: Textures (Tile Alignment) — dimmed baked tile textures (`Color(0.35, 0.35, 0.35)`), inspecting quad subdivision alignment with textures.
  - Preserves alpha transparency for foliage billboards; enabled 4x MSAA for crisp unbroken lines at all distances.
  - Added CLI flags `--wire_style=0|1|2` and `--wire_color=<color>`.
- RETRO EXPORT POWER-OF-TWO TEXTURE ENFORCEMENT (`PBTileBaker`, `PBMapExporter`, `PBExportDialog`):
  - Enforces power-of-two (POT) texture dimensions across all exported assets in Retro mode (composite tile bakes, base textures, billboards) to guarantee compatibility with retro engines.
  - Added `max_texture_size: int = 512` (default 512, adjustable: 64, 128, 256, 512, 1024) and `enforce_power_of_two: bool = true` in `ExportSettings`.
  - Added "Max Tex Size" OptionButton dropdown and expanded "Tile Res" options in `PBExportDialog`.
  - `enforce_pot_image` resizes non-POT and oversized textures to the nearest POT clamped to the configured maximum size using bilinear interpolation.
- CLEAN QUAD SUBDIVISION & SEAMLESS TILE BAKING (`PBFaceSubdivider`, `PBTileBaker`, `retro_map_viewer.gd`):
  - Tiled base texture restoration: resolved flat gray smears across the floor, stairs, and doorway. `texture_repeat = false` is now strictly restricted to `BakedTile_` materials, while shared base materials retain `texture_repeat = true` for continuous tiling beyond UV 1.0.
  - Clean grid-sliced n-gon subdivision (stairs & doorway topology): resolved radiating corner fans across stepped and notched faces. Instead of slicing pre-triangulated geometry, `PBFaceSubdivider` extracts the 2D perimeter polygon (`_extract_perimeter_polygon_2d`), clips it against each grid cell, and performs intermediate U and V coordinate slicing on any cell polygon with step/notch corners (`_triangulate_cell_polygon`). Slices decompose into clean rectangular and trapezoidal sub-boxes with single diagonals. The stairs side wall decomposes into 8 clean rectangular step columns with zero fans, zero slivers, and sharp right-angled step corners. The doorway front wall decomposes into clean leg columns and lintel squares with zero diagonal artifacts.
  - Seamless baked tile filtering: eliminated 1-pixel boundary seams between baked tiles. `PBTileBaker` disables texture repeat on baked tile materials (`tile_mat.texture_repeat = false`) to prevent linear sampling wrap bleed at $U=1.0$ / $U=0.0$, and samples texels edge-to-edge ($x / (\text{resolution}-1)$) with symmetric pixel indexing.
  - Decal depth testing fix: removed `render_priority = 2` on decal materials (`pb_paint_controller.gd` and `test_map_showcase_builder.gd`). Transparent decals now share priority 0 with foliage and billboards, properly sorting by camera distance so foreground trees and bushes correctly occlude decals behind them.
- TEST MAP SPLATTING & ROBUST STAMP BAKING (`TestMapShowcaseBuilder`, `PBTileBaker`):
  - Export consistency fix: resolved 100-meter oversized stamp distortion in Godot. `PBTileBaker` now consumes true physical object-space metrics (`anchor_u`, `anchor_v`, `anchor_scale_x`, `anchor_scale_y`) and `TestMapShowcaseBuilder` sets both physical meters and normalized anchors correctly derived from node transforms. Stamps now appear with identical 1:1 scale in both the Godot project and the retro export.
  - Directional light orientation fix: updated Sun direction to `Vector3(0.4, -1.0, -0.6).normalized()` (shining North-East from South-West) and increased shadow ray bias to 0.05. The sloped ramp face now receives direct warm sunlight while the stairs' west wall sits in shadow.
  - Generated seamless 256x256 stylized terracotta stone brick texture `brick_path_4x4.png`.
  - Applied smooth-edged splat path running straight down the center line ($X=0$) from south across the courtyard through the arched doorway, with an expanded entrance apron, central courtyard plaza, and smoothstep organic edge blending.
  - Isolated splatting strictly to `top_face` (+Y) and assigned clean stone tiles to all other 5 slab faces (rims and bottom), eliminating bottom-face splatting and front-rim corner bleed.
  - "HELLO WORLD" text stamp ($4.32\text{ m} \times 2.16\text{ m}$) straddles the brick splat and base stone tile boundary, oriented right-side up towards the camera.
  - 3x sized circular stamp ($3.6\text{ m} \times 3.6\text{ m}$) on the sloped face of `EastRamp`, partially cut off along the top ridge of the prism with clean face-edge clipping via `pb_decal_shader.gdshader`.
  - Removed unwanted untextured floating plane (`Stamp_Tapestry`) and flower patch behind the bush.
  - Unified anchor-space and object-space sampling in `PBTileBaker` via `anchor_offset`.
- NON-BLOCKING ASYNC EXPORT & PROGRESS SCREEN (`PBExportDialog`, `PBMapExporter`):
  - Non-blocking export flow: resolved engine lockup/freeze during map export. `PBMapExporter.export_map_async` executes step-by-step, yielding across process frames (`await Engine.get_main_loop().process_frame`) so the Godot editor UI stays 100% interactive and responsive.
  - Live modal progress UI: `PBExportDialog` features a real-time `ProgressBar` (0% to 100%), phase label ("Baking Floor (2/14)..."), detailed sub-task readout, and a "Cancel" button to abort export cleanly at any time.
  - Viewer launcher button: adds an "Open in Retro Map Viewer" action button in the dialog upon export completion to inspect the map immediately.
- EDITOR GLTF EXPORT ROOT CAUSE (THE 276-BYTE EMPTY EXPORT BUG):
  - In Godot C++ (`modules/gltf/gltf_document.cpp:4236`), `GLTFDocument::append_from_scene` in editor mode (`Engine.is_editor_hint() == true`) explicitly skips any descendant node whose owner is null (`p_current->get_owner() == nullptr`). Generated nodes in `build_export_tree` lacked owners, causing Godot to silently drop all meshes and produce an empty 276-byte GLB.
  - `_set_owner_recursive(export_root, export_root)` now assigns ownership to all descendant meshes, lights, colliders, and billboards, guaranteeing 100% complete GLB exports in both headless tests and live editor sessions.
- FAST 3D DDA RAYCASTING & SCENE AABB CLIPPING (`PBLightBaker`, `SpatialGrid`):
  - Implemented 3D DDA (voxel line traversal) through `SpatialGrid` ($O(N)$ cells visited instead of iterating the entire 3D bounding box cuboid $O(N^3)$).
  - Directional shadow rays clamp maximum travel distance to the scene AABB exit boundary (`_ray_box_exit`), eliminating thousands of empty-space cell iterations above the map.
  - Shadow rays enable `early_exit = true`, immediately terminating upon the first occluder hit for $O(1)$ shadow evaluation.
- Tests: 806/806 GUT unit tests passing, 49/49 GUI harness tests passing (0 failures).
v0.9.53 round complete ✓ — map export pipeline (retro baked tilemap + modern GLB), vertex lighting, tile baking, standalone viewer app:
- RETRO ENGINE MAP EXPORT (`PBMapExporter`, `export/pb_map_exporter.gd`):
  - Fully baked map pipeline tailored for old and simple engines.
  - Grid-aligned quad subdivision (`PBFaceSubdivider`): divides faces into triangulated quads aligned to the texture tiling grid for high-fidelity vertex lighting and tile-based texturing.
  - Tile-map style texturing (`PBTileBaker`): painted areas (splats + stamps) generate unique composite tile textures; unpainted tiles reuse the shared base texture for optimal memory and draw calls.
  - Vertex color lighting bake (`PBLightBaker`): bakes direct lighting (DirectionalLight3D, OmniLight3D, SpotLight3D), sharp ray-traced shadows, and multi-sample Fibonacci hemisphere ambient occlusion (AO) into vertex colors.
  - Billboards: lit billboards receive vertex lighting and shadows; unlit billboards stay pure white unshaded.
  - Collision mesh export: automatically names collider meshes with `Collider_*` prefix for clean engine detection.
- MODERN ENGINE MAP EXPORT:
  - Exports native geometry without forced subdivision.
  - Encodes stamp placements and splat state into node metadata (`poi_stamps`, `poi_paint`) and exports decal child quads for universal engine compatibility.
- EXPORT DIALOG & TOOLBAR INTEGRATION (`PBExportDialog`, `export/pb_export_dialog.gd`, `PBToolbar`):
  - Dedicated "Export" button on the PoiBuilder toolbar.
  - Comprehensive dialog with individual toggles for Retro vs Modern mode, quad subdivision, tile grid size, lighting bake, shadows, AO samples & distance, texture baking, resolution, billboards, and colliders.
- STANDALONE RETRO MAP VIEWER APP (`test_scenes/retro_map_viewer.tscn`, `retro_map_viewer.gd`, `run_viewer.sh`):
  - Real-time renderer with Godot-style free camera (WASD, mouse look, turbo boost, elevation controls).
  - Multiple inspection display modes (Keys 1-4): Full Baked, Vertex Colors Only (Lighting/AO), Textures Only, and Wireframe.
  - In-viewport HUD showing live FPS, mesh count, surface count, vertex count, and triangle count.
- COMPREHENSIVE TEST MAP SHOWCASE (`test_scenes/test_map_showcase_builder.gd`, `showcase_retro_baked.glb`, `showcase_modern.glb`):
  - Feature map exercising courtyard floor, perimeter walls, arched doorway, grand stairs, balcony, n-gon pillars, sloped ramp, multi-layer splatting, wall/floor stamps, lit/unlit billboards, and multi-light setup.
- Tests: 799/799 GUT unit tests (+15), GUI test harness passing with toolbar export button and modal dialog verification.

v0.9.52 round complete ✓ — stamp billboard delete tool, billboard sprite placement UX, 5-texture carousel, camera orient & scaling:
- STAMP BILLBOARD DELETE TOOL (`PBPaintController.Mode.STAMP_DELETE`, `pb_material_dock.gd`, `poibuilder_plugin.gd`):
  - Added dedicated "Delete Tool" toggle button in the Stamp section of `PBMaterialDock` (`[ Place Stamp ] [ Delete Tool ]`).
  - In `STAMP_DELETE` mode, raycasts directly test against placed stamp decal billboards (`pick_stamp_at_ray`).
  - Hovering a stamp highlights the billboard with a vibrant translucent red outline quad (`delete_highlight_mesh`).
  - Left-clicking the hovered billboard deletes it cleanly with full Undo/Redo support (`Delete Stamp Billboard` action with `_detach_node` / `_attach_detached`).
- PROCEDURAL FOLIAGE & TREE PNGS:
  - Generated stylized, transparent RGBA PNG assets saved under `addons/poibuilder/materials/textures/` and `materials/textures/`:
    - `tree_pine.png` (256x512 evergreen pine tree with layered needles and trunk)
    - `tree_oak.png` (512x512 deciduous oak tree with lush canopy clumps and sturdy trunk)
    - `bush_foliage.png` (256x256 round leafy bush with highlights and red berries)
    - `grass_tuft.png` (256x256 tuft of wild grass blades with color gradients)
    - `flower_patch.png` (256x256 colorful wildflower patch with petals and stems)
- BILLBOARD SPRITE PLACEMENT CONTROLLER & UX (`PBSpritePlacer`, `editor/pb_sprite_placer.gd`, `poibuilder_plugin.gd`):
  - Triggerable via New Shape > Sprite, or dedicated `B` hotkey (`PBActions` `"tool_sprite"`: `KEY_B`).
  - Single click on a surface places a billboard using `last_texture` directly.
  - Click-and-drag (>= 6px drag with LMB held down) opens modal horizontal carousel overlay (`PBBillboardCarousel`).
  - Carousel renders 5 textures at a time; horizontal mouse motion smoothly scrolls through all available project billboard textures; centered texture appears highlighted with PoiBuilder cyan border, background tint, and filename readout.
  - Releasing LMB (in hold mode) or clicking (in click mode) confirms the centered texture and sets `last_texture`.
  - If no `last_texture` exists on first click, a simple click opens the carousel without requiring a drag.
  - RAISE PHASE: Moving mouse up/down raises the billboard along the surface normal (respecting grid snap); the billboard dynamically rotates around the normal to face the camera. Left-clicking confirms and locks elevation and facing angle.
  - SCALE PHASE: Moving mouse left/right scales the billboard uniformly (same UX as scale gizmo); respects grid snapping when enabled. Left-clicking confirms and finalizes placement.
  - `ESC` cancels cleanly at any phase with zero stray nodes left behind.
- SPRITE SHAPE PROPERTIES VIA OVERLAY (`PBToolOverlay`, `PBShapeParams`, `poibuilder_plugin.gd`):
  - Rebuilt sprite properties through the standard overlay pattern: removed property widgets from the dock's sprite panel.
  - The overlay shows an `[ ⚙ Edit Shape Properties ]` button whenever any unedited factory shape is selected (including sprites).
  - Clicking opens `tool_overlay.open_params()` with live updating controls: Width, Height, `Lit (Shaded)`, `Cast Shadows`, `Auto Orient To Camera`.
  - Live update in `_on_param_changed` preserves existing sprite textures, switches `shading_mode = PER_PIXEL` vs `UNSHADED` (`lit`), toggles `billboard_mode = BILLBOARD_FIXED_Y` vs `BILLBOARD_DISABLED` (`billboard`), and sets `node.cast_shadow = DOUBLE_SIDED` vs `OFF` (`cast_shadow`) with full Undo/Redo property tracking on commit.
- Tests: 784/784 GUT unit tests (+11), 49/49 real-editor GUI tests under Xvfb (+7 assertions covering stamp delete mode, hover highlight, click deletion, billboard sprite placement flow, and material dock sprite mode).

v0.9.51 round complete ✓ — non-stretching texture layers & stamps on geometry resize, halo-free overwrite falloff:
- NON-STRETCHING / NON-SLIDING TEXTURE LAYERS (`PBMeshData.to_array_mesh`, `pb_splat_shader.gdshader`):
  - Root cause of painted layers stretching on geometry resize: `textures1` (the UV2 channel carrying
    splat mask coordinates) was only populated on `begin_stroke()` and was never recomputed when vertices
    moved during geometry editing/dragging. Moved vertices kept their stale normalized coordinates,
    causing the GPU to interpolate the mask across newly resized geometry.
  - `to_array_mesh()` now re-evaluates `PBSplat.ensure_mesh_uv2(self)` whenever splat data is present,
    computing vertex UV2 coordinates relative to the face's persistent `splat_bounds`.
  - Clamped out-of-bounds UV2 in `pb_splat_shader.gdshader`: fragments where `UV2 < 0.0 || UV2 > 1.0` evaluate
    to mask `0.0` rather than clamping to edge texels. Result: painted texture layers stay firmly at their
    exact object-space physical position and scale without stretching or sliding.
  - Unpainted faces do not prematurely set `face.splat_bounds`; `splat_bounds` locks on first paint.
- NON-STRETCHING / NON-SLIDING STAMPS & MESH-LOCAL CLIPPING (`PBSplat.compute_stamp_anchor`, `stamp_transform_from_anchor`, `PBMesh._refresh_stamps`, `pb_decal_shader.gdshader`):
  - Replaced the v0.9.50 stretch-on-resize behavior with physical object-space anchoring: stamps carry
    `anchor_u`, `anchor_v`, `anchor_scale_x`, and `anchor_scale_y`.
  - Resizing a face updates decal boundary clipping (`face_bounds` shader parameter) while the stamp quad
    maintains its exact physical dimensions (`stamp_scale`) and object-space position on the face plane.
    Stamps never stretch, shear, or slide when geometry is resized or extruded.
  - Root cause of stamp clipping staying at old world position when moving/raising an object in Object Mode:
    `pb_decal_shader.gdshader` previously used `mesh_to_world` (a static shader uniform storing the mesh's
    global_transform at creation) and multiplied `inverse(mesh_to_world) * world_pos`. When the object moved,
    the uniform was stale, causing clipping coordinates to drift in world space.
  - Replaced with `stamp_to_mesh` (the decal's local transform relative to `PBMesh`) and computed `face_uv`
    directly in `vertex()` in mesh-local space. Clipping is 100% mesh-local, zero matrix inverses in fragment(),
    and remains perfectly aligned when the object is translated, raised, rotated, or scaled in Object Mode.
- HALO-FREE REPLACE & OVERWRITE PAINT SEMANTICS (`PBSplat.paint_face_splat`):
  - Fixed empty halo around the brush: previously, `bytes[i] = target_b` forced fringe pixels to ~0
    over existing painted areas.
  - The brush now acts as an eraser towards brush opacity: if existing canvas opacity $P_{base} > O_{brush}$,
    it erases the excess down to $O_{brush}$ scaled by brush falloff $w$, leaving the fringe at $P_{base}$
    (no empty halo). Lower-opacity strokes can overwrite higher-opacity areas without using the eraser tool.
  - If $P_{base} \le O_{brush}$, it raises the pixel up to $\max(P_{base}, w \cdot O_{brush})$, preventing
    opacity accumulation when overlapping strokes at the same configured opacity.
  - Fast path for hard brushes (`softness <= 0.001`) and direct byte-LUT (`_get_brush_lut_bytes`) with integer
    math eliminates per-pixel float/Color boxing for lag-free painting on small faces.
- Tests: 773/773 GUT (+3), 42/42 real-editor GUI tests under Xvfb (asserting stamps/splats do not stretch and clipping moves with object).

v0.9.50 round complete ✓ — paint perf/semantics rework, face-anchored stamps, export-bake seam:
- PAINT HOT LOOP REWRITE (`PBSplat.paint_face_splat` byte-buffer + LUT + dab spacing):
  - Root cause of cube-face lag (measured: ~12ms/dab on a 2m face vs ~3ms on a 20m floor): a dab
    covers a much larger FRACTION of a small face's mask (256 texels/m uniform → 0.4m dab =
    ~200px footprint on a 512² mask), and the inner loop paid per-pixel `Image.get_pixel`/
    `set_pixel` Color boxing. The loop now walks the raw R8 `PackedByteArray` with a cached
    brush-falloff LUT indexed by SQUARED distance (no sqrt/cos/division per pixel;
    `_get_brush_lut(softness)` caches per quantized softness) plus incremental coordinate
    accumulation: ~40% faster per dab, and `PBPaintController` spaces dabs at 20% of the brush
    radius (`DAB_SPACING_FRACTION`) so high-rate mouse-motion events no longer re-walk the same
    footprint dozens of times per stroke.
  - Byte writes use `Image.get_data()`/`set_data()` around the loop; `ImageTexture.update()`
    still uploads in place, skipped entirely when a dab changed nothing.
- REPLACE-MODE PAINT SEMANTICS (per-stroke via `stroke_ctx` Dictionary the controller hands
  down, fresh per `begin_stroke`, keyed by mask image id + resolution):
  - Paint: within-stroke the pixel keeps the stroke's MAX target (fringe-then-center dabs still
    brighten); across strokes the stroke OVERWRITES absolutely — a 0.3-opacity stroke painted
    over a 1.0 area now REPLACES it to 0.3 (single-layer mental model).
  - Erase: subtracts `weight*opacity` EXACTLY ONCE per pixel per stroke — opacity is the real
    erase strength; slow re-tracing within one stroke no longer drains pixels to 0 regardless
    of opacity. Regression tests: test_paint_lower_opacity_stroke_overwrites_stronger_one,
    test_paint_within_stroke_keeps_max, test_erase_applies_opacity_once_per_stroke.
  - Minor intentional shift: the boundary pixel at exactly dist==radius with softness=0 no
    longer paints full-strength (hard brushes had a full-alpha rim ring).
- FACE-ANCHORED STAMPS (`PBSplat.compute_stamp_anchor` + `stamp_transform_from_anchor`,
  `PBMesh._refresh_stamps` called from rebuild()/rebuild_positions() — live during drags):
  - New stamps store a NORMALIZED face-planar anchor (`anchor_center` Vector2 + two normalized
    half-edge vectors `anchor_du`/`anchor_dv`, computed against CURRENT GEOMETRY bounds, NOT the
    persistent splat_bounds) plus the existing texture/opacity/scale/rotation metas. Put
    differently: stamps now GROW AND MOVE when the face is resized (uniform and non-uniform —
    the basis may shear; the unit quad + decal shader sample by UV so texture fill stays 1:1),
    and stay clipped to the live face bounds (`face_*` shader uniforms refreshed with the bounds).
  - Stamps are now UNIT QuadMesh (size 1x1) with the extent carried in the transform basis
    columns — required for shear-capable re-anchoring. Pre-0.9.50 stamps (QuadMesh(s,s), no
    anchor metas) are left untouched and simply don't track resizes.
  - GOTCHA pinned by the GUI harness: compute_stamp_anchor PROJECTION is only meaningful when
    the cursor hit is coherent (point+normal+face_idx from one face — true for real picks; the
    harness originally stamped a side face with an UP-cursor and the anchor correctly degenerated).
- DECAL CLIP BOUNDS now use geometry bounds (`get_face_planar_bounds(..., force_geometry=true)`)
  instead of persistent splat_bounds. SPLAT MASK policy unchanged: masks NEVER stretch — their
  normalized space is anchored to `face.splat_bounds`, persisted at first paint.
- EXPORT-BAKE SEAM (consumed by the future retro exporter, not yet built):
  - `PBSplat.collect_face_paint_state(mesh_data, face) -> Dictionary`: base texture path/color,
    per-layer {slot, texture path, color, roughness, mask Image}, baked stamp layer image, and the
    normalized planar bounds — the tile-baker needs nothing else. {} for unpainted faces.
  - `PBSplat.collect_stamp_data(mesh) -> Array`: one node-free record per anchored stamp:
    texture path, face_idx, normalized anchor (resolution-independent — re-rasterizable at any
    export tile size), opacity, scale, rotation.
  - Remaining future bake inputs already exist: UV2 masks are per-face R8 images at uniform
    texel density with persistent bounds, materials are per-face via PBMeshData slots, and
    stamps double their metadata for both visual decals and deterministic bakes.
- Tests: 770/770 GUT (+7), 42/42 real-editor GUI tests under Xvfb (+1 stamp-anchor tracking
  test that resizes a stamped face and asserts the decal extent doubles).

v0.9.49 round complete ✓ — replace-mode paint opacity, inspector textbox styling & face-bounds decal clipping:
- REPLACE-MODE PAINT ALPHA IN PBSplat (`core/pb_splat.gd`):
  - Fixed opacity not doing anything when dragging over the same spot: paint replaces layer contents with
    `target_a = weight * opacity` instead of accumulating endlessly (`cur_a + delta`), ensuring that multiple
    overlapping strokes of the same layer maintain the exact configured opacity (e.g. 0.4 stays 0.4).
  - Pixels already at or above `target_a` are skipped immediately, making painting over the same spot instant with zero lag.
- INSPECTOR TEXTBOX STYLING & FINE-GRAINED DRAG STEPS (`PBMaterialDock`):
  - Set `s.flat = false` on `EditorSpinSlider` so they render with the proper textbox borders, background,
    and styling matching the real Godot Inspector.
  - Tuned step increments for smooth dragging without massive jumps: 0.005 for opacity and softness, 0.01 for
    radius, scale, and tiling, and 1.0° for rotation angles.
- FACE BOUNDS CLIPPING FOR BILLBOARD DECALS (`pb_decal_shader.gdshader`, `pb_paint_controller.gd`):
  - Decal billboards are now shaded with `pb_decal_shader.gdshader` which automatically clips out-of-bounds
    fragments against the face's planar boundary (`if (u < min_u || u > max_u ...) discard;`).
  - Decals placed near edges or when geometry is resized cleanly end at the face boundary and never stick out into empty air.
- TESTS & VERIFICATION:
  - 763/763 GUT unit tests passing (13504 asserts).
  - 41/41 real editor GUI tests passing under Xvfb.

v0.9.48 round complete ✓ — native EditorSpinSlider, multi-layer splatting, persistent splat bounds & lag-free cube paint:
- NATIVE EditorSpinSlider CLICK-DRAG ADJUSTABLE CONTROLS (`PBMaterialDock`):
  - Replaced basic SpinBoxes with Godot's built-in `EditorSpinSlider` control (the same native control
    used by the Inspector and 3D editor panels), providing horizontal click-drag scrubbing with mouse
    wrapping, acceleration, and direct value typing.
  - Implemented `_make_spinbox()` which instantiates `EditorSpinSlider` in the live editor and falls back
    to `SpinBox` in headless test runs where `Engine.is_editor_hint()` is false, maintaining 100% test compatibility.
- MULTI-LAYER SPLATTING & DYNAMIC LAYER SWITCHING (`pb_paint_controller.gd`, `pb_material_dock.gd`):
  - Fixed single-texture overwrite bug: selecting a different texture in the palette now dynamically
    allocates or switches to its dedicated blend layer (Layer 1, Layer 2, Layer 3, etc.) on the splat material
    via `PBSplat.ensure_layer_for_texture()`. Each texture paints on its own independent blend layer.
- NON-STRETCHING SPLAT LAYERS ON GEOMETRY RESIZE (`PBFace.splat_bounds`, `core/pb_splat.gd`):
  - Fixed splatted layers stretching when moving vertices or resizing geometry: `face.splat_bounds` records
    persistent face planar coordinates on first paint. Resizing a face expands the geometry canvas without
    stretching existing painted splat layers.
- LAG-FREE CUBE PAINTING:
  - Isolated paint stroke execution to the target face under the cursor, eliminating the 6-face cross-painting
    loop on small cubes that caused stutter and face-overwriting.
- SDF SCREEN-SPACE ANTIALIASED SPLAT CONTOUR & UNIFORM 2048 RES (`pb_splat_shader.gdshader`, `core/pb_splat.gd`):
  - Raised MAX_RESOLUTION to 2048 and TEXELS_PER_METER to 256 for uniform resolution across all faces up to 16 meters.
  - Dynamically initializes layer 1 mask resolution from calculate_uniform_face_resolution() at material setup.
  - Replaced raw linear mask blending with screen-space antialiased smoothstep contour reconstruction centered at 0.5:
    `smoothstep(0.5 - edge_w, 0.5 + edge_w, m)` where `edge_w = mix(max(fw * 2.0, 0.02), 0.48, roughness)`.
  - Completely eliminates bilinear stairstep blocky pixels on large terrain floors and walls, rendering
    smooth, organic, antialiased stroke contours on faces of any size.
- OPTIMIZED STROKE PAINTING PERFORMANCE (`PBPaintController.apply_paint_stroke`):
  - Moved `PBSplat.ensure_mesh_uv2` to `begin_stroke()` so it executes once at drag start rather than
    redundantly on every mouse motion event.
  - Keeps stroke execution at sub-millisecond speeds (0.024ms per stroke, >40,000 strokes/sec).
- TESTS & VERIFICATION:
  - 763/763 GUT unit tests passing (13504 asserts).
  - 41/41 real editor GUI tests passing under Xvfb.

v0.9.47 round complete ✓ — billboard decal stamping, keybind removal & fast splat painting:
- BILLBOARD DECAL STAMPING ON PBMesh (`PBPaintController.apply_stamp`):
  - Replaced resolution-constrained mask baking with high-fidelity billboard decal quads (`MeshInstance3D`
    with `QuadMesh` and `StandardMaterial3D` with alpha and mipmapped linear filtering).
  - 100% native GPU texture resolution on any face of any size (zero blur, zero pixelation, uniform sharp
    rendering on small boxes and 100m terrain floors alike).
  - Attached under `target_mesh/PBStamps` container; transforms move with the mesh and are fully undoable.
  - Structured metadata stored per stamp node (`stamp_scale`, `stamp_rotation`, `stamp_opacity`,
    `stamp_texture_path`, `face_idx`) ready for tile-based baking during scene export.
  - Added "Clear All Stamps" button in `PBMaterialDock` with full undo/redo support.
- REMOVED ALL PAINT & STAMP KEYBINDS:
  - Removed all mouse wheel interception and keyboard shortcuts (`R`, `Shift+R`, `[`, `]`) from
    `poibuilder_plugin.gd` to eliminate all conflicts with Godot editor camera zoom, navigation, and engine tools.
  - Rotation and scaling are controlled cleanly through the UI buttons and spinboxes in `PBMaterialDock`.
  - Mouse wheel passes through untouched to 3D viewport camera zoom in all modes.
- RESTORED FAST SPLATTING MASK RESOLUTION (ZERO-LAG PAINTING):
  - Bounded splat masks to 256x256 (max 512) and optimized inner row pixel range in `PBSplat.paint_face_splat`.
  - Restored silky smooth 60+ FPS paint performance with zero stutter.
- TESTS & VERIFICATION:
  - 763/763 GUT unit tests passing (13504 asserts), including billboard decal creation and stamp clearing.
  - 41/41 real editor GUI tests passing under Xvfb.

v0.9.46 round complete ✓ — uniform resolution scaling, wheel release leak fix & stamp hotkeys:
- UNIFORM RESOLUTION PER METER ACROSS ALL FACES (`core/pb_splat.gd`):
  - Fixed resolution degradation on large faces: `calculate_uniform_face_resolution()` computes target
    mask and stamp resolution proportional to face physical meter dimensions (`TEXELS_PER_METER = 256`,
    power-of-two clamped between 256 and 2048).
  - A 10m floor receives 2048x2048 resolution with crisp, uniform 256 texels/meter density matching
    smaller faces without pixelation or stretching.
  - Dynamic layer resolution upscaling: `get_layer_mask_image()` and `get_stamp_layer_image()` dynamically
    resize existing images using bilinear interpolation if interacting with larger faces, preserving
    existing painted data while scaling up resolution.
- MOUSE WHEEL RELEASE LEAK FIX:
  - Fixed 3D camera zooming while scrolling wheel in Stamp mode: Godot emits mouse wheel events in press
    and release pairs (`pressed=true` and `pressed=false`); `poibuilder_plugin.gd` now consumes wheel
    events on BOTH press and release when modifier keys (Ctrl/Shift) are active, preventing the release
    event from passing into `Node3DEditorViewport` camera navigation.
- KEYBOARD SHORTCUTS & DOCK ADJUSTMENT BUTTONS:
  - Added `R` key to rotate stamp CW (+15°) and `Shift+R` to rotate CCW (-15°).
  - Added `[` key to scale stamp down (-10%) and `]` to scale stamp up (+10%).
  - Added quick `↺` / `↻` rotation and `-` / `+` scale buttons directly in `PBMaterialDock`.
- TESTS & VERIFICATION:
  - 763/763 GUT unit tests passing (13501 asserts), including tests for uniform resolution calculation,
    dynamic image resizing on large faces, and stamp keyboard shortcuts.
  - 41/41 real editor GUI tests passing under Xvfb.

v0.9.45 round complete ✓ — dedicated 1:1 stamp layer, preview texture fix & camera zoom passthrough:
- DEDICATED 1:1 STAMP LAYER ON TOP OF SPLATTING (`pb_splat_shader.gdshader`, `core/pb_splat.gd`):
  - Stamps are copied 1:1 onto a dedicated stamp layer (`stamp_layer_enabled`, `stamp_layer_texture`)
    sampled via UV2 on top of all splatting layers.
  - Full RGBA Porter-Duff alpha compositing (`PBSplat.stamp_face`): stamps preserve their exact
    original colors and sharp alpha edges without blurring, tiling distortion, or being constrained
    by the face's tiled base texture.
  - Deep cloning support in `clone_splat_material` ensures full undo/redo coverage for stamped layers.
- STAMP PREVIEW TEXTURE & CANONICAL WALL ROTATION FIX:
  - Fixed white square preview: `setup_previews()` and `_update_stamp_preview_texture()` now immediately
    bind `stamp_texture` to `stamp_mesh_instance.material_override.albedo_texture`.
  - Fixed vertical wall 90° rotation: implemented `PBSplat.get_stamp_basis()` which computes an orthonormal
    right-handed basis (+1.0 determinant) where `up` points straight UP (+Y) on any vertical wall/slope and
    away (-Z) on floors, and `right` points to viewer's right. Both `PBPaintController.update_cursor` and
    `PBSplat.stamp_face` share this exact basis, guaranteeing upright stamps at 0° and 1:1 preview alignment.
  - Fixed compressed image error (`Can't get_pixel() on compressed image, sorry` which painted black squares):
    `get_stamp_image()` and `stamp_face()` now check `img.is_compressed()` and call `img.decompress()`,
    ensuring clean RGBA8 access for all VRAM-compressed project textures.
- SHIFT+WHEEL ROTATION & CTRL+WHEEL SCALE:
  - Changed stamp rotation binding from plain mouse wheel to `Shift + Mouse Wheel` (15° steps).
  - `Ctrl + Mouse Wheel` scales stamp (10% increments).
  - Plain Mouse Wheel without modifiers passes through (`AFTER_GUI_INPUT_PASS`) directly to the 3D
    editor viewport camera zoom, completely resolving mouse wheel conflict.
- TESTS & VERIFICATION:
  - 760/760 GUT unit tests passing (13490 asserts), including tests for `get_stamp_basis()` upright vectors
    on all 4 wall orientations and VRAM texture auto-decompression.
  - Live editor GUI test harness passing with preview texture, Shift+Wheel rotation, Ctrl+Wheel scaling,
    and plain Wheel zoom passthrough assertions (41/41 passing).

v0.9.44 round complete ✓ — texture splatting (multi-layer alpha mask brush painting) & stamping mode:
- TEXTURE SPLATTING SHADER & MULTI-LAYER ENGINE (`PBSplat`, `core/pb_splat.gd`, `materials/shaders/pb_splat_shader.gdshader`):
  - Up to 8 splat layers blended over a face's base texture terrain-editor style.
  - Every additional layer follows the identical UV tiling as the base texture.
  - Normalized face-local planar coordinates (`UV2` / `textures1` channel on `PBMeshData`) map the alpha masks with continuous, artifact-free barycentric interpolation across arbitrary polygons and n-gons.
  - Highly optimized brush painting engine: computes exact 2D pixel bounding boxes in the mask image, applies cosine S-curve softness falloff in meters, and updates in-place via `ImageTexture.update()`. Zero lag, 60+ FPS painting performance.
  - Brush radius, softness, opacity, erase (subtract) mode, layer index selector (1-8), and layer clear controls.
- STAMP MODE WITH LIVE 3D PREVIEW, ROTATION, AND SCALING:
  - Select any texture/image from the palette or project (including transparent PNGs) and paste anywhere on geometry.
  - Live 3D surface decal preview oriented to face normals with zero z-fighting.
  - Mouse wheel in viewport rotates the stamp (15° increments); Ctrl + mouse wheel scales the stamp (10% increments).
  - Left click pastes the rotated and scaled stamp onto the mesh's splat layer mask.
- PLACEHOLDER TEST TEXTURES:
  - Added `res://addons/poibuilder/materials/textures/circular_square_pattern.png` (transparent PNG pattern).
  - Added `res://addons/poibuilder/materials/textures/tapestry.png` (rich ornamental decorative tapestry).
- UNIFIED PALETTE & DOCK INTEGRATION (`PBMaterialDock`, `gui/docks/pb_material_dock.gd`):
  - Segmented mode selector (`[Material & UV] [Texture Paint] [Stamp]`).
  - Shared materials and textures palette: card click routes dynamically (Material assignment / Paint brush texture / Stamp texture).
  - Automatic project image discovery (`.png`, `.jpg`, `.jpeg`, `.webp`).
  - Active paint brush (🖌) and stamp (⎘) indicator badges on palette cards.
  - Tool info panels embedded directly in the dock below the palette.
- FULL UNDO/REDO:
  - Deep cloning of splat materials and CPU mask images via `PBCommand.copy_mesh_data` and `PBSplat.clone_splat_material`.
- TESTS:
  - 14 new unit tests in `tests/test_pb_splat_and_stamp.gd` (758/758 GUT unit tests passing, 13458 asserts).
  - Extended GUI integration harness in `test_scenes/editor_gui_test.gd` (41/41 real editor GUI tests passing).

v0.9.43 round complete ✓ — knife tool & interactive n-gon shape extrusion:
- UNIFIED POLYGON DRAWING CONTROLLER (`PBNgonDrawer`, `editor/pb_ngon_drawer.gd`):
  - Common UX for Knife tool and N-gon shape extrusion:
    - Click on any surface (or grid) to place vertices.
    - Live visible overlay shows placed vertices connected by lines, with a line to the cursor and indicator point under mouse.
    - Click and drag placed vertices to reposition them along the surface plane.
    - Full multi-tier snapping: snaps to placed vertices, target mesh edges and vertices, and PBGrid.
    - Enter confirms/completes:
      - Knife: cuts the face (edge-to-edge cut splits face in two; closed loop cuts inner/outer n-gons).
      - N-Gon: transitions to HEIGHT phase to adjust 3rd dimension by moving mouse, LMB click confirms extrusion.
    - ESC cancels/aborts cleanly without leaving stray preview nodes.
- CORE FACE-CUTTING MATH (`PBMeshOps.cut_face`, `mesh_ops/pb_mesh_ops.gd`):
  - Splits a face by an edge-to-edge cut path into two clean `PBFace` n-gons with ear-clipped triangulation.
  - Closed-loop interior cut splices the hole into the outer perimeter via mutually visible bridge pairs (slit edges cancel out in `PBFace._cache_edges()`), producing two distinct selectable n-gon faces: the inner shape and the outer frame with hole.
  - Adjacent face edges sharing the cut points are automatically split to preserve a closed 2-manifold mesh without T-junctions.
  - Full undo/redo integration via `CmdMeshOp`.
- ARBITRARY N-GON EXTRUSION PRIMITIVES (`PBShapeComplex.create_ngon_prism`, `shapes/pb_shape_complex.gd`):
  - Generates 3D prisms from arbitrary 2D or 3D polygons with outward normals and watertight 2-manifold topology.
  - Both top and bottom caps are emitted as single merged n-gon `PBFace` instances; side walls are quad `PBFace` instances.
  - Registered `&"ngon"` in `PBShapeFactory` and `PBShapeParams`.
- TOOLBAR & UI INTEGRATION (`PBToolbar`, `PBActions`):
  - Added Knife tool button (`icon_knife.svg`) in the operations group and registered `op_knife` in `PBActions`.
  - Added N-Gon Extrude button (`icon_ngon.svg`) next to New Shape and added Ngon to New Shape dropdown.
- COMPREHENSIVE TESTS:
  - 10 new unit tests in `tests/test_pb_knife_and_ngon.gd` (738/738 GUT unit tests passing).
  - Extended GUI integration harness in `test_scenes/editor_gui_test.gd` (40/40 real editor GUI tests passing).

v0.9.42 round complete ✓ — persistent object-space texture anchor, seam-continuous extrude UVs, corner-anchored 45° diagonal tiling:
- PERSISTENT OBJECT-SPACE TEXTURE ANCHOR (`PBMeshData.texture_anchor`):
  - Faces previously anchored UVs to their own dynamic bounding box minimum (`min_u, min_v`),
    causing textures to slide whenever a face at the minimum corner was moved, and causing
    adjacent faces or extruded caps with different bounding boxes to have misaligned rotation centers.
  - `PBMeshData` now stores a persistent `texture_anchor: Vector3` (initialized at shape creation
    to the shape's initial bounding box minimum corner, cloned/restored across snapshots).
  - `calculate_face_uvs()` anchors UV coordinates relative to `u_axis.dot(texture_anchor)` and
    `v_axis.dot(texture_anchor)` in absolute object space.
  - Result: moving/resizing ANY face (including the face at that corner) never makes the texture slide;
    and coplanar seams (including extruded caps adjacent to untouched faces) share the exact same
    object-space anchor, perfectly aligning 45° diagonal tiling across seams.
- EXTRUDE SEAM-CONTINUOUS UV PROJECTION:
  - Extruded side bridge faces inherit UV properties (scale, rotation, flips, material slot)
    from the source face and use the persistent object-space `texture_anchor` directly.
  - Coplanar faces (such as an extruded front side quad adjacent to an existing front wall)
    share the identical planar basis and anchor, producing 100% continuous and matching UVs
    across the seam without artificial offsets or world-space flags.
  - Across 90° corners, vertical and horizontal tile rows wrap at the exact same elevation
    around the object with zero seam jump.
- CORNER-ANCHORED 45° DIAGONAL TILING:
  - Angled scaling and rotation are anchored to the face's reference corner `(0, 0)` in
    anchor space rather than `centroid`, keeping the texture firmly anchored consistently
    with non-angled tiling when any face edge is moved.

v0.9.41 round complete ✓ — auto UV management, texturing, material picker dock, and drag-and-drop:
- AUTO-UV PROJECTION & NON-STRETCHING HEURISTIC (`PBUv`, `core/pb_uv.gd`):
  - Default auto-calculated UVs project a uniform 1x1 meter repeat pattern in
    face plane coordinates.
  - Planar basis heuristic:
    - Walls and slopes (|N.y| < 0.9999): U = (Vector3.UP × N).normalized()
      (runs horizontally across the wall/slope, always pointing to viewer's
      right when facing it), V = (N × U).normalized() (points straight up the
      wall/slope).
    - Floors (N.y > 0): U = Vector3.RIGHT (+X), V = Vector3.BACK (+Z).
    - Ceilings (N.y < 0): U = Vector3.RIGHT (+X), V = Vector3.FORWARD (-Z).
  - Resizing faces never stretches textures: UV coordinates are reprojected from
    vertex 3D positions, keeping the texture uniformly tiled at the fixed meter repeat.
  - 45-degree diagonal button sets 1/sqrt(2) scale (~0.7071) and 45° rotation with
    clean alignment so triangulated quads cleanly map texture corners to vertices.
  - Quick scale `x2` / `/2`, manual U/V tiling, offset U/V, rotation angle,
    flips, and manual UV preservation.
- STOCK CHECKERBOARD TEXTURE & DEFAULT MATERIAL:
  - Added `res://addons/poibuilder/materials/textures/checkerboard_2x2.png`
    (soft dark gray #3c3f41 and #2c2e30 2x2 pattern).
  - Added `res://addons/poibuilder/materials/pb_default_material.tres`
    (`StandardMaterial3D` with linear mipmapped filtering, roughness 0.8, and
    `vertex_color_use_as_albedo = true` for face tinting).
  - New shapes created via `PBShapeParams` automatically get this default material
    assigned.
- MULTI-MATERIAL & FACE ASSIGNMENT (`PBMeshData`, `PBMesh`):
  - `materials: Array[Material] = []` on `PBMeshData`.
  - `get_face_material()`, `set_face_material()`, `set_faces_material()` with
    automatic submesh slot allocation, reuse, and compaction.
  - `to_array_mesh()` creates surfaces per submesh and sets materials via
    `mesh.surface_set_material(surface_idx, mat)` with default fallback.
  - `PBCommand.copy_mesh_data` and `restore_mesh_data` duplicate and restore
    `materials` array for undo/redo.
  - Face tinting via vertex color array.
- TOGGLEABLE MATERIAL & UV DOCK (`PBMaterialDock`, `gui/docks/pb_material_dock.gd`):
  - Docks to `DOCK_SLOT_RIGHT_UL` (to the right of the 3D viewport, to the left
    of the Inspector).
  - Starts closed/hidden to preserve viewport layout; toggleable from the
    PoiBuilder toolbar via new "Material" button (`icon_materials.svg`).
  - Material picker grid with thumbnail swatches, resource names, left-click to
    apply to selected face(s), right-click context menu ("Set as Default for New
    Shapes", "Apply to Selection", "Copy Path").
  - Default material badged with star indicator icon (★).
  - Synchronizes live with editor element selection changes.
- DRAG-AND-DROP MATERIAL ASSIGNMENT (`PBMaterialDropOverlay`, `gui/docks/pb_material_card_drag.gd`):
  - Drag a material from FileSystem or Material Dock onto a face -> face instantly
    gets that material.
  - If multiple faces selected and dragged onto one of the selected faces -> applies
    to the entire selection.
  - Dragging onto an unselected face targets only that face.
  - Full undo/redo integration with snapshot restoration.
  - Notification-driven mouse filter (`NOTIFICATION_DRAG_BEGIN` / `NOTIFICATION_DRAG_END`)
    ensures zero interference with normal viewport input.

v0.9.40 round complete ✓ — demo scratch project mouse capture & recapture:
- DEMO SCRATCH PROJECT MOUSE CAPTURE:
  Updated `scratch.sh` launcher and added `project/player.gd` + updated
  `project/main.tscn` with the complete 3D playground environment and character controller:
  - Captures the mouse by default on startup (`Input.mouse_mode = Input.MOUSE_MODE_CAPTURED`).
  - Pressing `ESC` releases the mouse (`Input.mouse_mode = Input.MOUSE_MODE_VISIBLE`).
  - Clicking inside the game window (`InputEventMouseButton` pressed) recaptures
    the mouse (`Input.mouse_mode = Input.MOUSE_MODE_CAPTURED`).
  - F5 in the editor or running `./scratch.sh` both boot the interactive playground
    directly with identical controls.

v0.9.39 round complete ✓ — root-cause fix for 3D viewport freeze (render_target_update_mode):
- ROOT CAUSE OF 3D SCENE FREEZE:
  In v0.9.38, `_redraw_viewport()` assigned `vp.render_target_update_mode = SubViewport.UPDATE_ONCE`
  to the editor's main 3D SubViewport. In Godot's C++ rendering pipeline (`viewport.cpp:5720`),
  after the rendering server renders that single frame, it automatically switches the viewport's
  update mode to `VIEWPORT_UPDATE_DISABLED`. This permanently halted continuous 3D rendering
  in the editor until an action (like toggling the grid) triggered another one-shot update.
- RESOLUTION:
  - Completely removed `_redraw_viewport()` and all assignments to `render_target_update_mode`.
  - `_enter_tree()` now self-heals and explicitly restores
    `vp.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE`.
  - Normal per-frame `_process()` updates `grid_view.update(cam)` and
    `RenderingServer.instance_set_transform` cleanly while the engine's viewport
    renders continuously as designed.

v0.9.38 round complete ✓ — concave extrusion face flip fix, live grid repeat viewport redraw:
- EXTRUSION FLIPPED FACES FIX (CONCAVE / STEPPED PROFILES):
  In `PBElementEditor`, the side quad live-flip check during `EXTRUDE_MOVE`
  previously computed `outward := wall_center - translated_center`. For concave
  or stepped profiles (stairs, notched shapes), lower steps sit below the
  centroid while their treads face UP (+Y), making the radial dot product
  negative and mistakenly inverting treads and risers inside-out.
  Fixed to use the exact ground truth outward direction:
  `seed_outward := e1.cross(_drag_extrude_normal)`. A side wall now flips if
  and only if `winding_n.dot(seed_outward) < 0.0` (i.e. when pushed back
  through zero), keeping all extruded walls facing outward on any profile.
- LIVE GRID REPEAT VIEWPORT REDRAW:
  While holding `]` or `[`, the mouse is stationary, so the idle editor
  viewport previously did not re-render between key repeats, making repeat
  elevation changes appear stalled until the next mouse motion.
  `_redraw_viewport()` now sets `vp.render_target_update_mode = SubViewport.UPDATE_ONCE`
  and queues container redraws on every repeat tick, rendering each elevation
  step live on screen. Echo repeats are also accepted during active shape creation.
- TESTS:
  Added `test_extrude_stair_side_never_flips_faces` in `tests/test_pb_mesh_ops.gd`
  confirming all 14 extrusion side quads maintain outward axial normals.
  704/704 GUT unit tests + GUI test harness passing.

v0.9.37 round complete ✓ — grid raise/lower key auto-repeat, merged stairs side faces:
- GRID ELEVATION AUTO-REPEAT:
  `PBActions.action_for()` and `poibuilder_plugin.gd` key forwarder now allow
  `key_event.echo` events specifically for `grid_raise` and `grid_lower`.
  Holding down `]` or `[` continuously raises or lowers the grid elevation
  step-by-step. All other actions continue to reject echo events.
- MERGED STAIRS SIDES (ONE FACE PER SIDE):
  `PBShapeComplex.create_stairs()` previously generated individual quads under
  each step. The left (-X) and right (+X) side walls are now generated as
  single continuous 2D profile polygons and ear-clipped via `_triangulate_2d`,
  emitting exactly one `PBFace` per side. Selecting either side in Face mode
  selects the entire side out of the box as a single face.
- TESTS:
  - `tests/test_pb_grid.gd`: asserts `grid_raise` and `grid_lower` match on echo
    while actions like `select_vertex` (H) reject echo.
  - `tests/test_pb_shapes_complex.gd`: asserts `create_stairs` with sides produces
    exactly 1 left face (normal -X) and 1 right face (normal +X).

v0.9.36 round complete ✓ — keybind layout matching, grid lifecycle per mode, surface picking default:
- KEYBIND MATCHING FIX (`[` and `]` without reassignment):
  `make_event(spec)` previously only set `ev.physical_keycode` while `ev.keycode`
  was `KEY_NONE`. On keyboards or layouts where incoming key events carry `keycode`
  or translate physical keys, Godot's `Shortcut::is_match` failed to match until
  the user manually reassigned the key in settings (which wrote `keycode`).
  `make_event` now initializes `keycode`, `physical_keycode`, and `key_label`.
  Additionally, `PBActions.action_for` falls back to `_match_default` whenever
  `settings.is_shortcut` misses.
- GRID LIFECYCLE & POIBUILDER-ONLY MODES:
  `_on_selection_changed()` previously only updated `editor.active_mesh` when a
  `PBMesh` was selected; selecting a non-PBMesh (or deselecting) left `editor.active_mesh`
  stale forever, causing PoiBuilder's grid to stay visible permanently.
  `_on_selection_changed` now unconditionally assigns `editor.active_mesh = pb_mesh`.
  The grid now only renders in PoiBuilder modes (PBMesh selected, shape creation
  armed, draw_on_grid on, elevated grid, or grid settings panel open); selecting
  a non-PoiBuilder node or deselecting cleanly restores Godot's stock grid.
  `_process()` also tracks `vp.find_world_3d().get_scenario()` and re-attaches
  whenever a new scene/scenario loads.
- SURFACE-DRAWING DEFAULT & COMPREHENSIVE PICKING:
  `draw_on_grid` was previously included in `GRID_SETTING_KEYS`, persisting as
  `true` into `EditorSettings` and permanently forcing grid-plane creation over
  surfaces. `draw_on_grid` is now session-only, forced to `false` on startup, and
  removed from persistent keys. `_pick_creation_surface()` and hover tracking
  now pick `PBMesh` faces, generic `MeshInstance3D` triangle meshes, and scene
  physics colliders, falling back to the grid plane only when no surface is hit.

v0.9.35 round complete ✓ — shortcut label naming & EditorSettingsDialog discoverability:
- ROOT CAUSE OF MISSING `grid_raise` IN SETTINGS:
  In Godot C++ (`editor_settings_dialog.cpp:712`), the Shortcuts dialog iterates
  shortcuts and does `if (!sc->has_meta("original")) { continue; }`, silently
  skipping any shortcut lacking the `"original"` metadata tag. If a shortcut
  existed in settings without `"original"` (e.g. from prior runs or unbinds),
  it was never shown. Furthermore, `_make_shortcut` never called `sc.set_name()`,
  so shortcuts were assigned internal slug names (`grid_raise`, `grid_lower`)
  rather than human-readable labels, causing searches for "Elevation" or "Raise"
  to miss.
- RESOLUTION:
  - `_make_shortcut(id)` now explicitly sets `sc.set_name(ACTIONS[id]["label"])`
    so shortcuts appear as `Grid: Raise Elevation`, `Grid: Lower Elevation`, etc.
  - `PBActions.register()` guarantees `sc.has_meta("original")` is always set
    and updates existing shortcuts with proper labels and default events.
- VERIFICATION:
  Unit test in `test_pb_grid.gd` asserts `grid_raise` and `grid_lower` have
  proper display labels and `"original"` metadata. GUI harness asserts both
  shortcuts are registered with labels and events in a live editor.

v0.9.34 round complete ✓ — grayish light-blue grid palette:
- GRID PALETTE TUNING: replaced punchy saturated cyan with a soft, neutral,
  grayish light-blue (`COLOR_MAJOR = Color(0.52, 0.68, 0.82, 0.55)`,
  `COLOR_MINOR = Color(0.46, 0.58, 0.70, 0.22)`).
- Distinct from active overlays: the subtle grayish light-blue keeps the cool
  custom look while avoiding visual competition with bright cyan drag/hover
  overlays (`Color(0.2, 0.9, 1.0)`) and yellow selections.
- Axis lines kept crisp: red X (`Color(0.90, 0.38, 0.38, 0.85)`) and
  blue Z (`Color(0.38, 0.56, 0.90, 0.85)`).
- Updated GUI harness assertions for the new palette.

v0.9.33 round complete ✓ — unbind conflicting stock Godot shortcuts (H, ], [),
user warning & editor toast notification:
- CONFLICTING STOCK SHORTCUTS: `H` collided with Godot's built-in
  `editor/toggle_selected_nodes_visibility`, causing `H` in the 3D editor to
  hide selected nodes instead of entering Vertex mode. `]` collided with
  `animation_editor/move_last_selected_key_to_cursor`, and `[` collided with
  `animation_editor/move_first_selected_key_to_cursor`. Furthermore,
  `PBActions.register()` previously skipped re-populating default events when
  a shortcut entry existed with empty events, leaving keys seemingly unbound.
- RESOLUTION (`PBActions.unbind_conflicts`):
  Automatically inspects `EditorSettings` shortcuts and filters out bare
  `KEY_H`, `KEY_BRACKETRIGHT`, and `KEY_BRACKETLEFT` events from stock
  shortcuts, leaving non-colliding events untouched. `register()` also ensures
  PoiBuilder actions with empty events are properly bound with defaults.
- USER WARNING & NOTIFICATION:
  Logs a clear warning via `logger.warn("actions", ...)` detailing the unbound
  stock shortcuts and keys, and presents an in-editor toast notification via
  `EditorInterface.get_editor_toaster().push_toast(...)` (SEVERITY_WARNING).
- TESTING:
  Added `test_unbind_conflicting_stock_shortcuts` in `tests/test_pb_grid.gd`
  asserting that stock `H`, `]`, and `[` shortcuts are unbound, non-conflicting
  shortcuts (Ctrl+S) remain untouched, and PoiBuilder actions register and
  match. 703/703 GUT unit tests + GUI test harness passing.

v0.9.32 round complete ✓ — procedural infinite horizon cyan grid via
RenderingServer, immediate arming, engine grid cull fix:
- PROCEDURAL INFINITE HORIZON GRID: the v0.9.31 gizmo-drawn line approach had
  critical defects: (1) `EditorNode3DGizmo.add_lines` discarded vertex colors
  and drew lines in pure white; (2) `minor_radius = step * 40.0` cut minor
  lines off at 8m and a power-of-two thinning loop doubled spacing so lines
  didn't match the snap step; (3) drawing through active node gizmos meant the
  grid was tied to node selection and couldn't arm immediately on New Shape;
  (4) `GIZMO_GRID_LAYER` bitmask in `pb_tool_bridge.gd` was using
  `1 << (25 - 1)` (bit 24 = MISC_TOOL_LAYER) instead of `1 << 25`, so the
  engine stock gray grid was never actually hidden and bled through.
- REPLACED BY SCENARIO-ATTACHED PROCEDURAL INFINITE GRID:
  `PBGridView` now owns a `RenderingServer` instance in the editor's
  `World3D.scenario`:
  - 4000m x 4000m plane following the camera on XZ at elevation `y = grid.origin.y`.
  - Spatial shader (`render_mode unshaded, blend_mix, depth_draw_always, cull_disabled, fog_disabled`):
    screen-space 1px anti-aliased line coverage via `fwidth(uv)`, smooth
    distance fading, and grazing-angle fading matching the stock Godot grid.
  - True Cyan palette: `COLOR_MAJOR` (bright crisp cyan `Color(0.45, 0.88, 1.0, 0.65)`),
    `COLOR_MINOR` (subtle cyan `Color(0.35, 0.78, 0.95, 0.25)`), crisp Red
    X-axis and Blue Z-axis stripes crossing at `grid.origin`.
  - Screen-space sub-pixel density fading for minor lines: when zooming out,
    minor lines smoothly dissolve to prevent moiré while major unit lines
    remain crisp.
  - Step fidelity: 100% 1:1 match to `grid.step()` (cell_size) and `grid.unit`
    (unit_size) with zero thinning or density jumps.
- ARMS IMMEDIATELY:
  Scenario attachment happens on plugin initialization (`_enter_tree()`).
  Visibility is driven directly by `grid_view.set_visible(wants)` in `_process()`,
  so the grid is visible the very instant "New Shape" is clicked, or upon
  selecting a PBMesh, or opening the Grid panel, before any mouse motion or click.
- ENGINE STOCK GRID HIDING FIXED:
  Bitmask corrected to `1 << GIZMO_GRID_LAYER` (`1 << 25`). While PoiBuilder's
  grid is shown, the engine's gray grid is cleanly culled; when inactive or
  deselecting, it restores.
- GUI HARNESS:
  Verified with `./run_gui_tests.sh` + pixel inspection: 44,233 cyan pixels
  in the viewport, immediate arming assertion, and smooth horizon fading
  confirmed.

v0.9.31 round complete ✓ — grid visual rewrite + panel + engine sync, from
the first sign-off of the 0.9.30 grid:
- GRID VISUALS: the 2D `_forward_3d_draw_over_viewport` line overlay
  degenerated at the horizon (finite patch + hairline 1px draw_line) and
  couldn't reach the sky properly. REPLACED by world-space gizmo drawing:
  PBGridView (editor/pb_grid_view.gd) caches a WORLD-space vertex-color line
  soup (majors + minors + X/Z axis stripes, cyan palette) and the active
  mesh's gizmo draws it (transformed to node-local) — node gizmos are the
  ONE render channel that reliably re-renders when content changes. The
  SubViewport-injected MeshInstance3D prototype died: visibility flips on
  injected nodes never re-render an idle editor viewport.
- FADE MODEL: subdivision lines draw only within a ProGrids-style local
  radius (~40 steps around the focus); major lines fade by SEGMENT-MIDPOINT
  distance (per-vertex radial fade zeroed every line — its endpoints always
  live at the patch rim).
- ENGINE GRID: hidden while ANY PoiBuilder context is active (element modes,
  object mode, an armed shape session). The View > Grid toggle is just the
  camera cull-mask bit 25 — SET IT DIRECTLY via `cam.cull_mask` (the
  `set_cull_mask_value` API silently rejects layers > 20). Restored on exit
  / deselect.
- GRID PANEL: toolbar inline widgets replaced by the "Grid" toggle button +
  one-line status readout ("0.2m ↕+0.4"); the overlay gained a GRID &
  SNAPPING section (open from the toolbar button): instant-apply controls
  (snap, draw-on-grid, show-grid, unit, subdivisions, rotate step, elevation
  ▲▼/spin) and a Reset button that restores stock defaults.
- OBJECT MODE follows our grid: while a PBMesh is selected in OBJECT mode
  the bridge writes our step/rotate-step into the engine's SNAP SETTINGS
  dialog spinners (structurally matched: ConfirmationDialog with exactly 3
  EditorSpinSliders) and confirms it — engine-side node drags then quantize
  to OUR values; on deselect they restore. Element modes keep our own layer
  (engine Use Snap stays force-off there — same as before).
- Grid keys ([ ] \ = - G Y ...) work in EVERY context including mid-creation
  — the dispatcher sits ABOVE the `is_editing` gate in the input forwarder
  (a regression during this round proved them otherwise gated).

v0.9.30 round complete ✓ — PoiBuilder's own grid & snapping system:
- PBGrid (editor/pb_grid.gd): the plugin's OWN grid, independent of Godot's.
  unit (1m major lines) / subdivisions (5) → snap step 0.2m; full 3D origin
  (origin.y = grid ELEVATION, moved by [ / ] in step increments; \ resets);
  draw_on_grid (new shapes draw on the grid plane at its elevation instead
  of the clicked surface — picking bypasses meshes entirely); show_grid.
  Persisted in EditorSettings under poibuilder/grid/* (elevation is
  session-only). All math is ProBuilder parity (ProBuilderSnapping.Snap):
  quantized to step·round(v/step), normal-masked press points on cardinal
  surfaces only.
- SNAP APPLICATION POINTS (single authority, all in PBElementEditor /
  PBShapeCreator): move drags snap the translation DELTA per world-space
  component (incremental/relative mode — selection-internal offsets are
  preserved and node rotation/scale-safe); ROTATE drags snap the angle to
  rotate_step (15°) with the rotation CENTER recovered from the unsnapped
  rel via the closed form c = ½·o⊥ + ½·cot(θ/2)·(axis × o⊥) (snapping the
  basis alone drifts the pivot); EXTRUDE caps snap their world distance
  along the normal (tangential passes through); SCALE/INSET unsnapped;
  creation press/extents/height snap. "Snap Selection To Grid" (registered
  action, unbound default) quantizes selected elements absolutely.
- PBActions (editor/pb_actions.gd): EVERY plugin keybind lives in one table
  and registers via EditorSettings.add_shortcut("poibuilder/...") — the same
  array the engine's ED_SHORTCUT macro feeds — so all actions appear under
  Editor Settings → Shortcuts and rebinds persist (add_shortcut keeps
  user-saved events across restarts). Defaults: H/J/K/X modes/space, Y =
  toggle our snapping (contextual: passes to the engine when no PBMesh is
  active), G = draw-on-grid, =/- subdivisions, Shift+=/- unit ×2/÷2, Alt+E
  extrude, Alt+I inset, remaining ops registered unbound (rebindable).
- ENGINE SNAP ISOLATION: the engine's own Use Snap quantizes the subgizmo
  drag DELIVERY (apply_transform) at its project step (default 1m) BEFORE
  our layer sees it — while editing, PBToolBridge holds the engine's Y
  toggle OFF and disabled (same pattern as the local-coords toggle).
  OBJECT-mode node drags still use the ENGINE's snap/grid (documented cut:
  the node gizmo's drag application is engine-opaque). IN v0.9.31 the bridge
  also syncs the engine snap VALUES (Snap Settings dialog spinners) while
  OBJECT mode is active — object drags follow our grid too; element editing
  and creation remain ours.
- Grid overlay drawing (SUPERSEDED by v0.9.31 — now a gizmo-drawn world line
  soup): the initial 2D `_forward_3d_draw_over_viewport` approach proved
  unfit (plugin leaves the "over" draw list when no object is edited, and
  hairline canvas lines degenerate at the horizon). Kept: grid keys work
  in EVERY context — mid-creation (never conflicting with LMB/ESC/ENTER)
  and with nothing selected.
- v0.9.30 also: Extrude became ONE action routed by mode (face extrude +
  edge fins share the toolbar button and Alt+E); the inline toolbar grid
  section shipped then moved into the overlay's grid panel in v0.9.31.

v0.9.21 round complete ✓ (nightly workflow, crisp wireframe/arrow, facing bias)
- NIGHTLY WORKFLOW: `gh release delete --cleanup-tag` deleted the local and
  remote tag, causing immediate `src refspec nightly does not match any` on
  the following push. Replaced by a single clean step: release delete without
  `--cleanup-tag`, local tag creation, force push, and release create.
- CRISP THICK WIREFRAME & ARROW: `_add_thick_lines` replaced the 5-parallel-line
  "wire comb" hack (which separated into fuzzy disconnected 1px wires when zoomed
  in) with solid unshaded crossed quads (double-sided triangles) plus a 1px center
  hardware line for guaranteed distance visibility. `_add_creation_arrow` replaced
  its 15 overlapping wire segments with a real solid triangular arrowhead and a
  solid 3D shaft with perpendicular fins, completely eliminating all fuzziness.
- CREATION FACING BIAS & DEADZONE: increased `FACING_DEAD_ZONE` (0.04m → 0.15m)
  and added `PBShapeParams.facing_prefers_shorter` dimension bias (doors naturally
  align parallel to the shorter dimension, stairs along the longer dimension).
  Near-square base dimensions apply hysteresis so the facing arrow never
  ping-pongs at the slightest mouse movement; deliberate lateral nudges (> deadzone)
  still allow manual 90° rotation.

v0.9.22 round complete ✓ (flat clean creation arrow, loosened bias & door tunnel nudging)
- ARROW MANGLING / EXTRA SPIKE: `_add_creation_arrow` had a perpendicular vertical
  triangle fin (`l_head_up`) on the arrowhead and a vertical quad on the shaft, which
  projected sideways at angles as an ugly sticking-out spike. Removed all vertical fins;
  the arrow is now a completely flat, crisp, solid 2D decal (solid triangular arrowhead +
  solid rectangular shaft) lying flush in the surface plane with clean 1px border outlines.
- LOOSENED BIAS & DOOR TUNNEL NUDGING (RETIRED in v0.9.79 — the rule could not
  tell an ordinary drag from a deliberate nudge for a shape that faces across
  its dominant extent, and it is what built the showcase's doorway as a slab;
  see the v0.9.79 entry): `FACING_DEAD_ZONE` tuned to 0.08m (8cm), and
  distinguished base rect establishment from post-creation nudging via `_has_initial_base`.
  Doors naturally default to doorway orientation (facing shorter wall thickness), but
  deliberately nudging across the arrow by > 0.08m rotates it into a tunnel (facing the
  longer dimension) and persists across subsequent frames without snapping back.

v0.9.29 round complete ✓ (curved-stairs ramp collider: TWO stacked defects, both
physics-reproduced headlessly — "stuck the moment I touch them"):
- INVERTED RAMP WINDING: the ramp wedge emission never got Godot's front-face
  reversal (the render mesh is CCW-from-outside and reversed in to_array_mesh;
  the collider bypassed that path and fed ConcavePolygonShape3D raw). With
  backface_collision=false (default), the wedge was passable from outside and
  solid from inside: walk into the outer wall, fall into the wedge, trapped.
  Fixed at emission; wedge is now built by the standalone
  PBShapeComplex.create_curved_stairs_ramp (the mesh generator no longer
  emits/stores ramp_faces metas).
- CREASE-CLIFF LOCK: even correctly wound, one quad per step makes a twisted
  helical strip whose two triangle halves differed by ~25 deg of local slope
  (27 deg vs 53 deg on the defaults — the steep facet is a WALL to
  floor_max_angle 45-50); a climber hit the first crease and the
  floor+wall contact pair locked its velocity to zero. The wedge is now
  tessellated 4 slices/step (crease angle falls with the square of slice
  arc). Verified by capsule climb: continuous ascent, never sinks.
- STALE-COLLIDER RULES: _update_collider RAMP path now ALWAYS regenerates
  from shape_params (never reads a stored ramp_faces meta — old scenes carry
  inward-wound ones) and falls back to a live trimesh when
  pb_mesh_data.shape_edited or params are absent (params describe the
  pristine primitive, not an edited mesh).
- PIE POLE HOLE: fanning the ramp to the axis left an unsealable vertical
  slit per spoke (one-sided faces cannot close it). Pie ramps now keep a 5cm
  pole hole — closed shell, walkably identical.
- DEBUG-INFRA (headless): debug/pb_collider_audit.gd — signed_volume (shell
  orientation), edge_pairing_report (closure + winding consistency),
  front_exterior_report (per-face inside/outside via GENERALIZED WINDING
  NUMBERS — ray probes are blind to wall inversion: a probe along the face's
  own normal from inside hits the wall's inward front. Sliver facets smaller
  than the probe epsilon are exempt by design: closure+consistency covers
  them). tests/test_pb_collider_audit.gd runs: winding+closure+concordance
  audits (drop rays from tread-derived probes), character containment
  (capsule pushed into the wedge must never end up under the ramp surface),
  character climb (must progress in angle and height, never sink), and
  variant sweeps (pie / flipped / no_sides — EACH IN ITS OWN TEST: multiple
  staircases in one physics space contaminate each other's raycasts).
  NOTE: there is no sound per-facet slope cap for tessellated helicoids
  (inner-chord facets structurally hit the inner-radius design slope);
  walkability locks via the character tests, not a slope assert.
- DEBUG-INFRA (visual): the show_collider overlay now draws the collider as
  an inspection skin — every collision triangle inflated 3cm along WELDED
  vertex normals (per-face inflation opens silhouette gaps that read as
  false positives), depth-tested, green on the face FRONT (the physics side)
  and RED on the back: green coat wrapping the mesh from outside = sound;
  red patch = that face collides on the wrong side. Depth-testing matters:
  an x-ray solid pass cannot tell an inverted face from the far side of a
  correct shell. Reading rules are documented on _draw_collider_debug.
  GUI harness covers it (green-present + red-ratio bounds; place test
  objects AWAY from the world origin — the viewport's red X origin-axis line
  pollutes naive pixel counts).
- Version bump convention applied (0.9.28 -> 0.9.29 in plugin, editor,
  plugin.cfg).

v0.9.80 round complete ✓ — showcase video review fixes, ear-clipped merged faces, combined bent n-gon, and stray sticker root cause:
- EAR-CLIPPED MERGED FACES (THE "merge coplanar faces" TEXTURE BUG):
  `merge_faces` previously fan-triangulated the boundary cycle from `dup[0]`.
  When boundary vertices were collinear (the middle vertices along an edge
  created by subdivide, loop cuts, or knife cuts), the fan formed 0-area
  degenerate triangles with (0,0,0) normals that corrupted vertex normals to
  (0,0,-1) and distorted texture projections on the merged face into diagonal
  stripes. Replaced with 2D ear clipping (`PBShapeComplex._triangulate_2d`),
  eliminating degenerate triangles and restoring a uniform square checkerboard.
- COMBINED CUBE+PRISM FOR BENT N-GON: `_merge_nonplanar` rebuilt around a single
  2-manifold house mesh (`ShowcaseUtil.create_house`). The beat enters vertex mode,
  moves the roof's front apex inward along Z to tilt the front gable triangle at a
  shallow angle, merges the triangle with the front quad across the crease, and
  showcases moving the resulting bent n-gon as one piece. `edl.toml` caption
  shortened to "Merge across a crease — one bent n-gon".
- ORANGE CUBE PRESERVED: in `_surfaces` (`create.gd`), the slope cube tint loop
  previously re-tinted all non-floor shapes, turning the wall cube green ("moss").
  Tracking `wall_shape` preserves the wall cube's "brick" tint so only the new
  slope cube is green.
- EMBEDDED EXPORT DIALOG VISIBLE ON SCREEN: `ConfirmationDialog` in Godot 4 was
  rendering as an OS-level X11 subwindow outside the root viewport framebuffer
  captured by `win.get_texture().get_image()`. Setting `win.gui_embed_subwindows = true`
  embeds dialogs inside the root viewport. `_export()` in `map.gd` displays Retro
  Engine settings and `.pbm` path, clicks Export, and `edl.toml` clip `67-map-export`
  starts at `at = 0.2, dur = 3.0` so the export window is clearly visible.
- STRAY WATERFALL STICKER ROOT CAUSE: `_paint()` left `paint_controller.mode` in
  `Mode.STAMP`. The subsequent click on the export OK button at (500, 494) passed
  through to the 3D viewport, where `_forward_3d_gui_input` intercepted it and
  stamped the active "HELLO WORLD" texture onto `FallWall` in the background.
  Fixed by exiting stamp mode at the end of `_paint()`, guarding `_forward_3d_gui_input`
  against stamping when dialogs are visible, resetting `mode = Mode.NONE` on export
  requests, and cleaning up any stray container.
- REGENERATED RETRO MAP ACT & TEASER: full `map` session re-rendered with fixed
  archway opening, waterfall sheets, painted path, particles, visible export window,
  and night lighting, eliminating the stray sticker and outdated geometry from
  `05-teaser-night`, `65-map-paint`, `66-map-particles`, `67-map-export`, and
  `68-map-night`.
- WALL/SLOPE DRAG TRANSITION: adjusted `11-create-wall` to `at = 5.0, dur = 2.1`
  and `12-create-slope` to `at = 7.1, dur = 2.3`, cutting before the cursor moves
  to the menu and eliminating the duplicate slope drag.
- Version bump 0.9.79 -> 0.9.80 (plugin, editor, plugin.cfg).

v0.9.79 round complete ✓ — the third review round. Four plugin bugs the film
exposed, the painted water's flow direction, and the beats rebuilt around them.
- MERGED FACES KEEP THEIR OWN UVs. `merge_faces` fan-triangulated the region on
  the REMOVED faces' positions, and those are not always free: a subdivision
  leaves its mid-point positions SHARED between the pieces either side of the
  cut, while UVs live in a per-position array that every rebuild re-projects. So
  the moment the merged n-gon MOVED, the next refresh wrote a neighbour's
  projection over the shared corners and the face went to diagonal stripes (the
  merge beat's report). The merged face now DUPLICATES every corner
  (`_dup_position` — the position-privacy invariant) and inherits the first
  source face's material slot and auto-UV settings; the op's weld rebuild
  re-connects the copies by coincidence, so it still drags as part of the mesh.
- DOORS AND ARCHES NEVER READ THEIR OWN DRAG AS A "NUDGE". The facing
  heuristic's lateral-nudge rule ("a step perpendicular to the facing re-points
  it", meant to rotate a door into a tunnel) cannot tell intent for a shape that
  faces ACROSS its dominant extent: the courtyard doorway's 4x1 m footprint
  flipped 90 degrees mid-drag, swapped width and depth, and — since the door
  clamps its frame legs to the width — closed the opening into a slab. That is
  the "the doorway faces the wrong way" report, twice. The base rect's ASPECT
  decides the facing now, full stop (the sign still follows the drag, Ctrl still
  locks it); `arch` joins `door` in facing across its dominant extent (its arc
  lies in the local XY plane, exactly like a door's opening) and both draw the
  facing arrow.
- ALT+CLICK IS THE EDGE LOOP, SHIFT+ALT+CLICK IS THE EDGE RING (ProBuilder's
  own gesture pair). The plugin had ONE gesture for both and it was the ring,
  which is why the loop cut beat's payoff deformed the whole cube: the ring of a
  cut edge runs over the top and under the bottom (6 edges on a mid-cut box),
  while the cut's own four edges are a genuine LOOP (their corners are the
  4-valence vertices the cut created). `PBTopology.get_edge_loop` already
  existed — the gestures now pick the right walk (`edge_loop_ids` /
  `edge_ring_ids`).
- A STAND-OFF PLANE'S IN-PLANE AXES COME FROM THE WORLD, NOT FROM THE DRAG.
  A plane's V axis is its texture's flow axis, and the placement basis used to
  take its in-plane orientation from the drag direction — so on a wall the
  sheet's V ran HORIZONTALLY (the waterfall flowed sideways) and on the floor
  the pool's ran across instead of away from the wall ("the scrolling textures
  flow the wrong way, possibly the placement orientation": it was). The rule is
  now fixed and world-aligned (`PBShapeParams.plane_flow_axis`): V DOWN on a
  wall or slope, +Z on a floor/ceiling — byte-for-byte the shipped map's own
  convention (`make_water_sheet` / `make_water_floor`), so a sheet built through
  the creation flow animates exactly like the one the device plays. The paint
  act's hand-built sheet was ALSO upside down (it stood the plane up with
  `rotation_degrees = (-90,0,0)`, leaving V up, so its negative speed climbed);
  it is +90 now.
- THE CURSOR OVERLAY WAS MAPPED BY A CALL SITE THAT HAD DROPPED THE CLIP'S BOX.
  `draw.make_mapper` learned `contain` + the `into` offset in the last round,
  but `overlay.render_frame` kept calling it with the crop and a full-frame
  cover box — so every letterboxed clip (all three paint clips, the toolbar cut,
  the HUD card) drew the pointer up to 124 px from where the editor's own brush
  ring sat ("the mouse is offset in the splatting clip"). The mapper now comes
  from `overlay.point_mapper(plan)`, built by `build.overlay_plan` — the same
  constructor the bake uses — and `cursor_check` calls that path, so the check
  can no longer pass while the renderer is wrong (verified: dropping the old
  call site back in makes the check report 114/124 px on the paint clips and
  0 on full-frame ones).
- SEGMENT STAMPS NOW HASH THE PIPELINE'S OWN SOURCE (draw/overlay/ffmpeg/edl):
  a stamp that cannot see a code change keeps the master on the old overlays
  until the files are deleted by hand — the same staleness the frame-signature
  fix closed for re-recorded takes.
- THE BEATS: loop cut orbits all four sides before selecting the loop its cut
  made and MOVING it (a ring move deformed the cube); knife extrudes the FAR
  half so the raised block does not stand between the lens and the cut; the
  merge-crease beat stands the prism on a PLINTH (the column elongates as the
  merged roof is dragged up, and the plinth is asserted not to move), slows the
  two slope clicks down and runs 9 s instead of 2.4; the inset beat drags the
  inset over 84 frames with a settle either side, so the ring is seen being
  made; the edge-ring beat uses the new shift+alt gesture.
- THE MAP ACT BUILDS THE SHIPPED MAP'S NUMBERS. Its off-grid pieces (waterfall
  wall 2.5..6.5, stairs -5.75..-3.25, east ramp) are drawn UNSNAPPED — the grid
  quantised a 4 m wall into 3.8 — and every water sheet's stand-off is placed
  CLOSED-LOOP: the plugin reads the pointer back along the surface normal, so
  `height_drag_to` now walks the pointer to the closed-form position for the
  target (a 6 cm stand-off is a couple of pixels at a beat's framing and the old
  pixel-step loop could not resolve it; the pool came back 0.00 and the sheets
  landed IN the wall — the striped z-fighting band across the wet stone). New
  checks: the core/pool/foam footprints against the map's own AABBs and a
  "floats clear of the floor" assertion.
- THE RENDER HARNESS NO LONGER INHERITS PLUGIN STATE BETWEEN RUNS. The editor
  home it reuses caches EditorSettings, and the plugin persists its grid
  settings there — so a beat that turns snapping off (the map act does, once per
  water sheet) left it off for the NEXT session, which is how the courtyard wall
  came out 3.8 m in one render and 4.0 m in the next, and why the toolbar read
  "Grid 0.2m (snap off)" on camera through every creation beat. Each session
  now starts from `ShowcaseUtil.fresh_grid`, and `_place` sets the grid state
  from the piece's own flag instead of inheriting whatever was left behind.
- Suite: 842/842.
- Version bump 0.9.78 -> 0.9.79 (plugin, editor, plugin.cfg).

v0.9.78 round complete ✓ — the showcase video reworked from the first
review, plus the plugin bugs the rework exposed. The video is BUILT FROM DATA
(`showcase_video/`): each beat below is a session script driving the real UI, and
every beat ends in a `check()` — a beat that silently does nothing fails its
render.
- THE MAP ACT IS THE SHIPPED MAP, BUILT BY GESTURE (`sessions/map.gd`). Every
  structural piece is drag-created at the footprint `TestMapShowcaseBuilder`
  puts it, with the builder's own materials (tiles / wet tiles / the water
  materials), and asserted against a `REAL` table of AABBs probed out of the
  shipped scene — so the courtyard the PSP act runs in is recognisably THIS
  scene. Samples from the render log: floor `(-6.0,-0.51,-6.0)..(6.0,0.0,6.0)`
  vs `(-6,-0.5,-6)..(6,0,6)`; archway `(-2,0,-6)..(2,4,-5)` exact; both pillars,
  the balcony, the ramp and the waterfall wall all within 0.1 m. The act has no
  bench: the courtyard IS the scene, the floor is drawn on the grid plane and
  the height drag goes DOWN so the walking surface lands at y = 0, and the grid
  is switched off the moment the slab exists (coplanar surfaces fight).
- BUILD ORDER IS PART OF THE CHOREOGRAPHY: the colonnade goes up BEFORE the
  terrace, because the balcony overhangs the pillars — once it exists, no
  camera reaches the floor under it (from above the drag lands on the balcony,
  from low down the stairs block the ray, and from low-and-oblique the floor
  rect collapses to a couple of pixels, which is how PillarB came out a 0.2 m
  needle floating over a step).
- PLUGIN BUG 1, the "zero-height floor": `apply_drag_extents` clamped the
  signed drag height (`maxf(0.1, height)`), so the courtyard floor dragged 0.5 m
  DOWNWARD became a 1 cm wafer inside the grid. The sign belongs to the
  PLACEMENT (`placement_transform` anchors the top face to the plane; the
  parameter is the magnitude) — now `maxf(0.1, absf(height))`, locked by
  `test_negative_height_keeps_the_dragged_magnitude`.
- PLUGIN BUG 2, the stamp preview: `_update_preview_material` cast the stamp
  overlay to StandardMaterial3D, but that preview wears the DECAL SHADER, so the
  cast was null and every stamp-opacity change threw ("Invalid assignment ...
  on a base object of type 'Nil'"). The tint is a shader parameter now.
- HARNESS FIXES worth keeping (`showcase_director.gd`): `height_drag_to()`
  closes the loop on the creation height stage (the height is
  `(ray ∩ view-parallel plane − press) · normal`, so gliding the pointer to
  `corner + normal * target` — what the beats used to do — never produced that
  height); `grid_show()`; `arm_shape()` now HIDES a leftover New Shape popup,
  because an open popup swallows every later drag (one stuck popup silently
  killed the ramp and the entire waterfall in a single run); and the create act
  PARKS its shapes instead of freeing them — freeing a node the creation flow
  made segfaults the editor (signal 11, no usable backtrace, at the beat
  handoff; parked nodes are renamed so they cannot be mistaken for a new shape).
- THE VIDEO (edl.toml, 124 s): the cold open is manipulation and map building
  (move, extrude, arch, waterfall, night) instead of shape orbits; the round
  shape's creation clip is gone; "drag on any surface" is three clips from one
  beat (floor → wall → sloped face, each growing along that surface's normal);
  the stairs' Edit Params beat doubles the step count (10 → 16) from a low side
  angle where every new tread lands; the move beat works a doorway (side quad,
  then the front n-gon with its arch hole moving as one face); detach moves the
  piece away; delete removes two faces and the camera looks into the hole;
  subdivide grabs the edge it created and drags it; merge moves the merged face
  as one and a second beat merges ACROSS a crease; inset lifts the new face out
  of its ring; the map act now includes the waterfall and a particles beat, and
  the hardware act carries PSP mist (day) and brazier-fire (night) clips.
- GEOMETRY BEATS WEAR A SOFT CHECKERBOARD (8 cells per metre, tinted to the
  beat's palette colour, `project/materials/textures/showcase_checker_soft.png`
  + `ShowcaseUtil.checker_mat`): a flat-shaded face hides exactly what the beats
  are about, and the tiling makes the auto-UV management visible.
- ALSO: the git history was rewritten to drop every regenerable artifact
  (~100 MB of video, map exports and PSP binaries; `.git` 119 MB → 5.7 MB) and
  the rule went into this file and `.pi/ORIENTATION.md`.
- Version bump 0.9.77 → 0.9.78. Suite: 836/836.

v0.9.77 round complete ✓ — the README video is built from data instead of
screen-recorded, plus two PSP-side fixes that fell out of watching it:
- THE PIPELINE (`showcase_video/`): a frame-stepped recorder drives a REAL
  editor under Xvfb and writes one PNG per rendered frame plus cursor/event
  sidecars; everything downstream (crop, captions, cursor, transitions,
  encoding) is Pillow + ffmpeg. Consequence: no dropped frames, and a beat can
  be re-cut or re-captioned without re-rendering the editor.
  * `./showcase_video/render.sh <session>` records the shot programs in
    `project/showcase/sessions/*.gd` through the API in
    `project/showcase/showcase_director.gd`. Each shot owns its directory
    (`bake/<session>/shots/<shot>/`), so re-recording one beat leaves the others
    alone; `PB_SHOWCASE_ONLY=a,b` re-records a subset in one editor boot (the
    earlier beats still run, unrecorded, so the state is identical).
  * `edl.toml` is the timeline; `./showcase_video/build.sh` bakes one segment
    per clip, concatenates the master, encodes the 960x540 README cut and
    verifies it (duration, black frames, frame size). `--list`, `--only`,
    `--clips-only`, `--preview`, `--verify`.
  * Self-contained toolchain: a `uv` venv, Inter (OFL) vendored under
    `showcase_video/fonts/`, ffmpeg resolved vendored -> `$SHOWCASE_FFMPEG` ->
    PATH. New footage is dropped into `showcase_video/source/` (the newest file
    there is used if the name does not match), so swapping the PSP clip needs no
    EDL edit — only the in/out points, which `sheet_clip.sh` helps pick.
- WHAT IT COST TO DRIVE THE EDITOR (each is written up where it lives):
  * `can_instantiate()` is false for a non-@tool script under
    `Engine.is_editor_hint()` — session scripts MUST be `@tool`.
  * A NEW `class_name` script is only resolvable after the editor's filesystem
    scan; `render.sh` warms the class cache with one headless boot first.
  * `@tool` + `:=` do not mix: a `:=` whose right side reaches into an untyped
    (`Object`/Variant) access is a parse error, not a warning.
  * A synthesized click on a toolbar button can be swallowed, and the plugin
    re-mirrors the ENGINE's subgizmo selection on every gizmo redraw — so an
    element selection written only into the plugin's mirror is wiped within a
    frame (every op then fails with "invalid selection" while the toolbar looks
    perfectly selected). `op()` snapshots the selection, VERIFIES the mesh
    changed, restores the snapshot in the SAME frame and drives the plugin's own
    entry point; `select_points()` likewise asserts a selection through the
    plugin's picker instead of assuming the clicks landed. Reproduction:
    `showcase/sessions/probe_ops.gd`.
  * Keyboard events go to the FOCUSED control: after a toolbar click, Enter went
    to the button and the knife's cut never completed. `key()` grabs focus back.
  * Wall-clock logic and a frame-stepped recorder disagree: the editor's 400 ms
    double-click test cannot be synthesized when a frame takes ~0.5 s, so the
    beats use alt+click for edge loops.
  * Framing is computed, never hand-placed: `framing()` projects the subject's
    AABB onto the camera's right/up axes and solves for the distance that fills
    a given fraction of the frame (`fill_scale` is the per-session taste knob).
    The AABB is taken through the node's GLOBAL transform, and objects are
    dropped onto the ground from their own bounds, because the shape generators
    disagree about whether their origin is the base or the centre.
- FIVE RECORDED SESSIONS (create / edit / shapes / paint / map, ~20 beats
  total) drive the real UI — toolbar buttons, the New Shape menu, drag-creation,
  the params modal including the arched toggle, the material dock, the paint
  controller, the export dialog. Every beat ends in a `check()`: a beat that
  silently does nothing fails the render instead of shipping.
- TWO PSP FIXES THE VIDEO FOUND (both real bugs):
  * HUD: `Select` now toggles a COMPACT hud (frame rate + the cpu/gpu profiler
    only — what a capture wants), and the Textured/Lighting/Wireframe cycle
    moved to `L+Select`. Input is edge-detected now; the old code acted on the
    held state, so every button repeated while held. The hint lines were
    rewritten to fit the 60-glyph budget (a longer line silently loses its tail
    on the 480 px screen).
  * The courtyard's wildflowers were authored UNSHADED, which in this pipeline
    means "pure white, ignore the baked lighting" — at dusk/night they stayed
    bright while everything around them went dark. They are lit now, and the map
    carries a soft shadowless `FoliageFill` in front of the billboard cluster: a
    billboard is a flat quad whose normal faces +Z, so the bake only ever sees
    its front, and with no light on the viewer's side the foliage goes black in
    the presets that have no strong sun.
- `run_psp_hw.sh --preset <dawn|day|dusk|night>` (bare word also accepted) runs
  or DEPLOYS a preset: the .pbm plus a `poi_preset.txt` are staged on host0:,
  which is exactly what a Memory Stick install needs. App mode used to wait for
  the profiler's output file, which the interactive app never writes — it
  reported a wedge that had not happened, three times, and gave up.
- Version bump 0.9.76 -> 0.9.77.

Backlog lives in the README's roadmap (human-facing). The showcase video now
budgets for a fresh capture: the editor acts are recorded from source
(`showcase_video/render.sh`), the handheld footage is dropped into
`showcase_video/source/` and re-cut in `edl.toml`, and `./showcase_video/
build.sh` rebuilds the master, the README cut and the poster in a few minutes.
The next scheduled piece of work is a **courtyard walkthrough with the real
device in frame** (the current handheld clip was shot before the lit-foliage and
compact-HUD changes).

v0.9.82 round complete ✓ — Session 1: 2D UV Editor Panel Base (canvas, navigation, grid, texture underlay, wireframe, selection sync & bottom dock):
- DEDICATED 2D UV EDITOR PANEL (`PBUvEditorPanel` in `editor/uv/pb_uv_editor_panel.gd`):
  * Added to Godot's bottom panel dock via `add_control_to_bottom_panel(uv_editor_panel, "UV Editor")`.
  * Top toolbar with modes (Face, Vertex, Edge, Island), channel selector (UV1/UV2), framing buttons (`[0,1]` and `⛶ Frame`), snap toggle and step selection (1/32 to 1.0), texture underlay controls (texture toggle, repeat tile toggle, opacity slider), selection status readout, and a pop-out floating window button (`Window` popup centered).
  * Toolbar button "UV" added to the persistent toolbar (`PBToolbar`) next to Material button to quickly open/focus the bottom panel.
- INTERACTIVE 2D UV CANVAS (`PBUvCanvas` in `editor/uv/pb_uv_canvas.gd`):
  * 2D control with cursor-anchored mouse wheel zoom (`MIN_ZOOM = 20.0`, `MAX_ZOOM = 10000.0`, `DEFAULT_ZOOM = 350.0`) and middle-mouse or Space+LMB drag panning.
  * Invertible, exact coordinate space conversions between normalized UV space $[0, 1]$ and local canvas pixel coordinates (`uv_to_screen`, `screen_to_uv`).
  * Dark slate background (`Color(0.12, 0.13, 0.16)`), adaptive grid lines adapting to zoom and snap step, $[0, 1]$ unit square border line with corner coordinate labels.
  * Material texture underlay from active mesh's material with repeat tiling toggle and adjustable opacity.
  * UV wireframe drawing: unselected faces/edges (subtle cyan/white), selected faces/edges (bright yellow), hovered elements (cyan).
  * Point picking with distance threshold, rubber-band marquee drag selection with Shift-toggle support, and UV island detection (double-click).
- BIDIRECTIONAL SELECTION SYNCHRONIZATION:
  * Selecting a face in the 3D viewport immediately reflects onto the 2D UV canvas (`sync_selection_from_3d`).
  * Selecting faces in the 2D UV editor synchronizes back to `editor.selection` in the 3D scene.
- TESTS & VERIFICATION:
  * 859/859 GUT unit tests passing (+8 tests in `test_pb_uv_editor.gd`).
  * Real editor GUI test harness passing with 0 failures under Xvfb (`run_gui_tests.sh`).
- Version bump 0.9.81 -> 0.9.82 (poibuilder_plugin.gd, pb_editor.gd, plugin.cfg).

v0.9.83 round complete ✓ — Session 2: UV Editor Operations, 2D Transform Gizmo, Snapping, Seams & Projections:
- CORE UV OPERATIONS LIBRARY (`PBUvOps` in `editor/uv/pb_uv_ops.gd`):
  * Mode conversion: `convert_to_manual` (freezes coordinates into `textures0`, sets `manual_uv = true`), `convert_to_auto` (restores dynamic projection), and `get_uv_mode` (`"Auto"`, `"Manual"`, `"Mixed"`, `"NoSelection"`).
  * 2D Transformations: `translate_uvs` (delta translation with automatic manual mode conversion), `rotate_uvs` (rotation around arbitrary pivot by degrees), `scale_uvs` (per-axis or uniform scaling around pivot), `flip_uvs` (horizontal and vertical reflection across selection center), and `rotate_90` (90° CW/CCW).
  * Projections: `fit_uvs` (normalizes selection bounds into $[0, 1]$ unit square), `planar_project` (planar projection along average face normal, lower-left aligned to $(0, 0)$), and `box_project` (independent dominant cardinal axis projection per face).
  * Seams & Topology: `sew_uvs` (welds proximate coincident 3D vertices in UV space within configurable distance), `split_uvs` (separates coincident UV coordinates with displacement offset), `collapse_uvs` (collapses all selected UVs to geometric centroid), and `auto_stitch` (aligns and welds matching UV edges of adjacent 3D faces with scaling, rotation, and translation).
  * Utilities: `sample_texel_density` and `normalize_texel_density` (calculates 3D area vs 2D UV area and scales UVs to match target pixels-per-meter), and `export_uv_template` (renders UV wireframe directly to an `Image` with Bresenham line rasterization and exports to PNG).
- 2D TRANSFORM GIZMO (`PBUvGizmo` in `editor/uv/pb_uv_gizmo.gd`):
  * Interactive 2D viewport transform gizmo with Move, Rotate, and Scale tool modes:
    - Move: Center free-2D handle square, horizontal U-axis red arrow, vertical V-axis green arrow.
    - Rotate: Circular dial with angle tracking indicator and 15° detent angle snapping.
    - Scale: Center uniform scale box, U-axis scale box, V-axis scale box with Shift-uniform override.
  * Full grid snapping and proximity snapping support.
  * Integrated directly into `PBUvCanvas`: draws at the selection pivot, hit-tests on mouse down, applies live interactive dragging with 60 FPS real-time ArrayMesh rebuild updates in the 3D viewport, and commits undo actions via `CmdMeshOp` on release.
  * Keyboard hotkeys in canvas: `W` (Move), `E` (Rotate), `R` (Scale).
- OPERATIONS TOOLBAR & PANEL UI (`PBUvEditorPanel` in `editor/uv/pb_uv_editor_panel.gd`):
  * Tool buttons on top toolbar: `Move (W)`, `Rotate (E)`, `Scale (R)`.
  * Dedicated secondary operations toolbar row (`_ops_toolbar`):
    - Mode Conversion: `[Auto]` / `[Manual]`
    - Projections: `[Planar]` / `[Box]` / `[Fit]`
    - Quick Transforms: `[Flip U]` / `[Flip V]` / `[↶ 90°]` / `[↷ 90°]`
    - Seams: `[Sew]` / `[Split]` / `[Collapse]` / `[Stitch]`
    - Texel Density: `[Get]` / `SpinBox` (px/m) / `[Set]`
    - Export: `[Export PNG]`
  * Robust Undo/Redo integration: every operation wrapped in `CmdMeshOp` with full snapshot swap and 3D scene rebuild.
- TESTS & VERIFICATION:
  * 872/872 GUT unit tests passing (+13 tests in `test_pb_uv_ops.gd`, 16,210 total asserts).
  * Real editor GUI test harness passing with 0 failures under Xvfb (`run_gui_tests.sh`), covering toolbar, tool switching, and operation execution.
- Version bump 0.9.82 -> 0.9.83 across `poibuilder_plugin.gd`, `pb_editor.gd`, and `plugin.cfg`.

v0.9.84 round complete ✓ — UV gizmo undo reset, selection mode isolation & SVG icon buttons:
- GIZMO UNDO PIVOT RESET & MESH SIGNAL:
  * Added `signal mesh_rebuilt` to `PBMesh` emitted on `rebuild()` and `rebuild_positions()`.
  * `PBUvCanvas` connects to `active_mesh.mesh_rebuilt` and automatically refreshes UV coordinates and recalculates `gizmo.pivot_uv` whenever geometry or UV snapshots are restored.
  * `PBUvEditorPanel` connects to `EditorUndoRedoManager.version_changed`, ensuring canvas refreshes immediately when Undo (`Ctrl+Z`) or Redo (`Ctrl+Y`) is triggered.
  * `_update_gizmo_pivot()` explicitly branches on `select_mode`: single vertex selection pins `gizmo.pivot_uv` directly to `uvs[v_idx]`, so undoing a vertex translation immediately returns the gizmo to the original vertex coordinate with zero offset drift.
- SELECTION MODE ISOLATION & LOOP PREVENTION:
  * Root cause of vertex selection appearing broken after selecting a 3D face: (1) `sync_selection_from_3d()` previously populated `selected_faces` and left it filled when switching to vertex mode, causing `_draw()` to keep the entire face highlighted in bright yellow so individual vertex picks were visually masked; (2) `_on_canvas_selection_changed()` unconditionally synced `canvas.selected_faces` to the 3D scene, triggering an engine deselect/re-sync loop that immediately wiped the 2D vertex pick.
  * Fixed in `PBUvCanvas`: `select_mode` setter now calls `_convert_selection_to_mode()`, clearing `selected_faces` when switching to vertex or edge mode.
  * `_handle_left_press()` clears disjoint mode selections on element clicks (e.g. vertex picks clear `selected_faces` and `selected_edges`), ensuring only the clicked vertex is highlighted.
  * `_on_canvas_selection_changed()` only syncs face selections back to the 3D scene when `canvas.select_mode` is `FACE` or `ISLAND`, completely isolating vertex and edge UV picking from 3D face selection feedback loops.
- 23 CRISP 16x16 SVG ICONS ACROSS THE UV PANEL:
  * Authored 23 clean SVG icons (`viewBox="0 0 16 16"`, `#e0e0e0` stroke/fill) in `addons/poibuilder/icons/`: Move, Rotate, Scale, Face, Vertex, Edge, Island, Frame Unit `[0,1]`, Frame Sel `⛶`, Snap, Texture Underlay, Tile, Pop-out Window, Auto UV, Manual UV, Planar, Box, Fit, Flip H, Flip V, Rot CCW, Rot CW, Sew, Split, Collapse, Stitch, Texel Get, Texel Set, and Export PNG.
  * Replaced clunky text buttons in `PBUvEditorPanel` with compact, flat icon buttons (`_create_icon_btn`), retaining rich descriptive tooltips.
- TESTS & VERIFICATION:
  * 875/875 GUT unit tests passing (+3 regression tests in `test_pb_uv_ops.gd`, 16,257 total asserts).
  * Real editor GUI test harness passing with 0 failures under Xvfb (`run_gui_tests.sh`).
- Version bump 0.9.83 -> 0.9.84 across `poibuilder_plugin.gd`, `pb_editor.gd`, and `plugin.cfg`.

v0.9.85 round complete ✓ — Bidirectional 3D/2D Selection Synchronization & Stitched Coincident Vertex Welding:
- BIDIRECTIONAL 3D/2D SELECTION SYNCHRONIZATION:
  * Selecting a vertex in the UV canvas immediately switches the 3D editor to `VERTEX` mode, updates `editor.selection.set_vertices()`, highlights the corresponding vertex dot in bright yellow in the 3D viewport, and attaches the 3D transform gizmo to it via `plugin.select_subgizmo_element()`.
  * Selecting an edge in the UV canvas switches the 3D editor to `EDGE` mode, selects and highlights the 3D edge in yellow, and sets the 3D subgizmo selection.
  * Selecting a face in the UV canvas switches the 3D editor to `FACE` mode and highlights the 3D face.
  * Symmetrically, selecting a vertex, edge, or face in the 3D viewport immediately synchronizes to the UV canvas via `sync_selection_from_3d_state()`, highlights the element in yellow in 2D, and centers the 2D transform gizmo on it.
  * Bidirectional feedback loops are prevented via explicit re-entrancy protection (`_syncing_selection` guards in both directions).
- STITCHED / SEWN VERTEX JOINING:
  * Root cause of stitched faces appearing "unjoined" when moving vertices: `_handle_left_press` in `SelectMode.VERTEX` only picked one face's vertex index, ignoring coincident vertices of stitched/sewn neighbors sharing that exact UV position and 3D corner.
  * Implemented `get_coincident_uv_vertices()` and `get_coincident_uv_edges()` in `PBUvCanvas`: selecting a vertex or edge on a stitched boundary selects all coincident vertices/edges sharing that UV coordinate and 3D position.
  * Moving a stitched vertex or edge with the 2D transform gizmo now moves all coincident corners in lockstep, keeping stitched faces completely joined without seam tearing.
  * `PBUvOps.rebuild_shared_textures()` is automatically invoked by `sew_uvs()` and `auto_stitch()`, updating `mesh_data.shared_textures` groups and invalidating lookup caches.
- TESTS & VERIFICATION:
  * 877/877 GUT unit tests passing (+2 regression tests in `test_pb_uv_ops.gd`, 16,269 total asserts).
  * Real editor GUI test harness passing with 0 failures under Xvfb (`run_gui_tests.sh`).
- Version bump 0.9.84 -> 0.9.85 across `poibuilder_plugin.gd`, `pb_editor.gd`, and `plugin.cfg`.

v0.9.86 round complete ✓ — 3D/2D Mode Feedback Loop Fix & Stitched Face Coincident Movement:
- 3D/2D SELECTION MODE SYNC & FEEDBACK LOOP ELIMINATION:
  * Root cause of 3D mode switch leaving UV editor in vertex mode and deselecting on click: (1) `poibuilder_plugin.gd`'s `_sync_uv_editor_selection()` did not check `uv_editor_panel._syncing_selection`, so 2D mode changes triggered 3D mode changes that fired `_on_select_mode_changed()`, which wiped the 2D selection and left the gizmo detached; (2) `PBUvEditorPanel`'s mode button states (`_btn_mode_*`) were not updated when `canvas.select_mode` changed, leaving the Vertex button visually toggled on so clicking it again was ignored by Godot's `ButtonGroup`.
  * Added `_syncing_selection` early return in `poibuilder_plugin.gd._sync_uv_editor_selection()`.
  * Added `signal select_mode_changed(mode: SelectMode)` to `PBUvCanvas`, connected to `PBUvEditorPanel._on_canvas_select_mode_changed()`, automatically updating `_btn_mode_*.button_pressed = true`.
  * `sync_selection_from_3d_state()` now updates `_btn_mode_*.button_pressed = true` and expands selected faces to the full UV island when `canvas.select_mode == ISLAND`.
- STITCHED FACES COINCIDENT MOVEMENT:
  * Root cause of stitched faces separating when moved in Face mode: `get_selected_vertex_indices()` previously only returned the selected face's 4 vertices, omitting the coincident vertices of adjacent faces sewn/stitched to that shared edge.
  * Updated `PBUvCanvas.get_selected_vertex_indices()` across all modes (Vertex, Edge, Face, Island) to expand all vertex indices through `get_coincident_uv_vertices()`. Moving a face or element with sewn edges now moves all coincident vertices in lockstep, keeping stitched seams completely joined.
- TESTS & VERIFICATION:
  * 877/877 GUT unit tests passing (16,269 total asserts).
  * Real editor GUI test harness passing with 0 failures under Xvfb (`run_gui_tests.sh`).
- Version bump 0.9.85 -> 0.9.86 across `poibuilder_plugin.gd`, `pb_editor.gd`, and `plugin.cfg`.

v0.9.87 round complete ✓ — UV Mode Persistence, 3-Row Compact Toolbar, Unfold/Unwrap & Template Layout Bounds:
- SELECTION MODE PERSISTENCE ON CLICK-OFF:
  * Root cause of clicking off in vertex mode reverting to face mode: when vertex mode was activated in the UV editor, the 3D editor's `select_mode` remained in `FACE` mode. On deselecting in 2D, the 3D editor synced its `FACE` mode back to the UV editor.
  * Updated `_create_mode_btn()` and `_on_canvas_select_mode_changed()`: switching mode in the UV editor immediately updates `editor.select_mode` in the 3D editor (Vertex, Edge, Face) with `_syncing_selection` protection. Clicking off in vertex mode now stays firmly in vertex mode with `_btn_mode_vert` visually pressed.
- 3-ROW BALANCED UV PANEL TOOLBAR (Fits 1080p Docks):
  * Split the overcrowded toolbar into 3 clean, balanced horizontal rows (each < 550px wide, eliminating horizontal stretching and dock clipping):
    - Row 1: Tools (Move, Rotate, Scale), Modes (Face, Vertex, Edge, Island), Framing (`[0,1]`, `[Frame]`), Channel selector, Status readout, Pop-out Window.
    - Row 2: Snapping (`[Snap]`, step dropdown), Texture underlay (`[Texture]`, `[Tile]`), Opacity slider, Texel Density (`Texel:`, `[Get]`, `_spin_texel`, `[Set]`).
    - Row 3: UV Mode (`[Auto]`, `[Manual]`), Projections (`[Planar]`, `[Box]`, `[Fit]`, `[Unwrap]`), Transforms (`[Flip U]`, `[Flip V]`, `[↶ 90°]`, `[↷ 90°]`), Seams (`[Sew]`, `[Split]`, `[Collapse]`, `[Stitch]`), Export (`[Export PNG]`).
  * Doubled `_spin_texel` minimum width from 90px to 180px (`custom_minimum_size = Vector2(180, 24)`).
- NON-OVERLAPPING UNWRAP & TEMPLATE LAYOUT BOUNDS:
  * Root cause of exported template showing "a square with a few lines": (1) pristine cubes and box projections map all 6 faces to $[0, 1] \times [0, 1]$ directly overlapping; (2) `export_uv_template()` hardcoded pixel mapping to $[0, 1]$, discarding any faces or islands moved outside unit square.
  * Implemented `PBUvOps.unwrap_box()` and `[Unwrap]` button (`icon_uv_unwrap.svg`): unfolds 6-sided boxes/cubes into a canonical non-overlapping cross layout in $[0, 1]$, and packs arbitrary meshes into clean non-overlapping grid layouts.
  * Updated `PBUvOps.export_uv_template()`: dynamically measures the bounding box of all UV islands; if any islands extend outside $[0, 1]$, it maps the entire layout into the image with 3% padding so zero lines or islands are ever clipped away.
- TESTS & VERIFICATION:
  * 881/881 GUT unit tests passing (+4 regression tests in `test_pb_uv_ops.gd`, 16,331 total asserts).
  * Real editor GUI test harness passing with 0 failures under Xvfb (`run_gui_tests.sh`).
- Version bump 0.9.86 -> 0.9.87 across `poibuilder_plugin.gd`, `pb_editor.gd`, and `plugin.cfg`.

v0.9.88 round complete ✓ — Stock Cube Bowtie Seam Fix, UV Island 3D Selection Sync, & In-Scene 3D Viewport Texture Tool ("Material Mode" 6):
- STOCK CUBE PINCHED BOWTIE FIX (UNSEWN CORNER COINCIDENCE ELIMINATED):
  * Root cause of 3 faces joined by 1 vertex on a stock cube: `get_coincident_uv_vertices()` and `rebuild_shared_textures()` previously treated any vertices sharing identical 3D position and UV coordinates as "sewn", even when their adjacent edges had completely different UV coordinates and `mesh_data.shared_textures` was empty. On a stock cube, corner (-0.5, -0.5, -0.5) has UV (0, 0) on Front, Left, and Bottom by coincidence of independent planar projections; moving one face dragged that corner from the other two faces, stretching them into a 3-face non-manifold bowtie pinch.
  * Fixed in `PBUvCanvas.get_coincident_uv_vertices()` and `PBUvOps.rebuild_shared_textures()`: two vertices are now coincident/sewn if and only if they belong to `mesh_data.shared_textures` OR share a full sewn edge (both 3D endpoints coincident in both 3D and UV space). Single isolated corner coincidences are never welded or grouped.
  * `_get_uv_island()` now traverses faces connected by shared sewn edges in UV space (rather than single vertex coordinates), so the 6 faces on a stock cube are 6 independent UV islands.
- UV ISLAND 3D VIEW SELECTION SYNCHRONIZATION:
  * Root cause of island selection only showing 1 face in 3D: Godot's engine subgizmo API (`set_subgizmo_selection`) is single-ID. When selecting an island with multiple faces, `select_subgizmo_element(active_mesh, packed[0])` caused `mirror_engine_selection()` to overwrite `editor.selection.selected_faces` down to 1 face, and `_draw_selected_faces()` only drew the single subgizmo.
  * Implemented `selected_face_groups: Dictionary` (seed -> all face IDs) and `expand_face_ids()` in `PBElementEditor` (matching the proven `selected_loops` architecture for edges).
  * `PBUvEditorPanel._on_canvas_selection_changed()` sets the face group; `_draw_selected_faces()` draws the full expanded face group in bright yellow; `mirror_engine_selection()` preserves all faces in `editor.selection.selected_faces`; and `element_indices()` moves all faces together when dragged with the 3D gizmo.
- IN-SCENE 3D VIEWPORT TEXTURE TOOL ("MATERIAL MODE" 6 / ProBuilder TextureTool parity):
  * Added `SelectMode.TEXTURE` to `PBEditor.SelectMode`, hotkey `6` (`KEY_6`) registered in `PBActions`, and a dedicated mode button in `PBToolbar` (`icon_texture_mode.svg`).
  * Planar gizmo directly on the face surface aligned to face tangent plane (X=U, Y=V, Z=Normal):
    - Move tool (W): slides texture along U and V (1:1 lockstep with cursor).
    - Rotate tool (E): turns texture around face normal with 15° snap detents (or relative to `grid.rotate_step`).
    - Scale tool (R): stretches U and V, or center-handle scales uniformly.
  * Auto-bakes auto-UV faces to manual mode on drag start with zero visual jump (`PBUvOps._ensure_faces_manual()`).
  * Full Undo/Redo integration (`CmdMeshOp` / "Transform Texture UVs" compatible with both `EditorUndoRedoManager` and `UndoRedo`).
- TESTS & VERIFICATION:
  * 884/884 GUT unit tests passing (+3 regression tests in `test_pb_uv_ops.gd`, 16,358 total asserts).
  * Real editor GUI test harness passing with 0 failures under Xvfb (`run_gui_tests.sh`), including new Section 15 verifying Texture Mode button and mode switching in live editor.
- Version bump 0.9.87 -> 0.9.88 across `poibuilder_plugin.gd`, `pb_editor.gd`, and `plugin.cfg`.

v0.9.89 round complete ✓ — Session 4: Core Modeling — Bevel & Chamfer (edge & face beveling, multi-segment fillets, watertight corner capping, and toolbar integration):
- CORE BEVEL OPERATION (`PBMeshOps.bevel_edges`):
  * Flat chamfer (`segments = 1`) and multi-segment circular arc fillets (`segments = 2..8`).
  * Inward perpendicular edge shifting in face plane ($\vec{u} = \vec{n}_F \times \vec{t}$), corner linear intersection solving, and distance clamping against shortest incident edge.
  * Generates $S$ bridge quads along each beveled edge with exact circular arc tangent interpolation (`_arc_interp`).
  * Automated corner junction resolution: chains directed bridge and cut segments into closed cycles (`_chain_segments_into_cycles`) and caps corner holes with outward-oriented polygon faces (`_build_bevel_polygon_face`).
  * Preserves position-privacy invariant via `_dup_position_at` and topology repair via `_rebuild_topology` (orphan compaction + weld groups rebuilt from 3D coincidence).
- FACE-MODE PERIMETER BEVELING:
  * Added `PBMeshOps.face_perimeter_common_edge_ids`: extracts perimeter boundary edges of the given face region and resolves them to common edge IDs.
  * Selecting faces and clicking Bevel automatically bevels their perimeter edges into chamfered boundaries.
- TOOLBAR & ACTION INTEGRATION:
  * Added Bevel button to `PBToolbar` (`icon_bevel.svg`) in Row 1 next to Inset and Extrude, enabled for both edge and face selections.
  * Registered `op_bevel` action in `PBActions` (`Ctrl+B`, `KEY_B` + Ctrl) mapped to `bevel_edges`.
  * Added `OP_ACTION_NAMES["bevel_edges"] = "Bevel Edges"`, session defaults (`OP_BEVEL_AMOUNT = 0.2`, `OP_BEVEL_SEGMENTS = 1`), and undo/redo handling in `poibuilder_plugin.gd`.
  * Upgraded `CmdMeshOp.add_to_undo_manager` to support both native `UndoRedo` (using `Callable`) and `EditorUndoRedoManager` (`object, method`), ensuring seamless undo/redo across test runners and editor.
- TESTS & VERIFICATION:
  * 894/894 GUT unit tests passing (+10 comprehensive tests in `test_pb_bevel.gd`, 16,411 total asserts).
  * Real editor GUI test harness passing with 0 failures under Xvfb (`run_gui_tests.sh`), asserting toolbar Bevel button existence, enabling on face selection, and live bevel operation execution.
- Version bump 0.9.88 -> 0.9.89 across `poibuilder_plugin.gd`, `pb_editor.gd`, and `plugin.cfg`.

v0.9.90 round complete ✓ — Bevel fillet arc endpoint convergence & corner cap watertightness:
- FILLET ARC ENDPOINT ALIGNMENT (`PBMeshOps._arc_interp` radius interpolation):
  * Root cause of disconnected bevel strips, open boundary seams, and skybox bleed through bevel edges with `segments >= 2`: at mitered corners (e.g. around an inward extruded cavity or stepped profile), adjacent faces retract with different shift vectors (diagonal on the front frame vs orthogonal on the cavity side walls), so the endpoints $p_0$ and $p_1$ are at different distances from the arc center ($|v_0| \ne |v_1|$).
  * `_arc_interp` previously rotated $v_0$ by `angle * t` preserving vector length $|v_0|$, which undershot $p_1$ by $(|v_1| - |v_0|)$ (e.g. ~4cm at default settings). At $t = 1.0$, the fillet quad ended at distance $|v_0|$ instead of reaching $p_1$, creating an open gap/slit of usage=1 edges across all 4 edges of the opening where sky/background bled through and Godot's backface culling made faces appear flipped/missing.
  * Linearly interpolating the radius along the arc (`radius = (1.0 - t) * l0 + t * l1; return center + (v_rot / l0) * radius`) guarantees exact mathematical convergence to $p_1$ at $t = 1.0$, seamlessly welding the multi-segment fillet quads to the retracted cavity walls across all segment counts (1..8).
- CORNER TERMINATION CAPS & SHARED EDGE ENDPOINTS:
  * Root cause of disconnected vertices, open triangular voids, and slit cuts when beveling subsets of edges (e.g. ring or single rim edges): `bevel_edges` only added corner segments when `vertex_beveled_count >= 2`, completely skipping corner capping when a beveled edge terminates at an un-beveled junction (`vertex_beveled_count == 1`). Furthermore, un-beveled faces touching the corner computed local shift offsets that disagreed with the beveled faces' rail endpoints.
  * Pre-sorted face execution with `shared_edge_endpoints` so un-beveled faces look up the exact endpoints established by beveled neighbors.
  * Recorded bridge and cut segments universally and added `_cancel_opposite_segments()`: cancelling opposite shared segments leaves only the true outer boundary of corner junctions, cleanly chaining into closed cycles and constructing watertight corner caps across both mitered and terminating corners.
- TESTS & VERIFICATION:
  * Added `test_bevel_inset_inward_extrusion_outer_edges` and `test_bevel_inset_inward_extrusion_single_rim_edge` in `tests/test_pb_bevel.gd` covering 4-edge loop, single rim edge, and ring beveling across segments 1, 2, 3, 4, confirming 100% watertightness (0 bad edges) and valid compiled conventions.
  * Extended GUI test harness in `project/test_scenes/editor_gui_test.gd` asserting watertight beveling on extruded cavity rims in live editor under Xvfb.
  * 902/902 GUT unit tests passing, 54/54 GUI harness assertions passing with 0 failures.
v0.9.91 round complete ✓ — Shared miter rails across meeting bevel bridges (corner fillet alignment & welding):
- MITER CORNER RAIL SHARING ACROSS BEVEL BRIDGES:
  * Root cause of disconnected and misaligned vertices when beveling edges meeting at a miter (e.g. outer edge loop of an inset face, or perimeter edge loops): when two beveled edges meet at a corner sharing a face, both edges' bridge end rails connect the exact same two 3D endpoints (`P_outer` along the un-beveled outer seam, and `P_inner` on the shared face). However, `bevel_edges` previously computed the intermediate rail fillet points independently for each bridge using that bridge's own incident face normals (e.g. `n_top` vs `n_right`). Because the normals differed, one bridge curved in Y-Z while the other curved in X-Z, producing differing intermediate 3D coordinates along the corner (e.g. `(0.959, 0.996, 0.941)` vs `(0.996, 0.959, 0.941)`).
  * Consequently, `_cancel_opposite_segments` could not cancel the mismatched segments, and `_chain_segments_into_cycles` created degenerate 6-gon slit faces across the gaps. The vertices of the two meeting bevel bridges landed in separate weld groups, so moving a vertex tore the mesh open and revealed that the two bevel strips were not connected and not aligned.
  * Solution: Precompute corner rails across all beveled edges meeting at a common vertex `c`. When two edges share a miter (matching endpoint pair `{r0, r1}` within tolerance), they share the exact same miter rail computed with the combined/averaged surface normals at `r0` and `r1`.
  * Result: Both bridges generate identical intermediate coordinates along the miter, opposite segments cancel out cleanly to zero in `_cancel_opposite_segments`, no degenerate corner cap polygons are created (face count drops from 30 to 26), and coincident vertices weld into shared groups so moving a corner vertex moves all 4 coincident positions in lockstep with zero tearing.
- TESTS & VERIFICATION:
  * Added `test_reproduce_user_bevel_outer_edge_loop` in `tests/test_pb_bevel.gd`: insets and inward extrudes a cube face, bevels the outer perimeter edge loop with `segments = 3`, verifies 26 faces (0 degenerate caps), confirms miter vertices weld into 4-position groups, and moves the miter vertex with `CmdMoveElements` asserting 100% watertightness and lockstep motion.
  * Extended GUI test harness in `project/test_scenes/editor_gui_test.gd` with `BEVEL-OUTER-LOOP-SEG3` test passing in live editor under Xvfb.
  * 903/903 GUT tests passing (+1), 55/55 GUI harness assertions passing with 0 failures.
- Version bump 0.9.90 -> 0.9.91 across `poibuilder_plugin.gd`, `pb_editor.gd`, and `plugin.cfg`.

v0.9.92 round complete ✓ — THE BEVEL REWRITTEN (the reported "inset, inward extrude,
then bevel the outer edge loop" corner that was "not connected and not even aligned"
across four previous rounds):
- WHAT WAS ACTUALLY WRONG (two independent defects, both structural):
  * The corner formula was off by cos(45 deg). At a corner whose two edges are
    both beveled, the old code moved the corner `amount` along the DIAGONAL
    (`normalize(u_prev + u_next) * amount`), i.e. only `amount * cos(45 deg)`
    perpendicular to each edge, while the neighbouring face's corner (whose
    other edge is not beveled) moved a full `amount`. The two faces of one
    beveled edge therefore disagreed about how far the edge had moved — the
    mismatch in the report. Now every boundary line is offset by exactly
    `amount` (the miter intersection of the two offset lines).
  * Rails and corner caps were RECONSTRUCTED from geometry: per-face rail
    endpoints fished out of a dictionary whose miss value was `Vector3.ZERO`,
    corner caps rebuilt by cancelling and re-chaining straight segments within a
    0.5 mm tolerance. Anything that did not match to tolerance left a slit, and
    because position welding only merges EXACT coincidence the result still
    passed the watertight assertions ("not connected").
- THE REWRITE (`mesh_ops/pb_bevel.gd`, class `PBMeshBevel`; `PBMeshOps.bevel_edges`
  delegates). One shared POINT REGISTRY: every point the op creates exists once
  as a record — a face corner's offset chain, a point a neighbour's offset placed
  on a shared edge (coincident placements on the same edge reuse one record), a
  bridge rail — and each face takes its OWN position copy of the records it uses.
  The position-privacy invariant is preserved (flat normals are written per
  position), and the weld rebuild reconnects the copies, which is what makes
  dragging, moving and selecting coherent. Per beveled vertex the surface is: a
  CHAIN per face (miter point when both of the face's edges move — the fillet's
  corner sphere touches the face exactly there, so chamfers and fillets share it
  — the offset line's intersection with the other edge when one moves, the
  vertex's neighbouring edge points when neither does), a RAIL per beveled edge
  end (the fillet's end ring for segments >= 2; fillet ring ENDPOINTS are
  inserted as boundary points for case-B corners, which is what removes the old
  retraced sliver caps), and a CAP closing the ring, triangulated as a centroid
  FAN (ear-clipping a curved corner patch emitted triangles whose normals opposed
  each other, which flat shading turns into dark facets).
- SELF-CHECK + RETRY (the robustness guarantee): after a build the op verifies
  that every seam that was fine before is still fine (used twice, opposite
  directions), failing the attempt and retrying at half the distance, then
  reporting. The distance clamp is the old `shortest incident edge * 0.38`; the
  retry is what handles faces whose own offset lines would cross (a bevel wider
  than the face is not representable — it now shrinks instead of shipping
  non-manifold junk). Failure rolls the mesh back through a `PBCommand` snapshot,
  so a refused bevel leaves the mesh byte-identical.
- CORNER PATCHES ARE THE BANDS TURNING THE CORNER (the follow-up report: the
  first rewrite closed the corners but did it with one many-sided fan face
  stuck between the bands — "just makes ugly n-gons for the corners", next to
  UniBuilder's strips). Where two beveled edges meet, the patch is now built
  from the two rails the way the bands are built: rows of quads bridging them
  (paired corner-relative — both rails start at the point they share, which is
  the face the two bands have in common; pairing them by the ring's own walk
  order twists the quads when the rails run head to tail), collapsing to a
  triangle at a seam end, plus one leftover face closing the corner region
  between the rails' far ends and the faces' own cut-back corner path. Rails
  that are the same point set (the bands meeting in a ridge — a cube's
  chamfered top rim) bound nothing and add no face at all. A 1-segment chamfer
  therefore still has NO corner face (2 rails that are one segment), a 3-segment
  fillet has 3 strip faces + 1 small corner face per corner, and no corner face
  has more than four vertices — `test_bevel_corners_are_quads_not_fans` pins
  that (several faces per corner, each a quad or triangle, for segments 2-4).
- ALSO: `bevel_faces` (FACE mode) validated its faces only AFTER marking them
  removed — a hole face would have been dropped from the mesh; it now validates
  first and reports a collapsed inset instead of silently skipping a face.
- VERIFIED: a 288-case sweep (cube sizes 1/2 m x inset 0.1-0.3 x extrude depth
  0.2/0.5 x amount 0.05-0.3 x segments 1-3 x outer/inner rim selection) — zero
  failures, zero open or non-manifold edges, zero inverted or degenerate faces,
  and TORN=0: moving EVERY weld group leaves the mesh intact, which is the
  reported symptom expressed as a check. `tests/test_pb_bevel.gd` grew the
  user-scenario regression (4 outer rim edges x segments 1-4, watertight + no
  inverted faces + no tearing group), the uniform-offset assertion, and an
  every-ring-edge case (12 edges, 3 beveled edges meeting at each corner).
  906/906 GUT tests passing (16.5k asserts), GUI harness green including the
  live editor bevel checks; `test_pb_bevel_sweep_all_shapes_stay_closed` keeps
  the 288-case sweep in the suite (~9 s).
- Version bump 0.9.91 -> 0.9.93 across `poibuilder_plugin.gd`, `pb_editor.gd`,
  and `plugin.cfg`.

v0.9.94 round complete ✓ — bevel loop corners are duplicated edge loops, not n-gons:
- THE REPORT: cube → inset a face → extrude inward → bevel the extruded loop at
  3 segments produced leftover n-gons at the corners (and a previous attempt
  left verts unaligned/unconnected). UniBuilder does the simple thing: duplicate
  the loop S times and connect matching verts, with a straight subdivided rail
  through each corner.
- CAUSE: multi-segment rails were circular arcs through each edge's own dihedral,
  so the two edges of a loop corner missed each other; extra "fillet end" points
  then split the corner and `_corner_patch` filled the gap with an n-gon.
- FIX (`pb_bevel.gd`): valence-2 corners (a closed loop) share one STRAIGHT rail
  of S segments, keyed by the endpoints so both strips reference the same
  records; no corner cap. Valence-1 terminations still cap; valence-3+ cube
  corners still cap (all-12-edge face counts unchanged).
- LOCK: inset+extrude outer/inner rim, segments 1–4 → `14 + 4*S` faces, all
  quads/tris, collinear `S+1`-point rail at each cube corner, watertight, no
  tearing weld group. 908/908 GUT.
- Version bump 0.9.93 -> 0.9.94.

v0.9.95 round complete ✓ — multi-segment bevel is a rounded cylindrical fillet:
- THE REPORT: v0.9.94's shared straight rail was connected but looked like a
  subdivided 1-segment chamfer. S > 1 must round the profile.
- FIX: each edge's rail is `_arc_interp` in that edge's dihedral (cached by
  endpoints + normals). A loop corner's two arcs are bridged by a quad/tri
  grid; the leftover n-gon is gone. S=1 still 18 quads; S=3 outer loop is 38
  faces, all ≤4 verts, profile bulges off the chamfer chord, watertight.
- Version bump 0.9.94 -> 0.9.95.

v0.9.96 round complete ✓ — multi-edge bevel actually runs; terminal n-gons split:
- THE REPORT: selecting more than one edge (loop/shift) made Bevel a no-op;
  a single edge still left an n-gon where it met the unbeveled edges.
- CAUSE: clicking the toolbar emptied the engine subgizmo selection, and
  `mirror_engine_selection` wiped `selected_edges` / `selected_loops` before
  the op ran. Terminations were one n-gon cap (ProBuilder tent / our `_fan_face`).
- FIX: do not wipe element selection on empty engine ids; edge ops use
  `_edge_ids_for_op` (expand loops). Blender `bevel_build_trifan`: perimeters
  with >4 sides become separate triangles (`_simple_faces`).
- Version bump 0.9.95 -> 0.9.96.

v0.9.97 round complete ✓ — single-edge bevel keeps original faces as n-gons:
- THE REPORT: beveling one cube edge fanned the top into triangles and grew
  extra corner junk (11 faces). ProBuilder / Blender: 1 bridge quad, 2 adjacent
  faces stay quads, 2 end faces become pentagons (7 faces).
- CAUSE: extra fillet-end points in the adjacent-face chains plus `_simple_faces`
  trifan on those faces, plus a valence-1 cap that split the termination.
- FIX: no extra fillet-end points; terminal (3-face, 1-bevel) end faces absorb
  the rail as one n-gon (`_should_absorb_face`); rebuilt faces keyed by original
  index so `_replace_faces` keeps in-place slots. Cube S=1 → 7 faces / 2
  pentagons; S=3 → 9 faces / 2 heptagons. Watertight.
- Version bump 0.9.96 -> 0.9.97.

v0.9.98 round complete ✓ — bevel distance matches the request; loop corners stay flat:
- THE REPORT: 0.1 looked like ~0.02, 0.11 looked right, 0.12 tiny again;
  inset+inward-extrude inner loop failed with 8 folded seams; outer loop
  fillet had a bump at the cube corner.
- CAUSE: (1) 0.38×shortest-incident clamp plus 0.45×radial cap turned 0.1
  into ~0.06 on an inset ring, then half-retry ping-ponged tiny/proper
  sizes; (2) plugin also mutated `op_bevel_amount` from shortest selected
  edge; (3) S>1 rails at valence-2 corners were cylindrical in different
  dihedrals, so the ruled patch bowed toward the original vertex.
- FIX: remaining-room clamp (0.49× if both ends beveled, 0.95× if one);
  no silent half-retry; modal min=0 / step=0.01; valence-2 rails lerp the
  chamfer chord. Inner loop 0.1 is 0.1 wide; 0.10/0.11/0.12 track the
  request; loop S>1 is 14+4S faces, no corner bump.
- Version bump 0.9.97 -> 0.9.98.



v0.9.99 round complete ✓ — bridge, connect, collapse, fill hole:
- New topology ops in PBMeshOps: bridge edge pairs into face strips, connect
  (edges → splitting verts; verts → new edges), collapse elements (per-mode),
  fill hole from boundary edges; toolbar buttons + keys wired through the op
  pipeline; undo via whole-mesh snapshots.

v0.9.100–v0.9.102 (v0.9.100–102 "selection conversion", REVERTED):
- A first selection-conversion implementation forced single-element engine
  selections without expanding the mirrors/drag unions (only 1 vert stayed
  selected; undo moved 1 vert) and added a parallel
  `selection_origin`/`selection_basis` gizmo-orientation layer duplicating
  behavior the engine already had — breaking extrude direction and multi-
  select pivots. Fully discarded via `git reset` (kept from those sessions:
  the bridge/extrude winding fixes and the bevel stale-selection fix, which
  landed anew in v0.9.103/104). The redesign contract is documented in
  `.pi/orientation/selection.md`.

v0.9.103 round complete ✓ — pristine reset + bridge/hole-extrude winding:
- Reset to the pre-conversion state; `bridge_edges` now strictly obeys the
  2-manifold half-edge invariant; `extrude_edges` keeps hole-edge winding.

v0.9.104 round complete ✓ — bevel commit clears stale selection:
- Bevel commit no longer restores pre-op edge ids (that selected an edge
  BEHIND the bevel); selection is cleared on commit.

v0.9.105 round complete ✓ — mode-switch selection conversion, done sanely:
- THE FEATURE (third attempt; the reverted v0.9.100–102 taught the shape):
  switching element modes now CONVERTS the selection, ProBuilder parity —
  face → its 4 verts / 4 edges, verts → the faces they fully cover / the
  edges with both endpoints, edges → their endpoints / the faces whose
  every edge is selected. Rules are conservative and symmetric; TEXTURE
  shares the FACE id space; OBJECT mode and empty conversions clear as
  before.
- THE ARCHITECTURE (no hacks, no parallel state): the engine's script API
  can only replace the subgizmo selection with ONE id
  (`se->subgizmos.clear(); insert(...)` in the C++), so the converted set is
  carried as ONE seed id (the element nearest the set's centroid) plus a
  conversion-expansion map in PBElementEditor — the same pattern as edge
  loops and UV island groups. Drag union, mirror, highlights, undo payloads,
  and ops all go through the SAME expansion path as an ordinary selection;
  the seed reports the set's CENTROID as its pivot origin, so the engine's
  transform gizmo lands on the selection's center and rotate/scale compose
  about it (rel = target·start⁻¹ algebra unchanged). Coming from a face
  selection, the gizmo orients to that face's normal (pick-side UX).
- Bevel Apply no longer dead-ends the selection: the op's output band
  (`new_face_ids`) becomes the selection through the same path; bridge/fill
  hole likewise select their created faces now (the gizmo stays live on the
  new geometry instead of hiding until the next click).
- Fixes from the session/history sweeps: `run_tests.sh`'s silent-skip guard
  no longer disables itself (`grep -c || echo 0` emitted two lines);
  `./run_tests.sh -gselect=...` passes GUT filters through for iterating
  (filtered runs skip the count guard and never count as "tests pass");
  59 orphaned `.gd.uid` files swept; vacuous `pass_test("skipping")`
  fixture skips in `test_pb_edge_loop_ring.gd` now `fail_test`; UV template
  export print routed through PBLogger; the four inline centroid loops
  (inset, face centroid, bevel cap) now use `PBMath.average`.
- Docs: `.pi/ORIENTATION.md` is now an index; the implementation detail
  lives in `.pi/orientation/` (architecture, selection, mesh_ops, testing,
  footguns, retro) — distilled from a sweep of ~80 agent session transcripts
  and the full git history, so workers stop re-implementing what exists.
- Tests: new `test_pb_selection_conversion.gd` (18 tests: conversion rules,
  seed+expansion carry, drag/undo coverage, mirror prune, pivot centroid);
  GUI harness gained a CONVERT case (face → edges → verts → face round trip
  in a real editor). 957 tests, 19.6k assertions, 59 suites, all green;
  `run_gui_tests.sh` failures=0.
- Version bump 0.9.104 -> 0.9.105.

v0.9.106 round complete ✓ — fix bevel-Apply stack overflow (crash regression):
- THE REPORT: beveling a cube EDGE and pressing Apply crashed the editor
  with a stack overflow. The backtrace showed `_commit_bevel_session` →
  `set_select_mode` → `_on_select_mode_changed` → `_on_params_applied` →
  `_commit_bevel_session` ping-ponging forever.
- CAUSE (introduced by the v0.9.105 selection-retention change): the commit
  switched select_mode (to FACE, for the output band) while
  `_params_session_kind` was still "bevel", so the mode-change handler's
  "apply any open modal first" rule re-entered the commit mid-teardown —
  and with TWO disagreeing mode assignments (session mode vs FACE) every
  re-entry flipped EDGE<->FACE, the setter's equality early-return never
  fired, and recursion ran away. The pre-0.9.105 code only ever assigned ONE
  target mode, so the same re-entrancy accidentally terminated at depth 2.
- FIX: the commit/cancel tear the session down FIRST (session kind, node,
  snapshot, faces/edges into locals) before any mode or selection work, so
  the handler's modal-apply rule finds no open session; plus a
  `_params_dispatch_underway` guard in `_on_params_applied`/
  `_on_params_canceled` as the second belt. Commit order is now: teardown →
  undo action → clear selection/gizmo → FACE → select the band.
- Regression case in the GUI harness (the FACE-mode apply path could never
  trigger this — that's why the suite stayed green): EDGE mode → select
  edge → bevel → Apply ⇒ lands in FACE with the band selected, modal closed,
  no re-entry (BEVEL-EDGE-APPLY, 17 → 21 faces). Full suite 957/957, GUI
  harness failures=0.
- Version bump 0.9.105 -> 0.9.106.

v0.9.107 round complete ✓ — feature gap implementation (Sessions 6, 7, 8, 9):
- Session 6: Advanced Selection & Snapping Suite:
  - Added `PBSelectionOps` (`editor/pb_selection_ops.gd`) with:
    - Grow/shrink selection with normal angle threshold (preventing growth across sharp crease edges).
    - Select coplanar faces (flood-fill adjacent faces on the same plane within angle tolerance).
    - Select similar faces (matching Material slot `submesh_index`, Smoothing Group, Element Color, or Surface Area).
    - Select boundary edges and hole loops (edges used by exactly 1 face).
    - Face loop and face ring traversal (quad strip traversal via winged edges).
    - Select All and Invert Selection helpers in PBActions and PBSelectionOps.
  - Precision Snapping & Proportional Editing:
    - Vertex snapping toggle button (`V-Snap`) on Row 2: snaps dragged element pivot to nearest vertex across any PBMesh in the scene.
    - Proportional editing toggle button (`Soft`) and radius input (`r: 2.0m`) on Row 2: Smooth, Sphere, Linear, Sharp, Constant falloff curves.
    - Live 3D wireframe preview sphere gizmo (3 orthogonal circles) centered at the selection pivot displaying the influence radius.
    - Unbound conflicting default shortcuts (Ctrl+A, O, V) and removed mouse-wheel interception so viewport zoom remains responsive.
  - Toolbar Reorganization (3-Row Layout):
    - Permanent 2-row base layout: Row 1 holds tools, primary mesh operations, and environment presets; Row 2 holds modes, space, snapping controls, shape generators, and docks.
    - Toggleable Row 3 (Extended Tools): Button toggles Row 3 on and off, exposing the full Selection Suite (All, Invert, Grow, Shrink, Coplanar, Similar, Boundary, Loop, Ring), Object Tools (Merge, Mirror, Center Pivot, Freeze, Probuilderize), CSG Booleans (Union, Subtract, Intersect), and Auto-Smooth.
- Session 7: Object Tools & Pivots:
  - Added `PBObjectOps` (`editor/pb_object_ops.gd`) with:
    - `merge_meshes`: combines multiple PBMesh nodes into one, baking relative transforms and rebuilding weld groups.
    - `mirror_mesh_data`: mirrors geometry across local X, Y, or Z Cartesian planes with winding reversal for outward normals.
    - `center_pivot`: moves object pivot to bounding box center, translating vertices in local space and compensating node transform.
    - `set_pivot_to_selection`: moves object pivot to selection centroid.
    - `freeze_transform`: bakes node transform into vertex positions and resets transform to identity (with parity check).
    - `probuilderize`: converts standard Godot `MeshInstance3D` / `ArrayMesh` surfaces into an editable `PBMesh`.
- Session 8: CSG Booleans & Smoothing Groups:
  - Added `PBCsg` (`mesh_ops/pb_csg.gd`): solid boolean engine supporting Union, Subtract, and Intersect operations between two PBMeshData operands with pre-flight watertightness validation and conversion to PBMeshData.
  - Added `PBSmoothGroups` (`editor/pb_smooth_groups.gd`): smoothing groups 1..30 per face (0 = hard), dihedral angle auto-smoothing (`auto_smooth`), and normal preview line generation.
- Session 9: Architectural Trims:
  - Added `PBShapeTrim` (`shapes/pb_shape_trim.gd`): procedural architectural moulding profiles (Skirting, Cornice, Dado rail; Flat, Chamfer, Round, Cove, Ogee, Stepped) swept along 3D wall paths with mitred corners.
  - Registered `&"trim"` in `PBShapeFactory` and `PBShapeParams`.
- Tests: added 5 new test suites:
  - `test_pb_selection_ops.gd` (14 tests)
  - `test_pb_object_ops.gd` (5 tests)
  - `test_pb_csg.gd` (4 tests)
  - `test_pb_smooth_groups.gd` (4 tests)
  - `test_pb_shape_trim.gd` (3 tests)
  - Full test suite: 989/989 tests passing across 64 suites (20,102 assertions), zero errors; real-editor GUI harness `./run_gui_tests.sh` passes with 0 failures.
  - Fix: preserve toroidal and spherical UVs on compile (`manual_uv = true`) with aspect-ratio scaling.
  - Version bump 0.9.106 -> 0.9.107.

v0.9.108 round complete ✓ — poibuilderize/CSG dispatch, multi-select element
editing, and spec-exact trim placement:
- Poibuilderize & CSG booleans actually run now (regression from v0.9.107):
  `_on_operation_requested` gated EVERY op behind `editor.is_editing()` and a
  non-null `active_mesh`, so clicking Poibuilderize (or a CSG boolean) with a
  plain MeshInstance3D / CSGShape3D selected — exactly the state the tools
  exist for — silently returned before reaching their handlers. Object-level
  ops are dispatched BEFORE the editing gate now; the CSG toolbar buttons are
  enabled unconditionally (they act on the scene selection, not the active
  element edit).
- Poibuilderize undo repaired: the node swap (add PBMesh / remove source) is
  registered purely through undo do-methods. The old path also added the
  PBMesh directly, so the committed `add_child` errored with "already has a
  parent" and the action's bookkeeping diverged from the tree.
- CSG operand semantics: the selection ORDER decides — FIRST-selected node is
  the target, LAST-selected (Shift/Ctrl-clicked most recently) is the cutter.
  There is no hidden "active mesh" in a multi-node selection anymore; the
  toolbar tooltips say so, and the target/cutter pair is logged.
- Multi-select vs element modes: with several nodes selected, the active
  mesh is the LAST-clicked PBMesh (selection order = click order; it used to
  grab the FIRST, fighting the engine's own primary object). Entering an
  element mode (or ctrl-adding a node while one is active) narrows the
  engine selection to the active PBMesh — the whole-object gizmo on the
  other nodes used to swallow element clicks ("faces hover but never
  select"). Object mode keeps engine-native multi-select (move both, CSG,
  merge).
- Trim placement rewritten to the Unibuilder spec (PBShapeCreator):
  - The drawn rect is the strip's FACE: u extent → Length, v extent →
    Height, and the Depth is never dragged (the max/min heuristic used to
    map the longer extent onto whichever axis it liked).
  - On a floor the strip STANDS UP ON THE EDGE THE DRAG STARTED FROM: the
    back-bottom edge lands on the start edge and the depth runs toward the
    drag side, so starting at the wall leaves the strip flush with it (it
    used to be centered on the drawn rect — half a height off the wall).
  - On a wall it lies FLAT on the surface, bottom on the drag's lower edge,
    depth protruding along the wall normal into the room.
  - Depth/Height retypes in the adjust panel keep the back-bottom corner
    pinned (the placement anchors the trim's local origin, not its AABB).
  - The run arrow follows the drag direction (no aspect flip mid-drag).
  - Project depth memory: a new trim starts at the last DEPTH committed in
    this project (EditorSettings `poibuilder/trim/last_depth`; 5 cm before
    you set one), and `on_wall` records which way the strip was drawn.
- Tests: 5 new PBShapeCreator trim placement tests (flush start-edge stand,
  drag-side depth flip, wall lie-flat, facing lock, mapping); full suite
  993/993 across 64 suites.
- Version bump 0.9.107 -> 0.9.108.

v0.9.109 round complete ✓ — trim placement robustness, CSG undo ghost fix,
CSGCombiner3D baking, and the Trim Walls tool:
- Trim placement no longer trusts the drag's u lock: the u axis locks to the
  first centimetres of mouse motion, so a wall-base drag begun with a
  perpendicular wobble locked u INTO the room and the long along-wall extent
  landed in the height — the strip stood the whole drag length TALL ("dragging
  the trim at the base of the wall places it going up instead"). On a floor the
  LONGER side of the drawn rect is the run now, and the strip stands on the
  line through the drag start along it (back stays flush with the wall line);
  on a wall the split is by WORLD direction (vertical extent = height,
  horizontal = length), so mouldings sit upright whatever the lock did.
- CSG boolean undo repaired: the cutter swap now follows the detach/creation
  convention (add_do_reference keeps the node alive across the history; a
  reattach helper restores tree membership, owner, and re-requests the gizmo).
  Raw remove/add_child left the undone cutter a ghost — rendered but
  unpickable, unmovable, and effectively absent from the scene dock. The
  target is re-selected on commit so a dangling selection on the detached
  cutter cannot break viewport picking.
- Poibuilderize accepts CSGCombiner3D: `poibuilderize_csg` probed
  `csg_node.material`, which only CSG *primitive* nodes have — combining a
  combiner errored ("Invalid access to property or key 'material'"). The
  property is probed with `in` now; combiners bake through
  `bake_static_mesh()` like any CSG shape.
- NEW TOOL — Trim Walls (Unibuilder spec): click wall faces on any PBMesh in
  any order; a wall highlights teal under the cursor and amber once chosen;
  the trim previews live as you go. Click a chosen wall again to drop it,
  Backspace drops the last, Enter / double-click / panel Apply commits,
  Esc or Cancel abandons. The strip sits where the wall meets the room: a
  wall cube reaching below the floor slab still gets its skirting ON the
  slab's surface (physics probe), a cornice tucks under the ceiling slab;
  Placement Bottom/Top + Offset slide it; the six profiles are shared with
  Trim. Walls meeting at a corner join with a clean mitre at any angle
  (bounded line intersection), walls that overlap carry trim on their visible
  run only (colinear overlap merge), a perimeter closes into a ring, and a
  doorway cut breaks the run at the jambs (the run follows each clicked
  face's own cross-section at the trim height). The result is ONE new
  object; the mitred paths are recorded in its shape_params so Edit Params
  rebuilds the same walls with new parameters. New files:
  `editor/pb_trim_walls_tool.gd` (headless core), `tests/test_pb_trim_walls.gd`
  (10 tests), `icons/icon_trim_walls.svg`; toolbar button in the Shapes group.
  Also fixed a latent crash: `PBMeshData.get_face_positions()` was called by
  `set_pivot_to_selection` but never defined — implemented on PBMeshData.
- CSG/Poibuilderize/Trim Walls undo routed into the SCENE undo history
  (context object on `create_action`, the same convention CmdMeshOp and
  shape creation already used). Without a context the action landed in the
  GLOBAL history while the engine's node Translates went to the scene
  history; interleaving them printed "UndoRedo history mismatch: expected 0,
  got 1" and a resync undo re-ran the CSG action's detach — the restored
  cutter vanished the next time it was moved ("box->sphere subtraction ...
  moved the sphere and it disappeared"). Scene + global histories now stay
  consistent; Ctrl+Z walks Translate and CSG Subtract in one linear stack.
- CRASH fixed in the CSG cutter reference polarity: `add_do_reference` puts
  the marker in the action's do-ops, and `discard_redo()` — triggered by the
  very next commit after an undo — memdeletes do-referenced objects. The
  sphere re-attached by the undo was therefore deleted (while selected and
  in the tree) by the first following transform, surfacing as "invalid
  callable" in add_do_method and a SIGSEGV on the next editor action. The
  cutter now takes `add_undo_reference`, the engine's own "Remove Node(s)"
  convention (scene_tree_dock.cpp): the detached node is freed only if the
  action falls off the history tail, never while it lives in the scene.
  All other node-lifecycle ops audited for the same polarity (all correct:
  do_reference = created by do; undo_reference = removed by do) and the
  convention is now written into `.pi/orientation/architecture.md`.
- Tests: 7 new trim placement regression tests (v0.9.108/109), 10 Trim Walls
  tests; full suite 1005/1005 across 65 suites; GUI harness failures=0.
- v0.9.109 addendum — shift+drag extrude/inset of CONVERTED selections
  fixed: Alt+C coplanar (and select similar/mode-switch) selections ride
  ONE engine seed id; the shift+move and shift+scale gestures passed that
  raw id list to the op, so only the seed face extruded/insetted while
  highlights and plain moves acted on the whole set. The gesture begins
  expand the seed through the same maps every other consumer uses, and
  the topology commit now selects the op output (the moved caps) instead
  of clearing the selection — the gizmo stays element-locked and the
  overlay count reflects the whole extruded set. Selection consumers
  audited: toolbar ops, snap-to-grid, pivot tools, material apply and
  `_edge_ids_for_op` all read the mirrored/expanded PBSelection; the drag
  gestures were the only raw-seed readers. Regression test in
  test_pb_element_gestures.gd (conversion group of two faces extrudes
  both and the commit carries both caps).
- v0.9.109 addendum 2 — creation protrudes toward the viewer; params modal
  no longer buried under the creation box: shapes are placed against the
  picked face's normal, and inward-wound geometry (GLB-sourced meshes with
  the opposite winding) yields the FLIPPED normal - a trim created on such
  a wall protruded into/behind the surface and read as "completely flipped
  windings". Creation now flips the captured normal when it points along
  the view direction (correct geometry is untouched - its normals already
  oppose the view); Trim Walls wall picks apply the same camera-facing
  rule and carry the corrected normal into the trim. The thick cyan
  creation box/arrow/end squares no longer draw while the adjust-params
  modal is open (PARAMS state) - the placed shape is the thing to see.
  Winding guard test: the placed trim's signed world volume must stay
  positive (normals outward) across floor/ceiling/wall/ramp drags and the
  placement basis is asserted never mirrored.
- v0.9.109 addendum 3 — trim shading, placement visibility, panel width,
  toolbar width, Trim Walls Offset memory:
  - Trim sides shaded with a weird gradient because EVERY face shared one
    smoothing group - the profile's sharp 90° corners blended into the
    sides. `PBShapeTrim.get_profile_smooth_segments` now maps which
    profile runs are actually curved (Round/Cove/Ogee arcs) and only those
    quads shade smoothly; Flat/Chamfer/Stepped and all bottoms/tops/backs/
    ends stay hard. Applies to the one-drag trim, Trim Walls, and the
    Edit Params rebuild.
  - A trim placed by base-release was INVISIBLE until the first parameter
    touch: the BASE phase keeps the render mesh hidden for the outline,
    and committing straight to PARAMS never un-hid it. The confirming
    path refreshes the preview now.
  - The Trim Walls panel was viewport-wide because the Profile row's
    label carried the whole value mapping. The label is "Profile" and the
    mapping (0 Flat ... 5 Stepped) is a tooltip on the row; param defs
    support `tooltip` generally.
  - Toolbar width rule: rows 1-2 must never exceed Godot's builtin 3D
    toolbar. Docks/Export (Materials, UV, Panel, Recover, Settings,
    Export) moved from Row 2 to Row 4, and the Trim Walls button moved
    from Row 2 to Row 4 (after CSG).
  - Trim Walls Offset was baked into the recorded mitred paths, so Edit
    Params offsetting +0.3 then back to 0 never returned to the walls.
    The recording is offset-free now and the rebuild applies Offset as a
    plain vertical slide. Profile/Flip/Upside-Down/Placement changes
    mid-session were and remain GLOBAL (every change rebuilds all chosen
    walls).
- v0.9.110 — Trim Walls re-audit (root causes for the "broken panel" round):
  - CORNERS SINKING / placement only partially applying:
    `merge_colinear` rebuilt its segment dicts WITHOUT the per-segment
    base height, so every mitred corner fell back to y=0 while endpoints
    stayed right. Fixed; the new determinism/globality tests catch it.
  - OFFSET PING-PONG / permanent upward drift: the room-shell probes
    raycast against the session preview's own collider, so each rebuild's
    heights fed back from the previous build. Probes now exclude every
    trim (`trim`/`trim_walls` shape ids + the preview) and measure only
    the room shell.
  - Build purity is pinned by tests: identical state produces identical
    geometry, and Placement Top/Bottom moves EVERY wall's run (verified
    against a canned ceiling probe).
  - The Trim Walls hint now reports the wall->run count and an explicit
    reason when a selection produced no runs — the panel can no longer
    look fine while broken. The hint label wraps at a fixed width (a
    one-line hint used to stretch the panel across the viewport).
  - Tooltips explain the Chamfer no-ops: Arc Segments and Smooth Shading
    only act on the Round/Cove/Ogee profiles' curved runs (this is
    correct moulding shading, not a dead control).
  - Toolbar balance restored: Row 2 is back to its pre-Trim-Walls
    composition (docks/Export included); Trim Walls stays on Row 4.
  - Footguns documented in .pi/orientation/footguns.md §14 (probe
    feedback, field-dropping intermediates, baked editable params,
    always-right-handed placement bases, select-your-output, visible
    build status, per-change version bumps).
- Version bump 0.9.109 -> 0.9.110.

v0.9.111 — Trim Walls hover outline alignment + Offset direction:
- The teal hover outline was pushed through the node's INVERSE transform
  even though get_face_positions is already local (gizmo space) - on any
  node with a transform the outline floated off the face entirely. The
  strokes now draw the local face polygon exactly; pinned by a test
  asserting every stroke vertex IS a face polygon vertex.
- Offset is measured OFF the placement edge: Bottom slides UP from the
  floor, Top slides DOWN from the ceiling (positive = away from the
  edge). The session tool, the recorded paths, and the Edit Params
  rebuild all share the same direction.
- Version bump 0.9.110 -> 0.9.111.

v0.9.112 — Trim Walls around doors and stairs:
- DOOR FRONTS: a door's front is ONE concave polygon wrapping its arch.
  Cross-section pairing walked the crossings in BOUNDARY order, which
  scrambles on concave faces - only one pier got a trim run (a sliver of
  the other), and higher placements produced nothing. Crossings are now
  SORTED along the run line before pairing (they always alternate in/out
  on a simple polygon), so both piers - and any height - yield their
  spans.
- STAIR SIDES: the stair generator stores side-face vertices in
  sliver-triangle appearance order, not outline order - the cross-section
  read a zigzag polygon and one side produced nothing (the other a
  truncated run). PBFace.get_outline_indexes reconstructs the outline by
  chaining boundary edges (edges in exactly one triangle) with winding
  preserved; face_world_polygon and the session hover strokes use it.
- Placement Top/Bottom now keeps runs at DIFFERENT base heights separate
  (a wall at ceiling height vs a door front at the arch top no longer
  mitre into each other with an averaged, shifted corner).
- Version bump 0.9.111 -> 0.9.112.

v0.9.113 — Trim Walls chaining sanity, calmer highlights, live placement after commit:
- WRAPPING RUNS: toggling a segment of a curved/extruded wall wrapped the
  trim around the wall's free end — the chain admitted endpoints up to
  1.5 m apart and let shallow-angle mitres extend up to 2x the segment
  length. Chains now require endpoints within 0.6 m and mitre corners
  within 0.6 m of both endpoints; real corners sit at the shared
  endpoints and are unaffected.
- CHOSEN-FACE HIGHLIGHTS: the amber fill was depth-test-off at 50% alpha
  and drowned the scene through walls. It is now depth-tested and very
  dim (14%); the teal hover keeps its visibility.
- PLACEMENT STAYS LIVE AFTER COMMIT: the recorded runs now carry their
  room-shell references (floor/ceiling Y from the placement probes), and
  the Edit Params rebuild re-places the run — Bottom sits on the floor
  (+offset), Top hangs under the ceiling (-height -offset) — so
  Placement/Height/Offset all keep working after the trim is committed
  ("changing top/bottom after the fact doesn't work").
- Version bump 0.9.112 -> 0.9.113.

v0.9.114 — Trim Walls cross-sections follow the placement edge:
- Bottom placement cross-sections at the room shell surface (door front =
  two pier runs); Top placement cross-sections at the FACE'S OWN TOP EDGE
  (door front = one head run across the arch; a stair side = the top
  step only) - the geometry REMAKES when Placement switches, and the
  strip is then HUNG/SAT at the probe-based placement height. Path
  points are normalized to the placement base (the raw cross-section
  points sit at the edge height and previously ramped the strip).
- Tests: door bottom=2/top=1, stair side top=short run on the top step
  with bottom=full depth.
- Version bump 0.9.113 -> 0.9.114.

v0.9.115 — Trim Walls Top placement marks the structure's top edge:
- Moving a full loop to Top kept runs on faces that never reach the top
  edge - the door's inner reveal faces kept arch-level rings, and runs
  appeared to wrap oddly. At Top the trim marks the top edge of the
  TALLEST chosen face: faces more than 0.1 m below it (door reveals,
  arch inners, stair sides in a room) yield nothing, while in isolation
  (only the door or stair chosen) those same faces are the tallest and
  still work. Bottom placement is unchanged (every face trims at the
  floor).
- Version bump 0.9.114 -> 0.9.115.

v0.9.116 — Trim Walls Top placement keeps the simple runs:
- Reveal faces (door sides, stair tops) reach the structure's top edge,
  and their tiny top runs chained into the wall runs - the trim wrapped
  into the doorway's top corners ("goes into the door's top geometry").
  At Top placement, when longer runs exist in the build, runs shorter
  than 0.5 m are dropped: the simple runs move to the top and connect,
  the fiddly parts stay out. An all-short build (only a door or stair
  chosen) keeps its short runs, so that flow still works.
- Version bump 0.9.115 -> 0.9.116.

v0.9.117 — Top-run filtering at the segment level; overlay thickness/offset:
- TOP-RUN FILTER REBUILT: the short-run drop happened AFTER chaining, so
  chained side-face runs rode INSIDE the long path and the corners still
  wrapped (the overshoot tabs at wall corners). The filter now removes
  short SEGMENTS before chaining - long runs chain only with long runs;
  an all-short build (door/stair alone) still keeps its runs.
- OVERLAY THICKNESS/OFFSET: the thick-line volume straddled the edge
  symmetrically, so its outward half depth-tested away and the visible
  half floated off the surface - up close that read as a thick band
  hovering off the mesh. The solid quads are now BIASED TOWARD THE
  CAMERA (75% of the offset), the stroke/fill clamp maxima drop from
  0.08/0.06 to 0.014/0.006 world units, and the selected/hover edge
  multipliers from 1.5x to 1.2x.
- Version bump 0.9.116 -> 0.9.117.

v0.9.118 — documentation round: Trim Walls Top-swap recorded as a known
limitation (deliberate stop):
- After five fix rounds (v0.9.109-117), Top-swap of a loop with openings
  still places opening-adjacent runs at the arch/lintel height instead of
  the structure's top edge. Documented as KNOWN BROKEN in
  .pi/orientation/footguns.md §15 with the investigation summary, the
  code involved, today's working mitigations (Bottom placement; select
  only the simple faces for Top; delete/re-place opening-adjacent
  pieces), and the shape a real fix would take (a per-run placement line
  decoupled from the ceiling probe + user-flagged opening masks).
- docs/DOCUMENTATION-ROADMAP.md: the Trim Walls page spec must state the
  limitation verbatim plus the current semantics (placement-edge
  cross-sections, offset off the placement edge, arc-only smoothing,
  0.5 m top-run floor); the FAQ page gains the matching entry; the
  showcase plan's Trim Walls beat no longer demos Top on loops with
  openings (simple wall run only) and the README carries a one-line
  limitation note.
- No plugin code changed. Version bump 0.9.117 -> 0.9.118 marks the
  documentation state.

v0.9.119 — end-user docs site, retro export of plain meshes, showcase tail:
- Static HTML docs (`docs/site/`, stdlib `build.py`) for GitHub Pages and a
  bundled `addons/poibuilder/docs-site/` copy. Toolbar Docs button opens
  the local site (or GitHub Pages if it has not been built). Pages cover
  install, the 60-second win, every tool group, keys generated from
  `pb_actions.gd`, and the Trim Walls Top-swap limitation.
- Retro export now includes ordinary MeshInstance3D nodes (imported GLB
  props), not only PBMesh. Albedo is sanitized to power-of-two dimensions
  clamped at max_texture_size (default 512) in both the direct PBM writer
  and the GLB converter — NPOT and 2048 atlases were a PSP texture-cache
  cliff.
- Showcase session `more.gd` plus EDL clips 80–86 appended after the
  existing film (UV editor, bevel, trim, trim walls, CSG, selection,
  poibuilderize). Earlier clips are unchanged.
- Version bump 0.9.118 -> 0.9.119.


v0.9.120–v0.9.126 — docs site rounds (versions bumped, entries not written
here; see the site's own pages and git history).

v0.9.127 — imported GLB props: courtyard barrels, the export fixes they
needed, and the device texture budget they were measured against:
- Demo content: two barrels from the PSX_Modular_Medieval pack stand beside
  the archway in the showcase courtyard (`test_map_showcase_builder.gd`
  `_add_courtyard_props`), left as ordinary imported MeshInstance3D nodes —
  NOT poibuilderized, which is the path a user takes when they drag a .glb
  from the FileSystem dock. The pack lives on the dev machine, so a machine
  without it builds the map without props (the export path itself is covered
  by generated fixtures in `test_pb_map_exporter.gd`).
- FIX, nested prop placement: the export tree is flat, and every geometry
  node read only its OWN transform — so a prop whose placement lives on the
  wrapper node a GLB import creates landed at the map origin, in both the
  GLB and the .pbm route. Exported geometry now carries its WORLD transform
  (`_get_world_transform`), which is also the convention the PBM writer's
  vertex bake always assumed.
- FIX, 128x128 textures were atlased as baked tiles: the GLB→PBM converter
  classified any 128x128 image as a baked tile. An asset pack's 128x128 wood
  texture became a TileAtlas slot — its wrap was destroyed, the RGB source
  was rejected by the RGBA8 atlas blit (silently leaving a black slot), and
  the texture grew to a 512x512 atlas. Tiles are identified by name now
  (`BakedTile_*`) in both `pb_pbm_converter.gd` and the `pbm_conv.py` oracle,
  and the atlas blit converts the source format instead of refusing it.
- Imported textures are now PLANNED per export run (`plan_imported_textures`):
  * CROPPED to the UV region their meshes actually sample, at the nearest
    power-of-two rect. The barrels' metal hoops sample a 51x9 texel corner of
    the pack's 704x704 atlas: 512x512 RGBA8888 (1 MB) → 64x16 RGBA5551 (2 KB).
    The showcase map's texture payload drops from 6448 KB to 4434 KB *with the
    props included*.
  * The rect is grown out of the atlas's unused area when the target power of
    two is larger (a 1:1 copy, no resampling) and resized down when it is
    smaller; UVs are remapped by `(uv - origin) * scale`, which is independent
    of the power-of-two resize, so the sampled texels are unchanged.
  * Alpha is taken from the PIXELS, not just the material: an atlas declaring
    BLEND over fully opaque texels ships as opaque (RGBA5551, opaque pass).
  * Textures are shared by content, so N instances of a prop (or several pack
    models sharing one atlas) cost one texture and one upload.
- Device, PSP over PSPLink (`./run_psp_hw.sh`), showcase courtyard spawn view:
  two barrels cost +0.1 gpu / +0.1 cpu ms and are drawn correctly (wood 128x128,
  hoops 64x16, both RGBA5551); the worst view stays at 2.72 gpu / 5.27 frame
  against the 16.67 ms budget. Eight barrels: 4.13 cpu / 0.11 gpu at the spawn.
  Six wall pieces filling the spawn view: 2.03 gpu. A 24-instance map with a
  UNIQUE texture per instance (44 textures, 7.5 MB payload) loads and renders
  with no loader FATAL. Rows and what they mean for authoring: 
  `retro_engine/psp/HARDWARE-TESTING.md` ("Imported props") and
  `retro_engine/RETRO-AUTHORING.md` §7.
- Version bump 0.9.126 -> 0.9.127.
- Docs polish & fixes (v0.9.128):
  * FIX: Markdown `[[kbd:...]]` inline regex now accepts closing brackets such as
    `[[kbd:]]]` and nested bracket keys without syntax bleed (`<kbd>[</kbd> / <kbd>]</kbd>`),
    and normalizes `\\\\` to single backslash `<kbd>\</kbd>`.
  * Knife Tool screenshot (`edit-knife.png`): re-framed from frame 260 (mid-drag dent)
    to frame 310, clearly showing the post-extrude result where the cut face is lifted
    cleanly above the slab with full lighting and geometry definition.
  * Texture splatting video (`paint-splat.mp4`): corrected master video offset from
    (78.0s, 1.8s) to (72.80s, 1.85s), fixing the bug where paint & stamps showed UV
    scrolling followed by the shape lineup instead of active texture splatting.
  * Animated materials video (`paint-scroll.mp4`): added to `CLIPS` extraction table
    at (77.25s, 2.00s), eliminating the "Clip not built yet" placeholder on the materials
    page. Also aligned `edit-extrude.mp4`, `create-floor.mp4`, and `map-waterfall.mp4`
    extraction offsets with `edl.toml`.
- Version bump 0.9.127 -> 0.9.128.
- Precision Vertex Snapping overhaul (v0.9.129):
  * FIX: Eliminated lateral/sideways jumping when dragging an axis gizmo handle. Single-axis drags (e.g. Y arrow) project candidate vertices strictly onto the active axis line, guaranteeing zero displacement in orthogonal directions across World, Object, and Element orientation spaces.
  * FIX: Eliminated backwards snapping and mesh collapse to zero height. Replaced unbounded nearest-search (`INF` distance) with localized magnetic catch (`snap_threshold`, 0.2m default / clamped to half grid step) along the motion axis. Moving an element upward will never catch base vertices behind the motion.
  * FIX: Clean dislodgement when dragging beyond the magnetic threshold. When the drag moves past candidate vertices, snapping smoothly releases and translation continues freely.
  * Feature: Screen-space cursor targeting (Unity/Godot style). Hovering the mouse cursor near a vertex in the viewport (within 35px screen distance) explicitly selects that vertex as the snap target, projecting its coordinates onto the active drag axes or plane.
  * Feature: Extrusion vertex snapping. Extruding faces (Shift+Move) now supports vertex snapping along the extrusion normal, allowing extruded cap heights to align with adjacent geometry.
  * Feature: Hold-V key support. Holding V in the 3D viewport temporarily activates vertex snapping for the duration of the key press; releasing V returns to normal translation. Toolbar button state is synchronized.
  * FIX: Decoupled vertex snapping from grid snapping: vertex snap now operates independently of `grid.enabled`. When both are active, vertex snap takes precedence when near a vertex and falls back to grid snapping when outside the snap threshold.
  * Added `tests/test_pb_vertex_snap.gd` (9 tests, 34 asserts) validating axis constraints, zero-height collapse prevention, adjacent mesh catching, dislodging, screen cursor targeting, and element/object space constraints.
- Version bump 0.9.128 -> 0.9.129.
- Precision Vertex Snapping — Vertex-level distance & Strict Axis Isolation (v0.9.130):
  * FIX: Vertex-level snapping on elongated faces and edges. Replaced centroid-based distance checking with true source-vertex evaluation (`_get_source_vertices`). For elongated or large faces/edges, the snap now measures from each corner/endpoint of the moved element to nearby target vertices, allowing long walls and beams to cleanly snap their ends to adjacent geometry regardless of total length.
  * FIX: Strict single-axis isolation in Element space (edge drags). Fixed a matrix row-vs-column dot product decomposition bug in Element space (`elem_b.x` in GDScript returns row 0, not column 0, which caused motion along one gizmo handle to leak into adjacent axes on rotated edges). Decomposing via `elem_b.inverse() * motion` guarantees exact coordinates along the gizmo axes, strictly zeroing motion along inactive axes.
  * FIX: Filtered coincident duplicate vertices at drag start and skipped $t_v \approx 0$ displacements, preventing drags from magnetically locking at zero movement.
  * Added `test_elongated_face_snaps_at_corner_vertex` and `test_edge_drag_single_axis_strictly_constrained` in `test_pb_vertex_snap.gd` (total suite: 11 tests, 43 asserts).
- Version bump 0.9.129 -> 0.9.130.
- Vertex Snap rebuilt from scratch — pair-magnet model (v0.9.131):
  * FIX: Replaced the projection-only solver. It accepted any scene vertex whose displacement ALONG the drag axis matched the drag distance regardless of lateral distance, so vertices meters away yanked the selection to heights nothing visible justified ("ping-pongs between positions that aren't snapped to anything"); the 35px screen-space cursor override additionally teleported the selection to whatever vertex sat under the mouse. Both are removed.
  * NEW MODEL: A snap is a (dragged corner s, scene vertex v) PAIR; it catches only when the constraint-valid motion lands s within the magnet radius of v. Single-axis drags stay EXACTLY on the axis (a catch rescales the signed distance so a corner lands on the vertex — never sideways); plane drags snap the in-plane delta when a candidate sits within the radius of the drag plane; free drags land a corner on a vertex in 3D. A single dragged vertex degenerates to one source (snap off that one point); faces/edges snap at their real corners.
  * FIX: Snap sources and the coincident-candidate exclusion now read the DRAG-START position snapshot instead of live positions. Live sources wandered with the drag, so each caught snap un-caught on the next engine delivery and re-caught at the raw cursor position — the second half of the ping-pong. Locked in by `test_catch_is_stable_across_successive_deliveries`.
  * NEW: The magnet radius is `clampf(grid.step * 0.5, 0.1, 0.5)` (0.2 m with the grid off); catches release cleanly once the raw drag moves back outside the radius.
  * NEW: Raising a freshly drawn shape now honors V-snap: PBShapeCreator and PBNgonDrawer HEIGHT/OFFSET drags use the drawn base corners / polygon corners as snap sources along the surface normal (callables injected by the plugin; creation previews never catch themselves). The extrude cap (shift+move) solves along the extrude normal as before, now with the same reachable-only criterion.
  * Solvers are pure statics (`snap_axis_delta` / `snap_plane_delta` / `snap_free_delta`, shared `vertex_snap_radius`), reused by the creation tools.
  * Tests: `test_pb_vertex_snap.gd` rewritten for the new semantics (17 tests, 62 asserts) incl. lateral-rejection and cursor-yank regression guards; 4 new shape-creator and 2 new n-gon height-snap tests. Full suite: 1054 tests, 20.5k asserts, failures=0; GUI harness failures=0.
- Version bump 0.9.130 -> 0.9.131.
- Docs pipeline: nightly bundle ships real docs; Pages deploy fixed; alpha framing (v0.9.132):
  * NEW: `docs/site/assets/` (38 screenshots + 5 clip loops, ~19 MB) is now COMMITTED. The nightly workflow and the Pages deploy build the site from them on CI; the showcase bake they were extracted from cannot run on a runner, so they are source material now (rule-4 exception documented in `.pi/ORIENTATION.md`; `extract_media.py` remains the local regeneration tool). Everything downstream (`docs/site/out/`, `addons/poibuilder/docs-site/`) stays gitignored.
  * FIX: The nightly release zip carried docs full of "Screenshot not built yet" placeholders: `build.sh --bundle` ran without any assets in CI. The nightly now builds `--bundle --strict`, so a missing file fails the run instead of shipping placeholders.
  * FIX: The Docs (GitHub Pages) workflow failed on every run with "Get Pages site failed ... Not Found" — Pages was never enabled on the repository (the "Node 20 deprecated" log line next to it is only a deprecation warning, not the error). `actions/configure-pages` now runs with `enablement: true` so the workflow enables Pages itself; `actions/checkout` bumped v4 -> v5 (node20 -> node24) in both workflows.
  * NEW: `build.sh --bundle` writes a `.gdignore` into `addons/poibuilder/docs-site/` so Godot never imports the bundled docs media (no .import spam, no .godot copies for users who unzip the addon). The plugin's Docs button opens the bundle via OS paths, which .gdignore does not affect.
  * DOCS: Install page rewritten around the three reader scenarios — already installed (release zip or Asset Library: just enable it; Docs button location), reading on GitHub Pages (link to Releases, download/extract/enable), and repo checkout. GitHub Releases is the recommended source; the Asset Library listing mirrors it and can lag (its repo-snapshot download has no offline docs, so the Docs button falls back to the online site). Alpha status called out on Install, the landing page, the FAQ, and the nightly release notes.
  * DOCS: Retro section reframed — the PSP/raylib demo engine is explicitly a proof of concept and performance sanity check, NOT an engine to ship with; the documented `.pbm` format is the contract for implementing loaders in your own engine, and the repo's demo engine is the reference implementation.
  * DOCS: plugin.cfg description now carries the alpha note and the online docs URL (there is no standard docs-URL field in plugin.cfg; the toolbar Docs button + description URL + Asset Library listing are the conventions).
- Version bump 0.9.131 -> 0.9.132.
- Landing page plays the full showcase film (v0.9.133):
  * DOCS: The landing page's courtyard still is replaced by the whole 960x540 showcase video (`clips/poibuilder-showcase-960.mp4`, ~10 MB, 3 min) via the `:::video` directive — the film is now committed under `docs/site/assets/` and ships inside the nightly docs bundle. `hero-courtyard.png` stays committed as the extracted still.
- Version bump 0.9.132 -> 0.9.133.
- UV editor keeps its texture under splat materials and shows the splat paint on UV2 (v0.9.134):
  * FIX: The UV editor's texture underlay vanished the moment a splat-painted face was selected: `_update_preview_texture` only understood StandardMaterial3D/ORMMaterial3D, and painting converts the face's material to a splat ShaderMaterial, so the underlay went null — the texture showed only in object-level selection. Splat materials now contribute their `base_texture` shader parameter as the UV1 underlay, and a face material that yields no texture falls back to the mesh's first material instead of blanking the canvas.
  * NEW: The UV2 (Splat/Mask) channel now shows the paint: `PBSplat.build_preview_texture` CPU-composites the splat stack over the UV2 unit square — base color/texture, every enabled layer blended through its painted mask with the shader's own smoothstep, stamp layer on top — for the selected face's material. Face selections survive a channel switch (face indices are channel-independent; vertex/edge selections still reset), so the composite follows the selection. The composite is cached per material instance and rebuilt only when the new `PBSplat.mask_state_version` moves (bumped by every paint/stamp/clear/add/remove/mask-resize mutation).
  * FIX: Splat masks live outside PBMeshData (they are material shader parameters), so painting never fires `mesh_rebuilt`; the UV panel now connects to `PBPaintController.stroke_committed` when the plugin is assigned and refreshes the canvas per committed stroke. The preview's mask sampling reads the CPU image cache (`get_layer_mask_image`), not `ImageTexture.get_image()` — the GPU round-trip returns stale pre-update data headless.
  * FIX: Switching the 3D editor back to OBJECT mode clears the mirrored 2D UV selection; previously stale faces and the 2D gizmo lingered in the canvas.
  * Tests: `test_pb_uv_editor.gd` +3 (splat face-select keeps underlay + UV2 composite, OBJECT-mode sync clears 2D selection, stroke_committed wiring); `test_pb_splat_and_stamp.gd` +4 (base-only/painted composites, non-splat null, mask_state_version bumps). Full suite: 1061 tests, ~20.5k asserts, failures=0.
- Version bump 0.9.133 -> 0.9.134.
- UV2 read-only splat view + modern (non-retro) workflow hardening (v0.9.135):
  * FIX: Poibuilderize silently dropped most triangles of dense real-scale sculpt imports. The degenerate-triangle check used an absolute area-squared threshold (length_squared < 1e-7 ≈ 3 cm²), so a 17k-tri 4k statue converted to 40 faces — a 99.8% mesh loss. Now a linear-scale threshold (cross.length < 1e-6 ≈ 0.5 mm²) keeps genuinely collapsed triangles out without eating real content; the same statue converts 17,285 faces. Found by the new modern-workflow probe with Polyhaven-style 4k PBR GLTF assets.
  * FIX: Poibuilderize dropped ARRAY_TANGENT — normal-mapped source assets (the common modern-asset case) lost their normal maps after conversion. Tangents now ride along the corner-duplication mapping (test: test_poibuilderize_preserves_tangents).
  * FIX: Any non-empty textures1 was treated as splat data and regenerated to per-face planar coordinates on rebuild, clobbering authored lightmap UV2 unwraps on splat-FREE meshes. has_splat_data now requires actual splat evidence (any face.splat_bounds OR any assigned splat material). Splat paint and LightmapGI-style UV2 remain mutually exclusive per mesh (splat meshes still regenerate) — the contract is documented in uv.md, paint.md, and footguns.md #10.
  * NEW: The UV editor's UV2 channel is now explicitly a READ-ONLY debug view: relabeled "UV2 (Splat — read-only)" with an explanatory tooltip, the operations toolbar and texel Set disable while it is up, _execute_uv_op refuses to run, canvas gizmo transforms are refused (selection still works for inspection), and the canvas draws a read-only banner. The status line shows the selected face's real-world splat area ("Splat area 4.00 × 0.50 m"), explaining why an elongated face's paint displays as a centered blot in the unit square — the square IS the face's splat-bounds box, and the mask is authored stretched over it.
  * FIX: Modern .glb export carried splat ShaderMaterials into GLTF, where custom shaders have no representation — splat surfaces came back untextured (paint AND base look lost). The modern export path now substitutes the splat base look (texture/color/roughness) as a StandardMaterial3D; painted layer content intentionally needs the retro bake, which is now a documented gotcha in paint.md (test: test_modern_export_substitutes_splat_base_material).
  * NEW: test_scenes/modern_workflow_probe.gd — a committed headless probe mimicking a non-retro user: loads machine-local 4k PBR GLTF props (project/test_scenes/modern_assets/, gitignored — never commit these), poibuilderizes the smallest prop, edits it, splat-paints an elongated floor with a 4k texture, exports modern .glb and re-imports it, and checks the UV2/lightmap contract. Prints an OK/NOTE/ISSUE report and skips cleanly when the assets are absent (CI/fresh checkouts). Current run: 10 ok / 3 notes / 0 issues.
  * DOCS: uv.md gains "UV2 — the splat debug view" and "UV2 and lightmaps" sections; paint.md gains the modern-export paint-loss gotcha and links the UV2 debug view; footguns.md gains #10 (UV2 ownership contract).
  * Tests: 6 new (tangent preservation, UV2 survival/regeneration ×3, UV2 read-only guards, splat base substitution on modern export). Full suite: 1067 tests, ~20.6k asserts, failures=0.
- Version bump 0.9.134 -> 0.9.135.
- Splats-to-lightmaps bake, modern stamp round-trip, interactive smoke-test harness (v0.9.136):
  * NEW: `PBTileBaker.bake_pb_mesh_in_place` — the "switch to lightmaps" move as a data-level operation. Reuses the retro bake machinery (face subdivider + tile baker) on the LIVE PBMesh: painted faces become grid-cell faces with baked composite tiles on plain StandardMaterial3Ds, splat data and textures1 are gone (UV2 free for LightmapGI, which also auto-generates UV2 when missing), all baked faces are manual_uv so rebuilds keep tile coordinates, and fragment normals are carried through a new `PBMeshData.set_authored_normals`. Exposed as `./bake_splat.sh <scene.tscn>` (runs headlessly inside the owning project) and documented in uv.md/paint.md. Second call on a baked mesh is a clean no-op.
  * FIX: The tile bake silently painted NOTHING when a splat layer's texture had no resource path (runtime/procedural ImageTextures): `_prepare_layer_data` required `ResourceLoader.exists(path)` and dropped the layer. `collect_face_paint_state` now carries the texture instance and the bake prefers it, path only as fallback — affects the retro export bake too.
  * FIX: Poibuilderize/bake in-place writers that rebuilt mesh data via packed-array Dictionaries silently lost content (copy-on-write on Dictionary-fetched packed arrays) — the bake accumulation now uses flat typed locals. Found immediately by the new bake test (0 faces baked).
  * CHECKED: Decals are well behaved in the modern pipeline — a stamp survives the full .glb export/re-import round trip as an ordinary MeshInstance3D quad under PBStamps, keeping mesh, material and anchored transform (unit test: test_modern_glb_roundtrip_preserves_stamps; probe prints the check too).
  * NEW: Interactive smoke-test harness, all with the FPS controller:
    - `./deploy_psp.sh [map.pbm]` — stages the newest scratch-exported .pbm into the device's map slot and runs the interactive app on a real PSP via the existing PSPLink pipeline.
    - `./test_baked_glb.sh [map.glb]` / `./test_modern_glb.sh [map.glb]` — open scratch exports in the map viewer (the modern one boots straight into FPS play mode).
    - `./modern.sh [--play|--build-only]` — disposable 4k-asset modern-workflow playground (live splat floor + Polyhaven-style props + FPS controller); auto-extracts the machine-local gitignored assets, rebuilds the scene headlessly each launch via the committed `modern_playground_builder.gd`.
    - `./scratch.sh` now also ships `bake_splat_in_place.gd` into the playground for §E of the cheat sheet.
  * NEW: `SMOKE-TESTS.md` — the one-page human cheat sheet: per-workflow command sequences, poke lists and pass criteria (editor basics, PBM→PSP, baked GLB, modern GLB, splats→lightmaps bake, modern 4k playground) plus a fast change-area → smoke-test matrix. Linked from CLAUDE.md's Quick Start.
  * FIX: Headless scene saves lost live splat masks — ResourceSaver samples `ImageTexture.get_image()`, which returns stale pre-update data in headless mode (same root cause as the v0.9.134 preview issue). New `PBSplat.sync_mask_textures(mat)` rebuilds the GPU mask/stamp textures from the CPU image cache; the playground builder calls it before saving. Interactive painting is unaffected (update() remains the zero-lag per-dab path).
  * Tests: test_pb_map_exporter +2 (bake-in-place frees UV2 with painted-content verification, modern stamp .glb round trip). Full suite: 1069 tests, ~20.6k asserts, failures=0. Modern probe: 0 issues, now with the decal round-trip check.
- Version bump 0.9.135 -> 0.9.136.
- Modern-scene creation drag freeze: picking overhaul (v0.9.137):
  * FIX: Dragging out a cube in the modern 4k playground froze the editor ~10 s EVERY drag. Two stacked causes, both fixed:
    - The creation tools' plain-mesh picking (`_update_creation_hover` + the press-point picker) swept EVERY triangle of EVERY MeshInstance3D in the scene per mouse move in GDScript — `generate_triangle_mesh()` + a 34 MB `get_faces()` copy + 943k `ray_intersects_triangle` calls for the coastal cliff. Replaced by `PBPicking.pick_plain_mesh_surface`: per-Mesh face cache (one-time extraction), a world-AABB ray slab prefilter that skips meshes the ray misses or that lie beyond an already-found nearer surface, and a `PLAIN_MESH_PICK_TRI_BUDGET` (65,536 tris) that excludes giant sculpts from the sweep — the grid plane and PBMeshes stay pickable, and PBMesh passes got the same AABB prefilter. The gizmo click-picking path no longer feeds the editor 943k collision triangles per redraw either.
    - `PBMath.ray_intersects_triangle` used the 1e-4 `FLT_EPSILON` (a meter-scale tolerance) as its parallel-plane gate, but det = 2 x triangle area — so a sculpt's 1 mm² triangle (det ~ 2e-6) read as "ray parallel to plane" and NEVER intersected. Dense geometry was silently unpickable everywhere (converted sculpts were unclickable in element mode too), and the 943k-triangle sweep paid full cost to always return nothing. Now a true 1e-9 epsilon (RAY_TRI_EPSILON, local to this function).
  * Measured on the real assets (probe step 5, new): over-budget cliff pick = ~0.1 ms warm (was ~10 s per hover update; one-time 0.9 s face extraction per Mesh), under-budget marble bust = 29 ms and now actually HITS (it never did before the epsilon fix). Probe reports 14 ok / 3 notes / 0 issues.
  * Tests: `test_pb_picking.gd` +3 (tiny-triangle intersection, budget exclusion + AABB early-out/miss, ray-AABB slab spans). Full suite: 1072 tests, ~20.6k asserts, failures=0.
- Version bump 0.9.136 -> 0.9.137.
- PBM-first export, curved-stairs rect fill, toolbar grid move, playground prop scales (v0.9.138):
  * FIX: The export dialog offered NO .pbm path — both modes wrote GLB, leaving the PSP format reachable only by hand-typing an extension (deploy_psp.sh then found nothing to deploy). The dialog now leads with **PBM — PoiBuilder Retro Map (PSP)** as the default format (default path `res://exports/exported_map.pbm`), with GLB retro-baked and GLB modern as secondary flavors; switching flavors swaps the path extension and the retro bake toggles. `export_map_async` now routes `.pbm` to the retro writer through the same progress callback. Toolbar: **Export PBM** is a ONE-CLICK export (default retro bake straight to res://exports/exported_map.pbm); **Export...** opens the dialog for options/GLB. deploy_psp.sh's hint updated to match. Fixed en route: the dialog's lighting-bake toggle wrote `editable` to CheckBoxes — a runtime error on every toggle, so the dependent controls never greyed (now disabled/enabled per control type).
  * FIX: Curved stairs never matched the dragged box — the old sizing kept a fixed 180 deg sweep, derived radii from min(size.x, size.z) and centered the arc, leaving the stairs floating inside the rect off the grid lines. New contract: the arc's bounding box EXACTLY fills the dragged rect — the SHORT rect axis pins the outer radius (radial depth flush), the LONG axis is matched by bisecting the sweep angle against the annulus bbox contract (span_x = r_out - r_in*cos a), and rects deeper than wide set the generator's new swap_axes (chord exchanged onto the long axis, winding preserved). Step count now quantizes to the grid snap (height/snap, clamped 2..64) while still dividing the dragged height exactly, so the bottom riser base and top tread stay flush with the box edges and treads land on grid lines whenever the height is a grid multiple. Factory + drag params + a "Swap Arc Axes" params entry all share the new `curved_stairs_sizing` solver.
  * Toolbar: the Grid section (grid panel toggle + snap readout) moved from the cramped Row 2 to Row 3, which had the space (docs updated: interface.md rows + export buttons, export.md intro).
  * Modern playground: props at scale 1.0 (the cliff was also dropped from the scene — 943k tris is too heavy for interactive editing; it remains in the machine-local assets for the headless probe's over-budget picking regression). Splat paint layer now uses the gothic statue's 4k stone diffuse.
  * Tests: `test_pb_shapes_complex.gd` +2 (rect-fill bbox across four aspect ratios incl. the swapped deep rect; step quantization), `test_pb_map_exporter.gd` +2 (async .pbm routing writes a real PBM3 file; dialog defaults to PBM with extension swapping), `test_pb_collider_audit.gd` +1 (factory rect-derived quarter-ring ramp stays closed and CW-from-outside) with the audit battery now pinned to the documented 180 deg reference geometry explicitly instead of inheriting the factory default. Footgun for the road: shape_params must be set BEFORE pb_mesh_data reaches the node — the mesh_data setter builds the collider and rebuild() alone does not refresh it (the rewired audit test tripped on exactly this). Full suite: 1077 tests, ~20.6k asserts, failures=0.
- Version bump 0.9.137 -> 0.9.138.
- Async PBM export, sprite/n-gon live readouts, asset categorization, PSP unwedge (v0.9.139):
  * FIX: PBM export froze the whole editor. The v0.9.138 dialog routing short-circuited to the SYNCHRONOUS `export_retro_pbm` before `export_map_async`'s incremental build loop — which already handles .pbm end to end (per-node "Baking X (n/N)" progress, a frame yield per node, cancel support, and the PBM write phase). The short-circuit is removed; the one-click toolbar export and the dialog now stay live for the entire retro bake, exactly like the GLB path.
  * NEW: Billboard sprites show live feedback while placing. Raising off the surface draws a green guide line from the ground anchor to the sprite's bottom edge plus a small ground cross (ImmediateMesh, unshaded green, cleaned up on finalize/abort), and the tool overlay shows the live numbers: `Offset: X.XXm` while raising, `W X.XXm x H X.XXm (xN.NN)` — world-unit size plus scale multiplier — while scaling. N-gon placement gets the same treatment: `N vertices` while drawing and `Height: X.XXm` during the height drag.
  * NEW: `PBAssetCatalog` categorizes image assets into sprites / stamps / textures (particles excluded from all three pickers), by folder name (`.../sprites/`, `.../stamps/`, `.../particles/`, `.../textures/`), then file-name prefix (`sprite_`, `stamp_`, `particle_`, `tree_`, `bush_`, `grass_`, `decal_`, `billboard_`), then the shipped defaults that predate prefixes (tree_oak/pine, bush_foliage, grass_tuft -> sprites; flower_patch, tapestry -> stamps). The sprite carousel lists only sprites; the Material dock filters its grid per mode (PAINT -> textures, STAMP -> stamps, SPRITE -> sprites; MATERIAL keeps the full palette). Users add their own assets by dropping files into `res://materials/sprites/`, `res://materials/stamps/` or `res://materials/textures/` — nothing in the addon folder is touched. Documented in paint.md.
  * FIX: run_psp_hw.sh / deploy_psp.sh could sit silently for many minutes at "resetting the device". Two causes addressed: (1) `wait_link` was silent for its whole grace window — it now prints progress per second; (2) a STALE `usbhostfs_pc` (left by a Ctrl-C'd run or --keep) keeps owning the USB session, so after a device reset/replug the bootstrap traffic goes nowhere while every pspsh call times out at 25 s each — up to ~17 minutes of dead air before the failure. Both the reset path and the usbhostfs-reuse check now detect the dead-link-with-live-process state, kill and restart usbhostfs_pc serving the current hostdir, and only then declare failure.
  * Tests: `test_pb_asset_catalog.gd` +4 (folder/prefix/default-name classification, disjoint buckets, particles excluded), `test_pb_sprite_placer.gd` updated for the categorized carousel (stamps/textures/particles must NOT appear). Full suite: 1081 tests, ~20.6k asserts, failures=0.
- Version bump 0.9.138 -> 0.9.139.
- PSP link wedge root cause: cross-project usbhostfs_pc conflict (v0.9.140):
  * FIX: deploy_psp.sh / run_psp_hw.sh stalled at "waiting for the PSPLink link" even though the device visibly reset. Root cause found LIVE: a leftover `usbhostfs_pc` serving `../poichara`'s hwrun (poichara's `--keep`, or a Ctrl-C'd run) was still holding the USB session — and since pspsh reaches the device THROUGH usbhostfs's local relay, poichara's instance was the one answering our commands. The reset fired (visible), then the device re-attached to the instance that serves the WRONG hwrun and the link wait stalled. run_psp_hw.sh now enforces the singleton at start: ANY pre-existing usbhostfs_pc (logged with its served directory) is killed before build/staging, and step 3 always starts this run's instance fresh — never reuses, never runs two. reset_device keeps its mid-reset recovery as belt-and-braces.
  * The stale instance was cleared from the live session. `../poichara`'s run_psp_hw.sh already enforced the same singleton on ITS start (running it will kill ours, by design); its `--keep` exit path now prints a loud note saying exactly that, so a kept instance is a known trade-off rather than a mystery wedge. No udev/systemd/other claimants found in poichara.
  * SMOKE-TESTS.md §B documents the "Stopping stale usbhostfs_pc" line as the fix working, not a failure.
- Version bump 0.9.139 -> 0.9.140.
- PSP export garbage traced: sprite raise guide leaked into the map (v0.9.141):
  * FIX: PBM exports showed "flipped windings", sheets sunk into the floor near sprites, and a stamp-like patch in the wrong place. Root cause: the sprite raise guide line (v0.9.139) was never cleared on finalize — every placed sprite left an ImmediateMesh line-art node in the live scene, named `SpriteRaiseGuide`. The exporter then exported it TWO ways: the name matches the billboard prefix rule (`sprite*`) so the billboard branch baked its vertices as a billboard, AND the plain-mesh path read its unindexed line vertices as a triangle soup of arbitrary winding — garbage triangles exactly at sprite ground positions. Fixed on all legs: `finalize_placement` clears the guide (the leak), the guide is renamed `RaiseGuideLine` (no billboard prefix match), the billboard branch refuses ImmediateMeshes, and the plain-mesh/single-node export paths refuse ImmediateMeshes too (tooling line art can never become map geometry). The retro async and sync PBM writers produce byte-identical output (verified).
  * Spawn documentation: without an authored spawn the PBM defaults to the map bounds (far edge, eye height over the lowest point) — that is the "spawns far away / under the floor" report. To choose the start point, add a Node3D named `Spawn` (Y position and yaw honored). Exporter now prints a notice when defaulting; SMOKE-TESTS §B documents it.
  * Tests: `test_pb_map_exporter.gd` +1 (editor tool meshes never enter the export tree — both the billboard and plain-mesh legs). Full suite: 1082 tests, ~20.6k asserts, failures=0.
- Version bump 0.9.140 -> 0.9.141.
- PSP winding root cause: direct PBM writer emitted flipped triangles (v0.9.142):
  * FIX: "Flipped windings on all the geometry on the PSP" — root-caused by forensics on the actual deployed map and a calibrated comparison against the device-verified oracle. The GLB+oracle preset pipeline (pbm_conv.py, the historical device-verified path) stores PBM triangles CCW-from-outward; the direct GDScript writer (`_write_pbm_from_tree`, added for the dialog's one-click PBM) stored them in Godot's CW order — reversed relative to what `sceGuFrontFace(GU_CCW)` + the y-down framebuffer expect, so EVERYTHING exported through the dialog rendered inside-out on the device (the old preset bakes, e.g. the Sep 16 `day.pbm`, are CCW and render correctly — verified by parsing both). Fix: the writer now reverses each triangle to the oracle convention; dialog exports are verified top-face-outward-up across the whole courtyard. Caught because it was only ever viewable through double-sided renderers (raylib viewer, PPSSPP software) until it hit real hardware. Regression test: `test_pbm_triangle_winding_matches_oracle` parses the written PBM and locks the convention (plus header bounds/spawn sanity).
  * Previously reported flipped-windings sightings were compounded by the v0.9.139 sprite guide leak (fixed in v0.9.141) — the forensics that found the real writer bug also confirmed the v0.9.141 cleanup: the deployed post-fix export contains no line-soup garbage.
  * NEW: Billboard sprite raise/scale feedback — the ground->sprite guide is now a camera-facing translucent green ribbon with a bright core and a ground diamond (1px lines were invisible), and the floating cursor extents label (same style as cube placement) now covers billboard raise ("Offset: X.XXm") and scale ("W x H (xN)"), plus the n-gon height drag ("Height: X.XXm").
  * CONTAINMENT (OOM incident response): all automated Godot invocations now run inside ONE persistent, memory-capped container (tools/godot_guard.sh, modeled on ../recettear-decomp/scripts/container.sh): exactly one named/labeled container can exist, cgroup RAM cap 2 GB default (8 GB hard max, GUARD_MEM env), --init zombie reaping, 4h auto-recycle, and `cleanup` force-removes it plus any labeled strays. Verified live: the container's cgroup memory.max is exactly 2 GiB — a runaway inside it OOM-kills inside the cgroup and can never take the host down. run_tests.sh routes every Godot invocation through the guard (PB_GUARD=off to bypass; GUARD_MEM=8G to raise) and force-removes the container on exit; run_psp_headless.sh gained an outer hard timeout (the emulator's own --timeout does not always fire).
- Version bump 0.9.141 -> 0.9.142.
- Containment actually enforced, upside-down sprite root cause, Spawn reaches the PBM header, one-click button removed (v0.9.143):
  * CONTAINMENT, PART 2: the v0.9.142 guard was found VOID on this machine — a runaway test ballooned to 15.6 GB while "inside" it. Two root causes, both fixed. (1) `run_tests.sh` computed GUARD_SCRIPT from `"$0"` AFTER `cd project`, so it resolved to `project/tools/godot_guard.sh` (nonexistent) and the old run_guarded SILENTLY FELL BACK to running Godot direct and uncapped on every invocation — the podman path had been dead code since birth (a guard script that is merely missing now fails the run instead). (2) Rootless podman on this host has no cgroup delegation: `podman inspect` reports an EMPTY CgroupPath and `--memory=2G` is silently unenforced — container processes inherit the CALLER's cgroup (the stray lived in the desktop session's scope). The guard no longer assumes: when podman cannot manage cgroups, every exec is wrapped in a `systemd-run --user --scope` with `MemoryMax`/`MemorySwapMax=0` (the scope contains the podman client AND everything it spawns, so the kernel OOM-kills inside the cap even if the caller is SIGKILLed and orphans the tree); when NO mechanism can enforce, exec FAILS CLOSED with `PB_GUARD_UNCAPPED=1` as the loud escape hatch (best-effort 8 GB `ulimit -v`, which even `PB_GUARD=off` now applies). New subcommands: `status` (what is enforcing the cap right now) and `verify` (allocates 3 GB in-container and PASSES only if the kernel OOM-kills it — run after any podman/systemd change). Verified live on this host: verify reports `OK: hog killed by signal 137`, and a hog orphaned by killing its caller is still OOM-killed with host memory untouched. The GUT step additionally gained a hard wall clock (`PB_TEST_TIMEOUT`, default 900 s) so a hang dies on its own instead of growing forever.
  * The balloon itself was a test bug: `test_pbm_triangle_winding_matches_oracle` walked the PBM texture table reading `data_size` at header offset +36, but the writer emits `format` and `alpha_mode` before the size field (+40) — garbage `dsz` shifted every later offset, the mesh `vertex_count` read back as ~2^30 and the parser appended hundreds of millions of vertices (that, not Godot, was the 15.6 GB). And once the offset was fixed the test STILL failed for a second stale reason: it read vertices POSITION-first, while the device contract (`PbmVertex` in retro_engine/psp/pbm.h) is `u, v, color, x, y, z` — the winding assertions had been running against garbage since the vertex layout changed. Both parse bugs fixed; the winding test now genuinely validates the CCW-from-outward convention (and passes).
  * FIX: "the sprite outline while placing is offset" + "upside down into the floor on the PSP" (one of two trees, Godot fine, baked GLB equally flipped) — one root cause. The billboard sprite placement pick did NOT apply the viewer-facing normal flip the shape-creation path has (`_creation_begin_from_surface` flips normals that point WITH the view ray; `_sprite_placer_input` passed the raw pick through), so a backface/inward-wound face (normal pointing away from the camera, e.g. DOWN) authored the sprite's basis with its up axis pointing DOWN — the tree hangs below its anchor. Godot hides this completely: BILLBOARD_FIXED_Y rebuilds the quad's basis from world up + camera and keeps only the node origin (verified in godot source, `material.cpp` BILLBOARD_FIXED_Y), so the editor shows an upright tree while the bake keeps the authored transform. Fixed at the source (`_sprite_placer_input` flips the surface normal toward the viewer) AND hardened in the exporter: `_billboard_bake_transform` un-flips any billboard whose baked basis has its up column below the horizon (180° rotation about the local X axis — anchor, yaw and scale preserved, proper rotation), so maps authored before the fix export upright too.
  * FIX: "sprite guide still thin and barely visible" — two bugs. The guide ribbon's top endpoint subtracted half the sprite height (`- normal * h * 0.5`), which assumes a CENTER-anchored quad, but `create_sprite` is BASE-anchored (Y=0 up) — at typical elevations most of the guide was drawn UNDER the surface it rose from (at 1.8 m elevation with a 4.8 m tree, the entire ribbon was below grade). The ribbon now ends exactly at the sprite's base (surface + normal * elevation). Visibility: the band is 0.18 m wide (was 0.07), the ground diamond 0.28 m, alpha 1.0, and the material is depth-test OFF with render_priority 10 — the guide reads even against the floor it launches from.
  * FIX: "placed a Node3D named Spawn but the PSP app didn't spawn me there" — the Spawn node was discovered but its position only reached the `player_spawn` metadata JSON tag, which the PSP engine never reads; the engine spawns from the BINARY HEADER (`map->header.spawn_pos/spawn_rot` in pbm_loader.c/main.c), and the writer always stored the bounds-derived default plus a hardcoded yaw 0.0. `_collect_metadata_from_scene` now reports the discovered spawn through an out-param and `_write_pbm_from_tree` writes its position AND world yaw (basis `get_euler().y`, correct under rotated parents) into the header; the "No Spawn node" notice prints only when actually defaulting. Regression test parses the header back.
  * NEW: the redundant toolbar "Export PBM" one-click button is REMOVED (the Export... dialog's PBM format is the same default-path export; one button, one entry point). Signal, handler and docs references updated (export.md, interface.md, SMOKE-TESTS §B, deploy_psp.sh hint); showcase director and GUI harness now reference the dialog button.
  * FIX: `SCRIPT ERROR: Invalid access to property or key 'position' on a base object of type 'InputEventJoypadMotion'` spamming the console while the billboard tool was armed: `_forward_3d_gui_input` fed EVERY event (including joypad motion) to the sprite cursor readout. Now guarded to `InputEventMouse`.
  * Tests: `test_pb_sprite_placer.gd` +1 (guide band endpoints land on the ground plane and the sprite BASE; material is no_depth_test), `test_pb_map_exporter.gd` +2 (upside-down billboard basis un-flipped with anchor preserved and upright billboards untouched; a `Spawn` node reaches the binary header position + yaw), winding-test parser fixed as above. Toolbar button assertion updated. Full suite: 1086 tests, ~20.6k asserts, failures=0 — run end-to-end under the VERIFIED cap.
- Version bump 0.9.142 -> 0.9.143.
- Stamp preview leaked into exports, baked-tile grid seams, viewer button removed (v0.9.144):
  * FIX: "right edge of stamp leaking to a completely different PBMesh in the baked map (glb + pbm, looks fine in Godot)" — forensics on the actual scratch export (`/tmp/poibuilder_scratch/exports`) found the paint controller's LIVE preview nodes in both files: `StampQuad_0` (the tapestry decal being placed, tex_id 50, spanning two wall meshes at x=11.8..14.2 with its right sliver hanging past the wall corner), plus `StampDeleteHighlight_0` and an emitter-tex carrier. The preview subtree (`PBSplatPreviewNode` under the scene root) is visible in the editor viewport — which is why Godot looked right — but nothing under it is committed map data: the tapestry stamp was never anchored (no committed stamp carries it), so the "stamp" in the export was 100% leaked preview. Fix: `PBMapExporter._is_editor_preview` (name `PBSplatPreviewNode` OR meta `poi_editor_preview`) skips the subtree in ALL THREE collection passes (export-node collection for sync+async GLB/PBM, node recursion, imported-texture usage planning), and `pb_paint_controller.setup_previews` stamps `poi_editor_preview` on the preview root so a rename cannot reintroduce the leak. Same class as the v0.9.141 raise-guide leak — editor previews live in the authored scene and the exporter is the chokepoint.
  * FIX: "very obvious seams around the texture splats — you can literally see the grid, also on the stamps". Root cause in `PBTileBaker._bake_composite_tile`: baked pixels were mapped ENDPOINT-style (`tx = x/(res-1)`, image lookups `round(u*(w-1))`), which puts the cell's edge coordinates exactly ON the first/last texel columns. Consequences: (a) each tile's content is stretched by 128/127 relative to its quad; (b) the boundary coordinate is baked into BOTH adjacent tiles, so every shared tile edge renders that texel twice — the stamp's navy border and the checker's dark edges smeared one texel across every tile line, reading as a dark grid over painted regions (confirmed by parsing the scratch GLB: a bright poster tile's column 127 mean was 185/255 vs 238 for its neighbors — the border bleeding inward). Fix: texel-center mapping everywhere in the bake (`tx = (x+0.5)/res`, image lookups `int(u*size)` clamped — the mask path already did this), which matches the GPU's linear sampling of the tile quads' [0,1] UVs exactly; adjacent tiles and baked-vs-base boundaries now line up texel-for-texel. Pure bake-time arithmetic change — identical loop counts, identical output sizes/textures, zero runtime impact on any consumer.
  * FIX: the export dialog's "Open in Retro Map Viewer" button is REMOVED: it spawned the engine on `res://test_scenes/retro_map_viewer.tscn`, a dev-repo scene that does not exist in an end user's project, so the button could only ever fail for them (the dev workflow uses ./run_viewer.sh / ./deploy_psp.sh). Button, action bar, handler and all visibility toggles removed.
  * FIX (the actual seam root cause, found after the texel fix did not clear the device view): "very obvious seams around the texture splats — you can literally see the grid, also on the stamps" was ALSO a broken engine contract, not a bake-content bug. The PSP renderer keys its painted-tile policy off the texture NAME (`strstr(tex->name, "TileAtlas")` in psp_render.c): such textures are sampled with GU_CLAMP (a tile samples only its own slot, so LINEAR must never blend the opposite edge into it) and get the pinned-mip detail LOD (per-primitive levels step in sharpness at every tile boundary — the renderer comment literally describes "a blurred, seamed floor"). The old atlas exporter named its textures `TileAtlas_N` and the GLB->PBM converter still does (pb_pbm_converter.gd:530), but the per-tile baker's textures carry no resource name, so the direct PBM writer registered them as `tex_N`: baked tiles rendered with GU_REPEAT + per-primitive LOD. With LINEAR+REPEAT, every tile's edge texels blend with the tile's OWN OPPOSITE edge — a tile that contains the stamp's navy border on one side and poster white on the other shows a gray fringe at its boundary (white bleeding out of the splat, dark bleeding in — exactly the reported bright-line-outside/dark-line-inside pattern), and the per-primitive mip steps add sharpness seams between neighbouring tiles. Fix: `PBTileBaker.bake_face_tiles` names every baked tile texture `TileAtlas_<face>_<cx>_<cy>` (the material keeps `BakedTile_*`), which re-arms the engine's measured policy (`detail_const = 1`, device row in psp_render.c). Verified on the real PSP with the scratch courtyard map: before = poster sliced by gray grid lines, hazy under per-primitive mips; after = crisp, seam-free, at the same 60.0 fps — profiling battery on the same map: stairs view frame 9.06 ms (cpu 8.96 / gpu 0.10), worst view 9.18 ms, 99% CPU-bound (display-list construction), mip-chain benefit +25.78 ms; no performance regression.
  * Tests: `test_pb_map_exporter.gd` +1 (paint-preview subtree and poi_editor_preview meta never enter the export tree; ordinary props still do), `test_pb_export_tile_baker.gd` +1 (baked tiles sample texel centers: a ramp base's last tile column must be bright — endpoint sampling wraps it to black; exactly one dark column per tile) + TileAtlas name-convention assertion.
- Version bump 0.9.143 -> 0.9.144 (plugin.cfg was left ahead of the two code constants by earlier rounds; all three now agree).
- Trim UV tiling, PSP map slots, dock placement modes, object state toggles (v0.9.145):
  * FIX: "a long wall trim run has a stretched out texture. it should instead tile like everything else (the door part in the image is a separate run to show how it stretches based on length)". `PBShapeTrim.extrude_profile_along_path` wrote normalized 0..1 UVs — U was `segment/segment_count` and V `profile_point/profile_point_count`, so a 10 m run stretched the same texture a 1 m run tiled (the trim faces are manual_uv, so the dock's tiling never applied). UVs are now WORLD METRES on both axes, matching the plugin's 1x1 m repeat convention everywhere else (PBUv auto-UV, the "Reset (1m)" tiling default): U is the accumulated path arc length (mitred corners and closed rings included via the wrap-to-total-length term), V the profile's own 2D arc length, so curved profiles (Round/Cove/Ogee) sample the texture without angular stretching and trim rows line up with wall rows at the same height. Cap UVs were already in metres and are untouched. Regression test: `test_sweep_uvs_tile_by_world_length` (1 m and 10 m straight runs must span exactly N metres of U).
  * FIX: "./run_psp_hw.sh runs the scratch map now instead of the courtyard. deploy_psp is for that, run_psp_hw should run the courtyard reference demo map". Root cause: `deploy_psp.sh` staged the scratch export by OVERWRITING the shipping slot `retro_engine/psp/showcase_retro_baked.pbm` — the same file `run_psp_hw.sh` copies onto host0: and `build_psp.sh` ships next to the EBOOT — so one deploy left every later hardware run (and any standalone zip) on the scratch map until the tests re-exported the courtyard. Deploy now stages into its OWN slot: the scratch map lands as `poi_scratch.pbm` + a one-line `poi_map.txt` naming it (both gitignored), passed to `run_psp_hw.sh --app --staged`; the shipping slot is never touched. `run_psp_hw.sh` gained `--staged` and always stages the courtyard map as the base; without the flag it DELETES a leftover poi_map.txt/poi_scratch.pbm from host0:, so a bare `./run_psp_hw.sh` (profiling or `--app`) always runs the courtyard demo again. Engine side (main.c): after the explicit .pbm argument and ahead of the preset files, the app now reads `poi_map.txt` (cwd / host0: / ms0:) naming an arbitrary staged map, with the same fall-back-to-default behavior the preset path has. Standalone Memory-Stick installs of a scratch map = copy `poi_scratch.pbm` + `poi_map.txt` next to the EBOOT. The stale shipping slot on disk is re-cut by this round's full test run (test_pb_map_showcase re-exports it from the courtyard).
  * NEW: viewport MODE BANNER + always-armed placement modes for the Material dock's tabs:
    - A small top-center banner over the 3D scene (PBModeBanner, mouse-transparent) shows the active mode and its exit route — e.g. "Texture paint mode — drag on a face to paint · select the Material & UV tab to exit", likewise Stamp, Sprite placement and Shape mode (with the armed shape's name). The dock emits `dock_mode_changed`; the plugin arms/disarms the matching viewport tool and composes the banner text.
    - Sprite tab: the tab IS the mode — switching to it arms billboard placement and it STAYS armed (placing one sprite re-arms for the next; Esc cancels the current placement only; exiting = selecting the Material & UV tab, as the banner says). The "Place Sprite (B)" button is REMOVED, replaced by a written placement guide (click places the selected sprite; drag/wheel opens the texture carousel; up/down raises, left/right scales; a sprite set on the tab always SKIPS the carousel unless you hold/drag). The B key and the New Shape menu's Sprite entry land on the same tab-driven mode. Also fixed here: `sprite_placer.disarm()` was called by the Trim Walls arming path but never existed (Nonexistent-function crash when arming Trim Walls mid-sprite-session) — added as the abort-equivalent teardown.
    - NEW Shapes tab: a fifth dock mode with its own always-armed primitive placement. The tab shows a palette of every drag-creatable shape (PBShapeFactory ids minus sprite/ngon), each card rendered once per editor session as a real 3D silhouette preview (small SubViewport render) in its OWN bright color — a golden-angle hue walk gives every shape a distinct saturated hue, reused as the selected-card border. Picking a card arms that shape immediately (the same path the New Shape menu uses); after every placement (Apply/Cancel of the params modal, Esc, tiny-drag abort) the same shape re-arms so the tab is a placement "mode" and not a one-shot. Deliberate switches (new shape picked, another tool arming) do not re-arm.
  * NEW: quick Lit / Cast Shadows toggles for the selected objects — two toggle buttons on toolbar row 3 (the extended bar) with 16x16 SVG icons, plus rebindable hotkeys `Object: Toggle Lit (Selected)` / `Object: Toggle Cast Shadows (Selected)` in Editor Settings → Shortcuts (default unbound). Semantics follow a mixed checkbox: all-lit (respectively all-casting) = checked, all-off = unchecked, MIXED = unchecked — checking it synchronizes every selected object, unchecking clears all; hotkeys flip the combined state. Applies to PBMesh (mesh-data materials, rebuilt), plain MeshInstance3D (material_override first, else per-surface override copies — shared mesh resources are never mutated), and CSG primitives. Shared/persisted materials (.tres) are duplicated with their resource_path severed before flipping, so toggling one object can never re-shade another object sharing the material or write back into the shipped .tres. "Lit" follows the retro pipeline's own convention (shading_mode != UNSHADED, what PBLightBaker keys billboards on); lit target is per-pixel shading. Shadow enable keeps DOUBLE_SIDED nodes double-sided; disable is SHADOW_CASTING_SETTING_OFF; a disabled-then-re-enabled node ends ON. Every toggle is one undoable action. Decisions live in runtime-safe `PBObjectState` (tri-state combine + undo records); the plugin only wraps records into EditorUndoRedoManager actions.
  * FIX: "all the other bundled textures like the water should be registered on a fresh project". `PBMaterialDock.refresh_materials` scanned only `res://` with a depth cap of 3 — `res://addons/poibuilder/materials/textures` sits 4 levels down, so on a fresh install (no res://materials of the user's own) the bundled water/waterfall/tiles/particle textures and shipped stamps never reached the palette and every picker but sprites was empty. The addon's bundled texture folder is now scanned explicitly (before the project scan), and palette cards dedupe by texture FILE NAME so a user's copy of a bundled texture no longer shows twice. Combined with the reclassification below, a fresh project now ships paint textures (water, tiles, brick, checkerboard), stamps (flower patch, tapestry, hello world, circular pattern)  and sprites (trees, bush, grass) in their own tabs. Entering a tab also auto-selects the FIRST matching-classified card as the active tool texture (a paint brush of checkerboard / a "sprite" of checkerboard was noise from picking the default material).
  * NEW: the bundled `circular_square_pattern.png` is a STAMP (PBAssetCatalog DEFAULT_STAMP_NAMES) — it showed only in the paint bucket, never in the Stamp tab.
  * Tests: `test_pb_shape_trim.gd` +1 (UVs tile by world length), `test_pb_object_state.gd` NEW (lit/unlit round-trip, shared-material isolation, shadow states incl. DOUBLE_SIDED preservation, mixed-state combine + synchronization, undo-record replay, Shapes palette contents + bright-color distinctness, action-table registration), `test_pb_asset_catalog.gd` +1 (circular pattern is a stamp). Full suite: 1097 tests, 21164 asserts, 68 suites, failures=0.
- Version bump 0.9.144 -> 0.9.145.
- Palette dedupe, creation rejection, banner restyle, sprite shadows, README (v0.9.146):
  * FIX: "material & uv is showing all the billboards and also showing some of the stock materials multiple times like the default material appears 3 times". Two palette changes: (1) MATERIAL mode (and the new Shapes tab, which shares its palette) now shows real materials plus plain paint textures — sprite/stamp/particle-classified textures stay in their own tabs instead of flooding the material palette; (2) the palette dedupes on a KEY SET (resource path, source-texture path, and the albedo texture's path), so the same stock material arriving via the default-material setting, the active mesh, the project scan, or a plain texture wrapper of the same image collapses into ONE card.
  * FIX: "when i just accidentally click when placing e.g a cube it will create a tiny cube that has an exclamation mark and sometimes the vert overlay stays on screen... undoing after a broken placement makes more exclamation mark nodes. just reject anything that is smaller than grid step or otherwise invalid". `PBShapeCreator.end_base` only rejected drags where BOTH extents were under 0.1 m, so a ~12 cm one-axis click-jitter passed and committed a degenerate sliver. The DOMINANT extent must now reach `max(0.1, grid step)` — with snapping on the drag quantizes to whole cells first (a sub-half-cell jitter quantizes to zero and dies), with snapping off the step still floors the check. The LATERAL extent may stay small on purpose (a straight 2 m x 5 cm drag is a legitimate thin wall). `_creation_confirm` additionally refuses degenerate geometry (no faces, <3 positions, NaN positions) and aborts like an undersized drag, so an invalid shape can never reach the scene, the undo history, or the overlay again. Tests: jitter-drag rejected (snap on and off), thin-wall drag accepted.
  * FIX: "the overlay text is partially off screen to the left... make it a simple white text with black border like the size overlay. remove the part that mentions the shape as it's redundant". PBModeBanner is now a plain Label in the cursor-extents style (white text, black outline, no panel), kept centered by repositioning on text/host resize (the anchor preset fought the dynamic width and could hang the label off the viewport edge), and every placement mode shows the same one line: "Select Material & UV tab to exit placement mode".
  * FIX: "the material palette for shape placement mode should just be the same palette as material & uv tab and synchronized with it" — SHAPE mode now renders the identical filtered palette with identical click behavior (apply to selection / right-click default) instead of hiding it.
  * FIX: "the sprites are never casting shadows now". Two causes. (1) The sprite placer's billboard material used soft TRANSPARENCY_ALPHA — Godot's shadow pass renders only alpha-scissor geometry, so a placed sprite NEVER cast a real-time shadow regardless of the cast-shadow setting; the material is now TRANSPARENCY_ALPHA_SCISSOR (sprite art is a hard silhouette), which also exports as the PBM cutout mode exactly like the showcase's trees. (2) In the retro bake, placed sprites (PBMesh, shape_id "sprite") missed the light baker's billboard predicate and fell into the plain-mesh path — an opaque full-quad occluder (rectangle shadow) with the texture silhouette never sampled. The predicate now mirrors `PBMapExporter._is_billboard` and the billboard branch falls back to the ArrayMesh surface material when no override is set (a no-material sprite still enters the grid as a plain occluder rather than disappearing from it). Tests: placed sprite is shadow-casting with a scissor material; the bake collects silhouette (alpha) triangles for a placed sprite.
  * README rewritten into a dense overview: the intro, video, AI warning and similar-project links are unchanged; the PBM retro pipeline is highlighted with file-format/addon features (bakes, atlasing, collision hulls, UV scroll, emitters lump, metadata, alpha modes) separated from the bundled PSP demo engine (DMA vertex format, swizzled textures, measured LOD policy, device numbers); the feature checklist is one dense list, the feature-gap list is gone, and the "how this project is built" section is compressed (the agent workflow notes stay).
- Version bump 0.9.145 -> 0.9.146.
- Stray-click creation leak root cause, order-independent palette dedupe (v0.9.147):
  * FIX: "clicking without dragging still breaks shape placement: the vertex overlay is persistent and it makes an errored shape that complains about a MeshInstance3D not having a mesh". Reproduced in a live editor and root-caused: arming a shape and PRESSING on a surface immediately creates the preview PBMesh in the scene (named Shape_Cube, owner set before first draw) and the BASE phase deliberately renders it MESHLESS (the outline-only stage). On release, `PBShapeCreator.end_base()` rejects an undersized base by calling its own `reset()` — which NULLS `preview_node` — and the plugin's `_creation_abort` then read the already-nulled reference and SKIPPED the node teardown. Every rejected release (a bare click, or a drag under the new step floor) therefore leaked exactly one meshless PBMesh WITH its live base-outline/vertex gizmo: the warning-icon "broken object" and the persistent overlay, stacking one per click (and each carried data + a name, so undo interactions around them corrupted further). Fix: `_creation_end_base` captures the preview BEFORE calling `end_base()` and tears it down explicitly when the base is rejected; the creator's rejection contract is unchanged. Verified in the editor: a bare click and a 1 px-drag click now leave the scene with zero new nodes, `preview_node` null, and the hover overlay cleared. Regression test added to the GUI harness (synthesized click, asserts no meshless PBMesh, no preview reference, no hover leak); headless tests cover the state contract.
  * FIX: "stock texture still appears twice". The v0.9.146 palette dedupe registered keys during the scans, so it was ORDER-DEPENDENT: a bundled/project texture wrapper scanned before the saved material referencing the same image kept both cards (the default material's checkerboard appeared as the starred .tres AND as a wrapper). `PBMaterialDock._collapse_duplicate_materials` now runs a post-scan collapse pass: saved materials (.tres) always win over wrappers of the same image, first wrapper wins among wrappers — order-independent. Test drives both orders plus the saved-vs-saved non-collapse.
- Version bump 0.9.146 -> 0.9.147.
- Transparency auto-detection, scroll carry, face opacity, Particles tab (v0.9.148):
  * FIX: "when I author a plane with the water texture, the texture doesn't appear transparent in godot but once baked to the psp it is transparent". Root cause: the PSP exporters pick a texture's alpha handling from its PIXELS (`PBMapExporter._narrow_alpha_mode`), but the Godot palette wrappers left transparency DISABLED, so the editor showed an opaque quad while the device blended. NEW `PBAlphaDetect` (`materials/pb_alpha_detect.gd`): classifies a texture once per session (no alpha -> opaque; 1-bit alpha -> cutout/ALPHA_SCISSOR; soft alpha -> blend/TRANSPARENCY_ALPHA — the exporter's own decision) and applies it to any StandardMaterial3D whose transparency is still disabled, duplicating saved .tres resources detached-first so nothing on disk is rewritten. Hooked where materials are born and applied: the dock's palette scan, the +Add file dialog, `PBMeshData.load_material_or_texture`, and every face apply via `PBApplyPrep` — so preview and bake now agree with zero manual toggles.
  * FIX: "the scrolling preview often pauses in godot e.g if i change material - it should keep its scrolling properties". Two defects: applying a material onto a scrolling face replaced the animated per-face material with a static palette card (the waterfall silently stopped), and the apply path never re-registered the new material so even a scrolling replacement sat still for up to one 1.5 s scan period. `PBApplyPrep.prepare` (pure static, headless-tested) now carries the faces' previous scroll speed onto the incoming material (on a detached copy; an incoming material's own scroll always wins) and `apply_faces_material` re-runs `scan_scrolling_materials()` immediately after every apply — also covering the drag-and-drop path, which routes through the same function.
  * NEW: Face Opacity — an Opacity slider next to Face Tint in Material & UV writes the tint's ALPHA channel on the selected faces (whole object when nothing is selected; Reset restores 1.0). In Godot it multiplies through vertex_color_use_as_albedo; below 100% the faces' material is flipped to TRANSPARENCY_ALPHA on a detached copy (an opaque material can never show vertex alpha anywhere). On PSP the same alpha byte rides the exported vertex colour: the retro bake previously REPLACED vertex colors wholesale (light bake forces a=1), so `_export_retro_pb_mesh` now multiplies each fragment's face tint back into the baked colours (tint RGB — previously lost in the bake too — and alpha), the modern bake multiplies the authored per-vertex colours, and the billboard bake multiplies the billboard material's albedo colour (its tint's only home) — so a dimmed face, mesh or billboard fades on the device. Device caveat, stated in the control's tooltip: alpha only blends on surfaces whose texture alpha mode blends, hence the material flip; per-emitter opacity rides the same vertex-colour path.
  * NEW: the Particles dock tab — click-to-place particle emitters shaped like the reference courtyard PSP demo's, without touching a GPUParticles3D inspector. The palette shows ONLY particle-classified textures (PBAssetCatalog "particle": the shipped particle_flame/glow/smoke sheets, or your own `particles/` folder / `particle_` prefix); picking a card selects its PRESET keyed on the texture family (flame = additive fire, smoke = soft-blended upright mist, glow/default = cheap additive). Placement: click a surface -> a LIVE GPUParticles3D preview appears (real particles in the editor) with mouse up/down lifting it off the surface billboard-style -> click locks the offset -> mouse left/right tunes the particle COUNT, wheel tunes the particle SIZE -> click commits (one undoable action, always re-armed like the sprite tab; Esc cancels; fine tuning via the overlay's "Edit Emitter Properties" outside particle mode — count/size/speed/lifetime/spread/rise/opacity/additive/upright/sheet grid, live-previewed, applied/cancelled as one undo). Construction lives in `PBParticleParams` (single source with the exporter's field mapping: the alpha-ramp knee, scale curve, BILLBOARD_PARTICLES sheet grid, `poi_seed`/`poi_y_locked` metadata, deterministic seed) so a placed, hand-tuned and exported emitter cannot drift. PSP soft caps are surfaced, not silent: the count knob clamps at the 64-per-emitter format cap, size at 4 m (fill rate, not count, is the device cost), and the tab shows a live "x / 256 map budget" readout that turns amber when the scene exceeds the measured 256-particle map budget (the exporter still clamps per emitter either way). Feedback: green ring + stem + emission-arrow guide (no depth test, editor-only named/meta'd so it can never export), phase hints in the creation row, and the floating cursor readout like the sprite placer. A plain GPUParticles3D remains fully supported — the tab just removes the friction.
  * Tests: `test_pb_alpha_detect.gd` NEW (opaque/cutout/blend classification, in-place vs detached-duplicate transparency, no downgrades, scroll carry + non-override + transparency-on-apply through PBApplyPrep), `test_pb_particle_placer.gd` NEW (presets, exporter-record parity of a placed node incl. additive/y-locked flags and the ramp knee, values round-trip, count/size caps, full click->RAISE->TUNE->commit gesture, Esc cleanliness, budget readout flagging, param-def caps, dock palette filtering), `test_pb_opacity_export.gd` NEW (50% face tint survives the retro bake at 0.5 vertex alpha, default mesh stays 1.0, billboard albedo alpha bakes through — with the PrimitiveMesh material fallback), GUI harness + PARTICLE blocks (arm, live preview, tuned count within the cap, committed emitter with seed meta, water palette card blended via ALPHA-DETECT, dock tab routing, disarm-on-exit, Edit Emitter Properties session landing an applied count). Full suite: 1125 tests, 21483 asserts, 71 suites, failures=0.
  * FIX (GUI harness flake, hunted via bisect): the EXTRUDE-INWARD real-editor click intermittently selected nothing under the software renderer (cascading into the UV-Fit assert reading an un-extruded mesh). Instrumentation proved the pick itself healthy — the same world position, camera and mesh state produce a valid `pick_ray` hit at failure time, and merely adding a debug print to the pick path makes the test pass (a Heisenbug: the click->pick chain — focus hand-off, deferred selection signals, gizmo redraw scheduling — is timing-sensitive, and a few milliseconds of extra boot work anywhere can flip it). Test 6 now retries the click once and, if the engine routing is still wedged, falls back to the same programmatic `pick_ray` + `set_subgizmo_selection` the plugin itself uses — the test's subject is the INWARD-EXTRUDE winding, not click routing (covered by tests 3 / 5a / 5b). Also harness-side: the particle block restores a PBMesh selection when it ends (its committed emitter is a plain GPUParticles3D; leaving it selected left the UV canvas without an active mesh, exactly like the sprite block leaving its billboard). No plugin behavior changes.
- Version bump 0.9.147 -> 0.9.148.
- Real-PSP verification of v0.9.148, probe tooling, billboard texture fix (v0.9.149):
  * FIX: a plain `MeshInstance3D` billboard whose material rides the QuadMesh/PrimitiveMesh (`quad.material = mat`, the shape the authoring docs' `is_billboard` recipe produces) exported UNTEXTURED: `_export_billboard`'s material lookup covered material_override, ArrayMesh surfaces and PBMesh face materials but not PrimitiveMesh.material — only the new tint multiply had the branch, so the opacity bake worked while the texture fell off. The same branch now feeds the texture registration; the feature map below caught this on device (billboards drew white before it).
  * NEW: `./psp_probe.sh` — the 5-second "can I see the PSP?" check agents were skipping (one session shipped "no PSP connected" caveats while the device sat answering on USB). Three layers, verdict at each: USB device (054c:01c9), the udev /dev/psp symlink, and the actual PSPLink link (temporary usbhostfs_pc + pspsh modlist, only when no other instance owns the singleton). The retro orientation doc now mandates probing before any device claim.
  * FIX: `run_psp_hw.sh` died with SIGPIPE (exit 141) right after staging once hwrun/ accumulates many screenshot BMPs — `ls -la | head -12` under `set -o pipefail` kills the script when `ls` out-writes the pipe buffer and `head` exits. The `head` became `sed -n '1,12p'` (consumes all input), and stale BMPs are cleaned.
  * Device round (PSP-2000 over PSPLink/usbhostfs): the v0.9.148-exported courtyard battery measures worst pose 7.21 ms/frame (cpu 4.52 / gpu 2.70; every other pose 4.4–6.8) — inside the 16.67 ms budget, with the GPU column matching the documented 2.71 baseline exactly and the calibration probes reproducing the documented fill rates (483–488 Mfrag/s plain, 26.9 Mfrag/s 512²-miss). A new feature map (`project/tests/build_v148_feature_map.gd`, headless exporter run) verified on device at 59.9 FPS (cpu ≤2.1 / gpu 0.10): auto-detected blended scrolling water, auto-detected cutout billboards (textured — the fix above), a 40%-faded billboard, and two Particles-tab preset emitters (additive flame + blended upright smoke) alive at 24+12 particles. The dimmed-face A/B was also verified at the byte level in the exported map (blend alpha mode + vertex alpha 127 on the dimmed face's fragments, bright on the solid twin); its on-screen contrast needs a better-lit test scene — the first feature map accidentally built the floor as an 8-metre solid cube, which swallowed the spawn, shadowed the bake and made every view read black (kept as a caution: `PBMesh.create_cube(8.0)` is a solid 8×8×8, not a pad).
- Version bump 0.9.148 -> 0.9.149.
