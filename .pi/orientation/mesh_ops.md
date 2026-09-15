# Mesh Ops — Rules, Invariants, And The Staleness Bug Class

Read before touching `mesh_ops/` or the op plumbing in
`poibuilder_plugin.gd` (`_on_operation_requested`, `_finish_mesh_op`).

## Op inventory (what exists — do not re-implement)

Extrude faces / extrude edges (fins), inset faces, subdivide faces, merge
faces, delete faces, detach faces (into a new node), weld vertices, insert
edge loop, bridge edges, connect edges / connect vertices, collapse
elements, fill hole, bevel edges / bevel faces, knife tool (n-gon drawer),
snap selection to grid. Gestures: Shift+Move = extrude, Shift+Scale =
inset (both drag-driven, decided ONCE at drag begin — mid-drag modifier
flaps do not re-decide), center-handle uniform scale.

Op keys route through the toolbar pipeline (`PBActions.OP_ACTION_TO_OPERATION`
→ `_on_operation_requested`) so buttons and keyboard share one validation
path. Extrude is ONE action: face mode extrudes faces, edge mode extrudes
fins (`extrude_faces` + EDGE mode ⇒ `extrude_edges`).

## Selection inputs per op

Edge-mode ops read ids through `PBElementEditor.expand_edge_ids`
(`_edge_ids_for_op`) — toolbar clicks must not shrink a loop/ring selection
to its seed. Face-mode ops read `editor.selection.selected_faces` (already
expanded by the mirror). COLLAPSE takes the current mode's ids. Bevel from
FACE mode: full-mesh selection ⇒ bevel all edges; partial selection ⇒
`bevel_faces` (inset-style), amount clamped by the shortest selected edge
length.

## Undo

- Topology-rewriting ops: `CmdMeshOp` with WHOLE-MESH before/after snapshots
  (`PBCommand.copy_mesh_data` / `restore_mesh_data`). Per-index payloads do
  NOT survive element insertion/removal — the undo-stale-view and
  cross-mesh-pollution bugs came from getting this wrong.
- Drag gestures commit per-position payloads (normal) or whole-mesh
  snapshots (topology gestures); see selection.md for the protocol.
- After any commit that split coincident positions: `mesh_data.
  rebuild_welds()` BEFORE snapshotting, or the next grab's union carries the
  unmoved bases ("moving the extruded face moves the whole part").

## Winding invariants (regressions here shipped 8+ times)

- Internal data CCW-from-outside; outward normals; `to_array_mesh()`
  reverses for Godot's CW front faces. NEVER "fix" a rendering artifact by
  flipping winding or negating normals without reading
  `tests/test_pb_winding.gd` first — the bug is usually upstream (an op
  emitted a flipped face), and flipping the converter hides it while
  breaking everything else.
- After ANY face-producing op (extrude, bridge, bevel, knife, subdivide,
  shape gen), verify winding headlessly before claiming done: watertightness
  (every common edge shared by exactly 2 faces), signed volume > 0 for
  closed regions, per-face area > 0. Existing tests to model:
  `test_pb_bevel.gd` (watertight + corner-quads), `test_pb_winding.gd`.
- Inward extrusion must stay possible: sides are wound for the drag-start
  region normal and FLIPPED on the fly when the cap crosses back through
  its base plane (`_drag_side_flipped`) — don't remove the flip.

## Bevel domain rules (the ~20-commit saga)

- A well-behaved domain, enforced not hinted: bevel refuses (returns
  `{"ok": false, "error": ...}`) where the geometry can't produce a clean
  result; the modal's slider max is the op's own representable clamp, so
  every slider position is valid.
- NO silent retries that change the effective parameter (the "0.1 vs 0.11
  ping-pong" bug — a folded-seam check halved the amount until something
  tiny succeeded). Clamp deterministically; surface the limit in the modal.
- Corner rails pair "corner-relative" (both starting at the shared face) —
  pairing by the ring's walk order is natural to write and wrong.
- No corner face may exceed 4 vertices (fans are a bug):
  `test_bevel_corners_are_quads_not_fans`.
- One shared point registry (the `1cb2846` rewrite) — positions created for
  a bevel are deduplicated through it; don't add parallel bookkeeping.

## The staleness bug class (this repo's signature failure mode)

Element ids, weld groups, caches, and selection are all INDEXED state; every
op that adds/removes/reorders elements invalidates them. Five separate
shipped bugs ("stale drag_positions through compact", "stale welds after
topology gestures", "undo-stale view", "cross-mesh undo pollution", "stale
selection after bevel") share the shape: something kept pre-op indices and
replayed them post-op. Rules:

1. After an op, selection is either REMAPPED to the op's output
   (`_apply_selection_set` with created faces — bridge/fill/bevel) or
   CLEARED — never left as-is, never restored to pre-op ids.
2. Mirrors and expansions reset with it (`reset_side_faces()`), and the
   engine subgizmo selection is cleared/set in that order (deferred calls
   run in submission order — clear BEFORE set).
3. Undo payloads: whole-mesh snapshots for topology, per-position for
   drags; a payload must never outlive the topology it was taken from.
4. New derived data (caches, colliders, bakes) is generated in the SAME
   pass as the data it derives from, from the same params — never
   re-derived later from defaults (the collider-at-2x-size bug).

## Param plumbing

`op_bevel_amount/segments` (session values) live in the plugin; the bevel
modal (`_start_bevel_modal`) previews live via `_update_bevel_preview`
(restore snapshot → re-run op → rebuild) and commits via
`_commit_bevel_session` (undo action + select the new band). Numeric modal
params: min=0, step=0.01 for distances so Godot's Range can't phase-shift.
