#!/bin/bash
# bench/lib/flow.sh - helpers shared by every bench/flows/*.sh.
#
# Sources common.sh, then adds the three things a flow needs on top of the
# measurement primitives: tool wrappers that keep machine-specific values out of
# the CSV, a device wake, and a blank-frame guard.
#
# Portability: macOS system /bin/bash 3.2, same as common.sh.

if [ -n "${BENCH_FLOW_LIB_SOURCED:-}" ]; then
  return 0
fi
BENCH_FLOW_LIB_SOURCED=1

BENCH_FLOW_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$BENCH_FLOW_LIB_DIR/common.sh"

# Path to the simprobe binary, relative to the repo root so that neither the
# cmd column nor the published markdown carries an absolute home path.
BENCH_SIMPROBE="${BENCH_SIMPROBE:-.build/release/simprobe}"

# A capture smaller than this is treated as a blank frame rather than a settled
# screen: a slept simulator screenshots as solid black, which every pixel
# measurement then reports as perfectly stable (skill/references/pitfalls.md #12).
BENCH_MIN_SHOT_BYTES="${BENCH_MIN_SHOT_BYTES:-15360}"

# --- tool wrappers ----------------------------------------------------------
#
# These are functions, not variables, for a reason: bench_run_step records the
# joined command line into the cmd column, and that column ends up in the CSV,
# in the rendered markdown and finally in the tracked README. Expanding
# "$BENCH_UDID" at the call site would publish the maintainer's simulator UDID.
# Called as `bench_run_step open ad open com.apple.Preferences`, the column
# reads `ad open com.apple.Preferences` and the UDID stays in bench/local.env.

# ad <args>... - agent-device, always pinned to the device and the session.
ad() {
  agent-device --udid "$BENCH_UDID" --session "$BENCH_SESSION" "$@"
}

# sp <verb> <args>... - simprobe, always pinned to the device.
#
# --udid is a per-subcommand option, not a global one, so it goes after the verb:
# `simprobe --udid <u> shot` is rejected with "Unknown option '--udid'".
sp() {
  local verb="$1"
  shift
  "$BENCH_SIMPROBE" "$verb" --udid "$BENCH_UDID" "$@"
}

# --- device state -----------------------------------------------------------

# bench_flow_wake_device - deliver a HOME button event so the display is awake.
#
# The simulator auto-locks after a few minutes and its framebuffer goes dark
# while the accessibility tree stays correct, so an AX-only tool cannot see the
# difference. simctl launch and openurl do not wake it; a HID event does. Call
# this before an `open`, never mid-flow: HOME backgrounds the foreground app.
bench_flow_wake_device() {
  if bench_is_dry_run; then
    return 0
  fi
  if ! command -v idb > /dev/null 2>&1; then
    echo "bench: idb not on PATH - cannot wake the display before pixel steps" >&2
    return 0
  fi
  idb ui button HOME --udid "$BENCH_UDID" > /dev/null 2>&1 \
    || echo "bench: 'idb ui button HOME' failed (continuing)" >&2
  return 0
}

# bench_flow_guard_frame <image> - warn when a capture looks like a blank frame.
#
# Always returns 0: a suspicious frame is reported, and the run continues so the
# CSV still shows what happened. Never silently accepts the frame as settled.
bench_flow_guard_frame() {
  local image="$1"
  local bytes

  if bench_is_dry_run; then
    return 0
  fi
  if [ ! -f "$image" ]; then
    echo "bench: expected capture [$image] was never written" >&2
    return 0
  fi

  bytes=$(bench_byte_count "$image")
  if [ "$bytes" -lt "$BENCH_MIN_SHOT_BYTES" ]; then
    echo "bench: capture [$image] is $bytes B (< $BENCH_MIN_SHOT_BYTES) - almost" \
      "certainly a blank frame from a slept display, not a settled screen." >&2
    echo "bench: waking the device; treat this repeat's pixel rows as suspect." >&2
    bench_flow_wake_device
  fi
  return 0
}

# --- preconditions ----------------------------------------------------------

# bench_flow_require_tools - fail early, with a fix, when a flow cannot run.
# A dry run needs none of them: it records commands without executing any.
bench_flow_require_tools() {
  local missing=0

  if bench_is_dry_run; then
    return 0
  fi

  if [ -z "${BENCH_UDID:-}" ]; then
    echo "bench: BENCH_UDID is empty. Set it in bench/local.env." >&2
    missing=1
  fi
  if ! command -v agent-device > /dev/null 2>&1; then
    echo "bench: agent-device is not on PATH. Install it with:" >&2
    echo "         npm i -g agent-device@0.20.10" >&2
    missing=1
  fi
  if [ ! -x "$BENCH_SIMPROBE" ]; then
    echo "bench: no simprobe binary at [$BENCH_SIMPROBE]. Build it with:" >&2
    echo "         swift build -c release" >&2
    missing=1
  fi

  [ "$missing" -eq 0 ] || return 1
  return 0
}

# bench_flow_press_then_motion <selector> <window_ms> - tap, then time the pixels.
#
# The tap runs in the background on purpose. A foreground `press` returns only
# once the in-simulator runner has acknowledged it - one to one and a half
# seconds - by which point a 300 ms transition is long over, so measuring the
# two in series reports a flat timeline for an animation that really happened.
# Backgrounding the tap puts it inside the capture window instead, which is
# what makes the timeline a measurement rather than an artefact of call order.
bench_flow_press_then_motion() {
  local selector="$1"
  local window="$2"
  local rc=0
  local log="${BENCH_OUT_DIR:-.}/press-async.log"
  local pid

  ad press "$selector" > "$log" 2>&1 &
  pid=$!
  sp motion "$window" || rc=$?
  wait "$pid" || rc=$?
  return "$rc"
}
