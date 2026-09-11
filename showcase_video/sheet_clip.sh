#!/usr/bin/env bash
# sheet_clip.sh — timestamped contact sheet for any video, for picking in/out
# points (the EDL's `at` / `dur` values are content-specific).
#
#   ./showcase_video/sheet_clip.sh showcase_video/source/psp-handheld.mp4
#   ./showcase_video/sheet_clip.sh <file> [tiles_w] [tiles_h] [out.png]
#
# One tile per second by default, with the time burned into each tile.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="${1:?usage: sheet_clip.sh <video> [tiles_w] [tiles_h] [out.png]}"
W="${2:-6}"
H="${3:-6}"
OUT="${4:-$REPO/showcase_video/bake/$(basename "${FILE%.*}")-sheet.png}"

[ -f "$FILE" ] || { echo "no such file: $FILE" >&2; exit 2; }
mkdir -p "$(dirname "$OUT")"

DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$FILE")
# one tile per second, capped at the grid size
RATE=$(awk -v d="$DUR" -v n="$((W * H))" 'BEGIN { r = n / d; if (r > 1) r = 1; printf "%.4f", r }')

ffmpeg -v error -y -i "$FILE" -vf \
    "fps=$RATE,scale=320:-1,drawtext=text='%{pts\\:hms}':x=6:y=6:fontsize=22:fontcolor=yellow:box=1:boxcolor=black@0.6,tile=${W}x${H}" \
    -frames:v 1 "$OUT"
echo "$(basename "$FILE"): ${DUR}s -> $OUT (${W}x${H} tiles at ${RATE}/s)"
