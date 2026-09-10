/* PoiRetro PSP — on-device frame profiler.
 *
 * The desktop emulator hides every cost that matters on this hardware: its
 * rasteriser runs on the host GPU with a huge texture cache and no shared
 * memory bus, so a scene that crawls on a real PSP can run at full speed
 * there. The PSP itself is therefore the only trustworthy measurement
 * channel. For every test this module reports:
 *
 *     cpu  — time spent BUILDING the display list (CPU busy, GE idle)
 *     gpu  — time spent in sceGuSync waiting for the GE (the GPU's own cost)
 *     wall — real elapsed frame time, including the vblank-paced swap
 *
 * Measurements are paired with ablations that attribute cost to a pipeline
 * stage: textures off, a cache-resident 64x64 texture substituted for the
 * 512x512 ones, minification vs magnification filters, depth test, culling,
 * clip planes, near-plane distance — plus synthetic fill, per-draw-call and
 * triangle-throughput probes for calibration.
 *
 * A run is triggered by the presence of ms0:/poi_profile.cfg, which can
 * override frame counts and camera poses without rebuilding the EBOOT. Output
 * goes to ms0:/poi_profile.txt and to the screen. */
#include <pspkernel.h>
#include <pspdisplay.h>
#include <pspgu.h>
#include <pspgum.h>
#include <psputils.h>
#include <stdio.h>
#include <stdlib.h>
#include <malloc.h>
#include <string.h>
#include <math.h>

#include "psp_render.h"
#include "psp_prof.h"

#define SCR_W 480
#define SCR_H 272

#define MAX_TESTS 64
#define MAX_CAMS  24

enum {
    TK_CLEAR = 0,    /* clear only: the per-frame floor */
    TK_SCENE,        /* full map render, cfg-driven */
    TK_FILL2D,       /* N screen-space quads */
    TK_FILL3D_FIT,   /* one camera-facing world quad exactly filling the screen */
    TK_FILL3D_BIG,   /* the same quad 16x oversized: crosses the guardband */
    TK_DRAWCALLS,    /* N separate tiny draw calls */
    TK_TRIS          /* N triangles in one draw call */
};

typedef struct {
    const char* name;
    int   kind;
    int   frames;      /* 0 = use cfg default */
    RenderCfg cfg;
    float cam[3];
    float yaw, pitch;
    int   count;       /* quads / draw calls / triangle quads */
    int   tex;         /* 0 none, 1 = biggest map texture, 2 = cache-resident 64x64 */
    float rect[4];     /* x0,y0,x1,y1 screen px (TK_FILL2D) */
    int   depth;
    int   blend;
    int   hud;         /* draw the in-game HUD block (scene tests) */
} ProfTest;

typedef struct {
    const char* name;
    float cpu_ms;
    float gpu_ms;
    float wall_ms;
    float maxfps;
    uint32_t draws;
    uint32_t verts;
} ProfResult;

static ProfResult s_results[MAX_TESTS];
static int s_result_count = 0;

/* ── Configuration ──────────────────────────────────────────────────────── */

typedef struct {
    int   frames;
    int   warmup;
    int   sweep;
    float near_plane;
} ProfCfg;

static void cfg_defaults(ProfCfg* c) {
    c->frames = 40;
    c->warmup = 6;
    c->sweep = 1;
    c->near_plane = 0.08f;
}

static void read_cfg(ProfCfg* c) {
    FILE* f = fopen("ms0:/poi_profile.cfg", "r");
    if (!f) f = fopen("poi_profile.cfg", "r");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        char* hash = strchr(line, '#');
        if (hash) *hash = 0;
        char* eq = strchr(line, '=');
        if (!eq) continue;
        *eq = 0;
        char* key = line;
        char* val = eq + 1;
        while (*key == ' ' || *key == '\t') key++;
        char* ke = key + strlen(key);
        while (ke > key && (ke[-1] == ' ' || ke[-1] == '\t')) *--ke = 0;
        while (*val == ' ' || *val == '\t') val++;
        char* ve = val + strlen(val);
        while (ve > val && (ve[-1] == '\n' || ve[-1] == '\r' || ve[-1] == ' ')) *--ve = 0;

        if (!strcmp(key, "frames")) { c->frames = atoi(val); if (c->frames < 4) c->frames = 4; }
        else if (!strcmp(key, "warmup")) c->warmup = atoi(val);
        else if (!strcmp(key, "sweep")) c->sweep = atoi(val);
        else if (!strcmp(key, "near")) c->near_plane = (float)atof(val);
    }
    fclose(f);
}

