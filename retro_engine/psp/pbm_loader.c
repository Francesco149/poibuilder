#include "pbm_loader.h"
#include <stdio.h>
#include <stdlib.h>
#include <malloc.h>
#ifdef __PSP__
#include <psputils.h>
#endif
#include <string.h>
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

PbmMap* pbm_load(const char* filepath) {
    FILE* f = fopen(filepath, "rb");
    if (!f) {
        printf("[PBM] Error: Could not open '%s'\n", filepath);
        return NULL;
    }

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
    if (magic != PBM_MAGIC && magic != PBM_MAGIC_V1) {
        printf("[PBM] Error: Invalid magic 0x%08X (expected 'PBM2' 0x%08X or 'PBM1' 0x%08X)\n",
            (unsigned int)magic, (unsigned int)PBM_MAGIC, (unsigned int)PBM_MAGIC_V1);
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

    printf("[PBM] Loaded header v%u: %u textures, %u meshes, %u colliders, %u metadata\n",
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
            map->textures[i].has_alpha = thdr.has_alpha;
            map->textures[i].data_size = thdr.data_size;

            /* 16-byte aligned pixel buffer for PSP DMA / GE */
            void* pixels = memalign(16, thdr.data_size);
            if (!pixels) {
                pixels = malloc(thdr.data_size);
            }
            if (pixels) {
                fread(pixels, 1, thdr.data_size, f);
                map->textures[i].pixels = pixels;
                map->textures[i].is_swizzled = 0;

                /* Swizzle 16-bit power-of-two textures to eliminate texture cache thrashing and memory bus congestion! */
                if (thdr.format == PBM_TEX_FMT_RGBA5551 && thdr.width >= 16 && thdr.height >= 8 && (thdr.width & (thdr.width - 1)) == 0) {
                    void* swizzled = memalign(16, thdr.data_size);
                    if (swizzled) {
                        swizzle_texture_16((uint8_t*)swizzled, (const uint8_t*)pixels, thdr.width, thdr.height);
                        free(pixels);
                        map->textures[i].pixels = swizzled;
                        map->textures[i].is_swizzled = 1;
                    }
                }
            }
        }
    }

    /* 2. Meshes */
    map->total_vertices = 0;
    if (map->header.num_meshes > 0) {
        map->meshes = (PbmMesh*)calloc(map->header.num_meshes, sizeof(PbmMesh));
        for (uint32_t i = 0; i < map->header.num_meshes; ++i) {
            PbmMeshHeader mhdr;
            if (fread(&mhdr, sizeof(PbmMeshHeader), 1, f) != 1) {
                printf("[PBM] Error reading mesh header %u\n", (unsigned int)i);
                break;
            }
            memcpy(map->meshes[i].name, mhdr.name, 32);
            map->meshes[i].texture_id = mhdr.texture_id;
            map->meshes[i].num_vertices = mhdr.num_vertices;
            memcpy(map->meshes[i].bounds_min, mhdr.bounds_min, sizeof(float) * 3);
            memcpy(map->meshes[i].bounds_max, mhdr.bounds_max, sizeof(float) * 3);
            map->total_vertices += mhdr.num_vertices;

            uint32_t vbuf_size = mhdr.num_vertices * sizeof(PbmVertex);
            void* vbuf = memalign(16, vbuf_size);
            if (!vbuf) {
                vbuf = malloc(vbuf_size);
            }
            if (vbuf) {
                fread(vbuf, 1, vbuf_size, f);
                map->meshes[i].vertices = (PbmVertex*)vbuf;
            }
        }
    }

    /* 3. Colliders */
    if (map->header.num_colliders > 0) {
        map->colliders = (PbmCollider*)calloc(map->header.num_colliders, sizeof(PbmCollider));
        for (uint32_t i = 0; i < map->header.num_colliders; ++i) {
            PbmColliderHeader chdr;
            if (fread(&chdr, sizeof(PbmColliderHeader), 1, f) != 1) {
                printf("[PBM] Error reading collider header %u\n", (unsigned int)i);
                break;
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

    /* Flush all loaded textures, vertices, and colliders from D-Cache to main RAM
     * so the Sony GE hardware DMA reads valid data without bus stalls! */
#ifdef __PSP__
    sceKernelDcacheWritebackAll();
#endif
    return map;
}

void pbm_free(PbmMap* map) {
    if (!map) return;
    if (map->textures) {
        for (uint32_t i = 0; i < map->header.num_textures; ++i) {
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
