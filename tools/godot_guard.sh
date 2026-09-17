#!/usr/bin/env bash
# godot_guard.sh — ONE persistent, memory-capped container for every headless
# Godot invocation. Modeled on ../recettear-decomp/scripts/container.sh.
#
#   tools/godot_guard.sh exec <cmd…>   run a command inside it (THE way)
#   tools/godot_guard.sh sh            interactive shell in it
#   tools/godot_guard.sh recycle       force teardown + fresh container now
#   tools/godot_guard.sh cleanup       force-remove it (and any strays)
#   tools/godot_guard.sh status        print container state + cap enforcement
#   tools/godot_guard.sh verify        PROVE the cap works (OOM-kills a 3G hog)
#
# Why this exists: on 2026-09-17 stray headless Godot processes piled up and
# OOM'd the machine. Here the guarantee is structural, not behavioral:
#   * exactly ONE container can ever exist (named, labeled),
#   * a kernel cgroup cap (GUARD_MEM, default 2 GB, hard max 8 GB) bounds the
#     whole process tree — the kernel OOM-kills INSIDE the cap long before the
#     host is at risk, even if the caller is SIGKILLed and orphans the child,
#   * `--init` reaps zombie children,
#   * the container self-recycles when older than GUARD_RECYCLE_AFTER (4 h),
#   * `cleanup` force-removes it and sweeps any labeled strays.
#
# 2026-09-17, later: the guarantee was found VOID on this machine. Rootless
# podman without cgroup delegation runs containers with an EMPTY CgroupPath —
# `--memory=2G` is silently not enforced and container processes inherit the
# CALLER's cgroup (a runaway test ballooned to 15+ GB under the "guard").
# The guard now VERIFIES enforcement instead of assuming it:
#   * podman cgroups active → the container's own cap is real;
#   * otherwise EVERY exec is wrapped in a systemd user transient scope with
#     MemoryMax (systemd is what actually owns cgroups here) — the cap still
#     holds even for orphaned processes;
#   * if NEITHER can enforce, exec FAILS CLOSED — it refuses to run Godot
#     uncapped. PB_GUARD_UNCAPPED=1 overrides at your own risk (best-effort
#     8 GB ulimit + loud warning; not a real cap).
#
# Env: GUARD_MEM (default 2G, clamped to <= 8G), GUARD_CPUS (default 4),
# GUARD_RECYCLE_AFTER (default 4h), PB_GUARD_UNCAPPED (=1 to allow uncapped).
set -euo pipefail

NAME="poibuilder-godot"
LABEL="poibuilder-godot"
IMAGE="localhost/poibuilder-godot:latest"
GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$GUARD_DIR")"
HOME_DIR="${GUARD_HOME:-/tmp/pb_godot_home}"

GUARD_MEM="${GUARD_MEM:-2G}"
GUARD_CPUS="${GUARD_CPUS:-4}"
GUARD_RECYCLE_AFTER="${GUARD_RECYCLE_AFTER:-4h}"
# Best-effort virtual-address backstop for the PB_GUARD_UNCAPPED escape hatch.
UNCAPPED_ULIMIT_KB="${UNCAPPED_ULIMIT_KB:-8388608}"

# Clamp RAM to the 8 GB ceiling the project allows.
mem_g="${GUARD_MEM//[!0-9]/}"
case "$GUARD_MEM" in
  *G|*g) : ;;
  *M|*m) GUARD_MEM="$(( mem_g > 8192 ? 8192 : (mem_g < 256 ? 256 : mem_g) ))M" ;;
  *) GUARD_MEM="$(( mem_g > 8 ? 8 : (mem_g < 1 ? 2 : mem_g) ))G" ;;
esac

mkdir -p "$HOME_DIR"

state() { podman inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null || true; }

# Empty output means podman is NOT managing cgroups here (rootless without
# delegation): the container's --memory flag is void and container processes
# inherit the caller's cgroup.
container_cgroup_path() {
    podman inspect -f '{{.CgroupPath}}' "$NAME" 2>/dev/null || true
}

