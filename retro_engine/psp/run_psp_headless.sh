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
# The benchmark captures the orbit at frame 60, freezes the camera, and
# captures again 20 frames later (screenshot_psp_scroll.tga). Two frames of the
# SAME camera are what make the animated UV scroll measurable: diff them, or
# correlate the scrolling mesh's pixels, to see which way the texture moves.
# NOTE: the TGA's alpha byte is 0 for every pixel (the PSP framebuffer is
# 5551), so it must be dropped or an image viewer shows a blank white frame.
if [ -f "screenshot_psp.tga" ]; then
    echo "Screenshot saved: screenshot_psp.tga"
    ls -lh screenshot_psp.tga
    python3 - <<'PYEOF'
import os
from PIL import Image
for name in ("screenshot_psp.tga", "screenshot_psp_scroll.tga"):
    if not os.path.exists(name):
        continue
    img = Image.open(name).convert("RGBA")
    img.putalpha(255)   # see the note above: the TGA alpha is meaningless
    out = name.replace(".tga", ".png")
    img.convert("RGB").save(out)
    print(f"Saved {out} ({img.size[0]}x{img.size[1]})")
PYEOF
fi
