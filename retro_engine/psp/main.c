/* PoiRetro — Sony PSP homebrew renderer for PoiBuilder retro maps (.pbm).
 *
 * This file owns initialisation, input and the frame loop. The scene renderer
 * lives in psp_render.c (so the profiler can drive it with one GPU state
 * changed at a time) and the profiling suite in psp_prof.c.
 *
 * Every frame is timed in two halves:
 *   cpu — building the display list (the GE is idle, the CPU is busy)
 *   gpu — sceGuSync waiting for the GE to finish that list
 * The HUD shows both, and pressing L + R dumps the worst frames of the recent
 * past — with their camera poses — to ms0:/poi_trace.txt. That is how a
 * slowdown reported from a real PSP is reproduced without guessing. */
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
#include <stdlib.h>
#include <math.h>

#include "pbm_loader.h"
#include "psp_render.h"
#include "psp_prof.h"

PSP_MODULE_INFO("PoiRetro", 0, 1, 1);
PSP_MAIN_THREAD_ATTR(THREAD_ATTR_USER | THREAD_ATTR_VFPU);

#define BUF_WIDTH (512)
#define SCR_WIDTH (480)
#define SCR_HEIGHT (272)

#ifndef HEADLESS_BENCHMARK
#define HEADLESS_BENCHMARK 0
#endif

/* Frames kept for the on-demand worst-frame trace (~1 minute at 60 fps). */
#define TRACE_FRAMES 3600

typedef struct {
    float cpu_ms, gpu_ms;
    float x, y, z, yaw, pitch;
    uint32_t draws, verts;
} TraceFrame;

/* Heap-allocated: the module's static memory is what PSPLink must find a
 * contiguous block for when it loads us, so keep it small. */
static TraceFrame* s_trace = NULL;
static int s_trace_head = 0;
static int s_trace_count = 0;

static void trace_push(const TraceFrame* f) {
    if (!s_trace) {
        s_trace = (TraceFrame*)malloc(TRACE_FRAMES * sizeof(TraceFrame));
        if (!s_trace) return;
    }
    s_trace[s_trace_head] = *f;
    s_trace_head = (s_trace_head + 1) % TRACE_FRAMES;
    if (s_trace_count < TRACE_FRAMES) s_trace_count++;
}

/* Dumps the worst frames by GPU time with their camera poses. Prefers host0:
 * (the PSPLink USB host filesystem) so a trace lands on the development
 * machine; falls back to the memory stick. */
/* Writes to the memory stick first and only falls back to host0: (PSPLink).
 * A host0: open BLOCKS while the USB link is down, and this runs inside the
 * quit path -- doing that first is what froze the game on exit when the link
 * had dropped. The local filesystem always answers. */
static int trace_dump(void) {
    FILE* f = fopen("ms0:/poi_trace.txt", "w");
    if (!f) f = fopen("host0:/poi_trace.txt", "w");
    if (!f) return 0;
    fprintf(f, "PoiRetro frame trace: %d frames, worst first\n", s_trace_count);
    fprintf(f, "%-7s %-7s %-8s %-7s %-7s %-7s %-7s %-7s\n",
            "cpu_ms", "gpu_ms", "frame_ms", "x", "y", "z", "yaw", "pitch");
    int shown = 0;
    char* done = (char*)calloc(s_trace_count > 0 ? s_trace_count : 1, 1);
    if (!done) { fclose(f); return 0; }
    while (shown < 80) {
        int best = -1;
        float best_gpu = -1.0f;
        for (int i = 0; i < s_trace_count; ++i) {
            if (done[i]) continue;
            if (s_trace[i].gpu_ms > best_gpu) { best_gpu = s_trace[i].gpu_ms; best = i; }
        }
        if (best < 0) break;
        done[best] = 1;
        const TraceFrame* t = &s_trace[best];
        fprintf(f, "%-7.2f %-7.2f %-8.2f %-7.2f %-7.2f %-7.2f %-7.3f %-7.3f\n",
                t->cpu_ms, t->gpu_ms, t->cpu_ms + t->gpu_ms,
                t->x, t->y, t->z, t->yaw, t->pitch);
        shown++;
    }
    free(done);
    fclose(f);
    return shown;
}

