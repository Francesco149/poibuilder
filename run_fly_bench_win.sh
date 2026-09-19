#!/usr/bin/env bash
# run_fly_bench_win.sh — the INTERACTIVE fly bench on the NATIVE WINDOWS
# Godot, driven from WSL: any variant of the alpha demo map, fly mode only,
# frame-time graph + 1%-low overlay, on the GPU attached to Windows (the
# bench box's RTX 5060).
#
# Prereq: repo copy on the WINDOWS filesystem (see run_bench_win.sh). The
# fly window opens ON THE WINDOWS DESKTOP — sit at that machine (or reach
# its desktop) to fly it. Over ssh, this script blocks until you quit.
#
# Usage:
#   ./run_fly_bench_win.sh                      # the PB scene as-is, GL
#   ./run_fly_bench_win.sh retro_glb            # or pb | modern_glb
#   ./run_fly_bench_win.sh pb --renderer vulkan
#   ./run_fly_bench_win.sh --selftest=shot.png  # boot + screenshot, no flying
#
# Controls (also on the HUD):
#   click  capture mouse    WASD + mouse  fly     Shift  turbo (×3)
#   Space/E  up             Q/C  down             wheel  speed 1..50
#   1..5  photo poses (plaza waterfall doorway neon roof)   R  spawn
#   H/Tab  toggle HUD       G  toggle graph       Esc  release mouse, again quits
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/win_godot.sh
source "$REPO_DIR/tools/win_godot.sh"
win_godot_require_windows_fs "$REPO_DIR"
GODOT_EXE="$(win_godot_detect)"
echo "Windows Godot: $GODOT_EXE"

cd "$REPO_DIR/project"

VARIANT="pb"
RENDERER="gl"
SELFTEST=""
while [ "${1:-}" != "" ]; do
	case "$1" in
		--renderer) RENDERER="$2"; shift ;;
		gl|gl_compatibility|compatibility) RENDERER="gl" ;;
		vulkan|forward_plus|forward) RENDERER="vulkan" ;;
		--selftest=*) SELFTEST="${1#--selftest=}" ;;
		-h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
		*) VARIANT="$1" ;;
	esac
	shift
done
case "$VARIANT" in
	pb|retro_glb|modern_glb) ;;
	*) echo "unknown variant '$VARIANT' (pb | retro_glb | modern_glb)" >&2; exit 2 ;;
esac
if [ "$RENDERER" = "vulkan" ]; then
	DRIVER_ARGS="--rendering-method forward_plus --rendering-driver vulkan"
	RENDERER_NAME="forward_plus (Vulkan)"
else
	DRIVER_ARGS="--rendering-driver opengl3"
	RENDERER_NAME="gl_compatibility"
fi

# The GLB variants must exist; run_bench_win.sh owns the export.
if [ ! -f exports/alpha_demo_retro_baked.glb ] || [ ! -f exports/alpha_demo_modern.glb ]; then
	"$REPO_DIR/run_bench_win.sh" --export-only
fi

SELFTEST_ARGS=""
if [ -n "$SELFTEST" ]; then
	# Dev/CI: boot the rig, screenshot the HUD, quit — how an ssh session
	# verifies the interactive tool without a human flying it.
	SELFTEST_ARGS="--selftest=$(win_path "$REPO_DIR/project/$SELFTEST")"
fi

echo "============================================================"
echo " PoiBuilder fly bench — $VARIANT — $RENDERER_NAME (vsync off)"
echo "   click: capture mouse   WASD + mouse: fly   Shift: turbo"
echo "   Space/E: up   Q/C: down   wheel: speed"
echo "   1..5: photo poses   R: spawn   H/Tab: HUD   G: graph"
echo "   Esc: release mouse, Esc again quits"
echo "============================================================"

# The fly session is interactive: no timeout, no grep — let the window run.
"$GODOT_EXE" $DRIVER_ARGS -s res://test_scenes/fly_bench.gd -- \
	--variant=$VARIANT $SELFTEST_ARGS
