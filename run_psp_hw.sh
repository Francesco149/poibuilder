#!/usr/bin/env bash
# run_psp_hw.sh — real-hardware profiling on a PSP over PSPLink USB.
#
# The PSP is the only machine that can measure PSP performance: PPSSPP
# rasterises on the host GPU with a huge texture cache and no shared memory
# bus, so a scene that crawls on hardware runs there at full speed. This script
# removes the manual loop around that fact. If no PSP is connected it says so
# and refuses to pretend: **performance numbers are real only when they come
# from here.** See HARDWARE-TESTING.md for what the emulator IS good for.
#
# ONE-TIME SETUP (30 seconds, on the device):
#   1. Copy the PSPLink files to ms0:/PSP/GAME/PSPLINK/ (setup_psplink.sh does it)
#   2. On the PSP: Game -> Memory Stick -> PSPLink. It prints "Waiting for
#      usbhostfs connection..." and stays there.
#   After that the device is only ever touched to *exit* one of our builds.
#
# EVERY RUN after that, from this machine:
#   ./run_psp_hw.sh              build the hardware-test PRX, reset the device,
#                                load it, wait for the results, print the report
#   ./run_psp_hw.sh --app        build + load the INTERACTIVE app instead (leaves
#                                it running so it can be played and screenshotted)
#   ./run_psp_hw.sh --keep       leave usbhostfs_pc running afterwards
#   ./run_psp_hw.sh --no-reset   skip the pre-load reset (debugging only: a device
#                                that is already clean loads fine, but see below)
#
# How it works: usbhostfs_pc serves ./retro_engine/psp/hwrun/ to the PSP as
# host0:. The test binary (built with -DHWTEST=1, target poiretro_psp_hwtest.prx)
# loads the map from host0:/ and writes host0:/poi_profile.txt straight into
# that directory on this machine, so results need no copying back either.
#
# WEDGE POLICY — why this resets before every load
# ---------------------------------------------------------------------------
# A module that exits by itself leaves the GE and the display controller in the
# state it died in. The NEXT load then succeeds, reports success, and never
# executes: black screen, no output, and easy to misread as a bug in the build
# under test. Measured over one afternoon: 2 of 4 runs wedged when the previous
# module had exited by itself, and 0 of 6 wedged after a reset. So the script
# resets first (a reboot, ~6 s, PSPLink comes back on its own), verifies that
# the profiler actually started writing, and retries the whole load up to
# MAX_ATTEMPTS times if it did not. A wedged device is a normal state to
# recover from here, not something to sit and wait on.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PSP_DIR="$REPO_DIR/retro_engine/psp"
HOSTDIR="$PSP_DIR/hwrun"
PSPLINK_SRC="${PSPLINK_SRC:-/tmp/psplinkusb}"
USBHOSTFS="$PSPLINK_SRC/usbhostfs_pc/usbhostfs_pc"
PSPSH_BIN="$PSPLINK_SRC/pspsh/pspsh"
PSPSH=("$PSPSH_BIN" -h 127.0.0.1)
PRX_NAME="poiretro_psp_hwtest.prx"
LOG="$HOSTDIR/poi_profile.txt"
WAIT_SECS="${WAIT_SECS:-240}"     # total wait for the result file to stop growing
LOAD_GRACE="${LOAD_GRACE:-25}"    # seconds allowed for the profiler's FIRST output
LINK_GRACE="${LINK_GRACE:-40}"    # seconds allowed for PSPLink to answer after a reset
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
KEEP=0
MODE=prof
NO_RESET=0
for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=1 ;;
        --app)  MODE=app; KEEP=1 ;;   # interactive build needs host0: to stay alive!
        --no-reset) NO_RESET=1 ;;
    esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

# All PSP compilation happens in the pinned pspdev container.
psp_make() {
    podman run --rm -v "$PSP_DIR:/src:Z" -w /src docker.io/pspdev/pspdev:latest \
        bash -c "export PATH=\$PATH:/usr/local/pspdev/bin; make $*"
}

