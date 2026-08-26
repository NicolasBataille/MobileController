#!/bin/bash
# bench/lib/common.sh - measurement primitives for the MobileController bench.
#
# Source it, then drive it:
#
#   . bench/lib/common.sh
#   BENCH_FLOW=settings-observe-act
#   BENCH_OUT_DIR=bench/out/$(date +%Y%m%dT%H%M%S)
#   BENCH_CSV="$BENCH_OUT_DIR/results.csv"
#   BENCH_UDID="$BENCH_UDID"        # from bench/local.env, never committed
#   bench_csv_init "$BENCH_CSV"
#   bench_run_step 1-open agent-device open --session "$BENCH_SESSION" ...
#   bench_render_markdown "$BENCH_CSV" > "$BENCH_OUT_DIR/results.md"
#   bench_teardown_agent_device "$BENCH_SESSION"
#
# Portability: macOS system /bin/bash 3.2. No associative arrays, no mapfile,
# no `date +%s%N` (BSD date has no %N - timing goes through perl's Time::HiRes).
# Every numeric read is forced through LC_ALL=C: under a comma-decimal locale
# (fr_FR, de_DE, ...) `sysctl -n vm.loadavg` prints "{ 49,59 ... }", which would
# both break arithmetic and inject a stray separator into the CSV.

if [ -n "${BENCH_COMMON_SOURCED:-}" ]; then
  return 0
fi
BENCH_COMMON_SOURCED=1

set -euo pipefail

# The documented column list (docs/plans/02-architecture.md, "Bench design").
# Changing it is a documentation change first: test_csv_header_matches_documented_columns
# re-reads the doc and fails if the two drift apart.
BENCH_CSV_COLUMNS="flow,step,cmd,wall_ms,stdout_bytes,est_tokens,loadavg_1m,control_probe_ms,exit_code"

BENCH_NL='
'

# --- timing -----------------------------------------------------------------

# bench_now_ms - wall clock in integer milliseconds.
bench_now_ms() {
  perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000' 2>/dev/null || {
    echo "bench: perl with Time::HiRes is required for millisecond timing" >&2
    return 1
  }
}

# --- host load --------------------------------------------------------------

# bench_loadavg_1m - 1-minute load average, always dot-decimal.
bench_loadavg_1m() {
  LC_ALL=C sysctl -n vm.loadavg 2>/dev/null \
    | LC_ALL=C awk '{ v = $2; gsub(/,/, ".", v); printf "%.2f\n", v + 0 }' \
    || printf '0.00\n'
}

# bench_cpu_count - logical cores, for interpreting loadavg_1m.
bench_cpu_count() {
  LC_ALL=C sysctl -n hw.ncpu 2>/dev/null || printf '1\n'
}

# --- CSV --------------------------------------------------------------------

# bench_csv_header - the fixed header line.
bench_csv_header() {
  printf '%s\n' "$BENCH_CSV_COLUMNS"
}

# bench_csv_escape <field> - RFC4180 escaping: quote-wrap when the field holds a
# comma, a double quote or a newline, doubling any embedded quote.
bench_csv_escape() {
  local field="$1"
  local inner
  case "$field" in
    *[,\"]* | *"$BENCH_NL"*)
      inner=$(printf '%s' "$field" | LC_ALL=C sed 's/"/""/g')
      printf '"%s"' "$inner"
      ;;
    *)
      printf '%s' "$field"
      ;;
  esac
}

# bench_csv_init <csv> - create the parent directory and write the header.
bench_csv_init() {
  local csv="$1"
  mkdir -p "$(dirname "$csv")"
  bench_csv_header > "$csv"
}

# bench_csv_append_row <csv> <field>... - append one escaped row.
bench_csv_append_row() {
  local csv="$1"
  shift
  local line=""
  local sep=""
  local field
  for field in "$@"; do
    line="$line$sep$(bench_csv_escape "$field")"
    sep=","
  done
  printf '%s\n' "$line" >> "$csv"
}

# --- control probe ----------------------------------------------------------

# bench_control_probe <udid> - milliseconds for one `simctl io ... screenshot`.
#
# This is the independent yardstick: simctl talks to the same simulator over a
# path that does not involve agent-device, so a row where wall_ms and
# control_probe_ms rose together is host load, not a regression. Always prints
# an integer and always returns 0, so callers running under `set -e` can do
# `ms=$(bench_control_probe "$udid")` without a guard; failures warn on stderr.
bench_control_probe() {
  local udid="${1:-}"
  local dir shot start end

  if [ -z "$udid" ]; then
    echo "bench: no UDID given, control probe skipped (recorded as 0 ms)" >&2
    printf '0\n'
    return 0
  fi

  dir=$(mktemp -d "${TMPDIR:-/tmp}/bench-probe.XXXXXX")
  shot="$dir/probe.png"
  start=$(bench_now_ms)
  if ! xcrun simctl io "$udid" screenshot "$shot" >/dev/null 2>&1; then
    echo "bench: control probe screenshot failed (is the device booted?)" >&2
  fi
  end=$(bench_now_ms)
  # The probe image is a measurement artefact, never a baseline: delete it.
  rm -rf "$dir"

  printf '%s\n' "$((end - start))"
}

# --- measured step ----------------------------------------------------------

# bench_byte_count <file> - size in bytes (macOS `wc -c` pads its output).
bench_byte_count() {
  LC_ALL=C wc -c < "$1" | LC_ALL=C tr -d ' '
}

