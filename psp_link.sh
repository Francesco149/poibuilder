#!/usr/bin/env bash
# psp_link.sh — shared PSPLink USB-link management (sourced by the PSP scripts,
# not run directly).
#
# WHY THIS EXISTS — the PSP wedge, once and for all (patches: psp_patches/):
#
# PSPLink on the PSP presents its USB device (054c:01c9) for only a FEW
# SECONDS per activation while it waits for a host to claim it and finish the
# hostfs handshake. If nobody does, the PSP deactivates, retries a few seconds
# later, and the activation window SHRINKS on every miss (observed 8s -> 1s
# over about a minute) until the PSP side gives up entirely and presents
# nothing — the state where replugging "does nothing" and only a PSP reboot
# seems to help. Every miss is also visible in the kernel log as the
# "new USB device -> USB disconnect one second later" churn.
#
# So the whole game is: a healthy usbhostfs_pc daemon must ALREADY be running
# and must claim within ~0.1s whenever the PSP (re)attaches. That is provided
# by:
#   * ~/.local/bin/usbhostfs_pc  — patched to poll every 100 ms (stock: 1 s),
#     to log missed windows instead of looking dead, and to exit 0 on
#     SIGTERM so clean kills are distinguishable from crashes
#   * the psp-usbhostfs.service systemd --user unit — keeps exactly one
#     daemon running from login to logout (linger on), auto-restarting
#     crashes but NOT clean stops, so other projects may still pkill it
#   * these helpers — scripts ensure/restart the daemon instead of killing
#     it wholesale, and never stop a daemon that is currently CONNECTED to
#     the PSP (a disconnected-then-idle daemon is what starts the churn).
#
# Functions provided:
#   psp_usb_present               054c:01c9 on the bus right now?
#   psp_daemons                   pids of running usbhostfs_pc (exact match)
#   psp_daemon_dir PID            hostdir a daemon serves
#   psp_daemon_connected          daemon alive AND serving a PSP
#   psp_ensure_daemon [DIR]       one daemon serving DIR; reuse if healthy
#   psp_restart_daemon [DIR]      fresh daemon (wedge recovery)
#   psp_maybe_stop_daemon         stop the daemon unless it is CONNECTED
#   psp_link_ok [TIMEOUT]         PSPLink answers pspsh (default 8s)
#   psp_wait_link [SECS] [LABEL]  wait for the link, keeping the daemon alive
#   psp_link_state                human-readable diagnosis of the link

# shellcheck shell=bash

PSP_LINK_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PSP_DEFAULT_HOSTDIR="${PSP_DEFAULT_HOSTDIR:-$PSP_LINK_REPO_DIR/retro_engine/psp/hwrun}"
USBHOSTFS_LOG="${USBHOSTFS_LOG:-/tmp/usbhostfs_pc.log}"
PSP_UNIT_NAME="psp-usbhostfs.service"
PSP_UNIT_FILE="$HOME/.config/systemd/user/$PSP_UNIT_NAME"

# Resolve the host tools: persistent install first, source tree fallback.
_psp_resolve_bin() {
    local name="$1" src="$2"
    if [ -x "$HOME/.local/bin/$name" ]; then
        printf '%s\n' "$HOME/.local/bin/$name"
    else
        printf '%s\n' "$src"
    fi
}
# Source-tree fallback for the tools; the persistent patched clone lives in
# ~/.local/share/psplinkusb (patches documented in psp_patches/README.md).
PSPLINK_SRC="${PSPLINK_SRC:-$HOME/.local/share/psplinkusb}"
USBHOSTFS="${USBHOSTFS:-$(_psp_resolve_bin usbhostfs_pc "$PSPLINK_SRC/usbhostfs_pc/usbhostfs_pc")}"
PSPSH_BIN="${PSPSH_BIN:-$(_psp_resolve_bin pspsh "$PSPLINK_SRC/pspsh/pspsh")}"
unset -f _psp_resolve_bin

psp_unit_active() {
    systemctl --user is-active --quiet "$PSP_UNIT_NAME" 2>/dev/null
}

