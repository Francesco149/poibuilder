/* PoiRetro PSP — scene renderer.
 *
 * Everything here used to live inline in main.c's frame loop. It was split out
 * so the profiler (psp_prof.c) can drive the exact shipping render path with
 * one GPU state changed at a time — the only way to attribute a frame-time
 * regression on real hardware to a specific stage of the pipeline.
 *
 * The default RenderCfg reproduces the shipping renderer bit for bit. */
#include <pspkernel.h>
#include <pspdisplay.h>
#include <pspgu.h>
#include <pspgum.h>
#include <psprtc.h>
#include <psputils.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "psp_render.h"
#include "font8x8.h"

#define BUF_WIDTH (512)
#define SCR_WIDTH (480)
#define SCR_HEIGHT (272)

/* Display list. GU_DIRECT: the GE DMAs this list, so every byte written here is
 * bus traffic the GE also has to read back. A frame emits a few KB of commands
 * (19 draw calls and a handful of state changes, plus the HUD's vertices), so
 * 128 KB is ~40x headroom — and unlike the 1 MB this used to be, it leaves the
 * module small enough for PSPLink to load into the PSP's kernel partition. */
#define PSP_DLIST_WORDS (32768)
static unsigned int __attribute__((aligned(16))) s_dlist[PSP_DLIST_WORDS];

void* psp_dlist(void) { return s_dlist; }

uint64_t psp_now_us(void) {
    /* sceKernelGetSystemTimeWide is the kernel's microsecond counter: cheaper
     * than the RTC path and with a guaranteed 1 us resolution, which is what a
     * per-frame cpu/gpu split needs. */
    return (uint64_t)sceKernelGetSystemTimeWide();
}

static const PbEnvDef s_env_defs[] = {
    { "day",   0x382218, 1, 22.0f, 65.0f, 0x382218 },
    { "dawn",  0x262028, 1, 16.0f, 52.0f, 0x262028 },
    { "dusk",  0x1C1824, 1, 14.0f, 48.0f, 0x1C1824 },
    { "night", 0x100A08, 1, 10.0f, 40.0f, 0x100A08 },
};

const PbEnvDef* pb_env_get(int preset_id) {
    if (preset_id >= 0 && preset_id < 4) return &s_env_defs[preset_id];
    return &s_env_defs[0];
}

const PbEnvDef* pb_env_find(const char* name) {
    if (!name || !name[0]) return &s_env_defs[0];
    for (int i = 0; i < 4; ++i) {
        if (!strcasecmp(name, s_env_defs[i].name)) return &s_env_defs[i];
    }
    return &s_env_defs[0];
}

void render_cfg_set_env(RenderCfg* cfg, const char* name) {
    const PbEnvDef* env = pb_env_find(name);
    for (int i = 0; i < 4; ++i) {
        if (&s_env_defs[i] == env) { cfg->env_preset = i; break; }
    }
    cfg->clear_color = env->clear_color;
    cfg->fog_enabled = env->fog_enabled;
    cfg->fog_near = env->fog_near;
    cfg->fog_far = env->fog_far;
    cfg->fog_color = env->fog_color;
}
void render_cfg_default(RenderCfg* c) {
    c->display_mode = 0;
    c->use_textures = 1;
    c->depth_test = 1;
    c->depth_write = 0;   /* depth-tested, not depth-written: see psp_render.h */
    c->cull = 1;
    c->clip_planes = 1;
    c->alpha_pass = 1;
    c->entity = 1;
    c->uv_scroll = 1;
    c->particles = 3;

    /* Filtering and LOD policy: MEASURED on the device, not tuned by taste.
     *
     * The GE's texture cache is ~8 KB. A fragment whose sampled mip level does
     * not fit it costs a main-memory fetch (~37 ns at 27 Mfrag/s, measured)
     * against ~2 ns when the footprint fits (480 Mfrag/s) — the same 19x the
     * no-mip case pays — and the cliff between the two is sharp. The level the
     * hardware picks from the UV derivatives is the sharpest that still
     * averages ~1 texel per pixel, so at that level the sampled footprint IS
     * the surface's on-screen area: 75 000 pixels of wall means ~75 000 texels
     * of the chosen level, ~150 KB for a 16-bit texture. Only close,
     * screen-filling surfaces reach that, and they reach it hard.
     *
     * A NEGATIVE bias samples past that cliff. Measured at the foot of the
     * showcase waterfall — the app's worst view, where the scene is the same
     * 1526 triangles and 27 draw calls as the spawn view (battery rows wf_*):
     *
     *     bias -1.0 + trilinear   25.21 ms   <- was the default: 36 fps
     *     bias -1.0 + mip_lin     14.61
     *     bias  0.0 + mip_lin     11.20
     *     bias +0.5 + mip_lin      4.32
     *     bias +1.0 + mip_lin      2.79      (~0.8 ms of that is the frame floor)
     *     bias +2.0 + mip_lin      1.02
     * and at the two views the map is judged on: spawn 8.76 -> 0.43 ms,
     * stairs 11.12 -> 0.11 ms. The old -1.0 was picked when the scene was
     * cheaper and "quality was affordable"; it is not affordable any more,
     * because it is the difference between the cache holding the footprint
     * and missing on every fragment.
     *
     * So: sample ONE mip level (a mipmap-nearest filter — trilinear doubles the
     * fetch set for a level-crossing smoothness that per-primitive LOD already
     * steps anyway) and bias it one level coarse. `poi_render.txt` overrides
     * both without a rebuild: bias=0 is visibly sharper and still fits (11 ms
     * at the worst view), bias=2 is what a weaker machine would want. */
    c->tex_filter = PBFILT_MIP_LIN;
    c->tex_lod_bias = 1.0f;
    /* Painted detail (the baked splat/stamp tiles) is pinned to ONE mip level
     * rather than left to the per-primitive LOD. The GE derives a level per
     * triangle from that triangle's own UV derivatives, so a floor crossing
     * several levels in a few metres steps in sharpness at every tile boundary
     * — and, worse, the automatic level for a tile a couple of metres away
     * lands several steps coarser than the texture's real detail, which reads
     * as a blurred, seamed floor. One constant level keeps it crisp; measured
     * at the grazing floor view: 0.50 vs 0.12 ms gpu (3.15 vs 2.49 ms frame),
     * i.e. ~0.4 ms for the whole painted floor. `detail_const = -1` restores the
     * per-primitive behaviour, and `detail_bias` applies in that case only. */
    c->detail_const = 1;
    c->detail_bias = -1.0f;   /* used only when detail_const < 0 (per-primitive mode) */
    c->tex_level_mode = PBLEVEL_AUTO;
    c->force_small_tex = 0;
    c->use_mips = 1;   /* load-time mip chain: the default since it fixes the minified-fetch cost */
    c->cutout_mips = 1; /* cutouts carry an alpha-preserving chain (max-alpha combine) */
    c->near_plane = 0.08f;
    render_cfg_set_env(c, "day");
}

/* ── Font + 2D text ─────────────────────────────────────────────────────── */

#define FONT_TEX_W 128
#define FONT_TEX_H 64
static uint16_t __attribute__((aligned(16))) s_font_tex[FONT_TEX_W * FONT_TEX_H];

/* 64x64 swizzled RGBA5551 test texture: magenta/green checker so it is
 * unmistakable on screen. Fits entirely in the GE texture cache. */
#define SMALL_TEX_W 64
#define SMALL_TEX_H 64
static uint16_t __attribute__((aligned(64))) s_small_tex[SMALL_TEX_W * SMALL_TEX_H];
static int s_small_tex_ready = 0;

static void swizzle16(uint8_t* out, const uint8_t* in, unsigned int width, unsigned int height) {
    unsigned int width_bytes = width * 2;
    unsigned int width_blocks = width_bytes / 16;
    unsigned int height_blocks = height / 8;
    unsigned int src_pitch = (width_bytes - 16) / 4;
    unsigned int src_row = width_bytes * 8;
    const uint8_t* ysrc = in;
    uint32_t* dst = (uint32_t*)out;
    for (unsigned int by = 0; by < height_blocks; ++by) {
        const uint32_t* xsrc = (const uint32_t*)ysrc;
        for (unsigned int bx = 0; bx < width_blocks; ++bx) {
            for (int yp = 0; yp < 8; ++yp) {
                for (int xp = 0; xp < 4; ++xp) *dst++ = *xsrc++;
                xsrc += src_pitch;
            }
            ysrc += 16;
        }
        ysrc += src_row - width_bytes;
    }
}

const void* psp_small_texture(int* width, int* height) {
    if (!s_small_tex_ready) {
        uint16_t linear[SMALL_TEX_W * SMALL_TEX_H];
        for (int y = 0; y < SMALL_TEX_H; ++y) {
            for (int x = 0; x < SMALL_TEX_W; ++x) {
                int chk = ((x >> 3) ^ (y >> 3)) & 1;
                linear[y * SMALL_TEX_W + x] = chk ? 0xF81F /* magenta */ : 0x07E0 /* green */;
            }
        }
        swizzle16((uint8_t*)s_small_tex, (const uint8_t*)linear, SMALL_TEX_W, SMALL_TEX_H);
        sceKernelDcacheWritebackRange(s_small_tex, sizeof(s_small_tex));
        s_small_tex_ready = 1;
    }
    if (width) *width = SMALL_TEX_W;
    if (height) *height = SMALL_TEX_H;
    return s_small_tex;
}

void psp_font_init(void) {
    memset(s_font_tex, 0, sizeof(s_font_tex));
    for (int c = 32; c < 127; ++c) {
        int idx = c - 32;
        int base_col = (idx % 16) * 8;
        int base_row = (idx / 16) * 8;
        for (int y = 0; y < 8; ++y) {
            uint8_t row_bits = (uint8_t)font8x8_basic[c][y];
            for (int x = 0; x < 8; ++x) {
                s_font_tex[(base_row + y) * FONT_TEX_W + (base_col + x)] =
                    (row_bits & (1 << x)) ? 0xFFFF : 0x0000;
            }
        }
    }
    sceKernelDcacheWritebackRange(s_font_tex, sizeof(s_font_tex));
}

