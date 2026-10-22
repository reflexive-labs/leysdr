#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# The theme gate (`make app-lint`): colours and fonts in the app come from Theme.swift only
# (docs/dev/app.md, "Palette and type"; docs/dev/swift-style.md, section 1, rule 6), so a design
# change is one file's worth of edits and no system colour lands on the app's dark ground.
#
#   scripts/check-theme.sh
#
# Every Swift file under app/Sources/LeylineApp except Theme.swift is searched for a colour built
# in place (`Color(`, `NSColor(`, `MTLClearColor(` and the like), a named system colour
# (`Color.red`, `NSColor.labelColor`), a system font (`.font(.system`, `Font.system`) and a hex
# colour (`#2A3034`, `0x2A3034`). Each hit prints as `file:line: message`; any hit exits 1.
# Whole-line comments are skipped, so a comment may name the hex value it explains.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# The allow-list: `file|text|reason`, one entry a line. `file` is a name under the app's source
# directory, or `*` for any. `text` is removed from a line of that file before the line is
# searched, so the rest of the line is still checked. Every entry says why it is allowed.
ALLOW="
*|Color.clear|transparent, not a colour: an unselected row's ground or a spacer
LeylineApp.swift|NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)|the About panel is the system's window on the system's ground
LeylineApp.swift|NSColor.secondaryLabelColor|the About panel is the system's window on the system's ground
"
export ALLOW

files=()
for path in app/Sources/LeylineApp/*.swift; do
    [ "${path##*/}" = Theme.swift ] || files+=("$path")
done

awk '
    BEGIN {
        n = split(ENVIRON["ALLOW"], entries, "\n")
        for (i = 1; i <= n; i++) {
            if (entries[i] == "") continue
            split(entries[i], parts, "|")
            count++
            allowFile[count] = parts[1]
            allowText[count] = parts[2]
        }
    }
    function strip(line, text,    at) {
        while ((at = index(line, text)) > 0)
            line = substr(line, 1, at - 1) substr(line, at + length(text))
        return line
    }
    function hit(message) {
        printf "%s:%d: %s\n", FILENAME, FNR, message
        bad = 1
    }
    /^[ \t]*\/\// { next }
    {
        name = FILENAME
        sub(/.*\//, "", name)
        line = $0
        for (i = 1; i <= count; i++)
            if (allowFile[i] == "*" || allowFile[i] == name) line = strip(line, allowText[i])
        if (line ~ /Color\(/) hit("a colour built outside Theme.swift; use a Theme token")
        if (line ~ /(^|[^A-Za-z0-9_])(NS)?Color\.[a-z]/) hit("a system colour; use a Theme token")
        if (line ~ /\.font\(\.system/ || line ~ /Font\.system/)
            hit("a system font; use a Theme.Font token")
        if (line ~ /(#|0x)[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]([^0-9A-Za-z_]|$)/)
            hit("a hex colour outside Theme.swift; use a Theme token")
    }
    END { exit bad }
' "${files[@]}"
