# Selection, Picking, Gizmo — How It Actually Works

Read this before touching ANY of: `pb_selection.gd`, `pb_editor.gd`,
`pb_element_editor.gd`, `pb_gizmo_plugin.gd`, the selection halves of
`poibuilder_plugin.gd`, or anything about select modes / mode switching.
Every selector-related regression since v0.9.90 came from not knowing
something on this page.

## The three layers (and who is authoritative)

1. **The engine's subgizmo selection is AUTHORITATIVE while editing.**
   It lives in C++ (`Node3DEditorSelectedItem::subgizmos`, a HashMap<int,
   Transform3D>) and is NOT script-reachable as a multi-map. What script CAN
   do:
   - READ: `gizmo.get_subgizmo_selection() -> PackedInt32Array` (all ids).
   - WRITE: `node.set_subgizmo_selection(gizmo, id, xform)` — **replaces the
     ENTIRE selection with ONE id** (the C++ is literally
     `se->subgizmos.clear(); se->subgizmos.insert(p_id, ...)`), deferred via
     the `_spatial_editor_group` group call. `clear_subgizmo_selection()`
     clears. THERE IS NO SCRIPT API TO SET N IDS.
   Multi-selections arise only from the engine's own click/shift-click/
   rubber-band paths (C++), which call our gizmo plugin's
   `_subgizmos_intersect_ray` / `_subgizmos_intersect_frustum`.

2. **PBSelection** (`editor/pb_selection.gd`) — the canonical mirror the
   rest of the plugin reads (mesh ops, toolbar, docks, overlay). Per mode:
   `selected_vertices` (SHARED-GROUP indices), `selected_edges`
   (Array[PBEdge], deduped by common edge), `selected_faces` (face indices).
   Engine → PBSelection mirroring happens inside every `_redraw` (before
   drawing) via `element_editor.mirror_engine_selection(...)`. If drag is
   active or engine ids are empty, the mirror does nothing (an empty read is
   a toolbar click stealing focus, not a deselect — wiping there made
   Bevel/Loop Cut no-ops on multi-selections).

