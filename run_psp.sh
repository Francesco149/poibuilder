#!/usr/bin/env bash
# run_psp.sh — Launches the interactive Sony PSP Homebrew on the PPSSPPSDL emulator.
#
# Usage:
#   ./run_psp.sh                                  # Launches interactive PPSSPPSDL window
#   ./run_psp.sh --headless                       # Runs 120-frame headless benchmark test
#
# Controls (In Emulator Window):
#   Analog Stick / Arrow Keys: Fly forward/backward, strafe left/right
#   Hold Triangle + Analog Stick: Full 360° Look/Tilt
#   Square: 2.5x Turbo Boost
#   LT / RT (Q / E keys on PC): Turn camera left / right (Yaw)
#   Cross (X / Z key on PC): Fly UP
#   Circle (O / X key on PC): Fly DOWN
#   Select (V key on PC): Cycle render modes (Textured -> Lighting -> Wireframe)
#   Start (Space on PC): Reset camera to spawn
#   Start + Select: Quit game
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PSP_DIR="$REPO_DIR/retro_engine/psp"
EBOOT="$PSP_DIR/EBOOT.PBP"

for arg in "$@"; do
    if [[ "$arg" == "--headless" || "$arg" == "-h" ]]; then
        exec "$PSP_DIR/run_psp_headless.sh"
    fi
done

if [ ! -f "$EBOOT" ]; then
    echo "Building PSP Homebrew binaries..."
    "$PSP_DIR/build_psp.sh"
fi

# PPSSPPSDL is SDL and will use Wayland when available, but the X path needs a
# real display too; see xdisplay.sh.
source "$REPO_DIR/xdisplay.sh"
ensure_display || true

echo "============================================================"
echo " PoiRetro Sony PSP Homebrew Emulator Launcher"
echo " Executable: $EBOOT"
echo " Controls (Default Keyboard):"
echo "   Arrow Keys / WASD: Analog Stick Fly & Strafe"
echo "   Hold Triangle (S on PC) + Move: Look / Tilt"
echo "   Square (A on PC): Boost | Q / E: Turn Left / Right"
echo "   Z: Fly UP | X: Fly DOWN | V: Cycle Render Mode | Space: Reset"
echo "============================================================"

exec PPSSPPSDL "$EBOOT" "$@"
