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
/* Standard lump: particle emitters (binary, normative layout below). */
#define PBM_META_EMITTER   4

#define PBM_ENTITY_PATROL_SPHERE 1

#define PBM_TEX_FMT_RGBA8888 0
#define PBM_TEX_FMT_RGBA5551 1
#define PBM_TEX_FMT_RGBA4444 2
#define PBM_TEX_FMT_RGB565   3

typedef struct __attribute__((packed)) {
    uint32_t magic;         /* "PBM3" (0x334D4250); PBM2/PBM1 still load */
    uint32_t version;       /* 3 */
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
                             * in the alpha pass, mip chain built with an
                             * alpha-preserving combine (ANY opaque texel keeps
                             * the level opaque, so the silhouette dilates
                             * instead of eroding — a plain box filter on a
                             * 1-bit alpha would eat the silhouette away) */
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

/* ── Particle emitters (standard lump "emitters") ─────────────────────────
 * A normative part of the format: an emitter is a LOOPING, STATELESS particle
 * stream. No particle state is stored anywhere -- at any scene time t every
 * particle of an emitter is a pure function of (t, its index, the emitter's
 * seed), which is what makes the feature cost a few flops per particle on the
 * CPU, one draw call per emitter, and nothing else. See SPEC_RETRO_FORMAT.md
 * for the normative semantics; the constants below are the binary layout.
 *
 * Payload = PbmEmitterLumpHeader followed by `count` PbmEmitter records. */
#define PBM_EMITTER_MAGIC   0x54494D45u /* "EMIT" */
#define PBM_EMITTER_VERSION 1
#define PBM_EMITTER_LUMP_HDR 16
#define PBM_EMITTER_SIZE    176         /* sizeof(PbmEmitter) */

/* PbmEmitter.flags */
#define PBM_EMIT_ADDITIVE    (1u << 0)  /* GU_ADD, SRC_ALPHA * ONE (order-independent,
                                         * so no sorting). Cleared = alpha blend,
                                         * which the runtime sorts back-to-front. */
#define PBM_EMIT_Y_LOCKED    (1u << 1)  /* Cylinder billboard: the quad's up axis stays
                                         * world up instead of following the camera. */
#define PBM_EMIT_VEL_ALIGN   (1u << 2)  /* Align the quad's up axis with the particle's
                                         * own velocity (overrides Y_LOCKED). */
#define PBM_EMIT_PHASE_ALIGN (1u << 3)  /* All particles share one phase: the emitter
                                         * becomes a burst repeating every lifetime
                                         * instead of a continuous stream. */
#define PBM_EMIT_SPAWN_BOX   (1u << 4)  /* Spawn inside an axis-aligned BOX whose
                                         * half extents are reserved[0..2] (world
                                         * metres) instead of the spawn_radius ball.
                                         * A wave crest's spray line, a band of sun
                                         * glitter on the sea: shapes a ball cannot
                                         * make without a dozen emitters. Loaders
                                         * that predate the flag see reserved != 0
                                         * and a point/ball emitter, which degrades
                                         * to a clump rather than failing. */
#define PBM_EMIT_BURST_PHASE (1u << 5)  /* With PHASE_ALIGN: the burst fires at
                                         * t = (1 - reserved0/256) * life (mod life)
                                         * instead of t = 0, so several bursts that
                                         * share a lifetime can be staggered — spray
                                         * timed to each of a set of waves. */

/* Runtime limits. A file may exceed them; a loader clamps and says so, so a map
 * authored for a stronger machine still loads with a reduced budget. */
#define PBM_EMIT_MAX_EMITTERS        64
#define PBM_EMIT_MAX_PER_EMITTER     64
#define PBM_EMIT_MAX_TOTAL_PARTICLES 256

typedef struct __attribute__((packed)) {
    uint32_t magic;         /* PBM_EMITTER_MAGIC */
    uint32_t version;       /* PBM_EMITTER_VERSION */
    uint32_t count;         /* Number of PbmEmitter records that follow */
    uint32_t reserved;      /* MUST be 0 */
} PbmEmitterLumpHeader;

