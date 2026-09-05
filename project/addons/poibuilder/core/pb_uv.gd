## PBUv — Auto-UV projection, planar mapping, and UV manipulation for PoiBuilder.
##
## Provides deterministic, uniform 1x1 meter repeat pattern projection for faces,
## robust orientation heuristics for non-axis-aligned and sloped surfaces, and
## tools for tiling, rotation, offsets, and diagonal 45-degree quad mapping.
@tool
class_name PBUv
extends RefCounted

## Enumeration of projection anchor points matching ProBuilder.
enum Anchor {
	UPPER_LEFT = 0,
	UPPER_CENTER = 1,
	UPPER_RIGHT = 2,
	MIDDLE_LEFT = 3,
	MIDDLE_CENTER = 4,
	MIDDLE_RIGHT = 5,
	LOWER_LEFT = 6,
	LOWER_CENTER = 7,
	LOWER_RIGHT = 8,
	NONE = 9
}

## Enumeration of UV fill modes matching ProBuilder.
enum Fill {
	FIT = 0,
	TILE = 1,
	STRETCH = 2
}

## Scale factor for 45-degree grid diagonal tiling (1.0 / sqrt(2.0)).
const DIAGONAL_SCALE_FACTOR := 0.7071067811865475

# ==============================================================================
# Planar Projection Basis Heuristic
# ==============================================================================

## Computes orthonormal U (horizontal) and V (vertical) tangent vectors in the plane
## of a face with unit normal `normal`.
##
## Heuristic:
## - Non-vertical surfaces (|normal.y| < 0.9999, e.g. walls, roofs, ramps, angled quads):
##   U = (Vector3.UP x normal).normalized()
##   V = (normal x U).normalized()
##   This ensures that looking directly at any wall or slope, U always points to the
##   viewer's right and V always points upward along the surface slope.
## - Vertical surfaces (|normal.y| >= 0.9999, e.g. floors, ceilings):
##   Top and Bottom: U = Vector3.RIGHT (+X), V = Vector3.BACK (+Z), anchored to -Z edge.
static func get_planar_basis(normal: Vector3) -> Dictionary:
	var n := normal.normalized()
	var u := Vector3.ZERO
	var v := Vector3.ZERO

	if absf(n.y) < 0.9999:
		if absf(n.x - 1.0) < 0.001:
			u = Vector3.BACK
			v = Vector3.UP
		else:
			u = Vector3.UP.cross(n).normalized()
			if u.length_squared() < 0.0001:
				u = Vector3.RIGHT.cross(n).normalized()
			v = n.cross(u).normalized()
	else:
		u = Vector3.RIGHT
		v = Vector3.BACK
	return {"u": u, "v": v, "normal": n}

# ==============================================================================
# UV Calculation
# ==============================================================================

## Calculates auto-projected UV coordinates for a single face on `mesh_data`.
## Returns a Dictionary mapping local vertex index -> Vector2 UV coordinate.
static func calculate_face_uvs(mesh_data: PBMeshData, face: PBFace) -> Dictionary:
	var result: Dictionary = {}
	if mesh_data == null or face == null:
		return result

	var indices: PackedInt32Array = face.get_distinct_indexes()
	if indices.is_empty():
		return result

	var pos_count: int = mesh_data.positions.size()
	for idx in indices:
		if idx < 0 or idx >= pos_count:
			return result

	# Calculate face normal from geometry
	var normal: Vector3 = PBMath.normal_from_positions(mesh_data.positions, face.get_indexes())
	if normal.length_squared() < 0.0001:
		normal = Vector3.UP
	else:
		normal = normal.normalized()

	var basis := get_planar_basis(normal)
	var u_axis: Vector3 = basis["u"]
	var v_axis: Vector3 = basis["v"]

	# Compute raw planar projected UVs
	var raw_uvs: Array[Vector2] = []
	var min_u := INF
	var min_v := INF
	for idx in indices:
		var p: Vector3 = mesh_data.positions[idx]
		var uv0 := Vector2(u_axis.dot(p), v_axis.dot(p))
		raw_uvs.append(uv0)
		min_u = minf(min_u, uv0.x)
		min_v = minf(min_v, uv0.y)

	# Anchor face to (0, 0) at its minimum corner by default unless world space UV is specified.
	# World space UVs (uv_use_world_space) preserve continuous planar mapping across seams.
	if not face.uv_use_world_space:
		for i in range(raw_uvs.size()):
			raw_uvs[i] -= Vector2(min_u, min_v)

	var scale: Vector2 = face.uv_scale
	var rotation: float = face.uv_rotation
	var rot_rad: float = deg_to_rad(rotation)
	var cos_r: float = cos(rot_rad)
	var sin_r: float = sin(rot_rad)
	var offset: Vector2 = face.uv_offset
	for i in range(indices.size()):
		var idx: int = indices[i]
		var uv: Vector2 = raw_uvs[i]

		if face.uv_flip_u:
			uv.x = -uv.x
		if face.uv_flip_v:
			uv.y = -uv.y
		if face.uv_swap_uv:
			var tmp := uv.x
			uv.x = uv.y
			uv.y = tmp

		if rotation != 0.0:
			# Corner-anchored scaling and rotation: keeps (0, 0) anchored to the reference corner
			var sx: float = uv.x * scale.x
			var sy: float = uv.y * scale.y
			var rx: float = sx * cos_r - sy * sin_r
			var ry: float = sx * sin_r + sy * cos_r
			uv = Vector2(rx, ry) + offset
		else:
			# Corner-anchored scaling: keeps (0, 0) at the corner for all scale factors (1x, 2x, etc.)
			uv = Vector2(uv.x * scale.x, uv.y * scale.y) + offset

		result[idx] = uv

	return result

