#!/usr/bin/env bash
# deploy_psp.sh — Stage a scratch-exported .pbm map onto the PSP and run the
# interactive app on device (via run_psp_hw.sh's PSPLink/usbhostfs pipeline).
#
# Usage:
#   ./deploy_psp.sh                       # newest .pbm in the default scratch exports
#   ./deploy_psp.sh path/to/map.pbm       # explicit map
#   ./deploy_psp.sh map.pbm --keep        # extra args pass through to run_psp_hw.sh
#
# Default scratch export dir: /tmp/poibuilder_scratch/exports/ (what the
# scratch project's Export dialog writes to with its default path).
# The map replaces the shipping slot map (showcase_retro_baked.pbm); restore
# it any time with ./showcase_map.sh (regenerates) — the file is not tracked.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRATCH_EXPORTS="/tmp/poibuilder_scratch/exports"
PSP_DIR="$REPO_DIR/retro_engine/psp"
SLOT_MAP="$PSP_DIR/showcase_retro_baked.pbm"

MAP=""
PASSTHROUGH=()
for arg in "$@"; do
	if [[ "$arg" == *.pbm ]]; then
		MAP="$arg"
	else
		PASSTHROUGH+=("$arg")
	fi
done

if [ -z "$MAP" ]; then
	MAP="$(ls -t "$SCRATCH_EXPORTS"/*.pbm 2>/dev/null | head -1 || true)"
fi
if [ -z "$MAP" ]; then
	MAP="$(ls -t "$REPO_DIR/project/exports"/*.pbm 2>/dev/null | head -1 || true)"
fi
if [ -z "$MAP" ] || [ ! -f "$MAP" ]; then
	echo "ERROR: no .pbm found. Export one from the scratch project first:"
	echo "  ./scratch.sh  →  toolbar 'Export...' → Format: PBM (writes"
	echo "  res://exports/exported_map.pbm)"
	echo "  (looks in $SCRATCH_EXPORTS then $REPO_DIR/project/exports)"
	exit 1
fi

echo "============================================================"
echo " PoiBuilder PSP Deploy (interactive)"
echo " Map: $MAP ($(du -h "$MAP" | cut -f1))"
echo "============================================================"

mkdir -p "$PSP_DIR"
cp -f "$MAP" "$SLOT_MAP"
echo "Staged as $(basename "$SLOT_MAP") — launching on device..."
echo

exec "$REPO_DIR/run_psp_hw.sh" --app "${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}"
