#include <pspkernel.h>
#include <pspdisplay.h>
#include <pspdebug.h>
#include <pspgu.h>
#include <pspgum.h>
#include <pspctrl.h>
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
    sceGuDepthRange(0, 65535);
    sceGuScissor(0, 0, SCR_WIDTH, SCR_HEIGHT);
    sceGuEnable(GU_SCISSOR_TEST);
    sceGuDepthFunc(GU_GEQUAL);
    sceGuEnable(GU_DEPTH_TEST);
    sceGuFrontFace(GU_CCW);
    sceGuShadeModel(GU_SMOOTH);
    sceGuDisable(GU_CULL_FACE); /* Double-sided faces for retro showcase */

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

    int running = 1;
    int frame_count = 0;
    float orbit_angle = 0.6f;
    int display_mode = 0; /* 0: Textured + Vertex Color Lighting, 1: Lighting Only, 2: Wireframe */
    int headless = 1; /* Default to benchmark / headless mode for automated pipeline testing */

    void* curr_fbp = fbp0;

    printf("[PSP] Entering 3D rendering loop...\n");

    while (running) {
        SceCtrlData pad;
        sceCtrlReadBufferPositive(&pad, 1);

        if (pad.Buttons & PSP_CTRL_START) {
            headless = 0;
            orbit_angle = 0.0f;
        }
        if (pad.Buttons & PSP_CTRL_SELECT) {
            display_mode = (display_mode + 1) % 3;
            sceKernelDelayThread(150000);
        }

        /* Update Camera */
        if (headless) {
            orbit_angle += 0.025f;
        } else {
            if (pad.Buttons & PSP_CTRL_LEFT)  orbit_angle -= 0.03f;
            if (pad.Buttons & PSP_CTRL_RIGHT) orbit_angle += 0.03f;
        }

        float cam_x = center_x + sinf(orbit_angle) * radius;
        float cam_y = center_y + radius * 0.45f;
        float cam_z = center_z + cosf(orbit_angle) * radius;

        /* Begin Frame */
        sceGuStart(GU_DIRECT, dlist);

        /* Clear background: deep dusk sky blue */
        sceGuClearColor(0xFF382218);
        sceGuClearDepth(0);
        sceGuClear(GU_COLOR_BUFFER_BIT | GU_DEPTH_BUFFER_BIT);

        /* Projection Matrix */
        sceGumMatrixMode(GU_PROJECTION);
        sceGumLoadIdentity();
        sceGumPerspective(65.0f, 16.0f / 9.0f, 0.2f, 2000.0f);

        /* View Matrix */
        sceGumMatrixMode(GU_VIEW);
        sceGumLoadIdentity();
        ScePspFVector3 eye    = { cam_x, cam_y, cam_z };
        ScePspFVector3 target = { center_x, center_y + 1.2f, center_z };
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

            if (display_mode == 1) {
                /* Vertex colors only */
                sceGuDisable(GU_TEXTURE_2D);
            } else if (display_mode == 2) {
                /* Wireframe / untextured */
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

        sceDisplayWaitVblankStart();
        curr_fbp = (curr_fbp == fbp0) ? fbp1 : fbp0;
        sceGuSwapBuffers();

        frame_count++;

        /* In headless mode, capture screenshot at frame 60 and exit at frame 120 */
        if (headless) {
            if (frame_count == 60) {
                printf("[PSP] Capturing benchmark screenshot at frame 60 (%u vertices)...\n", (unsigned int)total_rendered_verts);
                save_tga("screenshot_psp.tga", (void*)(0x04000000), SCR_WIDTH, SCR_HEIGHT, BUF_WIDTH);
            }
            if (frame_count >= 120) {
                printf("[PSP] Headless benchmark completed successfully: %d frames rendered!\n", frame_count);
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
