#!/usr/bin/env bash
# PoiBuilder interactive paint tracer.
#
# Boots a REAL editor on this machine's REAL display + GPU with
# PB_PAINT_TRACE=1, you paint the case that feels bad (fast strokes over a
# small face, whatever reproduces it), and when you close the editor the
# per-frame trace (/tmp/pb_paint_trace.log) is analyzed:
# frame-time distribution, hitch attribution (paint handler vs render/editor),
# input->drawn latency, timeline. The trace file is kept for deeper digs.
#
# Optional: pass a scene to open:  ./trace_paint.sh [res://-relative .tscn]
set -uo pipefail
cd "$(dirname "$0")/project"

DISPLAY_ARGS=()
if [ -z "${DISPLAY:-}" ]; then
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then
        DISPLAY_ARGS+=(--display-driver wayland)
        echo "=== paint trace: no DISPLAY, using native Wayland ($WAYLAND_DISPLAY) ==="
    else
        echo "ERROR: no DISPLAY and no WAYLAND_DISPLAY — run this inside the" >&2
        echo "machine's graphical session (the trace must see the real GPU)." >&2
        exit 2
    fi
fi

SCENE_ARGS=()
if [ $# -ge 1 ]; then
    SCENE_ARGS+=("$1")
fi

rm -f /tmp/pb_paint_trace.log
HARNESS_HOME="$(mktemp -d /tmp/pb_paint_trace_home.XXXXXX)"

echo
echo "==================== interactive paint trace ===================="
echo " 1. The editor opens (isolated HOME — your settings untouched)."
echo " 2. Create/open a mesh, open the Material dock, switch to PAINT,"
echo "    and paint EXACTLY the case that feels laggy (e.g. fast strokes"
echo "    across a 3x3 m face at the default brush)."
echo " 3. Close the editor window when done — the analysis prints here."
echo "================================================================="
echo

HOME="$HARNESS_HOME" PB_PAINT_TRACE=1 \
    godot-mono --editor --rendering-driver opengl3 "${DISPLAY_ARGS[@]}" "${SCENE_ARGS[@]}"
STATUS=$?

echo
echo "=== editor closed (exit $STATUS); analyzing the trace ==="
python3 "$(dirname "$0")/tools/analyze_paint_trace.py" /tmp/pb_paint_trace.log
echo
echo "trace kept at /tmp/pb_paint_trace.log"
rm -rf "$HARNESS_HOME"
exit 0
