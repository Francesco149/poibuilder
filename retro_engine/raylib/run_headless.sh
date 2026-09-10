#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MAP_FILE="../../retro_engine/psp/showcase_retro_baked.pbm"
if [ ! -f "$MAP_FILE" ]; then
    echo "Warning: Map file not found at $MAP_FILE"
fi

echo "=== [1/2] Compiling Raylib Custom Entity Test Runner ==="
gcc main.c -O2 -I/usr/include -o raylib_runner -lraylib -lGL -lm -lpthread -ldl -lrt -lX11
echo "=== [2/2] Running Headless Verification under xvfb-run ==="
xvfb-run -a ./raylib_runner "$MAP_FILE" --headless

if [ -f "raylib_proof_of_concept.png" ]; then
    ls -lh raylib_proof_of_concept.png
fi
