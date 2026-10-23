#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# scripts/reload.sh without the Mac's daemon: HOME is a scratch directory, and codesign, security,
# launchctl and the ley it installs are stubs that log what they were asked. Nothing here reaches
# the person's LaunchAgent, keychain or socket.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-reload.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

identity="Developer ID Application: Example (TEAM123456)"
mkdir -p "$tmp/build" "$tmp/stubs"
log="$tmp/calls.log"

# The built binaries. The ley stub is what reload.sh copies and then runs, so it logs from wherever
# it was copied to.
printf '#!/bin/sh\necho leylined\n' > "$tmp/build/leylined"
cat > "$tmp/build/ley" <<'SH'
#!/bin/sh
echo "ley $*" >> "$RELOAD_TEST_LOG"
[ "$1 $2" = "daemon status" ] && [ -n "${RELOAD_TEST_STATUS_FAILS:-}" ] && exit 1
exit 0
SH
cat > "$tmp/stubs/codesign" <<'SH'
#!/bin/sh
echo "codesign $*" >> "$RELOAD_TEST_LOG"
SH
cat > "$tmp/stubs/security" <<'SH'
#!/bin/sh
[ -n "${RELOAD_TEST_IDENTITY:-}" ] && printf '  1) 0123ABCD "%s"\n     1 valid identities found\n' "$RELOAD_TEST_IDENTITY"
exit 0
SH
# launchctl print answers with RELOAD_TEST_JOB's contents when it names a file, else as launchd
# does for a label it has never seen.
cat > "$tmp/stubs/launchctl" <<'SH'
#!/bin/sh
echo "launchctl $*" >> "$RELOAD_TEST_LOG"
[ "$1" = print ] && [ -f "${RELOAD_TEST_JOB:-}" ] && { cat "$RELOAD_TEST_JOB"; exit 0; }
exit 113
SH
chmod +x "$tmp/build/leylined" "$tmp/build/ley" "$tmp/stubs/"*

# reload [env...]: run reload.sh against the scratch HOME and stubs; stdout+stderr in $tmp/out.
reload() {
  rm -f "$log"
  : > "$log"
  env HOME="$tmp/home" LEYLINED_SRC="$tmp/build/leylined" LEY_SRC="$tmp/build/ley" \
    CODESIGN="$tmp/stubs/codesign" SECURITY="$tmp/stubs/security" LAUNCHCTL="$tmp/stubs/launchctl" \
    RELOAD_TEST_LOG="$log" CODESIGN_IDENTITY="$identity" "$@" "$here/reload.sh" > "$tmp/out" 2>&1
}
bin="$tmp/home/Library/Application Support/Leyline/bin"

# With the identity in the keychain: both copies signed with it under the bundle's identifiers,
# then the installed ley stops the daemon, installs the agent on the copy and asks for its status.
mkdir -p "$bin"
printf 'old\n' > "$bin/leylined"
old_inode=$(ls -i "$bin/leylined" | awk '{print $1}')
reload RELOAD_TEST_IDENTITY="$identity" || fail "reload with an identity failed: $(cat "$tmp/out")"
cmp -s "$bin/leylined" "$tmp/build/leylined" || fail "leylined was not copied to $bin"
cmp -s "$bin/ley" "$tmp/build/ley" || fail "ley was not copied to $bin"
[ "$(ls -i "$bin/leylined" | awk '{print $1}')" != "$old_inode" ] \
  || fail "leylined was rewritten in place; a running daemon's file must be replaced by rename"
[ ! -e "$bin/leylined.new" ] && [ ! -e "$bin/ley.new" ] || fail "a .new file was left in $bin"
want="codesign --force --sign $identity --identifier leylined --timestamp=none $bin/leylined.new
codesign --force --sign $identity --identifier ley --timestamp=none $bin/ley.new
ley daemon stop
ley daemon install --bin $bin/leylined
ley daemon status"
got=$(grep -v '^launchctl' "$log")
[ "$got" = "$want" ] || fail "with an identity, the calls were:
$got
want:
$want"
grep -q 'warning' "$tmp/out" && fail "a signed reload warned: $(cat "$tmp/out")"

