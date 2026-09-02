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