typedef struct __attribute__((packed)) {
    char     name[24];      /* 0x00  Debug/label name */
    float    pos[3];        /* 0x18  Emitter origin, world space */
    float    dir[3];        /* 0x24  Emission axis, unit length */
    float    spread;        /* 0x30  Cone half-angle in radians; PI = sphere */
    float    speed_min;     /* 0x34  Initial speed (m/s) */
    float    speed_max;     /* 0x38 */
    float    life_min;      /* 0x3C  Particle lifetime (s); > 0 */
    float    life_max;      /* 0x40 */
    float    gravity[3];    /* 0x44  Constant acceleration (m/s^2) */
    float    damping;       /* 0x50  Exponential velocity drag, per second (0 = none) */
    float    size_min;      /* 0x54  Quad HEIGHT at birth (m), lower bound */
    float    size_max;      /* 0x58  Quad height at birth (m), upper bound */
    float    size_mid;      /* 0x5C  Birth-size MULTIPLIER at the knee (1 = unchanged) */
    float    size_end;      /* 0x60  Birth-size MULTIPLIER at death */
    float    aspect;        /* 0x64  Width / height of the particle quad (1 = square) */
    float    angle_min;     /* 0x68  Initial screen-plane rotation (radians) */
    float    angle_max;     /* 0x6C */
    float    spin_min;      /* 0x70  Rotation speed over life (rad/s) */
    float    spin_max;      /* 0x74 */
    float    wobble_amp;    /* 0x78  Lateral sinusoidal displacement (m, 0 = none) */
    float    wobble_freq;   /* 0x7C  Wobble frequency (Hz) */
    float    spawn_radius;  /* 0x80  Spawn sphere radius (m, 0 = point emitter) */
    float    knee;          /* 0x84  Life fraction of the mid key, 0..1 (0.5 typical) */
    uint32_t color_start;   /* 0x88  RGBA8 (0xAABBGGRR) at birth */
    uint32_t color_mid;     /* 0x8C  at the knee */
    uint32_t color_end;     /* 0x90  at death */
    int32_t  texture_id;    /* 0x94  Texture chunk index; -1 = built-in radial glow */
    uint16_t count;         /* 0x98  Simultaneous particles (>= 1) */
    uint16_t flags;         /* 0x9A  PBM_EMIT_* */
    uint8_t  atlas_cols;    /* 0x9C  Flipbook grid, >= 1 */
    uint8_t  atlas_rows;    /* 0x9D  >= 1 */
    uint8_t  anim_loops;    /* 0x9E  Animation loops per particle lifetime, >= 1 */
    uint8_t  reserved0;     /* 0x9F  0, or with PBM_EMIT_BURST_PHASE the burst's
                             *       phase in 1/256ths of the lifetime */
    uint32_t seed;          /* 0xA0  Per-emitter random seed */
    float    reserved[3];   /* 0xA4  0, or the spawn box half extents when
                             *       flags has PBM_EMIT_SPAWN_BOX */
} PbmEmitter;

/* Layout guards: these offsets ARE the file format, so a struct edit must not
 * be able to drift past the specification unnoticed. */
#include <stddef.h>
typedef char pbm_emitter_size_guard[(sizeof(PbmEmitter) == PBM_EMITTER_SIZE) ? 1 : -1];
typedef char pbm_emitter_lump_guard[(sizeof(PbmEmitterLumpHeader) == PBM_EMITTER_LUMP_HDR) ? 1 : -1];
typedef char pbm_emitter_off_guard[
    (offsetof(PbmEmitter, pos) == 0x18 && offsetof(PbmEmitter, color_start) == 0x88 &&
     offsetof(PbmEmitter, texture_id) == 0x94 && offsetof(PbmEmitter, seed) == 0xA0) ? 1 : -1];

