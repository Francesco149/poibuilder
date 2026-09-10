#!/usr/bin/env bash
# run_psp_hw.sh — real-hardware profiling on a PSP over PSPLink USB.
#
# The PSP is the only machine that can measure PSP performance: PPSSPP
# rasterises on the host GPU with a huge texture cache and no shared memory
# bus, so a scene that crawls on hardware runs there at full speed. This script
# removes the manual loop around that fact.
#
# ONE-TIME SETUP (30 seconds, on the device):
#   1. Copy the PSPLink files to ms0:/PSP/GAME/PSPLINK/ (setup_psplink.sh does it)
#   2. On the PSP: Game -> Memory Stick -> PSPLink. It prints "Waiting for
#      usbhostfs connection..." and stays there.
#   After that the device never needs to be touched again: no memory-stick
#   copies, no XMB navigation, no USB-mode toggling.
#
# EVERY RUN after that, from this machine:
#   ./run_psp_hw.sh              build the hardware-test PRX, load it over USB,
#                                wait for the results, print the report
#   ./run_psp_hw.sh --keep       leave usbhostfs_pc running afterwards
#
# How it works: usbhostfs_pc serves ./retro_engine/psp/hwrun/ to the PSP as
# host0:. The test binary (built with -DHWTEST=1, target poiretro_psp_hwtest.prx)
# loads the map from host0:/ and writes host0:/poi_profile.txt straight into
# that directory on this machine, so results need no copying back either.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PSP_DIR="$REPO_DIR/retro_engine/psp"
HOSTDIR="$PSP_DIR/hwrun"
PSPLINK_SRC="${PSPLINK_SRC:-/tmp/psplinkusb}"
USBHOSTFS="$PSPLINK_SRC/usbhostfs_pc/usbhostfs_pc"
PSPSH="$PSPLINK_SRC/pspsh/pspsh"
PRX_NAME="poiretro_psp_hwtest.prx"
LOG="$HOSTDIR/poi_profile.txt"
WAIT_SECS="${WAIT_SECS:-240}"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

die() { echo "ERROR: $*" >&2; exit 1; }

[ -x "$USBHOSTFS" ] || die "usbhostfs_pc not built at $USBHOSTFS
  git clone https://github.com/pspdev/psplinkusb.git $PSPLINK_SRC && (cd $PSPLINK_SRC/usbhostfs_pc && make) && (cd $PSPLINK_SRC/pspsh && make)"
[ -x "$PSPSH" ] || die "pspsh not built at $PSPSH"

echo "=== [1/5] Building the hardware-test PRX ==="
podman run --rm -v "$PSP_DIR:/src:Z" -w /src docker.io/pspdev/pspdev:latest \
    bash -c 'export PATH=$PATH:/usr/local/pspdev/bin; make hwtest' >/tmp/psp_hwtest_build.log 2>&1 \
    || { tail -30 /tmp/psp_hwtest_build.log; die "build failed (full log: /tmp/psp_hwtest_build.log)"; }
[ -f "$PSP_DIR/$PRX_NAME" ] || die "$PRX_NAME was not produced"

echo "=== [2/5] Staging host0: ($HOSTDIR) ==="
mkdir -p "$HOSTDIR"
rm -f "$LOG"
cp "$PSP_DIR/$PRX_NAME" "$HOSTDIR/$PRX_NAME"
cp "$PSP_DIR/showcase_retro_baked.pbm" "$HOSTDIR/showcase_retro_baked.pbm"
ls -la "$HOSTDIR"

if pgrep -f "usbhostfs_pc.*$HOSTDIR" >/dev/null 2>&1; then
    echo "=== [3/5] usbhostfs_pc already running ==="
else
    echo "=== [3/5] Starting usbhostfs_pc (serving host0: = $HOSTDIR) ==="
    nohup "$USBHOSTFS" "$HOSTDIR" >/tmp/usbhostfs_pc.log 2>&1 &
    sleep 3
fi
pgrep -f "usbhostfs_pc" >/dev/null || { cat /tmp/usbhostfs_pc.log; die "usbhostfs_pc died"; }

echo "=== [4/5] Loading and starting $PRX_NAME over USB ==="
timeout 60 "$PSPSH" -n -e "ld host0:/$PRX_NAME" || echo "(pspsh returned non-zero; checking for results anyway)"

echo "=== [5/5] Waiting for host0:/poi_profile.txt (up to ${WAIT_SECS}s) ==="
prev=-1
stable=0
for ((i = 0; i < WAIT_SECS; i++)); do
    cur=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
    if [ "$cur" != "0" ] && [ "$cur" = "$prev" ]; then
        stable=$((stable + 1))
        [ "$stable" -ge 3 ] && break
    else
        stable=0
    fi
    prev=$cur
    sleep 1
done
[ -s "$LOG" ] || { echo "--- usbhostfs_pc log ---"; tail -20 /tmp/usbhostfs_pc.log; die "no results arrived"; }

if [ "$KEEP" = 0 ]; then
    pkill -f "usbhostfs_pc.*$HOSTDIR" 2>/dev/null || true
fi

echo
echo "=== REPORT ==="
python3 "$REPO_DIR/retro_engine/pbm_profile_report.py" "$LOG"
