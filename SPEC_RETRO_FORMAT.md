# PoiBuilder Retro Map Binary Format Specification (.pbm)
**Version: 3.0 (PBM3)**  
**Status: Formal Standard**  
**Author: PoiBuilder Project**  
**Date: 2026-09-10**

> **What v3 added on top of that:** the standard lumps in §8 — payload layouts
> the specification defines, carried by the extensible metadata table (§7). They
> need no version change: a loader that does not know a lump's tag skips it.
>
> **What v3 changed (breaking):** the mesh header grew from 64 to 72 bytes by
> appending the animated-UV-scroll words `uv_scroll_u` / `uv_scroll_v`, and the
> texture header's `has_alpha` became a three-valued `alpha_mode`
> (`NONE` / `CUTOUT` / `BLEND`). Both changes are what makes scrolling and
> translucent textures a first-class part of the format instead of something an
> engine has to infer. v1 and v2 files still load (see §3.1) — their meshes are
> simply static and their alpha is a cutout.

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
| `0x00` | `uint32_t` | `magic` | Magic identifier. Must be `0x334D4250` (`"PBM3"` in ASCII Little-Endian). Version 2 used `0x324D4250` (`"PBM2"`), version 1 `0x314D4250` (`"PBM1"`). |
| `0x04` | `uint32_t` | `version` | Format major version number. Must be `3` for PBM3. |
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
  Loaders supporting version 3 SHOULD maintain backwards-compatibility with version 1 and 2 files.

### 3.1 Version Differences a Loader Must Handle

| | v1 | v2 | v3 |
|---|---|---|---|
| magic | `PBM1` | `PBM2` | `PBM3` |
| `PbmHeader` size | 60 | 64 | 64 |
| Metadata chunk | absent (`num_metadata` = 0) | present | present |
| Mesh header size | 64 | 64 | **72** |
| Texture `has_alpha` | 0 / 1 | 0 / 1 | **`alpha_mode` 0 / 1 / 2** |

Practical rule: read the version first, then read `PBM_MESH_HEADER_V2` (64) bytes
of every mesh header when the version is below 3, and treat the missing
`uv_scroll_*` words as `0,0` (static). A v1/v2 map therefore renders exactly as
it did before the upgrade.

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
| `0x26` | `uint16_t` | `alpha_mode` | How the surface blends, `PBM_ALPHA_*` (see below). v1/v2 called this `has_alpha` and used only `0`/`1`, which load as `NONE`/`CUTOUT`. |
| `0x28` | `uint32_t` | `data_size` | Length of pixel payload in bytes ($= \text{width} \times \text{height} \times \text{bytes\_per\_pixel}$). |

### Alpha Modes

| Constant | Value | Meaning | Engine behaviour |
|---|---|---|---|
| `PBM_ALPHA_NONE` | `0` | Fully opaque | Opaque pass; mip chain built. |
| `PBM_ALPHA_CUTOUT` | `1` | Hard-edged transparency (foliage, decals, lace) | Alpha-tested in the alpha pass (a threshold near 1/16 of full range); mip chain built with an **alpha-preserving combine** — ANY opaque texel of a 2x2 block keeps the level's texel opaque, so the silhouette dilates by half a texel per level. A plain box filter would instead make every level further transparent and eat the silhouette, which is why an implementation may be tempted to ship cutouts with no chain; doing so costs a texture-cache miss per fragment on art that is routinely 256x512 or larger. |
| `PBM_ALPHA_BLEND` | `2` | Soft, partial alpha (water, glass, smoke, wetness overlays) | Blended in the alpha pass with a zero threshold (only fully transparent texels are discarded, which keeps early-Z working); mip chain built. |

**A `BLEND` texture MUST be stored as `PBM_TEX_FMT_RGBA8888`.** The 16-bit
formats carry a single alpha bit, which can only cut a texel out — a soft edge
quantised to it becomes a hard one, which is precisely the difference between
the two modes. Exporters derive the mode from the authoring tool (in Godot:
`transparency = Alpha` → `BLEND`, `Alpha Scissor`/`Alpha Hash` → `CUTOUT`,
everything else → `NONE`; in glTF: `alphaMode` `BLEND` / `MASK` / absent).

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
| `0x40` | `float` | `uv_scroll_u` | Animated UV scroll along U (§5.1). `0.0` = static. |
| `0x44` | `float` | `uv_scroll_v` | Animated UV scroll along V (§5.1). `0.0` = static. |

*(The 64-byte v2 mesh header ended at `0x40`; the two scroll words are what
makes a v3 header 72 bytes.)*

