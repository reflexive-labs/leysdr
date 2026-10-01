// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"fmt"
	"math"
	"strings"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
)

// The trace's geometry. The height is fixed rather than taken from the
// terminal: the picture is redrawn in place, and a block that grows to fill
// the screen cannot be. Eight rows of braille is 32 dots over full scale,
// which resolves a sixteenth of a division.
const (
	scopeHeight  = 8
	scopeMinCols = 16
	// scopeMinDbfs is where the level scale stops. Digital silence has no
	// level at all, and a row carrying negative infinity is not JSON.
	scopeMinDbfs = -120
)

// brailleBase is the blank cell; every pattern is an offset from it.
const brailleBase = 0x2800

// brailleDots are the bits of a braille cell's 2 x 4 dots, indexed by column
// then by row from the top.
var brailleDots = [2][4]byte{
	{0x01, 0x02, 0x04, 0x40},
	{0x08, 0x10, 0x20, 0x80},
}

// scopeFrame is one window as the view draws it: the samples, the statistics
// taken over them, and what the daemon reports about them.
type scopeFrame struct {
	samples  []float32
	tap      leylinev1.AudioTap
	windowMs int
	// scale is how far from the centre the top row stands, in the tap's units.
	scale    float64
	peakDbfs float64
	rmsDbfs  float64
	// tuningHz reads the DC offset as a tuning error, NaN where the mode and
	// the tap give it no such meaning.
	tuningHz float64
	// fullScaleHz is what the top of the trace is worth in hertz, 0 on a tap
	// whose samples are amplitude.
	fullScaleHz uint32
	// what names the channel: its frequency and mode.
	what string
	// tone is the daemon's sub-audible report, nil until it has made one. The
	// view never estimates a tone itself: the trace shows the samples and the
	// header shows the daemon's report, and the two may disagree.
	tone *leylinev1.SubAudible
	// muted says the daemon's squelch is closed on a tap that the squelch
	// silences, which is why the trace is flat under a header that may still
	// name a tone.
	muted bool
}

// scopeView draws one window of samples: a header of facts, then the trace.
type scopeView struct {
	st    ui.Style
	width int
	// scale is what --scale asked for; the frame carries the number it came
	// out at, which under auto moves from frame to frame.
	scale scopeScale
	// gutterW is the level axis left of the trace: as many columns as the
	// run's scale labels need, plus the axis column itself. It is fixed for
	// the run, so the trace does not change width when the scale does, and it
	// comes out of the width the way the spectrum's level axis does, so a
	// trace and a chart asked for the same --width are the same width.
	gutterW int
	// framed draws the trace and its timebase inside a Box, the way the
	// spectrum's chart is framed, with the header above it.
	framed bool
}

func newScopeView(st ui.Style, width int, scale scopeScale, frame bool) *scopeView {
	if width <= 0 {
		width = ui.DefaultWidth
	}
	return &scopeView{
		st: st, width: width, scale: scale,
		gutterW: scale.labelWidth() + 1, framed: chartFramed(st, width, frame),
	}
}

// inner is the width the trace and its timebase may use: the whole width, less
// what the frame spends on its border and padding when there is one.
func (v *scopeView) inner() int { return chartInner(v.width, v.framed) }

// cols is the trace's width: the width inside any frame, less the level axis,
// which stands left of it.
func (v *scopeView) cols() int {
	if c := v.inner() - v.gutterW; c >= scopeMinCols {
		return c
	}
	return scopeMinCols
}

func (v *scopeView) render(f scopeFrame) string {
	var b strings.Builder
	for _, l := range v.header(f) {
		b.WriteString(l + "\n")
	}
	var chart strings.Builder
	for r, l := range v.trace(f.samples, f.scale) {
		chart.WriteString(v.gutter(r, f.scale) + l + "\n")
	}
	for _, l := range v.axis(f.windowMs) {
		chart.WriteString(l + "\n")
	}
	// The trace and the milliseconds under it are one object and are framed as
	// one; the header reads as prose above it and stays outside.
	b.WriteString(chartFrame(v.st, v.framed, chart.String()))
	return b.String()
}

