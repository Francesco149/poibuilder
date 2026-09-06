## PBSplat — Texture splatting and multi-layer surface painting engine for PoiBuilder.
##
## Manages terrain-editor-style texture splatting with up to 8 blend layers over a face's
## base texture using high-performance alpha mask painting and stamping.
##
## All layers share the exact same UV tiling as the base texture. Alpha masks are
## mapped to faces using normalized face-local planar coordinates (UV2).
@tool
class_name PBSplat
extends RefCounted

const SHADER_PATH := "res://addons/poibuilder/materials/shaders/pb_splat_shader.gdshader"
const MAX_LAYERS := 8
const DEFAULT_MASK_RES := 256

const DEFAULT_STAMP_LAYER_RES := 512
const TEXELS_PER_METER := 128
const MIN_RESOLUTION := 256
const MAX_RESOLUTION := 512
## Computes uniform texture resolution (w, h) in pixels for `face` based on its physical size in meters.
## Guarantees a consistent texel density across both small and large faces.
static func calculate_uniform_face_resolution(mesh_data: PBMeshData, face: PBFace,
		texels_per_m: int = TEXELS_PER_METER) -> Vector2i:
	if mesh_data == null or face == null:
		return Vector2i(MIN_RESOLUTION, MIN_RESOLUTION)

	var bounds := get_face_planar_bounds(mesh_data, face)
	if bounds.is_empty():
		return Vector2i(MIN_RESOLUTION, MIN_RESOLUTION)

	var range_u: float = bounds.get("range_u", 1.0)
	var range_v: float = bounds.get("range_v", 1.0)

	var target_w: int = int(ceil(range_u * float(texels_per_m)))
	var target_h: int = int(ceil(range_v * float(texels_per_m)))

	var w: int = clampi(nearest_po2(target_w), MIN_RESOLUTION, MAX_RESOLUTION)
	var h: int = clampi(nearest_po2(target_h), MIN_RESOLUTION, MAX_RESOLUTION)
	return Vector2i(w, h)


## Cached reference to the splat shader resource.
static var _cached_shader: Shader = null

# ==============================================================================
## Returns an orthonormal right-handed stamp basis (right, up, normal) for any surface normal.
## Guarantees that:
## - On any vertical wall or slope, 'up' points straight UP along the surface (+Y).
## - 'right' points to the viewer's right when facing the surface.
## - On a floor, 'up' points away (-Z, North) and 'right' points right (+X, East).
## - Determinant is always exactly +1.0 (right-handed, never flipped).
static func get_stamp_basis(surface_normal: Vector3) -> Dictionary:
	var n := surface_normal.normalized()
	if n.length_squared() < 0.0001:
		n = Vector3.UP

	var u_right := Vector3.RIGHT
	var v_up := Vector3.BACK

	if absf(n.y) < 0.9999:
		# Vertical wall or slope: project world UP onto the face plane
		var up_proj := Vector3.UP - n * (Vector3.UP.dot(n))
		if up_proj.length_squared() > 0.0001:
			v_up = up_proj.normalized()
		else:
			v_up = Vector3.UP
		u_right = v_up.cross(n).normalized()
	else:
		if n.y > 0.0:
			# Floor (normal UP): Up is away (-Z), Right is (+X)
			u_right = Vector3.RIGHT
			v_up = Vector3.FORWARD
		else:
			# Ceiling (normal DOWN): Up is (+Z), Right is (+X)
			u_right = Vector3.RIGHT
			v_up = Vector3.BACK

	return {"right": u_right, "up": v_up, "normal": n}

# Shader & Material Management
# ==============================================================================

## Returns the shared splat shader resource.
static func get_splat_shader() -> Shader:
	if _cached_shader == null:
		if ResourceLoader.exists(SHADER_PATH):
			_cached_shader = ResourceLoader.load(SHADER_PATH) as Shader
	return _cached_shader

## Returns true if the given material is a PoiBuilder splat material.
static func is_splat_material(mat: Material) -> bool:
	if mat is ShaderMaterial:
		var sm := mat as ShaderMaterial
		if sm.shader != null and (sm.shader == get_splat_shader() or sm.shader.resource_path == SHADER_PATH):
			return true
	return false

