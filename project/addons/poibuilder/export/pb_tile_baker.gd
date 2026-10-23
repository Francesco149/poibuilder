## PBTileBaker — Bakes texture splatting and decals into textures.
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

	# A scrolling face keeps its base material and standalone texture: the
	# animation moves the texture coordinates, and a baked tile lives at fixed
	# slot coordinates inside an atlas, where an offset would drag it across
	# the slot border. It also means the moving texture cannot carry paint.
	#
	# A non-opaque face (cutout or blended) keeps its base material for the same
	# structural reason: a baked tile is an opaque 5551 crop of the composite,
	# which cannot express either a cutout silhouette or a soft alpha.
	if PBUv.has_scroll(src_mat) or _is_non_opaque(src_mat):
		for frag in fragments:
			result.tile_materials[frag] = base_mat
		return result

	# Collect the face's paint state: blend layers plus the decal layer (which
	# holds every pasted stamp and decal-brush pixel as an image).
	var paint_state := PBSplat.collect_face_paint_state(mesh_data, face)
	var layers_list: Array = paint_state.get("layers", [])
	var decal_image: Image = paint_state.get("decal_layer_image", null)
	# The decal image is a WINDOW inside the face's mask rect (uniform density
	# on large faces), so every decal lookup goes through its rect.
	var decal_window: Rect2 = paint_state.get("decal_window", Rect2(0.0, 0.0, 1.0, 1.0))
	var has_paint: bool = not paint_state.is_empty() and (not layers_list.is_empty() or decal_image != null)

	# If this face has no paint at all, every fragment reuses the base material
	if not has_paint:
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

		# Check if the decal layer has pixels in this tile
		if decal_image != null and splat_bounds.size() == 4 \
				and _decal_touches_rect(decal_image, decal_window, splat_bounds, cell_rect_obj):
			tile_has_paint = true

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
				base_image, base_color, layer_data, decal_image, decal_window,
				tile_resolution, anchor_offset)
			var tile_tex := ImageTexture.create_from_image(composite)
			# The retro engine keys its painted-tile policy off this name: a
			# texture called "TileAtlas*" is sampled with GU_CLAMP (a tile
			# samples its own slot, so LINEAR must never blend the opposite
			# edge into it — with GU_REPEAT every tile edge shows a fringe of
			# the tile's opposite side) and gets the pinned-mip detail LOD
			# (per-primitive levels step in sharpness at tile boundaries).
			# The old atlas exporter used the same convention (the GLB->PBM
			# converter still does); the per-tile bake must carry it too.
			tile_tex.resource_name = "TileAtlas_%d_%d_%d" % [face_idx, frag.cell_coord.x, frag.cell_coord.y]
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
		base_image: Image, base_color: Color, layer_data: Array, decal_image: Image,
		decal_window: Rect2, resolution: int, anchor_offset: Vector2 = Vector2.ZERO) -> Image:
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

	# Step 1: Base layer fill / sample.
	# All sampling below uses TEXEL CENTERS: pixel i covers [i/res, (i+1)/res)
	# of the cell, so the sample point is (i+0.5)/res — matching how the GPU
	# interpolates the tile quad's [0,1] UVs. The old endpoint mapping
	# (i/(res-1), round(u*(w-1))) put the cell's edge coordinates exactly ON
	# the first/last texels, which duplicated the boundary content into BOTH
	# adjacent tiles and smeared the stamp's border / checker edges one texel
	# across every tile line — the visible "grid" around splats and stamps in
	# exports. Image lookups use floor(u * size) clamped, so a lookup never
	# lands ON a boundary coordinate.
	var res_n := maxf(float(resolution), 2.0)
	for y in range(resolution):
		var ty := (float(y) + 0.5) / res_n
		var pv := lerpf(v0, v1, ty)
		var uv_v := wrapf(pv, 0.0, 1.0)
		var base_py := clampi(int(uv_v * float(base_h)), 0, base_h - 1) if base_h > 0 else 0

		for x in range(resolution):
			var tx := (float(x) + 0.5) / res_n
			var pu := lerpf(u0, u1, tx)
			var uv_u := wrapf(pu, 0.0, 1.0)
			var c := base_color
			if base_image != null:
				var base_px := clampi(int(uv_u * float(base_w)), 0, base_w - 1)
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

				# Bilinear, not nearest: the live mask is a fixed 256 square
				# while a retro tile is drawn at the tile resolution, so a
				# nearest read would print mask texel blocks across the tile.
				var weight := _sample_mask_bilinear(mask, mu, mv)

				if weight > 0.001:
					var lw := l_img.get_width()
					var lh := l_img.get_height()
					var lpx := clampi(int(uv_u * float(lw)), 0, lw - 1)
					var lpy := clampi(int(uv_v * float(lh)), 0, lh - 1)
					var l_pixel := l_img.get_pixel(lpx, lpy) * l_col
					c = c.lerp(l_pixel, clampf(weight * l_col.a, 0.0, 1.0))
			# Step 3: decal layer — pasted stamps and decal painting, stored as
			# pixels in the face's planar [0,1] mask space but IMAGE-CROPPED to
			# the painted window (decal_window maps one onto the other).
			if decal_image != null:
				var dpu := pu + anchor_offset.x
				var dpv := pv + anchor_offset.y
				var dmu := ((dpu - splat_min_u) / splat_span_u - decal_window.position.x) / decal_window.size.x
				var dmv := ((dpv - splat_min_v) / splat_span_v - decal_window.position.y) / decal_window.size.y
				if dmu >= 0.0 and dmu <= 1.0 and dmv >= 0.0 and dmv <= 1.0:
					var dw := decal_image.get_width()
					var dh := decal_image.get_height()
					var dpx := clampi(int(dmu * float(dw)), 0, dw - 1)
					var dpy := clampi(int(dmv * float(dh)), 0, dh - 1)
					var d_col := decal_image.get_pixel(dpx, dpy)
					if d_col.a > 0.001:
						c = Color(
							c.r + (d_col.r - c.r) * d_col.a,
							c.g + (d_col.g - c.g) * d_col.a,
							c.b + (d_col.b - c.b) * d_col.a,
							c.a)
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
	if src_mat == null:
		src_mat = PBMeshData.get_default_material()
	var cache_key = src_mat if src_mat != null else "null_default"
	if cache.has(cache_key):
		return cache[cache_key]

	var out := StandardMaterial3D.new()
	out.resource_name = src_mat.resource_name if src_mat != null else "BaseMaterial"
	out.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	if src_mat is StandardMaterial3D:
		var sm := src_mat as StandardMaterial3D
		out.albedo_color = sm.albedo_color
		out.albedo_texture = sm.albedo_texture
		out.roughness = sm.roughness
		# The transparency mode is what the retro exporters map to a texture's
		# alpha handling (cutout vs soft blend), so it has to survive this copy.
		out.transparency = sm.transparency
		out.alpha_scissor_threshold = sm.alpha_scissor_threshold
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

	# Carry the animated-UV scroll across the copy: it is what the retro
	# exporters read to emit the per-mesh scroll speed, and what the glTF
	# writer serializes into the material's `extras` for the GLB pipeline.
	var scroll := PBUv.get_scroll_speed(src_mat)
	if scroll != Vector2.ZERO:
		PBUv.set_scroll_speed(out, scroll)

	cache[cache_key] = out
	return out