# bench_run_step <tag> <cmd>... - run one command, measure it, append one CSV row.
#
# Column mapping: flow = $BENCH_FLOW, step = <tag>, cmd = the joined command line.
# Reads  : BENCH_CSV (required), BENCH_FLOW, BENCH_OUT_DIR, BENCH_UDID.
# Writes : one CSV row; the command's stdout/stderr to $BENCH_OUT_DIR/<flow>-<tag>.{stdout,stderr};
#          BENCH_LAST_STDOUT_FILE / BENCH_LAST_STDERR_FILE / BENCH_LAST_EXIT_CODE.
# Prints nothing on stdout, so flows can capture around it. Returns 0 even when
# the measured command fails - a failed step is data, recorded in exit_code.
bench_run_step() {
  local tag="$1"
  shift

  local csv="${BENCH_CSV:-}"
  if [ -z "$csv" ]; then
    echo "bench_run_step: BENCH_CSV is not set" >&2
    return 2
  fi

  local flow="${BENCH_FLOW:-default}"
  local outdir="${BENCH_OUT_DIR:-$(dirname "$csv")}"
  mkdir -p "$outdir"

  local safe_tag
  safe_tag=$(printf '%s' "$tag" | LC_ALL=C tr -cs 'A-Za-z0-9._-' '-')
  local stdout_file="$outdir/$flow-$safe_tag.stdout"
  local stderr_file="$outdir/$flow-$safe_tag.stderr"
  local cmd_str="$*"

  # Probe immediately before the step so the two share host conditions.
  local probe_ms
  probe_ms=$(bench_control_probe "${BENCH_UDID:-}")

  local start end rc
  start=$(bench_now_ms)
  if "$@" > "$stdout_file" 2> "$stderr_file"; then rc=0; else rc=$?; fi
  end=$(bench_now_ms)

  local bytes est load
  bytes=$(bench_byte_count "$stdout_file")
  # est_tokens is bytes/4, integer-truncated. An estimate of observation cost,
  # not a token count - see the caveat header on the rendered table.
  est=$((bytes / 4))
  load=$(bench_loadavg_1m)

  bench_csv_append_row "$csv" \
    "$flow" "$tag" "$cmd_str" "$((end - start))" "$bytes" "$est" \
    "$load" "$probe_ms" "$rc"

  # Consumed by flow scripts (bench/flows/*.sh), not by this file.
  # shellcheck disable=SC2034
  BENCH_LAST_STDOUT_FILE="$stdout_file"
  # shellcheck disable=SC2034
  BENCH_LAST_STDERR_FILE="$stderr_file"
  # shellcheck disable=SC2034
  BENCH_LAST_EXIT_CODE="$rc"
  return 0
}

# --- rendering --------------------------------------------------------------

# bench_markdown_caveat - the header every rendered table carries.
bench_markdown_caveat() {
  cat <<'CAVEAT'
> **Read ratios, not absolutes.** wall_ms inflates 2-10x when loadavg_1m rises
> above roughly 2x the core count of the machine that produced the row, so
> compare control_probe_ms across rows first: if it moved with wall_ms the host
> was loaded, and only a step whose wall_ms moved while control_probe_ms held
> steady is a real regression. est_tokens is stdout_bytes/4 - an estimate of
> observation cost, not a token count.
CAVEAT
}

# bench_render_markdown <csv> - caveat header plus the CSV as a markdown table.
# The parser handles quoted fields; embedded newlines are out of scope because
# bench_run_step never writes one (cmd is always a single line).
bench_render_markdown() {
  local csv="$1"
  if [ ! -f "$csv" ]; then
    echo "bench_render_markdown: no such CSV: $csv" >&2
    return 2
  fi

  bench_markdown_caveat
  printf '\n'

  LC_ALL=C awk '
    function esc(s) { gsub(/\|/, "\\|", s); return s }
    {
      n = 0; f = ""; inq = 0; len = length($0)
      for (i = 1; i <= len; i++) {
        c = substr($0, i, 1)
        if (inq) {
          if (c == "\"") {
            if (substr($0, i + 1, 1) == "\"") { f = f "\""; i++ } else { inq = 0 }
          } else { f = f c }
        } else if (c == "\"") { inq = 1 }
        else if (c == ",") { fld[++n] = f; f = "" }
        else { f = f c }
      }
      fld[++n] = f
      row = ""
      for (j = 1; j <= n; j++) row = row "| " esc(fld[j]) " "
      print row "|"
      if (NR == 1) {
        sep = ""
        for (j = 1; j <= n; j++) sep = sep "| --- "
        print sep "|"
      }
    }
  ' "$csv"
}

# --- teardown ---------------------------------------------------------------

# bench_teardown_agent_device <session> - the only sanctioned way to end a run.
#
# REAPER GUARD - never kill the runner by hand.
#   Do NOT use pkill (or kill, or killall) on the in-simulator XCUITest runner
#   or on the agent-device daemon. Reaping that runner poisons accessibility
#   device-wide until the simulator is rebooted: every later query returns empty
#   or stale trees, on every session, for every tool. The sanctioned reclaim of
#   retained runner processes and leases is `close` followed by
#   `daemon stop --clean`, and that is what this function does. If a process
#   somehow survives, reboot the simulator - do not reach for pkill. The
#   in-simulator runner also idle-stops on its own after ~5 minutes, so a
#   survivor is time-bounded anyway. CI greps this repo for pkill.
bench_teardown_agent_device() {
  local session="${1:-${BENCH_SESSION:-default}}"

  if ! command -v agent-device > /dev/null 2>&1; then
    echo "bench: agent-device not on PATH, nothing to tear down" >&2
    return 0
  fi

  if ! agent-device close --session "$session" > /dev/null 2>&1; then
    echo "bench: 'agent-device close --session $session' failed (continuing)" >&2
  fi
  if ! agent-device daemon stop --clean > /dev/null 2>&1; then
    echo "bench: 'agent-device daemon stop --clean' failed (continuing)" >&2
  fi
  return 0
}
