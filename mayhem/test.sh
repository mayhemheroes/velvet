#!/usr/bin/env bash
# velvet/mayhem/test.sh — RUN velvet's OWN functional test suite (tests/run-tests.sh), which
# golden-diffs velveth output (Sequences / Roadmaps) against the committed reference files
# Sequences.31 / Roadmaps.31 using `cmp -s`. This asserts BEHAVIOR/OUTPUT (known-answer / golden
# diffs), so a no-op / exit(0) PATCH fails it — it is NOT a mere "exit 0 / didn't crash" check.
#
# Does NOT compile: mayhem/build.sh already built the clean (NORMAL-flags) velveth/velvetg into
# mayhem/test-bin/. The upstream runner hardcodes ../velveth and ../velvetg relative to tests/, so
# we run it from a staging dir whose parent holds those clean binaries (never the sanitized fuzz
# binaries — an honest functional oracle uses the project's real build).
#
# velvet's run-tests.sh exits 0 on full success and `exit 2` (problem) on the FIRST mismatch; it does
# not report per-test counts on failure, so we drive each tests/*.t individually to get real
# passed/failed counts for CTRF.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

VH=/mayhem/mayhem/test-bin/velveth
VG=/mayhem/mayhem/test-bin/velvetg
[ -x "$VH" ] && [ -x "$VG" ] || { echo "missing clean test binaries ($VH / $VG) — run mayhem/build.sh first" >&2; exit 2; }

# Stage: the runner uses VH=../velveth, VG=../velvetg, so the clean binaries must sit one dir above
# a copy of tests/. Use a scratch staging dir.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp "$VH" "$STAGE/velveth"
cp "$VG" "$STAGE/velvetg"
cp -r "$SRC/tests" "$STAGE/tests"
cd "$STAGE/tests"

export OMP_NUM_THREADS=1
# shellcheck disable=SC1091
. ./run-tests.functions   # provides $VH=../velveth, $SEQ, $ROADMAP, inform/problem, the FQ*/FA* vars

passed=0; failed=0
DIR="$(mktemp -d "$STAGE/tests/velvet.test.XXXXXX")"
export DIR
for TEST in *.t ; do
  # Each .t calls `problem` -> exit 2 on the first failed assertion. Run it in a subshell so one
  # failing test does not abort the whole suite; subshell exit !=0 => that test failed.
  if ( . ./"$TEST" ) >/dev/null 2>&1; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAILED: $TEST" >&2
  fi
done

emit_ctrf "velvet-tests" "$passed" "$failed"