static void draw_text_raw(float start_x, float start_y, uint32_t color, const char* str) {
    if (!str || !*str) return;
    int len = (int)strlen(str);
    if (len > 250) len = 250;

    PspVertex* v = (PspVertex*)sceGuGetMemory(len * 2 * sizeof(PspVertex));
    if (!v) return;

    sceGuEnable(GU_TEXTURE_2D);
    sceGuTexMode(GU_PSM_5551, 0, 0, 0);
    sceGuTexImage(0, FONT_TEX_W, FONT_TEX_H, FONT_TEX_W, s_font_tex);
    sceGuTexFunc(GU_TFX_MODULATE, GU_TCC_RGBA);
    sceGuTexFilter(GU_NEAREST, GU_NEAREST);
    sceGuDisable(GU_DEPTH_TEST);
    sceGuDisable(GU_CULL_FACE);
    sceGuEnable(GU_BLEND);
    sceGuBlendFunc(GU_ADD, GU_SRC_ALPHA, GU_ONE_MINUS_SRC_ALPHA, 0, 0);

    float cur_x = start_x;
    int n = 0;
    for (int i = 0; i < len; ++i) {
        unsigned char c = (unsigned char)str[i];
        if (c < 32 || c > 126) c = ' ';
        int idx = c - 32;
        float u1 = (float)((idx % 16) * 8);
        float v1 = (float)((idx / 16) * 8);
        v[n].u = u1; v[n].v = v1; v[n].color = color;
        v[n].x = cur_x; v[n].y = start_y; v[n].z = 0.0f; n++;
        v[n].u = u1 + 8.0f; v[n].v = v1 + 8.0f; v[n].color = color;
        v[n].x = cur_x + 8.0f; v[n].y = start_y + 8.0f; v[n].z = 0.0f; n++;
        cur_x += 8.0f;
    }
    sceGuDrawArray(GU_SPRITES,
        GU_TEXTURE_32BITF | GU_COLOR_8888 | GU_VERTEX_32BITF | GU_TRANSFORM_2D,
        n, 0, v);
}

void psp_draw_text(float x, float y, uint32_t color, const char* str) {
    draw_text_raw(x + 1.0f, y + 1.0f, 0xFF000000, str);
    draw_text_raw(x, y, color, str);
}

void psp_draw_hud(PbmMap* map, const RenderStats* stats, float fps,
                  int display_mode, const char* extra, const char* extra2,
                  const char* input, int hold_on, int compact) {
    char buf[128];
    uint32_t verts = stats ? stats->vertices : 0;
    uint32_t draws = stats ? stats->draw_calls : 0;

    /* One line, and it has to FIT: 480 px / 8 px per glyph = 60 characters, and
     * a line that runs past the edge silently loses its last digits (a full
     * particle count read as "Parts: 4" that way). The vertex total is a
     * per-mesh property that the profiler reports; the per-frame numbers are
     * what belongs on the HUD. */
    snprintf(buf, sizeof(buf), "FPS: %4.1f | Tris: %u | Draws: %u | Parts: %u",
             fps, (unsigned)(verts / 3), (unsigned)draws,
             (unsigned)(stats ? stats->particles : 0));
    psp_draw_text(8.0f, 8.0f, 0xFF00FF55, buf);

    /* COMPACT: everything except the frame-rate line and the profiler readout
     * is hidden, so a capture shows the scene rather than the documentation.
     * Select toggles it (see main.c). */
    if (compact) {
        if (extra && *extra) psp_draw_text(8.0f, 18.0f, 0xFF66E0FF, extra);
        if (extra2 && *extra2) psp_draw_text(8.0f, 28.0f, 0xFF8888FF, extra2);
        return;
    }

    snprintf(buf, sizeof(buf), "Map: %s | %s | Env: %s", map->map_name,
             display_mode == 0 ? "Textured" : (display_mode == 1 ? "Lighting" : "Wireframe"),
             map->env_preset[0] ? map->env_preset : "day");
    psp_draw_text(8.0f, 18.0f, 0xFFFFFF00, buf);

    /* The Hold switch suppresses every button while leaving the analog stick
     * readable, so an app with Hold on looks like "the stick works but no key
     * does". Say so on screen rather than leaving it to be guessed at. */
    if (hold_on) {
        /* 480px / 8px per glyph = 60 characters; keep it inside that. */
        snprintf(buf, sizeof(buf), "!! HOLD ON - buttons disabled (%s)", input ? input : "");
        psp_draw_text(8.0f, 28.0f, 0xFF3F3FFF, buf);
    } else if (map->has_patrol_sphere) {
        snprintf(buf, sizeof(buf), "Entity: %-14s | %s",
                 map->patrol_sphere.name, input ? input : "");
        psp_draw_text(8.0f, 28.0f, 0xFF00C8FF, buf);
    } else if (input) {
        psp_draw_text(8.0f, 28.0f, 0xFF00C8FF, input);
    }

    /* The control hints used to be shown only when the map had no entity, so
     * on any map with one they were invisible and the controls looked missing.
     * Every line stays inside 60 glyphs (480 px / 8 px): a line that runs past
     * the edge silently loses its tail. */
    psp_draw_text(8.0f, 38.0f, 0xFFDDDDDD,
                  "Stick: Fly/Strafe | Hold Tri+Stick: Look | Square: Boost");
    psp_draw_text(8.0f, 48.0f, 0xFFDDDDDD,
                  "X/O: Up/Down | L/R: Turn | Start: Reset");
    psp_draw_text(8.0f, 58.0f, 0xFFDDDDDD,
                  "Select: HUD | L+Select: Mode | Tri+L/R: Env");

    if (extra && *extra) psp_draw_text(8.0f, 68.0f, 0xFF66E0FF, extra);
    if (extra2 && *extra2) psp_draw_text(8.0f, 78.0f, 0xFF8888FF, extra2);
}

/* Runtime render overrides, read once at startup from a file on the host.
 *
 * Tuning mip/filter settings otherwise costs a rebuild and a USB round trip per
 * data point, which is far too slow to iterate on a visual problem. Writing
 *   host0:/poi_render.txt  with e.g.
 *       filter=linear      (linear | mip_lin | nearest | asym)
 *       bias=-2            (negative = sharper)
 *       mips=0
 * lets the same binary be re-run with different settings and screenshotted.
 * Absent file: the compiled defaults apply. */
/* Meshes whose name contains this substring are skipped. Coplanar surfaces are
 * the reason: the exporter emits a base-material quad across the whole floor
 * AND baked tile quads on top of it, both at y=0, and two coplanar surfaces
 * fight in the depth buffer along their triangle edges -- which shows up as
 * thin lines that flicker as the camera moves. Being able to drop one layer at
 * runtime is what identifies it. */
static char s_skip_mesh[64] = "";

void psp_render_skip_mesh(const char* needle) {
    snprintf(s_skip_mesh, sizeof(s_skip_mesh), "%s", needle ? needle : "");
}

/* Which meshes the per-mesh LOD policy applies to. The baked splat/stamp tiles
 * are the surfaces where a mip-level step between neighbouring primitives reads
 * as a seam (a floor at a grazing angle crosses several levels across a few
 * metres), so they default to "keep me sharp". Matched against the mesh name
 * and its texture's name, both of which the exporter controls. */
static char s_detail_match[64] = "TileAtlas";

void psp_render_detail_match(const char* needle) {
    snprintf(s_detail_match, sizeof(s_detail_match), "%s", needle ? needle : "");
}

void psp_render_overrides(RenderCfg* cfg) {
    FILE* f = fopen("host0:/poi_render.txt", "r");
    if (!f) f = fopen("ms0:/poi_render.txt", "r");
    if (!f) f = fopen("poi_render.txt", "r");
    if (!f) return;
    char line[128];
    while (fgets(line, sizeof(line), f)) {
        char* hash = strchr(line, '#');
        if (hash) *hash = 0;
        char* eq = strchr(line, '=');
        if (!eq) continue;
        *eq = 0;
        char* k = line;
        char* v = eq + 1;
        while (*k == ' ' || *k == '\t') k++;
        char* ke = k + strlen(k);
        while (ke > k && (ke[-1] == ' ' || ke[-1] == '\t')) *--ke = 0;
        while (*v == ' ' || *v == '\t') v++;
        char* ve = v + strlen(v);
        while (ve > v && (ve[-1] == '\n' || ve[-1] == '\r' || ve[-1] == ' ')) *--ve = 0;

        if (!strcmp(k, "filter")) {
            if (!strcmp(v, "linear"))       cfg->tex_filter = PBFILT_LINEAR;
            else if (!strcmp(v, "nearest")) cfg->tex_filter = PBFILT_NEAREST;
            else if (!strcmp(v, "asym"))    cfg->tex_filter = PBFILT_ASYM;
            else                            cfg->tex_filter = PBFILT_MIP_LIN;
        } else if (!strcmp(k, "uv_scroll")) cfg->uv_scroll = atoi(v);
        else if (!strcmp(k, "particles")) cfg->particles = atoi(v);
        else if (!strcmp(k, "preset")) render_cfg_set_env(cfg, v);
        else if (!strcmp(k, "bias")) cfg->tex_lod_bias = (float)atof(v);
        else if (!strcmp(k, "mips"))   cfg->use_mips = atoi(v);
        else if (!strcmp(k, "cutout_mips")) cfg->cutout_mips = atoi(v);
        else if (!strcmp(k, "depth_write")) cfg->depth_write = atoi(v);
        else if (!strcmp(k, "skip_mesh")) psp_render_skip_mesh(v);
        else if (!strcmp(k, "detail_mesh")) psp_render_detail_match(v);
        else if (!strcmp(k, "detail_bias")) cfg->detail_bias = (float)atof(v);
        else if (!strcmp(k, "detail_const")) cfg->detail_const = atoi(v);
        else if (!strcmp(k, "level_mode"))
            cfg->tex_level_mode = strcmp(v, "const") ? PBLEVEL_AUTO : PBLEVEL_CONST;
    }
    fclose(f);
}

