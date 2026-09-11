#include "pbm_loader.h"
#include <stdio.h>
#include <stdlib.h>
#include <malloc.h>
#ifdef __PSP__
#include <psputils.h>
#include <pspkernel.h>
#endif
#include <string.h>
#include <math.h>
#include <stdarg.h>
/* Swizzles a 16-bit texture into 16-byte wide x 8-line high blocks for Sony GE texture cache */
static void swizzle_texture_16(uint8_t* out, const uint8_t* in, unsigned int width, unsigned int height) {
    unsigned int width_bytes = width * 2;
    unsigned int width_blocks = width_bytes / 16;
    unsigned int height_blocks = height / 8;
    unsigned int src_pitch = (width_bytes - 16) / 4;
    unsigned int src_row = width_bytes * 8;
    const uint8_t* ysrc = in;
    uint32_t* dst = (uint32_t*)out;
    const uint32_t* xsrc;

    for (unsigned int blocky = 0; blocky < height_blocks; ++blocky) {
        const uint8_t* xsrc_b = ysrc;
        for (unsigned int blockx = 0; blockx < width_blocks; ++blockx) {
            xsrc = (const uint32_t*)xsrc_b;
            for (unsigned int j = 0; j < 8; ++j) {
                *(dst++) = *(xsrc++);
                *(dst++) = *(xsrc++);
                *(dst++) = *(xsrc++);
                *(dst++) = *(xsrc++);
                xsrc += src_pitch;
            }
            xsrc_b += 16;
        }
        ysrc += src_row;
    }
}

/* ── Mip chain ────────────────────────────────────────────────────────────
 * Every base material in an exported map tiles a 512x512 texture across a
 * metre of surface, so almost every visible texel is minified: a floor seen at
 * a grazing angle puts adjacent screen pixels tens of texels apart. With no
 * mip chain and a 4-tap LINEAR minification filter the GE's ~8 KB texture
 * cache misses on essentially every fragment, and each miss is a main-memory
 * round trip. Downsampling the chain and sampling it with a mipmap filter
 * keeps the fetch footprint at roughly one texel per pixel.
 *
 * The chain stops at 16x16: below that a 16-bit level is narrower than the
 * GE's 16-byte swizzle block and the layout is no longer worth the risk, and
 * 16x16 is already 1/32 of the base linear scale.
 *
 * Alpha textures are deliberately left alone. Their alpha is 1 bit, so box
 * filtering turns any level where fewer than half the texels are opaque fully
 * transparent — the classic cutout-foliage disappearance. Billboards cover
 * little screen area, so they keep their crisp level 0. */
static inline void unpack5551(uint16_t p, int* r, int* g, int* b, int* a) {
    *r = p & 0x1F;
    *g = (p >> 5) & 0x1F;
    *b = (p >> 10) & 0x1F;
    *a = (p >> 15) & 1;
}

static inline uint16_t pack5551(int r, int g, int b, int a) {
    if (r > 31) r = 31;
    if (g > 31) g = 31;
    if (b > 31) b = 31;
    return (uint16_t)(((a ? 1 : 0) << 15) | (b << 10) | (g << 5) | r);
}

/* 2x2 box filter. Weighting RGB by alpha keeps cutout edges from darkening.
 * `alpha_max` picks how the 1-bit alpha combines: 0 == majority (a soft edge
 * stays soft), 1 == ANY opaque sample keeps the texel opaque. The second mode
 * is what lets a CUTOUT keep a mip chain at all: averaging a 1-bit alpha
 * erodes the silhouette away by the fourth level, which is why cutout textures
 * used to ship with no chain — and therefore paid a texture-cache miss per
 * fragment on art that is 256x512 to 512x512. Max-alpha dilates the silhouette
 * by half a texel per level instead, which is what the eye expects as foliage
 * recedes, and it lets the chain collapse the fetch footprint like every other
 * texture. */
static void downsample_5551(uint16_t* dst, const uint16_t* src, int sw, int sh, int alpha_max) {
    int dw = sw >> 1, dh = sh >> 1;
    for (int y = 0; y < dh; ++y) {
        for (int x = 0; x < dw; ++x) {
            int r = 0, g = 0, b = 0, a = 0, wsum = 0;
            for (int k = 0; k < 4; ++k) {
                int sx = 2 * x + (k & 1);
                int sy = 2 * y + (k >> 1);
                int sr, sg, sb, sa;
                unpack5551(src[sy * sw + sx], &sr, &sg, &sb, &sa);
                int w = sa + 1;
                r += sr * w; g += sg * w; b += sb * w;
                wsum += w;
                a += sa;
            }
            if (wsum < 1) wsum = 1;
            int out_a = alpha_max ? (a > 0) : (a >= 2);
            dst[y * dw + x] = pack5551(r / wsum, g / wsum, b / wsum, out_a);
        }
    }
}

/* 2x2 box filter for the 32-bit path. A blend texture carries an 8-bit alpha
 * ramp, and averaging is exactly what a mip level of a soft alpha edge should
 * be; RGB is alpha-weighted so a fading edge does not darken as it shrinks. */
