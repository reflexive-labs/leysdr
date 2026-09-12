#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Installs the repository's decoder plugins where a running leylined looks for them: the platform
# default decoder directory (docs/design/decoders.md, "Decisions"). Each decoder's manifest and its
# built binary go into one directory per decoder, the binary beside the manifest, so the daemon
# resolves `executable` against the manifest's own directory and needs nothing on its PATH -- which
# a launchd job does not have. `make reload` runs this so `ley decode`/`ley watch` work after it.
set -euo pipefail
cd "$(dirname "$0")/.."

GOBIN="${GOBIN:-$PWD/go/bin}"

# The default the daemon searches when no --decoders flag names another (DaemonCommand.swift,
# defaultDecodersPath). LEYLINE_DECODERS_DEST overrides, for a test or a non-standard install.
if [ -n "${LEYLINE_DECODERS_DEST:-}" ]; then
  DEST="$LEYLINE_DECODERS_DEST"
elif [ "$(uname -s)" = Darwin ]; then
  DEST="$HOME/Library/Application Support/Leyline/decoders"
else
  DEST="${XDG_DATA_HOME:-$HOME/.local/share}/leyline/decoders"
fi

mkdir -p "$DEST"
installed=0
for m in decoders/*/manifest.json; do
  [ -f "$m" ] || continue
  name="$(basename "$(dirname "$m")")"
  # The binary the manifest names. Bare grep/sed rather than jq: this runs on a stock Mac.
  exe="$(sed -n 's/.*"executable"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$m" | head -1)"
  [ -n "$exe" ] || { echo "install-decoders: no executable named in $m" >&2; exit 1; }
  if [ ! -x "$GOBIN/$exe" ]; then
    echo "install-decoders: $GOBIN/$exe is missing; run 'make go' first" >&2
    exit 1
  fi
  mkdir -p "$DEST/$name"
  cp "$m" "$DEST/$name/manifest.json"
  cp "$GOBIN/$exe" "$DEST/$name/$exe.new"
  mv "$DEST/$name/$exe.new" "$DEST/$name/$exe"   # atomic replace: never a half-copied binary
  chmod +x "$DEST/$name/$exe"
  echo "installed decoder '$name' -> $DEST/$name"
  installed=$((installed + 1))
done

if [ "$installed" -eq 0 ]; then
  echo "install-decoders: no decoders found under decoders/" >&2
  exit 1
fi
echo "$installed decoder(s) installed; a running daemon picks them up on its next start (make reload)"