/* ── Scene ──────────────────────────────────────────────────────────────── */

static inline int is_billboard_mesh(const char* name) {
    if (!name) return 0;
    return strstr(name, "billboard") || strstr(name, "Billboard") ||
           strstr(name, "sprite") || strstr(name, "Sprite") ||
           strstr(name, "tree") || strstr(name, "Tree") ||
           strstr(name, "bush") || strstr(name, "Bush") ||
           strstr(name, "flower") || strstr(name, "Flower") ||
           strstr(name, "wildflower") || strstr(name, "Wildflower");
}

/* The alpha handling a mesh needs: PBM_ALPHA_CUTOUT for hard-edged sprites,
 * PBM_ALPHA_BLEND for soft alpha, PBM_ALPHA_NONE for opaque. A mesh whose
 * NAME says billboard is a cutout regardless of what its texture claims —
 * foliage art is frequently saved fully opaque with a hard alpha edge. */
static inline int mesh_alpha_mode(PbmMap* map, PbmMesh* mesh) {
    if (!mesh) return PBM_ALPHA_NONE;
    if (mesh->texture_id >= 0 && mesh->texture_id < (int)map->header.num_textures) {
        int mode = map->textures[mesh->texture_id].alpha_mode;
        if (mode != PBM_ALPHA_NONE) return mode;
    }
    if (is_billboard_mesh(mesh->name)) return PBM_ALPHA_CUTOUT;
    return PBM_ALPHA_NONE;
}

static inline int is_transparent_mesh(PbmMap* map, PbmMesh* mesh) {
    return mesh_alpha_mode(map, mesh) != PBM_ALPHA_NONE;
}

static void bind_texture(PbmMap* map, const RenderCfg* cfg, PbmMesh* mesh, int* last_tex_id) {
    if (!cfg->use_textures || cfg->display_mode != 0) {
        sceGuDisable(GU_TEXTURE_2D);
        *last_tex_id = -1;
        return;
    }
    if (cfg->force_small_tex) {
        if (*last_tex_id != -2) {
            int w, h;
            const void* tex = psp_small_texture(&w, &h);
            sceGuEnable(GU_TEXTURE_2D);
            sceGuTexMode(GU_PSM_5551, 0, 0, 1);
            sceGuTexImage(0, w, h, w, tex);
            *last_tex_id = -2;
        }
        return;
    }
    if (mesh->texture_id >= 0 && mesh->texture_id < (int)map->header.num_textures) {
        if (mesh->texture_id != *last_tex_id) {
            PbmTexture* tex = &map->textures[mesh->texture_id];
            /* Tile atlases are addressed by absolute slot coordinates: a tile
             * samples right up to its slot edge, so the sampler must clamp at
             * the atlas border or it wraps to the opposite side. The tiling base
             * materials are the opposite case and must repeat. */
            if (strstr(tex->name, "TileAtlas")) sceGuTexWrap(GU_CLAMP, GU_CLAMP);
            else                               sceGuTexWrap(GU_REPEAT, GU_REPEAT);
            if (tex->pixels && tex->num_levels > 0) {
                int psm = (tex->format == PBM_TEX_FMT_RGBA5551) ? GU_PSM_5551 : GU_PSM_8888;
                int swizzle = tex->is_swizzled ? 1 : 0;
                /* Cutout chains are alpha-preserving (see the loader); the
                 * switch exists so the old level-0-only behaviour can be
                 * compared on the device without a rebuild. */
                int use_chain = cfg->use_mips && tex->num_levels > 1 &&
                                (cfg->cutout_mips || mesh_alpha_mode(map, mesh) != PBM_ALPHA_CUTOUT);
                if (use_chain) {
                    /* Every level's base/size lives in its own GE register set. */
                    sceGuEnable(GU_TEXTURE_2D);
                    sceGuTexMode(psm, tex->num_levels - 1, 0, swizzle);
                    for (uint32_t k = 0; k < tex->num_levels; ++k)
                        sceGuTexImage((int)k, tex->level_w[k], tex->level_h[k],
                                      tex->level_w[k], tex->level_ptr[k]);
                } else {
                    sceGuEnable(GU_TEXTURE_2D);
                    sceGuTexMode(psm, 0, 0, swizzle);
                    sceGuTexImage(0, tex->width, tex->height, tex->width, tex->pixels);
                }
            }
            *last_tex_id = mesh->texture_id;
        }
    } else {
        sceGuDisable(GU_TEXTURE_2D);
        *last_tex_id = -1;
    }
}

/* ── Per-mesh LOD policy ──────────────────────────────────────────────────
 * The GE picks ONE mip level per primitive from that primitive's own UV
 * derivatives, and the level-mode/bias registers are per draw call. Two things
 * follow that matter on a big smooth floor:
 *   - neighbouring quads (baked tiles, floor chunks) land on different integer
 *     levels, so the surface shows a sharpness step wherever the level changes
 *     — invisible at level 0-1, a visible band once the level is coarse;
 *   - spending texture cache on a surface that is already ~1 texel/pixel is
 *     what the global bias exists to avoid.
 * So the meshes that carry painted detail get their own policy (a sharper bias,
 * or a single constant level — the only way to remove the step entirely) while
 * the bulk of the scene keeps the global one. Which meshes match is
 * psp_render_detail_match(), "TileAtlas" by default. `mesh == NULL` applies the
 * global policy, which is what the emitter path needs: a particle texture must
 * not inherit whatever the last mesh drew with. */
#define LOD_STATE_INVALID (-999.0f)
static int   s_lod_mode = -1;
static float s_lod_bias = LOD_STATE_INVALID;

static int is_detail_mesh(const PbmMap* map, const PbmMesh* mesh) {
    if (!s_detail_match[0] || !mesh) return 0;
    if (strstr(mesh->name, s_detail_match)) return 1;
    if (mesh->texture_id >= 0 && mesh->texture_id < (int)map->header.num_textures &&
        strstr(map->textures[mesh->texture_id].name, s_detail_match)) return 1;
    return 0;
}

static void apply_mesh_lod(const RenderCfg* cfg, const PbmMap* map, const PbmMesh* mesh) {
    int mode = cfg->tex_level_mode;
    float bias = cfg->tex_lod_bias;
    if (is_detail_mesh(map, mesh)) {
        if (cfg->detail_const >= 0) { mode = PBLEVEL_CONST; bias = (float)cfg->detail_const; }
        else bias += cfg->detail_bias;
    }
    if (bias < -4.0f) bias = -4.0f;
    else if (bias > 6.0f) bias = 6.0f;
    if (mode == s_lod_mode && bias == s_lod_bias) return;
    sceGuTexLevelMode(mode == PBLEVEL_CONST ? GU_TEXTURE_CONST : GU_TEXTURE_AUTO, bias);
    s_lod_mode = mode;
    s_lod_bias = bias;
}

/* Scripted patrol-sphere entity (procedural, CPU-generated once). */
#define SPHERE_LATS 6
#define SPHERE_LONS 8
#define NUM_SPHERE_VERTS (SPHERE_LATS * SPHERE_LONS * 6)
static PbmVertex s_sphere_verts[NUM_SPHERE_VERTS];
static int s_sphere_initialized = 0;

static void init_sphere_mesh(float radius, uint32_t color) {
    int idx = 0;
    for (int i = 0; i < SPHERE_LATS; ++i) {
        float lat0 = -M_PI / 2.0f + (float)i * M_PI / SPHERE_LATS;
        float z0 = sinf(lat0), zr0 = cosf(lat0);
        float lat1 = -M_PI / 2.0f + (float)(i + 1) * M_PI / SPHERE_LATS;
        float z1 = sinf(lat1), zr1 = cosf(lat1);
        for (int j = 0; j < SPHERE_LONS; ++j) {
            float lng0 = 2.0f * M_PI * (float)j / SPHERE_LONS;
            float x0 = cosf(lng0), y0 = sinf(lng0);
            float lng1 = 2.0f * M_PI * (float)(j + 1) / SPHERE_LONS;
            float x1 = cosf(lng1), y1 = sinf(lng1);

            #define V_SPHERE(vx, vy, vz) do { \
                s_sphere_verts[idx].u = 0.0f; \
                s_sphere_verts[idx].v = 0.0f; \
                float diff = 0.4f + 0.6f * fmaxf(0.0f, (vx)*0.5f + (vy)*0.8f + (vz)*0.3f); \
                uint8_t cr = (uint8_t)(fminf(255.0f, ((color) & 0xFF) * diff)); \
                uint8_t cg = (uint8_t)(fminf(255.0f, (((color) >> 8) & 0xFF) * diff)); \
                uint8_t cb = (uint8_t)(fminf(255.0f, (((color) >> 16) & 0xFF) * diff)); \
                s_sphere_verts[idx].color = cr | (cg << 8) | (cb << 16) | (255u << 24); \
                s_sphere_verts[idx].x = (vx) * radius; \
                s_sphere_verts[idx].y = (vy) * radius; \
                s_sphere_verts[idx].z = (vz) * radius; \
                idx++; \
            } while(0)

            V_SPHERE(x0 * zr0, z0, y0 * zr0);
            V_SPHERE(x1 * zr1, z1, y1 * zr1);
            V_SPHERE(x1 * zr0, z0, y1 * zr0);

            V_SPHERE(x0 * zr0, z0, y0 * zr0);
            V_SPHERE(x0 * zr1, z1, y0 * zr1);
            V_SPHERE(x1 * zr1, z1, y1 * zr1);
            #undef V_SPHERE
        }
    }
    s_sphere_initialized = 1;
}

