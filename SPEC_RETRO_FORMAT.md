# PoiBuilder Retro Map Binary Format Specification (.pbm)
**Version: 2.0 (PBM2)**  
**Status: Formal Standard**  
**Author: PoiBuilder Project**  
**Date: 2026-09-10**

---

## 1. Overview & Architectural Goals

The **PoiBuilder Retro Map** format (`.pbm`) is a compact, zero-overhead, memory-mapped binary 3D map format designed specifically for fixed-function and resource-constrained retro hardware (such as the Sony PlayStation Portable, Nintendo DS/3DS, Dreamcast, PlayStation 2) as well as custom low-overhead software and OpenGL ES 1.x/2.0 renderers.

### Core Design Principles
1. **Direct DMA / Hardware Alignment**: All vertex data is pre-interleaved into a single 24-byte structure matching native GPU registers (`GU_TEXTURE_32BITF | GU_COLOR_8888 | GU_VERTEX_32BITF | GU_TRANSFORM_3D` on Sony PSP GU). Vertices require zero runtime rearrangement or format conversion.
2. **Zero Runtime Decompression**: Textures are stored in native uncompressed power-of-two formats (16-bit `RGBA5551` or 32-bit `RGBA8888`) ready for immediate VRAM upload via DMA (`sceGuTexImage`).
3. **Texture Swizzling Support**: 16-bit textures can be swizzled into 16-byte $\times$ 8-row cache-friendly Morton/tile blocks to eliminate memory bus thrashing.
4. **Tile-Based Texture Atlasing**: Discrete baked tiles (splats, stamps, decals) are packed into 512x512 texture atlases with half-texel clamped UV coordinates.
5. **Baked Vertex Lighting & AO**: Static scene illumination (directional sun, omni lights, shadows, and hemisphere ambient occlusion) is fully pre-baked into 32-bit vertex colors (`0xAABBGGRR`).
6. **Built-in Physical Collision**: Dedicated bounding-box and triangle-mesh collision hulls are stored alongside visual meshes for native player collision and raycasting.
7. **Arbitrary Binary Metadata & Entity Scripting**: Version 2 introduces an extensible metadata chunk table for embedding arbitrary binary payloads, level descriptors, waypoints, scripting logic, and entity definitions directly within the map file.

---

## 2. File Structure & Memory Layout

A `.pbm` file is composed of five sequential contiguous binary chunks in Little-Endian byte order:

```
+-------------------------------------------------------------+
| PbmHeader (64 bytes)                                        |
+-------------------------------------------------------------+
| Texture Chunk (num_textures entries)                        |
|   ├── PbmTextureHeader (44 bytes)                           |
|   └── Raw Pixel Buffer (data_size bytes, 16-byte aligned)   |
|   └── ...                                                   |
+-------------------------------------------------------------+
| Mesh Chunk (num_meshes entries)                             |
|   ├── PbmMeshHeader (72 bytes)                              |
|   └── Vertex Buffer (num_vertices * 24 bytes, aligned)      |
|   └── ...                                                   |
+-------------------------------------------------------------+
| Collider Chunk (num_colliders entries)                      |
|   ├── PbmColliderHeader (68 bytes)                          |
|   └── Triangle Buffer (num_triangles * 36 bytes)            |
|   └── ...                                                   |
+-------------------------------------------------------------+
| Metadata Chunk (num_metadata entries) [NEW in v2.0]         |
|   ├── PbmMetadataHeader (40 bytes)                          |
|   └── Raw Payload (data_size bytes, 4-byte padded)          |
|   └── ...                                                   |
+-------------------------------------------------------------+
```

---

## 3. Header Specification

The file begins with an exact 64-byte header:

### `PbmHeader` (64 bytes, packed)

