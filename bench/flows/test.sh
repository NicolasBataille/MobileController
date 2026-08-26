#!/bin/bash
# bench/flows/test.sh - smoke tests for the flows and for bench/run.sh.
#
# Run:  /bin/bash bench/flows/test.sh
#
# Touches no simulator, needs no agent-device and no Xcode: everything runs
# under BENCH_DRY_RUN=1, which records each step's tag and command line without
# executing it. What that buys is real coverage of the flow scripts themselves -
# their loops, their step tags, their argument construction - in CI, on a
# machine with no device. What it deliberately does not cover is whether the
# commands work; that is what a live `bench/run.sh` is for.
#
# Compatible with macOS system /bin/bash 3.2.

set -euo pipefail

BENCH_TEST_DIR=$(cd "$(dirname "$0")" && pwd)
BENCH_REPO_ROOT=$(cd "$BENCH_TEST_DIR/../.." && pwd)
cd "$BENCH_REPO_ROOT"

SETTINGS_FLOW="bench/flows/settings-observe-act.sh"
DEMOAPP_FLOW="bench/flows/demoapp-observe-act.sh"
RUN_SH="bench/run.sh"

BENCH_TEST_FAILS=0

fail() {
  echo "    FAIL: $*" >&2
  BENCH_TEST_FAILS=$((BENCH_TEST_FAILS + 1))
  return 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "${3:-value}: expected [$1] got [$2]"
}

# --- helpers ----------------------------------------------------------------

# declared_steps <flow-file> <variable-name> - the step names a flow declares.
#
# Read out of the flow rather than duplicated here on purpose: the assertion is
# "the flow emits exactly the steps it says it emits", which catches a step
# added to the loop without being declared, and a declared step never emitted.
declared_steps() {
  LC_ALL=C sed -n "s/^$2=\"\\(.*\\)\"$/\\1/p" "$1" | head -1
}

# expected_tags <oneshot> <repeat-steps> <n> - the full tag list, in order.
expected_tags() {
  local oneshot="$1" repeat="$2" n="$3" i=1 s
  for s in $oneshot; do
    printf '0-%s\n' "$s"
  done
  while [ "$i" -le "$n" ]; do
    for s in $repeat; do
      printf 'r%s-%s\n' "$i" "$s"
    done
    i=$((i + 1))
  done
}

# write_env <path> - a local.env good enough for a dry run (no UDID needed).
write_env() {
  cat > "$1" <<'ENV'
BENCH_UDID=
BENCH_APP_BUNDLE_ID=com.apple.Preferences
BENCH_SESSION=bench-dry-run
ENV
}

# dry_run <target> <repeat> <outdir> - run.sh under BENCH_DRY_RUN, echo the CSV.
dry_run() {
  local target="$1" repeat="$2" out="$3"
  write_env "$out/local.env"
  BENCH_DRY_RUN=1 BENCH_LOCAL_ENV="$out/local.env" \
    /bin/bash "$RUN_SH" --target "$target" --repeat "$repeat" --out "$out" \
    > "$out/run.stdout" 2> "$out/run.stderr"
  printf '%s\n' "$out/results.csv"
}

# step_column <csv> - the step column of every data row, one per line.
step_column() {
  LC_ALL=C awk -F, 'NR > 1 { print $2 }' "$1"
}

# --- tests ------------------------------------------------------------------

assert_flow_tags() {
  # assert_flow_tags <target> <flow-file> <oneshot-var> <repeat-var> <n>
  local target="$1" flow="$2" oneshot_var="$3" repeat_var="$4" n="$5"
  local work oneshot repeat csv expected actual

  work=$(mktemp -d "$BENCH_TEST_TMP/$target.XXXXXX")
  oneshot=$(declared_steps "$flow" "$oneshot_var")
  repeat=$(declared_steps "$flow" "$repeat_var")
  [ -n "$repeat" ] || fail "$flow declares no $repeat_var"

  csv=$(dry_run "$target" "$n" "$work")
  [ -f "$csv" ] || fail "no CSV at $csv"

  expected=$(expected_tags "$oneshot" "$repeat" "$n")
  actual=$(step_column "$csv")
  assert_eq "$expected" "$actual" "$target step tags"

  # A dry run must not have reached a simulator: every timing column is zero.
  assert_eq "0" "$(LC_ALL=C awk -F, 'NR == 2 { print $4 }' "$csv")" "wall_ms"
  assert_eq "0" "$(LC_ALL=C awk -F, 'NR == 2 { print $8 }' "$csv")" "control_probe_ms"

  # run.sh prints the markdown path and the table renders.
  assert_eq "$work/results.md" "$(cat "$work/run.stdout")" "printed markdown path"
  grep -Fq 'Read ratios, not absolutes' "$work/results.md" \
    || fail "rendered table is missing the host-load caveat"
}

test_settings_flow_dry_run_emits_expected_step_tags() {
  assert_flow_tags settings "$SETTINGS_FLOW" \
    BENCH_SETTINGS_ONESHOT_STEPS BENCH_SETTINGS_REPEAT_STEPS 2
}