static void get_patrol_sphere_pos(const PbmEntityPatrolSphere* ent, float time,
                                  float* out_x, float* out_y, float* out_z) {
    uint32_t n = ent->num_waypoints;
    if (n < 2) {
        *out_x = ent->waypoints[0][0]; *out_y = ent->waypoints[0][1]; *out_z = ent->waypoints[0][2];
        return;
    }
    if (n > 8) n = 8;
    float seg_lens[8];
    float total_len = 0.0f;
    for (uint32_t i = 0; i < n; ++i) {
        uint32_t next = (i + 1) % n;
        float dx = ent->waypoints[next][0] - ent->waypoints[i][0];
        float dy = ent->waypoints[next][1] - ent->waypoints[i][1];
        float dz = ent->waypoints[next][2] - ent->waypoints[i][2];
        seg_lens[i] = sqrtf(dx * dx + dy * dy + dz * dz);
        total_len += seg_lens[i];
    }
    if (total_len <= 0.0001f) {
        *out_x = ent->waypoints[0][0]; *out_y = ent->waypoints[0][1]; *out_z = ent->waypoints[0][2];
        return;
    }
    float speed = ent->speed > 0.01f ? ent->speed : 2.5f;
    float dist = fmodf(time * speed, total_len);
    if (dist < 0.0f) dist += total_len;
    float acc = 0.0f;
    for (uint32_t i = 0; i < n; ++i) {
        if (dist <= acc + seg_lens[i] || i == n - 1) {
            float t = (seg_lens[i] > 0.0001f) ? ((dist - acc) / seg_lens[i]) : 0.0f;
            uint32_t next = (i + 1) % n;
            *out_x = ent->waypoints[i][0] + (ent->waypoints[next][0] - ent->waypoints[i][0]) * t;
            *out_y = ent->waypoints[i][1] + (ent->waypoints[next][1] - ent->waypoints[i][1]) * t;
            *out_z = ent->waypoints[i][2] + (ent->waypoints[next][2] - ent->waypoints[i][2]) * t;
            return;
        }
        acc += seg_lens[i];
    }
}

/* ── Animated UV scroll (PBM 3.0) ─────────────────────────────────────────
 * A mesh's uv_scroll_u/v carry the VELOCITY OF THE TEXTURE PATTERN across the
 * surface, in texture repeats per second, along the surface's own UV axes:
 * the waterfall on the courtyard wall falls downward, i.e. toward -V (V runs
 * up a wall), so its speed_v is negative, while churn on the floor spreading
 * away from the wall is positive (V runs toward +Z there).
 *
 * The implementation is one register: the GE's texture offset advances by
 * speed * time, and what that does to the picture was measured rather than
 * assumed. On hardware, an INCREASING offset slides the pattern toward +V —
 * the sign is the opposite of what "offset is added to the texture coordinate"
 * suggests, and getting it backwards is invisible in a static frame, which is
 * exactly how it shipped once. Re-measure with `run_psp_headless.sh` (frames
 * 60 and 80 of the benchmark share a frozen camera) plus a correlation over
 * the scrolling mesh's pixels before changing this line.
 *
 * Cost: two register writes for a mesh whose offset moved this frame, nothing
 * at all for a static one (the last offset is cached, so a scene with no
 * animated meshes emits zero extra commands).
 *
 * Two hardware constraints shape this:
 *   - The offset applies to the 3D T&L pipe only, which is the path every
 *     mesh here already uses (GU_TRANSFORM_3D). The 2D HUD is unaffected.
 *   - A tile-atlas mesh addresses absolute slot coordinates inside a 512x512
 *     atlas, so an offset would drag the tile across its slot border. The
 *     exporter never marks such a mesh as scrolling; skip it defensively
 *     here as well rather than trusting the file.
 */
static void apply_uv_scroll(PbmMap* map, PbmMesh* mesh, float time_s,
                            float* cur_u, float* cur_v) {
    float su = 0.0f, sv = 0.0f;
    if ((mesh->uv_scroll_u != 0.0f || mesh->uv_scroll_v != 0.0f) &&
        mesh->texture_id >= 0 && mesh->texture_id < (int)map->header.num_textures &&
        !strstr(map->textures[mesh->texture_id].name, "TileAtlas")) {
        su = mesh->uv_scroll_u;
        sv = mesh->uv_scroll_v;
    }
    /* Wrap into one repeat before it reaches the register: the offset is a
     * 12-bit fixed-point add, so an offset the size of the texture would just
     * lose precision. Wrapping first keeps the visible shift exact. */
    float u = time_s * su;
    float v = time_s * sv;
    u -= floorf(u);
    v -= floorf(v);
    if (u != *cur_u || v != *cur_v) {
        sceGuTexOffset(u, v);
        *cur_u = u;
        *cur_v = v;
    }
}

/* ── Particle emitters (standard lump "emitters") ─────────────────────────
 * An emitter is a LOOPING, STATELESS particle stream: particle i's state at
 * scene time t is a closed form of (t, i, seed), with the per-particle
 * constants derived once at load (map->particles). Nothing here simulates,
 * integrates, sorts by insertion on a state array, or allocates a particle --
 * the loop evaluates position, size, colour, spin angle and flipbook frame and
 * writes two triangles per particle into the display list.
 *
 * What shapes the implementation is what this hardware actually charges for:
 *   - FILL RATE is the budget. A full screen of cache-resident textured fill is
 *     ~0.3 ms (measured 480 Mfrag/s); one draw call is ~0.94 us and a few
 *     hundred transformed vertices are noise. So the goal is "as few fragments
 *     as the effect needs", not "as few vertices", and particles may be big --
 *     but not many.
 *   - Sampling a texture that does not fit the GE's texture cache while it is
 *     MINIFIED costs 19x, and a flipbook atlas cannot carry a mip chain (a mip
 *     level would mix neighbouring frames). Particles whose projected edge
 *     falls below PBM_EMIT_MIN_PX are therefore dropped: they cover a handful
 *     of pixels but would scatter their texture fetches across the atlas.
 * Emitters ride the same 3D path as the meshes, with normalized UVs, so they
 * inherit the engine's texture state machine unchanged. */
/* Drop particles thinner than this on screen. The threshold exists because
 * minification is where the GE pays: the penalty is ~19x when the sampled
 * texture does not fit the ~8 KB texture cache, and it is only ever paid on
 * fragments that are heavily minified (a small on-screen particle). Emitter
 * textures are required to be small, so the penalty is bounded -- this cull is
 * the backstop for the case where a whole frame's worth of particles is small
 * on screen at once, not a general "skip small things" rule. */
#define PBM_EMIT_MIN_PX   1.5f
#define PBM_EMIT_TAN_HALF 0.63707f /* tan(65 deg / 2): the scene's vertical fov */
/* Screen pixels per world metre at 1 m: (272 / 2) / tan(fov/2). */
#define PBM_EMIT_PX_PER_M 213.44f

/* Table sine with linear interpolation. The per-particle math needs sin/cos
 * several times per particle per frame (wobble, spin), and a libm call each
 * would be a visible share of an emitter's cost; one table serves both. */
#define PBM_SIN_STEPS 256
static float s_sin_tab[PBM_SIN_STEPS + 1];
static int s_sin_ready = 0;

static void pbm_sin_init(void) {
    for (int i = 0; i <= PBM_SIN_STEPS; ++i)
        s_sin_tab[i] = sinf(6.28318530718f * (float)i / (float)PBM_SIN_STEPS);
    s_sin_ready = 1;
}

static inline float pbm_sin(float x) {
    float w = x * 0.15915494309f;   /* / 2pi */
    w -= floorf(w);
    float f = w * (float)PBM_SIN_STEPS;
    int i = (int)f;
    f -= (float)i;
    return s_sin_tab[i] + (s_sin_tab[i + 1] - s_sin_tab[i]) * f;
}
static inline float pbm_cos(float x) { return pbm_sin(x + 1.57079632679f); }

/* Linear interpolation between two packed 0xAABBGGRR colours. */
static inline uint32_t pbm_lerp_rgba(uint32_t a, uint32_t b, float t) {
    int ti = (int)(t * 256.0f);
    if (ti < 0) ti = 0; else if (ti > 256) ti = 256;
    uint32_t out = 0;
    for (int s = 0; s < 32; s += 8) {
        int ca = (int)((a >> s) & 0xFFu), cb = (int)((b >> s) & 0xFFu);
        out |= ((uint32_t)(ca + (((cb - ca) * ti) >> 8)) & 0xFFu) << s;
    }
    return out;
}

/* Built-in emitter texture: a radial falloff, RGB white-to-black with a solid
 * alpha, which is exactly what an ADDITIVE particle wants (the falloff rides
 * the RGB channels, so it survives a 16-bit format's one alpha bit). A file may
 * reference no texture; that is what it gets. */
#define PBM_GLOW_W 32
#define PBM_GLOW_H 32
static uint16_t __attribute__((aligned(64))) s_glow_tex[PBM_GLOW_W * PBM_GLOW_H];
static int s_glow_ready = 0;

static const void* psp_glow_texture(int* w, int* h) {
    if (!s_glow_ready) {
        uint16_t linear[PBM_GLOW_W * PBM_GLOW_H];
        const float c = (PBM_GLOW_W - 1) * 0.5f;
        for (int y = 0; y < PBM_GLOW_H; ++y) {
            for (int x = 0; x < PBM_GLOW_W; ++x) {
                float dx = ((float)x - c) / c, dy = ((float)y - c) / c;
                float d = sqrtf(dx * dx + dy * dy);
                if (d > 1.0f) d = 1.0f;
                float f = 1.0f - d;
                f = f * f * (3.0f - 2.0f * f);   /* smoothstep: no visible rim */
                int v = (int)(f * 31.0f + 0.5f);
                linear[y * PBM_GLOW_W + x] = (uint16_t)(0x8000 | (v << 10) | (v << 5) | v);
            }
        }
        swizzle16((uint8_t*)s_glow_tex, (const uint8_t*)linear, PBM_GLOW_W, PBM_GLOW_H);
        sceKernelDcacheWritebackRange(s_glow_tex, sizeof(s_glow_tex));
        s_glow_ready = 1;
    }
    if (w) *w = PBM_GLOW_W;
    if (h) *h = PBM_GLOW_H;
    return s_glow_tex;
}

