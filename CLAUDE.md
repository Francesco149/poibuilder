# PoiBuilder (Godot ProBuilder clone)

A Godot 4.3+ editor plugin reimplementing Unity ProBuilder's mesh editing
capabilities. Built from a 37k-line specification extracted from ProBuilder
v6.1.2 source code.

Naming: the plugin is **PoiBuilder** (renamed from ProBuilder in v0.8.0).
The `PB*`/`pb_*` prefix and the `addons/probuilder/` folder+file names are
kept on purpose (they pre-date the rename and res:// paths / .uid files
reference them). Comments citing "ProBuilder" behavior/math refer to Unity's
ProBuilder — the spec source — and are intentional.

## Quick Start

```bash
# Run all tests (ALWAYS use this — never invoke GUT directly; see G4 gate)
./run_tests.sh

# Open in editor for interactive testing
godot-mono --editor project/project.godot
# Then open: test_scenes/human_test_phase6.tscn
```

## Key Documents

- `SPECIFICATION.md` — Complete ProBuilder spec (201 sections, 711 citations)
- `UNITY-GODOT-MAPPING.md` — Unity→Godot API mapping reference
- `IMPLEMENTATION.md` — Phased implementation plan + mandatory verification gates
- `.pi/ORIENTATION.md` — Sub-agent worker orientation

## Reference Repos

- `../probuilder-ref/` — Unity ProBuilder C# source
- `../cyclops-ref/` — Cyclops Level Builder Godot plugin (pattern reference)
- `../godot/` — Godot engine source (4.8-dev, for engine internals).
  NOTE: the INSTALLED engine is 4.7.2-stable — verify APIs against
  `../godot/doc/classes/*.xml` and a real editor boot before using (G5 gate).

## Architecture

Plugin: `project/addons/probuilder/`
- `probuilder_plugin.gd` — EditorPlugin entry: registration, hover tracking,
  H/J/K/X keys. Clicks pass through untouched (the engine's own priority
  applies: the transform gizmo wins over element picking).
- `core/` — PBMeshData, PBFace, PBEdge, PBMath, PBTopology
- `editor/pb_gizmo_plugin.gd` — THE editor integration: EditorNode3DGizmoPlugin
  with SUBGIZMOS. The native editor does element picking, rubber-band
  selection, transform-gizmo drags, snapping, and
  calls back into us. Thin adapter only (editor-only classes cannot be
  instantiated in headless tests).
- `editor/pb_element_editor.gd` — Runtime-safe element logic: per-element
  origins/bases, idempotent drag math from snapshot, undo payloads, selection
  mirroring. Fully headless-testable.
- `editor/pb_editor.gd` — State: select mode (REMEMBERED across selection
  changes), the plugin's OWN tool mode (Move/Rotate/Scale — the editor's
  universal gizmo is never used), orientation space, hover id, selection.
- `editor/pb_tool_bridge.gd` — Presses the engine's Move/Rotate/Scale tool
  buttons to mirror OUR tool onto the engine's transform gizmo, DISABLES
  the engine's Transform(Q)/Select(V) buttons while editing (a disabled
  button also ignores its shortcut), and drives the engine's local-coords
  toggle (T) to implement the orientation space (below). Headless-testable
  decisions.