static void downsample_8888(uint32_t* dst, const uint32_t* src, int sw, int sh) {
    int dw = sw >> 1, dh = sh >> 1;
    for (int y = 0; y < dh; ++y) {
        for (int x = 0; x < dw; ++x) {
            int r = 0, g = 0, b = 0, a = 0, wsum = 0;
            for (int k = 0; k < 4; ++k) {
                uint32_t p = src[(2 * y + (k >> 1)) * sw + (2 * x + (k & 1))];
                int sa = (int)((p >> 24) & 0xFF);
                int w = sa + 1;
                r += (int)(p & 0xFF) * w;
                g += (int)((p >> 8) & 0xFF) * w;
                b += (int)((p >> 16) & 0xFF) * w;
                a += sa;
                wsum += w;
            }
            if (wsum < 1) wsum = 1;
            dst[y * dw + x] = (uint32_t)(r / wsum) | ((uint32_t)(g / wsum) << 8) |
                              ((uint32_t)(b / wsum) << 16) | ((uint32_t)(a >> 2) << 24);
        }
    }
}

/* Load diagnostics go both to the on-device debug screen and to a file on the
 * host (host0: when running under PSPLink, else the memory stick). A map that
 * fails to load must never be a silent black screen. */
static void pbm_log(const char* fmt, ...) {
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    printf("%s", buf);

    FILE* lf = fopen("host0:/pbm_load.log", "a");
    if (!lf) lf = fopen("ms0:/pbm_load.log", "a");
    if (lf) { fputs(buf, lf); fclose(lf); }
}

#ifdef __PSP__
/* Heap pressure is the difference between a map that loads and one that comes
 * up empty, so record it around every load. */
static void pbm_log_mem(const char* tag) {
    pbm_log("[PBM] mem %-12s total_free=%u max_free=%u\n", tag,
            (unsigned)sceKernelTotalFreeMemSize(), (unsigned)sceKernelMaxFreeMemSize());
}
#else
static void pbm_log_mem(const char* tag) { (void)tag; }
#endif

/* ── Particle emitters (standard lump "emitters") ─────────────────────────
 * The lump carries only the emitters. The PER-PARTICLE constants are derived
 * here, once, because they never change for the life of the map: an emitter is
 * a looping, stateless stream, so particle i's state at time t is a closed
 * form of (t, i, seed) and nothing has to be stored per frame. Two runtimes
 * that implement pbm_rand() (pbm.h) identically produce the same particle
 * field, which is what lets the format promise a reproducible look. */
static inline float pbm_lerpf(float a, float b, float t) { return a + (b - a) * t; }

/* Clamp that also swallows NaN (a NaN would otherwise reach the GE as a
 * degenerate vertex, which is much harder to diagnose than a clamped value). */
static inline float pbm_clampf(float v, float lo, float hi) {
    if (!(v > lo)) return lo;
    return v > hi ? hi : v;
}

static void pbm_emitters_release(PbmMap* map) {
    free(map->emitters);              map->emitters = NULL;
    free(map->particles);             map->particles = NULL;
    free(map->emitter_first_particle);map->emitter_first_particle = NULL;
    free(map->emitter_cull_radius);   map->emitter_cull_radius = NULL;
    map->num_emitters = 0;
    map->num_particles = 0;
}

/* Derives `n` per-particle constants for one emitter into `out`. Public: the
 * profiler's synthetic particle probe drives the SAME derivation the loader
 * does, so what it measures is the shipped code path and not a copy of it. */
