#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Builds, signs, notarizes and packages a release of the app, and publishes it as a GitHub
# prerelease. docs/plans/distribution.md, "Sign, notarize, package", is the specification and
# docs/dev/release-checklist.md the pass around it.
#
#   scripts/release.sh           (make release) dist/<VERSION>/: the notarized Leyline-<VERSION>.dmg,
#                                the source tarballs the release owes, drivers.json, appcast.xml
#   scripts/release.sh publish   (make release-publish) the GitHub prerelease v<VERSION> on
#                                reflexive-labs/leysdr from dist/<VERSION>/, refused until the
#                                commit it was built from is on GitHub
#
# CODESIGN_IDENTITY is the Developer ID Application identity's full name and NOTARY_PROFILE the
# `xcrun notarytool store-credentials` keychain profile; neither has a default here. The Sparkle
# EdDSA key is read from the login keychain by scripts/release-appcast.sh.
#
# A release is made from a clean tree whose VERSION is a release's (no -dev), once: an existing
# dist/<VERSION>/ stops it, because a second DMG under one version would be a different update
# with the same name. Earlier versions' directories stay in dist/, because the appcast lists every
# DMG found there.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
# The scratch directory, a mounted DMG and an unfinished dist/<VERSION>/, for the EXIT trap.
work=
mnt=
partial=

# The feed and the DMGs it names are served from here (docs/plans/distribution.md, OWN-4).
DOWNLOAD_URL_PREFIX=https://leysdr.com/updates/
REPO=reflexive-labs/leysdr

die() { echo "release.sh: $*" >&2; exit 1; }

# release_version_refusal <version>: why <version> cannot be released, or nothing. A -dev version
# is what the tree carries between releases, and every release changes VERSION
# (docs/plans/distribution.md, "Decisions").
release_version_refusal() {
  case "$1" in
    "") echo "VERSION is empty" ;;
    *-dev | *-dev+* | *-dev.*) echo "VERSION is $1; bump it to this release's version (0.1.0-alpha.N) and commit" ;;
    # A + would read as build metadata, which DaemonAgent.sameBuild compares with CFBundleVersion.
    *[!0-9A-Za-z.-]*) echo "VERSION $1 may hold only letters, digits, dots and hyphens" ;;
  esac
}

# engine_version <Version.swift>: the string leylined reports, as scripts/gen-version.sh wrote it.
engine_version() {
  sed -n 's/^let leylinedVersion = "\(.*\)"$/\1/p' "$1"
}

# driver_sources <drivers.json>: one line per driver, "<file name>|<url>|<sha256>". The file is the
# one bundle-app.sh writes, one driver object per line; the name is <formula>-<version> with the
# URL's archive extension, because the URLs' own names (v2.0.2.tar.gz) collide and do not say what
# they hold.
driver_sources() {
  local line formula version url sha ext
  while IFS= read -r line; do
    case "$line" in *'"source_url"'*) ;; *) continue ;; esac
    formula=$(printf '%s' "$line" | sed -n 's/.*"formula": *"\([^"]*\)".*/\1/p')
    version=$(printf '%s' "$line" | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p')
    url=$(printf '%s' "$line" | sed -n 's/.*"source_url": *"\([^"]*\)".*/\1/p')
    sha=$(printf '%s' "$line" | sed -n 's/.*"sha256": *"\([^"]*\)".*/\1/p')
    [ -n "$formula" ] && [ -n "$version" ] && [ -n "$url" ] && [ -n "$sha" ] \
      || { echo "release.sh: a driver in $1 lacks a formula, version, source_url or sha256: $line" >&2; return 1; }
    case "$url" in
      *.tar.gz) ext=tar.gz ;;
      *.tar.bz2) ext=tar.bz2 ;;
      *.tar.xz) ext=tar.xz ;;
      *.tgz) ext=tgz ;;
      *.zip) ext=zip ;;
      *) ext=source ;;
    esac
    printf '%s-%s-source.%s|%s|%s\n' "$formula" "$version" "$ext" "$url" "$sha"
  done < "$1"
}

