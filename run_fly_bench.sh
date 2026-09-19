#!/usr/bin/env bash
# run_fly_bench.sh — ONE COMMAND to fly the bench interactively: any variant
# of the alpha demo map, fly mode only (the Player node is removed), with a
# frame-time graph and 1%-low overlay. The numbers-and-path twin of this is
# run_bench.sh; this one is for standing where the dips happen and watching
# the graph spike.
#
# Usage:
#   ./run_fly_bench.sh                       # the PB scene as-is, GL
#   ./run_fly_bench.sh retro_glb             # or pb | modern_glb
#   ./run_fly_bench.sh pb --renderer vulkan  # the forward_plus axis
#   ./run_fly_bench.sh --reexport pb         # force re-export the GLBs first
#
# Controls (also on the HUD):
#   click  capture mouse    WASD + mouse  fly     Shift  turbo (×3)
#   Space/E  up             Q/C  down             wheel  speed 1..50
#   1..5  photo poses (plaza waterfall doorway neon roof)   R  spawn
#   H/Tab  toggle HUD       G  toggle graph       Esc  release mouse, again quits
#
# CONTAINMENT: like run_bench.sh, the run goes through tools/godot_guard.sh
# with GUARD_X11=1 (the window draws on the host display via xwayland-
# satellite; /dev/dri passthrough rides along). If the window doesn't appear,
# the persistent container may predate the X11 mounts:
#   GUARD_X11=1 GUARD_ASSETS=1 tools/godot_guard.sh recycle
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VARIANT="pb"
RENDERER="gl"
REEXPORT=0
while [ "${1:-}" != "" ]; do
	case "$1" in
		--reexport) REEXPORT=1 ;;
		--renderer) RENDERER="$2"; shift ;;
		gl|gl_compatibility|compatibility) RENDERER="gl" ;;
		vulkan|forward_plus|forward) RENDERER="vulkan" ;;
		-h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}"; exit 0 ;;
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

# The GLB variants must exist before the fly bench can load them; the export
# is headless and guarded, run_bench.sh owns it.
if [ "$REEXPORT" -eq 1 ] || [ ! -f "$REPO_DIR/project/exports/alpha_demo_retro_baked.glb" ] \
	|| [ ! -f "$REPO_DIR/project/exports/alpha_demo_modern.glb" ]; then
	"$REPO_DIR/run_bench.sh" --export-only
fi

export GUARD_X11=1
export GUARD_ASSETS=1
source "$REPO_DIR/xdisplay.sh"
if ! ensure_display; then
	echo "FAIL: no X display available — the fly bench draws on a real display via xwayland-satellite." >&2
	exit 1
fi

echo "============================================================"
echo " PoiBuilder fly bench — $VARIANT — $RENDERER_NAME (vsync off)"
echo "   click: capture mouse   WASD + mouse: fly   Shift: turbo"
echo "   Space/E: up   Q/C: down   wheel: speed"
echo "   1..5: photo poses   R: spawn   H/Tab: HUD   G: graph"
echo "   Esc: release mouse, Esc again quits"
echo "============================================================"

exec "$REPO_DIR/tools/godot_guard.sh" exec bash -c "cd /work/project && exec godot-mono $DRIVER_ARGS -s res://test_scenes/fly_bench.gd -- --variant=$VARIANT"
