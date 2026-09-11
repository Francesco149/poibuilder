#!/usr/bin/env bash
# scratch.sh — Starts Godot on a clean, isolated scratch playground project with an empty floor.
#
# Usage:
#   ./scratch.sh              # Launches Godot Editor on clean playground
#   ./scratch.sh --play       # Boots directly into playable first-person game
#   ./scratch.sh /path/to/dir # Custom scratch directory
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRATCH_DIR="/tmp/poibuilder_scratch"
LAUNCH_MODE="editor"

for arg in "$@"; do
	if [[ "$arg" == "--play" || "$arg" == "-p" ]]; then
		LAUNCH_MODE="play"
	elif [[ "$arg" == "--editor" || "$arg" == "-e" ]]; then
		LAUNCH_MODE="editor"
	elif [[ "$arg" != -* ]]; then
		SCRATCH_DIR="$arg"
	fi
done

echo "============================================================"
echo " PoiBuilder Playground Scratch Project Launcher"
echo " Target: $SCRATCH_DIR"
echo " Mode:   $LAUNCH_MODE"
echo "============================================================"

echo "== [1/3] Preparing clean scratch directory =="
rm -rf "$SCRATCH_DIR"
mkdir -p "$SCRATCH_DIR/addons" "$SCRATCH_DIR/materials"

echo "== [2/3] Installing latest PoiBuilder plugin & assets =="
cp -r "$REPO_DIR/project/addons/poibuilder" "$SCRATCH_DIR/addons/"
if [ -d "$REPO_DIR/project/materials" ]; then
	cp -r "$REPO_DIR/project/materials" "$SCRATCH_DIR/"
fi
cp "$REPO_DIR/project/player.gd" "$SCRATCH_DIR/player.gd"
cp "$REPO_DIR/project/main.tscn" "$SCRATCH_DIR/playground.tscn"

# Project configuration
cat << 'EOF' > "$SCRATCH_DIR/project.godot"
; Engine configuration file.
config_version=5

[application]
config/name="PoiBuilder Playground"
config/features=PackedStringArray("4.7", "Forward Plus")
run/main_scene="res://playground.tscn"

[editor_plugins]
enabled=PackedStringArray("res://addons/poibuilder/plugin.cfg")
EOF


echo "Initializing scratch project imports & class cache..."
godot-mono --headless --path "$SCRATCH_DIR" --editor --quit-after 100 >/dev/null 2>&1 || true

if [[ "$LAUNCH_MODE" == "play" ]]; then
	echo "== [3/3] Booting playable playground =="
	exec godot-mono "$SCRATCH_DIR/project.godot"
else
	echo "== [3/3] Launching Godot Editor on clean playground =="
	exec godot-mono --editor "$SCRATCH_DIR/project.godot" "res://playground.tscn"
fi