### 5.1 Standard Specification: Animated UV Scrolling

The PBM specification formalizes animated scrolling textures through a **minimal, universal common denominator**: a continuous 2D linear translation offset.

#### 5.1.1 Scope and Guarantees

The specification guarantees **only** the simplest linear translation model:
```
uv(t) = uv(0) + t * (uv_scroll_u, uv_scroll_v)
```
Where:
- $t$ is scene elapsed time in seconds.
- `uv_scroll_u` and `uv_scroll_v` are float values expressing velocity in **texture repeats per second** along the surface's local UV axes.
- `0.0, 0.0` denotes a static mesh.

**Intentional Minimalism:** The format deliberately does *not* specify full animated UV node graphs, arbitrary rotation matrices, non-linear spline curves, or procedural UV distortion. Restricting the guarantee to linear 2D translation ensures universal compatibility across:
1. **Fixed-function retro hardware:** Sony PlayStation Portable (PSP) Graphics Engine (GE) via hardware coordinate offset registers (`sceGuTexOffset`), with zero CPU vertex transformation, zero bus traffic, and zero allocation.
2. **Modern GPU pipelines:** Direct material shader uniforms (`StandardMaterial3D.uv1_offset`) or vertex shader additions with near-zero overhead.
3. **Software and minimal rasterizers:** Single addition per vertex or scanline iterator step.

#### 5.1.2 Format Constraints

To guarantee correct rasterization across all targets:
1. **Standalone Texture Enforcement:** Any mesh with non-zero scroll velocity **MUST** reference a dedicated, standalone texture. It must **NEVER** be packed into a shared tile atlas. Atlased textures use clamped sampling within sub-rectangle coordinate slots; applying an offset to an atlased mesh would drag texture coordinates across slot boundaries into neighboring tiles.
2. **Repeat Wrapping (`GU_REPEAT` / `GL_REPEAT`):** The referenced texture must wrap seamlessly along the scrolling axis.
3. **Alpha Blending:** Scrolling surfaces requiring soft transparency (e.g. water streams, mist, glass) use `alpha_mode = PBM_ALPHA_BLEND` (RGBA8888 with mip chain retained). Hard-edged cutouts use `alpha_mode = PBM_ALPHA_CUTOUT`.

#### 5.1.3 Sign and Direction Convention

`uv_scroll_u` and `uv_scroll_v` describe the direction the **pattern travels** across the surface:
- **Walls:** The surface $V$ axis points vertically upward. A downward-falling waterfall moves toward $-V$; therefore, falling water has **negative** `uv_scroll_v` (e.g. `-0.75`).
- **Floors:** The surface $V$ axis points toward world $+Z$. A fluid churning away from a wall (toward $+Z$) travels along $+V$; under the coordinate offset relation ($uv(t) = uv_0 + \vec{v} \cdot t$), advancing the offset translates the pattern outward.
- **Billboards:** Rising steam, smoke, or mist moving upward has **positive** `uv_scroll_v` (e.g. `+0.35`).

#### 5.1.4 Authoring Workflow in PoiBuilder

The canonical workflow to author scrolling textures in PoiBuilder:
1. **Shape Creation (Plane):** Select **New Shape → Plane** (or press `B` / toolbar shortcut).
2. **Surface Drag:** Click and drag on any surface (wall, floor, or sloped ramp) to establish a base rectangle parallel to the surface.
3. **Standoff Offset:** Release mouse button; move the cursor along the surface normal (clamped $\ge 0$) to set the standoff elevation (keeping the sheet clear of wall/floor z-fighting), then click to confirm.
4. **Material & UV Dock:** Select the face in Face Mode, navigate to **Scrolling Texture (UV Animation)** in the dock:
   - Enter `Speed U` and `Speed V` in repeats/second (the dock displays live equivalent m/s translation).
   - Click **Apply Scroll**. The material is automatically duplicated so other faces are not unintentionally animated, and metadata `poi_uv_scroll` is set.
5. **Live In-Editor Preview:** The **Animate in Viewport** checkbox animates the scrolling texture live in the 3D editor viewport at 60 FPS while editing.
6. **Export:** Exporting via **Export → PoiRetro (.pbm)** or GLB automatically writes `uv_scroll_u` / `uv_scroll_v` and keeps the texture standalone.

---

## 6. Collider Chunk Specification

The Collider Chunk contains `header.num_colliders` collision hulls. Each record has a 68-byte `PbmColliderHeader` followed by triangle vertex data if `type == PBM_COL_TRIMESH`.

### `PbmColliderHeader` (64 bytes, packed)

