#!/usr/bin/env bash
# Regenerates tests/fixtures/release_<version>/ with the RELEASE'S OWN CODE.
#
# The fixture is the compatibility contract with maps users made on a public
# release: it must be produced by that release, never by the current tree.
# Usage: tools/release_fixture/make_release_fixture.sh [commit] [version-dir]
# (defaults: de492fe = the v0.9.167 nightly, release_v0_9_167).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMMIT="${1:-de492fe}"
NAME="${2:-release_v0_9_167}"
# Inside project/exports (gitignored, .gdignore'd) so the guard container,
# which mounts the repo at /work, can see it.
WT_REL="project/exports/_release_wt"
WT="$REPO_ROOT/$WT_REL"
OUT="$REPO_ROOT/project/tests/fixtures/$NAME"
cd "$REPO_ROOT"
git worktree remove --force "$WT" 2>/dev/null || true
git worktree add --detach "$WT" "$COMMIT"
trap 'git -C "$REPO_ROOT" worktree remove --force "$WT" 2>/dev/null || true' EXIT
cp "$REPO_ROOT/tools/release_fixture/make_release_fixture.gd" "$WT/project/"
GUARD="$REPO_ROOT/tools/godot_guard.sh"
# Import pass (class cache), then the builder.
"$GUARD" exec bash -c "cd /work/$WT_REL/project && timeout 300 godot-mono --headless --editor --quit-after 200" >/dev/null 2>&1 || true
"$GUARD" exec bash -c "cd /work/$WT_REL/project && timeout 300 godot-mono --headless --script res://make_release_fixture.gd" 2>&1 | grep -E "RELEASE_FIXTURE|SCRIPT ERROR" || true
mkdir -p "$OUT"
cp "$WT/project/release_fixture.scn" "$WT/project/release_fixture.json" "$OUT/"
ls -la "$OUT"
