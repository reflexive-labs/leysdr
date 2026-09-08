#!/usr/bin/env bash
# Regenerates leyline.v1 code for both languages from proto/. The generated code is checked in so
# the Go module and the Swift package build without protoc; CI runs this script and fails on drift.
#
# Toolchain: everything except protoc itself comes from the repo and is installed into
# .tools/<os>-<arch>/bin (gitignored) so the output never depends on what happens to be on PATH:
#   - protoc-gen-go, protoc-gen-go-grpc: `tool` directives in go/go.mod (`go install tool`)
#   - protoc-gen-swift, protoc-gen-grpc-swift-2: products of the engine package's resolved
#     dependencies (engine/Package.resolved), built with `swift build` when a Swift toolchain is present
# protoc: the system one (Homebrew, apt, arduino/setup-protoc in CI). Any current version produces the
# same code for these proto3 files; the Go plugins stamp the protoc version into a header comment,
# which this script normalises. Real drift (a different descriptor or plugin) still fails proto-check.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
# Per-host tool directory: a checkout shared between machines (a Mac and a Linux container on the
# same mount) must not hand one host the other's binaries.
HOST="$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
TOOLS=$ROOT/.tools/$HOST/bin
mkdir -p "$TOOLS"

PROTOC_VERSION=25.1   # what CI installs; informational
PROTOS=(proto/leyline/v1/*.proto)
GO_MODULE=github.com/dpup/leysdr/go/gen

command -v protoc >/dev/null || { echo "protoc not found (brew install protobuf / apt install protobuf-compiler)" >&2; exit 1; }
have="$(protoc --version | awk '{print $2}')"
if [ "$have" != "$PROTOC_VERSION" ]; then
  echo "note: protoc $have (CI uses $PROTOC_VERSION); output should be identical, proto-check verifies" >&2
fi

echo "installing pinned Go plugins -> .tools/$HOST/bin (go/go.mod tool directives)"
(cd go && GOBIN="$TOOLS" go install tool)

# Swift plugins: rebuilt when missing or when the resolved package versions change.
SWIFT_PLUGINS=0
if command -v swift >/dev/null; then
  stamp="$(cksum engine/Package.resolved | awk '{print $1}')"
  if [ ! -x "$TOOLS/protoc-gen-swift" ] || [ ! -x "$TOOLS/protoc-gen-grpc-swift-2" ] \
     || [ "$(cat "$ROOT/.tools/$HOST/swift-plugins.stamp" 2>/dev/null)" != "$stamp" ]; then
    echo "building pinned Swift plugins -> .tools/$HOST/bin (engine/Package.resolved)"
    (cd engine && swift build -c release --product protoc-gen-swift >/dev/null \
               && swift build -c release --product protoc-gen-grpc-swift-2 >/dev/null)
    # --show-bin-path resolves the per-triple directory; the .build/release symlink can point at
    # another host's build on a shared checkout.
    bin="$(cd engine && swift build -c release --show-bin-path)"
    cp "$bin/protoc-gen-swift" "$bin/protoc-gen-grpc-swift-2" "$TOOLS/"
    echo "$stamp" > "$ROOT/.tools/$HOST/swift-plugins.stamp"
  fi
  SWIFT_PLUGINS=1
else
  echo "swift not on PATH; skipping Swift generation" >&2
  [ "${REQUIRE_SWIFT:-0}" = "1" ] && exit 1
fi

echo "validating protos"
protoc -I proto --descriptor_set_out=/dev/null "${PROTOS[@]}"

# Generate into a scratch directory and replace the checked-in files only once protoc has
# succeeded, so a failed run (missing plugin, bad proto) never leaves the tree without its
# generated code. This matters on a shared checkout: the Swift package cannot even load without
# engine/Sources/LeylineProto, and the plugins are built from that package.
OUT="$(mktemp -d "${TMPDIR:-/tmp}/leyline-gen.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

echo "generating Go -> go/gen/leyline/v1"
mkdir -p "$OUT/go"
protoc -I proto \
  --plugin=protoc-gen-go="$TOOLS/protoc-gen-go" --plugin=protoc-gen-go-grpc="$TOOLS/protoc-gen-go-grpc" \
  --go_out="$OUT/go" --go_opt=module="$GO_MODULE" \
  --go-grpc_out="$OUT/go" --go-grpc_opt=module="$GO_MODULE" \
  "${PROTOS[@]}"
# Drop the protoc version the Go plugins stamp into their headers ("// \tprotoc        v4.25.1",
# "// - protoc             v4.25.1") so the checked-in files do not depend on the local protoc.
perl -pi -e 's{^(// \t?protoc\s+|// - protoc\s+)v\d[\w.-]*$}{$1(version-independent)}' "$OUT"/go/leyline/v1/*.pb.go
mkdir -p go/gen/leyline/v1
rm -f go/gen/leyline/v1/*.pb.go
cp "$OUT"/go/leyline/v1/*.pb.go go/gen/leyline/v1/

if [ "$SWIFT_PLUGINS" = "1" ]; then
  echo "generating Swift -> engine/Sources/LeylineProto"
  mkdir -p "$OUT/swift"
  protoc -I proto \
    --plugin=protoc-gen-swift="$TOOLS/protoc-gen-swift" --plugin=protoc-gen-grpc-swift-2="$TOOLS/protoc-gen-grpc-swift-2" \
    --swift_out="$OUT/swift" --swift_opt=Visibility=Public --swift_opt=FileNaming=DropPath \
    --grpc-swift-2_out="$OUT/swift" --grpc-swift-2_opt=Visibility=Public \
    --grpc-swift-2_opt=Server=true --grpc-swift-2_opt=Client=true --grpc-swift-2_opt=FileNaming=DropPath \
    "${PROTOS[@]}"
  mkdir -p engine/Sources/LeylineProto
  rm -f engine/Sources/LeylineProto/*.pb.swift engine/Sources/LeylineProto/*.grpc.swift
  cp "$OUT"/swift/*.pb.swift "$OUT"/swift/*.grpc.swift engine/Sources/LeylineProto/
fi
echo "done"