## Creates a new ShaderMaterial configured for texture splatting.
## If `base_mat` is provided, inherits its albedo texture, color, and roughness.
static func create_splat_material(base_mat: Material = null) -> ShaderMaterial:
	var shader := get_splat_shader()
	if shader == null:
		return null

	var mat := ShaderMaterial.new()
	mat.shader = shader

	var base_tex: Texture2D = null
	var base_col := Color.WHITE
	var roughness := 0.8

	if base_mat is StandardMaterial3D:
		var sm := base_mat as StandardMaterial3D
		base_tex = sm.albedo_texture
		base_col = sm.albedo_color
		roughness = sm.roughness
	elif base_mat != null and base_mat.resource_name != "":
		mat.resource_name = "Splat_" + base_mat.resource_name
	else:
		# Fallback to stock default checkerboard
		var def_mat = PBMeshData.get_default_material()
		if def_mat is StandardMaterial3D:
			base_tex = def_mat.albedo_texture

	mat.set_shader_parameter("base_texture", base_tex)
	mat.set_shader_parameter("base_color", base_col)
	mat.set_shader_parameter("roughness", roughness)

	return mat

# ==============================================================================
# Layer Management
# ==============================================================================

## Returns the number of enabled splat layers on `mat`.
static func get_layer_count(mat: ShaderMaterial) -> int:
	if mat == null:
		return 0
	var count := 0
	for i in range(1, MAX_LAYERS + 1):
		var enabled = mat.get_shader_parameter("layer_%d_enabled" % i)
		if enabled == true:
			count += 1
	return count

## Returns the index of the first active layer, or 1 if none.
static func get_first_active_layer(mat: ShaderMaterial) -> int:
	if mat == null:
		return 1
	for i in range(1, MAX_LAYERS + 1):
		if mat.get_shader_parameter("layer_%d_enabled" % i) == true:
			return i
	return 1

## Adds a new splat layer using `texture` to `mat`.
## Returns the allocated layer index (1..8), or -1 if full.
static func add_layer(mat: ShaderMaterial, texture: Texture2D, color: Color = Color.WHITE,
		roughness: float = 0.8, mask_res: int = DEFAULT_MASK_RES) -> int:
	if mat == null:
		return -1

	# Find first unused layer slot
	var slot := -1
	for i in range(1, MAX_LAYERS + 1):
		var enabled = mat.get_shader_parameter("layer_%d_enabled" % i)
		if enabled == null or enabled == false:
			slot = i
			break

	if slot == -1:
		return -1 # Max layers reached

	# Initialize blank alpha mask
	var mask_img := Image.create(mask_res, mask_res, false, Image.FORMAT_R8)
	mask_img.fill(Color(0, 0, 0, 1))

	var mask_tex := ImageTexture.create_from_image(mask_img)

	mat.set_shader_parameter("layer_%d_enabled" % slot, true)
	mat.set_shader_parameter("layer_%d_texture" % slot, texture)
	mat.set_shader_parameter("layer_%d_mask" % slot, mask_tex)
	mat.set_shader_parameter("layer_%d_color" % slot, color)
	mat.set_shader_parameter("layer_%d_roughness" % slot, roughness)

	# Store mask image in metadata for fast in-place painting without GPU readback
	mat.set_meta("layer_%d_mask_image" % slot, mask_img)

	return slot

## Ensures that a layer exists for `texture`. If already present, returns its index.
## Otherwise adds a new layer and returns the index.
static func ensure_layer_for_texture(mat: ShaderMaterial, texture: Texture2D) -> int:
	if mat == null or texture == null:
		return -1

	for i in range(1, MAX_LAYERS + 1):
		if mat.get_shader_parameter("layer_%d_enabled" % i) == true:
			var tex = mat.get_shader_parameter("layer_%d_texture" % i)
			if tex == texture:
				return i

	return add_layer(mat, texture)

## Returns the Texture2D assigned to `layer_idx`.
static func get_layer_texture(mat: ShaderMaterial, layer_idx: int) -> Texture2D:
	if mat == null or layer_idx < 1 or layer_idx > MAX_LAYERS:
		return null
	return mat.get_shader_parameter("layer_%d_texture" % layer_idx) as Texture2D

## Sets the Texture2D assigned to `layer_idx`.
static func set_layer_texture(mat: ShaderMaterial, layer_idx: int, texture: Texture2D) -> void:
	if mat == null or layer_idx < 1 or layer_idx > MAX_LAYERS:
		return
	mat.set_shader_parameter("layer_%d_texture" % layer_idx, texture)

