#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Cuts the next alpha of the app from start to finish (make alpha), so no step of
# docs/dev/release-checklist.md, "The signed build", depends on being remembered:
#
#   1. preflight: on main, a clean tree not behind origin/main, Homebrew's drivers (installed when
#      missing), Xcode's tools and Go, the signing identity, the notary profile, GitHub access, and
#      notes under the CHANGELOG's `## Unreleased`
#   2. the version: the next alpha after VERSION (`X-dev` is followed by `X-alpha.1`, `X-alpha.N`
#      by `X-alpha.N+1`), or NEXT; it and its notes are shown and confirmed unless YES=1
#   3. VERSION, `make version`, and `## Unreleased` dated as `## <version> (<YYYY-MM-DD>)` under a
#      new, empty `## Unreleased`
#   4. the commit `release: <version>` and the annotated tag v<version>, both before the build, so
#      the bundle's git describe (LeylineBuild, the about panel) is the tag
#   5. make release
#   6. main and the tag pushed, then make release-publish
#   7. what is left for a person: the second Mac's checks and the site's pull request
#
# A run that stops after step 4 is carried on by running it again: HEAD is the release commit,
# tagged, so nothing is bumped twice; a complete dist/<version>/ is reused and a partial one built
# again; a GitHub release that exists is not published again.
#
# DRY_RUN=1 is a rehearsal: the preflight that needs no credentials, the version, and an
# ad-hoc-signed app and DMG of the tree as it is (make release-rehearse) in a new temporary
# directory. VERSION, CHANGELOG.md, the commits, tags, origin and GitHub are left alone.
#
# CODESIGN_IDENTITY and NOTARY_PROFILE come from the Makefile's defaults. MAKE names the make it
# calls back into, `make` when unset.
set -euo pipefail
cd "$(dirname "$0")/.."
# release_version_refusal, release_assets and REPO; notes_for, which reads a CHANGELOG section.
# shellcheck source=release.sh
. "$(dirname "${BASH_SOURCE[0]}")/release.sh"
# shellcheck source=release-appcast.sh
. "$(dirname "${BASH_SOURCE[0]}")/release-appcast.sh"

FORMULAS=(librtlsdr hackrf libusb)

die() { echo "alpha: $*" >&2; exit 1; }
say() { echo "==> $*"; }

# truthy <value>: set to anything but nothing, 0, no or false.
truthy() {
  case "${1:-}" in "" | 0 | no | false | NO | FALSE) return 1 ;; *) return 0 ;; esac
}

# next_version <version>: the alpha after <version>, or a failure when <version> is neither
# `X-dev` nor `X-alpha.N`.
next_version() {
  local n
  case "$1" in
    ?*-dev) echo "${1%-dev}-alpha.1" ;;
    ?*-alpha.*)
      n=${1##*-alpha.}
      [[ $n =~ ^[0-9]+$ ]] || return 1
      echo "${1%-alpha.*}-alpha.$((10#$n + 1))"
      ;;
    *) return 1 ;;
  esac
}

# unreleased_notes <changelog>: the `## Unreleased` section's text, trimmed of blank lines at
# either end; nothing when the section is missing or empty.
unreleased_notes() {
  notes_for Unreleased "$1"
}

# changelog_cut <changelog> <version> <date>: `## Unreleased` becomes `## <version> (<date>)` under
# a new, empty `## Unreleased`. The first release also drops the line saying nothing has been
# released yet, with the blank line after it. Fails, leaving the file alone, without the heading.
changelog_cut() {
  local tmp
  tmp=$(mktemp)
  awk -v v="$2" -v d="$3" '
    !cut && /^Nothing has been released yet\./ { drop_blank = 1; next }
    drop_blank && /^[[:space:]]*$/ { drop_blank = 0; next }
    { drop_blank = 0 }
    !cut && /^## Unreleased[[:space:]]*$/ { print "## Unreleased"; print ""; print "## " v " (" d ")"; cut = 1; next }
    { print }
    END { if (!cut) exit 1 }
  ' "$1" > "$tmp" || { rm -f "$tmp"; return 1; }
  # cat > rather than mv keeps the file's mode and owner on a shared checkout.
  cat "$tmp" > "$1"
  rm -f "$tmp"
}

