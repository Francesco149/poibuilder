#include <pspkernel.h>
#include <pspdisplay.h>
#include <pspdebug.h>
#include <pspgu.h>
#include <pspgum.h>
#include <pspctrl.h>
#include <psprtc.h>
#include <psppower.h>
#include <psputils.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "pbm_loader.h"
#include "font8x8.h"

PSP_MODULE_INFO("PoiRetro", 0, 1, 1);
PSP_MAIN_THREAD_ATTR(THREAD_ATTR_USER | THREAD_ATTR_VFPU);

#define BUF_WIDTH (512)
#define SCR_WIDTH (480)
#define SCR_HEIGHT (272)

static unsigned int __attribute__((aligned(16))) dlist[262144];

/* 128x64 16-bit font texture (16 chars/row x 6 rows of 8x8 glyphs) */
static uint16_t __attribute__((aligned(16))) font_tex[128 * 64];

/* 2D Sprite vertex format for Sony GU hardware text rendering */
typedef struct {
    float u, v;
    uint32_t color;
    float x, y, z;
} SpriteVertex;

static SpriteVertex __attribute__((aligned(16))) text_verts[512];

/* Exit callback thread for Home button */
static int exit_callback(int arg1, int arg2, void *common) {
    sceKernelExitGame();
    return 0;
}

static int callback_thread(SceSize args, void *argp) {
    int cbid = sceKernelCreateCallback("Exit Callback", exit_callback, NULL);
    sceKernelRegisterExitCallback(cbid);
    sceKernelSleepThreadCB();
    return 0;
}

static int setup_callbacks(void) {
    int thid = sceKernelCreateThread("update_thread", callback_thread, 0x11, 0xFA0, 0, 0);
    if (thid >= 0) {
        sceKernelStartThread(thid, 0, 0);
    }
    return thid;
}

/* Unpack 8x8 bitmap font into 16-bit RGBA5551 texture in RAM */
static void font_init(void) {
    memset(font_tex, 0, sizeof(font_tex));
    for (int c = 32; c < 127; ++c) {
        int idx = c - 32;
        int base_col = (idx % 16) * 8;
        int base_row = (idx / 16) * 8;
        for (int y = 0; y < 8; ++y) {
            uint8_t row_bits = (uint8_t)font8x8_basic[c][y];
            for (int x = 0; x < 8; ++x) {
                if (row_bits & (1 << x)) {
                    /* Solid white in RGBA5551: 0xFFFF (A=1, B=31, G=31, R=31) */
                    font_tex[(base_row + y) * 128 + (base_col + x)] = 0xFFFF;
                } else {
                    /* Fully transparent */
                    font_tex[(base_row + y) * 128 + (base_col + x)] = 0x0000;
                }
            }
        }
    }
    /* Flush font texture from D-Cache to RAM so GE hardware reads it */
    sceKernelDcacheWritebackRange(font_tex, sizeof(font_tex));
}

/* Renders 2D text directly via Sony GU display list quads (100% visible on PPSSPP Vulkan/OpenGL & Real Hardware) */
static void draw_text_gu(float start_x, float start_y, uint32_t color, const char* str) {
    if (!str || !*str) return;

    int len = strlen(str);
    if (len > 250) len = 250;

    sceGuEnable(GU_TEXTURE_2D);
    sceGuTexMode(GU_PSM_5551, 0, 0, 0);
    sceGuTexImage(0, 128, 64, 128, font_tex);
    sceGuTexFunc(GU_TFX_MODULATE, GU_TCC_RGBA);
    sceGuTexFilter(GU_NEAREST, GU_NEAREST);
    sceGuDisable(GU_DEPTH_TEST);
    sceGuDisable(GU_CULL_FACE);
    sceGuEnable(GU_BLEND);
    sceGuBlendFunc(GU_ADD, GU_SRC_ALPHA, GU_ONE_MINUS_SRC_ALPHA, 0, 0);

    float cur_x = start_x;
    float cur_y = start_y;
    int vert_count = 0;

    for (int i = 0; i < len; ++i) {
        unsigned char c = (unsigned char)str[i];
        if (c < 32 || c > 126) c = ' ';
        int idx = c - 32;
        int col = idx % 16;
        int row = idx / 16;

        float u1 = (float)(col * 8);
        float v1 = (float)(row * 8);
        float u2 = u1 + 8.0f;
        float v2 = v1 + 8.0f;

        /* Top-left */
        text_verts[vert_count].u = u1;
        text_verts[vert_count].v = v1;
        text_verts[vert_count].color = color;
        text_verts[vert_count].x = cur_x;
        text_verts[vert_count].y = cur_y;
        text_verts[vert_count].z = 0.0f;
        vert_count++;

        /* Bottom-right (GU_SPRITES uses 2 vertices per quad) */
        text_verts[vert_count].u = u2;
        text_verts[vert_count].v = v2;
        text_verts[vert_count].color = color;
        text_verts[vert_count].x = cur_x + 8.0f;
        text_verts[vert_count].y = cur_y + 8.0f;
        text_verts[vert_count].z = 0.0f;
        vert_count++;

        cur_x += 8.0f;
    }

    /* CRITICAL FOR REAL PSP HARDWARE:
     * Flush CPU D-Cache lines to RAM so the Sony GE hardware DMA sees all text lines! */
    sceKernelDcacheWritebackRange(text_verts, vert_count * sizeof(SpriteVertex));

    sceGuDrawArray(GU_SPRITES, GU_TEXTURE_32BITF | GU_COLOR_8888 | GU_VERTEX_32BITF | GU_TRANSFORM_2D, vert_count, 0, text_verts);
}

