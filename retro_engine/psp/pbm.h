#ifndef PBM_H
#define PBM_H

#include <stdint.h>

#define PBM_MAGIC          0x334D4250 /* "PBM3" (Little Endian: 'P','B','M','3') */
#define PBM_MAGIC_V2       0x324D4250 /* "PBM2" */
#define PBM_MAGIC_V1       0x314D4250 /* "PBM1" */
#define PBM_VERSION        3
#define PBM_MIN_SUPPORTED  1
#define PBM_MAX_SUPPORTED  3
/* v1/v2 mesh headers carried no trailing words: they are 64 bytes, v3's are 72
 * (see PbmMeshHeader). The loader picks the size from the file version. */
#define PBM_MESH_HEADER_V2 64

#define PBM_META_RAW       0
#define PBM_META_STRING    1
#define PBM_META_JSON      2
#define PBM_META_ENTITY    3

#define PBM_ENTITY_PATROL_SPHERE 1

#define PBM_TEX_FMT_RGBA8888 0
#define PBM_TEX_FMT_RGBA5551 1
#define PBM_TEX_FMT_RGBA4444 2
#define PBM_TEX_FMT_RGB565   3

typedef struct __attribute__((packed)) {
    uint32_t magic;         /* "PBM2" (0x324D4250) */
    uint32_t version;       /* 2 */
    uint32_t num_textures;  /* Count of textures */
    uint32_t num_meshes;    /* Count of meshes */
    uint32_t num_colliders; /* Count of colliders */
    uint32_t num_metadata;  /* Count of metadata entries */
    float spawn_pos[3];     /* Default spawn position (x, y, z) */
    float spawn_rot;        /* Default spawn yaw angle in radians */
    float bounds_min[3];    /* Scene AABB min (x, y, z) */
    float bounds_max[3];    /* Scene AABB max (x, y, z) */
} PbmHeader;

/* Alpha handling of a texture (PbmTextureHeader.alpha_mode). v1/v2 files wrote
 * only 0/1 here (the field was named has_alpha); 2 is new in v3. */
#define PBM_ALPHA_NONE   0  /* fully opaque: opaque pass, mip chain */
#define PBM_ALPHA_CUTOUT 1  /* hard-edged cutout (foliage, decals): alpha-tested
                             * in the alpha pass, NO mip chain (halving a 1-bit
                             * alpha makes every level further transparent,
                             * eating the silhouette) */
#define PBM_ALPHA_BLEND  2  /* soft alpha (water, glass, smoke): blended in the
                             * alpha pass, mip chain kept (averaged alpha is
                             * exactly what a blended surface wants) */

typedef struct __attribute__((packed)) {
    char name[32];          /* Texture name / identifier */
    uint16_t width;         /* Texture width (power-of-two, e.g. 128, 256, 512) */
    uint16_t height;        /* Texture height (power-of-two) */
    uint16_t format;        /* PBM_TEX_FMT_* */
    uint16_t alpha_mode;    /* PBM_ALPHA_* (v1/v2 called this `has_alpha`: 0/1) */
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
    /* Animated UV scroll (PBM 3.0; v1/v2 mesh headers ended 8 bytes earlier, so
     * their meshes are simply static). The texture coordinates of every vertex
     * of this mesh are shifted by (u * uv_scroll_u, v * uv_scroll_v) at draw
     * time, u/v being scene time in seconds. Units are texture repeats per
     * second (1.0 = one full tile per second along that axis); 0,0 = static,
     * and the sign picks the direction. The mesh MUST reference a standalone,
     * repeat-wrapped texture — an offset applied to a tile-atlas slot would
     * drag the tile across its slot border. */
    float uv_scroll_u;
    float uv_scroll_v;
} PbmMeshHeader;

typedef struct __attribute__((packed)) {
    char name[32];          /* Collider name */
    uint32_t type;          /* 0 = BOX, 1 = TRI_MESH, 2 = RAMP */
    float bounds_min[3];
    float bounds_max[3];
    uint32_t num_triangles;
} PbmColliderHeader;


typedef struct __attribute__((packed)) {
    char tag[32];           /* Metadata identifier, e.g. "map_name", "entities" */
    uint32_t type;          /* PBM_META_* */
    uint32_t data_size;     /* Length of payload in bytes */
} PbmMetadataHeader;

/* Proof of concept entity structure: 3-point cyclic patrolling sphere */
typedef struct __attribute__((packed)) {
    char name[32];          /* "PatrolSphere" */
    uint32_t entity_type;   /* PBM_ENTITY_PATROL_SPHERE */
    float radius;           /* Sphere radius in meters */
    uint32_t color;         /* 0xAABBGGRR color */
    float speed;            /* Velocity in meters per second */
    uint32_t num_waypoints; /* Number of waypoints (e.g. 3) */
    float waypoints[3][3];  /* 3D waypoints */
} PbmEntityPatrolSphere;
#endif /* PBM_H */
