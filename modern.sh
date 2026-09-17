#!/usr/bin/env bash
# modern.sh — Modern-workflow playground: 4k PBR props + live splat floor +
# FPS controller, as a disposable Godot project you can poke around in.
#
# Usage:
#   ./modern.sh              # launches the Godot Editor on the playground
#   ./modern.sh --play       # boots straight into the first-person playground
#   ./modern.sh /path/to/dir # custom playground directory
#
# Props come from the machine-local 4k assets (project/test_scenes/modern_assets/
# — extracted from /mnt/ephemeral/assets/*.gltf.zip on first run if needed).
# Nothing here is committed; the playground is rebuilt fresh every launch.
#
# Editor poking ideas: paint splats (Material dock → paint), inspect paint in
# the UV editor's "UV2 (Splat — read-only)" channel, poibuilderize a statue,
# export Retro/Modern GLB, then ./bake_splat.sh and bake a lightmap.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODERN_DIR="/tmp/poibuilder_modern"
ASSET_SRC="$REPO_DIR/project/test_scenes/modern_assets"
EPHEMERAL="/mnt/ephemeral/assets"
LAUNCH_MODE="editor"

BUILD_ONLY=0
for arg in "$@"; do
	if [[ "$arg" == "--play" || "$arg" == "-p" ]]; then
		LAUNCH_MODE="play"
	elif [[ "$arg" == "--editor" || "$arg" == "-e" ]]; then
		LAUNCH_MODE="editor"
	elif [[ "$arg" == "--build-only" ]]; then
		BUILD_ONLY=1
	elif [[ "$arg" != -* ]]; then
		MODERN_DIR="$arg"
	fi
done

echo "============================================================"
echo " PoiBuilder Modern Workflow Playground"
echo " Target: $MODERN_DIR"
echo " Mode:   $LAUNCH_MODE"
echo "============================================================"

echo "== [1/4] Preparing playground project =="
rm -rf "$MODERN_DIR"
mkdir -p "$MODERN_DIR/addons"

echo "== [2/4] Installing plugin, player & 4k assets =="
cp -r "$REPO_DIR/project/addons/poibuilder" "$MODERN_DIR/addons/"
if [ -d "$REPO_DIR/project/materials" ]; then
	cp -r "$REPO_DIR/project/materials" "$MODERN_DIR/"
fi
cp "$REPO_DIR/project/player.gd" "$MODERN_DIR/player.gd"
# The builder extends this into playground.tscn; the base keeps player+sky.
cp "$REPO_DIR/project/main.tscn" "$MODERN_DIR/playground_base.tscn"
cp "$REPO_DIR/project/test_scenes/modern_playground_builder.gd" "$MODERN_DIR/build_modern_playground.gd"
cp "$REPO_DIR/project/test_scenes/bake_splat_in_place.gd" "$MODERN_DIR/bake_splat_in_place.gd"

# Assets: prefer the repo's gitignored extraction; fall back to ephemeral zips.
if [ ! -d "$ASSET_SRC" ] || [ -z "$(ls -A "$ASSET_SRC" 2>/dev/null)" ]; then
	if [ -d "$EPHEMERAL" ]; then
		echo "   extracting 4k GLTFs from $EPHEMERAL (one-time, ~95 MB, gitignored)..."
		mkdir -p "$ASSET_SRC"
		for z in marble_bust_01_4k gothic_statue_4k coastal_cliff_02_4k; do
			unzip -oq "$EPHEMERAL/$z.gltf.zip" -d "$ASSET_SRC/$z"
		done
	else
		echo "   WARNING: no 4k assets at $ASSET_SRC or $EPHEMERAL — playground will be prop-less."
	fi
fi
if [ -d "$ASSET_SRC" ] && [ -n "$(ls -A "$ASSET_SRC" 2>/dev/null)" ]; then
	cp -r "$ASSET_SRC" "$MODERN_DIR/modern_assets"
fi

cat << 'EOF' > "$MODERN_DIR/project.godot"
; Engine configuration file.
config_version=5

[application]
config/name="PoiBuilder Modern Playground"
config/features=PackedStringArray("4.7", "Forward Plus")
run/main_scene="res://playground.tscn"

[editor_plugins]
enabled=PackedStringArray("res://addons/poibuilder/plugin.cfg")
EOF

echo "== [3/4] Importing assets (4k textures, one-time per launch) =="
GODOT_DISABLE_LEAK_CHECKS=1 godot-mono --headless --path "$MODERN_DIR" --import . >/dev/null 2>&1 || true

echo "==    Building playground scene (splat floor + props) =="
GODOT_DISABLE_LEAK_CHECKS=1 godot-mono --headless --path "$MODERN_DIR" -s res://build_modern_playground.gd 2>&1 | grep -E "splat|instanced|saved|ERROR|skip" || true
[ -f "$MODERN_DIR/playground.tscn" ] || { echo "ERROR: playground scene was not built"; exit 1; }

if [ "$BUILD_ONLY" = 1 ]; then
	echo "== build-only: playground ready at $MODERN_DIR/playground.tscn =="
	exit 0
fi

if [[ "$LAUNCH_MODE" == "play" ]]; then
	echo "== [4/4] Booting first-person playground =="
	exec godot-mono --path "$MODERN_DIR"
else
	echo "== [4/4] Launching Godot Editor on the modern playground =="
	exec godot-mono --editor --path "$MODERN_DIR" "res://playground.tscn"
fi
