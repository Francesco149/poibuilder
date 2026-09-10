#!/usr/bin/env python3
"""
pbm_conv.py — PoiBuilder Retro Map Converter with Texture Atlasing
Converts PoiBuilder exported GLB maps to PBM (PoiBuilder Retro Map) binary format for PSP and retro engines.
Packs individual 128x128 baked tiles into 512x512 atlases, reducing draw calls and texture state changes by ~85%.
"""

import sys
import os
import struct
import json
import io
import math
from PIL import Image

PBM_MAGIC = 0x334D4250 # "PBM3"
PBM_VERSION = 3

PBM_META_RAW    = 0
PBM_META_STRING = 1
PBM_META_JSON   = 2
PBM_META_ENTITY = 3
PBM_ENTITY_PATROL_SPHERE = 1

PBM_ALPHA_NONE = 0      # opaque: opaque pass, mip chain
PBM_ALPHA_CUTOUT = 1    # hard-edged cutout: alpha-tested, no mip chain
PBM_ALPHA_BLEND = 2     # soft alpha: blended, mip chain kept, RGBA8888

PBM_TEX_FMT_RGBA8888 = 0
PBM_TEX_FMT_RGBA5551 = 1
PBM_TEX_FMT_RGBA4444 = 2
PBM_TEX_FMT_RGB565   = 3

def next_pot(x):
    return 1 << (x - 1).bit_length()

def rgba_to_rgba5551(r, g, b, a):
    # 5 bits R, 5 bits G, 5 bits B, 1 bit A
    r5 = (r >> 3) & 0x1F
    g5 = (g >> 3) & 0x1F
    b5 = (b >> 3) & 0x1F
    a1 = 1 if a > 127 else 0
    return (a1 << 15) | (b5 << 10) | (g5 << 5) | r5

def convert_pil_to_bytes(pil_img, format_16bit=True):
    w, h = pil_img.size
    has_alpha = 1 if any(px[3] < 250 for px in pil_img.getdata()) else 0
    
    if format_16bit:
        pix = pil_img.load()
        tex_data = bytearray(w * h * 2)
        for y in range(h):
            for x in range(w):
                r, g, b, a = pix[x, y]
                p16 = rgba_to_rgba5551(r, g, b, a)
                struct.pack_into("<H", tex_data, (y * w + x) * 2, p16)
        fmt = PBM_TEX_FMT_RGBA5551
    else:
        tex_data = pil_img.tobytes()
        fmt = PBM_TEX_FMT_RGBA8888
        
    return tex_data, fmt, has_alpha

def parse_glb(glb_path):
    with open(glb_path, "rb") as f:
        magic, version, length = struct.unpack("<4sII", f.read(12))
        if magic != b"glTF":
            raise ValueError("Not a valid glTF/GLB file")
        
        chunk_len, chunk_type = struct.unpack("<I4s", f.read(8))
        if chunk_type != b"JSON":
            raise ValueError("First chunk is not JSON")
        json_data = json.loads(f.read(chunk_len).decode("utf-8"))
        
        bin_len, bin_type = struct.unpack("<I4s", f.read(8))
        bin_data = f.read(bin_len)
        
    return json_data, bin_data

def read_accessor_data(gltf, bin_data, accessor_idx):
    acc = gltf["accessors"][accessor_idx]
    bv = gltf["bufferViews"][acc["bufferView"]]
    
    comp_type = acc["componentType"]
    type_str = acc["type"]
    count = acc["count"]
    
    bv_offset = bv.get("byteOffset", 0)
    acc_offset = acc.get("byteOffset", 0)
    offset = bv_offset + acc_offset
    stride = bv.get("byteStride", 0)
    
    type_counts = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}
    n_comp = type_counts[type_str]
    
    comp_formats = {
        5120: "b", 5121: "B", 5122: "h", 5123: "H", 5125: "I", 5126: "f"
    }
    comp_sizes = {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4}
    
    fmt_char = comp_formats[comp_type]
    comp_size = comp_sizes[comp_type]
    elem_size = comp_size * n_comp
    step = stride if stride > 0 else elem_size
    
    result = []
    for i in range(count):
        pos = offset + i * step
        raw = bin_data[pos : pos + elem_size]
        vals = struct.unpack("<" + fmt_char * n_comp, raw)
        result.append(vals if n_comp > 1 else vals[0])
        
    return result