/* ── Camera presets (world coordinates of the showcase map) ─────────────── */

typedef struct {
    const char* name;
    float x, y, z, yaw, pitch;
} CamPreset;

static const CamPreset k_cams[] = {
    { "spawn",       0.0f,  1.60f,  4.2f,  0.0f,         0.05f },
    { "arch",        0.0f,  1.60f, -2.0f,  0.0f,         0.0f  },
    { "stairs",     -2.0f,  1.50f,  0.0f, -1.5707963f,   0.0f  },
    { "stairs_low", -1.4f,  0.60f,  0.0f, -1.5707963f,   0.15f },
    { "below_up",    0.0f, -1.20f,  2.0f,  0.0f,         1.0f  },
    { "above_down",  0.0f,  6.00f,  0.0f,  0.0f,        -1.0f  },
    { "balcony",    -4.5f,  3.50f, -4.0f,  0.0f,        -0.2f  },
    { "ramp",        4.5f,  1.00f,  3.0f,  3.1415927f,  -0.1f  },
    { "corner",      5.0f,  1.60f,  5.0f, -2.35f,        0.0f  },
    { "floor_graz",  0.0f,  0.25f,  3.0f,  0.0f,        -0.05f },
    { "sky_up",      0.0f,  1.60f,  0.0f,  0.0f,         1.2f  },
};
#define NUM_CAMS ((int)(sizeof(k_cams) / sizeof(k_cams[0])))

/* ── Synthetic geometry ─────────────────────────────────────────────────── */

static PspVertex s_fill3d[6];
/* The 4096-triangle throughput probe needs ~590 KB. It lives on the heap so it
 * is not part of the module's declared memory (the interactive build links this
 * file but never runs the probes). */
#define TINY_MAX_QUADS 4096
static PspVertex* s_tiny = NULL;
static int s_tiny_capacity = 0;

static void set_color_clear(void) {
    sceGuClearColor(0x382218);
    sceGuClearDepth(65535);
    sceGuClear(GU_COLOR_BUFFER_BIT | GU_DEPTH_BUFFER_BIT);
}

static void fill2d_emit(int count, const float rect[4], int tex_id,
                        int use_depth, int use_blend, PbmMap* map) {
    float u1 = 0.0f, v1 = 0.0f;
    const void* tex = NULL;

    if (tex_id == 2) {
        int w, h;
        tex = psp_small_texture(&w, &h);
        u1 = (float)w; v1 = (float)h;
        sceGuTexMode(GU_PSM_5551, 0, 0, 1);
        sceGuTexImage(0, w, h, w, tex);
    } else if (tex_id == 1 && map && map->header.num_textures > 0) {
        /* the biggest map texture, sampled across the quad */
        int best = 0;
        for (uint32_t i = 1; i < map->header.num_textures; ++i)
            if (map->textures[i].width > map->textures[best].width) best = i;
        PbmTexture* t = &map->textures[best];
        tex = t->pixels;
        u1 = (float)t->width; v1 = (float)t->height;
        sceGuTexMode((t->format == PBM_TEX_FMT_RGBA5551) ? GU_PSM_5551 : GU_PSM_8888,
                     0, 0, t->is_swizzled ? 1 : 0);
        sceGuTexImage(0, t->width, t->height, t->width, t->pixels);
    }

    if (use_depth) {
        sceGuEnable(GU_DEPTH_TEST);
        sceGuDepthFunc(GU_LEQUAL);
        sceGuDepthMask(GU_FALSE);
    } else {
        sceGuDisable(GU_DEPTH_TEST);
    }
    if (use_blend) {
        sceGuEnable(GU_BLEND);
        sceGuBlendFunc(GU_ADD, GU_SRC_ALPHA, GU_ONE_MINUS_SRC_ALPHA, 0, 0);
    } else {
        sceGuDisable(GU_BLEND);
    }
    sceGuDisable(GU_ALPHA_TEST);
    sceGuDisable(GU_CULL_FACE);
    if (tex) sceGuEnable(GU_TEXTURE_2D); else sceGuDisable(GU_TEXTURE_2D);
    sceGuTexWrap(GU_REPEAT, GU_REPEAT);

    for (int i = 0; i < count; ++i) {
        PspVertex* v = (PspVertex*)sceGuGetMemory(2 * sizeof(PspVertex));
        if (!v) return;
        v[0].u = 0; v[0].v = 0; v[0].color = 0xFFFFFFFF;
        v[0].x = rect[0]; v[0].y = rect[1]; v[0].z = 0.0f;
        v[1].u = u1; v[1].v = v1; v[1].color = 0xFFFFFFFF;
        v[1].x = rect[2]; v[1].y = rect[3]; v[1].z = 0.0f;
        sceGuDrawArray(GU_SPRITES,
            GU_TEXTURE_32BITF | GU_COLOR_8888 | GU_VERTEX_32BITF | GU_TRANSFORM_2D,
            2, 0, v);
    }
}

