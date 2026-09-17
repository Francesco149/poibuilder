#!/usr/bin/env bash
# test_baked_glb.sh — Open a retro-BAKED .glb export in the interactive map
# viewer (fly cam + FPS play mode, render-mode toggles).
#
# Usage:
#   ./test_baked_glb.sh                    # newest .glb in the scratch exports
#   ./test_baked_glb.sh path/to/map.glb    # explicit file
#
# The baked export carries atlas tiles + vertex-color lighting, so it renders
# identically anywhere — this is the "does the bake look right" check.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRATCH_EXPORTS="/tmp/poibuilder_scratch/exports"

MAP=""
for arg in "$@"; do
	if [[ "$arg" == *.glb || "$arg" == *.gltf ]]; then
		MAP="$arg"
	fi
done

if [ -z "$MAP" ]; then
	MAP="$(ls -t "$SCRATCH_EXPORTS"/*.glb 2>/dev/null | head -1 || true)"
fi
if [ -z "$MAP" ]; then
	MAP="$(ls -t "$REPO_DIR/project/exports"/*.glb 2>/dev/null | head -1 || true)"
fi
if [ -z "$MAP" ]; then
	echo "ERROR: no .glb found. Export one from the scratch project first:"
	echo "  ./scratch.sh  →  Export dialog → Retro Engine (Fully Baked) → res://exports/<name>.glb"
	echo "  (looks in $SCRATCH_EXPORTS then $REPO_DIR/project/exports)"
	exit 1
fi

exec "$REPO_DIR/run_viewer.sh" "$MAP"
