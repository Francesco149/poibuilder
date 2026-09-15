# Architecture — How The Plugin Is Put Together

## Bootstrap (`poibuilder_plugin.gd`, ~3000 lines, the EditorPlugin)

`_enter_tree` order matters (later wiring assumes earlier):
1. `set_input_event_forwarding_always_enabled()` — shape creation must work
   with NOTHING selected (the engine otherwise only forwards viewport input
   when `_handles()` matches the edited object).
2. Subsystem wiring: `editor` (PBEditor state) is the hub; `gizmo_plugin`
   and `element_editor` get editor/grid/undo references; controllers
   (shape_creator, ngon_drawer, sprite_placer, paint_controller) get the
   plugin/grid.
3. `PBActions.register` — every shortcut goes through the rebindable action
   table (Editor Settings → Shortcuts). Viewport keys funnel
   `_forward_3d_gui_input` → `_handle_action_key` → action match; actions
   with a PoiBuilder context STOP the event, everything else PASSES so
   engine shortcuts keep working. Grid keys work with nothing selected.
4. Toolbar (a row BELOW the 3D toolbar), tool overlay (floating panel in
   the viewport), material dock (right-UL; other docks are reparented to
   right-UR by `_setup_ideal_dock_layout`), UV editor bottom panel, export
   dialog — all created and connected here.
5. `add_node_3d_gizmo_plugin(gizmo_plugin)` — THE integration: element
   picking, rubber-band, transform drags, snapping, undo are driven BY the
   editor THROUGH the subgizmo API.
6. Tool bridge attaches to the engine's Move/Rotate/Scale buttons.

`_exit_tree` must mirror EVERY addition (the historical bugs were all
"X still there after disabling the plugin") — including dropping half-created
previews without putting them into undo.

## Input: clicks pass through UNTOUCHED

`_forward_3d_gui_input` NEVER consumes mouse clicks. The engine's own
priority applies: transform gizmo hit-test first, then subgizmo picking /
rubber-band. Interception here is what broke gizmo drags in earlier rounds.
The plugin only OBSERVES motion (hover into `editor.hover_id`, one
`update_gizmos()` per real change) and REMEMBERS the last press position
(`_last_mouse_pos/camera/msec`) so entering a PBMesh auto-picks the element
under the cursor (deferred; the engine is mid-selection-change).

## The data model (`core/`)

- `PBMeshData`: `positions` (PackedVector3Array), `faces` (Array[PBFace];
  a face owns triangle INDEX triples + submesh/uv/smoothing data),
  `shared_vertices` (Array[PBSharedVertex] — weld groups of coincident
  positions), derived `get_common_edges()` (group-pair deduped, cached),
  `get_shared_vertex_lookup()` (position index → group index).
- WELDS: `ensure_welds()` runs on every active-mesh change — broken welds
  make element ids resolve to raw position pairs and tear corners apart on
  drag ("moved those 2 verts" bug). `rebuild_welds()` after any op that
  SPLITS coincident positions (extrude/inset commits) or the drag union
  carries stale group members.
- Winding contract: internal data CCW-from-outside (Unity);
  `to_array_mesh()` reverses index triples for Godot's CW front faces;
  normals pass through UNCHANGED (outward). Locked by
  `tests/test_pb_winding.gd` — do not "fix" winding without reading it.
- `PBMath.average(positions, indexes)` is the canonical centroid — use it
  instead of inline sum/div loops.
- Mutating a mesh: modify → `invalidate_caches()` → `calculate_normals()` →
  `node.rebuild()` → `node.update_gizmos()` (or go through a mesh op +
  `_finish_mesh_op`, which does all of it).

## The gizmo plugin (`editor/pb_gizmo_plugin.gd`, thin adapter)

- `_redraw(gizmo)` is a FULL clear + redraw on every `update_gizmos()`.
  Order: collision triangles (cached per mesh instance via the
  `_pb_pick_tmesh` meta — the engine's click/rubber-band picking runs
  through gizmo collision ONLY, and stock triangle meshes go stale because
  PBMesh never emits property-change notifications) → creation/drawer
  overlays → wireframe → `_mirror_engine_selection` → per-mode selection
  highlights (EXPANDED ids) → hover highlights → center scale handle.
- Editor-only classes cannot be instantiated headless: every DECISION lives
  in `pb_element_editor.gd` (runtime-safe, headless-tested); the plugin
  only adapts engine virtuals to it.
- Draw materials: wireframe/hover/selection opacities are user settings
  (`poibuilder/display/*`); strokes/fills scale with camera distance
  (`_live_stroke_offset/_live_fill_offset`) so overlays read at any zoom.

