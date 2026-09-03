## In-depth profiling script for PoiBuilder element dragging pipeline.
## Run: godot-mono --headless --path project -s tests/profile_drag_in_depth.gd
extends SceneTree

func _init() -> void:
	_run_profile()
	quit(0)

func _run_profile() -> void:
	print("=================================================================")
	print("POI-BUILDER ELEMENT DRAG PROFILING (BEFORE vs AFTER OPTIMIZATION)")
	print("=================================================================")

	var ed := PBEditor.new()
	ed.tool_mode = PBEditor.ToolMode.MOVE
	ed.select_mode = PBEditor.SelectMode.FACE
	var logic := PBElementEditor.new()
	logic.editor = ed

	for face_count in [6, 96, 384, 1536]:
		var md := _make_gridded_cube(face_count)
		var mesh := PBMesh.new()
		mesh.pb_mesh_data = md
		ed.active_mesh = mesh

		var vc: int = md.positions.size()
		var fc: int = md.faces.size()
		var ec: int = md.get_common_edges().size()

		print("\n--- Mesh: %d faces, %d vertices, %d common edges ---" % [fc, vc, ec])

		# 1. Profile to_array_mesh: full rebuild vs cached rebuild_positions
		_profile_to_array_mesh_comparison(md, 100)

		# 2. Profile PBElementEditor._apply_drag()
		_profile_apply_drag(logic, mesh, md, 100)

		# 3. Profile Wireframe: legacy Array[PBEdge] vs fast get_common_edge_indices()
		_profile_wireframe_comparison(md, 100)

		# 4. Profile thick lines: legacy multiple allocations vs batched single buffer
		_profile_thick_lines_comparison(md, 100)

		# 5. Face fill: single vs multi
		_profile_face_fill_comparison(logic, md, 100)

func _profile_to_array_mesh_comparison(md: PBMeshData, iters: int) -> void:
	var t0 := Time.get_ticks_usec()
	for i in range(iters):
		var am := md.to_array_mesh()
	var full_us := Time.get_ticks_usec() - t0

	# Fast path (cached indices)
	var t1 := Time.get_ticks_usec()
	for i in range(iters):
		var am := md.to_array_mesh(null, true)
	var cached_us := Time.get_ticks_usec() - t1

	print("  to_array_mesh: full=%.2f us | cached (positions_only)=%.2f us (%.1fx faster)" % [
		float(full_us) / iters,
		float(cached_us) / iters,
		float(full_us) / float(cached_us) if cached_us > 0 else 1.0
	])

func _profile_apply_drag(logic: PBElementEditor, mesh: PBMesh, md: PBMeshData, iters: int) -> void:
	var ids := PackedInt32Array([0])
	var target_base := Transform3D(Basis(), Vector3(0.1, 0, 0))

	logic.set_subgizmo_transform_with_shift(mesh, ids, 0, target_base, false)

	var t0 := Time.get_ticks_usec()
	for i in range(iters):
		var target := Transform3D(Basis(), Vector3(0.01 * (i + 1), 0, 0))
		logic.set_subgizmo_transform_with_shift(mesh, ids, 0, target, false)
	var drag_total_us := Time.get_ticks_usec() - t0
	logic.commit_subgizmos(mesh, ids, false)

	var union := logic.element_indices(md, 0)
	t0 = Time.get_ticks_usec()
	for i in range(iters):
		md.update_normals_for(union)
	var update_normals_us := Time.get_ticks_usec() - t0

	print("  _apply_drag: total=%.2f us/delivery | update_normals=%.2f us" % [
		float(drag_total_us) / iters,
		float(update_normals_us) / iters
	])

func _profile_wireframe_comparison(md: PBMeshData, iters: int) -> void:
	var positions := md.positions
	var pos_size := positions.size()
	var edges := md.get_common_edges()

	# Legacy loop
	var t0 := Time.get_ticks_usec()
	for i in range(iters):
		var wire_points := PackedVector3Array()
		for edge in edges:
			if edge.a >= 0 and edge.a < pos_size and edge.b >= 0 and edge.b < pos_size:
				wire_points.append(positions[edge.a])
				wire_points.append(positions[edge.b])
	var legacy_us := Time.get_ticks_usec() - t0

	# Fast flat indices loop
	var edge_indices := md.get_common_edge_indices()
	var n_indices := edge_indices.size()
	var t1 := Time.get_ticks_usec()
	for i in range(iters):
		var wire_points := PackedVector3Array()
		wire_points.resize(n_indices)
		var write_idx := 0
		for j in range(0, n_indices, 2):
			var a: int = edge_indices[j]
			var b: int = edge_indices[j + 1]
			if a >= 0 and a < pos_size and b >= 0 and b < pos_size:
				wire_points[write_idx] = positions[a]
				wire_points[write_idx + 1] = positions[b]
				write_idx += 2
		if write_idx < n_indices:
			wire_points.resize(write_idx)
	var fast_us := Time.get_ticks_usec() - t1

	print("  wireframe: legacy=%.2f us | fast_flat=%.2f us (%.1fx faster)" % [
		float(legacy_us) / iters,
		float(fast_us) / iters,
		float(legacy_us) / float(fast_us) if fast_us > 0 else 1.0
	])

