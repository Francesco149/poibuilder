#!/usr/bin/env bash
# run_bench.sh — the Godot-side frame-pacing benchmark for the alpha demo map:
# the poibuilder scene AS IS vs the retro-baked GLB vs the modern GLB, flown
# through the same gameplay-like camera path while per-frame times are
# recorded. The full methodology lives in
# project/test_scenes/frame_pacing_bench.gd; results and how to read them are
# documented in docs/site/pages/performance.html.
#
# Usage:
#   ./run_bench.sh                 # export variants if missing, run all three
#   ./run_bench.sh --reexport      # force re-export the GLBs, then bench
#   ./run_bench.sh pb              # bench one variant (pb | retro_glb | modern_glb)
#   ./run_bench.sh --renderer vulkan          # forward_plus/Vulkan instead of GL
#   ./run_bench.sh --profile                  # ablation profile of the PB scene
#                                             #   (what is bottlenecking)
#   ./run_bench.sh --profile --renderer vulkan  # the same profile on Vulkan
#   ./run_bench.sh --export-only   # just (re)export the GLB variants, no bench
#
# CONTAINMENT: every Godot run goes through tools/godot_guard.sh — headless
# exports and the GPU bench alike (the bench needs a display: GUARD_X11).
# Runs are strictly sequential — ONE Godot at a time — and each bench pass
# quits itself; the guard's trap cleans up the container on exit.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$REPO_DIR/tools/godot_guard.sh"
export GUARD_X11=1
export GUARD_ASSETS=1

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

if [ "$EXPORT_ONLY" -eq 0 ]; then
	# The bench renders — it needs a real X display (xwayland-satellite :0 on
	# this workstation), not xvfb: the numbers must come from the GPU.
	# (--export-only is headless and skips this.)
	source "$REPO_DIR/xdisplay.sh"
	if ! ensure_display; then
		echo "FAIL: no X display available — the frame-pacing bench renders on a real GPU via xwayland-satellite." >&2
		exit 1
	fi
	echo "bench display: DISPLAY=$DISPLAY"
fi
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
echo " PoiBuilder frame-pacing benchmark (alpha demo map)"
echo " Renderer: $RENDERER_NAME on a real display (vsync off)"
echo "============================================================"

bench_export() {
	echo "== [1/2] Exporting the benchmark variants (headless, guarded) ="
	"$GUARD" exec bash -c 'cd /work/project && timeout 180 godot-mono --headless --editor --quit-after 100' \
		> /tmp/pb_bench_import.log 2>&1 || true
	if grep -q "SCRIPT ERROR" /tmp/pb_bench_import.log; then
		echo "FAIL: script errors during editor boot:" >&2
		grep -A4 "SCRIPT ERROR" /tmp/pb_bench_import.log >&2
		exit 1
	fi
	"$GUARD" exec bash -c 'cd /work/project && godot-mono --headless -s /work/tools/export_bench_variants.gd'
	# The freshly written .glb files need an import pass before a plain run
	# can load() them (testing.md's import footgun — load() hands back null
	# and you debug a phantom).
	"$GUARD" exec bash -c 'cd /work/project && timeout 180 godot-mono --headless --editor --quit-after 100' \
		> /tmp/pb_bench_import2.log 2>&1 || true
	if grep -q "SCRIPT ERROR" /tmp/pb_bench_import2.log; then
		echo "FAIL: script errors during post-export import:" >&2
		grep -A4 "SCRIPT ERROR" /tmp/pb_bench_import2.log >&2
		exit 1
	fi
}

if [ "$EXPORT_ONLY" -eq 1 ]; then
	bench_export
	echo "Exports done: $REPO_DIR/project/exports/alpha_demo_{retro_baked,modern}.glb"
	exit 0
fi

if [ "$REEXPORT" -eq 1 ] || [ ! -f "$REPO_DIR/project/exports/alpha_demo_retro_baked.glb" ] \
	|| [ ! -f "$REPO_DIR/project/exports/alpha_demo_modern.glb" ]; then
	bench_export
else
	echo "== [1/2] Variants already exported (--reexport to force) =="
fi

if [ "$PROFILE" -eq 1 ]; then
	echo "== [2/2] Ablation profile of the PB scene ($RENDERER_NAME) =="
	"$GUARD" exec bash -c "cd /work/project && timeout 600 godot-mono ${DRIVER_ARGS[*]} -s res://test_scenes/frame_pacing_bench.gd -- --ablate --out=res://exports/bench/pb_profile.${TAG}.json" 2>&1 | grep -E '^\[bench\]|^\[profile\]|SCRIPT ERROR|ERROR: .*missing' || true
	echo ""
	echo "Reports: $REPO_DIR/project/exports/bench/*.json"
	exit 0
fi

echo "== [2/2] Flying the bench (${VARIANTS[*]}) =="
for v in "${VARIANTS[@]}"; do
	echo "---- $v ----"
	"$GUARD" exec bash -c "cd /work/project && timeout 300 godot-mono ${DRIVER_ARGS[*]} -s res://test_scenes/frame_pacing_bench.gd -- --variant=$v --out=res://exports/bench/${TAG}_${v}.json" 2>&1 | grep -E '^\[bench\]|SCRIPT ERROR|ERROR: .*missing' || true
done

echo ""
echo "Reports: $REPO_DIR/project/exports/bench/*.json"
