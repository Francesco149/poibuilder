#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Building PoiRetro PSP Homebrew using pspdev container ==="
podman run --rm -v "${SCRIPT_DIR}:/src:Z" -w /src docker.io/pspdev/pspdev:latest make clean all

echo "=== PSP Build complete ==="
ls -la "${SCRIPT_DIR}/poiretro_psp.elf" "${SCRIPT_DIR}/EBOOT.PBP"
