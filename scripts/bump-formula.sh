#!/usr/bin/env bash
#
# Point Formula/simprobe.rb at a release tag. Run from anywhere in the working tree.
#
#   scripts/bump-formula.sh v0.2.0
#
# The formula carries a URL and a checksum, and both move on every release. A formula left on
# the previous tag still installs cleanly - it just installs the previous binary, silently,
# which is the worst possible failure mode for a release step. So this is a script rather than
# a line in CONTRIBUTING.md: the checksum in particular is not something to compute by hand.
#
# Running it on the tag the formula already carries is a no-op, which is what makes it safe to
# re-run and what CONTRIBUTING.md tells a reviewer to check.
#
# Exit 0 when the formula matches the tag, 1 on a bad argument or an unreachable tarball.

set -euo pipefail

readonly REPO='NicolasBataille/MobileController'

usage() {
    echo "usage: $(basename "$0") <tag>        # e.g. $(basename "$0") v0.2.0" >&2
    exit 1
}

[ "$#" -eq 1 ] || usage
readonly TAG="$1"
case "$TAG" in
    v[0-9]*) ;;
    *) echo "bump-formula: '$TAG' is not a vX.Y.Z tag" >&2; usage ;;
esac

cd "$(git rev-parse --show-toplevel)"
readonly FORMULA='Formula/simprobe.rb'
readonly URL="https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz"

# --fail so a 404 becomes an error rather than a checksum over a page of HTML.
tarball="$(mktemp -t simprobe-formula)"
trap 'rm -f "$tarball"' EXIT
if ! curl -fsL "$URL" -o "$tarball"; then
    echo "bump-formula: could not download $URL - is the tag pushed?" >&2
    exit 1
fi
sha="$(shasum -a 256 "$tarball" | cut -d' ' -f1)"

python3 - "$FORMULA" "$URL" "$sha" <<'PY'
import re
import sys

path, url, sha = sys.argv[1:4]
with open(path, encoding="utf-8") as handle:
    text = handle.read()

# Only the two release lines are touched, and each must match exactly once: a formula that
# grew a second url or sha256 is one this script must not guess about.
for pattern, replacement in ((r'^  url ".*"$', f'  url "{url}"'),
                             (r'^  sha256 ".*"$', f'  sha256 "{sha}"')):
    text, count = re.subn(pattern, replacement, text, flags=re.MULTILINE)
    if count != 1:
        sys.exit(f"bump-formula: expected 1 {pattern!r} line in {path}, found {count}")

with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
PY

echo "bump-formula: $FORMULA -> $TAG"
echo "  url    $URL"
echo "  sha256 $sha"