| Offset | Type | Field Name | Description |
|---|---|---|---|
| `0x00` | `char[32]` | `name` | Collider name (e.g. `"Collider_NorthWall"`). |
| `0x20` | `uint32_t` | `type` | Collider type: `0` = BOX, `1` = TRIMESH, `2` = RAMP. |
| `0x24` | `float[3]` | `bounds_min` | Collider AABB minimum $(X, Y, Z)$. |
| `0x30` | `float[3]` | `bounds_max` | Collider AABB maximum $(X, Y, Z)$. |
| `0x3C` | `uint32_t` | `num_triangles` | Number of triangles in payload (`0` for simple AABB BOX). |

*(`PbmColliderHeader` is 64 bytes as implemented and written; there is no
padding field in the binary layout.)*

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

## 8. Standard Lump: Particle Emitters (`tag = "emitters"`)

A **standard lump** is a metadata entry (§7) whose payload layout this
specification defines, rather than the author's engine. `"emitters"` is the first
one: the metadata table is the transport, and the payload is normative. It is a
compatible addition *within* v3 — the chunk is already extensible, and a loader
that does not know the tag skips it — so the major version does not move.

### 8.1 The model: a looping, stateless particle stream

An emitter does **not** own a particle array. At any scene time `t`, particle `i`
of an emitter is a **pure function of `t`, `i`, and the emitter's `seed`**:

```
age_i(t)  = frac(t / life_i + phase_i)        # 0 at birth, → 1 at death
tau       = age_i(t) * life_i                 # the particle's age in seconds
position  = origin + spawn_i + closed_form(tau)
size      = size_i * curve(tau / life_i)
colour    = colour_curve(tau / life_i)
rotation  = angle0_i + spin_i * tau
frame     = atlas cell at frac(age * anim_loops + anim_offset_i)
```

Every particle is therefore always alive and always at a different point of its
own loop, which is what makes a fixed budget of them read as a continuous
emission. Two consequences are worth stating, because they are the reason this
model is in the format at all:

* A runtime needs **no per-particle state, no allocation, and no integration**:
  the per-particle constants (`life`, `speed`, `size`, `spin`, `angle0`, `dir`,
  `spawn`, `phase`, `anim_offset`, `wobble_phase`) are derived **once** from the
  seed, and the per-frame cost is the closed form plus two triangles per particle.
* The look is **deterministic**: an implementation that derives the constants as
  §8.3 specifies shows the same particle field as the reference, so a preview in
  an authoring tool and the device output can be compared directly.

The cost profile that shaped it, measured on PSP hardware (see §11): fill rate is
the only real budget — a full screen of cache-resident textured fill is ≈0.3 ms,
one draw call is ≈0.94 µs, and a few hundred transformed vertices are noise. The
design goal is therefore "as few fragments as the effect needs", not "as few
vertices". Particles may be large, but not many.

### 8.2 Lump layout (normative)

```
"emitters" payload =
  PbmEmitterLumpHeader        (16 bytes)
  PbmEmitter records[N]       (176 bytes each)
```

#### `PbmEmitterLumpHeader`

| Offset | Type | Field | Meaning |
|---|---|---|---|
| `0x00` | `uint32` | `magic` | `0x54494D45` (`"EMIT"`, little-endian) |
| `0x04` | `uint32` | `version` | `1`. A loader MUST reject a **higher** version by skipping the lump |
| `0x08` | `uint32` | `count` | Number of `PbmEmitter` records |
| `0x0C` | `uint32` | `reserved` | MUST be 0 |

#### `PbmEmitter` (176 bytes, packed, little-endian)

