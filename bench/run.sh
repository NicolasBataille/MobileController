#!/bin/bash
# bench/run.sh - the bench entry point.
#
#   bench/run.sh --target settings                 # zero-setup: any simulator
#   bench/run.sh --target demoapp --repeat 5       # builds + installs DemoApp
#
# Reads machine-specific values from the git-ignored bench/local.env, runs one
# flow, and writes bench/out/<timestamp>/results.csv plus a rendered
# results.md. Prints the markdown path on stdout and nothing else, so it
# composes: `open "$(bench/run.sh --target settings)"`.
#
# Portability: macOS system /bin/bash 3.2.

set -euo pipefail

BENCH_RUN_DIR=$(cd "$(dirname "$0")" && pwd)
BENCH_REPO_ROOT=$(cd "$BENCH_RUN_DIR/.." && pwd)
cd "$BENCH_REPO_ROOT"
# shellcheck source=/dev/null
. "$BENCH_REPO_ROOT/bench/lib/common.sh"

BENCH_TARGET=""
BENCH_REPEAT=3
BENCH_OUT_DIR=""
# Overridable so the test suite can point at a path that does not exist and
# exercise the missing-config branch on a machine that has a real local.env.
BENCH_LOCAL_ENV="${BENCH_LOCAL_ENV:-bench/local.env}"

usage() {
  cat <<'USAGE'
usage: bench/run.sh --target settings|demoapp [--repeat N] [--out DIR]

  --target settings   Apple Settings. Needs only a booted simulator.
  --target demoapp    DemoApp. Generates the Xcode project, builds it into a
                      scratch derivedData under the output directory, installs
                      it on the target simulator, then runs the flow.
  --repeat N          Repeats of the warm part of the flow (default 3).
  --out DIR           Output directory (default bench/out/<timestamp>).

Configuration lives in the git-ignored bench/local.env; copy
bench/local.env.example and fill in BENCH_UDID. Set BENCH_DRY_RUN=1 to record
every step's command line without executing it or touching a simulator.
USAGE
}

die() {
  echo "bench: $*" >&2
  exit 2
}

# --- arguments --------------------------------------------------------------

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      [ "$#" -ge 2 ] || die "--target needs a value (settings|demoapp)"
      BENCH_TARGET="$2"
      shift 2
      ;;
    --repeat)
      [ "$#" -ge 2 ] || die "--repeat needs a value"
      BENCH_REPEAT="$2"
      shift 2
      ;;
    --out)
      [ "$#" -ge 2 ] || die "--out needs a value"
      BENCH_OUT_DIR="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

case "$BENCH_TARGET" in
  settings) BENCH_FLOW_FILE="bench/flows/settings-observe-act.sh" ;;
  demoapp) BENCH_FLOW_FILE="bench/flows/demoapp-observe-act.sh" ;;
  "")
    usage >&2
    die "--target is required"
    ;;
  *)
    usage >&2
    die "unknown target [$BENCH_TARGET] - expected settings or demoapp"
    ;;
esac

case "$BENCH_REPEAT" in
  '' | *[!0-9]*) die "--repeat must be a positive integer, got [$BENCH_REPEAT]" ;;
esac
[ "$BENCH_REPEAT" -ge 1 ] || die "--repeat must be at least 1"

# --- configuration ----------------------------------------------------------

if [ ! -f "$BENCH_LOCAL_ENV" ]; then
  cat >&2 <<CONFIG
bench: no configuration at [$BENCH_LOCAL_ENV].

  The bench needs a simulator UDID, and that is the one value this repo refuses
  to commit. Create it from the committed template:

      cp bench/local.env.example bench/local.env
      xcrun simctl list devices booted     # or: .build/release/simprobe devices
      \$EDITOR bench/local.env             # set BENCH_UDID

  bench/local.env is git-ignored on purpose - nothing machine-specific is ever
  committed. Point BENCH_LOCAL_ENV elsewhere to use a different file.
CONFIG
  exit 2
fi

# `set -a` so every value the file defines is exported to the flow, which runs
# as a separate process. Without it a setting like BENCH_SETTINGS_ROW is read
# here and then silently ignored there - the flow falls back to its default and
# the failure looks like a broken selector rather than a missing export.
set -a
# shellcheck source=/dev/null
. "$BENCH_LOCAL_ENV"
set +a

BENCH_SESSION="${BENCH_SESSION:-bench}"
if ! bench_is_dry_run && [ -z "${BENCH_UDID:-}" ]; then
  die "BENCH_UDID is empty in [$BENCH_LOCAL_ENV]. Set it to a booted simulator's UDID."
fi

if [ -z "$BENCH_OUT_DIR" ]; then
  BENCH_OUT_DIR="bench/out/$(date +%Y%m%dT%H%M%S)"
fi
BENCH_CSV="$BENCH_OUT_DIR/results.csv"
BENCH_MARKDOWN="$BENCH_OUT_DIR/results.md"

export BENCH_UDID BENCH_SESSION BENCH_OUT_DIR BENCH_CSV BENCH_REPEAT

# --- DemoApp build + install ------------------------------------------------

# bench_build_and_install_demoapp - XcodeGen, xcodebuild, simctl install.
#
# The .xcodeproj is generated, never committed, and derivedData goes under the
# run's own output directory so two runs never share a build and nothing lands
# outside the git-ignored bench/out/.
bench_build_and_install_demoapp() {
  local dd="$BENCH_OUT_DIR/dd"
  local app="$dd/Build/Products/Debug-iphonesimulator/DemoApp.app"

  if bench_is_dry_run; then
    return 0
  fi

  command -v xcodegen > /dev/null 2>&1 \
    || die "xcodegen is not on PATH. Install it with: brew install xcodegen"

  mkdir -p "$dd"
  echo "bench: generating DemoApp.xcodeproj" >&2
  (cd DemoApp && xcodegen generate > /dev/null) \
    || die "xcodegen generate failed in DemoApp/"

  echo "bench: building DemoApp into $dd (this takes a minute the first time)" >&2
  xcodebuild -project DemoApp/DemoApp.xcodeproj \
    -scheme DemoApp \
    -destination "id=$BENCH_UDID" \
    -derivedDataPath "$dd" \
    -quiet \
    build > "$BENCH_OUT_DIR/xcodebuild.log" 2>&1 \
    || die "xcodebuild failed - see $BENCH_OUT_DIR/xcodebuild.log"

  [ -d "$app" ] || die "xcodebuild produced no app bundle at $app"

  echo "bench: installing DemoApp on the target simulator" >&2
  xcrun simctl install "$BENCH_UDID" "$app" \
    || die "simctl install failed for $app"
}

# --- run --------------------------------------------------------------------

mkdir -p "$BENCH_OUT_DIR"
if [ "$BENCH_TARGET" = "demoapp" ]; then
  bench_build_and_install_demoapp
fi

bench_csv_init "$BENCH_CSV"

# A failing flow still produced rows, and those rows are the evidence for why it
# failed: render the table either way, and report the flow's status afterwards.
flow_rc=0
/bin/bash "$BENCH_FLOW_FILE" || flow_rc=$?

bench_render_markdown "$BENCH_CSV" > "$BENCH_MARKDOWN"
printf '%s\n' "$BENCH_MARKDOWN"

if [ "$flow_rc" -ne 0 ]; then
  echo "bench: flow [$BENCH_FLOW_FILE] exited $flow_rc - the table above is still valid" >&2
  exit "$flow_rc"
fi