[ -x "$USBHOSTFS" ] || die "usbhostfs_pc not built at $USBHOSTFS"
[ -x "$PSPSH_BIN" ] || die "pspsh not built at $PSPSH_BIN"

# ── Device helpers ───────────────────────────────────────────────────────────

# pspsh with a timeout; stdout only, because callers all grep it.
pspsh() {
    local t="$1"; shift
    timeout "$t" "${PSPSH[@]}" -n -e "$1" 2>/dev/null || true
}

link_ok() { [ -n "$(pspsh 25 'modlist' | grep 'UID:')" ]; }

wait_link() {
    local n="${1:-$LINK_GRACE}"
    for ((i = 0; i < n; i++)); do
        if link_ok; then echo "  link OK (${i}s)"; return 0; fi
        sleep 1
    done
    return 1
}

reset_device() {
    echo "  resetting the device (psplink reset -> fresh GE/display state)"
    timeout 30 "${PSPSH[@]}" -n -e "reset" >/dev/null 2>&1 || true
    wait_link || die "PSPLink did not come back after the reset.
  The PSP is sitting at the XMB: relaunch PSPLink (Game -> Memory Stick ->
  PSPLink), then re-run. Everything else in this run is unaffected."
}

poiretro_resident() { [ -n "$(pspsh 20 'modlist' | grep -i 'PoiRetro')" ]; }

# A live module blocks the next load (ALREADY_LOADED), and force-stopping one
# (modstop) wedges module startup for the rest of the session -- a reset is the
# only supported way to clear it.
load_module() {
    poiretro_resident && reset_device
    timeout 60 "${PSPSH[@]}" -n -e "ld host0:/$PRX_NAME" \
        || echo "  (pspsh returned non-zero; checking for results anyway)"
}