/* The camera basis an emitter is projected against. */
typedef struct {
    float ex, ey, ez;   /* eye */
    float fx, fy, fz;   /* forward */
    float rx, ry, rz;   /* right */
    float ux, uy, uz;   /* up */
} EmitView;

/* One particle, evaluated for this frame. */
typedef struct {
    float x, y, z;          /* centre, world */
    float half_w, half_h;   /* half extents, in metres (width uses the emitter's aspect) */
    float ca, sa;           /* cos/sin of the screen-plane rotation */
    float depth;            /* view depth (m): the back-to-front sort key */
    float rx, ry, rz;       /* billboard right */
    float ux, uy, uz;       /* billboard up */
    float u0, v0, du, dv;   /* flipbook cell (already inset) */
    uint32_t color;
} PbmEmitItem;

static PbmEmitItem s_items[PBM_EMIT_MAX_PER_EMITTER];
static int s_order[PBM_EMIT_MAX_PER_EMITTER];

/* Evaluates every particle of one emitter into s_items. Returns how many
 * survived (near-plane and size culls); 0 means nothing to draw. `pool` is the
 * particle-constant array (`first` indexes into it) -- the map's own for a real
 * emitter, a local one for the profiler's synthetic probe. */
static uint32_t emitter_eval(PbmMap* map, const PbmEmitter* e, const PbmParticle* pool,
                             uint32_t first, float time_s, const EmitView* vw, float near_plane) {
    const uint32_t n = e->count;
    const float knee = e->knee;
    const int cols = (int)e->atlas_cols, rows = (int)e->atlas_rows;
    const int frames = cols * rows;
    float tex_w = 1.0f, tex_h = 1.0f;
    if (frames > 1 && e->texture_id >= 0 && e->texture_id < (int)map->header.num_textures) {
        tex_w = (float)map->textures[e->texture_id].width;
        tex_h = (float)map->textures[e->texture_id].height;
    }
    const float cell_u = 1.0f / (float)cols, cell_v = 1.0f / (float)rows;
    /* The size cull measures the LARGER extent: a wide particle is as expensive
     * on screen as a tall one. */
    const float aspect_big = e->aspect > 1.0f ? e->aspect : 1.0f;
    /* Half-texel inset: a flipbook cell must not filter against its neighbour. */
    const float inset_u = 0.5f / tex_w, inset_v = 0.5f / tex_h;

    /* Wobble basis: perpendicular to the emission axis, fixed per emission. */
    const float ax = e->dir[0], ay = e->dir[1], az = e->dir[2];
    float w1x, w1y, w1z, w2x, w2y, w2z;
    if (fabsf(ay) < 0.9f) { w1x = -az; w1y = 0.0f; w1z = ax; }
    else                  { w1x = 0.0f; w1y = az; w1z = -ay; }
    {
        float l = sqrtf(w1x * w1x + w1y * w1y + w1z * w1z);
        if (!(l > 0.0001f)) { w1x = 1.0f; w1y = 0.0f; w1z = 0.0f; l = 1.0f; }
        w1x /= l; w1y /= l; w1z /= l;
    }
    w2x = ay * w1z - az * w1y;
    w2y = az * w1x - ax * w1z;
    w2z = ax * w1y - ay * w1x;

    /* Billboard basis for the emitter-wide modes. */
    float brx = vw->rx, bry = vw->ry, brz = vw->rz;
    float bux = vw->ux, buy = vw->uy, buz = vw->uz;
    if (e->flags & PBM_EMIT_Y_LOCKED) {
        /* Cylinder billboard: right = normalize(cross(world_up, forward)). */
        float rx = vw->fz, rz = -vw->fx;
        float l = sqrtf(rx * rx + rz * rz);
        if (l > 0.0001f) { rx /= l; rz /= l; } else { rx = 1.0f; rz = 0.0f; }
        brx = rx; bry = 0.0f; brz = rz;
        /* up = cross(right, forward) */
        bux = bry * vw->fz - brz * vw->fy;
        buy = brz * vw->fx - brx * vw->fz;
        buz = brx * vw->fy - bry * vw->fx;
    }

    uint32_t live = 0;
    for (uint32_t k = 0; k < n; ++k) {
        const PbmParticle* p = &pool[first + k];
        float age = time_s * p->inv_life + p->phase;
        age -= floorf(age);
        const float tau = age * p->life;

        /* Size: the particle's own birth size scaled by the two-segment curve. */
        float size = p->size * (age < knee
            ? 1.0f + (e->size_mid - 1.0f) * (age / knee)
            : e->size_mid + (e->size_end - e->size_mid) * ((age - knee) / (1.0f - knee)));

        /* Position: closed-form ballistic, with the exponential drag's analytic
         * form when the emitter damps (k1 -> tau, k2 -> tau^2/2 as damping -> 0). */
        float px, py, pz;
        if (e->damping > 0.0f) {
            float decay = expf(-e->damping * tau);
            float k1 = (1.0f - decay) / e->damping;
            float k2 = (tau - k1) / e->damping;
            px = e->pos[0] + p->spawn[0] + p->dir[0] * p->speed * k1 + e->gravity[0] * k2;
            py = e->pos[1] + p->spawn[1] + p->dir[1] * p->speed * k1 + e->gravity[1] * k2;
            pz = e->pos[2] + p->spawn[2] + p->dir[2] * p->speed * k1 + e->gravity[2] * k2;
        } else {
            float half_t2 = 0.5f * tau * tau;
            px = e->pos[0] + p->spawn[0] + p->dir[0] * p->speed * tau + e->gravity[0] * half_t2;
            py = e->pos[1] + p->spawn[1] + p->dir[1] * p->speed * tau + e->gravity[1] * half_t2;
            pz = e->pos[2] + p->spawn[2] + p->dir[2] * p->speed * tau + e->gravity[2] * half_t2;
        }
        if (e->wobble_amp > 0.0f) {
            float w = 6.28318530718f * e->wobble_freq * tau + p->wobble_phase;
            float sw = pbm_sin(w), cw = pbm_cos(w);
            px += (w1x * sw + w2x * cw) * e->wobble_amp;
            py += (w1y * sw + w2y * cw) * e->wobble_amp;
            pz += (w1z * sw + w2z * cw) * e->wobble_amp;
        }

            float dx = px - vw->ex, dy = py - vw->ey, dz = pz - vw->ez;
        float depth = dx * vw->fx + dy * vw->fy + dz * vw->fz;
        if (depth + size * 0.75f < near_plane) continue;
        if (size * aspect_big * PBM_EMIT_PX_PER_M < depth * PBM_EMIT_MIN_PX) continue;

        uint32_t col = age < knee
            ? pbm_lerp_rgba(e->color_start, e->color_mid, age / knee)
            : pbm_lerp_rgba(e->color_mid, e->color_end, (age - knee) / (1.0f - knee));

        float rx = brx, ry = bry, rz = brz;
        float ux = bux, uy = buy, uz = buz;
        if (e->flags & PBM_EMIT_VEL_ALIGN) {
            /* up = velocity direction, right = cross(up, to_camera). */
            float dxn = dx, dyn = dy, dzn = dz;
            float dl = sqrtf(dxn * dxn + dyn * dyn + dzn * dzn);
            if (dl > 0.0001f) { dxn /= dl; dyn /= dl; dzn /= dl; }
            float vx, vy, vz;
            if (e->damping > 0.0f) {
                float decay = expf(-e->damping * tau);
                vx = p->dir[0] * p->speed * decay + e->gravity[0] * (1.0f - decay) / e->damping;
                vy = p->dir[1] * p->speed * decay + e->gravity[1] * (1.0f - decay) / e->damping;
                vz = p->dir[2] * p->speed * decay + e->gravity[2] * (1.0f - decay) / e->damping;
            } else {
                vx = p->dir[0] * p->speed + e->gravity[0] * tau;
                vy = p->dir[1] * p->speed + e->gravity[1] * tau;
                vz = p->dir[2] * p->speed + e->gravity[2] * tau;
            }
            float vl = sqrtf(vx * vx + vy * vy + vz * vz);
            if (vl > 0.0001f) {
                ux = vx / vl; uy = vy / vl; uz = vz / vl;
                float cx2 = uy * dzn - uz * dyn;
                float cy2 = uz * dxn - ux * dzn;
                float cz2 = ux * dyn - uy * dxn;
                float cl = sqrtf(cx2 * cx2 + cy2 * cy2 + cz2 * cz2);
                if (cl > 0.0001f) { rx = cx2 / cl; ry = cy2 / cl; rz = cz2 / cl; }
            }
        }

        float u0 = 0.0f, v0 = 0.0f, du = 1.0f, dv = 1.0f;
        if (frames > 1) {
            float af = age * (float)e->anim_loops + p->anim_offset;
            af -= floorf(af);
            int fr = (int)(af * (float)frames);
            if (fr >= frames) fr = frames - 1;
            int cell_x = fr % cols;
            int cell_y = fr / cols;
            u0 = (float)cell_x * cell_u + inset_u;
            v0 = (float)cell_y * cell_v + inset_v;
            du = cell_u - 2.0f * inset_u;
            dv = cell_v - 2.0f * inset_v;
        }

        PbmEmitItem* it = &s_items[live];
        it->x = px; it->y = py; it->z = pz;
        it->half_w = size * e->aspect * 0.5f;
        it->half_h = size * 0.5f;
        float ang = p->angle0 + p->spin * tau;
        it->ca = pbm_cos(ang);
        it->sa = pbm_sin(ang);
        it->depth = depth;
        it->rx = rx; it->ry = ry; it->rz = rz;
        it->ux = ux; it->uy = uy; it->uz = uz;
        it->u0 = u0; it->v0 = v0; it->du = du; it->dv = dv;
        it->color = col;
        live++;
    }
    return live;
}

