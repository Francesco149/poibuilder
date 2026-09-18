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
#   ./run_psp_hw.sh --keep       legacy: the usbhostfs_pc daemon is now kept
#                                alive by the psp-usbhostfs user service and
#                                reused across runs (see psp_link.sh); --keep
#                                only stops the EXIT trap from tidying a
#                                nohup-managed daemon
#   ./run_psp_hw.sh --no-reset   skip the pre-load reset (debugging only: a device
#                                that is already clean loads fine, but see below)
#   ./run_psp_hw.sh --preset N   run the time-of-day preset N (dawn|day|dusk|night)
#                                instead of the shipping map; also accepted as a
#                                bare word: `./run_psp_hw.sh night`.
#
# DEPLOYING A PRESET TO THE DEVICE is `--app --preset N`: the preset's .pbm is
# staged on host0: next to a poi_preset.txt naming it, and the app picks it up
# at startup (main.c reads a .pbm argument, --preset=, poi_preset.txt from
# the working dir, host0: or ms0:). A standalone Memory Stick install wants the
# same two files next to EBOOT.PBP.
#
# This script ALWAYS stages the courtyard reference demo map
# (showcase_retro_baked.pbm); deploy_psp.sh adds --staged so the scratch map
# it staged (poi_scratch.pbm + a poi_map.txt naming it) rides along and the
# app loads it instead. Without --staged a leftover poi_map.txt from an
# earlier deploy is deleted, so a bare run always shows the courtyard.
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
# Shared PSPLink link management: daemon singleton (user service when
# installed), fast link checks, wedge diagnosis. See psp_link.sh for why the
# daemon must be running BEFORE the PSP (re)attaches.
source "$REPO_DIR/psp_link.sh"
PSPSH=("$PSPSH_BIN" -h 127.0.0.1)
PRX_NAME="poiretro_psp_hwtest.prx"
LOG="$HOSTDIR/poi_profile.txt"
# What proves "the module is running": the profiler's result file for a profiling
# run, the app's own log for the interactive one. The app never writes
# poi_profile.txt, so app mode used to spin through all three retry attempts and
# report a wedge that had not happened.
START_LOG="$LOG"
WAIT_SECS="${WAIT_SECS:-240}"     # total wait for the result file to stop growing
LOAD_GRACE="${LOAD_GRACE:-25}"    # seconds allowed for the profiler's FIRST output
LINK_GRACE="${LINK_GRACE:-40}"    # seconds allowed for PSPLink to answer after a reset
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
KEEP=0
MODE=prof
NO_RESET=0
STAGED=0
PRESET=""
PRESETS=(dawn day dusk night)

_args=("$@")
_i=0
while [ "$_i" -lt "${#_args[@]}" ]; do
    arg="${_args[$_i]}"
    case "$arg" in
        --keep) KEEP=1 ;;
        --app)  MODE=app; KEEP=1 ;;   # interactive build needs host0: to stay alive!
        --no-reset) NO_RESET=1 ;;
        --staged) STAGED=1 ;;         # deploy_psp.sh: also stage the scratch map slot
        --preset)
            _i=$((_i + 1))
            PRESET="${_args[$_i]:-}"
            [ -n "$PRESET" ] || { echo "ERROR: --preset needs a name (${PRESETS[*]})" >&2; exit 2; } ;;
        --preset=*) PRESET="${arg#--preset=}" ;;
        dawn|day|dusk|night) PRESET="$arg" ;;
        -h|--help)
            sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "ERROR: unknown argument '$arg' (try --help)" >&2; exit 2 ;;
    esac
    _i=$((_i + 1))
done

die() { echo "ERROR: $*" >&2; exit 1; }

