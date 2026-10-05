#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# The licence gate (`make license-check`, CI): every source file names its licence, and every
# dependency sits in third_party/licenses/MANIFEST.txt beside its licence text, with terms the code
# that pulls it in may use. docs/decisions/D2-licensing.md is the rule; this script enforces it.
#
#   scripts/check-licenses.sh          check
#   scripts/check-licenses.sh --fix    add the SPDX line to hand-written files that lack it
#
# Licence by path: engine/ is GPL-3.0-or-later (it links librtlsdr); everything else is Apache-2.0,
# the generated contract in swift/LeylineProto included — it lives outside engine/ so the licence
# boundary is a directory boundary. Generated files (go/gen, LeylineProto) inherit the line from
# their .proto, so `make proto` refreshes them and --fix never touches them.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

fix=0
[ "${1:-}" = "--fix" ] && fix=1
fail=0
say() { printf '%s\n' "$*" >&2; }
first_of() {  # the first existing path among the globs given, or nothing (an unmatched glob is never an error)
  local g
  for g in "$@"; do [ -e "$g" ] && { printf '%s\n' "$g"; return 0; }; done
  return 0
}
bad() { say "license-check: $*"; fail=1; }

expected_licence() {
  case "$1" in
    engine/*) echo GPL-3.0-or-later ;;
    *) echo Apache-2.0 ;;
  esac
}
is_generated() { case "$1" in go/gen/*|swift/LeylineProto/Sources/*) return 0 ;; *) return 1 ;; esac; }
comment_prefix() {
  case "$1" in
    *.go|*.swift|*.proto|*.h|*.modulemap) echo '//' ;;
    *.sh|*.py|Makefile|*/Makefile) echo '#' ;;
  esac
}
insert_header() {  # file line: after a shebang or swift-tools-version line, else first with a blank after
  local f=$1 line=$2 tmp
  tmp=$(mktemp)
  if head -n 1 "$f" | grep -Eq '^#!|^// swift-tools-version'; then
    { head -n 1 "$f"; printf '%s\n' "$line"; tail -n +2 "$f"; } > "$tmp"
  else
    { printf '%s\n\n' "$line"; cat "$f"; } > "$tmp"
  fi
  cat "$tmp" > "$f"
  rm -f "$tmp"
}

# 1. SPDX headers on every source file git tracks.
while IFS= read -r f; do
  prefix=$(comment_prefix "$f")
  [ -n "$prefix" ] || continue
  want=$(expected_licence "$f")
  have=$(head -n 20 "$f" | sed -n 's/^.*SPDX-License-Identifier: *\([A-Za-z0-9.+-]*\).*$/\1/p' | head -n 1)
  [ "$have" = "$want" ] && continue
  if is_generated "$f"; then
    bad "$f: generated file lacks 'SPDX-License-Identifier: $want' (make proto)"
  elif [ -n "$have" ]; then
    bad "$f: says $have, must be $want"
  elif [ $fix -eq 1 ]; then
    insert_header "$f" "$prefix SPDX-License-Identifier: $want"
    say "license-check: added $want to $f"
  else
    bad "$f: missing 'SPDX-License-Identifier: $want' (scripts/check-licenses.sh --fix adds it)"
  fi
done < <(git ls-files -- '*.go' '*.swift' '*.proto' '*.sh' '*.py' '*.h' '*.modulemap' 'Makefile' '*/Makefile')

# 2. No cgo in the Go clients: the only way Go code here could link librtlsdr.
if git grep -lE '^import "C"$' -- 'go/*.go' >/dev/null 2>&1; then
  bad "cgo in go/: $(git grep -lE '^import "C"$' -- 'go/*.go' | tr '\n' ' ')(the clients must not link C libraries; librtlsdr is GPL)"
fi

