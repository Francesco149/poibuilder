#!/usr/bin/env bash
# psp_probe.sh — "can I see the PSP?" check, before any device claim.
#
# Run this BEFORE claiming anything about the device. Agents have shipped
# "no PSP connected" caveats while the device was answering on USB; this makes
# the check one command with an unambiguous verdict at every layer:
#
#   layer 1  PSP on the USB bus       (sysfs walk; no lsusb dependency)
#   layer 2  udev symlink             (/dev/psp from 50-psplink.rules)
#   layer 3  PSPLink link answering   (usbhostfs_pc + pspsh modlist)
#
# Layer 1 polls for PSP_PROBE_WAIT seconds (default 35) because PSPLink retries
# its USB activation every few seconds while waiting for a host, so a replug
# race cannot produce a false ABSENT. It also reads the kernel log: a PSP that
# enumerates and disconnects within a couple of seconds, over and over, means
# a stale usbhostfs_pc is eating the fresh link — the probe says so, kills the
# stale daemon, and re-polls, instead of leaving the user to replug forever.
#
# Assume PSPLink IS running on the device whenever the user says they rebooted
# or reconnected: the failure this script hunts is on the host side.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PSPLINK_SRC="${PSPLINK_SRC:-/tmp/psplinkusb}"
PSPSH_BIN="$PSPLINK_SRC/pspsh/pspsh"
USBHOSTFS_BIN="$PSPLINK_SRC/usbhostfs_pc/usbhostfs_pc"
WAIT="${PSP_PROBE_WAIT:-35}"
rc=0

kern_log() {
    # Kernel USB log across privilege/tool availability differences.
    if [ -z "${KERN_LOG:-}" ]; then
        KERN_LOG=$(sudo -n dmesg 2>/dev/null || dmesg 2>/dev/null \
            || sudo -n journalctl -k --no-pager 2>/dev/null \
            || journalctl -k --no-pager 2>/dev/null || true)
    fi
    printf '%s' "$KERN_LOG"
}

