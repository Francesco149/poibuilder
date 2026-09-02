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
# your real editor settings (last-opened scenes, layout, editor settings),
# and never trips crash-recovery prompts from either side.
set -uo pipefail
cd "$(dirname "$0")/project"

HARNESS_HOME="$(mktemp -d /tmp/pb_gui_home.XXXXXX)"
trap 'rm -rf "$HARNESS_HOME"' EXIT

HOME="$HARNESS_HOME" LIBGL_ALWAYS_SOFTWARE=1 PB_GUI_TEST=1 \
    exec xvfb-run -a -s "-screen 0 1600x900x24" \
    godot-mono --editor --rendering-driver opengl3 \
    res://test_scenes/editor_gui_test.tscn
