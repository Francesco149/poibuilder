## PBSplat — Texture splatting and multi-layer surface painting engine for PoiBuilder.
##
## Manages terrain-editor-style texture splatting with up to 8 blend layers over a face's
## base texture using high-performance alpha mask painting and stamping.
##
## All layers share the exact same UV tiling as the base texture. Alpha masks are
## mapped to faces using normalized face-local planar coordinates, carried by
## the CUSTOM0 vertex attribute (see PBMeshData.splat_uvs) — never UV2, which
## stays free for an authored LightmapGI unwrap.
@tool
class_name PBSplat
extends RefCounted

const SHADER_PATH := "res://addons/poibuilder/materials/shaders/pb_splat_shader.gdshader"
const MAX_LAYERS := 8
const DEFAULT_MASK_RES := 256

## Face-normal alignment cutoffs for decal writes. A face turned more than this
## far from the decal's normal is skipped: stamps may wrap onto a perpendicular
## neighbour (a wall's floor), brush dabs stay on surfaces they are facing
## (otherwise a stroke smears its pattern sideways onto every wall it passes).
## Child node name the previous stamp design used for its decal quads.
const LEGACY_STAMP_CONTAINER := "PBStamps"
const DECAL_MIN_FACE_ALIGNMENT := -0.2
const DECAL_MIN_DAB_ALIGNMENT := 0.25
const DEFAULT_DECAL_LAYER_RES := 512
const TEXELS_PER_METER := 256
const MIN_RESOLUTION := 256
const MAX_RESOLUTION := 2048
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

## Brush falloff lookup table cache, keyed by quantized softness.
## The LUT maps SQUARED normalized distance t^2 (in [0,1)) to the brush weight,
## so the inner paint loop needs no sqrt/cos per pixel — the dominant cost at
## the uniform 256 texels/m mask density (a 0.4m dab on a 2m face walks ~40k
## pixels at every mouse motion event).
static var _brush_lut_cache: Dictionary = {}
static var _brush_lut_bytes_cache: Dictionary = {}
const BRUSH_LUT_SIZE := 1024

## In-memory CPU mask and stamp image cache (keyed by mat.get_instance_id() and slot/name).
## Eliminates storing uncompressed multi-megabyte Images in Resource metadata,
## which caused .tscn text scenes to explode to 30+ MB.
static var _cpu_image_cache: Dictionary = {}

## Bumped whenever any splat layer mask, decal layer, or layer set changes, so
## downstream caches (the UV editor's splat composite preview) know when to rebuild.
static var mask_state_version: int = 0

static func _get_cached_image(mat: ShaderMaterial, key: String) -> Image:
	if mat == null:
		return null
	var id := mat.get_instance_id()
	if _cpu_image_cache.has(id):
		return _cpu_image_cache[id].get(key, null)
	return null

static func _set_cached_image(mat: ShaderMaterial, key: String, img: Image) -> void:
	if mat == null or img == null:
		return
	var id := mat.get_instance_id()
	if not _cpu_image_cache.has(id):
		_cpu_image_cache[id] = {}
	_cpu_image_cache[id][key] = img

static func _get_brush_lut(softness: float) -> PackedFloat32Array:
	var key := int(round(softness * 1000.0))
	var lut: PackedFloat32Array = _brush_lut_cache.get(key, PackedFloat32Array())
	if lut.size() == BRUSH_LUT_SIZE:
		return lut
	var soft := clampf(softness, 0.0, 1.0)
	var inner_ratio := 1.0 - soft
	lut = PackedFloat32Array()
	lut.resize(BRUSH_LUT_SIZE)
	for i in range(BRUSH_LUT_SIZE):
		# Table index encodes t^2; evaluate the falloff at t = sqrt(i / size).
		var t := sqrt(float(i) / float(BRUSH_LUT_SIZE))
		var weight := 1.0
		if soft > 0.001 and t > inner_ratio:
			weight = clampf(0.5 * (1.0 + cos(PI * (t - inner_ratio) / soft)), 0.0, 1.0)
		lut[i] = weight
	_brush_lut_cache[key] = lut
	return lut

static func _get_brush_lut_bytes(softness: float) -> PackedByteArray:
	var key := int(round(softness * 1000.0))
	var lut: PackedByteArray = _brush_lut_bytes_cache.get(key, PackedByteArray())
	if lut.size() == BRUSH_LUT_SIZE:
		return lut
	var float_lut := _get_brush_lut(softness)
	lut = PackedByteArray()
	lut.resize(BRUSH_LUT_SIZE)
	for i in range(BRUSH_LUT_SIZE):
		lut[i] = int(round(float_lut[i] * 255.0))
	_brush_lut_bytes_cache[key] = lut
	return lut

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
	mask_state_version += 1

	# Store mask image in CPU memory cache (never serialize raw uncompressed Images to scene metadata)
	_set_cached_image(mat, "layer_%d" % slot, mask_img)
	if mat.has_meta("layer_%d_mask_image" % slot):
		mat.remove_meta("layer_%d_mask_image" % slot)
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

	var cache_key := "layer_%d" % layer_idx
	var img := _get_cached_image(mat, cache_key)

	if img == null:
		var meta_key := "layer_%d_mask_image" % layer_idx
		if mat.has_meta(meta_key):
			var meta_val = mat.get_meta(meta_key)
			if meta_val is Image:
				img = meta_val
			mat.remove_meta(meta_key)
		elif mat.get_shader_parameter("layer_%d_mask" % layer_idx) is ImageTexture:
			img = (mat.get_shader_parameter("layer_%d_mask" % layer_idx) as ImageTexture).get_image()
		if img != null:
			_set_cached_image(mat, cache_key, img)

	if img != null:
		if target_res != Vector2i.ZERO and (target_res.x > img.get_width() or target_res.y > img.get_height()):
			var new_w := maxi(img.get_width(), target_res.x)
			var new_h := maxi(img.get_height(), target_res.y)
			img.resize(new_w, new_h, Image.INTERPOLATE_BILINEAR)
			var tex = mat.get_shader_parameter("layer_%d_mask" % layer_idx) as ImageTexture
			if tex != null:
				tex.set_image(img)
			mask_state_version += 1
		return img

	# Create new blank mask with uniform resolution
	var init_w := target_res.x if target_res.x > 0 else DEFAULT_MASK_RES
	var init_h := target_res.y if target_res.y > 0 else DEFAULT_MASK_RES
	var new_img := Image.create(init_w, init_h, false, Image.FORMAT_R8)
	new_img.fill(Color(0, 0, 0, 1))
	var new_tex := ImageTexture.create_from_image(new_img)
	mat.set_shader_parameter("layer_%d_mask" % layer_idx, new_tex)
	_set_cached_image(mat, cache_key, new_img)
	mask_state_version += 1
	return new_img