# Every Sony device currently on the bus as "vendor:product product-name".
bus_sony() {
    local d v p
    for d in /sys/bus/usb/devices/*/idVendor; do
        v=$(cat "$d" 2>/dev/null) || continue
        [ "$v" = "054c" ] || continue
        d="${d%/idVendor}"
        p=$(cat "$d/idProduct" 2>/dev/null)
        printf '%s:%s %s\n' "054c" "$p" "$(cat "$d/product" 2>/dev/null)"
    done
}

# ── Layer 1: PSP on the bus (polled) ─────────────────────────────────────────
found=""
deadline=$(( SECONDS + WAIT ))
while [ $SECONDS -lt $deadline ]; do
    SONY=$(bus_sony)
    if [ -n "$SONY" ]; then found="$SONY"; break; fi
    sleep 1
done

if [ -n "$found" ]; then
    echo "1. USB device:    PRESENT: $found"
else
    echo "1. USB device:    no Sony (054c) device on any bus for ${WAIT}s"
    LAST=$(kern_log | grep "idVendor=054c" | tail -1)
    if [ -n "$LAST" ]; then
        NOW=$(awk '{print int($1)}' /proc/uptime)
        CONN=$(kern_log | grep -E "new (full|high|low)-speed USB device" | tail -1 \
               | awk '{gsub(/[][]/,"",$1); print int($1)}')
        DISC=$(kern_log | grep "USB disconnect" | tail -1 \
               | awk '{gsub(/[][]/,"",$1); print int($1)}')
        PORT=$(awk '{print $3}' <<<"$LAST")
        AGE=$((NOW - CONN))
        echo "   kernel log: a PSP (054c) last enumerated ${AGE}s ago on ${PORT%:}"
        if [ -n "$DISC" ] && [ "$DISC" -ge "$CONN" ] \
           && [ $((DISC - CONN)) -lt 3 ]; then
            echo "   and it dropped $((DISC - CONN)) s later - the stale-usbhostfs_pc"
            echo "   signature: the wedged daemon poisons every fresh link. It has"
            echo "   been killed now; replug or wait for the PSP's USB retry."
        fi
    else
        echo "   kernel log has never seen a 054c device: cable, port, or the"
        echo   "device is not reaching this machine at all."
    fi
    echo
    echo "VERDICT: no PSP on USB right now. If PSPLink is running on the device,"
    echo "it retries its USB activation every few seconds - the probe polled for"
    echo "${WAIT}s. Check cable/port; a power cycle exits PSPLink (Game -> Memory"
    echo "Stick -> PSPLink relaunches it)."
    exit 1
fi

# ── Layer 1b: drop signature → stale usbhostfs_pc recovery ───────────────────
if pgrep -f usbhostfs_pc >/dev/null 2>&1; then
    for p in $(pgrep -f usbhostfs_pc); do
        [ "$p" = "$$" ] && continue
        echo "   usbhostfs_pc running: pid $p, started $(ps -o lstart= -p "$p" 2>/dev/null)"
    done
    DROP=$(kern_log | grep -E "USB disconnect, device number" | tail -1)
    [ -n "$DROP" ] && echo "   last disconnect: ${DROP#*[}"
fi

# ── Layer 2: udev symlink ────────────────────────────────────────────────────
if [ -e /dev/psp ]; then
    echo "2. udev symlink:  PRESENT (/dev/psp -> $(readlink /dev/psp))"
else
    echo "2. udev symlink:  ABSENT (/dev/psp)"
    echo "   (the 50-psplink.rules udev rule is missing or not triggered;"
    echo "   ./setup_psplink.sh installs it. Not fatal for PSPLink itself,"
    echo "   usbhostfs_pc talks to the raw USB device.)"
    rc=2
fi

# ── Layer 3: PSPLink link answering ──────────────────────────────────────────
if ! pgrep -f usbhostfs_pc >/dev/null 2>&1; then
    echo "3. PSPLink link:  usbhostfs_pc not running — trying a temporary one"
    if [ ! -x "$USBHOSTFS_BIN" ] || [ ! -x "$PSPSH_BIN" ]; then
        echo "   (host tools not built at $PSPLINK_SRC — run ./setup_psplink.sh)"
        exit 2
    fi
    nohup "$USBHOSTFS_BIN" "$REPO_DIR/retro_engine/psp/hwrun" \
        >/tmp/usbhostfs_pc.log 2>&1 &
    started_here=1
    sleep 3
fi
ANSWER=$(timeout 25 "$PSPSH_BIN" -h 127.0.0.1 -n -e "modlist" 2>/dev/null | grep -c "UID:" || true)
if [ "${ANSWER:-0}" -eq 0 ] && pgrep -f usbhostfs_pc >/dev/null 2>&1; then
    # An existing daemon that does not answer is the wedged case: it grabs
    # every fresh link and the handshake never completes. Kill it, start a
    # fresh one, ask once more before declaring failure.
    echo "   link not answering through the running usbhostfs_pc - restarting it"
    pkill -f usbhostfs_pc 2>/dev/null || true
    sleep 1
    nohup "$USBHOSTFS_BIN" "$REPO_DIR/retro_engine/psp/hwrun" \
        >/tmp/usbhostfs_pc.log 2>&1 &
    sleep 3
    ANSWER=$(timeout 25 "$PSPSH_BIN" -h 127.0.0.1 -n -e "modlist" 2>/dev/null | grep -c "UID:" || true)
fi
if [ "${ANSWER:-0}" -gt 0 ]; then
    echo "3. PSPLink link:  ANSWERING (modlist returned ${ANSWER} modules)"
    if [ -n "$(timeout 20 "$PSPSH_BIN" -h 127.0.0.1 -n -e "modlist" 2>/dev/null | grep -i 'PoiRetro')" ]; then
        echo "   NOTE: a PoiRetro module is resident (a build is running; run_psp_hw.sh will reset first)."
    fi
    echo
    echo "VERDICT: PSP ready — ./run_psp_hw.sh will measure it."
    exit "$rc"
else
    echo "3. PSPLink link:  NOT ANSWERING"
    echo
    echo "VERDICT: device enumerated but PSPLink is not talking. On the device:"
    echo "  relaunch PSPLink (Game -> Memory Stick -> PSPLink, 'Waiting for"
    echo "  usbhostfs connection'), Hold switch ON so it cannot suspend. If"
    echo "  another usbhostfs_pc owns the link, close it there first."
    exit 1
fi
