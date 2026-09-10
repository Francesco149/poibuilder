@tool
class_name PBPbmConverter
extends RefCounted

## PBPbmConverter — Ports the PoiRetro PBMv2 Map Converter with Tile Atlasing to GDScript.
## Converts PoiBuilder exported GLB maps to PBM (PoiBuilder Retro Map) v2.0 binary format.

const PBM_MAGIC := 0x324D4250 # "PBM2"
const PBM_VERSION := 2

const PBM_TEX_FMT_RGBA8888 := 0
const PBM_TEX_FMT_RGBA5551 := 1
const PBM_TEX_FMT_RGBA4444 := 2
const PBM_TEX_FMT_RGB565   := 3

const PBM_META_RAW    := 0
const PBM_META_STRING := 1
const PBM_META_JSON   := 2
const PBM_META_ENTITY := 3

const PBM_ENTITY_PATROL_SPHERE := 1

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
		if (img.get_width() == 128 and img.get_height() == 128) or name_str.contains("BakedTile"):
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
	var img_base_colors: Dictionary = {}
	var materials_gltf: Array = gltf.get("materials", [])
	var textures_gltf: Array = gltf.get("textures", [])
	for mat in materials_gltf:
		var pbr: Dictionary = mat.get("pbrMetallicRoughness", {})
		var col: Array = pbr.get("baseColorFactor", [1.0, 1.0, 1.0, 1.0])
		var base_tex: Dictionary = pbr.get("baseColorTexture", {})
		var t_idx: int = base_tex.get("index", -1)
		if t_idx >= 0 and t_idx < textures_gltf.size():
			var s_idx: int = textures_gltf[t_idx].get("source", -1)
			if s_idx >= 0 and (col[0] < 0.999 or col[1] < 0.999 or col[2] < 0.999):
				img_base_colors[s_idx] = Color(col[0], col[1], col[2], col[3])

	# 4. Assemble Textures Table
	var textures: Array[Dictionary] = []
	var img_to_tex_mapping: Dictionary = {} # raw_img_idx -> { "tex_id": int, "is_atlas": bool, "col": int, "row": int }
	# 4a. Base Textures
	for base in base_images:
		var img: Image = base["image"]
		var w := img.get_width()
		var h := img.get_height()
		var pot_w := next_pot(w)
		var pot_h := next_pot(h)
		if pot_w != w or pot_h != h:
			img.resize(pot_w, pot_h, Image.INTERPOLATE_BILINEAR)
			w = pot_w
			h = pot_h

		if img_base_colors.has(base["index"]):
			var bcol: Color = img_base_colors[base["index"]]
			for py in range(h):
				for px in range(w):
					var p_col: Color = img.get_pixel(px, py)
					img.set_pixel(px, py, Color(p_col.r * bcol.r, p_col.g * bcol.g, p_col.b * bcol.b, p_col.a))

		var converted := convert_image_to_bytes(img, format_16bit)
		var tex_id := textures.size()
		textures.append({
			"name": base["name"].substr(0, 31),
			"width": w, "height": h,
			"format": converted["format"],
			"has_alpha": converted["has_alpha"],
			"data": converted["data"]
		})
		img_to_tex_mapping[base["index"]] = { "tex_id": tex_id, "is_atlas": false, "col": 0, "row": 0 }

	var atlas_start_tex_id := textures.size()
	for a_idx in range(atlases.size()):
		var converted := convert_image_to_bytes(atlases[a_idx], format_16bit)
		var tex_id := textures.size()
		textures.append({
			"name": "TileAtlas_%d" % a_idx,
			"width": 512, "height": 512,
			"format": converted["format"],
			"has_alpha": converted["has_alpha"],
			"data": converted["data"]
		})
	for tile in tile_images:
		var uid: int = img_to_unique_tile[tile["index"]]
		var mapping: Dictionary = tile_to_atlas_map[uid]
		img_to_tex_mapping[tile["index"]] = {
			"tex_id": atlas_start_tex_id + mapping["atlas_idx"],
			"is_atlas": true,
			"col": mapping["col"],
			"row": mapping["row"]
		}

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
			if img_to_tex_mapping.has(src_img_idx):
				mat_to_tex_mapping[mat_idx] = img_to_tex_mapping[src_img_idx]

	# 6. Parse Nodes, Meshes, and Vertices
	var nodes: Array = gltf.get("nodes", [])
	var meshes_gltf: Array = gltf.get("meshes", [])

	var mesh_buckets: Dictionary = {} # tex_id -> Array[Dictionary]
	for t_idx in range(textures.size()):
		mesh_buckets[t_idx] = []
	mesh_buckets[-1] = []

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
						var half_texel: float = 0.5 / 128.0
						var u_c := clampf(raw_uv.x, 0.0, 1.0)
						var v_c := clampf(raw_uv.y, 0.0, 1.0)
						var u_in_slot := half_texel + u_c * (1.0 - 2.0 * half_texel)
						var v_in_slot := half_texel + v_c * (1.0 - 2.0 * half_texel)
						u_val = (col_slot + u_in_slot) * 0.25
						v_val = (row_slot + v_in_slot) * 0.25

					var r_b := int(clampf(c.r, 0.0, 1.0) * 255.0)
					var g_b := int(clampf(c.g, 0.0, 1.0) * 255.0)
					var b_b := int(clampf(c.b, 0.0, 1.0) * 255.0)
					var a_b := int(clampf(c.a, 0.0, 1.0) * 255.0)
					var c_int := r_b | (g_b << 8) | (b_b << 16) | (a_b << 24)

					mesh_buckets[tex_id].append({
						"u": u_val, "v": v_val,
						"color": c_int,
						"x": wp.x, "y": wp.y, "z": wp.z
					})

	# 7. Group into spatial chunks of <= 384 vertices (128 triangles)
	var all_meshes: Array[Dictionary] = []
	for tex_id in mesh_buckets:
		var vlist: Array = mesh_buckets[tex_id]
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
	var metadata_entries: Array[Dictionary] = []

	# Metadata 1: map_name
	var map_name_bytes := "PoiRetro Courtyard Showcase".to_utf8_buffer()
	map_name_bytes.append(0)
	metadata_entries.append({
		"tag": "map_name",
		"type": PBM_META_STRING,
		"data": map_name_bytes
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

	# Metadata 5: particle_emitters
	var particles_arr := [
		{
			"id": "torch_sparks",
			"position": [2.5, 1.8, -4.5],
			"rate": 30,
			"lifetime": 1.2,
			"velocity": [0.0, 1.5, 0.0],
			"spread": 0.3,
			"color": "0xFF33AAFF"
		}
	]
	var particles_bytes := JSON.stringify(particles_arr).to_utf8_buffer()
	particles_bytes.append(0)
	metadata_entries.append({
		"tag": "particle_emitters",
		"type": PBM_META_JSON,
		"data": particles_bytes
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
		f.store_16(tex["has_alpha"])
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
