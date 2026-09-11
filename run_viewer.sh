#!/usr/bin/env bash
# run_viewer.sh — Launches the standalone Retro Map Viewer with Godot-style free camera.
#
# Usage:
#   ./run_viewer.sh                            # Loads default baked showcase map
#   ./run_viewer.sh dawn|day|dusk|night        # Loads test map with specified environment preset
#   ./run_viewer.sh res://path/to/my_map.glb   # Loads custom GLB map
#   ./run_viewer.sh --preset=dusk              # Explicit preset option
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR/project"

PRESET=""
MAP_ARG=""
PASSTHROUGH=()
for arg in "$@"; do
    if [[ "$arg" == "--preset="* ]]; then
        PRESET="${arg#--preset=}"
    elif [[ "$arg" == "dawn" || "$arg" == "day" || "$arg" == "dusk" || "$arg" == "night" ]]; then
        PRESET="$arg"
    elif [[ "$arg" == *.glb || "$arg" == *.gltf || "$arg" == res://* ]]; then
        MAP_ARG="$arg"
    else
        PASSTHROUGH+=("$arg")
    fi
done

DEFAULT_MAP="res://exports/showcase_retro_baked.glb"
if [ -n "$PRESET" ]; then
    if [ -f "$REPO_DIR/project/exports/showcase_retro_baked_${PRESET}.glb" ]; then
        DEFAULT_MAP="res://exports/showcase_retro_baked_${PRESET}.glb"
    elif [ -f "$REPO_DIR/project/test_scenes/showcase_retro_baked_${PRESET}.glb" ]; then
        DEFAULT_MAP="res://test_scenes/showcase_retro_baked_${PRESET}.glb"
    fi
elif [ ! -f "$REPO_DIR/project/exports/showcase_retro_baked.glb" ] && [ -f "$REPO_DIR/project/test_scenes/showcase_retro_baked.glb" ]; then
    DEFAULT_MAP="res://test_scenes/showcase_retro_baked.glb"
fi
MAP_TO_LOAD="${MAP_ARG:-$DEFAULT_MAP}"

PRESET_OPT=()
if [ -n "$PRESET" ]; then
    PRESET_OPT=("--preset=$PRESET")
fi
source "$REPO_DIR/xdisplay.sh"
ensure_display || true
echo "============================================================"
echo " PoiBuilder Retro Map Viewer Launcher"
echo " Target Map: $MAP_TO_LOAD ${PRESET:+(Preset: $PRESET)}"
echo " Controls:"
echo "   WASD + Mouse: Fly (Free Cam) / Walk (Play Mode)"
echo "   Shift: Turbo boost (Fly) / Sprint (Play)"
echo "   Space: Ascend (Fly) / Jump (Play) | Q / C: Descend (Fly)"
echo "   1: Full Baked | 2: Vertex Colors | 3: Textures | 4: Wireframe | 5: Colliders Only"
echo "   P: Toggle Play Mode (First-Person Physics Test) | R: Respawn Player"
echo "   ESC: Toggle Mouse Capture | H or Tab: Toggle HUD"
echo "============================================================"

exec godot-mono test_scenes/retro_map_viewer.tscn --map="$MAP_TO_LOAD" "${PRESET_OPT[@]}" "${PASSTHROUGH[@]}"