## True when the material draws with transparency — a baked tile is opaque.
static func _is_non_opaque(mat: Material) -> bool:
	if mat is StandardMaterial3D:
		return (mat as StandardMaterial3D).transparency != BaseMaterial3D.TRANSPARENCY_DISABLED
	return false

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
		var mask: Image = layer.get("mask_image")
		# Prefer the texture instance carried by the paint state; the path is
		# only a fallback. Pathless runtime textures (procedural paint sources)
		# used to be dropped here, silently baking every tile unpainted.
		var tex: Texture2D = layer.get("texture")
		if tex == null:
			var path: String = layer.get("texture_path", "")
			if not path.is_empty() and ResourceLoader.exists(path):
				tex = load(path) as Texture2D
		if tex == null or mask == null:
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
			# The live shader widens a layer's blend edge with its roughness;
			# dropping it here baked every layer at the 0.8 default.
			"roughness": layer.get("roughness", 0.8),
		})
	return out

## True when the decal layer has any opaque pixel inside `rect` (object-space
## tile bounds), sampled through the same planar + window mapping the baker uses.
static func _decal_touches_rect(decal: Image, decal_window: Rect2,
		splat_bounds: PackedFloat32Array, rect: Rect2) -> bool:
	if decal == null or splat_bounds.size() != 4:
		return false
	var su_min: float = splat_bounds[0]
	var sv_min: float = splat_bounds[2]
	var span_u: float = maxf(splat_bounds[1] - su_min, 0.0001)
	var span_v: float = maxf(splat_bounds[3] - sv_min, 0.0001)
	# The decal window in object space; a tile outside it has no decal (the
	# clamped pixel window below would otherwise sample the window's edge).
	var win_rect := Rect2(
		su_min + decal_window.position.x * span_u, sv_min + decal_window.position.y * span_v,
		decal_window.size.x * span_u, decal_window.size.y * span_v)
	if not win_rect.intersects(rect):
		return false

	var w := decal.get_width()
	var h := decal.get_height()
	var px0 := clampi(int(((rect.position.x - su_min) / span_u - decal_window.position.x) / decal_window.size.x * w), 0, w - 1)
	var px1 := clampi(int(((rect.position.x + rect.size.x - su_min) / span_u - decal_window.position.x) / decal_window.size.x * w), 0, w - 1)
	var py0 := clampi(int(((rect.position.y - sv_min) / span_v - decal_window.position.y) / decal_window.size.y * h), 0, h - 1)
	var py1 := clampi(int(((rect.position.y + rect.size.y - sv_min) / span_v - decal_window.position.y) / decal_window.size.y * h), 0, h - 1)
	if px0 > px1:
		var t := px0; px0 = px1; px1 = t
	if py0 > py1:
		var t := py0; py0 = py1; py1 = t

	var step_x := maxi(1, (px1 - px0) / 32)
	var step_y := maxi(1, (py1 - py0) / 32)
	for py in range(py0, py1 + 1, step_y):
		for px in range(px0, px1 + 1, step_x):
			if decal.get_pixel(px, py).a > 0.01:
				return true
	return false


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