/* A camera-facing world quad on the view axis at z = -2 (identity view).
 * scale 1.0 == exactly the screen rectangle; 16.0 pushes the corners far past
 * the 4096x4096 guardband, forcing the hardware clipper to run. */
#define FILL3D_D 2.0f
#define FILL3D_TANH 0.6371f

static float s_fill3d_built_scale = -1.0f;

/* Geometry is built once and flushed to RAM; only the draw call is timed, so
 * the probe measures submission + GE execution rather than the CPU cost of
 * generating its own vertices. */
static void fill3d_build(float scale) {
    if (s_fill3d_built_scale == scale) return;
    s_fill3d_built_scale = scale;
    float hh = FILL3D_D * FILL3D_TANH;
    float hw = hh * (16.0f / 9.0f);
    float x = hw * scale, y = hh * scale;

    float pos[4][3] = {{-x, -y, -FILL3D_D}, {x, -y, -FILL3D_D},
                       {x, y, -FILL3D_D}, {-x, y, -FILL3D_D}};
    int order[6] = {0, 1, 2, 0, 2, 3};
    for (int i = 0; i < 6; ++i) {
        int k = order[i];
        s_fill3d[i].u = (k == 1 || k == 2) ? 1.0f : 0.0f;
        s_fill3d[i].v = (k == 2 || k == 3) ? 1.0f : 0.0f;
        s_fill3d[i].color = 0xFFFFA040;
        s_fill3d[i].x = pos[k][0];
        s_fill3d[i].y = pos[k][1];
        s_fill3d[i].z = pos[k][2];
    }
    sceKernelDcacheWritebackRange(s_fill3d, sizeof(s_fill3d));
}

static void fill3d_emit(float scale, int textured) {
    fill3d_build(scale);
    if (textured) {
        sceGuEnable(GU_TEXTURE_2D);
        sceGuTexMode(GU_PSM_5551, 0, 0, 1);
        sceGuTexImage(0, 64, 64, 64, psp_small_texture(NULL, NULL));
        sceGuTexWrap(GU_REPEAT, GU_REPEAT);
    } else {
        sceGuDisable(GU_TEXTURE_2D);
    }
    sceGuDisable(GU_CULL_FACE);
    sceGuDisable(GU_ALPHA_TEST);
    sceGuDisable(GU_BLEND);
    sceGuEnable(GU_DEPTH_TEST);
    sceGuDepthFunc(GU_LEQUAL);
    sceGuDepthMask(GU_FALSE);
    sceGuDrawArray(GU_TRIANGLES,
        GU_TEXTURE_32BITF | GU_COLOR_8888 | GU_VERTEX_32BITF | GU_TRANSFORM_3D,
        6, 0, s_fill3d);
}

/* N tiny (4x4 px) quads, as N separate draw calls or one batched call:
 * separates per-draw-call submission cost from raw triangle throughput. */
static int s_tiny_built = -1;

