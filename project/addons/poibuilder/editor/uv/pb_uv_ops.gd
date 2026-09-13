## PBUvOps — Headless-testable UV Operations Library for PoiBuilder.
##
## Implements core UV operations conforming to Unity ProBuilder & UniBuilder parity:
## - Mode conversion: Convert to Manual / Convert to Auto.
## - 2D Transformations: Translate, Rotate, Scale, Flip Horizontal/Vertical, Rotate 90° CW/CCW.
## - Projections: Planar Project, Box Project, Fit UVs.
## - Seams & Topology: Sew UVs, Split UVs, Collapse UVs, Auto-Stitch adjacent edges.
## - Utilities: Sample/Normalize Texel Density, Export UV Template PNG.
@tool
class_name PBUvOps
extends RefCounted

# ==============================================================================
# Mode Conversion (Auto vs Manual)
# ==============================================================================

## Returns the aggregate UV mode of the given face indices ("Auto", "Manual", "Mixed", or "NoSelection").
static func get_uv_mode(mesh_data: PBMeshData, face_indices: Array) -> String:
	if mesh_data == null or face_indices.is_empty():
		return "NoSelection"

	var has_auto := false
	var has_manual := false

	for fi in face_indices:
		var idx: int = int(fi)
		if idx >= 0 and idx < mesh_data.faces.size():
			var face: PBFace = mesh_data.faces[idx]
			if face.manual_uv:
				has_manual = true
			else:
				has_auto = true

	if has_auto and has_manual:
		return "Mixed"
	elif has_manual:
		return "Manual"
	elif has_auto:
		return "Auto"
	return "NoSelection"

## Converts specified faces to Manual UV mode, freezing current UV coordinates into textures0.
static func convert_to_manual(mesh_data: PBMeshData, face_indices: Array) -> bool:
	if mesh_data == null or face_indices.is_empty():
		return false

	var vc: int = mesh_data.positions.size()
	if mesh_data.textures0.size() != vc:
		mesh_data.textures0.resize(vc)

	var modified := false
	for fi in face_indices:
		var idx: int = int(fi)
		if idx >= 0 and idx < mesh_data.faces.size():
			var face: PBFace = mesh_data.faces[idx]
			if not face.manual_uv:
				var uvs := PBUv.calculate_face_uvs(mesh_data, face)
				for v_idx: int in uvs:
					if v_idx >= 0 and v_idx < vc:
						mesh_data.textures0[v_idx] = uvs[v_idx]
				face.manual_uv = true
				face.texture_group = -1
				modified = true

	return modified

## Converts specified faces to Auto UV mode, restoring dynamic planar projection.
static func convert_to_auto(mesh_data: PBMeshData, face_indices: Array) -> bool:
	if mesh_data == null or face_indices.is_empty():
		return false

	var vc: int = mesh_data.positions.size()
	if mesh_data.textures0.size() != vc:
		mesh_data.textures0.resize(vc)

	var modified := false
	for fi in face_indices:
		var idx: int = int(fi)
		if idx >= 0 and idx < mesh_data.faces.size():
			var face: PBFace = mesh_data.faces[idx]
			if face.manual_uv:
				face.manual_uv = false
				var uvs := PBUv.calculate_face_uvs(mesh_data, face)
				for v_idx: int in uvs:
					if v_idx >= 0 and v_idx < vc:
						mesh_data.textures0[v_idx] = uvs[v_idx]
				modified = true

	return modified

# ==============================================================================
# Transformations (Move, Rotate, Scale, Flip)
# ==============================================================================

## Translates UV coordinates of the given vertex indices by `delta`.
## If the faces containing these vertices are Auto UV, converts them to Manual UV.
static func translate_uvs(mesh_data: PBMeshData, vertex_indices: Array, delta: Vector2, channel: int = 0) -> bool:
	if mesh_data == null or vertex_indices.is_empty() or delta.length_squared() < 0.00000001:
		return false

	var target_arr: PackedVector2Array = mesh_data.textures1 if channel == 1 else mesh_data.textures0
	var vc: int = mesh_data.positions.size()
	if target_arr.size() != vc:
		target_arr.resize(vc)

	# Ensure affected faces are in manual mode so the edit is preserved
	_ensure_faces_manual_for_vertices(mesh_data, vertex_indices)

	for vi in vertex_indices:
		var idx: int = int(vi)
		if idx >= 0 and idx < vc:
			target_arr[idx] += delta

	if channel == 1:
		mesh_data.textures1 = target_arr
	else:
		mesh_data.textures0 = target_arr

	return true

## Rotates UV coordinates of the given vertex indices around `pivot` by `angle_deg` degrees.
static func rotate_uvs(mesh_data: PBMeshData, vertex_indices: Array, pivot: Vector2, angle_deg: float, channel: int = 0) -> bool:
	if mesh_data == null or vertex_indices.is_empty() or is_zero_approx(angle_deg):
		return false

	var target_arr: PackedVector2Array = mesh_data.textures1 if channel == 1 else mesh_data.textures0
	var vc: int = mesh_data.positions.size()
	if target_arr.size() != vc:
		target_arr.resize(vc)

	_ensure_faces_manual_for_vertices(mesh_data, vertex_indices)

	var rad := deg_to_rad(angle_deg)
	for vi in vertex_indices:
		var idx: int = int(vi)
		if idx >= 0 and idx < vc:
			var p := target_arr[idx]
			target_arr[idx] = pivot + (p - pivot).rotated(rad)

	if channel == 1:
		mesh_data.textures1 = target_arr
	else:
		mesh_data.textures0 = target_arr

	return true