/* ── Mesh effects (standard lump "mesh_fx", type PBM_META_MESH_FX) ─────────
 * Per-mesh runtime animation that costs the CPU a few register writes per
 * mesh per frame and nothing per vertex:
 *
 *   MORPH     the GE's own vertex morphing. A morphing mesh carries N full
 *             vertex sets ("targets", N <= 8); the GE fetches all of them and
 *             blends position, colour and UV with the morph-weight registers
 *             before transform. Two closed-form weight models:
 *               KEYFRAME: the targets are poses on a loop of `period` seconds;
 *                 key_t[i] is pose i's place on the loop (0..1, ascending,
 *                 key_t[0] = 0). Only the two poses around the current time
 *                 have non-zero weight.
 *               HARMONIC: target 0 is the rest pose, every other target i is
 *                 rest + a displacement D_i whose weight is
 *                 sin(2*pi*t / key_t[i] + key_phase[i]), and target 0 takes
 *                 1 - sum(others). Two targets 90 degrees apart with the same
 *                 period form a quadrature pair, which reproduces a TRAVELLING
 *                 wave exactly (sin(kx - wt) = sin kx cos wt - cos kx sin wt):
 *                 Gerstner swell with 3 targets, two swells with 5.
 *               CYCLIC: the convex form of HARMONIC, and what the exporter
 *                 writes. Target 0 (the rest pose) has weight 0; targets
 *                 1..N-1 come in TRIPLETS, triplet j = targets 1+3j..3+3j with
 *                 period key_t[1+3j] and phase key_phase[1+3j]:
 *                 w[1+3j+k] = (1 + cos(2*pi*t/P_j + ph_j - 2*pi*k/3)) / (3*J),
 *                 J = (N-1)/3. Every weight is >= 0 and they sum to 1, so the
 *                 GE's 24-bit weights blend positions without amplifying error
 *                 (HARMONIC's rest weight swings to -3..+5 with two swells),
 *                 and a travelling wave is still exact: a rotating displacement
 *                 A cos + B sin is the triplet P_k = rest + 2J(A cos phi_k +
 *                 B sin phi_k), phi_k = 2*pi*k/3. Two periods fit (7 sets).
 *   FLIPBOOK  the mesh's texture is frame_tex[(int)(t * fps) % num_frames].
 *   ADDITIVE  drawn in the alpha pass with GU_ADD, SRC_ALPHA * ONE (glints,
 *             sun glare, light shafts): order-independent like the additive
 *             emitters.
 *   NO_FOG    drawn with fog disabled (the sky dome, a sun disc).
 *
 * Payload = PbmMeshFxLumpHeader, then `count` records, each a PbmMeshFx
 * followed by `morph_bytes` of vertex data: targets 1..N-1, each a full
 * copy of the mesh's PbmVertex array in the mesh's own vertex order (target 0
 * IS the mesh's vertex array). */
#define PBM_META_MESH_FX     5
#define PBM_META_CAMERA_PATH 6
#define PBM_META_ENV         7

#define PBM_MESHFX_MAGIC   0x3158464Du /* "MFX1" */
#define PBM_MESHFX_VERSION 1
#define PBM_MESHFX_SIZE    124         /* sizeof(PbmMeshFx) */
#define PBM_MESHFX_MAX_TARGETS 8
#define PBM_MESHFX_MAX_FRAMES  16

#define PBM_MFX_ADDITIVE (1u << 0)
#define PBM_MFX_NO_FOG   (1u << 1)
#define PBM_MFX_DECAL    (1u << 2)  /* depth-biased toward the camera by
                                     * reserved0 depth-buffer units (0 = 48):
                                     * an overlay lying on another surface (a
                                     * sun path on the sea, a blob shadow on
                                     * sand) wins the 16-bit depth test at any
                                     * distance. The PSP has no polygon offset;
                                     * the runtime biases the projection's z
                                     * row by eps*w for the draw. */

#define PBM_MORPH_NONE     0
#define PBM_MORPH_KEYFRAME 1
#define PBM_MORPH_HARMONIC 2
#define PBM_MORPH_CYCLIC   3

typedef struct __attribute__((packed)) {
    uint32_t magic;         /* PBM_MESHFX_MAGIC */
    uint32_t version;
    uint32_t count;
    uint32_t reserved;      /* MUST be 0 */
} PbmMeshFxLumpHeader;