3. **Expansion maps** in `PBElementEditor` — how ONE engine id comes to mean
   MANY elements. The engine holds a *seed* id; the maps expand it for
   dragging, highlighting, mirroring, and mesh-op inputs:

   | Map | Mode | Set by | Seed's expansion |
   |---|---|---|---|
   | `selected_loops` | EDGE | alt+click / double-click (loop), shift+alt (ring) via `record_edge_click` | every common edge in the loop/ring walk |
   | `selected_face_groups` | FACE | UV editor island selection (`set_selected_face_group`) | every face in the group |
   | `selected_conversion` | any element mode | mode-switch conversion (`set_conversion_group`) | every id the conversion produced |

   Shared lifecycle: `reset_side_faces()` clears all three (mode switch,
   post-op); the mirror erases entries whose seed left the engine selection;
   a plain (no-modifier) re-click on the seed drops its entry
   (`record_edge_click` for loops AND conversions).

   Expander functions: `expand_edge_ids` (loops ∪ conversions),
   `expand_face_ids` (groups ∪ conversions), `expand_conversion_ids`
   (conversions, used in VERTEX mode where the other two don't apply).
   Everything that needs "the real selection" goes through them — if you
   write a loop that reads `gizmo.get_subgizmo_selection()` raw and uses the
   ids directly, you are probably introducing a bug.

## Subgizmo id spaces (per select mode)

- VERTEX: shared-vertex GROUP index (`mesh_data.shared_vertices[i]`).
  NEVER pass a group id to `get_coincident_vertices*` — it would be looked
  up as a POSITION index and move a different corner (shipped bug).
- EDGE: index into `mesh_data.get_common_edges()` (group-pair deduped).
  Mapping raw picked edges to ids MUST go through group-pair keys
  (`_common_edge_index`) — comparing a group pair to a raw position pair
  with `.equals()` matched 4 of 12 cube edges (shipped bug).
- FACE / TEXTURE: index into `mesh_data.faces`. TEXTURE shares the FACE id
  space and selection.

## The drag protocol (why drags are idempotent)

- First delivery creates the drag: `set_subgizmo_transform(node, ids, id,
  target)` → `_begin_drag` snapshots positions and per-id start transforms
  (`_drag_start_xf[id] = get_subgizmo_transform(...)`), decides the gesture
  (tool + shift), builds `_drag_union` = coincident-expanded position indices
  of every ENGINE id (through `element_indices`, which expands loops/
  conversions).
- Each delivery: `rel = target * start⁻¹`, then positions are recomputed
  from the SNAPSHOT (`new = rel * old`) — repeated delivery is IDEMPOTENT.
  This is the guarantee that killed the "teleporting cube" regression. Never
  accumulate deltas.
- Commit (`commit_subgizmos`) writes an undo action: per-position payload
  (indices + before/after) for normal drags, WHOLE-MESH snapshot for
  topology gestures (shift+move extrude, shift+scale inset). Cancel restores
  the snapshot/positions.
- The engine delivers one target per ENGINE-selected id; rels are identical
  affine maps across ids, so using the latest is correct.
- 4.7.2 quirk: for subgizmo drags whose basis is permuted/flipped, the
  engine's composed origin does not track the mouse. The extrude gesture
  therefore drives cap distance from the CURSOR (`track_mouse`), engaging
  only on real motion events. Synthetic deliveries (tests) keep the rel path.

## Pivot semantics (do not re-implement gizmo orientation)

- The ENGINE positions the transform gizmo at the average of the selected
  subgizmos' origins and takes the LAST id's basis in local-coords mode
  (`Node3DEditor::update_transform_gizmo` — read it in ../godot). Multi-
  select via clicks/marquee therefore already pivots at the centroid.
  This "already existed" when an agent re-implemented it and got reverted.
- Our gizmo plugin additionally draws a CENTER scale handle whose pivot is
  the average of `element_pivot_origin` over engine ids
  (`_draw_center_scale_handle`; `billboard=false` is REQUIRED there or the
  handle drifts off-pivot around the node origin).
- `element_pivot_origin(mesh_data, id)` = `element_origin` for plain
  elements and loop/group seeds; for a CONVERSION seed it is the centroid
  of the full converted set — so the engine gizmo lands on a converted
  selection's center and rotate/scale compose about it. This works because
  the engine applies its gesture to the transform WE reported and the drag
  replays the same affine (`rel = target * start⁻¹`) onto positions — no
  drag math special-cases the pivot. Do not "simplify" this back to
  element_origin without re-reading this paragraph.

## Mode-switch conversion (v0.9.105)

ProBuilder parity: switching element modes CONVERTS the selection (face →
its verts, etc.). Flow in `poibuilder_plugin._on_select_mode_changed`:

1. `PBSelection.convert_between_modes(md, from=_last_select_mode, to, ...)` —
   pure static rules, CONSERVATIVE and symmetric (a target element is
   selected only when EVERY defining element is selected):
   - FACE→VERTEX: all corner groups. FACE→EDGE: all distinct edges.
   - VERTEX→FACE: faces fully covered by the groups. VERTEX→EDGE: edges with
     both endpoint groups selected.
   - EDGE→VERTEX: endpoint groups. EDGE→FACE: faces whose every edge is
     selected. TEXTURE ≡ FACE. OBJECT target / empty result → clear.
2. Clear mirrors + `reset_side_faces()`.
3. `_apply_selection_set(mesh, converted, source_faces)` — the SAME path an
   ordinary selection uses: write PBSelection for the new mode; pick ONE
   seed (`seed_id_nearest_centroid`); `set_conversion_group(seed, ids)`;
   orient continuity via `pick_side_faces[seed] = nearest source face`;
   `mesh.set_subgizmo_selection(gizmo, seed, get_subgizmo_transform(...))`.
4. `_apply_selection_set` is also the tail for ops that create faces:
   bevel Apply selects the new band (`_bevel_session_last_new_faces`),
   bridge/fill select `created_faces` — dismissing a dialog or finishing an
   op must not dead-end the selection.

DEFERRED ORDERING: `set_subgizmo_selection` and `clear_subgizmo_selection`
queue through the engine's deferred group call IN SUBMISSION ORDER — always
submit clear BEFORE set, or the set is wiped.

## Picking

- `pick_ray` (element editor): mode-specific (`PBPicking.pick_face/_edge/
  _vertex`), then an occlusion check against OTHER PBMeshes so clicking an
  object sitting on a huge floor picks the object. `record_side=true` ONLY
  on the click path (`pick_side_faces[id] = face under cursor`) — the
  ELEMENT-space gizmo is oriented by the face the element was selected FROM;
  hover must never re-record it.
- `pick_frustum`: element ORIGIN points in frustum + own-mesh occlusion, so
  rubber-band matches what the user sees.
- Hover: `_forward_3d_gui_input` observes motion, never consumes; hover is
  skipped while buttons are held or a drag is active; hover id changes
  trigger exactly one `update_gizmos()`.

## Grow/shrink/all/invert/snap

Already implemented in PBSelection (`select_all`, `invert_selection`,
`grow_selection`, `shrink_selection` — per-mode private helpers) and grid
snap in the plugin (`_on_snap_selection_to_grid`: positions move, weld
groups keep topology sound, full-mesh undo). Do not re-implement.

## Post-mortem: the v0.9.100–102 selection-conversion failure (reverted)

The first attempt (later `git reset` out of history) kept a PARALLEL
"converted selection" state: it forced a single-element engine selection,
did NOT expand mirrors/drag unions (so only 1 vert stayed selected and undo
moved 1 vert), then added its own `selection_origin`/`selection_basis`
gizmo orientation layer — duplicating behavior the engine already had,
breaking extrude direction, and ending in a full revert. The rule that
replaced it: **conversion must trigger the same code path as ordinary
selection** — write PBSelection, hold ONE seed in the engine, expand via
the maps, let the engine's own gizmo/mirror/drag machinery do everything
else. If you find yourself adding a second source of truth for selection or
a second gizmo-orientation path, stop and re-read this file.
