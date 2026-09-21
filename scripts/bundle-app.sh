#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Assembles app/dist/Leyline.app from the SwiftPM release build. SwiftPM produces a bare executable;
# a Mac app is a bundle (Info.plist, resources, a signature), and this is the one place that bundle
# is laid out, so `swift build` stays the build and Xcode is never required. docs/dev/app.md,
# "Building and running".
#
#   scripts/bundle-app.sh                 build release, bundle, ad-hoc sign
#   scripts/bundle-app.sh --with-daemon   also carry leylined, ley and the decoder plugins under
#                                         Contents/Helpers (what a distributed build ships: E.7)
#
# CODESIGN_IDENTITY names a signing identity ("Developer ID Application: …"); unset, the bundle is
# ad-hoc signed, which runs on this machine and nowhere else. Notarization is the release
# checklist's step, not this script's.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
[ "$(uname -s)" = Darwin ] || { echo "bundle-app.sh lays out a Mac bundle; run it on the Mac" >&2; exit 2; }

with_daemon=0
[ "${1:-}" = "--with-daemon" ] && with_daemon=1
identity=${CODESIGN_IDENTITY:--}

version=$(tr -d '[:space:]' < VERSION)
build=$(git describe --tags --always --dirty --match 'v*' --abbrev=7 2>/dev/null || echo dev)

echo "==> swift build -c release (app/)"
(cd app && swift build -c release --product LeylineApp)
bin=$(cd app && swift build -c release --show-bin-path)

out=app/dist/Leyline.app
rm -rf "$out"
mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
sed -e "s/__VERSION__/$version/" -e "s/__BUILD__/$build/" app/Sources/LeylineApp/Info.plist > "$out/Contents/Info.plist"
printf 'APPL????' > "$out/Contents/PkgInfo"
cp "$bin/LeylineApp" "$out/Contents/MacOS/LeylineApp"
# SwiftPM resource bundles (assets, Metal libraries) sit beside the executable; Bundle.module
# looks for them in the app's Resources when it is not beside the binary.
for b in "$bin"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$out/Contents/Resources/"; done

if [ $with_daemon -eq 1 ]; then
  echo "==> helpers: leylined, ley, decoders"
  (cd engine && swift build -c release --product leylined >/dev/null)
  ebin=$(cd engine && swift build -c release --show-bin-path)
  mkdir -p "$out/Contents/Helpers/decoders"
  cp "$ebin/leylined" "$out/Contents/Helpers/"
  [ -x go/bin/ley ] || make go >/dev/null
  cp go/bin/ley "$out/Contents/Helpers/"
  for d in decoders/*/; do
    name=$(basename "$d")
    mkdir -p "$out/Contents/Helpers/decoders/$name"
    cp "$d"/*.json "$out/Contents/Helpers/decoders/$name/" 2>/dev/null || true
    [ -x "go/bin/leydec-$name" ] && cp "go/bin/leydec-$name" "$out/Contents/Helpers/decoders/$name/"
  done
  # The GPL engine travels with its licence text and the source offer (docs/decisions/D2-licensing.md).
  cp engine/LICENSE "$out/Contents/Helpers/LICENSE.leylined"
  cp third_party/licenses/librtlsdr.txt "$out/Contents/Helpers/"
  cp third_party/licenses/libhackrf.txt "$out/Contents/Helpers/"
fi
cp LICENSE NOTICE "$out/Contents/Resources/"

echo "==> codesign ($identity)"
sign_opts=(--force --sign "$identity" --timestamp=none)
[ "$identity" != "-" ] && sign_opts=(--force --sign "$identity" --options runtime --timestamp)
if [ $with_daemon -eq 1 ]; then
  find "$out/Contents/Helpers" -type f -perm -u+x -exec codesign "${sign_opts[@]}" {} \;
fi
codesign "${sign_opts[@]}" "$out"
codesign --verify --deep --strict "$out"
echo "$out ($version, $build). Open it with: open $out"
