#!/usr/bin/env bash
# PoiBuilder editor GUI test harness.
#
# Reproduction testing for VIEWPORT interactions: boots a REAL editor under
# Xvfb (software GL), opens test_scenes/editor_gui_test.tscn, and the scene
# drives synthesized mouse events through the input pipeline — clicking
# meshes and drag-creating a shape — asserting the observable outcomes.
#
# Headless GUT cannot cover this layer: click-picking, gizmo drags, and the
# creation flow all depend on the live editor's picking machinery. Exit code
# = number of failures.
#
# The harness runs with an ISOLATED HOME so it neither reads nor pollutes
# your real editor settings, and never trips crash-recovery prompts from
# either side. The dock LAYOUT (and last-opened scenes) is not in HOME but in
# project/.godot/editor/editor_layout.cfg: the run pins the harness's own
# (test_scenes/editor_gui_layout.cfg) and restores yours afterwards
# (tools/pin_editor_layout.sh). Before v0.9.185 it read and overwrote yours,
# and its viewport clicks moved with whatever dock widths you had saved.
INTERACTIVE=0
for arg in "$@"; do
    if [[ "$arg" == "--interactive" || "$arg" == "-i" ]]; then
        INTERACTIVE=1
    fi
done

if [ "$INTERACTIVE" -eq 1 ]; then
    echo "=== Running Editor GUI Test Interactively on Active Display ==="
    exec godot-mono --editor res://test_scenes/editor_gui_test.tscn
fi

set -uo pipefail
cd "$(dirname "$0")/project"

HARNESS_HOME="$(mktemp -d /tmp/pb_gui_home.XXXXXX)"
# The dock layout lives in the PROJECT, not in HOME: pin the harness's own
# for the run and give the user's back afterwards (tools/pin_editor_layout.sh).
source "$(dirname "$PWD")/tools/pin_editor_layout.sh"
pin_editor_layout "$PWD" "$HARNESS_HOME"
trap 'restore_editor_layout; rm -rf "$HARNESS_HOME"' EXIT

OUT=$(mktemp /tmp/pb_gui_out.XXXXXX)
HOME="$HARNESS_HOME" LIBGL_ALWAYS_SOFTWARE=1 PB_GUI_TEST=1 \
    xvfb-run -a -s "-screen 0 1600x900x24" \
    godot-mono --editor --rendering-driver opengl3 \
    res://test_scenes/editor_gui_test.tscn 2>&1 | tee "$OUT" || true
if grep -q "done, failures=0" "$OUT"; then
    rm -f "$OUT"
    exit 0
fi

FAILURES=$(grep -oE "done, failures=[0-9]+" "$OUT" | grep -oE "[0-9]+" || echo 1)
rm -f "$OUT"
exit "$FAILURES"
