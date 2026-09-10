#!/usr/bin/env bash
# ensure_display — make an X display available for X11-only GUI programs.
#
# This workstation runs niri (pure Wayland) and nothing starts an Xwayland for
# the session, so DISPLAY is empty inside tmux/ssh and an X11-only program
# (raylib/GLFW here) has nowhere to draw. Starting a private `Xwayland :99` does
# NOT work: a bare Xwayland has no Wayland compositor behind it, so its windows
# never appear on screen even though the program runs happily and renders.
#
# `xwayland-satellite` is the compositor-integrated Xwayland (niri pairs with
# it), and it needs to be running once per session. Sourced by the launchers:
#
#   source "$REPO_DIR/xdisplay.sh"
#   if ensure_display; then ./app; else xvfb-run -a ./app; fi
#
# Returns 0 with DISPLAY exported on success, non-zero when no X display can be
# provided (callers then fall back to xvfb-run for headless use).
ensure_display() {
    # Already have a usable display (an X socket must exist for it).
    if [ -n "${DISPLAY:-}" ] && [ -S "/tmp/.X11-unix/X${DISPLAY#:}" ]; then
        return 0
    fi

    command -v xwayland-satellite >/dev/null 2>&1 || return 1

    if ! pgrep -x xwayland-satellite >/dev/null 2>&1; then
        nohup xwayland-satellite >/tmp/xwayland-satellite.log 2>&1 &
        for _ in $(seq 1 50); do
            sleep 0.1
            [ -S /tmp/.X11-unix/X0 ] && break
        done
    fi

    # xwayland-satellite takes the lowest free display; niri sessions land on :0.
    local n
    for n in $(ls /tmp/.X11-unix/ 2>/dev/null | sed -n 's/^X\([0-9]\+\)$/\1/p' | sort -n); do
        # A stale socket left by a dead server has no listener; xdpyinfo may not
        # be installed, so treat only :0 as authoritative here.
        if [ "$n" = "0" ]; then
            export DISPLAY=":$n"
            return 0
        fi
    done
    return 1
}