static void tiny_build(int count) {
    if (count > TINY_MAX_QUADS) count = TINY_MAX_QUADS;
    if (!s_tiny) {
        s_tiny = (PspVertex*)memalign(64, (size_t)TINY_MAX_QUADS * 6 * sizeof(PspVertex));
        if (!s_tiny) return;
        s_tiny_capacity = TINY_MAX_QUADS;
    }
    if (s_tiny_built == count) return;
    s_tiny_built = count;
    float hh = FILL3D_D * FILL3D_TANH, hw = hh * (16.0f / 9.0f);
    int n = 0;
    for (int i = 0; i < count; ++i) {
        float fx = -1.0f + 2.0f * (float)(i % 32) / 31.0f;
        float fy = -1.0f + 2.0f * (float)((i / 32) % 32) / 31.0f;
        float cx = fx * hw * 0.95f, cy = fy * hh * 0.95f;
        float s = (hw * 2.0f) * 0.008f;
        float pos[4][3] = {
            {cx - s, cy - s, -FILL3D_D}, {cx + s, cy - s, -FILL3D_D},
            {cx + s, cy + s, -FILL3D_D}, {cx - s, cy + s, -FILL3D_D}
        };
        int order[6] = {0, 1, 2, 0, 2, 3};
        for (int k = 0; k < 6; ++k) {
            s_tiny[n].u = 0;
            s_tiny[n].v = 0;
            s_tiny[n].color = 0xFF40FF40;
            s_tiny[n].x = pos[order[k]][0];
            s_tiny[n].y = pos[order[k]][1];
            s_tiny[n].z = pos[order[k]][2];
            n++;
        }
    }
    sceKernelDcacheWritebackRange(s_tiny, (size_t)n * sizeof(PspVertex));
}

static void tiny_emit(int count, int separate_calls) {
    const int verts_per_quad = 6;
    tiny_build(count);
    if (!s_tiny) return;
    if (count > s_tiny_capacity) count = s_tiny_capacity;
    int total = count * verts_per_quad;

    sceGuDisable(GU_TEXTURE_2D);
    sceGuDisable(GU_CULL_FACE);
    sceGuDisable(GU_ALPHA_TEST);
    sceGuDisable(GU_BLEND);
    sceGuEnable(GU_DEPTH_TEST);
    sceGuDepthFunc(GU_LEQUAL);
    sceGuDepthMask(GU_FALSE);

    if (separate_calls) {
        for (int i = 0; i < count; ++i) {
            sceGuDrawArray(GU_TRIANGLES,
                GU_TEXTURE_32BITF | GU_COLOR_8888 | GU_VERTEX_32BITF | GU_TRANSFORM_3D,
                verts_per_quad, 0, &s_tiny[i * verts_per_quad]);
        }
    } else {
        sceGuDrawArray(GU_TRIANGLES,
            GU_TEXTURE_32BITF | GU_COLOR_8888 | GU_VERTEX_32BITF | GU_TRANSFORM_3D,
            total, 0, s_tiny);
    }
}

/* ── Test execution ─────────────────────────────────────────────────────── */

static void identity_camera(float near_plane) {
    sceGumMatrixMode(GU_PROJECTION);
    sceGumLoadIdentity();
    sceGumPerspective(65.0f, 16.0f / 9.0f, near_plane, 200.0f);
    sceGumMatrixMode(GU_VIEW);
    sceGumLoadIdentity();
    ScePspFVector3 eye = { 0.0f, 0.0f, 0.0f };
    ScePspFVector3 trg = { 0.0f, 0.0f, -1.0f };
    ScePspFVector3 up = { 0.0f, 1.0f, 0.0f };
    sceGumLookAt(&eye, &trg, &up);
    sceGumMatrixMode(GU_MODEL);
    sceGumLoadIdentity();
    sceGumUpdateMatrix();
}

