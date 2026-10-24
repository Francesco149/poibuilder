#!/usr/bin/env bash
# PoiBuilder paint-stroke perf bench — REAL-GPU profiling of the paint path.
#
# Boots the SAME real-editor GUI harness as run_gui_tests.sh, but:
#   * on the machine's REAL display + REAL GPU — never xvfb, never
#     LIBGL_ALWAYS_SOFTWARE (software GL lies about every number this bench
#     exists to produce);
#   * with PB_PAINT_PERF=1, which runs the harness's paint-stroke bench:
#     fast strokes (press -> ONE multi-spacing motion event -> release)
#     through the plugin's real input path over a 3 m face and a 0.5 m tile,
#     splat and decal targets;
#   * with PB_PAINT_PROFILE=1, which arms PBPaintProfile's stage timers
#     (pick / interpolated dab walk / splat & decal pixel loops / texture
#     uploads) — one breakdown line per stroke plus a mean-per-stroke
#     aggregate.
#
# Output: all "[PAINT PERF]" lines are echoed at the end (also in /tmp file).
# Exit code = harness failure count.
set -uo pipefail
cd "$(dirname "$0")/project"

DISPLAY_ARGS=()
if [ -z "${DISPLAY:-}" ]; then
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then
        DISPLAY_ARGS+=(--display-driver wayland)
        echo "=== paint perf: no DISPLAY, using native Wayland ($WAYLAND_DISPLAY) ==="
    else
        echo "ERROR: no DISPLAY and no WAYLAND_DISPLAY — run this inside the" >&2
        echo "machine's graphical session (the bench needs the REAL GPU; xvfb" >&2
        echo "would measure software GL, not the iGPU)." >&2
        exit 2
    fi
fi

HARNESS_HOME="$(mktemp -d /tmp/pb_paint_perf_home.XXXXXX)"
# The dock layout lives in the PROJECT, not in HOME: pin the harness's own
# for the run and give the user's back afterwards (tools/pin_editor_layout.sh).
source "$(dirname "$PWD")/tools/pin_editor_layout.sh"
pin_editor_layout "$PWD" "$HARNESS_HOME"
trap 'restore_editor_layout; rm -rf "$HARNESS_HOME"' EXIT

OUT=$(mktemp /tmp/pb_paint_perf_out.XXXXXX)
HOME="$HARNESS_HOME" PB_GUI_TEST=1 PB_PAINT_PERF=1 PB_PAINT_PROFILE=1 \
    godot-mono --editor --rendering-driver opengl3 \
    "${DISPLAY_ARGS[@]}" \
    res://test_scenes/editor_gui_test.tscn 2>&1 | tee "$OUT"
STATUS=${PIPESTATUS[0]}

echo
echo "==================== [PAINT PERF] summary ===================="
grep -E "\[PAINT PERF\]|\[GUI TEST\] (PASS|FAIL): PAINT" "$OUT" || echo "(no PAINT PERF lines — did the bench run?)"
FAILURES=$(grep -oE "done, failures=[0-9]+" "$OUT" | grep -oE "[0-9]+$" || echo 1)
if grep -q "real button(s) held mid-run" "$OUT"; then
    echo ">>> This run received REAL input mid-run (a human click reached the"
    echo ">>> automated window — the bench shares your desktop). Every failure"
    echo ">>> above is suspect: rerun hands-off."
fi
echo "==============================================================="
rm -f "$OUT"
exit "$FAILURES"
