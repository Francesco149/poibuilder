#!/usr/bin/env bash
# run_seashore.sh — Build and export the SEASHORE showcase map (the retro
# pipeline's showpiece: GE-morphed sea and surf, flipbook water, additive sun
# path, wave-timed spray, swaying palms; see
# project/test_scenes/seashore_map_builder.gd) and run it.
#
# Usage:
#   ./run_seashore.sh             export project/exports/seashore.pbm (+ the
#                                 editor scene test_scenes/seashore_map.tscn)
#   ./run_seashore.sh --psp       ... then run it on the PSP (interactive app;
#                                 idle 12 s or Select+R = attract-mode tour)
#   ./run_seashore.sh --bench     ... then the profiling battery on the PSP
#                                 (sweeps the map's own camera path)
#   ./run_seashore.sh --ppsspp    ... then PPSSPP headless captures (LOOKS only;
#                                 never a performance number)
#   --no-export                   reuse the existing .pbm
#
# Textures: project/test_scenes/seashore/tex/ — the painted ones are committed
# source art; the procedural ones (sea/shallow/glint frames, foam, glow,
# shadow, spray) are regenerated here by retro_engine/gen_seashore_textures.py
# and gitignored.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$REPO_DIR/tools/godot_guard.sh"
PBM="$REPO_DIR/project/exports/seashore.pbm"
MODE="export"
EXPORT=1
PASS=()
for arg in "$@"; do
	case "$arg" in
		--psp) MODE="psp" ;;
		--bench) MODE="bench" ;;
		--ppsspp) MODE="ppsspp" ;;
		--no-export) EXPORT=0 ;;
		*) PASS+=("$arg") ;;
	esac
done

if [ "$EXPORT" = 1 ]; then
	echo "== [0/2] procedural textures (gitignored build output) =="
	python3 "$REPO_DIR/retro_engine/gen_seashore_textures.py" >/dev/null
	echo "== [1/2] editor boot (imports + class cache) =="
	"$GUARD" exec bash -c 'cd /work/project && timeout 240 godot-mono --headless --editor --quit-after 120' \
		> /tmp/pb_seashore_import.log 2>&1 || true
	if grep -q "SCRIPT ERROR\|Parse Error" /tmp/pb_seashore_import.log; then
		echo "FAIL: script errors during editor boot:" >&2
		grep -B2 -A6 "SCRIPT ERROR\|Parse Error" /tmp/pb_seashore_import.log | head -60 >&2
		exit 1
	fi
	echo "== [2/2] build + export =="
	"$GUARD" exec bash -c 'cd /work/project && timeout 600 godot-mono --headless -s res://test_scenes/seashore_export.gd' 2>&1 | tee /tmp/pb_seashore_export.log | grep -E "seashore|ERROR|error" | head -40
	[ -f "$PBM" ] || { echo "FAIL: $PBM was not written (see /tmp/pb_seashore_export.log)" >&2; exit 1; }
	ls -la "$PBM"
fi

case "$MODE" in
	psp)    exec "$REPO_DIR/deploy_psp.sh" "$PBM" "${PASS[@]+"${PASS[@]}"}" ;;
	bench)
		cp -f "$PBM" "$REPO_DIR/retro_engine/psp/poi_scratch.pbm"
		echo "poi_scratch.pbm" > "$REPO_DIR/retro_engine/psp/poi_map.txt"
		exec "$REPO_DIR/run_psp_hw.sh" --staged "${PASS[@]+"${PASS[@]}"}" ;;
	ppsspp)
		cp -f "$PBM" "$REPO_DIR/retro_engine/psp/seashore.pbm"
		cd "$REPO_DIR/retro_engine/psp" && exec ./run_psp_headless.sh seashore.pbm "${PASS[@]+"${PASS[@]}"}" ;;
esac