static void draw_text_shadow(float x, float y, uint32_t color, const char* str) {
    /* Crisp black drop shadow */
    draw_text_gu(x + 1.0f, y + 1.0f, 0xFF000000, str);
    /* Foreground colored text */
    draw_text_gu(x, y, color, str);
}

/* Screenshot utility */
static void save_tga(const char* filename, void* vram_buffer, int width, int height, int stride) {
    FILE* f = fopen(filename, "wb");
    if (!f) return;
    unsigned char header[18] = {
        0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        (unsigned char)(width & 0xFF), (unsigned char)((width >> 8) & 0xFF),
        (unsigned char)(height & 0xFF), (unsigned char)((height >> 8) & 0xFF),
        32, 0x20 /* 32-bit top-left origin */
    };
    fwrite(header, 1, 18, f);
    unsigned int* src = (unsigned int*)vram_buffer;
    for (int y = 0; y < height; ++y) {
        fwrite(&src[y * stride], 4, width, f);
    }
    fclose(f);
    printf("[PSP] Saved screenshot to '%s'\n", filename);
}

static inline int is_billboard_mesh(const char* name) {
    if (!name) return 0;
    if (strstr(name, "billboard") || strstr(name, "Billboard") ||
        strstr(name, "sprite")    || strstr(name, "Sprite")    ||
        strstr(name, "tree")      || strstr(name, "Tree")      ||
        strstr(name, "bush")      || strstr(name, "Bush")      ||
        strstr(name, "flower")    || strstr(name, "Flower")) {
        return 1;
    }
    return 0;
}

