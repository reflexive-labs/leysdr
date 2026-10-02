#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# Fails when a document points at something that is not in the repository: a relative Markdown
# link to a missing file, or a backticked repository path (`docs/x.md`, `go/pkg/leyline/`) that
# does not exist. Plans and the changelog are skipped, because they name files that are planned or
# have since moved, and saying so is their job.
#
#   scripts/check-docs.py        # from the repository root; exit 1 lists every broken reference

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKIP = ("docs/plans/", "CHANGELOG.md")
# A backticked path is checked only when it starts at one of the repository's top-level
# directories, so command lines and code in backticks are left alone.
TOP = ("docs/", "go/", "engine/", "app/", "swift/", "proto/", "scripts/", "fixtures/", "evals/",
       "decoders/", "third_party/", ".github/")
# Generated or local-only paths that a fresh checkout does not have until a build runs.
GENERATED = ("fixtures/", "go/bin", "engine/.build", "app/.build", "app/dist", ".tools/")

LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
TICK = re.compile(r"`([^`\s]+)`")
FENCE = re.compile(r"^\s*(```|~~~)")


def tracked_markdown():
    out = subprocess.run(["git", "ls-files", "*.md"], cwd=ROOT, capture_output=True, text=True,
                         check=True).stdout.split()
    return [p for p in out if not p.startswith(SKIP)]


def check_link(doc: Path, target: str):
    if re.match(r"^[a-z][a-z0-9+.-]*:", target) or target.startswith("#"):
        return None  # a URL, mailto:, or an anchor in the same page
    path = target.split("#", 1)[0]
    if not path:
        return None
    resolved = (doc.parent / path) if not path.startswith("/") else ROOT / path.lstrip("/")
    return None if resolved.exists() else target


def check_tick(doc: Path, text: str):
    path = text.rstrip(".,;:")
    path = re.sub(r":\d+(-\d+)?$", "", path)  # file.swift:123 cites a line
    if not path.startswith(TOP) or any(c in path for c in "<>{}$"):
        return None
    if path.startswith(GENERATED):
        return None
    if "*" in path:
        return None if list(ROOT.glob(path)) else text
    return None if (ROOT / path).exists() else text


def main() -> int:
    broken = []
    for rel in tracked_markdown():
        doc = ROOT / rel
        fenced = False
        for n, line in enumerate(doc.read_text(encoding="utf-8").splitlines(), 1):
            if FENCE.match(line):
                fenced = not fenced
                continue
            if fenced:
                continue
            for m in LINK.finditer(line):
                bad = check_link(doc, m.group(1))
                if bad:
                    broken.append(f"{rel}:{n}: link to a missing file: {bad}")
            for m in TICK.finditer(line):
                bad = check_tick(doc, m.group(1))
                if bad:
                    broken.append(f"{rel}:{n}: no such path in the repository: {bad}")
    for b in broken:
        print(b)
    if broken:
        print(f"check-docs: {len(broken)} broken reference(s)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