# ==============================================================================
# Decal Layer (painted image overlay: stamps + free drawing)
# ==============================================================================

## The decal layer is one RGBA image per material, mapped 1:1 over each face's
## planar rect (the same [0,1] space as the splat masks) — the pixels ARE the
## content, so a pasted PNG keeps its own colors and alpha instead of being
## tinted through a layer texture. Everything that lands here is painted
## through the same rasterizer: a stamp is one oriented paste, the brush is a
## run of dabs, and both may span several faces (a stamp can overhang an edge
## and continue on the neighbouring face).
##
## Shader uniform names stay `stamp_layer_*` from the previous design so scenes
## saved before the rename keep their painted content.

## Returns true if the decal layer exists on `mat`.
static func has_decal_layer(mat: ShaderMaterial) -> bool:
	if mat == null:
		return false
	return mat.get_shader_parameter("stamp_layer_enabled") == true

## Returns or initializes the decal layer RGBA Image on `mat`.
static func get_decal_layer_image(mat: ShaderMaterial, target_res: Vector2i = Vector2i.ZERO) -> Image:
	if mat == null:
		return null

	var cache_key := "stamp"
	var img := _get_cached_image(mat, cache_key)

	if img == null:
		if mat.has_meta("stamp_layer_image"):
			var meta_val = mat.get_meta("stamp_layer_image")
			if meta_val is Image:
				img = meta_val
			mat.remove_meta("stamp_layer_image")
		elif mat.get_shader_parameter("stamp_layer_texture") is ImageTexture:
			img = (mat.get_shader_parameter("stamp_layer_texture") as ImageTexture).get_image()
		if img != null:
			_set_cached_image(mat, cache_key, img)

	if img != null:
		if target_res != Vector2i.ZERO and (target_res.x > img.get_width() or target_res.y > img.get_height()):
			var new_w := maxi(img.get_width(), target_res.x)
			var new_h := maxi(img.get_height(), target_res.y)
			img.resize(new_w, new_h, Image.INTERPOLATE_BILINEAR)
			var tex = mat.get_shader_parameter("stamp_layer_texture") as ImageTexture
			if tex != null:
				tex.set_image(img)
			mask_state_version += 1
		return img

	# Create new transparent RGBA8 image with uniform resolution
	var init_w := target_res.x if target_res.x > 0 else DEFAULT_DECAL_LAYER_RES
	var init_h := target_res.y if target_res.y > 0 else DEFAULT_DECAL_LAYER_RES
	var new_img := Image.create(init_w, init_h, false, Image.FORMAT_RGBA8)
	new_img.fill(Color(0, 0, 0, 0))
	var new_tex := ImageTexture.create_from_image(new_img)
	mat.set_shader_parameter("stamp_layer_enabled", true)
	mat.set_shader_parameter("stamp_layer_texture", new_tex)
	_set_cached_image(mat, cache_key, new_img)
	mask_state_version += 1
	return new_img
## Clears the decal layer to transparent on `mat`.
static func clear_decal_layer(mat: ShaderMaterial) -> void:
	if mat == null:
		return
	var img := get_decal_layer_image(mat)
	if img != null:
		img.fill(Color(0, 0, 0, 0))
		var tex = mat.get_shader_parameter("stamp_layer_texture") as ImageTexture
		if tex != null:
			tex.update(img)
		mask_state_version += 1
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
		mask_state_version += 1

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
	mask_state_version += 1

# ==============================================================================
# Planar Mask Coordinates (CUSTOM0)
# ==============================================================================

## Calculates face-local planar normalized bounding box coordinates for a face.
## Returns Dictionary with:
## - "u": Vector3 tangent horizontal axis
## - "v": Vector3 tangent vertical axis
## - "normal": Vector3 face normal
## - "min_u", "max_u", "range_u": float
## - "min_v", "max_v", "range_v": float
##
## SPLAT RESIZE POLICY: by default a face's splat_bounds PERSIST from the first
## paint (see PBFace.splat_bounds), so splat masks do not stretch when geometry
## is resized later. Callers that must track the CURRENT geometry (stamp
## anchors, decal clipping bounds) pass force_geometry = true, which also skips
## writing face.splat_bounds so it never poisons the persistent mask record.
static func get_face_planar_bounds(mesh_data: PBMeshData, face: PBFace, force_geometry: bool = false) -> Dictionary:
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

	if face.splat_bounds.size() == 4 and not force_geometry:
		min_u = face.splat_bounds[0]
		max_u = face.splat_bounds[1]
		min_v = face.splat_bounds[2]
		max_v = face.splat_bounds[3]

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

## Ensures that `mesh_data.splat_uvs` (the CUSTOM0 splat-mask coordinate
## attribute) is populated with clean face-local planar normalized [0, 1]
## coordinates for all faces. This is DERIVED data: it is regenerated on every
## mesh build from each face's persisted planar bounds, and UV2 (`textures1`)
## is never touched — the author's lightmap unwrap must survive paint.
static func ensure_mesh_splat_uv(mesh_data: PBMeshData) -> void:
	if mesh_data == null:
		return
	var vc := mesh_data.positions.size()
	if mesh_data.splat_uvs.size() != vc:
		mesh_data.splat_uvs.resize(vc)

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
				mesh_data.splat_uvs[idx] = Vector2(u_norm, v_norm)

# ==============================================================================
# Brush Painting Engine
# ==============================================================================