typedef struct __attribute__((packed)) {
    uint32_t mesh_index;    /* 0x00  index into the mesh table */
    uint16_t flags;         /* 0x04  PBM_MFX_* */
    uint8_t  morph_mode;    /* 0x06  PBM_MORPH_* */
    uint8_t  num_targets;   /* 0x07  vertex sets including the mesh's own (1 = no morph) */
    float    period;        /* 0x08  KEYFRAME: loop length (s) */
    float    phase;         /* 0x0C  KEYFRAME: time offset (s) */
    float    key_t[8];      /* 0x10  KEYFRAME: pose times 0..1; HARMONIC: period (s) per target */
    float    key_phase[8];  /* 0x30  HARMONIC: phase (rad) per target */
    uint8_t  ease;          /* 0x50  KEYFRAME: 0 linear, 1 smoothstep between poses */
    uint8_t  num_frames;    /* 0x51  flipbook frames (0 = no flipbook) */
    uint16_t reserved0;     /* 0x52  DECAL depth bias (depth units), else 0 */
    float    fps;           /* 0x54  flipbook frames per second */
    int16_t  frame_tex[16]; /* 0x58  flipbook texture ids */
    uint32_t morph_bytes;   /* 0x78  = (num_targets - 1) * num_vertices * 24 */
} PbmMeshFx;
typedef char pbm_meshfx_size_guard[(sizeof(PbmMeshFx) == PBM_MESHFX_SIZE) ? 1 : -1];

/* ── Camera path (standard lump "camera_path") ─────────────────────────────
 * Named viewpoints the map author placed. The profiler sweeps them (a map
 * prices its own views instead of the courtyard's), and the app flies through
 * them in attract mode: hold each pose `hold` seconds, then travel to the next
 * over `travel` seconds on a Catmull-Rom spline, looping. */
#define PBM_CAMPATH_MAGIC 0x534D4143u /* "CAMS" */
#define PBM_CAMPATH_MAX   24
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t version;       /* 1 */
    uint32_t count;
    uint32_t reserved;
} PbmCameraPathHeader;
typedef struct __attribute__((packed)) {
    char  name[16];
    float pos[3];
    float yaw, pitch;       /* radians, the app's convention (yaw 0 looks down -Z) */
    float hold;             /* seconds spent at this pose */
    float travel;           /* seconds from this pose to the next */
} PbmCameraPose;            /* 44 bytes */

/* ── Environment (standard lump "env") ─────────────────────────────────────
 * The map's own sky colour and fog, overriding the time-of-day preset. */
#define PBM_ENV_MAGIC 0x31564E45u /* "ENV1" */
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t clear_color;   /* 0x00BBGGRR */
    uint32_t fog_enabled;
    float    fog_near, fog_far;
    uint32_t fog_color;     /* 0x00BBGGRR */
    float    far_plane;     /* projection far plane, metres (0 = default 200) */
    float    near_plane;    /* metres (0 = the runtime's default); the 16-bit
                             * depth buffer's precision scales with it */
    float    reserved[2];
} PbmEnv;                   /* 40 bytes */

/* Runtime per-particle constants. These are CONSTANT for the whole life of the
 * map, so they are derived once at load (from the emitter's seed and the
 * particle index) and never recomputed: the per-frame cost is the closed-form
 * evaluation in psp_render.c, not a simulation. */
typedef struct {
    float life;         /* seconds */
    float inv_life;     /* 1/life */
    float phase;        /* 0..1 offset into the loop */
    float speed;        /* m/s */
    float size;         /* m (edge length at birth) */
    float spin;         /* rad/s */
    float angle0;       /* rad, initial screen-plane rotation */
    float wobble_phase; /* rad */
    float anim_offset;  /* 0..1, random flipbook start */
    float dir[3];       /* unit emission direction (inside the cone) */
    float spawn[3];     /* offset inside the spawn sphere */
} PbmParticle;

/* ── The emitter random source (normative) ────────────────────────────────
 * An emitter's whole look is a function of its seed, so this hash IS part of
 * the format's semantics: two runtimes that implement it as written here show
 * the same particle field. It is a 32-bit avalanche hash (the "lowbias32"
 * constants) -- cheap enough to run a few times per particle at load, mixed
 * well enough that neighbouring indices are uncorrelated. */
static inline uint32_t pbm_hash32(uint32_t x) {
    x ^= x >> 16; x *= 0x7feb352du;
    x ^= x >> 15; x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

/* Uniform [0,1) hash of (seed, particle index, channel). */
static inline float pbm_rand(uint32_t seed, uint32_t idx, uint32_t chan) {
    return (float)(pbm_hash32(seed ^ (idx * 0x9E3779B9u) ^ (chan * 0x85EBCA6Bu)) >> 8)
           * (1.0f / 16777216.0f);
}

#endif /* PBM_H */
