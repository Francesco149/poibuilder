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

## Child node name the previous stamp design used for its decal quads.
const LEGACY_STAMP_CONTAINER := "PBStamps"
## Alignment cutoffs for decal writes, as a dot product against the decal's own
## normal. A face the decal's plane is not roughly parallel to gets a DEGENERATE
## projection of the content (a floor stamp smeared into horizontal lines down a
## perpendicular wall — the "completely broken stamp on the wall"), so the cut
## is deliberately generous but nowhere near perpendicular:
##   * stamps/decal pastes: 0.35 (~70°) — a decal may wrap a shallow crease,
##   * brush dabs: 0.25 (~75°) — a dab is round in the FACE's own plane, so
##     only the sampled content degenerates, and erase must work anywhere.
const DECAL_MIN_FACE_ALIGNMENT := 0.35
const DECAL_MIN_DAB_ALIGNMENT := 0.25
const TEXELS_PER_METER := 256
const MIN_RESOLUTION := 256
const MAX_RESOLUTION := 2048
## Decal layer density. The decal image is a WINDOW cropped to the painted area
## (not the whole face rect), so it can hold this density — the same 256
## texels/m the splat masks use — on a face of any size: a 2 m stamp is 512 px
## wide whether it lands on a 2 m panel or a 60 m floor. The window grows in
## DECAL_WINDOW_ALIGN_PX steps as paint spreads; past DECAL_MAX_WINDOW_PX or
## DECAL_MAX_WINDOW_TEXELS the density drops instead, so one face can never blow
## up memory. `decal_density()` reports what a face ended up with.
const DECAL_TEXELS_PER_M := 256.0
const DECAL_MIN_WINDOW_PX := 64
## Per-axis ceiling for the window image. Past the texel budget below the
## DENSITY drops instead of the covered area (dropping area would silently move
## or lose paint).
const DECAL_MAX_WINDOW_PX := 4096
## Total texel budget (RGBA8: 8 M texels = 32 MB) the window's density is
## chosen to respect. Together with DECAL_MAX_WINDOW_PX it decides how far a
## face keeps DECAL_TEXELS_PER_M: the old 2048-per-axis cap put a 60 m floor's
## painted bbox (25 m of span) at 70 texels/m — about half the base texture's
## density — so every decal on that face read as blocky next to the surface
## around it. 32 MB is the same order the splat masks already spend on a face
## (8 layers x 2048 x 2048 x 1 B) and doubles the reach of the sharp band.
const DECAL_MAX_WINDOW_TEXELS := 8388608
## Window sizes are rounded up to a multiple of this many pixels: tidy
## allocations with a bounded waste (powers of two doubled the budget's texels
## whenever the span sat just past one).
const DECAL_WINDOW_ALIGN_PX := 64
## Slack (window pixels) kept around the written footprint so a stroke that
## drifts a little does not reallocate the window on every dab.
const DECAL_WINDOW_PAD_PX := 8
## Above this many pixels on an axis a brush dab falls back to the per-pixel
## loop instead of building a sprite: the sprite path trades memory for speed,
## and a 10 m radius brush sprite would be hundreds of megabytes.
const DECAL_MAX_SPRITE_PX := 1024
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

## Decal source images resampled to a footprint size, keyed "source_key_WxH".
## A stroke writes the same footprint size on every dab, so the resample (the
## only per-stamp cost that scales with the source) happens once.
static var _decal_resample_cache: Dictionary = {}

## Decal sources already decompressed/level-stripped, keyed by image instance
## id (the palette and stamp images are static, so a stroke hits this every
## dab instead of copying the pixels again).
static var _decal_source_cache: Dictionary = {}

## Brush dab sprites: the falloff disc of a flat-colour brush, rendered once per
## (colour, radius, softness, opacity, density) and then composited with one
## Image.blend_rect() C++ call per dab. The same per-pixel work in GDScript
## costs ~36 ms for a 0.35 m dab (~100 ms at the default 0.5 m radius) — the
## difference between a responsive brush and a stuttering one.
static var _dab_sprite_cache: Dictionary = {}

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

## Why a face must NOT be painted, or "" when it is paintable.
##
## Converting a face to a splat material keeps its albedo texture, colour and
## roughness — and drops everything else. The one that bites is TRANSPARENCY: a
## billboard sprite's quad is alpha-scissor art, and the splat shader has no
## scissor, so painting a sprite turned its silhouette into an opaque rectangle
## (the sprite "lost its alpha", with only undo to get it back). Transparent
## surfaces are refused rather than converted: the paint tools are for opaque
## geometry. Billboard detection comes first so the message names the real
## cause (a sprite material is transparent AND billboard).
static func paint_block_reason(mat: Material) -> String:
	if mat == null or is_splat_material(mat):
		return ""
	if mat is StandardMaterial3D:
		var sm := mat as StandardMaterial3D
		if sm.billboard_mode != BaseMaterial3D.BILLBOARD_DISABLED:
			return "billboard sprite"
		if sm.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			return "transparent material"
	return ""

## `paint_block_reason` for one face of a mesh: the material half plus the
## mesh-level half — a sprite PBMesh is a billboard whatever material it
## currently wears (the sprite shape's alpha would be lost either way).
static func face_paint_block_reason(mesh: PBMesh, face_idx: int) -> String:
	if mesh == null or mesh.pb_mesh_data == null:
		return ""
	var data := mesh.pb_mesh_data
	if data.shape_id == &"sprite" \
			or (data.shape_params.has("billboard") and float(data.shape_params["billboard"]) > 0.5):
		return "billboard sprite"
	if face_idx < 0 or face_idx >= data.faces.size():
		return ""
	return paint_block_reason(data.get_face_material(data.faces[face_idx]))

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

## The decal layer is one RGBA image per material — the pixels ARE the content,
## so a pasted PNG keeps its own colors and alpha instead of being tinted
## through a layer texture. Everything that lands here is painted through the
## same rasterizer: a stamp is one oriented paste, the brush is a run of dabs,
## and both may span several faces (a stamp can cross an edge and continue on
## the neighbouring face).
##
## The image is a WINDOW inside each face's planar [0,1] mask space, cropped to
## the painted area and held at DECAL_TEXELS_PER_M (see ensure_decal_window), so
## its density does not fall off with face size the way a whole-face image
## would. Face-mask uv -> window uv goes through get_decal_window /
## decal_uv_from_mask_uv — the shader does the same remap with the
## stamp_layer_uv_offset/scale uniforms, and EVERY other consumer of the image
## (tile baker, face-composite baker, UV editor preview, modern sidecars) must
## map through it too.
##
## Shader uniform names stay `stamp_layer_*` from the previous design so scenes
## saved before the rename keep their painted content.

## Returns true if the decal layer exists on `mat`.
static func has_decal_layer(mat: ShaderMaterial) -> bool:
	if mat == null:
		return false
	return mat.get_shader_parameter("stamp_layer_enabled") == true

