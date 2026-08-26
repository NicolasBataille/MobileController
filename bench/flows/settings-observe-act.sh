#!/bin/bash
# bench/flows/settings-observe-act.sh - the observation ladder against Settings.
#
# Apple Settings is the zero-setup bench target: every simulator already has it,
# so this flow runs on a stock machine with nothing built but simprobe. It walks
# one observe -> act -> verify cycle at each rung of the ladder, so the CSV shows
# what each way of looking at the same screen costs in bytes and in wall clock.
#
# Driven by bench/run.sh, which supplies BENCH_UDID / BENCH_SESSION / BENCH_CSV /
# BENCH_OUT_DIR / BENCH_REPEAT. Runnable directly with those set.

set -euo pipefail

BENCH_FLOW_DIR=$(cd "$(dirname "$0")" && pwd)
BENCH_REPO_ROOT=$(cd "$BENCH_FLOW_DIR/../.." && pwd)
cd "$BENCH_REPO_ROOT"
# shellcheck source=/dev/null
. "$BENCH_REPO_ROOT/bench/lib/flow.sh"

BENCH_FLOW=settings-observe-act
BENCH_REPEAT="${BENCH_REPEAT:-3}"
BENCH_SESSION="${BENCH_SESSION:-bench}"
export BENCH_FLOW BENCH_SESSION

# The step tags this flow emits, declared once. bench/flows/test.sh reads these
# two lines out of this file and asserts the dry run produced exactly them, so
# a step added here without a test update is caught rather than silently landed.
# shellcheck disable=SC2034  # read out of this file by bench/flows/test.sh
BENCH_SETTINGS_ONESHOT_STEPS="open_cold close_cold"
# shellcheck disable=SC2034  # read out of this file by bench/flows/test.sh
BENCH_SETTINGS_REPEAT_STEPS="open_warm digest_snapshot interactive_snapshot full_snapshot press_row wait_stable press_row_settle simprobe_shot agent_screenshot close"

SETTINGS_BUNDLE_ID="${BENCH_APP_BUNDLE_ID:-com.apple.Preferences}"

# The row to press. Settings is localised, so a selector that matches a row by
# its label only matches on a device in the language that label is written in.
# The default targets an English simulator; on any other language set
# BENCH_SETTINGS_ROW in bench/local.env to that device's spelling of the row
# (read it out of `agent-device snapshot -i`). This is the one part of the flow
# that is not device-independent, which is why it is a variable and not a
# literal buried in the press below.
SETTINGS_ROW="${BENCH_SETTINGS_ROW:-text=General}"

# --- helpers ----------------------------------------------------------------

# settings_back - return to the Settings root. Deliberately unmeasured: it is a
# state reset between two measured presses of the same row, not an observation.
settings_back() {
  if bench_is_dry_run; then
    return 0
  fi
  ad back > /dev/null 2>&1 || echo "bench: 'back' failed (continuing)" >&2
  return 0
}

# settings_teardown - the sanctioned reclaim, on every exit path.
#
# REAPER GUARD: close + `daemon stop --clean`, never pkill. Reaping the
# in-simulator XCUITest runner poisons accessibility device-wide until the
# simulator is rebooted - see bench/lib/common.sh and skill/references/pitfalls.md.
settings_teardown() {
  if bench_is_dry_run; then
    return 0
  fi
  bench_teardown_agent_device "$BENCH_SESSION"
}
trap settings_teardown EXIT

# --- flow -------------------------------------------------------------------

bench_flow_require_tools

if [ -z "${BENCH_CSV:-}" ]; then
  echo "bench: BENCH_CSV is not set - run this flow through bench/run.sh" >&2
  exit 2
fi

# The first `open` on a device builds and installs the XCUITest runner, which
# takes tens of seconds. That is a real cost a user pays once per device, so it
# is a measured row of its own rather than an untimed warm-up.
bench_flow_wake_device
bench_run_step "0-open_cold" ad open "$SETTINGS_BUNDLE_ID"
bench_run_step "0-close_cold" ad close

r=1
while [ "$r" -le "$BENCH_REPEAT" ]; do
  shot="$BENCH_OUT_DIR/settings-shot-r$r.jpg"
  png="$BENCH_OUT_DIR/settings-screenshot-r$r.png"

  # Wake before the open, never mid-flow: HOME backgrounds the foreground app.
  bench_flow_wake_device

  bench_run_step "r$r-open_warm" ad open "$SETTINGS_BUNDLE_ID"

  # The observation ladder, cheapest rung first, all against the same screen.
  bench_run_step "r$r-digest_snapshot" ad --level digest --json snapshot -i
  bench_run_step "r$r-interactive_snapshot" ad snapshot -i
  bench_run_step "r$r-full_snapshot" ad snapshot

  # Act, then verify with pixels rather than with the tree.
  bench_run_step "r$r-press_row" ad press "$SETTINGS_ROW"
  bench_run_step "r$r-wait_stable" sp wait-stable --timeout 6s
  settings_back

  # The same tap with --settle, for the side-by-side comparison: same action,
  # ~50x the stdout bytes, because the settled diff comes back with it.
  bench_run_step "r$r-press_row_settle" ad press "$SETTINGS_ROW" --settle
  settings_back

  # Two ways to take the same picture. simprobe emits 1x logical points; the
  # bytes that matter are the file's, not the one-line path on stdout.
  bench_run_step "r$r-simprobe_shot" sp shot --out "$shot"
  bench_flow_guard_frame "$shot"
  bench_run_step "r$r-agent_screenshot" ad screenshot --out "$png"
  bench_flow_guard_frame "$png"

  bench_run_step "r$r-close" ad close
  r=$((r + 1))
done

echo "bench: $BENCH_FLOW finished ($BENCH_REPEAT repeat(s))" >&2
