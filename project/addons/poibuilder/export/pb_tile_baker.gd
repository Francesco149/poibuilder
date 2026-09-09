## PBTileBaker — Bakes texture splatting and stamps into discrete tile textures.
##
## In retro engines, painted geometry is treated like a tile map: tiles that have
## been painted (with splat layers or stamp decals) generate a unique composite
## tile texture, while all unpainted tiles reuse the shared base material/texture.
@tool
class_name PBTileBaker
extends RefCounted

## Result of baking tiles for a face.
class BakedFaceResult:
	## Map of TileFragment -> Material.
	var tile_materials: Dictionary = {} # TileFragment -> Material
	## Generated texture resources for cleanup or export bundling.
	var baked_textures: Array[Texture2D] = []

# ==============================================================================
# Public API
# ==============================================================================

## Bakes textures for all tile fragments of a face.
## Returns a BakedFaceResult mapping each fragment to its appropriate material.
## If bake_textures is false, assigns the base material to all fragments.
static func bake_face_tiles(mesh_node: Node, mesh_data: PBMeshData, face: PBFace,
		face_idx: int, fragments: Array[PBFaceSubdivider.TileFragment],
		bake_textures: bool = true, tile_resolution: int = 128,
		base_material_cache: Dictionary = {}, max_texture_size: int = 512) -> BakedFaceResult:
	var result := BakedFaceResult.new()
	if mesh_data == null or face == null or fragments.is_empty():
		return result

	# Enforce power-of-two tile resolution clamped to max_texture_size
	tile_resolution = clampi(nearest_po2(tile_resolution), 16, max_texture_size)
	while tile_resolution > max_texture_size:
		tile_resolution /= 2

	# Get face base material with POT enforcement
	var src_mat := mesh_data.get_face_material(face)
	var base_mat: StandardMaterial3D = _get_or_create_base_material(src_mat, base_material_cache, max_texture_size)
	# If texture baking is disabled, all fragments use the base material
	if not bake_textures:
		for frag in fragments:
			result.tile_materials[frag] = base_mat
		return result

	# Collect paint and stamp state for this face
	var paint_state := PBSplat.collect_face_paint_state(mesh_data, face)
	var all_stamps := PBSplat.collect_stamp_data(mesh_node)
	var face_stamps: Array = []
	for s in all_stamps:
		if s.get("face_idx", -1) == face_idx:
			face_stamps.append(s)

	var layers_list: Array = paint_state.get("layers", [])
	var has_paint: bool = not paint_state.is_empty() and not layers_list.is_empty()
	var has_stamps: bool = not face_stamps.is_empty()

	# If this face has zero paint and zero stamps, all fragments reuse base material
	if not has_paint and not has_stamps:
		for frag in fragments:
			result.tile_materials[frag] = base_mat
		return result

	# Process each tile fragment individually
	var splat_bounds: PackedFloat32Array = face.splat_bounds
	if splat_bounds.size() != 4 and not paint_state.is_empty():
		var pb_dict = paint_state.get("planar_bounds", {})
		if pb_dict is Dictionary and pb_dict.has("min_u"):
			splat_bounds = PackedFloat32Array([pb_dict["min_u"], pb_dict["max_u"], pb_dict["min_v"], pb_dict["max_v"]])
	# Pre-load base image
	var base_image: Image = _extract_base_image(src_mat, paint_state)
	var base_color: Color = _extract_base_color(src_mat, paint_state)

	# Pre-load layer images and masks
	var layer_data: Array = _prepare_layer_data(paint_state)

	# Pre-load stamp images
	var stamp_data: Array = _prepare_stamp_data(face_stamps)
	# Compute anchor offset between anchor space (cell_bounds) and object space (splat_bounds)
	var anchor: Vector3 = mesh_data.get_texture_anchor() if not face.uv_use_world_space else Vector3.ZERO
	var normal: Vector3 = PBMath.normal_from_positions(mesh_data.positions, face.get_indexes())
	if normal.length_squared() < 0.0001: normal = Vector3.UP
	else: normal = normal.normalized()
	var basis := PBUv.get_planar_basis(normal)
	var anchor_offset := Vector2(basis["u"].dot(anchor), basis["v"].dot(anchor))

	for frag in fragments:
		var tile_has_paint := false
		var cell_rect_obj := Rect2(frag.cell_bounds.position + anchor_offset, frag.cell_bounds.size)

		# Check if any stamp touches this tile
		for sd in stamp_data:
			if _stamp_touches_rect(sd, cell_rect_obj):
				tile_has_paint = true
				break

		# Check if any splat layer touches this tile
		if not tile_has_paint and not layer_data.is_empty() and splat_bounds.size() == 4:
			for ld in layer_data:
				if _mask_touches_rect(ld.get("mask_image"), splat_bounds, cell_rect_obj):
					tile_has_paint = true
					break

		if not tile_has_paint:
			# Unpainted tile reuses base material
			result.tile_materials[frag] = base_mat
		else:
			# Painted tile: bake composite texture
			var composite := _bake_composite_tile(frag.cell_bounds, splat_bounds,
				base_image, base_color, layer_data, stamp_data, tile_resolution, anchor_offset)
			var tile_tex := ImageTexture.create_from_image(composite)
			result.baked_textures.append(tile_tex)

			var tile_mat := StandardMaterial3D.new()
			tile_mat.resource_name = "BakedTile_%d_%d_%d" % [face_idx, frag.cell_coord.x, frag.cell_coord.y]
			tile_mat.albedo_texture = tile_tex
			tile_mat.roughness = paint_state.get("roughness", 0.8)
			tile_mat.vertex_color_use_as_albedo = true
			tile_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
			tile_mat.texture_repeat = false

			# Switch fragment UVs to normalized local tile UVs
			frag.uvs = frag.tile_uvs
			result.tile_materials[frag] = tile_mat

	return result

