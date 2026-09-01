## Phase 6 human sign-off scene: cube + printed checklist.
@tool
extends Node3D


func _enter_tree() -> void:
	if has_node("PBCube"):
		return
	var cube: PBMesh = PBMesh.create_cube(1.0)
	cube.name = "PBCube"
	add_child(cube)
	cube.owner = get_tree().edited_scene_root if Engine.is_editor_hint() else self


func _ready() -> void:
	print("========== Phase 6 human checklist ==========")
	print("1. Enable the ProBuilder plugin if needed.")
	print("2. Select PBCube. Toolbar should show Vertex/Edge/Face.")
	print("3. Face mode (K): click a face so it highlights.")
	print("4. W = Move, drag in the viewport — face translates. Ctrl+Z undoes.")
	print("5. E = Rotate, drag — face rotates about centroid. Undo.")
	print("6. R = Scale, drag — face scales about centroid. Undo.")
	print("7. Q = Select-only. Tool Properties dock (left) shows tool/mode/selection.")
	print("8. Dock settings line shows Delta / Rotation / Scale while dragging.")
	print("Hotkeys: H vertex, J edge, K face, W move, E rotate, R scale, Q select.")
	print("================================================")