## Paints on a face's splat layer with an adjustable brush radius and softness.
## Highly optimized: the pixel walk runs on the raw R8 byte buffer (no per-pixel
## Color boxing), only the affected 2D bounding box is touched, and the mask is
## uploaded in-place via ImageTexture.update().
##
## STROKE SEMANTICS (single-layer replace mode):
## - Paint is an OVERWRITE ("replace"): within a stroke the pixel value is the
##   stroke's max target (max of weight*opacity over touches); a NEW stroke with
##   lower opacity therefore REPLACES a previously painted stronger area instead
##   of being absorbed by it. Correct mental model for painting one layer.
## - Erase applies its ONCE per pixel per stroke (subtractive): opacity is the
##   real erase strength — slow motion in one stroke can no longer drain a pixel
##   to zero regardless of opacity.
##
## Per-pixel once-per-stroke bookkeeping lives in `stroke_ctx`: pass the SAME
## Dictionary for every dab of one stroke (the controller makes a fresh one in
## begin_stroke) and a fresh/empty one for an independent stroke. Keyed by mask
## image instance id, auto-rebuilt if the mask resolution changed.
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
		opacity: float, erase: bool = false, stroke_ctx: Dictionary = {}) -> bool:
	if mesh_data == null or face == null or splat_mat == null or radius <= 0.0:
		return false

	var target_res := calculate_uniform_face_resolution(mesh_data, face)
	var mask_img := get_layer_mask_image(splat_mat, layer_idx, target_res)
	if mask_img == null:
		return false
	if face.splat_bounds.size() != 4:
		var geom_bounds := get_face_planar_bounds(mesh_data, face, true)
		if not geom_bounds.is_empty():
			face.splat_bounds = PackedFloat32Array([
				geom_bounds["min_u"], geom_bounds["max_u"],
				geom_bounds["min_v"], geom_bounds["max_v"]
			])
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
	var inv_r_sq := 1.0 / (radius * radius)
	var step_u := range_u / float(w - 1)
	var step_v := range_v / float(h - 1)

	if mask_img.get_format() != Image.FORMAT_R8:
		mask_img.convert(Image.FORMAT_R8)
	var bytes := mask_img.get_data()

	var stroke: Dictionary = stroke_ctx.get(mask_img.get_instance_id(), {})
	if stroke.is_empty() or stroke.get("w", 0) != w or stroke.get("h", 0) != h:
		var base := bytes.duplicate()
		var wmax := PackedByteArray()
		wmax.resize(w * h)
		stroke = {"w": w, "h": h, "base": base, "wmax": wmax}
		stroke_ctx[mask_img.get_instance_id()] = stroke
	var base: PackedByteArray = stroke["base"]
	var wmax: PackedByteArray = stroke["wmax"]

	var opacity_b := int(round(opacity * 255.0))

	if soft <= 0.001:
		# Fast path for hard brush: uniform weight across the entire circle footprint
		for y in range(y0, y1 + 1):
			var dy_m: float = (min_v + float(y) * step_v) - v_hit
			var dy_sq := dy_m * dy_m + d_perp * d_perp
			var max_dx_sq := radius * radius - dy_sq
			if max_dx_sq < 0.0:
				continue
			var max_dx := sqrt(max_dx_sq)
			var rx0 := clampi(int(floor((u_hit - max_dx - min_u) / range_u * (w - 1))), x0, x1)
			var rx1 := clampi(int(ceil((u_hit + max_dx - min_u) / range_u * (w - 1))), x0, x1)
			var row := y * w

			for x in range(rx0, rx1 + 1):
				var i := row + x
				if erase:
					var sub := opacity_b
					if sub <= 0 or sub <= int(wmax[i]):
						continue
					wmax[i] = sub
					var p_base := int(base[i])
					var p_new := maxi(0, p_base - sub)
					if int(bytes[i]) != p_new:
						bytes[i] = p_new
						dirty = true
				else:
					var target_b := opacity_b
					if target_b <= int(wmax[i]):
						continue
					wmax[i] = target_b
					var p_base := int(base[i])
					var p_new := p_base
					if p_base <= opacity_b:
						p_new = opacity_b
					else:
						p_new = opacity_b
					if int(bytes[i]) != p_new:
						bytes[i] = p_new
						dirty = true
	else:
		# Soft brush with cosine falloff: acts as an eraser towards brush opacity
		# for higher opacity pixels, and smoothly raises lower opacity pixels.
		# Never leaves an empty halo at the brush fringe.
		var lut_bytes := _get_brush_lut_bytes(soft)
		var lut_sz_minus_1 := float(BRUSH_LUT_SIZE - 1)
		for y in range(y0, y1 + 1):
			var dy_m: float = (min_v + float(y) * step_v) - v_hit
			var dy_sq := dy_m * dy_m + d_perp * d_perp
			var max_dx_sq := radius * radius - dy_sq
			if max_dx_sq < 0.0:
				continue
			var max_dx := sqrt(max_dx_sq)
			var rx0 := clampi(int(floor((u_hit - max_dx - min_u) / range_u * (w - 1))), x0, x1)
			var rx1 := clampi(int(ceil((u_hit + max_dx - min_u) / range_u * (w - 1))), x0, x1)
			var row := y * w

			var dx_m: float = (min_u + float(rx0) * step_u) - u_hit
			for x in range(rx0, rx1 + 1):
				var dist_sq := dx_m * dx_m + dy_sq
				dx_m += step_u
				var li := int(dist_sq * inv_r_sq * lut_sz_minus_1)
				if li >= BRUSH_LUT_SIZE - 1:
					continue
				var wb := int(lut_bytes[li])
				if wb <= 0:
					continue
				var i := row + x
				if erase:
					var sub := (wb * opacity_b + 128) / 255
					if sub <= 0 or sub <= int(wmax[i]):
						continue
					wmax[i] = sub
					var p_base := int(base[i])
					var p_new := maxi(0, p_base - sub)
					if int(bytes[i]) != p_new:
						bytes[i] = p_new
						dirty = true
				else:
					var target_b := (wb * opacity_b + 128) / 255
					if target_b <= int(wmax[i]):
						continue
					wmax[i] = target_b
					var p_base := int(base[i])
					var p_new := p_base
					if p_base <= opacity_b:
						p_new = maxi(p_base, target_b)
					else:
						var erase_excess := (wb * (p_base - opacity_b) + 128) / 255
						p_new = p_base - erase_excess
					if int(bytes[i]) != p_new:
						bytes[i] = p_new
						dirty = true
	if dirty:
		mask_img.set_data(w, h, false, Image.FORMAT_R8, bytes)
		var mask_tex = splat_mat.get_shader_parameter("layer_%d_mask" % layer_idx) as ImageTexture
		if mask_tex != null:
			mask_tex.update(mask_img)
		mask_state_version += 1

	return dirty