## The decal image's rect in the face's own [0, 1] mask space (the same space
## as `splat_uv` / CUSTOM0). The image covers this window, not the whole face,
## which is what keeps the texel density uniform on large faces.
static func get_decal_window(mat: ShaderMaterial) -> Rect2:
	if mat == null:
		return Rect2(0.0, 0.0, 1.0, 1.0)
	var off = mat.get_shader_parameter("stamp_layer_uv_offset")
	var sc = mat.get_shader_parameter("stamp_layer_uv_scale")
	var offset: Vector2 = off if off is Vector2 else Vector2.ZERO
	var scale: Vector2 = sc if sc is Vector2 else Vector2.ONE
	if scale.x <= 0.000001 or scale.y <= 0.000001:
		return Rect2(0.0, 0.0, 1.0, 1.0)
	return Rect2(offset, Vector2(1.0 / scale.x, 1.0 / scale.y))

## Face-mask uv -> decal-image uv for `mat` (outside [0, 1] = outside the
## window; the shader discards those fragments the same way).
static func decal_uv_from_mask_uv(mat: ShaderMaterial, mask_uv: Vector2) -> Vector2:
	var win := get_decal_window(mat)
	return Vector2((mask_uv.x - win.position.x) / win.size.x,
			(mask_uv.y - win.position.y) / win.size.y)

## Returns the decal layer's pixel image (the window), or null when `mat` has
## no decal layer. `target_res` keeps the historical behaviour for layers
## created before windows existed (a whole-face image grown to density).
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

	if img == null:
		return null
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	if target_res != Vector2i.ZERO and (target_res.x > img.get_width() or target_res.y > img.get_height()):
		# Legacy whole-face layer: grow it to the face's density. Windowed
		# layers are sized by ensure_decal_window instead.
		var new_w := maxi(img.get_width(), target_res.x)
		var new_h := maxi(img.get_height(), target_res.y)
		img.resize(new_w, new_h, Image.INTERPOLATE_BILINEAR)
		var tex = mat.get_shader_parameter("stamp_layer_texture") as ImageTexture
		if tex != null:
			tex.set_image(img)
		mask_state_version += 1
	return img

## Grows/creates the decal window so it covers `need_uv` (face-mask uv space),
## at DECAL_TEXELS_PER_M in world units (`face_size_m` = the face rect's size in
## metres, the scale between uv and metres). Returns the image, ready to write
## through get_decal_window()'s mapping. Existing pixels are preserved: the
## window only ever grows, so paint already on the face never moves.
static func ensure_decal_window(mat: ShaderMaterial, need_uv: Rect2,
		face_size_m: Vector2, texels_per_m: float = DECAL_TEXELS_PER_M) -> Image:
	if mat == null:
		return null
	var existing := get_decal_layer_image(mat)
	if existing == null:
		return _realloc_decal_window(mat, null, Rect2(), need_uv, face_size_m, texels_per_m)
	if mat.get_shader_parameter("stamp_layer_uv_scale") == null:
		# A layer created by an older build covers the whole face rect.
		return existing
	var win := get_decal_window(mat)
	if win.encloses(need_uv):
		return existing
	return _realloc_decal_window(mat, existing, win, win.merge(need_uv), face_size_m, texels_per_m)

## The decal layer's real texel density on `mat`, in texels per metre, from the
## window image and the face's planar rect (`face_range_m` = that rect's size in
## metres). 0 when the material has no decal layer. This is what an author needs
## to know when a decal looks blocky: the density is DECAL_TEXELS_PER_M until
## the window hits DECAL_MAX_WINDOW_PX / DECAL_MAX_WINDOW_TEXELS, and past that
## it falls as the painted span on the face grows.
static func decal_density(mat: ShaderMaterial, face_range_m: Vector2) -> float:
	var img := get_decal_layer_image(mat)
	if img == null:
		return 0.0
	var win := get_decal_window(mat)
	var span_x := maxf(win.size.x * maxf(face_range_m.x, 0.000001), 0.000001)
	var span_y := maxf(win.size.y * maxf(face_range_m.y, 0.000001), 0.000001)
	return minf(float(img.get_width()) / span_x, float(img.get_height()) / span_y)

## Allocates a new decal window image covering `want_uv` (padded + rounded up to
## DECAL_WINDOW_ALIGN_PX) and copies `old_img` (which covered `old_uv`) into
## it. Density follows the requested texels/m until the window would exceed
## DECAL_MAX_WINDOW_PX, then the covered span wins and the density drops — the
## only way a face can hold a very large painted span without unbounded memory.
static func _realloc_decal_window(mat: ShaderMaterial, old_img: Image, old_uv: Rect2,
		want_uv: Rect2, face_size_m: Vector2, texels_per_m: float) -> Image:
	var face_m := Vector2(maxf(face_size_m.x, 0.001), maxf(face_size_m.y, 0.001))
	var margin := Vector2(float(DECAL_WINDOW_PAD_PX) / (face_m.x * maxf(texels_per_m, 1.0)),
			float(DECAL_WINDOW_PAD_PX) / (face_m.y * maxf(texels_per_m, 1.0)))
	var rect := want_uv.grow_individual(margin.x, margin.y, margin.x, margin.y)

	# Density: as requested, until the window would exceed DECAL_MAX_WINDOW_PX
	# per axis OR DECAL_MAX_WINDOW_TEXELS in total. Past that the DENSITY drops,
	# never the covered area — a window always covers everything painted
	# through it (dropping the area would silently move or lose paint).
	var span_m := Vector2(maxf(rect.size.x * face_m.x, 0.000001), maxf(rect.size.y * face_m.y, 0.000001))
	var span_cap := float(DECAL_MAX_WINDOW_PX)
	var area_cap := sqrt(float(DECAL_MAX_WINDOW_TEXELS) / (span_m.x * span_m.y))
	var dens := maxf(minf(minf(texels_per_m, span_cap / span_m.x), minf(span_cap / span_m.y, area_cap)), 1.0)
	var px_per_uv := face_m * dens
	var size_px := Vector2i(
		clampi(_align_window_px(int(ceil(rect.size.x * px_per_uv.x))), DECAL_MIN_WINDOW_PX, DECAL_MAX_WINDOW_PX),
		clampi(_align_window_px(int(ceil(rect.size.y * px_per_uv.y))), DECAL_MIN_WINDOW_PX, DECAL_MAX_WINDOW_PX))
	# Keep the requested rect centred inside the (possibly larger) image.
	var span_uv := Vector2(float(size_px.x) / px_per_uv.x, float(size_px.y) / px_per_uv.y)
	if span_uv.x < rect.size.x or span_uv.y < rect.size.y:
		# The alignment/rounding can overshoot the cap; grow the span instead.
		span_uv = Vector2(maxf(span_uv.x, rect.size.x), maxf(span_uv.y, rect.size.y))
		size_px = Vector2i(
			clampi(_align_window_px(int(ceil(span_uv.x * px_per_uv.x))), DECAL_MIN_WINDOW_PX, DECAL_MAX_WINDOW_PX),
			clampi(_align_window_px(int(ceil(span_uv.y * px_per_uv.y))), DECAL_MIN_WINDOW_PX, DECAL_MAX_WINDOW_PX))
		span_uv = Vector2(float(size_px.x) / px_per_uv.x, float(size_px.y) / px_per_uv.y)
	rect.position -= (span_uv - rect.size) * 0.5

	var img := Image.create(size_px.x, size_px.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	if old_img != null and not old_img.is_empty() and old_uv.size.x > 0.000001 and old_uv.size.y > 0.000001:
		var want_w := maxi(1, int(round(old_uv.size.x / span_uv.x * float(size_px.x))))
		var want_h := maxi(1, int(round(old_uv.size.y / span_uv.y * float(size_px.y))))
		var scaled := old_img
		if want_w != old_img.get_width() or want_h != old_img.get_height():
			scaled = old_img.duplicate()
			scaled.resize(want_w, want_h, Image.INTERPOLATE_TRILINEAR)
		var dst := Vector2i(
			int(round((old_uv.position.x - rect.position.x) / span_uv.x * float(size_px.x))),
			int(round((old_uv.position.y - rect.position.y) / span_uv.y * float(size_px.y))))
		img.blit_rect(scaled, Rect2i(0, 0, scaled.get_width(), scaled.get_height()), dst)

	mat.set_shader_parameter("stamp_layer_enabled", true)
	mat.set_shader_parameter("stamp_layer_texture", ImageTexture.create_from_image(img))
	mat.set_shader_parameter("stamp_layer_uv_offset", rect.position)
	mat.set_shader_parameter("stamp_layer_uv_scale", Vector2(1.0 / span_uv.x, 1.0 / span_uv.y))
	_set_cached_image(mat, "stamp", img)
	mask_state_version += 1
	return img

## Window sizes round up to DECAL_WINDOW_ALIGN_PX (see the constant).
static func _align_window_px(v: int) -> int:
	return int(ceil(float(v) / float(DECAL_WINDOW_ALIGN_PX))) * DECAL_WINDOW_ALIGN_PX

## Clears the decal window to transparent on `mat` (the window itself stays, so
## the mapping the shader holds does not change).
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

## Pastes `image` as a decal centred on `center_local`, oriented by `normal` +
## `rotation_deg`, `scale` METRES WIDE (the height follows the image's own
## aspect ratio — a 4:1 banner lands as a 4:1 banner, never squished into a
## square). `center_local` and `normal` are NODE-LOCAL: converting the point
## but not the normal (the caller's job) used a basis that is not in the face's
## plane and smeared the decal. Every face of `mesh_data` the oriented
## footprint can reach receives its own part of the paste, so a stamp may cross
## a face edge and continue on the neighbour; faces are given their own splat
## material first (see ensure_face_owned_material). `opacity` scales the
## source alpha. Returns the number of faces painted.
static func paste_decal(mesh_data: PBMeshData, center_local: Vector3, normal: Vector3,
		rotation_deg: float, scale: float, opacity: float, image: Image,
		texels_per_m: float = DECAL_TEXELS_PER_M) -> int:
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
		if _paste_decal_into(t, src, center_local, basis["right"], basis["up"], ext,
				opacity_b, texels_per_m):
			painted += 1
	return painted

## One brush dab into the decal layer: the same oriented footprint as a paste,
## sized by `radius` and faded by the brush falloff LUT. `erase` fades the
## layer's alpha out instead of compositing new pixels in, which is how parts
## of a stamp get removed again. With `image` = null the dab paints a solid
## `color` (the basic brush); pass an image to dab the palette texture instead.
## Returns the number of faces touched.
static func paint_decal_dab(mesh_data: PBMeshData, center_local: Vector3, normal: Vector3,
		rotation_deg: float, radius: float, softness: float, opacity: float,
		erase: bool, image: Image, color: Color = Color(0, 0, 0, 0),
		texels_per_m: float = DECAL_TEXELS_PER_M) -> int:
	if mesh_data == null or radius <= 0.0:
		return 0
	if image == null and not erase and color.a <= 0.0:
		return 0
	var src := _decal_source(image) if image != null else _decal_solid_source(color)
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
				ext, radius, lut, opacity_b, erase, texels_per_m):
			touched += 1
	return touched

