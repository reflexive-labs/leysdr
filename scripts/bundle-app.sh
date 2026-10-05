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
#                                         Contents/Helpers, the driver libraries under
#                                         Contents/Frameworks and the daemon's launch agent under
#                                         Contents/Library/LaunchAgents (what a distributed build
#                                         ships: E.7)
#
# CODESIGN_IDENTITY names a signing identity ("Developer ID Application: …"); unset, the bundle is
# ad-hoc signed, which runs on this machine and nowhere else. Notarization is scripts/release.sh's
# step, not this script's. BUNDLE_GOBIN names the directory holding ley and the leydec-* plugins
# (default go/bin, built with `make go` when ley is missing there); scripts/release.sh points it at
# a release build of its own. BUNDLE_OUT names the bundle to write (default app/dist/Leyline.app);
# `make release DRY_RUN=1` writes its rehearsal elsewhere.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
[ "$(uname -s)" = Darwin ] || { echo "bundle-app.sh lays out a Mac bundle; run it on the Mac" >&2; exit 2; }

# The driver libraries a distributed build carries, as Homebrew formula and library name. They
# go in Contents/Frameworks, where the loaders in engine/Sources/CRTLSDR and CHackRF look first,
# because a hardened-runtime daemon may load only libraries signed by Apple or by its own team,
# and Homebrew's copies are signed by neither. libusb is what both drivers link.
drivers=(librtlsdr:librtlsdr.0.dylib hackrf:libhackrf.0.dylib libusb:libusb-1.0.0.dylib)

die() { echo "bundle-app.sh: $*" >&2; exit 1; }

# bundle_drivers <app>: copy the drivers out of Homebrew, point their references to each other at
# the copies beside them, and record in Contents/Resources/drivers.json what source each one came
# from, because librtlsdr (GPL-2.0-or-later) and libusb (LGPL-2.1-or-later) oblige a release to
# offer it (docs/decisions/D2-licensing.md, "Distribution obligations").
bundle_drivers() {
  local fw="$1/Contents/Frameworks" pair formula lib prefix keg installed info fields name version url sha
  local entries=() names=() dep
  command -v brew >/dev/null 2>&1 || die "Homebrew is not installed; the driver libraries come from it (brew install librtlsdr hackrf libusb)"
  echo "==> drivers: ${drivers[*]}"
  mkdir -p "$fw"
  for pair in "${drivers[@]}"; do names+=("${pair#*:}"); done
  for pair in "${drivers[@]}"; do
    formula=${pair%%:*}
    lib=${pair#*:}
    prefix=$(brew --prefix --installed "$formula" 2>/dev/null) \
      || die "$lib: Homebrew's $formula is not installed; a distributed build carries every driver (brew install $formula)"
    [ -f "$prefix/lib/$lib" ] || die "$lib: not found in $prefix/lib (brew reinstall $formula)"
    # Homebrew installs libraries read-only, and install_name_tool and codesign rewrite them.
    cp "$prefix/lib/$lib" "$fw/$lib"
    chmod u+w "$fw/$lib"
    install_name_tool -id "@rpath/$lib" "$fw/$lib"

    # The opt link resolves to the keg actually installed; its name is the version, with any
    # Homebrew revision (_1) after it. The source URL brew reports is the formula's current one,
    # so the two must agree or drivers.json would name source that did not build this binary.
    keg=$(cd "$prefix" && pwd -P)
    installed=$(basename "$keg")
    info=$(brew info --json=v2 "$formula") || die "$lib: brew info --json=v2 $formula failed"
    # JavaScript for Automation ships with every Mac; jq and python3 do not.
    fields=$(osascript -l JavaScript - "$info" 2>&1 <<'JS'
function run(argv) {
  const f = JSON.parse(argv[0]).formulae[0];
  const src = (f.urls && f.urls.stable) || {};
  return [f.name, f.versions.stable || "", src.url || "", src.checksum || ""].join("|");
}
JS
    ) || die "$lib: could not read brew info for $formula: $fields"
    IFS="|" read -r name version url sha <<<"$fields"
    [ "${installed%_*}" = "$version" ] \
      || die "$lib: $formula $installed is installed but the formula is at $version, so its source URL is not this build's (brew upgrade $formula)"
    [ -n "$url" ] && [ -n "$sha" ] || die "$lib: brew info gives no source URL and SHA-256 for $formula"
    entries+=("$(printf '    {"library": "%s", "formula": "%s", "version": "%s", "source_url": "%s", "sha256": "%s"}' \
      "$lib" "$name" "$version" "$url" "$sha")")
  done

  # Each library's references to the other two, wherever Homebrew put them, become the copy beside
  # it. The id (otool's first entry after the file name) is skipped; it was rewritten above.
  for lib in "${names[@]}"; do
    while read -r dep; do
      for name in "${names[@]}"; do
        if [ "$(basename "$dep")" = "$name" ]; then
          install_name_tool -change "$dep" "@loader_path/$name" "$fw/$lib"
        fi
      done
    done < <(otool -L "$fw/$lib" | tail -n +3 | awk '{print $1}')
    if otool -L "$fw/$lib" | tail -n +2 | grep -Eq '/opt/homebrew|/usr/local'; then
      die "$lib still links into Homebrew after rewriting: $(otool -L "$fw/$lib" | tail -n +2 | grep -E '/opt/homebrew|/usr/local' | awk '{print $1}' | xargs)"
    fi
  done

  { printf '{\n  "drivers": [\n'
    local i
    for i in "${!entries[@]}"; do
      if [ "$i" -gt 0 ]; then printf ',\n'; fi
      printf '%s' "${entries[$i]}"
    done
    printf '\n  ]\n}\n'
  } > "$1/Contents/Resources/drivers.json"
}

with_daemon=0
[ "${1:-}" = "--with-daemon" ] && with_daemon=1
identity=${CODESIGN_IDENTITY:--}

version=$(tr -d '[:space:]' < VERSION)
build=$(git describe --tags --always --dirty --match 'v*' --abbrev=7 2>/dev/null || echo dev)
# Sparkle compares CFBundleVersion between builds, so it is a number that only grows; the describe
# string, which names the tree, goes in LeylineBuild for the about panel and bug reports.
build_number=$(git rev-list --count HEAD 2>/dev/null || echo 0)
gobin=${BUNDLE_GOBIN:-go/bin}

echo "==> swift build -c release (app/)"
(cd app && swift build -c release --product LeylineApp)
bin=$(cd app && swift build -c release --show-bin-path)

out=${BUNDLE_OUT:-app/dist/Leyline.app}
case "$out" in *.app) ;; *) die "BUNDLE_OUT must name a .app bundle, not $out" ;; esac
rm -rf "$out"
mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
sed -e "s/__VERSION__/$version/" -e "s/__BUILD__/$build_number/" -e "s/__BUILD_DESCRIBE__/$build/" \
  app/Sources/LeylineApp/Info.plist > "$out/Contents/Info.plist"