| Offset | Type | Field | Meaning |
|---|---|---|---|
| `0x00` | `char[24]` | `name` | Label (debug only) |
| `0x18` | `float[3]` | `pos` | Emitter origin, world space |
| `0x24` | `float[3]` | `dir` | Emission axis, unit length |
| `0x30` | `float` | `spread` | Cone half-angle, **radians**; `PI` = sphere |
| `0x34` | `float` | `speed_min` | Initial speed along the particle's own direction, m/s |
| `0x38` | `float` | `speed_max` | |
| `0x3C` | `float` | `life_min` | Particle lifetime, seconds (> 0) |
| `0x40` | `float` | `life_max` | |
| `0x44` | `float[3]` | `gravity` | Constant acceleration, m/s² |
| `0x50` | `float` | `damping` | Exponential drag λ, per second; `0` = none |
| `0x54` | `float` | `size_min` | Quad **height** at birth, metres |
| `0x58` | `float` | `size_max` | |
| `0x5C` | `float` | `size_mid` | Height multiplier at the knee (`1` = unchanged) |
| `0x60` | `float` | `size_end` | Height multiplier at death |
| `0x64` | `float` | `aspect` | Width ÷ height of the quad (`1` = square) |
| `0x68` | `float` | `angle_min` | Initial screen-plane rotation, radians |
| `0x6C` | `float` | `angle_max` | |
| `0x70` | `float` | `spin_min` | Rotation speed over life, rad/s |
| `0x74` | `float` | `spin_max` | |
| `0x78` | `float` | `wobble_amp` | Lateral sinusoidal displacement, metres (`0` = none) |
| `0x7C` | `float` | `wobble_freq` | Wobble frequency, Hz |
| `0x80` | `float` | `spawn_radius` | Spawn sphere radius, metres (`0` = point) |
| `0x84` | `float` | `knee` | Life fraction of the mid key, `0.05…0.95` (`0.5` typical) |
| `0x88` | `uint32` | `color_start` | `0xAABBGGRR` at birth |
| `0x8C` | `uint32` | `color_mid` | …at the knee |
| `0x90` | `uint32` | `color_end` | …at death |
| `0x94` | `int32` | `texture_id` | Texture chunk index, or `-1` for the built-in radial glow |
| `0x98` | `uint16` | `count` | Simultaneous particles (≥ 1) |
| `0x9A` | `uint16` | `flags` | `PBM_EMIT_*` |
| `0x9C` | `uint8` | `atlas_cols` | Flipbook columns (≥ 1) |
| `0x9D` | `uint8` | `atlas_rows` | Flipbook rows (≥ 1) |
| `0x9E` | `uint8` | `anim_loops` | Whole animation loops per particle lifetime (≥ 1) |
| `0x9F` | `uint8` | `reserved0` | MUST be 0 |
| `0xA0` | `uint32` | `seed` | Per-emitter random seed |
| `0xA4` | `float[3]` | `reserved` | MUST be 0 (minor extensions only) |

#### Flags

| Constant | Value | Meaning |
|---|---|---|
| `PBM_EMIT_ADDITIVE` | `1` | Additive blending (`dst = src·srcA + dst`). **Order-independent, so no sorting is needed** — this is the cheap default |
| `PBM_EMIT_Y_LOCKED` | `2` | Cylinder billboard: the quad's up axis stays world up |
| `PBM_EMIT_VEL_ALIGN` | `4` | The quad's up axis follows the particle's own velocity (overrides `Y_LOCKED`) |
| `PBM_EMIT_PHASE_ALIGN` | `8` | Every particle shares phase 0: a burst repeating once per lifetime, instead of a continuous stream |

### 8.3 Particle derivation (normative)

`pbm_rand(seed, index, channel)` is this 32-bit avalanche hash — it is part of the
format, because it is what makes the particle field reproducible:

```c
static inline uint32_t pbm_hash32(uint32_t x) {
    x ^= x >> 16; x *= 0x7feb352du;
    x ^= x >> 15; x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}
static inline float pbm_rand(uint32_t seed, uint32_t idx, uint32_t chan) {
    return (float)(pbm_hash32(seed ^ (idx * 0x9E3779B9u) ^ (chan * 0x85EBCA6Bu)) >> 8)
           * (1.0f / 16777216.0f);          /* uniform in [0,1) */
}
```

With `u_c = pbm_rand(seed, i, c)` for particle `i`:

| `c` | Quantity |
|---|---|
| 0 | `life_i    = lerp(life_min, life_max, u_0)` |
| 1 | phase jitter (`phase_i`, below) |
| 2 | `speed_i   = lerp(speed_min, speed_max, u_2)` |
| 3 | `size_i    = lerp(size_min, size_max, u_3)` |
| 4 | `spin_i    = lerp(spin_min, spin_max, u_4)` |
| 12 | `angle0_i  = lerp(angle_min, angle_max, u_12)` |
| 5 | `wobble_phase_i = u_5 · 2π` |
| 6 | `anim_offset_i  = u_6` |
| 7 | cone polar angle `θ = spread · √u_7` |
| 8 | cone azimuth `φ = u_8 · 2π` |
| 9, 10, 11 | spawn point in the sphere: radius `spawn_radius · u_9^(1/3)`, `cos θ_s = 2u_10 − 1`, azimuth `u_11 · 2π` |

**Direction.** With `t1` any unit vector perpendicular to `dir` and `t2 = dir × t1`:

```
dir_i = dir·cos θ + (t1·cos φ + t2·sin φ)·sin θ
```