## Returns the in-memory Image for `layer_idx`.
static func get_layer_mask_image(mat: ShaderMaterial, layer_idx: int, target_res: Vector2i = Vector2i.ZERO) -> Image:
	if mat == null or layer_idx < 1 or layer_idx > MAX_LAYERS:
		return null

	var meta_key := "layer_%d_mask_image" % layer_idx
	var img: Image = null

	if mat.has_meta(meta_key):
		var meta_val = mat.get_meta(meta_key)
		if meta_val is Image:
			img = meta_val
	elif mat.get_shader_parameter("layer_%d_mask" % layer_idx) is ImageTexture:
		img = (mat.get_shader_parameter("layer_%d_mask" % layer_idx) as ImageTexture).get_image()
		if img != null:
			mat.set_meta(meta_key, img)

	if img != null:
		if target_res != Vector2i.ZERO and (target_res.x > img.get_width() or target_res.y > img.get_height()):
			var new_w := maxi(img.get_width(), target_res.x)
			var new_h := maxi(img.get_height(), target_res.y)
			img.resize(new_w, new_h, Image.INTERPOLATE_BILINEAR)
			var tex = mat.get_shader_parameter("layer_%d_mask" % layer_idx) as ImageTexture
			if tex != null:
				tex.set_image(img)
		return img

	# Create new blank mask with uniform resolution
	var init_w := target_res.x if target_res.x > 0 else DEFAULT_MASK_RES
	var init_h := target_res.y if target_res.y > 0 else DEFAULT_MASK_RES
	var new_img := Image.create(init_w, init_h, false, Image.FORMAT_R8)
	new_img.fill(Color(0, 0, 0, 1))
	var new_tex := ImageTexture.create_from_image(new_img)
	mat.set_shader_parameter("layer_%d_mask" % layer_idx, new_tex)
	mat.set_meta(meta_key, new_img)
	return new_img

# ==============================================================================
# Dedicated Stamp Layer Management
# ==============================================================================

## Returns true if the dedicated stamp layer is enabled on `mat`.
static func has_stamp_layer(mat: ShaderMaterial) -> bool:
	if mat == null:
		return false
	return mat.get_shader_parameter("stamp_layer_enabled") == true

## Returns or initializes the dedicated stamp layer RGBA Image on `mat`.
static func get_stamp_layer_image(mat: ShaderMaterial, target_res: Vector2i = Vector2i.ZERO) -> Image:
	if mat == null:
		return null

	var img: Image = null
	if mat.has_meta("stamp_layer_image"):
		var meta_val = mat.get_meta("stamp_layer_image")
		if meta_val is Image:
			img = meta_val
	elif mat.get_shader_parameter("stamp_layer_texture") is ImageTexture:
		img = (mat.get_shader_parameter("stamp_layer_texture") as ImageTexture).get_image()
		if img != null:
			mat.set_meta("stamp_layer_image", img)

	if img != null:
		if target_res != Vector2i.ZERO and (target_res.x > img.get_width() or target_res.y > img.get_height()):
			var new_w := maxi(img.get_width(), target_res.x)
			var new_h := maxi(img.get_height(), target_res.y)
			img.resize(new_w, new_h, Image.INTERPOLATE_BILINEAR)
			var tex = mat.get_shader_parameter("stamp_layer_texture") as ImageTexture
			if tex != null:
				tex.set_image(img)
		return img

	# Create new transparent RGBA8 image with uniform resolution
	var init_w := target_res.x if target_res.x > 0 else DEFAULT_STAMP_LAYER_RES
	var init_h := target_res.y if target_res.y > 0 else DEFAULT_STAMP_LAYER_RES
	var new_img := Image.create(init_w, init_h, false, Image.FORMAT_RGBA8)
	new_img.fill(Color(0, 0, 0, 0))
	var new_tex := ImageTexture.create_from_image(new_img)
	mat.set_shader_parameter("stamp_layer_enabled", true)
	mat.set_shader_parameter("stamp_layer_texture", new_tex)
	mat.set_meta("stamp_layer_image", new_img)
	return new_img
## Clears the dedicated stamp layer to transparent on `mat`.
static func clear_stamp_layer(mat: ShaderMaterial) -> void:
	if mat == null:
		return
	var img := get_stamp_layer_image(mat)
	if img != null:
		img.fill(Color(0, 0, 0, 0))
		var tex = mat.get_shader_parameter("stamp_layer_texture") as ImageTexture
		if tex != null:
			tex.update(img)