# 3. The manifest: every row vendored, named in NOTICE, and licensed for where it is used.
manifest=third_party/licenses/MANIFEST.txt
permissive='Apache-2.0|MIT|BSD-2-Clause|BSD-3-Clause|ISC|Zlib|0BSD'
engine_ok="$permissive|GPL-2.0-or-later|GPL-3.0-only|GPL-3.0-or-later|LGPL-2.1-or-later|LGPL-3.0-or-later|MPL-2.0"
rows() { grep -v '^#' "$manifest" | awk -v k="$1" 'NF==4 && $1==k {print $2}' | sort; }
while read -r kind name lic file; do
  [ -f "third_party/licenses/$file" ] || bad "$name: third_party/licenses/$file is not vendored"
  grep -qF -- "$name" NOTICE || bad "$name: not named in NOTICE"
  # A comma-separated list means every licence in it applies, so each one must be allowed.
  for one in ${lic//,/ }; do
    case "$kind" in
      go) printf '%s' "$one" | grep -Eqx "$permissive" || bad "$name is $one; nothing outside engine/ may import copyleft code" ;;
      swift|system) printf '%s' "$one" | grep -Eqx "$engine_ok" || bad "$name is $one, which the GPL-3.0 engine cannot link" ;;
      swift-macos) printf '%s' "$one" | grep -Eqx "$permissive" || bad "$name is $one; the Apache-2.0 app may not link copyleft code" ;;
      *) bad "$name: unknown kind '$kind' in $manifest"; break ;;
    esac
  done
done < <(grep -v '^#' "$manifest" | awk 'NF==4')

# 4. The Go dependency graph (tests included) equals the manifest, and each vendored text still
#    matches the module in the cache, so an upgrade that changes a licence is noticed.
main_mod=$(cd go && go list -m)
actual=$(cd go && go list -deps -test -f '{{with .Module}}{{.Path}}{{end}}' ./... | grep -v '^$' | grep -vx "$main_mod" | sort -u)
listed=$(rows go)
for m in $(comm -23 <(printf '%s\n' "$actual") <(printf '%s\n' "$listed")); do
  bad "Go module $m is imported but not in $manifest (add a row and copy its LICENSE beside it)"
done
for m in $(comm -13 <(printf '%s\n' "$actual") <(printf '%s\n' "$listed")); do
  bad "Go module $m is in $manifest but nothing imports it (remove the row and its text)"
done
while read -r _ name _ file; do
  dir=$(cd go && go list -m -f '{{.Dir}}' "$name" 2>/dev/null || true)
  [ -n "$dir" ] || continue
  src=$(first_of "$dir"/LICENSE* "$dir"/COPYING*)
  [ -n "$src" ] || continue
  cmp -s "$src" "third_party/licenses/$file" || bad "$name: third_party/licenses/$file differs from the module's own licence file ($src)"
  # An Apache-2.0 module's NOTICE must ship with it, as the Swift packages' do (step 6).
  notice=$(first_of "$dir"/NOTICE*)
  [ -n "$notice" ] || continue
  cmp -s "$notice" "third_party/licenses/${file%.txt}.NOTICE.txt" || bad "$name ships a NOTICE that third_party/licenses/${file%.txt}.NOTICE.txt does not match"
done < <(grep -v '^#' "$manifest" | awk 'NF==4 && $1=="go"')

# 5. The Swift packages the three Package.resolved files pin equal the manifest (each resolves the
#    contract package's graph again through its path dependency, plus anything of its own); texts
#    compared when the checkouts exist (after a swift build), skipped otherwise.
#    A `swift-macos` row is a package only app/Package.swift's `#if os(macOS)` block declares
#    (Sparkle, a binary target Linux must not download). A resolve on macOS pins it and a resolve on
#    Linux drops the pin, so app/Package.resolved may hold it or not; the row must instead name a
#    package that block declares, and a pin of it is accepted wherever it appears.
resolved=(engine/Package.resolved)
[ -f swift/LeylineProto/Package.resolved ] && resolved+=(swift/LeylineProto/Package.resolved)
[ -f app/Package.resolved ] && resolved+=(app/Package.resolved)
actual=$(cat "${resolved[@]}" | grep -o '"identity" *: *"[^"]*"' | sed 's/.*: *"//; s/"//' | sort -u)
listed=$(rows swift)
macos_only=$(rows swift-macos)
for p in $(comm -23 <(printf '%s\n' "$actual") <(printf '%s\n' "$listed" "$macos_only" | sort)); do
  bad "Swift package $p is in ${resolved[*]} but not in $manifest"
