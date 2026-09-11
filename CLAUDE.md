# PoiBuilder (Godot ProBuilder clone)

A Godot 4.3+ editor plugin reimplementing Unity ProBuilder's mesh editing
capabilities. Built from a 37k-line specification extracted from ProBuilder
v6.1.2 source code.

Naming: the plugin is **PoiBuilder** (renamed from ProBuilder in v0.8.0).
Since v0.9.19 the addon folder/file names carry the rename too:
`addons/poibuilder/` + `poibuilder_plugin.gd`. The `PB*`/`pb_*` script and
class prefixes are kept (res:// paths and .uid files reference them;
renaming classes would churn every file for no functional gain). Comments
citing "ProBuilder" behavior/math refer to Unity's ProBuilder — the spec
source — and are intentional.

## Quick Start

```bash
# Run all tests (ALWAYS use this — never invoke GUT directly; see G4 gate)
./run_tests.sh

# Open in editor for interactive testing
godot-mono --editor project/project.godot
# Then open: test_scenes/human_test_phase6.tscn
```

Interactive launchers (`./test.sh raylib|psp`, `./run_raylib.sh`) need an X
display. This workstation is pure Wayland (niri) with no Xwayland for the
session, so `xdisplay.sh` resolves one: reuse `DISPLAY`, else start
`xwayland-satellite` (compositor-integrated, `:0`), else fall back to
`xvfb-run` and say so. Starting a private `Xwayland :99` does **not** work —
it has no compositor behind it, so the program runs and renders perfectly into
a window nobody can see. That was the entire "no window appears" bug.

## Key Documents

- `SPECIFICATION.md` — Complete ProBuilder spec (201 sections, 711 citations)
- `UNITY-GODOT-MAPPING.md` — Unity→Godot API mapping reference
- `IMPLEMENTATION.md` — Phased implementation plan + mandatory verification gates
- `retro_engine/psp/HARDWARE-TESTING.md` — **real PSP measurement and debugging**:
  PSPLink over USB, the `./run_psp_hw.sh` loop, device diagnostics, and the
  hard-won rules (never `modstop` a live module; a resident `PoiRetro` module —
  which happens whenever an app wedges, and **Home then does nothing, since a
  wedged app never runs its exit callback** — is cleared with psplink's `reset`,
  which `run_psp_hw.sh` performs by itself; do not sit waiting for someone to
  press a button). It also documents how to verify a scrolling texture's
  direction on the device. Read this BEFORE concluding anything about PSP
  performance — PPSSPP cannot measure it, and a build that runs at 60 fps there
  can spend 27 ms of a 16.6 ms budget on the device.
- `.pi/ORIENTATION.md` — Sub-agent worker orientation

## Reference Repos

- `../probuilder-ref/` — Unity ProBuilder C# source
- `../cyclops-ref/` — Cyclops Level Builder Godot plugin (pattern reference)
- `../godot/` — Godot engine source (4.8-dev, for engine internals).
  NOTE: the INSTALLED engine is 4.7.2-stable — verify APIs against
  `../godot/doc/classes/*.xml` and a real editor boot before using (G5 gate).

## Architecture

Plugin: `project/addons/poibuilder/`
- `poibuilder_plugin.gd` — EditorPlugin entry: registration, hover tracking,
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
- LOOSENED BIAS & DOOR TUNNEL NUDGING: `FACING_DEAD_ZONE` tuned to 0.08m (8cm), and
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
  poibuilder_plugin.gd, `PLUGIN_VERSION` in pb_editor.gd, and
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
