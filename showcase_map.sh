#!/usr/bin/env bash
# showcase_map.sh — Launches Godot on an isolated pre-bake showcase test map project.
#
# Allows showcasing the live editable/playable pre-bake map side-by-side with
# the retro baked export (run_viewer.sh).
#
# Usage:
#   ./showcase_map.sh           # Opens Godot Editor on the pre-bake showcase map
#   ./showcase_map.sh --editor  # Explicit editor launch
#   ./showcase_map.sh --play    # Boots directly into first-person playable game (WASD/Mouse)
#   ./showcase_map.sh /path/to/dir [--editor|--play]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHOWCASE_DIR="/tmp/poibuilder_showcase"
LAUNCH_MODE="editor"

for arg in "$@"; do
	if [[ "$arg" == "--play" || "$arg" == "-p" ]]; then
		LAUNCH_MODE="play"
	elif [[ "$arg" == "--editor" || "$arg" == "-e" ]]; then
		LAUNCH_MODE="editor"
	elif [[ "$arg" != -* ]]; then
		SHOWCASE_DIR="$arg"
	fi
done

echo "============================================================"
echo " PoiBuilder Pre-Bake Showcase Map Launcher"
echo " Target Directory: $SHOWCASE_DIR"
echo " Launch Mode:      $LAUNCH_MODE"
echo " Controls (Play mode):"
echo "   WASD / Arrows: Walk | Space: Jump | Mouse: Look | ESC: Release Mouse"
echo " Compare side-by-side with:"
echo "   ./run_viewer.sh (Retro Baked Map Viewer)"
echo "============================================================"

echo "== [1/3] Preparing clean showcase project directory =="
rm -rf "$SHOWCASE_DIR"
mkdir -p "$SHOWCASE_DIR/addons"

echo "== [2/3] Installing latest PoiBuilder plugin & showcase assets =="
cp -r "$REPO_DIR/project/addons/poibuilder" "$SHOWCASE_DIR/addons/"
if [ -d "$REPO_DIR/project/materials" ]; then
	cp -r "$REPO_DIR/project/materials" "$SHOWCASE_DIR/"
fi
cp "$REPO_DIR/project/player.gd" "$SHOWCASE_DIR/player.gd"

# Ensure pre-bake test map scene exists
if [ ! -f "$REPO_DIR/project/test_scenes/test_map_showcase.tscn" ]; then
	echo "Generating showcase scene..."
	godot-mono --headless --path "$REPO_DIR/project" -s - << 'EOF'
extends SceneTree
func _init():
	TestMapShowcaseBuilder.save_showcase_scene("res://test_scenes/test_map_showcase.tscn", true)
	quit(0)
EOF
fi

cp "$REPO_DIR/project/test_scenes/test_map_showcase.tscn" "$SHOWCASE_DIR/showcase_map.tscn"

# Project configuration
cat << 'EOF' > "$SHOWCASE_DIR/project.godot"
; Engine configuration file.
config_version=5

[application]
config/name="PoiBuilder Showcase Map (Pre-Bake)"
config/features=PackedStringArray("4.7", "Forward Plus")
run/main_scene="res://showcase_map.tscn"

[editor_plugins]
enabled=PackedStringArray("res://addons/poibuilder/plugin.cfg")
EOF

if [[ "$LAUNCH_MODE" == "play" ]]; then
	echo "== [3/3] Booting playable showcase game =="
	exec godot-mono "$SHOWCASE_DIR/project.godot"
else
	echo "== [3/3] Launching Godot Editor on showcase map =="
	exec godot-mono --editor "$SHOWCASE_DIR/project.godot" "res://showcase_map.tscn"
fi