void pbm_derive_particles(const PbmEmitter* e, PbmParticle* out, uint32_t n) {
    const float ax = e->dir[0], ay = e->dir[1], az = e->dir[2];
    float t1x, t1y, t1z, t2x, t2y, t2z;
    /* An arbitrary basis perpendicular to the emission axis. */
    if (fabsf(ay) < 0.9f) { t1x = -az; t1y = 0.0f; t1z = ax; }
    else                  { t1x = 0.0f; t1y = az;  t1z = -ay; }
    {
        float l = sqrtf(t1x * t1x + t1y * t1y + t1z * t1z);
        if (!(l > 0.0001f)) { t1x = 1.0f; t1y = 0.0f; t1z = 0.0f; l = 1.0f; }
        t1x /= l; t1y /= l; t1z /= l;
    }
    t2x = ay * t1z - az * t1y;
    t2y = az * t1x - ax * t1z;
    t2z = ax * t1y - ay * t1x;

    const float inv_n = 1.0f / (float)n;
    for (uint32_t k = 0; k < n; ++k) {
        PbmParticle* p = &out[k];
        p->life = pbm_lerpf(e->life_min, e->life_max, pbm_rand(e->seed, k, 0));
        if (!(p->life > 0.0001f)) p->life = 0.0001f;
        p->inv_life = 1.0f / p->life;
        /* Even phase slots + in-slot jitter: a continuous stream that never
         * looks like the same handful of particles on a metronome, and never
         * has them all in lockstep either. A PHASE_ALIGN emitter skips the
         * spread entirely and becomes a repeating burst. */
        if (e->flags & PBM_EMIT_PHASE_ALIGN) {
            p->phase = 0.0f;
        } else {
            float ph = (float)k * inv_n + pbm_rand(e->seed, k, 1) * inv_n;
            p->phase = ph - floorf(ph);
        }
        p->speed = pbm_lerpf(e->speed_min, e->speed_max, pbm_rand(e->seed, k, 2));
        p->size = pbm_lerpf(e->size_min, e->size_max, pbm_rand(e->seed, k, 3));
        p->spin = pbm_lerpf(e->spin_min, e->spin_max, pbm_rand(e->seed, k, 4));
        p->angle0 = pbm_lerpf(e->angle_min, e->angle_max, pbm_rand(e->seed, k, 12));
        p->wobble_phase = pbm_rand(e->seed, k, 5) * 6.28318530718f;
        p->anim_offset = pbm_rand(e->seed, k, 6);
        /* Direction: uniform in the emission cone. The polar sample is linear in
         * the angle (not in solid angle) because that is what reads as an even
         * spread to the eye at the angles particle cones use. */
        {
            float theta = e->spread * sqrtf(pbm_rand(e->seed, k, 7));
            float phi = pbm_rand(e->seed, k, 8) * 6.28318530718f;
            float st = sinf(theta), ct = cosf(theta);
            float cp = cosf(phi), sp = sinf(phi);
            p->dir[0] = ax * ct + (t1x * cp + t2x * sp) * st;
            p->dir[1] = ay * ct + (t1y * cp + t2y * sp) * st;
            p->dir[2] = az * ct + (t1z * cp + t2z * sp) * st;
        }
        if (e->spawn_radius > 0.0f) {
            float u = pbm_rand(e->seed, k, 9);
            float v = pbm_rand(e->seed, k, 10);
            float rad = e->spawn_radius * cbrtf(u);   /* cbrt: uniform inside the ball */
            float cz = 2.0f * v - 1.0f;
            float sz = sqrtf(fmaxf(0.0f, 1.0f - cz * cz));
            float ang = pbm_rand(e->seed, k, 11) * 6.28318530718f;
            p->spawn[0] = rad * sz * cosf(ang);
            p->spawn[1] = rad * sz * sinf(ang);
            p->spawn[2] = rad * cz;
        } else {
            p->spawn[0] = p->spawn[1] = p->spawn[2] = 0.0f;
        }
    }
}

