#include "pbm_loader.h"
#include <stdio.h>
#include <stdlib.h>
#include <malloc.h>
#include <psputils.h>
#include <string.h>

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

    if (fread(&map->header, sizeof(PbmHeader), 1, f) != 1) {
        printf("[PBM] Error: Failed to read header\n");
        free(map);
        fclose(f);
        return NULL;
    }

    if (map->header.magic != PBM_MAGIC) {
        printf("[PBM] Error: Invalid magic 0x%08X (expected 0x%08X)\n", (unsigned int)map->header.magic, (unsigned int)PBM_MAGIC);
        free(map);
        fclose(f);
        return NULL;
    }

    printf("[PBM] Loaded header: %u textures, %u meshes, %u colliders\n",
        (unsigned int)map->header.num_textures,
        (unsigned int)map->header.num_meshes,
        (unsigned int)map->header.num_colliders);

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
            map->textures[i].data_size = thdr.data_size;

            /* 16-byte aligned pixel buffer for PSP DMA / GE */
            void* pixels = memalign(16, thdr.data_size);
            if (!pixels) {
                pixels = malloc(thdr.data_size);
            }
            if (pixels) {
                fread(pixels, 1, thdr.data_size, f);
                map->textures[i].pixels = pixels;
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

    /* Flush all loaded textures, vertices, and colliders from D-Cache to main RAM
     * so the Sony GE hardware DMA reads valid data without bus stalls! */
    sceKernelDcacheWritebackAll();
    fclose(f);
    printf("[PBM] Successfully loaded '%s' (%u total vertices)\n", filepath, (unsigned int)map->total_vertices);
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
    free(map);
}