**Phase.** A continuous emitter spreads its particles evenly through the loop and
jitters each one inside its own slot, so no two share a phase:

```
phase_i = frac(i / count + u_1 / count)        (PBM_EMIT_PHASE_ALIGN: phase_i = 0)
```

**Position** (closed form; `λ = damping`). With `τ` the particle's age:

```
λ = 0 :  p = pos + spawn_i + dir_i·speed_i·τ + ½·gravity·τ²
λ > 0 :  k1 = (1 − e^(−λτ)) / λ
         k2 = (τ − k1) / λ
         p  = pos + spawn_i + dir_i·speed_i·k1 + gravity·k2
```

The damped form is the analytic solution of `v′ = −λv + g`, so a damped emitter
never needs integration either; as `λ → 0` it converges to the ballistic form.

**Wobble** (`wobble_amp > 0`): with `(w1, w2)` a right-handed orthonormal basis
perpendicular to `dir`:

```
p += wobble_amp · (w1·sin(2π·wobble_freq·τ + wobble_phase_i)
                 + w2·cos(2π·wobble_freq·τ + wobble_phase_i))
```

**Size** (two segments, meeting at `age = knee`):

```
age < knee :  size = size_i · lerp(1, size_mid, age / knee)
age ≥ knee :  size = size_i · lerp(size_mid, size_end, (age − knee) / (1 − knee))
```

**Colour**: the same two-segment interpolation over `color_start → color_mid →
color_end`, per channel including alpha. Alpha is the fade: an emitter whose art
spans its whole loop should start and end at `α = 0`, so the loop restart is
invisible.

**Rotation**: `angle = angle0_i + spin_i · τ`, applied in the quad's plane.

**Flipbook**: `frames = atlas_cols · atlas_rows`;

```
frame = min(frames − 1, floor(frac(age · anim_loops + anim_offset_i) · frames))
cell  = (frame mod atlas_cols, frame / atlas_cols)          # row-major
```

The cell's UV rectangle is **inset by half a texel** on every side
(`0.5 / texture_width` in U, `0.5 / texture_height` in V) so a filter tap at the
cell edge cannot reach the neighbouring frame.

### 8.4 Rendering (normative intent)

Each particle is two triangles in the billboard plane:

* the **billboard basis** is the camera's right/up (`Y_LOCKED`: world up, and
  right perpendicular to it; `VEL_ALIGN`: the particle's velocity and a right
  vector perpendicular to both);
* the quad spans `size · aspect` in width and `size` in height, rotated by
  `angle` in that plane;