static void test_emit(PbmMap* map, const ProfTest* t, RenderStats* stats, float fps) {
    /* Every probe pays the same clear as a real frame so that subtracting the
     * clear_only row yields the probe's own cost. */
    if (t->kind != TK_SCENE) set_color_clear();

    switch (t->kind) {
        case TK_CLEAR:
            break;

        case TK_SCENE:
            psp_render_scene(map, &t->cfg, t->cam[0], t->cam[1], t->cam[2],
                             t->yaw, t->pitch, 1.0f, stats);
            if (t->hud) psp_draw_hud(map, stats, fps, t->cfg.display_mode, NULL, NULL, NULL, 0);
            break;

        case TK_FILL2D:
            fill2d_emit(t->count, t->rect, t->tex, t->depth, t->blend, map);
            if (stats) { stats->draw_calls = t->count; stats->vertices = t->count * 2; }
            break;

        case TK_FILL3D_FIT:
            identity_camera(t->cfg.near_plane);
            fill3d_emit(1.0f, t->tex != 0);
            if (stats) { stats->draw_calls = 1; stats->vertices = 6; }
            break;

        case TK_FILL3D_BIG:
            identity_camera(t->cfg.near_plane);
            fill3d_emit(16.0f, t->tex != 0);
            if (stats) { stats->draw_calls = 1; stats->vertices = 6; }
            break;

        case TK_DRAWCALLS:
            identity_camera(t->cfg.near_plane);
            tiny_emit(t->count, 1);
            if (stats) { stats->draw_calls = t->count; stats->vertices = t->count * 6; }
            break;

        case TK_TRIS:
            identity_camera(t->cfg.near_plane);
            tiny_emit(t->count, 0);
            if (stats) { stats->draw_calls = 1; stats->vertices = t->count * 6; }
            break;
    }
}

static void run_test(PbmMap* map, ProfTest* t, ProfCfg* pc, ProfResult* out) {
    const int frames = t->frames > 0 ? t->frames : pc->frames;
    RenderStats stats = { 0, 0, 0 };
    stats.draw_calls = 0;

    for (int i = 0; i < pc->warmup; ++i) {
        sceGuStart(GU_DIRECT, psp_dlist());
        test_emit(map, t, &stats, 60.0f);
        sceGuFinish();
        sceGuSync(0, 0);
        sceGuSwapBuffers();
    }
    sceGuSync(0, 0);

    uint64_t cpu = 0, gpu = 0;
    uint64_t wall0 = psp_now_us();
    for (int i = 0; i < frames; ++i) {
        uint64_t a = psp_now_us();
        sceGuStart(GU_DIRECT, psp_dlist());
        test_emit(map, t, &stats, 60.0f);
        sceGuFinish();
        uint64_t b = psp_now_us();
        sceGuSync(0, 0);
        uint64_t c = psp_now_us();
        sceGuSwapBuffers();
        cpu += b - a;
        gpu += c - b;
    }
    uint64_t wall1 = psp_now_us();
    sceGuSync(0, 0);

    out->name = t->name;
    out->cpu_ms = (float)cpu / frames / 1000.0f;
    out->gpu_ms = (float)gpu / frames / 1000.0f;
    out->wall_ms = (float)(wall1 - wall0) / frames / 1000.0f;
    out->maxfps = (out->cpu_ms + out->gpu_ms) > 0.001f ? 1000.0f / (out->cpu_ms + out->gpu_ms) : 0.0f;
    out->draws = stats.draw_calls;
    out->verts = stats.vertices;
}

/* ── Test table ─────────────────────────────────────────────────────────── */

static ProfTest* new_test(ProfTest* t, int* n, const char* name, int kind,
                          const ProfCfg* pc, const RenderCfg* base) {
    ProfTest* x = &t[(*n)++];
    memset(x, 0, sizeof(*x));
    x->name = name;
    x->kind = kind;
    x->cfg = *base;
    x->cfg.near_plane = pc->near_plane;
    return x;
}

static void add_scene_test(ProfTest* t, int* n, const char* name, const char* cam,
                           const ProfCfg* pc, const RenderCfg* base) {
    ProfTest* x = new_test(t, n, name, TK_SCENE, pc, base);
    for (int i = 0; i < NUM_CAMS; ++i) {
        if (!strcmp(k_cams[i].name, cam)) {
            x->cam[0] = k_cams[i].x; x->cam[1] = k_cams[i].y; x->cam[2] = k_cams[i].z;
            x->yaw = k_cams[i].yaw; x->pitch = k_cams[i].pitch;
            break;
        }
    }
    x->hud = 1;
}