static void pbm_build_emitters(PbmMap* map, const void* data, uint32_t size) {
    if (size < PBM_EMITTER_LUMP_HDR) {
        pbm_log("[PBM] WARN: 'emitters' lump is %u bytes, shorter than its %u-byte header; ignored\n",
                (unsigned)size, (unsigned)PBM_EMITTER_LUMP_HDR);
        return;
    }
    const PbmEmitterLumpHeader* hdr = (const PbmEmitterLumpHeader*)data;
    if (hdr->magic != PBM_EMITTER_MAGIC) {
        pbm_log("[PBM] WARN: 'emitters' lump magic 0x%08X is not EMIT; ignored\n", (unsigned)hdr->magic);
        return;
    }
    if (hdr->version > PBM_EMITTER_VERSION) {
        pbm_log("[PBM] WARN: 'emitters' lump version %u is newer than %u; ignored\n",
                (unsigned)hdr->version, (unsigned)PBM_EMITTER_VERSION);
        return;
    }
    uint32_t count = hdr->count;
    if (count == 0) return;
    if ((uint64_t)PBM_EMITTER_LUMP_HDR + (uint64_t)count * PBM_EMITTER_SIZE > (uint64_t)size) {
        pbm_log("[PBM] WARN: 'emitters' lump claims %u records but carries only %u bytes; ignored\n",
                (unsigned)count, (unsigned)size);
        return;
    }
    if (count > PBM_EMIT_MAX_EMITTERS) {
        pbm_log("[PBM] WARN: %u emitters in file, runtime supports %u; the rest are skipped\n",
                (unsigned)count, (unsigned)PBM_EMIT_MAX_EMITTERS);
        count = PBM_EMIT_MAX_EMITTERS;
    }

    map->emitters = (PbmEmitter*)calloc(count, sizeof(PbmEmitter));
    map->emitter_first_particle = (uint32_t*)calloc(count + 1, sizeof(uint32_t));
    map->emitter_cull_radius = (float*)calloc(count, sizeof(float));
    map->particles = (PbmParticle*)calloc(PBM_EMIT_MAX_TOTAL_PARTICLES, sizeof(PbmParticle));
    if (!map->emitters || !map->emitter_first_particle || !map->emitter_cull_radius || !map->particles) {
        pbm_log("[PBM] WARN: out of memory for the emitter records; particles disabled\n");
        pbm_emitters_release(map);
        return;
    }

    const uint8_t* base = (const uint8_t*)data + PBM_EMITTER_LUMP_HDR;
    uint32_t total = 0;
    uint32_t live = 0;
    for (uint32_t i = 0; i < count; ++i) {
        const PbmEmitter* src = (const PbmEmitter*)(base + (size_t)i * PBM_EMITTER_SIZE);
        PbmEmitter* e = &map->emitters[live];
        memcpy(e, src, sizeof(PbmEmitter));
        e->name[sizeof(e->name) - 1] = '\0';
        e->name[23] = '\0';

        /* ── Sanitize. A malformed record must degrade, not print NaNs. ── */
        e->life_min = pbm_clampf(e->life_min, 0.01f, 600.0f);
        e->life_max = pbm_clampf(e->life_max, e->life_min, 600.0f);
        e->speed_min = pbm_clampf(e->speed_min, -200.0f, 200.0f);
        e->speed_max = pbm_clampf(e->speed_max, e->speed_min, 200.0f);
        e->size_min = pbm_clampf(e->size_min, 0.0005f, 200.0f);
        e->size_mid = pbm_clampf(e->size_mid, 0.0f, 64.0f);
        e->size_end = pbm_clampf(e->size_end, 0.0f, 64.0f);
        e->spin_min = pbm_clampf(e->spin_min, -64.0f, 64.0f);
        e->spin_max = pbm_clampf(e->spin_max, e->spin_min, 64.0f);
        e->wobble_amp = pbm_clampf(e->wobble_amp, 0.0f, 100.0f);
        e->wobble_freq = pbm_clampf(e->wobble_freq, 0.0f, 64.0f);
        e->spawn_radius = pbm_clampf(e->spawn_radius, 0.0f, 200.0f);
        e->damping = pbm_clampf(e->damping, 0.0f, 32.0f);
        e->aspect = pbm_clampf(e->aspect, 0.01f, 64.0f);
        e->angle_min = pbm_clampf(e->angle_min, -6.2831853f, 6.2831853f);
        e->angle_max = pbm_clampf(e->angle_max, e->angle_min, 6.2831853f);
        e->knee = pbm_clampf(e->knee, 0.05f, 0.95f);
        e->spread = pbm_clampf(e->spread, 0.0f, 3.14159265f);
        if (e->atlas_cols < 1) e->atlas_cols = 1;
        if (e->atlas_cols > 16) e->atlas_cols = 16;
        if (e->atlas_rows < 1) e->atlas_rows = 1;
        if (e->atlas_rows > 16) e->atlas_rows = 16;
        if (e->anim_loops < 1) e->anim_loops = 1;
        if (e->anim_loops > 16) e->anim_loops = 16;
        if (e->texture_id >= (int32_t)map->header.num_textures) {
            pbm_log("[PBM] WARN: emitter '%s' references texture %d of %u; using the built-in glow\n",
                    e->name, (int)e->texture_id, (unsigned)map->header.num_textures);
            e->texture_id = -1;
        }
        {
            float dl = sqrtf(e->dir[0] * e->dir[0] + e->dir[1] * e->dir[1] + e->dir[2] * e->dir[2]);
            if (!(dl > 0.0001f)) { e->dir[0] = 0.0f; e->dir[1] = 1.0f; e->dir[2] = 0.0f; dl = 1.0f; }
            e->dir[0] /= dl; e->dir[1] /= dl; e->dir[2] /= dl;
        }

        /* ── Particle budget: per emitter, and across the whole map. ── */
        uint32_t n = e->count;
        if (n > PBM_EMIT_MAX_PER_EMITTER) {
            pbm_log("[PBM] WARN: emitter '%s' asks for %u particles, the runtime caps one emitter at %u\n",
                    e->name, (unsigned)n, (unsigned)PBM_EMIT_MAX_PER_EMITTER);
            n = PBM_EMIT_MAX_PER_EMITTER;
        }
        if (n > PBM_EMIT_MAX_TOTAL_PARTICLES - total) n = PBM_EMIT_MAX_TOTAL_PARTICLES - total;
        e->count = (uint16_t)n;

        map->emitter_first_particle[live] = total;
        map->emitter_first_particle[live + 1] = total + n;

        /* ── Derive the per-particle constants. ── */
        pbm_derive_particles(e, &map->particles[total], n);
        total += n;

        /* Bounding sphere for the per-frame cull. Conservative: it ignores
         * damping (which only ever pulls particles back in) and assumes the
         * whole size range can be reached. */
        {
            float g = sqrtf(e->gravity[0] * e->gravity[0] + e->gravity[1] * e->gravity[1] +
                            e->gravity[2] * e->gravity[2]);
            float big = fmaxf(1.0f, fmaxf(e->size_mid, e->size_end));
            float reach = e->spawn_radius + e->wobble_amp + e->size_max * 0.5f * big * 1.45f +
                          fabsf(e->speed_max) * e->life_max * 1.05f +
                          0.5f * g * e->life_max * e->life_max * 1.05f;
            map->emitter_cull_radius[live] = reach * 1.1f + 0.05f;
        }
        live++;
    }

    map->num_emitters = live;
    map->num_particles = total;
    map->emitter_first_particle[live] = total;
    pbm_log("[PBM] Emitters: %u emitters, %u particles (lump v%u)\n",
            (unsigned)live, (unsigned)total, (unsigned)hdr->version);
}

