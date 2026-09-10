#ifndef PBM_LOADER_H
#define PBM_LOADER_H

#include "pbm.h"

#define PBM_MAX_MIP_LEVELS 8

typedef struct {
    char name[32];
    uint16_t width;
    uint16_t height;
    uint16_t format;
    uint16_t has_alpha;
    uint16_t is_swizzled;
    uint32_t data_size;
    void* pixels;                       /* mip level 0 */
    /* Mip chain, built at load time for opaque 16-bit power-of-two textures.
     * Each level is its own swizzled, 64-byte aligned buffer: the GE keeps one
     * base/size register per level (sceGuTexImage picks the level with its
     * first argument), so the chain layout is entirely ours. Sampled with a
     * *mipmap* minification filter it collapses the texel footprint of every
     * minified surface to roughly one texel per pixel, which is what keeps the
     * 8 KB texture cache from missing on every fragment. */
    uint32_t num_levels;                /* >= 1; 1 == no chain */
    uint16_t level_w[PBM_MAX_MIP_LEVELS];
    uint16_t level_h[PBM_MAX_MIP_LEVELS];
    void* level_ptr[PBM_MAX_MIP_LEVELS];
} PbmTexture;

typedef struct {
    char name[32];
    int32_t texture_id;
    uint32_t num_vertices;
    float bounds_min[3];
    float bounds_max[3];
    PbmVertex* vertices;
} PbmMesh;

typedef struct {
    char name[32];
    uint32_t type;
    float bounds_min[3];
    float bounds_max[3];
    uint32_t num_triangles;
    float* triangles;
} PbmCollider;
typedef struct {
    char tag[32];
    uint32_t type;
    uint32_t data_size;
    void* data;
} PbmMetadata;


typedef struct {
    PbmHeader header;
    PbmTexture* textures;
    PbmMesh* meshes;
    PbmCollider* colliders;
    PbmMetadata* metadata;
    uint32_t total_vertices;
    /* Parsed proof-of-concept convenience fields */
    char map_name[64];
    PbmEntityPatrolSphere patrol_sphere;
    int has_patrol_sphere;
} PbmMap;

PbmMap* pbm_load(const char* filepath);
void pbm_free(PbmMap* map);

#endif /* PBM_LOADER_H */
