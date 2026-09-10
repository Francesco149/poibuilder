#!/usr/bin/env bash
# run_viewer.sh — Launches the standalone Retro Map Viewer with Godot-style free camera.
#
# Usage:
#   ./run_viewer.sh                            # Loads default baked showcase map
#   ./run_viewer.sh res://path/to/my_map.glb   # Loads custom GLB map
#   ./run_viewer.sh /absolute/path/my_map.glb
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR/project"

MAP_ARG="${1:-res://test_scenes/showcase_retro_baked.glb}"

echo "============================================================"
echo " PoiBuilder Retro Map Viewer Launcher"
echo " Target Map: $MAP_ARG"
echo " Controls:"
echo "   WASD + Mouse: Fly (Free Cam) / Walk (Play Mode)"
echo "   Shift: Turbo boost (Fly) / Sprint (Play)"
echo "   Space: Ascend (Fly) / Jump (Play) | Q / C: Descend (Fly)"
echo "   1: Full Baked | 2: Vertex Colors | 3: Textures | 4: Wireframe | 5: Colliders Only"
echo "   P: Toggle Play Mode (First-Person Physics Test) | R: Respawn Player"
echo "   ESC: Toggle Mouse Capture | H or Tab: Toggle HUD"
echo "============================================================"

exec godot-mono test_scenes/retro_map_viewer.tscn --map="$MAP_ARG" "$@"