## Scales UV coordinates of the given vertex indices around `pivot` by `scale_factor`.
static func scale_uvs(mesh_data: PBMeshData, vertex_indices: Array, pivot: Vector2, scale_factor: Vector2, channel: int = 0) -> bool:
	if mesh_data == null or vertex_indices.is_empty():
		return false

	var target_arr: PackedVector2Array = mesh_data.textures1 if channel == 1 else mesh_data.textures0
	var vc: int = mesh_data.positions.size()
	if target_arr.size() != vc:
		target_arr.resize(vc)

	_ensure_faces_manual_for_vertices(mesh_data, vertex_indices)

	for vi in vertex_indices:
		var idx: int = int(vi)
		if idx >= 0 and idx < vc:
			var p := target_arr[idx]
			target_arr[idx] = pivot + Vector2((p.x - pivot.x) * scale_factor.x, (p.y - pivot.y) * scale_factor.y)

	if channel == 1:
		mesh_data.textures1 = target_arr
	else:
		mesh_data.textures0 = target_arr

	return true

## Flips UV coordinates of the given faces horizontally (horizontal = true) or vertically (horizontal = false)
## around the selection center point.
static func flip_uvs(mesh_data: PBMeshData, face_indices: Array, horizontal: bool, channel: int = 0) -> bool:
	if mesh_data == null or face_indices.is_empty():
		return false

	var vert_indices := get_distinct_vertices_for_faces(mesh_data, face_indices)
	if vert_indices.is_empty():
		return false

	var target_arr: PackedVector2Array = mesh_data.textures1 if channel == 1 else mesh_data.textures0
	var bounds := get_uv_bounds(target_arr, vert_indices)
	var center := bounds.get_center()

	_ensure_faces_manual(mesh_data, face_indices)

	for vi in vert_indices:
		var idx: int = int(vi)
		if idx >= 0 and idx < target_arr.size():
			if horizontal:
				target_arr[idx].x = 2.0 * center.x - target_arr[idx].x
			else:
				target_arr[idx].y = 2.0 * center.y - target_arr[idx].y

	if channel == 1:
		mesh_data.textures1 = target_arr
	else:
		mesh_data.textures0 = target_arr

	return true

## Rotates UV coordinates of the given faces by 90 degrees around selection center.
static func rotate_90(mesh_data: PBMeshData, face_indices: Array, clockwise: bool, channel: int = 0) -> bool:
	if mesh_data == null or face_indices.is_empty():
		return false

	var vert_indices := get_distinct_vertices_for_faces(mesh_data, face_indices)
	if vert_indices.is_empty():
		return false

	var target_arr: PackedVector2Array = mesh_data.textures1 if channel == 1 else mesh_data.textures0
	var bounds := get_uv_bounds(target_arr, vert_indices)
	var center := bounds.get_center()

	var angle := 90.0 if clockwise else -90.0
	return rotate_uvs(mesh_data, vert_indices, center, angle, channel)

# ==============================================================================
# Projections (Planar, Box, Fit)
# ==============================================================================

## Fits the UV coordinates of the selected faces into the [0, 1] unit square.
static func fit_uvs(mesh_data: PBMeshData, face_indices: Array, channel: int = 0) -> bool:
	if mesh_data == null or face_indices.is_empty():
		return false

	var vert_indices := get_distinct_vertices_for_faces(mesh_data, face_indices)
	if vert_indices.is_empty():
		return false

	var target_arr: PackedVector2Array = mesh_data.textures1 if channel == 1 else mesh_data.textures0
	var bounds := get_uv_bounds(target_arr, vert_indices)
	if bounds.size.x < 0.00001 or bounds.size.y < 0.00001:
		return false

	_ensure_faces_manual(mesh_data, face_indices)

	for vi in vert_indices:
		var idx: int = int(vi)
		if idx >= 0 and idx < target_arr.size():
			var u := (target_arr[idx].x - bounds.position.x) / bounds.size.x
			var v := (target_arr[idx].y - bounds.position.y) / bounds.size.y
			target_arr[idx] = Vector2(u, v)

	if channel == 1:
		mesh_data.textures1 = target_arr
	else:
		mesh_data.textures0 = target_arr

	return true