def matrix_multiply_vec3(mat, v):
    x = mat[0] * v[0] + mat[4] * v[1] + mat[8] * v[2] + mat[12]
    y = mat[1] * v[0] + mat[5] * v[1] + mat[9] * v[2] + mat[13]
    z = mat[2] * v[0] + mat[6] * v[1] + mat[10] * v[2] + mat[14]
    return (x, y, z)

def get_node_transform(node):
    if "matrix" in node:
        return node["matrix"]
    
    t = node.get("translation", [0.0, 0.0, 0.0])
    r = node.get("rotation", [0.0, 0.0, 0.0, 1.0])
    s = node.get("scale", [1.0, 1.0, 1.0])
    
    qx, qy, qz, qw = r
    xx = qx * qx; yy = qy * qy; zz = qz * qz
    xy = qx * qy; xz = qx * qz; yz = qy * qz
    wx = qw * qx; wy = qw * qy; wz = qw * qz
    
    m00 = (1.0 - 2.0 * (yy + zz)) * s[0]
    m01 = (2.0 * (xy + wz)) * s[0]
    m02 = (2.0 * (xz - wy)) * s[0]
    
    m10 = (2.0 * (xy - wz)) * s[1]
    m11 = (1.0 - 2.0 * (xx + zz)) * s[1]
    m12 = (2.0 * (yz + wx)) * s[1]
    
    m20 = (2.0 * (xz + wy)) * s[2]
    m21 = (2.0 * (yz - wx)) * s[2]
    m22 = (1.0 - 2.0 * (xx + yy)) * s[2]
    
    return [
        m00, m01, m02, 0.0,
        m10, m11, m12, 0.0,
        m20, m21, m22, 0.0,
        t[0], t[1], t[2], 1.0
    ]

def multiply_matrices(a, b):
    res = [0.0] * 16
    for c in range(4):
        for r in range(4):
            s = 0.0
            for k in range(4):
                s += a[k * 4 + r] * b[c * 4 + k]
            res[c * 4 + r] = s
    return res