# ==============================================================================
# Decal Rasterizer (stamps and brush dabs share it)
# ==============================================================================

## Pastes `image` as a decal centred on `center_local` (node-local space),
## oriented by `normal` + `rotation_deg`, `scale` METRES WIDE (the height
## follows the image's own aspect ratio — a 4:1 banner lands as a 4:1 banner,
## never squished into a square). Every face of `mesh_data` the oriented
## footprint touches receives its own part of the paste, so a stamp can wrap
## over a face edge or a corner; faces are given their own splat material first
## (see ensure_face_owned_material). `opacity` scales the source alpha.
## Returns the number of faces painted.
static func paste_decal(mesh_data: PBMeshData, center_local: Vector3, normal: Vector3,
		rotation_deg: float, scale: float, opacity: float, image: Image) -> int:
	if mesh_data == null or image == null or scale <= 0.0:
		return 0
	var src := _decal_source(image)
	if src.is_empty():
		return 0
	var basis := _decal_basis(normal, rotation_deg)
	var ext := _decal_extents(src, scale)
	# The footprint's circumscribed radius: the prefilter and the pixel window
	# only need an outer bound, the sampling below uses the real extents.
	var circum: float = 0.5 * sqrt(ext.x * ext.x + ext.y * ext.y)
	var targets := _decal_targets(mesh_data, center_local, basis["right"], basis["up"],
			basis["normal"], circum, DECAL_MIN_FACE_ALIGNMENT)
	if targets.is_empty():
		return 0
	var opacity_b := int(round(clampf(opacity, 0.0, 1.0) * 255.0))
	var painted := 0
	for t in targets:
		if _paste_decal_into(t, src, center_local, basis["right"], basis["up"], ext, opacity_b):
			painted += 1
	return painted

## One brush dab into the decal layer: the same oriented footprint as a paste,
## sized by `radius` and faded by the brush falloff LUT. `erase` fades the
## layer's alpha out instead of compositing new pixels in, which is how parts
## of a stamp get removed again. Returns the number of faces touched.
static func paint_decal_dab(mesh_data: PBMeshData, center_local: Vector3, normal: Vector3,
		rotation_deg: float, radius: float, softness: float, opacity: float,
		erase: bool, image: Image) -> int:
	if mesh_data == null or image == null or radius <= 0.0:
		return 0
	var src := _decal_source(image)
	if src.is_empty():
		return 0
	var basis := _decal_basis(normal, rotation_deg)
	var ext := _decal_extents(src, radius * 2.0)
	var circum: float = 0.5 * sqrt(ext.x * ext.x + ext.y * ext.y)
	var targets := _decal_targets(mesh_data, center_local, basis["right"], basis["up"],
			basis["normal"], circum, DECAL_MIN_DAB_ALIGNMENT)
	if targets.is_empty():
		return 0
	var opacity_b := int(round(clampf(opacity, 0.0, 1.0) * 255.0))
	var lut := _get_brush_lut_bytes(clampf(softness, 0.0, 1.0))
	var touched := 0
	for t in targets:
		if _brush_decal_into(t, src, center_local, basis["right"], basis["up"],
				ext, radius, lut, opacity_b, erase):
			touched += 1
	return touched

## Footprint extents (metres) for a source image painted `width_m` wide: the
## height follows the image's aspect ratio, so nothing is ever squished. Pad
## images keep their transparent area — the stamp is exactly the PNG.
static func _decal_extents(src: Dictionary, width_m: float) -> Vector2:
	var w: float = maxf(float(src.get("w", 1)), 1.0)
	var h: float = maxf(float(src.get("h", 1)), 1.0)
	return Vector2(width_m, width_m * (h / w))

## In-plane orthonormal basis for a decal write: the canonical stamp basis
## (`get_stamp_basis`) rotated by `rotation_deg` around the surface normal.
static func _decal_basis(normal: Vector3, rotation_deg: float) -> Dictionary:
	var sbasis := get_stamp_basis(normal)
	var rad := deg_to_rad(rotation_deg)
	var right: Vector3 = sbasis["right"]
	var up: Vector3 = sbasis["up"]
	return {
		"normal": sbasis["normal"],
		"right": cos(rad) * right + sin(rad) * up,
		"up": -sin(rad) * right + cos(rad) * up,
	}

## Faces of `mesh_data` whose planar rect the oriented footprint can touch,
## with everything the pixel loops need (mask image, rect, axis, hit point).
## `min_alignment` rejects faces turned away from the decal's normal — a stamp
## on a wall must not bleed onto the wall's far side, while a perpendicular
## neighbour (a floor meeting that wall) still counts.
static func _decal_targets(mesh_data: PBMeshData, center_local: Vector3, rot_right: Vector3,
		rot_up: Vector3, normal: Vector3, half_extent: float, min_alignment: float) -> Array:
	var out: Array = []
	if mesh_data == null or half_extent <= 0.0:
		return out

	var ex := rot_right * half_extent
	var ey := rot_up * half_extent
	var stamp_box := AABB(center_local - ex - ey, Vector3.ZERO)
	stamp_box = stamp_box.expand(center_local + ex - ey)
	stamp_box = stamp_box.expand(center_local + ex + ey)
	stamp_box = stamp_box.expand(center_local - ex + ey)
	# Faces are flat: a zero-thickness box touching the stamp box edge-on must
	# still count (a stamp exactly on a wall's plane is the common case), and
	# AABB.intersects() treats touching edges as a miss.
	stamp_box = stamp_box.grow(0.0005)

	for face in mesh_data.faces:
		if face == null:
			continue
		var distinct := face.get_distinct_indexes()
		if distinct.is_empty():
			continue
		var face_normal := PBMath.normal_from_positions(mesh_data.positions, face.get_indexes())
		if face_normal.length_squared() < 0.0001:
			continue
		face_normal = face_normal.normalized()
		if face_normal.dot(normal) < min_alignment:
			continue

		var face_box := AABB()
		var first := true
		for idx in distinct:
			if idx < 0 or idx >= mesh_data.positions.size():
				continue
			var p: Vector3 = mesh_data.positions[idx]
			if first:
				face_box = AABB(p, Vector3.ZERO)
				first = false
			else:
				face_box = face_box.expand(p)
		if first or not face_box.grow(0.0005).intersects(stamp_box):
			continue

		var mat := ensure_face_owned_material(mesh_data, face)
		if mat == null:
			continue
		ensure_face_splat_bounds(mesh_data, face)
		var bounds := get_face_planar_bounds(mesh_data, face)
		if bounds.is_empty():
			continue
		var img := get_decal_layer_image(mat, calculate_uniform_face_resolution(mesh_data, face))
		if img == null:
			continue
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		out.append({
			"face": face,
			"mat": mat,
			"img": img,
			"u_axis": bounds["u"],
			"v_axis": bounds["v"],
			"min_u": bounds["min_u"],
			"min_v": bounds["min_v"],
			"range_u": bounds["range_u"],
			"range_v": bounds["range_v"],
			"hit_u": (bounds["u"] as Vector3).dot(center_local),
			"hit_v": (bounds["v"] as Vector3).dot(center_local),
		})
	return out

