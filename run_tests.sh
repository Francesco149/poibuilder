#!/usr/bin/env bash
# ProBuilder test runner — hardened against GUT's silent-skip hole.
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
set -uo pipefail
cd "$(dirname "$0")/project"

FAIL=0

echo "== [1/4] Refreshing imports/class cache (editor boot smoke test) =="
if ! timeout 120 godot-mono --headless --editor --quit-after 100 > /tmp/pb_import.log 2>&1; then
  echo "WARN: editor run exited nonzero (may be benign headless teardown)"
fi
if grep -q "SCRIPT ERROR" /tmp/pb_import.log; then
  echo "FAIL: script errors during editor boot:" >&2
  grep -A4 "SCRIPT ERROR" /tmp/pb_import.log >&2
  FAIL=1
fi

echo "== [2/4] Running GUT suite =="
LOG=/tmp/pb_gut.log
if ! GODOT_DISABLE_LEAK_CHECKS=1 godot-mono --headless -s addons/gut/gut_cmdln.gd \
    -gdir=res://tests -ginclude_subdirs -gexit > "$LOG" 2>&1; then
  echo "FAIL: GUT exited nonzero" >&2
  grep -E "\[Failed\]|Failing" "$LOG" | head -30 >&2
  FAIL=1
fi

echo "== [3/4] Checking for script errors inside the test run =="
if grep -q "SCRIPT ERROR" "$LOG"; then
  echo "FAIL: script errors during test run (GUT may have silently skipped a script):" >&2
  grep -A4 "SCRIPT ERROR" "$LOG" | head -30 >&2
  FAIL=1
fi

echo "== [4/4] Verifying every test script was discovered =="
TESTFILES=$(find tests -maxdepth 1 -name 'test_*.gd' | wc -l | tr -d ' ')
SUITECOUNT=$(grep -c '<testsuite name=' tests/results.xml 2>/dev/null || echo 0)
echo "   test files on disk: $TESTFILES   suites discovered: $SUITECOUNT"
if [ "$TESTFILES" -ne "$SUITECOUNT" ]; then
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
