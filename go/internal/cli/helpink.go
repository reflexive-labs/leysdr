// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"strings"

	"github.com/dpup/leysdr/go/internal/ui"
)

// Help is hand-wrapped prose plus two-column blocks, and it is snapshotted
// byte-for-byte through a non-terminal writer. So the treatment here adds ink
// and nothing else: no word moves, no column moves, and with colour off
// styleHelp is the identity function -- which is what keeps the goldens in
// testdata/help valid. What it inks is the left column of every block (the
// verb names, the topic names, the option keys, the glossary terms, the
// preset and band names, the flags) plus the section headings, and it dims
// Cobra's scaffolding: the Usage block, the trailing "Use ..." footer, the
// "# ..." half of an example and the "(default ...)" tail of a flag.
const (
	// helpKeyMax is the widest left column that still reads as a key; past
	// it the line is prose that happens to hold a double space.
	helpKeyMax = 24
	// helpHeadingMax bounds a heading in characters and words, so a prose
	// line ending in a colon is not mistaken for one.
	helpHeadingMax     = 40
	helpHeadingMaxWord = 5
)

// styleHelp inks one rendered help screen. The zero style returns it unchanged.
func styleHelp(st ui.Style, text string) string {
	if !st.Color {
		return text
	}
	lines := strings.Split(text, "\n")
	key := helpKeyLines(lines)
	usage := false
	for i, line := range lines {
		trimmed := strings.TrimLeft(line, " ")
		switch {
		case trimmed == "":
			usage = false
		case line == "Usage:":
			usage = true
			lines[i] = st.Muted(line)
		case usage:
			// "ley [flags]" is a shape, not a command to copy.
			lines[i] = st.Muted(line)
		default:
			lines[i] = styleHelpLine(st, line, trimmed, key[i])
		}
	}
	return strings.Join(lines, "\n")
}

// helpKeyLines marks the lines whose left column is a key worth inking. A
// key column is a column: one line that happens to hold a double space (the
// sample meter line in `ley help squelch`, say) is prose, so a row only
// counts when another row in the same block lines its description up at the
// same place.
func helpKeyLines(lines []string) []bool {
	out := make([]bool, len(lines))
	col := make([]int, len(lines))
	start := 0
	flush := func(end int) {
		counts := map[int]int{}
		for i := start; i < end; i++ {
			if col[i] >= 0 {
				counts[col[i]]++
			}
		}
		for i := start; i < end; i++ {
			if col[i] >= 0 && counts[col[i]] > 1 {
				out[i] = true
			}
		}
	}
	for i, line := range lines {
		col[i] = helpDescCol(line)
		if strings.TrimSpace(line) == "" {
			flush(i)
			start = i + 1
		}
	}
	flush(len(lines))
	return out
}

// helpDescCol is the column a two-column block line's description starts at,
// or -1 when the line is not one: prose, an example, a flag (those are inked
// on their own account) or a left column too wide to be a key.
func helpDescCol(line string) int {
	trimmed := strings.TrimLeft(line, " ")
	indent := len(line) - len(trimmed)
	if trimmed == "" || strings.HasPrefix(trimmed, "-") {
		return -1
	}
	if indent > 0 && strings.HasPrefix(trimmed, "ley ") {
		return -1
	}
	left, gap, _, ok := splitHelpColumns(trimmed)
	if !ok || ui.Visible(left) > helpKeyMax {
		return -1
	}
	return indent + len(left) + len(gap)
}

// styleHelpLine inks one line of help by what it is: a heading, Cobra's
// footer, an example, a flag, or the left column of a two-column block.
func styleHelpLine(st ui.Style, line, trimmed string, key bool) string {
	indent := line[:len(line)-len(trimmed)]
	if indent == "" {
		if strings.HasPrefix(trimmed, `Use "`) {
			return st.Muted(line)
		}
		if isHelpHeading(trimmed) {
			return st.Label(line)
		}
	}
	left, gap, right, ok := splitHelpColumns(trimmed)
	if indent != "" && strings.HasPrefix(trimmed, "ley ") {
		return indent + inkHelpExample(st, left, gap, right, ok)
	}
	if !ok {
		return line
	}
	if strings.HasPrefix(left, "-") {
		return indent + inkHelpFlag(st, left) + gap + inkHelpDefault(st, right)
	}
	if !key {
		return line
	}
	return indent + st.Label(left) + gap + right
}

// isHelpHeading reports whether a line is a section heading ("Flags:",
// "Listening:", "Exit codes:") rather than prose that ends in a colon.
func isHelpHeading(s string) bool {
	if !strings.HasSuffix(s, ":") || len(s) > helpHeadingMax {
		return false
	}
	return len(strings.Fields(s)) <= helpHeadingMaxWord
}

// splitHelpColumns cuts a block line at its first run of two or more spaces,
// which is the gutter every help block uses. ok is false for a line that has
// no second column.
func splitHelpColumns(s string) (left, gap, right string, ok bool) {
	i := strings.Index(s, "  ")
	if i <= 0 {
		return s, "", "", false
	}
	rest := s[i:]
	j := len(rest) - len(strings.TrimLeft(rest, " "))
	if j == len(rest) {
		return strings.TrimRight(s, " "), rest, "", false
	}
	return s[:i], rest[:j], rest[j:], true
}

// inkHelpExample inks an example: the command is what the reader copies, the
// "# ..." half is a comment about it.
func inkHelpExample(st ui.Style, left, gap, right string, twoColumn bool) string {
	if !twoColumn {
		return st.Cmd(left)
	}
	if strings.HasPrefix(right, "#") {
		return st.Cmd(left) + gap + st.Muted(right)
	}
	return st.Cmd(left) + gap + right
}

// inkHelpFlag inks a flag's key column: the names are the key, the type token
// after them is scaffolding.
func inkHelpFlag(st ui.Style, left string) string {
	if i := strings.LastIndex(left, " "); i > 0 && !strings.HasPrefix(left[i+1:], "-") {
		return st.Label(left[:i]) + " " + st.Muted(left[i+1:])
	}
	return st.Label(left)
}

// inkHelpDefault dims a trailing "(default ...)" so the sentence before it
// reads first.
func inkHelpDefault(st ui.Style, desc string) string {
	i := strings.LastIndex(desc, "(default")
	if i < 0 || !strings.HasSuffix(desc, ")") {
		return desc
	}
	return desc[:i] + st.Muted(desc[i:])
}