## State (`editor/pb_editor.gd` — state only, no algorithms)

- `select_mode` (OBJECT/VERTEX/EDGE/FACE/TEXTURE) — REMEMBERED
  (`_last_element_mode`) across selection changes so re-entering a mesh
  restores the mode. An EXPLICIT object mode (`_object_mode_explicit`)
  survives deselect+reselect; the IMPLICIT one (fresh editor) hands over to
  the remembered element mode on first selection. UV-panel sync must not
  fight this (`b44d0fc` fixed the bounce).
- `tool_mode` (MOVE/ROTATE/SCALE) — the plugin's OWN tool; the engine's
  universal gizmo is never used while editing.
- `orientation_space` (ELEMENT/OBJECT/WORLD, X key / space button).
- Signals drive toolbar/overlay/dock refresh; the plugin listens and
  applies to the engine.

## Tool bridge (`editor/pb_tool_bridge.gd`)

- Presses the ENGINE's Move/Rotate/Scale tool buttons to mirror our tool;
  DISABLES the engine's Transform(Q)/Select(V) buttons while editing (a
  disabled button also ignores its shortcut); while editing with NO
  selection the engine idles in its SELECT tool (builder mode must never
  show the whole-object transform gizmo — and select mode is what makes
  click-selecting other nodes work natively).
- Orientation space: the engine's gizmo only adopts a subgizmo's basis
  while its OWN local-coords toggle ("Use Local Space", T) is ON — there is
  no other script hook (`update_transform_gizmo()` in the engine C++). The
  bridge finds that toggle (shortcut identity, fallback physical T) and
  presses it: WORLD → OFF, ELEMENT/OBJECT → ON. While editing the toggle is
  DISABLED so T can't fight the plugin; a stray external flip is re-asserted
  via the `toggled` listener.
- Also drives: engine snap tracking our grid in OBJECT mode, hiding the
  engine's stock grid in any PoiBuilder context, and the View-Grid menu
  lookup (`find_editor_menus` walks the base control tree).

## Toolbar & overlay placement (VERSION-SENSITIVE, do not "simplify")

- Toolbar row: a throwaway anchor is added to CONTAINER_SPATIAL_EDITOR_MENU
  and walked UP: anchor → context panel → HFlowContainer → toolbar
  MarginContainer → layout container. In 4.7 the Node3DEditor IS the layout
  VBox (`get_class()` still says "Node3DEditor") — NEVER search descendants
  by the "VBoxContainer" class (that once landed the row inside a hidden
  snap dialog = the invisible-toolbar bug). The row is inserted as a sibling
  AFTER the engine toolbar margin; the engine's VBox sizes it and pushes
  the viewports down.
- Toolbar button icons: bar buttons MUST always be SVG icons (16x16 vector line
  style matching `icons/*.svg`) unless there is a specific load-bearing reason
  for text (e.g. dynamic state readouts like Space, snap step label, or numeric
  inputs). Never ship bare text-only action buttons on the toolbar.
- Overlay: parented to `viewport.get_parent().get_parent()` (the
  Node3DEditorViewport is a plain Control, no container sort — anchored
  children keep place and receive mouse first). Compact by default:
  selection readout while something is selected, drag readout while
  dragging, params modal when a session needs one; auto-hides otherwise;
  draggable by header, pinned via the toolbar Panel toggle. Params modal
  semantics: Apply/Cancel for shape params and bevel; clicking elsewhere =
  cancel for create, apply for bevel; selection change cancels; any mode/
  tool change applies first (`_on_select_mode_changed` /
  `_on_tool_mode_changed`). Numeric fields use the same method as the built
  in Inspector — never hand-rolled drag widgets (that was added, then
  reverted the same day).

## Grid (`editor/pb_grid.gd`, `pb_grid_view.gd`)

The plugin has its OWN grid independent of the engine's: element drags,
extrude gestures, and shape creation snap to it. `grid_view` renders it as a
cyan line mesh injected into the editor's 3D SubViewport scenario (never
pollutes the edited scene); `_process` re-renders only on real staleness.
Grid jurisdiction: while any PoiBuilder context is active (mesh selected,
creation armed, draw-on-grid, elevated grid) the engine's stock grid hides
and ours shows. Settings persist via EditorSettings (`poibuilder/grid/*`);
origin/elevation is session-only on purpose.

## Version-sensitive engine facts the plugin depends on

- `set_subgizmo_selection` = single-id replace, deferred (see
  selection.md).
- `Node3DEditor::_set_subgizmo_selection/_clear_subgizmo_selection` are
  ClassDB-bound group-call targets — script reaches them only via the
  Node3D wrappers.