/* ── Home-button exit callback thread ───────────────────────────────────── */
static int exit_callback(int arg1, int arg2, void* common) {
    (void)arg1; (void)arg2; (void)common;
    sceKernelExitGame();
    return 0;
}

static int callback_thread(SceSize args, void* argp) {
    (void)args; (void)argp;
    int cbid = sceKernelCreateCallback("Exit Callback", exit_callback, NULL);
    sceKernelRegisterExitCallback(cbid);
    sceKernelSleepThreadCB();
    return 0;
}

static int setup_callbacks(void) {
    int thid = sceKernelCreateThread("update_thread", callback_thread, 0x11, 0xFA0, 0, 0);
    if (thid >= 0) sceKernelStartThread(thid, 0, 0);
    return thid;
}

/* ── Screenshot (16-bit RGBA5551 framebuffer) ───────────────────────────── */
static void save_tga(const char* filename, void* vram_buffer, int width, int height, int stride) {
    FILE* f = fopen(filename, "wb");
    if (!f) return;
    unsigned char header[18] = {
        0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        (unsigned char)(width & 0xFF), (unsigned char)((width >> 8) & 0xFF),
        (unsigned char)(height & 0xFF), (unsigned char)((height >> 8) & 0xFF),
        32, 0x20
    };
    fwrite(header, 1, 18, f);
    uint16_t* src = (uint16_t*)vram_buffer;
    uint32_t line[512];
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            uint16_t p = src[y * stride + x];
            uint8_t r = (uint8_t)(((p & 0x1F) * 255) / 31);
            uint8_t g = (uint8_t)((((p >> 5) & 0x1F) * 255) / 31);
            uint8_t b = (uint8_t)((((p >> 10) & 0x1F) * 255) / 31);
            uint8_t a = (p & 0x8000) ? 255 : 0;
            line[x] = b | (g << 8) | (r << 16) | ((uint32_t)a << 24);
        }
        fwrite(line, 4, width, f);
    }
    fclose(f);
    printf("[PSP] Saved screenshot to '%s'\n", filename);
}

/* Loop-stage breadcrumbs, kept to the PSPLink/hardware-test builds: when a
 * module appears to do nothing, the screen is not always visible to the host
 * but host0: file writes are, and these pinpoint the blocking call. */
#ifdef PSPLINK_RUN
static void dbg(const char* msg) {
    FILE* f = fopen("host0:/poi_app.log", "a");
    if (!f) f = fopen("ms0:/poi_app.log", "a");
    if (f) { fprintf(f, "%s\n", msg); fclose(f); }
}
#else
static void dbg(const char* msg) { (void)msg; }
#endif

static int file_exists(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) return 0;
    fclose(f);
    return 1;
}

/* Waits up to `ms` for any button press; returns 1 if one arrived. */
static int wait_any_button(int ms) {
    SceCtrlData pad;
    uint64_t t0 = psp_now_us();
    for (;;) {
        sceCtrlReadBufferPositive(&pad, 1);
        if (pad.Buttons & 0xFFF) return 1;
        sceDisplayWaitVblankStart();
        if ((psp_now_us() - t0) / 1000 > (uint64_t)ms) return 0;
    }
}