int main(int argc, char* argv[]) {
    /* Set up Home button exit callback thread */
    setup_callbacks();

    /* Unlock full 333 MHz CPU and 166 MHz GPU clock speed on real PSP!
     * (Defaults to 222MHz battery-saver mode which throttles 3D fillrate) */
    scePowerSetClockFrequency(333, 333, 166);

    pspDebugScreenInit();
    printf("[PSP] Starting PoiRetro Homebrew Engine v0.9.61...\n");

    void* fbp0 = (void*)0;
    void* fbp1 = (void*)(BUF_WIDTH * SCR_HEIGHT * 4);
    void* zbp  = (void*)((BUF_WIDTH * SCR_HEIGHT * 4) * 2);

    /* Initialize 8x8 font texture */
    font_init();

    /* Initialize Sony GU */
    sceGuInit();
    sceGuStart(GU_DIRECT, dlist);
    sceGuDrawBuffer(GU_PSM_8888, fbp0, BUF_WIDTH);
    sceGuDispBuffer(SCR_WIDTH, SCR_HEIGHT, fbp1, BUF_WIDTH);
    sceGuDepthBuffer(zbp, BUF_WIDTH);
    sceGuOffset(2048 - (SCR_WIDTH / 2), 2048 - (SCR_HEIGHT / 2));
    sceGuViewport(2048, 2048, SCR_WIDTH, SCR_HEIGHT);

    /* Standard depth buffer: Near=0, Far=65535, clear to 65535, GU_LEQUAL */
    sceGuDepthRange(0, 65535);
    sceGuDepthFunc(GU_LEQUAL);
    sceGuEnable(GU_DEPTH_TEST);
    sceGuDepthMask(GU_FALSE); /* Allow depth writes */

    /* Scissor */
    sceGuScissor(0, 0, SCR_WIDTH, SCR_HEIGHT);
    sceGuEnable(GU_SCISSOR_TEST);

    /* Counter-Clockwise front faces, cull backfaces */
    sceGuFrontFace(GU_CCW);
    sceGuEnable(GU_CULL_FACE);
    sceGuShadeModel(GU_SMOOTH);

    /* Texture settings */
    sceGuEnable(GU_TEXTURE_2D);
    sceGuTexWrap(GU_REPEAT, GU_REPEAT);
    sceGuTexFilter(GU_LINEAR, GU_LINEAR);
    sceGuTexFunc(GU_TFX_MODULATE, GU_TCC_RGBA);

    sceGuFinish();
    sceGuSync(0, 0);

    sceDisplayWaitVblankStart();
    sceGuDisplay(GU_TRUE);

    /* Load Map */
    const char* map_path = "showcase_retro_baked.pbm";
    if (argc > 1 && argv[1] != NULL && strlen(argv[1]) > 0) {
        map_path = argv[1];
    }
    PbmMap* map = pbm_load(map_path);
    if (!map) {
        map = pbm_load("disc0:/showcase_retro_baked.pbm");
    }
    if (!map) {
        map = pbm_load("ms0:/showcase_retro_baked.pbm");
    }
    if (!map) {
        map = pbm_load("PSP/GAME/PoiRetro/showcase_retro_baked.pbm");
    }

    if (!map) {
        printf("[PSP] Warning: Map file '%s' not found! Please check path.\n", map_path);
        sceKernelDelayThread(1000000);
        sceKernelExitGame();
        return 1;
    }

    float center_x = (map->header.bounds_min[0] + map->header.bounds_max[0]) * 0.5f;
    float center_y = (map->header.bounds_min[1] + map->header.bounds_max[1]) * 0.5f;
    float center_z = (map->header.bounds_min[2] + map->header.bounds_max[2]) * 0.5f;

    float span_x = map->header.bounds_max[0] - map->header.bounds_min[0];
    float span_z = map->header.bounds_max[2] - map->header.bounds_min[2];
    float radius = sqrtf(span_x * span_x + span_z * span_z) * 0.75f;
    if (radius < 5.0f) radius = 12.0f;

    printf("[PSP] Map bounds: center=(%.2f, %.2f, %.2f) radius=%.2f\n", center_x, center_y, center_z, radius);

    /* Set up controller */
    sceCtrlSetSamplingCycle(0);
    sceCtrlSetSamplingMode(PSP_CTRL_MODE_ANALOG);

    /* Initial Camera: standing in front of the billboard looking directly at the archway
     * Archway is at Z=-5.5, billboard is at Z=4.0.
     * Standing at (0, 1.6, 4.2), yaw=0.0 looks straight North (-Z) at the archway! */
    float cam_x = 0.0f;
    float cam_y = 1.6f;  /* Eye level standing on floor */
    float cam_z = 4.2f;  /* In front of the trees/bush billboard, facing North */
    float cam_yaw = 0.0f; /* Facing straight North (-Z) at the archway at Z=-5.5 */
    float cam_pitch = 0.05f; /* Slightly upward toward the arch opening */

    int running = 1;
    int frame_count = 0;
    int display_mode = 0; /* 0: Textured (Baked Lit), 1: Baked Lighting Only, 2: Wireframe */

#ifdef HEADLESS_BENCHMARK
    int is_benchmark = 1;
    float orbit_angle = 0.5f;
#else
    int is_benchmark = 0;
    float orbit_angle = 0.0f;
#endif

    /* Timing / FPS */
    u64 last_tick = 0;
    sceRtcGetCurrentTick(&last_tick);
    float fps = 60.0f;
    int fps_frames = 0;
    float fps_timer = 0.0f;

    void* curr_fbp = fbp0;

    printf("[PSP] Entering 3D rendering loop (benchmark mode: %d)...\n", is_benchmark);

    while (running) {
        /* Compute Delta Time */
        u64 curr_tick = 0;
        sceRtcGetCurrentTick(&curr_tick);
        float dt = (float)(curr_tick - last_tick) / 1000000.0f;
        if (dt <= 0.0001f || dt > 0.2f) dt = 1.0f / 60.0f;
        last_tick = curr_tick;

        fps_timer += dt;
        fps_frames++;
        if (fps_timer >= 0.35f) {
            fps = (float)fps_frames / fps_timer;
            fps_frames = 0;
            fps_timer = 0.0f;
        }

        /* Read Controller Input */
        SceCtrlData pad;
        sceCtrlReadBufferPositive(&pad, 1);

        /* Exit shortcut: Start + Select held together quits immediately */
        if ((pad.Buttons & PSP_CTRL_START) && (pad.Buttons & PSP_CTRL_SELECT)) {
            printf("[PSP] Start+Select pressed — exiting game.\n");
            running = 0;
            break;
        }

        if (!is_benchmark) {
            /* Interactive Fly Camera Controls:
             * - Analog stick: Fly forward/backward along yaw, strafe left/right
             * - LT / RT: Look left / right (yaw)
             * - X (Cross): Fly UP
             * - Circle (O): Fly DOWN
             * - Triangle / Square / D-Pad: Pitch look up / down
             * - Start: Reset to spawn
             * - Select: Cycle render modes */
            if (pad.Buttons & PSP_CTRL_START) {
                cam_x = 0.0f;
                cam_y = 1.6f;
                cam_z = 4.2f;
                cam_yaw = 0.0f;
                cam_pitch = 0.05f;
            }
            if (pad.Buttons & PSP_CTRL_SELECT) {
                display_mode = (display_mode + 1) % 3;
                sceKernelDelayThread(150000);
            }

            /* 1. Fly motion with Analog Stick (or D-Pad) */
            float move_speed = 9.5f * dt;
            if (pad.Buttons & PSP_CTRL_SQUARE) move_speed *= 2.0f; /* Turbo speed */

            float in_fwd = 0.0f;
            float in_strafe = 0.0f;

            if (abs((int)pad.Ly - 128) > 20) {
                in_fwd = -(float)((int)pad.Ly - 128) / 128.0f;
            }
            if (abs((int)pad.Lx - 128) > 20) {
                in_strafe = (float)((int)pad.Lx - 128) / 128.0f;
            }
            if (pad.Buttons & PSP_CTRL_UP)    in_fwd += 1.0f;
            if (pad.Buttons & PSP_CTRL_DOWN)  in_fwd -= 1.0f;
            if (pad.Buttons & PSP_CTRL_LEFT)  in_strafe -= 1.0f;
            if (pad.Buttons & PSP_CTRL_RIGHT) in_strafe += 1.0f;

            float fwd_x = sinf(cam_yaw);
            float fwd_z = -cosf(cam_yaw);
            float right_x = cosf(cam_yaw);
            float right_z = sinf(cam_yaw);

            cam_x += (fwd_x * in_fwd + right_x * in_strafe) * move_speed;
            cam_z += (fwd_z * in_fwd + right_z * in_strafe) * move_speed;

            /* 2. Look left / right via LT / RT */
            float turn_speed = 2.4f * dt;
            if (pad.Buttons & PSP_CTRL_LTRIGGER) cam_yaw -= turn_speed;
            if (pad.Buttons & PSP_CTRL_RTRIGGER) cam_yaw += turn_speed;

            /* 3. Up / Down elevation: X to go up, Circle to go down */
            float vert_speed = 8.0f * dt;
            if (pad.Buttons & PSP_CTRL_CROSS)  cam_y += vert_speed;
            if (pad.Buttons & PSP_CTRL_CIRCLE) cam_y -= vert_speed;

            /* 4. Look pitch (up/down): Triangle looks up, Square looks down */
            if (pad.Buttons & PSP_CTRL_TRIANGLE) cam_pitch += 1.8f * dt;
            if (cam_pitch > 1.45f)  cam_pitch = 1.45f;
            if (cam_pitch < -1.45f) cam_pitch = -1.45f;
        } else {
            /* Headless benchmark auto-orbit */
            orbit_angle += 0.02f;
            cam_x = center_x + sinf(orbit_angle) * radius;
            cam_y = center_y + radius * 0.4f;
            cam_z = center_z + cosf(orbit_angle) * radius;
            float dx = center_x - cam_x;
            float dz = center_z - cam_z;
            cam_yaw = atan2f(dx, -dz);
            cam_pitch = -0.32f;
        }

        /* Begin Frame */
        sceGuStart(GU_DIRECT, dlist);

        /* Clear background: deep dusk sky blue */
        sceGuClearColor(0xFF382218);
        sceGuClearDepth(65535); /* Clear depth to farthest */
        sceGuClear(GU_COLOR_BUFFER_BIT | GU_DEPTH_BUFFER_BIT);

        /* CRITICAL: Re-enable depth testing on EVERY frame for 3D meshes!
         * (Text pass disables it, so it must be restored here) */
        sceGuEnable(GU_DEPTH_TEST);
        sceGuDepthFunc(GU_LEQUAL);
        sceGuDepthMask(GU_FALSE); /* Allow depth writes */

        /* Projection Matrix */
        sceGumMatrixMode(GU_PROJECTION);
        sceGumLoadIdentity();
        sceGumPerspective(65.0f, 16.0f / 9.0f, 0.2f, 2000.0f);

        /* View Matrix */
        sceGumMatrixMode(GU_VIEW);
        sceGumLoadIdentity();
        float target_x = cam_x + sinf(cam_yaw) * cosf(cam_pitch);
        float target_y = cam_y + sinf(cam_pitch);
        float target_z = cam_z - cosf(cam_yaw) * cosf(cam_pitch);
        ScePspFVector3 eye    = { cam_x, cam_y, cam_z };
        ScePspFVector3 target = { target_x, target_y, target_z };
        ScePspFVector3 up     = { 0.0f, 1.0f, 0.0f };
        sceGumLookAt(&eye, &target, &up);

        /* ── TWO-PASS 3D RENDERING ARCHITECTURE ───
         * PASS 1: Solid Opaque Meshes (floors, walls, pillars, stairs, cylinder, prism)
         *   - GU_BLEND is DISABLED! (No heavy eDRAM read-modify-write; full fillrate & early-Z)
         *   - Depth write enabled, backface culling enabled
         * PASS 2: Alpha-blended Billboards (trees, bushes, flowers)
         *   - GU_BLEND enabled, backface culling disabled */

        int last_tex_id = -999;
        uint32_t total_rendered_verts = 0;

        /* PASS 1: Solid Opaque Meshes */
        sceGuDisable(GU_BLEND);
        sceGuEnable(GU_CULL_FACE);

        for (uint32_t mi = 0; mi < map->header.num_meshes; ++mi) {
            PbmMesh* mesh = &map->meshes[mi];
            if (!mesh->vertices || mesh->num_vertices == 0) continue;
            if (is_billboard_mesh(mesh->name)) continue; /* Rendered in Pass 2 */

            if (display_mode == 1 || display_mode == 2) {
                sceGuDisable(GU_TEXTURE_2D);
            } else {
                sceGuEnable(GU_TEXTURE_2D);
                if (mesh->texture_id >= 0 && mesh->texture_id < (int)map->header.num_textures) {
                    if (mesh->texture_id != last_tex_id) {
                        PbmTexture* tex = &map->textures[mesh->texture_id];
                        if (tex->pixels) {
                            int psm = (tex->format == PBM_TEX_FMT_RGBA5551) ? GU_PSM_5551 : GU_PSM_8888;
                            sceGuTexMode(psm, 0, 0, 0);
                            sceGuTexImage(0, tex->width, tex->height, tex->width, tex->pixels);
                        }
                        last_tex_id = mesh->texture_id;
                    }
                } else {
                    sceGuDisable(GU_TEXTURE_2D);
                    last_tex_id = -1;
                }
            }

            if (display_mode == 2) {
                sceGuDisable(GU_CULL_FACE);
            } else {
                sceGuEnable(GU_CULL_FACE);
            }

            sceGumMatrixMode(GU_MODEL);
            sceGumLoadIdentity();

            int prim_type = (display_mode == 2) ? GU_LINE_STRIP : GU_TRIANGLES;
            sceGumDrawArray(prim_type,
                GU_TEXTURE_32BITF | GU_COLOR_8888 | GU_VERTEX_32BITF | GU_TRANSFORM_3D,
                mesh->num_vertices, 0, mesh->vertices);

            total_rendered_verts += mesh->num_vertices;
        }

        /* PASS 2: Alpha-blended Billboards */
        sceGuEnable(GU_BLEND);
        sceGuBlendFunc(GU_ADD, GU_SRC_ALPHA, GU_ONE_MINUS_SRC_ALPHA, 0, 0);
        sceGuDisable(GU_CULL_FACE);

        for (uint32_t mi = 0; mi < map->header.num_meshes; ++mi) {
            PbmMesh* mesh = &map->meshes[mi];
            if (!mesh->vertices || mesh->num_vertices == 0) continue;
            if (!is_billboard_mesh(mesh->name)) continue; /* Already rendered in Pass 1 */

            if (display_mode == 1 || display_mode == 2) {
                sceGuDisable(GU_TEXTURE_2D);
            } else {
                sceGuEnable(GU_TEXTURE_2D);
                if (mesh->texture_id >= 0 && mesh->texture_id < (int)map->header.num_textures) {
                    if (mesh->texture_id != last_tex_id) {
                        PbmTexture* tex = &map->textures[mesh->texture_id];
                        if (tex->pixels) {
                            int psm = (tex->format == PBM_TEX_FMT_RGBA5551) ? GU_PSM_5551 : GU_PSM_8888;
                            sceGuTexMode(psm, 0, 0, 0);
                            sceGuTexImage(0, tex->width, tex->height, tex->width, tex->pixels);
                        }
                        last_tex_id = mesh->texture_id;
                    }
                }
            }

            sceGumMatrixMode(GU_MODEL);
            sceGumLoadIdentity();

            int prim_type = (display_mode == 2) ? GU_LINE_STRIP : GU_TRIANGLES;
            sceGumDrawArray(prim_type,
                GU_TEXTURE_32BITF | GU_COLOR_8888 | GU_VERTEX_32BITF | GU_TRANSFORM_3D,
                mesh->num_vertices, 0, mesh->vertices);

            total_rendered_verts += mesh->num_vertices;
        }

        /* ── PASS 3: Hardware 2D On-Screen HUD Overlay (100% visible on PPSSPP Vulkan/OpenGL & Real Hardware) ─── */
        char buf[80];
        snprintf(buf, sizeof(buf), "FPS: %4.1f | Tris: %u | Verts: %u",
            fps, (unsigned int)(total_rendered_verts / 3), (unsigned int)total_rendered_verts);
        draw_text_shadow(8.0f, 8.0f, 0xFF00FF55, buf); /* Bright Green */

        snprintf(buf, sizeof(buf), "Pos: (%.1f, %.1f, %.1f) | %s",
            cam_x, cam_y, cam_z,
            display_mode == 0 ? "Textured (Baked Lit)" : (display_mode == 1 ? "Baked Lighting" : "Wireframe"));
        draw_text_shadow(8.0f, 18.0f, 0xFFFFFF00, buf); /* Cyan */

        draw_text_shadow(8.0f, 28.0f, 0xFFDDDDDD, "Analog: Fly | LT/RT: Turn | X: Up | O: Down | Sel: Mode");

        sceGuFinish();
        sceGuSync(0, 0);

        sceDisplayWaitVblankStart();
        curr_fbp = (curr_fbp == fbp0) ? fbp1 : fbp0;
        sceGuSwapBuffers();

        frame_count++;

        /* Headless benchmark: capture screenshot at frame 60, exit at frame 120 */
        if (is_benchmark) {
            if (frame_count == 60) {
                printf("[PSP] Capturing benchmark screenshot at frame 60 (%u vertices, %.1f FPS)...\n",
                    (unsigned int)total_rendered_verts, fps);
                save_tga("screenshot_psp.tga", (void*)(0x04000000), SCR_WIDTH, SCR_HEIGHT, BUF_WIDTH);
            }
            if (frame_count >= 120) {
                printf("[PSP] Headless benchmark completed: %d frames rendered at ~%.1f FPS!\n", frame_count, fps);
                running = 0;
            }
        }
    }

    pbm_free(map);
    printf("[PSP] Exiting clean with sceKernelExitGame().\n");
    sceKernelDelayThread(50000);
    sceKernelExitGame();
    return 0;
}
