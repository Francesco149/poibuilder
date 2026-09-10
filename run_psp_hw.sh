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
MODE=prof
for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=1 ;;
        --app)  MODE=app ;;   # interactive build instead of the profiling battery
    esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

# All PSP compilation happens in the pinned pspdev container.
psp_make() {
    podman run --rm -v "$PSP_DIR:/src:Z" -w /src docker.io/pspdev/pspdev:latest \
        bash -c "export PATH=\$PATH:/usr/local/pspdev/bin; make $*"
}

[ -x "$USBHOSTFS" ] || die "usbhostfs_pc not built at $USBHOSTFS
  git clone https://github.com/pspdev/psplinkusb.git $PSPLINK_SRC && (cd $PSPLINK_SRC/usbhostfs_pc && make) && (cd $PSPLINK_SRC/pspsh && make)"
[ -x "$PSPSH" ] || die "pspsh not built at $PSPSH"

if [ "$MODE" = app ]; then
    echo "=== [1/5] Building the interactive PRX ==="
    psp_make hwapp >/tmp/psp_hwtest_build.log 2>&1 \
        || { tail -30 /tmp/psp_hwtest_build.log; die "build failed (full log: /tmp/psp_hwtest_build.log)"; }
    PRX_NAME="poiretro_psp_app.prx"
else
    echo "=== [1/5] Building the hardware-test PRX ==="
    psp_make hwtest >/tmp/psp_hwtest_build.log 2>&1 \
        || { tail -30 /tmp/psp_hwtest_build.log; die "build failed (full log: /tmp/psp_hwtest_build.log)"; }
    PRX_NAME="poiretro_psp_hwtest.prx"
fi
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

echo "=== [3b/5] Checking the PSPLink USB link ==="
if ! timeout 25 "$PSPSH" -n -e "modlist" 2>/dev/null | grep -q "UID:"; then
    cat <<'MSG'
PSPLink is not answering on USB. Check, in order:
  1. Is PSPLink running on the PSP? (Game -> Memory Stick -> PSPLink)
  2. Did the unit suspend? A suspended PSP drops the USB link. Relaunch
     PSPLink, and keep the Hold switch on so it cannot sleep again.
  3. Is a homebrew of ours already running? Exit it with the Home button (or
     press Start+Select if that build still has it), then re-run.
MSG
    die "no PSPLink link"
fi
echo "link OK"

# Reset ONLY when a module is actually left over.
#
# A stale module keeps the GE and display controller in whatever state it died
# in, and the next module then loads, reports success and never executes — a
# black screen with no output, easy to misread as a bug in the new build.
# psplink's `reset` clears that.
#
# But resetting a HEALTHY device reboots the PSP out of PSPLink for no reason,
# and if PSPLink does not come back on its own you are left staring at the XMB
# with nothing running — which is exactly what happened. So: only reset when
# there is something to clear.
stale=$("$PSPSH" -n -e "modlist" 2>/dev/null | awk '/PoiRetro/{print $2}' | tr '\n' ' ')
if [ -n "$stale" ]; then
    echo "=== [3c/5] stale module(s) present ($stale) -- resetting psplink ==="
    "$PSPSH" -n -e "reset" >/dev/null 2>&1 || true
    for i in $(seq 1 40); do
        sleep 1
        if timeout 10 "$PSPSH" -n -e "modlist" 2>/dev/null | grep -q "UID:"; then
            echo "link back after reset (${i}s)"
            break
        fi
        [ "$i" = 40 ] && die "psplink did not come back after the reset.
  The PSP is now sitting at the XMB: relaunch PSPLink, then re-run."
    done
else
    echo "=== [3c/5] no stale module -- loading without a reset ==="
fi

echo "=== [4/5] Loading and starting $PRX_NAME over USB ==="
# A resident module blocks the next load (ALREADY_LOADED). The test binary
# unloads itself on exit, so normally there is nothing to clear.
#
# DELIBERATELY NOT `modstop`: force-stopping a module that is still running
# leaves this PSP unable to start any further module (they load, report
# success, and then never execute — a device reset is the only recovery).
for uid in $("$PSPSH" -n -e "modlist" 2>/dev/null | awk '/PoiRetro/{print $2}'); do
    if "$PSPSH" -n -e "modunld $uid" >/dev/null 2>&1; then
        echo "cleared leftover module $uid"
    else
        die "module $uid is still resident and will not unload harmlessly.
  It is probably still running: press Start+Select on the PSP to exit and
  unload it, then re-run. (Do not force it — that wedges module startup.)"
    fi
done
timeout 60 "$PSPSH" -n -e "ld host0:/$PRX_NAME" || echo "(pspsh returned non-zero; checking for results anyway)"

if [ "$MODE" = app ]; then
    echo "=== app running on the device (Home exits) ==="
    [ "$KEEP" = 0 ] && pkill -f "usbhostfs_pc.*$HOSTDIR" 2>/dev/null || true
    echo "Take a screenshot any time with:"
    echo "  $PSPSH -n -e \"scrshot host0:/shot.bmp\"   # lands in $HOSTDIR (480x272x24 BMP)"
    exit 0
fi

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

# `make hwtest` starts with `make clean` (the HWTEST objects must not be
# reused by the shipping build), which removes the tracked EBOOT.PBP. Put the
# shipping artifacts back so the tree stays clean after a profiling run.
echo "=== restoring the shipping build ==="
psp_make all >/dev/null 2>&1 && psp_make test_build >/dev/null 2>&1 || echo "(shipping rebuild failed)"

echo
echo "=== REPORT ==="
python3 "$REPO_DIR/retro_engine/pbm_profile_report.py" "$LOG"
