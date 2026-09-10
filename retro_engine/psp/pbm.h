#ifndef PBM_H
#define PBM_H

#include <stdint.h>

#define PBM_MAGIC 0x314D4250 /* "PBM1" */
#define PBM_VERSION 1

#define PBM_TEX_FMT_RGBA8888 0
#define PBM_TEX_FMT_RGBA5551 1
#define PBM_TEX_FMT_RGBA4444 2
#define PBM_TEX_FMT_RGB565   3

typedef struct __attribute__((packed)) {
    uint32_t magic;         /* "PBM1" (0x314D4250) */
    uint32_t version;       /* 1 */
    uint32_t num_textures;  /* Count of textures */
    uint32_t num_meshes;    /* Count of meshes */
    uint32_t num_colliders; /* Count of colliders */
    float spawn_pos[3];     /* Default spawn position (x, y, z) */
    float spawn_rot;        /* Default spawn yaw angle in radians */
    float bounds_min[3];    /* Scene AABB min (x, y, z) */
    float bounds_max[3];    /* Scene AABB max (x, y, z) */
} PbmHeader;

typedef struct __attribute__((packed)) {
    char name[32];          /* Texture name / identifier */
    uint16_t width;         /* Texture width (power-of-two, e.g. 128, 256, 512) */
    uint16_t height;        /* Texture height (power-of-two) */
    uint16_t format;        /* PBM_TEX_FMT_* */
    uint16_t has_alpha;     /* 1 if texture has transparent pixels (<250), 0 if opaque */
    uint32_t data_size;     /* Size of raw pixel buffer in bytes */
} PbmTextureHeader;

typedef struct __attribute__((aligned(4))) {
    float u, v;             /* Texture coordinates */
    uint32_t color;         /* 0xAABBGGRR (baked lighting & AO) */
    float x, y, z;          /* 3D position */
} PbmVertex;

typedef struct __attribute__((packed)) {
    char name[32];          /* Mesh name */
    int32_t texture_id;     /* Index in texture array (-1 if untextured / vertex-color only) */
    uint32_t num_vertices;  /* Number of vertices (must be multiple of 3 for GU_TRIANGLES) */
    float bounds_min[3];    /* Mesh AABB min */
    float bounds_max[3];    /* Mesh AABB max */
} PbmMeshHeader;

typedef struct __attribute__((packed)) {
    char name[32];          /* Collider name */
    uint32_t type;          /* 0 = BOX, 1 = TRI_MESH, 2 = RAMP */
    float bounds_min[3];
    float bounds_max[3];
    uint32_t num_triangles;
} PbmColliderHeader;

#endif /* PBM_H */