## Planar projects the selected faces along their averaged normal vector.
static func planar_project(mesh_data: PBMeshData, face_indices: Array, channel: int = 0) -> bool:
	if mesh_data == null or face_indices.is_empty():
		return false

	var avg_normal := Vector3.ZERO
	for fi in face_indices:
		var idx: int = int(fi)
		if idx >= 0 and idx < mesh_data.faces.size():
			var face: PBFace = mesh_data.faces[idx]
			var n := PBMath.normal_from_positions(mesh_data.positions, face.get_indexes())
			avg_normal += n

	if avg_normal.length_squared() < 0.0001:
		avg_normal = Vector3.UP
	else:
		avg_normal = avg_normal.normalized()

	var basis := PBUv.get_planar_basis(avg_normal)
	var u_axis: Vector3 = basis["u"]
	var v_axis: Vector3 = basis["v"]

	var vert_indices := get_distinct_vertices_for_faces(mesh_data, face_indices)
	var target_arr: PackedVector2Array = mesh_data.textures1 if channel == 1 else mesh_data.textures0
	var vc: int = mesh_data.positions.size()
	if target_arr.size() != vc:
		target_arr.resize(vc)

	_ensure_faces_manual(mesh_data, face_indices)

	var min_u := INF
	var min_v := INF

	for vi in vert_indices:
		var idx: int = int(vi)
		if idx >= 0 and idx < vc:
			var p: Vector3 = mesh_data.positions[idx]
			var uv := Vector2(u_axis.dot(p), v_axis.dot(p))
			target_arr[idx] = uv
			min_u = minf(min_u, uv.x)
			min_v = minf(min_v, uv.y)

	# Align lower-left to (0, 0)
	var offset := Vector2(min_u, min_v)
	for vi in vert_indices:
		var idx: int = int(vi)
		if idx >= 0 and idx < vc:
			target_arr[idx] -= offset

	if channel == 1:
		mesh_data.textures1 = target_arr
	else:
		mesh_data.textures0 = target_arr

	return true

## Box projects each selected face independently along its own dominant cardinal normal axis into [0, 1].
static func box_project(mesh_data: PBMeshData, face_indices: Array, channel: int = 0) -> bool:
	if mesh_data == null or face_indices.is_empty():
		return false

	var target_arr: PackedVector2Array = mesh_data.textures1 if channel == 1 else mesh_data.textures0
	var vc: int = mesh_data.positions.size()
	if target_arr.size() != vc:
		target_arr.resize(vc)

	_ensure_faces_manual(mesh_data, face_indices)

	for fi in face_indices:
		var f_idx: int = int(fi)
		if f_idx < 0 or f_idx >= mesh_data.faces.size():
			continue

		var face: PBFace = mesh_data.faces[f_idx]
		var n := PBMath.normal_from_positions(mesh_data.positions, face.get_indexes())
		var basis := PBUv.get_planar_basis(n)
		var u_axis: Vector3 = basis["u"]
		var v_axis: Vector3 = basis["v"]

		var face_verts := face.get_distinct_indexes()
		var min_u := INF
		var min_v := INF
		var max_u := -INF
		var max_v := -INF

		for v in face_verts:
			if v >= 0 and v < vc:
				var p: Vector3 = mesh_data.positions[v]
				var uv := Vector2(u_axis.dot(p), v_axis.dot(p))
				target_arr[v] = uv
				min_u = minf(min_u, uv.x)
				min_v = minf(min_v, uv.y)
				max_u = maxf(max_u, uv.x)
				max_v = maxf(max_v, uv.y)

		var span_u := max_u - min_u
		var span_v := max_v - min_v
		var max_span := maxf(span_u, span_v)
		if max_span < 0.0001:
			max_span = 1.0

		for v in face_verts:
			if v >= 0 and v < vc:
				target_arr[v] = Vector2((target_arr[v].x - min_u) / max_span, (target_arr[v].y - min_v) / max_span)

	if channel == 1:
		mesh_data.textures1 = target_arr
	else:
		mesh_data.textures0 = target_arr

	return true

