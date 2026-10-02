#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Every commit in a range carries the Developer Certificate of Origin sign-off of its author:
# a "Signed-off-by: Name <email>" line that matches the commit's author (`git commit -s` writes
# it). Merge commits are skipped. CONTRIBUTING.md says why the project asks for it.
#
#   scripts/check-dco.sh <base> <head>     # e.g. origin/main HEAD

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <base> <head>" >&2
  exit 2
fi

missing=0
while read -r sha; do
  author="$(git log -1 --format='%an <%ae>' "$sha")"
  if ! git log -1 --format='%B' "$sha" | grep -qFx "Signed-off-by: $author"; then
    echo "$(git log -1 --format='%h %s' "$sha")"
    echo "  no \"Signed-off-by: $author\" line"
    missing=$((missing + 1))
  fi
done < <(git rev-list --no-merges "$1..$2")

if [[ $missing -gt 0 ]]; then
  echo
  echo "check-dco: $missing commit(s) lack the author's sign-off. Add it with:"
  echo "  git rebase --signoff $1"
  exit 1
fi
echo "check-dco: every commit is signed off by its author"
