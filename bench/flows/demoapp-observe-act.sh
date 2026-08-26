#!/bin/bash
# bench/flows/demoapp-observe-act.sh - the same ladder against a known app.
#
# Settings measures what an agent pays on an app nobody controls. DemoApp
# measures what it pays where the ground truth is known: every element has a
# stable accessibility identifier, and `home.animateButton` drives exactly one
# 300 ms easeInOut transition per tap. That number is what makes the `motion`
# row a check rather than a reading - a timeline with a couple of non-zero
# samples and then quiet is the transition; a flat timeline is a broken
# measurement, and this flow is the thing that can tell them apart.
#
# Driven by bench/run.sh, which builds and installs the app first and supplies
# BENCH_UDID / BENCH_SESSION / BENCH_CSV / BENCH_OUT_DIR / BENCH_REPEAT.

set -euo pipefail

BENCH_FLOW_DIR=$(cd "$(dirname "$0")" && pwd)
BENCH_REPO_ROOT=$(cd "$BENCH_FLOW_DIR/../.." && pwd)
cd "$BENCH_REPO_ROOT"
# shellcheck source=/dev/null
. "$BENCH_REPO_ROOT/bench/lib/flow.sh"

BENCH_FLOW=demoapp-observe-act
BENCH_REPEAT="${BENCH_REPEAT:-3}"
BENCH_SESSION="${BENCH_SESSION:-bench}"
export BENCH_FLOW BENCH_SESSION

# Declared once; bench/flows/test.sh reads these two lines and asserts the dry
# run emitted exactly them.
# shellcheck disable=SC2034  # read out of this file by bench/flows/test.sh
BENCH_DEMOAPP_ONESHOT_STEPS="open"
# shellcheck disable=SC2034  # read out of this file by bench/flows/test.sh
BENCH_DEMOAPP_REPEAT_STEPS="tab_list wait_stable_list interactive_snapshot tab_form wait_stable_form fill_textfield get_echo is_echo_text press_clear wait_stable_clear get_echo_cleared dismiss_keyboard tab_home wait_stable_home press_animate_motion"

# The identifiers are DemoApp's public contract (DemoApp/README.md).
DEMOAPP_BUNDLE_ID="dev.mobilecontroller.demoapp"
DEMOAPP_FILL_TEXT="example.com"
DEMOAPP_EMPTY_ECHO="(empty)"
# The transition is 300 ms. 1500 ms of capture at the ~3 fps a simctl screenshot
# allows is four to seven samples: enough to show the motion and the quiet after.
DEMOAPP_MOTION_MS=1500

# --- helpers ----------------------------------------------------------------

# demoapp_expect <needle> <what> - assert the last step's stdout contains needle.
#
# A failed expectation is reported and the run continues: the CSV row for the
# step is the evidence, and aborting here would throw away the rows that explain
# why. The exit status is accumulated so the flow still fails overall.
DEMOAPP_EXPECT_FAILURES=0

demoapp_expect() {
  local needle="$1"
  local what="$2"

  if bench_is_dry_run; then
    return 0
  fi
  if [ ! -f "${BENCH_LAST_STDOUT_FILE:-}" ]; then
    echo "bench: $what - no stdout captured for the previous step" >&2
    DEMOAPP_EXPECT_FAILURES=$((DEMOAPP_EXPECT_FAILURES + 1))
    return 0
  fi
  if ! LC_ALL=C grep -Fq -- "$needle" "$BENCH_LAST_STDOUT_FILE"; then
    echo "bench: $what - expected [$needle] in $BENCH_LAST_STDOUT_FILE, got:" >&2
    LC_ALL=C head -c 400 "$BENCH_LAST_STDOUT_FILE" >&2
    echo >&2
    DEMOAPP_EXPECT_FAILURES=$((DEMOAPP_EXPECT_FAILURES + 1))
  fi
  return 0
}

