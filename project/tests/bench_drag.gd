## Headless micro-benchmark for the per-motion drag cost (smoothness work).
## Run: godot-mono --headless -s tests/bench_drag.gd
extends SceneTree

func _init() -> void:
	_bench()
	quit(0)

func _bench() -> void:
	var ed := PBEditor.new()
	ed.tool_mode = PBEditor.ToolMode.MOVE
	ed.select_mode = PBEditor.SelectMode.FACE
	var logic := PBElementEditor.new()
	logic.editor = ed

	for face_count in [6, 96, 384]:
		var mesh := PBMesh.new()
		var md := _make_gridded_cube(face_count)
		mesh.pb_mesh_data = md
		ed.active_mesh = mesh

		# Select one face and simulate 60 motion events of a shift+move
		# extrude drag (extrude at begin + per-frame deliveries).
		var ids := PackedInt32Array([0])
		var t0 := Time.get_ticks_usec()
		for frame in range(60):
			var target := Transform3D(Basis(), Vector3(0, 0.02 * (frame + 1), 0))
			logic.set_subgizmo_transform_with_shift(mesh, ids, 0, target, true)
		var t_drag := Time.get_ticks_usec() - t0
		logic.commit_subgizmos(mesh, ids, false)

		# Plain (non-topology) move drag on one face.
		var t0b := Time.get_ticks_usec()
		for frame in range(60):
			var target := Transform3D(Basis(), Vector3(0.02 * (frame + 1), 0, 0))
			logic.set_subgizmo_transform_with_shift(mesh, ids, 0, target, false)
		var t_move := Time.get_ticks_usec() - t0b
		logic.commit_subgizmos(mesh, ids, false)

		# Per-motion rebuild cost: full rebuild vs position-only fast path.
		var t0c := Time.get_ticks_usec()
		for i in range(60):
			mesh.rebuild()
		var t_rebuild := Time.get_ticks_usec() - t0c

		var t0d := Time.get_ticks_usec()
		for i in range(60):
			mesh.rebuild_positions()
		var t_rebuild_pos := Time.get_ticks_usec() - t0d

		print("faces=%d: extrude_drag(60)=%d us  move_drag(60)=%d us  rebuild_pos(60)=%d us (full=%d us)  pos=%d" % [
			face_count, t_drag, t_move, t_rebuild_pos, t_rebuild, md.positions.size()])

func _make_gridded_cube(target_faces: int) -> PBMeshData:
	# Start from a cube and subdivide until we roughly hit the face budget.
	var md := PBMeshData.create_cube(1.0)
	while md.faces.size() < target_faces:
		var all := PackedInt32Array()
		for fi in range(md.faces.size()):
			all.append(fi)
		var result := PBMeshOps.subdivide_faces(md, all)
		if not result["ok"]:
			break
	return md