- Manipulator gizmo size default 80 is halved to 40 on first boot (only if
  untouched — respect user customization).
- `EditorNode3DGizmo.is_selected()` is not script-bound on 4.7 — query
  EditorSelection directly (`_node_selected`).

## Logging & debugging

- PBLogger (categories `plugin/core/mesh_ops/selection/undo/tools/render/
  io/telemetry`) → Godot console. `POIBUILDER_DEBUG=1` enables verbose.
  `PB_BEVEL_TRACE=1` is a separate legacy trace channel in `pb_bevel.gd`.
- The overlay title shows PLUGIN_VERSION — a stale build is immediately
  obvious when behavior "doesn't match" what was fixed (this is why every
  round bumps the version).

## The rest of the module map (moved from CLAUDE.md — single source)

- `editor/pb_shape_creator.gd` — drag-to-create state machine (runtime-safe,
  headless-testable): ARMED → BASE (LMB drag coplanar to the pressed surface;
  floor vs wall extent mapping) → HEIGHT (mouse sets the 3rd dimension along
  the normal, click confirms) → PARAMS (overlay modal; Cancel restores). ESC
  before the confirming click creates NOTHING. `shapes/pb_shape_params.gd`
  holds the per-shape parameter defs, defaults, `build()` dispatch, and the
  drag-extent mapping. TRIM is special: it commits on base release and has
  its own placement (`_trim_placement` — the strip stands on the drag's
  start line, the longer rect side is the run; on walls the split is by
  WORLD direction) — do not "simplify" it back into the generic centering.
- `editor/pb_trim_walls_tool.gd` — the Trim Walls session (click wall faces,
  teal/amber highlights, mitred chaining, floor/ceiling probes, ONE committed
  object whose recorded paths keep params live via
  `PBShapeParams.build(&"trim_walls")`). Headless-testable core; the plugin
  owns the preview node + input.
- `editor/uv/` — dedicated 2D UV Editor: `pb_uv_canvas.gd` (interactive 2D
  canvas: pan/zoom, grid, texture underlay, wireframe, selection),
  `pb_uv_editor_panel.gd` (bottom dock, toolbar, pop-out, selection sync).
- `mesh_ops/` — PBMeshOps topology ops (extrude, inset, subdivide, loop cut,
  merge, weld, delete, detach, knife, bevel, bridge, connect, collapse, fill
  hole) + `pb_csg.gd` (booleans via Godot's CSG kernel; watertightness
  pre-flight). Headless-static.
- `materials/` — default material, shipped textures, splat/decal shaders, the
  paint/splat data model (`core/pb_splat.gd`).
- `export/` — the retro pipeline (see retro.md): `pb_map_exporter.gd`
  (glTF writer, tile/light bakers, colliders) and `pb_pbm_converter.gd`
  (byte-compatible with the Python oracle).
- `gui/` — docks (Material & UV / paint / stamp) + the in-viewport overlay.

Hover highlights are CYAN, selection YELLOW (v0.9.0+): yellow reads as
"selected", cyan as "under your cursor".

## Node-lifecycle ops (CSG booleans, detach, creation): the reference pattern

Any op that adds/removes NODES through undo follows the engine's own
"Remove Node(s)" convention (scene_tree_dock.cpp):
- Node CREATED by the do → `add_do_reference(node)`.
- Node REMOVED by the do (restored by the undo) → `add_undo_reference(node)`.
  POLARITY MATTERS AND IS A CRASH: do-references live in the action's do-ops,
  and `discard_redo()` — which runs on the very next commit after an undo —
  `memdelete`s do-referenced objects. A do_reference on a node the undo
  re-attached deleted that node while it sat in the scene tree (selected!),
  and the next transform commit registered a Callable on a freed object:
  "!p_callable.is_valid()" in add_do_method, then SIGSEGV (the "sphere
  vanished and the editor crashed" round).
- Tree changes go ONLY through undo do/undo methods (performing them
  directly AND registering them double-fires — the committed `add_child`
  errors "already has a parent").
- Every action pins its history with a CONTEXT OBJECT on `create_action`
  (`create_action(name, MERGE_DISABLE, scene_node)`). Without it the action
  lands in the GLOBAL undo history, interleaves with the engine's scene
  actions ("UndoRedo history mismatch: expected 0, got 1"), and cross-history
  resyncs re-run detach/restore ops out of order.
- A reattach helper must restore `owner` + `update_gizmos()` (a node
  re-added without this renders but no longer picks or draws — the
  "CSG undo ghost").
Existing helpers: `_attach_detached`, `_own_node`, `_detach_node`,
`_reattach_csg_cutter` in `poibuilder_plugin.gd`.
