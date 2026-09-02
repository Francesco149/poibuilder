## Phase 6 human sign-off scene: cube + printed checklist.
##
## The plugin now integrates through Godot's NATIVE editor machinery
## (EditorNode3DGizmoPlugin subgizmos): the editor itself handles element
## picking, rubber-band selection, the transform gizmo (its own Q/W/E/R
## toolbar modes), snapping, and undo. Verify THAT nothing fights.
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
	print("========== Phase 6 human checklist (native subgizmo integration) ==========")
	print("Setup: enable the ProBuilder plugin if needed, select PBCube in the 3D view.")
	print("")
	print("Object-level (native behavior must be untouched):")
	print("  1. Selecting PBCube auto-enters FACE mode; toolbar shows Vertex/Edge/Face.")
	print("  2. The orange selection box hugs the cube. NOTE: this box is engine-native")
	print("     (drawn for every selected Node3D); removing it per-node is not possible")
	print("     in Godot 4.7 without breaking mesh rendering — documented limitation.")
	print("  3. Q/W/E/R switch Godot's own Select/Move/Rotate/Scale; camera orbit/pan/zoom")
	print("     work everywhere EXCEPT while actually dragging an element.")
	print("")
	print("Element picking:")
	print("  4. Click a face -> cyan highlight; Godot's transform gizmo jumps to THAT FACE,")
	print("     not the cube center. Shift-click toggles; click empty space clears.")
	print("  5. Box select starting on EMPTY SPACE -> Godot's dashed marquee selects faces")
	print("     in the rect; the marquee is Godot's own and never lingers afterwards.")
	print("  6. H/J/K switch Vertex/Edge/Face; vertex dots / edge highlights render;")
	print("     box select works in each mode; switching mode clears the selection.")
	print("")
	print("Manipulation (Godot's own gizmo + toolbar modes):")
	print("  7. W + drag an arrow -> face translates; welded corners stay welded;")
	print("     adjacent faces stretch. Ctrl+Z undoes, Ctrl+Shift+Z redoes. No teleporting,")
	print("     and repeated fast drags never compound.")
	print("  8. E + drag a ring -> face rotates about its own centroid. Undo.")
	print("  9. R + drag -> face scales about its centroid. Undo.")
	print(" 10. X cycles gizmo space Element -> Object -> World; the gizmo axes visibly")
	print("     re-orient each time (Element = face normal, Object = node axes, World = world).")
	print(" 11. Hold Ctrl while dragging -> Godot's snapping applies natively.")
	print("")
	print("Negative checks (the Phase 6 regression cluster):")
	print(" 12. Clicking/dragging EMPTY SPACE never moves the cube.")
	print(" 13. Dragging an element never simultaneously draws a selection marquee.")
	print(" 14. No cyan marquee (ours is gone; Godot's never sticks around).")
	print(" 15. Nothing fights: only ONE gizmo is ever visible (the editor's own, at the")
	print("     element/object pivot), and selecting faces always responds on the first click.")
	print(" 16. VERTEX mode: dragging a corner moves THAT corner (the gizmo's corner), with")
	print("     all 3 welded positions of the corner moving together — never a neighbor.")
	print(" 17. EDGE mode with the cube edge-on: clicking an edge picks the VISIBLE (near)")
	print("     edge, never a hidden far-side edge showing through the mesh. Faces stay")
	print("     quads (n-gons): no triangulation diagonals appear in the edge list.")
	print("")
	print("Tool Properties dock (bottom-left): shows mode, space, selection counts, and a")
	print("live Delta/Rotation/Scale readout while dragging.")
	print("=============================================================================")