int main(int argc, char** argv) {
    (void)argc; (void)argv;
    setup_callbacks();

    /* Full 333 MHz CPU / 166 MHz GPU clock. */
    scePowerSetClockFrequency(333, 333, 166);

    /* NOTE: scePowerIdleTimerDisable() hangs on this firmware/CFW when called
     * from a PSPLink-loaded module, leaving a black screen and no output.
     * Suspend prevention is left to the user's Hold switch instead. */

    pspDebugScreenInit();
    printf("[PSP] PoiRetro starting (build %s %s)\n", __DATE__, __TIME__);

    void* fbp0 = (void*)0;
    void* fbp1 = (void*)(BUF_WIDTH * SCR_HEIGHT * 2);
    void* zbp  = (void*)((BUF_WIDTH * SCR_HEIGHT * 2) * 2);

    psp_font_init();

    sceGuInit();
    sceGuStart(GU_DIRECT, psp_dlist());
    sceGuDrawBuffer(GU_PSM_5551, fbp0, BUF_WIDTH);
    sceGuDispBuffer(SCR_WIDTH, SCR_HEIGHT, fbp1, BUF_WIDTH);
    sceGuDepthBuffer(zbp, BUF_WIDTH);
    sceGuOffset(2048 - (SCR_WIDTH / 2), 2048 - (SCR_HEIGHT / 2));
    sceGuViewport(2048, 2048, SCR_WIDTH, SCR_HEIGHT);

    sceGuDepthRange(0, 65535);
    sceGuDepthFunc(GU_LEQUAL);
    sceGuEnable(GU_DEPTH_TEST);
    sceGuDepthMask(GU_FALSE);

    sceGuEnable(GU_CLIP_PLANES);
    sceGuScissor(0, 0, SCR_WIDTH, SCR_HEIGHT);
    sceGuEnable(GU_SCISSOR_TEST);

    sceGuFrontFace(GU_CCW);
    sceGuEnable(GU_CULL_FACE);
    sceGuShadeModel(GU_SMOOTH);

    sceGuEnable(GU_TEXTURE_2D);
    sceGuTexWrap(GU_REPEAT, GU_REPEAT);
    sceGuTexFilter(GU_LINEAR, GU_NEAREST);
    sceGuTexFunc(GU_TFX_MODULATE, GU_TCC_RGBA);

    sceGuFinish();
    sceGuSync(0, 0);

    sceDisplayWaitVblankStart();
    sceGuDisplay(GU_TRUE);

    const char* map_path = "showcase_retro_baked.pbm";
    PbmMap* map = pbm_load("host0:/showcase_retro_baked.pbm");   /* PSPLink USB host fs */
    if (!map) map = pbm_load(map_path);
    if (!map) map = pbm_load("disc0:/showcase_retro_baked.pbm");
    if (!map) map = pbm_load("ms0:/showcase_retro_baked.pbm");
    if (!map) map = pbm_load("PSP/GAME/PoiRetro/showcase_retro_baked.pbm");
    if (!map) {
        printf("[PSP] Map '%s' not found. Place showcase_retro_baked.pbm next to the EBOOT.\n", map_path);
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

    printf("[PSP] Map '%s' loaded: %u meshes, %u verts\n",
           map->map_name, (unsigned)map->header.num_meshes, (unsigned)map->total_vertices);


    /* ── Profiling run, triggered by ms0:/poi_profile.cfg ─────────────── */
#ifdef HWTEST
    /* Hardware-test build: always profile, then stop. Meant to be loaded and
     * started over PSPLink USB (see run_psp_hw.sh), so it never touches the
     * memory stick and never enters the interactive loop. */
    printf("[HWTEST] running the profiling battery over PSPLink\n");
    psp_prof_suite(map);
    pbm_free(map);
    printf("[HWTEST] done; results on the host as host0:/poi_profile.txt\n");
    /* Stop and unload this module rather than just ending the thread: a
     * resident module holds ~200 KB of the kernel partition and blocks the next
     * load with ALREADY_LOADED. */
    sceKernelSelfStopUnloadModule(0, 0, NULL);
    return 0;
#endif
    if (file_exists("ms0:/poi_profile.cfg")) {
        psp_prof_suite(map);
        remove("ms0:/poi_profile.cfg");
        sceGuStart(GU_DIRECT, psp_dlist());
        sceGuClearColor(0x101418);
        sceGuClearDepth(65535);
        sceGuClear(GU_COLOR_BUFFER_BIT | GU_DEPTH_BUFFER_BIT);
        psp_draw_text(4.0f, 250.0f, 0xFF00FF55, "Profile written to ms0:/poi_profile.txt - press any button");
        sceGuFinish();
        sceGuSync(0, 0);
        sceGuSwapBuffers();
        wait_any_button(20000);
    }

    dbg("loop: ctrl setup begin");
    sceCtrlSetSamplingCycle(0);
    sceCtrlSetSamplingMode(PSP_CTRL_MODE_ANALOG);
    dbg("loop: ctrl setup done");

    /* Camera: standing in the courtyard, facing the archway, as the spawn
     * metadata suggests unless the map overrides it. */
    float cam_x = map->header.spawn_pos[0];
    float cam_y = map->header.spawn_pos[1];
    float cam_z = map->header.spawn_pos[2];
    float cam_yaw = map->header.spawn_rot;
    float cam_pitch = 0.05f;
    float home_x = cam_x, home_y = cam_y, home_z = cam_z, home_yaw = cam_yaw;

    int running = 1;
    int frame_count = 0;
    int display_mode = 0;
    RenderCfg cfg;
    render_cfg_default(&cfg);
    psp_render_overrides(&cfg);   /* host0:/poi_render.txt, if present */
    RenderStats stats = { 0, 0, 0 };

    int is_benchmark = HEADLESS_BENCHMARK;
    float orbit_angle = 0.5f;

    uint64_t last_tick = psp_now_us();
    float fps = 60.0f;
    int fps_frames = 0;
    float fps_timer = 0.0f;
    float patrol_time = 0.0f;
    float last_cpu_ms = 0.0f, last_gpu_ms = 0.0f;
    char hud_extra[128];
    char hud_input[64];
    int pad_hold = 0;
    hud_input[0] = '\0';

    printf("[PSP] Entering render loop (benchmark=%d)\n", is_benchmark);

    dbg("loop: entering main loop");
    while (running) {
        if (frame_count < 5) dbg("loop: frame top");
        uint64_t curr_tick = psp_now_us();
        float dt = (float)(curr_tick - last_tick) / 1000000.0f;
        if (dt <= 0.0001f || dt > 0.2f) dt = 1.0f / 60.0f;
        last_tick = curr_tick;
        patrol_time += dt;
        fps_timer += dt;
        fps_frames++;
        if (fps_timer >= 0.35f) {
            fps = (float)fps_frames / fps_timer;
            fps_frames = 0;
            fps_timer = 0.0f;
        }

        SceCtrlData pad;
        if (frame_count < 5) dbg("loop: before ctrl read");
        sceCtrlReadBufferPositive(&pad, 1);
        if (frame_count < 5) dbg("loop: after ctrl read");
        /* Live input readout: without it there is no way to tell "the controls
         * are undocumented" from "the pad is not being read". */
        snprintf(hud_input, sizeof(hud_input), "in: %3d,%3d btn %04X",
                 (int)pad.Lx, (int)pad.Ly, (unsigned)pad.Buttons);
        pad_hold = (pad.Buttons & PSP_CTRL_HOLD) ? 1 : 0;

        /* L + R together dumps the worst recent frames with camera poses. */
        if ((pad.Buttons & PSP_CTRL_LTRIGGER) && (pad.Buttons & PSP_CTRL_RTRIGGER)) {
            int n = trace_dump();
            printf("[PSP] Trace written (%d frames).\n", n);
            sceKernelDelayThread(300000);
        }

        if (!is_benchmark) {
            if (pad.Buttons & PSP_CTRL_START) {
                cam_x = home_x; cam_y = home_y; cam_z = home_z;
                cam_yaw = home_yaw; cam_pitch = 0.05f;
            }
            if (pad.Buttons & PSP_CTRL_SELECT) {
                display_mode = (display_mode + 1) % 3;
                cfg.display_mode = display_mode;
                sceKernelDelayThread(150000);
            }

            float move_speed = 9.5f * dt;
            if (pad.Buttons & PSP_CTRL_SQUARE) move_speed *= 2.5f;

            if (pad.Buttons & PSP_CTRL_TRIANGLE) {
                if (abs((int)pad.Lx - 128) > 20) {
                    float stick_x = (float)((int)pad.Lx - 128) / 128.0f;
                    cam_yaw += stick_x * 2.8f * dt;
                }
                if (abs((int)pad.Ly - 128) > 20) {
                    float stick_y = -(float)((int)pad.Ly - 128) / 128.0f;
                    cam_pitch += stick_y * 2.2f * dt;
                }
            } else {
                float in_fwd = 0.0f, in_strafe = 0.0f;
                if (abs((int)pad.Ly - 128) > 20) in_fwd = -(float)((int)pad.Ly - 128) / 128.0f;
                if (abs((int)pad.Lx - 128) > 20) in_strafe = (float)((int)pad.Lx - 128) / 128.0f;
                float fwd_x = sinf(cam_yaw), fwd_z = -cosf(cam_yaw);
                float right_x = cosf(cam_yaw), right_z = sinf(cam_yaw);
                cam_x += (fwd_x * in_fwd + right_x * in_strafe) * move_speed;
                cam_z += (fwd_z * in_fwd + right_z * in_strafe) * move_speed;
            }

            if (pad.Buttons & PSP_CTRL_UP)    { cam_x += sinf(cam_yaw) * move_speed;  cam_z += -cosf(cam_yaw) * move_speed; }
            if (pad.Buttons & PSP_CTRL_DOWN)  { cam_x -= sinf(cam_yaw) * move_speed;  cam_z -= -cosf(cam_yaw) * move_speed; }
            if (pad.Buttons & PSP_CTRL_LEFT)  { cam_x -= cosf(cam_yaw) * move_speed;  cam_z -= sinf(cam_yaw) * move_speed; }
            if (pad.Buttons & PSP_CTRL_RIGHT) { cam_x += cosf(cam_yaw) * move_speed;  cam_z += sinf(cam_yaw) * move_speed; }

            float turn_speed = 2.4f * dt;
            if (pad.Buttons & PSP_CTRL_LTRIGGER) cam_yaw -= turn_speed;
            if (pad.Buttons & PSP_CTRL_RTRIGGER) cam_yaw += turn_speed;

            float vert_speed = 8.0f * dt;
            if (pad.Buttons & PSP_CTRL_CROSS)  cam_y += vert_speed;
            if (pad.Buttons & PSP_CTRL_CIRCLE) cam_y -= vert_speed;

            if (cam_pitch > 1.45f)  cam_pitch = 1.45f;
            if (cam_pitch < -1.45f) cam_pitch = -1.45f;
        } else {
            orbit_angle += 0.02f;
            cam_x = center_x + sinf(orbit_angle) * radius;
            cam_y = center_y + radius * 0.4f;
            cam_z = center_z + cosf(orbit_angle) * radius;
            cam_yaw = atan2f(center_x - cam_x, -(center_z - cam_z));
            cam_pitch = -0.32f;
        }

        /* ── Frame: emit, finish, sync (timed), swap ─────────────────── */
        uint64_t t_emit0 = psp_now_us();
        sceGuStart(GU_DIRECT, psp_dlist());
        psp_render_scene(map, &cfg, cam_x, cam_y, cam_z, cam_yaw, cam_pitch,
                         patrol_time, &stats);

        snprintf(hud_extra, sizeof(hud_extra), "cpu %5.2f gpu %5.2f ms | pos %.1f %.1f %.1f",
                 last_cpu_ms, last_gpu_ms, cam_x, cam_y, cam_z);
        psp_draw_hud(map, &stats, fps, display_mode, hud_extra,
                     "Home: exit | L+R: dump trace", hud_input, pad_hold);

        sceGuFinish();
        uint64_t t_emit1 = psp_now_us();
        sceGuSync(0, 0);
        uint64_t t_sync1 = psp_now_us();

        last_cpu_ms = (float)(t_emit1 - t_emit0) / 1000.0f;
        last_gpu_ms = (float)(t_sync1 - t_emit1) / 1000.0f;

        TraceFrame tf;
        tf.cpu_ms = last_cpu_ms;
        tf.gpu_ms = last_gpu_ms;
        tf.x = cam_x; tf.y = cam_y; tf.z = cam_z;
        tf.yaw = cam_yaw; tf.pitch = cam_pitch;
        tf.draws = stats.draw_calls; tf.verts = stats.vertices;
        trace_push(&tf);

        if (frame_count < 5) dbg("loop: before swap");
        sceGuSwapBuffers();
        if (frame_count < 5) dbg("loop: after swap");
        frame_count++;

        if (is_benchmark) {
            if (frame_count == 60) {
                printf("[PSP] frame 60: %u verts, %.1f fps, cpu %.2f gpu %.2f\n",
                       (unsigned)stats.vertices, fps, last_cpu_ms, last_gpu_ms);
                save_tga("screenshot_psp.tga", (void*)(0x04000000), SCR_WIDTH, SCR_HEIGHT, BUF_WIDTH);
            }
            if (frame_count >= 120) {
                printf("[PSP] benchmark done: %d frames, ~%.1f fps\n", frame_count, fps);
                trace_dump();
                running = 0;
            }
        }
    }

    pbm_free(map);
    printf("[PSP] Exiting.\n");
#ifdef PSPLINK_RUN
    /* Loaded over PSPLink: sceKernelExitGame would reset the device and drop
     * the USB link, so stop and unload just this module instead. */
    sceKernelSelfStopUnloadModule(0, 0, NULL);
#else
    sceKernelDelayThread(50000);
    sceKernelExitGame();
#endif
    return 0;
}