# Without the identity: ad hoc, and a warning that names the keychain cost.
reload || fail "reload without an identity failed: $(cat "$tmp/out")"
grep -q -- "codesign --force --sign - --identifier leylined" "$log" || fail "without an identity leylined was not signed ad hoc: $(cat "$log")"
grep -q "no codesigning identity \"$identity\"" "$tmp/out" || fail "the ad-hoc warning does not name the missing identity: $(cat "$tmp/out")"
grep -q "must be added again" "$tmp/out" || fail "the ad-hoc warning does not say keys must be added again: $(cat "$tmp/out")"
reload CODESIGN_IDENTITY= || fail "reload with an empty CODESIGN_IDENTITY failed: $(cat "$tmp/out")"
grep -q "CODESIGN_IDENTITY is empty" "$tmp/out" || fail "an empty CODESIGN_IDENTITY was not named: $(cat "$tmp/out")"

# The app's own agent holds the label: refused before anything is copied, stopped or installed.
rm -rf "$tmp/home"
cat > "$tmp/app-job" <<'TXT'
gui/501/com.leysdr.daemon = {
	path = /Applications/Leyline.app/Contents/Library/LaunchAgents/com.leysdr.daemon.plist
	program = /Applications/Leyline.app/Contents/Helpers/leylined
}
TXT
reload RELOAD_TEST_JOB="$tmp/app-job" && fail "reload went ahead over the app's agent"
grep -q "the Leyline app already starts the daemon at login (/Applications/Leyline.app/Contents/Helpers/leylined)" "$tmp/out" \
  || fail "the refusal does not name the app's daemon: $(cat "$tmp/out")"
grep -q "Login Items" "$tmp/out" || fail "the refusal does not name Login Items: $(cat "$tmp/out")"
grep -q '^ley \|^codesign' "$log" && fail "reload stopped or signed something over the app's agent: $(cat "$log")"
[ -e "$bin" ] && fail "reload created $bin over the app's agent"

# ley's own job pointed at a bundled leylined (ley daemon install --bin) is ley's, not the app's.
cat > "$tmp/ley-job" <<TXT
gui/501/com.leysdr.daemon = {
	path = $tmp/home/Library/LaunchAgents/com.leysdr.daemon.plist
	program = /Applications/Leyline.app/Contents/Helpers/leylined
}
TXT
reload RELOAD_TEST_JOB="$tmp/ley-job" || fail "reload refused ley's own job: $(cat "$tmp/out")"

# A daemon that does not come up: the status failure is the script's, after the log's tail.
reload RELOAD_TEST_STATUS_FAILS=1 && fail "reload succeeded although the daemon did not answer"
grep -q "leylined log (last 20 lines)" "$tmp/out" || fail "a failed start does not show the log: $(cat "$tmp/out")"

# DRY_RUN=1 says what it would do and does nothing.
rm -rf "$tmp/home"
reload DRY_RUN=1 || fail "a dry run failed: $(cat "$tmp/out")"
grep -q "would run: .*ley daemon install --bin" "$tmp/out" || fail "a dry run does not show the install: $(cat "$tmp/out")"
[ -e "$bin" ] && fail "a dry run created $bin"
grep -q '^ley \|^codesign' "$log" && fail "a dry run ran something: $(cat "$log")"

# A binary that was never built is named, with the target that builds it.
env HOME="$tmp/home" LEYLINED_SRC="$tmp/build/nope" LEY_SRC="$tmp/build/ley" LAUNCHCTL="$tmp/stubs/launchctl" \
  RELOAD_TEST_LOG="$log" "$here/reload.sh" > "$tmp/out" 2>&1 && fail "reload ran without a leylined"
grep -q "nope is missing; run make swift-release" "$tmp/out" || fail "a missing leylined was not named: $(cat "$tmp/out")"

if [ "$failures" -gt 0 ]; then
  echo "test-reload.sh: $failures failure(s)" >&2
  exit 1
fi
echo "test-reload.sh: ok"