PbmMap* pbm_load(const char* filepath) {
    FILE* f = fopen(filepath, "rb");
    if (!f) {
        printf("[PBM] Error: Could not open '%s'\n", filepath);
        return NULL;
    }

    pbm_log_mem("before load");

    PbmMap* map = (PbmMap*)calloc(1, sizeof(PbmMap));
    if (!map) {
        fclose(f);
        return NULL;
    }

    /* First read 4-byte magic to identify format generation */
    uint32_t magic = 0;
    if (fread(&magic, sizeof(uint32_t), 1, f) != 1) {
        printf("[PBM] Error: Failed to read magic header\n");
        free(map);
        fclose(f);
        return NULL;
    }

    /* Validate Magic */
    if (magic != PBM_MAGIC && magic != PBM_MAGIC_V2 && magic != PBM_MAGIC_V1) {
        printf("[PBM] Error: Invalid magic 0x%08X (expected 'PBM3' 0x%08X, 'PBM2' 0x%08X or 'PBM1' 0x%08X)\n",
            (unsigned int)magic, (unsigned int)PBM_MAGIC,
            (unsigned int)PBM_MAGIC_V2, (unsigned int)PBM_MAGIC_V1);
        free(map);
        fclose(f);
        return NULL;
    }

    uint32_t version = 0;
    if (fread(&version, sizeof(uint32_t), 1, f) != 1) {
        printf("[PBM] Error: Failed to read format version\n");
        free(map);
        fclose(f);
        return NULL;
    }

    /* Version breaking change detection & diagnostic */
    if (version > PBM_MAX_SUPPORTED) {
        printf("[PBM] Error: Incompatible map version %u! (Loader supports up to v%u).\n"
               "[PBM] FATAL: Breaking format change detected. Please re-export or update loader.\n",
               (unsigned int)version, (unsigned int)PBM_MAX_SUPPORTED);
        free(map);
        fclose(f);
        return NULL;
    }
    if (version < PBM_MIN_SUPPORTED) {
        printf("[PBM] Error: Obsolete map version %u! (Minimum supported is v%u).\n",
               (unsigned int)version, (unsigned int)PBM_MIN_SUPPORTED);
        free(map);
        fclose(f);
        return NULL;
    }

    map->header.magic = magic;
    map->header.version = version;

    if (version == 1) {
        /* Legacy v1 Header: 60 bytes total (magic + version already read = 52 bytes remain) */
        struct __attribute__((packed)) {
            uint32_t num_textures;
            uint32_t num_meshes;
            uint32_t num_colliders;
            float spawn_pos[3];
            float spawn_rot;
            float bounds_min[3];
            float bounds_max[3];
        } v1_hdr;
        if (fread(&v1_hdr, sizeof(v1_hdr), 1, f) != 1) {
            printf("[PBM] Error reading v1 header body\n");
            free(map);
            fclose(f);
            return NULL;
        }
        map->header.num_textures = v1_hdr.num_textures;
        map->header.num_meshes = v1_hdr.num_meshes;
        map->header.num_colliders = v1_hdr.num_colliders;
        map->header.num_metadata = 0;
        memcpy(map->header.spawn_pos, v1_hdr.spawn_pos, sizeof(float) * 3);
        map->header.spawn_rot = v1_hdr.spawn_rot;
        memcpy(map->header.bounds_min, v1_hdr.bounds_min, sizeof(float) * 3);
        memcpy(map->header.bounds_max, v1_hdr.bounds_max, sizeof(float) * 3);
    } else {
        /* Modern v2 Header: 64 bytes total (magic + version already read = 56 bytes remain) */
        struct __attribute__((packed)) {
            uint32_t num_textures;
            uint32_t num_meshes;
            uint32_t num_colliders;
            uint32_t num_metadata;
            float spawn_pos[3];
            float spawn_rot;
            float bounds_min[3];
            float bounds_max[3];
        } v2_hdr;
        if (fread(&v2_hdr, sizeof(v2_hdr), 1, f) != 1) {
            printf("[PBM] Error reading v2 header body\n");
            free(map);
            fclose(f);
            return NULL;
        }
        map->header.num_textures = v2_hdr.num_textures;
        map->header.num_meshes = v2_hdr.num_meshes;
        map->header.num_colliders = v2_hdr.num_colliders;
        map->header.num_metadata = v2_hdr.num_metadata;
        memcpy(map->header.spawn_pos, v2_hdr.spawn_pos, sizeof(float) * 3);
        map->header.spawn_rot = v2_hdr.spawn_rot;
        memcpy(map->header.bounds_min, v2_hdr.bounds_min, sizeof(float) * 3);
        memcpy(map->header.bounds_max, v2_hdr.bounds_max, sizeof(float) * 3);
    }

    pbm_log("[PBM] Loaded header v%u: %u textures, %u meshes, %u colliders, %u metadata\n",
        (unsigned int)map->header.version,
        (unsigned int)map->header.num_textures,
        (unsigned int)map->header.num_meshes,
        (unsigned int)map->header.num_colliders,
        (unsigned int)map->header.num_metadata);
    strncpy(map->map_name, "PoiRetro Map", sizeof(map->map_name) - 1);
    map->has_patrol_sphere = 0;
    map->env_preset[0] = '\0';
    /* 1. Textures */
    if (map->header.num_textures > 0) {
        map->textures = (PbmTexture*)calloc(map->header.num_textures, sizeof(PbmTexture));
        for (uint32_t i = 0; i < map->header.num_textures; ++i) {
            PbmTextureHeader thdr;
            if (fread(&thdr, sizeof(PbmTextureHeader), 1, f) != 1) {
                printf("[PBM] Error reading texture header %u\n", (unsigned int)i);
                break;
            }
            memcpy(map->textures[i].name, thdr.name, 32);
            map->textures[i].width = thdr.width;
            map->textures[i].height = thdr.height;
            map->textures[i].format = thdr.format;
            map->textures[i].alpha_mode = thdr.alpha_mode;
            map->textures[i].data_size = thdr.data_size;

            PbmTexture* tex = &map->textures[i];
            tex->pixels = NULL;
            tex->num_levels = 0;
            tex->is_swizzled = 0;

            uint8_t* linear = (uint8_t*)malloc(thdr.data_size);
            if (!linear) {
                pbm_log("[PBM] FATAL: out of memory for texture %u (%u bytes)\n",
                        (unsigned int)i, (unsigned)thdr.data_size);
                goto load_failed;
            }
            if (fread(linear, 1, thdr.data_size, f) != thdr.data_size) {
                pbm_log("[PBM] FATAL: short read on texture %u data\n", (unsigned int)i);
                free(linear);
                goto load_failed;
            }

            int pot16 = (thdr.format == PBM_TEX_FMT_RGBA5551) &&
                        thdr.width >= 16 && thdr.height >= 8 &&
                        (thdr.width & (thdr.width - 1)) == 0 &&
                        (thdr.height & (thdr.height - 1)) == 0;

            if (pot16) {
                int lw[PBM_MAX_MIP_LEVELS], lh[PBM_MAX_MIP_LEVELS];
                const uint16_t* src[PBM_MAX_MIP_LEVELS];
                int built = 1;
                lw[0] = thdr.width;
                lh[0] = thdr.height;
                src[0] = (const uint16_t*)linear;

                /* Mip chains for every 16-bit texture, cutouts included. Only
                 * the alpha combine differs (see downsample_5551): averaging
                 * erodes a 1-bit silhouette, so cutouts take ANY-opaque-wins
                 * instead. The footprint argument is identical — foliage
                 * sprites are 256x512 to 512x512 and sampled minified, so
                 * without a chain they pay a texture-cache miss per fragment
                 * and shimmer at distance. `mips=0` in poi_render.txt is the
                 * A/B against the old level-0-only behaviour. */
                {
                    int alpha_max = (thdr.alpha_mode == PBM_ALPHA_CUTOUT) ? 1 : 0;
                    while (built < PBM_MAX_MIP_LEVELS && lw[built - 1] >= 32 && lh[built - 1] >= 32) {
                        int pw = lw[built - 1] >> 1, ph = lh[built - 1] >> 1;
                        uint16_t* lvl = (uint16_t*)malloc((size_t)pw * ph * 2);
                        if (!lvl) break;
                        downsample_5551(lvl, src[built - 1], lw[built - 1], lh[built - 1], alpha_max);
                        src[built] = lvl;
                        lw[built] = pw;
                        lh[built] = ph;
                        built++;
                    }
                }

                int done = 0;
                for (; done < built; ++done) {
                    uint32_t sz = (uint32_t)lw[done] * lh[done] * 2;
                    void* dst = memalign(64, sz);
                    if (!dst) break;
                    swizzle_texture_16((uint8_t*)dst, (const uint8_t*)src[done], lw[done], lh[done]);
                    tex->level_w[done] = (uint16_t)lw[done];
                    tex->level_h[done] = (uint16_t)lh[done];
                    tex->level_ptr[done] = dst;
                }
                for (int k = 1; k < built; ++k) free((void*)src[k]);
                if (done > 0) {
                    tex->num_levels = done;
                    tex->pixels = tex->level_ptr[0];
                    tex->is_swizzled = 1;
                }
            } else if (thdr.format == PBM_TEX_FMT_RGBA8888 &&
                       thdr.alpha_mode == PBM_ALPHA_BLEND &&
                       thdr.width >= 16 && thdr.height >= 16 &&
                       (thdr.width & (thdr.width - 1)) == 0 &&
                       (thdr.height & (thdr.height - 1)) == 0) {
                /* 32-bit blend textures get an UNswizzled mip chain: the 16-bit
                 * swizzle layout does not apply, and the GE takes one base/size
                 * register per level, so a linear chain is legal and still
                 * collapses the minified fetch footprint. Soft alpha needs the
                 * 8 bits per channel that 5551 cannot carry. */
                int lw[PBM_MAX_MIP_LEVELS];
                int lh[PBM_MAX_MIP_LEVELS];
                const uint32_t* src[PBM_MAX_MIP_LEVELS];
                int built = 1;
                lw[0] = thdr.width;
                lh[0] = thdr.height;
                src[0] = (const uint32_t*)linear;
                while (built < PBM_MAX_MIP_LEVELS && lw[built - 1] >= 16 && lh[built - 1] >= 16) {
                    int pw = lw[built - 1] >> 1, ph = lh[built - 1] >> 1;
                    uint32_t* lvl = (uint32_t*)malloc((size_t)pw * ph * 4);
                    if (!lvl) break;
                    downsample_8888(lvl, src[built - 1], lw[built - 1], lh[built - 1]);
                    src[built] = lvl;
                    lw[built] = pw;
                    lh[built] = ph;
                    built++;
                }
                int done = 0;
                for (; done < built; ++done) {
                    uint32_t sz = (uint32_t)lw[done] * lh[done] * 4;
                    void* dst = memalign(16, sz);
                    if (!dst) break;
                    memcpy(dst, src[done], sz);
                    tex->level_w[done] = (uint16_t)lw[done];
                    tex->level_h[done] = (uint16_t)lh[done];
                    tex->level_ptr[done] = dst;
                }
                for (int k = 1; k < built; ++k) free((void*)src[k]);
                if (done > 0) {
                    tex->num_levels = done;
                    tex->pixels = tex->level_ptr[0];
                    tex->is_swizzled = 0;
                }
            } else {
                void* pixels = memalign(16, thdr.data_size);
                if (!pixels) pixels = malloc(thdr.data_size);
                if (pixels) {
                    memcpy(pixels, linear, thdr.data_size);
                    tex->pixels = pixels;
                    tex->num_levels = 1;
                    tex->level_w[0] = thdr.width;
                    tex->level_h[0] = thdr.height;
                    tex->level_ptr[0] = pixels;
                }
            }
            free(linear);
        }
    }

    /* 2. Meshes */
    map->total_vertices = 0;
    uint32_t animated_meshes = 0;
    if (map->header.num_meshes > 0) {
        map->meshes = (PbmMesh*)calloc(map->header.num_meshes, sizeof(PbmMesh));
        for (uint32_t i = 0; i < map->header.num_meshes; ++i) {
            PbmMeshHeader mhdr;
            memset(&mhdr, 0, sizeof(mhdr));
            /* v3 grew the mesh header by the two UV-scroll words; v1/v2 files
             * end where uv_scroll_u would begin, so read exactly that much and
             * leave the scroll at zero (their meshes are static by definition). */
            size_t hdr_size = (map->header.version >= 3)
                ? sizeof(PbmMeshHeader) : (size_t)PBM_MESH_HEADER_V2;
            if (fread(&mhdr, hdr_size, 1, f) != 1) {
                pbm_log("[PBM] FATAL: short read on mesh header %u\n", (unsigned int)i);
                goto load_failed;
            }
            memcpy(map->meshes[i].name, mhdr.name, 32);
            map->meshes[i].texture_id = mhdr.texture_id;
            map->meshes[i].num_vertices = mhdr.num_vertices;
            memcpy(map->meshes[i].bounds_min, mhdr.bounds_min, sizeof(float) * 3);
            memcpy(map->meshes[i].bounds_max, mhdr.bounds_max, sizeof(float) * 3);
            map->meshes[i].uv_scroll_u = mhdr.uv_scroll_u;
            map->meshes[i].uv_scroll_v = mhdr.uv_scroll_v;
            if (mhdr.uv_scroll_u != 0.0f || mhdr.uv_scroll_v != 0.0f) {
                animated_meshes++;
                if (map->meshes[i].texture_id < 0) {
                    pbm_log("[PBM] Warning: mesh '%s' scrolls but has no texture; "
                            "the offset will be ignored.\n", map->meshes[i].name);
                }
            }
            map->total_vertices += mhdr.num_vertices;

            uint32_t vbuf_size = mhdr.num_vertices * sizeof(PbmVertex);
            void* vbuf = memalign(16, vbuf_size);
            if (!vbuf) {
                vbuf = malloc(vbuf_size);
            }
            if (!vbuf) {
                pbm_log("[PBM] FATAL: out of memory for mesh %u vertices (%u bytes)\n",
                        (unsigned int)i, (unsigned)vbuf_size);
                goto load_failed;
            }
            if (fread(vbuf, 1, vbuf_size, f) != vbuf_size) {
                pbm_log("[PBM] FATAL: short read on mesh %u vertices\n", (unsigned int)i);
                free(vbuf);
                goto load_failed;
            }
            map->meshes[i].vertices = (PbmVertex*)vbuf;
        }
    }

    /* 3. Colliders */
    if (map->header.num_colliders > 0) {
        map->colliders = (PbmCollider*)calloc(map->header.num_colliders, sizeof(PbmCollider));
        for (uint32_t i = 0; i < map->header.num_colliders; ++i) {
            PbmColliderHeader chdr;
            if (fread(&chdr, sizeof(PbmColliderHeader), 1, f) != 1) {
                pbm_log("[PBM] FATAL: short read on collider header %u\n", (unsigned int)i);
                goto load_failed;
            }
            memcpy(map->colliders[i].name, chdr.name, 32);
            map->colliders[i].type = chdr.type;
            memcpy(map->colliders[i].bounds_min, chdr.bounds_min, sizeof(float) * 3);
            memcpy(map->colliders[i].bounds_max, chdr.bounds_max, sizeof(float) * 3);
            map->colliders[i].num_triangles = chdr.num_triangles;

            if (chdr.num_triangles > 0) {
                uint32_t tbuf_size = chdr.num_triangles * 9 * sizeof(float);
                float* tbuf = (float*)malloc(tbuf_size);
                if (tbuf) {
                    fread(tbuf, 1, tbuf_size, f);
                    map->colliders[i].triangles = tbuf;
                }
            }
        }
    }

    /* 4. Metadata Chunk (v2.0+) */
    if (map->header.num_metadata > 0) {
        map->metadata = (PbmMetadata*)calloc(map->header.num_metadata, sizeof(PbmMetadata));
        for (uint32_t i = 0; i < map->header.num_metadata; ++i) {
            PbmMetadataHeader mdhdr;
            if (fread(&mdhdr, sizeof(PbmMetadataHeader), 1, f) != 1) {
                printf("[PBM] Error reading metadata header %u\n", (unsigned int)i);
                break;
            }
            memcpy(map->metadata[i].tag, mdhdr.tag, 32);
            map->metadata[i].tag[31] = '\0';
            map->metadata[i].type = mdhdr.type;
            map->metadata[i].data_size = mdhdr.data_size;

            if (mdhdr.data_size > 0) {
                uint32_t alloc_size = mdhdr.data_size + 4;
                void* mdata = calloc(1, alloc_size);
                if (mdata) {
                    fread(mdata, 1, mdhdr.data_size, f);
                    map->metadata[i].data = mdata;

                    /* Skip alignment padding to 4 bytes */
                    uint32_t pad = (4 - (mdhdr.data_size % 4)) % 4;
                    if (pad > 0) {
                        uint8_t pad_buf[4];
                        fread(pad_buf, 1, pad, f);
                    }

                    /* Parse known proof-of-concept metadata tags */
                    if (strcmp(map->metadata[i].tag, "map_name") == 0) {
                        strncpy(map->map_name, (const char*)mdata, sizeof(map->map_name) - 1);
                        map->map_name[sizeof(map->map_name) - 1] = '\0';
                        printf("[PBM] Metadata parsed: Map Name = '%s'\n", map->map_name);
                    } else if (strcmp(map->metadata[i].tag, "entities") == 0) {
                        if (mdhdr.data_size >= sizeof(PbmEntityPatrolSphere)) {
                            memcpy(&map->patrol_sphere, mdata, sizeof(PbmEntityPatrolSphere));
                            map->has_patrol_sphere = 1;
                            printf("[PBM] Metadata parsed: Entity '%s' (type %u, radius=%.2f, speed=%.2f, %u waypoints)\n",
                                map->patrol_sphere.name,
                                (unsigned int)map->patrol_sphere.entity_type,
                                map->patrol_sphere.radius,
                                map->patrol_sphere.speed,
                                (unsigned int)map->patrol_sphere.num_waypoints);
                        }
                    } else if (strcmp(map->metadata[i].tag, "emitters") == 0) {
                        /* Standard lump: particle emitters (see pbm.h). */
                        pbm_build_emitters(map, mdata, mdhdr.data_size);
                    } else if (strcmp(map->metadata[i].tag, "env_preset") == 0) {
                        strncpy(map->env_preset, (const char*)mdata, sizeof(map->env_preset) - 1);
                        map->env_preset[sizeof(map->env_preset) - 1] = '\0';
                        printf("[PBM] Metadata parsed: Env Preset = '%s'\n", map->env_preset);
                    }
            }
        }
    }
    }

    /* A map that claims meshes but has no vertices renders as an empty scene
     * while still reporting success. Treat it as a load failure. */
    for (uint32_t i = 0; i < map->header.num_meshes; ++i) {
        if (!map->meshes[i].vertices || map->meshes[i].num_vertices == 0) {
            pbm_log("[PBM] FATAL: mesh %u of %u has no vertices; map is incomplete\n",
                    (unsigned int)i, (unsigned)map->header.num_meshes);
            goto load_failed;
        }
    }

    /* Flush all loaded textures, vertices, and colliders from D-Cache to main RAM
     * so the Sony GE hardware DMA reads valid data without bus stalls! */
#ifdef __PSP__
    sceKernelDcacheWritebackAll();
#endif
    if (animated_meshes > 0) {
        pbm_log("[PBM] %u of %u meshes have an animated UV scroll (PBM 3.0)\n",
                (unsigned)animated_meshes, (unsigned)map->header.num_meshes);
    }
    pbm_log_mem("after load");
    return map;

load_failed:
    pbm_log("[PBM] Load of '%s' failed; refusing to run with a partial map.\n", filepath);
    pbm_log_mem("on failure");
    pbm_free(map);
    fclose(f);
    return NULL;
}