/* Turns one evaluated particle into six vertices (two triangles). */
static void emitter_emit_quad(PspVertex* v, const PbmEmitItem* it) {
    /* r' = r*ca + u*sa, u' = u*ca - r*sa: the spin, in the billboard plane. */
    float rxh = (it->rx * it->ca + it->ux * it->sa) * it->half_w;
    float ryh = (it->ry * it->ca + it->uy * it->sa) * it->half_w;
    float rzh = (it->rz * it->ca + it->uz * it->sa) * it->half_w;
    float uxh = (it->ux * it->ca - it->rx * it->sa) * it->half_h;
    float uyh = (it->uy * it->ca - it->ry * it->sa) * it->half_h;
    float uzh = (it->uz * it->ca - it->rz * it->sa) * it->half_h;

    float x0 = it->x - rxh - uxh, y0 = it->y - ryh - uyh, z0 = it->z - rzh - uzh; /* bottom-left  */
    float x1 = it->x + rxh - uxh, y1 = it->y + ryh - uyh, z1 = it->z + rzh - uzh; /* bottom-right */
    float x2 = it->x + rxh + uxh, y2 = it->y + ryh + uyh, z2 = it->z + rzh + uzh; /* top-right    */
    float x3 = it->x - rxh + uxh, y3 = it->y - ryh + uyh, z3 = it->z - rzh + uzh; /* top-left     */

    const float u0 = it->u0, v0 = it->v0, u1 = it->u0 + it->du, v1 = it->v0 + it->dv;
    const uint32_t c = it->color;

    v[0].u = u0; v[0].v = v0; v[0].color = c; v[0].x = x3; v[0].y = y3; v[0].z = z3;
    v[1].u = u1; v[1].v = v0; v[1].color = c; v[1].x = x2; v[1].y = y2; v[1].z = z2;
    v[2].u = u1; v[2].v = v1; v[2].color = c; v[2].x = x1; v[2].y = y1; v[2].z = z1;
    v[3].u = u0; v[3].v = v0; v[3].color = c; v[3].x = x3; v[3].y = y3; v[3].z = z3;
    v[4].u = u1; v[4].v = v1; v[4].color = c; v[4].x = x1; v[4].y = y1; v[4].z = z1;
    v[5].u = u0; v[5].v = v1; v[5].color = c; v[5].x = x0; v[5].y = y0; v[5].z = z0;
}

/* Defined with the scene's texture setup below; an emitter that samples a mip
 * chain has to use the same filter/level state a mesh would. */
static void set_texture_filter(const RenderCfg* cfg);

static void emitter_bind(PbmMap* map, const RenderCfg* cfg, const PbmEmitter* e, int* alpha_mode) {
    *alpha_mode = PBM_ALPHA_NONE;
    if (!cfg->use_textures || cfg->display_mode == 2) {
        sceGuDisable(GU_TEXTURE_2D);
        return;
    }
    sceGuEnable(GU_TEXTURE_2D);
    if (e->texture_id >= 0 && e->texture_id < (int)map->header.num_textures &&
        map->textures[e->texture_id].pixels) {
        PbmTexture* t = &map->textures[e->texture_id];
        *alpha_mode = t->alpha_mode;
        int psm = (t->format == PBM_TEX_FMT_RGBA5551) ? GU_PSM_5551 : GU_PSM_8888;
        int swizzle = t->is_swizzled ? 1 : 0;
        /* A single-cell emitter samples the whole texture, exactly like a mesh,
         * so it CAN and MUST use the load-time mip chain: it is the difference
         * between a minified soft puff costing its fragments and costing a
         * scattered main-memory fetch per tap (measured: 1.7 ms for fourteen
         * 25-pixel puffs without the chain, nothing with it). A flipbook is the
         * opposite case -- each level would average neighbouring frames into
         * one another -- so it stays on level 0, where the size cull below keeps
         * the fetch footprint bounded instead. */
        int multi_cell = (e->atlas_cols > 1 || e->atlas_rows > 1);
        if (!multi_cell && cfg->use_mips && t->num_levels > 1) {
            set_texture_filter(cfg);
            sceGuTexMode(psm, t->num_levels - 1, 0, swizzle);
            for (uint32_t k = 0; k < t->num_levels; ++k)
                sceGuTexImage((int)k, t->level_w[k], t->level_h[k], t->level_w[k], t->level_ptr[k]);
        } else {
            sceGuTexMode(psm, 0, 0, swizzle);
            sceGuTexImage(0, t->width, t->height, t->width, t->pixels);
            sceGuTexFilter(GU_LINEAR, GU_LINEAR);
        }
        sceGuTexWrap(GU_CLAMP, GU_CLAMP);
    } else {
        int w, h;
        const void* tex = psp_glow_texture(&w, &h);
        sceGuTexMode(GU_PSM_5551, 0, 0, 1);
        sceGuTexImage(0, w, h, w, tex);
        sceGuTexWrap(GU_CLAMP, GU_CLAMP);
        sceGuTexFilter(GU_LINEAR, GU_LINEAR);
    }
}

/* Draws one emitter: evaluate, sort (unless additive), emit two triangles per
 * particle, one draw call. Shared by the scene pass and the profiler probe. */
static void emitter_draw_one(PbmMap* map, const RenderCfg* cfg, const EmitView* vw,
                             const PbmEmitter* e, const PbmParticle* pool, uint32_t first,
                             float time_s, uint32_t* verts, uint32_t* calls,
                             uint32_t* particles, int additive) {
    uint32_t live = emitter_eval(map, e, pool, first, time_s, vw, cfg->near_plane);
    if (live == 0) return;

    int alpha_mode = PBM_ALPHA_NONE;
    emitter_bind(map, cfg, e, &alpha_mode);
    /* A particle texture always takes the GLOBAL policy: inheriting the previous
     * mesh's detail policy would sample it at whatever level that mesh wanted. */
    apply_mesh_lod(cfg, map, NULL);
    sceGuDisable(GU_CULL_FACE);
    sceGuDepthMask(GU_FALSE);
    if (additive) {
        /* dst = src * srcAlpha + dst * 1. The GE has no GU_ONE factor; a fixed
         * blend colour of 1.0 is the idiomatic equivalent. */
        sceGuBlendFunc(GU_ADD, GU_SRC_ALPHA, GU_FIX, 0, 0xFFFFFFFF);
    } else {
        sceGuBlendFunc(GU_ADD, GU_SRC_ALPHA, GU_ONE_MINUS_SRC_ALPHA, 0, 0);
    }
    /* Alpha test: cut-out particle art keeps its hard silhouette, soft art only
     * has its fully transparent texels discarded (which keeps early-Z rejection
     * working for the blended surfaces too). */
    sceGuAlphaFunc(GU_GREATER, (alpha_mode == PBM_ALPHA_CUTOUT) ? 0x10 : 0x00, 0xFF);

    for (uint32_t i = 0; i < live; ++i) s_order[i] = (int)i;
    if (!additive) {
        /* Back to front: far particles first, so the nearer ones blend onto
         * them. Insertion sort -- live is at most PBM_EMIT_MAX_PER_EMITTER. */
        for (uint32_t i = 1; i < live; ++i) {
            int cur = s_order[i];
            float d = s_items[cur].depth;
            int j = (int)i - 1;
            while (j >= 0 && s_items[s_order[j]].depth < d) {
                s_order[j + 1] = s_order[j];
                --j;
            }
            s_order[j + 1] = cur;
        }
    }

    PspVertex* v = (PspVertex*)sceGuGetMemory(live * 6 * sizeof(PspVertex));
    if (!v) {
        static int warned = 0;
        if (!warned) { warned = 1; printf("[PSP] emitter: display list full, particles skipped\n"); }
        return;
    }
    for (uint32_t i = 0; i < live; ++i)
        emitter_emit_quad(&v[i * 6], &s_items[s_order[i]]);

    sceGuDrawArray(GU_TRIANGLES,
        GU_TEXTURE_32BITF | GU_COLOR_8888 | GU_VERTEX_32BITF | GU_TRANSFORM_3D,
        live * 6, 0, v);
    *verts += live * 6;
    *calls += 1;
    *particles += live;
}

/* Draws every emitter whose blend group matches `additive` (0 = alpha blend,
 * 1 = additive). Additive emitters need no sorting at all: additive blending is
 * order-independent, which is exactly why they are the cheap default. */
static void emitter_pass(PbmMap* map, const RenderCfg* cfg, const EmitView* vw,
                         float time_s, uint32_t* verts, uint32_t* calls,
                         uint32_t* particles, int additive) {
    for (uint32_t ei = 0; ei < map->num_emitters; ++ei) {
        const PbmEmitter* e = &map->emitters[ei];
        if (e->count == 0) continue;
        if (((e->flags & PBM_EMIT_ADDITIVE) != 0) != (additive != 0)) continue;

        /* Emitter cull: bounding sphere against the near plane and the four
         * side planes (conservative, no matrix work). `vz` is the projection
         * onto the camera's forward axis, i.e. the distance IN FRONT. */
        float dx = e->pos[0] - vw->ex, dy = e->pos[1] - vw->ey, dz = e->pos[2] - vw->ez;
        float vz = dx * vw->fx + dy * vw->fy + dz * vw->fz;
        float vx = dx * vw->rx + dy * vw->ry + dz * vw->rz;
        float vy = dx * vw->ux + dy * vw->uy + dz * vw->uz;
        float rad = map->emitter_cull_radius[ei];
        float front = vz;
        if (front + rad < cfg->near_plane) continue;
        float reach = front + rad;
        if (reach < 0.05f) reach = 0.05f;
        if (fabsf(vx) - rad > reach * PBM_EMIT_TAN_HALF * (16.0f / 9.0f)) continue;
        if (fabsf(vy) - rad > reach * PBM_EMIT_TAN_HALF) continue;

        emitter_draw_one(map, cfg, vw, e, map->particles, map->emitter_first_particle[ei],
                         time_s, verts, calls, particles, additive);
    }
}

