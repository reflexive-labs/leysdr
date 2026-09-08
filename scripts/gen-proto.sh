#!/usr/bin/env bash
# Regenerates leyline.v1 code for both languages from proto/. The generated code is checked in so
# the Go module and the Swift package build without protoc; CI runs this script and fails on drift.
#
# Requires: protoc, protoc-gen-go, protoc-gen-go-grpc, protoc-gen-swift (apple/swift-protobuf),
#           protoc-gen-grpc-swift-2 (grpc/grpc-swift-protobuf). See docs/dev-setup.md.
#
# Plugin versions (they shape the output): protoc-gen-go v1.36.12, protoc-gen-go-grpc v1.6.2,
# swift-protobuf 1.38.1, grpc-swift-protobuf 2.4.1. CI installs exactly these and protoc
# PROTOC_VERSION. Any reasonably current protoc produces the same code for these proto3 files; the
# Go plugins stamp the protoc version into a header comment, which this script normalises so a
# different local protoc does not show up as drift. Real drift (a different descriptor) still fails
# `make proto-check`.
set -euo pipefail
cd "$(dirname "$0")/.."

PROTOC_VERSION=25.1
PROTOS=(proto/leyline/v1/*.proto)
GO_MODULE=github.com/dpup/leysdr/go/gen

have="$(protoc --version | awk '{print $2}')"
if [ "$have" != "$PROTOC_VERSION" ]; then
  echo "note: protoc $have (CI uses $PROTOC_VERSION); output should be identical, proto-check verifies" >&2
fi

echo "validating protos"
protoc -I proto --descriptor_set_out=/dev/null "${PROTOS[@]}"

echo "generating Go -> go/gen/leyline/v1"
mkdir -p go/gen
protoc -I proto \
  --go_out=go/gen --go_opt=module="$GO_MODULE" \
  --go-grpc_out=go/gen --go-grpc_opt=module="$GO_MODULE" \
  "${PROTOS[@]}"
# Drop the protoc version the Go plugins stamp into their headers ("// \tprotoc        v4.25.1",
# "// - protoc             v4.25.1") so the checked-in files do not depend on the local protoc.
perl -pi -e 's{^(// \t?protoc\s+|// - protoc\s+)v\d[\w.-]*$}{$1(version-independent)}' go/gen/leyline/v1/*.pb.go

if command -v protoc-gen-swift >/dev/null && command -v protoc-gen-grpc-swift-2 >/dev/null; then
  echo "generating Swift -> engine/Sources/LeylineProto"
  mkdir -p engine/Sources/LeylineProto
  rm -f engine/Sources/LeylineProto/*.pb.swift engine/Sources/LeylineProto/*.grpc.swift
  protoc -I proto \
    --swift_out=engine/Sources/LeylineProto --swift_opt=Visibility=Public --swift_opt=FileNaming=DropPath \
    --grpc-swift-2_out=engine/Sources/LeylineProto --grpc-swift-2_opt=Visibility=Public \
    --grpc-swift-2_opt=Server=true --grpc-swift-2_opt=Client=true --grpc-swift-2_opt=FileNaming=DropPath \
    "${PROTOS[@]}"
else
  echo "protoc-gen-swift / protoc-gen-grpc-swift-2 not on PATH; skipping Swift generation" >&2
  [ "${REQUIRE_SWIFT:-0}" = "1" ] && exit 1
fi
echo "done"
