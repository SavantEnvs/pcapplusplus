#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# RUN Packet++Test (built by mayhem/build.sh with the project's normal flags). It is the project's own
# assertion suite: every case prints "<name> : PASSED|FAILED|SKIPPED". We parse those lines ourselves, so a
# neutered/absent binary (no output) yields zero passes and fails below instead of passing silently.
TESTDIR="$SRC/build/tests/Tests/Packet++Test"
[ -x "$TESTDIR/Packet++Test" ] || { echo "Packet++Test missing — mayhem/build.sh must build it" >&2; emit_ctrf "packet++test" 0 1 0; exit 1; }
cd "$TESTDIR"
OUT="$(mktemp)"
./Packet++Test -s > "$OUT" 2>&1
RC=$?
cat "$OUT"
passed=$(grep -cE ': PASSED$' "$OUT")
failed=$(grep -cE ': FAILED' "$OUT")
skipped=$(grep -cE ': SKIPPED' "$OUT")
# Known-answer floor: the suite has ~285 cases; far fewer means it did not really run.
if [ "$passed" -lt 250 ]; then echo "only $passed tests passed (expected >=250)" >&2; failed=$((failed + 1)); fi
grep -q 'ALL TESTS PASSED' "$OUT" || { echo "no 'ALL TESTS PASSED' verdict from Packet++Test (rc=$RC)" >&2; failed=$((failed + 1)); }
emit_ctrf "packet++test" "$passed" "$failed" "$skipped"