# ==============================================================================
# In-Place Bake (lightmap switch)
# ==============================================================================

## Bakes a PBMesh's splat paint and stamps into ordinary tile textures and
## rewrites the mesh data in place, exactly like the retro export bake but
## applied to the live PBMesh instead of a throwaway export copy. After this:
##   - every face carries a plain StandardMaterial3D (base look or baked tile),
##   - `splat_bounds` and splat materials are gone, `textures1` is empty —
##     so UV2 is free for a LightmapGI unwrap (Godot also auto-generates UV2
##     at bake time),
##   - all faces are marked `manual_uv` (baked atlas coordinates survive).
## The mesh stays an editable PBMesh (grid-cell faces, like the retro bake).
## Geometry rewrites UV1 into tile slots — that is the point; do not call it
## on meshes whose authored UV1 unwrap must survive unpainted.
## Returns a report Dictionary: {ok, had_splat, faces, materials, baked_textures}.
static func bake_pb_mesh_in_place(pb: PBMesh, grid_size: float = 1.0,
		tile_resolution: int = 128, max_texture_size: int = 512) -> Dictionary:
	var report := {"ok": false, "had_splat": false, "faces": 0, "materials": 0, "baked_textures": 0}
	if pb == null or pb.pb_mesh_data == null:
		return report
	var mesh_data := pb.pb_mesh_data

	var had_splat := false
	for f in mesh_data.faces:
		if f != null and f.splat_bounds.size() == 4:
			had_splat = true
			break
	if not had_splat:
		for mat in mesh_data.materials:
			if mat != null and PBSplat.is_splat_material(mat):
				had_splat = true
				break
	report["had_splat"] = had_splat
	if not had_splat:
		report["ok"] = true
		return report

	var base_material_cache: Dictionary = {}
	var all_textures: Array[Texture2D] = []

	# Flat accumulation buffers. Fragments arrive in Godot CW-front index
	# order with per-fragment local indices; everything is rebased into one
	# global vertex pool plus a per-vertex material slot id, then regrouped
	# per material slot at the end (plain typed locals — packed arrays
	# mutated through Dictionary fetches are lost to copy-on-write).
	var mat_order: Array[Material] = []
	var all_positions := PackedVector3Array()
	var all_normals := PackedVector3Array()
	var all_uvs := PackedVector2Array()
	var all_indices := PackedInt32Array()
	var all_mat_slot := PackedInt32Array()

	for fi in range(mesh_data.faces.size()):
		var face := mesh_data.faces[fi]
		if face == null or face.get_indexes().is_empty():
			continue

		var frags := PBFaceSubdivider.subdivide_face(mesh_data, face, fi, true, grid_size)
		var baked := bake_face_tiles(pb, mesh_data, face, fi, frags, true, tile_resolution,
				base_material_cache, max_texture_size)
		all_textures.append_array(baked.baked_textures)

		for frag in frags:
			var mat: Material = baked.tile_materials.get(frag, null)
			if mat == null:
				mat = _get_or_create_base_material(mesh_data.get_face_material(face), base_material_cache, max_texture_size)
			var slot := mat_order.find(mat)
			if slot < 0:
				mat_order.append(mat)
				slot = mat_order.size() - 1
			var base_idx := all_positions.size()
			all_positions.append_array(frag.positions)
			all_normals.append_array(frag.normals)
			all_uvs.append_array(frag.uvs)
			for v in range(frag.positions.size()):
				all_mat_slot.append(slot)
			for idx in frag.indices:
				all_indices.append(base_idx + idx)

	if mat_order.is_empty():
		return report

	# Rebuild the mesh data from the baked fragments: per-slot index buffers,
	# one PBFace per triangle, all referencing the global vertex pool.
	var idx_by_slot: Array[PackedInt32Array] = []
	idx_by_slot.resize(mat_order.size())
	for slot in range(mat_order.size()):
		idx_by_slot[slot] = PackedInt32Array()
	for i in range(all_indices.size()):
		idx_by_slot[all_mat_slot[all_indices[i]]].append(all_indices[i])

	var new_faces: Array[PBFace] = []
	for slot in range(mat_order.size()):
		var idx: PackedInt32Array = idx_by_slot[slot]
		for i in range(0, idx.size() - 2, 3):
			# Baked fragments are in Godot CW-front order; flip each triangle
			# to the internal CCW convention like poibuilderize does.
			var new_face := PBFace.new()
			new_face.set_indexes(PackedInt32Array([idx[i + 2], idx[i + 1], idx[i]]))
			new_face.submesh_index = slot
			new_face.manual_uv = true
			new_faces.append(new_face)
	var new_positions := all_positions
	var new_normals := all_normals
	var new_uvs := all_uvs

	# Fragment vertices are fresh (Position-Privacy), so source tangents and
	# vertex colors no longer line up — drop them; baked tiles are albedo-only.
	mesh_data.tangents = PackedFloat32Array()
	mesh_data.colors = PackedColorArray()
	# Only the splat data goes: the mask coordinates are derived and the splat
	# materials are replaced by baked tiles. UV2 was never the splat system's
	# to clear — an authored lightmap unwrap survives this bake.
	mesh_data.splat_uvs = PackedVector2Array()
	mesh_data.positions = new_positions
	mesh_data.textures0 = new_uvs
	mesh_data.faces = new_faces
	var mats: Array[Material] = []
	mats.assign(mat_order)
	mesh_data.materials = mats

	mesh_data.invalidate_caches()
	mesh_data.rebuild_welds()
	if not mesh_data.set_authored_normals(new_normals):
		mesh_data.calculate_normals()
	mesh_data.shape_edited = true

	pb.rebuild()

	report["ok"] = true
	report["faces"] = new_faces.size()
	report["materials"] = mat_order.size()
	report["baked_textures"] = all_textures.size()
	return report