# resume_version: the version a stopped run left at HEAD, or status 1 when HEAD is not one. HEAD
# is the commit `release: <version>`, VERSION says <version>, and the tag v<version> is at HEAD or
# missing (the run stopped between commit and tag); a tag elsewhere is status 3, said on stderr.
resume_version() {
  local subject version tagged
  subject=$(git log -1 --format=%s 2>/dev/null) || return 1
  case "$subject" in "release: "?*) version=${subject#release: } ;; *) return 1 ;; esac
  [ "$(tr -d '[:space:]' < VERSION)" = "$version" ] || return 1
  tagged=$(git rev-parse -q --verify "refs/tags/v$version^{commit}" || true)
  [ -z "$tagged" ] || [ "$tagged" = "$(git rev-parse HEAD)" ] \
    || { echo "alpha: HEAD is the release commit for $version, but the tag v$version points at ${tagged:0:12}. Look at both with: git log --oneline --no-walk v$version HEAD" >&2; return 3; }
  echo "$version"
}

# dist_state <dir> <version>: complete when <dir> holds every asset the release publishes and was
# built from HEAD, partial when it exists otherwise, none when it does not.
dist_state() {
  local asset assets
  [ -e "$1" ] || { echo none; return; }
  [ -f "$1/commit" ] && [ "$(cat "$1/commit")" = "$(git rev-parse HEAD)" ] && [ -f "$1/notes.md" ] \
    || { echo partial; return; }
  assets=$(release_assets "$1" "$2" 2>/dev/null) || { echo partial; return; }
  while IFS= read -r asset; do
    [ -f "$asset" ] || { echo partial; return; }
  done <<<"$assets"
  echo complete
}

# preflight_repo: on main, a clean tree, not behind origin/main.
preflight_repo() {
  local branch behind
  branch=$(git symbolic-ref -q --short HEAD || true)
  [ "$branch" = main ] \
    || die "HEAD is ${branch:-detached}, and a release is cut from main. Switch with: git switch main"
  [ -z "$(git status --porcelain)" ] \
    || die "the tree has changes, which the release would ship without its source tarball holding them. Commit them, or set them aside with: git stash -u"
  say "git fetch origin main"
  git fetch --quiet origin main \
    || die "could not fetch origin, so whether main is behind it is unknown. Check the remote with: git fetch origin main"
  behind=$(git rev-list --count HEAD..origin/main)
  [ "$behind" -eq 0 ] \
    || die "main is $behind commit(s) behind origin/main, and the release must include them. Bring it up to date with: git pull --ff-only origin main"
}

# preflight_tools: Homebrew and the drivers the app carries (installed when missing), Xcode's
# command line tools, Go.
preflight_tools() {
  local f missing=()
  command -v brew >/dev/null 2>&1 \
    || die "Homebrew is not installed, and the app's driver libraries come from it. Install it with: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
  for f in "${FORMULAS[@]}"; do
    brew list --versions "$f" >/dev/null 2>&1 || missing+=("$f")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    say "brew install ${missing[*]} (the app carries them)"
    brew install "${missing[@]}" || die "brew could not install ${missing[*]}. Try it yourself with: brew install ${missing[*]}"
  fi
  xcode-select -p >/dev/null 2>&1 \
    || die "Xcode's command line tools are not installed. Install them with: xcode-select --install"
  command -v swift >/dev/null 2>&1 \
    || die "swift is not on the PATH. Install Xcode's command line tools with: xcode-select --install"
  command -v go >/dev/null 2>&1 || die "go is not on the PATH, and ley and the decoders are built with it. Install it with: brew install go"
}

