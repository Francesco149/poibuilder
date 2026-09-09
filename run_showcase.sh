#!/usr/bin/env bash
# run_showcase.sh — Alias for showcase_map.sh
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/showcase_map.sh" "$@"