def convert_glb_to_pbm(glb_path, pbm_path, format_16bit=True):
    print(f"Loading GLB: {glb_path}...")
    gltf, bin_data = parse_glb(glb_path)
    
    raw_images = gltf.get("images", [])
    print(f"Loaded {len(raw_images)} raw images from GLB.")
    
    # Per-material properties this converter has to know BEFORE it decides how
    # each image is stored, all of them carried by the glTF material:
    #   - `extras.poi_uv_scroll`: the animated UV scroll speed, in texture
    #     repeats per second (PoiBuilder writes the material metadata through
    #     Godot's glTF writer). A scrolling texture must stay a standalone,
    #     repeat-wrapped texture: an offset applied to an atlas slot would drag
    #     the tile across its slot border.
    #   - `alphaMode`: BLEND means a soft alpha, which needs 8 bits per channel
    #     (5551 has one) and so must NOT be packed into a 5551 atlas either.
    materials_gltf = gltf.get("materials", [])
    textures_gltf = gltf.get("textures", [])
    material_scroll = {}    # glTF material index -> (speed_u, speed_v)
    material_alpha = {}     # glTF material index -> PBM_ALPHA_*
    atlas_exempt_images = set()  # raw image indices that must stay standalone
    for mat_idx, mat in enumerate(materials_gltf):
        gltf_alpha = mat.get("alphaMode", "OPAQUE")
        if gltf_alpha == "BLEND":
            material_alpha[mat_idx] = PBM_ALPHA_BLEND
        elif gltf_alpha == "MASK":
            material_alpha[mat_idx] = PBM_ALPHA_CUTOUT
        else:
            material_alpha[mat_idx] = PBM_ALPHA_NONE

        bct = mat.get("pbrMetallicRoughness", {}).get("baseColorTexture", {})
        t_idx = bct.get("index", -1)
        src_img = -1
        if 0 <= t_idx < len(textures_gltf):
            src_img = textures_gltf[t_idx].get("source", -1)

        extras = mat.get("extras") or {}
        s = extras.get("poi_uv_scroll")
        if isinstance(s, (list, tuple)) and len(s) >= 2:
            su, sv = float(s[0]), float(s[1])
            if su != 0.0 or sv != 0.0:
                material_scroll[mat_idx] = (su, sv)
                if src_img >= 0:
                    atlas_exempt_images.add(src_img)
        if gltf_alpha == "BLEND" and src_img >= 0:
            atlas_exempt_images.add(src_img)

    if material_scroll:
        print(f"Found {len(material_scroll)} scrolling material(s); "
              f"{len(atlas_exempt_images)} texture(s) kept out of the atlases.")
    
    # Separate Base Textures from 128x128 Baked Tiles
    base_images = []
    tile_images = []
    
    for img_idx, img_info in enumerate(raw_images):
        bv = gltf["bufferViews"][img_info["bufferView"]]
        offset = bv.get("byteOffset", 0)
        length = bv["byteLength"]
        img_bytes = bin_data[offset : offset + length]
        pil_img = Image.open(io.BytesIO(img_bytes)).convert("RGBA")
        
        name = img_info.get("name", f"img_{img_idx}")
        # An image is an individual tile if its size is 128x128 or its name
        # says BakedTile -- unless a scrolling or blending material samples it,
        # in which case it stays a standalone base texture (see above).
        if img_idx not in atlas_exempt_images and (pil_img.size == (128, 128) or "BakedTile" in name):
            tile_images.append((img_idx, name, pil_img))
        else:
            base_images.append((img_idx, name, pil_img))

    # Deduplicate 128x128 baked tiles
    unique_tiles = {} # hash -> (unique_id, pil_img)
    img_to_unique_tile = {}
    for img_idx, name, img in tile_images:
        h = hash(img.tobytes())
        if h not in unique_tiles:
            unique_tiles[h] = (len(unique_tiles), img)
        img_to_unique_tile[img_idx] = unique_tiles[h][0]

    print(f"Deduplicated {len(tile_images)} baked tiles into {len(unique_tiles)} unique tile images.")

    # Pack unique 128x128 tiles into 512x512 Atlases (16 tiles per atlas, 4x4 grid)
    atlases = [] # list of 512x512 PIL Images
    tile_to_atlas_map = {} # unique_id -> (atlas_local_idx, col, row)

    tile_list = sorted(list(unique_tiles.values()), key=lambda x: x[0])
    for uid, t_img in tile_list:
        atlas_local_idx = uid // 16
        slot = uid % 16
        col = slot % 4
        row = slot // 4
        while len(atlases) <= atlas_local_idx:
            atlases.append(Image.new("RGBA", (512, 512), (0, 0, 0, 255)))
        atlases[atlas_local_idx].paste(t_img, (col * 128, row * 128))
        tile_to_atlas_map[uid] = (atlas_local_idx, col, row)

    print(f"Packed tiles into {len(atlases)} 512x512 atlas textures.")

    # Collect baseColorFactor from materials for any tinted base textures
    img_base_colors = {}
    materials_gltf = gltf.get("materials", [])
    textures_gltf = gltf.get("textures", [])
    for mat in materials_gltf:
        pbr = mat.get("pbrMetallicRoughness", {})
        col = pbr.get("baseColorFactor", [1.0, 1.0, 1.0, 1.0])
        base_tex = pbr.get("baseColorTexture", {})
        t_idx = base_tex.get("index", -1)
        if t_idx >= 0 and t_idx < len(textures_gltf):
            s_idx = textures_gltf[t_idx].get("source", -1)
            if s_idx >= 0 and (col[0] < 0.999 or col[1] < 0.999 or col[2] < 0.999):
                img_base_colors[s_idx] = col

    # Assemble Final Textures Table
    textures = []
    img_to_tex_mapping = {} # raw_img_idx -> { "tex_id": int, "is_atlas": bool, "col": int, "row": int }
    # 1. Base textures
    for img_idx, name, pil_img in base_images:
        w, h = pil_img.size
        pot_w = next_pot(w); pot_h = next_pot(h)
        if pot_w != w or pot_h != h:
            pil_img = pil_img.resize((pot_w, pot_h), Image.Resampling.BILINEAR)
            w, h = pot_w, pot_h
        if img_idx in img_base_colors:
            bcol = img_base_colors[img_idx]
            r, g, b, a = pil_img.split()
            r = r.point(lambda p: int(p * bcol[0]))
            g = g.point(lambda p: int(p * bcol[1]))
            b = b.point(lambda p: int(p * bcol[2]))
            pil_img = Image.merge("RGBA", (r, g, b, a))
        # The image's alpha mode is the strongest any material using it needs.
        mode = PBM_ALPHA_NONE
        for mat_idx, m_alpha in material_alpha.items():
            bct_m = materials_gltf[mat_idx].get("pbrMetallicRoughness", {}).get("baseColorTexture", {})
            t_m = bct_m.get("index", -1)
            if t_m >= 0 and t_m < len(textures_gltf) and textures_gltf[t_m].get("source", -1) == img_idx:
                mode = max(mode, m_alpha)
        # Soft alpha needs the 8 bits per channel that 5551 cannot carry.
        tex_data, fmt, has_a = convert_pil_to_bytes(pil_img, format_16bit and mode != PBM_ALPHA_BLEND)
        if mode == PBM_ALPHA_NONE and has_a:
            # Opaque material, transparent art: the pixels still need the alpha
            # pass, as a cutout.
            mode = PBM_ALPHA_CUTOUT
        tex_id = len(textures)
        textures.append({
            "name": name[:31],
            "width": w, "height": h,
            "format": fmt, "alpha_mode": mode,
            "data": tex_data
        })
        img_to_tex_mapping[img_idx] = { "tex_id": tex_id, "is_atlas": False, "col": 0, "row": 0 }

    # 2. Atlas textures
    atlas_start_tex_id = len(textures)
    for a_idx, atlas_img in enumerate(atlases):
        tex_data, fmt, has_a = convert_pil_to_bytes(atlas_img, format_16bit)
        tex_id = len(textures)
        textures.append({
            "name": f"TileAtlas_{a_idx}"[:31],
            "width": 512, "height": 512,
            "format": fmt,
            # Baked tiles are 5551, so their alpha can only cut a texel out.
            "alpha_mode": PBM_ALPHA_CUTOUT if has_a else PBM_ALPHA_NONE,
            "data": tex_data
        })

    # Map each raw tile image index to its atlas texture ID and slot
    for img_idx, name, _ in tile_images:
        uid = img_to_unique_tile[img_idx]
        atlas_local_idx, col, row = tile_to_atlas_map[uid]
        img_to_tex_mapping[img_idx] = {
            "tex_id": atlas_start_tex_id + atlas_local_idx,
            "is_atlas": True,
            "col": col,
            "row": row
        }

    print(f"Total textures in PBM: {len(textures)} ({len(base_images)} base + {len(atlases)} atlases)")

    # Map materials to texture info
    material_to_tex_info = {}
    for mat_idx, mat in enumerate(gltf.get("materials", [])):
        pbr = mat.get("pbrMetallicRoughness", {})
        tex_info = pbr.get("baseColorTexture", None)
        if tex_info is not None:
            tex_idx = tex_info.get("index", 0)
            if "textures" in gltf and tex_idx < len(gltf["textures"]):
                t_obj = gltf["textures"][tex_idx]
                img_src = t_obj.get("source", 0)
                material_to_tex_info[mat_idx] = img_to_tex_mapping.get(img_src, None)
            else:
                material_to_tex_info[mat_idx] = None
        else:
            material_to_tex_info[mat_idx] = None

    # Process Nodes and World Transforms
    nodes = gltf.get("nodes", [])
    node_world_mats = [None] * len(nodes)
    
    def compute_world_transforms(node_idx, parent_mat):
        node = nodes[node_idx]
        local_mat = get_node_transform(node)
        world_mat = multiply_matrices(parent_mat, local_mat) if parent_mat else local_mat
        node_world_mats[node_idx] = world_mat
        for child_idx in node.get("children", []):
            compute_world_transforms(child_idx, world_mat)
    scene_idx = gltf.get("scene", 0)
    root_nodes = gltf.get("scenes", [{}])[scene_idx].get("nodes", list(range(len(nodes))))
    ident = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]
    for r_idx in root_nodes:
        if r_idx < len(nodes):
            compute_world_transforms(r_idx, ident)


    all_meshes = []
    all_colliders = []
    bounds_min = [float("inf"), float("inf"), float("inf")]
    bounds_max = [float("-inf"), float("-inf"), float("-inf")]

    # Group primitives by final tex_id (this naturally batches atlas tiles together!)
    mesh_buckets = {} # tex_id -> list of PbmVertex

    for node_idx, node in enumerate(nodes):
        node_name = node.get("name", f"node_{node_idx}")
        mat = node_world_mats[node_idx] or ident
        
        is_collider = node_name.startswith("Collider_") or node_name.startswith("collider_")
        mesh_idx = node.get("mesh", None)
        if mesh_idx is None:
            continue
            
        mesh_obj = gltf["meshes"][mesh_idx]
        for prim in mesh_obj.get("primitives", []):
            attrs = prim.get("attributes", {})
            pos_acc = attrs.get("POSITION", None)
            if pos_acc is None:
                continue
                
            positions = read_accessor_data(gltf, bin_data, pos_acc)
            uvs = read_accessor_data(gltf, bin_data, attrs["TEXCOORD_0"]) if "TEXCOORD_0" in attrs else [(0.0, 0.0)] * len(positions)
            colors = read_accessor_data(gltf, bin_data, attrs["COLOR_0"]) if "COLOR_0" in attrs else [(1.0, 1.0, 1.0, 1.0)] * len(positions)
            indices = read_accessor_data(gltf, bin_data, prim["indices"]) if "indices" in prim else list(range(len(positions)))
            
            mat_idx = prim.get("material", None)
            tex_mapping = material_to_tex_info.get(mat_idx, None) if mat_idx is not None else None
            
            if is_collider:
                coll_triangles = []
                for idx in indices:
                    p = positions[idx]
                    wp = matrix_multiply_vec3(mat, p)
                    coll_triangles.append(wp)
                all_colliders.append({
                    "name": node_name[:31],
                    "type": 2 if "ramp" in node_name.lower() else (0 if "box" in node_name.lower() else 1),
                    "triangles": coll_triangles
                })
            else:
                tex_id = tex_mapping["tex_id"] if tex_mapping else -1
                is_atlas = tex_mapping["is_atlas"] if tex_mapping else False
                col_slot = tex_mapping["col"] if tex_mapping else 0
                row_slot = tex_mapping["row"] if tex_mapping else 0
                scroll = material_scroll.get(mat_idx, (0.0, 0.0))

                # Bucket key: the scroll speed is a per-mesh property of the
                # file, so two materials sharing one texture but scrolling at
                # different speeds must not be merged into a single mesh --
                # one of the two animations would be lost.
                bucket = (tex_id, scroll)
                if bucket not in mesh_buckets:
                    mesh_buckets[bucket] = []
                    
                for idx in indices:
                    p = positions[idx]
                    wp = matrix_multiply_vec3(mat, p)
                    
                    for i in range(3):
                        bounds_min[i] = min(bounds_min[i], wp[i])
                        bounds_max[i] = max(bounds_max[i], wp[i])
                        
                    raw_uv = uvs[idx] if idx < len(uvs) else (0.0, 0.0)
                    col = colors[idx] if idx < len(colors) else (1.0, 1.0, 1.0, 1.0)
                    
                    # Atlas UV Remapping: slot (col_slot, row_slot) in 4x4 atlas (512x512)
                    if is_atlas:
                        u_c = max(0.0, min(1.0, raw_uv[0]))
                        v_c = max(0.0, min(1.0, raw_uv[1]))
                        # Edge-to-edge: a tile owns the full width of its slot.
                        # (The old half-texel inset mapped the tile onto texel
                        # *centres* 0..127, which leaves a one-texel band that
                        # no tile displays -- neighbouring tiles then do not
                        # meet and the pattern shifts at every seam.)
                        u_in_slot = u_c
                        v_in_slot = v_c
                        u_val = (col_slot + u_in_slot) * 0.25
                        v_val = (row_slot + v_in_slot) * 0.25
                    else:
                        u_val = raw_uv[0]
                        v_val = raw_uv[1]
                    r_b = int(max(0.0, min(1.0, col[0])) * 255.0)
                    g_b = int(max(0.0, min(1.0, col[1])) * 255.0)
                    b_b = int(max(0.0, min(1.0, col[2])) * 255.0)
                    a_b = int(max(0.0, min(1.0, col[3])) * 255.0) if len(col) > 3 else 255
                    c_int = r_b | (g_b << 8) | (b_b << 16) | (a_b << 24)
                    
                    mesh_buckets[bucket].append({
                        "u": float(u_val),
                        "v": float(v_val),
                        "color": c_int,
                        "x": float(wp[0]),
                        "y": float(wp[1]),
                        "z": float(wp[2]),
                    })

    # Group into spatial chunks of <= 384 vertices (128 triangles) or 6m x 6m cells
    # to give meshes tight bounding boxes and eliminate clipping bottleneck on huge floors!
    for (tex_id, scroll), vlist in mesh_buckets.items():
        batch_size = 384
        for i in range(0, len(vlist), batch_size):
            batch = vlist[i : i + batch_size]
            b_min = [float("inf"), float("inf"), float("inf")]
            b_max = [float("-inf"), float("-inf"), float("-inf")]
            for v in batch:
                b_min[0] = min(b_min[0], v["x"]); b_max[0] = max(b_max[0], v["x"])
                b_min[1] = min(b_min[1], v["y"]); b_max[1] = max(b_max[1], v["y"])
                b_min[2] = min(b_min[2], v["z"]); b_max[2] = max(b_max[2], v["z"])
            
            tex_name = textures[tex_id]["name"] if (tex_id >= 0 and tex_id < len(textures)) else f"mesh_t{tex_id}"
            all_meshes.append({
                "name": f"{tex_name}_{i // batch_size}"[:31],
                "texture_id": tex_id,
                "uv_scroll": scroll,
                "vertices": batch,
                "bounds_min": b_min,
                "bounds_max": b_max
            })
    if bounds_min[0] == float("inf"):
        bounds_min = [-10.0, 0.0, -10.0]
        bounds_max = [10.0, 5.0, 10.0]

    spawn_pos = [0.0, 1.6, 4.2]
    spawn_rot = 0.0

    # Metadata Chunk (PBM v2.0):
    metadata_entries = []

    # 1. Map Name (String)
    map_name_str = "PoiRetro Courtyard Showcase\x00".encode("utf-8")
    metadata_entries.append({
        "tag": "map_name",
        "type": PBM_META_STRING,
        "data": map_name_str
    })

    # 2. Player Spawn Point (JSON)
    spawn_json = json.dumps({
        "position": spawn_pos,
        "yaw": spawn_rot,
        "camera_fov": 65.0
    }).encode("utf-8") + b"\x00"
    metadata_entries.append({
        "tag": "player_spawn",
        "type": PBM_META_JSON,
        "data": spawn_json
    })

    # 3. Walkable Mesh Navigation Surface (Binary triangles: 2 triangles = 18 floats = 72 bytes)
    # Quad floor from (-4.0, -5.5) to (4.0, 5.0) at Y=0.0
    walkable_tris = [
        -4.0, 0.0, -5.5,   4.0, 0.0, -5.5,   4.0, 0.0,  5.0,
        -4.0, 0.0, -5.5,   4.0, 0.0,  5.0,  -4.0, 0.0,  5.0
    ]
    walkable_buf = struct.pack("<18f", *walkable_tris)
    metadata_entries.append({
        "tag": "walkable_mesh",
        "type": PBM_META_ENTITY,
        "data": walkable_buf
    })

    # 4. Cutscene / Event Trigger Areas (JSON)
    triggers_json = json.dumps([
        {
            "id": "cutscene_archway",
            "event": "on_enter_archway",
            "bounds_min": [-2.0, 0.0, -5.8],
            "bounds_max": [2.0, 3.5, -4.8],
            "oneshot": True
        }
    ]).encode("utf-8") + b"\x00"
    metadata_entries.append({
        "tag": "triggers",
        "type": PBM_META_JSON,
        "data": triggers_json
    })

    # 5. Particle Emitters (JSON)
    particles_json = json.dumps([
        {
            "id": "torch_sparks",
            "position": [2.5, 1.8, -4.5],
            "rate": 30,
            "lifetime": 1.2,
            "velocity": [0.0, 1.5, 0.0],
            "spread": 0.3,
            "color": "0xFF33AAFF"
        }
    ]).encode("utf-8") + b"\x00"
    metadata_entries.append({
        "tag": "particle_emitters",
        "type": PBM_META_JSON,
        "data": particles_json
    })

    # 6. Physics Rigid Bodies / Ball Pit (JSON)
    rigid_bodies_json = json.dumps({
        "type": "ball_pit",
        "count": 16,
        "radius": 0.22,
        "mass": 1.0,
        "restitution": 0.75,
        "spawn_min": [-0.8, 2.0, -0.8],
        "spawn_max": [0.8, 4.0, 0.8]
    }).encode("utf-8") + b"\x00"
    metadata_entries.append({
        "tag": "rigid_bodies",
        "type": PBM_META_JSON,
        "data": rigid_bodies_json
    })
    # 2. Scripted Entity: 3-Point Cyclic Patrol Sphere
    ent_name = b"PatrolSphere\x00".ljust(32, b"\x00")
    ent_type = PBM_ENTITY_PATROL_SPHERE
    ent_radius = 0.35
    ent_color = 0xFF00C8FF # Gold: A=255, B=0, G=200, R=255
    ent_speed = 2.5 # m/s
    waypoints = [
        -3.0, 1.2, -1.0,  # Waypoint 0 (near west stairs)
         0.0, 2.2, -4.5,  # Waypoint 1 (front of arched doorway)
         3.0, 1.2,  0.5   # Waypoint 2 (near east ramp)
    ]
    ent_data = struct.pack("<32sIfIfI9f", ent_name, ent_type, ent_radius, ent_color, ent_speed, 3, *waypoints)
    metadata_entries.append({
        "tag": "entities",
        "type": PBM_META_ENTITY,
        "data": ent_data
    })

    print(f"Writing PBMv3: {len(textures)} textures, {len(all_meshes)} meshes ({sum(len(m['vertices']) for m in all_meshes)} vertices), {len(all_colliders)} colliders, {len(metadata_entries)} metadata entries...")
    
    with open(pbm_path, "wb") as f:
        # Header (64 bytes)
        hdr = struct.pack(
            "<IIIIII4f6f",
            PBM_MAGIC,
            PBM_VERSION,
            len(textures),
            len(all_meshes),
            len(all_colliders),
            len(metadata_entries),
            spawn_pos[0], spawn_pos[1], spawn_pos[2], spawn_rot,
            bounds_min[0], bounds_min[1], bounds_min[2],
            bounds_max[0], bounds_max[1], bounds_max[2]
        )
        f.write(hdr)
        
        # Texture chunk
        for tex in textures:
            t_name = tex["name"].encode("ascii", errors="ignore")[:31].ljust(32, b"\x00")
            thdr = struct.pack(
                "<32sHHHHI",
                t_name,
                tex["width"],
                tex["height"],
                tex["format"],
                tex["alpha_mode"],
                len(tex["data"])
            )
            f.write(thdr)
            f.write(tex["data"])
            
        # Mesh chunk
        for m in all_meshes:
            m_name = m["name"].encode("ascii", errors="ignore")[:31].ljust(32, b"\x00")
            su, sv = m.get("uv_scroll", (0.0, 0.0))
            mhdr = struct.pack(
                "<32siI6fff",
                m_name,
                m["texture_id"],
                len(m["vertices"]),
                m["bounds_min"][0], m["bounds_min"][1], m["bounds_min"][2],
                m["bounds_max"][0], m["bounds_max"][1], m["bounds_max"][2],
                su, sv
            )
            f.write(mhdr)
            
            vbuf = bytearray(len(m["vertices"]) * 24)
            for vi, v in enumerate(m["vertices"]):
                struct.pack_into("<ffIfff", vbuf, vi * 24, v["u"], v["v"], v["color"], v["x"], v["y"], v["z"])
            f.write(vbuf)

        # Collider chunk
        for col in all_colliders:
            c_name = col["name"].encode("ascii", errors="ignore")[:31].ljust(32, b"\x00")
            tris = col["triangles"]
            n_tris = len(tris) // 3
            c_min = [min(p[i] for p in tris) for i in range(3)] if tris else [0,0,0]
            c_max = [max(p[i] for p in tris) for i in range(3)] if tris else [0,0,0]
            chdr = struct.pack(
                "<32sI6fI",
                c_name,
                col["type"],
                c_min[0], c_min[1], c_min[2],
                c_max[0], c_max[1], c_max[2],
                n_tris
            )
            f.write(chdr)
            if tris:
                cbuf = bytearray(len(tris) * 12)
                for vi, p in enumerate(tris):
                    struct.pack_into("<fff", cbuf, vi * 12, p[0], p[1], p[2])
                f.write(cbuf)

        # Metadata chunk (v2.0+)
        for mentry in metadata_entries:
            m_tag = mentry["tag"].encode("ascii", errors="ignore")[:31].ljust(32, b"\x00")
            m_data = mentry["data"]
            mhdr = struct.pack("<32sII", m_tag, mentry["type"], len(m_data))
            f.write(mhdr)
            f.write(m_data)
            # Pad to 4-byte alignment
            pad = (4 - (len(m_data) % 4)) % 4
            if pad > 0:
                f.write(b"\x00" * pad)

    size_mb = os.path.getsize(pbm_path) / (1024 * 1024)
    print(f"PBM map written successfully: {pbm_path} ({size_mb:.2f} MB)")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: pbm_conv.py <input.glb> <output.pbm> [--32bit]")
        sys.exit(1)
    
    use_16bit = "--32bit" not in sys.argv
    convert_glb_to_pbm(sys.argv[1], sys.argv[2], format_16bit=use_16bit)
