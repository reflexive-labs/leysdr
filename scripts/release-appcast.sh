#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Writes the Sparkle appcast for a directory of notarized DMGs: Sparkle's generate_appcast reads
# each DMG's Info.plist, signs it with the EdDSA key in the login keychain (Sparkle's
# generate_keys put it there), and writes <dir>/appcast.xml. docs/plans/distribution.md, "Sparkle".
#
#   scripts/release-appcast.sh <dir> [generate_appcast option…]
#
# Every DMG is named Leyline-<version>.dmg. Its release notes are the `## <version>` section of
# CHANGELOG.md (make alpha writes `## <version> (<date>)`; anything after the version is ignored,
# and a heading of `## [<version>]` or `## v<version>` counts too), written beside it as
# Leyline-<version>.md and embedded in the appcast, so a tester reads in the update dialog what
# the changelog says. A DMG whose version has no section stops the script: an update without
# notes is a step the release checklist missed.
#
# SPARKLE_BIN names the directory holding generate_appcast; unset, it is the copy SwiftPM
# downloads with the package (app/.build/artifacts/sparkle/Sparkle/bin, after `swift build` or
# `swift package resolve` in app/). Options after the directory go to generate_appcast unchanged:
# --download-url-prefix when the DMGs are served somewhere other than beside the appcast,
# --account when the key is not the keychain's default `ed25519` entry.
set -euo pipefail

# notes_for <version> [changelog]: the section of the changelog (default CHANGELOG.md) for one
# version, without its heading or the blank lines around it; nothing when there is no such section.
notes_for() {
  awk -v want="$1" '
    /^## / {
      if (inside) exit
      h = $2; gsub(/^\[|\]$/, "", h); sub(/^v/, "", h)
      if (h == want) { inside = 1; next }
    }
    inside { lines[++n] = $0 }
    END {
      first = 1; while (first <= n && lines[first] ~ /^[[:space:]]*$/) first++
      last = n; while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
      for (i = first; i <= last; i++) print lines[i]
    }
  ' "${2:-CHANGELOG.md}"
}

main() {
  local root dir bin gen found dmg name version notes
  cd "$(dirname "$0")/.."
  root=$PWD
  [ "$(uname -s)" = Darwin ] || { echo "release-appcast.sh runs Sparkle's macOS tools; run it on the Mac" >&2; exit 2; }

  [ $# -ge 1 ] || { echo "usage: scripts/release-appcast.sh <dir of DMGs> [generate_appcast option…]" >&2; exit 2; }
  dir=$1
  shift
  [ -d "$dir" ] || { echo "release-appcast.sh: $dir is not a directory" >&2; exit 2; }

  bin=${SPARKLE_BIN:-$root/app/.build/artifacts/sparkle/Sparkle/bin}
  gen=$bin/generate_appcast
  [ -x "$gen" ] || {
    echo "release-appcast.sh: no generate_appcast at $gen; run \`swift package resolve\` in app/ or set SPARKLE_BIN" >&2
    exit 2
  }

  found=0
  for dmg in "$dir"/Leyline-*.dmg; do
    [ -e "$dmg" ] || continue
    found=1
    name=$(basename "$dmg" .dmg)
    version=${name#Leyline-}
    notes=$(notes_for "$version")
    [ -n "$notes" ] || { echo "release-appcast.sh: CHANGELOG.md has no \`## $version\` section for $(basename "$dmg")" >&2; exit 1; }
    printf '%s\n' "$notes" > "$dir/$name.md"
    echo "==> $name: notes from CHANGELOG.md ($(printf '%s\n' "$notes" | wc -l | tr -d ' ') lines)"
  done
  [ $found -eq 1 ] || { echo "release-appcast.sh: no Leyline-<version>.dmg in $dir" >&2; exit 1; }

  echo "==> generate_appcast ($gen)"
  "$gen" --embed-release-notes -o "$dir/appcast.xml" ${@+"$@"} "$dir"
  echo "$dir/appcast.xml"
}

# Sourced by scripts/test-release.sh, which tests notes_for without a Mac.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