container_age_seconds() {
    local started
    started="$(podman inspect -f '{{.State.StartedAt}}' "$NAME" 2>/dev/null || true)"
    [ -n "$started" ] || { echo 999999999; return; }
    local now started_s
    now="$(date +%s)"
    started_s="$(date -d "${started%%.*}" +%s 2>/dev/null || echo "$now")"
    echo $((now - started_s))
}

remove_container() {
    podman rm -f "$NAME" >/dev/null 2>&1 || true
    # sweep any labeled strays from older invocations
    local ids
    ids="$(podman ps -aq --filter "label=${LABEL}" 2>/dev/null || true)"
    # shellcheck disable=SC2086
    [ -n "$ids" ] && podman rm -f $ids >/dev/null 2>&1 || true
}

ensure_image() {
    if podman image exists "$IMAGE" >/dev/null 2>&1; then
        return 0
    fi
    echo "[guard] building $IMAGE (one-time, ~750 MB context)..." >&2
    local ctx
    ctx="$(mktemp -d /tmp/pb_guard_ctx.XXXXXX)"
    mkdir -p "$ctx/godot-mono" "$ctx/dotnet"
    cp -a /usr/lib/godot-mono/. "$ctx/godot-mono/"
    cp -a /usr/share/dotnet/. "$ctx/dotnet/"
    install -m 644 "$GUARD_DIR/Containerfile.godot" "$ctx/Containerfile.godot"
    install -m 755 "$GUARD_DIR/godot-wrapper" "$ctx/godot-wrapper"
    local ok=0
    (cd "$ctx" && podman build --format docker -t "$IMAGE" -f Containerfile.godot . >/dev/null 2>&1) && ok=1
    rm -rf "$ctx"
    [ "$ok" = 1 ] || { echo "[guard] image build failed" >&2; return 1; }
}

create_container() {
    ensure_image
    echo "[guard] creating persistent container (${GUARD_MEM} RAM, ${GUARD_CPUS} CPUs)"
    # stderr is kept visible: a failed --memory cgroup setup must not be silent.
    podman run -d --name "$NAME" \
        --label "${LABEL}=1" \
        --memory="$GUARD_MEM" --memory-swap="$GUARD_MEM" \
        --cpus="$GUARD_CPUS" \
        --userns=keep-id \
        --init \
        -v /usr/lib:/usr/lib:ro \
        -v "${HOME_DIR}:/home/guard:Z" \
        -v "${REPO_ROOT}:/work:Z" \
        -w /work \
        -e HOME=/home/guard \
        -e DOTNET_ROOT=/usr/share/dotnet \
        "$IMAGE" \
        sleep infinity >/dev/null
    if [ -z "$(container_cgroup_path)" ]; then
        echo "[guard] NOTE: podman has no cgroup management here (empty CgroupPath) —" >&2
        echo "[guard] the container's --memory flag is VOID; exec enforces the cap" >&2
        echo "[guard] via a systemd user scope instead (see run_capped below)." >&2
    fi
}

ensure_container() {
    local st
    st="$(state)"
    if [ -z "$st" ]; then
        create_container
        return 0
    fi
    local age max_age
    age="$(container_age_seconds)"
    max_age="$(echo "$GUARD_RECYCLE_AFTER" | tr -d 'h')"; max_age="${max_age:-4}"
    max_age=$((max_age * 3600))
    if [ "$age" -gt "$max_age" ]; then
        echo "[guard] container is ${age}s old — forced recycle"
        remove_container
        create_container
        return 0
    fi
    if [ "$st" != "running" ]; then
        podman start "$NAME" >/dev/null
    fi
}

scope_works() {
    command -v systemd-run >/dev/null 2>&1 || return 1
    [ -n "${XDG_RUNTIME_DIR:-}" ] || return 1
    systemd-run --user --scope --quiet -p MemoryMax=16M true >/dev/null 2>&1
}