# demoapp_teardown - REAPER GUARD: close + `daemon stop --clean`, never pkill.
demoapp_teardown() {
  if bench_is_dry_run; then
    return 0
  fi
  bench_teardown_agent_device "$BENCH_SESSION"
}
trap demoapp_teardown EXIT

# --- flow -------------------------------------------------------------------

bench_flow_require_tools

if [ -z "${BENCH_CSV:-}" ]; then
  echo "bench: BENCH_CSV is not set - run this flow through bench/run.sh" >&2
  exit 2
fi

bench_flow_wake_device
bench_run_step "0-open" ad open "$DEMOAPP_BUNDLE_ID"

# Unmeasured warm-up. The first accessibility query after an `open` pays for the
# in-simulator runner attaching to a freshly launched app and can time out
# outright; charging that one-off to the first press of the first repeat would
# put a spurious failure in the published table.
if ! bench_is_dry_run; then
  ad snapshot -i > /dev/null 2>&1 || echo "bench: warm-up snapshot failed (continuing)" >&2
fi

r=1
while [ "$r" -le "$BENCH_REPEAT" ]; do
  # List tab: 40 rows, the dense-tree case.
  bench_run_step "r$r-tab_list" ad press "id=tabBar.list"
  bench_run_step "r$r-wait_stable_list" sp wait-stable --timeout 6s
  bench_run_step "r$r-interactive_snapshot" ad snapshot -i

  # Form tab: fill, read back, clear, read back. No OCR anywhere - the echo
  # label mirrors the field, so what was actually typed is a tree read.
  bench_run_step "r$r-tab_form" ad press "id=tabBar.form"
  bench_run_step "r$r-wait_stable_form" sp wait-stable --timeout 6s

  bench_run_step "r$r-fill_textfield" ad fill "id=form.textField" "$DEMOAPP_FILL_TEXT"
  # `get attrs`, not `get text`: on a label carrying both, `get text` returns the
  # accessibility *label* ("Echo") and the text the app is echoing lives in
  # `value`. Reading the wrong one passes silently on an empty field.
  bench_run_step "r$r-get_echo" ad get attrs "id=form.echoLabel"
  demoapp_expect "$DEMOAPP_FILL_TEXT" "echo label after fill"
  bench_run_step "r$r-is_echo_text" ad is text "id=form.echoLabel" "$DEMOAPP_FILL_TEXT"

  # agent-device has no clear-field primitive (`fill ""` is rejected), so the
  # sanctioned path is the app's own clear button.
  bench_run_step "r$r-press_clear" ad press "id=form.clearButton"
  bench_run_step "r$r-wait_stable_clear" sp wait-stable --timeout 6s
  bench_run_step "r$r-get_echo_cleared" ad get attrs "id=form.echoLabel"
  demoapp_expect "$DEMOAPP_EMPTY_ECHO" "echo label after clear"

  # The keyboard is still up, and on this geometry it covers the tab bar: a
  # press on a tab then reports `Tapped id=tabBar.home` and changes nothing,
  # because the tap landed on the keyboard's accessory row. agent-device has no
  # working `keyboard dismiss` on iOS (UNSUPPORTED_OPERATION - it refuses to tap
  # outside the keyboard), so the return key is the way out.
  bench_run_step "r$r-dismiss_keyboard" ad keyboard return

  # Home tab, then the ground truth: one 300 ms transition, timed in pixels.
  bench_run_step "r$r-tab_home" ad press "id=tabBar.home"
  bench_run_step "r$r-wait_stable_home" sp wait-stable --timeout 6s
  bench_run_step "r$r-press_animate_motion" \
    bench_flow_press_then_motion "id=home.animateButton" "$DEMOAPP_MOTION_MS"

  r=$((r + 1))
done

echo "bench: $BENCH_FLOW finished ($BENCH_REPEAT repeat(s))" >&2
if [ "$DEMOAPP_EXPECT_FAILURES" -ne 0 ]; then
  echo "bench: $DEMOAPP_EXPECT_FAILURES expectation(s) failed - see above" >&2
  exit 1
fi
