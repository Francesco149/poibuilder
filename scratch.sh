#!/usr/bin/env bash
# scratch.sh — Starts Godot on an isolated scratch project with the actual showcase map
# and the latest PoiBuilder plugin, allowing safe editing, re-exporting, and testing in Raylib.
#
# Usage:
#   ./scratch.sh              # Launches Godot Editor on the actual showcase map
#   ./scratch.sh --play       # Boots directly into playable first-person game
#   ./scratch.sh /path/to/dir # Uses custom scratch directory
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
echo " PoiBuilder Scratch Project & Map Editor Launcher"
echo " Target Directory: $SCRATCH_DIR"
echo " Launch Mode:      $LAUNCH_MODE"
echo " Workflow:"
echo "   1. Edit geometry, entities, triggers, or ball pit in Godot"
echo "   2. Click 'Export' on toolbar, OR run: $SCRATCH_DIR/export_to_raylib.sh"
echo "   3. Run: ./run_raylib.sh to see your changes rendered in Raylib!"
echo "============================================================"

echo "== [1/4] Preparing clean scratch directory =="
rm -rf "$SCRATCH_DIR"
mkdir -p "$SCRATCH_DIR/addons" "$SCRATCH_DIR/exports" "$SCRATCH_DIR/test_scenes"

echo "== [2/4] Installing latest PoiBuilder plugin, assets & textures =="
cp -r "$REPO_DIR/project/addons/poibuilder" "$SCRATCH_DIR/addons/"
if [ -d "$REPO_DIR/project/materials" ]; then
    cp -r "$REPO_DIR/project/materials" "$SCRATCH_DIR/"
fi
cp "$REPO_DIR/project/player.gd" "$SCRATCH_DIR/player.gd"

# Ensure showcase scene exists
if [ ! -f "$REPO_DIR/project/test_scenes/test_map_showcase.tscn" ]; then
    echo "Generating showcase scene..."
    cat << 'EOF' > /tmp/gen_showcase.gd
extends SceneTree
func _init():
    TestMapShowcaseBuilder.save_showcase_scene("res://test_scenes/test_map_showcase.tscn", true)
    quit(0)
EOF
    godot-mono --headless --path "$REPO_DIR/project" -s /tmp/gen_showcase.gd
    rm -f /tmp/gen_showcase.gd

fi

cp "$REPO_DIR/project/test_scenes/test_map_showcase.tscn" "$SCRATCH_DIR/showcase_map.tscn"

# Project configuration
cat << 'EOF' > "$SCRATCH_DIR/project.godot"
; Engine configuration file.
config_version=5

[application]
config/name="PoiBuilder Showcase Map (Scratch)"
config/features=PackedStringArray("4.7", "Forward Plus")
run/main_scene="res://showcase_map.tscn"

[editor_plugins]
enabled=PackedStringArray("res://addons/poibuilder/plugin.cfg")
EOF

# Pre-scan editor filesystem to initialize class cache and import textures
echo "Initializing scratch project imports & class cache..."
godot-mono --headless --path "$SCRATCH_DIR" --editor --quit-after 100 >/dev/null 2>&1 || true

# One-command re-export and test script inside scratch project
cat << EOF > "$SCRATCH_DIR/export_to_raylib.sh"
#!/usr/bin/env bash
set -euo pipefail
DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
echo "Exporting modified map from scratch project to PBMv2..."
cat << 'GEN' > /tmp/run_export_pbm.gd
extends SceneTree
func _init():
    var scene = load("res://showcase_map.tscn").instantiate()
    var settings = PBMapExporter.ExportSettings.new()
    settings.export_mode = PBMapExporter.ExportMode.RETRO
    var out_path = "$REPO_DIR/retro_engine/psp/showcase_retro_baked.pbm"
    var err = PBMapExporter.export_retro_pbm(scene, out_path, settings)
    if err == OK:
        print("Successfully exported PBM to: ", out_path)
    else:
        printerr("Failed to export PBM, error: ", err)
    quit(err)
GEN
godot-mono --headless --path "\$DIR" -s /tmp/run_export_pbm.gd
rm -f /tmp/run_export_pbm.gd
echo "Map re-exported successfully! Launching Raylib demo..."
exec "$REPO_DIR/run_raylib.sh"
EOF
chmod +x "$SCRATCH_DIR/export_to_raylib.sh"

if [[ "$LAUNCH_MODE" == "play" ]]; then
    echo "== [3/4] Launching playable 3D character playground =="
    exec godot-mono "$SCRATCH_DIR/project.godot"
else
    echo "== [3/4] Launching Godot Editor on actual showcase map =="
    exec godot-mono --editor "$SCRATCH_DIR/project.godot" "res://showcase_map.tscn"
fi
