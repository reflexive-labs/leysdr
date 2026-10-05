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
#                                commit it was built from is on GitHub. When the tag v<VERSION>
#                                exists locally (make alpha makes it before the build) it must
#                                point at that commit and be pushed, and the release uses it.
#   scripts/release.sh rehearse <dir>
#                                (make release-rehearse) the tree as it is, whatever its VERSION,
#                                as an ad-hoc-signed Leyline.app and Leyline-<VERSION>.dmg in
#                                <dir>: the release's build without its credentials, which
#                                `make alpha DRY_RUN=1` runs
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

# changelog_has_section <version> <file>: whether <file> has a `## <version>` heading, with a
# date or anything else after a space (`## 0.1.0-alpha.1 (2026-10-05)`, as make alpha writes it),
# and `## [<version>]` or `## v<version>` counting too, as scripts/release-appcast.sh reads them.
changelog_has_section() {
  grep -Eq "^## \[?v?${1//./\\.}\]?([[:space:]]|$)" "$2"
}

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

# build_app <version> <work> <identity> <app>: ley and the decoders for the one architecture the
# alpha ships, stamped with the bare version, then the bundle at <app> signed by <identity> ("-"
# for ad hoc) and verified. Not go/bin, which holds whatever the last `make go` built.
build_app() {
  local version=$1 gobin=$2/gobin identity=$3 app=$4 d name
  mkdir -p "$gobin"
  echo "==> go build (darwin/arm64): ley, leydec-*"
  (cd go && GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -trimpath \
    -ldflags "-X github.com/reflexive-labs/leysdr/go/internal/cli.Version=$version" \
    -o "$gobin/" ./cmd/ley ./cmd/leydec-*)
  for d in decoders/*/; do
    name=$(basename "$d")
    [ -x "$gobin/leydec-$name" ] || die "decoders/$name has no go/cmd/leydec-$name to build"
  done

  BUNDLE_GOBIN=$gobin BUNDLE_OUT=$app CODESIGN_IDENTITY=$identity ./scripts/bundle-app.sh --with-daemon
  echo "==> codesign --verify --strict --deep"
  codesign --verify --strict --deep --verbose=2 "$app"
}

# make_dmg <app> <dmg> <version> <stage>: the disk image holding the app and an /Applications
# link, unsigned.
make_dmg() {
  echo "==> $2"
  mkdir -p "$4"
  ditto "$1" "$4/Leyline.app"
  ln -s /Applications "$4/Applications"
  hdiutil create -volname "Leyline $3" -srcfolder "$4" -format UDZO -ov "$2"
}

# rehearse <version> <dir>: build_app and make_dmg, ad hoc, into <dir>; nothing is notarized,
# published or written outside <dir>.
rehearse() {
  local version=$1 out=$2
  [ ! -e "$out" ] || [ -z "$(ls -A "$out")" ] || die "$out is not empty; name a new directory"
  work=$(mktemp -d "${TMPDIR:-/tmp}/leyline-rehearse.XXXXXX")
  trap 'rm -rf "$work"' EXIT
  mkdir -p "$out"
  build_app "$version" "$work" - "$out/Leyline.app"
  make_dmg "$out/Leyline.app" "$out/Leyline-$version.dmg" "$version" "$work/dmg"
  echo "$out:"
  ls -l "$out"
}

# build: the release, from the Go build to the appcast.
build() {
  local version=$1 out=$2 identity app dmg json id status stage d tagged
  identity=${CODESIGN_IDENTITY:-}
  [ -n "$identity" ] && [ "$identity" != "-" ] \
    || die "CODESIGN_IDENTITY must name the Developer ID Application identity (security find-identity -v -p codesigning)"
  [ -n "${NOTARY_PROFILE:-}" ] || die "NOTARY_PROFILE must name the notarytool keychain profile (xcrun notarytool store-credentials)"
  security find-identity -v -p codesigning | grep -qF "\"$identity\"" \
    || die "no valid signing identity \"$identity\" in the keychain"
  [ "$(engine_version engine/Sources/LeylineDaemon/Version.swift)" = "$version" ] \
    || die "engine/Sources/LeylineDaemon/Version.swift does not say $version; run make version and commit it"
  changelog_has_section "$version" CHANGELOG.md \
    || die "CHANGELOG.md has no \`## $version\` section, which the update's release notes come from"
  [ ! -e "$out" ] || die "$out already exists; a version is released once (remove it to build this version again)"
  # make alpha tags before it builds, so the bundle's git describe (LeylineBuild, the about panel)
  # is the tag. A tag on another commit means this tree is not the release it names.
  tagged=$(git rev-parse -q --verify "refs/tags/v$version^{commit}" || true)
  [ -z "$tagged" ] || [ "$tagged" = "$(git rev-parse HEAD)" ] \
    || die "the tag v$version points at ${tagged:0:12}, not HEAD; check out that commit to build it"

  # A release that stops part way leaves no dist/<VERSION>/ behind, so it can be run again.
  work=$(mktemp -d "${TMPDIR:-/tmp}/leyline-release.XXXXXX")
  mnt=
  partial=$out
  trap 'if [ -n "$mnt" ]; then hdiutil detach -quiet "$mnt" || true; fi; rm -rf "$work" "$partial"' EXIT

  # The tree is clean and the release's tag points, or will point, at this commit, so the Go
  # helpers carry the bare version.
  app=app/dist/Leyline.app
  build_app "$version" "$work" "$identity" "$app"

  mkdir -p "$out"
  dmg=$out/Leyline-$version.dmg
  make_dmg "$app" "$dmg" "$version" "$work/dmg"
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
# A local tag v<version> (make alpha's) is the release's tag: it must name that commit and be on
# origin, and gh is told to use it rather than make one.
publish() {
  local version=$1 out=$2 commit asset tagged assets=() target=()
  [ -f "$out/commit" ] || die "$out has no release; make it first with: make release"
  commit=$(cat "$out/commit")
  while IFS= read -r asset; do
    [ -f "$asset" ] || die "$asset is missing; make the release again with: make release"
    assets+=("$asset")
  done < <(release_assets "$out" "$version")
  git fetch --quiet origin || die "git fetch origin failed"
  [ -n "$(git branch -r --contains "$commit")" ] \
    || die "commit ${commit:0:12} is not on GitHub yet, and the release's tag must point at it; push it first with: git push"
  tagged=$(git rev-parse -q --verify "refs/tags/v$version^{commit}" || true)
  if [ -n "$tagged" ]; then
    [ "$tagged" = "$commit" ] \
      || die "the tag v$version points at ${tagged:0:12}, but $out was built from ${commit:0:12}; build it again from the tag with: make release"
    git ls-remote --exit-code --tags origin "refs/tags/v$version" >/dev/null \
      || die "the tag v$version is not on GitHub yet; push it first with: git push origin v$version"
    target=(--verify-tag)
  else
    target=(--target "$commit")
  fi
  echo "==> gh release create v$version (prerelease, ${#assets[@]} assets, at ${commit:0:12})"
  gh release create "v$version" --repo "$REPO" --prerelease --title "Leyline $version" \
    --notes-file "$out/notes.md" "${target[@]}" "${assets[@]}"
}

main() {
  local version refusal out
  [ "$(uname -s)" = Darwin ] || die "a release is signed and notarized on the Mac; run it there"
  [ "$(uname -m)" = arm64 ] || die "the alpha ships Apple silicon only; build it on an Apple silicon Mac"
  version=$(tr -d '[:space:]' < VERSION)
  if [ "${1:-}" = rehearse ]; then
    [ $# -eq 2 ] || { echo "usage: scripts/release.sh rehearse <dir>" >&2; exit 2; }
    rehearse "$version" "$2"
    return
  fi
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
    *) echo "usage: scripts/release.sh [publish | rehearse <dir>]" >&2; exit 2 ;;
  esac
}

# Sourced by scripts/test-release.sh, which tests the functions above without a Mac.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
