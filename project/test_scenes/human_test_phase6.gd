## Phase 7 UX human sign-off scene: cube + printed checklist.
##
## UX round: persistent toolbar row UNDER the 3D scene toolbar, plugin-owned
## transform tools (never the editor's universal gizmo), remembered element
## mode, yellow hover highlights, a floating in-viewport tool overlay instead
## of docks, and gizmo-first click priority.
@tool
extends Node3D


func _enter_tree() -> void:
	# ALWAYS reset to a pristine cube on load: earlier sessions of this scene
	# were mangled by since-fixed bugs, and testing picking/behavior on a
	# deformed mesh produces misleading results.
	if has_node("PBCube"):
		var existing: PBMesh = get_node("PBCube")
		existing.pb_mesh_data = PBMeshData.create_cube(1.0)
	else:
		var cube: PBMesh = PBMesh.create_cube(1.0)
		cube.name = "PBCube"
		add_child(cube)
		cube.owner = get_tree().edited_scene_root if Engine.is_editor_hint() else self
	print("[Phase6] Cube reset to pristine unit cube (expect V=24 F=6 groups=8 edges=12)")


func _ready() -> void:
	print("========== Phase 7 human checklist (persistent toolbar + own tools + hover) ==========")
	print("Setup: enable the ProBuilder plugin if needed, select PBCube in the 3D view.")
	print("")
	print("Toolbar (persistent row UNDER the 3D scene toolbar, never inside it):")
	print("  1. A 'ProBuilder' toolbar row sits BELOW the scene toolbar at all times,")
	print("     even with nothing selected — buttons disabled (grey) until a PBMesh")
	print("     is selected. Move/Rotate/Scale | Space | Vertex/Edge/Face groups.")
	print("  2. Selecting PBCube enables the row, auto-enters FACE mode, and shows the")
	print("     floating tool overlay panel in the viewport's bottom-left.")
	print("")
	print("Mode persistence:")
	print("  3. Switch to EDGE (J). Click empty space (deselect), then click the cube")
	print("     again → you land back in EDGE mode, not FACE. Same after selecting")
	print("     another node in between.")
	print("")
	print("Hover highlights (yellow, slightly more transparent than selected):")
	print("  4. FACE mode: hovering a face tints it translucent YELLOW (selection")
	print("     stays cyan and reads more solid). Same story in EDGE mode (yellow")
	print("     stroke) and VERTEX mode (yellow dot). Hover follows the cursor and")
	print("     never sticks when you move off the mesh.")
	print("")
	print("Plugin-owned transform tools (never the universal gizmo):")
	print("  5. While editing, the engine toolbar's Q (Transform/universal) and V")
	print("     (Select) buttons are DISABLED — pressing their keys does nothing, so")
	print("     the combined universal gizmo can never appear over elements.")
	print("  6. Move/Rotate/Scale toolbar buttons and W/E/R switch the tool; the")
	print("     toolbar buttons and the engine's buttons stay in sync whichever side")
	print("     you click. The gizmo always shows ONLY that tool's handles.")
	print("  7. Leaving the PBMesh (deselect) re-enables Q/V — the editor returns to")
	print("     stock behavior outside ProBuilder.")
	print("")
	print("Element picking (gizmo now WINS clicks):")
	print("  8. Click a face where the gizmo is NOT → selects it (cyan). The gizmo")
	print("     jumps to that face. Shift-click toggles; click empty space clears.")
	print("  9. Clicking ON the gizmo's arrows/rings drags the gizmo, even when an")
	print("     element sits behind it — the gizmo takes precedence over picking.")
	print(" 10. Box select starting on EMPTY SPACE still selects elements in the rect.")
	print(" 11. H/J/K switch Vertex/Edge/Face; switching mode clears the selection.")
	print("")
	print("Manipulation (unchanged native subgizmo machinery):")
	print(" 12. Move/Rotate/Scale drags behave as before: welded corners stay welded,")
	print("     Ctrl+Z/Ctrl+Shift+Z undo/redo, snapping with Ctrl held, X cycles")
	print("     Element → Object → World space (Space button too).")
	print("")
	print("Overlay panel (bottom-left of the viewport — docks are GONE):")
	print(" 13. No ProBuilder docks in the editor's dock slots anymore. The floating")
	print("     panel shows plugin version, mode + tool + space, V/E/F counts, and a")
	print("     live Delta/Rotation/Scale readout while dragging. Clicks on the panel")
	print("     hit the panel, not the scene; log output goes to the console only.")
	print("")
	print("Negative checks (Phase 6 regressions must stay fixed):")
	print(" 14. Clicking/dragging EMPTY SPACE never moves the cube; no stuck marquee.")
	print(" 15. Only ONE gizmo is ever visible (the editor's own, at the element")
	print("     pivot, in the chosen tool's mode).")
	print(" 16. VERTEX mode: dragging a corner moves THAT corner with all welded")
	print("     positions; EDGE mode: bold black wireframe, big hitbox, visible edge")
	print("     wins over far edge; faces stay quads — no triangulation diagonals.")
	print("=============================================================================")
