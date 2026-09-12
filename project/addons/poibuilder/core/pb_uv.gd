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
## Robust Dominant-Axis Projection (ProBuilder parity):
## Determines which cardinal projection axis the normal faces predominantly:
## - Dominant Y (|ny| > |nx| and |ny| > |nz|, e.g. floors, ceilings, roofs, horizontal slopes):
##   U aligns with world X (+X), and V aligns with world Z (+Z on floors/slopes).
##   Lifting an edge or vertex stretches the texture naturally along the slope without
##   sudden 45-degree diagonal spins or 90-degree U/V axis swaps.
## - Dominant Z (|nz| >= |nx|, e.g. front/back walls, steep north/south slopes, 45-deg roofs):
##   U is horizontal along X, and V points up along the slope.
## - Dominant X (|nx| > |nz|, e.g. right/left walls, steep east/west slopes, 45-deg roofs):
##   U is horizontal along Z (+Z), and V points up along the slope.
static func get_planar_basis(normal: Vector3) -> Dictionary:
	var n := normal.normalized() if normal.length_squared() > 0.000001 else Vector3.UP
	var u := Vector3.ZERO
	var v := Vector3.ZERO

	var ax := absf(n.x)
	var ay := absf(n.y)
	var az := absf(n.z)

	const EPS := 0.0001

	if (ax - ay > EPS) and (ax - az > EPS):
		# Dominant X (Right / Left wall or steep east/west slope)
		var prj := Vector3.UP
		if n.x >= 0.0:
			u = n.cross(prj)
			v = u.cross(n)
		else:
			u = prj.cross(n)
			v = n.cross(u)
	elif (ay - az > EPS):
		# Dominant Y (Floor / Ceiling / gentle roof slope / tilted floor)
		if n.y >= 0.0:
			var prj := Vector3.BACK
			u = n.cross(prj)
			v = u.cross(n)
		else:
			var prj := Vector3.FORWARD
			u = n.cross(prj)
			v = n.cross(u)
	else:
		# Dominant Z (Front / Back wall or steep north/south slope, or 45-deg roof)
		var prj := Vector3.UP
		u = prj.cross(n)
		v = n.cross(u)

	if u.length_squared() < 0.0001:
		u = Vector3.RIGHT
	else:
		u = u.normalized()

	if v.length_squared() < 0.0001:
		v = Vector3.BACK
	else:
		v = v.normalized()

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

	# Anchor face relative to the object's persistent texture anchor point.
	# This ensures that as the object is resized (whichever face moves, even
	# the one at the corner), texture tiling remains anchored to the same
	# absolute object-space point and never slides relative to the object.
	if not face.uv_use_world_space:
		var anchor: Vector3 = mesh_data.get_texture_anchor() if mesh_data != null else Vector3.ZERO
		var ax := absf(normal.x)
		var ay := absf(normal.y)
		var az := absf(normal.z)
		const EPS := 0.0001
		var anchor_proj := anchor
		if (ax - ay > EPS) and (ax - az > EPS):
			var ref_x: float = mesh_data.positions[indices[0]].x
			anchor_proj = Vector3(ref_x, anchor.y, anchor.z)
		elif (ay - az > EPS):
			var ref_y: float = mesh_data.positions[indices[0]].y
			anchor_proj = Vector3(anchor.x, ref_y, anchor.z)
		else:
			var ref_z: float = mesh_data.positions[indices[0]].z
			anchor_proj = Vector3(anchor.x, anchor.y, ref_z)

		var anchor_uv := Vector2(u_axis.dot(anchor_proj), v_axis.dot(anchor_proj))
		for i in range(raw_uvs.size()):
			raw_uvs[i] -= anchor_uv
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
## align with the object's texture anchor and inherit material and UV parameters.
static func setup_extruded_face_uvs(mesh_data: PBMeshData, side: PBFace,
		source_face: PBFace, _edge_a: int = -1, _edge_b: int = -1, _qa: int = -1, _qb: int = -1) -> void:
	if mesh_data == null or side == null:
		return
	if source_face != null:
		side.submesh_index = source_face.submesh_index
		side.uv_scale = source_face.uv_scale
		side.uv_rotation = source_face.uv_rotation
		side.uv_offset = source_face.uv_offset
		side.uv_flip_u = source_face.uv_flip_u
		side.uv_flip_v = source_face.uv_flip_v
		side.uv_swap_uv = source_face.uv_swap_uv
		side.uv_fill = source_face.uv_fill
		side.uv_anchor = source_face.uv_anchor
		side.uv_use_world_space = source_face.uv_use_world_space
	else:
		side.uv_use_world_space = false
		side.uv_anchor = Anchor.LOWER_LEFT

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