if [ -n "$PRESET" ]; then
    preset_ok=0
    for p in "${PRESETS[@]}"; do [ "$p" = "$PRESET" ] && preset_ok=1; done
    [ "$preset_ok" = 1 ] || die "unknown preset '$PRESET' (known: ${PRESETS[*]})"
    PRESET_MAP="$PSP_DIR/showcase_retro_baked_${PRESET}.pbm"
    [ -f "$PRESET_MAP" ] || die "no map for preset '$PRESET' (looked for $PRESET_MAP).
  Re-export the presets with ./run_presets.sh, or pick one of:
    $(ls "$PSP_DIR"/showcase_retro_baked*.pbm 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ')"
fi

# All PSP compilation happens in the pinned pspdev container.
psp_make() {
    podman run --rm -v "$PSP_DIR:/src:Z" -w /src docker.io/pspdev/pspdev:latest \
        bash -c "export PATH=\$PATH:/usr/local/pspdev/bin; make $*"
}

[ -x "$USBHOSTFS" ] || die "usbhostfs_pc not built at $USBHOSTFS"
[ -x "$PSPSH_BIN" ] || die "pspsh not built at $PSPSH_BIN"

# ── Singleton: exactly ONE usbhostfs_pc owns the USB link ────────────────────
# pspsh reaches the device THROUGH usbhostfs's local relay, so whoever owns
# that process owns the conversation. psp_ensure_daemon keeps exactly one
# daemon serving THIS hostdir (stopping any other project's stray), and —
# crucially — it is ensured BEFORE the build below: the PSP re-presents its
# USB device for only a few seconds per activation, so a daemon that appears
# minutes late (the old flow started it after the container build) misses the
# windows, the PSP's retries shrink to ~1s, and it gives up entirely. That
# give-up state is the "replug does nothing" wedge.
echo "=== [0/5] Ensuring the usbhostfs_pc singleton (serving host0: = $HOSTDIR) ==="
psp_ensure_daemon "$HOSTDIR" || die "could not start usbhostfs_pc (see $USBHOSTFS_LOG)"

# Never leave a stray daemon behind on Ctrl-C or failure — psp_maybe_stop_daemon
# refuses to stop one that is connected to the PSP (dropping a live link is
# what starts the activation churn), so this is safe at any exit point.
cleanup() { [ "$KEEP" = 0 ] && psp_maybe_stop_daemon || true; }
trap cleanup INT TERM EXIT

# ── Device helpers ───────────────────────────────────────────────────────────

# pspsh with a timeout; stdout only, because callers all grep it.
pspsh() {
    local t="$1"; shift
    timeout "$t" "${PSPSH[@]}" -n -e "$1" 2>/dev/null || true
}

# 8s spans one full PSP activation window; a connected link answers in well
# under a second. The old 25s timeout here could sleep through an entire
# re-activation cycle of a bouncing PSP and report a link that had come and
# gone.
link_ok() { psp_link_ok 8; }

wait_link() { psp_wait_link "${1:-$LINK_GRACE}" "waiting for the PSPLink link"; }

reset_device() {
    echo "  resetting the device (psplink reset -> fresh GE/display state)"
    # A reset can only land on a LIVE link. Sending it into a dead one just
    # burns two 30s pspsh timeouts per attempt while the PSP re-activates on
    # its own anyway (and, with the usbhostfs watchdog prx, keeps re-activating
    # every ~15-30s until the daemon claims it).
    if link_ok; then
        timeout 30 "${PSPSH[@]}" -n -e "reset" >/dev/null 2>&1 || true
    else
        echo "  link already down — waiting for the PSP to re-activate"
    fi
    if ! wait_link 12; then
        # The daemon can wedge (alive, but never completing the handshake on
        # a re-attached PSP). A fresh daemon claims the PSP's next activation
        # within ~0.1s, so restart it instead of failing the run.
        if [ -n "$(psp_daemons)" ]; then
            echo "  link not back: usbhostfs_pc is running but stale — restarting it"
            psp_restart_daemon "$HOSTDIR"
        fi
    fi
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
log_started() { [ "$(stat -c %s "$START_LOG" 2>/dev/null || echo 0)" != "0" ]; }

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
    START_LOG="$HOSTDIR/poi_app.log"
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
rm -f "$LOG" "$HOSTDIR/poi_app.log"
cp "$PSP_DIR/$PRX_NAME" "$HOSTDIR/$PRX_NAME"
# The COURTYARD reference demo map is always the base staging — deploy_psp's
# scratch slot never replaces it in this directory, it only adds to it.
cp "$PSP_DIR/showcase_retro_baked.pbm" "$HOSTDIR/showcase_retro_baked.pbm"
if [ -n "$PRESET" ]; then
    # The app resolves showcase_retro_baked_<preset>.pbm beside the shipping map
    # when poi_preset.txt (or an argument) names the preset.
    cp "$PRESET_MAP" "$HOSTDIR/$(basename "$PRESET_MAP")"
    printf '%s\n' "$PRESET" > "$HOSTDIR/poi_preset.txt"
    echo "    preset: $PRESET  (poi_preset.txt + $(basename "$PRESET_MAP") staged)"
else
    rm -f "$HOSTDIR/poi_preset.txt"    # a previous run's preset must not leak
fi
if [ "$STAGED" = 1 ]; then
    # deploy_psp.sh's scratch map: poi_scratch.pbm + poi_map.txt naming it,
    # which main.c resolves ahead of the default map/preset files.
    [ -f "$PSP_DIR/poi_scratch.pbm" ] || die "--staged: no scratch map staged ($PSP_DIR/poi_scratch.pbm missing — run ./deploy_psp.sh)"
    cp "$PSP_DIR/poi_scratch.pbm" "$HOSTDIR/poi_scratch.pbm"
    cp "$PSP_DIR/poi_map.txt" "$HOSTDIR/poi_map.txt"
    echo "    staged scratch map: poi_scratch.pbm (poi_map.txt)"
else
    rm -f "$HOSTDIR/poi_map.txt"       # a previous deploy's scratch map must not leak
    rm -f "$HOSTDIR/poi_scratch.pbm"
fi
rm -f "$HOSTDIR/poi_render.txt"     # runtime overrides must not leak between runs
ls -la "$HOSTDIR" | sed -n "1,12p"   # sed eats all input: head SIGPIPEs ls under pipefail

echo "=== [3/5] usbhostfs_pc (serving host0: = $HOSTDIR) ==="
psp_ensure_daemon "$HOSTDIR" || { tail -5 "$USBHOSTFS_LOG"; die "usbhostfs_pc died"; }
[ -n "$(psp_daemons)" ] || die "usbhostfs_pc is not running (see $USBHOSTFS_LOG)"

echo "=== [3b/5] Checking the PSPLink USB link ==="
# The wait spans several PSP activation cycles: if the PSP is bouncing (each
# activation a few seconds) the fast-polling daemon claims one of them and
# the wait ends early. Only a PSP that has given up (or is unplugged/suspended)
# times out, and psp_link_state says which and what to do.
if ! psp_wait_link 60 "checking for a PSP"; then
    psp_link_state
    cat <<'MSG'
No PSP answering over USB. If the state above says the PSP is silent:
  relaunch PSPLink on the device (Game -> Memory Stick -> PSPLink) or replug
  ONCE — the daemon is already waiting and claims within ~0.1s. Keep the Hold
  switch ON so the unit cannot suspend mid-run.
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

# The daemon from step [0] stays if it is connected (or is under the always-on
# user service); a leftover nohup daemon that is NOT connected is stopped by
# the EXIT trap via psp_maybe_stop_daemon.

# `make hwtest` starts with `make clean` (the HWTEST objects must not be
# reused by the shipping build), which removes the tracked EBOOT.PBP. Put the
# shipping artifacts back so the tree stays clean after a profiling run.
echo "=== restoring the shipping build ==="
psp_make all >/dev/null 2>&1 && psp_make test_build >/dev/null 2>&1 || echo "(shipping rebuild failed)"

echo
echo "=== REPORT ==="
python3 "$REPO_DIR/retro_engine/pbm_profile_report.py" "$LOG"