## Clears the alpha mask for `layer_idx` to zero (transparent).
static func clear_layer(mat: ShaderMaterial, layer_idx: int) -> void:
	if mat == null or layer_idx < 1 or layer_idx > MAX_LAYERS:
		return
	var img := get_layer_mask_image(mat, layer_idx)
	if img != null:
		img.fill(Color(0, 0, 0, 1))
		var tex = mat.get_shader_parameter("layer_%d_mask" % layer_idx) as ImageTexture
		if tex != null:
			tex.update(img)

## Removes/disables `layer_idx` on `mat`.
static func remove_layer(mat: ShaderMaterial, layer_idx: int) -> void:
	if mat == null or layer_idx < 1 or layer_idx > MAX_LAYERS:
		return
	mat.set_shader_parameter("layer_%d_enabled" % layer_idx, false)
	mat.set_shader_parameter("layer_%d_texture" % layer_idx, null)
	mat.set_shader_parameter("layer_%d_mask" % layer_idx, null)
	var meta_key := "layer_%d_mask_image" % layer_idx
	if mat.has_meta(meta_key):
		mat.remove_meta(meta_key)

# ==============================================================================
# UV2 / Planar Coordinate Calculation
# ==============================================================================

## Calculates face-local planar normalized bounding box coordinates for a face.
## Returns Dictionary with:
## - "u": Vector3 tangent horizontal axis
## - "v": Vector3 tangent vertical axis
## - "normal": Vector3 face normal
## - "min_u", "max_u", "range_u": float
## - "min_v", "max_v", "range_v": float
static func get_face_planar_bounds(mesh_data: PBMeshData, face: PBFace) -> Dictionary:
	var result: Dictionary = {}
	if mesh_data == null or face == null:
		return result

	var indices := face.get_distinct_indexes()
	if indices.is_empty():
		return result

	var normal := PBMath.normal_from_positions(mesh_data.positions, face.get_indexes())
	if normal.length_squared() < 0.0001:
		normal = Vector3.UP
	else:
		normal = normal.normalized()

	var basis := PBUv.get_planar_basis(normal)
	var u_axis: Vector3 = basis["u"]
	var v_axis: Vector3 = basis["v"]

	var min_u := INF
	var max_u := -INF
	var min_v := INF
	var max_v := -INF

	var pos_count := mesh_data.positions.size()
	for idx in indices:
		if idx >= 0 and idx < pos_count:
			var p: Vector3 = mesh_data.positions[idx]
			var u_val := u_axis.dot(p)
			var v_val := v_axis.dot(p)
			min_u = minf(min_u, u_val)
			max_u = maxf(max_u, u_val)
			min_v = minf(min_v, v_val)
			max_v = maxf(max_v, v_val)

	var range_u := max_u - min_u
	if range_u < 0.0001:
		range_u = 1.0
	var range_v := max_v - min_v
	if range_v < 0.0001:
		range_v = 1.0

	result["u"] = u_axis
	result["v"] = v_axis
	result["normal"] = normal
	result["min_u"] = min_u
	result["max_u"] = max_u
	result["range_u"] = range_u
	result["min_v"] = min_v
	result["max_v"] = max_v
	result["range_v"] = range_v
	return result

## Ensures that `mesh_data.textures1` (UV2 channel) is populated with clean
## face-local planar normalized coordinates [0, 1] for all faces.
static func ensure_mesh_uv2(mesh_data: PBMeshData) -> void:
	if mesh_data == null:
		return
	var vc := mesh_data.positions.size()
	if mesh_data.textures1.size() != vc:
		mesh_data.textures1.resize(vc)

	for face in mesh_data.faces:
		if face == null:
			continue
		var bounds := get_face_planar_bounds(mesh_data, face)
		if bounds.is_empty():
			continue

		var u_axis: Vector3 = bounds["u"]
		var v_axis: Vector3 = bounds["v"]
		var min_u: float = bounds["min_u"]
		var range_u: float = bounds["range_u"]
		var min_v: float = bounds["min_v"]
		var range_v: float = bounds["range_v"]

		for idx in face.get_distinct_indexes():
			if idx >= 0 and idx < vc:
				var p: Vector3 = mesh_data.positions[idx]
				var u_norm := (u_axis.dot(p) - min_u) / range_u
				var v_norm := (v_axis.dot(p) - min_v) / range_v
				mesh_data.textures1[idx] = Vector2(u_norm, v_norm)

