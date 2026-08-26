#!/usr/bin/env bash
#
# Public-repo hygiene gate. Run from the repository root; also wired into CI.
#
# Two groups of patterns, deliberately scoped differently:
#
#   1. Forbidden mechanisms — private-API loading and process reaping. These must never
#      appear in anything that executes. Prose is exempt (*.md), because the whole point of
#      the documentation is to tell contributors *not* to do these things: the planning docs
#      and the skill's pitfalls reference both `pkill` and the private-framework names by
#      name. A rule that cannot be written down is not a rule. For the same reason `pkill`
#      is only flagged in *command position* (start of line / after `;`, `&`, `|`, `(`,
#      `$(`), so a comment or a grep pattern that forbids it is not a hit while an actual
#      invocation is.
#
#   2. Leakage — absolute home paths and simulator UDIDs. Scanned everywhere, prose
#      included, because a leaked path or UDID is just as public in a README as in a script.
#      The home-path pattern requires a real first path segment, so documentation that names
#      the bare prefix or writes an elided `/Users/...` example is not a hit while an actual
#      `/Users/<name>/...` path is.
#
# This file is excluded from both scans: it necessarily contains every pattern it looks for.
#
# Both scans use --text rather than skipping binary-flagged files. A file git treats as
# binary - anything with a NUL byte in it, or anything a .gitattributes says is binary - is
# exactly where a leaked UDID or home path would go unnoticed, and "we did not look" is not
# an answer a hygiene gate gets to give.
#
# Exit 0 when clean, 1 on any match.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

readonly SELF=':!scripts/hygiene-check.sh'
readonly PROSE=':!*.md'

readonly PRIVATE_API_PATTERN='dlopen|AXPTranslator|SimulatorKit'
readonly REAPER_PATTERN='(^|[;&|(]|\$\()[[:space:]]*(sudo[[:space:]]+)?pkill([[:space:]]|$)'
readonly MECHANISM_PATTERN="$PRIVATE_API_PATTERN|$REAPER_PATTERN"
readonly HOME_PATH_PATTERN='/Users/[A-Za-z0-9_-][A-Za-z0-9._-]*'
readonly UDID_PATTERN='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
readonly LEAK_PATTERN="$HOME_PATH_PATTERN|$UDID_PATTERN"

failures=0

report() {
    local label="$1"
    local matches="$2"
    if [ -n "$matches" ]; then
        printf 'hygiene: %s\n%s\n\n' "$label" "$matches" >&2
        failures=$((failures + 1))
    fi
}

mechanism_hits="$(git grep --untracked -n --text -E "$MECHANISM_PATTERN" -- . "$SELF" "$PROSE" || true)"
report 'forbidden mechanism (private API loading or process reaping) in executable files' \
    "$mechanism_hits"

leak_hits="$(git grep --untracked -n --text -E "$LEAK_PATTERN" -- . "$SELF" || true)"
report 'leaked absolute home path or simulator UDID' "$leak_hits"

if [ "$failures" -ne 0 ]; then
    echo "hygiene: FAILED ($failures group(s) with matches)" >&2
    exit 1
fi

echo 'hygiene: clean'