## A 1x1 source for the solid-colour brush: the pixel loops then run unchanged
## (every fetch lands on the single texel), so a colour dab costs strictly less
## than an image dab.
static func _decal_solid_source(color: Color) -> Dictionary:
	var b := PackedByteArray()
	b.resize(4)
	b[0] = int(round(clampf(color.r, 0.0, 1.0) * 255.0))
	b[1] = int(round(clampf(color.g, 0.0, 1.0) * 255.0))
	b[2] = int(round(clampf(color.b, 0.0, 1.0) * 255.0))
	b[3] = int(round(clampf(color.a, 0.0, 1.0) * 255.0))
	return {"bytes": b, "w": 1, "h": 1}

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
## with everything the pixel loops need (owned material, rect, axes).
## `min_alignment` rejects faces the decal's plane is not roughly parallel to:
## on those the paste is a degenerate projection of the content (a floor stamp
## smeared down a perpendicular wall), not a decal.
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

		# A stamp may span faces: the ones that must not take paint (a
		# billboard's alpha-scissor quad) are skipped here, not converted.
		if not paint_block_reason(mesh_data.get_face_material(face)).is_empty():
			continue
		var mat := ensure_face_owned_material(mesh_data, face)
		if mat == null:
			continue
		ensure_face_splat_bounds(mesh_data, face)
		var bounds := get_face_planar_bounds(mesh_data, face)
		if bounds.is_empty():
			continue
		# The decal window itself is allocated by the writer, which is the
		# only place that knows the footprint it has to cover.
		out.append({
			"face": face,
			"mat": mat,
			"u_axis": bounds["u"],
			"v_axis": bounds["v"],
			"min_u": bounds["min_u"],
			"min_v": bounds["min_v"],
			"range_u": bounds["range_u"],
			"range_v": bounds["range_v"],
		})
	return out

## The stamp sprite for an AXIS-ALIGNED paste: the source cropped to the
## footprint's texel range and resized to the footprint's pixel grid, all in
## C++. Returns null when the stamp's axes do not line up with the face's (a
## rotated stamp), where the caller falls back to the per-pixel loop.
##
## The mapping from a sprite pixel to source uv is affine:
##   sx = a*x + b*y + c, sy = d*x + e*y + f
## and it is axis-aligned when the CROSS terms stay under half a source texel
## across the whole sprite.
static func _aligned_stamp_sprite(src: Dictionary, ext: Vector2, center_u: float,
		center_v: float, u_face: Vector3, v_face: Vector3, rot_right: Vector3,
		rot_up: Vector3, px_per_m_u: float, px_per_m_v: float, opacity_b: int) -> Image:
	if src.is_empty():
		return null
	var sw: int = src["w"]
	var sh: int = src["h"]
	var w := maxi(1, int(round(ext.x * px_per_m_u)))
	var h := maxi(1, int(round(ext.y * px_per_m_v)))
	if w < 1 or h < 1:
		return null
	var a := u_face.dot(rot_right) / ext.x / px_per_m_u
	var b := v_face.dot(rot_right) / ext.x / px_per_m_v
	var d := -u_face.dot(rot_up) / ext.y / px_per_m_u
	var e := -v_face.dot(rot_up) / ext.y / px_per_m_v
	var half_w := float(w) * 0.5
	var half_h := float(h) * 0.5
	var c := 0.5 - half_w * a - half_h * b
	var f := 0.5 - half_w * d - half_h * e
	# Half a source texel of drift is the most a bilinear resample can hide.
	if absf(b) * float(h) * float(maxi(sw - 1, 1)) > 0.5 \
			or absf(d) * float(w) * float(maxi(sh - 1, 1)) > 0.5:
		return null
	var src_img := Image.create_from_data(sw, sh, false, Image.FORMAT_RGBA8, src["bytes"])
	var x0 := c * float(sw - 1)
	var x1 := (a * float(w - 1) + c) * float(sw - 1)
	var y0 := f * float(sh - 1)
	var y1 := (e * float(h - 1) + f) * float(sh - 1)
	var lo_x := clampi(int(floor(minf(x0, x1))), 0, sw - 1)
	var lo_y := clampi(int(floor(minf(y0, y1))), 0, sh - 1)
	var hi_x := clampi(int(ceil(maxf(x0, x1))), 0, sw - 1)
	var hi_y := clampi(int(ceil(maxf(y0, y1))), 0, sh - 1)
	var crop := src_img.get_region(Rect2i(lo_x, lo_y, hi_x - lo_x + 1, hi_y - lo_y + 1))
	crop.resize(w, h, Image.INTERPOLATE_BILINEAR)
	if a < 0.0:
		crop.flip_x()
	if e < 0.0:
		crop.flip_y()
	if opacity_b < 255:
		# The aligned fast path bypasses the pixel-walk compositor (where
		# opacity is applied), so the stamp opacity must be baked into the
		# sprite's alpha here or it silently never applies.
		var ab := crop.get_data()
		for i in range(3, ab.size(), 4):
			ab[i] = (int(ab[i]) * opacity_b + 127) / 255
		crop.set_data(crop.get_width(), crop.get_height(), false, Image.FORMAT_RGBA8, ab)
	return crop