printf 'APPL????' > "$out/Contents/PkgInfo"
cp "$bin/LeylineApp" "$out/Contents/MacOS/LeylineApp"
# The app links Sparkle, which SwiftPM leaves beside the executable as a framework. In a bundle it
# lives in Contents/Frameworks, and the executable needs an rpath that reaches it there.
[ -d "$bin/Sparkle.framework" ] || die "no Sparkle.framework in $bin; the release build should have put it there"
mkdir -p "$out/Contents/Frameworks"
ditto "$bin/Sparkle.framework" "$out/Contents/Frameworks/Sparkle.framework"
otool -l "$out/Contents/MacOS/LeylineApp" | grep -q '@executable_path/../Frameworks' \
  || install_name_tool -add_rpath @executable_path/../Frameworks "$out/Contents/MacOS/LeylineApp"
# SwiftPM resource bundles sit beside the executable; in the app they go in Contents/Resources,
# which is where LeylineClient's ResourceBundle looks first for the band table. SwiftPM's own
# Bundle.module accessor does not look there, so a bundle missing from it would leave the app
# without its bands on every Mac but this one; the check makes that a failed build instead.
for b in "$bin"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$out/Contents/Resources/"; done
[ -f "$out/Contents/Resources/LeylineApp_LeylineClient.bundle/bands.json" ] \
  || die "$out/Contents/Resources has no LeylineApp_LeylineClient.bundle/bands.json; the app would have no band table (make bands-json, then build again)"
# The icon is drawn at bundle time rather than checked in (docs/design/brand/README.md);
# Info.plist names it as CFBundleIconFile. Without iconutil the bundle gets the generic icon.
if command -v iconutil >/dev/null 2>&1; then
  echo "==> icon (scripts/render-icon.swift)"
  icondir=app/.build/icon
  mkdir -p "$icondir"
  swift scripts/render-icon.swift "$icondir" >/dev/null
  cp "$icondir/AppIcon.icns" "$out/Contents/Resources/AppIcon.icns"