| Offset | Type | Field Name | Description |
|---|---|---|---|
| `0x00` | `uint32_t` | `magic` | Magic identifier. Must be `0x324D4250` (`"PBM2"` in ASCII Little-Endian). Version 1 used `0x314D4250` (`"PBM1"`). |
| `0x04` | `uint32_t` | `version` | Format major version number. Must be `2` for PBM2. |
| `0x08` | `uint32_t` | `num_textures` | Total number of texture records in the Texture Chunk. |
| `0x0C` | `uint32_t` | `num_meshes` | Total number of visual mesh records in the Mesh Chunk. |
| `0x10` | `uint32_t` | `num_colliders` | Total number of collision shapes in the Collider Chunk. |
| `0x14` | `uint32_t` | `num_metadata` | Total number of metadata entries in the Metadata Chunk. (`0` in v1). |
| `0x18` | `float[3]` | `spawn_pos` | Default player camera/spawn position $(X, Y, Z)$ in world meters. |
| `0x24` | `float` | `spawn_rot` | Default player camera spawn yaw orientation in radians. |
| `0x28` | `float[3]` | `bounds_min` | Scene Axis-Aligned Bounding Box (AABB) minimum coordinates $(X, Y, Z)$. |
| `0x34` | `float[3]` | `bounds_max` | Scene Axis-Aligned Bounding Box (AABB) maximum coordinates $(X, Y, Z)$. |
| `0x40` | `uint8_t[0]`| *(end)* | Total size = 64 bytes. |

### Versioning & Breaking Change Policy
- **Minor Version Increments**: Backwards-compatible additions (e.g. new optional metadata tags or hints) MUST NOT increment the major version.
- **Breaking Format Changes**: Any structural change to existing headers, vertex layouts, or chunk order MUST increment `PBM_VERSION` and update the magic string (e.g. `PBM3`).
- **Loader Compliance Rule**:
  Loaders MUST inspect `header.version`. If `header.version > PBM_SUPPORTED_VERSION`, the loader MUST reject the file with an explicit diagnostic:
  `[PBM] Error: Incompatible map version %u (supported: 1..%u). Breaking format change detected.`
  Loaders supporting version 2 SHOULD maintain backwards-compatibility with version 1 files by detecting `PBM1` (`0x314D4250`, version 1, 60-byte header) and defaulting `num_metadata = 0`.

---

## 4. Texture Chunk Specification

The Texture Chunk contains `header.num_textures` sequential records. Each record consists of a 44-byte `PbmTextureHeader` followed immediately by `data_size` bytes of raw uncompressed pixel data.

### `PbmTextureHeader` (44 bytes, packed)

| Offset | Type | Field Name | Description |
|---|---|---|---|
| `0x00` | `char[32]` | `name` | Null-terminated ASCII texture name / identifier (max 31 chars + `\0`). |
| `0x20` | `uint16_t` | `width` | Texture width in pixels. Must be a power of two ($\ge 16$, e.g. 128, 256, 512). |
| `0x22` | `uint16_t` | `height` | Texture height in pixels. Must be a power of two ($\ge 8$, e.g. 128, 256, 512). |
| `0x24` | `uint16_t` | `format` | Pixel storage format (`PBM_TEX_FMT_*`). |
| `0x26` | `uint16_t` | `has_alpha` | `1` if texture has transparent pixels (alpha < 250); `0` if solid opaque. |
| `0x28` | `uint32_t` | `data_size` | Length of pixel payload in bytes ($= \text{width} \times \text{height} \times \text{bytes\_per\_pixel}$). |

### Pixel Storage Formats

| Constant | Value | BPP | Layout Description |
|---|---|---|---|
| `PBM_TEX_FMT_RGBA8888` | `0` | 32 | 32-bit direct color: 8 bits Red, 8 bits Green, 8 bits Blue, 8 bits Alpha. |
| `PBM_TEX_FMT_RGBA5551` | `1` | 16 | 16-bit direct color: 5 bits Red, 5 bits Green, 5 bits Blue, 1 bit Alpha (`R:0..4, G:5..9, B:10..14, A:15`). Halves VRAM usage. |
| `PBM_TEX_FMT_RGBA4444` | `2` | 16 | 16-bit direct color: 4 bits Red, 4 bits Green, 4 bits Blue, 4 bits Alpha. |
| `PBM_TEX_FMT_RGB565`   | `3` | 16 | 16-bit direct color: 5 bits Red, 6 bits Green, 5 bits Blue, 0 bits Alpha. |