## Unwraps selected faces into a clean, non-overlapping UV layout.
## For 6-sided boxes or cubes, produces a canonical cross unwrap.
## For arbitrary meshes, packs faces non-overlapping into a grid layout in [0, 1].
static func unwrap_box(mesh_data: PBMeshData, face_indices: Array, channel: int = 0) -> bool:
	if mesh_data == null or face_indices.is_empty():
		return false

	var target_arr: PackedVector2Array = mesh_data.textures1 if channel == 1 else mesh_data.textures0
	var vc: int = mesh_data.positions.size()
	if target_arr.size() != vc:
		target_arr.resize(vc)

	_ensure_faces_manual(mesh_data, face_indices)

	var cardinal_faces: Dictionary = {}
	for fi in face_indices:
		var f_idx: int = int(fi)
		if f_idx >= 0 and f_idx < mesh_data.faces.size():
			var face: PBFace = mesh_data.faces[f_idx]
			var n := PBMath.normal_from_positions(mesh_data.positions, face.get_indexes())
			var an := n.abs()
			var axis_key := ""
			if an.x >= an.y and an.x >= an.z:
				axis_key = "+X" if n.x > 0 else "-X"
			elif an.y >= an.x and an.y >= an.z:
				axis_key = "+Y" if n.y > 0 else "-Y"
			else:
				axis_key = "+Z" if n.z > 0 else "-Z"

			if not cardinal_faces.has(axis_key):
				cardinal_faces[axis_key] = f_idx

	if cardinal_faces.size() == 6 and face_indices.size() == 6:
		# Canonical cross layout in [0, 1] with 4 columns and 3 rows:
		# Cell size: 1/4 = 0.25 on U, 1/3 = 0.3333 on V
		# col 0: -X (Left) at (0, 1/3)
		# col 1: -Z (Front) at (1/4, 1/3), +Y (Top) at (1/4, 2/3), -Y (Bottom) at (1/4, 0)
		# col 2: +X (Right) at (2/4, 1/3)
		# col 3: +Z (Back) at (3/4, 1/3)
		var cell_w := 0.24
		var cell_h := 0.31
		var pad_u := (0.25 - cell_w) * 0.5
		var pad_v := (1.0 / 3.0 - cell_h) * 0.5

		var layout_slots := {
			"-X": Vector2(0.0 * 0.25 + pad_u, 1.0 * (1.0 / 3.0) + pad_v),
			"-Z": Vector2(1.0 * 0.25 + pad_u, 1.0 * (1.0 / 3.0) + pad_v),
			"+X": Vector2(2.0 * 0.25 + pad_u, 1.0 * (1.0 / 3.0) + pad_v),
			"+Z": Vector2(3.0 * 0.25 + pad_u, 1.0 * (1.0 / 3.0) + pad_v),
			"+Y": Vector2(1.0 * 0.25 + pad_u, 2.0 * (1.0 / 3.0) + pad_v),
			"-Y": Vector2(1.0 * 0.25 + pad_u, 0.0 * (1.0 / 3.0) + pad_v),
		}

		for axis_key in cardinal_faces:
			var fi: int = cardinal_faces[axis_key]
			var face: PBFace = mesh_data.faces[fi]
			var n := PBMath.normal_from_positions(mesh_data.positions, face.get_indexes())
			var basis := PBUv.get_planar_basis(n)
			var u_axis: Vector3 = basis["u"]
			var v_axis: Vector3 = basis["v"]

			var face_verts := face.get_distinct_indexes()
			var min_u := INF
			var min_v := INF
			var max_u := -INF
			var max_v := -INF

			for v in face_verts:
				if v >= 0 and v < vc:
					var p: Vector3 = mesh_data.positions[v]
					var uv := Vector2(u_axis.dot(p), v_axis.dot(p))
					target_arr[v] = uv
					min_u = minf(min_u, uv.x)
					min_v = minf(min_v, uv.y)
					max_u = maxf(max_u, uv.x)
					max_v = maxf(max_v, uv.y)

			var span_u := maxf(0.001, max_u - min_u)
			var span_v := maxf(0.001, max_v - min_v)
			var slot_pos: Vector2 = layout_slots[axis_key]

			for v in face_verts:
				if v >= 0 and v < vc:
					var norm_u := (target_arr[v].x - min_u) / span_u
					var norm_v := (target_arr[v].y - min_v) / span_v
					target_arr[v] = slot_pos + Vector2(norm_u * cell_w, norm_v * cell_h)
	else:
		var n_faces := face_indices.size()
		var cols := int(ceilf(sqrt(float(n_faces))))
		var rows := int(ceilf(float(n_faces) / float(cols)))
		var col_w := 1.0 / float(cols)
		var row_h := 1.0 / float(rows)
		var pad_w := col_w * 0.05
		var pad_h := row_h * 0.05
		var inner_w := col_w - pad_w * 2.0
		var inner_h := row_h - pad_h * 2.0

		for i in range(n_faces):
			var fi: int = int(face_indices[i])
			if fi < 0 or fi >= mesh_data.faces.size():
				continue
			var face: PBFace = mesh_data.faces[fi]
			var n := PBMath.normal_from_positions(mesh_data.positions, face.get_indexes())
			var basis := PBUv.get_planar_basis(n)
			var u_axis: Vector3 = basis["u"]
			var v_axis: Vector3 = basis["v"]

			var face_verts := face.get_distinct_indexes()
			var min_u := INF
			var min_v := INF
			var max_u := -INF
			var max_v := -INF

			for v in face_verts:
				if v >= 0 and v < vc:
					var p: Vector3 = mesh_data.positions[v]
					var uv := Vector2(u_axis.dot(p), v_axis.dot(p))
					target_arr[v] = uv
					min_u = minf(min_u, uv.x)
					min_v = minf(min_v, uv.y)
					max_u = maxf(max_u, uv.x)
					max_v = maxf(max_v, uv.y)

			var span_u := maxf(0.001, max_u - min_u)
			var span_v := maxf(0.001, max_v - min_v)

			var c_idx := i % cols
			var r_idx := i / cols
			var slot_pos := Vector2(float(c_idx) * col_w + pad_w, float(r_idx) * row_h + pad_h)

			for v in face_verts:
				if v >= 0 and v < vc:
					var norm_u := (target_arr[v].x - min_u) / span_u
					var norm_v := (target_arr[v].y - min_v) / span_v
					target_arr[v] = slot_pos + Vector2(norm_u * inner_w, norm_v * inner_h)

	if channel == 1:
		mesh_data.textures1 = target_arr
	else:
		mesh_data.textures0 = target_arr

	rebuild_shared_textures(mesh_data)
	return true

# ==============================================================================
# Seams & Topology Tools (Sew, Split, Collapse, Auto-Stitch)
# ==============================================================================

