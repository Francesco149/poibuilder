#!/usr/bin/env bash
# run_psp_preset.sh — Launches the Sony PSP Homebrew on PPSSPP with a specific environment preset.
#
# Usage:
#   ./run_psp_preset.sh dawn
#   ./run_psp_preset.sh day
#   ./run_psp_preset.sh dusk
#   ./run_psp_preset.sh night
#   ./run_psp_preset.sh --headless dawn    # Headless benchmark mode
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRESET="day"
ARGS=()

for arg in "$@"; do
    if [[ "$arg" == "dawn" || "$arg" == "day" || "$arg" == "dusk" || "$arg" == "night" ]]; then
        PRESET="$arg"
    else
        ARGS+=("$arg")
    fi
done

echo "=== Launching Sony PSP Homebrew on PPSSPP with preset: $PRESET ==="
exec "$DIR/run_psp.sh" "$PRESET" "${ARGS[@]}"
