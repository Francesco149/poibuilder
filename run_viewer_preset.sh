#!/usr/bin/env bash
# run_viewer_preset.sh — Launches Godot Retro Map Viewer with a specific environment preset.
#
# Usage:
#   ./run_viewer_preset.sh dawn
#   ./run_viewer_preset.sh day
#   ./run_viewer_preset.sh dusk
#   ./run_viewer_preset.sh night
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRESET="${1:-day}"

echo "=== Launching Godot Retro Map Viewer with preset: $PRESET ==="
exec "$DIR/run_viewer.sh" "$PRESET" "${@:2}"