# ==============================================================================
# Internal Baking Pipeline
# ==============================================================================

static func _bake_composite_tile(cell_bounds: Rect2, splat_bounds: PackedFloat32Array,
		base_image: Image, base_color: Color, layer_data: Array, stamp_data: Array,
		resolution: int, anchor_offset: Vector2 = Vector2.ZERO) -> Image:
	var out := Image.create(resolution, resolution, false, Image.FORMAT_RGBA8)

	var u0: float = cell_bounds.position.x
	var u1: float = cell_bounds.position.x + cell_bounds.size.x
	var v0: float = cell_bounds.position.y
	var v1: float = cell_bounds.position.y + cell_bounds.size.y

	var splat_min_u: float = splat_bounds[0] if splat_bounds.size() == 4 else u0
	var splat_max_u: float = splat_bounds[1] if splat_bounds.size() == 4 else u1
	var splat_min_v: float = splat_bounds[2] if splat_bounds.size() == 4 else v0
	var splat_max_v: float = splat_bounds[3] if splat_bounds.size() == 4 else v1
	var splat_span_u: float = maxf(splat_max_u - splat_min_u, 0.0001)
	var splat_span_v: float = maxf(splat_max_v - splat_min_v, 0.0001)

	var base_w := base_image.get_width() if base_image != null else 0
	var base_h := base_image.get_height() if base_image != null else 0

	# Step 1: Base layer fill / sample
	var res_f := maxf(float(resolution - 1), 1.0)
	for y in range(resolution):
		var ty := float(y) / res_f
		var pv := lerpf(v0, v1, ty)
		var uv_v := wrapf(pv, 0.0, 1.0)
		var base_py := clampi(int(round(uv_v * float(base_h - 1))), 0, base_h - 1) if base_h > 0 else 0

		for x in range(resolution):
			var tx := float(x) / res_f
			var pu := lerpf(u0, u1, tx)
			var uv_u := wrapf(pu, 0.0, 1.0)
			var c := base_color
			if base_image != null:
				var base_px := clampi(int(round(uv_u * float(base_w - 1))), 0, base_w - 1)
				c = base_image.get_pixel(base_px, base_py) * base_color

			# Step 2: Splat layers
			for ld in layer_data:
				var mask: Image = ld.get("mask_image")
				var l_img: Image = ld.get("image")
				var l_col: Color = ld.get("color", Color.WHITE)
				if mask == null or l_img == null:
					continue

				# Sample mask at (pu_obj, pv_obj) in object planar space
				var pu_obj := pu + anchor_offset.x
				var pv_obj := pv + anchor_offset.y
				var mu := (pu_obj - splat_min_u) / splat_span_u
				var mv := (pv_obj - splat_min_v) / splat_span_v
				if mu < 0.0 or mu > 1.0 or mv < 0.0 or mv > 1.0:
					continue

				var mw := mask.get_width()
				var mh := mask.get_height()
				var mpx := clampi(int(mu * mw), 0, mw - 1)
				var mpy := clampi(int(mv * mh), 0, mh - 1)
				var weight: float = mask.get_pixel(mpx, mpy).r

				if weight > 0.001:
					var lw := l_img.get_width()
					var lh := l_img.get_height()
					var lpx := clampi(int(round(uv_u * float(lw - 1))), 0, lw - 1)
					var lpy := clampi(int(round(uv_v * float(lh - 1))), 0, lh - 1)
					var l_pixel := l_img.get_pixel(lpx, lpy) * l_col
					c = c.lerp(l_pixel, clampf(weight * l_col.a, 0.0, 1.0))
			# Step 3: Stamps
			for sd in stamp_data:
				var s_img: Image = sd.get("image")
				if s_img == null:
					continue
				var opacity: float = sd.get("opacity", 1.0)

				# Transform (pu_obj, pv_obj) into stamp coordinate space
				var pu_obj := pu + anchor_offset.x
				var pv_obj := pv + anchor_offset.y
				var su := 0.0
				var sv := 0.0
				var inside := false

				if sd.has("anchor_u") and sd.has("anchor_v"):
					var uc: float = sd["anchor_u"]
					var vc: float = sd["anchor_v"]
					var sx: float = sd.get("anchor_scale_x", 1.0)
					var sy: float = sd.get("anchor_scale_y", 1.0)
					su = (pu_obj - uc) / maxf(sx, 0.0001)
					sv = (pv_obj - vc) / maxf(sy, 0.0001)
					inside = (su >= -0.5 and su <= 0.5 and sv >= -0.5 and sv <= 0.5)
				else:
					var anchor_c: Vector2 = sd.get("anchor_center", Vector2.ZERO)
					var du: Vector2 = sd.get("anchor_du", Vector2.RIGHT)
					var dv: Vector2 = sd.get("anchor_dv", Vector2.UP)
					var rel := Vector2(pu_obj, pv_obj) - anchor_c
					var det := du.x * dv.y - du.y * dv.x
					if absf(det) > 0.00001:
						su = (rel.x * dv.y - rel.y * dv.x) / det
						sv = (rel.y * du.x - rel.x * du.y) / det
						inside = (su >= -0.5 and su <= 0.5 and sv >= -0.5 and sv <= 0.5)

				if inside:
					var stu := su + 0.5
					var stv := 0.5 - sv
					var rot_u: Vector3 = sd.get("anchor_rot_up", Vector3.UP)
					if rot_u.dot(Vector3.BACK) < -0.5:
						stv = sv + 0.5
					var sw := s_img.get_width()
					var sh := s_img.get_height()
					var spx := clampi(int(round(stu * float(sw - 1))), 0, sw - 1)
					var spy := clampi(int(round(stv * float(sh - 1))), 0, sh - 1)
					var sp := s_img.get_pixel(spx, spy)
					var alpha: float = sp.a * opacity
					if alpha > 0.001:
						c = c.lerp(Color(sp.r, sp.g, sp.b, 1.0), alpha)
			out.set_pixel(x, y, c)

	return out