# ==============================================================================
# Modern (per-face) Bake
# ==============================================================================

## Bakes a face's full paint stack into ONE texture laid out in mask space
## (face-planar [0,1], the same space the masks and the decal layer live in).
## This is what a modern .glb export ships when the author picks "bake paint":
## the receiving engine needs no shader of ours — the face samples the texture
## with its (rewritten) UV1, exactly like any other baked surface.
##
## Resolution follows the BAKE policy (256 texels/m of the face's world size,
## clamped 256..min(max_size, MAX_RESOLUTION)) — NOT the live mask, which is a
## fixed square chosen to bound per-dab cost. That inversion is the whole point
## of the split: a 20 m face paints on a 256x256 mask but bakes at 2048, and
## the blend mask is upsampled to meet it, while the base texture and the decal
## layer composite natively at the bake resolution.
static func bake_face_composite(mesh_data: PBMeshData, face: PBFace, max_size: int = 2048) -> Image:
	if mesh_data == null or face == null:
		return null
	var paint_state := PBSplat.collect_face_paint_state(mesh_data, face)
	if paint_state.is_empty():
		return null

	var res := PBSplat.bake_resolution(mesh_data, face, max_size)

	var base_image: Image = _extract_base_image(mesh_data.get_face_material(face), paint_state)
	var base_color: Color = _extract_base_color(mesh_data.get_face_material(face), paint_state)
	var layer_data: Array = _prepare_layer_data(paint_state)
	var decal_image: Image = paint_state.get("decal_layer_image", null)
	var decal_window: Rect2 = paint_state.get("decal_window", Rect2(0.0, 0.0, 1.0, 1.0))
	var bounds := PBSplat.get_face_planar_bounds(mesh_data, face)
	if bounds.is_empty():
		return null

	var u_axis: Vector3 = bounds["u"]
	var v_axis: Vector3 = bounds["v"]
	var min_u: float = bounds["min_u"]
	var min_v: float = bounds["min_v"]
	var range_u: float = bounds["range_u"]
	var range_v: float = bounds["range_v"]

	# Triangle soup in mask space, each corner carrying its UV1: sampling the
	# base texture this way (instead of assuming a linear UV ramp) keeps n-gons,
	# manual UVs and resized faces correct.
	#
	# A face is PLANAR, so within one triangle the barycentric weights are
	# affine in (mu, mv) and the UV1 is affine with them. The bake therefore
	# precomputes each triangle's affine coefficients ONCE (see
	# the composite loop) and evaluates them per texel, instead of
	# solving a 2x2 system per texel — measured 12x on that term, which
	# dominated a 2048x2048 bake.
	var tri_a := PackedVector2Array()
	var tri_b := PackedVector2Array()
	var tri_c := PackedVector2Array()
	var tri_uv := PackedVector2Array()
	var idxs := face.get_indexes()
	for tri_i in range(0, idxs.size() - 2, 3):
		var ok := true
		var pu := PackedFloat32Array()
		var pv := PackedFloat32Array()
		var puv := PackedVector2Array()
		for k in range(3):
			var vi: int = idxs[tri_i + k]
			if vi < 0 or vi >= mesh_data.positions.size():
				ok = false
				break
			var p: Vector3 = mesh_data.positions[vi]
			pu.append((u_axis.dot(p) - min_u) / range_u)
			pv.append((v_axis.dot(p) - min_v) / range_v)
			puv.append(mesh_data.textures0[vi] if vi < mesh_data.textures0.size() else Vector2.ZERO)
		if not ok:
			continue
		var den := (pu[1] - pu[0]) * (pv[2] - pv[0]) - (pv[1] - pv[0]) * (pu[2] - pu[0])
		if absf(den) < 1e-12:
			continue
		# Affine fit of (wb, wc) over (mu, mv), taken from the REFERENCE
		# formula evaluated at three points, so this can never drift from the
		# barycentric definition:  f(mu, mv) = C + A*mu + B*mv.
		var w_00 := _bake_weights(pu, pv, 0.0, 0.0)
		var a_w := _bake_weights(pu, pv, 1.0, 0.0) - w_00
		var b_w := _bake_weights(pu, pv, 0.0, 1.0) - w_00
		tri_a.append(a_w)
		tri_b.append(b_w)
		tri_c.append(w_00)
		tri_uv.append_array(puv)
	if tri_uv.is_empty():
		return null

	# The composite runs on RAW BYTES: one get_pixel() per base texel, four per
	# layer mask and one set_pixel() per output texel were most of a 2048x2048
	# bake (22.7 s for an 8 m face). Reads go through BAKE_BYTE_TO_FLOAT, the
	# exact float32 value Image.get_pixel() produces for a byte, and writes
	# repeat Image.set_pixel()'s conversion, so the output is byte-identical
	# to the per-pixel version it replaced (pinned by the tile-baker tests).
	var lut := _byte_to_float_lut()
	var w_out := res.x
	var out_b := PackedByteArray()
	out_b.resize(w_out * res.y * 4)

	var base_b := PackedByteArray()
	var base_w := 0
	var base_h := 0
	if base_image != null and not base_image.is_empty():
		var bi := _rgba8_copy(base_image)
		base_b = bi.get_data()
		base_w = bi.get_width()
		base_h = bi.get_height()
	var has_base := base_w > 0 and base_h > 0

	# Flatten the layer stack once, and find where each layer can contribute:
	# outside the bounding box of its mask's nonzero texels (padded by the
	# bilinear footprint) its weight is 0, so its smoothstep blend is 0 and the
	# layer is skipped — exactly what the per-pixel test did, without the work.
	var layer_masks: Array[PackedByteArray] = []
	var layer_mask_size: Array[Vector2i] = []
	var layer_imgs: Array[PackedByteArray] = []
	var layer_img_size: Array[Vector2i] = []
	var layer_cols: PackedColorArray = PackedColorArray()
	var layer_edge: PackedFloat32Array = PackedFloat32Array()
	var layer_box: Array[Rect2i] = []  # output-pixel rect the layer may touch
	for ld in layer_data:
		var mask: Image = ld.get("mask_image")
		var l_img: Image = ld.get("image")
		if mask == null or l_img == null or mask.is_empty() or l_img.is_empty():
			continue
		var mask_r8 := mask
		if mask.get_format() != Image.FORMAT_R8:
			mask_r8 = Image.new()
			mask_r8.copy_from(mask)
			mask_r8.convert(Image.FORMAT_R8)
		var mb := mask_r8.get_data()
		var mw := mask_r8.get_width()
		var mh := mask_r8.get_height()
		var used := _nonzero_texel_rect(mb, mw, mh)
		if used.size.x <= 0:
			continue  # an empty mask contributes nowhere
		var limg := _rgba8_copy(l_img)
		var fw: float = 1.5 / float(mw)
		layer_masks.append(mb)
		layer_mask_size.append(Vector2i(mw, mh))
		layer_imgs.append(limg.get_data())
		layer_img_size.append(Vector2i(limg.get_width(), limg.get_height()))
		layer_cols.append(ld.get("color", Color.WHITE))
		layer_edge.append(lerpf(maxf(fw * 2.0, 0.02), 0.48, float(ld.get("roughness", 0.8))))
		# Mask texel t covers bilinear sample positions within one texel of
		# its centre; map that span to output pixels with a one-pixel margin.
		var x0 := int(floor((float(used.position.x) - 1.0) / float(mw) * float(res.x))) - 1
		var x1 := int(ceil((float(used.end.x) + 1.0) / float(mw) * float(res.x))) + 1
		var y0 := int(floor((float(used.position.y) - 1.0) / float(mh) * float(res.y))) - 1
		var y1 := int(ceil((float(used.end.y) + 1.0) / float(mh) * float(res.y))) + 1
		layer_box.append(Rect2i(x0, y0, x1 - x0, y1 - y0))

	var decal_b := PackedByteArray()
	var decal_w := 0
	var decal_h := 0
	if decal_image != null and not decal_image.is_empty():
		var di := _rgba8_copy(decal_image)
		decal_b = di.get_data()
		decal_w = di.get_width()
		decal_h = di.get_height()

	# The out image is square in practice, but res.x/res.y are independent; the
	# sample coordinates must each use their OWN axis count.
	var inv_out_u := 1.0 / maxf(float(res.x), 1.0)
	var inv_out_v := 1.0 / maxf(float(res.y), 1.0)
	var decal_win_pos := decal_window.position
	var decal_win_size := decal_window.size
	var has_decal := decal_w > 0
	var layer_count := layer_masks.size()
	var tri_count := tri_uv.size() / 3

	for y in range(res.y):
		var mv := (float(y) + 0.5) * inv_out_v
		var decal_dv := (mv - decal_win_pos.y) / decal_win_size.y
		var row_layers: Array[int] = []
		for li in range(layer_count):
			if y >= layer_box[li].position.y and y < layer_box[li].end.y:
				row_layers.append(li)
		var o := y * w_out * 4
		for x in range(res.x):
			var mu := (float(x) + 0.5) * inv_out_u
			# UV1 at this mask-space point: the first triangle containing it
			# (weights within -0.001), NaN outside the face.
			var uv1 := Vector2(NAN, NAN)
			for t in range(tri_count):
				var ta := tri_a[t]
				var tb := tri_b[t]
				var tc := tri_c[t]
				var wb := ta.x * mu + tb.x * mv + tc.x
				if wb < -0.001:
					continue
				var wc := ta.y * mu + tb.y * mv + tc.y
				if wc < -0.001:
					continue
				var wa := 1.0 - wb - wc
				if wa < -0.001:
					continue
				var ti := t * 3
				uv1 = tri_uv[ti] * wa + tri_uv[ti + 1] * wb + tri_uv[ti + 2] * wc
				break
			var inside := uv1.x == uv1.x # NaN (outside the face) is never equal to itself
			var c := base_color
			var base_alpha := 1.0
			if has_base:
				if inside:
					var bo := (posmod(int(floor(uv1.y * base_h)), base_h) * base_w
							+ posmod(int(floor(uv1.x * base_w)), base_w)) * 4
					c = Color(lut[base_b[bo]], lut[base_b[bo + 1]], lut[base_b[bo + 2]], lut[base_b[bo + 3]]) * base_color
					base_alpha = c.a
				else:
					base_alpha = base_color.a

			var decal_du := (mu - decal_win_pos.x) / decal_win_size.x
			for li in row_layers:
				if x < layer_box[li].position.x or x >= layer_box[li].end.x:
					continue
				var msize: Vector2i = layer_mask_size[li]
				var weight := _mask_bilinear_bytes(layer_masks[li], msize.x, msize.y, mu, mv, lut)
				var edge_w: float = layer_edge[li]
				var blend := smoothstep(0.5 - edge_w, 0.5 + edge_w, weight)
				if blend <= 0.0:
					continue
				var l_col: Color = layer_cols[li]
				var isize: Vector2i = layer_img_size[li]
				var lb: PackedByteArray = layer_imgs[li]
				var lo := (posmod(int(floor(uv1.y * isize.y)), isize.y) * isize.x
						+ posmod(int(floor(uv1.x * isize.x)), isize.x)) * 4
				var layer_col := Color(lut[lb[lo]], lut[lb[lo + 1]], lut[lb[lo + 2]], lut[lb[lo + 3]]) * l_col
				var a: float = blend * layer_col.a
				c = Color(
					c.r + (layer_col.r - c.r) * a,
					c.g + (layer_col.g - c.g) * a,
					c.b + (layer_col.b - c.b) * a,
					c.a)

			if has_decal and decal_du >= 0.0 and decal_du <= 1.0 \
					and decal_dv >= 0.0 and decal_dv <= 1.0:
				var do_ := (clampi(int(floor(decal_dv * decal_h)), 0, decal_h - 1) * decal_w
						+ clampi(int(floor(decal_du * decal_w)), 0, decal_w - 1)) * 4
				var d_col := Color(lut[decal_b[do_]], lut[decal_b[do_ + 1]], lut[decal_b[do_ + 2]], lut[decal_b[do_ + 3]])
				if d_col.a > 0.001:
					c = Color(
						c.r + (d_col.r - c.r) * d_col.a,
						c.g + (d_col.g - c.g) * d_col.a,
						c.b + (d_col.b - c.b) * d_col.a,
						maxf(c.a, d_col.a))
			c.a = maxf(c.a, base_alpha)
			# Image.set_pixel's RGBA8 conversion: truncate(clamp(v * 255)).
			out_b[o] = int(clampf(c.r * 255.0, 0.0, 255.0))
			out_b[o + 1] = int(clampf(c.g * 255.0, 0.0, 255.0))
			out_b[o + 2] = int(clampf(c.b * 255.0, 0.0, 255.0))
			out_b[o + 3] = int(clampf(c.a * 255.0, 0.0, 255.0))
			o += 4
	var out := Image.create_from_data(res.x, res.y, false, Image.FORMAT_RGBA8, out_b)
	return out

