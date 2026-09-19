#!/usr/bin/env bash
# run_bench_win.sh — the frame-pacing benchmark on the NATIVE WINDOWS Godot,
# driven from WSL: same variants, same path, same methodology as
# run_bench.sh, on the GPU that is attached to Windows (the bench box's RTX
# 5060 — WSL's paravirtualized /dev/dri is NOT the measurement target).
#
# Prereq: this copy of the repo lives on the WINDOWS filesystem
# (e.g. /mnt/c/Users/<you>/Documents/_devtools/poibuilder) — a Windows exe
# cannot use a \\wsl.localhost cwd. Godot is found under
# /mnt/c/Users/*/Documents/_devtools/Godot_v* (console exe preferred);
# override with GODOT_WIN_EXE=/mnt/c/path/Godot.exe.
#
# Usage (mirrors run_bench.sh):
#   ./run_bench_win.sh                          # export if needed, all three (GL)
#   ./run_bench_win.sh pb                       # one variant
#   ./run_bench_win.sh --renderer vulkan        # the forward_plus axis
#   ./run_bench_win.sh --profile                # ablation profile (PB scene)
#   ./run_bench_win.sh --reexport               # force re-export first
#   ./run_bench_win.sh --export-only            # just (re)export the GLBs
#
# Reports land in project/exports/bench/<renderer>_<variant>.json, exactly
# like the Linux side. One Godot at a time, strictly sequential; each pass
# quits itself. The bench window appears on the Windows desktop (vsync off,
# 1280x720) — leave it alone while a pass runs.
#
# PROP-LIBRARY CAVEAT: --export-only / --reexport REBUILD the demo map, and
# the builder's pack props (the market barrels) live outside the repo at
# /mnt/ephemeral on the dev machine — a Windows-side export bakes a map
# WITHOUT them (the builder now errors loudly about it). The right Windows
# flow is: rsync the dev machine's project/exports GLBs over and bench those
# (the launcher exports only when the GLBs are missing).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/win_godot.sh
source "$REPO_DIR/tools/win_godot.sh"
win_godot_require_windows_fs "$REPO_DIR"
GODOT_EXE="$(win_godot_detect)"
echo "Windows Godot: $GODOT_EXE"

cd "$REPO_DIR/project"
# -s wants a script path the WINDOWS side can read; win_path translates.
EXPORT_SCRIPT="$(win_path "$REPO_DIR/tools/export_bench_variants.gd")"

VARIANTS=("pb" "retro_glb" "modern_glb")
REEXPORT=0
RENDERER="gl"
PROFILE=0
EXPORT_ONLY=0
while [ "${1:-}" != "" ]; do
	case "$1" in
		--reexport) REEXPORT=1 ;;
		--renderer) RENDERER="$2"; shift ;;
		gl|gl_compatibility|compatibility) RENDERER="gl" ;;
		vulkan|forward_plus|forward) RENDERER="vulkan" ;;
		--profile) PROFILE=1 ;;
		--export-only) EXPORT_ONLY=1 ;;
		*) VARIANTS=("$1") ;;
	esac
	shift
done
if [ "$RENDERER" = "vulkan" ]; then
	DRIVER_ARGS=(--rendering-method forward_plus --rendering-driver vulkan)
	RENDERER_NAME="forward_plus (Vulkan)"
	TAG="vulkan"
else
	DRIVER_ARGS=(--rendering-driver opengl3)
	RENDERER_NAME="gl_compatibility"
	TAG="gl"
fi

echo "============================================================"
echo " PoiBuilder frame-pacing benchmark (alpha demo map) — WINDOWS"
echo " Renderer: $RENDERER_NAME"
echo "============================================================"

win_import() {
	echo "== import pass (headless editor boot) ="
	timeout 900 "$GODOT_EXE" --headless --editor --quit-after 200 \
		> /tmp/pb_bench_win_import.log 2>&1 || true
	if grep -q "SCRIPT ERROR" /tmp/pb_bench_win_import.log; then
		echo "FAIL: script errors during editor boot:" >&2
		grep -A4 "SCRIPT ERROR" /tmp/pb_bench_win_import.log >&2
		exit 1
	fi
}

win_export() {
	win_import
	echo "== exporting the benchmark variants (headless) ="
	timeout 600 "$GODOT_EXE" --headless -s "$EXPORT_SCRIPT"
	# The freshly written .glb files need an import pass before a plain run
	# can load() them (the import footgun — load() hands back null).
	win_import
}

if [ "$EXPORT_ONLY" -eq 1 ]; then
	win_export
	echo "Exports done: $REPO_DIR/project/exports/alpha_demo_{retro_baked,modern}.glb"
	exit 0
fi

if [ "$REEXPORT" -eq 1 ] || [ ! -f exports/alpha_demo_retro_baked.glb ] \
	|| [ ! -f exports/alpha_demo_modern.glb ]; then
	win_export
else
	echo "== [1/2] Variants already exported (--reexport to force) =="
fi

if [ "$PROFILE" -eq 1 ]; then
	echo "== [2/2] Ablation profile of the PB scene ($RENDERER_NAME) ="
	timeout 1200 "$GODOT_EXE" "${DRIVER_ARGS[@]}" -s res://test_scenes/frame_pacing_bench.gd -- \
		--ablate --out=res://exports/bench/pb_profile.${TAG}.json 2>&1 \
		| grep -E '^\[bench\]|^\[profile\]|SCRIPT ERROR|ERROR: .*missing' || true
	echo ""
	echo "Reports: $REPO_DIR/project/exports/bench/*.json"
	exit 0
fi

echo "== [2/2] Flying the bench (${VARIANTS[*]}) =="
for v in "${VARIANTS[@]}"; do
	echo "---- $v ----"
	timeout 900 "$GODOT_EXE" "${DRIVER_ARGS[@]}" -s res://test_scenes/frame_pacing_bench.gd -- \
		--variant=$v --out=res://exports/bench/${TAG}_${v}.json 2>&1 \
		| grep -E '^\[bench\]|SCRIPT ERROR|ERROR: .*missing' || true
done

echo ""
echo "Reports: $REPO_DIR/project/exports/bench/*.json"