# ==============================================================================
# Helper Methods
# ==============================================================================

static func enforce_pot_image(img: Image, max_size: int = 512) -> Image:
	if img == null or img.is_empty():
		return img
	if img.is_compressed():
		img = img.duplicate()
		img.decompress()
	var w := img.get_width()
	var h := img.get_height()
	var pot_w := clampi(nearest_po2(w), 16, max_size)
	var pot_h := clampi(nearest_po2(h), 16, max_size)
	while pot_w > max_size:
		pot_w /= 2
	while pot_h > max_size:
		pot_h /= 2
	if w != pot_w or h != pot_h:
		var resized := img.duplicate()
		resized.resize(pot_w, pot_h, Image.INTERPOLATE_BILINEAR)
		return resized
	return img

static func enforce_pot_texture(tex: Texture2D, max_size: int = 512) -> Texture2D:
	if tex == null:
		return null
	var img := tex.get_image()
	if img == null:
		return tex
	var pot_img := enforce_pot_image(img, max_size)
	if pot_img != img:
		return ImageTexture.create_from_image(pot_img)
	return tex

static func _get_or_create_base_material(src_mat: Material, cache: Dictionary, max_size: int = 512) -> StandardMaterial3D:
	var cache_key = src_mat if src_mat != null else "null_default"
	if cache.has(cache_key):
		return cache[cache_key]

	var out := StandardMaterial3D.new()
	out.resource_name = src_mat.resource_name if src_mat != null else "BaseMaterial"
	out.vertex_color_use_as_albedo = true
	out.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	if src_mat is StandardMaterial3D:
		var sm := src_mat as StandardMaterial3D
		out.albedo_color = sm.albedo_color
		out.albedo_texture = sm.albedo_texture
		out.roughness = sm.roughness
	elif src_mat is ShaderMaterial:
		var sh := src_mat as ShaderMaterial
		var col = sh.get_shader_parameter("base_color")
		if col is Color: out.albedo_color = col
		var tex = sh.get_shader_parameter("base_texture")
		if tex is Texture2D: out.albedo_texture = tex
		var r = sh.get_shader_parameter("roughness")
		if r is float: out.roughness = r
	else:
		out.albedo_color = Color(0.8, 0.8, 0.8, 1.0)
		out.roughness = 0.8

	if out.albedo_texture != null:
		out.albedo_texture = enforce_pot_texture(out.albedo_texture, max_size)

	cache[cache_key] = out
	return out
