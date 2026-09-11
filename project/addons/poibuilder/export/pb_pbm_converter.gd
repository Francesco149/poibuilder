@tool
class_name PBPbmConverter
extends RefCounted

## PBPbmConverter — Ports the PoiRetro PBMv2 Map Converter with Tile Atlasing to GDScript.
## Converts PoiBuilder exported GLB maps to PBM (PoiBuilder Retro Map) v2.0 binary format.

const PBM_MAGIC := 0x334D4250 # "PBM3"
const PBM_VERSION := 3

const PBM_TEX_FMT_RGBA8888 := 0
const PBM_TEX_FMT_RGBA5551 := 1

## Alpha handling stored per texture (PBM v3). 5551 carries ONE alpha bit, so a
## soft (partial) alpha has to travel as RGBA8888.
const PBM_ALPHA_NONE := 0
const PBM_ALPHA_CUTOUT := 1
const PBM_ALPHA_BLEND := 2
const PBM_TEX_FMT_RGBA4444 := 2
const PBM_TEX_FMT_RGB565   := 3

const PBM_META_RAW    := 0
const PBM_META_STRING := 1
const PBM_META_JSON   := 2
const PBM_META_ENTITY := 3
const PBM_META_EMITTER := 4
const PBM_EMITTER_SIZE := 176

const PBM_ENTITY_PATROL_SPHERE := 1

## Packs the standard "emitters" lump (SPEC_RETRO_FORMAT.md §8). The record
## layout is normative and mirrored byte for byte by the Python oracle
## (retro_engine/pbm_conv.py) — the two converters are expected to agree on the
## whole file, so every field is written at an explicit offset.
static func pack_emitter_lump(records: Array) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(16 + records.size() * PBM_EMITTER_SIZE)
	buf.encode_u32(0, 0x54494D45)
	buf.encode_u32(4, 1)
	buf.encode_u32(8, records.size())
	buf.encode_u32(12, 0)
	var off := 16
	for e in records:
		var name_bytes: PackedByteArray = str(e.get("name", "")).substr(0, 23).to_ascii_buffer()
		for bi in range(name_bytes.size()):
			buf[off + bi] = name_bytes[bi]

		var pos: Array = e.get("pos", [0.0, 0.0, 0.0])
		var dir: Array = e.get("dir", [0.0, 1.0, 0.0])
		var grav: Array = e.get("gravity", [0.0, 0.0, 0.0])
		buf.encode_float(off + 0x18, float(pos[0])); buf.encode_float(off + 0x1C, float(pos[1])); buf.encode_float(off + 0x20, float(pos[2]))
		buf.encode_float(off + 0x24, float(dir[0])); buf.encode_float(off + 0x28, float(dir[1])); buf.encode_float(off + 0x2C, float(dir[2]))
		buf.encode_float(off + 0x30, float(e.get("spread", 0.0)))
		buf.encode_float(off + 0x34, float(e.get("speed_min", 0.0)))
		buf.encode_float(off + 0x38, float(e.get("speed_max", 0.0)))
		buf.encode_float(off + 0x3C, float(e.get("life_min", 0.0)))
		buf.encode_float(off + 0x40, float(e.get("life_max", 0.0)))
		buf.encode_float(off + 0x44, float(grav[0])); buf.encode_float(off + 0x48, float(grav[1])); buf.encode_float(off + 0x4C, float(grav[2]))
		buf.encode_float(off + 0x50, float(e.get("damping", 0.0)))
		buf.encode_float(off + 0x54, float(e.get("size_min", 0.0)))
		buf.encode_float(off + 0x58, float(e.get("size_max", 0.0)))
		buf.encode_float(off + 0x5C, float(e.get("size_mid", 1.0)))
		buf.encode_float(off + 0x60, float(e.get("size_end", 1.0)))
		buf.encode_float(off + 0x64, float(e.get("aspect", 1.0)))
		buf.encode_float(off + 0x68, float(e.get("angle_min", 0.0)))
		buf.encode_float(off + 0x6C, float(e.get("angle_max", 0.0)))
		buf.encode_float(off + 0x70, float(e.get("spin_min", 0.0)))
		buf.encode_float(off + 0x74, float(e.get("spin_max", 0.0)))
		buf.encode_float(off + 0x78, float(e.get("wobble_amp", 0.0)))
		buf.encode_float(off + 0x7C, float(e.get("wobble_freq", 0.0)))
		buf.encode_float(off + 0x80, float(e.get("spawn_radius", 0.0)))
		buf.encode_float(off + 0x84, float(e.get("knee", 0.5)))
		buf.encode_u32(off + 0x88, int(e.get("color_start", 0xFFFFFFFF)))
		buf.encode_u32(off + 0x8C, int(e.get("color_mid", 0xFFFFFFFF)))
		buf.encode_u32(off + 0x90, int(e.get("color_end", 0xFFFFFFFF)))
		buf.encode_u32(off + 0x94, int(e.get("texture_id", -1)))
		buf.encode_u16(off + 0x98, int(e.get("count", 1)))
		buf.encode_u16(off + 0x9A, int(e.get("flags", 0)))
		buf[off + 0x9C] = int(e.get("atlas_cols", 1))
		buf[off + 0x9D] = int(e.get("atlas_rows", 1))
		buf[off + 0x9E] = int(e.get("anim_loops", 1))
		buf[off + 0x9F] = 0
		buf.encode_u32(off + 0xA0, int(e.get("seed", 0)))
		off += PBM_EMITTER_SIZE
	return buf

