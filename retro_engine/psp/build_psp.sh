#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== [1/4] Building Normal Interactive PoiRetro PSP Homebrew ==="
podman run --rm -v "${SCRIPT_DIR}:/src:Z" -w /src docker.io/pspdev/pspdev:latest make clean all

echo "=== [2/4] Building Headless Benchmark Test Binary (poiretro_psp_test.elf) ==="
podman run --rm -v "${SCRIPT_DIR}:/src:Z" -w /src docker.io/pspdev/pspdev:latest make test_build

echo "=== [3/4] Ensuring PBM Map Asset exists ==="
if [ ! -f "showcase_retro_baked.pbm" ]; then
    if [ -f "../../project/exports/showcase_retro_baked.glb" ]; then
        python3 ../pbm_conv.py ../../project/exports/showcase_retro_baked.glb showcase_retro_baked.pbm
    fi
fi

echo "=== [4/4] Creating Ready-to-Copy PSP Package & ZIP ==="
PKG_DIR="${SCRIPT_DIR}/package/PSP/GAME/PoiRetro"
mkdir -p "$PKG_DIR"

# Copy EBOOT and PBM map
cp "${SCRIPT_DIR}/EBOOT.PBP" "$PKG_DIR/EBOOT.PBP"
if [ -f "${SCRIPT_DIR}/showcase_retro_baked.pbm" ]; then
    cp "${SCRIPT_DIR}/showcase_retro_baked.pbm" "$PKG_DIR/showcase_retro_baked.pbm"
fi

cat << 'EOF' > "$PKG_DIR/README.txt"
PoiRetro — Retro 3D Map Renderer for Sony PlayStation Portable (PSP)
=====================================================================

INSTALLATION:
Copy the 'PSP' folder from this package directly to the root of your
PSP Memory Stick (e.g. ms0:/).
The executable will appear under: Game -> Memory Stick -> PoiRetro Map Renderer.

CONTROLS:
- Analog Stick: Fly forward / backward, strafe left / right
- LT / RT: Turn camera left / right (Yaw)
- Cross (X): Fly UP
- Circle (O): Fly DOWN
- Triangle / Square / D-Pad: Look up / down (Pitch)
- Start: Reset camera to spawn point
- Select: Toggle view mode (Textured + Baked Lighting / Vertex Lighting Only / Wireframe)
- Hold Square while moving: Boost / Turbo flight speed
EOF

cd "${SCRIPT_DIR}/package"
zip -r -q "${SCRIPT_DIR}/PoiRetro_PSP.zip" PSP
cd "$SCRIPT_DIR"

echo "=== PSP Build and Packaging Complete ==="
echo "Interactive ELF:     ${SCRIPT_DIR}/poiretro_psp.elf"
echo "Interactive EBOOT:   ${SCRIPT_DIR}/EBOOT.PBP"
echo "Test Benchmark ELF:  ${SCRIPT_DIR}/poiretro_psp_test.elf"
echo "PSP Memory Stick:    ${SCRIPT_DIR}/package/PSP/GAME/PoiRetro/"
echo "Ready-to-copy ZIP:   ${SCRIPT_DIR}/PoiRetro_PSP.zip"
ls -lh "${SCRIPT_DIR}/PoiRetro_PSP.zip" "${SCRIPT_DIR}/EBOOT.PBP"