## The flat-colour brush's falloff disc as an image: `color` (with the brush's
## opacity baked into alpha) inside the brush's cosine falloff. Cached, because
## a stroke asks for the same sprite on every dab.
static func _flat_dab_sprite(src: Dictionary, radius: float, lut: PackedByteArray,
		opacity_b: int, texels_per_m: float) -> Image:
	var src_b: PackedByteArray = src["bytes"]
	var sr := int(src_b[0])
	var sg := int(src_b[1])
	var sb := int(src_b[2])
	var sa := int(src_b[3])
	var key := "%d_%d_%d_%d_%d_%d" % [sr, sg, sb, sa, int(round(radius * texels_per_m)),
			int(round(opacity_b)) | (lut.size() << 9) | (int(round(radius * 1000.0)) << 20)]
	if _dab_sprite_cache.has(key):
		return _dab_sprite_cache[key]
	var side := maxi(3, int(round(radius * 2.0 * texels_per_m)))
	if side > DECAL_MAX_SPRITE_PX:
		return null
	var sprite := Image.create(side, side, false, Image.FORMAT_RGBA8)
	sprite.fill(Color(0, 0, 0, 0))
	var b := sprite.get_data()
	var half := float(side) * 0.5
	var inv_r_sq := 1.0 / (radius * radius)
	var lut_max := float(BRUSH_LUT_SIZE - 1)
	for y in range(side):
		var dy := (float(y) + 0.5 - half) / texels_per_m
		var dy_sq := dy * dy
		for x in range(side):
			var dx := (float(x) + 0.5 - half) / texels_per_m
			var li := int((dx * dx + dy_sq) * inv_r_sq * lut_max)
			if li >= BRUSH_LUT_SIZE - 1:
				continue
			var w255 := int(lut[li])
			if w255 <= 0:
				continue
			var weight := (w255 * opacity_b + 127) / 255
			if weight <= 0:
				continue
			var di := (y * side + x) * 4
			b[di] = sr
			b[di + 1] = sg
			b[di + 2] = sb
			b[di + 3] = (sa * weight + 127) / 255
	sprite.set_data(side, side, false, Image.FORMAT_RGBA8, b)
	if _dab_sprite_cache.size() >= 8:
		_dab_sprite_cache.clear()
	_dab_sprite_cache[key] = sprite
	return sprite

## An oriented decal sprite: the source projected through the face's axes into
## the footprint's pixel grid, ready for one Image.blend_rect(). With a `lut`
## the brush falloff fades it (a dab); without one the pixels are copied as-is
## (a stamp). Cached per source/rotation/basis/density, because a stroke and a
## repeated stamp ask for the same sprite over and over — building it is the
## only per-pixel GDScript work left on this path.
##
## Returns null when the mapping needs a sprite larger than DECAL_MAX_SPRITE_PX
## or the source has nothing to paint, so the caller can walk pixels instead.
static func _oriented_sprite(src: Dictionary, u_face: Vector3, v_face: Vector3,
		rot_right: Vector3, rot_up: Vector3, ext: Vector2, px_per_m_u: float,
		px_per_m_v: float, lut: PackedByteArray, opacity_b: int, radius: float) -> Image:
	if src.is_empty():
		return null
	var is_dab: bool = lut.size() > 0
	var half_u_m := radius
	var half_v_m := radius
	if not is_dab:
		# The footprint's bbox in the FACE's plane. A stamp that is not axis-
		# aligned with the face (rotated, or on a face whose planar basis differs
		# from the stamp's) occupies its ext ROTATED, so sizing the sprite by the
		# unrotated ext clipped the content — which read as a horizontally
		# squashed stamp.
		var k_r_u := u_face.dot(rot_right)
		var k_r_v := v_face.dot(rot_right)
		var k_u_u := u_face.dot(rot_up)
		var k_u_v := v_face.dot(rot_up)
		half_u_m = 0.5 * (absf(ext.x * k_r_u) + absf(ext.y * k_u_u))
		half_v_m = 0.5 * (absf(ext.x * k_r_v) + absf(ext.y * k_u_v))
	var side_u := maxi(1, int(round(half_u_m * 2.0 * px_per_m_u)))
	var side_v := maxi(1, int(round(half_v_m * 2.0 * px_per_m_v)))
	if side_u < 3 or side_v < 3 or side_u > DECAL_MAX_SPRITE_PX or side_v > DECAL_MAX_SPRITE_PX:
		return null

	var key_u := "%d_%d_%d" % [int(round(u_face.x * 100.0)), int(round(u_face.y * 100.0)), int(round(u_face.z * 100.0))]
	var key_v := "%d_%d_%d" % [int(round(v_face.x * 100.0)), int(round(v_face.y * 100.0)), int(round(v_face.z * 100.0))]
	var key := "%s_%s_%s_%d_%d_%dx%d_%d_%d_%d" % [src["key"], key_u, key_v,
			int(round(ext.x * 1000.0)), int(round(ext.y * 1000.0)),
			side_u, side_v, opacity_b, int(round(radius * 1000.0)), 1 if is_dab else 0]
	if _dab_sprite_cache.has(key):
		return _dab_sprite_cache[key]

	var rsrc := _resample_source(src, maxi(1, int(round(ext.x * px_per_m_u))),
			maxi(1, int(round(ext.y * px_per_m_v))))
	if rsrc.is_empty():
		return null
	var src_b: PackedByteArray = rsrc["bytes"]
	var sw: int = rsrc["w"]
	var sh: int = rsrc["h"]
	var sprite := Image.create(side_u, side_v, false, Image.FORMAT_RGBA8)
	sprite.fill(Color(0, 0, 0, 0))
	var b := sprite.get_data()
	var half_u := float(side_u) * 0.5
	var half_v := float(side_v) * 0.5
	var inv_r_sq := 1.0 / maxf(radius * radius, 0.000001)
	var lut_max := float(BRUSH_LUT_SIZE - 1)
	var last_sx := float(sw - 1)
	var last_sy := float(sh - 1)
	var dirty := false
	for y in range(side_v):
		var dv := (float(y) + 0.5 - half_v) / px_per_m_v
		var dv_sq := dv * dv
		for x in range(side_u):
			var du := (float(x) + 0.5 - half_u) / px_per_m_u
			var weight := 255
			if is_dab:
				var li := int((du * du + dv_sq) * inv_r_sq * lut_max)
				if li >= BRUSH_LUT_SIZE - 1:
					continue
				var w255 := int(lut[li])
				if w255 <= 0:
					continue
				weight = (w255 * opacity_b + 127) / 255
				if weight <= 0:
					continue
			else:
				# A stamp has no falloff; its opacity IS the weight.
				weight = opacity_b
				if weight <= 0:
					continue
			var dp := du * u_face + dv * v_face
			var sx := dp.dot(rot_right) / ext.x + 0.5
			if sx < 0.0 or sx > 1.0:
				continue
			var sy := 0.5 - dp.dot(rot_up) / ext.y
			if sy < 0.0 or sy > 1.0:
				continue
			var si := (clampi(int(sy * last_sy), 0, sh - 1) * sw 					+ clampi(int(sx * last_sx), 0, sw - 1)) * 4
			var sa := int(src_b[si + 3])
			if sa <= 0:
				continue
			var a := (sa * weight + 127) / 255
			if a <= 0:
				continue
			var di := (y * side_u + x) * 4
			b[di] = src_b[si]
			b[di + 1] = src_b[si + 1]
			b[di + 2] = src_b[si + 2]
			b[di + 3] = a
			dirty = true
	if not dirty:
		return null
	sprite.set_data(side_u, side_v, false, Image.FORMAT_RGBA8, b)
	if side_u * side_v <= DECAL_MAX_SPRITE_PX * 256:
		if _dab_sprite_cache.size() >= 8:
			_dab_sprite_cache.clear()
		_dab_sprite_cache[key] = sprite
	return sprite

