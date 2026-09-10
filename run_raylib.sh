#!/usr/bin/env bash
# run_raylib.sh — Launches the interactive 3D Raylib Custom Engine & Entity Playground.
#
# Usage:
#   ./run_raylib.sh                                  # Launches interactive window
#   ./run_raylib.sh path/to/custom_map.pbm           # Loads custom PBM map
#   ./run_raylib.sh --headless                       # Runs 60-frame automated verification under Xvfb
#
# Controls (Interactive Window):
#   WASD: Move | Mouse: Look around | Shift: Sprint
#   Space / Left Click: Throw a physics bouncy ball into the scene / ball pit
#   R: Reset physics ball pit
#   T: Teleport player into the cutscene archway trigger area
#   M: Toggle walkable mesh navigation wireframe
#   P: Toggle particle emitter
#   ESC: Toggle mouse capture
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAYLIB_DIR="$REPO_DIR/retro_engine/raylib"
MAP_FILE="$REPO_DIR/retro_engine/psp/showcase_retro_baked.pbm"
for arg in "$@"; do
    if [[ "$arg" != -* && -f "$arg" ]]; then
        MAP_FILE="$arg"
    fi
done

echo "============================================================"
echo " PoiRetro Raylib Custom Engine & Entity Playground"
echo " Target Map: $MAP_FILE"
echo " Controls:"
echo "   WASD + Mouse: First-Person Look & Walk"
echo "   Shift: Sprint | Space / LMB: Throw Bouncy Ball"
echo "   R: Reset Ball Pit | T: Teleport to Trigger | M: Walkable Mesh | P: Particles"
echo "   ESC: Toggle Mouse Capture"
echo "============================================================"

cd "$RAYLIB_DIR"

if [ ! -f "raylib_runner" ] || [ "main.c" -nt "raylib_runner" ]; then
    echo "Compiling raylib_runner with system Raylib..."
    gcc main.c -O2 -I/usr/include -o raylib_runner -lraylib -lGL -lm -lpthread -ldl -lrt -lX11
fi

# X11-only program on a Wayland session: see xdisplay.sh for why a private
# `Xwayland :99` never shows a window and what to use instead.
source "$REPO_DIR/xdisplay.sh"
if ensure_display; then
    exec ./raylib_runner "$@"
elif command -v xvfb-run >/dev/null 2>&1; then
    echo "[DISPLAY] No X display available (install/start xwayland-satellite for a"
    echo "          visible window). Running headless under xvfb-run instead."
    exec xvfb-run -a ./raylib_runner "$@"
else
    echo "[DISPLAY] No X display and no xvfb-run; cannot start the window." >&2
    exit 1
fi