* the vertex colour is the particle's colour, and the texture is sampled with
  `MODULATE` (colour × texel) — so a texture's RGB **is** the particle's shading
  and its alpha (together with the colour's alpha) is the opacity;
* emitters are **unlit**: no baked lighting, no shadows. A particle is its own
  light source; that is also why additive emitters look right on a dark scene;
* depth **test** on, depth **write** off, backface culling off;
* additive emitters use `dst = src·srcA + dst` and need **no sorting**; blended
  emitters use `dst = src·srcA + dst·(1 − srcA)` and MUST be drawn
  back-to-front. Within one emitter the particles sort by view depth; between
  emitters, scene order is the intended order.

A runtime MAY drop a particle whose projected edge is below ≈3 px: it covers a
handful of fragments while its texture fetch is fully minified, which on the GE
is the difference between a cache hit and a main-memory round trip (see §11).

### 8.5 Textures

A particle texture obeys the same rules as any other texture, plus three specific
to emitters:

1. **Standalone.** An emitter texture is never packed into a tile atlas: the cell
   addressing assumes the whole texture is the flipbook.
2. **Small.** A texture that fits the hardware's texture cache is sampled at full
   speed even when minified. 64×64 is the sweet spot on the PSP (8 KB in 5551)
   and is enough for four 32×32 flipbook cells or one soft 64×64 puff.
3. **No mip chain for emitters.** A mip level of a flipbook averages neighbouring
   frames together; the reference implementation samples level 0 only and relies
   on the size cull above for the fetch footprint.

For **additive** emitters, put the falloff in the texture's **RGB**, not in its
alpha: one alpha bit (all the 16-bit formats have) can only cut a texel out,
while additive blending multiplies by RGB anyway. An emitter with
`texture_id = -1` gets a runtime-generated radial glow (white centre → black
edge, alpha 1) and is intended for additive use only.

Soft-edged particle art (smoke, mist) needs real alpha and therefore travels as
`RGBA8888` with `alpha_mode = BLEND`, exactly like a soft-alpha surface. Hard
art (glows, sparks, flame cells) stays `RGBA5551` + `CUTOUT`: half the memory,
and it is the difference between fitting the cache and not.

Every flipbook cell SHOULD keep a fully transparent border ring, so a stray
filter tap can only find more transparency.

### 8.6 Authoring in Godot

Emitters are authored as ordinary `GPUParticles3D` nodes — the editor preview and
the device playback are then the same effect. The exporter maps:

| PBM field | Godot source |
|---|---|
| `pos` | node global position |
| `dir` | node basis × `ParticleProcessMaterial.direction`, normalized |
| `spread` | `spread` (degrees → radians) |
| `speed_min/max` | `initial_velocity_min/max` |
| `life_min/max` | `lifetime × (1 − lifetime_randomness)`, `lifetime` |
| `gravity` | `gravity` |
| `damping` | mean of `damping_min/max` |
| `size_min/max` | draw-pass quad height × `scale_min/max` × `scale_curve(0)` |
| `size_mid/end` | `scale_curve(knee) / scale_curve(0)`, `scale_curve(1) / scale_curve(0)` |
| `aspect` | draw-pass quad width ÷ height |
| `angle_min/max` | `angle_min/max` (degrees → radians) |
| `spin_min/max` | `angular_velocity_min/max` (degrees/s → rad/s) |
| `knee` | t of the peak of `color_ramp`'s alpha (else of `scale_curve`, else 0.5) |
| `color_start/mid/end` | `color_ramp` sampled at 0 / knee / 1, × `color` |
| `count` | `amount` |
| `atlas_cols/rows` | material `particles_anim_h_frames/v_frames` (in `BILLBOARD_PARTICLES` mode) |
| `anim_loops` | `anim_speed` (Godot counts complete cycles per lifetime too) |
| `flags` | `BLEND_MODE_ADD` → additive; `one_shot` → phase-aligned burst; `particle_flag_align_y` → velocity-aligned |
| `seed` | node `seed` when `use_fixed_seed`, else derived from the node name |
| `texture_id` | the draw-pass material's albedo texture, registered as a standalone texture |

Fields Godot has no concept for are reachable as explicit `poi_*` metadata on the
node — an override list, not a second authoring path: `poi_additive`,
`poi_y_locked`, `poi_wobble_amp`, `poi_wobble_freq`, `poi_knee`, `poi_seed`.

### 8.7 Recipes

**A looping animation on one quad (the cheapest emitter there is).** Set
`count = 1`, `size_min = size_max = the quad's size`, `anim_loops = 1`, an atlas
whose cells are the animation frames, `life_min = life_max = the loop period`,
`color_start = color_end = transparent`, `color_mid` opaque, and no motion at all
(`speed = 0`, `gravity = 0`, `spread = 0`). One quad, one draw call, one texture:
a torch flame, a magic portal, a fountain plume. `size_mid/end` can still expand
the quad over the loop if the animation breathes.

**A campfire.** Three emitters at one point: a `count = 1` flame quad as above; a
small additive glimmer with `spread ≈ 25°`, `speed ≈ 1…2 m/s`, `gravity ≈ +0.5`,
`life ≈ 1 s` for the sparks; and — if the scene allows transparency — a blended
soft puff with `damping` for the smoke column.

**Testability note**: a looping emitter that is *wrong* looks exactly like one
that is right, in a single frame. Verify motion with two captures at different
scene times (see §10).

## 9. End-to-End Walkthrough: Godot 4 Authoring to Custom Engine Implementation

> **CRITICAL ARCHITECTURAL DISTINCTION — RECIPES VS. STANDARD**:  
> The specific entity tags and structures detailed below (`"walkable_mesh"`, `"triggers"`, `"player_spawn"`, `"rigid_bodies"`, `"entities"`) are **EXAMPLE IMPLEMENTATION RECIPES**, **NOT** fixed schema constraints of the specification. Particle emitters are the exception: they graduated from a recipe to a **standard lump** with a normative payload, defined in §8.
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

#### 4. Particle Emitters (`tag = "emitters"`, standard binary lump)

1. Add a `GPUParticles3D` node named `Emitter_*` and style it with a
   `ParticleProcessMaterial` exactly as for a real-time effect; the editor
   preview is the effect the device will play.
2. Give it a draw pass: a `QuadMesh` with a `StandardMaterial3D`. That material
   supplies the particle texture and the blend mode (choose `Add` for fire,
   sparks and glows; leave it on `Mix` for smoke and mist). For a flipbook, set
   the material's billboard mode to **Particles** and its `particles_anim_h/v
   frames` to the sheet's grid.
3. Export. The exporter writes the standard `"emitters"` lump (§8) and registers
   the particle texture as a standalone texture entry.

The mapping table, the fields Godot cannot express, and the runtime semantics are
all in §8; this recipe is the authoring workflow, §8 is the contract.

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
3. Dynamically extracts `player_spawn`, `walkable_mesh`, `triggers`, `rigid_bodies` and custom metadata lumps, and packs every `GPUParticles3D` into the standard `emitters` lump (§8).
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
    } else if (strcmp(mhdr.tag, "emitters") == 0) {
        parse_emitters_lump(payload, mhdr.data_size);   /* standard lump, §8 */
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

---

## 10. Recipe: A Scrolling Texture (Waterfall), Godot → Retro Engine

A worked example of the pattern above, end to end. It is the recipe behind the
courtyard waterfall in the showcase map
(`project/test_scenes/test_map_showcase_builder.gd`), and every value in it is
read straight out of the Godot material — there is no special-casing anywhere
in the pipeline.

### Step 1 — Author the surface

1. **New Shape → Plane**. The plane is the surface-decoration shape: drag it out
   **parallel to the surface** you are decorating (it starts coplanar with it),
   then move the mouse to **offset it clear of that surface** and click to
   confirm. The stand-off is the plane's third dimension — it is not a size — so
   a waterfall sheet can hang a few centimetres in front of a wall without
   z-fighting it. Plane values are `width`/`depth` only; the offset is
   placement, so it never reaches the params modal.
2. Assign the water texture to the face (Material & UV dock) and set its
   **Tiling** to fix how many metres one repeat covers. That matters for the
   speed you pick next: `metres per second = speed × (metres per repeat)`. The
   dock prints the metres/second figure under the speed fields, so the number
   can be judged in world terms rather than in texture terms.

### Step 2 — Give the material a scroll speed

In the Material & UV dock, **Scrolling Texture**:

| field | meaning |
|---|---|
| Speed U / Speed V | texture repeats per second, along the face's own U / V axes |
| Apply Scroll | writes the speed onto the selected faces' material |
| Clear | removes it (the surface becomes static again) |

The sign is a direction, and with the reference implementation (§5.1) the rule
that matters for this scene is simple — **negative V travels down a wall and
away from a wall on the floor**:

- a sheet falling down a wall: **Speed V negative** (e.g. `-0.75`),
- a second, faster sheet in front of it: `-1.15` (the parallax reads as depth),
- churn spreading away from the base of the fall, and a pool drifting with it:
  **also negative** (e.g. `-0.30`),
- rising mist on a billboard: positive, because a sprite's V runs down its own
  face — the one place the sign flips.

Applying a speed duplicates the material when other faces share it, because the
animation is a property of the *material* — that is the unit the exporters split
meshes by.

### Step 3 — Choose the transparency

Water almost never wants to be opaque. Set the material's **Transparency** and
the exporter carries it through:

| Godot | glTF | PBM `alpha_mode` | Result in the engine |
|---|---|---|---|
| Disabled | *(absent)* | `NONE` | opaque pass, mip chain |
| Alpha Scissor / Hash | `MASK` | `CUTOUT` | alpha-tested, **no** mip chain |
| Alpha | `BLEND` | `BLEND` | blended, **RGBA8888** + mip chain |

`Alpha` on the waterfall sheet is what lets the stone read through the thin
parts of the water. Foliage and other hard-edged cutouts stay on `Alpha
Scissor`: their silhouette is 1-bit, and a mip chain would erode it.

### Step 4 — Export

Toolbar **Export → PoiRetro (.pbm)**. For each scrolling face the exporter
writes the mesh's `uv_scroll_u`/`uv_scroll_v`, keeps its texture out of the tile
atlases (a scrolling atlas tile would drag across its slot), and stores a
blended texture as RGBA8888. Nothing else changes: lighting still bakes into
vertex colours, tiles still atlas, colliders still export.

The same data also rides a GLB round trip, for the Python oracle
(`retro_engine/pbm_conv.py`) and the GDScript converter
(`PBPbmConverter.convert_glb_to_pbm`), because the speed is mirrored into the
material's glTF `extras` as `{"poi_uv_scroll": [u, v]}`. The two converters are
expected to agree bit for bit apart from float rounding.

### Step 5 — Consume it in the engine

```c
/* Per frame, before the draw calls: advance each animated mesh's texture
 * coordinates. On the GE this is one register write per axis, and only for
 * meshes whose offset actually changed — a static scene emits none. */
static void apply_uv_scroll(PbmMap* map, PbmMesh* mesh, float t,
                            float* cur_u, float* cur_v) {
    float su = mesh->uv_scroll_u, sv = mesh->uv_scroll_v;
    if (mesh->texture_id < 0 ||
        strstr(map->textures[mesh->texture_id].name, "TileAtlas")) {
        su = sv = 0.0f;              /* atlases must never be offset (see 5.1) */
    }
    /* The register holds one repeat: wrap, so a long-running clock keeps full
     * fixed-point precision. */
    float u = t * su, v = t * sv;
    u -= floorf(u);
    v -= floorf(v);
    if (u != *cur_u || v != *cur_v) {
        sceGuTexOffset(u, v);        /* pattern velocity; the GE inverts it */
        *cur_u = u; *cur_v = v;
    }
}
```

Draw scrolling meshes in the same passes as everything else: `BLEND` meshes
belong to the alpha pass (after the opaques), and two translucent layers must
be emitted back to front. Scene-tree order is preserved into the file, so list
the far sheet before the near one.

### Step 6 — Verify it actually moves

A scrolling texture that is wrong looks exactly like one that is frozen. Check
the *rendered* result, not the numbers:

```bash
cd retro_engine/psp
./run_psp_headless.sh     # builds, runs the benchmark, writes two PNGs
```

The benchmark captures twice — at frame 60 and 20 frames later, with the camera
frozen — into `screenshot_psp.png` and `screenshot_psp_scroll.png`. Diff them,
or correlate the scrolling mesh's pixels. To isolate the animation from
everything else, zero every `uv_scroll` field in a copy of the map, capture the
same frame from both, and diff: the pixels that change are exactly the ones the
scroll owns. (Remember the capture's alpha byte is meaningless — the framebuffer
is 5551 — so drop it before viewing, or the image looks blank.)

If the pattern moves the wrong way, the sign flipped somewhere: the file's
meaning is "where the pattern travels", and hardware offset registers are
commonly the opposite of it (see the implementation note in §5.1).

## 11. Hardware Clipping & Performance Rules (PSP Guidelines)

1. **Near-Plane Distance**:
   Perspective projection near plane MUST be set between `0.05f` and `0.10f` meters (`sceGumPerspective(fov, aspect, 0.08f, 200.0f)`). A near plane of `0.5m` causes geometry within arm's reach of floors and stairs to intersect the near clipping plane, inducing heavy hardware re-triangulation.
2. **Hardware Clipping Planes**:
   Call `sceGuEnable(GU_CLIP_PLANES)` to ensure the hardware near-plane clipper handles near-Z triangles correctly without driver fallbacks.
3. **Guardband Culling**:
   Set `sceGuViewport(2048, 2048, 480, 272)` and `sceGuOffset(2048 - 240, 2048 - 136)`. Triangles within the $4096 \times 4096$ virtual coordinate space avoid software clipping and rasterize at full hardware fillrate.
4. **Spatial Mesh Chunking**:
   Large planar meshes (such as 12m terrain floors) SHOULD be subdivided into $\le 6\text{m} \times 6\text{m}$ spatial chunks rather than merged into a single multi-thousand-vertex draw call. This ensures that off-screen chunks are culled and only local triangles undergo near-plane testing.

---

## 12. Compliance Verification

A compliant PBM exporter and loader MUST pass the following tests:
1. `magic == 0x334D4250` and `version == 3`.
2. Reject files where `version > 3` with explicit error logging, and load v1/v2
   files (64-byte mesh headers, `has_alpha` 0/1) with their meshes static.
3. Successfully load textures with power-of-two dimensions and 16-byte memory alignment.
4. Successfully parse arbitrary metadata entries by tag and type.
5. Store a `BLEND` texture as RGBA8888 and never leave it without its mip chain;
   store a `CUTOUT` texture without a mip chain.
6. Never apply a UV scroll to a tile-atlas texture, and keep every scrolling
   mesh's texture standalone.
7. Load the standard `emitters` lump (§8): skip a lump whose own version is newer
   than the loader supports, clamp an over-budget `count` instead of failing
   (stating the clamp in the log), and derive the per-particle constants with the
   specified `pbm_rand` so two implementations show the same particle field.
8. Never sample an emitter texture with a mip chain, and never let an emitter
   reference a tile-atlas texture.
9. Draw additive emitters without sorting them and blended emitters
   back-to-front; leave the emitters unlit.
10. 100% binary validation against the reference Python oracle (`pbm_conv.py`)
    and the GDScript converter (`project/addons/poibuilder/export/pb_pbm_converter.gd`).
