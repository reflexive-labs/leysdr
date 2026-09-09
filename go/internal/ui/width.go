// Package ui owns how `ley` looks: the resolved terminal capabilities
// (colour, unicode, width), the six ink roles, the glyph vocabulary and the
// visible-width helpers every renderer aligns with. It implements section 7
// of docs/cli-style.md and depends on nothing outside the standard library.
//
// The zero Style is plain, ASCII and unknown-width, and every one of its ink
// methods is the identity function: the default path is the plain path, which
// is what the golden tests capture.
package ui

import (
	"strings"
	"unicode"
)

// Visible reports the printed width of s in terminal columns: SGR escape
// sequences count zero, combining marks count zero, and East Asian wide
// characters count two.
func Visible(s string) int {
	n := 0
	for _, seg := range segments(s) {
		if seg.escape {
			continue
		}
		for _, r := range seg.text {
			n += runeWidth(r)
		}
	}
	return n
}

// Strip removes every ANSI escape sequence from s, leaving the text a reader
// sees. Tests assert on it: Strip(styled) must equal the plain rendering.
func Strip(s string) string {
	if !strings.ContainsRune(s, escByte) {
		return s
	}
	var b strings.Builder
	b.Grow(len(s))
	for _, seg := range segments(s) {
		if !seg.escape {
			b.WriteString(seg.text)
		}
	}
	return b.String()
}

// escByte is the ESC that starts every sequence Strip and Visible skip.
const escByte = '\x1b'

// segment is one run of s: either an escape sequence or printable text.
type segment struct {
	text   string
	escape bool
}

// segments splits s into escape sequences and the text between them. It
// recognises CSI sequences (ESC [ ... final byte in @-~), the string
// sequences OSC/DCS/APC/PM (terminated by BEL or ST) and two-byte escapes;
// that is every form a terminal writer can emit, so nothing invisible is ever
// counted as width.
func segments(s string) []segment {
	var out []segment
	start := 0
	for i := 0; i < len(s); {
		if s[i] != escByte {
			i++
			continue
		}
		if start < i {
			out = append(out, segment{text: s[start:i]})
		}
		end := escapeEnd(s, i)
		out = append(out, segment{text: s[i:end], escape: true})
		i, start = end, end
	}
	if start < len(s) {
		out = append(out, segment{text: s[start:]})
	}
	return out
}

// escapeEnd returns the index just past the escape sequence starting at i.
func escapeEnd(s string, i int) int {
	j := i + 1
	if j >= len(s) {
		return len(s)
	}
	switch s[j] {
	case '[': // CSI: parameters then a final byte in @-~
		for j++; j < len(s); j++ {
			if s[j] >= '@' && s[j] <= '~' {
				return j + 1
			}
		}
		return len(s)
	case ']', 'P', '_', '^': // OSC, DCS, APC, PM: run to BEL or ST
		for j++; j < len(s); j++ {
			if s[j] == '\a' {
				return j + 1
			}
			if s[j] == escByte && j+1 < len(s) && s[j+1] == '\\' {
				return j + 2
			}
		}
		return len(s)
	default:
		return j + 1
	}
}

// runeWidth is r's width in terminal columns: 0 for combining marks and
// format characters, 2 for East Asian wide and fullwidth characters, 1
// otherwise. Control characters count zero.
func runeWidth(r rune) int {
	switch {
	case r == 0:
		return 0
	case r < 0x20 || (r >= 0x7f && r < 0xa0):
		return 0
	case r < 0x7f:
		return 1
	case unicode.In(r, unicode.Mn, unicode.Me, unicode.Cf):
		return 0
	case r == 0x200b: // zero-width space (Zs, not Cf)
		return 0
	case wide(r):
		return 2
	}
	return 1
}

// wideRanges are the East Asian Wide and Fullwidth blocks, plus the emoji
// blocks terminals render double width. Kept as a table rather than a
// dependency: the CLI's own glyphs are all narrow, and this only has to be
// right for text a daemon or a device name puts on the screen.
var wideRanges = [...][2]rune{
	{0x1100, 0x115f},
	{0x2e80, 0x303e},
	{0x3041, 0x33ff},
	{0x3400, 0x4dbf},
	{0x4e00, 0x9fff},
	{0xa000, 0xa4cf},
	{0xa960, 0xa97f},
	{0xac00, 0xd7a3},
	{0xf900, 0xfaff},
	{0xfe10, 0xfe19},
	{0xfe30, 0xfe6f},
	{0xff00, 0xff60},
	{0xffe0, 0xffe6},
	{0x1f300, 0x1f64f},
	{0x1f680, 0x1f6ff},
	{0x1f900, 0x1f9ff},
	{0x20000, 0x2fffd},
	{0x30000, 0x3fffd},
}

// wide reports whether r occupies two terminal columns.
func wide(r rune) bool {
	for _, rg := range wideRanges {
		if r >= rg[0] && r <= rg[1] {
			return true
		}
	}
	return false
}

// truncateVisible returns the longest prefix of s whose Visible width is at
// most n, keeping every escape sequence it passes so styling is not cut in
// half, and reports whether anything was dropped.
func truncateVisible(s string, n int) (string, bool) {
	var b strings.Builder
	width := 0
	for _, seg := range segments(s) {
		if seg.escape {
			b.WriteString(seg.text)
			continue
		}
		for _, r := range seg.text {
			w := runeWidth(r)
			if width+w > n {
				return b.String(), true
			}
			b.WriteRune(r)
			width += w
		}
	}
	return b.String(), false
}

// hasEscape reports whether s carries any SGR, so a truncation knows to close
// it with a reset.
func hasEscape(s string) bool { return strings.ContainsRune(s, escByte) }