## Re-projects ONE face's UVs from its own planar basis and writes them into
## the mesh. Used by the mesh ops that BUILD a face out of other faces (merge):
## the new n-gon would otherwise inherit its corners' old UVs, which fan out
## into diagonal stripes as soon as it is moved.
static func apply_face_uvs(mesh_data: PBMeshData, face: PBFace, force := false) -> void:
	if mesh_data == null or face == null:
		return
	if face.manual_uv and not force:
		return
	var vc: int = mesh_data.positions.size()
	if mesh_data.textures0.size() != vc:
		mesh_data.textures0.resize(vc)
	var uvs := calculate_face_uvs(mesh_data, face)
	for idx: int in uvs:
		if idx >= 0 and idx < vc:
			mesh_data.textures0[idx] = uvs[idx]

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

# ==============================================================================
# Animated UV scroll (retro-exportable scrolling textures)
# ==============================================================================
#
# A scrolling texture is a property of the MATERIAL, because that is the unit
# the retro exporters split meshes by: one mesh in the .pbm references one
# texture, and the scroll is stored per mesh in the file. The speed lives in
# the material's metadata under SCROLL_META as a Vector2, in TEXTURE REPEATS
# PER SECOND (1.0 = the texture crawls one full tile per second along that
# axis, 0.0 = that axis is static). The speed is signed, so a negative value
# scrolls the other way — that is how a waterfall sheet and its foam layer are
# given different directions from the same texture.

## Material metadata key holding the scroll speed (Vector2, repeats/second).
const SCROLL_META := "poi_uv_scroll"
## Material metadata key Godot's glTF exporter serializes to `extras` verbatim.
const GLTF_EXTRAS_META := "extras"

## The material's scroll speed in repeats/second, or Vector2.ZERO when it does
## not scroll. Accepts any Material (metadata is a Resource-level feature).
static func get_scroll_speed(mat: Material) -> Vector2:
	if mat == null or not mat.has_meta(SCROLL_META):
		return Vector2.ZERO
	var v = mat.get_meta(SCROLL_META)
	if v is Vector2:
		return v
	if v is Vector3:
		return Vector2(v.x, v.y)
	return Vector2.ZERO

static func has_scroll(mat: Material) -> bool:
	return get_scroll_speed(mat) != Vector2.ZERO

## Writes (or clears, with Vector2.ZERO) the material's scroll speed and keeps
## the glTF `extras` mirror in sync so an exported GLB carries the animation
## through to the retro converters.
static func set_scroll_speed(mat: Material, speed: Vector2) -> void:
	if mat == null:
		return
	if speed == Vector2.ZERO:
		mat.remove_meta(SCROLL_META)
	else:
		mat.set_meta(SCROLL_META, speed)
	_sync_gltf_extras(mat, speed)

## Mirrors the scroll speed into the material's `extras` metadata dictionary.
## Godot's glTF exporter serializes that dictionary verbatim into the material
## JSON (`_attach_meta_to_extras` in gltf_document.cpp), which is how
## pbm_conv.py and PBPbmConverter see the animation on the GLB path. Values are
## [u, v] float pairs: Vector2 is not a JSON type, and a Stringified Vector2
## would have to be parsed back out.
static func _sync_gltf_extras(mat: Material, speed: Vector2) -> void:
	var extras: Dictionary = mat.get_meta(GLTF_EXTRAS_META, {}) if mat.has_meta(GLTF_EXTRAS_META) else {}
	if speed == Vector2.ZERO:
		extras.erase(SCROLL_META)
		if extras.is_empty():
			mat.remove_meta(GLTF_EXTRAS_META)
		else:
			mat.set_meta(GLTF_EXTRAS_META, extras)
		return
	extras[SCROLL_META] = [speed.x, speed.y]
	mat.set_meta(GLTF_EXTRAS_META, extras)

## Reads a scroll speed out of a glTF `extras` dictionary (the inverse of
## _sync_gltf_extras; used by the converters, which see GLB JSON, not GDScript
## materials). Returns Vector2.ZERO when the extras carry no animation.
static func scroll_from_extras(extras) -> Vector2:
	if not (extras is Dictionary) or not extras.has(SCROLL_META):
		return Vector2.ZERO
	var v = extras[SCROLL_META]
	if v is Array and v.size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	if v is Dictionary and v.has("u") and v.has("v"):
		return Vector2(float(v["u"]), float(v["v"]))
	return Vector2.ZERO
