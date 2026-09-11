#ifndef PBM_LOADER_H
#define PBM_LOADER_H

#include "pbm.h"

#define PBM_MAX_MIP_LEVELS 8

typedef struct {
    char name[32];
    uint16_t width;
    uint16_t height;
    uint16_t format;
    uint16_t alpha_mode;                /* PBM_ALPHA_* */
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
    /* Texture repeats per second; 0,0 = static (see PbmMeshHeader). */
    float uv_scroll_u;
    float uv_scroll_v;
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
    /* Particle emitters (standard lump "emitters"). `emitters` is the file's
     * record list (sanitized + clamped at load); `particles` holds the
     * per-particle constants derived once from each emitter's seed, indexed by
     * emitter_first_particle[i] .. emitter_first_particle[i + 1]. */
    PbmEmitter* emitters;
    uint32_t num_emitters;
    PbmParticle* particles;
    uint32_t num_particles;
    uint32_t* emitter_first_particle;
    float* emitter_cull_radius;
    /* Parsed proof-of-concept convenience fields */
    char map_name[64];
    PbmEntityPatrolSphere patrol_sphere;
    int has_patrol_sphere;
    char env_preset[32];
} PbmMap;

PbmMap* pbm_load(const char* filepath);
void pbm_free(PbmMap* map);

/* Derives the per-particle constants for one emitter (PbmParticle). The loader
 * calls this for every emitter it parses; the profiler's particle probe calls
 * it too, so a measurement runs the shipped derivation. */
void pbm_derive_particles(const PbmEmitter* e, PbmParticle* out, uint32_t n);

#endif /* PBM_LOADER_H */
