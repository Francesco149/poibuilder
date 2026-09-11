#ifndef PSP_RENDER_H
#define PSP_RENDER_H

#include <stdint.h>
#include "pbm_loader.h"

/* Per-frame rendering configuration.
 * render_cfg_default() reproduces the shipping renderer exactly; every other
 * field combination exists so the profiler (psp_prof.c) can ablate one GPU
 * state at a time and attribute frame cost to a specific pipeline stage. */
typedef struct {
    int   display_mode;    /* 0 textured+baked, 1 vertex colour only, 2 wireframe */
    int   use_textures;    /* 0 binds no textures (vertex colour only) */
    int   depth_test;
    int   cull;
    int   clip_planes;     /* GE near/far clip planes vs guardband-only */
    int   alpha_pass;      /* the billboard/foliage alpha+blend pass */
    int   entity;          /* the scripted patrol sphere */
    int   uv_scroll;       /* animated UV scroll (PBM 3.0) on scrolling meshes */
    int   particles;       /* particle emitters, as a bitmask: 1 = blended,
                            * 2 = additive, 3 = both (the shipped default).
                            * The two halves are separable because they differ in
                            * what they cost a frame: additive needs no sorting
                            * and no depth order, blended needs both. */
    int   tex_filter;      /* PBFILT_* */
    float tex_lod_bias;    /* negative = sharper (picks a smaller mip level) */
    int   tex_level_mode;  /* PBLEVEL_*: how the mip level is chosen */
    int   force_small_tex; /* bind a cache-resident 64x64 texture to every mesh */
    int   use_mips;        /* sample the load-time mip chain (mipmap min filter) */
    float near_plane;
    int   env_preset;      /* PB_ENV_* */
    uint32_t clear_color;  /* 0xBBGGRR framebuffer clear color */
    int   fog_enabled;
    float fog_near;
    float fog_far;
    uint32_t fog_color;
} RenderCfg;

/* tex_filter values. Note sceGuTexFilter(min, mag): the first argument is the
 * MINIFICATION filter, the second the MAGNIFICATION filter. */
/* How the GE picks the mip level. AUTO derives it per primitive from the UV
 * derivatives; CONST uses one level everywhere. Per-primitive derivation is
 * what puts a visible step in sharpness at every tile boundary on a grazing
 * floor, so CONST is the escape hatch when that reads as a seam. */
#define PBLEVEL_AUTO   0
#define PBLEVEL_CONST  1

#define PBFILT_MIP_LIN 0   /* min LINEAR_MIPMAP_NEAREST, mag LINEAR (default) */
#define PBFILT_LINEAR  1   /* min LINEAR_MIPMAP_LINEAR (trilinear), mag LINEAR */
#define PBFILT_NEAREST 2   /* both NEAREST: 1 tap per fragment, no filter work */
#define PBFILT_ASYM    3   /* min LINEAR_MIPMAP_NEAREST, mag NEAREST (the old default) */

/* Environment Presets (Dawn, Day, Dusk, Night) matching dioramap / PoiBuilder */
#define PB_ENV_DAY   0
#define PB_ENV_DAWN  1
#define PB_ENV_DUSK  2
#define PB_ENV_NIGHT 3

typedef struct {
    const char* name;
    uint32_t clear_color;
    int fog_enabled;
    float fog_near;
    float fog_far;
    uint32_t fog_color;
} PbEnvDef;

const PbEnvDef* pb_env_get(int preset_id);
const PbEnvDef* pb_env_find(const char* name);
void render_cfg_set_env(RenderCfg* cfg, const char* name);
void render_cfg_default(RenderCfg* cfg);

/* Applies overrides from host0:/poi_render.txt (or ms0:) if the file exists.
 * Lets filter/mip settings be re-tested without rebuilding the binary. */
void psp_render_overrides(RenderCfg* cfg);

/* Drops any mesh whose NAME contains `needle` from both passes ("" re-enables
 * everything). The profiler uses it to attribute frame cost to one surface at
 * a time; the runtime override file exposes it as `skip_mesh=`. */
void psp_render_skip_mesh(const char* needle);

typedef struct {
    uint32_t draw_calls;
    uint32_t vertices;
    uint32_t triangles;
    uint32_t particles;   /* emitter particles actually drawn this frame */
} RenderStats;

/* Vertex layout shared by the 3D meshes and the 2D HUD sprites. */
typedef struct {
    float u, v;
    uint32_t color;
    float x, y, z;
} PspVertex;

/* The shared 1 MB display list. One open list per frame; see the callers. */
void* psp_dlist(void);

/* Microsecond clock (sceRtcGetCurrentTick). */
uint64_t psp_now_us(void);

void psp_font_init(void);

/* 2D HUD text. Self-contained: sets every GE state it needs, so it may be
 * called before or after the 3D passes. */
void psp_draw_text(float x, float y, uint32_t color, const char* str);

/* The in-game HUD block (frame stats + map/mode line + optional extra line).
 * Shared by the game loop and the profiler so both measure the same pixels. */
void psp_draw_hud(PbmMap* map, const RenderStats* stats, float fps,
                  int display_mode, const char* extra, const char* extra2,
                  const char* input, int hold_on);

/* A 64x64 swizzled RGBA5551 texture used by the profiler's cache-residency
 * ablation. */
const void* psp_small_texture(int* width, int* height);

/* Emits the 3D scene (clear, both passes, entity) into the currently open
 * display list. Does not start/finish/sync the list.
 * `time_s` is the scene clock in seconds: it drives the scripted patrol
 * entity and every mesh's animated UV scroll (PbmMeshHeader uv_scroll_u/v). */
void psp_render_scene(PbmMap* map, const RenderCfg* cfg,
                      float cx, float cy, float cz, float yaw, float pitch,
                      float time_s, RenderStats* stats);

/* Synthetic particle load for the profiler: draws `count` additive particles of
 * `size` metres at the identity view, through the shipped emitter evaluator.
 * It exists so the cost of N particles can be measured on the device without
 * authoring a map for every data point. */
void psp_render_particle_probe(int count, float size, uint32_t color, RenderStats* stats);

/* Deterministic fill calibration through the emitter path: `count` stationary
 * particles covering the frustum at 2 m, each `size` metres tall. `additive`
 * selects the blend mode, so the two can be compared directly. */
void psp_render_particle_fill_probe(PbmMap* map, int count, float size, int additive,
                                    int texture_id, uint32_t color, RenderStats* stats);

#endif /* PSP_RENDER_H */