static func _extract_base_image(src_mat: Material, paint_state: Dictionary) -> Image:
	var tex: Texture2D = null
	var path: String = paint_state.get("base_texture_path", "")
	if not path.is_empty() and ResourceLoader.exists(path):
		tex = load(path)
	elif src_mat is StandardMaterial3D and (src_mat as StandardMaterial3D).albedo_texture != null:
		tex = (src_mat as StandardMaterial3D).albedo_texture
	elif src_mat is ShaderMaterial:
		var st = (src_mat as ShaderMaterial).get_shader_parameter("base_texture")
		if st is Texture2D: tex = st

	if tex != null:
		var img := tex.get_image()
		if img != null:
			if img.is_compressed():
				img.decompress()
			return img
	return null

static func _extract_base_color(src_mat: Material, paint_state: Dictionary) -> Color:
	if paint_state.has("base_color") and paint_state["base_color"] is Color:
		return paint_state["base_color"]
	if src_mat is StandardMaterial3D:
		return (src_mat as StandardMaterial3D).albedo_color
	elif src_mat is ShaderMaterial:
		var c = (src_mat as ShaderMaterial).get_shader_parameter("base_color")
		if c is Color: return c
	return Color.WHITE

static func _prepare_layer_data(paint_state: Dictionary) -> Array:
	var out: Array = []
	for layer in paint_state.get("layers", []):
		var path: String = layer.get("texture_path", "")
		var mask: Image = layer.get("mask_image")
		if path.is_empty() or mask == null or not ResourceLoader.exists(path):
			continue
		var tex: Texture2D = load(path)
		if tex == null:
			continue
		var img := tex.get_image()
		if img == null:
			continue
		if img.is_compressed():
			img.decompress()
		if mask.is_compressed():
			mask.decompress()
		out.append({
			"image": img,
			"mask_image": mask,
			"color": layer.get("color", Color.WHITE),
		})
	return out

