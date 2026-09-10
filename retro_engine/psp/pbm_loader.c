#include "pbm_loader.h"
#include <stdio.h>
#include <stdlib.h>
#include <malloc.h>
#ifdef __PSP__
#include <psputils.h>
#include <pspkernel.h>
#endif
#include <string.h>
#include <stdarg.h>
/* Swizzles a 16-bit texture into 16-byte wide x 8-line high blocks for Sony GE texture cache */
static void swizzle_texture_16(uint8_t* out, const uint8_t* in, unsigned int width, unsigned int height) {
    unsigned int width_bytes = width * 2;
    unsigned int width_blocks = width_bytes / 16;
    unsigned int height_blocks = height / 8;
    unsigned int src_pitch = (width_bytes - 16) / 4;
    unsigned int src_row = width_bytes * 8;
    const uint8_t* ysrc = in;
    uint32_t* dst = (uint32_t*)out;
    const uint32_t* xsrc;

    for (unsigned int blocky = 0; blocky < height_blocks; ++blocky) {
        const uint8_t* xsrc_b = ysrc;
        for (unsigned int blockx = 0; blockx < width_blocks; ++blockx) {
            xsrc = (const uint32_t*)xsrc_b;
            for (unsigned int j = 0; j < 8; ++j) {
                *(dst++) = *(xsrc++);
                *(dst++) = *(xsrc++);
                *(dst++) = *(xsrc++);
                *(dst++) = *(xsrc++);
                xsrc += src_pitch;
            }
            xsrc_b += 16;
        }
        ysrc += src_row;
    }
}

/* ── Mip chain ────────────────────────────────────────────────────────────
 * Every base material in an exported map tiles a 512x512 texture across a
 * metre of surface, so almost every visible texel is minified: a floor seen at
 * a grazing angle puts adjacent screen pixels tens of texels apart. With no
 * mip chain and a 4-tap LINEAR minification filter the GE's ~8 KB texture
 * cache misses on essentially every fragment, and each miss is a main-memory
 * round trip. Downsampling the chain and sampling it with a mipmap filter
 * keeps the fetch footprint at roughly one texel per pixel.
 *
 * The chain stops at 16x16: below that a 16-bit level is narrower than the
 * GE's 16-byte swizzle block and the layout is no longer worth the risk, and
 * 16x16 is already 1/32 of the base linear scale.
 *
 * Alpha textures are deliberately left alone. Their alpha is 1 bit, so box
 * filtering turns any level where fewer than half the texels are opaque fully
 * transparent — the classic cutout-foliage disappearance. Billboards cover
 * little screen area, so they keep their crisp level 0. */
static inline void unpack5551(uint16_t p, int* r, int* g, int* b, int* a) {
    *r = p & 0x1F;
    *g = (p >> 5) & 0x1F;
    *b = (p >> 10) & 0x1F;
    *a = (p >> 15) & 1;
}

static inline uint16_t pack5551(int r, int g, int b, int a) {
    if (r > 31) r = 31;
    if (g > 31) g = 31;
    if (b > 31) b = 31;
    return (uint16_t)(((a ? 1 : 0) << 15) | (b << 10) | (g << 5) | r);
}

/* 2x2 box filter. Weighting RGB by alpha keeps cutout edges from darkening. */
static void downsample_5551(uint16_t* dst, const uint16_t* src, int sw, int sh, int has_alpha) {
    int dw = sw >> 1, dh = sh >> 1;
    for (int y = 0; y < dh; ++y) {
        for (int x = 0; x < dw; ++x) {
            int r = 0, g = 0, b = 0, a = 0, wsum = 0;
            for (int k = 0; k < 4; ++k) {
                int sx = 2 * x + (k & 1);
                int sy = 2 * y + (k >> 1);
                int sr, sg, sb, sa;
                unpack5551(src[sy * sw + sx], &sr, &sg, &sb, &sa);
                int w = has_alpha ? (sa + 1) : 1;
                r += sr * w; g += sg * w; b += sb * w;
                wsum += w;
                a += sa;
            }
            if (wsum < 1) wsum = 1;
            dst[y * dw + x] = pack5551(r / wsum, g / wsum, b / wsum, a * 2 / 4);
        }
    }
}

