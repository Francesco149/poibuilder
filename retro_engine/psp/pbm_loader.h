#ifndef PBM_LOADER_H
#define PBM_LOADER_H

#include "pbm.h"

typedef struct {
    char name[32];
    uint16_t width;
    uint16_t height;
    uint16_t format;
    uint16_t has_alpha;
    uint16_t is_swizzled;
    uint32_t data_size;
    void* pixels;
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
    PbmHeader header;
    PbmTexture* textures;
    PbmMesh* meshes;
    PbmCollider* colliders;
    uint32_t total_vertices;
} PbmMap;

PbmMap* pbm_load(const char* filepath);
void pbm_free(PbmMap* map);

#endif /* PBM_LOADER_H */
