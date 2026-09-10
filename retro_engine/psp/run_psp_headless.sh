#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MAP_FILE="${1:-showcase_retro_baked.pbm}"
if [ ! -f "$MAP_FILE" ]; then
    echo "Warning: '$MAP_FILE' not found in $SCRIPT_DIR."
    if [ -f "../../project/exports/showcase_retro_baked.glb" ]; then
        echo "Converting showcase_retro_baked.glb -> $MAP_FILE..."
        python3 ../pbm_conv.py ../../project/exports/showcase_retro_baked.glb "$MAP_FILE"
    fi
fi

TEST_ELF="./poiretro_psp_test.elf"
if [ ! -f "$TEST_ELF" ]; then
    echo "Building test binary $TEST_ELF..."
    podman run --rm -v "${SCRIPT_DIR}:/src:Z" -w /src docker.io/pspdev/pspdev:latest make test_build
fi

echo "=== Running PoiRetro PSP Homebrew Test under PPSSPPHeadless ==="
echo "Map: $MAP_FILE"
echo "ELF: $TEST_ELF"

# Run with timeout to prevent hangs
PPSSPPHeadless "$TEST_ELF" "$MAP_FILE" --graphics=software --timeout=15

echo "=== Execution finished ==="
if [ -f "screenshot_psp.tga" ]; then
    echo "Screenshot saved: screenshot_psp.tga"
    ls -lh screenshot_psp.tga
    # Convert TGA to PNG for easy viewing/inspection
    python3 -c '
from PIL import Image
import os
if os.path.exists("screenshot_psp.tga"):
    img = Image.open("screenshot_psp.tga")
    img.save("screenshot_psp.png")
    print(f"Saved screenshot_psp.png ({img.size[0]}x{img.size[1]}, {len(img.getcolors(100000))} unique colors)")
'
fi