## byte -> the float32 Image.get_pixel() returns for it (byte / 255.0 rounded
## to float32), as a 256-entry table the raw-byte bake reads through.
static var _bake_lut: PackedFloat32Array = PackedFloat32Array()

static func _byte_to_float_lut() -> PackedFloat32Array:
	if _bake_lut.size() != 256:
		_bake_lut.resize(256)
		for i in range(256):
			_bake_lut[i] = float(i) / 255.0
	return _bake_lut

## An RGBA8 copy of `img` (the same pixels get_pixel() would read).
static func _rgba8_copy(img: Image) -> Image:
	if img.get_format() == Image.FORMAT_RGBA8 and not img.has_mipmaps():
		return img
	var copy := Image.new()
	copy.copy_from(img)
	if copy.has_mipmaps():
		copy.clear_mipmaps()
	copy.convert(Image.FORMAT_RGBA8)
	return copy

## The bounding rect of a single-channel buffer's nonzero texels (size 0 when
## all are zero). Empty rows are found by a C++ count, so mostly-unpainted
## masks cost little.
static func _nonzero_texel_rect(bytes: PackedByteArray, w: int, h: int) -> Rect2i:
	var x0 := w
	var x1 := -1
	var y0 := h
	var y1 := -1
	for y in range(h):
		var row := bytes.slice(y * w, (y + 1) * w)
		if row.count(0) == w:
			continue
		y0 = mini(y0, y)
		y1 = y
		for x in range(w):
			if row[x] != 0:
				x0 = mini(x0, x)
				break
		for x in range(w - 1, -1, -1):
			if row[x] != 0:
				x1 = maxi(x1, x)
				break
	if y1 < 0:
		return Rect2i()
	return Rect2i(x0, y0, x1 - x0 + 1, y1 - y0 + 1)

