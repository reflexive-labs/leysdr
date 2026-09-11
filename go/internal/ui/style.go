package ui

// Style is the resolved look of one output stream. It is resolved once per
// stream in NewRootCommand (see Resolve) and carried on the App; call sites
// take it, they never build one.
//
// The zero value is plain, ASCII and unknown-width: every ink method is the
// identity function, Glyphs returns the ASCII set, and the width-taking
// helpers still measure visible width correctly.
type Style struct {
	// Color enables SGR output. Every ink role draws from the 16 ANSI
	// names, never 256 and never truecolor: the user's terminal theme
	// resolves them. Level is the one exception; see Profile.
	Color bool
	// Profile is the colour depth the stream reports, used by Level alone.
	// The zero value reads as the 16 ANSI names, so a style built by hand
	// with Color set still ramps safely.
	Profile Profile
	// Unicode enables the UTF-8 glyph set; false uses the ASCII fallbacks.
	Unicode bool
	// Width is the resolved terminal width in columns; 0 means unknown.
	Width int
	// Height is the terminal's row count; 0 means unknown. It is not part of
	// layout -- nothing wraps to a height -- and exists for the one decision
	// that needs it: whether a block is short enough to redraw in place, since
	// cursor-up clamps at the top of the screen.
	Height int
}

// sgrReset closes any ink Truncate had to cut mid-string.
const sgrReset = "\x1b[0m"

// Label is bold: table headers, field labels, the left column of a label
// block, verb names in help.
func (s Style) Label(text string) string { return s.ink(inkLabel, text) }

// Muted is dim: ids the reader is not being asked to read, units, hints,
// scaffolding, values below the noise floor.
func (s Style) Muted(text string) string { return s.ink(inkMuted, text) }

// Ok is green: ACTIVE, AVAILABLE, audio flowing, squelch open, a successful
// action.
func (s Style) Ok(text string) string { return s.ink(inkOk, text) }

// Warn is yellow: OUT_OF_CAPTURE, IN_USE by another program, muted audio, a
// degraded but working state.
func (s Style) Warn(text string) string { return s.ink(inkWarn, text) }

// Err is red: DISCONNECTED, CAPTURE_DETACHED, the `ley:` error prefix, a
// rejected write.
func (s Style) Err(text string) string { return s.ink(inkErr, text) }

// Cmd is cyan: commands the reader is meant to copy and run.
func (s Style) Cmd(text string) string { return s.ink(inkCmd, text) }

// Glyphs is the drawing vocabulary of section 4 of docs/cli-style.md, in
// whichever alphabet the style resolved to. Every glyph has an ASCII
// fallback: a screen must be legible in both.
type Glyphs struct {
	// Ramp is the spectrum column ramp, empty first then eight levels. It is
	// a string so a caller cannot mutate the shared alphabet.
	Ramp string
	// BarFull and BarEmpty draw level meters.
	BarFull, BarEmpty rune
	// BlockTop and BlockBottom are the upper and lower halves of a cell,
	// which give a filled shape half-row precision at its edges. ASCII has no
	// half cell, so both fall back to the full one: a clip drawn there is
	// coarser, not broken.
	BlockTop, BlockBottom rune
	// Marker points at a frequency or a squelch threshold under an axis.
	Marker rune
	// Shade is the waterfall's density ramp, empty first then four levels. A
	// waterfall carries level by hue, and hue alone is nothing with colour off,
	// so the cell's texture has to carry it too. These tile; the block ramp
	// does not -- stacked in a grid, `▁▂▃` reads as scan lines rather than as
	// density.
	Shade string
	// Trace draws a waveform one column at a time. The Unicode set leaves it
	// empty, which means braille: a braille cell is 2 x 4 dots, so a trace
	// drawn with it carries eight times the detail of the character grid and
	// no single glyph can stand in for one. ASCII has no such cell, so it
	// names three levels -- low, middle, high -- and a renderer that finds
	// them here draws the coarser picture instead.
	Trace string
	// Rule draws a horizontal separator or the noise floor.
	Rule rune
	// RuleHeavy is the same line drawn with weight, for a separator that
	// has to carry more than a section break.
	RuleHeavy rune
	// TreeBranch, TreeLast and TreeTrunk draw the `ley state` hierarchy.
	TreeBranch, TreeLast, TreeTrunk string
	// Absent is the placeholder for a value the daemon does not have. It is
	// never blank, and never the glyph a range would use.
	Absent string
	// Ellipsis marks text Truncate had to cut.
	Ellipsis string
}

var (
	unicodeGlyphs = Glyphs{
		Ramp:        " ▁▂▃▄▅▆▇█",
		Shade:       " ░▒▓█",
		Trace:       "",
		BarFull:     '█',
		BarEmpty:    '░',
		BlockTop:    '▀',
		BlockBottom: '▄',
		Marker:      '▲',
		Rule:        '─',
		RuleHeavy:   '━',
		TreeBranch:  "├─",
		TreeLast:    "└─",
		TreeTrunk:   "│",
		Absent:      "-",
		Ellipsis:    "…",
	}
	asciiGlyphs = Glyphs{
		Ramp:        " .:-=+*#%",
		Shade:       " .:+#",
		Trace:       `_-"`,
		BarFull:     '#',
		BarEmpty:    '.',
		BlockTop:    '#',
		BlockBottom: '#',
		Marker:      '^',
		Rule:        '-',
		RuleHeavy:   '=',
		TreeBranch:  "+-",
		TreeLast:    "\\-",
		TreeTrunk:   "|",
		Absent:      "-",
		Ellipsis:    "...",
	}
)

// Glyphs returns the glyph set for this style: UTF-8 when Unicode is on,
// the ASCII fallbacks otherwise.
func (s Style) Glyphs() Glyphs {
	if s.Unicode {
		return unicodeGlyphs
	}
	return asciiGlyphs
}
