#!/usr/bin/env bash
# Regenerates leyline.v1 code for both languages from proto/. The generated code is checked in so
# the Go module and the Swift package build without protoc; CI runs this script and fails on drift.
#
# Toolchain: everything except protoc itself comes from the repo and is installed into .tools/bin
# (gitignored) so the output never depends on what happens to be on PATH:
#   - protoc-gen-go, protoc-gen-go-grpc: `tool` directives in go/go.mod (`go install tool`)
#   - protoc-gen-swift, protoc-gen-grpc-swift-2: products of the engine package's resolved
#     dependencies (engine/Package.resolved), built with `swift build` when a Swift toolchain is present
# protoc: the system one (Homebrew, apt, arduino/setup-protoc in CI). Any current version produces the
# same code for these proto3 files; the Go plugins stamp the protoc version into a header comment,
# which this script normalises. Real drift (a different descriptor or plugin) still fails proto-check.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
TOOLS=$ROOT/.tools/bin
mkdir -p "$TOOLS"

PROTOC_VERSION=25.1   # what CI installs; informational
PROTOS=(proto/leyline/v1/*.proto)
GO_MODULE=github.com/dpup/leysdr/go/gen

command -v protoc >/dev/null || { echo "protoc not found (brew install protobuf / apt install protobuf-compiler)" >&2; exit 1; }
have="$(protoc --version | awk '{print $2}')"
if [ "$have" != "$PROTOC_VERSION" ]; then
  echo "note: protoc $have (CI uses $PROTOC_VERSION); output should be identical, proto-check verifies" >&2
fi

echo "installing pinned Go plugins -> .tools/bin (go/go.mod tool directives)"
(cd go && GOBIN="$TOOLS" go install tool)

# Swift plugins: rebuilt when missing or when the resolved package versions change.
SWIFT_PLUGINS=0
if command -v swift >/dev/null; then
  stamp="$(cksum engine/Package.resolved | awk '{print $1}')"
  if [ ! -x "$TOOLS/protoc-gen-swift" ] || [ ! -x "$TOOLS/protoc-gen-grpc-swift-2" ] \
     || [ "$(cat "$ROOT/.tools/swift-plugins.stamp" 2>/dev/null)" != "$stamp" ]; then
    echo "building pinned Swift plugins -> .tools/bin (engine/Package.resolved)"
    (cd engine && swift build -c release --product protoc-gen-swift >/dev/null \
               && swift build -c release --product protoc-gen-grpc-swift-2 >/dev/null)
    cp engine/.build/release/protoc-gen-swift engine/.build/release/protoc-gen-grpc-swift-2 "$TOOLS/"
    echo "$stamp" > "$ROOT/.tools/swift-plugins.stamp"
  fi
  SWIFT_PLUGINS=1
else
  echo "swift not on PATH; skipping Swift generation" >&2
  [ "${REQUIRE_SWIFT:-0}" = "1" ] && exit 1
fi

echo "validating protos"
protoc -I proto --descriptor_set_out=/dev/null "${PROTOS[@]}"

echo "generating Go -> go/gen/leyline/v1"
mkdir -p go/gen
protoc -I proto \
  --plugin=protoc-gen-go="$TOOLS/protoc-gen-go" --plugin=protoc-gen-go-grpc="$TOOLS/protoc-gen-go-grpc" \
  --go_out=go/gen --go_opt=module="$GO_MODULE" \
  --go-grpc_out=go/gen --go-grpc_opt=module="$GO_MODULE" \
  "${PROTOS[@]}"
# Drop the protoc version the Go plugins stamp into their headers ("// \tprotoc        v4.25.1",
# "// - protoc             v4.25.1") so the checked-in files do not depend on the local protoc.
perl -pi -e 's{^(// \t?protoc\s+|// - protoc\s+)v\d[\w.-]*$}{$1(version-independent)}' go/gen/leyline/v1/*.pb.go

if [ "$SWIFT_PLUGINS" = "1" ]; then
  echo "generating Swift -> engine/Sources/LeylineProto"
  mkdir -p engine/Sources/LeylineProto
  rm -f engine/Sources/LeylineProto/*.pb.swift engine/Sources/LeylineProto/*.grpc.swift
  protoc -I proto \
    --plugin=protoc-gen-swift="$TOOLS/protoc-gen-swift" --plugin=protoc-gen-grpc-swift-2="$TOOLS/protoc-gen-grpc-swift-2" \
    --swift_out=engine/Sources/LeylineProto --swift_opt=Visibility=Public --swift_opt=FileNaming=DropPath \
    --grpc-swift-2_out=engine/Sources/LeylineProto --grpc-swift-2_opt=Visibility=Public \
    --grpc-swift-2_opt=Server=true --grpc-swift-2_opt=Client=true --grpc-swift-2_opt=FileNaming=DropPath \
    "${PROTOS[@]}"
fi
echo "done"
