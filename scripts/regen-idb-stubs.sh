#!/usr/bin/env bash
#
# Regenerates the vendored idb protobuf/gRPC stubs under Sources/SimProbeDaemon/Generated/.
#
# The stubs are generated from **the installed idb client's own descriptor**, not from
# upstream's `idb.proto`. Upstream has grown fields the released companion does not know
# (`AccessibilityInfoRequest.marker`, `Format.COMPLETE`, ...), and a client generated from it
# sends messages the companion rejects. Dumping `idb.grpc.idb_pb2.DESCRIPTOR` to a
# FileDescriptorSet and feeding that to `protoc --descriptor_set_in` makes the stubs
# wire-compatible with whatever idb is actually installed, by construction.
#
# The interpreter is taken from `idb`'s own shebang: fb-idb is a pip install into one specific
# Python, which is rarely the `python3` first on PATH. Override with IDB_PYTHON.
#
# Needs, besides idb:
#   brew install protobuf swift-protobuf protoc-gen-grpc-swift
# whose plugin binaries live under `$(brew --prefix)/opt/<formula>/bin` and are not all
# symlinked into `bin`, so they are put on PATH explicitly below.
#
# Run from anywhere in the working tree. Regenerating with the same idb version reproduces the
# vendored files byte for byte; a diff means the installed companion moved.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

readonly OUT='Sources/SimProbeDaemon/Generated'

idb_path="$(command -v idb || true)"
if [ -z "$idb_path" ]; then
    echo 'regen: idb is not installed: brew install facebook/fb/idb-companion && pip3 install fb-idb' >&2
    exit 1
fi

python="${IDB_PYTHON:-$(sed -n '1s/^#!//p' "$idb_path")}"
if [ ! -x "$python" ]; then
    echo "regen: no usable Python behind $idb_path (set IDB_PYTHON)" >&2
    exit 1
fi

brew_prefix="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
PATH="$brew_prefix/opt/swift-protobuf/bin:$brew_prefix/opt/protoc-gen-grpc-swift/bin:$PATH"
export PATH
for tool in protoc protoc-gen-swift protoc-gen-grpc-swift-2; do
    command -v "$tool" >/dev/null || {
        echo "regen: $tool not found; brew install protobuf swift-protobuf protoc-gen-grpc-swift" >&2
        exit 1
    }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The interpreter both dumps the descriptor and reports which fb-idb it belongs to: `idb`
# itself has no `--version`, and the package metadata is the only honest answer.
idb_version="$("$python" - "$work/idb.desc" <<'PY'
import sys
from importlib import metadata

from google.protobuf import descriptor_pb2

import idb.grpc.idb_pb2 as idb_pb2

file_set = descriptor_pb2.FileDescriptorSet()
idb_pb2.DESCRIPTOR.CopyToProto(file_set.file.add())
with open(sys.argv[1], "wb") as handle:
    handle.write(file_set.SerializeToString())
try:
    print("fb-idb", metadata.version("fb-idb"))
except metadata.PackageNotFoundError:
    print("fb-idb (version unknown)")
PY
)"

protoc \
    --descriptor_set_in="$work/idb.desc" \
    --swift_opt=Visibility=Public \
    --swift_out="$work" \
    --grpc-swift-2_opt=Visibility=Public,Client=true,Server=false \
    --grpc-swift-2_out="$work" \
    idb.proto

mkdir -p "$OUT"
for name in idb.pb.swift idb.grpc.swift; do
    {
        cat <<EOF
// Vendored, generated code — do not edit by hand; run scripts/regen-idb-stubs.sh instead.
//
// Origin: the \`idb.proto\` service definition of Facebook's idb (MIT), read out of the
// installed client's own compiled descriptor rather than from upstream source, so these stubs
// match the companion on this machine. Generated against ${idb_version:-an unknown idb}.
EOF
        cat "$work/$name"
    } >"$OUT/$name"
done

echo "regen: wrote $OUT/idb.pb.swift and $OUT/idb.grpc.swift from ${idb_version:-idb}"