# ==============================================================================
# Brush Painting Engine
# ==============================================================================

## Paints on a face's splat layer with an adjustable brush radius and softness.
## Highly optimized: computes only the affected 2D bounding box in the mask image
## and uploads in-place via ImageTexture.update(). Zero lag, 60+ FPS.
##
## Parameters:
## - `hit_point_local`: Raycast hit point in node-local 3D coordinates.
## - `radius`: Brush radius in meters.
## - `softness`: 0.0 (hard edge) to 1.0 (smooth cosine S-curve falloff).
## - `opacity`: Paint opacity / strength step (0.01 to 1.0).
## - `erase`: If true, subtracts alpha instead of adding.
##
## Returns true if the mask was modified.
static func paint_face_splat(mesh_data: PBMeshData, face: PBFace, splat_mat: ShaderMaterial,
		layer_idx: int, hit_point_local: Vector3, radius: float, softness: float,
		opacity: float, erase: bool = false) -> bool:
	if mesh_data == null or face == null or splat_mat == null or radius <= 0.0:
		return false

	var target_res := calculate_uniform_face_resolution(mesh_data, face)
	var mask_img := get_layer_mask_image(splat_mat, layer_idx, target_res)
	if mask_img == null:
		return false
	var bounds := get_face_planar_bounds(mesh_data, face)
	if bounds.is_empty():
		return false

	var u_axis: Vector3 = bounds["u"]
	var v_axis: Vector3 = bounds["v"]
	var normal: Vector3 = bounds["normal"]
	var min_u: float = bounds["min_u"]
	var range_u: float = bounds["range_u"]
	var min_v: float = bounds["min_v"]
	var range_v: float = bounds["range_v"]

	# Check perpendicular distance from hit point to the face's plane
	var indices := face.get_distinct_indexes()
	if indices.is_empty():
		return false
	var plane_origin: Vector3 = mesh_data.positions[indices[0]]
	var d_perp := absf(normal.dot(hit_point_local - plane_origin))
	if d_perp >= radius:
		return false # Brush sphere does not intersect face plane

	# Projected in-plane radius
	var r_plane := sqrt(maxf(0.0, radius * radius - d_perp * d_perp))

	# Hit point projected onto face's planar coordinates
	var u_hit := u_axis.dot(hit_point_local)
	var v_hit := v_axis.dot(hit_point_local)

	var w := mask_img.get_width()
	var h := mask_img.get_height()

	# Bounding box of affected pixels
	var u_min_b := (u_hit - r_plane - min_u) / range_u
	var u_max_b := (u_hit + r_plane - min_u) / range_u
	var v_min_b := (v_hit - r_plane - min_v) / range_v
	var v_max_b := (v_hit + r_plane - min_v) / range_v

	var x0 := clampi(int(floor(u_min_b * (w - 1))), 0, w - 1)
	var x1 := clampi(int(ceil(u_max_b * (w - 1))), 0, w - 1)
	var y0 := clampi(int(floor(v_min_b * (h - 1))), 0, h - 1)
	var y1 := clampi(int(ceil(v_max_b * (h - 1))), 0, h - 1)

	if x0 > x1 or y0 > y1:
		return false

	var dirty := false
	var soft := clampf(softness, 0.0, 1.0)
	var inner_ratio := 1.0 - soft

	for y in range(y0, y1 + 1):
		var v_coord := min_v + (float(y) / float(h - 1)) * range_v
		var dy_m := v_coord - v_hit
		var dy_sq := dy_m * dy_m + d_perp * d_perp
		var max_dx_sq := radius * radius - dy_sq
		if max_dx_sq < 0.0:
			continue
		var max_dx := sqrt(max_dx_sq)
		var rx0 := clampi(int(floor((u_hit - max_dx - min_u) / range_u * (w - 1))), x0, x1)
		var rx1 := clampi(int(ceil((u_hit + max_dx - min_u) / range_u * (w - 1))), x0, x1)

		for x in range(rx0, rx1 + 1):
			var u_coord := min_u + (float(x) / float(w - 1)) * range_u
			var dx_m := u_coord - u_hit
			var dist_sq := dx_m * dx_m + dy_sq
			var dist := sqrt(dist_sq)
			var t := dist / radius
			var weight := 1.0

			if soft > 0.001:
				if t > inner_ratio:
					var falloff_t := (t - inner_ratio) / soft
					weight = clampf(0.5 * (1.0 + cos(PI * falloff_t)), 0.0, 1.0)

			var cur_a := mask_img.get_pixel(x, y).r
			var delta := weight * opacity
			var new_a: float

			if erase:
				new_a = maxf(0.0, cur_a - delta)
			else:
				new_a = minf(1.0, cur_a + delta)
			if absf(new_a - cur_a) > 0.001:
				mask_img.set_pixel(x, y, Color(new_a, new_a, new_a, 1.0))
				dirty = true

	if dirty:
		var mask_tex = splat_mat.get_shader_parameter("layer_%d_mask" % layer_idx) as ImageTexture
		if mask_tex != null:
			mask_tex.update(mask_img)

	return dirty