// header names the channel, which stage of it is being drawn, how much of it
// fits in the frame, and how loud it is. On the demod tap of an FM mode the DC
// offset is a tuning error in hertz, which is what that offset means there.
func (v *scopeView) header(f scopeFrame) []string {
	segs := []headerSeg{
		{value: f.what},
		tapSeg(f.tap),
		{name: "window ", value: fmt.Sprintf("%d ms", f.windowMs)},
		{name: "peak ", value: fmtDb(f.peakDbfs) + " dBFS"},
		{name: "rms ", value: fmtDb(f.rmsDbfs) + " dBFS"},
	}
	if v.scale.named() {
		segs = append(segs, headerSeg{name: "scale ", value: fmt.Sprintf("±%g", f.scale)})
	}
	if note := fullScaleNote(f.tap, f.fullScaleHz); note != "" {
		segs = append(segs, headerSeg{name: "full scale ", value: note})
	}
	if !math.IsNaN(f.tuningHz) {
		segs = append(segs, headerSeg{name: "tuning ", value: fmt.Sprintf("%+.0f Hz", f.tuningHz)})
	}
	if tone := scopeToneText(f.tone); tone != "" {
		segs = append(segs, headerSeg{name: "PL ", value: tone})
	}
	if code := dcsHeader(f.tone); code != "" {
		segs = append(segs, headerSeg{name: "DCS ", value: code})
	}
	lines := packSegments(v.st, segs, v.width)
	if f.muted {
		for _, l := range scopeMutedNote(v.width) {
			lines = append(lines, v.st.Muted(l))
		}
	}
	return lines
}

// scopeMutedNote says why the trace is flat when the daemon's squelch is shut,
// and where to look instead: a header that still names a PL tone over a flat
// audio trace otherwise reads as "the tone is there but my voice is not".
// The two halves go on one line where the width takes them, because they are
// one sentence.
func scopeMutedNote(width int) []string {
	const (
		what  = "squelch closed: the audio tap is muted;"
		where = "--tap demod shows what the detector hears"
	)
	if len(what)+1+len(where) <= width {
		return []string{what + " " + where}
	}
	return []string{what, where}
}

// dcsHeader is the DCS code for a view's header, "023" or "023 inverted", or
// nothing when the daemon reports no code. The JSON rows carry no code: tone_hz
// is a CTCSS tone's, and the code is the telemetry's (docs/design/signal-views.md,
// "DCS").
func dcsHeader(sa *leylinev1.SubAudible) string {
	if sa == nil || sa.Kind != leylinev1.SubAudibleKind_SUB_AUDIBLE_DCS {
		return ""
	}
	return dcsText(sa)
}

// scopeToneText is the daemon's sub-audible report as one phrase: the tone it
// identified, then the measurement it identified it from.
func scopeToneText(sa *leylinev1.SubAudible) string {
	if sa == nil || sa.Kind != leylinev1.SubAudibleKind_SUB_AUDIBLE_CTCSS {
		return ""
	}
	// A measurement between two standard tones is reported as itself: naming
	// one of the two would be a guess.
	named := sa.StandardToneHz
	if named == 0 {
		named = sa.ToneHz
	}
	if math.IsNaN(named) {
		return ""
	}
	var parts []string
	if !math.IsNaN(sa.ToneHz) {
		parts = append(parts, fmt.Sprintf("measured %.2f Hz", sa.ToneHz))
	}
	if !math.IsNaN(sa.ToneSnrDb) {
		parts = append(parts, fmt.Sprintf("%.0f dB", sa.ToneSnrDb))
	}
	if sa.Confidence > 0 {
		parts = append(parts, fmt.Sprintf("confidence %.1f", sa.Confidence))
	}
	text := fmt.Sprintf("%.1f Hz", named)
	if len(parts) > 0 {
		text += " (" + strings.Join(parts, ", ") + ")"
	}
	return text
}

// fullScaleNote says what ±1.0 on the tap is worth, for the views whose rows
// are fractions of it. An FM channel's full scale follows its own bandwidth,
// so a narrow radio and a broadcast one fill the same rows for very different
// deviations and a reader who knew only the mode would read the picture
// wrong. "" where the samples are amplitude and stand for no deviation.
func fullScaleNote(tap leylinev1.AudioTap, fullScaleHz uint32) string {
	if tap != leylinev1.AudioTap_TAP_DEMOD || fullScaleHz == 0 {
		return ""
	}
	return "±" + formatBandwidth(fullScaleHz)
}