# fetch_driver_sources <drivers.json> <dir>: downloads each driver's source into <dir> and checks
# it against the SHA-256 Homebrew recorded, so the tarball offered is the one that built the
# binary (docs/decisions/D2-licensing.md, "Distribution obligations").
fetch_driver_sources() {
  local sources name url sha got
  sources=$(driver_sources "$1") || return 1
  [ -n "$sources" ] || { echo "release.sh: $1 lists no drivers" >&2; return 1; }
  while IFS="|" read -r name url sha; do
    echo "==> source: $name ($url)"
    curl -fsSL --retry 3 -o "$2/$name" "$url" || { echo "release.sh: could not download $url" >&2; return 1; }
    got=$(shasum -a 256 "$2/$name" | awk '{print $1}')
    [ "$got" = "$sha" ] || { echo "release.sh: $name has SHA-256 $got; drivers.json says $sha" >&2; return 1; }
  done <<<"$sources"
}

# release_assets <dir> <version>: every file the GitHub release carries, one per line.
release_assets() {
  local name
  printf '%s\n' "$1/Leyline-$2.dmg" "$1/leysdr-$2-source.tar.gz"
  driver_sources "$1/drivers.json" | while IFS="|" read -r name _; do printf '%s\n' "$1/$name"; done
  printf '%s\n' "$1/drivers.json" "$1/appcast.xml"
}

# build: the release, from the Go build to the appcast.
build() {
  local version=$1 out=$2 identity gobin name app dmg json id status stage d
  identity=${CODESIGN_IDENTITY:-}
  [ -n "$identity" ] && [ "$identity" != "-" ] \
    || die "CODESIGN_IDENTITY must name the Developer ID Application identity (security find-identity -v -p codesigning)"
  [ -n "${NOTARY_PROFILE:-}" ] || die "NOTARY_PROFILE must name the notarytool keychain profile (xcrun notarytool store-credentials)"
  security find-identity -v -p codesigning | grep -qF "\"$identity\"" \
    || die "no valid signing identity \"$identity\" in the keychain"
  [ "$(engine_version engine/Sources/LeylineDaemon/Version.swift)" = "$version" ] \
    || die "engine/Sources/LeylineDaemon/Version.swift does not say $version; run make version and commit it"
  grep -Eq "^## \[?v?${version//./\\.}\]?([[:space:]]|$)" CHANGELOG.md \
    || die "CHANGELOG.md has no \`## $version\` section, which the update's release notes come from"
  [ ! -e "$out" ] || die "$out already exists; a version is released once (remove it to build this version again)"

  # A release that stops part way leaves no dist/<VERSION>/ behind, so it can be run again.
  work=$(mktemp -d "${TMPDIR:-/tmp}/leyline-release.XXXXXX")
  mnt=
  partial=$out
  trap 'if [ -n "$mnt" ]; then hdiutil detach -quiet "$mnt" || true; fi; rm -rf "$work" "$partial"' EXIT

  # The Go helpers, built for the one architecture the alpha ships, stamped with the bare version:
  # the tree is clean and the release's tag will point at this commit. Not go/bin, which holds
  # whatever the last `make go` built.
  gobin=$work/gobin
  mkdir -p "$gobin"
  echo "==> go build (darwin/arm64): ley, leydec-*"
  (cd go && GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -trimpath \
    -ldflags "-X github.com/reflexive-labs/leysdr/go/internal/cli.Version=$version" \
    -o "$gobin/" ./cmd/ley ./cmd/leydec-*)
  for d in decoders/*/; do
    name=$(basename "$d")
    [ -x "$gobin/leydec-$name" ] || die "decoders/$name has no go/cmd/leydec-$name to build"
  done

  BUNDLE_GOBIN=$gobin CODESIGN_IDENTITY=$identity ./scripts/bundle-app.sh --with-daemon
  app=app/dist/Leyline.app
  echo "==> codesign --verify --strict --deep"
  codesign --verify --strict --deep --verbose=2 "$app"

  mkdir -p "$out"
  dmg=$out/Leyline-$version.dmg
  echo "==> $dmg"
  stage=$work/dmg
  mkdir -p "$stage"
  ditto "$app" "$stage/Leyline.app"
  ln -s /Applications "$stage/Applications"
  hdiutil create -volname "Leyline $version" -srcfolder "$stage" -format UDZO -ov "$dmg"
  codesign --force --sign "$identity" --timestamp "$dmg"

  echo "==> notarytool submit (profile $NOTARY_PROFILE); this waits for Apple"
  json=$work/notary.json
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$json" || true
  id=$(plutil -extract id raw -o - "$json" 2>/dev/null || true)
  status=$(plutil -extract status raw -o - "$json" 2>/dev/null || true)
  if [ "$status" != Accepted ]; then
    cat "$json" >&2
    if [ -n "$id" ]; then
      echo "--- notarytool log $id" >&2
      xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fi
    die "notarization ${status:-did not complete} for $dmg"
  fi
  xcrun stapler staple "$dmg"

  echo "==> spctl"
  spctl -a -t open --context context:primary-signature -v "$dmg"
  mnt=$work/mnt
  mkdir -p "$mnt"
  hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$dmg" >/dev/null
  spctl -a -vvv "$mnt/Leyline.app"
  hdiutil detach -quiet "$mnt"
  mnt=

  # The source the release owes (docs/decisions/D2-licensing.md, "Distribution obligations"): this
  # commit's tree, and each driver library's as Homebrew built it.
  echo "==> source: leysdr-$version-source.tar.gz"
  git archive --format=tar.gz --prefix="leysdr-$version/" -o "$out/leysdr-$version-source.tar.gz" HEAD
  cp "$app/Contents/Resources/drivers.json" "$out/drivers.json"
  fetch_driver_sources "$out/drivers.json" "$out" || die "the driver sources could not be fetched"
  git rev-parse HEAD > "$out/commit"

  # generate_appcast reads one directory, so every release's DMG is linked into one; the feed then
  # lists earlier versions too. Delta updates are off: they would be more files to serve.
  stage=$work/appcast
  mkdir -p "$stage"
  for d in dist/*/Leyline-*.dmg; do
    ln "$d" "$stage/" 2>/dev/null || cp "$d" "$stage/"
  done
  ./scripts/release-appcast.sh "$stage" --download-url-prefix "$DOWNLOAD_URL_PREFIX" --maximum-deltas 0
  cp "$stage/appcast.xml" "$out/appcast.xml"
  cp "$stage/Leyline-$version.md" "$out/notes.md"
  partial=
  echo "$out:"
  ls -l "$out"
}