## _sample_mask_bilinear on a raw R8 buffer (same arithmetic; texel values
## through the get_pixel-exact table).
static func _mask_bilinear_bytes(mask: PackedByteArray, w: int, h: int, u: float, v: float,
		lut: PackedFloat32Array) -> float:
	var fx := u * float(w) - 0.5
	var fy := v * float(h) - 0.5
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	var x0c := clampi(x0, 0, w - 1)
	var x1c := clampi(x0 + 1, 0, w - 1)
	var y0c := clampi(y0, 0, h - 1)
	var y1c := clampi(y0 + 1, 0, h - 1)
	var r0: float = lut[mask[y0c * w + x0c]]
	var r1: float = lut[mask[y0c * w + x1c]]
	var r2: float = lut[mask[y1c * w + x0c]]
	var r3: float = lut[mask[y1c * w + x1c]]
	var top := r0 + (r1 - r0) * tx
	var bot := r2 + (r3 - r2) * tx
	return top + (bot - top) * ty

## Wrapped/clamped pixel reads (the base and layer textures tile, masks and the
## decal layer do not).
static func _sample_image_repeat(img: Image, u: float, v: float) -> Color:
	if img == null or img.is_empty():
		return Color.WHITE
	return img.get_pixel(
			posmod(int(floor(u * img.get_width())), img.get_width()),
			posmod(int(floor(v * img.get_height())), img.get_height()))