else
  echo "==> icon skipped: iconutil is not on this machine; the bundle has the generic icon"
fi

if [ $with_daemon -eq 1 ]; then
  echo "==> helpers: leylined, ley, decoders"
  # leylined reports the version compiled into it, and the app restarts a daemon whose version
  # differs from CFBundleShortVersionString (DaemonAgent.sameBuild), so a constant left behind by
  # a VERSION bump would restart the daemon on every launch. Regenerating it here changes nothing
  # when it is current.
  ./scripts/gen-version.sh >/dev/null
  (cd engine && swift build -c release --product leylined >/dev/null)
  ebin=$(cd engine && swift build -c release --show-bin-path)
  # Contents/Helpers holds code only: codesign treats every file there as a nested code object
  # and fails on an unsigned one, so manifests and licence texts go under Contents/Resources.
  # leylined reads the manifests from Resources/decoders and finds their executables beside itself.
  mkdir -p "$out/Contents/Helpers" "$out/Contents/Resources/decoders" "$out/Contents/Resources/licenses"
  cp "$ebin/leylined" "$out/Contents/Helpers/"
  if [ ! -x "$gobin/ley" ]; then
    [ -z "${BUNDLE_GOBIN:-}" ] || die "no ley in BUNDLE_GOBIN ($gobin)"
    make go >/dev/null
  fi
  cp "$gobin/ley" "$out/Contents/Helpers/"
  for d in decoders/*/; do
    name=$(basename "$d")
    mkdir -p "$out/Contents/Resources/decoders/$name"
    cp "$d"/*.json "$out/Contents/Resources/decoders/$name/" 2>/dev/null || true
    [ -x "$gobin/leydec-$name" ] && cp "$gobin/leydec-$name" "$out/Contents/Helpers/"
  done
  # The GPL engine travels with its licence text and the source offer (docs/decisions/D2-licensing.md).
  cp engine/LICENSE "$out/Contents/Resources/licenses/LICENSE.leylined"
  cp third_party/licenses/librtlsdr.txt "$out/Contents/Resources/licenses/"
  cp third_party/licenses/libhackrf.txt "$out/Contents/Resources/licenses/"
  cp third_party/licenses/libusb.txt "$out/Contents/Resources/licenses/"
  # A non-executable file left in Helpers would fail the signature check at the end; say which.
  stray=$(find "$out/Contents/Helpers" -type f ! -perm -u+x)
  [ -z "$stray" ] || die "Contents/Helpers may hold only executables; found: $stray"
  bundle_drivers "$out"
  # The app registers this agent through SMAppService; its BundleProgram is Contents/Helpers/leylined.
  mkdir -p "$out/Contents/Library/LaunchAgents"
  cp app/Sources/LeylineApp/com.leysdr.daemon.plist "$out/Contents/Library/LaunchAgents/"
fi
cp LICENSE NOTICE "$out/Contents/Resources/"

echo "==> codesign ($identity)"
sign_opts=(--force --sign "$identity" --timestamp=none)
[ "$identity" != "-" ] && sign_opts=(--force --sign "$identity" --options runtime --timestamp)
# Inside out, each piece on its own and never with --deep, which would sign Sparkle's helpers
# without the hardened runtime and strip Downloader.xpc's entitlements: Sparkle's XPC services, its
# Autoupdate and Updater.app, the framework; the libraries the helpers load; the helpers; the app.
# Sparkle's order and the entitlements Downloader.xpc keeps are Sparkle's own instructions
# ("Sandboxing" and "Code signing" in its documentation).
sparkle="$out/Contents/Frameworks/Sparkle.framework"
codesign "${sign_opts[@]}" "$sparkle/Versions/B/XPCServices/Installer.xpc"
codesign "${sign_opts[@]}" --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
codesign "${sign_opts[@]}" "$sparkle/Versions/B/Autoupdate"
codesign "${sign_opts[@]}" "$sparkle/Versions/B/Updater.app"
codesign "${sign_opts[@]}" "$sparkle"
if [ $with_daemon -eq 1 ]; then
  find "$out/Contents/Frameworks" -maxdepth 1 -type f -name '*.dylib' -exec codesign "${sign_opts[@]}" {} \;
  find "$out/Contents/Helpers" -type f -perm -u+x -exec codesign "${sign_opts[@]}" {} \;
fi
codesign "${sign_opts[@]}" "$out"
codesign --verify --deep --strict "$out"
echo "$out ($version, build $build_number, $build). Open it with: open $out"