## Source image as raw RGBA8 bytes (decompress + convert once per write, never
## per pixel: the pixel loops index the byte array directly). Mipmaps are
## dropped: get_data() concatenates every level, so a mipmapped source would
## hand the resampler a buffer larger than the base level it describes.
static func _decal_source(image: Image) -> Dictionary:
	if image == null or image.is_empty():
		return {}
	var id := image.get_instance_id()
	if _decal_source_cache.has(id):
		return _decal_source_cache[id]
	var img := image
	if img.is_compressed():
		img = img.duplicate()
		img.decompress()
	if img.get_format() != Image.FORMAT_RGBA8 or img.has_mipmaps():
		# Copy the BASE LEVEL into a clean RGBA8 image: get_data() concatenates
		# every mip level (an imported 256x128 PNG arrives as 174764 bytes
		# instead of 131072) and get_region() keeps them.
		var src := img
		if src.get_format() != Image.FORMAT_RGBA8:
			src = src.duplicate()
			src.convert(Image.FORMAT_RGBA8)
		var base := Image.create(src.get_width(), src.get_height(), false, Image.FORMAT_RGBA8)
		base.blit_rect(src, Rect2i(0, 0, src.get_width(), src.get_height()), Vector2i.ZERO)
		img = base
	if img.is_empty():
		return {}
	var out := {"bytes": img.get_data(), "w": img.get_width(), "h": img.get_height(),
			"key": "img_%d" % id}
	if _decal_source_cache.size() >= 8:
		_decal_source_cache.clear()
	_decal_source_cache[id] = out
	return out

## The source resampled to the footprint's own size in the target's pixel grid.
## The oriented fetch below is then a 1:1 nearest read, which is what keeps a
## stamp as sharp as its source: nearest-sampling a 256 px PNG into an 85 px
## footprint (the old behaviour) aliases it into the visible blocks/dropouts
## the decal layer was reported for. Cached per (source, size) because every
## dab of a stroke writes the same footprint size.
static func _resample_source(src: Dictionary, fw: int, fh: int) -> Dictionary:
	var sw: int = src["w"]
	var sh: int = src["h"]
	if (sw == fw and sh == fh) or (sw == 1 and sh == 1):
		return src
	var key := "%s_%dx%d" % [src["key"], fw, fh]
	if _decal_resample_cache.has(key):
		return _decal_resample_cache[key]
	var img := Image.create_from_data(sw, sh, false, Image.FORMAT_RGBA8, src["bytes"])
	var mode := Image.INTERPOLATE_BILINEAR if (fw >= sw and fh >= sh) else Image.INTERPOLATE_TRILINEAR
	img.resize(fw, fh, mode)
	var out := {"bytes": img.get_data(), "w": fw, "h": fh, "key": key}
	if _decal_resample_cache.size() >= 6:
		_decal_resample_cache.clear()
	_decal_resample_cache[key] = out
	return out

## The pixel bbox of a decal footprint inside a target's window image, from the
## footprint's own half extents in face metres per axis (NOT a circumscribed
## square: a 4:1 banner would make that square 4x the pixels for nothing),
## clamped to the window.
static func _decal_pixel_window(t: Dictionary, win: Rect2, center_u: float,
		center_v: float, half_u: float, half_v: float) -> Dictionary:
	var img: Image = t["img"]
	var w := img.get_width()
	var h := img.get_height()
	var min_u: float = t["min_u"]
	var min_v: float = t["min_v"]
	var range_u: float = t["range_u"]
	var range_v: float = t["range_v"]
	var fu0: float = (center_u - half_u - min_u) / range_u
	var fv0: float = (center_v - half_v - min_v) / range_v
	var fu1: float = (center_u + half_u - min_u) / range_u
	var fv1: float = (center_v + half_v - min_v) / range_v
	var x0 := clampi(int(floor((fu0 - win.position.x) / win.size.x * float(w - 1))), 0, w - 1)
	var x1 := clampi(int(ceil((fu1 - win.position.x) / win.size.x * float(w - 1))), 0, w - 1)
	var y0 := clampi(int(floor((fv0 - win.position.y) / win.size.y * float(h - 1))), 0, h - 1)
	var y1 := clampi(int(ceil((fv1 - win.position.y) / win.size.y * float(h - 1))), 0, h - 1)
	return {"x0": x0, "x1": x1, "y0": y0, "y1": y1, "w": w, "h": h}

## Uploads a target's image back to its ImageTexture and bumps the state
## version so downstream caches (UV editor preview, exporters) refresh.
static func _commit_decal_target(mat: ShaderMaterial, img: Image) -> void:
	if mat == null or img == null:
		return
	var tex = mat.get_shader_parameter("stamp_layer_texture") as ImageTexture
	if tex != null:
		tex.update(img)
	mask_state_version += 1