## Sews coincident 3D vertices whose UV coordinates are within `max_distance` by averaging their UVs.
## Returns the count of welded vertex pairs.
static func sew_uvs(mesh_data: PBMeshData, vertex_indices: Array, max_distance: float = 0.05, channel: int = 0) -> int:
	if mesh_data == null or vertex_indices.size() < 2:
		return 0

	var target_arr: PackedVector2Array = mesh_data.textures1 if channel == 1 else mesh_data.textures0
	var vc: int = mesh_data.positions.size()
	if target_arr.size() != vc:
		target_arr.resize(vc)

	# Build spatial groups of 3D coincident vertices
	var coincident_groups: Array[Array] = _get_3d_coincident_groups(mesh_data, vertex_indices)
	var welded_count := 0

	for group in coincident_groups:
		if group.size() < 2:
			continue

		for i in range(group.size() - 1):
			var vi: int = group[i]
			for j in range(i + 1, group.size()):
				var vj: int = group[j]
				var d := target_arr[vi].distance_to(target_arr[vj])
				if d <= max_distance and d > 0.00001:
					var mid := (target_arr[vi] + target_arr[vj]) * 0.5
					target_arr[vi] = mid
					target_arr[vj] = mid
					welded_count += 1

	if welded_count > 0:
		_ensure_faces_manual_for_vertices(mesh_data, vertex_indices)
		if channel == 1:
			mesh_data.textures1 = target_arr
		else:
			mesh_data.textures0 = target_arr
			rebuild_shared_textures(mesh_data)

	return welded_count

## Collapses all given UV vertices to their geometric centroid.
static func collapse_uvs(mesh_data: PBMeshData, vertex_indices: Array, channel: int = 0) -> bool:
	if mesh_data == null or vertex_indices.is_empty():
		return false

	var target_arr: PackedVector2Array = mesh_data.textures1 if channel == 1 else mesh_data.textures0
	var vc: int = mesh_data.positions.size()
	if target_arr.size() != vc:
		target_arr.resize(vc)

	var centroid := Vector2.ZERO
	var valid_count := 0
	for vi in vertex_indices:
		var idx: int = int(vi)
		if idx >= 0 and idx < vc:
			centroid += target_arr[idx]
			valid_count += 1

	if valid_count == 0:
		return false

	centroid /= float(valid_count)
	_ensure_faces_manual_for_vertices(mesh_data, vertex_indices)

	for vi in vertex_indices:
		var idx: int = int(vi)
		if idx >= 0 and idx < vc:
			target_arr[idx] = centroid

	if channel == 1:
		mesh_data.textures1 = target_arr
	else:
		mesh_data.textures0 = target_arr

	return true

## Splits UV seams by slightly displacing vertices of different faces away from coincident UV points.
static func split_uvs(mesh_data: PBMeshData, vertex_indices: Array, offset: Vector2 = Vector2(0.05, 0.05), channel: int = 0) -> int:
	if mesh_data == null or vertex_indices.is_empty():
		return 0

	var target_arr: PackedVector2Array = mesh_data.textures1 if channel == 1 else mesh_data.textures0
	var vc: int = mesh_data.positions.size()
	if target_arr.size() != vc:
		target_arr.resize(vc)

	_ensure_faces_manual_for_vertices(mesh_data, vertex_indices)

	# Find vertex pairs that share the exact same UV position and displace one of them
	var uv_map: Dictionary = {} # {Vector2i: Array[int]}
	var split_count := 0

	for vi in vertex_indices:
		var idx: int = int(vi)
		if idx >= 0 and idx < vc:
			var key := Vector2i(int(round(target_arr[idx].x * 10000.0)), int(round(target_arr[idx].y * 10000.0)))
			if not uv_map.has(key):
				uv_map[key] = []
			uv_map[key].append(idx)

	for key: Vector2i in uv_map:
		var list: Array = uv_map[key]
		if list.size() > 1:
			for k in range(1, list.size()):
				var idx: int = list[k]
				var step := offset * float(k)
				target_arr[idx] += step
				split_count += 1

	if channel == 1:
		mesh_data.textures1 = target_arr
	else:
		mesh_data.textures0 = target_arr

	return split_count

