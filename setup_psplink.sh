#!/usr/bin/env bash
# setup_psplink.sh — one-time setup for autonomous real-hardware PSP profiling.
#
# Installs PSPLink (the standard PSP remote-execution/debug bridge) so that
# run_psp_hw.sh can load and run test binaries on the device over USB without
# copying anything to the memory stick:
#
#   1. builds psplinkusb (PSP-side PRX modules in the pspdev container, host
#      tools with the local toolchain)
#   2. installs a udev rule so usbhostfs_pc can claim the device unprivileged
#   3. deploys the PSP-side files to ms0:/PSP/GAME/PSPLINK/
#
# The only manual step left afterwards is launching PSPLink once from the PSP's
# XMB (Game -> Memory Stick -> PSPLink); it then waits on USB for the host.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PSPLINK_SRC="${PSPLINK_SRC:-/tmp/psplinkusb}"
PSP_MOUNT="${PSP_MOUNT:-/mnt/psp}"
PSP_DEV="${PSP_DEV:-/dev/sdf1}"

echo "=== [1/4] Fetching psplinkusb ==="
if [ -d "$PSPLINK_SRC/.git" ]; then
    git -C "$PSPLINK_SRC" pull --ff-only || true
else
    git clone --depth 1 https://github.com/pspdev/psplinkusb.git "$PSPLINK_SRC"
fi

echo "=== [2/4] Building PSP-side modules (pspdev container) ==="
podman run --rm -v "$PSPLINK_SRC:/src:Z" -w /src docker.io/pspdev/pspdev:latest \
    bash -c 'export PATH=$PATH:/usr/local/pspdev/bin; make -f Makefile.psp all'

echo "=== [3/4] Building host tools (usbhostfs_pc, pspsh) ==="
( cd "$PSPLINK_SRC/usbhostfs_pc" && make )
( cd "$PSPLINK_SRC/pspsh" && make )

echo "=== [4/4] Installing udev rule and deploying to the memory stick ==="
RULE=/etc/udev/rules.d/50-psplink.rules
if [ ! -f "$RULE" ]; then
    printf '# PSPLink USB access (Sony 054c, PSPLink 01c9)\nSUBSYSTEM=="usb", ATTR{idVendor}=="054c", ATTR{idProduct}=="01c9", SYMLINK+="psp", MODE="0666", TAG+="uaccess"\n' \
        | sudo tee "$RULE" >/dev/null
    sudo udevadm control --reload-rules
    sudo udevadm trigger || true
    echo "installed $RULE"
else
    echo "$RULE already present"
fi

if ! mountpoint -q "$PSP_MOUNT"; then
    echo "Mounting the PSP memory stick ($PSP_DEV -> $PSP_MOUNT; put the PSP in USB mode first)"
    sudo mkdir -p "$PSP_MOUNT"
    sudo mount "$PSP_DEV" "$PSP_MOUNT"
fi
sudo mkdir -p "$PSP_MOUNT/PSP/GAME/PSPLINK"
for f in psplink/psplink.prx psplink/psplink.ini psplink_user/psplink_user.prx \
         usbhostfs/usbhostfs.prx usbgdb/usbgdb.prx bootstrap/EBOOT.PBP; do
    sudo cp -v "$PSPLINK_SRC/$f" "$PSP_MOUNT/PSP/GAME/PSPLINK/$(basename "$f")"
done
sudo sync
sudo umount "$PSP_MOUNT"

cat <<'EOF'

=== PSPLink installed ===
On the PSP: press O to leave USB mode, then Game -> Memory Stick -> PSPLink.
It will print "Waiting for usbhostfs connection..." and stay there; from then
on drive everything from this machine with ./run_psp_hw.sh
EOF