### Memory Swizzling Specification
For 16-bit textures (`RGBA5551`) targeting Sony PSP GU hardware, pixels SHOULD be pre-swizzled or runtime-swizzled into 16-byte $\times$ 8-row tiles:
```c
void swizzle_texture_16(uint8_t* out, const uint8_t* in, unsigned int width, unsigned int height) {
    unsigned int block_address = 0;
    unsigned int row_blocks = (width * 2) / 16;
    for (unsigned int y = 0; y < height; ++y) {
        for (unsigned int x = 0; x < width * 2; x += 16) {
            unsigned int block_x = x / 16;
            unsigned int block_y = y / 8;
            unsigned int block_index = block_y * row_blocks + block_x;
            unsigned int block_offset = block_index * 128;
            unsigned int row_in_block = y % 8;
            memcpy(&out[block_offset + row_in_block * 16], &in[y * width * 2 + x], 16);
        }
    }
}
```

---

## 5. Mesh Chunk Specification

The Mesh Chunk contains `header.num_meshes` records. Each record consists of a 72-byte `PbmMeshHeader` followed immediately by `num_vertices * sizeof(PbmVertex)` bytes of interleaved vertex data.

### `PbmMeshHeader` (72 bytes, packed)

| Offset | Type | Field Name | Description |
|---|---|---|---|
| `0x00` | `char[32]` | `name` | Null-terminated ASCII mesh name (e.g. `"CourtyardFloor_0"`). |
| `0x20` | `int32_t` | `texture_id` | Zero-based index into Texture Chunk, or `-1` if untextured (vertex color only). |
| `0x24` | `uint32_t` | `num_vertices` | Total vertices. Must be a multiple of 3 ($\text{triangles} = \text{num\_vertices} / 3$). |
| `0x28` | `float[3]` | `bounds_min` | Mesh AABB minimum coordinates $(X, Y, Z)$ in world space. |
| `0x34` | `float[3]` | `bounds_max` | Mesh AABB maximum coordinates $(X, Y, Z)$ in world space. |
| `0x40` | `float[2]` | `reserved` | Reserved for future spatial partitioning tags / padding to 72 bytes. |

### `PbmVertex` (24 bytes, 4-byte aligned)

| Offset | Type | Field Name | Description |
|---|---|---|---|
| `0x00` | `float` | `u` | Horizontal texture coordinate ($U$). Normalized $0.0 \dots 1.0$, or atlas sub-slot. |
| `0x04` | `float` | `v` | Vertical texture coordinate ($V$). Normalized $0.0 \dots 1.0$, or atlas sub-slot. |
| `0x08` | `uint32_t` | `color` | Packed 32-bit vertex color: `0xAABBGGRR` (Direct hardware Gouraud / Ambient Occlusion lighting). |
| `0x0C` | `float` | `x` | World-space X coordinate in meters. |
| `0x10` | `float` | `y` | World-space Y coordinate in meters. |
| `0x14` | `float` | `z` | World-space Z coordinate in meters. |

**Hardware Format Bitmask (Sony GU)**:
```c
GU_TEXTURE_32BITF | GU_COLOR_8888 | GU_VERTEX_32BITF | GU_TRANSFORM_3D
```

---

## 6. Collider Chunk Specification

The Collider Chunk contains `header.num_colliders` collision hulls. Each record has a 68-byte `PbmColliderHeader` followed by triangle vertex data if `type == PBM_COL_TRIMESH`.

### `PbmColliderHeader` (68 bytes, packed)

| Offset | Type | Field Name | Description |
|---|---|---|---|
| `0x00` | `char[32]` | `name` | Collider name (e.g. `"Collider_NorthWall"`). |
| `0x20` | `uint32_t` | `type` | Collider type: `0` = BOX, `1` = TRIMESH, `2` = RAMP. |
| `0x24` | `float[3]` | `bounds_min` | Collider AABB minimum $(X, Y, Z)$. |
| `0x30` | `float[3]` | `bounds_max` | Collider AABB maximum $(X, Y, Z)$. |
| `0x3C` | `uint32_t` | `num_triangles` | Number of triangles in payload (`0` for simple AABB BOX). |
| `0x40` | `uint32_t` | `reserved` | Padding to 68 bytes. |

- If `num_triangles > 0`, exactly `num_triangles * 9 * sizeof(float)` bytes follow (3 vertices $\times$ 3 floats $(x, y, z)$ per triangle, total 36 bytes per triangle).

---

## 7. Metadata Chunk Specification (New in v2.0)

The Metadata Chunk contains `header.num_metadata` entries. This chunk allows embedding arbitrary binary metadata, scripting tables, entity lists, audio triggers, and custom data blocks.

### `PbmMetadataHeader` (40 bytes, packed)