# publish: the GitHub prerelease, the way `leyshots publish` makes a shots-* release. GitHub can
# only tag a commit it has, so the commit the release was built from must be on a branch of origin.
publish() {
  local version=$1 out=$2 commit asset assets=()
  [ -f "$out/commit" ] || die "$out has no release; make it first with: make release"
  commit=$(cat "$out/commit")
  while IFS= read -r asset; do
    [ -f "$asset" ] || die "$asset is missing; make the release again with: make release"
    assets+=("$asset")
  done < <(release_assets "$out" "$version")
  git fetch --quiet origin || die "git fetch origin failed"
  [ -n "$(git branch -r --contains "$commit")" ] \
    || die "commit ${commit:0:12} is not on GitHub yet, and the release's tag must point at it; push it first with: git push"
  echo "==> gh release create v$version (prerelease, ${#assets[@]} assets, at ${commit:0:12})"
  gh release create "v$version" --repo "$REPO" --prerelease --title "Leyline $version" \
    --notes-file "$out/notes.md" --target "$commit" "${assets[@]}"
}

main() {
  local version refusal out
  [ "$(uname -s)" = Darwin ] || die "a release is signed and notarized on the Mac; run it there"
  [ "$(uname -m)" = arm64 ] || die "the alpha ships Apple silicon only; build it on an Apple silicon Mac"
  version=$(tr -d '[:space:]' < VERSION)
  refusal=$(release_version_refusal "$version")
  [ -z "$refusal" ] || die "$refusal"
  out=$ROOT/dist/$version
  case "${1:-build}" in
    build)
      [ -z "$(git status --porcelain)" ] \
        || die "the tree has changes, which the release would ship without its source tarball holding them; commit or stash them"
      build "$version" "$out"
      ;;
    publish) publish "$version" "$out" ;;
    *) echo "usage: scripts/release.sh [publish]" >&2; exit 2 ;;
  esac
}

# Sourced by scripts/test-release.sh, which tests the functions above without a Mac.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