## Automatically aligns and stitches `target_face`'s UV edge to match `anchor_face`'s UV edge.
## Finds the shared 3D edge between them, scales/translates/rotates target_face's UVs.
static func auto_stitch(mesh_data: PBMeshData, anchor_face_idx: int, target_face_idx: int, channel: int = 0) -> bool:
	if mesh_data == null or anchor_face_idx == target_face_idx:
		return false

	var faces := mesh_data.faces
	if anchor_face_idx < 0 or anchor_face_idx >= faces.size() or target_face_idx < 0 or target_face_idx >= faces.size():
		return false

	var f_anchor: PBFace = faces[anchor_face_idx]
	var f_target: PBFace = faces[target_face_idx]

	var target_arr: PackedVector2Array = mesh_data.textures1 if channel == 1 else mesh_data.textures0
	var vc: int = mesh_data.positions.size()
	if target_arr.size() != vc:
		target_arr.resize(vc)

	# Find shared 3D edge between f_anchor and f_target
	var anchor_edges := f_anchor.get_edges()
	var target_edges := f_target.get_edges()

	var match_anchor_edge: PBEdge = null
	var match_target_edge: PBEdge = null

	for ae in anchor_edges:
		var p_a1: Vector3 = mesh_data.positions[ae.a]
		var p_a2: Vector3 = mesh_data.positions[ae.b]
		for te in target_edges:
			var p_t1: Vector3 = mesh_data.positions[te.a]
			var p_t2: Vector3 = mesh_data.positions[te.b]

			if (p_a1.is_equal_approx(p_t1) and p_a2.is_equal_approx(p_t2)) or (p_a1.is_equal_approx(p_t2) and p_a2.is_equal_approx(p_t1)):
				match_anchor_edge = ae
				match_target_edge = te
				break
		if match_anchor_edge != null:
			break

	if match_anchor_edge == null or match_target_edge == null:
		return false

	# Match vertices so that anchor_v1 matches target_v1 in 3D
	var a_v1 := match_anchor_edge.a
	var a_v2 := match_anchor_edge.b
	var t_v1 := match_target_edge.a
	var t_v2 := match_target_edge.b

	if mesh_data.positions[a_v1].is_equal_approx(mesh_data.positions[t_v2]):
		var tmp := t_v1
		t_v1 = t_v2
		t_v2 = tmp

	var anchor_uv1 := target_arr[a_v1]
	var anchor_uv2 := target_arr[a_v2]
	var target_uv1 := target_arr[t_v1]
	var target_uv2 := target_arr[t_v2]

	var dist_anchor := anchor_uv1.distance_to(anchor_uv2)
	var dist_target := target_uv1.distance_to(target_uv2)

	if dist_anchor < 0.00001 or dist_target < 0.00001:
		return false

	_ensure_faces_manual(mesh_data, [anchor_face_idx, target_face_idx])

	var target_verts := f_target.get_distinct_indexes()

	# 1. Scale target UVs to match anchor edge length
	var scale := dist_anchor / dist_target
	var t_mid := (target_uv1 + target_uv2) * 0.5
	for v in target_verts:
		target_arr[v] = t_mid + (target_arr[v] - t_mid) * scale

	# Update transformed edge UVs
	target_uv1 = target_arr[t_v1]
	target_uv2 = target_arr[t_v2]
	t_mid = (target_uv1 + target_uv2) * 0.5
	var a_mid := (anchor_uv1 + anchor_uv2) * 0.5

	# 2. Translate target face so edge midpoints coincide
	var shift := a_mid - t_mid
	for v in target_verts:
		target_arr[v] += shift

	# Update edge UVs after shift
	target_uv1 = target_arr[t_v1]
	target_uv2 = target_arr[t_v2]

	# 3. Rotate around a_mid to align edge vector
	var dir_anchor := (anchor_uv2 - anchor_uv1).normalized()
	var dir_target := (target_uv2 - target_uv1).normalized()

	var angle := dir_target.angle_to(dir_anchor)
	for v in target_verts:
		target_arr[v] = a_mid + (target_arr[v] - a_mid).rotated(angle)

	# 4. Weld the two matching vertices
	target_arr[t_v1] = anchor_uv1
	target_arr[t_v2] = anchor_uv2

	if channel == 1:
		mesh_data.textures1 = target_arr
	else:
		mesh_data.textures0 = target_arr
		rebuild_shared_textures(mesh_data)

	return true


## Rebuilds the mesh_data.shared_textures array by finding all vertex pairs that are coincident in 3D and in UV space.
static func rebuild_shared_textures(mesh_data: PBMeshData) -> void:
	if mesh_data == null:
		return
	mesh_data.shared_textures.clear()
	var uvs := mesh_data.textures0
	var vc: int = mesh_data.positions.size()
	if uvs.size() != vc:
		return

	var visited: Dictionary = {}
	for i in range(vc - 1):
		if visited.has(i):
			continue
		var group: PackedInt32Array = [i]
		var p_i: Vector3 = mesh_data.positions[i]
		var uv_i: Vector2 = uvs[i]
		for j in range(i + 1, vc):
			if visited.has(j):
				continue
			if mesh_data.positions[j].distance_squared_to(p_i) < 0.0001:
				if uvs[j].distance_squared_to(uv_i) < 0.000001:
					group.append(j)
					visited[j] = true
		if group.size() > 1:
			visited[i] = true
			mesh_data.shared_textures.append(PBSharedVertex.new(group))
	mesh_data.invalidate_shared_texture_lookup()
# ==============================================================================
# Texel Density Utilities
# ==============================================================================

## Computes the texel density (pixels per meter) of `face`.
static func sample_texel_density(mesh_data: PBMeshData, face: PBFace, texture_size: Vector2 = Vector2(512, 512), channel: int = 0) -> float:
	if mesh_data == null or face == null:
		return 0.0

	var area_3d := _calculate_face_area_3d(mesh_data, face)
	var area_uv := _calculate_face_area_uv(mesh_data, face, channel)

	if area_3d < 0.000001 or area_uv < 0.000000001:
		return 0.0

	var linear_3d := sqrt(area_3d)
	var linear_uv := sqrt(area_uv)

	return (linear_uv * texture_size.x) / linear_3d