static func _paste_decal_into(t: Dictionary, src: Dictionary, center_local: Vector3,
		rot_right: Vector3, rot_up: Vector3, ext: Vector2, opacity_b: int,
		texels_per_m: float) -> bool:
	# The decal centre projected into THIS face's plane: once a stamp wraps a
	# corner, every face samples it through its own axes.
	var u_face: Vector3 = t["u_axis"]
	var v_face: Vector3 = t["v_axis"]
	var min_u: float = t["min_u"]
	var min_v: float = t["min_v"]
	var range_u: float = t["range_u"]
	var range_v: float = t["range_v"]
	var center_u: float = u_face.dot(center_local)
	var center_v: float = v_face.dot(center_local)
	# The footprint's OWN bounding box in the face's plane. A stamp is usually
	# not square (a 4:1 banner), and the circumscribed square would walk four
	# times its pixels for nothing.
	var k_r_u := u_face.dot(rot_right)
	var k_r_v := v_face.dot(rot_right)
	var k_u_u := u_face.dot(rot_up)
	var k_u_v := v_face.dot(rot_up)
	var half_u: float = 0.5 * (absf(ext.x * k_r_u) + absf(ext.y * k_u_u))
	var half_v: float = 0.5 * (absf(ext.x * k_r_v) + absf(ext.y * k_u_v))

	var mat: ShaderMaterial = t["mat"]
	var need := Rect2(
		(center_u - half_u - min_u) / range_u, (center_v - half_v - min_v) / range_v,
		2.0 * half_u / range_u, 2.0 * half_v / range_v)
	var inv_u := 1.0 / maxf(range_u * maxf(texels_per_m, 1.0), 0.001)
	var inv_v := 1.0 / maxf(range_v * maxf(texels_per_m, 1.0), 0.001)
	need = need.grow_individual(inv_u, inv_v, inv_u, inv_v)
	var dst_img := ensure_decal_window(mat, need, Vector2(range_u, range_v), texels_per_m)
	if dst_img == null:
		return false
	t["img"] = dst_img
	var win := get_decal_window(mat)
	var px_per_m_u := float(dst_img.get_width() - 1) / maxf(win.size.x * range_u, 0.000001)
	var px_per_m_v := float(dst_img.get_height() - 1) / maxf(win.size.y * range_v, 0.000001)
	var win_data := _decal_pixel_window(t, win, center_u, center_v, half_u, half_v)
	if win_data["x0"] > win_data["x1"] or win_data["y0"] > win_data["y1"]:
		return false

	# A stamp is ONE click, so its paste must not walk the footprint pixel by
	# pixel in GDScript (a 4.32 m banner took 1.2 s that way). When the stamp's
	# axes line up with the face's — rotation 0 on an axis-aligned face, which
	# is the normal case — the sprite is a crop + resize (+ flip), and the paste
	# is one Image.blend_rect() call.
	var sprite := _aligned_stamp_sprite(src, ext, center_u, center_v, u_face, v_face,
			rot_right, rot_up, px_per_m_u, px_per_m_v, opacity_b)
	if sprite != null:
		var half_px := Vector2(sprite.get_width() * 0.5, sprite.get_height() * 0.5)
		var centre_px := Vector2(
			(center_u - min_u) / range_u, (center_v - min_v) / range_v)
		var at := Vector2i(
			int(round((centre_px.x - win.position.x) / win.size.x * float(dst_img.get_width() - 1) - half_px.x)),
			int(round((centre_px.y - win.position.y) / win.size.y * float(dst_img.get_height() - 1) - half_px.y)))
		dst_img.blend_rect(sprite, Rect2i(0, 0, sprite.get_width(), sprite.get_height()), at)
		_commit_decal_target(mat, dst_img)
		return true

	# A rotated stamp (or one whose sprite is too large to prebuild): the
	# sprite is still built once and cached, so only the first stamp of a given
	# source/rotation/size pays for the pixel walk — the ones after it are one
	# blend. Stamps placed repeatedly (a tile pattern across a floor) are the
	# normal case.
	var osprite := _oriented_sprite(src, u_face, v_face, rot_right, rot_up, ext,
			px_per_m_u, px_per_m_v, PackedByteArray(), opacity_b, 0.0)
	if osprite != null:
		var ohalf := Vector2(osprite.get_width() * 0.5, osprite.get_height() * 0.5)
		var ocentre := Vector2(
			(center_u - min_u) / range_u, (center_v - min_v) / range_v)
		dst_img.blend_rect(osprite, Rect2i(0, 0, osprite.get_width(), osprite.get_height()),
				Vector2i(
					int(round((ocentre.x - win.position.x) / win.size.x * float(dst_img.get_width() - 1) - ohalf.x)),
					int(round((ocentre.y - win.position.y) / win.size.y * float(dst_img.get_height() - 1) - ohalf.y))))
		_commit_decal_target(mat, dst_img)
		return true

	# Footprint-sized source: the oriented fetch stays a 1:1 read.
	var rsrc := _resample_source(src, maxi(1, int(round(ext.x * px_per_m_u))),
			maxi(1, int(round(ext.y * px_per_m_v))))

	var w: int = win_data["w"]
	var h: int = win_data["h"]
	var inv_w := 1.0 / float(maxi(w - 1, 1))
	var inv_h := 1.0 / float(maxi(h - 1, 1))
	var src_b: PackedByteArray = rsrc["bytes"]
	var sw: int = rsrc["w"]
	var sh: int = rsrc["h"]
	var dst_b := dst_img.get_data()

	var dirty := false
	for y in range(win_data["y0"], win_data["y1"] + 1):
		var v_coord := min_v + (win.position.y + float(y) * inv_h * win.size.y) * range_v
		var row := y * w
		for x in range(win_data["x0"], win_data["x1"] + 1):
			var u_coord := min_u + (win.position.x + float(x) * inv_w * win.size.x) * range_u
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
	_commit_decal_target(mat, dst_img)
	return true

