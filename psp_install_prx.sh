#!/usr/bin/env bash
# psp_install_prx.sh — install the patched PSP-side PSPLink modules to the
# memory stick (one manual step: put the PSP in USB mode).
#
# WHY: the host-side fixes live in usbhostfs_pc + the scripts, but the
# give-up state lives in the PSP's loaded usbhostfs.prx — patch 0003 adds a
# re-activation watchdog to that module (see psp_patches/README.md) so the
# PSP never stops presenting USB while no host is connected. Getting it onto
# the device needs the memory stick exactly once; after that, recovery from
# any wedge is: nothing (the watchdog re-presents within ~30s and the
# always-on daemon claims it).
#
# Usage:
#   ./psp_install_prx.sh            # waits for the PSP in USB mode (90 s)
#
# On the PSP: exit PSPLink if running, then XMB -> Settings -> USB
# Connection (the "USB cable" icon). The script detects the stick, backs up
# the current module, installs the patched one, and unmounts. Afterwards:
# press O to leave USB mode and relaunch PSPLink (Game -> Memory Stick ->
# PSPLink). Rollback: copy the backup back the same way.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PSPLINK_SRC="${PSPLINK_SRC:-$HOME/.local/share/psplinkusb}"
PRX_SRC="$PSPLINK_SRC/usbhostfs/usbhostfs.prx"
PSP_MOUNT="${PSP_MOUNT:-/mnt/psp}"
TARGET_DIR="PSP/GAME/PSPLINK"
die() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$PRX_SRC" ] || die "patched module not built at $PRX_SRC
  (run ./setup_psplink.sh, or: podman run --rm -v $PSPLINK_SRC:/src:Z -w /src \\
     docker.io/pspdev/pspdev:latest make -f Makefile.psp)"

if ! grep -q usb_watchdog_thread "$PSPLINK_SRC/usbhostfs/main.c" 2>/dev/null; then
    die "the build in $PSPLINK_SRC does not carry the watchdog patch;
  re-run ./setup_psplink.sh so psp_patches/0003 gets applied first"
fi

# The stick: a Sony removable USB disk (or an explicit PSP_DEV=/dev/sdX1).
psp_partition() {
    if [ -n "${PSP_DEV:-}" ] && [ -e "${PSP_DEV:-}" ]; then
        printf '%s\n' "$PSP_DEV"; return 0
    fi
    local disk
    disk=$(lsblk -rno NAME,VENDOR,TYPE 2>/dev/null | awk '$2=="Sony" && $3=="disk" {print $1; exit}')
    [ -n "$disk" ] && [ -e "/dev/${disk}1" ] && printf '/dev/%s1\n' "$disk"
    return 1
}

echo "Waiting for the PSP in USB mode (XMB -> Settings -> USB Connection)…"
DEV=""
for ((i = 0; i < 90; i++)); do
    DEV=$(psp_partition || true) && [ -n "$DEV" ] && break
    sleep 1
done
[ -n "$DEV" ] || die "no Sony USB disk appeared in 90s — is the PSP in USB mode?"

echo "Found memory stick: $DEV"
sudo mkdir -p "$PSP_MOUNT"
sudo mount "$DEV" "$PSP_MOUNT"
trap 'sudo umount "$PSP_MOUNT" 2>/dev/null || true' EXIT

[ -f "$PSP_MOUNT/$TARGET_DIR/usbhostfs.prx" ] \
    || die "no PSPLink install found on the stick ($PSP_MOUNT/$TARGET_DIR)"

STAMP=$(date +%Y%m%d-%H%M%S)
sudo cp -v "$PSP_MOUNT/$TARGET_DIR/usbhostfs.prx" \
    "$PSP_MOUNT/$TARGET_DIR/usbhostfs.prx.stock-$STAMP"
sudo install -m644 -v "$PRX_SRC" "$PSP_MOUNT/$TARGET_DIR/usbhostfs.prx"
sudo sync
sudo umount "$PSP_MOUNT"
trap - EXIT

echo
echo "Installed. On the PSP: press O to leave USB mode, then relaunch PSPLink"
echo "(Game -> Memory Stick -> PSPLink). Verify from here with ./psp_probe.sh —"
echo "and from now on a wedged-looking PSP recovers by itself within ~30s."
echo "Rollback: repeat with the usbhostfs.prx.stock-$STAMP backup instead."