| Offset | Type | Field Name | Description |
|---|---|---|---|
| `0x00` | `char[32]` | `tag` | Null-terminated ASCII tag identifier (e.g. `"map_name"`, `"entities"`, `"waypoints"`). |
| `0x20` | `uint32_t` | `type` | Payload type identifier (`PBM_META_*`). |
| `0x24` | `uint32_t` | `data_size` | Length of payload in bytes. |

### Metadata Type Constants

| Constant | Value | Description |
|---|---|---|
| `PBM_META_RAW` | `0` | Raw unformatted binary blob. |
| `PBM_META_STRING` | `1` | UTF-8 / ASCII null-terminated text string. |
| `PBM_META_JSON` | `2` | Plain UTF-8 JSON object string for flexible high-level scripting. |
| `PBM_META_ENTITY` | `3` | Binary structured entity record list (see Section 8). |

Following each `PbmMetadataHeader`, exactly `data_size` bytes of binary data are stored. If `data_size` is not a multiple of 4, the writer MUST pad with `0x00` bytes to maintain 4-byte alignment for subsequent headers.

---

## 8. End-to-End Walkthrough: Godot 4 Authoring to Custom Engine Implementation

> **CRITICAL ARCHITECTURAL DISTINCTION — RECIPES VS. STANDARD**:  
> The specific entity tags and structures detailed below (`"walkable_mesh"`, `"triggers"`, `"player_spawn"`, `"particle_emitters"`, `"rigid_bodies"`, `"entities"`) are **EXAMPLE IMPLEMENTATION RECIPES**, **NOT** fixed schema constraints of the PBMv2 specification.
>
> The PBMv2 specification defines **only the general binary lump transport container** (Section 7: 32-byte tag string, 32-bit type integer, 32-bit length integer, and raw payload bytes). The payload data can be **anything you want**: flat binary structs, UTF-8 JSON, byte-encoded bytecode, dialog trees, navmesh graphs, or audio cue tables. You are completely free to invent your own tags and payload formats for your custom game engine.
>
> The walkthrough below demonstrates tested, real-world patterns for authoring custom data in the Godot 3D editor, exporting via PoiBuilder, and consuming them in custom C / Raylib / PSP game engines.

```
  [ Godot 4 3D Editor ]           [ PoiBuilder Exporter ]            [ Custom Engine / Raylib / PSP ]
  ---------------------           -----------------------            --------------------------------
  1. Place Visual Geometry        PBMapExporter:                     pbm_load("map.pbm"):
  2. Place Marker3D (PlayerSpawn) -> Discovers scene nodes           -> Uploads GPU textures & meshes
  3. Place Area3D (Trigger)       -> Computes world transforms       -> Parses metadata lump table
  4. Place Mesh (Walkable)        -> Extracts AABB bounds / triangles-> Initializes Player at Spawn
  5. Attach Inspector Metadata    -> Encodes JSON / Binary lumps     -> Drops rays onto Walkable Mesh
  6. Click "Export Retro PBM"     -> Writes PBMv2 (64-byte header)   -> Checks Trigger containment
                                                                     -> Steps Physics Ball Pit & Particles
```

---

### Step 1: Authoring in Godot 4 Editor

In the Godot 3D Viewport and Scene Dock, authoring entities uses standard, intuitive node patterns:

#### 1. Player Spawn Point (`tag = "player_spawn"`, JSON)
1. Add a `Marker3D` or `Node3D` anywhere in your level.
2. Name the node `PlayerSpawn` (or any name starting with `Spawn`).
3. Rotate and position it where the player should begin.
4. *(Optional)* In the Inspector, scroll to **Metadata**, click **Add Metadata**, and set `camera_fov = 75.0`.

#### 2. Walkable Mesh Navigation Surface (`tag = "walkable_mesh"`, Binary Triangles)
1. When creating stepped terraced stairs, complex ruins, or decorative balustrades, computing exact physics collision against thousands of detailed visual triangles is slow and prone to snagging.
2. Add an invisible `MeshInstance3D` named `Walkable_Floor` spanning the walkable area.
3. Assign it a simple quad or low-poly ramp surface and set `visible = false`.
4. The exporter extracts its triangles into `"walkable_mesh"` (`num_triangles * 9 * sizeof(float)`) and excludes it from opaque visual drawing so it does not render twice.

