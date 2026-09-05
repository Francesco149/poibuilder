#!/usr/bin/env bash
# scratch.sh — Starts Godot on a fresh, isolated scratch project with the
# latest PoiBuilder plugin installed directly from this repository,
# without clobbering or polluting the git repository.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRATCH_DIR="${1:-/tmp/poibuilder_scratch}"

echo "============================================================"
echo " PoiBuilder Scratch Project Launcher"
echo " Target: $SCRATCH_DIR"
echo " Source: $REPO_DIR/project/addons/poibuilder"
echo "============================================================"

echo "== [1/3] Preparing clean scratch directory =="
rm -rf "$SCRATCH_DIR"
mkdir -p "$SCRATCH_DIR/addons"

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
config/features=PackedStringArray("4.3", "Forward Plus")
run/main_scene="res://playground.tscn"

[editor_plugins]
enabled=PackedStringArray("res://addons/poibuilder/plugin.cfg")
EOF

echo "== [3/3] Launching Godot Editor on scratch project =="
exec godot-mono --editor "$SCRATCH_DIR/project.godot"
