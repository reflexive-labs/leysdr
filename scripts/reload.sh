#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# `make reload` after the build (docs/dev/setup.md, "The edit-build-try loop"): copies the release
# leylined and ley out of the build tree into ~/Library/Application Support/Leyline/bin, signs the
# copies, points the LaunchAgent at them and restarts the daemon.
#
# The daemon must not run from engine/.build. `make app-check` and every other release build relink
# that file under a running daemon, and a keychain read from a process whose file has changed fails
# (docs/plans/app.md, MC-8). The copy is replaced only by this script, by rename, so a running
# daemon keeps the file it started from until it is restarted onto the new one.
#
# The copies are signed with CODESIGN_IDENTITY, the build Mac's Developer ID, under the identifiers
# the app bundle's helpers carry (`leylined`, `ley`), so the keychain sees one program across
# reinstalls and a key added through either daemon is readable by the other. They are not signed
# with the hardened runtime: its library validation would refuse Homebrew's librtlsdr, which this
# leylined loads from where Homebrew put it. Without the identity they are signed ad hoc, which
# works until the next reload, and a key stored in the keychain must then be added again.
#
# The label com.leysdr.daemon is shared with the Leyline app's agent (DaemonAgent.swift). When the
# app registered it, this script refuses before stopping anything, as `ley daemon install` does.
#
# Environment, for scripts/test-reload.sh and a non-standard install: LEYLINED_SRC and LEY_SRC
# (the built binaries), LEYLINE_BIN_DIR (where the copies go), CODESIGN, SECURITY and LAUNCHCTL
# (the tools), DRY_RUN=1 (say what would be done and do nothing).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)

die() { echo "reload.sh: $*" >&2; exit 1; }
warn() { echo "reload.sh: warning: $*" >&2; }

leylined_src=${LEYLINED_SRC:-}
if [ -z "$leylined_src" ]; then
  leylined_src="$(cd "$root/engine" && swift build -c release --show-bin-path)/leylined"
fi
ley_src=${LEY_SRC:-$root/go/bin/ley}
dest=${LEYLINE_BIN_DIR:-$HOME/Library/Application Support/Leyline/bin}
codesign=${CODESIGN:-codesign}
security=${SECURITY:-security}
launchctl=${LAUNCHCTL:-launchctl}
identity=${CODESIGN_IDENTITY:-}
dry_run=${DRY_RUN:-0}
label=com.leysdr.daemon
agent_plist="$HOME/Library/LaunchAgents/$label.plist"

[ -x "$leylined_src" ] || die "$leylined_src is missing; run make swift-release first"
[ -x "$ley_src" ] || die "$ley_src is missing; run make go first"

# app_job prints the program of the com.leysdr.daemon job when the Leyline app registered it, as
# `ley daemon install` decides (go/internal/cli/daemon.go, appDaemonProgram): the program lies in an
# app bundle's Contents/Helpers and the job was not loaded from the plist ley writes.
app_job() {
  local out program path
  out=$("$launchctl" print "gui/$(id -u)/$label" 2>/dev/null) || return 0
  program=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*program = //p' | head -1)
  path=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*path = //p' | head -1)
  [ "$path" != "$agent_plist" ] || return 0
  case "$program" in *.app/Contents/Helpers/*) printf '%s\n' "$program" ;; esac
}

# signing_identity prints the identity to sign with: CODESIGN_IDENTITY when the keychain holds it,
# else `-` (ad hoc) after a warning that says what that costs.
signing_identity() {
  if [ -n "$identity" ] && "$security" find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$identity\""; then
    printf '%s\n' "$identity"
    return
  fi
  if [ -n "$identity" ]; then
    warn "no codesigning identity \"$identity\" in the keychain (security find-identity -v -p codesigning)"
  else
    warn "CODESIGN_IDENTITY is empty"
  fi
  warn "signing ad hoc: each reload is a new program to the keychain, so a key the daemon stored there must be added again after it (ley ai add <provider>)"
  printf '%s\n' -
}

run() {
  if [ "$dry_run" = 1 ]; then
    printf 'would run:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

prog=$(app_job)
if [ -n "$prog" ]; then
  die "the Leyline app already starts the daemon at login ($prog). To run a build from source instead, switch Leyline off in System Settings > General > Login Items & Extensions, then run make reload again"
fi

sign_as=$(signing_identity)
echo "==> install leylined and ley in $dest (signed ${sign_as/#-/ad hoc})"
run mkdir -p "$dest"
# Copy, sign, then rename over the old copy: the running daemon keeps its file, and a failed
# signature leaves the installed copy as it was.
for pair in "leylined:$leylined_src" "ley:$ley_src"; do
  name=${pair%%:*}
  src=${pair#*:}
  run cp "$src" "$dest/$name.new"
  run "$codesign" --force --sign "$sign_as" --identifier "$name" --timestamp=none "$dest/$name.new"
  run mv -f "$dest/$name.new" "$dest/$name"
done

# The installed ley does the launchd work, so the plist's --ley names the installed copy too.
echo "==> restart the daemon on $dest/leylined"
run "$dest/ley" daemon stop || true
run "$dest/ley" daemon install --bin "$dest/leylined"
if ! run "$dest/ley" daemon status; then
  echo "--- leylined log (last 20 lines)" >&2
  "$dest/ley" daemon logs | tail -20 >&2
  exit 1
fi
