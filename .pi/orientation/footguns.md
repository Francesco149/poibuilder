# Footguns — Distilled From ~80 Agent Sessions And The Full Git History

Each rule below cost at least one reverted commit or one human round-trip.
When your task is in the area of a rule, the rule wins over your intuition.

## 1. Re-implementing behavior that already exists (the #1 cost)

Examples: re-implementing gizmo-orient-to-centroid (it's the ENGINE's
`update_transform_gizmo` over subgizmos — the duplicate layer broke
extrusions and was fully reverted, v0.9.100–102); regressing draw-on-surface
shape placement to grid-only (the surface path was still in the code);
destroying the overlay's draggable header while touching the panel.
RULES: (a) "X is broken/missing" ⇒ first grep the code + `git log` +
`CHANGELOG.md` for X — regressions look like missing features; (b) before
adding any mechanism, read `orientation/selection.md` /
`orientation/architecture.md` for the existing one; (c) if the user says
"the gizmo was already behaving correctly", believe them and find what YOUR
change disturbed.

## 2. Winding

Eight shipped regressions (cube demo, curved stairs, inward extrude, bridge
over a hole, retro export, PSP demo, sphere half invisible twice). Never fix
a symptom by flipping winding or negating normals; find the op that emitted
the flipped face. See mesh_ops.md invariants and the tests to run.

## 3. Bypassing run_tests.sh

Raw GUT runs are green while suites silently fail to parse. 37 of 77
sessions did it. `./run_tests.sh` (full, unfiltered) is the only claimable
evidence. See testing.md.

## 4. Silent parameter degradation

The bevel "distance ping-pong": a retry loop halved the user's distance
until something succeeded, so 0.11 worked and 0.10 didn't. Never retry with
changed parameters; clamp deterministically and surface the limit.

## 5. Stale indices across topology ops

The repo's signature bug class (five shipped bugs). Remap or clear selection
and caches after every op; never replay pre-op ids. See mesh_ops.md.

## 6. Derived data from defaults

The curved-stairs collider: visual mesh built from drag params, collider
re-derived from shape defaults → floating wall at 2x size. Anything derived
(params, colliders, bakes) is generated in the same pass, from the same
data.

## 7. Improper reverts

"Revert X" means `git reset`/`git revert` to the known-good commit, re-run
the full suite, and smoke-check the behavior — not hand-undoing edits (the
PSP perf revert that "still has the puffs"). If the same spot fails twice,
the expectation is an architecture rethink or an honest hand-off, not a
third patch (bevel needed a from-scratch rewrite after ~4 sessions;
selection conversion needed the reset + redesign).

## 8. Performance claims

PPSSPP/desktop numbers are not evidence; only `./run_psp_hw.sh` rows are.
A change that passes emulation at 60fps once cost 2.5ms → 58ms on device.
Perf-sensitive changes without a connected PSP are UNVERIFIED, not done.
Re-measure and update the doc row in the same commit when changing a
measured default.

## 9. Verification theater

Claiming UI/video/visual work "done" without a rendered artifact or harness
run. Every "done" claim about interactive behavior needs: run_gui_tests.sh
output, an automated checker (e.g. `tools/showcase/cursor_check.py`), or an
explicit human sign-off gate. Show real output — fabrication is worse than
admitting uncertainty.

## 10. Engine API guessing