static func _sample_image_clamp(img: Image, u: float, v: float) -> Color:
	if img == null or img.is_empty():
		return Color(0, 0, 0, 1)
	return img.get_pixel(
			clampi(int(floor(u * img.get_width())), 0, img.get_width() - 1),
			clampi(int(floor(v * img.get_height())), 0, img.get_height() - 1))

## BILINEAR sample of a single-channel image (a splat mask) at (u, v) in [0, 1],
## clamped at the edges. The live mask is a fixed 256 square while the bake
## runs at up to 2048, so a nearest read would print 8-pixel-wide blocks of
## mask value across the baked blend edge — the mask has to be interpolated to
## meet the bake's resolution. Measured on a 6-texel live ramp upsampled 8x:
## nearest yields 13 distinct levels and 984-px flat runs, bilinear yields 98
## levels (a smooth ramp). Blending is a smoothstep of this weight, so what the
## eye reads at a layer boundary is the ramp, not the mask's texel grid.
static func _sample_mask_bilinear(mask: Image, u: float, v: float) -> float:
	if mask == null or mask.is_empty():
		return 0.0
	var w := mask.get_width()
	var h := mask.get_height()
	var fx := u * float(w) - 0.5
	var fy := v * float(h) - 0.5
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	var x0c := clampi(x0, 0, w - 1)
	var x1c := clampi(x0 + 1, 0, w - 1)
	var y0c := clampi(y0, 0, h - 1)
	var y1c := clampi(y0 + 1, 0, h - 1)
	var r0 := mask.get_pixel(x0c, y0c).r
	var r1 := mask.get_pixel(x1c, y0c).r
	var r2 := mask.get_pixel(x0c, y1c).r
	var r3 := mask.get_pixel(x1c, y1c).r
	var top := r0 + (r1 - r0) * tx
	var bot := r2 + (r3 - r2) * tx
	return top + (bot - top) * ty

## Barycentric weights (of corners 1 and 2) for mask-space point (mu, mv) in the
## triangle whose corners are (pu[i], pv[i]). This is the REFERENCE definition:
## the bake's affine coefficients are a 3-point fit of exactly this function
## (in the composite loop), so the fast path cannot silently diverge from it.
static func _bake_weights(pu: PackedFloat32Array, pv: PackedFloat32Array,
		mu: float, mv: float) -> Vector2:
	var e0x := pu[1] - pu[0]
	var e0y := pv[1] - pv[0]
	var e1x := pu[2] - pu[0]
	var e1y := pv[2] - pv[0]
	var den := e0x * e1y - e0y * e1x
	var rx := mu - pu[0]
	var ry := mv - pv[0]
	return Vector2((rx * e1y - ry * e1x) / den, (ry * e0x - rx * e0y) / den)