## Source image as raw RGBA8 bytes (decompress + convert once per write, never
## per pixel: the pixel loops index the byte array directly).
static func _decal_source(image: Image) -> Dictionary:
	if image == null or image.is_empty():
		return {}
	var img := image
	if img.is_compressed():
		img = img.duplicate()
		img.decompress()
	if img.get_format() != Image.FORMAT_RGBA8:
		img = img.duplicate()
		img.convert(Image.FORMAT_RGBA8)
	if img.is_empty():
		return {}
	return {"bytes": img.get_data(), "w": img.get_width(), "h": img.get_height()}

## Pixel window of a decal footprint inside one target's mask image.
static func _decal_pixel_window(t: Dictionary, hit_u: float, hit_v: float, half_extent: float) -> Dictionary:
	var w: int = t["img"].get_width()
	var h: int = t["img"].get_height()
	var u0: float = (hit_u - half_extent - t["min_u"]) / t["range_u"]
	var u1: float = (hit_u + half_extent - t["min_u"]) / t["range_u"]
	var v0: float = (hit_v - half_extent - t["min_v"]) / t["range_v"]
	var v1: float = (hit_v + half_extent - t["min_v"]) / t["range_v"]
	return {
		"x0": clampi(int(floor(u0 * (w - 1))), 0, w - 1),
		"x1": clampi(int(ceil(u1 * (w - 1))), 0, w - 1),
		"y0": clampi(int(floor(v0 * (h - 1))), 0, h - 1),
		"y1": clampi(int(ceil(v1 * (h - 1))), 0, h - 1),
		"w": w, "h": h,
	}

## Uploads a target's mask image back to its ImageTexture and bumps the state
## version so downstream caches (UV editor preview, exporters) refresh.
static func _commit_decal_target(t: Dictionary) -> void:
	var mat: ShaderMaterial = t["mat"]
	var tex = mat.get_shader_parameter("stamp_layer_texture") as ImageTexture
	if tex != null:
		tex.update(t["img"])
	mask_state_version += 1

static func _paste_decal_into(t: Dictionary, src: Dictionary, center_local: Vector3,
		rot_right: Vector3, rot_up: Vector3, ext: Vector2, opacity_b: int) -> bool:
	# The decal centre projected into THIS face's plane: once a stamp wraps a
	# corner, every face samples it through its own axes.
	var center_u: float = (t["u_axis"] as Vector3).dot(center_local)
	var center_v: float = (t["v_axis"] as Vector3).dot(center_local)
	var half: float = 0.5 * sqrt(ext.x * ext.x + ext.y * ext.y)
	var win := _decal_pixel_window(t, center_u, center_v, half)
	if win["x0"] > win["x1"] or win["y0"] > win["y1"]:
		return false

	var u_face: Vector3 = t["u_axis"]
	var v_face: Vector3 = t["v_axis"]
	var min_u: float = t["min_u"]
	var min_v: float = t["min_v"]
	var range_u: float = t["range_u"]
	var range_v: float = t["range_v"]
	var w: int = win["w"]
	var h: int = win["h"]
	var step_u := range_u / float(maxi(w - 1, 1))
	var step_v := range_v / float(maxi(h - 1, 1))

	var src_b: PackedByteArray = src["bytes"]
	var sw: int = src["w"]
	var sh: int = src["h"]
	var dst_img: Image = t["img"]
	var dst_b := dst_img.get_data()

	var dirty := false
	for y in range(win["y0"], win["y1"] + 1):
		var v_coord := min_v + float(y) * step_v
		var row := y * w
		for x in range(win["x0"], win["x1"] + 1):
			var u_coord := min_u + float(x) * step_u
			var dp := (u_coord - center_u) * u_face + (v_coord - center_v) * v_face
			var sx := dp.dot(rot_right) / ext.x + 0.5
			if sx < 0.0 or sx > 1.0:
				continue
			var sy := 0.5 - dp.dot(rot_up) / ext.y
			if sy < 0.0 or sy > 1.0:
				continue
			var si := (clampi(int(sy * float(sh - 1)), 0, sh - 1) * sw 					+ clampi(int(sx * float(sw - 1)), 0, sw - 1)) * 4
			var sa := int(src_b[si + 3])
			if sa == 0:
				continue
			var a := (sa * opacity_b + 127) / 255
			if a <= 0:
				continue
			var di := (row + x) * 4
			var da := int(dst_b[di + 3])
			if da == 0:
				# Fast path: nothing underneath — copy the source pixels.
				dst_b[di] = src_b[si]
				dst_b[di + 1] = src_b[si + 1]
				dst_b[di + 2] = src_b[si + 2]
				dst_b[di + 3] = a
			else:
				var inv := 255 - a
				var out_a := a + (da * inv + 127) / 255
				if out_a <= 0:
					continue
				for c in range(3):
					var num := int(src_b[si + c]) * a + (int(dst_b[di + c]) * da * inv + 127) / 255
					dst_b[di + c] = clampi((num + out_a / 2) / out_a, 0, 255)
				dst_b[di + 3] = out_a
			dirty = true

	if not dirty:
		return false
	dst_img.set_data(w, h, false, Image.FORMAT_RGBA8, dst_b)
	_commit_decal_target(t)
	return true

