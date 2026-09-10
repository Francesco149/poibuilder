#include <pspkernel.h>
#include <pspdisplay.h>
#include <pspdebug.h>
#include <pspgu.h>
#include <pspgum.h>
#include <pspctrl.h>
#include <psprtc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "pbm_loader.h"

PSP_MODULE_INFO("PoiRetro", 0, 1, 1);
PSP_MAIN_THREAD_ATTR(THREAD_ATTR_USER | THREAD_ATTR_VFPU);

#define BUF_WIDTH (512)
#define SCR_WIDTH (480)
#define SCR_HEIGHT (272)

static unsigned int __attribute__((aligned(16))) dlist[262144];

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
    pspDebugScreenInit();
    printf("[PSP] Starting PoiRetro Homebrew Engine v0.9.61...\n");

    void* fbp0 = (void*)0;
    void* fbp1 = (void*)(BUF_WIDTH * SCR_HEIGHT * 4);
    void* zbp  = (void*)((BUF_WIDTH * SCR_HEIGHT * 4) * 2);

    /* Initialize Sony GU */
    sceGuInit();
    sceGuStart(GU_DIRECT, dlist);
    sceGuDrawBuffer(GU_PSM_8888, fbp0, BUF_WIDTH);
    sceGuDispBuffer(SCR_WIDTH, SCR_HEIGHT, fbp1, BUF_WIDTH);
    sceGuDepthBuffer(zbp, BUF_WIDTH);
    sceGuOffset(2048 - (SCR_WIDTH / 2), 2048 - (SCR_HEIGHT / 2));
    sceGuViewport(2048, 2048, SCR_WIDTH, SCR_HEIGHT);

    /* CORRECT DEPTH BUFFER:
     * Near = 0, Far = 65535. Clear to 65535.
     * Use GU_LEQUAL so closer fragments (smaller Z) pass and occlude background! */
    sceGuDepthRange(0, 65535);
    sceGuDepthFunc(GU_LEQUAL);
    sceGuEnable(GU_DEPTH_TEST);

    /* SCISSOR */
    sceGuScissor(0, 0, SCR_WIDTH, SCR_HEIGHT);
    sceGuEnable(GU_SCISSOR_TEST);

    /* WINDING & CULLING:
     * Front faces are Counter-Clockwise (CCW). Cull backfaces (GU_BACK).
     * Billboards dynamically disable culling during draw. */
    sceGuFrontFace(GU_CCW);
    sceGuEnable(GU_CULL_FACE);
    sceGuShadeModel(GU_SMOOTH);

    /* Texture settings */
    sceGuEnable(GU_TEXTURE_2D);
    sceGuTexWrap(GU_REPEAT, GU_REPEAT);
    sceGuTexFilter(GU_LINEAR, GU_LINEAR);
    sceGuTexFunc(GU_TFX_MODULATE, GU_TCC_RGBA); /* Modulate texture with vertex lighting + AO */

    /* Alpha blending */
    sceGuEnable(GU_BLEND);
    sceGuBlendFunc(GU_ADD, GU_SRC_ALPHA, GU_ONE_MINUS_SRC_ALPHA, 0, 0);

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
        printf("[PSP] Warning: Map file '%s' not found! Please convert GLB to PBM.\n", map_path);
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

    /* Interactive Fly Camera State */
    float cam_x = map->header.spawn_pos[0];
    float cam_y = map->header.spawn_pos[1] + 1.2f;
    float cam_z = map->header.spawn_pos[2];
    float cam_yaw = map->header.spawn_rot + 3.14159f; /* Look forward into the scene */
    float cam_pitch = -0.1f; /* Slightly downward */

    int running = 1;
    int frame_count = 0;
    int display_mode = 0; /* 0: Textured + Lighting, 1: Lighting Only, 2: Wireframe */
    int auto_orbit = 1;   /* Auto-orbits until user interacts with gamepad */
    float orbit_angle = 0.5f;

    /* Timing / FPS */
    u64 last_tick = 0;
    sceRtcGetCurrentTick(&last_tick);
    float fps = 60.0f;
    int fps_frames = 0;
    float fps_timer = 0.0f;

    void* curr_fbp = fbp0;

    printf("[PSP] Entering 3D rendering loop...\n");

    while (running) {
        /* Compute Delta Time */
        u64 curr_tick = 0;
        sceRtcGetCurrentTick(&curr_tick);
        float dt = (float)(curr_tick - last_tick) / 1000000.0f;
        if (dt <= 0.0001f || dt > 0.2f) dt = 1.0f / 60.0f;
        last_tick = curr_tick;

        fps_timer += dt;
        fps_frames++;
        if (fps_timer >= 0.4f) {
            fps = (float)fps_frames / fps_timer;
            fps_frames = 0;
            fps_timer = 0.0f;
        }

        /* Read Controller Input */
        SceCtrlData pad;
        sceCtrlReadBufferPositive(&pad, 1);

        /* Detect user interaction: switches from auto-orbit demo to interactive fly camera */
        int has_input = 0;
        if (abs((int)pad.Lx - 128) > 20 || abs((int)pad.Ly - 128) > 20) has_input = 1;
        if (pad.Buttons & (PSP_CTRL_LTRIGGER | PSP_CTRL_RTRIGGER | PSP_CTRL_CROSS | PSP_CTRL_CIRCLE |
                           PSP_CTRL_TRIANGLE | PSP_CTRL_SQUARE   | PSP_CTRL_UP    | PSP_CTRL_DOWN)) {
            has_input = 1;
        }
        if (has_input) {
            auto_orbit = 0;
        }

        if (pad.Buttons & PSP_CTRL_START) {
            /* Reset camera to spawn position */
            cam_x = map->header.spawn_pos[0];
            cam_y = map->header.spawn_pos[1] + 1.2f;
            cam_z = map->header.spawn_pos[2];
            cam_yaw = map->header.spawn_rot + 3.14159f;
            cam_pitch = -0.1f;
            auto_orbit = 0;
        }
        if (pad.Buttons & PSP_CTRL_SELECT) {
            display_mode = (display_mode + 1) % 3;
            sceKernelDelayThread(150000);
        }

        /* Update Camera */
        if (auto_orbit) {
            orbit_angle += 0.02f;
            cam_x = center_x + sinf(orbit_angle) * radius;
            cam_y = center_y + radius * 0.4f;
            cam_z = center_z + cosf(orbit_angle) * radius;
            /* Point directly at map center */
            float dx = center_x - cam_x;
            float dz = center_z - cam_z;
            cam_yaw = atan2f(dx, -dz);
            cam_pitch = -0.32f;
        } else {
            /* 1. Fly camera movement via Analog Stick (or D-Pad) */
            float move_speed = 9.0f * dt;
            if (pad.Buttons & PSP_CTRL_SQUARE) move_speed *= 2.0f; /* Sprint with Square */

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

            /* 2. Look left and right via LT / RT */
            float turn_speed = 2.4f * dt;
            if (pad.Buttons & PSP_CTRL_LTRIGGER) cam_yaw -= turn_speed;
            if (pad.Buttons & PSP_CTRL_RTRIGGER) cam_yaw += turn_speed;

            /* 3. Up / Down elevation: X to go up, Circle to go down */
            float vert_speed = 7.5f * dt;
            if (pad.Buttons & PSP_CTRL_CROSS)  cam_y += vert_speed;
            if (pad.Buttons & PSP_CTRL_CIRCLE) cam_y -= vert_speed;

            /* 4. Look pitch (up/down): Triangle looks up, Square looks down (when not strafing) */
            if (pad.Buttons & PSP_CTRL_TRIANGLE) cam_pitch += 1.8f * dt;
            if (cam_pitch > 1.45f)  cam_pitch = 1.45f;
            if (cam_pitch < -1.45f) cam_pitch = -1.45f;
        }

        /* Begin Frame */
        sceGuStart(GU_DIRECT, dlist);

        /* Clear background: deep atmospheric dusk blue */
        sceGuClearColor(0xFF382218);
        sceGuClearDepth(65535); /* Clear depth to farthest */
        sceGuClear(GU_COLOR_BUFFER_BIT | GU_DEPTH_BUFFER_BIT);

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

        /* Render Meshes */
        int last_tex_id = -999;
        uint32_t total_rendered_verts = 0;

        for (uint32_t mi = 0; mi < map->header.num_meshes; ++mi) {
            PbmMesh* mesh = &map->meshes[mi];
            if (!mesh->vertices || mesh->num_vertices == 0) {
                continue;
            }

            int is_billboard = is_billboard_mesh(mesh->name);

            if (display_mode == 1) {
                /* Vertex colors / baked lighting only */
                sceGuDisable(GU_TEXTURE_2D);
            } else if (display_mode == 2) {
                /* Wireframe */
                sceGuDisable(GU_TEXTURE_2D);
            } else {
                /* Textured */
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

            /* Culling: billboards are double-sided; solid geometry culls backfaces */
            if (is_billboard || display_mode == 2) {
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

        sceGuFinish();
        sceGuSync(0, 0);

        /* Draw on-screen HUD (FPS counter, vertex count, controls hint) */
        pspDebugScreenSetOffset((int)curr_fbp);
        pspDebugScreenEnableBackColor(0); /* Transparent background */

        pspDebugScreenSetTextColor(0xFF00FF55); /* Vibrant Green */
        pspDebugScreenSetXY(1, 1);
        pspDebugScreenPrintf("FPS: %4.1f | Tris: %u | Verts: %u",
            fps, (unsigned int)(total_rendered_verts / 3), (unsigned int)total_rendered_verts);

        pspDebugScreenSetTextColor(0xFFEEEE00); /* Cyan */
        pspDebugScreenSetXY(1, 2);
        pspDebugScreenPrintf("Cam: (%.1f, %.1f, %.1f) | Mode: %s",
            cam_x, cam_y, cam_z,
            display_mode == 0 ? "Textured (Baked Lit)" : (display_mode == 1 ? "Baked Lighting" : "Wireframe"));

        pspDebugScreenSetTextColor(0xFFDDDDDD); /* Light Gray */
        pspDebugScreenSetXY(1, 3);
        pspDebugScreenPrintf("Analog: Move | LT/RT: Turn | X: Up | O: Down | Sel: Mode");

        sceDisplayWaitVblankStart();
        curr_fbp = (curr_fbp == fbp0) ? fbp1 : fbp0;
        sceGuSwapBuffers();

        frame_count++;

        /* Headless test capture: screenshot at frame 60, exit cleanly at frame 120 */
        if (auto_orbit) {
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
