# PoiBuilder Human Smoke Tests

One page to hand to a human after significant changes. Every workflow gets a
build/command sequence, what to poke, and what "pass" looks like. Order matters
loosely: A creates the map the others deploy/export, so run A first.

All interactive Godot tests use the same first-person controller as the scratch
project: **WASD** move, **mouse** look (click to capture, **ESC** to release),
**Space** jump (Play mode) / ascend (fly cam), **Shift** sprint/turbo.

---

## A. Editor basics — `./scratch.sh`

Launches a clean disposable playground project (`/tmp/poibuilder_scratch`,
rebuilt fresh every run) in the Godot editor.

1. Draw a few shapes (toolbar create tools: cube, stairs, cylinder, custom ngon).
2. Select faces (4), extrude (Shift+Move), bevel an edge, loop-cut a wall.
3. Assign a material (Material dock), then **paint mode**: brush a splat layer
   onto the floor, place a stamp (poster/flower patch).
4. Open the **UV editor** (toolbar UV): click the painted face — texture underlay
   visible on UV1. Switch the channel to **UV2 (Splat — read-only)**: the
   painted composite shows, ops toolbar goes grey, a read-only banner appears.
5. **Pass**: no script errors in the editor console; selection, gizmos, snap,
   paint and the UV editor behave; UV2 view shows the paint, UV1 shows the texture.

## B. PBM → PSP — `./deploy_psp.sh`

Real-device check (needs PSPLink set up once — `./setup_psplink.sh`; see
`retro_engine/RETRO-AUTHORING.md`).

The script enforces the usbhostfs_pc singleton: any leftover instance (e.g.
from `../poichara`'s `--keep`) is killed at start and ours is started fresh —
if you see "Stopping stale usbhostfs_pc" in the log, that was the fix
working, not a failure.

1. In the scratch editor (A): **Export... → Format: PBM**; the default path
   lands in `/tmp/poibuilder_scratch/exports/`.
2. Without an authored spawn, the map starts at the bounds edge facing the
   build — to choose the start point, add a `Node3D` named `Spawn` (its Y and
   yaw are honored) before exporting.
3. `./deploy_psp.sh` — stages the newest scratch `.pbm` onto the device and
   boots the interactive app.
4. Poke: fly the map (analog/WASD-style), cycle render modes (**Select** =
   textured → lighting → wireframe), confirm painted tiles and stamps appear
   baked, lighting looks baked-in.
4. **Pass**: map loads first try (no black screen — if a previous run wedged
   the device, the script's reset handles it), paint visible, no missing tiles.

## C. Retro baked GLB — `./test_baked_glb.sh`

The "does the bake look right in Godot" check (what other engines would get).

1. Export from scratch: **Export dialog → Retro Engine (.glb)**.
2. `./test_baked_glb.sh` — opens the map viewer. **P** toggles FPS play mode
   (walk the map, test colliders), **1–5** render modes, **R** respawn.
3. **Pass**: atlas tiles + vertex lighting render, painted tiles present,
   colliders hold the player, no pink/missing textures.

## D. Modern GLB — `./test_modern_glb.sh`

The "does the plain .glb hold up outside PoiBuilder" check (boots straight
into play mode).

1. Export from scratch: **Export dialog → Modern Engine (.glb)**.
2. `./test_modern_glb.sh` — same viewer, FPS from the start.
3. **Pass**: geometry/materials/colliders intact; decal stamps appear as
   ordinary quads; splat-painted surfaces show the **base** texture (paint
   itself is retro-bake-only by design); no UV garbage.

## E. Splat → lightmaps — `./bake_splat.sh`

The "I decided to lightmap this map" move. Bakes every painted PBMesh to plain
tiles, clears splat data, frees UV2 (Godot's LightmapGI auto-generates UV2 at
bake time when missing).

1. `./bake_splat.sh /tmp/poibuilder_scratch/playground.tscn` (or a modern
   playground path) — prints per-mesh bake reports and saves in place.
2. Reopen the scene in `./scratch.sh`-style editor (or `./modern.sh`): paint is
   now baked textures; UV editor **UV2** channel shows nothing (free); add a
   `LightmapGI` node + `MeshInstance3D` lightmapping and bake.
3. **Pass**: bake report says `had_splat`, scene saves, paint looks unchanged
   in the viewport, LightmapGI bake succeeds with no "regenerated UV2"
   complaints about the previously-painted meshes.

## F. Modern 4k playground — `./modern.sh`

Photorealistic-assets playground (Polyhaven-style 4k props from
`project/test_scenes/modern_assets/` — machine-local, gitignored; auto-extracts
from `/mnt/ephemeral/assets` on first run). `--play` boots straight into FPS;
`--build-only` just (re)builds it headlessly (CI-friendly).

1. `./modern.sh` — editor on a scene with a live-splat floor + three 4k props.
2. Poke: select a statue → **PoiBuilderize** (Object menu) — expect it to warn
   how heavy sculpts are; the marble bust converts (~17k tris, seconds), the
   cliff (940k) should stay a plain MeshInstance3D. Check the statue keeps its
   normal map (tangents survive) and its authored unwrap (manual UV).
3. Paint the floor with a 4k texture, watch the **UV2** debug view while a face
   is selected (status line shows the real-world splat area).
4. Run `./bake_splat.sh /tmp/poibuilder_modern/playground.tscn`, reopen, bake a
   `LightmapGI` (§E).
5. `./modern_workflow_probe` equivalent headless: `cd project &&
   godot-mono --headless -s test_scenes/modern_workflow_probe.gd` — prints an
   OK/NOTE/ISSUE report; exit code 1 on any ISSUE.
6. **Pass**: probe reports 0 issues; poibuilderize keeps texture + normal map;
   bake frees UV2; LightmapGI works.

---

## Fast regression matrix

| Change area | Smoke |
|---|---|
| Editor core / selection / snapping | A |
| Export pipeline (retro) | B, C |
| Export pipeline (modern) / stamps / materials | D, F |
| Splat painting / UV editor | A (step 4), F (step 3) |
| Baking / lightmaps / UV2 | E, F (steps 4–5) |
| Anything touching `player.gd` / scenes | any `--play` launch |

Full headless suite (`./run_tests.sh`) stays the gate for CI — these cover what
only a human with a window can see.
