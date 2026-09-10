#!/usr/bin/env bash
# test.sh — Unified launcher for PoiBuilder interactive tests, viewers, and benchmarks.
#
# Usage:
#   ./test.sh <target> [options]
#
# Available Targets:
#   ./test.sh raylib     - Interactive Raylib custom entity & physics ball pit playground
#   ./test.sh psp        - Interactive Sony PSP homebrew on PPSSPPSDL emulator
#   ./test.sh viewer     - Interactive Retro Map Viewer (fly camera + Key 'P' first-person play)
#   ./test.sh showcase   - Pre-bake showcase map in Godot (first-person playground or editor)
#   ./test.sh gui        - Interactive Editor GUI test harness (runs on active window)
#   ./test.sh gut        - Interactive GUT unit test suite inside Godot Editor
#   ./test.sh all        - Runs all automated headless verification suites in sequence
#   ./test.sh unit       - Runs headless GUT unit tests (alias for ./run_tests.sh)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-help}"
shift || true

case "$TARGET" in
    raylib|rl)
        exec "$REPO_DIR/run_raylib.sh" "$@"
        ;;
    psp)
        exec "$REPO_DIR/run_psp.sh" "$@"
        ;;
    viewer|retro)
        exec "$REPO_DIR/run_viewer.sh" "$@"
        ;;
    showcase|demo)
        exec "$REPO_DIR/run_showcase.sh" "$@"
        ;;
    gui)
        exec "$REPO_DIR/run_gui_tests.sh" --interactive "$@"
        ;;
    gut|unit)
        if [[ "${1:-}" == "--interactive" || "${1:-}" == "-i" ]]; then
            exec godot-mono --path "$REPO_DIR/project" --editor
        else
            exec "$REPO_DIR/run_tests.sh" "$@"
        fi
        ;;
    all)
        echo "=== [1/4] Running GUT Unit Test Suite ==="
        "$REPO_DIR/run_tests.sh"
        echo "=== [2/4] Running Real-Editor GUI Test Harness ==="
        "$REPO_DIR/run_gui_tests.sh"
        echo "=== [3/4] Running Sony PSP Headless Benchmark ==="
        cd "$REPO_DIR/retro_engine/psp" && ./run_psp_headless.sh
        echo "=== [4/4] Running Raylib Headless Entity Verification ==="
        cd "$REPO_DIR/retro_engine/raylib" && ./run_headless.sh
        echo "============================================================"
        echo " ALL TEST SUITES PASSED CLEANLY!"
        echo "============================================================"
        ;;
    help|--help|-h|*)
        echo "============================================================"
        echo " PoiBuilder Unified Test & Playground Launcher"
        echo "============================================================"
        echo "Interactive Modes:"
        echo "  ./test.sh raylib     - Interactive Raylib custom entity & physics ball pit playground"
        echo "  ./test.sh psp        - Interactive Sony PSP homebrew running on PPSSPPSDL"
        echo "  ./test.sh viewer     - Interactive Retro Map Viewer (Fly camera + Key 'P' play mode)"
        echo "  ./test.sh showcase   - Pre-bake showcase map in Godot (WASD character controller)"
        echo "  ./test.sh gui        - Interactive Editor GUI test harness (runs on active window)"
        echo "  ./test.sh gut        - Interactive GUT unit test suite inside Godot Editor"
        echo ""
        echo "Automated / Headless Modes:"
        echo "  ./test.sh all        - Runs all 4 test suites headlessly (GUT, GUI, PSP, Raylib)"
        echo "  ./test.sh unit       - Runs headless GUT unit test suite"
        echo "  ./test.sh psp -h     - Runs headless PSP benchmark"
        echo "  ./test.sh raylib -h  - Runs headless Raylib verification"
        echo "============================================================"
        ;;
esac