# preflight_credentials: the signing identity, the notary profile, notarytool and stapler, GitHub
# access to the repository, and the Sparkle key when Sparkle's tools are already resolved.
preflight_credentials() {
  local team bin want got
  [ -n "${CODESIGN_IDENTITY:-}" ] && [ -n "${NOTARY_PROFILE:-}" ] \
    || die "CODESIGN_IDENTITY and NOTARY_PROFILE are not set. Run it as: make alpha"
  security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$CODESIGN_IDENTITY\"" \
    || die "the keychain has no valid signing identity \"$CODESIGN_IDENTITY\". Import the certificate's backup with: security import <file>.p12 -k ~/Library/Keychains/login.keychain-db"
  xcrun --find notarytool >/dev/null 2>&1 && xcrun --find stapler >/dev/null 2>&1 \
    || die "notarytool or stapler is missing from Xcode's tools. Install them with: xcode-select --install"
  team=$(printf '%s' "$CODESIGN_IDENTITY" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "the notary profile $NOTARY_PROFILE does not work. Store it again with: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <Apple ID> --team-id ${team:-<team ID>}"
  gh auth status >/dev/null 2>&1 \
    || die "gh is not signed in to GitHub. Sign in with: gh auth login"
  gh repo view "$REPO" --json name >/dev/null 2>&1 \
    || die "gh cannot see $REPO, where the release is published. Sign in as an account that can with: gh auth login"
  # generate_keys arrives with Sparkle when app/ is first built; before that, the appcast step is
  # the check.
  bin=app/.build/artifacts/sparkle/Sparkle/bin
  if [ -x "$bin/generate_keys" ]; then
    want=$(sed -n '/<key>SUPublicEDKey<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' app/Sources/LeylineApp/Info.plist)
    got=$("$bin/generate_keys" -p 2>/dev/null | tail -1 | tr -d '[:space:]' || true)
    [ "$got" = "$want" ] \
      || die "the keychain's Sparkle key is not the one Info.plist names, so installed copies would refuse the update. Import the backup with: $bin/generate_keys -f <backup file>"
  fi
}

# confirm <version>: y, or YES set, goes on; anything else stops with nothing changed.
confirm() {
  local answer=
  truthy "${YES:-}" && return 0
  read -r -p "Cut $1? [y/N] " answer || true
  case "$answer" in y | Y | yes | YES) ;; *) die "stopped before changing anything. Run again when ready, with YES=1 to skip this question: make alpha" ;; esac
}

# cut_release <version>: steps 3 and 4, the bump, the CHANGELOG, the commit and the tag.
cut_release() {
  local version=$1
  say "VERSION $version, make version, CHANGELOG.md"
  printf '%s\n' "$version" > VERSION
  "$MAKE" --no-print-directory version
  changelog_cut CHANGELOG.md "$version" "$(date +%Y-%m-%d)" \
    || die "CHANGELOG.md lost its \`## Unreleased\` heading. Undo the bump with: git checkout -- VERSION CHANGELOG.md engine go"
  say "commit release: $version, tag v$version"
  git commit --quiet -s -m "release: $version" -- VERSION CHANGELOG.md \
    engine/Sources/LeylineDaemon/Version.swift go/internal/cli/root.go
  git tag -a "v$version" -m "Leyline $version"
}

