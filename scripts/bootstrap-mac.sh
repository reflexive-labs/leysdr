#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# One-shot macOS setup: selected SDR driver, Go clients, release daemon, fixtures, decoders. See docs/dev/setup.md.
set -euo pipefail
cd "$(dirname "$0")/.."

install_rtl=1
install_hackrf=1
case "${1:-}" in
  "") ;;
  --rtl-only) install_hackrf=0 ;;
  --hackrf-only) install_rtl=0 ;;
  *) echo "usage: $0 [--rtl-only|--hackrf-only]" >&2; exit 2 ;;
esac

command -v brew >/dev/null || { echo "Homebrew is required: https://brew.sh" >&2; exit 1; }
command -v xcrun >/dev/null || { echo "Xcode (or Command Line Tools) is required" >&2; exit 1; }

echo "==> brew deps (selected SDR driver + libusb, go)"
if (( install_rtl )); then
  brew list librtlsdr >/dev/null 2>&1 || brew install librtlsdr
fi
if (( install_hackrf )); then
  brew list hackrf >/dev/null 2>&1 || brew install hackrf
fi
brew list go >/dev/null 2>&1 || brew install go

echo "==> Go clients -> go/bin"
make go

echo "==> engine (release) -> engine/.build/release/leylined"
make swift-release

echo "==> IQ fixtures -> fixtures/"
make fixtures

echo "==> decoders (APRS, SAME, AIS, iqstat) -> ~/Library/Application Support/Leyline/decoders"
make install-decoders

cat <<MSG

Done. Next:
  ./engine/.build/release/leylined --log-level debug     # terminal 1
  export PATH=\$PWD/go/bin:\$PATH && ley devices          # terminal 2
  ley tune 101.1M --mode wfm                              # broadcast FM: the "dongle is alive" test
MSG