static func _brush_decal_into(t: Dictionary, src: Dictionary, center_local: Vector3,
		rot_right: Vector3, rot_up: Vector3, ext: Vector2, radius: float,
		lut: PackedByteArray, opacity_b: int, erase: bool, texels_per_m: float) -> bool:
	var u_face: Vector3 = t["u_axis"]
	var v_face: Vector3 = t["v_axis"]
	var min_u: float = t["min_u"]
	var min_v: float = t["min_v"]
	var range_u: float = t["range_u"]
	var range_v: float = t["range_v"]
	var center_u: float = u_face.dot(center_local)
	var center_v: float = v_face.dot(center_local)

	var mat: ShaderMaterial = t["mat"]
	var need := Rect2(
		(center_u - radius - min_u) / range_u, (center_v - radius - min_v) / range_v,
		2.0 * radius / range_u, 2.0 * radius / range_v)
	var inv_u := 1.0 / maxf(range_u * maxf(texels_per_m, 1.0), 0.001)
	var inv_v := 1.0 / maxf(range_v * maxf(texels_per_m, 1.0), 0.001)
	need = need.grow_individual(inv_u, inv_v, inv_u, inv_v)
	var dst_img := ensure_decal_window(mat, need, Vector2(range_u, range_v), texels_per_m)
	if dst_img == null:
		return false
	t["img"] = dst_img
	var win := get_decal_window(mat)
	var px_per_m_u := float(dst_img.get_width() - 1) / maxf(win.size.x * range_u, 0.000001)
	var px_per_m_v := float(dst_img.get_height() - 1) / maxf(win.size.y * range_v, 0.000001)
	var win_data := _decal_pixel_window(t, win, center_u, center_v, radius, radius)
	if win_data["x0"] > win_data["x1"] or win_data["y0"] > win_data["y1"]:
		return false

	# Only the footprint's own box travels between the image and the byte
	# buffer: a dab touches a fraction of the window, and get_data()/set_data()
	# on the whole window copies megabytes for it.
	var w: int = win_data["w"]
	var h: int = win_data["h"]
	var inv_w := 1.0 / float(maxi(w - 1, 1))
	var inv_h := 1.0 / float(maxi(h - 1, 1))
	var box := Rect2i(win_data["x0"], win_data["y0"],
			win_data["x1"] - win_data["x0"] + 1, win_data["y1"] - win_data["y0"] + 1)
	var region := dst_img.get_region(box)
	var dst_b := region.get_data()
	var bw := box.size.x
	var bh := box.size.y

	# Face-metre position of the box's first pixel and the step per pixel. The
	# distance field only needs (u, v); the oriented source fetch needs sx/sy,
	# which are AFFINE in the pixel index (the face's axes are linear in uv and
	# the stamp basis is a fixed projection) — so both loops step floats
	# instead of rebuilding a Vector3 and two dot products per pixel.
	var step_u := inv_w * win.size.x * range_u
	var step_v := inv_h * win.size.y * range_v
	var u_at := min_u + (win.position.x + float(box.position.x) * inv_w * win.size.x) * range_u
	var v_at := min_v + (win.position.y + float(box.position.y) * inv_h * win.size.y) * range_v
	var dsx_du := step_u * u_face.dot(rot_right) / ext.x
	var dsy_du := -step_u * u_face.dot(rot_up) / ext.y
	var dsx_dv := step_v * v_face.dot(rot_right) / ext.x
	var dsy_dv := -step_v * v_face.dot(rot_up) / ext.y
	var sx_row := ((u_at - center_u) * u_face + (v_at - center_v) * v_face).dot(rot_right) / ext.x + 0.5
	var sy_row := 0.5 - ((u_at - center_u) * u_face + (v_at - center_v) * v_face).dot(rot_up) / ext.y

	var inv_r_sq := 1.0 / (radius * radius)
	var lut_max := float(BRUSH_LUT_SIZE - 1)
	var dirty := false

	if src["w"] == 1 and src["h"] == 1:
		# FLAT source (the colour brush, and every erase dab): one colour for
		# the whole footprint, so the sample fetch and the oriented basis drop
		# out entirely. This is the hot path — the basic brush.
		if not erase:
			# Paint as a prebuilt sprite: one C++ blend per dab instead of a
			# per-pixel GDScript loop (see _dab_sprite_cache).
			#
			# The sprite must be built at the WINDOW's real density, not the
			# requested one: past DECAL_MAX_WINDOW_PX the window holds fewer
			# texels per metre, and a sprite built at the requested density was
			# drawn that much larger in window pixels — its soft falloff ran
			# past the window edge and was cut off (the "paint cuts off
			# abruptly as it expands" report: a stroke's last dabs rendered ~2x
			# oversized and clipped).
			var sprite := _flat_dab_sprite(src, radius, lut, opacity_b,
					(px_per_m_u + px_per_m_v) * 0.5)
			if sprite != null:
				var half_px := Vector2(sprite.get_width() * 0.5, sprite.get_height() * 0.5)
				var centre_px := Vector2(
					((center_u - min_u) / range_u - win.position.x) / win.size.x * float(w - 1),
					((center_v - min_v) / range_v - win.position.y) / win.size.y * float(h - 1))
				var at := Vector2i(int(round(centre_px.x - half_px.x)), int(round(centre_px.y - half_px.y)))
				dst_img.blend_rect(sprite, Rect2i(0, 0, sprite.get_width(), sprite.get_height()), at)
				_commit_decal_target(mat, dst_img)
				return true
		var src_b: PackedByteArray = src["bytes"]
		var sr := int(src_b[0])
		var sg := int(src_b[1])
		var sb := int(src_b[2])
		var sa := int(src_b[3])
		for y in range(bh):
			var dv := v_at - center_v
			var dv_sq := dv * dv
			for x in range(bw):
				var du := u_at + float(x) * step_u - center_u
				var li := int((du * du + dv_sq) * inv_r_sq * lut_max)
				# (reached for erase, and for radii too large for a sprite)
				if li >= BRUSH_LUT_SIZE - 1:
					continue
				var w255 := int(lut[li])
				if w255 <= 0:
					continue
				var weight := (w255 * opacity_b + 127) / 255
				if weight <= 0:
					continue
				var di := (y * bw + x) * 4
				if erase:
					var da := int(dst_b[di + 3])
					if da == 0:
						continue
					var faded := (da * (255 - weight) + 127) / 255
					if faded != da:
						dst_b[di + 3] = faded
						dirty = true
					continue
				var a := (sa * weight + 127) / 255
				if a <= 0:
					continue
				var da2 := int(dst_b[di + 3])
				if da2 == 0:
					dst_b[di] = sr
					dst_b[di + 1] = sg
					dst_b[di + 2] = sb
					dst_b[di + 3] = a
				else:
					var inv := 255 - a
					var out_a := a + (da2 * inv + 127) / 255
					if out_a <= 0:
						continue
					var half := out_a / 2
					dst_b[di] = clampi((sr * a + (int(dst_b[di]) * da2 * inv + 127) / 255 + half) / out_a, 0, 255)
					dst_b[di + 1] = clampi((sg * a + (int(dst_b[di + 1]) * da2 * inv + 127) / 255 + half) / out_a, 0, 255)
					dst_b[di + 2] = clampi((sb * a + (int(dst_b[di + 2]) * da2 * inv + 127) / 255 + half) / out_a, 0, 255)
					dst_b[di + 3] = out_a
				dirty = true
			v_at += step_v
		if not dirty:
			return false
		region.set_data(bw, bh, false, Image.FORMAT_RGBA8, dst_b)
		dst_img.blit_rect(region, Rect2i(0, 0, bw, bh), box.position)
		_commit_decal_target(mat, dst_img)
		return true

	# ORIENTED source (a palette-image dab): the sampled content is projected
	# through the stamp basis, so each pixel needs its sx/sy position. Like the
	# flat brush, the sprite is position-independent within a stroke (fixed
	# source, rotation, size and face basis), so it is built once and blended
	# per dab — the same reason the colour brush is fast.
	if not erase:
		var osprite := _oriented_sprite(src, u_face, v_face, rot_right, rot_up,
				ext, px_per_m_u, px_per_m_v, lut, opacity_b, radius)
		if osprite != null:
			var ohalf := Vector2(osprite.get_width() * 0.5, osprite.get_height() * 0.5)
			var ocentre := Vector2(
				((center_u - min_u) / range_u - win.position.x) / win.size.x * float(w - 1),
				((center_v - min_v) / range_v - win.position.y) / win.size.y * float(h - 1))
			dst_img.blend_rect(osprite, Rect2i(0, 0, osprite.get_width(), osprite.get_height()),
					Vector2i(int(round(ocentre.x - ohalf.x)), int(round(ocentre.y - ohalf.y))))
			_commit_decal_target(mat, dst_img)
			return true

	var rsrc := _resample_source(src, maxi(1, int(round(ext.x * px_per_m_u))),
			maxi(1, int(round(ext.y * px_per_m_v))))
	var src_b: PackedByteArray = rsrc["bytes"]
	var sw2: int = rsrc["w"]
	var sh2: int = rsrc["h"]
	var last_sx := float(sw2 - 1)
	var last_sy := float(sh2 - 1)
	for y in range(bh):
		var dv := v_at - center_v
		var dv_sq := dv * dv
		var sx := sx_row
		var sy := sy_row
		for x in range(bw):
			var du := u_at + float(x) * step_u - center_u
			var li := int((du * du + dv_sq) * inv_r_sq * lut_max)
			if li < BRUSH_LUT_SIZE - 1:
				var w255 := int(lut[li])
				if w255 > 0:
					var weight := (w255 * opacity_b + 127) / 255
					if weight > 0:
						var di := (y * bw + x) * 4
						if erase:
							var da := int(dst_b[di + 3])
							if da != 0:
								var faded := (da * (255 - weight) + 127) / 255
								if faded != da:
									dst_b[di + 3] = faded
									dirty = true
						elif sx >= 0.0 and sx <= 1.0 and sy >= 0.0 and sy <= 1.0:
							var si := (clampi(int(sy * last_sy), 0, sh2 - 1) * sw2 									+ clampi(int(sx * last_sx), 0, sw2 - 1)) * 4
							var sa2 := int(src_b[si + 3])
							if sa2 > 0:
								var a := (sa2 * weight + 127) / 255
								if a > 0:
									var da2 := int(dst_b[di + 3])
									if da2 == 0:
										dst_b[di] = src_b[si]
										dst_b[di + 1] = src_b[si + 1]
										dst_b[di + 2] = src_b[si + 2]
										dst_b[di + 3] = a
									else:
										var inv := 255 - a
										var out_a := a + (da2 * inv + 127) / 255
										if out_a > 0:
											var half := out_a / 2
											dst_b[di] = clampi((int(src_b[si]) * a + (int(dst_b[di]) * da2 * inv + 127) / 255 + half) / out_a, 0, 255)
											dst_b[di + 1] = clampi((int(src_b[si + 1]) * a + (int(dst_b[di + 1]) * da2 * inv + 127) / 255 + half) / out_a, 0, 255)
											dst_b[di + 2] = clampi((int(src_b[si + 2]) * a + (int(dst_b[di + 2]) * da2 * inv + 127) / 255 + half) / out_a, 0, 255)
											dst_b[di + 3] = out_a
									dirty = true
			sx += dsx_du
			sy += dsy_du
		sx_row += dsx_dv
		sy_row += dsy_dv
		v_at += step_v

	if not dirty:
		return false
	region.set_data(bw, bh, false, Image.FORMAT_RGBA8, dst_b)
	dst_img.blit_rect(region, Rect2i(0, 0, bw, bh), box.position)
	_commit_decal_target(mat, dst_img)
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
			# The window mapping travels WITH the pixels: a copy that dropped
			# it would render the content stretched over the whole face.
			var win_off = source.get_shader_parameter("stamp_layer_uv_offset")
			var win_scale = source.get_shader_parameter("stamp_layer_uv_scale")
			if win_off is Vector2:
				target.set_shader_parameter("stamp_layer_uv_offset", win_off)
			if win_scale is Vector2:
				target.set_shader_parameter("stamp_layer_uv_scale", win_scale)
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