static int build_tests(PbmMap* map, ProfTest* t, ProfCfg* pc) {
    (void)map;
    int n = 0;
    RenderCfg base;
    render_cfg_default(&base);
    base.near_plane = pc->near_plane;

    /* --- the reported views, plus the rest of the map ---------------- */
    add_scene_test(t, &n, "scene_spawn", "spawn", pc, &base);
    add_scene_test(t, &n, "scene_arch", "arch", pc, &base);
    add_scene_test(t, &n, "scene_stairs", "stairs", pc, &base);
    add_scene_test(t, &n, "scene_stairs_low", "stairs_low", pc, &base);
    add_scene_test(t, &n, "scene_below_up", "below_up", pc, &base);
    add_scene_test(t, &n, "scene_above_down", "above_down", pc, &base);
    add_scene_test(t, &n, "scene_corner", "corner", pc, &base);
    add_scene_test(t, &n, "scene_balcony", "balcony", pc, &base);
    add_scene_test(t, &n, "scene_floor_graz", "floor_graz", pc, &base);

    /* --- ablations at the reported worst view (next to the stairs) --- */
    add_scene_test(t, &n, "abi_notex", "stairs", pc, &base);
    t[n - 1].cfg.use_textures = 0;
    add_scene_test(t, &n, "abi_tex64", "stairs", pc, &base);
    t[n - 1].cfg.force_small_tex = 1;
    /* the candidate fix: load-time mip chain + mipmap minification filter */
    add_scene_test(t, &n, "abi_nomip", "stairs", pc, &base);
    t[n - 1].cfg.use_mips = 0;
    add_scene_test(t, &n, "abi_mipmap_nearest", "stairs", pc, &base);
    t[n - 1].cfg.tex_filter = PBFILT_NEAREST;
    add_scene_test(t, &n, "abi_mag_nearest", "stairs", pc, &base);
    t[n - 1].cfg.tex_filter = PBFILT_ASYM;
    add_scene_test(t, &n, "abi_trilinear", "stairs", pc, &base);
    t[n - 1].cfg.tex_filter = PBFILT_LINEAR;
    add_scene_test(t, &n, "abi_bias_m1", "stairs", pc, &base);
    t[n - 1].cfg.tex_lod_bias = -1.0f;
    add_scene_test(t, &n, "abi_bias_p1", "stairs", pc, &base);
    t[n - 1].cfg.tex_lod_bias = 1.0f;
    add_scene_test(t, &n, "abi_filt_nearest", "stairs", pc, &base);
    t[n - 1].cfg.tex_filter = PBFILT_NEAREST;
    t[n - 1].cfg.tex_lod_bias = 0.0f;
    add_scene_test(t, &n, "abi_filt_linear", "stairs", pc, &base);
    t[n - 1].cfg.tex_filter = PBFILT_LINEAR;
    add_scene_test(t, &n, "abi_nodepth", "stairs", pc, &base);
    t[n - 1].cfg.depth_test = 0;
    add_scene_test(t, &n, "abi_nocull", "stairs", pc, &base);
    t[n - 1].cfg.cull = 0;
    add_scene_test(t, &n, "abi_noclip", "stairs", pc, &base);
    t[n - 1].cfg.clip_planes = 0;
    add_scene_test(t, &n, "abi_near050", "stairs", pc, &base);
    t[n - 1].cfg.near_plane = 0.5f;
    add_scene_test(t, &n, "abi_noalpha", "stairs", pc, &base);
    t[n - 1].cfg.alpha_pass = 0;
    add_scene_test(t, &n, "abi_noentity", "stairs", pc, &base);
    t[n - 1].cfg.entity = 0;
    add_scene_test(t, &n, "abi_nohud", "stairs", pc, &base);
    t[n - 1].hud = 0;
    add_scene_test(t, &n, "abi_vertcol", "stairs", pc, &base);
    t[n - 1].cfg.display_mode = 1;
    add_scene_test(t, &n, "abi_wire", "stairs", pc, &base);
    t[n - 1].cfg.display_mode = 2;

    /* --- the same ablations at the below-floor view ----------------- */
    add_scene_test(t, &n, "abi2_notex", "below_up", pc, &base);
    t[n - 1].cfg.use_textures = 0;
    add_scene_test(t, &n, "abi2_tex64", "below_up", pc, &base);
    t[n - 1].cfg.force_small_tex = 1;
    add_scene_test(t, &n, "abi2_nomip", "below_up", pc, &base);
    t[n - 1].cfg.use_mips = 0;
    add_scene_test(t, &n, "abi2_filt_nearest", "below_up", pc, &base);
    t[n - 1].cfg.tex_filter = PBFILT_NEAREST;
    add_scene_test(t, &n, "abi2_noclip", "below_up", pc, &base);
    t[n - 1].cfg.clip_planes = 0;
    add_scene_test(t, &n, "abi2_alpha_off", "below_up", pc, &base);
    t[n - 1].cfg.alpha_pass = 0;

    /* --- synthetic probes ------------------------------------------- */
    ProfTest* x;
    x = new_test(t, &n, "clear_only", TK_CLEAR, pc, &base);

    x = new_test(t, &n, "fill2d_1x_plain", TK_FILL2D, pc, &base);
    x->count = 1; x->rect[2] = 480; x->rect[3] = 272;
    x = new_test(t, &n, "fill2d_4x_plain", TK_FILL2D, pc, &base);
    x->count = 4; x->rect[2] = 480; x->rect[3] = 272;
    x = new_test(t, &n, "fill2d_1x_tex512", TK_FILL2D, pc, &base);
    x->count = 1; x->tex = 1; x->rect[2] = 480; x->rect[3] = 272;
    x = new_test(t, &n, "fill2d_4x_tex512_d", TK_FILL2D, pc, &base);
    x->count = 4; x->tex = 1; x->depth = 1; x->rect[2] = 480; x->rect[3] = 272;
    x = new_test(t, &n, "fill2d_4x_tex64_d", TK_FILL2D, pc, &base);
    x->count = 4; x->tex = 2; x->depth = 1; x->rect[2] = 480; x->rect[3] = 272;
    x = new_test(t, &n, "fill2d_4x_blend512", TK_FILL2D, pc, &base);
    x->count = 4; x->tex = 1; x->depth = 1; x->blend = 1; x->rect[2] = 480; x->rect[3] = 272;
    /* minification probe: all 512x512 texels squeezed into 32x32 px */
    x = new_test(t, &n, "min512_32px", TK_FILL2D, pc, &base);
    x->count = 1; x->tex = 1; x->rect[0] = 8; x->rect[1] = 8; x->rect[2] = 40; x->rect[3] = 40;
    x = new_test(t, &n, "min512_32px_x16", TK_FILL2D, pc, &base);
    x->count = 16; x->tex = 1; x->rect[0] = 8; x->rect[1] = 8; x->rect[2] = 40; x->rect[3] = 40;

    x = new_test(t, &n, "fill3d_fit", TK_FILL3D_FIT, pc, &base);
    (void)x;
    x = new_test(t, &n, "fill3d_big_noclip", TK_FILL3D_BIG, pc, &base);
    x->cfg.clip_planes = 0;
    x = new_test(t, &n, "fill3d_big_clip", TK_FILL3D_BIG, pc, &base);
    x->cfg.clip_planes = 1;

    x = new_test(t, &n, "drawcalls_256", TK_DRAWCALLS, pc, &base);
    x->count = 256;
    x = new_test(t, &n, "tris_4096", TK_TRIS, pc, &base);
    x->count = 4096;

    return n;
}