## True when any texel carries a partial (non 0/255) alpha — the difference
## between art a 16-bit format can hold (one alpha bit cuts a texel out) and art
## that needs the 8-bit alpha of RGBA8888 to fade.
static func has_soft_alpha(img: Image) -> bool:
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var a := int(img.get_pixel(x, y).a * 255.0)
			if a > 4 and a < 250:
				return true
	return false

static func next_pot(x: int) -> int:
	if x <= 0: return 1
	var p := 1
	while p < x: p <<= 1
	return p

static func rgba_to_rgba5551(r: int, g: int, b: int, a: int) -> int:
	var r5 := (r >> 3) & 0x1F
	var g5 := (g >> 3) & 0x1F
	var b5 := (b >> 3) & 0x1F
	var a1 := 1 if a > 127 else 0
	return (a1 << 15) | (b5 << 10) | (g5 << 5) | r5

## Converts an Image to raw pixel bytes (RGBA5551 or RGBA8888).
static func convert_image_to_bytes(img: Image, format_16bit: bool = true) -> Dictionary:
	var w := img.get_width()
	var h := img.get_height()
	img.convert(Image.FORMAT_RGBA8)
	var raw := img.get_data()

	var has_alpha := 0
	var out_data := PackedByteArray()
	var fmt := PBM_TEX_FMT_RGBA5551

	if format_16bit:
		out_data.resize(w * h * 2)
		for i in range(w * h):
			var r: int = raw[i * 4]
			var g: int = raw[i * 4 + 1]
			var b: int = raw[i * 4 + 2]
			var a: int = raw[i * 4 + 3]
			if a < 250:
				has_alpha = 1
			var p16 := rgba_to_rgba5551(r, g, b, a)
			out_data[i * 2] = p16 & 0xFF
			out_data[i * 2 + 1] = (p16 >> 8) & 0xFF
		fmt = PBM_TEX_FMT_RGBA5551
	else:
		out_data = raw
		for i in range(w * h):
			if raw[i * 4 + 3] < 250:
				has_alpha = 1
				break
		fmt = PBM_TEX_FMT_RGBA8888

	return { "data": out_data, "format": fmt, "has_alpha": has_alpha }

## Parses the binary GLB header and separates JSON chunk from BIN chunk.
static func parse_glb(glb_path: String) -> Dictionary:
	var f := FileAccess.open(glb_path, FileAccess.READ)
	if f == null:
		return { "error": FileAccess.get_open_error() }

	var magic := f.get_32()
	var version := f.get_32()
	var length := f.get_32()

	if magic != 0x46546C67: # "glTF"
		f.close()
		return { "error": ERR_INVALID_DATA }

	# Chunk 0: JSON
	var json_len := f.get_32()
	var json_type := f.get_32()
	if json_type != 0x4E4F534A: # "JSON"
		f.close()
		return { "error": ERR_INVALID_DATA }

	var json_bytes := f.get_buffer(json_len)
	var json_str := json_bytes.get_string_from_utf8()
	var gltf_data = JSON.parse_string(json_str)
	if not (gltf_data is Dictionary):
		f.close()
		return { "error": ERR_PARSE_ERROR }

	# Chunk 1: BIN
	var bin_len := f.get_32()
	var bin_type := f.get_32()
	var bin_data := f.get_buffer(bin_len)
	f.close()

	return {
		"error": OK,
		"gltf": gltf_data as Dictionary,
		"bin": bin_data
	}

## Reads and decodes accessor data from the binary buffer.
static func read_accessor(gltf: Dictionary, bin_data: PackedByteArray, acc_idx: int) -> Array:
	var accessors: Array = gltf.get("accessors", [])
	if acc_idx < 0 or acc_idx >= accessors.size():
		return []
	var acc: Dictionary = accessors[acc_idx]
	var buffer_views: Array = gltf.get("bufferViews", [])
	var bv_idx: int = acc.get("bufferView", -1)
	if bv_idx < 0 or bv_idx >= buffer_views.size():
		return []
	var bv: Dictionary = buffer_views[bv_idx]

	var comp_type: int = acc.get("componentType", 5126) # 5126 = float
	var type_str: String = acc.get("type", "SCALAR")
	var count: int = acc.get("count", 0)

	var bv_offset: int = bv.get("byteOffset", 0)
	var acc_offset: int = acc.get("byteOffset", 0)
	var offset: int = bv_offset + acc_offset
	var stride: int = bv.get("byteStride", 0)

	var n_comp := 1
	match type_str:
		"SCALAR": n_comp = 1
		"VEC2": n_comp = 2
		"VEC3": n_comp = 3
		"VEC4": n_comp = 4
		"MAT4": n_comp = 16

	var comp_size := 4
	match comp_type:
		5120, 5121: comp_size = 1 # b, B
		5122, 5123: comp_size = 2 # h, H
		5125, 5126: comp_size = 4 # I, f

	var elem_size := comp_size * n_comp
	var step := stride if stride > 0 else elem_size

	var result: Array = []
	for i in range(count):
		var pos := offset + i * step
		if type_str == "SCALAR":
			if comp_type == 5126:
				result.append(bin_data.decode_float(pos))
			elif comp_type == 5125:
				result.append(bin_data.decode_u32(pos))
			elif comp_type == 5123:
				result.append(bin_data.decode_u16(pos))
			elif comp_type == 5121:
				result.append(bin_data.decode_u8(pos))
		elif type_str == "VEC2":
			result.append(Vector2(bin_data.decode_float(pos), bin_data.decode_float(pos + 4)))
		elif type_str == "VEC3":
			result.append(Vector3(bin_data.decode_float(pos), bin_data.decode_float(pos + 4), bin_data.decode_float(pos + 8)))
		elif type_str == "VEC4":
			if comp_type == 5126:
				result.append(Color(bin_data.decode_float(pos), bin_data.decode_float(pos + 4), bin_data.decode_float(pos + 8), bin_data.decode_float(pos + 12)))
			elif comp_type == 5121: # unsigned byte normalized
				result.append(Color(bin_data.decode_u8(pos) / 255.0, bin_data.decode_u8(pos + 1) / 255.0, bin_data.decode_u8(pos + 2) / 255.0, bin_data.decode_u8(pos + 3) / 255.0))
			elif comp_type == 5123: # unsigned short normalized
				result.append(Color(bin_data.decode_u16(pos) / 65535.0, bin_data.decode_u16(pos + 2) / 65535.0, bin_data.decode_u16(pos + 4) / 65535.0, bin_data.decode_u16(pos + 6) / 65535.0))

	return result