static void psp_particle_fill_layout(PbmEmitter* e, PbmParticle* pool, int count, float size);

/* Fill calibration through the emitter path: `count` STATIONARY particles laid
 * out on a grid that exactly covers the frustum at 2 m, each `size` metres
 * tall, blended the way the caller asks. Unlike the moving probe this is a
 * deterministic coverage test, so its cost can be compared with the opaque
 * fill2d_* rows and turned into fragments per millisecond -- i.e. into what an
 * author may put on screen. */
void psp_render_particle_fill_probe(PbmMap* map, int count, float size, int additive,
                                    int texture_id, uint32_t color, RenderStats* stats) {
    static PbmEmitter e;
    static PbmParticle pool[PBM_EMIT_MAX_PER_EMITTER];
    static PbmMap fake;
    static RenderCfg cfg;
    static int built = -1;
    if (count < 1) return;
    if (count > PBM_EMIT_MAX_PER_EMITTER) count = PBM_EMIT_MAX_PER_EMITTER;
    if (!s_sin_ready) pbm_sin_init();
    static int cfg_ready = 0;
    if (!cfg_ready) { render_cfg_default(&cfg); cfg_ready = 1; }
    if (built != count) {
        memset(&e, 0, sizeof(e));
        e.pos[0] = 0.0f; e.pos[1] = 0.0f; e.pos[2] = -2.0f;
        e.dir[1] = 1.0f;
        e.size_min = size; e.size_max = size;
        e.size_mid = 1.0f; e.size_end = 1.0f;
        e.aspect = 1.0f;
        e.knee = 0.5f;
        e.life_min = 1000.0f; e.life_max = 1000.0f;
        e.color_start = color; e.color_mid = color; e.color_end = color;
        e.texture_id = texture_id;
        e.count = (uint16_t)count;
        e.atlas_cols = 1; e.atlas_rows = 1; e.anim_loops = 1;
        e.seed = 0x51ED2701u;
        pbm_derive_particles(&e, pool, (uint32_t)count);
        built = count;
    }
    e.flags = additive ? PBM_EMIT_ADDITIVE : 0;
    psp_particle_fill_layout(&e, pool, count, size);

    EmitView vw;
    vw.ex = 0.0f; vw.ey = 0.0f; vw.ez = 0.0f;
    vw.fx = 0.0f; vw.fy = 0.0f; vw.fz = -1.0f;
    vw.rx = 1.0f; vw.ry = 0.0f; vw.rz = 0.0f;
    vw.ux = 0.0f; vw.uy = 1.0f; vw.uz = 0.0f;
    fake.header.num_textures = 0;
    uint32_t verts = 0, calls = 0, parts = 0;
    /* A long life plus a tiny time coefficient pins every particle near the
     * start of its loop, so the field is static and the frame measures fill.
     * `map` is only consulted for the texture (and may be NULL for the
     * built-in glow). */
    emitter_draw_one(map ? map : &fake, &cfg, &vw, &e, pool, 0, 0.0f, &verts, &calls,
                     &parts, additive != 0);
    if (stats) {
        stats->vertices = verts;
        stats->triangles = verts / 3;
        stats->draw_calls = calls;
        stats->particles = parts;
    }
}

/* Lays `count` particles out on a grid covering the 65-degree frustum at the
 * emitter's depth, each one `size` metres tall. */
static void psp_particle_fill_layout(PbmEmitter* e, PbmParticle* pool, int count, float size) {
    int cols = 1;
    while (cols * cols < count) cols++;
    int rows = (count + cols - 1) / cols;
    const float half_h = 2.0f * PBM_EMIT_TAN_HALF;              /* frustum half height at 2 m */
    const float half_w = half_h * (16.0f / 9.0f);
    for (int k = 0; k < count; ++k) {
        PbmParticle* p = &pool[k];
        int col = k % cols, row = k / cols;
        p->dir[0] = p->dir[1] = p->dir[2] = 0.0f;
        p->speed = 0.0f;
        p->spin = 0.0f;
        p->angle0 = 0.0f;
        p->wobble_phase = 0.0f;
        p->anim_offset = 0.0f;
        p->size = size;
        p->life = 1000.0f;
        p->inv_life = 0.001f;
        p->phase = 0.0f;
        p->spawn[0] = -half_w + ((float)col + 0.5f) * (2.0f * half_w / (float)cols);
        p->spawn[1] = -half_h + ((float)row + 0.5f) * (2.0f * half_h / (float)rows);
        p->spawn[2] = 0.0f;
    }
    (void)e;
}

/* Synthetic particle load for the profiler: `count` additive particles of `size`
 * metres in front of the identity-view camera, built through the shipped
 * derivation and evaluator. The map's own emitters play no part, so a probe row
 * is the cost of N particles and nothing else. */
void psp_render_particle_probe(int count, float size, uint32_t color, RenderStats* stats) {
    static PbmEmitter e;
    static PbmParticle pool[PBM_EMIT_MAX_PER_EMITTER];
    static PbmMap fake;
    static RenderCfg cfg;
    static int built = -1;
    if (count < 1) return;
    /* The POOL holds at most one emitter's worth; the REQUEST may be larger and
     * is drawn as several emitters' worth below. Clamping the request itself
     * would silently measure 64 particles while claiming 256. */
    int pool_count = count > PBM_EMIT_MAX_PER_EMITTER ? PBM_EMIT_MAX_PER_EMITTER : count;
    if (!s_sin_ready) pbm_sin_init();
    if (built != pool_count) {
        memset(&e, 0, sizeof(e));
        e.pos[0] = 0.0f; e.pos[1] = 0.0f; e.pos[2] = -2.0f;
        e.dir[0] = 0.0f; e.dir[1] = 1.0f; e.dir[2] = 0.0f;
        e.spread = 0.5f;
        e.speed_min = 0.2f; e.speed_max = 1.2f;
        e.life_min = 1.0f; e.life_max = 1.6f;
        e.gravity[0] = 0.0f; e.gravity[1] = 0.5f; e.gravity[2] = 0.0f;
        e.size_min = size; e.size_max = size * 1.3f;
        e.size_mid = 1.2f; e.size_end = 0.2f;
        e.aspect = 1.0f;
        e.spin_min = -1.2f; e.spin_max = 1.2f;
        e.wobble_amp = 0.05f; e.wobble_freq = 0.6f;
        e.knee = 0.45f;
        e.color_start = color & 0x00FFFFFFu;          /* fade in */
        e.color_mid = color;
        e.color_end = color & 0x00FFFFFFu;            /* fade out */
        e.texture_id = -1;
        e.count = (uint16_t)pool_count;
        e.flags = PBM_EMIT_ADDITIVE;
        e.atlas_cols = 1; e.atlas_rows = 1; e.anim_loops = 1;
        e.seed = 0x51ED2701u;
        pbm_derive_particles(&e, pool, (uint32_t)pool_count);
        render_cfg_default(&cfg);
        built = pool_count;
    }
    EmitView vw;
    vw.ex = 0.0f; vw.ey = 0.0f; vw.ez = 0.0f;
    vw.fx = 0.0f; vw.fy = 0.0f; vw.fz = -1.0f;
    vw.rx = 1.0f; vw.ry = 0.0f; vw.rz = 0.0f;
    vw.ux = 0.0f; vw.uy = 1.0f; vw.uz = 0.0f;
    fake.header.num_textures = 0;
    uint32_t verts = 0, calls = 0, parts = 0;
    /* The pool holds at most one emitter's worth, so a larger request is drawn
     * as several emitters' worth (each batch offset in time, so they are not
     * the same field stacked on itself). That is exactly what N particles of
     * budget spread over several emitters costs in a real map. */
    int remaining = count;
    int batch_index = 0;
    while (remaining > 0) {
        PbmEmitter batch = e;
        if (remaining < (int)e.count) batch.count = (uint16_t)remaining;
        emitter_draw_one(&fake, &cfg, &vw, &batch, pool, 0,
                         1.234f + 0.37f * (float)batch_index, &verts, &calls, &parts, 1);
        remaining -= (int)batch.count;
        batch_index++;
    }
    if (stats) {
        stats->vertices = verts;
        stats->triangles = verts / 3;
        stats->draw_calls = calls;
        stats->particles = parts;
    }
}

static void set_texture_filter(const RenderCfg* cfg) {
    if (cfg->use_mips) {
        /* A *mipmap* minification filter is what actually selects a level; the
         * plain filters ignore the chain entirely. */
        switch (cfg->tex_filter) {
            case PBFILT_NEAREST: sceGuTexFilter(GU_NEAREST_MIPMAP_NEAREST, GU_NEAREST); break;
            case PBFILT_LINEAR:  sceGuTexFilter(GU_LINEAR_MIPMAP_LINEAR, GU_LINEAR); break;   /* trilinear: blends adjacent levels, which is what smooths the level discontinuity between neighbouring tiles */
            case PBFILT_ASYM:    sceGuTexFilter(GU_LINEAR_MIPMAP_NEAREST, GU_NEAREST); break;
            default:             sceGuTexFilter(GU_LINEAR_MIPMAP_NEAREST, GU_LINEAR); break;
        }
        if (cfg->tex_level_mode == PBLEVEL_CONST)
            sceGuTexLevelMode(GU_TEXTURE_CONST, cfg->tex_lod_bias);
        else
            sceGuTexLevelMode(GU_TEXTURE_AUTO, cfg->tex_lod_bias);
        s_lod_mode = cfg->tex_level_mode;
        s_lod_bias = cfg->tex_lod_bias;
        return;
    }
    /* No chain: the level registers keep whatever the last frame left in them,
     * so the cached level state is not the truth any more. */
    s_lod_mode = -1;
    s_lod_bias = LOD_STATE_INVALID;
    switch (cfg->tex_filter) {
        case PBFILT_LINEAR:  sceGuTexFilter(GU_LINEAR, GU_LINEAR); break;
        case PBFILT_NEAREST: sceGuTexFilter(GU_NEAREST, GU_NEAREST); break;
        default:             sceGuTexFilter(GU_LINEAR, GU_NEAREST); break;
    }
}

