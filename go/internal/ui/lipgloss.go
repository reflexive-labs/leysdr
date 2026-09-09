package ui

import (
	"fmt"
	"io"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"
)

// Profile is the colour depth one stream reports. It exists for the level
// ramp only (section 3a of docs/cli-style.md): every other ink role stays on
// the 16 ANSI names whatever the profile says, so the user's terminal theme
// resolves them.
//
// The zero value is ProfileNone, which is why a zero Style emits nothing.
type Profile int

const (
	// ProfileNone is no colour at all.
	ProfileNone Profile = iota
	// ProfileANSI is the 16 named colours, the depth every ink role uses.
	ProfileANSI
	// ProfileANSI256 is the 256-colour cube.
	ProfileANSI256
	// ProfileTrueColor is 24-bit colour.
	ProfileTrueColor
)

// renderers is one lipgloss renderer per depth, owned by this package. They
// write nowhere: only Render's return value is used, so a stray
// fmt.Fprintf can never pick a profile up from them. The global default
// renderer is never touched, and neither HasDarkBackground nor AdaptiveColor
// is ever called: both query the terminal and read stdin.
var renderers = func() [4]*lipgloss.Renderer {
	profiles := [4]termenv.Profile{termenv.Ascii, termenv.ANSI, termenv.ANSI256, termenv.TrueColor}
	var rs [4]*lipgloss.Renderer
	for i, p := range profiles {
		r := lipgloss.NewRenderer(io.Discard, termenv.WithProfile(p))
		r.SetColorProfile(p)
		rs[i] = r
	}
	return rs
}()

// The 16 ANSI names the ink roles and the collapsed ramp draw from.
const (
	ansiRed    = "1"
	ansiGreen  = "2"
	ansiYellow = "3"
	ansiBlue   = "4"
	ansiCyan   = "6"
)

// inkBase is the ANSI-depth style every ink role extends. Tabs survive it
// untouched: an inked table header goes on to meet tabwriter, which counts
// its own columns.
var (
	inkBase    = renderers[ProfileANSI].NewStyle().TabWidth(lipgloss.NoTabConversion)
	inkLabel   = inkBase.Bold(true)
	inkMuted   = inkBase.Faint(true)
	inkOk      = inkBase.Foreground(lipgloss.Color(ansiGreen))
	inkWarn    = inkBase.Foreground(lipgloss.Color(ansiYellow))
	inkErr     = inkBase.Foreground(lipgloss.Color(ansiRed))
	inkCmd     = inkBase.Foreground(lipgloss.Color(ansiCyan))
	plainStyle = renderers[ProfileNone].NewStyle().TabWidth(lipgloss.NoTabConversion)
)

// ink renders text in one lipgloss style, or returns it unchanged when
// colour is off or there is nothing to emphasise. Each line is rendered on
// its own so a block never picks up the padding lipgloss would align it to.
func (s Style) ink(st lipgloss.Style, text string) string {
	if !s.Color || text == "" {
		return text
	}
	if !strings.Contains(text, "\n") {
		return st.Render(text)
	}
	lines := strings.Split(text, "\n")
	for i, line := range lines {
		if line != "" {
			lines[i] = st.Render(line)
		}
	}
	return strings.Join(lines, "\n")
}

// levelStops is the ramp of section 3a of docs/cli-style.md as RGB: deep
// blue at the noise floor, then cyan, green, yellow and red at full scale.
// The stops sit on the edges of the colour cube so interpolating between
// them sweeps the hue monotonically from cold to hot.
var levelStops = [5][3]float64{
	{0, 0, 160},   // deep blue
	{0, 190, 220}, // cyan
	{0, 200, 60},  // green
	{215, 210, 0}, // yellow
	{220, 30, 20}, // red
}

// levelNames is the same ramp collapsed to five of the 16 ANSI names, for a
// terminal that reports no more depth than that.
var levelNames = [5]string{ansiBlue, ansiCyan, ansiGreen, ansiYellow, ansiRed}

// Level inks text with the ramp that stands for frac, a level normalised to
// [0, 1] (anything outside is clamped; a NaN reads as the floor). It is the
// only ink that uses more depth than the 16 ANSI names, because a spectrum
// carries level by hue and sixteen colours cannot express a gradient.
//
// It degrades by profile, not by branch: ProfileTrueColor renders the
// gradient, ProfileANSI256 the nearest cube colour, ProfileANSI the five
// named colours, and no colour at all returns text unchanged. A reader with
// colour off still has the eight-level block ramp from Glyphs, so level
// survives as height.
func (s Style) Level(frac float64, text string) string {
	if !s.Color || text == "" {
		return text
	}
	f := clamp01(frac)
	p := s.Profile
	if p < ProfileANSI || p > ProfileTrueColor {
		// A style built by hand says Color without a depth: the named
		// sixteen are always safe.
		p = ProfileANSI
	}
	color := levelHex(f)
	if p == ProfileANSI {
		color = levelNames[nearestStop(f)]
	}
	return s.ink(renderers[p].NewStyle().TabWidth(lipgloss.NoTabConversion).Foreground(lipgloss.Color(color)), text)
}

// levelHex is the ramp as a hex colour, interpolated between the two stops
// frac falls between. lipgloss downsamples it to whatever the profile can
// draw.
func levelHex(frac float64) string {
	last := len(levelStops) - 1
	x := frac * float64(last)
	i := int(x)
	if i >= last {
		c := levelStops[last]
		return fmt.Sprintf("#%02X%02X%02X", int(c[0]), int(c[1]), int(c[2]))
	}
	t := x - float64(i)
	lo, hi := levelStops[i], levelStops[i+1]
	mix := func(n int) int { return int(lo[n] + (hi[n]-lo[n])*t + 0.5) }
	return fmt.Sprintf("#%02X%02X%02X", mix(0), mix(1), mix(2))
}

// nearestStop picks the ramp stop frac is closest to.
func nearestStop(frac float64) int {
	last := len(levelStops) - 1
	i := int(frac*float64(last) + 0.5)
	if i > last {
		i = last
	}
	return i
}

// Borders for Box, in both alphabets. The ASCII fallback is the same shape
// drawn with the characters section 4 already uses for a rule and a trunk.
var (
	roundedBorder = lipgloss.RoundedBorder()
	asciiBorder   = lipgloss.Border{
		Top: "-", Bottom: "-", Left: "|", Right: "|",
		TopLeft: "+", TopRight: "+", BottomLeft: "+", BottomRight: "+",
	}
)

// BoxPadding is the number of columns a Box adds to its content: a border
// and a space on each side. A caller sizing a chart to the terminal
// subtracts it before it renders.
const BoxPadding = 4

// Box frames content in a rounded border (ASCII when the style is not
// Unicode), one space of padding on each side. Lines are measured by visible
// width, so content that is already inked frames correctly, and the frame
// itself never emits SGR: it is glyphs, so it survives colour being off.
func (s Style) Box(content string) string {
	border := asciiBorder
	if s.Unicode {
		border = roundedBorder
	}
	return plainStyle.Border(border).Padding(0, 1).Render(content)
}
