#!/usr/bin/env bash
# sheet.sh — contact sheet from a rendered shot, for reviewing a beat without
# playing back the video.
#
#   ./showcase_video/sheet.sh <session> <shot> [tiles_w] [tiles_h] [crop]
#
#   crop: optional ffmpeg crop WxH+X+Y applied before tiling
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION="${1:?usage: sheet.sh <session> <shot> [tiles_w] [tiles_h] [crop]}"
SHOT="${2:?usage: sheet.sh <session> <shot> [tiles_w] [tiles_h] [crop]}"
W="${3:-5}"
H="${4:-4}"
CROP="${5:-}"

SLUG="$(printf '%s' "$SHOT" | tr '/ -' '___')"
OUT="${PB_SHOWCASE_OUT:-$REPO/showcase_video/bake/$SESSION}"
DIR="$OUT/shots/$SLUG/frames"
[ -d "$DIR" ] || { echo "no frames in $DIR" >&2; exit 2; }

N=$(find "$DIR" -name '*.png' | wc -l)
TILES=$((W * H))
STRIDE=$(awk -v n="$N" -v t="$TILES" 'BEGIN { s = int(n / t); if (s < 1) s = 1; printf "%d", s }')
FPS=$(awk -v s="$STRIDE" 'BEGIN { printf "%.4f", 60.0 / s }')

VF="fps=$FPS"
if [ -n "$CROP" ]; then
    VF="$VF,crop=$CROP"
fi
VF="$VF,scale=420:-1,tile=${W}x${H}:padding=2:color=0x181818"

mkdir -p "$OUT/sheets"
ffmpeg -v error -y -framerate 60 -i "$DIR/%06d.png" -vf "$VF" -frames:v 1 \
    "$OUT/sheets/$SLUG.png"
echo "$N frames -> $OUT/sheets/$SLUG.png (stride $STRIDE, $W x $H tiles)"