# The profiler writes its header within a few seconds of starting (the map load
# comes first). No bytes at all after LOAD_GRACE means the wedge above.
log_started() { [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" != "0" ]; }

# Load `PRX_NAME`, resetting first (unless --no-reset) and retrying the whole
# attempt if the module loads but never runs.
start_module_with_retries() {
    local attempt
    for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
        [ "$NO_RESET" = 0 ] && reset_device
        load_module
        for ((i = 0; i < LOAD_GRACE; i++)); do
            log_started && break
            sleep 1
        done
        if log_started; then
            echo "  module running (output started after ${i}s)"
            return 0
        fi
        if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
            echo "  no output after ${LOAD_GRACE}s: module loaded but never ran (wedge)."
            echo "  retrying with a fresh reset (attempt $((attempt + 1))/$MAX_ATTEMPTS)…"
        fi
    done
    die "the module never started after $MAX_ATTEMPTS attempts.
  That is no longer the wedge (which a reset clears) -- check, in order:
    1. '$PRX_NAME' present and current in $HOSTDIR?
    2. USB link stable? (unplug/replug; usbhostfs_pc reconnects by itself)
    3. PSPLink running on the device?
  See HARDWARE-TESTING.md -> 'Checklist: the module loads but nothing happens'."
}

# ── Build ────────────────────────────────────────────────────────────────────

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
rm -f "$HOSTDIR/poi_render.txt"     # runtime overrides must not leak between runs
ls -la "$HOSTDIR" | head -12

if pgrep -f "usbhostfs_pc.*$HOSTDIR" >/dev/null 2>&1; then
    echo "=== [3/5] usbhostfs_pc already running ==="
else
    echo "=== [3/5] Starting usbhostfs_pc (serving host0: = $HOSTDIR) ==="
    nohup "$USBHOSTFS" "$HOSTDIR" >/tmp/usbhostfs_pc.log 2>&1 &
    sleep 3
fi
pgrep -f "usbhostfs_pc" >/dev/null || { cat /tmp/usbhostfs_pc.log; die "usbhostfs_pc died"; }

echo "=== [3b/5] Checking the PSPLink USB link ==="
if ! link_ok; then
    cat <<'MSG'
No PSP answering over USB. Check, in order:
  1. Is a PSP plugged in and PSPLink running on it?
     (Game -> Memory Stick -> PSPLink -> "Waiting for usbhostfs connection...")
  2. Did the unit suspend? A suspended PSP drops the link; relaunch PSPLink and
     keep the Hold switch ON so it cannot sleep again.
  3. Is another of our builds running? Exit it with Home, then re-run.
  4. Never set up at all? Run ./setup_psplink.sh once (30 s, needs the device).
NOTE: PPSSPP is NOT a substitute for this. It is for "does it crash" and
"does it look right" only -- it cannot measure GE cost (see HARDWARE-TESTING.md).
MSG
    die "no PSPLink link -- nothing was measured"
fi
echo "link OK"

# ── Interactive app mode: reset, load, verify the display is ours ────────────

if [ "$MODE" = app ]; then
    echo "=== [4/5] Loading the interactive app ==="
    NO_RESET=0 start_module_with_retries || true
    sleep 4
    shot="$(timeout 25 "${PSPSH[@]}" -n -e "scrshot host0:/app_boot.bmp" 2>&1 || true)"
    if ! echo "$shot" | grep -q "0x4044000"; then
        echo "  the app is not driving the display yet (scrshot: $shot)"
        echo "  resetting and loading once more…"
        reset_device
        load_module
        sleep 8
        shot="$(timeout 25 "${PSPSH[@]}" -n -e "scrshot host0:/app_boot.bmp" 2>&1 || true)"
    fi
    echo "$shot" | grep -q "0x4044000" \
        && echo "  app is driving the display (frame_addr 0x4044000)" \
        || echo "  WARNING: display still not ours; see HARDWARE-TESTING.md diagnostics"
    # `make hwapp` begins with `make clean`, which deletes the TRACKED shipping
    # EBOOT.PBP; the profiling path restores it at the end, but this path would
    # otherwise return first and leave the tree with a deleted binary.
    echo "=== restoring the shipping build ==="
    psp_make all >/dev/null 2>&1 && psp_make test_build >/dev/null 2>&1 \
        || echo "(shipping rebuild failed; EBOOT.PBP may be missing)"
    echo "Take a screenshot any time with:"
    echo "  $PSPSH_BIN -n -e \"scrshot host0:/shot.bmp\"   # lands in $HOSTDIR (480x272x24 BMP)"
    echo "Baseline capture (480x272 BMP -> PNG):"
    echo "  python3 $REPO_DIR/retro_engine/bmp_scrshot.py $HOSTDIR/shot.bmp --out /tmp/shot.png"
    exit 0
fi

# ── Profiling run ────────────────────────────────────────────────────────────

echo "=== [4/5] Resetting the device and loading $PRX_NAME ==="
start_module_with_retries

echo "=== [5/5] Waiting for the run to finish (up to ${WAIT_SECS}s) ==="
prev=-1
stable=0
link_lost=0
for ((i = 0; i < WAIT_SECS; i++)); do
    cur=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
    if [ "$cur" != "0" ] && [ "$cur" = "$prev" ]; then
        stable=$((stable + 1))
        [ "$stable" -ge 3 ] && break
    else
        stable=0
    fi
    prev=$cur

    # Unplugging the PSP mid-run means the results are never coming -- host0:
    # IS the USB link. Say so instead of waiting out the timeout. Checked from
    # the host only (lsusb), so it adds no traffic to the measurement.
    if ! lsusb -d 054c:01c9 >/dev/null 2>&1; then
        echo "PSP left USB at ${i}s (unplugged or suspended)"
        link_lost=1
        break
    fi
    sleep 1
done

if [ ! -s "$LOG" ]; then
    if [ "$link_lost" = 1 ]; then
        die "the USB link dropped during the run.
  The app keeps running on the PSP but results go to host0: -- the link itself --
  so this run has nothing to report. Replug, re-run; usbhostfs_pc reconnects by
  itself."
    fi
    echo "--- usbhostfs_pc log ---"; tail -20 /tmp/usbhostfs_pc.log
    die "no results arrived"
fi

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