## Normalizes the texel density of all given faces to `target_density` (pixels per meter).
static func normalize_texel_density(mesh_data: PBMeshData, face_indices: Array, target_density: float = 256.0, texture_size: Vector2 = Vector2(512, 512), channel: int = 0) -> int:
	if mesh_data == null or face_indices.is_empty() or target_density <= 0.0:
		return 0

	var target_arr: PackedVector2Array = mesh_data.textures1 if channel == 1 else mesh_data.textures0
	var vc: int = mesh_data.positions.size()
	if target_arr.size() != vc:
		target_arr.resize(vc)

	_ensure_faces_manual(mesh_data, face_indices)
	var modified_count := 0

	for fi in face_indices:
		var f_idx: int = int(fi)
		if f_idx < 0 or f_idx >= mesh_data.faces.size():
			continue

		var face: PBFace = mesh_data.faces[f_idx]
		var cur_density := sample_texel_density(mesh_data, face, texture_size, channel)
		if cur_density < 0.0001:
			continue

		var scale_factor := target_density / cur_density
		var face_verts := face.get_distinct_indexes()
		var center := get_uv_bounds(target_arr, face_verts).get_center()

		for v in face_verts:
			if v >= 0 and v < vc:
				target_arr[v] = center + (target_arr[v] - center) * scale_factor

		modified_count += 1

	if channel == 1:
		mesh_data.textures1 = target_arr
	else:
		mesh_data.textures0 = target_arr

	return modified_count

# ==============================================================================
# UV Template Export
# ==============================================================================

## Renders the UV wireframe to an Image and saves it as a PNG file.
static func export_uv_template(mesh_data: PBMeshData, file_path: String, image_size: int = 1024,
		line_color: Color = Color.WHITE, bg_color: Color = Color.BLACK, transparent: bool = false,
		selected_faces_only: bool = false, selected_face_indices: Array = [], channel: int = 0) -> Error:
	if mesh_data == null or file_path.is_empty() or image_size < 32:
		return ERR_INVALID_PARAMETER

	var target_arr: PackedVector2Array = mesh_data.textures1 if channel == 1 else mesh_data.textures0
	if target_arr.is_empty():
		return ERR_UNCONFIGURED

	var img := Image.create(image_size, image_size, false, Image.FORMAT_RGBA8)
	var fill_color := Color(0, 0, 0, 0) if transparent else bg_color
	img.fill(fill_color)

	var faces_to_draw: Array = []
	if selected_faces_only and not selected_face_indices.is_empty():
		for fi in selected_face_indices:
			var idx: int = int(fi)
			if idx >= 0 and idx < mesh_data.faces.size():
				faces_to_draw.append(mesh_data.faces[idx])
	else:
		faces_to_draw = mesh_data.faces

	# Compute the bounding box of all UV coordinates to be drawn
	var all_verts: Array[int] = []
	for face: PBFace in faces_to_draw:
		if face == null:
			continue
		for v in face.get_distinct_indexes():
			if v < target_arr.size():
				all_verts.append(v)

	var bounds := get_uv_bounds(target_arr, all_verts)

	# If bounds are within [0, 1], render standard [0, 1] space.
	# If any UVs lie outside [0, 1], dynamically fit all UVs with 3% margin so nothing is clipped.
	var uv_min := Vector2.ZERO
	var uv_scale_span := 1.0

	var fits_in_unit := bounds.position.x >= -0.01 and bounds.position.y >= -0.01 and bounds.end.x <= 1.01 and bounds.end.y <= 1.01
	if not fits_in_unit and bounds.size.x > 0.0001 and bounds.size.y > 0.0001:
		var pad := maxf(bounds.size.x, bounds.size.y) * 0.03
		uv_min = bounds.position - Vector2(pad, pad)
		var uv_max := bounds.end + Vector2(pad, pad)
		uv_scale_span = maxf(uv_max.x - uv_min.x, uv_max.y - uv_min.y)
		if uv_scale_span < 0.0001:
			uv_scale_span = 1.0

	var drawn_edges: Dictionary = {}
	var max_coord := float(image_size - 1)

	for face: PBFace in faces_to_draw:
		if face == null:
			continue
		for edge in face.get_edges():
			if edge.a >= target_arr.size() or edge.b >= target_arr.size():
				continue
			var ekey := Vector2i(mini(edge.a, edge.b), maxi(edge.a, edge.b))
			if drawn_edges.has(ekey):
				continue
			drawn_edges[ekey] = true

			var uv1: Vector2 = target_arr[edge.a]
			var uv2: Vector2 = target_arr[edge.b]

			var norm1 := (uv1 - uv_min) / uv_scale_span
			var norm2 := (uv2 - uv_min) / uv_scale_span

			var p1 := Vector2i(int(round(norm1.x * max_coord)), int(round(norm1.y * max_coord)))
			var p2 := Vector2i(int(round(norm2.x * max_coord)), int(round(norm2.y * max_coord)))

			_draw_line_on_image(img, p1, p2, line_color)

	return img.save_png(file_path)

# ==============================================================================
# Helper Methods
# ==============================================================================

static func get_distinct_vertices_for_faces(mesh_data: PBMeshData, face_indices: Array) -> Array[int]:
	var result: Array[int] = []
	var seen: Dictionary = {}
	if mesh_data == null:
		return result

	for fi in face_indices:
		var idx: int = int(fi)
		if idx >= 0 and idx < mesh_data.faces.size():
			var face: PBFace = mesh_data.faces[idx]
			for v in face.get_distinct_indexes():
				if not seen.has(v):
					seen[v] = true
					result.append(v)
	return result