- `editor/pb_toolbar.gd` — Persistent toolbar row BELOW the 3D scene toolbar.
  PLACEMENT IS VERSION-SENSITIVE: Node3DEditor must be located by walking the
  anchor's real ancestor path — in 4.7 the Node3DEditor IS the layout VBox
  (`VBoxContainer *vbc = this;`, get_class() still says "Node3DEditor"), so
  NEVER search descendants by "VBoxContainer" class (that found a hidden snap
  dialog's VBox = the invisible-toolbar bug). The row is inserted as a
  sibling AFTER the engine's toolbar MarginContainer; the engine's own VBox
  layout then sizes the row and pushes the viewports down. Icon buttons (SVGs
  in icons/), disabled when no PBMesh is selected; the row never hides.
  Carries: tools (Move/Rotate/Scale), modes (Object/Vertex/Edge/Face), space
  cycler, ALL mesh-op buttons (enable per selection context), New Shape menu,
  Edit Params (pristine factory shapes only), and the Panel (overlay pin)
  toggle.
- `gui/overlays/pb_tool_overlay.gd` — Floating in-viewport PanelContainer
  (bottom-left) in standard panel language. COMPACT BY DEFAULT: carries NO
  op buttons and NO tool/space controls (toolbar has them) — it shows the
  SELECTION readout only while something is selected, the live drag readout
  only while a drag runs, and the shape-params MODAL (Apply/Cancel, live
  preview). Auto-hides otherwise; draggable by its header, collapsible to
  the header, pinned via the toolbar Panel toggle. Clicks on it are
  consumed; everything else passes to the scene. NO docks: debug logging
  goes to the Godot console via PBLogger.
- `editor/pb_shape_creator.gd` — Drag-to-create state machine (runtime-safe,
  headless-testable): ARMED → BASE (LMB drag on any surface, coplanar to the
  pressed plane; floor vs wall extent mapping) → HEIGHT (mouse adjusts the
  3rd dimension along the normal, LMB click confirms) → PARAMS (overlay
  modal; Cancel restores session values). ESC before the confirming click
  aborts with NOTHING created (the preview node never enters undo).
- `shapes/pb_shape_params.gd` — Per-shape parameter defs (name/label/min/
  max/step/default/kind), defaults, build() dispatch to the generators, and
  apply_drag_extents() mapping the base drag + height onto size dims.
- `editor/pb_picking.gd` — Pure-logic ray/screen picking.
- `commands/` — Undo/redo command pattern (CmdMove/Rotate/ScaleElements)
- `shapes/` — Primitive shape generators
- `debug/` — PBLogger, PBTelemetry

Hover highlights: `_forward_3d_gui_input` observes mouse motion (never
consumes), picks the element under the cursor into `PBEditor.hover_id`, and
redraws the gizmo; hover is CYAN and selection YELLOW (since v0.9.0) —
yellow reads as "selected", cyan as "under your cursor".

Orientation space (Element/Object/World, X key or Space button): the engine's
transform gizmo only adopts a subgizmo's basis while the editor's own
local-coords toggle ("Use Local Space", T) is ON — otherwise its basis stays
identity (world axes). There is no other script-accessible hook
(`update_transform_gizmo()` in node_3d_editor_plugin.cpp). So PBToolBridge
finds that toggle button (shortcut identity, fallback physical T) and presses
it: WORLD → OFF, ELEMENT/OBJECT → ON. The engine's `toggled` handler then
calls its own update_transform_gizmo() and also pre-converts drag motion
through the gizmo basis, so element_basis() becomes live for display AND
drag math. While editing the toggle is DISABLED (like Q/V) so T can't fight
the plugin; a stray external flip is re-asserted via the `toggled` listener.

Tests: `project/tests/` (GUT framework, headless-capable).
NEVER claim "tests pass" without run_tests.sh output — GUT silently skips
unparseable test scripts and still reports green.

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
- Edge-loop select (#14): alt+click or double-click an edge selects its
  whole ring. The ENGINE selection stays the seed id (script API is
  single-id); PBElementEditor.selected_loops expands it for dragging,
  highlight, and the PBSelection mirror. Two rapid PLAIN clicks = double
  click; a plain re-click drops the loop.
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

Next: Phase 7 leftovers — bevel edges, connect, bridge. Re-run the printed
checklist in test_scenes/human_test_phase6.tscn for the human pass.

## Key Conventions

- COMMIT SIGNING (mandatory): every commit must end with a blank line plus
  a `Co-authored-by` trailer naming the model that produced it, in the
  format used across the history:
  `Co-authored-by: <provider-slug>/<model-slug> <<provider-slug>+<model-slug>@users.noreply.github.com>`
  e.g. `Co-authored-by: zai-coding-plan/glm-5.3-flash <zai-coding-plan+glm-5.3-flash@users.noreply.github.com>`.
  Derive the slugs from YOUR OWN model id (lowercase, provider path prefix);
  never reuse another model's trailer.
- VERSION BUMP EVERY SIGN-OFF ROUND (mandatory): bump `VERSION` in
  probuilder_plugin.gd, `PLUGIN_VERSION` in pb_editor.gd, and
  plugin.cfg's `version` TOGETHER at the start of every fix/UX round. The
  overlay title is how the human verifies they are running the new build —
  rounds 2 and 3 of v0.9.0 skipped this and shipped fixes the human never
  received (they rightly checked "is it 0.9.0?" and it was).
- REPRODUCE BEFORE CLAIMING: for viewport-interaction bugs (click picking,
  gizmo behavior, creation flow), do not rely on static code reading — use
  `./run_gui_tests.sh` (editor_gui_test.tscn: boots a REAL editor under
  Xvfb and drives synthesized mouse events through the input pipeline,
  asserting selection and creation outcomes). Extend that scene with a new
  test case for every regression it catches. GUT alone cannot see this
  layer; twice, view-port fixes that "looked right" shipped unverified and
  were not fixes.
- The README.md is a purely HUMAN-FACING doc: do not read it for context and
  do not factor it into how you work on the project. The ONLY exception is
  updating the feature checklist when features are completed, when
  explicitly asked to edit it. Everything an agent needs lives here in
  CLAUDE.md, SPECIFICATION.md, and IMPLEMENTATION.md.
- Internal mesh data uses CCW-from-outside winding (Unity convention) —
  PBMath.cross-based normals point OUTWARD.
- Godot renders CW front faces. to_array_mesh() reverses each triangle's
  index order; the normals array is passed through UNCHANGED (outward).
  This is locked by test_pb_winding.gd against BoxMesh ground truth — do not
  "fix" winding or normals without updating that file and reading it first.
- The editor's subgizmo selection is the authoritative element selection
  while editing; PBSelection mirrors it (engine → us, in _redraw).
- Element transforms compose as rel = target_xf * start_xf⁻¹ applied to the
  drag-start snapshot — idempotent under the engine's per-id delivery.
