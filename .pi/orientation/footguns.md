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

## 10. UV2 is owned by the splat system (when splat data exists)

`textures1` has two mutually exclusive meanings, switched by whether the
mesh carries splat data (`has_splat_data` in `PBMeshData.to_array_mesh`:
any `face.splat_bounds` OR any splat material assigned):

- **Splat meshes**: UV2 = per-face planar normalized [0,1] splat-mask
  coordinates, REGENERATED by `PBSplat.ensure_mesh_uv2` on every rebuild
  (`manual_uv` is deliberately ignored there). The UV editor's UV2 channel
  is a read-only debug view — its op toolbar is disabled and canvas gizmo
  transforms are refused (`_apply_gizmo_transform` guards on channel).
  Editing UV2 by hand is a silent no-op: the next rebuild discards it.
- **Splat-free meshes**: UV2 belongs to the author (e.g. a LightmapGI
  unwrap) and must survive rebuilds untouched. The old trigger
  (`not textures1.is_empty()`) clobbered exactly those unwraps — keep it
  dead. Tests: `test_authored_uv2_survives_rebuild_without_splat_data`,
  `test_splat_mesh_regenerates_uv2_on_rebuild`.

LightmapGI reads UV2, so "splat paint" and "lightmap unwrap" cannot coexist
on one mesh — document the bake-down path, don't add a third channel hack.
