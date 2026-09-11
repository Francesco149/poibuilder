#!/usr/bin/env bash
# build.sh — assemble the showcase video from the EDL.
#
#   ./showcase_video/build.sh                    everything
#   ./showcase_video/build.sh --list             the timeline
#   ./showcase_video/build.sh --only intro,grid  re-cut two clips + the master
#   ./showcase_video/build.sh --preview 2       2-second previews of every clip
#   ./showcase_video/build.sh --verify           check the finished master
#
# Self-contained: the Python environment lives in showcase_video/.venv (uv) and
# ffmpeg is resolved vendored → $SHOWCASE_FFMPEG → PATH. Nothing is installed
# system-wide.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$REPO/showcase_video"
VENV="$DIR/.venv"

if [ ! -x "$VENV/bin/python" ]; then
    echo "== creating the showcase python environment (uv) =="
    if command -v uv >/dev/null 2>&1; then
        (cd "$DIR" && uv sync --quiet)
    else
        python3 -m venv "$VENV"
        "$VENV/bin/pip" install --quiet pillow
    fi
fi

export PYTHONPATH="$DIR/tools${PYTHONPATH:+:$PYTHONPATH}"
exec "$VENV/bin/python" -m showcase.build "$@"