#### 3. Event / Cutscene Trigger Area (`tag = "triggers"`, JSON)
1. Add an `Area3D` or simple box `MeshInstance3D` named `Trigger_VaultDoor`.
2. Position and scale it over the doorway or entrance volume.
3. In the Inspector, under **Metadata**, click **Add Metadata**:
   - `event` (String): `"open_vault_cutscene"`
   - `dialogue_id` (String): `"vault_lore_01"`
   - `oneshot` (bool): `true`

#### 4. Particle Emitter Marker (`tag = "particle_emitters"`, JSON)
1. Add a `Marker3D` or `GPUParticles3D` named `Emitter_Torch`.
2. Position it on a wall bracket or campfire.
3. In the Inspector, add metadata:
   - `rate` (int): `45`
   - `lifetime` (float): `2.0`
   - `velocity` (Vector3): `(0.0, 3.0, 0.0)`
   - `spread` (float): `0.4`
   - `color` (Color): `Color(1.0, 0.5, 0.1, 1.0)`

#### 5. Physics Rigid Bodies / Ball Pit (`tag = "rigid_bodies"`, JSON)
1. Add a container `Node3D` named `BallPit`.
2. In the Inspector, add metadata:
   - `count` (int): `24`
   - `radius` (float): `0.22`
   - `restitution` (float): `0.85`
   - `mass` (float): `1.2`

#### 6. Arbitrary Custom Gameplay Entities (NPCs, Loot, Audio)
On **ANY** node in your Godot scene, you can attach arbitrary custom metadata:
1. Add metadata `poi_metadata_tag = "dialogue_npc"`.
2. Add your custom fields: `npc_name = "Elder Olaru"`, `quest_id = 101`, `greeting = "Welcome to the Sunken Vault."`.
3. The exporter will package all metadata on that node into a clean JSON lump under tag `"dialogue_npc"`.

---

### Step 2: Exporting from Godot via PoiBuilder

In the PoiBuilder Toolbar, click **Export** $\rightarrow$ select **PoiRetro (.pbm)** $\rightarrow$ click **Export**.

Under the hood, `PBMapExporter`:
1. Iterates the authored Godot scene tree (`root`).
2. Resolves world-space transforms (`_get_world_transform`).
3. Dynamically extracts `player_spawn`, `walkable_mesh`, `triggers`, `particle_emitters`, `rigid_bodies`, and custom metadata lumps.
4. Subdivides large surfaces into $\le 384$-vertex spatial chunks and packs textures into $512 \times 512$ atlases.
5. Writes the `.pbm` v2 binary file with the 64-byte header and lump table.

---

### Step 3: Loading & Parsing in a Custom Engine (C / Raylib / PSP)

In your custom engine, loading metadata is simple and decoupled:

```c
// 1. Read PBM Header
PbmHeader hdr;
fread(&hdr, sizeof(PbmHeader), 1, file);

// 2. Read GPU textures and visual mesh chunks
// ...

// 3. Read Extensible Metadata Lumps
for (uint32_t i = 0; i < hdr.num_metadata; ++i) {
    PbmMetadataHeader mhdr;
    fread(&mhdr, sizeof(PbmMetadataHeader), 1, file);
    
    uint8_t* payload = malloc(mhdr.data_size + 1);
    fread(payload, mhdr.data_size, 1, file);
    payload[mhdr.data_size] = '\0';
    
    // Skip 4-byte padding
    uint32_t pad = (4 - (mhdr.data_size % 4)) % 4;
    if (pad > 0) fseek(file, pad, SEEK_CUR);

    // Route by tag:
    if (strcmp(mhdr.tag, "walkable_mesh") == 0) {
        load_walkable_triangles((float*)payload, mhdr.data_size / sizeof(float));
    } else if (strcmp(mhdr.tag, "triggers") == 0) {
        parse_triggers_json((const char*)payload);
    } else if (strcmp(mhdr.tag, "player_spawn") == 0) {
        parse_spawn_json((const char*)payload);
    } else if (strcmp(mhdr.tag, "particle_emitters") == 0) {
        parse_emitters_json((const char*)payload);
    } else if (strcmp(mhdr.tag, "rigid_bodies") == 0) {
        init_ball_pit_from_json((const char*)payload);
    } else if (strcmp(mhdr.tag, "dialogue_npc") == 0) {
        spawn_npc_from_json((const char*)payload);
    }
    
    free(payload);
}
```