## Extracts transform matrix from a glTF node.
static func get_node_transform(node: Dictionary) -> Transform3D:
	if node.has("matrix"):
		var m: Array = node["matrix"]
		var basis := Basis(
			Vector3(m[0], m[1], m[2]),
			Vector3(m[4], m[5], m[6]),
			Vector3(m[8], m[9], m[10])
		)
		var origin := Vector3(m[12], m[13], m[14])
		return Transform3D(basis, origin)

	var t := Vector3.ZERO
	if node.has("translation"):
		var tv: Array = node["translation"]
		t = Vector3(tv[0], tv[1], tv[2])

	var q := Quaternion.IDENTITY
	if node.has("rotation"):
		var qv: Array = node["rotation"]
		q = Quaternion(qv[0], qv[1], qv[2], qv[3])

	var s := Vector3.ONE
	if node.has("scale"):
		var sv: Array = node["scale"]
		s = Vector3(sv[0], sv[1], sv[2])

	return Transform3D(Basis(q).scaled(s), t)

## Full conversion from exported GLB to PBMv2 with tile atlasing and metadata.
static func convert_glb_to_pbm(glb_path: String, pbm_path: String, format_16bit: bool = true) -> Error:
	var parsed := parse_glb(glb_path)
	if parsed.get("error", OK) != OK:
		return parsed["error"]

	var gltf: Dictionary = parsed["gltf"]
	var bin_data: PackedByteArray = parsed["bin"]

	var raw_images: Array = gltf.get("images", [])
	var buffer_views: Array = gltf.get("bufferViews", [])

	# Animated UV scroll (PBM 2.1). PoiBuilder stores the speed in the material
	# metadata; Godot's glTF writer serializes it verbatim into the material's
	# `extras` as {"poi_uv_scroll": [u, v]} — texture repeats per second, 0,0 =
	# static. Two consequences, both handled here: meshes must be bucketed per
	# speed as well as per texture, and a scrolling texture must never be packed
	# into a shared atlas (an offset would drag the tile across its slot edge).
	var materials_gltf: Array = gltf.get("materials", [])
	var textures_gltf: Array = gltf.get("textures", [])
	var material_scroll: Dictionary = {} # glTF material index -> Vector2
	var material_alpha: Dictionary = {} # glTF material index -> PBM_ALPHA_*
	var atlas_exempt_images: Dictionary = {} # raw image index -> true
	for mat_idx in range(materials_gltf.size()):
		var mat: Dictionary = materials_gltf[mat_idx]
		# How a surface blends travels in the glTF alphaMode: BLEND is a soft
		# alpha (needs 8 bits per channel, so it can never share a 5551 atlas),
		# MASK a hard-edged cutout.
		var gltf_alpha := String(mat.get("alphaMode", "OPAQUE"))
		match gltf_alpha:
			"BLEND": material_alpha[mat_idx] = PBM_ALPHA_BLEND
			"MASK": material_alpha[mat_idx] = PBM_ALPHA_CUTOUT
			_: material_alpha[mat_idx] = PBM_ALPHA_NONE

		var bct: Dictionary = mat.get("pbrMetallicRoughness", {}).get("baseColorTexture", {})
		var t_idx: int = bct.get("index", -1)
		var src_img := -1
		if t_idx >= 0 and t_idx < textures_gltf.size():
			src_img = int(textures_gltf[t_idx].get("source", -1))

		var speed := PBUv.scroll_from_extras(mat.get("extras", {}))
		if speed != Vector2.ZERO:
			material_scroll[mat_idx] = speed
			if src_img >= 0:
				atlas_exempt_images[src_img] = true
		if gltf_alpha == "BLEND" and src_img >= 0:
			atlas_exempt_images[src_img] = true

	# 1. Separate Base Textures from 128x128 Baked Tiles
	var base_images: Array[Dictionary] = []
	var tile_images: Array[Dictionary] = []

	for img_idx in range(raw_images.size()):
		var img_info: Dictionary = raw_images[img_idx]
		var bv_idx: int = img_info.get("bufferView", -1)
		if bv_idx < 0 or bv_idx >= buffer_views.size():
			continue
		var bv: Dictionary = buffer_views[bv_idx]
		var offset: int = bv.get("byteOffset", 0)
		var length: int = bv["byteLength"]
		var img_bytes := bin_data.slice(offset, offset + length)

		var img := Image.new()
		var mime: String = img_info.get("mimeType", "")
		if mime == "image/png" or img_bytes.slice(0, 8) == PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]):
			img.load_png_from_buffer(img_bytes)
		elif mime == "image/jpeg" or img_bytes.slice(0, 2) == PackedByteArray([0xFF, 0xD8]):
			img.load_jpg_from_buffer(img_bytes)
		elif mime == "image/webp":
			img.load_webp_from_buffer(img_bytes)
		else:
			img.load_png_from_buffer(img_bytes)

		if img.is_empty():
			continue

		var name_str: String = img_info.get("name", "img_%d" % img_idx)
		if not atlas_exempt_images.has(img_idx) and ((img.get_width() == 128 and img.get_height() == 128) or name_str.contains("BakedTile")):
			tile_images.append({ "index": img_idx, "name": name_str, "image": img })
		else:
			base_images.append({ "index": img_idx, "name": name_str, "image": img })

	# 2. Deduplicate 128x128 Baked Tiles
	var unique_tiles: Dictionary = {} # hash_int -> { "id": int, "image": Image }
	var img_to_unique_tile: Dictionary = {}

	for tile in tile_images:
		var img: Image = tile["image"]
		var h := hash(img.get_data())
		if not unique_tiles.has(h):
			unique_tiles[h] = { "id": unique_tiles.size(), "image": img }
		img_to_unique_tile[tile["index"]] = unique_tiles[h]["id"]

	# 3. Pack Unique Tiles into 512x512 Atlases (16 tiles per atlas, 4x4 grid)
	var atlases: Array[Image] = []
	var tile_to_atlas_map: Dictionary = {} # uid -> { "atlas_idx": int, "col": int, "row": int }

	var sorted_unique: Array = unique_tiles.values()
	sorted_unique.sort_custom(func(a, b): return a["id"] < b["id"])

	for item in sorted_unique:
		var uid: int = item["id"]
		var t_img: Image = item["image"]
		var atlas_idx := uid / 16
		var slot := uid % 16
		var col := slot % 4
		var row := slot / 4

		while atlases.size() <= atlas_idx:
			var new_atlas := Image.create(512, 512, false, Image.FORMAT_RGBA8)
			new_atlas.fill(Color(0, 0, 0, 1))
			atlases.append(new_atlas)

		atlases[atlas_idx].blit_rect(t_img, Rect2i(0, 0, 128, 128), Vector2i(col * 128, row * 128))
		tile_to_atlas_map[uid] = { "atlas_idx": atlas_idx, "col": col, "row": row }
	# Collect baseColorFactor from materials for any tinted base textures
	var img_tints: Dictionary = {} # img_idx -> Array of Vector3 (r, g, b)
	var mat_tint: Dictionary = {}  # mat_idx -> Vector3
	for mat_idx in range(materials_gltf.size()):
		var mat: Dictionary = materials_gltf[mat_idx]
		var pbr: Dictionary = mat.get("pbrMetallicRoughness", {})
		var col: Array = pbr.get("baseColorFactor", [1.0, 1.0, 1.0, 1.0])
		var r := snappedf(float(col[0]), 0.001)
		var g := snappedf(float(col[1]), 0.001)
		var b := snappedf(float(col[2]), 0.001)
		var tint := Vector3(r, g, b) if (r < 0.999 or g < 0.999 or b < 0.999) else Vector3.ONE
		mat_tint[mat_idx] = tint
		var base_tex: Dictionary = pbr.get("baseColorTexture", {})
		var t_idx: int = base_tex.get("index", -1)
		if t_idx >= 0 and t_idx < textures_gltf.size():
			var s_idx: int = textures_gltf[t_idx].get("source", -1)
			if s_idx >= 0:
				if not img_tints.has(s_idx):
					img_tints[s_idx] = []
				var list: Array = img_tints[s_idx]
				var found := false
				for existing in list:
					if (existing as Vector3).distance_to(tint) < 0.002:
						found = true
						break
				if not found:
					list.append(tint)

	# Additive emitters (standard lump "emitters", §8) may keep their particle art
	# in the 16-bit format when its alpha is genuinely 1-bit: they are the only
	# users needing transparency, and additive blending takes its falloff from the
	# RGB channels rather than from alpha. The direct PBM writer applies the same
	# rule — the two export routes have to agree byte for byte.
	var additive_emitter_mats: Dictionary = {}
	var gltf_nodes_for_emit: Array = gltf.get("nodes", [])
	var gltf_meshes_for_emit: Array = gltf.get("meshes", [])
	for em_node in gltf_nodes_for_emit:
		var rec = (em_node.get("extras", {}) as Dictionary).get("poi_emitter", null)
		if not (rec is Dictionary) or (int((rec as Dictionary).get("flags", 0)) & 1) == 0:
			continue
		var em_mesh: int = em_node.get("mesh", -1)
		if em_mesh < 0 or em_mesh >= gltf_meshes_for_emit.size():
			continue
		for prim_em in gltf_meshes_for_emit[em_mesh].get("primitives", []):
			if prim_em.has("material"):
				additive_emitter_mats[int(prim_em["material"])] = true

	# 4. Assemble Textures Table
	var textures: Array[Dictionary] = []
	var img_to_tex_mapping: Dictionary = {} # "img_idx|r|g|b" -> { "tex_id": int, "is_atlas": bool, "col": int, "row": int }
	# 4a. Base Textures
	for base in base_images:
		var orig_img: Image = base["image"]
		var w := orig_img.get_width()
		var h := orig_img.get_height()
		var pot_w := next_pot(w)
		var pot_h := next_pot(h)
		if pot_w != w or pot_h != h:
			orig_img.resize(pot_w, pot_h, Image.INTERPOLATE_BILINEAR)
			w = pot_w
			h = pot_h

		var b_idx: int = base["index"]
		var tints: Array = img_tints.get(b_idx, [Vector3.ONE])
		if tints.is_empty():
			tints = [Vector3.ONE]

		for tint_vec in tints:
			var tint: Vector3 = tint_vec
			var img: Image = orig_img.duplicate()
			var tex_name: String = base["name"]
			if tint.distance_to(Vector3.ONE) > 0.002:
				tex_name += "_tint"
				for py in range(h):
					for px in range(w):
						var p_col: Color = img.get_pixel(px, py)
						img.set_pixel(px, py, Color(p_col.r * tint.x, p_col.g * tint.y, p_col.b * tint.z, p_col.a))

			# The image's alpha mode is the strongest any material using it needs.
			var mode := PBM_ALPHA_NONE
			var blend_needs_8bit := false
			for mat_idx in material_alpha:
				var m_tint: Vector3 = mat_tint.get(mat_idx, Vector3.ONE)
				if m_tint.distance_to(tint) < 0.002:
					var bct: Dictionary = materials_gltf[mat_idx].get("pbrMetallicRoughness", {}).get("baseColorTexture", {})
					var t_idx: int = bct.get("index", -1)
					if t_idx >= 0 and t_idx < textures_gltf.size() and int(textures_gltf[t_idx].get("source", -1)) == b_idx:
						mode = maxi(mode, int(material_alpha[mat_idx]))
						if int(material_alpha[mat_idx]) == PBM_ALPHA_BLEND and not additive_emitter_mats.has(mat_idx):
							blend_needs_8bit = true
			if mode == PBM_ALPHA_BLEND and not blend_needs_8bit and not has_soft_alpha(img):
				# Only additive emitters draw this art, and its alpha is 1-bit: a
				# cutout is what it actually is.
				mode = PBM_ALPHA_CUTOUT

			var converted := convert_image_to_bytes(img, format_16bit and mode != PBM_ALPHA_BLEND)
			if mode == PBM_ALPHA_NONE and int(converted["has_alpha"]) != 0:
				mode = PBM_ALPHA_CUTOUT
			var tex_id := textures.size()
			textures.append({
				"name": tex_name.substr(0, 31),
				"width": w, "height": h,
				"format": converted["format"],
				"alpha_mode": mode,
				"data": converted["data"]
			})
			var key := "%d|%.3f|%.3f|%.3f" % [b_idx, tint.x, tint.y, tint.z]
			img_to_tex_mapping[key] = { "tex_id": tex_id, "is_atlas": false, "col": 0, "row": 0 }
			var fallback_key := "%d|fallback" % b_idx
			if not img_to_tex_mapping.has(fallback_key) or tint.distance_to(Vector3.ONE) < 0.002:
				img_to_tex_mapping[fallback_key] = img_to_tex_mapping[key]
	var atlas_start_tex_id := textures.size()
	for a_idx in range(atlases.size()):
		var converted := convert_image_to_bytes(atlases[a_idx], format_16bit)
		var tex_id := textures.size()
		textures.append({
			"name": "TileAtlas_%d" % a_idx,
			"width": 512, "height": 512,
			"format": converted["format"],
			# Baked tiles are 5551, so their alpha can only cut a texel out.
			"alpha_mode": PBM_ALPHA_CUTOUT if int(converted["has_alpha"]) != 0 else PBM_ALPHA_NONE,
			"data": converted["data"]
		})
	for tile in tile_images:
		var uid: int = img_to_unique_tile[tile["index"]]
		var mapping: Dictionary = tile_to_atlas_map[uid]
		var info := {
			"tex_id": atlas_start_tex_id + mapping["atlas_idx"],
			"is_atlas": true,
			"col": mapping["col"],
			"row": mapping["row"]
		}
		var t_idx: int = tile["index"]
		img_to_tex_mapping["%d|1.000|1.000|1.000" % t_idx] = info
		img_to_tex_mapping["%d|fallback" % t_idx] = info
	# 5. Map Materials to Texture Slots
	var materials: Array = materials_gltf
	var mat_to_tex_mapping: Dictionary = {}

	for mat_idx in range(materials.size()):
		var mat: Dictionary = materials[mat_idx]
		var pbr: Dictionary = mat.get("pbrMetallicRoughness", {})
		var base_tex: Dictionary = pbr.get("baseColorTexture", {})
		var tex_idx: int = base_tex.get("index", -1)
		if tex_idx >= 0 and tex_idx < textures_gltf.size():
			var src_img_idx: int = textures_gltf[tex_idx].get("source", -1)
			var tint: Vector3 = mat_tint.get(mat_idx, Vector3.ONE)
			var key := "%d|%.3f|%.3f|%.3f" % [src_img_idx, tint.x, tint.y, tint.z]
			if img_to_tex_mapping.has(key):
				mat_to_tex_mapping[mat_idx] = img_to_tex_mapping[key]
			elif img_to_tex_mapping.has("%d|fallback" % src_img_idx):
				mat_to_tex_mapping[mat_idx] = img_to_tex_mapping["%d|fallback" % src_img_idx]
	# 6. Parse Nodes, Meshes, and Vertices
	var nodes: Array = gltf.get("nodes", [])
	var meshes_gltf: Array = gltf.get("meshes", [])

	var mesh_buckets: Dictionary = {} # "tex|su|sv" -> {tex_id, scroll, verts}

	var all_colliders: Array[Dictionary] = []
	var bounds_min := Vector3(INF, INF, INF)
	var bounds_max := Vector3(-INF, -INF, -INF)

	for node_idx in range(nodes.size()):
		var node: Dictionary = nodes[node_idx]
		var node_name: String = node.get("name", "node_%d" % node_idx)
		var xf := get_node_transform(node)
		var mesh_idx: int = node.get("mesh", -1)
		if mesh_idx < 0 or mesh_idx >= meshes_gltf.size():
			continue

		# An emitter's texture carrier (PBMapExporter._export_emitter_holder) is
		# a zero-size quad whose only job is to put the particle texture in the
		# file: it is read as an emitter below, never as geometry.
		if (node.get("extras", {}) as Dictionary).has("poi_emitter"):
			continue

		var mesh_obj: Dictionary = meshes_gltf[mesh_idx]
		for prim in mesh_obj.get("primitives", []):
			var attrs: Dictionary = prim.get("attributes", {})
			var pos_acc: int = attrs.get("POSITION", -1)
			if pos_acc < 0: continue
			var positions := read_accessor(gltf, bin_data, pos_acc)
			var uv_acc: int = attrs.get("TEXCOORD_0", -1)
			var uvs := read_accessor(gltf, bin_data, uv_acc) if uv_acc >= 0 else []
			var col_acc: int = attrs.get("COLOR_0", -1)
			var colors := read_accessor(gltf, bin_data, col_acc) if col_acc >= 0 else []
			var idx_acc: int = prim.get("indices", -1)
			var indices := read_accessor(gltf, bin_data, idx_acc) if idx_acc >= 0 else []

			var idx_list: Array = []
			if not indices.is_empty():
				idx_list = indices
			else:
				for i in range(positions.size()): idx_list.append(i)

			var is_collider := node_name.begins_with("Collider_") or node_name.begins_with("collider_")
			if is_collider:
				var tris: PackedVector3Array = PackedVector3Array()
				for idx in idx_list:
					tris.append(xf * (positions[idx] as Vector3))
				all_colliders.append({
					"name": node_name.substr(0, 31),
					"type": 2 if node_name.to_lower().contains("ramp") else (0 if node_name.to_lower().contains("box") else 1),
					"triangles": tris
				})
			else:
				var mat_idx: int = prim.get("material", -1)
				var mapping: Dictionary = mat_to_tex_mapping.get(mat_idx, {})
				var tex_id: int = mapping.get("tex_id", -1)
				var is_atlas: bool = mapping.get("is_atlas", false)
				var col_slot: int = mapping.get("col", 0)
				var row_slot: int = mapping.get("row", 0)
				var scroll: Vector2 = material_scroll.get(mat_idx, Vector2.ZERO)

				# Bucket key: the scroll speed is a per-mesh property of the
				# file, so two materials sharing one texture but scrolling at
				# different speeds must not merge into one mesh — one of the two
				# animations would be lost.
				var bucket: String = "%d|%f|%f" % [tex_id, scroll.x, scroll.y]
				if not mesh_buckets.has(bucket):
					mesh_buckets[bucket] = { "tex_id": tex_id, "scroll": scroll, "verts": [] as Array[Dictionary] }
				var bucket_verts: Array = mesh_buckets[bucket]["verts"]

				for idx in idx_list:
					var p: Vector3 = positions[idx]
					var wp: Vector3 = xf * p

					bounds_min.x = minf(bounds_min.x, wp.x); bounds_max.x = maxf(bounds_max.x, wp.x)
					bounds_min.y = minf(bounds_min.y, wp.y); bounds_max.y = maxf(bounds_max.y, wp.y)
					bounds_min.z = minf(bounds_min.z, wp.z); bounds_max.z = maxf(bounds_max.z, wp.z)

					var raw_uv: Vector2 = uvs[idx] if idx < uvs.size() else Vector2.ZERO
					var c: Color = colors[idx] if idx < colors.size() else Color.WHITE

					var u_val: float = raw_uv.x
					var v_val: float = raw_uv.y

					if is_atlas:
						var u_c := clampf(raw_uv.x, 0.0, 1.0)
						var v_c := clampf(raw_uv.y, 0.0, 1.0)
						# Edge-to-edge: a tile owns the full width of its slot.
						# (The old half-texel inset mapped the tile onto texel
						# CENTRES 0..127, which leaves a one-texel band that no
						# tile displays -- neighbouring tiles then do not meet and
						# the pattern shifts at every seam. Must stay identical to
						# pbm_conv.py: the two converters are meant to agree.)
						var u_in_slot := u_c
						var v_in_slot := v_c
						u_val = (col_slot + u_in_slot) * 0.25
						v_val = (row_slot + v_in_slot) * 0.25

					var r_b := int(clampf(c.r, 0.0, 1.0) * 255.0)
					var g_b := int(clampf(c.g, 0.0, 1.0) * 255.0)
					var b_b := int(clampf(c.b, 0.0, 1.0) * 255.0)
					var a_b := int(clampf(c.a, 0.0, 1.0) * 255.0)
					var c_int := r_b | (g_b << 8) | (b_b << 16) | (a_b << 24)

					bucket_verts.append({
						"u": u_val, "v": v_val,
						"color": c_int,
						"x": wp.x, "y": wp.y, "z": wp.z
					})

	# 7. Group into spatial chunks of <= 384 vertices (128 triangles)
	var all_meshes: Array[Dictionary] = []
	for key in mesh_buckets:
		var bucket: Dictionary = mesh_buckets[key]
		var tex_id: int = bucket["tex_id"]
		var scroll: Vector2 = bucket["scroll"]
		var vlist: Array = bucket["verts"]
		if vlist.is_empty(): continue
		var batch_size := 384
		for i in range(0, vlist.size(), batch_size):
			var batch := vlist.slice(i, i + batch_size)
			var b_min := Vector3(INF, INF, INF)
			var b_max := Vector3(-INF, -INF, -INF)
			for v in batch:
				b_min.x = minf(b_min.x, v["x"]); b_max.x = maxf(b_max.x, v["x"])
				b_min.y = minf(b_min.y, v["y"]); b_max.y = maxf(b_max.y, v["y"])
				b_min.z = minf(b_min.z, v["z"]); b_max.z = maxf(b_max.z, v["z"])

			var tex_name: String = textures[tex_id]["name"] if (tex_id >= 0 and tex_id < textures.size()) else "mesh_t%d" % tex_id
			all_meshes.append({
				"name": ("%s_%d" % [tex_name, i / batch_size]).substr(0, 31),
				"texture_id": tex_id,
				"uv_scroll": scroll,
				"vertices": batch,
				"bounds_min": b_min,
				"bounds_max": b_max
			})

	if bounds_min.x == INF:
		bounds_min = Vector3(-10, 0, -10)
		bounds_max = Vector3(10, 5, 10)

	var spawn_pos := Vector3(0.0, 1.6, 4.2)
	var spawn_rot := 0.0

	# 8. Metadata Chunk (v2.0+)
	# ── Particle emitters (standard lump "emitters") ────────────────────────
	# The record rides in the holder node's glTF `extras`; the holder's material
	# is what ties the emitter to its texture in this file's texture table.
	var emitter_records: Array = []
	for node_idx2 in range(nodes.size()):
		var node2: Dictionary = nodes[node_idx2]
		var rec = (node2.get("extras", {}) as Dictionary).get("poi_emitter", null)
		if not (rec is Dictionary):
			continue
		var rec2: Dictionary = (rec as Dictionary).duplicate()
		var tex_id2 := -1
		var mesh_idx2: int = node2.get("mesh", -1)
		if mesh_idx2 >= 0 and mesh_idx2 < meshes_gltf.size():
			for prim2 in meshes_gltf[mesh_idx2].get("primitives", []):
				var mat_idx2: int = prim2.get("material", -1)
				var mapping2: Dictionary = mat_to_tex_mapping.get(mat_idx2, {})
				if mapping2.has("tex_id"):
					tex_id2 = int(mapping2["tex_id"])
					break
		rec2["texture_id"] = tex_id2
		emitter_records.append(rec2)

	var metadata_entries: Array[Dictionary] = []

	# Metadata 1: map_name
	var map_name_bytes := "PoiRetro Courtyard Showcase".to_utf8_buffer()
	map_name_bytes.append(0)
	metadata_entries.append({
		"tag": "map_name",
		"type": PBM_META_STRING,
		"data": map_name_bytes
	})
	# Metadata: env_preset
	var env_preset_str := "day"
	if glb_path.find("_dawn") != -1:
		env_preset_str = "dawn"
	elif glb_path.find("_dusk") != -1:
		env_preset_str = "dusk"
	elif glb_path.find("_night") != -1:
		env_preset_str = "night"
	var env_preset_bytes := env_preset_str.to_utf8_buffer()
	env_preset_bytes.append(0)
	metadata_entries.append({
		"tag": "env_preset",
		"type": PBM_META_STRING,
		"data": env_preset_bytes
	})
	# Metadata 2: player_spawn
	var spawn_dict := {
		"position": [spawn_pos.x, spawn_pos.y, spawn_pos.z],
		"yaw": spawn_rot,
		"camera_fov": 65.0
	}
	var spawn_bytes := JSON.stringify(spawn_dict).to_utf8_buffer()
	spawn_bytes.append(0)
	metadata_entries.append({
		"tag": "player_spawn",
		"type": PBM_META_JSON,
		"data": spawn_bytes
	})

	# Metadata 3: walkable_mesh (2 triangles = 18 floats = 72 bytes)
	var walkable_buf := PackedByteArray()
	walkable_buf.resize(72)
	var w_pts := [
		Vector3(-4.0, 0.0, -5.5), Vector3(4.0, 0.0, -5.5), Vector3(4.0, 0.0, 5.0),
		Vector3(-4.0, 0.0, -5.5), Vector3(4.0, 0.0, 5.0),  Vector3(-4.0, 0.0, 5.0)
	]
	for wi in range(6):
		walkable_buf.encode_float(wi * 12, w_pts[wi].x)
		walkable_buf.encode_float(wi * 12 + 4, w_pts[wi].y)
		walkable_buf.encode_float(wi * 12 + 8, w_pts[wi].z)
	metadata_entries.append({
		"tag": "walkable_mesh",
		"type": PBM_META_ENTITY,
		"data": walkable_buf
	})

	# Metadata 4: triggers
	var triggers_arr := [
		{
			"id": "cutscene_archway",
			"event": "on_enter_archway",
			"bounds_min": [-2.0, 0.0, -5.8],
			"bounds_max": [2.0, 3.5, -4.8],
			"oneshot": true
		}
	]
	var triggers_bytes := JSON.stringify(triggers_arr).to_utf8_buffer()
	triggers_bytes.append(0)
	metadata_entries.append({
		"tag": "triggers",
		"type": PBM_META_JSON,
		"data": triggers_bytes
	})

	# Metadata 5: emitters (standard binary lump)
	if not emitter_records.is_empty():
		metadata_entries.append({
			"tag": "emitters",
			"type": PBM_META_EMITTER,
			"data": pack_emitter_lump(emitter_records)
		})

	# Metadata 6: rigid_bodies (ball pit)
	var rigid_dict := {
		"type": "ball_pit",
		"count": 16,
		"radius": 0.22,
		"mass": 1.0,
		"restitution": 0.75,
		"spawn_min": [-0.8, 2.0, -0.8],
		"spawn_max": [0.8, 4.0, 0.8]
	}
	var rigid_bytes := JSON.stringify(rigid_dict).to_utf8_buffer()
	rigid_bytes.append(0)
	metadata_entries.append({
		"tag": "rigid_bodies",
		"type": PBM_META_JSON,
		"data": rigid_bytes
	})

	# Metadata 2: PatrolSphere Entity
	var ent_name_bytes := "PatrolSphere".to_ascii_buffer()
	ent_name_bytes.resize(32)
	var ent_buf := PackedByteArray()
	ent_buf.resize(88)
	# name: 32 bytes
	for bi in range(32): ent_buf[bi] = ent_name_bytes[bi]
	ent_buf.encode_u32(32, PBM_ENTITY_PATROL_SPHERE)
	ent_buf.encode_float(36, 0.35) # radius
	ent_buf.encode_u32(40, 0xFF00C8FF) # color (gold)
	ent_buf.encode_float(44, 2.5) # speed
	ent_buf.encode_u32(48, 3) # num_waypoints
	# Waypoint 0
	ent_buf.encode_float(52, -3.0); ent_buf.encode_float(56, 1.2); ent_buf.encode_float(60, -1.0)
	# Waypoint 1
	ent_buf.encode_float(64, 0.0);  ent_buf.encode_float(68, 2.2); ent_buf.encode_float(72, -4.5)
	# Waypoint 2
	ent_buf.encode_float(76, 3.0);  ent_buf.encode_float(80, 1.2); ent_buf.encode_float(84, 0.5)

	metadata_entries.append({
		"tag": "entities",
		"type": PBM_META_ENTITY,
		"data": ent_buf
	})

	# 9. Write PBMv2 File
	var f := FileAccess.open(pbm_path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()

	# Header (64 bytes)
	f.store_32(PBM_MAGIC)
	f.store_32(PBM_VERSION)
	f.store_32(textures.size())
	f.store_32(all_meshes.size())
	f.store_32(all_colliders.size())
	f.store_32(metadata_entries.size())
	f.store_float(spawn_pos.x); f.store_float(spawn_pos.y); f.store_float(spawn_pos.z)
	f.store_float(spawn_rot)
	f.store_float(bounds_min.x); f.store_float(bounds_min.y); f.store_float(bounds_min.z)
	f.store_float(bounds_max.x); f.store_float(bounds_max.y); f.store_float(bounds_max.z)

	# Textures Chunk
	for tex in textures:
		var name_b: PackedByteArray = (tex["name"] as String).to_ascii_buffer()
		name_b.resize(32)
		f.store_buffer(name_b)
		f.store_16(tex["width"])
		f.store_16(tex["height"])
		f.store_16(tex["format"])
		f.store_16(tex["alpha_mode"])
		f.store_32((tex["data"] as PackedByteArray).size())
		f.store_buffer(tex["data"])

	# Meshes Chunk
	for m in all_meshes:
		var name_b: PackedByteArray = (m["name"] as String).to_ascii_buffer()
		name_b.resize(32)
		f.store_buffer(name_b)
		f.store_32(m["texture_id"])
		var v_list: Array = m["vertices"]
		f.store_32(v_list.size())
		var b_min: Vector3 = m["bounds_min"]
		var b_max: Vector3 = m["bounds_max"]
		f.store_float(b_min.x); f.store_float(b_min.y); f.store_float(b_min.z)
		f.store_float(b_max.x); f.store_float(b_max.y); f.store_float(b_max.z)
		# PBM 2.1 animated UV scroll (was `reserved[2]`, always 0.0 before).
		var scroll: Vector2 = m.get("uv_scroll", Vector2.ZERO)
		f.store_float(scroll.x)
		f.store_float(scroll.y)
		for v in v_list:
			f.store_float(v["u"])
			f.store_float(v["v"])
			f.store_32(v["color"])
			f.store_float(v["x"])
			f.store_float(v["y"])
			f.store_float(v["z"])

	# Colliders Chunk
	for col in all_colliders:
		var name_b: PackedByteArray = (col["name"] as String).to_ascii_buffer()
		name_b.resize(32)
		f.store_buffer(name_b)
		f.store_32(col["type"])
		var tris: PackedVector3Array = col["triangles"]
		var c_min := Vector3(INF, INF, INF)
		var c_max := Vector3(-INF, -INF, -INF)
		for p in tris:
			c_min.x = minf(c_min.x, p.x); c_max.x = maxf(c_max.x, p.y)
			c_min.y = minf(c_min.y, p.y); c_max.y = maxf(c_max.y, p.y)
			c_min.z = minf(c_min.z, p.z); c_max.z = maxf(c_max.z, p.z)
		f.store_float(c_min.x); f.store_float(c_min.y); f.store_float(c_min.z)
		f.store_float(c_max.x); f.store_float(c_max.y); f.store_float(c_max.z)
		f.store_32(int(tris.size() / 3))
		for p in tris:
			f.store_float(p.x); f.store_float(p.y); f.store_float(p.z)

	# Metadata Chunk (v2.0+)
	for mentry in metadata_entries:
		var tag_b: PackedByteArray = (mentry["tag"] as String).to_ascii_buffer()
		tag_b.resize(32)
		f.store_buffer(tag_b)
		f.store_32(mentry["type"])
		var mdata: PackedByteArray = mentry["data"]
		f.store_32(mdata.size())
		f.store_buffer(mdata)
		var pad := (4 - (mdata.size() % 4)) % 4
		for pi in range(pad):
			f.store_8(0)

	f.close()
	return OK
