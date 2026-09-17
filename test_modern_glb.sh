#!/usr/bin/env bash
# test_modern_glb.sh — Open a MODERN (unbaked) .glb export in the interactive
# viewer, booting straight into FPS play mode.
#
# Usage:
#   ./test_modern_glb.sh                    # newest .glb in the scratch exports
#   ./test_modern_glb.sh path/to/map.glb    # explicit file
#
# The modern export keeps live materials (splat surfaces carry their base
# texture — painted blends need the retro bake). This is the "does the plain
# .glb hold up outside PoiBuilder" check: geometry, colliders, decal quads,
# UV1 and stamp nodes all survive as ordinary scene content.
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
	echo "  ./scratch.sh  →  Export dialog → Modern Engine (GLB + Metadata) → res://exports/<name>.glb"
	echo "  (looks in $SCRATCH_EXPORTS then $REPO_DIR/project/exports)"
	exit 1
fi

exec "$REPO_DIR/run_viewer.sh" "$MAP" --play
