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
    int   tex_filter;      /* PBFILT_* */
    float tex_lod_bias;    /* negative = sharper (picks a smaller mip level) */
    int   tex_level_mode;  /* PBLEVEL_*: how the mip level is chosen */
    int   force_small_tex; /* bind a cache-resident 64x64 texture to every mesh */
    int   use_mips;        /* sample the load-time mip chain (mipmap min filter) */
    float near_plane;
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

void render_cfg_default(RenderCfg* cfg);

/* Applies overrides from host0:/poi_render.txt (or ms0:) if the file exists.
 * Lets filter/mip settings be re-tested without rebuilding the binary. */
void psp_render_overrides(RenderCfg* cfg);

typedef struct {
    uint32_t draw_calls;
    uint32_t vertices;
    uint32_t triangles;
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
 * display list. Does not start/finish/sync the list. */
void psp_render_scene(PbmMap* map, const RenderCfg* cfg,
                      float cx, float cy, float cz, float yaw, float pitch,
                      float ent_time, RenderStats* stats);

#endif /* PSP_RENDER_H */