done
for p in $(comm -13 <(printf '%s\n' "$actual") <(printf '%s\n' "$listed")); do
  bad "Swift package $p is in $manifest but not in ${resolved[*]}"
done
# The identities the macOS block of app/Package.swift declares: the last path component of each
# package URL between `#if os(macOS)` and `#endif`, lowercased and without `.git`, as SwiftPM
# names a package in Package.resolved.
declared_macos=$(awk '/^#if os\(macOS\)/ {on=1} /^#endif/ {on=0} on' app/Package.swift \
  | grep -o '\.package(url: *"[^"]*"' | sed 's/.*"\(.*\)"/\1/; s|/*$||; s|.*/||; s/\.git$//' \
  | tr '[:upper:]' '[:lower:]' | sort -u || true)
for p in $(comm -23 <(printf '%s\n' "$macos_only") <(printf '%s\n' "$declared_macos")); do
  bad "Swift package $p is a swift-macos row in $manifest but app/Package.swift's #if os(macOS) block does not declare it"
done
for p in $(comm -13 <(printf '%s\n' "$macos_only") <(printf '%s\n' "$declared_macos")); do
  bad "Swift package $p is declared in app/Package.swift's #if os(macOS) block but is not a swift-macos row in $manifest"
done
while read -r _ name _ file; do
  # The checkout keeps the URL's case (Sparkle), the identity is lowercased.
  dir=$(find app/.build/checkouts -maxdepth 1 -iname "$name" 2>/dev/null | head -n 1)
  [ -n "$dir" ] || continue
  src=$(first_of "$dir"/LICENSE*)
  [ -n "$src" ] || continue
  cmp -s "$src" "third_party/licenses/$file" || bad "$name: third_party/licenses/$file differs from the checkout's licence file"
done < <(grep -v '^#' "$manifest" | awk 'NF==4 && $1=="swift-macos"')

# 6. The app never links the engine: it depends on swift/LeylineProto for the generated contract
#    and on the engine package not at all, so it stays a separate Apache-2.0 work beside the GPL
#    daemon (docs/decisions/D2-licensing.md, "Licence assignment").
if git grep --untracked -nE '^\s*(@testable )?import (EngineCore|CRTLSDR|LeylineDaemon)\b' -- 'app/*.swift' >/dev/null 2>&1; then
  bad "app/ imports the engine: $(git grep --untracked -lE '^\s*(@testable )?import (EngineCore|CRTLSDR|LeylineDaemon)\b' -- 'app/*.swift' | tr '\n' ' ')(the app links LeylineProto only)"
fi
while read -r _ name _ file; do
  src=$(first_of engine/.build/checkouts/"$name"/LICENSE*)
  [ -n "$src" ] || continue
  cmp -s "$src" "third_party/licenses/$file" || bad "$name: third_party/licenses/$file differs from the checkout's licence file"
  notice=$(first_of engine/.build/checkouts/"$name"/NOTICE*)
  [ -n "$notice" ] || continue
  cmp -s "$notice" "third_party/licenses/swift_${name}.NOTICE.txt" || bad "$name ships a NOTICE that third_party/licenses/swift_${name}.NOTICE.txt does not match"
done < <(grep -v '^#' "$manifest" | awk 'NF==4 && $1=="swift"')

[ $fail -eq 0 ] && say "license-check: ok"
exit $fail
