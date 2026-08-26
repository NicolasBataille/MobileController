#!/usr/bin/env bash
#
# Line-coverage floor for this repository's own sources. Run from anywhere in the working
# tree; also wired into CI, right after `swift test --enable-code-coverage`.
#
# Only files under <repo>/Sources are counted. The profile also carries the ArgumentParser
# checkout, whose coverage is not this project's business and which on its own drags the
# reported total from ~83% to ~36% - a floor computed over it would measure a dependency.
#
# A plain `swift test` rebuilds the bundle without instrumentation, so the profile left by an
# earlier run stops matching it. That is not a failure: the suite is re-run with coverage on.
#
# Set COVERAGE_MINIMUM to change the floor. Exit 0 at or above it, 1 below.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

readonly MINIMUM="${COVERAGE_MINIMUM:-80}"
readonly PROFDATA='.build/debug/codecov/default.profdata'

summarize() {
    local bundle
    bundle="$(/bin/ls -d .build/debug/*.xctest 2>/dev/null | head -1 || true)"
    if [ -z "$bundle" ] || [ ! -f "$PROFDATA" ]; then
        return 0
    fi
    xcrun llvm-cov export -summary-only \
        -instr-profile "$PROFDATA" \
        "$bundle/Contents/MacOS/$(basename "$bundle" .xctest)" 2>/dev/null || true
}

summary="$(summarize)"
if [ -z "$summary" ]; then
    echo 'coverage: no profile matching this build, running the suite with coverage' >&2
    swift test --enable-code-coverage >/dev/null
    summary="$(summarize)"
fi
if [ -z "$summary" ]; then
    echo 'coverage: llvm-cov produced no summary for .build/debug' >&2
    exit 1
fi

printf '%s' "$summary" \
    | COVERAGE_MINIMUM="$MINIMUM" COVERAGE_ROOT="$PWD/Sources/" python3 -c '
import json
import os
import sys

root = os.environ["COVERAGE_ROOT"]
minimum = float(os.environ["COVERAGE_MINIMUM"])
files = json.load(sys.stdin)["data"][0]["files"]

covered = total = 0
rows = []
for entry in files:
    name = entry["filename"]
    if not name.startswith(root):
        continue
    lines = entry["summary"]["lines"]
    covered += lines["covered"]
    total += lines["count"]
    rows.append((lines["percent"], name[len(root):]))

if total == 0:
    sys.exit("coverage: the profile covers no file under %s" % root)

percent = 100.0 * covered / total
for value, name in sorted(rows)[:5]:
    print("coverage: %6.1f%%  %s" % (value, name))
print("coverage: %.2f%% of %d lines in Sources (floor %.0f%%)" % (percent, total, minimum))
if percent < minimum:
    sys.exit("coverage: FAILED, %.2f%% is below the %.0f%% floor" % (percent, minimum))
'
