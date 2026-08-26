#!/bin/bash
# bench/lib/test.sh - plain-bash smoke tests for the bench library (no bats).
#
# Run:  /bin/bash bench/lib/test.sh
# Exits non-zero if any test fails. Touches no simulator: `xcrun` is stubbed
# through a PATH shim, so nothing here boots, screenshots or drives a device.
#
# Compatible with macOS system /bin/bash 3.2: no associative arrays, no mapfile.

set -euo pipefail

BENCH_TEST_DIR=$(cd "$(dirname "$0")" && pwd)
BENCH_REPO_ROOT=$(cd "$BENCH_TEST_DIR/../.." && pwd)
BENCH_COMMON="$BENCH_TEST_DIR/common.sh"
BENCH_ARCH_DOC="$BENCH_REPO_ROOT/docs/plans/02-architecture.md"

if [ -f "$BENCH_COMMON" ]; then
  # shellcheck source=/dev/null
  . "$BENCH_COMMON"
else
  echo "WARN: $BENCH_COMMON does not exist yet (expected during RED)" >&2
fi

# --- assertions -------------------------------------------------------------
#
# Assertions accumulate into BENCH_TEST_FAILS rather than relying on `set -e`:
# a test invoked from an `if` condition runs with errexit suppressed (bash
# ignores -e for everything inside a condition context, nested functions
# included), so a failing assertion would otherwise be silently skipped over.

BENCH_TEST_FAILS=0

fail() {
  echo "    FAIL: $*" >&2
  BENCH_TEST_FAILS=$((BENCH_TEST_FAILS + 1))
  return 1
}

assert_eq() {
  # assert_eq <expected> <actual> <what>
  [ "$1" = "$2" ] || fail "${3:-value}: expected [$1] got [$2]"
}

assert_match() {
  # assert_match <value> <ere> <what>
  printf '%s' "$1" | grep -Eq "$2" || fail "${3:-value}: [$1] does not match /$2/"
}

assert_contains() {
  # assert_contains <haystack-file> <fixed-substring> <what>
  grep -Fq "$2" "$1" || fail "${3:-file} does not contain [$2]"
}

# --- fixtures ---------------------------------------------------------------

# A placeholder identifier for the stubbed `xcrun`. Deliberately NOT shaped like
# a real UDID: the repo hygiene gate rejects any 8-4-4-4-12 hex string in tracked
# files, prose included, and a "harmless" all-zero UDID would trip it.
BENCH_TEST_UDID="simulator-udid-placeholder"

# Build a PATH shim exposing a fake `xcrun` that answers
# `xcrun simctl io <udid> screenshot <path>` without touching a simulator.
make_xcrun_shim() {
  # make_xcrun_shim <dir>
  shim_dir="$1"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/xcrun" <<'STUB'
#!/bin/sh
# Test stub. Supports only: simctl io <udid> screenshot <path>
if [ "$1" = "simctl" ] && [ "$2" = "io" ] && [ "$4" = "screenshot" ]; then
  sleep 0.05
  : > "$5"
  if [ -n "${BENCH_TEST_SHOT_LOG:-}" ]; then
    echo "$5" >> "$BENCH_TEST_SHOT_LOG"
  fi
  exit 0
fi
echo "xcrun stub: unexpected args: $*" >&2
exit 64
STUB
  chmod +x "$shim_dir/xcrun"
}

# Run one measured step into a fresh CSV and echo the CSV path.
# usage: run_one_step_csv <workdir> <tag> <cmd...>
run_one_step_csv() {
  work="$1"; shift
  tag="$1"; shift
  make_xcrun_shim "$work/shim"
  PATH="$work/shim:$PATH"
  export PATH
  BENCH_OUT_DIR="$work/out"
  BENCH_CSV="$BENCH_OUT_DIR/results.csv"
  BENCH_FLOW="unit"
  BENCH_UDID="$BENCH_TEST_UDID"
  export BENCH_OUT_DIR BENCH_CSV BENCH_FLOW BENCH_UDID
  bench_csv_init "$BENCH_CSV"
  bench_run_step "$tag" "$@"
  echo "$BENCH_CSV"
}

# Field <n> of the single data row. Test commands avoid commas so plain cut works.
row_field() {
  # row_field <csv> <n>
  LC_ALL=C sed -n '2p' "$1" | cut -d, -f"$2"
}

# --- tests ------------------------------------------------------------------

test_csv_header_matches_documented_columns() {
  header=$(bench_csv_header)
  assert_eq \
    "flow,step,cmd,wall_ms,stdout_bytes,est_tokens,loadavg_1m,control_probe_ms,exit_code" \
    "$header" "csv header"

  # And it must still match what docs/plans/02-architecture.md documents.
  [ -f "$BENCH_ARCH_DOC" ] || fail "architecture doc not found at $BENCH_ARCH_DOC"
  documented=$(LC_ALL=C grep -F 'flow, step, cmd, wall_ms' "$BENCH_ARCH_DOC" \
    | head -1 | tr -d '`' | tr -d ' ' | tr -d '\n')
  [ -n "$documented" ] || fail "no documented column list found in $BENCH_ARCH_DOC"
  assert_eq "$documented" "$header" "documented columns"
}

test_est_tokens_is_bytes_over_four() {
  work=$(mktemp -d "$BENCH_TEST_TMP/est.XXXXXX")
  # 13 bytes: distinguishes /4 from /3 and /5, and exercises truncation (3.25 -> 3).
  csv=$(run_one_step_csv "$work" "1-emit" /bin/sh -c 'printf "%s" 0123456789abc')
  bytes=$(row_field "$csv" 5)
  tokens=$(row_field "$csv" 6)
  assert_eq "13" "$bytes" "stdout_bytes"
  assert_eq "3" "$tokens" "est_tokens (13/4 truncated)"
  assert_eq "0" "$(row_field "$csv" 9)" "exit_code"
}

