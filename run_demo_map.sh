#!/usr/bin/env bash
# run_demo_map.sh — Build (if missing) and open the ALPHA DEMO MAP — the small
# map that showcases every core feature (walls/door/stairs, splatting, decals,
# a scrolling-texture waterfall, particle emitters, billboards, and the
# lightmap-ready neon room with imported barrels). It backs the documentation's
# end-to-end walkthroughs and the frame-pacing benchmark.
#
# Usage:
#   ./run_demo_map.sh            # build if missing, then open in the editor
#   ./run_demo_map.sh --editor   # explicit editor launch
#   ./run_demo_map.sh --play     # build if missing, then play (FPS controller)
#   ./run_demo_map.sh --rebuild  # rebuild the scene even if it exists
#
# CONTAINMENT: headless steps run through tools/godot_guard.sh; the
# interactive launch at the end is the one uncapped process this script
# starts (the guard caps headless work — a user-facing editor window is
# meant to stay open). Only ONE Godot runs at a time: the interactive
# launch replaces the build step, never overlaps it.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$REPO_DIR/tools/godot_guard.sh"
DEMO_DIR="/tmp/poibuilder_alpha_demo"
SCENE_SRC="$REPO_DIR/project/test_scenes/alpha_demo_map.tscn"
LAUNCH_MODE="editor"
REBUILD=0

for arg in "$@"; do
	case "$arg" in
		--play|-p) LAUNCH_MODE="play" ;;
		--editor|-e) LAUNCH_MODE="editor" ;;
		--rebuild|-r) REBUILD=1 ;;
		*) DEMO_DIR="$arg" ;;
	esac
done

echo "============================================================"
echo " PoiBuilder Alpha Demo Map"
echo " Scene:  $SCENE_SRC"
echo " Target: $DEMO_DIR"
echo " Mode:   $LAUNCH_MODE"
echo " Controls (play): WASD walk | Space jump | Mouse look | Esc release"
echo "============================================================"

build_scene() {
	echo "== Building the demo scene headlessly (one editor boot for the class cache, then the build) ="
	if [ -x "$GUARD" ]; then
		"$GUARD" exec bash -c 'cd /work/project && timeout 180 godot-mono --headless --editor --quit-after 100' \
			> /tmp/pb_demo_import.log 2>&1 || true
		if grep -q "SCRIPT ERROR" /tmp/pb_demo_import.log; then
			echo "FAIL: script errors during editor boot:" >&2
			grep -A4 "SCRIPT ERROR" /tmp/pb_demo_import.log >&2
			exit 1
		fi
		"$GUARD" exec bash -c 'cd /work/project && godot-mono --headless -s - << "GDEOF"
extends SceneTree
func _init():
	var err := AlphaDemoMapBuilder.save_demo_scene("res://test_scenes/alpha_demo_map.tscn", true)
	print("alpha demo scene save: ", error_string(err))
	quit(0 if err == OK else 1)
GDEOF'
	else
		( cd "$REPO_DIR/project" \
			&& timeout 180 godot-mono --headless --editor --quit-after 100 > /tmp/pb_demo_import.log 2>&1 || true \
			&& godot-mono --headless -s - << 'GDEOF'
extends SceneTree
func _init():
	var err := AlphaDemoMapBuilder.save_demo_scene("res://test_scenes/alpha_demo_map.tscn", true)
	print("alpha demo scene save: ", error_string(err))
	quit(0 if err == OK else 1)
GDEOF
		)
	fi
}

if [ ! -f "$SCENE_SRC" ] || [ "$REBUILD" -eq 1 ]; then
	build_scene
else
	echo "== Scene exists, reusing it (--rebuild to force) =="
fi

if [ ! -f "$SCENE_SRC" ]; then
	echo "FAIL: $SCENE_SRC was not produced — see the log above." >&2
	exit 1
fi

echo "== [2/2] Preparing the standalone play project at $DEMO_DIR =="
rm -rf "$DEMO_DIR"
mkdir -p "$DEMO_DIR/addons"
cp -r "$REPO_DIR/project/addons/poibuilder" "$DEMO_DIR/addons/"
[ -d "$REPO_DIR/project/materials" ] && cp -r "$REPO_DIR/project/materials" "$DEMO_DIR/"
cp "$REPO_DIR/project/player.gd" "$DEMO_DIR/player.gd"
cp "$SCENE_SRC" "$DEMO_DIR/alpha_demo_map.tscn"

cat << EOF > "$DEMO_DIR/project.godot"
; Engine configuration file
config_version=5

[application]
config/name="PoiBuilder Alpha Demo Map"
config/features=PackedStringArray("4.7", "Forward Plus")
run/main_scene="res://alpha_demo_map.tscn"

[rendering]
renderer/rendering_method="gl_compatibility"

[editor_plugins]
enabled=PackedStringArray("res://addons/poibuilder/plugin.cfg")
EOF

echo "== Launching =="
if [[ "$LAUNCH_MODE" == "play" ]]; then
	exec godot-mono "$DEMO_DIR/project.godot"
else
	exec godot-mono --editor "$DEMO_DIR/project.godot" "res://alpha_demo_map.tscn"
fi