/* ── Reporting ──────────────────────────────────────────────────────────── */

static void report_row(FILE* f, const ProfResult* r) {
    if (!f) return;
    fprintf(f, "%-20s cpu=%6.3f gpu=%6.3f frame=%6.3f maxfps=%5.1f draws=%3u verts=%5u\n",
            r->name, r->cpu_ms, r->gpu_ms, r->cpu_ms + r->gpu_ms, r->maxfps,
            (unsigned)r->draws, (unsigned)r->verts);
}

void psp_prof_suite(PbmMap* map) {
    static ProfTest tests[MAX_TESTS];
    ProfCfg pc;
    cfg_defaults(&pc);
    read_cfg(&pc);

    int n = build_tests(map, tests, &pc);
    if (n > MAX_TESTS) n = MAX_TESTS;

    /* host0:/ is the PSPLink USB host filesystem: when the profiler runs over
     * USB the log lands directly on the development machine, with no memory
     * stick, no mounting and no file copying. */
    FILE* f = fopen("host0:/poi_profile.txt", "w");
    const char* log_path = "host0:/poi_profile.txt";
    if (!f) { f = fopen("ms0:/poi_profile.txt", "w"); log_path = "ms0:/poi_profile.txt"; }
    if (!f) { f = fopen("poi_profile.txt", "w"); log_path = "poi_profile.txt"; }

    printf("[PROF] %d tests x %d frames (log: %s)\n", n, pc.frames, log_path);

    if (f) {
        fprintf(f, "PoiRetro PSP profile\n");
        fprintf(f, "map=%s meshes=%u textures=%u verts=%u tris=%u\n",
                map->map_name, (unsigned)map->header.num_meshes,
                (unsigned)map->header.num_textures, (unsigned)map->total_vertices,
                (unsigned)map->total_vertices / 3);
        fprintf(f, "frames=%d warmup=%d near=%.3f\n", pc.frames, pc.warmup, pc.near_plane);
        fprintf(f, "textures (WxH/levels): ");
        for (uint32_t i = 0; i < map->header.num_textures && i < 16; ++i)
            fprintf(f, "%ux%u/%u ", map->textures[i].width, map->textures[i].height,
                    (unsigned)map->textures[i].num_levels);
        fprintf(f, "\n\n");
    }

    s_result_count = 0;
    for (int i = 0; i < n; ++i) {
        run_test(map, &tests[i], &pc, &s_results[s_result_count]);
        report_row(f, &s_results[s_result_count]);
        if (f) fflush(f);
        s_result_count++;
    }

    if (pc.sweep) {
        if (f) fprintf(f, "\n--- camera sweep (baseline cfg) ---\n");
        ProfTest sw;
        for (int i = 0; i < NUM_CAMS; ++i) {
            memset(&sw, 0, sizeof(sw));
            sw.kind = TK_SCENE;
            sw.cfg = tests[0].cfg;
            sw.hud = 1;
            sw.frames = (pc.frames > 24) ? 24 : pc.frames;
            sw.name = k_cams[i].name;
            sw.cam[0] = k_cams[i].x; sw.cam[1] = k_cams[i].y; sw.cam[2] = k_cams[i].z;
            sw.yaw = k_cams[i].yaw; sw.pitch = k_cams[i].pitch;
            ProfResult r;
            run_test(map, &sw, &pc, &r);
            if (f)
                fprintf(f, "sweep:%-14s cpu=%6.3f gpu=%6.3f frame=%6.3f maxfps=%5.1f\n",
                        r.name, r.cpu_ms, r.gpu_ms, r.cpu_ms + r.gpu_ms, r.maxfps);
        }
    }

    if (f) {
        fprintf(f, "\n--- ranked by gpu ms ---\n");
        for (int i = 0; i < s_result_count; ++i)
            for (int j = i + 1; j < s_result_count; ++j)
                if (s_results[j].gpu_ms > s_results[i].gpu_ms) {
                    ProfResult tmp = s_results[i];
                    s_results[i] = s_results[j];
                    s_results[j] = tmp;
                }
        for (int i = 0; i < s_result_count; ++i) report_row(f, &s_results[i]);
        fclose(f);
    }

    /* On-screen copy: if the memory-stick write failed, a photo still works. */
    sceGuStart(GU_DIRECT, psp_dlist());
    set_color_clear();
    char line[96];
    psp_draw_text(4.0f, 4.0f, 0xFF00FF55, "PoiRetro profile - ranked by GPU ms");
    int shown = s_result_count < 22 ? s_result_count : 22;
    for (int i = 0; i < shown; ++i) {
        snprintf(line, sizeof(line), "%-20s cpu %5.2f gpu %5.2f",
                 s_results[i].name, s_results[i].cpu_ms, s_results[i].gpu_ms);
        psp_draw_text(4.0f, 16.0f + 11.0f * i, 0xFFDDDDDD, line);
    }
    sceGuFinish();
    sceGuSync(0, 0);
    sceGuSwapBuffers();
}
