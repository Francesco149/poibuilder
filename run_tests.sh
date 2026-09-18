#!/usr/bin/env bash
# PoiBuilder test runner — hardened against GUT's silent-skip hole.
#
# A test script that fails to PARSE is skipped by GUT with the suite still
# green (this is exactly how the Phase 6 normals bug reached a human: the
# tests that would have caught it silently never ran). This runner closes
# that hole:
#
#   1. Refreshes the global class cache first (new class_name scripts are
#      only registered by an editor filesystem scan; a stale cache makes
#      tests fail to resolve classes). Fails on any script error here —
#      this also boots the plugin, so plugin registration errors are caught.
#   2. Runs the GUT suite headlessly.
#   3. FAILS if any SCRIPT ERROR appears in the output, even when GUT is green.
#   4. FAILS if the number of discovered test suites differs from the number
#      of test_*.gd files on disk (silent-skip guard).
#
# Usage:
#   ./run_tests.sh                  # the full suite — the only accepted way
#                                   # to claim "tests pass"
#   ./run_tests.sh -gselect=X.gd    # filtered run while iterating (GUT args
#                                   # pass through). A filtered run skips the
#                                   # silent-skip count guard by definition —
#                                   # it does NOT count as "tests pass".
#
# CONTAINMENT: every Godot invocation runs through tools/godot_guard.sh —
# a hard memory cap (podman container, or a systemd scope fallback) with a
# hard timeout and forced process-group cleanup, so a hung headless run can
# never again pile up into an OOM. PB_GUARD=off bypasses (debugging only).
set -uo pipefail
# Anchor on the script location BEFORE any cd: computing paths from "$0"
# after `cd project` silently resolved the guard to project/tools/… (which
# does not exist) and the old silent fallback then ran Godot UNCAPPED on
# every invocation. This resolution bug is why the podman path was dead code.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT/project"

FAIL=0

# The suite runs inside ONE persistent, memory-capped container (2 GB default,
# 8 GB hard max) — see tools/godot_guard.sh. GUARD_MEM env raises it if the
# suite ever needs more; the kernel OOM-kills inside the cap, never the host.
# The guard VERIFIES its cap: where rootless podman has no cgroup management
# it enforces via a systemd user scope, and refuses to run at all when the
# cap cannot be enforced (PB_GUARD_UNCAPPED=1 overrides, ulimit backstop).
# PB_GUARD=off is the only direct-exec path and still applies a best-effort
# 8 GB ulimit — the suite can never again run with NO ceiling at all.
GUARD="${PB_GUARD:-podman}"
GUARD_SCRIPT="$REPO_ROOT/tools/godot_guard.sh"
# Inside the container the repo is bind-mounted at /work (godot_guard.sh);
# on the host the checkout's own path applies. Callers cd into PROJECT_DIR
# before running Godot so relative paths (res://, tests/) keep working in
# both environments.
PB_TEST_TIMEOUT="${PB_TEST_TIMEOUT:-900}"
if [ "$GUARD" = "off" ]; then
  PROJECT_DIR="$REPO_ROOT/project"
else
  PROJECT_DIR="/work/project"
fi
run_guarded() {
  local dir="$1"
  shift
  if [ "$GUARD" = "off" ]; then
    echo "WARNING: PB_GUARD=off — best-effort 8GB ulimit only, no container cap" >&2
    bash -c 'ulimit -v 8388608; cd "$1" || exit 70; shift; exec "$@"' _ "$dir" "$@"
  elif [ ! -x "$GUARD_SCRIPT" ]; then
    # Fail closed: an uncontained Godot run is how the machine OOM'd.
    echo "FAIL: $GUARD_SCRIPT missing or not executable — refusing to run Godot uncapped." >&2
    return 1
  else
    "$GUARD_SCRIPT" exec bash -c 'cd "$1" || exit 70; shift; exec "$@"' _ "$dir" "$@"
  fi
}
# GUT colours its output. Pattern-matching the raw log silently fails on
# anything anchored to the line start (a test line begins with a colour reset,
# not with "* "), so reporting reads the log through this.
strip_ansi() {
  sed 's/\x1b\[[0-9;]*m//g' "$1"
}
cleanup_container() {
  if [ "$GUARD" != "off" ] && [ -x "$GUARD_SCRIPT" ]; then
    "$GUARD_SCRIPT" cleanup
  fi
}
trap cleanup_container EXIT