static func get_uv_bounds(uvs: PackedVector2Array, vertex_indices: Array) -> Rect2:
	if uvs.is_empty() or vertex_indices.is_empty():
		return Rect2()

	var min_p := Vector2(INF, INF)
	var max_p := Vector2(-INF, -INF)
	var count := 0

	for vi in vertex_indices:
		var idx: int = int(vi)
		if idx >= 0 and idx < uvs.size():
			var uv := uvs[idx]
			min_p = min_p.min(uv)
			max_p = max_p.max(uv)
			count += 1

	if count == 0:
		return Rect2()
	return Rect2(min_p, max_p - min_p)

static func _ensure_faces_manual(mesh_data: PBMeshData, face_indices: Array) -> void:
	var vc: int = mesh_data.positions.size()
	if mesh_data.textures0.size() != vc:
		mesh_data.textures0.resize(vc)

	for fi in face_indices:
		var idx: int = int(fi)
		if idx >= 0 and idx < mesh_data.faces.size():
			var face: PBFace = mesh_data.faces[idx]
			if not face.manual_uv:
				var uvs := PBUv.calculate_face_uvs(mesh_data, face)
				for v_idx: int in uvs:
					if v_idx >= 0 and v_idx < vc:
						mesh_data.textures0[v_idx] = uvs[v_idx]
				face.manual_uv = true
				face.texture_group = -1

static func _ensure_faces_manual_for_vertices(mesh_data: PBMeshData, vertex_indices: Array) -> void:
	var v_set: Dictionary = {}
	for vi in vertex_indices:
		v_set[int(vi)] = true

	var faces_to_convert: Array = []
	for fi in range(mesh_data.faces.size()):
		var face: PBFace = mesh_data.faces[fi]
		if not face.manual_uv:
			for idx in face.get_distinct_indexes():
				if v_set.has(idx):
					faces_to_convert.append(fi)
					break

	if not faces_to_convert.is_empty():
		_ensure_faces_manual(mesh_data, faces_to_convert)

static func _get_3d_coincident_groups(mesh_data: PBMeshData, vertex_indices: Array) -> Array[Array]:
	var result: Array[Array] = []
	var pos_to_indices: Dictionary = {} # {Vector3i: Array[int]}

	for vi in vertex_indices:
		var idx: int = int(vi)
		if idx >= 0 and idx < mesh_data.positions.size():
			var p: Vector3 = mesh_data.positions[idx]
			var key := Vector3i(int(round(p.x * 1000.0)), int(round(p.y * 1000.0)), int(round(p.z * 1000.0)))
			if not pos_to_indices.has(key):
				pos_to_indices[key] = []
			pos_to_indices[key].append(idx)

	for key: Vector3i in pos_to_indices:
		var group: Array = pos_to_indices[key]
		if group.size() > 1:
			result.append(group)

	return result

static func _calculate_face_area_3d(mesh_data: PBMeshData, face: PBFace) -> float:
	var indices := face.get_indexes()
	if indices.size() < 3:
		return 0.0

	var total_area := 0.0
	for i in range(0, indices.size(), 3):
		var p0: Vector3 = mesh_data.positions[indices[i]]
		var p1: Vector3 = mesh_data.positions[indices[i + 1]]
		var p2: Vector3 = mesh_data.positions[indices[i + 2]]
		total_area += ((p1 - p0).cross(p2 - p0)).length() * 0.5

	return total_area

static func _calculate_face_area_uv(mesh_data: PBMeshData, face: PBFace, channel: int = 0) -> float:
	var target_arr: PackedVector2Array = mesh_data.textures1 if channel == 1 else mesh_data.textures0
	var indices := face.get_indexes()
	if indices.size() < 3 or target_arr.size() < mesh_data.positions.size():
		return 0.0

	var total_area := 0.0
	for i in range(0, indices.size(), 3):
		var ia: int = indices[i]
		var ib: int = indices[i + 1]
		var ic: int = indices[i + 2]
		if ia < target_arr.size() and ib < target_arr.size() and ic < target_arr.size():
			var u0 := target_arr[ia]
			var u1 := target_arr[ib]
			var u2 := target_arr[ic]
			total_area += absf((u1.x - u0.x) * (u2.y - u0.y) - (u2.x - u0.x) * (u1.y - u0.y)) * 0.5

	return total_area

## Bresenham line rasterizer on Image.
static func _draw_line_on_image(img: Image, p1: Vector2i, p2: Vector2i, col: Color) -> void:
	var x0 := p1.x
	var y0 := p1.y
	var x1 := p2.x
	var y1 := p2.y

	var dx := absi(x1 - x0)
	var dy := -absi(y1 - y0)
	var sx := 1 if x0 < x1 else -1
	var sy := 1 if y0 < y1 else -1
	var err := dx + dy

	var w := img.get_width()
	var h := img.get_height()

	while true:
		if x0 >= 0 and x0 < w and y0 >= 0 and y0 < h:
			img.set_pixel(x0, y0, col)

		if x0 == x1 and y0 == y1:
			break
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			x0 += sx
		if e2 <= dx:
			err += dx
			y0 += sy