## Configures an extruded side face's UV properties so that its UVs seamlessly
## match wherever the texture was cut off at the base edge [qa, qb], instead of
## anchoring from the beginning.
static func setup_extruded_face_uvs(mesh_data: PBMeshData, side: PBFace,
		source_face: PBFace, edge_a: int, edge_b: int, qa: int, qb: int) -> void:
	if mesh_data == null or side == null:
		return
	if source_face != null:
		side.submesh_index = source_face.submesh_index
		side.uv_scale = source_face.uv_scale
	side.uv_use_world_space = true
	side.uv_rotation = 0.0
	side.uv_anchor = Anchor.NONE
	var uv_a := Vector2.ZERO
	var uv_b := Vector2.ZERO
	if mesh_data.textures0.size() > edge_a and mesh_data.textures0.size() > edge_b \
			and (source_face == null or source_face.manual_uv or not mesh_data.textures0[edge_a].is_zero_approx()):
		uv_a = mesh_data.textures0[edge_a]
		uv_b = mesh_data.textures0[edge_b]
	elif source_face != null:
		var src_uvs := calculate_face_uvs(mesh_data, source_face)
		uv_a = src_uvs.get(edge_a, Vector2.ZERO)
		uv_b = src_uvs.get(edge_b, Vector2.ZERO)

	var normal_side: Vector3 = PBMath.normal_from_positions(mesh_data.positions, side.get_indexes())
	if normal_side.length_squared() < 0.0001:
		normal_side = Vector3.UP
	else:
		normal_side = normal_side.normalized()

	var basis := get_planar_basis(normal_side)
	var u_axis: Vector3 = basis["u"]
	var v_axis: Vector3 = basis["v"]

	var pos_a: Vector3 = mesh_data.positions[qa]
	var pos_b: Vector3 = mesh_data.positions[qb]
	var raw_a := Vector2(u_axis.dot(pos_a), v_axis.dot(pos_a))
	var raw_b := Vector2(u_axis.dot(pos_b), v_axis.dot(pos_b))

	var delta_raw := raw_b - raw_a
	var delta_src := uv_b - uv_a

	if delta_raw.x * delta_src.x < -0.001:
		side.uv_flip_u = true
		raw_a.x = -raw_a.x
		raw_b.x = -raw_b.x

	if delta_raw.y * delta_src.y < -0.001:
		side.uv_flip_v = true
		raw_a.y = -raw_a.y
		raw_b.y = -raw_b.y

	var scaled_a := Vector2(raw_a.x * side.uv_scale.x, raw_a.y * side.uv_scale.y)
	side.uv_offset = uv_a - scaled_a

	# Apply to mesh_data.textures0 if available
	if mesh_data.textures0.size() == mesh_data.positions.size():
		var side_uvs := calculate_face_uvs(mesh_data, side)
		for idx: int in side_uvs:
			if idx >= 0 and idx < mesh_data.textures0.size():
				mesh_data.textures0[idx] = side_uvs[idx]

## Refreshes UV coordinates in `mesh_data.textures0` for all faces.
## Faces with `manual_uv == true` are preserved unless `force_all` is true.
static func refresh_mesh_uvs(mesh_data: PBMeshData, force_all: bool = false) -> void:
	if mesh_data == null:
		return

	var vc: int = mesh_data.positions.size()
	if mesh_data.textures0.size() != vc:
		mesh_data.textures0.resize(vc)

	for face in mesh_data.faces:
		if face == null:
			continue
		if face.manual_uv and not force_all:
			continue

		var face_uvs := calculate_face_uvs(mesh_data, face)
		for idx: int in face_uvs:
			if idx >= 0 and idx < vc:
				mesh_data.textures0[idx] = face_uvs[idx]

## Configures the face for 45-degree diagonal tiling so that the texture width
## matches the grid diagonal (sqrt(1+1) = sqrt(2) on a 1m grid).
static func set_face_45_degree_diagonal(face: PBFace) -> void:
	if face == null:
		return
	face.uv_scale = Vector2(DIAGONAL_SCALE_FACTOR, DIAGONAL_SCALE_FACTOR)
	face.uv_rotation = 45.0
	face.uv_offset = Vector2.ZERO

## Multiplies the face's UV tiling by a factor (e.g. 2.0 for x2, 0.5 for /2).
static func scale_face_tiling(face: PBFace, factor: float) -> void:
	if face == null or factor == 0.0:
		return
	face.uv_scale *= factor