static func _brush_decal_into(t: Dictionary, src: Dictionary, center_local: Vector3,
		rot_right: Vector3, rot_up: Vector3, ext: Vector2, radius: float,
		lut: PackedByteArray, opacity_b: int, erase: bool) -> bool:
	var u_face: Vector3 = t["u_axis"]
	var v_face: Vector3 = t["v_axis"]
	var center_u: float = u_face.dot(center_local)
	var center_v: float = v_face.dot(center_local)
	var win := _decal_pixel_window(t, center_u, center_v, radius)
	if win["x0"] > win["x1"] or win["y0"] > win["y1"]:
		return false

	var min_u: float = t["min_u"]
	var min_v: float = t["min_v"]
	var range_u: float = t["range_u"]
	var range_v: float = t["range_v"]
	var w: int = win["w"]
	var h: int = win["h"]
	var step_u := range_u / float(maxi(w - 1, 1))
	var step_v := range_v / float(maxi(h - 1, 1))

	var src_b: PackedByteArray = src["bytes"]
	var sw: int = src["w"]
	var sh: int = src["h"]
	var dst_img: Image = t["img"]
	var dst_b := dst_img.get_data()
	var inv_r_sq := 1.0 / (radius * radius)
	var lut_max := float(BRUSH_LUT_SIZE - 1)

	var dirty := false
	for y in range(win["y0"], win["y1"] + 1):
		var v_coord := min_v + float(y) * step_v
		var dv := v_coord - center_v
		var row := y * w
		for x in range(win["x0"], win["x1"] + 1):
			var u_coord := min_u + float(x) * step_u
			var du := u_coord - center_u
			var dist_sq := du * du + dv * dv
			var li := int(dist_sq * inv_r_sq * lut_max)
			if li >= BRUSH_LUT_SIZE - 1:
				continue
			var w255 := int(lut[li])
			if w255 <= 0:
				continue
			var weight := (w255 * opacity_b + 127) / 255
			if weight <= 0:
				continue
			var di := (row + x) * 4

			if erase:
				var da := int(dst_b[di + 3])
				if da == 0:
					continue
				var faded := (da * (255 - weight) + 127) / 255
				if faded == da:
					continue
				dst_b[di + 3] = faded
				dirty = true
				continue

			var dp := du * u_face + dv * v_face
			var sx := dp.dot(rot_right) / ext.x + 0.5
			if sx < 0.0 or sx > 1.0:
				continue
			var sy := 0.5 - dp.dot(rot_up) / ext.y
			if sy < 0.0 or sy > 1.0:
				continue
			var si := (clampi(int(sy * float(sh - 1)), 0, sh - 1) * sw 					+ clampi(int(sx * float(sw - 1)), 0, sw - 1)) * 4
			var sa := int(src_b[si + 3])
			if sa == 0:
				continue
			var a := (sa * weight + 127) / 255
			if a <= 0:
				continue

			var da2 := int(dst_b[di + 3])
			if da2 == 0:
				dst_b[di] = src_b[si]
				dst_b[di + 1] = src_b[si + 1]
				dst_b[di + 2] = src_b[si + 2]
				dst_b[di + 3] = a
			else:
				var inv := 255 - a
				var out_a := a + (da2 * inv + 127) / 255
				if out_a <= 0:
					continue
				for c in range(3):
					var num := int(src_b[si + c]) * a + (int(dst_b[di + c]) * da2 * inv + 127) / 255
					dst_b[di + c] = clampi((num + out_a / 2) / out_a, 0, 255)
				dst_b[di + 3] = out_a
			dirty = true

	if not dirty:
		return false
	dst_img.set_data(w, h, false, Image.FORMAT_RGBA8, dst_b)
	_commit_decal_target(t)
	return true

## Records the face's planar rect on first paint: from then on the mask maps to
## that FIXED object-space rect, so resizing the face neither stretches nor
## slides the paint — new geometry simply clips it.
static func ensure_face_splat_bounds(mesh_data: PBMeshData, face: PBFace) -> void:
	if mesh_data == null or face == null or face.splat_bounds.size() == 4:
		return
	var geom := get_face_planar_bounds(mesh_data, face, true)
	if geom.is_empty():
		return
	face.splat_bounds = PackedFloat32Array([
		geom["min_u"], geom["max_u"], geom["min_v"], geom["max_v"]
	])

## Returns the face's splat material, first giving the face a PRIVATE copy of
## it when other faces use the same instance. Masks (and the decal layer) are
## per-material images mapped through each face's own planar rect, so a shared
## material would make one face's paint appear on every other face using it.
static func ensure_face_owned_material(mesh_data: PBMeshData, face: PBFace) -> ShaderMaterial:
	if mesh_data == null or face == null:
		return null
	var current := mesh_data.get_face_material(face)
	if is_splat_material(current) and not _is_material_shared(mesh_data, face, current):
		return current as ShaderMaterial

	var shell := create_splat_material(
			current if current is StandardMaterial3D else null)
	if is_splat_material(current):
		_copy_layer_setup(current as ShaderMaterial, shell)
	mesh_data.set_face_material(face, shell)
	return shell

static func _is_material_shared(mesh_data: PBMeshData, face: PBFace, mat: Material) -> bool:
	for f in mesh_data.faces:
		if f != null and f != face and mesh_data.get_face_material(f) == mat:
			return true
	return false

