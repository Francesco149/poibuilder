# PSPLink host-tool patches (usbhostfs_pc)

The PSP workflow in this repo depends on a patched `usbhostfs_pc` (the PSPLink
USB host daemon). The patches live here as git patches so they survive `/tmp`
and can be re-applied to a fresh upstream clone; `setup_psplink.sh` does that
automatically.

## The failure model these patches fix

PSPLink on the PSP presents its USB device (054c:01c9) for only **a few
seconds per activation** while waiting for a host. Every activation the host
misses **shrinks the next window** (observed 8s → 1s over about a minute)
until the PSP gives up entirely and presents nothing — the state where
replugging appears dead and only relaunching PSPLink on the device (or a
reboot) recovers it. A cable replug does NOT reset this: the degraded state
lives in the PSP's loaded modules. The kernel-log signature is
`new high-speed USB device ... USB disconnect` pairs a few seconds apart.

The host must therefore already be running a healthy daemon whenever the PSP
(re)attaches, and it must claim fast. See `../psp_link.sh` for the host-side
lifecycle built around that rule.

## The patches

### 0001 — poll every 100 ms, log missed windows

- `wait_for_device()` polls every `USBHOSTFS_POLL_MS` (default 100, was a
  fixed 1 s sleep) — the claim + handshake now land inside even short
  activation windows.
- A PSP that appears but fails to claim is logged instead of silently
  retrying.
- Exit code 0 on SIGINT/SIGTERM, 1 otherwise, so supervision can tell an
  intentional stop from a crash (the `psp-usbhostfs.service` user unit
  auto-restarts crashes but not clean stops — other projects may still pkill
  the daemon without starting a respawn war).
- stdout is line-buffered so the redirected log's order is trustworthy.

### 0002 — no async traffic before the PSP's hello; usbhdr race; drop logging

Caught live on 2026-09-18: a claimed-and-magic'd link died ~1 s in while
`pspsh` probes injected async data onto endpoint 0x3 mid-handshake — the PSP
only posts its async receive after its own `send_hello_cmd()` succeeds.

- Async (pspsh) data is held back until the PSP completed the hostfs HELLO
  exchange (`g_psp_hello`), and dropped (with a log line) before that.
- `usbhdr` is mutexed so `close_device()` on the main thread cannot race the
  async thread's bulk writes into a closed handle.
- The serve loop's exit path logs the read error (it used to `break`
  silently — the PSP dropping the link was invisible).
- Link-critical log lines are timestamped (`[HH:MM:SS.mmm]`) for correlation
  with dmesg, and `PSP hello exchanged — hostfs link established` is the
  definitive link-up marker (grep target for scripts).

### 0003 — usbhostfs.prx re-activation watchdog (PSP side)

The give-up state itself, killed at the source. The stock PSP-side stack
shrinks its activation window on every missed host claim and eventually
stops presenting USB entirely — a state only relaunching PSPLink on the
device clears (a cable replug does not; the degraded state lives in the
loaded modules). The watchdog thread in `usbhostfs.prx`:

- does nothing while a host link is up;
- when no host has been connected for two 15 s intervals, cycles
  `sceUsbDeactivate`/`sceUsbActivate` — a *software replug*: it resets the
  activation patience AND aborts in-flight requests, which also unfreezes
  the `usb_thread` if it is parked in one of its timeout-less transfer
  waits.

So a waiting host daemon gets a fresh activation to claim every ~15–30 s,
forever. Combined with the always-on `psp-usbhostfs.service` daemon, the
recovery from any wedge is: nothing — no replug, no reboot, no pkill.

**Installing it**: this patch changes a PSP-side module, so it must reach
`ms0:/PSP/GAME/PSPLINK/usbhostfs.prx` once — either a full
`./setup_psplink.sh` (its memory-stick step copies the patched build) or the
one-shot `./psp_install_prx.sh` (backs up the old module first). Afterwards
relaunch PSPLink on the device once.

## Where things live

| What | Where |
|---|---|
| Patched source clone | `~/.local/share/psplinkusb` (patches committed on top of upstream) |
| Installed binaries | `~/.local/bin/usbhostfs_pc`, `~/.local/bin/pspsh` |
| Daemon supervision | `~/.config/systemd/user/psp-usbhostfs.service` (enabled, linger on) |
| Patch files | this directory (applied by `../setup_psplink.sh`) |

`psp_link.sh` resolves binaries from `~/.local/bin` first, so scripts use the
patched daemon regardless of `PSPLINK_SRC`.

## Verifying the running binary is patched

- Its log prints `waiting for device... (polling every 100 ms)`.
- `strings ~/.local/bin/usbhostfs_pc | grep 'PSP hello exchanged'` finds the
  link-up marker.
- `./psp_probe.sh` layer 2 reports `RUNNING and CONNECTED` when a PSP is up.

## Re-applying by hand

```sh
git -C ~/.local/share/psplinkusb apply --check psp_patches/0001-*.patch || \
git -C ~/.local/share/psplinkusb apply psp_patches/0001-*.patch
# same for 0002, then:
make -C ~/.local/share/psplinkusb/usbhostfs_pc
install -m755 ~/.local/share/psplinkusb/usbhostfs_pc/usbhostfs_pc ~/.local/bin/
systemctl --user restart psp-usbhostfs
```

These changes are small and generic enough to offer upstream
(pspdev/psplinkusb); until then the patches are carried here.
