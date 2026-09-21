#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# One-shot macOS setup: Homebrew deps, Go clients, release daemon, fixtures. See docs/dev/setup.md.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v brew >/dev/null || { echo "Homebrew is required: https://brew.sh" >&2; exit 1; }
command -v xcrun >/dev/null || { echo "Xcode (or Command Line Tools) is required" >&2; exit 1; }

echo "==> brew deps (librtlsdr + HackRF + libusb, go)"
brew list librtlsdr >/dev/null 2>&1 || brew install librtlsdr
brew list hackrf >/dev/null 2>&1 || brew install hackrf
brew list go >/dev/null 2>&1 || brew install go

echo "==> Go clients -> go/bin"
make go

echo "==> engine (release) -> engine/.build/release/leylined"
make swift-release

echo "==> IQ fixtures -> fixtures/"
make fixtures

cat <<MSG

Done. Next:
  ./engine/.build/release/leylined --log-level debug     # terminal 1
  export PATH=\$PWD/go/bin:\$PATH && ley devices          # terminal 2
  ley tune 101.1M --mode wfm                              # broadcast FM: the "dongle is alive" test
MSG