/* 2x2 box filter for the 32-bit path. A blend texture carries an 8-bit alpha
 * ramp, and averaging is exactly what a mip level of a soft alpha edge should
 * be; RGB is alpha-weighted so a fading edge does not darken as it shrinks. */
static void downsample_8888(uint32_t* dst, const uint32_t* src, int sw, int sh) {
    int dw = sw >> 1, dh = sh >> 1;
    for (int y = 0; y < dh; ++y) {
        for (int x = 0; x < dw; ++x) {
            int r = 0, g = 0, b = 0, a = 0, wsum = 0;
            for (int k = 0; k < 4; ++k) {
                uint32_t p = src[(2 * y + (k >> 1)) * sw + (2 * x + (k & 1))];
                int sa = (int)((p >> 24) & 0xFF);
                int w = sa + 1;
                r += (int)(p & 0xFF) * w;
                g += (int)((p >> 8) & 0xFF) * w;
                b += (int)((p >> 16) & 0xFF) * w;
                a += sa;
                wsum += w;
            }
            if (wsum < 1) wsum = 1;
            dst[y * dw + x] = (uint32_t)(r / wsum) | ((uint32_t)(g / wsum) << 8) |
                              ((uint32_t)(b / wsum) << 16) | ((uint32_t)(a >> 2) << 24);
        }
    }
}

/* Load diagnostics go both to the on-device debug screen and to a file on the
 * host (host0: when running under PSPLink, else the memory stick). A map that
 * fails to load must never be a silent black screen. */
static void pbm_log(const char* fmt, ...) {
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    printf("%s", buf);

    FILE* lf = fopen("host0:/pbm_load.log", "a");
    if (!lf) lf = fopen("ms0:/pbm_load.log", "a");
    if (lf) { fputs(buf, lf); fclose(lf); }
}

#ifdef __PSP__
/* Heap pressure is the difference between a map that loads and one that comes
 * up empty, so record it around every load. */
static void pbm_log_mem(const char* tag) {
    pbm_log("[PBM] mem %-12s total_free=%u max_free=%u\n", tag,
            (unsigned)sceKernelTotalFreeMemSize(), (unsigned)sceKernelMaxFreeMemSize());
}
#else
static void pbm_log_mem(const char* tag) { (void)tag; }
#endif

