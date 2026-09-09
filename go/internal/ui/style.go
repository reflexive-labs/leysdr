package ui

// Style is the resolved look of one output stream. It is resolved once per
// stream in NewRootCommand (see Resolve) and carried on the App; call sites
// take it, they never build one.
//
// The zero value is plain, ASCII and unknown-width: every ink method is the
// identity function, Glyphs returns the ASCII set, and the width-taking
// helpers still measure visible width correctly.
type Style struct {
	// Color enables SGR output. Depth is always the 16 ANSI names, never
	// 256 and never truecolor: the user's terminal theme resolves them.
	Color bool
	// Unicode enables the UTF-8 glyph set; false uses the ASCII fallbacks.
	Unicode bool
	// Width is the resolved terminal width in columns; 0 means unknown.
	Width int
}

// SGR parameters for the six ink roles. Colour is redundant emphasis on
// information the words already carry, so the set stays this small.
const (
	sgrReset  = "\x1b[0m"
	sgrBold   = "\x1b[1m"
	sgrDim    = "\x1b[2m"
	sgrRed    = "\x1b[31m"
	sgrGreen  = "\x1b[32m"
	sgrYellow = "\x1b[33m"
	sgrCyan   = "\x1b[36m"
)

// ink wraps text in one SGR parameter, or returns it unchanged when colour is
// off or there is nothing to emphasise.
func (s Style) ink(sgr, text string) string {
	if !s.Color || text == "" {
		return text
	}
	return sgr + text + sgrReset
}

// Label is bold: table headers, field labels, the left column of a label
// block, verb names in help.
func (s Style) Label(text string) string { return s.ink(sgrBold, text) }

// Muted is dim: ids the reader is not being asked to read, units, hints,
// scaffolding, values below the noise floor.
func (s Style) Muted(text string) string { return s.ink(sgrDim, text) }

// Ok is green: ACTIVE, AVAILABLE, audio flowing, squelch open, a successful
// action.
func (s Style) Ok(text string) string { return s.ink(sgrGreen, text) }

// Warn is yellow: OUT_OF_CAPTURE, IN_USE by another program, muted audio, a
// degraded but working state.
func (s Style) Warn(text string) string { return s.ink(sgrYellow, text) }

// Err is red: DISCONNECTED, CAPTURE_DETACHED, the `ley:` error prefix, a
// rejected write.
func (s Style) Err(text string) string { return s.ink(sgrRed, text) }

// Cmd is cyan: commands the reader is meant to copy and run.
func (s Style) Cmd(text string) string { return s.ink(sgrCyan, text) }

// Glyphs is the drawing vocabulary of section 4 of docs/cli-style.md, in
// whichever alphabet the style resolved to. Every glyph has an ASCII
// fallback: a screen must be legible in both.
type Glyphs struct {
	// Ramp is the spectrum column ramp, empty first then eight levels. It is
	// a string so a caller cannot mutate the shared alphabet.
	Ramp string
	// BarFull and BarEmpty draw level meters.
	BarFull, BarEmpty rune
	// Marker points at a frequency or a squelch threshold under an axis.
	Marker rune
	// Rule draws a horizontal separator or the noise floor.
	Rule rune
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
		Ramp:       " ▁▂▃▄▅▆▇█",
		BarFull:    '█',
		BarEmpty:   '░',
		Marker:     '▲',
		Rule:       '─',
		TreeBranch: "├─",
		TreeLast:   "└─",
		TreeTrunk:  "│",
		Absent:     "-",
		Ellipsis:   "…",
	}
	asciiGlyphs = Glyphs{
		Ramp:       " .:-=+*#%",
		BarFull:    '#',
		BarEmpty:   '.',
		Marker:     '^',
		Rule:       '-',
		TreeBranch: "+-",
		TreeLast:   "\\-",
		TreeTrunk:  "|",
		Absent:     "-",
		Ellipsis:   "...",
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