static func _prepare_stamp_data(face_stamps: Array) -> Array:
	var out: Array = []
	for s in face_stamps:
		var path: String = s.get("texture_path", "")
		if path.is_empty() or not ResourceLoader.exists(path):
			continue
		var tex: Texture2D = load(path)
		if tex == null:
			continue
		var img := tex.get_image()
		if img == null:
			continue
		if img.is_compressed():
			img.decompress()
		var entry := {
			"image": img,
			"anchor_center": s.get("anchor_center", Vector2.ZERO),
			"anchor_du": s.get("anchor_du", Vector2.RIGHT),
			"anchor_dv": s.get("anchor_dv", Vector2.UP),
			"opacity": s.get("opacity", 1.0),
		}
		if s.has("anchor_u") and s.has("anchor_v"):
			entry["anchor_u"] = s["anchor_u"]
			entry["anchor_v"] = s["anchor_v"]
			entry["anchor_scale_x"] = s.get("anchor_scale_x", 1.0)
			entry["anchor_scale_y"] = s.get("anchor_scale_y", 1.0)
			entry["anchor_rot_right"] = s.get("anchor_rot_right", Vector3.RIGHT)
			entry["anchor_rot_up"] = s.get("anchor_rot_up", Vector3.UP)
		out.append(entry)
	return out

static func _stamp_touches_rect(sd: Dictionary, rect: Rect2) -> bool:
	if sd.has("anchor_u") and sd.has("anchor_v"):
		var uc: float = sd["anchor_u"]
		var vc: float = sd["anchor_v"]
		var hx: float = sd.get("anchor_scale_x", 1.0) * 0.5
		var hy: float = sd.get("anchor_scale_y", 1.0) * 0.5
		var stamp_rect := Rect2(uc - hx, vc - hy, hx * 2.0, hy * 2.0)
		return stamp_rect.intersects(rect)

	var center: Vector2 = sd.get("anchor_center", Vector2.ZERO)
	var du: Vector2 = sd.get("anchor_du", Vector2.RIGHT)
	var dv: Vector2 = sd.get("anchor_dv", Vector2.UP)
	# Bounding box of the stamp quad
	var p0 := center - du - dv
	var p1 := center + du - dv
	var p2 := center + du + dv
	var p3 := center - du + dv

	var s_min_x := minf(p0.x, minf(p1.x, minf(p2.x, p3.x)))
	var s_max_x := maxf(p0.x, maxf(p1.x, maxf(p2.x, p3.x)))
	var s_min_y := minf(p0.y, minf(p1.y, minf(p2.y, p3.y)))
	var s_max_y := maxf(p0.y, maxf(p1.y, maxf(p2.y, p3.y)))

	var stamp_rect := Rect2(s_min_x, s_min_y, s_max_x - s_min_x, s_max_y - s_min_y)
	return stamp_rect.intersects(rect)

static func _mask_touches_rect(mask: Image, splat_bounds: PackedFloat32Array, rect: Rect2) -> bool:
	if mask == null or splat_bounds.size() != 4:
		return false

	var su_min: float = splat_bounds[0]
	var su_max: float = splat_bounds[1]
	var sv_min: float = splat_bounds[2]
	var sv_max: float = splat_bounds[3]
	var span_u: float = maxf(su_max - su_min, 0.0001)
	var span_v: float = maxf(sv_max - sv_min, 0.0001)

	var splat_rect := Rect2(su_min, sv_min, span_u, span_v)
	if not splat_rect.intersects(rect):
		return false
	var mw := mask.get_width()
	var mh := mask.get_height()

	var px0 := clampi(int((rect.position.x - su_min) / span_u * mw), 0, mw - 1)
	var px1 := clampi(int((rect.position.x + rect.size.x - su_min) / span_u * mw), 0, mw - 1)
	var py0 := clampi(int((rect.position.y - sv_min) / span_v * mh), 0, mh - 1)
	var py1 := clampi(int((rect.position.y + rect.size.y - sv_min) / span_v * mh), 0, mh - 1)

	if px0 > px1:
		var t := px0; px0 = px1; px1 = t
	if py0 > py1:
		var t := py0; py0 = py1; py1 = t

	# Sample pixels in bounds (step for speed if area is large)
	var step_x := maxi(1, (px1 - px0) / 32)
	var step_y := maxi(1, (py1 - py0) / 32)

	for py in range(py0, py1 + 1, step_y):
		for px in range(px0, px1 + 1, step_x):
			if mask.get_pixel(px, py).r > 0.01:
				return true
	return false