# Layer 1: the PSP on the USB bus (sysfs walk, no lsusb dependency).
psp_usb_present() {
    local d
    for d in /sys/bus/usb/devices/*/idVendor; do
        if [ "$(cat "$d" 2>/dev/null)" = "054c" ] \
           && [ "$(cat "${d%/idVendor}/idProduct" 2>/dev/null)" = "01c9" ]; then
            return 0
        fi
    done
    return 1
}

# Pids of running daemons. -x matches the exact comm name so this never
# catches a shell/agent whose command line merely mentions the word.
psp_daemons() { pgrep -x usbhostfs_pc 2>/dev/null || true; }

psp_daemon_dir() { tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null | awk '{print $NF}'; }

# True when the daemon's log shows a connect after the last wait-for-device
# (the daemon prints "waiting for device..." whenever it loses the PSP,
# "Connected to device (claimed)" when the USB claim succeeds, and
# "PSP hello exchanged" once the protocol handshake completes).
psp_daemon_connected() {
    [ -n "$(psp_daemons)" ] || return 1
    awk '/waiting for device/{c=0} /Connected to device|PSP hello/{c=1} END{exit c?0:1}' \
        "$USBHOSTFS_LOG" 2>/dev/null
}

_psp_start_daemon() {
    local dir="$1"
    if [ -f "$PSP_UNIT_FILE" ]; then
        systemctl --user start "$PSP_UNIT_NAME" 2>/dev/null
    else
        nohup "$USBHOSTFS" "$dir" >>"$USBHOSTFS_LOG" 2>&1 &
    fi
    # The daemon is useless until it is polling; give it a moment and verify.
    local i
    for ((i = 0; i < 20; i++)); do
        [ -n "$(psp_daemons)" ] && return 0
        sleep 0.25
    done
    echo "ERROR: usbhostfs_pc did not start; last log lines:" >&2
    tail -5 "$USBHOSTFS_LOG" >&2 2>/dev/null
    return 1
}

# Exactly one daemon, serving DIR. A daemon serving a DIFFERENT directory
# (another project's stray) is stopped; a healthy one serving DIR is reused —
# no kill/restart churn, which is the point.
psp_ensure_daemon() {
    local dir="${1:-$PSP_DEFAULT_HOSTDIR}" pid d
    for pid in $(psp_daemons); do
        d="$(psp_daemon_dir "$pid")"
        if [ "$d" != "$dir" ]; then
            echo "stopping usbhostfs_pc pid $pid (serves $d, want $dir)"
            kill "$pid" 2>/dev/null || true
        fi
    done
    if psp_unit_active && [ -z "$(psp_daemons)" ]; then
        # Unit claims active but no process: a start is racing our kill.
        sleep 1
    fi
    [ -n "$(psp_daemons)" ] && return 0
    psp_start_daemon "$dir"
}

# Unconditional fresh daemon — for when the running one is wedged (alive but
# the handshake never completes through it).
psp_restart_daemon() {
    local dir="${1:-$PSP_DEFAULT_HOSTDIR}"
    if psp_unit_active; then
        systemctl --user restart "$PSP_UNIT_NAME"
    else
        pkill -x usbhostfs_pc 2>/dev/null || true
        sleep 1
        psp_start_daemon "$dir"
    fi
}

# Stop the daemon at end-of-run — with two hard exceptions. A daemon under
# the user unit is always-on by design (never stop it from scripts). And a
# daemon that is CONNECTED to the PSP is never stopped either: dropping a
# live link is exactly what teaches the PSP to start the shrinking
# activation churn. Only a disconnected, nohup-managed daemon is stopped.
psp_maybe_stop_daemon() {
    if psp_unit_active; then
        echo "usbhostfs_pc stays: managed by the $PSP_UNIT_NAME user service (always on)"
        return 0
    fi
    if psp_daemon_connected; then
        echo "usbhostfs_pc stays: it is connected to the PSP (dropping a live link starts the churn)"
        return 0
    fi
    pkill -x usbhostfs_pc 2>/dev/null || true
}

# PSPLink answering? One pspsh round trip. The timeout (default 8s) spans at
# worst one full PSP activation window; a connected link answers in well
# under a second, so this is also the fast "did the claim work" check.
psp_link_ok() {
    local t="${1:-8}"
    [ -n "$(psp_daemons)" ] || return 1
    timeout "$t" "$PSPSH_BIN" -h 127.0.0.1 -n -e "modlist" 2>/dev/null | grep -q 'UID:'
}

# Wait for the link, keeping the daemon healthy: restart it (once) if it
# died mid-wait, or if the PSP has been on the bus for several activation
# windows (~20s) without the daemon completing a claim — the wedged-daemon
# signature. A fresh daemon claims the PSP's next activation in ~0.1s.
psp_wait_link() {
    local t="${1:-45}" label="${2:-waiting for the PSPLink link}" i restarted=0
    echo -n "  $label"
    for ((i = 0; i < t; i += 2)); do
        if psp_link_ok; then
            echo " OK (${i}s)"
            return 0
        fi
        if [ "$restarted" -lt 1 ]; then
            if [ -z "$(psp_daemons)" ]; then
                echo -n "[daemon died; restarting it]"
                psp_restart_daemon >/dev/null 2>&1
                restarted=1
            elif [ "$i" -ge 20 ] && psp_usb_present && ! psp_daemon_connected; then
                echo -n "[daemon wedged; restarting it]"
                psp_restart_daemon >/dev/null 2>&1
                restarted=1
            fi
        fi
        echo -n "."
        sleep 2
    done
    psp_link_ok && { echo " OK"; return 0; }
    echo " timed out after ${t}s"
    return 1
}

# Human diagnosis of where the link is, using the daemon state and the kernel
# log's record of recent PSP activations.
psp_link_state() {
    local log n_disc since
    if [ -z "$(psp_daemons)" ]; then
        echo "  state: NO usbhostfs_pc daemon running (this is the wedge precondition;"
        echo "  psp_ensure_daemon should have prevented it)"
        return
    fi
    if psp_daemon_connected; then
        echo "  state: daemon connected to the PSP (kernel-side link is up)"
        return
    fi
    log="$(journalctl -k --since '-10 min' --no-pager 2>/dev/null || true)"
    n_disc="$(grep -c 'USB disconnect.*device number' <<<"$log" || true)"
    if grep -q 'idVendor=054c' <<<"$log"; then
        echo "  state: the PSP IS re-activating (kernel saw it in the last 10 min,"
        echo "  ${n_disc} disconnects) but the daemon has not completed a claim."
        echo "  If this persists the daemon is wedged: it gets restarted, and the"
        echo "  PSP's next activation (a few seconds) should connect."
    else
        since="$(journalctl -k --no-pager 2>/dev/null | grep 'idVendor=054c' | tail -1 | awk '{print $1, $2, $3}')"
        echo "  state: the PSP has not activated USB in the last 10 min (last seen:"
        echo "  ${since:-never}). It has either given up after repeated missed"
        echo "  activations or is unplugged/suspended. The daemon is up and polling"
        echo "  every 100 ms — with the usbhostfs watchdog prx installed just WAIT"
        echo "  ~30s for its re-activation; otherwise ONE replug (or relaunching"
        echo "  PSPLink on the device) connects it; no rebooting or pkill needed."
    fi
}