void psp_render_scene(PbmMap* map, const RenderCfg* cfg,
                      float cx, float cy, float cz, float yaw, float pitch,
                      float time_s, RenderStats* stats) {
    if (stats) { stats->draw_calls = 0; stats->vertices = 0; stats->triangles = 0; stats->particles = 0; }

    /* Clear */
    sceGuClearColor(cfg->clear_color ? cfg->clear_color : 0x382218);
    sceGuClearDepth(65535);
    sceGuClear(GU_COLOR_BUFFER_BIT | GU_DEPTH_BUFFER_BIT);

    if (cfg->fog_enabled) {
        sceGuEnable(GU_FOG);
        sceGuFog(cfg->fog_near, cfg->fog_far, cfg->fog_color);
    } else {
        sceGuDisable(GU_FOG);
    }

    if (cfg->depth_test) {
        sceGuEnable(GU_DEPTH_TEST);
        sceGuDepthFunc(GU_LEQUAL);
        /* Pass 1 may WRITE depth (cfg->depth_write) so later passes can reject
         * against it; off is the shipped default -- see the field's comment in
         * psp_render.h and the depth section of OPTIMIZATION.md. Pass 2 forces
         * the mask off again below, because blended surfaces never write. */
        sceGuDepthMask(cfg->depth_write ? GU_TRUE : GU_FALSE);
    } else {
        sceGuDisable(GU_DEPTH_TEST);
    }
    if (cfg->clip_planes) sceGuEnable(GU_CLIP_PLANES); else sceGuDisable(GU_CLIP_PLANES);

    /* Matrices */
    sceGumMatrixMode(GU_PROJECTION);
    sceGumLoadIdentity();
    sceGumPerspective(65.0f, 16.0f / 9.0f, cfg->near_plane, 200.0f);

    sceGumMatrixMode(GU_VIEW);
    sceGumLoadIdentity();
    ScePspFVector3 eye    = { cx, cy, cz };
    ScePspFVector3 target = {
        cx + sinf(yaw) * cosf(pitch),
        cy + sinf(pitch),
        cz - cosf(yaw) * cosf(pitch)
    };
    ScePspFVector3 up = { 0.0f, 1.0f, 0.0f };
    sceGumLookAt(&eye, &target, &up);

    sceGumMatrixMode(GU_MODEL);
    sceGumLoadIdentity();
    sceGumUpdateMatrix();

    set_texture_filter(cfg);
    sceGuTexFunc(GU_TFX_MODULATE, GU_TCC_RGBA);
    sceGuTexWrap(GU_REPEAT, GU_REPEAT);

    int last_tex_id = -999;
    /* GE texture-offset register state, cached so static meshes emit nothing.
     * The cache starts INVALID on purpose: a display list does not reset GE
     * registers, so the offset left by the previous frame's last animated mesh
     * is still live until something changes it. Starting at 0,0 would skip the
     * first write and paint the whole static scene through that stale offset. */
    float tex_off_u = -1.0f, tex_off_v = -1.0f;
    uint32_t verts = 0, calls = 0, parts = 0;

    /* ── Pass 1: opaque ── */
    sceGuDisable(GU_ALPHA_TEST);
    if (cfg->display_mode == 2) sceGuDisable(GU_BLEND); else sceGuDisable(GU_BLEND);
    if (cfg->display_mode == 2) sceGuDisable(GU_CULL_FACE);
    else if (cfg->cull) sceGuEnable(GU_CULL_FACE); else sceGuDisable(GU_CULL_FACE);

    for (uint32_t mi = 0; mi < map->header.num_meshes; ++mi) {
        PbmMesh* mesh = &map->meshes[mi];
        if (!mesh->vertices || mesh->num_vertices == 0) continue;
        if (is_transparent_mesh(map, mesh)) continue;
        if (s_skip_mesh[0] && strstr(mesh->name, s_skip_mesh)) continue;

        bind_texture(map, cfg, mesh, &last_tex_id);
        apply_mesh_lod(cfg, map, mesh);
        if (cfg->uv_scroll) apply_uv_scroll(map, mesh, time_s, &tex_off_u, &tex_off_v);
        if (cfg->display_mode != 2) {
            if (cfg->cull) sceGuEnable(GU_CULL_FACE); else sceGuDisable(GU_CULL_FACE);
        }
        int prim = (cfg->display_mode == 2) ? GU_LINE_STRIP : GU_TRIANGLES;
        sceGuDrawArray(prim,
            GU_TEXTURE_32BITF | GU_COLOR_8888 | GU_VERTEX_32BITF | GU_TRANSFORM_3D,
            mesh->num_vertices, 0, mesh->vertices);
        verts += mesh->num_vertices;
        calls++;
    }

    /* ── Scripted entity ── */
    float ent_x = 0.0f, ent_y = 0.0f, ent_z = 0.0f;
    if (cfg->entity && map->has_patrol_sphere) {
        if (!s_sphere_initialized)
            init_sphere_mesh(map->patrol_sphere.radius, map->patrol_sphere.color);
        get_patrol_sphere_pos(&map->patrol_sphere, time_s, &ent_x, &ent_y, &ent_z);

        sceGumMatrixMode(GU_MODEL);
        sceGumPushMatrix();
        ScePspFVector3 spos = { ent_x, ent_y, ent_z };
        sceGumTranslate(&spos);
        sceGumUpdateMatrix();

        sceGuDisable(GU_TEXTURE_2D);
        sceGuEnable(GU_CULL_FACE);
        sceGuDrawArray(GU_TRIANGLES,
            GU_TEXTURE_32BITF | GU_COLOR_8888 | GU_VERTEX_32BITF | GU_TRANSFORM_3D,
            NUM_SPHERE_VERTS, 0, s_sphere_verts);
        verts += NUM_SPHERE_VERTS;
        calls++;

        sceGumPopMatrix();
        sceGumUpdateMatrix();
    }

    /* ── Pass 2: alpha (cutouts and blends) ──
     * Alpha test stays on for both kinds: with GU_GREATER,0 it only discards
     * fully transparent fragments, which keeps early-Z rejection working for
     * the blended surfaces too. A CUTOUT raises the threshold, which is what
     * gives foliage its hard silhouette instead of a haze of soft texels. */
    if (cfg->alpha_pass) {
        sceGuEnable(GU_ALPHA_TEST);
        sceGuDepthMask(GU_FALSE);   /* blended/cutout fragments never write depth */
        int cur_alpha_ref = 0x10;
        sceGuAlphaFunc(GU_GREATER, cur_alpha_ref, 0xFF);
        sceGuEnable(GU_BLEND);
        sceGuBlendFunc(GU_ADD, GU_SRC_ALPHA, GU_ONE_MINUS_SRC_ALPHA, 0, 0);
        sceGuDisable(GU_CULL_FACE);

        for (uint32_t mi = 0; mi < map->header.num_meshes; ++mi) {
            PbmMesh* mesh = &map->meshes[mi];
            if (!mesh->vertices || mesh->num_vertices == 0) continue;
            if (!is_transparent_mesh(map, mesh)) continue;
            if (s_skip_mesh[0] && strstr(mesh->name, s_skip_mesh)) continue;

            int want_ref = (mesh_alpha_mode(map, mesh) == PBM_ALPHA_CUTOUT) ? 0x10 : 0x00;
            if (want_ref != cur_alpha_ref) {
                sceGuAlphaFunc(GU_GREATER, want_ref, 0xFF);
                cur_alpha_ref = want_ref;
            }
            bind_texture(map, cfg, mesh, &last_tex_id);
            apply_mesh_lod(cfg, map, mesh);
            if (cfg->uv_scroll) apply_uv_scroll(map, mesh, time_s, &tex_off_u, &tex_off_v);
            int prim = (cfg->display_mode == 2) ? GU_LINE_STRIP : GU_TRIANGLES;
            sceGuDrawArray(prim,
                GU_TEXTURE_32BITF | GU_COLOR_8888 | GU_VERTEX_32BITF | GU_TRANSFORM_3D,
                mesh->num_vertices, 0, mesh->vertices);
            verts += mesh->num_vertices;
            calls++;
        }

        /* ── Particle emitters (standard lump "emitters") ──
         * Blended emitters first, additive second: additive blending is
         * order-independent, so it needs neither a sort nor a place in the
         * scene's back-to-front ordering, and it sits happily on top of the
         * translucent surfaces drawn above. */
        if (cfg->particles && map->num_emitters > 0 && cfg->display_mode != 2) {
            if (!s_sin_ready) pbm_sin_init();
            EmitView vw;
            vw.ex = cx; vw.ey = cy; vw.ez = cz;
            vw.fx = sinf(yaw) * cosf(pitch);
            vw.fy = sinf(pitch);
            vw.fz = -cosf(yaw) * cosf(pitch);
            {
                /* right = normalize(cross(forward, world_up)) */
                float rx = -vw.fz, rz = vw.fx;
                float rl = sqrtf(rx * rx + rz * rz);
                if (rl < 0.0001f) { rx = 1.0f; rz = 0.0f; rl = 1.0f; }
                vw.rx = rx / rl; vw.ry = 0.0f; vw.rz = rz / rl;
                /* up = cross(right, forward) */
                vw.ux = -vw.rz * vw.fy;
                vw.uy = vw.rz * vw.fx - vw.rx * vw.fz;
                vw.uz = vw.rx * vw.fy;
            }
            if (cfg->particles & 1) emitter_pass(map, cfg, &vw, time_s, &verts, &calls, &parts, 0);
            if (cfg->particles & 2) emitter_pass(map, cfg, &vw, time_s, &verts, &calls, &parts, 1);
        }
        sceGuDisable(GU_ALPHA_TEST);
    }

    if (stats) {
        stats->vertices = verts;
        stats->triangles = verts / 3;
        stats->draw_calls = calls;
        stats->particles = parts;
    }
}
