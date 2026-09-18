#!/usr/bin/env bash
# psp_probe.sh — "can I see the PSP?" check, before any device claim.
#
# Run this BEFORE claiming anything about the device. Agents have shipped
# "no PSP connected" caveats while the device was answering on USB; this makes
# the check one command with an unambiguous verdict at every layer:
#
#   layer 1  PSP on the USB bus       (sysfs walk; no lsusb dependency)
#   layer 2  usbhostfs_pc daemon      (singleton via psp_link.sh — started if
#                                      absent: a PSP re-attaching while NO
#                                      daemon runs is what wedges it for good)
#   layer 3  udev symlink             (/dev/psp from 50-psplink.rules)
#   layer 4  PSPLink link answering   (pspsh modlist through the daemon)
#
# The failure model (full story in psp_link.sh): the PSP presents its USB
# device for only a few seconds per activation while waiting for a host, the
# window SHRINKS with every missed one, and after enough misses the PSP gives
# up entirely — the "replug does nothing" state that only a device reboot
# used to fix. Layer 1 polls for PSP_PROBE_WAIT seconds (default 35) because
# the PSP re-activates every few seconds, so a poll gap cannot produce a
# false ABSENT.
#
# Assume PSPLink IS running on the device whenever the user says they rebooted
# or reconnected: the failure this script hunts is on the host side.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_DIR/psp_link.sh"
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

# ── Layer 1: PSP on the bus (polled) ─────────────────────────────────────────
found=""
deadline=$(( SECONDS + WAIT ))
while [ $SECONDS -lt $deadline ]; do
    if psp_usb_present; then found=1; break; fi
    sleep 1
done

if [ -z "$found" ]; then
    echo "1. USB device:    no PSP (054c:01c9) on any bus for ${WAIT}s"
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
            echo "   and it dropped $((DISC - CONN)) s later — a missed activation"
            echo "   window: the PSP re-presents itself every few seconds while"
            echo "   waiting, each miss shortens the window, and eventually it"
            echo "   gives up. With the daemon below running, the next activation"
            echo "   connects; if the log has been silent for minutes the PSP has"
            echo "   given up and needs ONE replug (or a PSPLink relaunch)."
        fi
    else
        echo "   kernel log has never seen a 054c device: cable, port, or the"
        echo   "device is not reaching this machine at all."
    fi
    echo
    echo "VERDICT: no PSP on USB right now. If PSPLink is running on the device,"
    echo "make sure the usbhostfs daemon stays up (it is what catches the PSP's"
    echo "short activation windows) and replug once; a power cycle exits PSPLink"
    echo "(Game -> Memory Stick -> PSPLink relaunches it)."
    exit 1
fi
echo "1. USB device:    PRESENT (054c:01c9 on the bus)"

# ── Layer 2: usbhostfs_pc daemon (the thing that must never be missing) ──────
if psp_ensure_daemon; then
    if psp_daemon_connected; then
        echo "2. daemon:        RUNNING and CONNECTED to the PSP"
    else
        echo "2. daemon:        running (pid $(psp_daemons | tr '\n' ' ')),"
        echo "                  polling for the PSP's next activation"
    fi
else
    echo "2. daemon:        FAILED TO START (see $USBHOSTFS_LOG)"
    exit 2
fi

# ── Layer 3: udev symlink ────────────────────────────────────────────────────
if [ -e /dev/psp ]; then
    echo "3. udev symlink:  PRESENT (/dev/psp -> $(readlink /dev/psp))"
else
    echo "3. udev symlink:  ABSENT (/dev/psp)"
    echo "   (the 50-psplink.rules udev rule is missing or not triggered;"
    echo "   ./setup_psplink.sh installs it. Not fatal for PSPLink itself,"
    echo "   usbhostfs_pc talks to the raw USB device.)"
    rc=2
fi

# ── Layer 4: PSPLink link answering ──────────────────────────────────────────
modlist_count() {
    timeout 8 "$PSPSH_BIN" -h 127.0.0.1 -n -e "modlist" 2>/dev/null | grep -c "UID:" || true
}
ANSWER=$(modlist_count)
if [ "${ANSWER:-0}" -eq 0 ]; then
    # A daemon that does not answer is the wedged case: it grabs every fresh
    # activation but the handshake never completes. Restart it once and ask
    # again before declaring failure — a fresh daemon claims the PSP's next
    # activation (seconds away) within ~0.1s.
    echo "4. PSPLink link:  not answering through the running daemon — restarting it once"
    psp_restart_daemon
    if psp_wait_link 45 "asking again"; then
        ANSWER=$(modlist_count)
    fi
fi

if [ "${ANSWER:-0}" -gt 0 ]; then
    echo "4. PSPLink link:  ANSWERING (modlist returned ${ANSWER} modules)"
    if [ -n "$(timeout 8 "$PSPSH_BIN" -h 127.0.0.1 -n -e "modlist" 2>/dev/null | grep -i 'PoiRetro')" ]; then
        echo "   NOTE: a PoiRetro module is resident (a build is running; run_psp_hw.sh will reset first)."
    fi
    echo
    echo "VERDICT: PSP ready — ./run_psp_hw.sh will measure it."
    exit "$rc"
fi

echo "4. PSPLink link:  NOT ANSWERING"
psp_link_state
echo
echo "VERDICT: device enumerated but PSPLink is not talking. If the state above"
echo "says the PSP went silent: relaunch PSPLink on the device (Game -> Memory"
echo "Stick -> PSPLink) or replug ONCE — the daemon is waiting and will claim"
echo "the first activation. Keep the Hold switch ON so it cannot suspend."
exit 1