## Runs "$@" inside the container under a cap that is actually enforced.
## Never assumes: podman's flag is only trusted while podman manages cgroups,
## and an unusable systemd scope fails CLOSED rather than running uncapped.
run_capped() {
    [ "$#" -gt 0 ] || { echo "[guard] run_capped needs a command" >&2; exit 2; }
    if [ -n "$(container_cgroup_path)" ]; then
        podman exec -e HOME=/home/guard "$NAME" "$@"
        return
    fi
    if scope_works; then
        # The scope contains the podman client AND (cgroup-less rootless)
        # everything it spawns — conmon, the container init, Godot — so the
        # kernel OOM-kills inside the cap even if this guard is killed and
        # the tree is orphaned.
        systemd-run --user --scope --quiet \
            -p "MemoryMax=${GUARD_MEM}" -p MemorySwapMax=0 -p MemoryZSwapMax=0 \
            podman exec -e HOME=/home/guard "$NAME" "$@"
        return
    fi
    if [ "${PB_GUARD_UNCAPPED:-0}" = "1" ]; then
        echo "[guard] WARNING: PB_GUARD_UNCAPPED=1 — NO kernel memory cap!" >&2
        echo "[guard] Best-effort ${UNCAPPED_ULIMIT_KB}KB address-space limit only. Ctrl-C if unintended." >&2
        bash -c "ulimit -v ${UNCAPPED_ULIMIT_KB}; exec \"\$@\"" _ \
            podman exec -e HOME=/home/guard "$NAME" "$@"
        return
    fi
    echo "[guard] FAIL: cannot enforce the ${GUARD_MEM} memory cap" >&2
    echo "[guard] (podman cgroups unavailable and no working systemd user scope)." >&2
    echo "[guard] Refusing to run Godot uncapped. Set PB_GUARD_UNCAPPED=1 to override." >&2
    exit 1
}

cmd="${1:-}"
[ -n "$cmd" ] || { sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 2; }
shift

case "$cmd" in
    cleanup)
        echo "[guard] force-removing $NAME and any labeled strays"
        remove_container
        ;;
    recycle)
        remove_container
        create_container
        ;;
    status)
        echo "container: $(state || true) (name=$NAME)"
        local_cg="$(container_cgroup_path)"
        if [ -n "$local_cg" ]; then
            echo "cap: podman-managed cgroup ($local_cg) at ${GUARD_MEM}"
        elif scope_works; then
            echo "cap: podman cgroups UNAVAILABLE — systemd user scope enforces ${GUARD_MEM}"
        elif [ "${PB_GUARD_UNCAPPED:-0}" = "1" ]; then
            echo "cap: NONE (PB_GUARD_UNCAPPED=1 override; best-effort ulimit only)"
        else
            echo "cap: UNENFORCEABLE — exec will fail closed (PB_GUARD_UNCAPPED=1 overrides)"
        fi
        ;;
    verify)
        ensure_container
        echo "[guard] proving the ${GUARD_MEM} cap: allocating ~3G in-container (expect an OOM kill)"
        set +e
        run_capped bash -c 'x=$(head -c 3G /dev/zero | base64); echo "[hog] ALLOCATED-AND-SURVIVED"'
        rc=$?
        set -e
        if [ "$rc" -eq 0 ]; then
            echo "[guard] FAIL: the 3G hog SURVIVED — the memory cap is NOT enforced" >&2
            echo "[guard] Do not run the test suite until this is fixed." >&2
            exit 1
        elif [ "$rc" -ge 128 ]; then
            echo "[guard] OK: hog killed by signal $rc (kernel OOM inside the cap) — cap is enforced"
            exit 0
        else
            echo "[guard] FAIL: hog exited $rc without a kill signal — unexpected" >&2
            exit 1
        fi
        ;;
    sh)
        ensure_container
        run_capped bash
        ;;
    exec)
        [ "$#" -gt 0 ] || { echo "[guard] exec needs a command" >&2; exit 2; }
        ensure_container
        run_capped "$@"
        ;;
    *)
        echo "[guard] unknown subcommand: $cmd (use exec|sh|recycle|cleanup|status|verify)" >&2
        exit 2
        ;;
esac