test_loadavg_column_is_numeric() {
  work=$(mktemp -d "$BENCH_TEST_TMP/load.XXXXXX")
  csv=$(run_one_step_csv "$work" "1-noop" /bin/sh -c 'exit 0')
  loadavg=$(row_field "$csv" 7)
  # Must be a dot-decimal number even under a comma-decimal locale (fr_FR et al).
  assert_match "$loadavg" '^[0-9]+\.[0-9]+$' "loadavg_1m"
  # Same guarantee when the helper is called directly under such a locale.
  direct=$(LANG=fr_FR.UTF-8 bench_loadavg_1m)
  assert_match "$direct" '^[0-9]+\.[0-9]+$' "loadavg_1m under comma-decimal locale"
}

test_control_probe_records_milliseconds() {
  work=$(mktemp -d "$BENCH_TEST_TMP/probe.XXXXXX")
  make_xcrun_shim "$work/shim"
  PATH="$work/shim:$PATH"
  export PATH
  BENCH_TEST_SHOT_LOG="$work/shots.txt"
  export BENCH_TEST_SHOT_LOG

  ms=$(bench_control_probe "$BENCH_TEST_UDID")
  assert_match "$ms" '^[0-9]+$' "control_probe_ms"
  # The stub sleeps 50 ms; allow slack but reject a stuck-at-zero timer.
  [ "$ms" -ge 10 ] || fail "control_probe_ms [$ms] is implausibly small"
  [ "$ms" -lt 60000 ] || fail "control_probe_ms [$ms] is implausibly large"

  shot=$(head -1 "$work/shots.txt")
  [ -n "$shot" ] || fail "stub xcrun was never invoked"
  [ ! -e "$shot" ] || fail "probe screenshot [$shot] was not deleted"

  # The measured step records the same probe in its own column.
  csv=$(run_one_step_csv "$work" "1-noop" /bin/sh -c 'exit 0')
  assert_match "$(row_field "$csv" 8)" '^[0-9]+$' "control_probe_ms column"
}

test_markdown_table_has_caveat_header() {
  work=$(mktemp -d "$BENCH_TEST_TMP/md.XXXXXX")
  csv="$work/results.csv"
  bench_csv_init "$csv"
  bench_csv_append_row "$csv" unit 1-noop "sh -c 'true'" 12 40 10 1.25 33 0
  out="$work/table.md"
  bench_render_markdown "$csv" > "$out"

  assert_contains "$out" "wall_ms inflates" "markdown caveat"
  assert_contains "$out" "compare control_probe_ms across rows" "markdown caveat"
  assert_contains "$out" "| flow | step | cmd |" "markdown header row"
  assert_contains "$out" "| --- |" "markdown separator row"
  assert_contains "$out" "| 1-noop |" "markdown data row"
}

test_csv_escapes_commas_and_quotes() {
  assert_eq 'plain' "$(bench_csv_escape 'plain')" "plain field"
  assert_eq '"a,b"' "$(bench_csv_escape 'a,b')" "comma field"
  assert_eq '"say ""hi"""' "$(bench_csv_escape 'say "hi"')" "quoted field"
}

test_teardown_uses_sanctioned_reclaim_and_forbids_pkill() {
  [ -f "$BENCH_COMMON" ] || fail "common.sh missing"
  body=$(LC_ALL=C sed -n '/^bench_teardown_agent_device()/,/^}/p' "$BENCH_COMMON")
  [ -n "$body" ] || fail "bench_teardown_agent_device not defined in common.sh"
  printf '%s' "$body" | grep -Fq -- 'close --session' \
    || fail "teardown does not run 'agent-device close --session'"
  printf '%s' "$body" | grep -Fq -- 'daemon stop --clean' \
    || fail "teardown does not run 'agent-device daemon stop --clean'"
  # pkill may appear only inside a comment forbidding it, never as a command.
  offenders=$(LC_ALL=C grep -n 'pkill' "$BENCH_COMMON" | grep -v '^[0-9]*:[[:space:]]*#' || true)
  [ -z "$offenders" ] || fail "pkill used outside a comment: $offenders"
}

# --- runner -----------------------------------------------------------------

TESTS="
test_csv_header_matches_documented_columns
test_est_tokens_is_bytes_over_four
test_loadavg_column_is_numeric
test_control_probe_records_milliseconds
test_markdown_table_has_caveat_header
test_csv_escapes_commas_and_quotes
test_teardown_uses_sanctioned_reclaim_and_forbids_pkill
"

BENCH_TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/bench-lib-test.XXXXXX")
trap 'rm -rf "$BENCH_TEST_TMP"' EXIT

# Each test runs in its own subshell: one blown-up test cannot abort the runner,
# and its failure counter cannot leak into the next test.
run_test() {
  (
    BENCH_TEST_FAILS=0
    if "$1"; then rc=0; else rc=$?; fi
    if [ "$BENCH_TEST_FAILS" -gt 0 ]; then rc=1; fi
    exit "$rc"
  )
}

passed=0
failed=0
for t in $TESTS; do
  if run_test "$t"; then
    echo "ok     - $t"
    passed=$((passed + 1))
  else
    echo "not ok - $t"
    failed=$((failed + 1))
  fi
done

echo "----"
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
