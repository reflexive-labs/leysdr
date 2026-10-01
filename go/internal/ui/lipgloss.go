// SPDX-License-Identifier: Apache-2.0

package ui

import (
	"fmt"
	"io"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"
)

// Profile is the colour depth one stream reports. It exists for the level
// ramp only (section 3a of docs/dev/cli-style.md): every other ink role stays on
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
	ansiCyan   = "6"
	// ansiBrightRed is the level ramp's fourth stop; see levelNames.
	ansiBrightRed = "9"
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

// levelStops is the ramp of section 3a of docs/dev/cli-style.md as RGB: teal
// at the noise floor, then green, amber, orange and a salmon red at full
// scale. The hue sweeps monotonically from cold to hot. The stops are the
// brand's terminal ramp, sampled from the design system's dashboard mock, with
// a known trade-off: they are tuned for a dark
// ground, and ley is forbidden from asking which ground it is on (no OSC
// query, no HasDarkBackground). Every stop clears 3.9:1 against #1e1e1e; on
// white the cold end drops to 2.6:1, so a light terminal reads the noise
// floor faint. Level is carried by height and texture as well as hue, which
// is what keeps that chart readable. Holding every stop in one luminance band
// clears 3.2:1 on both grounds but reads as thin on a dark terminal.
// level_contrast_test.go holds the dark bar and a floor on white, so no stop
// can drift to invisible on either: a saturated {0,0,160} cold end is 1.2:1
// on a dark terminal and hides most of every chart.
var levelStops = [5][3]float64{
	{88, 176, 160}, // teal
	{104, 160, 96}, // green
	{168, 136, 64}, // amber
	{216, 128, 80}, // orange
	{192, 96, 80},  // salmon red
}

// levelNames is the same ramp collapsed to five of the 16 ANSI names, for a
// terminal that reports no more depth than that. Orange takes bright red,
// which most themes draw as a lighter orange-red, so the top two stops stay
// distinct.
var levelNames = [5]string{ansiCyan, ansiGreen, ansiYellow, ansiBrightRed, ansiRed}

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
	r, g, b := LevelRGB(frac)
	return fmt.Sprintf("#%02X%02X%02X", r, g, b)
}

// LevelRGB is the level ramp of section 3a as a colour: the same five stops
// Level inks a terminal with, interpolated for frac in [0, 1] (clamped; a
// NaN reads as the floor). It exists for a renderer that draws pixels rather
// than cells -- the MCP adapter's snapshot PNG -- so a level is the same
// colour on a picture as on the terminal chart of the same row.
func LevelRGB(frac float64) (r, g, b uint8) {
	f := clamp01(frac)
	last := len(levelStops) - 1
	x := f * float64(last)
	i := int(x)
	if i >= last {
		c := levelStops[last]
		return uint8(c[0]), uint8(c[1]), uint8(c[2])
	}
	t := x - float64(i)
	lo, hi := levelStops[i], levelStops[i+1]
	mix := func(n int) uint8 { return uint8(lo[n] + (hi[n]-lo[n])*t + 0.5) }
	return mix(0), mix(1), mix(2)
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