---

### Step 4: Real-time Runtime Execution in Custom Engine

In your frame loop:
1. **Ground Snapping**: When the player moves, sample ground elevation from the walkable triangles via 2D barycentric raycast:
   `player.y = get_walkable_ground_y(player.x, player.z, 0.0f) + player_eye_height;`
2. **Trigger Evaluation**: Check if the player position is contained in any trigger's AABB:
   `if (is_in_bounds(player.pos, trigger.min, trigger.max)) fire_event(trigger.event);`
3. **Physics Simulation (Ball Pit)**:
   Integrate gravity, resolve floor bounces ($v_y = -v_y \times \text{restitution}$), boundary walls, and elastic sphere-sphere collisions:
   ```c
   Vector3 diff = Vector3Subtract(b2->pos, b1->pos);
   float dist = Vector3Length(diff);
   float min_dist = b1->radius + b2->radius;
   if (dist < min_dist && dist > 0.0001f) {
       Vector3 normal = Vector3Scale(diff, 1.0f / dist);
       float overlap = 0.5f * (min_dist - dist);
       b1->pos = Vector3Subtract(b1->pos, Vector3Scale(normal, overlap));
       b2->pos = Vector3Add(b2->pos, Vector3Scale(normal, overlap));
       float k = Vector3DotProduct(Vector3Subtract(b1->vel, b2->vel), normal);
       if (k > 0.0f) {
           float impulse = (1.0f + b1->restitution) * k / (b1->mass + b2->mass);
           b1->vel = Vector3Subtract(b1->vel, Vector3Scale(normal, impulse * b2->mass));
           b2->vel = Vector3Add(b2->vel, Vector3Scale(normal, impulse * b1->mass));
       }
   }
   ```
4. **Particle Stepping**:
   Spawn particles over time and integrate velocity and gravity ($p + v \cdot \Delta t + \frac{1}{2} g \cdot \Delta t^2$).

---

### Step 5: Interactive Scratch Project & Re-Export Loop

To safely edit the map, poke around in Godot, and re-export to test in Raylib:

```bash
# 1. Open Godot Editor on isolated scratch project with the showcase map:
./scratch.sh
# (or via unified runner: ./test.sh scratch)

# 2. Edit geometry, move entities, adjust triggers or ball pit parameters in Godot

# 3. Re-export and test directly:
# In scratch project terminal, run:
#   ./export_to_raylib.sh
# Or launch Raylib runner directly:
#   ./run_raylib.sh
```
## 9. Hardware Clipping & Performance Rules (PSP Guidelines)

1. **Near-Plane Distance**:
   Perspective projection near plane MUST be set between `0.05f` and `0.10f` meters (`sceGumPerspective(fov, aspect, 0.08f, 200.0f)`). A near plane of `0.5m` causes geometry within arm's reach of floors and stairs to intersect the near clipping plane, inducing heavy hardware re-triangulation.
2. **Hardware Clipping Planes**:
   Call `sceGuEnable(GU_CLIP_PLANES)` to ensure the hardware near-plane clipper handles near-Z triangles correctly without driver fallbacks.
3. **Guardband Culling**:
   Set `sceGuViewport(2048, 2048, 480, 272)` and `sceGuOffset(2048 - 240, 2048 - 136)`. Triangles within the $4096 \times 4096$ virtual coordinate space avoid software clipping and rasterize at full hardware fillrate.
4. **Spatial Mesh Chunking**:
   Large planar meshes (such as 12m terrain floors) SHOULD be subdivided into $\le 6\text{m} \times 6\text{m}$ spatial chunks rather than merged into a single multi-thousand-vertex draw call. This ensures that off-screen chunks are culled and only local triangles undergo near-plane testing.

---

## 10. Compliance Verification

A compliant PBM exporter and loader MUST pass the following tests:
1. `magic == 0x324D4250` and `version == 2`.
2. Reject files where `version > 2` with explicit error logging.
3. Successfully load textures with power-of-two dimensions and 16-byte memory alignment.
4. Successfully parse arbitrary metadata entries by tag and type.
5. 100% binary validation against the reference Python oracle (`pbm_conv.py`) and GDScript exporter (`pb_pbm_exporter.gd`).