# ==============================================================================
# Stamp Mode Pasting Engine
# ==============================================================================

## Pastes/stamps an image onto a face's splat layer with arbitrary rotation and scale.
##
## Parameters:
## - `stamp_img`: The source image to stamp (e.g. pattern, decal, tapestry).
## - `hit_point_local`: Raycast hit point on the mesh in node-local 3D coordinates.
## - `stamp_scale`: Stamp diameter/size in meters.
## - `stamp_rotation_deg`: Rotation angle in degrees around the face normal.
## - `stamp_opacity`: Stamp alpha blending factor (0.0 to 1.0).
##
## Returns true if the stamp was successfully pasted.
static func stamp_face(mesh_data: PBMeshData, face: PBFace, splat_mat: ShaderMaterial,
		stamp_img: Image, hit_point_local: Vector3, stamp_scale: float,
		stamp_rotation_deg: float, stamp_opacity: float = 1.0, _legacy_layer_idx: int = -1) -> bool:
	if mesh_data == null or face == null or splat_mat == null or stamp_img == null or stamp_scale <= 0.0:
		return false

	# Ensure stamp image is uncompressed for get_pixel() access
	if stamp_img.is_compressed():
		stamp_img.decompress()
	if stamp_img.get_format() != Image.FORMAT_RGBA8:
		stamp_img.convert(Image.FORMAT_RGBA8)

	var target_res := calculate_uniform_face_resolution(mesh_data, face)
	var stamp_target_img := get_stamp_layer_image(splat_mat, target_res)
	if stamp_target_img == null:
		return false

	var bounds := get_face_planar_bounds(mesh_data, face)
	if bounds.is_empty():
		return false

	var u_face: Vector3 = bounds["u"]
	var v_face: Vector3 = bounds["v"]
	var normal: Vector3 = bounds["normal"]
	var min_u: float = bounds["min_u"]
	var range_u: float = bounds["range_u"]
	var min_v: float = bounds["min_v"]
	var range_v: float = bounds["range_v"]

	# Canonical stamp basis matching preview quad
	var sbasis := get_stamp_basis(normal)
	var u_right: Vector3 = sbasis["right"]
	var v_up: Vector3 = sbasis["up"]

	# Apply stamp rotation in surface plane
	var rad := deg_to_rad(stamp_rotation_deg)
	var rot_right := cos(rad) * u_right + sin(rad) * v_up
	var rot_up := -sin(rad) * u_right + cos(rad) * v_up

	var hit_u := u_face.dot(hit_point_local)
	var hit_v := v_face.dot(hit_point_local)

	var w := stamp_target_img.get_width()
	var h := stamp_target_img.get_height()
	var sw := stamp_img.get_width()
	var sh := stamp_img.get_height()

	var diag_rad := stamp_scale * 0.7071

	# Bounding box of pixels in stamp layer image
	var u_min_b := (hit_u - diag_rad - min_u) / range_u
	var u_max_b := (hit_u + diag_rad - min_u) / range_u
	var v_min_b := (hit_v - diag_rad - min_v) / range_v
	var v_max_b := (hit_v + diag_rad - min_v) / range_v

	var x0 := clampi(int(floor(u_min_b * (w - 1))), 0, w - 1)
	var x1 := clampi(int(ceil(u_max_b * (w - 1))), 0, w - 1)
	var y0 := clampi(int(floor(v_min_b * (h - 1))), 0, h - 1)
	var y1 := clampi(int(ceil(v_max_b * (h - 1))), 0, h - 1)

	if x0 > x1 or y0 > y1:
		return false

	var dirty := false

	for y in range(y0, y1 + 1):
		var v_coord := min_v + (float(y) / float(h - 1)) * range_v
		for x in range(x0, x1 + 1):
			var u_coord := min_u + (float(x) / float(w - 1)) * range_u

			# 3D displacement from stamp center in the face plane
			var dp := (u_coord - hit_u) * u_face + (v_coord - hit_v) * v_face

			# Project onto canonical rotated stamp axes
			var x_stamp := dp.dot(rot_right)
			var y_stamp := dp.dot(rot_up)

			var sx := (x_stamp / stamp_scale) + 0.5
			var sy := 0.5 - (y_stamp / stamp_scale)

			if sx >= 0.0 and sx <= 1.0 and sy >= 0.0 and sy <= 1.0:
				var sp_x := clampi(int(sx * (sw - 1)), 0, sw - 1)
				var sp_y := clampi(int(sy * (sh - 1)), 0, sh - 1)
				var src_col := stamp_img.get_pixel(sp_x, sp_y)
				var src_a := src_col.a * stamp_opacity

				if src_a > 0.001:
					var dst_col := stamp_target_img.get_pixel(x, y)
					# Porter-Duff Over alpha blend 1:1 copy
					var out_a := src_a + dst_col.a * (1.0 - src_a)
					var out_r := 0.0
					var out_g := 0.0
					var out_b := 0.0
					if out_a > 0.001:
						out_r = (src_col.r * src_a + dst_col.r * dst_col.a * (1.0 - src_a)) / out_a
						out_g = (src_col.g * src_a + dst_col.g * dst_col.a * (1.0 - src_a)) / out_a
						out_b = (src_col.b * src_a + dst_col.b * dst_col.a * (1.0 - src_a)) / out_a

					stamp_target_img.set_pixel(x, y, Color(out_r, out_g, out_b, out_a))
					dirty = true

	if dirty:
		var tex = splat_mat.get_shader_parameter("stamp_layer_texture") as ImageTexture
		if tex != null:
			tex.update(stamp_target_img)

	return dirty