// scopeTapName is the tap as the flag spells it.
func scopeTapName(tap leylinev1.AudioTap) string {
	if tap == leylinev1.AudioTap_TAP_DEMOD {
		return "demod"
	}
	return "audio"
}

// trace draws the window across the width. Each column covers a span of
// samples and is drawn from the lowest to the highest of them, so a waveform
// that swings between one column and the next reads as a line rather than as
// two dots with a hole between them.
func (v *scopeView) trace(samples []float32, scale float64) []string {
	cols := v.cols()
	if g := v.st.Glyphs(); g.Trace != "" {
		return v.levelTrace(samples, cols, []rune(g.Trace), scale)
	}
	return v.brailleTrace(samples, cols, scale)
}

// brailleTrace draws with 2 x 4 dot cells: eight times the detail of the
// character grid, at the cost of a glyph set not every terminal has.
func (v *scopeView) brailleTrace(samples []float32, cols int, scale float64) []string {
	dotCols, dotRows := cols*2, scopeHeight*4
	cells := make([][]byte, scopeHeight)
	for r := range cells {
		cells[r] = make([]byte, cols)
	}
	for x := range dotCols {
		lo, hi, ok := scopeSpan(samples, x, dotCols)
		if !ok {
			continue
		}
		for r := scopeRow(hi, scale, dotRows); r <= scopeRow(lo, scale, dotRows); r++ {
			cells[r/4][x/2] |= brailleDots[x%2][r%4]
		}
	}
	out := make([]string, scopeHeight)
	for r, row := range cells {
		var b strings.Builder
		for _, bits := range row {
			b.WriteRune(rune(brailleBase + int(bits)))
		}
		// A row the trace never reaches is blank to the right, and a line of
		// blank cells is trailing whitespace with a codepoint.
		out[r] = strings.TrimRight(b.String(), string(rune(brailleBase)))
	}
	return out
}

// levelTrace is the same picture in the ASCII alphabet: one glyph per column,
// carrying the level in its height, so a cell resolves three levels instead of
// a braille cell's four rows of two.
func (v *scopeView) levelTrace(samples []float32, cols int, glyphs []rune, scale float64) []string {
	steps := len(glyphs)
	levels := scopeHeight * steps
	grid := make([][]rune, scopeHeight)
	for r := range grid {
		grid[r] = []rune(strings.Repeat(" ", cols))
	}
	for x := range cols {
		lo, hi, ok := scopeSpan(samples, x, cols)
		if !ok {
			continue
		}
		top, bottom := scopeRow(hi, scale, levels), scopeRow(lo, scale, levels)
		for r := top / steps; r <= bottom/steps; r++ {
			// The cell shows the middle of the span it covers: a column that
			// crosses the whole cell has no one level to name, and its middle
			// is the one that keeps the stroke continuous.
			first, last := max(top, r*steps), min(bottom, (r+1)*steps-1)
			grid[r][x] = glyphs[steps-1-((first+last)/2-r*steps)]
		}
	}
	out := make([]string, scopeHeight)
	for r, row := range grid {
		out[r] = strings.TrimRight(string(row), " ")
	}
	return out
}

// scopeSpan is the range of the samples drawn in one column, and whether the
// column has any. A window with fewer samples than columns still draws: the
// nearest sample stands for the column.
func scopeSpan(samples []float32, col, cols int) (lo, hi float64, ok bool) {
	if len(samples) == 0 || cols <= 0 {
		return 0, 0, false
	}
	from, to := col*len(samples)/cols, (col+1)*len(samples)/cols
	if to <= from {
		to = from + 1
	}
	if from >= len(samples) {
		return 0, 0, false
	}
	lo, hi = math.Inf(1), math.Inf(-1)
	for _, s := range samples[from:min(to, len(samples))] {
		lo, hi = math.Min(lo, float64(s)), math.Max(hi, float64(s))
	}
	return lo, hi, true
}

// scopeRow maps a sample to a row from the top, over a vertical scale of
// ±scale. The gutter and the header say what the rows are worth, since the
// fitted scale moves between frames, and a sample past the scale is drawn at
// the edge rather than off the picture.
func scopeRow(v, scale float64, rows int) int {
	if math.IsNaN(v) {
		v = 0
	}
	if scale <= 0 {
		scale = 1
	}
	r := int(math.Round((1 - math.Max(-1, math.Min(1, v/scale))) / 2 * float64(rows-1)))
	return max(0, min(rows-1, r))
}
