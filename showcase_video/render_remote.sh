#!/usr/bin/env bash
# render_remote.sh — render showcase sessions on the GPU box, pull the frames back.
#
#   ./showcase_video/render_remote.sh <session>[,<session>...] [shot,shot,...]
#
# Same frames as render.sh, ~10x faster: the editor draws on a real GPU
# through a headless Weston (kiosk shell, GL renderer) and Godot's native
# Wayland driver, instead of llvmpipe under Xvfb. Measured on the smoke
# session: 43.4 s -> 3.6 s for the same 156-frame shot (draw 60 ms -> 4 ms a
# frame; what is left is the PNG encode, which render.sh already threads).
#
# What it does:
#   1. syncs the repo (tracked files + the project's untracked assets, never
#      .godot/ or exports/) and the cached editor HOME to the box
#   2. starts the headless compositor once (kept running between calls)
#   3. runs render.sh there with the same PB_SHOWCASE_LAYOUT / ONLY knobs
#   4. pulls back the manifest, the logs and exactly the shot directories
#      this run (re)recorded — local shots it did not touch stay as they are
#
#   PB_REMOTE_HOST   (default lame)      ssh host; must have nix
#   PB_REMOTE_DIR    (default /var/tmp/poibuilder-showcase)
#   PB_REMOTE_GPU    (default pci-0000_04_00_0 = lame's RX 570, idle; the
#                    7800 XT runs the LLM server) — a DRI_PRIME device tag
#   PB_SHOWCASE_LAYOUT is forwarded (path relative to the repo).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSIONS="${1:?usage: render_remote.sh <session>[,<session>...] [shot,...]}"
ONLY="${2:-}"
HOST="${PB_REMOTE_HOST:-lame}"
RDIR="${PB_REMOTE_DIR:-/var/tmp/poibuilder-showcase}"
GPU="${PB_REMOTE_GPU:-pci-0000_04_00_0}"
LAYOUT="${PB_SHOWCASE_LAYOUT:-}"
SOCK=pbshow-0

cd "$REPO"
LOCAL_VER="$(godot-mono --version 2>/dev/null | tail -1 | cut -d. -f1-3)"

echo "== sync -> $HOST:$RDIR =="
ssh "$HOST" "mkdir -p $RDIR/repo $RDIR/bake"
git ls-files -z | rsync -a --from0 --files-from=- ./ "$HOST:$RDIR/repo/"
# Untracked project assets the editor shows (palette textures, test assets)
# — the frames must match a local render, so the project must too.
rsync -a --exclude .godot/ --exclude exports/ project/ "$HOST:$RDIR/repo/project/"
rsync -a --delete showcase_video/bake/.home/ "$HOST:$RDIR/repo/showcase_video/bake/.home/"
for s in ${SESSIONS//,/ }; do
    if [ -f "showcase_video/bake/$s/manifest.json" ]; then
        # render.sh merges a partial render into the manifest it finds.
        ssh "$HOST" "mkdir -p $RDIR/bake/$s"
        rsync -a "showcase_video/bake/$s/manifest.json" "$HOST:$RDIR/bake/$s/"
    fi
done

rc=0
# shellcheck disable=SC2087
# ssh joins its arguments into ONE command line: an empty ONLY ("") would
# vanish and shift every later argument. Quote each one for the remote shell.
REMOTE_ARGS="$(printf '%q ' "$RDIR" "$GPU" "$SOCK" "$SESSIONS" "$ONLY" "$LAYOUT" "$LOCAL_VER")"
(ssh "$HOST" "bash -s -- $REMOTE_ARGS" <<'REMOTE'
set -uo pipefail
RDIR="$1"; GPU="$2"; SOCK="$3"; SESSIONS="$4"; ONLY="$5"; LAYOUT="$6"; WANT_VER="$7"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
GODOT_BIN="$(nix build --no-link --print-out-paths 'nixpkgs#godot^out')/bin/godot"
WESTON_BIN="$(nix build --no-link --print-out-paths 'nixpkgs#weston^out')/bin/weston"
GOT_VER="$("$GODOT_BIN" --version | tail -1 | cut -d. -f1-3)"
if [ -n "$WANT_VER" ] && [ "$GOT_VER" != "$WANT_VER" ]; then
    echo "WARNING: remote godot $GOT_VER != local $WANT_VER" >&2
fi

# The compositor: started once, reused. A pidfile, never pkill -f (that
# matches this very shell's command line).
cd "$RDIR"
if ! { [ -f weston.pid ] && kill -0 "$(cat weston.pid)" 2>/dev/null && [ -S "$XDG_RUNTIME_DIR/$SOCK" ]; }; then
    echo "== starting headless weston on $GPU =="
    (DRI_PRIME="$GPU" setsid "$WESTON_BIN" --backend=headless --renderer=gl \
        --shell=kiosk --width=1920 --height=1080 --socket="$SOCK" --idle-time=0 \
        > weston.log 2>&1 & echo $! > weston.pid)
    for _ in $(seq 1 50); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.1; done
    grep -m1 "GL renderer:" weston.log || { echo "weston failed:"; tail weston.log; exit 2; }
fi

cd "$RDIR/repo"
rc=0
for s in ${SESSIONS//,/ }; do
    touch "$RDIR/bake/.mark_$s"
    # DRI_PRIME for the CLIENT too: without it Godot picked the 7800 XT the
    # LLM server is using (weston's own device choice does not carry over).
    env DRI_PRIME="$GPU" GODOT_SILENCE_ROOT_WARNING=1 PB_SHOWCASE_GODOT="$GODOT_BIN" PB_SHOWCASE_WAYLAND="$SOCK" \
        PB_SHOWCASE_OUT="$RDIR/bake/$s" \
        ${LAYOUT:+PB_SHOWCASE_LAYOUT="$LAYOUT"} \
        ./showcase_video/render.sh "$s" "$ONLY" \
        | grep -E "^\[showcase\] (shot |done|SUMMARY|captured)|FAIL|SCRIPT ERROR|=== session" || true
    # The shot dirs this run wrote, for the pull-back.
    # (cursor.bin is rewritten by every recorded shot; the dir's own mtime
    # does not move when existing files are truncated.)
    find "$RDIR/bake/$s/shots" -mindepth 2 -maxdepth 2 -name cursor.bin \
        -newer "$RDIR/bake/.mark_$s" -printf '%h\n' | xargs -rn1 basename \
        > "$RDIR/bake/$s/.touched" 2>/dev/null
    grep -q "failed=0 frames" "$RDIR/bake/$s/render.log" || rc=1
done
exit $rc
REMOTE
) || rc=$?

echo "== pull <- $HOST =="
for s in ${SESSIONS//,/ }; do
    mkdir -p "showcase_video/bake/$s/shots"
    rsync -a "$HOST:$RDIR/bake/$s/manifest.json" "$HOST:$RDIR/bake/$s/render.log" \
        "$HOST:$RDIR/bake/$s/.touched" "showcase_video/bake/$s/"
    while read -r slug; do
        [ -n "$slug" ] || continue
        # --delete: a re-recorded shot may be shorter; stale tail frames would
        # otherwise survive into the cut.
        rsync -a --delete "$HOST:$RDIR/bake/$s/shots/$slug/" "showcase_video/bake/$s/shots/$slug/"
        echo "   $s/$slug"
    done < "showcase_video/bake/$s/.touched"
done
exit $rc