echo "== [1/4] Refreshing imports/class cache (editor boot smoke test) =="
if ! run_guarded "$PROJECT_DIR" timeout 180 godot-mono --headless --editor --quit-after 100 > /tmp/pb_import.log 2>&1; then
  echo "WARN: editor run exited nonzero (may be benign headless teardown)"
fi
if grep -q "SCRIPT ERROR" /tmp/pb_import.log; then
  echo "FAIL: script errors during editor boot:" >&2
  grep -A4 "SCRIPT ERROR" /tmp/pb_import.log >&2
  FAIL=1
fi

echo "== [2/4] Running GUT suite (hard timeout ${PB_TEST_TIMEOUT}s) =="
LOG=/tmp/pb_gut.log
GUT_RC=0
GODOT_DISABLE_LEAK_CHECKS=1 run_guarded "$PROJECT_DIR" timeout "$PB_TEST_TIMEOUT" godot-mono --headless -s addons/gut/gut_cmdln.gd \
    -gdir=res://tests -ginclude_subdirs -gexit "$@" > "$LOG" 2>&1 || GUT_RC=$?
if [ "$GUT_RC" -ne 0 ]; then
  FAIL=1
  if [ "$GUT_RC" -eq 124 ]; then
    echo "FAIL: GUT hit the ${PB_TEST_TIMEOUT}s timeout — the suite was killed mid-run." >&2
  else
    echo "FAIL: GUT exited with status $GUT_RC." >&2
  fi
  if grep -qE "^Tests +[0-9]+" "$LOG"; then
    # A finished run: say WHICH tests failed (GUT prints the suite path, then
    # "* test_name", then one line per assertion) instead of making the reader
    # grep a 20k-line log.
    {
      echo "-- failing tests --"
      strip_ansi "$LOG" | awk '/^res:\/\/tests\//{suite=$0} /^\* /{name=$0} /\[Failed\]/{key=suite" "name; if (!(key in seen)) {seen[key]=1; print suite"  "name}}' | head -25
    } >&2
  else
    # No summary line at all: the process died before GUT could report — a
    # crash or an OOM inside the guard's memory cap, or a test/addon script
    # edited while the suite was loading it. Name the stopping point so the
    # truncated log is not a mystery.
    {
      echo "-- the suite did NOT finish (no summary line in the log) --"
      echo "   last suite: $(strip_ansi "$LOG" | grep '^res://tests/' | tail -1)"
      echo "   last test:  $(strip_ansi "$LOG" | grep '^\* ' | tail -1)"
      echo "   likely: a crash/OOM inside the guard's memory cap (GUARD_MEM=${GUARD_MEM:-default 2G}), or a test/addon file changed while the suite ran."
      echo "   log tail:"
      tail -6 "$LOG" | sed 's/^/     /'
    } >&2
  fi
fi

echo "== [3/4] Checking for script errors inside the test run =="
if grep -q "SCRIPT ERROR" "$LOG"; then
  echo "FAIL: script errors during test run (GUT may have silently skipped a script):" >&2
  grep -A4 "SCRIPT ERROR" "$LOG" | head -30 >&2
  FAIL=1
fi

echo "== [4/4] Verifying every test script was discovered =="
# grep -c prints 0 AND exits 1 on a zero-match file, so `|| echo 0` fired
# too and produced "0\n0" — the guard disabled itself exactly when results.xml
# held no suites (the case it exists for). grep's own zero IS the count.
TESTFILES=$(find tests -name 'test_*.gd' | wc -l | tr -d ' ')
SUITECOUNT=$(grep -c '<testsuite name=' tests/results.xml 2>/dev/null)
SUITECOUNT=${SUITECOUNT:-0}
echo "   test files on disk: $TESTFILES   suites discovered: $SUITECOUNT"
if [ "$#" -gt 0 ]; then
  echo "   (filtered run — suite-count guard skipped)"
elif [ "$TESTFILES" -ne "$SUITECOUNT" ]; then
  echo "FAIL: script count mismatch — a test script was skipped (parse error or class resolution failure)" >&2
  FAIL=1
fi

echo "== Summary =="
grep -E "Tests |Passing Tests|Failing Tests|Asserts" "$LOG" | sed 's/^ *//' || true

if [ "$FAIL" -ne 0 ]; then
  echo "RESULT: FAILED" >&2
  exit 1
fi
echo "RESULT: PASSED"