PbmMap* pbm_load(const char* filepath) {
    FILE* f = fopen(filepath, "rb");
    if (!f) {
        printf("[PBM] Error: Could not open '%s'\n", filepath);
        return NULL;
    }

    pbm_log_mem("before load");

    PbmMap* map = (PbmMap*)calloc(1, sizeof(PbmMap));
    if (!map) {
        fclose(f);
        return NULL;
    }

    /* First read 4-byte magic to identify format generation */
    uint32_t magic = 0;
    if (fread(&magic, sizeof(uint32_t), 1, f) != 1) {
        printf("[PBM] Error: Failed to read magic header\n");
        free(map);
        fclose(f);
        return NULL;
    }

    /* Validate Magic */
    if (magic != PBM_MAGIC && magic != PBM_MAGIC_V2 && magic != PBM_MAGIC_V1) {
        printf("[PBM] Error: Invalid magic 0x%08X (expected 'PBM3' 0x%08X, 'PBM2' 0x%08X or 'PBM1' 0x%08X)\n",
            (unsigned int)magic, (unsigned int)PBM_MAGIC,
            (unsigned int)PBM_MAGIC_V2, (unsigned int)PBM_MAGIC_V1);
        free(map);
        fclose(f);
        return NULL;
    }

    uint32_t version = 0;
    if (fread(&version, sizeof(uint32_t), 1, f) != 1) {
        printf("[PBM] Error: Failed to read format version\n");
        free(map);
        fclose(f);
        return NULL;
    }

    /* Version breaking change detection & diagnostic */
    if (version > PBM_MAX_SUPPORTED) {
        printf("[PBM] Error: Incompatible map version %u! (Loader supports up to v%u).\n"
               "[PBM] FATAL: Breaking format change detected. Please re-export or update loader.\n",
               (unsigned int)version, (unsigned int)PBM_MAX_SUPPORTED);
        free(map);
        fclose(f);
        return NULL;
    }
    if (version < PBM_MIN_SUPPORTED) {
        printf("[PBM] Error: Obsolete map version %u! (Minimum supported is v%u).\n",
               (unsigned int)version, (unsigned int)PBM_MIN_SUPPORTED);
        free(map);
        fclose(f);
        return NULL;
    }

    map->header.magic = magic;
    map->header.version = version;

    if (version == 1) {
        /* Legacy v1 Header: 60 bytes total (magic + version already read = 52 bytes remain) */
        struct __attribute__((packed)) {
            uint32_t num_textures;
            uint32_t num_meshes;
            uint32_t num_colliders;
            float spawn_pos[3];
            float spawn_rot;
            float bounds_min[3];
            float bounds_max[3];
        } v1_hdr;
        if (fread(&v1_hdr, sizeof(v1_hdr), 1, f) != 1) {
            printf("[PBM] Error reading v1 header body\n");
            free(map);
            fclose(f);
            return NULL;
        }
        map->header.num_textures = v1_hdr.num_textures;
        map->header.num_meshes = v1_hdr.num_meshes;
        map->header.num_colliders = v1_hdr.num_colliders;
        map->header.num_metadata = 0;
        memcpy(map->header.spawn_pos, v1_hdr.spawn_pos, sizeof(float) * 3);
        map->header.spawn_rot = v1_hdr.spawn_rot;
        memcpy(map->header.bounds_min, v1_hdr.bounds_min, sizeof(float) * 3);
        memcpy(map->header.bounds_max, v1_hdr.bounds_max, sizeof(float) * 3);
    } else {
        /* Modern v2 Header: 64 bytes total (magic + version already read = 56 bytes remain) */
        struct __attribute__((packed)) {
            uint32_t num_textures;
            uint32_t num_meshes;
            uint32_t num_colliders;
            uint32_t num_metadata;
            float spawn_pos[3];
            float spawn_rot;
            float bounds_min[3];
            float bounds_max[3];
        } v2_hdr;
        if (fread(&v2_hdr, sizeof(v2_hdr), 1, f) != 1) {
            printf("[PBM] Error reading v2 header body\n");
            free(map);
            fclose(f);
            return NULL;
        }
        map->header.num_textures = v2_hdr.num_textures;
        map->header.num_meshes = v2_hdr.num_meshes;
        map->header.num_colliders = v2_hdr.num_colliders;
        map->header.num_metadata = v2_hdr.num_metadata;
        memcpy(map->header.spawn_pos, v2_hdr.spawn_pos, sizeof(float) * 3);
        map->header.spawn_rot = v2_hdr.spawn_rot;
        memcpy(map->header.bounds_min, v2_hdr.bounds_min, sizeof(float) * 3);
        memcpy(map->header.bounds_max, v2_hdr.bounds_max, sizeof(float) * 3);
    }

    pbm_log("[PBM] Loaded header v%u: %u textures, %u meshes, %u colliders, %u metadata\n",
        (unsigned int)map->header.version,
        (unsigned int)map->header.num_textures,
        (unsigned int)map->header.num_meshes,
        (unsigned int)map->header.num_colliders,
        (unsigned int)map->header.num_metadata);
    strncpy(map->map_name, "PoiRetro Map", sizeof(map->map_name) - 1);
    map->has_patrol_sphere = 0;
    /* 1. Textures */
    if (map->header.num_textures > 0) {
        map->textures = (PbmTexture*)calloc(map->header.num_textures, sizeof(PbmTexture));
        for (uint32_t i = 0; i < map->header.num_textures; ++i) {
            PbmTextureHeader thdr;
            if (fread(&thdr, sizeof(PbmTextureHeader), 1, f) != 1) {
                printf("[PBM] Error reading texture header %u\n", (unsigned int)i);
                break;
            }
            memcpy(map->textures[i].name, thdr.name, 32);
            map->textures[i].width = thdr.width;
            map->textures[i].height = thdr.height;
            map->textures[i].format = thdr.format;
            map->textures[i].alpha_mode = thdr.alpha_mode;
            map->textures[i].data_size = thdr.data_size;

            PbmTexture* tex = &map->textures[i];
            tex->pixels = NULL;
            tex->num_levels = 0;
            tex->is_swizzled = 0;

            uint8_t* linear = (uint8_t*)malloc(thdr.data_size);
            if (!linear) {
                pbm_log("[PBM] FATAL: out of memory for texture %u (%u bytes)\n",
                        (unsigned int)i, (unsigned)thdr.data_size);
                goto load_failed;
            }
            if (fread(linear, 1, thdr.data_size, f) != thdr.data_size) {
                pbm_log("[PBM] FATAL: short read on texture %u data\n", (unsigned int)i);
                free(linear);
                goto load_failed;
            }

            int pot16 = (thdr.format == PBM_TEX_FMT_RGBA5551) &&
                        thdr.width >= 16 && thdr.height >= 8 &&
                        (thdr.width & (thdr.width - 1)) == 0 &&
                        (thdr.height & (thdr.height - 1)) == 0;

            if (pot16) {
                int lw[PBM_MAX_MIP_LEVELS], lh[PBM_MAX_MIP_LEVELS];
                const uint16_t* src[PBM_MAX_MIP_LEVELS];
                int built = 1;
                lw[0] = thdr.width;
                lh[0] = thdr.height;
                src[0] = (const uint16_t*)linear;

                /* Mip chains for everything except hard-edged cutouts: halving
                 * a 1-bit alpha turns a level fully transparent long before
                 * the texels are small, which eats the silhouette. Soft alpha
                 * (PBM_ALPHA_BLEND) averages exactly the way a blended surface
                 * wants, and opaque textures have nothing to lose. */
                if (thdr.alpha_mode != PBM_ALPHA_CUTOUT) {
                    while (built < PBM_MAX_MIP_LEVELS && lw[built - 1] >= 32 && lh[built - 1] >= 32) {
                        int pw = lw[built - 1] >> 1, ph = lh[built - 1] >> 1;
                        uint16_t* lvl = (uint16_t*)malloc((size_t)pw * ph * 2);
                        if (!lvl) break;
                        downsample_5551(lvl, src[built - 1], lw[built - 1], lh[built - 1], 0);
                        src[built] = lvl;
                        lw[built] = pw;
                        lh[built] = ph;
                        built++;
                    }
                }

                int done = 0;
                for (; done < built; ++done) {
                    uint32_t sz = (uint32_t)lw[done] * lh[done] * 2;
                    void* dst = memalign(64, sz);
                    if (!dst) break;
                    swizzle_texture_16((uint8_t*)dst, (const uint8_t*)src[done], lw[done], lh[done]);
                    tex->level_w[done] = (uint16_t)lw[done];
                    tex->level_h[done] = (uint16_t)lh[done];
                    tex->level_ptr[done] = dst;
                }
                for (int k = 1; k < built; ++k) free((void*)src[k]);
                if (done > 0) {
                    tex->num_levels = done;
                    tex->pixels = tex->level_ptr[0];
                    tex->is_swizzled = 1;
                }
            } else if (thdr.format == PBM_TEX_FMT_RGBA8888 &&
                       thdr.alpha_mode == PBM_ALPHA_BLEND &&
                       thdr.width >= 16 && thdr.height >= 16 &&
                       (thdr.width & (thdr.width - 1)) == 0 &&
                       (thdr.height & (thdr.height - 1)) == 0) {
                /* 32-bit blend textures get an UNswizzled mip chain: the 16-bit
                 * swizzle layout does not apply, and the GE takes one base/size
                 * register per level, so a linear chain is legal and still
                 * collapses the minified fetch footprint. Soft alpha needs the
                 * 8 bits per channel that 5551 cannot carry. */
                int lw[PBM_MAX_MIP_LEVELS];
                int lh[PBM_MAX_MIP_LEVELS];
                const uint32_t* src[PBM_MAX_MIP_LEVELS];
                int built = 1;
                lw[0] = thdr.width;
                lh[0] = thdr.height;
                src[0] = (const uint32_t*)linear;
                while (built < PBM_MAX_MIP_LEVELS && lw[built - 1] >= 16 && lh[built - 1] >= 16) {
                    int pw = lw[built - 1] >> 1, ph = lh[built - 1] >> 1;
                    uint32_t* lvl = (uint32_t*)malloc((size_t)pw * ph * 4);
                    if (!lvl) break;
                    downsample_8888(lvl, src[built - 1], lw[built - 1], lh[built - 1]);
                    src[built] = lvl;
                    lw[built] = pw;
                    lh[built] = ph;
                    built++;
                }
                int done = 0;
                for (; done < built; ++done) {
                    uint32_t sz = (uint32_t)lw[done] * lh[done] * 4;
                    void* dst = memalign(16, sz);
                    if (!dst) break;
                    memcpy(dst, src[done], sz);
                    tex->level_w[done] = (uint16_t)lw[done];
                    tex->level_h[done] = (uint16_t)lh[done];
                    tex->level_ptr[done] = dst;
                }
                for (int k = 1; k < built; ++k) free((void*)src[k]);
                if (done > 0) {
                    tex->num_levels = done;
                    tex->pixels = tex->level_ptr[0];
                    tex->is_swizzled = 0;
                }
            } else {
                void* pixels = memalign(16, thdr.data_size);
                if (!pixels) pixels = malloc(thdr.data_size);
                if (pixels) {
                    memcpy(pixels, linear, thdr.data_size);
                    tex->pixels = pixels;
                    tex->num_levels = 1;
                    tex->level_w[0] = thdr.width;
                    tex->level_h[0] = thdr.height;
                    tex->level_ptr[0] = pixels;
                }
            }
            free(linear);
        }
    }

    /* 2. Meshes */
    map->total_vertices = 0;
    uint32_t animated_meshes = 0;
    if (map->header.num_meshes > 0) {
        map->meshes = (PbmMesh*)calloc(map->header.num_meshes, sizeof(PbmMesh));
        for (uint32_t i = 0; i < map->header.num_meshes; ++i) {
            PbmMeshHeader mhdr;
            memset(&mhdr, 0, sizeof(mhdr));
            /* v3 grew the mesh header by the two UV-scroll words; v1/v2 files
             * end where uv_scroll_u would begin, so read exactly that much and
             * leave the scroll at zero (their meshes are static by definition). */
            size_t hdr_size = (map->header.version >= 3)
                ? sizeof(PbmMeshHeader) : (size_t)PBM_MESH_HEADER_V2;
            if (fread(&mhdr, hdr_size, 1, f) != 1) {
                pbm_log("[PBM] FATAL: short read on mesh header %u\n", (unsigned int)i);
                goto load_failed;
            }
            memcpy(map->meshes[i].name, mhdr.name, 32);
            map->meshes[i].texture_id = mhdr.texture_id;
            map->meshes[i].num_vertices = mhdr.num_vertices;
            memcpy(map->meshes[i].bounds_min, mhdr.bounds_min, sizeof(float) * 3);
            memcpy(map->meshes[i].bounds_max, mhdr.bounds_max, sizeof(float) * 3);
            map->meshes[i].uv_scroll_u = mhdr.uv_scroll_u;
            map->meshes[i].uv_scroll_v = mhdr.uv_scroll_v;
            if (mhdr.uv_scroll_u != 0.0f || mhdr.uv_scroll_v != 0.0f) {
                animated_meshes++;
                if (map->meshes[i].texture_id < 0) {
                    pbm_log("[PBM] Warning: mesh '%s' scrolls but has no texture; "
                            "the offset will be ignored.\n", map->meshes[i].name);
                }
            }
            map->total_vertices += mhdr.num_vertices;

            uint32_t vbuf_size = mhdr.num_vertices * sizeof(PbmVertex);
            void* vbuf = memalign(16, vbuf_size);
            if (!vbuf) {
                vbuf = malloc(vbuf_size);
            }
            if (!vbuf) {
                pbm_log("[PBM] FATAL: out of memory for mesh %u vertices (%u bytes)\n",
                        (unsigned int)i, (unsigned)vbuf_size);
                goto load_failed;
            }
            if (fread(vbuf, 1, vbuf_size, f) != vbuf_size) {
                pbm_log("[PBM] FATAL: short read on mesh %u vertices\n", (unsigned int)i);
                free(vbuf);
                goto load_failed;
            }
            map->meshes[i].vertices = (PbmVertex*)vbuf;
        }
    }

    /* 3. Colliders */
    if (map->header.num_colliders > 0) {
        map->colliders = (PbmCollider*)calloc(map->header.num_colliders, sizeof(PbmCollider));
        for (uint32_t i = 0; i < map->header.num_colliders; ++i) {
            PbmColliderHeader chdr;
            if (fread(&chdr, sizeof(PbmColliderHeader), 1, f) != 1) {
                pbm_log("[PBM] FATAL: short read on collider header %u\n", (unsigned int)i);
                goto load_failed;
            }
            memcpy(map->colliders[i].name, chdr.name, 32);
            map->colliders[i].type = chdr.type;
            memcpy(map->colliders[i].bounds_min, chdr.bounds_min, sizeof(float) * 3);
            memcpy(map->colliders[i].bounds_max, chdr.bounds_max, sizeof(float) * 3);
            map->colliders[i].num_triangles = chdr.num_triangles;

            if (chdr.num_triangles > 0) {
                uint32_t tbuf_size = chdr.num_triangles * 9 * sizeof(float);
                float* tbuf = (float*)malloc(tbuf_size);
                if (tbuf) {
                    fread(tbuf, 1, tbuf_size, f);
                    map->colliders[i].triangles = tbuf;
                }
            }
        }
    }

    /* 4. Metadata Chunk (v2.0+) */
    if (map->header.num_metadata > 0) {
        map->metadata = (PbmMetadata*)calloc(map->header.num_metadata, sizeof(PbmMetadata));
        for (uint32_t i = 0; i < map->header.num_metadata; ++i) {
            PbmMetadataHeader mdhdr;
            if (fread(&mdhdr, sizeof(PbmMetadataHeader), 1, f) != 1) {
                printf("[PBM] Error reading metadata header %u\n", (unsigned int)i);
                break;
            }
            memcpy(map->metadata[i].tag, mdhdr.tag, 32);
            map->metadata[i].tag[31] = '\0';
            map->metadata[i].type = mdhdr.type;
            map->metadata[i].data_size = mdhdr.data_size;

            if (mdhdr.data_size > 0) {
                uint32_t alloc_size = mdhdr.data_size + 4;
                void* mdata = calloc(1, alloc_size);
                if (mdata) {
                    fread(mdata, 1, mdhdr.data_size, f);
                    map->metadata[i].data = mdata;

                    /* Skip alignment padding to 4 bytes */
                    uint32_t pad = (4 - (mdhdr.data_size % 4)) % 4;
                    if (pad > 0) {
                        uint8_t pad_buf[4];
                        fread(pad_buf, 1, pad, f);
                    }

                    /* Parse known proof-of-concept metadata tags */
                    if (strcmp(map->metadata[i].tag, "map_name") == 0) {
                        strncpy(map->map_name, (const char*)mdata, sizeof(map->map_name) - 1);
                        map->map_name[sizeof(map->map_name) - 1] = '\0';
                        printf("[PBM] Metadata parsed: Map Name = '%s'\n", map->map_name);
                    } else if (strcmp(map->metadata[i].tag, "entities") == 0) {
                        if (mdhdr.data_size >= sizeof(PbmEntityPatrolSphere)) {
                            memcpy(&map->patrol_sphere, mdata, sizeof(PbmEntityPatrolSphere));
                            map->has_patrol_sphere = 1;
                            printf("[PBM] Metadata parsed: Entity '%s' (type %u, radius=%.2f, speed=%.2f, %u waypoints)\n",
                                map->patrol_sphere.name,
                                (unsigned int)map->patrol_sphere.entity_type,
                                map->patrol_sphere.radius,
                                map->patrol_sphere.speed,
                                (unsigned int)map->patrol_sphere.num_waypoints);
                        }
                    }
                }
            }
        }
    }

    /* A map that claims meshes but has no vertices renders as an empty scene
     * while still reporting success. Treat it as a load failure. */
    for (uint32_t i = 0; i < map->header.num_meshes; ++i) {
        if (!map->meshes[i].vertices || map->meshes[i].num_vertices == 0) {
            pbm_log("[PBM] FATAL: mesh %u of %u has no vertices; map is incomplete\n",
                    (unsigned int)i, (unsigned)map->header.num_meshes);
            goto load_failed;
        }
    }

    /* Flush all loaded textures, vertices, and colliders from D-Cache to main RAM
     * so the Sony GE hardware DMA reads valid data without bus stalls! */
#ifdef __PSP__
    sceKernelDcacheWritebackAll();
#endif
    if (animated_meshes > 0) {
        pbm_log("[PBM] %u of %u meshes have an animated UV scroll (PBM 3.0)\n",
                (unsigned)animated_meshes, (unsigned)map->header.num_meshes);
    }
    pbm_log_mem("after load");
    return map;

load_failed:
    pbm_log("[PBM] Load of '%s' failed; refusing to run with a partial map.\n", filepath);
    pbm_log_mem("on failure");
    pbm_free(map);
    fclose(f);
    return NULL;
}

void pbm_free(PbmMap* map) {
    if (!map) return;
    if (map->textures) {
        for (uint32_t i = 0; i < map->header.num_textures; ++i) {
            /* level 0 aliases pixels; the rest are separately allocated */
            for (uint32_t k = 1; k < map->textures[i].num_levels; ++k) {
                if (map->textures[i].level_ptr[k]) free(map->textures[i].level_ptr[k]);
            }
            if (map->textures[i].pixels) {
                free(map->textures[i].pixels);
            }
        }
        free(map->textures);
    }
    if (map->meshes) {
        for (uint32_t i = 0; i < map->header.num_meshes; ++i) {
            if (map->meshes[i].vertices) {
                free(map->meshes[i].vertices);
            }
        }
        free(map->meshes);
    }
    if (map->colliders) {
        for (uint32_t i = 0; i < map->header.num_colliders; ++i) {
            if (map->colliders[i].triangles) {
                free(map->colliders[i].triangles);
            }
        }
        free(map->colliders);
    }
    if (map->metadata) {
        for (uint32_t i = 0; i < map->header.num_metadata; ++i) {
            if (map->metadata[i].data) {
                free(map->metadata[i].data);
            }
        }
        free(map->metadata);
    }
    free(map);
}