## Copies a splat material's look and layer setup (textures, colors, roughness
## and any painted masks/decal) onto `target`.
static func _copy_layer_setup(source: ShaderMaterial, target: ShaderMaterial) -> void:
	target.set_shader_parameter("base_texture", source.get_shader_parameter("base_texture"))
	target.set_shader_parameter("base_color", source.get_shader_parameter("base_color"))
	target.set_shader_parameter("roughness", source.get_shader_parameter("roughness"))
	for i in range(1, MAX_LAYERS + 1):
		if source.get_shader_parameter("layer_%d_enabled" % i) != true:
			continue
		target.set_shader_parameter("layer_%d_enabled" % i, true)
		target.set_shader_parameter("layer_%d_texture" % i, source.get_shader_parameter("layer_%d_texture" % i))
		target.set_shader_parameter("layer_%d_color" % i, source.get_shader_parameter("layer_%d_color" % i))
		target.set_shader_parameter("layer_%d_roughness" % i, source.get_shader_parameter("layer_%d_roughness" % i))
		var src_mask := get_layer_mask_image(source, i)
		if src_mask != null:
			var copy := Image.create(src_mask.get_width(), src_mask.get_height(), false, src_mask.get_format())
			copy.copy_from(src_mask)
			target.set_shader_parameter("layer_%d_mask" % i, ImageTexture.create_from_image(copy))
			_set_cached_image(target, "layer_%d" % i, copy)
	if has_decal_layer(source):
		var src_decal := get_decal_layer_image(source)
		if src_decal != null:
			var decal_copy := Image.create(src_decal.get_width(), src_decal.get_height(), false, Image.FORMAT_RGBA8)
			decal_copy.copy_from(src_decal)
			target.set_shader_parameter("stamp_layer_enabled", true)
			target.set_shader_parameter("stamp_layer_texture", ImageTexture.create_from_image(decal_copy))
			_set_cached_image(target, "stamp", decal_copy)
	mask_state_version += 1
# ==============================================================================
# Legacy decal nodes (migration into the decal layer)
# ==============================================================================

## Legacy `PBStamps` decal quads carried their placement as node metadata. The
## decal layer keeps the same information as painted pixels, so an old scene is
## migrated by re-pasting every record into the layer and dropping the nodes.
## Returns the number of decals re-pasted.
static func migrate_legacy_stamps(mesh: Node) -> int:
	if mesh == null or not (mesh is MeshInstance3D):
		return 0
	var data: PBMeshData = mesh.get("pb_mesh_data")
	if data == null:
		return 0
	var container := mesh.get_node_or_null(LEGACY_STAMP_CONTAINER)
	if container == null:
		return 0
	var migrated := 0
	for child in container.get_children():
		var mi := child as MeshInstance3D
		if mi == null or not mi.has_meta("anchor_center"):
			continue
		var tex_path := String(mi.get_meta("stamp_texture_path", ""))
		if tex_path.is_empty():
			continue
		var img: Image = null
		if ResourceLoader.exists(tex_path):
			var tex := load(tex_path) as Texture2D
			if tex != null:
				img = tex.get_image()
		elif FileAccess.file_exists(tex_path):
			# Legacy scenes may carry a globalized path (the old tool wrote
			# ProjectSettings.globalize_path for files outside res://).
			img = Image.load_from_file(tex_path)
		if img == null:
			continue
		var xf := mi.transform
		var normal: Vector3 = xf.basis.z.normalized()
		if normal.length_squared() < 0.0001:
			normal = Vector3.UP
		# The legacy node's basis is the FULL stamp extent (right, up, normal),
		# so the paste scale is the edge length and the rotation is baked into
		# the basis — paste with zero rotation after re-deriving the axes.
		var scale_x: float = xf.basis.x.length()
		var scale_y: float = xf.basis.y.length()
		var basis := get_stamp_basis(normal)
		var rot_right: Vector3 = basis["right"]
		var rot_up: Vector3 = basis["up"]
		var stamp_scale: float = maxf(scale_x, scale_y)
		var rotation := 0.0
		if scale_x > 0.0001:
			var x_dir := xf.basis.x / scale_x
			rotation = rad_to_deg(atan2(x_dir.dot(rot_up), x_dir.dot(rot_right)))
		if paste_decal(data, xf.origin, normal, rotation, stamp_scale,
				float(mi.get_meta("stamp_opacity", 1.0)), img) > 0:
			migrated += 1

	container.queue_free()
	if migrated > 0:
		# Rebuild the GPU masks from the CPU cache: headless saves sample
		# ImageTexture.get_image(), which is stale right after update().
		for mat in data.materials:
			if is_splat_material(mat):
				sync_mask_textures(mat as ShaderMaterial)
	return migrated

## Export-facing accessor: the full paint state of one face as plain data:
## base material params, every enabled splat layer (texture + mask Image) and
## the decal layer's composited pixels — exactly the seam a bake/exporter
## consumes. Returns {} when the face has no splat material.
static func collect_face_paint_state(mesh_data: PBMeshData, face: PBFace) -> Dictionary:
	if mesh_data == null or face == null:
		return {}
	var mat := mesh_data.get_face_material(face)
	if not is_splat_material(mat):
		return {}
	var sm := mat as ShaderMaterial
	var out: Dictionary = {
		"base_texture_path": "",
		"base_color": sm.get_shader_parameter("base_color"),
		"roughness": sm.get_shader_parameter("roughness"),
		"layers": [],
		"decal_layer_image": null,
		"planar_bounds": get_face_planar_bounds(mesh_data, face),
	}
	var base_tex := sm.get_shader_parameter("base_texture") as Texture2D
	if base_tex != null:
		out["base_texture_path"] = base_tex.resource_path
	for i in range(1, MAX_LAYERS + 1):
		if sm.get_shader_parameter("layer_%d_enabled" % i) == true:
			var layer_tex := sm.get_shader_parameter("layer_%d_texture" % i) as Texture2D
			out["layers"].append({
				"slot": i,
				"texture": layer_tex,
				"texture_path": layer_tex.resource_path if layer_tex != null else "",
				"color": sm.get_shader_parameter("layer_%d_color" % i),
				"roughness": sm.get_shader_parameter("layer_%d_roughness" % i),
				"mask_image": get_layer_mask_image(sm, i),
			})
	if has_decal_layer(sm):
		out["decal_layer_image"] = get_decal_layer_image(sm)
	return out

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
				_set_cached_image(clone, "layer_%d" % i, cloned_img)
	# Clone the decal layer if it exists
	if source.get_shader_parameter("stamp_layer_enabled") == true:
		clone.set_shader_parameter("stamp_layer_enabled", true)
		var src_stamp_img := get_decal_layer_image(source)
		if src_stamp_img != null:
			var cloned_stamp_img := Image.create(src_stamp_img.get_width(), src_stamp_img.get_height(), false, src_stamp_img.get_format())
			cloned_stamp_img.copy_from(src_stamp_img)
			var cloned_stamp_tex := ImageTexture.create_from_image(cloned_stamp_img)
			clone.set_shader_parameter("stamp_layer_texture", cloned_stamp_tex)
			_set_cached_image(clone, "stamp", cloned_stamp_img)
	return clone

