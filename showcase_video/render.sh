#!/usr/bin/env bash
# render.sh — render one showcase session to a PNG frame sequence.
#
#   ./showcase_video/render.sh <session> [shot,shot,...]
#
# Runs a REAL Godot editor under Xvfb on a 1920x1080 screen with an isolated
# editor HOME, opens res://showcase/showcase_recorder.tscn, and the director
# drives the editor frame by frame, writing every rendered frame to
# bake/<session>/frames/NNNNNN.png plus the cursor/event/manifest sidecars.
#
# Everything downstream (crop, captions, transitions) reads those frames, so a
# session only has to be rendered once no matter how the edit changes.
#
#   PB_SHOWCASE_* env knobs: OUT (output dir), SCREEN (Xvfb geometry),
#   FRESH_HOME=1 (throw away the cached editor home), KEEP_GOING=1
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION="${1:?usage: render.sh <session> [only,..., then pass extra args after --]}"
shift || true

ONLY="${1:-}"
if [ -n "$ONLY" ]; then shift || true; fi

OUT="${PB_SHOWCASE_OUT:-$REPO/showcase_video/bake/$SESSION}"
SCREEN="${PB_SHOWCASE_SCREEN:-1920x1080x24}"
HOME_DIR="${PB_SHOWCASE_HOME:-$REPO/showcase_video/bake/.home}"

if [ "${PB_SHOWCASE_FRESH_HOME:-0}" = "1" ]; then
    rm -rf "$HOME_DIR"
fi
mkdir -p "$HOME_DIR"

# Session scripts live under res://showcase/sessions; the smoke/dev session is
# not part of the shipped set but must be renderable the same way.
SESSION_SCRIPT="$REPO/project/showcase/sessions/$SESSION.gd"
if [ ! -f "$SESSION_SCRIPT" ]; then
    echo "no such session: $SESSION_SCRIPT" >&2
    exit 2
fi

echo "=== showcase render: session=$SESSION only=${ONLY:-<all>} ==="
echo "    out:  $OUT"
echo "    home: $HOME_DIR"
mkdir -p "$OUT"
# Each shot owns its directory (frames/cursor/events), so a partial render
# replaces exactly the beats it records and leaves the rest untouched.

LOG="$OUT/render.log"
# Godot resolves res:// from the project directory found upward from the CWD;
# without this it starts the Project Manager and never loads the scene.
cd "$REPO/project"

# A NEW class_name script (e.g. a new session or a shared helper) is only
# registered by an editor filesystem scan, and a session loaded before that
# scan fails to resolve the type. One cheap editor boot keeps the class cache
# warm — the same lesson run_tests.sh encodes.
if [ "${PB_SHOWCASE_SKIP_CACHE_WARM:-0}" != "1" ]; then
    HOME="$HOME_DIR" timeout 300 godot-mono --headless --editor --quit-after 90 \
        > "$OUT/cache_warm.log" 2>&1 || true
fi

TIMEOUT="${PB_SHOWCASE_TIMEOUT:-2400}"
set -x
timeout "$TIMEOUT" env HOME="$HOME_DIR" \
LIBGL_ALWAYS_SOFTWARE=1 \
PB_SHOWCASE_SESSION="$SESSION" \
PB_SHOWCASE_OUT="$OUT" \
PB_SHOWCASE_ONLY="$ONLY" \
    xvfb-run -a -s "-screen 0 $SCREEN" \
    godot-mono --editor --rendering-driver opengl3 \
    --resolution "${SCREEN%x*}" \
    res://showcase/showcase_recorder.tscn 2>&1 | tee "$LOG"
set +x

if grep -q "FAIL" "$LOG"; then
    echo "--- failed checks ---" >&2
    grep "FAIL" "$LOG" >&2
fi
FRAMES=$(find "$OUT/frames" -name '*.png' | wc -l)
echo "=== session $SESSION: $FRAMES frames -> $OUT ==="
grep -E "^\[showcase\] shot " "$LOG" || true