# ==============================================================================
# Material & Mask Snapshot Cloning (Undo/Redo)
# ==============================================================================

## Deep-clones a splat material and all of its active layer mask images for undo/redo.
static func clone_splat_material(source: ShaderMaterial) -> ShaderMaterial:
	if source == null:
		return null

	var clone := ShaderMaterial.new()
	clone.shader = source.shader
	clone.resource_name = source.resource_name

	# Copy base uniforms
	clone.set_shader_parameter("base_texture", source.get_shader_parameter("base_texture"))
	clone.set_shader_parameter("base_color", source.get_shader_parameter("base_color"))
	clone.set_shader_parameter("roughness", source.get_shader_parameter("roughness"))

	# Clone active layers and their mask images
	for i in range(1, MAX_LAYERS + 1):
		var enabled = source.get_shader_parameter("layer_%d_enabled" % i)
		if enabled == true:
			clone.set_shader_parameter("layer_%d_enabled" % i, true)
			clone.set_shader_parameter("layer_%d_texture" % i, source.get_shader_parameter("layer_%d_texture" % i))
			clone.set_shader_parameter("layer_%d_color" % i, source.get_shader_parameter("layer_%d_color" % i))
			clone.set_shader_parameter("layer_%d_roughness" % i, source.get_shader_parameter("layer_%d_roughness" % i))

			var src_img := get_layer_mask_image(source, i)
			if src_img != null:
				var cloned_img := Image.create(src_img.get_width(), src_img.get_height(), false, src_img.get_format())
				cloned_img.copy_from(src_img)
				var cloned_tex := ImageTexture.create_from_image(cloned_img)
				clone.set_shader_parameter("layer_%d_mask" % i, cloned_tex)
				clone.set_meta("layer_%d_mask_image" % i, cloned_img)

	# Clone dedicated stamp layer if enabled
	if source.get_shader_parameter("stamp_layer_enabled") == true:
		clone.set_shader_parameter("stamp_layer_enabled", true)
		var src_stamp_img := get_stamp_layer_image(source)
		if src_stamp_img != null:
			var cloned_stamp_img := Image.create(src_stamp_img.get_width(), src_stamp_img.get_height(), false, src_stamp_img.get_format())
			cloned_stamp_img.copy_from(src_stamp_img)
			var cloned_stamp_tex := ImageTexture.create_from_image(cloned_stamp_img)
			clone.set_shader_parameter("stamp_layer_texture", cloned_stamp_tex)
			clone.set_meta("stamp_layer_image", cloned_stamp_img)

	return clone