## Rebuilds every GPU mask/decal texture of a mesh from the CPU cache. Needed
## before saving a scene from HEADLESS code (builders, bake scripts): an
## ImageTexture that only saw update() serializes its stale pre-update pixels
## there, so paint written by a headless builder would be lost. Interactive
## painting keeps update() — it is the zero-lag per-dab path.
static func sync_mesh_mask_textures(mesh_data: PBMeshData) -> void:
	if mesh_data == null:
		return
	for mat in mesh_data.materials:
		if is_splat_material(mat):
			sync_mask_textures(mat as ShaderMaterial)

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
	# Hand-authored splat materials may enable a layer without ever setting
	# its color/roughness params (the shader's own defaults apply). A NIL
	# shader parameter would then flow into every consumer that does
	# dict.get("color", Color.WHITE) — the default only covers a MISSING key,
	# not a present-but-null one — and crash the bakers' typed assignments.
	# Coalesce to the same defaults the shader declares.
	var base_color: Color = sm.get_shader_parameter("base_color") if sm.get_shader_parameter("base_color") is Color else Color.WHITE
	var rough: float = sm.get_shader_parameter("roughness") if sm.get_shader_parameter("roughness") is float else 0.8
	var out: Dictionary = {
		"base_texture_path": "",
		"base_color": base_color,
		"roughness": rough,
		"layers": [],
		"decal_layer_image": null,
		"decal_window": Rect2(0.0, 0.0, 1.0, 1.0),
		"planar_bounds": get_face_planar_bounds(mesh_data, face),
	}
	var base_tex := sm.get_shader_parameter("base_texture") as Texture2D
	if base_tex != null:
		out["base_texture_path"] = base_tex.resource_path
	for i in range(1, MAX_LAYERS + 1):
		if sm.get_shader_parameter("layer_%d_enabled" % i) == true:
			var layer_tex := sm.get_shader_parameter("layer_%d_texture" % i) as Texture2D
			var layer_color: Color = sm.get_shader_parameter("layer_%d_color" % i) if sm.get_shader_parameter("layer_%d_color" % i) is Color else Color.WHITE
			var layer_rough: float = sm.get_shader_parameter("layer_%d_roughness" % i) if sm.get_shader_parameter("layer_%d_roughness" % i) is float else 0.8
			out["layers"].append({
				"slot": i,
				"texture": layer_tex,
				"texture_path": layer_tex.resource_path if layer_tex != null else "",
				"color": layer_color,
				"roughness": layer_rough,
				"mask_image": get_layer_mask_image(sm, i),
			})
	if has_decal_layer(sm):
		out["decal_layer_image"] = get_decal_layer_image(sm)
		out["decal_window"] = get_decal_window(sm)
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
	# Clone the decal layer if it exists (window mapping included)
	if source.get_shader_parameter("stamp_layer_enabled") == true:
		clone.set_shader_parameter("stamp_layer_enabled", true)
		var src_stamp_img := get_decal_layer_image(source)
		if src_stamp_img != null:
			var cloned_stamp_img := Image.create(src_stamp_img.get_width(), src_stamp_img.get_height(), false, src_stamp_img.get_format())
			cloned_stamp_img.copy_from(src_stamp_img)
			var cloned_stamp_tex := ImageTexture.create_from_image(cloned_stamp_img)
			clone.set_shader_parameter("stamp_layer_texture", cloned_stamp_tex)
			_set_cached_image(clone, "stamp", cloned_stamp_img)
		var clone_off = source.get_shader_parameter("stamp_layer_uv_offset")
		var clone_scale = source.get_shader_parameter("stamp_layer_uv_scale")
		if clone_off is Vector2:
			clone.set_shader_parameter("stamp_layer_uv_offset", clone_off)
		if clone_scale is Vector2:
			clone.set_shader_parameter("stamp_layer_uv_scale", clone_scale)
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
	var stamp_win := get_decal_window(smat)
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
				# The decal image is a WINDOW inside the face's [0, 1] space:
				# outside it there is no decal at all (never an edge smear).
				var du := (u - stamp_win.position.x) / stamp_win.size.x
				var dv := (v - stamp_win.position.y) / stamp_win.size.y
				if du >= 0.0 and du <= 1.0 and dv >= 0.0 and dv <= 1.0:
					var s_col := _sample_image_clamp(stamp_img, du, dv)
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