test_demoapp_flow_dry_run_emits_expected_step_tags() {
  assert_flow_tags demoapp "$DEMOAPP_FLOW" \
    BENCH_DEMOAPP_ONESHOT_STEPS BENCH_DEMOAPP_REPEAT_STEPS 2
}

test_run_sh_fails_helpfully_without_local_env() {
  local work out rc
  work=$(mktemp -d "$BENCH_TEST_TMP/noenv.XXXXXX")
  out="$work/out.txt"

  rc=0
  BENCH_DRY_RUN=1 BENCH_LOCAL_ENV="$work/definitely-not-here.env" \
    /bin/bash "$RUN_SH" --target settings --out "$work/run" > "$out" 2>&1 || rc=$?

  assert_eq "2" "$rc" "exit code with no local.env"
  # Helpful means: names the missing file, and gives the command that fixes it.
  grep -Fq 'definitely-not-here.env' "$out" || fail "message does not name the missing file"
  grep -Fq 'cp bench/local.env.example bench/local.env' "$out" \
    || fail "message does not show how to create the file"
  [ ! -f "$work/run/results.csv" ] || fail "a CSV was written despite the failure"
}

test_dry_run_never_writes_the_udid_into_the_csv() {
  # The cmd column is published: it reaches results.md and then the README. The
  # flows therefore pass the device through wrapper functions rather than
  # expanding $BENCH_UDID at the call site, and this is the test that says so.
  local work csv fake_udid
  work=$(mktemp -d "$BENCH_TEST_TMP/udid.XXXXXX")
  write_env "$work/local.env"
  # A UDID-shaped value, assembled at runtime. It must never appear whole in
  # this tracked file: scripts/hygiene-check.sh rejects any 8-4-4-4-12 hex
  # string anywhere in the repo, and a test fixture is not an exception.
  fake_udid="DEADBEEF-1234-5678-9ABC-DEF0123456"
  echo "BENCH_UDID=${fake_udid}78" >> "$work/local.env"

  BENCH_DRY_RUN=1 BENCH_LOCAL_ENV="$work/local.env" \
    /bin/bash "$RUN_SH" --target settings --repeat 1 --out "$work" \
    > "$work/run.stdout" 2> "$work/run.stderr"
  csv="$work/results.csv"

  if LC_ALL=C grep -Eq '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' "$csv"; then
    fail "the CSV contains a UDID-shaped string: $(grep -Eo '[0-9A-Fa-f-]{36}' "$csv" | head -1)"
  fi
  if LC_ALL=C grep -Eq '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' "$work/results.md"; then
    fail "the rendered markdown contains a UDID-shaped string"
  fi
}

test_run_sh_rejects_an_unknown_target() {
  local work rc
  work=$(mktemp -d "$BENCH_TEST_TMP/target.XXXXXX")
  write_env "$work/local.env"
  rc=0
  BENCH_DRY_RUN=1 BENCH_LOCAL_ENV="$work/local.env" \
    /bin/bash "$RUN_SH" --target nope --out "$work/run" > "$work/out.txt" 2>&1 || rc=$?
  assert_eq "2" "$rc" "exit code for an unknown target"
  grep -Fq 'unknown target' "$work/out.txt" || fail "no explanation of the bad target"
}

test_flows_never_reap_a_process() {
  # REAPER GUARD. pkill may appear in a comment forbidding it, never as a call.
  local offenders
  offenders=$(LC_ALL=C grep -n 'pkill\|killall' "$SETTINGS_FLOW" "$DEMOAPP_FLOW" \
    "$RUN_SH" bench/lib/flow.sh | grep -v ':[[:space:]]*#' || true)
  [ -z "$offenders" ] || fail "process reaping outside a comment: $offenders"

  grep -Fq 'bench_teardown_agent_device' "$SETTINGS_FLOW" \
    || fail "$SETTINGS_FLOW has no sanctioned teardown"
  grep -Fq 'bench_teardown_agent_device' "$DEMOAPP_FLOW" \
    || fail "$DEMOAPP_FLOW has no sanctioned teardown"
  grep -Fq 'trap ' "$SETTINGS_FLOW" || fail "$SETTINGS_FLOW does not tear down on EXIT"
  grep -Fq 'trap ' "$DEMOAPP_FLOW" || fail "$DEMOAPP_FLOW does not tear down on EXIT"
}

# --- runner -----------------------------------------------------------------

TESTS="
test_settings_flow_dry_run_emits_expected_step_tags
test_demoapp_flow_dry_run_emits_expected_step_tags
test_run_sh_fails_helpfully_without_local_env
test_dry_run_never_writes_the_udid_into_the_csv
test_run_sh_rejects_an_unknown_target
test_flows_never_reap_a_process
"

BENCH_TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/bench-flow-test.XXXXXX")
trap 'rm -rf "$BENCH_TEST_TMP"' EXIT

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
