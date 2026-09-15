#!/usr/bin/env bash
# Build the PoiBuilder end-user docs site.
#
#   ./docs/site/build.sh              HTML from Markdown → docs/site/out
#   ./docs/site/build.sh --assets     extract screenshots/clips first
#   ./docs/site/build.sh --bundle     also copy out/ into addons/poibuilder/docs-site/
#   ./docs/site/build.sh --strict     fail on missing images/clips
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIR="$REPO/docs/site"
ASSETS=0
BUNDLE=0
STRICT=0
for arg in "$@"; do
    case "$arg" in
        --assets) ASSETS=1 ;;
        --bundle) BUNDLE=1 ;;
        --strict) STRICT=1 ;;
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done
if [ "$ASSETS" = 1 ]; then
    python3 "$DIR/extract_media.py"
fi
args=()
[ "$STRICT" = 1 ] && args+=(--strict)
[ "$BUNDLE" = 1 ] && args+=(--bundle)
exec python3 "$DIR/build.py" "${args[@]}"
