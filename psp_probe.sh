#!/usr/bin/env bash
# psp_probe.sh — 5-second "can I see the PSP?" check.
#
# Run this BEFORE claiming anything about the device. Agents have shipped
# "no PSP connected" caveats without running any probe; this makes the check
# one command with an unambiguous verdict at every layer:
#
#   layer 1  USB device present      (lsusb 054c:01c9, Sony PSP Type B)
#   layer 2  udev symlink            (/dev/psp from 50-psplink.rules)
#   layer 3  PSPLink link answering  (usbhostfs_pc + pspsh modlist)
#
# Layer 3 is the one run_psp_hw.sh actually needs: a PSP can sit on USB with
# PSPLink not started (or suspended, or wedged) and no measurement is possible.
# Layer 3 is only tried when no other usbhostfs_pc owns the link — that process
# is a singleton per USB device, and stealing it breaks whoever owns it.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PSPLINK_SRC="${PSPLINK_SRC:-/tmp/psplinkusb}"
PSPSH_BIN="$PSPLINK_SRC/pspsh/pspsh"
rc=0

# ── Layer 1: USB device ──────────────────────────────────────────────────────
if lsusb -d 054c:01c9 >/dev/null 2>&1; then
    echo "1. USB device:    PRESENT ($(lsusb -d 054c:01c9 | sed 's/^[^ ]* [^ ]* //'))"
else
    echo "1. USB device:    ABSENT (no 054c:01c9 on any bus)"
    echo
    echo "VERDICT: no PSP on USB. Plug it in (or wake it: a suspended PSP drops"
    echo "the link). If PSPLink was never installed: ./setup_psplink.sh"
    exit 1
fi

# ── Layer 2: udev symlink ────────────────────────────────────────────────────
if [ -e /dev/psp ]; then
    echo "2. udev symlink:  PRESENT (/dev/psp -> $(readlink /dev/psp))"
else
    echo "2. udev symlink:  ABSENT (/dev/psp)"
    echo "   (the 50-psplink.rules udev rule is missing or not triggered;"
    echo "    ./setup_psplink.sh installs it. Not fatal for PSPLink itself,"
    echo "    usbhostfs_pc talks to the raw USB device.)"
    rc=2
fi

# ── Layer 3: PSPLink link ────────────────────────────────────────────────────
if ! pgrep -f usbhostfs_pc >/dev/null 2>&1; then
    echo "3. PSPLink link:  usbhostfs_pc not running — trying a temporary one"
    if [ ! -x "$PSPLINK_SRC/usbhostfs_pc/usbhostfs_pc" ] || [ ! -x "$PSPSH_BIN" ]; then
        echo "   (host tools not built at $PSPLINK_SRC — run ./setup_psplink.sh)"
        exit 2
    fi
    nohup "$PSPLINK_SRC/usbhostfs_pc/usbhostfs_pc" "$REPO_DIR/retro_engine/psp/hwrun" \
        >/tmp/usbhostfs_pc.log 2>&1 &
    started_here=1
    sleep 3
fi
ANSWER=$(timeout 25 "$PSPSH_BIN" -h 127.0.0.1 -n -e "modlist" 2>/dev/null | grep -c "UID:" || true)
if [ "${ANSWER:-0}" -gt 0 ]; then
    echo "3. PSPLink link:  ANSWERING (modlist returned ${ANSWER} modules)"
    [ -n "$(timeout 20 "$PSPSH_BIN" -h 127.0.0.1 -n -e "modlist" 2>/dev/null | grep -i 'PoiRetro')" ] \
        && echo "   NOTE: a PoiRetro module is resident (a build is running; run_psp_hw.sh will reset first)."
    echo
    echo "VERDICT: PSP ready — ./run_psp_hw.sh will measure it."
    exit "$rc"
else
    echo "3. PSPLink link:  NOT ANSWERING"
    echo
    echo "VERDICT: PSP on USB but PSPLink is not talking. On the device:"
    echo "  Game -> Memory Stick -> PSPLink ('Waiting for usbhostfs connection'),"
    echo "  Hold switch ON so it cannot suspend. If another usbhostfs_pc from a"
    echo "  different project owns the link, close it there first."
    exit 1
fi
