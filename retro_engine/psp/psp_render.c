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
    c->cull = 1;
    c->clip_planes = 1;
    c->alpha_pass = 1;
    c->entity = 1;
    c->uv_scroll = 1;

    c->tex_filter = PBFILT_LINEAR;   /* trilinear: blends adjacent mip levels, which is what removes the level discontinuity between neighbouring tiles at grazing angles */
    /* Mips make distant surfaces cheap but soft, and the hardware picks a level
     * from the geometric mean of the UV derivatives, which over-blurs the
     * compressed axis of a grazing surface. A small negative bias trades a
     * little of that softness back for detail. */
    c->tex_lod_bias = -1.0f;
    c->tex_level_mode = PBLEVEL_AUTO;
    c->force_small_tex = 0;
    c->use_mips = 1;   /* load-time mip chain: the default since it fixes the minified-fetch cost */
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
                  const char* input, int hold_on) {
    char buf[128];
    uint32_t verts = stats ? stats->vertices : 0;
    uint32_t draws = stats ? stats->draw_calls : 0;

    snprintf(buf, sizeof(buf), "FPS: %4.1f | Tris: %u | Verts: %u | Draws: %u",
             fps, (unsigned)(verts / 3), (unsigned)verts, (unsigned)draws);
    psp_draw_text(8.0f, 8.0f, 0xFF00FF55, buf);

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
     * on any map with one they were invisible and the controls looked missing. */
    psp_draw_text(8.0f, 38.0f, 0xFFDDDDDD,
                  "Stick: Fly/Strafe | Hold Tri+Stick: Look | Square: Boost");
    snprintf(buf, sizeof(buf),
             "X/O: Up/Down | L/R: Turn | Start: Reset | Select: Mode | Tri+L/R: Env");
    psp_draw_text(8.0f, 48.0f, 0xFFDDDDDD, buf);

    if (extra && *extra) psp_draw_text(8.0f, 58.0f, 0xFF66E0FF, extra);
    if (extra2 && *extra2) psp_draw_text(8.0f, 68.0f, 0xFF8888FF, extra2);
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
        else if (!strcmp(k, "preset")) render_cfg_set_env(cfg, v);
        else if (!strcmp(k, "bias")) cfg->tex_lod_bias = (float)atof(v);
        else if (!strcmp(k, "mips"))   cfg->use_mips = atoi(v);
        else if (!strcmp(k, "skip_mesh")) psp_render_skip_mesh(v);
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
                if (cfg->use_mips && tex->num_levels > 1) {
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
        return;
    }
    switch (cfg->tex_filter) {
        case PBFILT_LINEAR:  sceGuTexFilter(GU_LINEAR, GU_LINEAR); break;
        case PBFILT_NEAREST: sceGuTexFilter(GU_NEAREST, GU_NEAREST); break;
        default:             sceGuTexFilter(GU_LINEAR, GU_NEAREST); break;
    }
}

void psp_render_scene(PbmMap* map, const RenderCfg* cfg,
                      float cx, float cy, float cz, float yaw, float pitch,
                      float time_s, RenderStats* stats) {
    if (stats) { stats->draw_calls = 0; stats->vertices = 0; stats->triangles = 0; }

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
        sceGuDepthMask(GU_FALSE);
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
    uint32_t verts = 0, calls = 0;

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
            if (cfg->uv_scroll) apply_uv_scroll(map, mesh, time_s, &tex_off_u, &tex_off_v);
            int prim = (cfg->display_mode == 2) ? GU_LINE_STRIP : GU_TRIANGLES;
            sceGuDrawArray(prim,
                GU_TEXTURE_32BITF | GU_COLOR_8888 | GU_VERTEX_32BITF | GU_TRANSFORM_3D,
                mesh->num_vertices, 0, mesh->vertices);
            verts += mesh->num_vertices;
            calls++;
        }
        sceGuDisable(GU_ALPHA_TEST);
    }

    if (stats) {
        stats->vertices = verts;
        stats->triangles = verts / 3;
        stats->draw_calls = calls;
    }
}
