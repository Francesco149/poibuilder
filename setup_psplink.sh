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
#   4. installs the host tools to ~/.local/bin and enables the
#      psp-usbhostfs.service user unit (linger on) so exactly one daemon is
#      ALWAYS waiting for the PSP — the PSP presents USB for only a few
#      seconds per activation and wedges for good if no daemon claims it in
#      time; see psp_link.sh for the full failure model
#
# The only manual step left afterwards is launching PSPLink once from the PSP's
# XMB (Game -> Memory Stick -> PSPLink); it then waits on USB for the host.
set -euo pipefail
die() { echo "ERROR: $*" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Persistent source clone — /tmp would be wiped/reaped eventually, taking the
# locally-committed usbhostfs_pc patches with it. See psp_patches/README.md.
PSPLINK_SRC="${PSPLINK_SRC:-$HOME/.local/share/psplinkusb}"
PSP_MOUNT="${PSP_MOUNT:-/mnt/psp}"
PSP_DEV="${PSP_DEV:-/dev/sdf1}"

echo "=== [1/5] Fetching psplinkusb ==="
if [ -d "$PSPLINK_SRC/.git" ]; then
    git -C "$PSPLINK_SRC" pull --ff-only || true
else
    git clone --depth 1 https://github.com/pspdev/psplinkusb.git "$PSPLINK_SRC"
fi

# The host tools need the local robustness patches and the PSP side needs the
# re-activation watchdog (see psp_patches/README.md). A FRESH clone from
# upstream has neither; without this a re-run would silently build and
# install unpatched components over the good ones. Per-patch: apply only if
# it still applies cleanly (already-applied patches fail --check and are
# skipped); afterwards verify the markers so a conflicting upstream change
# dies loudly instead of shipping stock behaviour.
applied=0
for p in "$REPO_DIR"/psp_patches/0*.patch; do
    [ -e "$p" ] || die "no patches found in $REPO_DIR/psp_patches/"
    if git -C "$PSPLINK_SRC" apply --check "$p" 2>/dev/null; then
        echo "applying $(basename "$p")"
        git -C "$PSPLINK_SRC" apply "$p"
        applied=1
    fi
done
if [ "$applied" = 1 ]; then
    git -C "$PSPLINK_SRC" -c user.name="$USER" -c user.email="$USER@localhost" \
        commit -qam "carry local psplinkusb robustness patches (see psp_patches/)" || true
fi
grep -q USBHOSTFS_POLL_MS "$PSPLINK_SRC/usbhostfs_pc/main.c" \
    || die "host-tool patches (0001/0002) missing and would not apply — upstream moved?"
grep -q usb_watchdog_thread "$PSPLINK_SRC/usbhostfs/main.c" \
    || die "watchdog patch (0003) missing and would not apply — upstream moved?"

echo "=== [2/5] Building PSP-side modules (pspdev container) ==="
podman run --rm -v "$PSPLINK_SRC:/src:Z" -w /src docker.io/pspdev/pspdev:latest \
    bash -c 'export PATH=$PATH:/usr/local/pspdev/bin; make -f Makefile.psp all'

echo "=== [3/5] Building host tools (usbhostfs_pc, pspsh) ==="
( cd "$PSPLINK_SRC/usbhostfs_pc" && make )
( cd "$PSPLINK_SRC/pspsh" && make )

echo "=== [4/5] Installing host tools + always-on daemon service ==="
mkdir -p "$HOME/.local/bin"
install -m755 "$PSPLINK_SRC/usbhostfs_pc/usbhostfs_pc" "$HOME/.local/bin/usbhostfs_pc"
install -m755 "$PSPLINK_SRC/pspsh/pspsh" "$HOME/.local/bin/pspsh"
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/psp-usbhostfs.service" <<UNIT
[Unit]
Description=PSPLink usbhostfs_pc daemon (serves host0: to the PSP over USB)
Documentation=file://$REPO_DIR/psp_link.sh

[Service]
Type=simple
ExecStart=$HOME/.local/bin/usbhostfs_pc $REPO_DIR/retro_engine/psp/hwrun
Environment=USBHOSTFS_POLL_MS=100
Restart=on-failure
RestartSec=1
StandardOutput=append:/tmp/usbhostfs_pc.log
StandardError=append:/tmp/usbhostfs_pc.log

[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now psp-usbhostfs.service
loginctl enable-linger 2>/dev/null || sudo -n loginctl enable-linger "$USER" 2>/dev/null || true
echo "installed ~/.local/bin/{usbhostfs_pc,pspsh} + psp-usbhostfs.service (enabled)"

echo "=== [5/5] Deploying to the memory stick ==="
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
NOTE: the memory-stick copy above already includes the usbhostfs watchdog
(0003). On an already-installed PSP, ./psp_install_prx.sh refreshes just that
module without re-running the whole setup.
EOF
