#!/usr/bin/env bash
# run_presets.sh — Master launcher to test and run environment presets (dawn, day, dusk, night)
# on both the Godot Retro Map Viewer and the Sony PSP engine.
#
# Usage:
#   ./run_presets.sh                       # Interactive menu / summary
#   ./run_presets.sh viewer [preset]       # Runs Godot viewer (default: all or chosen preset)
#   ./run_presets.sh psp [preset]          # Runs PSP engine (interactive)
#   ./run_presets.sh psp-headless [preset] # Runs PSP engine in headless benchmark mode
#   ./run_presets.sh test                  # Headless smoke test of all 4 presets on both engines
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-test}"
PRESET="${2:-}"

PRESETS=("dawn" "day" "dusk" "night")

case "$TARGET" in
    viewer)
        if [ -n "$PRESET" ]; then
            exec "$DIR/run_viewer_preset.sh" "$PRESET" "${@:3}"
        else
            echo "Running Godot viewer for presets: ${PRESETS[*]}"
            for p in "${PRESETS[@]}"; do
                echo "--> Launching viewer with preset: $p"
                "$DIR/run_viewer_preset.sh" "$p"
            done
        fi
        ;;
    psp)
        if [ -n "$PRESET" ]; then
            exec "$DIR/run_psp_preset.sh" "$PRESET" "${@:3}"
        else
            exec "$DIR/run_psp.sh" "${@:2}"
        fi
        ;;
    psp-headless|headless)
        if [ -n "$PRESET" ]; then
            exec "$DIR/retro_engine/psp/run_psp_headless.sh" "$PRESET" "${@:3}"
        else
            echo "Running PSP headless for all presets..."
            for p in "${PRESETS[@]}"; do
                echo "============================================================"
                echo " Testing PSP Preset: $p"
                echo "============================================================"
                "$DIR/retro_engine/psp/run_psp_headless.sh" "$p"
            done
        fi
        ;;
    test)
        echo "============================================================"
        echo " Smoke Testing All Environment Presets (Godot Viewer + PSP) "
        echo "============================================================"
        echo "[1/2] Testing PSP Headless Presets..."
        for p in "${PRESETS[@]}"; do
            echo "  --> PSP preset: $p"
            "$DIR/retro_engine/psp/run_psp_headless.sh" "$p" > /dev/null
            echo "      OK: $p screenshot generated"
        done

        echo "[2/2] Testing Godot Viewer Presets..."
        for p in "${PRESETS[@]}"; do
            echo "  --> Godot viewer preset: $p"
            xvfb-run -a "$DIR/run_viewer.sh" "$p" --screenshot="/tmp/viewer_${p}_smoke.png" > /dev/null 2>&1 || "$DIR/run_viewer.sh" "$p" --screenshot="/tmp/viewer_${p}_smoke.png" > /dev/null 2>&1
            echo "      OK: $p screenshot saved"
        done
        echo "=== All environment presets verified successfully on both engines! ==="
        ;;
    *)
        if [[ "$TARGET" == "dawn" || "$TARGET" == "day" || "$TARGET" == "dusk" || "$TARGET" == "night" ]]; then
            echo "Running viewer with preset: $TARGET"
            exec "$DIR/run_viewer_preset.sh" "$TARGET" "${@:2}"
        else
            echo "Unknown command: $TARGET"
            echo "Usage: $0 [viewer|psp|psp-headless|test] [dawn|day|dusk|night]"
            exit 1
        fi
        ;;
esac
