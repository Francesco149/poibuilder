#!/usr/bin/env bash
# bake_splat.sh — Bake a scene's splat paint down to plain textures (the
# "switch to lightmaps" move). Runs headlessly over a .tscn containing PBMeshes.
#
# Usage:
#   ./bake_splat.sh /tmp/poibuilder_modern/playground.tscn
#
# After baking: painted faces carry baked composite tiles on plain
# StandardMaterial3Ds, splat data and UV2 are gone (free for LightmapGI), and
# UV1 points at tile slots. The scene is saved back in place.
#
# The baker runs INSIDE the project that owns the scene (its res:// references
# must resolve there); the baker script is copied in if missing.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENE="${1:-}"
if [ -z "$SCENE" ]; then
	echo "Usage: ./bake_splat.sh /path/to/scene.tscn"
	echo "  e.g. ./bake_splat.sh /tmp/poibuilder_modern/playground.tscn"
	exit 1
fi
case "$SCENE" in
	/*) ;; # already absolute
	*) SCENE="$(cd "$(dirname "$SCENE")" && pwd)/$(basename "$SCENE")" ;;
esac
[ -f "$SCENE" ] || { echo "ERROR: scene not found: $SCENE"; exit 1; }

# Find the owning project (walk up to project.godot).
PROJ_DIR="$(dirname "$SCENE")"
while [ "$PROJ_DIR" != "/" ] && [ ! -f "$PROJ_DIR/project.godot" ]; do
	PROJ_DIR="$(dirname "$PROJ_DIR")"
done
[ -f "$PROJ_DIR/project.godot" ] || { echo "ERROR: no project.godot above $SCENE"; exit 1; }

BAKER="$PROJ_DIR/bake_splat_in_place.gd"
if [ ! -f "$BAKER" ]; then
	cp "$REPO_DIR/project/test_scenes/bake_splat_in_place.gd" "$BAKER"
fi

cd "$PROJ_DIR"
GODOT_DISABLE_LEAK_CHECKS=1 godot-mono --headless --path "$PROJ_DIR" -s res://bake_splat_in_place.gd -- "$SCENE"