The `../godot` checkout is 4.8-dev; the INSTALLED engine is 4.7.2. Verify
against `../godot/doc/classes/*.xml` AND the C++ source for editor
internals. Landed wrong before: `EditorSettings.save()` (doesn't exist),
`EditorUndoRedoManager.add_do_method` arity, `set_cull_mask_value` silently
dropping layers > 20, `set_subgizmo_selection` being assumed additive (it
replaces with ONE id — selection.md). Engine internals are a first-class
lookup, not a guess: `Node3DEditor::update_transform_gizmo`,
`_set_subgizmo_selection`, `_select_region` in
`editor/scene/3d/node_3d_editor_plugin.cpp` settle most "how does the editor
behave" questions in minutes.

## 11. UI conventions (violating any = a sign-off bounce)

- Instant-apply + Reset for settings/grid panels; Apply/Cancel ONLY for
  shape params and bevel; clicking outside cancels create, applies bevel;
  any mode/tool change applies the open modal first.
- Numeric fields: the same method as the built-in Inspector — don't hand
  roll drag widgets (added and reverted same-day).
- Panels: bottom-left anchored, clamped on screen, collapsible to header,
  recovery button must itself be on-screen.
- Orderings that bit: free preview nodes BEFORE `update_gizmos()`; reset
  state before the final redraw (knife preview persisted once).
- Display settings apply on FIRST plugin entry too (hover once shipped at
  full opacity until the first settings touch).

## 12. Process

- VERSION BUMP every shipped round, all three files together
  (`plugin.cfg`, `poibuilder_plugin.gd VERSION`, `pb_editor.gd
  PLUGIN_VERSION`) — the overlay title is how the human verifies they run
  the new build (v0.9.0 rounds 2–3 shipped fixes the human never received).
- Commits: logical units, not batches; `Co-authored-by:` trailer from YOUR
  model slug (format in CLAUDE.md). Generated artifacts are never committed
  (~100 MB of history was rewritten once; don't be the second time).
- Subagents: an orchestrator must PROPERLY wait for workers before
  validating/committing their work (a race once committed unreturned work);
  late-project policy: don't spawn subagents unless the user asks.
- UV invariants (recurring review items): textures anchor to a fixed
  object-space point (no resize may make them slide); extrude continues
  tiling across the seam; per-face orientation must match ProBuilder's.
- Knife/n-gon: restrict points to the current face while supporting
  multiple candidate faces on edges; closed shapes touching edges must not
  produce degenerate faces.
- Edge-loop gestures: a loop runs END TO END through 4-valence corners; a
  ring is the parallel walk (what loop cut consumes). They are different
  questions — the video review caught the plugin answering the wrong one.

## 15. KNOWN BROKEN — Trim Walls: Top-swap of loops with openings (deliberate stop, v0.9.117)

Switching a multi-segment loop with openings (doors/arches/stairs) from
Bottom to Top placement does NOT produce a contiguous cornice at the
structure's top edge. Observed despite five fix rounds (v0.9.109-117):
runs around an opening place at the arch/lintel height (the ceiling probe
hits real overhanging geometry; per-face top-edge cross-sections re-
introduce arch-level runs; chains re-wrap through the opening).

**ASSUME THE SIDE-SWAP PATH IS BROKEN for loops of more than one segment
around openings.** Code involved: `PBTrimWallsTool.build/_chain_and_mitre/
_mitre_join/run_segments_at_height/_base_height_for` plus the MIN_TOP_RUN
segment filter. Everything else about the tool (Bottom placement, single
door/stair selections, mitres, probe exclusion, outline reconstruction)
is tested and behaves.

Mitigations that WORK today: Bottom placement everywhere; or select only
the simple faces, move them to Top, delete/re-place the opening-adjacent
pieces manually. The panel's status line reports the wall->run count —
if a swap "does nothing", it produced no runs at the placement edge.

If ever revisited: the fix likely needs the placement line decoupled from
the ceiling probe (a per-run "top edge" the user can set), and an
explicit opening mask (faces flagged as reveal/arch excluded from Top
runs by the user, not heuristically). Do not iterate the heuristics
again blind — that is what v0.9.109-117 were.

## 10. UV2 belongs to the author; splat masks live in CUSTOM0

`textures1` (UV2) is AUTHOR data — a LightmapGI unwrap, usually — and the
splat/decals system never writes it. Mask coordinates travel in the **CUSTOM0
vertex attribute** (`PBMeshData.splat_uvs`, flattened to RG floats by
`to_array_mesh`, sampled by the splat shader through a `splat_uv` varying).

- `PBSplat.ensure_mesh_splat_uv` regenerates the mask coordinates on every build
  from each face's PERSISTED planar rect (`PBFace.splat_bounds`). Resizing a face
  therefore neither stretches nor slides the paint — it clips, which is the
  agreed behaviour.
- Nothing in the splat/decal path touches `textures1`; `PBTileBaker.bake_pb_mesh_in_place`
  clears `splat_uvs` and keeps UV2.
- UV editor: UV1 and UV2 are both editable; the mask view is its own read-only
  channel. Do not "restore" UV2's read-only banner — that was the old contract.
- Decal stamps are PAINTED PIXELS in a per-material decal layer (shader uniforms
  still named `stamp_layer_*` for scene compatibility), not scene nodes. A stamp
  may span faces and may cross an edge; erase is the brush in Decal mode (which
  now paints a colour as well as the palette image). Legacy `PBStamps` node
  scenes migrate on load — but nothing may BUILD them any more: the exporter
  skips `PBStamps` by name, so a node-based stamp never reaches a map (that is
  how the courtyard demo shipped stamp-less).
- The decal image is a WINDOW inside the face's mask space (`stamp_layer_uv_offset`
  / `stamp_layer_uv_scale`), cropped to the painted area and held at 256
  texels/m (the splat masks' density) so a stamp is equally sharp on a 32 m floor
  and a 2 m panel. It grows in powers of two, and only past 8 m of painted span
  does the density drop. **Every** consumer of the decal image must map through
  `PBSplat.get_decal_window` / `decal_uv_from_mask_uv`: the shader, the UV
  editor preview, `PBTileBaker` (both the tile and the face-composite bakers),
  and the modern sidecar (`decal_rect`). Clamp-sampling the image without that
  mapping smears its edge texels over the whole face.
- A decal write is in the mesh's LOCAL space: the pick hands over a WORLD
  normal, and the controller converts it (`local_normal`) before
  `paste_decal` / `paint_decal_dab`. Passing the world normal worked only while
  the mesh sat at the origin unrotated — on anything else the decal basis left
  the face's plane and the stamp smeared into a band.
- Decal alignment cutoffs (`DECAL_MIN_FACE_ALIGNMENT` 0.35, `DECAL_MIN_DAB_ALIGNMENT`
  0.25) exist because a near-perpendicular face gets a DEGENERATE projection of
  the content (a floor stamp down a wall = horizontal streaks). Do not loosen
  them back toward perpendicular.
- Paint + lightmap coexistence is locked by
  `test_pb_splat_and_stamp.gd::test_paint_coexists_with_authored_uv2_lightmap_unwrap`
  and `test_pb_lightmap_uv2.gd`, and was verified with a REAL editor LightmapGI
  bake on a splat-painted, CUSTOM0-masked floor (v0.9.151): the atlas bakes, the
  paint survives, the mesh renders lit.
- The lightmap unwrap (`PBUvOps.unwrap_lightmap_uv2`) needs the unwrap control
  mesh to carry a unique per-vertex tag (COLOR) or the engine's rebuild merges
  per-face duplicates back together and the write-back cannot tell which copy
  got which island UV. Do not "simplify" that away.