func _profile_thick_lines_comparison(md: PBMeshData, iters: int) -> void:
	var edge_indices := md.get_common_edge_indices()
	var n_indices := edge_indices.size()
	var pos := md.positions
	var pos_size := pos.size()
	var wire_points := PackedVector3Array()
	wire_points.resize(n_indices)
	var write_idx := 0
	for j in range(0, n_indices, 2):
		var a: int = edge_indices[j]
		var b: int = edge_indices[j + 1]
		if a >= 0 and a < pos_size and b >= 0 and b < pos_size:
			wire_points[write_idx] = pos[a]
			wire_points[write_idx + 1] = pos[b]
			write_idx += 2
	if write_idx < n_indices:
		wire_points.resize(write_idx)

	var offset: float = 0.005
	var n := wire_points.size()

	# Legacy loop (simulated)
	var t0 := Time.get_ticks_usec()
	for iter in range(iters):
		var i := 0
		while i + 1 < n:
			var a: Vector3 = wire_points[i]
			var b: Vector3 = wire_points[i + 1]
			var dir := (b - a)
			if dir.length_squared() > 0.000000001:
				dir = dir.normalized()
				var perp1 := dir.cross(Vector3.UP)
				if perp1.length_squared() < 0.25:
					perp1 = dir.cross(Vector3.RIGHT)
				perp1 = perp1.normalized() * offset
				var p1 := PackedVector3Array([a, b])
				var p2 := PackedVector3Array([a + perp1, b + perp1])
				var p3 := PackedVector3Array([a - perp1, b - perp1])
			i += 2
	var legacy_us := Time.get_ticks_usec() - t0

	# Batched loop
	var t1 := Time.get_ticks_usec()
	for iter in range(iters):
		var mult := 3
		var out := PackedVector3Array()
		out.resize(n * mult)
		var widx := 0
		var i := 0
		while i + 1 < n:
			var a: Vector3 = wire_points[i]
			var b: Vector3 = wire_points[i + 1]
			var dir := (b - a)
			if dir.length_squared() > 0.000000001:
				dir = dir.normalized()
				var perp1 := dir.cross(Vector3.UP)
				if perp1.length_squared() < 0.25:
					perp1 = dir.cross(Vector3.RIGHT)
				perp1 = perp1.normalized() * offset
				out[widx] = a
				out[widx + 1] = b
				out[widx + 2] = a + perp1
				out[widx + 3] = b + perp1
				out[widx + 4] = a - perp1
				out[widx + 5] = b - perp1
				widx += 6
			else:
				out[widx] = a
				out[widx + 1] = b
				widx += 2
			i += 2
		if widx < out.size():
			out.resize(widx)
	var batched_us := Time.get_ticks_usec() - t1

	print("  thick_lines: legacy=%.2f us | batched=%.2f us (%.1fx faster)" % [
		float(legacy_us) / iters,
		float(batched_us) / iters,
		float(legacy_us) / float(batched_us) if batched_us > 0 else 1.0
	])

func _profile_face_fill_comparison(logic: PBElementEditor, md: PBMeshData, iters: int) -> void:
	var sel := PackedInt32Array([0])
	var t0 := Time.get_ticks_usec()
	for i in range(iters):
		var m := logic.build_face_fill_mesh(md, 0)
	var single_us := Time.get_ticks_usec() - t0

	var t1 := Time.get_ticks_usec()
	for i in range(iters):
		var m := logic.build_face_fill_mesh_multi(md, sel)
	var multi_us := Time.get_ticks_usec() - t1

	print("  face_fill: single=%.2f us | multi=%.2f us" % [
		float(single_us) / iters,
		float(multi_us) / iters
	])

func _make_gridded_cube(target_faces: int) -> PBMeshData:
	var md := PBMeshData.create_cube(1.0)
	while md.faces.size() < target_faces:
		var all := PackedInt32Array()
		for fi in range(md.faces.size()):
			all.append(fi)
		var result := PBMeshOps.subdivide_faces(md, all)
		if not result["ok"]:
			break
	return md