# dry_run <version>: the rehearsal's build, and what it left out.
dry_run() {
  local version=$1 current out
  current=$(tr -d '[:space:]' < VERSION)
  out=$(mktemp -d "${TMPDIR:-/tmp}/leyline-alpha-rehearsal.XXXXXX")
  say "make release-rehearse OUT=$out"
  "$MAKE" --no-print-directory release-rehearse OUT="$out"
  cat <<EOF

Rehearsal of $version done: $out holds an ad-hoc-signed Leyline.app and Leyline-$current.dmg,
built from the tree as it is, so they say $current, not $version.
Skipped: the signing identity, notary profile and GitHub checks; VERSION, \`make version\` and
the CHANGELOG; the commit and tag; the Developer ID signature, notarization and stapling; the
source tarballs and appcast; the push and the GitHub release. \`make alpha\` does all of them.
EOF
}

main() {
  local dry=0 resumed= rc=0 version current notes state out
  [ "$(uname -s)" = Darwin ] || die "a release is signed and notarized on the Mac. Run it there with: make alpha"
  [ "$(uname -m)" = arm64 ] || die "the alpha ships Apple silicon only. Run it on an Apple silicon Mac with: make alpha"
  truthy "${DRY_RUN:-}" && dry=1
  MAKE=${MAKE:-make}

  preflight_repo
  preflight_tools
  if [ $dry -eq 0 ]; then preflight_credentials; fi

  resumed=$(resume_version) || rc=$?
  [ $rc -ne 3 ] || exit 1
  [ $rc -eq 0 ] || resumed=
  if [ -n "$resumed" ]; then
    version=$resumed
    say "HEAD is the release commit for $version; carrying on from there"
  else
    notes=$(unreleased_notes CHANGELOG.md)
    [ -n "$notes" ] \
      || die "CHANGELOG.md's \`## Unreleased\` section is empty, and it becomes the release's notes. Write them, then commit: \$EDITOR CHANGELOG.md"
    current=$(tr -d '[:space:]' < VERSION)
    if [ -n "${NEXT:-}" ]; then
      version=$NEXT
    else
      version=$(next_version "$current") \
        || die "VERSION is $current, which is neither X-dev nor X-alpha.N, so the next alpha is unclear. Name it with: make alpha NEXT=<version>"
    fi
    [ -z "$(release_version_refusal "$version")" ] \
      || die "$version is not a version a release can carry ($(release_version_refusal "$version")). Name another with: make alpha NEXT=<version>"
    [ -z "$(git rev-parse -q --verify "refs/tags/v$version" || true)" ] \
      || die "the tag v$version already exists, so $version has been cut. Name the next with: make alpha NEXT=<version>"
    if [ $dry -eq 0 ]; then
      ! git ls-remote --exit-code --tags origin "refs/tags/v$version" >/dev/null 2>&1 \
        || die "origin already has the tag v$version. Fetch it and name the next with: git fetch --tags && make alpha NEXT=<version>"
      [ ! -e "dist/$version" ] \
        || die "dist/$version exists from a build that was not cut by make alpha. Move it aside with: rm -rf dist/$version"
    fi
    echo
    echo "Next release: $version (VERSION is $current)"
    echo "Notes, from CHANGELOG.md's ## Unreleased:"
    printf '%s\n' "$notes" | sed 's/^/  /'
    echo
  fi

  if [ $dry -eq 1 ]; then
    dry_run "$version"
    return
  fi

  if [ -z "$resumed" ]; then
    confirm "$version"
    cut_release "$version"
  elif [ -z "$(git rev-parse -q --verify "refs/tags/v$version" || true)" ]; then
    say "tag v$version"
    git tag -a "v$version" -m "Leyline $version"
  fi

  out=dist/$version
  state=$(dist_state "$out" "$version")
  case "$state" in
    complete) say "$out is complete; not building it again" ;;
    partial)
      say "$out is unfinished; building it again"
      rm -rf "$out"
      ;;
  esac
  if [ "$state" != complete ]; then
    say "make release"
    "$MAKE" --no-print-directory release \
      || die "make release failed; the lines above say why. Once it is fixed, carry on with: make alpha"
  fi

  say "git push origin main v$version"
  git push --quiet origin main "refs/tags/v$version" \
    || die "the push failed; the lines above say why. Once it is fixed, carry on with: make alpha"

  if gh release view "v$version" --repo "$REPO" >/dev/null 2>&1; then
    say "the GitHub release v$version exists; not publishing it again"
  else
    say "make release-publish"
    "$MAKE" --no-print-directory release-publish \
      || die "make release-publish failed; the lines above say why. Once it is fixed, carry on with: make alpha"
  fi

  cat <<EOF

Released $version: https://github.com/$REPO/releases/tag/v$version
Two steps are left, and neither can be scripted:
  1. Download Leyline-$version.dmg from that page in a browser, so it is quarantined, onto a second
     Mac or a fresh user account, and run docs/dev/release-checklist.md, "Acceptance, on a second
     Mac". Nothing is sent to testers until it passes.
  2. Merge the leysdr.com pull request that pins v$version (the site's daily workflow opens it, or
     dispatch the workflow to open it now). Merging it ships the update; then
     curl -I https://leysdr.com/updates/appcast.xml shows max-age=0.
EOF
}

# Sourced by scripts/test-release.sh, which tests the functions above without a Mac.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