# ==============================================================================
# UV Editor Splat Preview (splat-mask channel underlay)
# ==============================================================================

## Builds a CPU composite of `mat`'s splat stack over the mask unit square:
## base texture/color with every enabled layer blended through its painted
## mask (mirroring pb_splat_shader's smoothstep), then the stamp layer on top.
## The UV editor uses this as the underlay for the splat-mask channel —
## masks are authored in face-planar [0, 1] coordinates, which is exactly the
## unit square the canvas draws. Returns null for non-splat materials.
static func build_preview_texture(mat: Material, size: int = 256) -> ImageTexture:
	if mat == null or not is_splat_material(mat):
		return null
	var smat := mat as ShaderMaterial

	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)

	var base_col_v = smat.get_shader_parameter("base_color")
	var base_col: Color = base_col_v if base_col_v is Color else Color.WHITE
	var base_img := _preview_source_image(smat.get_shader_parameter("base_texture"))

	var layers: Array = []
	for i in range(1, MAX_LAYERS + 1):
		if smat.get_shader_parameter("layer_%d_enabled" % i) != true:
			continue
		var l_img := _preview_source_image(smat.get_shader_parameter("layer_%d_texture" % i))
		if l_img == null or smat.get_shader_parameter("layer_%d_mask" % i) == null:
			continue
		# Masks are sampled from the CPU image cache, never via
		# ImageTexture.get_image() — the GPU round-trip returns stale data
		# after update() (and is always the slower path for painted masks).
		var mask_img := get_layer_mask_image(smat, i)
		if mask_img == null:
			continue
		var l_col_v = smat.get_shader_parameter("layer_%d_color" % i)
		var l_rough_v = smat.get_shader_parameter("layer_%d_roughness" % i)
		layers.append({
			"img": l_img,
			"mask": mask_img,
			"color": l_col_v if l_col_v is Color else Color.WHITE,
			"roughness": clampf(float(l_rough_v) if l_rough_v != null else 0.8, 0.0, 1.0),
		})

	var stamp_img: Image = null
	if smat.get_shader_parameter("stamp_layer_enabled") == true \
			and smat.get_shader_parameter("stamp_layer_texture") != null:
		stamp_img = get_decal_layer_image(smat)

	for y in range(size):
		var v := (float(y) + 0.5) / float(size)
		for x in range(size):
			var u := (float(x) + 0.5) / float(size)
			var col := _sample_image_repeat(base_img, u, v) * base_col
			for L in layers:
				var m := _sample_image_clamp(L["mask"], u, v).r
				var fw: float = 1.5 / float(L["mask"].get_width())
				var edge_w: float = lerpf(maxf(fw * 2.0, 0.02), 0.48, L["roughness"])
				var blend := smoothstep(0.5 - edge_w, 0.5 + edge_w, m)
				if blend <= 0.0:
					continue
				var l_col: Color = _sample_image_repeat(L["img"], u, v) * L["color"]
				var a: float = blend * l_col.a
				col = Color(col.r + (l_col.r - col.r) * a, col.g + (l_col.g - col.g) * a, col.b + (l_col.b - col.b) * a, col.a)
			if stamp_img != null:
				var s_col := _sample_image_clamp(stamp_img, u, v)
				if s_col.a > 0.001:
					col = Color(col.r + (s_col.r - col.r) * s_col.a, col.g + (s_col.g - col.g) * s_col.a, col.b + (s_col.b - col.b) * s_col.a, col.a)
			img.set_pixel(x, y, col)

	return ImageTexture.create_from_image(img)

## Decompresses/normalizes a texture into an RGBA8 Image for CPU sampling.
static func _preview_source_image(tex: Texture2D) -> Image:
	if tex == null:
		return null
	var img := tex.get_image()
	if img == null:
		return null
	if img.is_compressed():
		img.decompress()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	return img

static func _sample_image_repeat(img: Image, u: float, v: float) -> Color:
	if img == null or img.is_empty():
		return Color.WHITE
	var x := posmod(int(floor(u * img.get_width())), img.get_width())
	var y := posmod(int(floor(v * img.get_height())), img.get_height())
	return img.get_pixel(x, y)

static func _sample_image_clamp(img: Image, u: float, v: float) -> Color:
	if img == null or img.is_empty():
		return Color(0, 0, 0, 1)
	var x := clampi(int(floor(u * img.get_width())), 0, img.get_width() - 1)
	var y := clampi(int(floor(v * img.get_height())), 0, img.get_height() - 1)
	return img.get_pixel(x, y)

## Recreates the GPU mask/stamp textures from the CPU image cache.
## ImageTexture.update() does not survive a HEADLESS ResourceSaver round trip
## (get_image() returns the stale pre-update image there), so call this before
## saving a scene with live splat materials from headless code (builders,
## bake/import scripts). Interactive painting is unaffected — update() stays
## the zero-lag per-dab path in the editor.
static func sync_mask_textures(mat: ShaderMaterial) -> void:
	if mat == null:
		return
	for i in range(1, MAX_LAYERS + 1):
		if mat.get_shader_parameter("layer_%d_enabled" % i) != true:
			continue
		var img := _get_cached_image(mat, "layer_%d" % i)
		if img != null:
			mat.set_shader_parameter("layer_%d_mask" % i, ImageTexture.create_from_image(img))
	if has_decal_layer(mat):
		var stamp_img := _get_cached_image(mat, "stamp")
		if stamp_img != null:
			mat.set_shader_parameter("stamp_layer_texture", ImageTexture.create_from_image(stamp_img))