void pbm_free(PbmMap* map) {
    if (!map) return;
    if (map->textures) {
        for (uint32_t i = 0; i < map->header.num_textures; ++i) {
            /* level 0 aliases pixels; the rest are separately allocated */
            for (uint32_t k = 1; k < map->textures[i].num_levels; ++k) {
                if (map->textures[i].level_ptr[k]) free(map->textures[i].level_ptr[k]);
            }
            if (map->textures[i].pixels) {
                free(map->textures[i].pixels);
            }
        }
        free(map->textures);
    }
    if (map->meshes) {
        for (uint32_t i = 0; i < map->header.num_meshes; ++i) {
            if (map->meshes[i].vertices) {
                free(map->meshes[i].vertices);
            }
        }
        free(map->meshes);
    }
    if (map->colliders) {
        for (uint32_t i = 0; i < map->header.num_colliders; ++i) {
            if (map->colliders[i].triangles) {
                free(map->colliders[i].triangles);
            }
        }
        free(map->colliders);
    }
    if (map->metadata) {
        for (uint32_t i = 0; i < map->header.num_metadata; ++i) {
            if (map->metadata[i].data) {
                free(map->metadata[i].data);
            }
        }
        free(map->metadata);
    }
    pbm_emitters_release(map);
    free(map);
}
