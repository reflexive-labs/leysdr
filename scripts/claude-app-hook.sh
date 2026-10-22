#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Claude Code's PostToolUse hook on Edit, Write and MultiEdit (.claude/settings.json): after an
# edit to a file under app/Sources, build the app package incrementally and run the theme gate,
# so a compile error or a colour outside Theme.swift shows up at the edit rather than at
# `make app-check` (docs/plans/mac-loop.md, ML-8).
#
#   echo '{"tool_input":{"file_path":"/repo/app/Sources/LeylineApp/X.swift"}}' | scripts/claude-app-hook.sh
#
# Reads the hook's JSON on stdin. An edit elsewhere exits 0 at once. On success it prints nothing;
# on a failure it prints the first 30 lines of errors to stderr and exits 2, which Claude Code
# hands back to the agent. It never runs the checks themselves: those take minutes.
set -uo pipefail

input=$(cat)
if command -v jq >/dev/null 2>&1; then
    path=$(jq -r '.tool_input.file_path // empty' <<<"$input" 2>/dev/null)
else
    path=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))' <<<"$input" 2>/dev/null)
fi

case "$path" in
    */app/Sources/*) ;;
    *) exit 0 ;;
esac

# The checkout is the part of the path before app/Sources, so an edit in a worktree builds that
# worktree.
root=${path%%/app/Sources/*}
[ -x "$root/scripts/check-theme.sh" ] || exit 0

if ! out=$(cd "$root/app" && swift build 2>&1); then
    errors=$(grep -E '(^|: )(fatal )?error:' <<<"$out" | awk '!seen[$0]++')
    {
        echo "swift build in app/ failed after the edit to ${path#"$root"/}:"
        if [ -n "$errors" ]; then head -30 <<<"$errors"; else tail -30 <<<"$out"; fi
    } >&2
    exit 2
fi

if ! out=$(cd "$root" && ./scripts/check-theme.sh 2>&1); then
    {
        echo "scripts/check-theme.sh failed after the edit to ${path#"$root"/}:"
        head -30 <<<"$out"
    } >&2
    exit 2
fi
exit 0
