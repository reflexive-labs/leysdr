// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"fmt"
	"math"
	"strconv"
	"strings"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
)

// The pieces every live chart is built from. A spectrum, a meter, a trace, a
// clip and a map are five views of the same signal, so they share the same
// header, the same gutter, the same tick-and-label rule under the plot, the
// same border, and one colour ramp whose ends mean the same thing. Only the
// plot itself is specific to each view. `ui` stays the palette and the glyph
// layer underneath.

// How a chart carries level as colour. Every cell takes the ramp ink its own
// level lands on, so a noise floor reads cold and a carrier hot. The steps
// quantise the ramp so a row of eighty columns emits a handful of escape
// sequences rather than one per column: neighbouring cells that land on the
// same step share one run of ink.
const chartLevelSteps = 24

// The ink bands a chart cell can be drawn in. A non-negative band is a step of
// the level ramp (see chartLevelSteps); the two negative bands are the inks
// that are not keyed to a level. They are indices, not colours: a run of cells
// sharing one band is inked once, so a row carries a handful of escape
// sequences rather than one per column.
const (
	inkPlain = -1
	inkMuted = -2
	// inkLabel is the emphasis a mark carries when it is not a level: the peak
	// cap of a meter ladder stands over the ramp, not in it.
	inkLabel = -3
)

// inkedLine builds one chart row, merging neighbouring cells that share an ink
// band into a single run.
type inkedLine struct {
	st   ui.Style
	out  strings.Builder
	run  strings.Builder
	band int
	open bool
}

func (l *inkedLine) add(s string, band int) {
	if l.open && band != l.band {
		l.flush()
	}
	l.band, l.open = band, true
	l.run.WriteString(s)
}

func (l *inkedLine) flush() {
	if !l.open {
		return
	}
	text := l.run.String()
	l.run.Reset()
	l.open = false
	switch {
	case l.band == inkMuted:
		text = l.st.Muted(text)
	case l.band == inkLabel:
		text = l.st.Label(text)
	case l.band >= 0:
		text = l.st.Level(rampFrac(float64(l.band), 0, chartLevelSteps-1), text)
	}
	l.out.WriteString(text)
}

func (l *inkedLine) String() string {
	l.flush()
	return l.out.String()
}

// rampFrac is where a value sits on a chart's colour ramp: 0 at the cold end,
// 1 at the hot one, and clamped to both. Every chart keys its ink this way and
// only the two references differ -- the cold end is the noise line for
// `spectrum`, the bottom of the meter's scale for `levels`, and silence for
// the waveform -- so a colour means the same thing on every chart: how far
// the value sits above that chart's zero reference.
func rampFrac(value, floor, top float64) float64 {
	// A chart that has not measured its own references yet has no ramp to
	// place anything on, so everything sits at the cold end until it has.
	if math.IsNaN(value) || !(top > floor) {
		return 0
	}
	return math.Max(0, math.Min(1, (value-floor)/(top-floor)))
}

// rampBand quantises a ramp fraction onto the chart's ink steps, so
// neighbouring cells at one level share a single run of ink.
func rampBand(frac float64) int {
	return int(rampFrac(frac, 0, 1) * float64(chartLevelSteps-1))
}

// fmtDb is a level as a chart writes it: whole dB, no unit (the unit is
// written once, beside the top of the axis).
func fmtDb(db float64) string {
	if math.IsNaN(db) || math.IsInf(db, 0) {
		return "-"
	}
	return strconv.FormatFloat(math.Round(db), 'f', 0, 64)
}

// headerSeg is one fact in the header. The word that names it is Muted, the
// value it names is plain, and a whole segment that is scaffolding is Muted.
type headerSeg struct {
	name, value string
	dim         bool
	// inked marks a name that carries its own colour -- a legend swatch is the
	// ramp's own glyph -- so it is written verbatim: muting it would show a
	// shade the map never draws.
	inked bool
	// width overrides the measured width for a segment whose name is already
	// inked, where counting bytes would count escape sequences as columns.
	width int
}

func (s headerSeg) visible() int {
	if s.width > 0 {
		return s.width
	}
	return len(s.name) + len(s.value)
}

func (s headerSeg) render(st ui.Style) string {
	if s.dim {
		return st.Muted(s.name + s.value)
	}
	if s.inked {
		return s.name + s.value
	}
	return st.Muted(s.name) + s.value
}

// tapSeg shows which stage of the channel the view is drawing. Every other
// number in the header is measured at that stage.
func tapSeg(tap leylinev1.AudioTap) headerSeg {
	return headerSeg{name: "tap ", value: scopeTapName(tap)}
}

// squelchSeg shows whether the squelch is open, inked by state, so a view
// whose picture goes blank shows why on the same screen.
func squelchSeg(st ui.Style, open bool) headerSeg {
	word, ink := "open", st.Ok
	if !open {
		word, ink = "closed", st.Warn
	}
	return headerSeg{name: "squelch ", value: ink(word), width: len("squelch ") + len(word)}
}

// packSegments lays facts out greedily across as many lines as the width needs,
// so a narrow terminal gets more lines rather than a truncated fact.
func packSegments(st ui.Style, segs []headerSeg, width int) []string {
	var lines []string
	var cur strings.Builder
	curw := 0
	for _, s := range segs {
		w := s.visible()
		switch {
		case curw == 0:
			cur.WriteString(s.render(st))
			curw = w
		case curw+2+w <= width:
			cur.WriteString("  " + s.render(st))
			curw += 2 + w
		default:
			lines = append(lines, cur.String())
			cur.Reset()
			cur.WriteString(s.render(st))
			curw = w
		}
	}
	if curw > 0 {
		lines = append(lines, cur.String())
	}
	return lines
}

// chartFrameMinWidth is the narrowest terminal that gets a frame around a
// chart. The border and its padding cost ui.BoxPadding columns of chart, which
// a cramped screen cannot spare.
const chartFrameMinWidth = 60

// chartFramed says whether a view may draw the border: the caller has to want
// one -- a pipe never does -- and the screen has to have both the alphabet and
// the columns for it. Every chart answers it the same way, so a spectrum and a
// meter side by side either both carry a frame or neither does.
func chartFramed(st ui.Style, width int, frame bool) bool {
	return frame && st.Unicode && width >= chartFrameMinWidth
}

// chartInner is the width a framed view's picture may use: the whole width,
// less what the border and its padding spend. A frame costs resolution rather
// than overflowing the terminal, so every view subtracts it before it lays
// anything out.
func chartInner(width int, framed bool) int {
	if framed {
		return width - ui.BoxPadding
	}
	return width
}

// chartFrame puts the border round a picture. The plot, its scale and their
// labels are framed together; the header sits above the frame, outside it.
func chartFrame(st ui.Style, framed bool, chart string) string {
	if !framed {
		return chart
	}
	return st.Box(strings.TrimRight(chart, "\n")) + "\n"
}

// chartGutterLabel right-aligns a value in the gutter's label field: the
// columns left of the unit, which is written once beside the top of the scale.
// The axis column is the caller's -- the rule glyph on a plot row, the start
// of the axis rule under it -- so the field is a column short of the gutter.
func chartGutterLabel(width int, label, unit string) string {
	return fmt.Sprintf("%*s", width-1-len(unit), label)
}

// chartGutterField is the gutter without its axis column: the value in
// whatever ink the caller wants it in -- a spectrum writes its levels plain so
// they read over the trace beside them -- and the unit, which is scaffolding
// wherever it appears.
func chartGutterField(st ui.Style, width int, label, unit string) string {
	return chartGutterLabel(width, label, unit) + st.Muted(unit)
}

// chartGutter is the whole gutter of one plot row, the axis column included
// and the value muted with the rest of the scale.
func chartGutter(st ui.Style, width int, label, unit string) string {
	return st.Muted(chartGutterLabel(width, label, unit) + unit + st.Glyphs().TreeTrunk)
}

// axisTick is one mark of an axis: the plot column it falls in and what is
// written under it.
type axisTick struct {
	col  int
	text string
}

// axisRule draws the line under a plot, with a mark at every labelled column.
// It starts one column early, in the axis column the gutter ends in, so the
// rule under the plot and the scale beside it meet at the corner.
func axisRule(st ui.Style, cols int, ticks []axisTick) string {
	g := st.Glyphs()
	rule := []rune(strings.Repeat(string(g.Rule), cols+1))
	for _, t := range ticks {
		if t.col+1 < len(rule) {
			rule[t.col+1] = []rune(g.TreeTrunk)[0]
		}
	}
	return st.Muted(string(rule))
}

// axisLabelRow writes each mark's text under it, dropping any label the width
// cannot fit beside its neighbour: two labels with no gap read as one wrong
// number. width is the whole row, gutter included, because a label at the
// right edge is pulled back to fit rather than dropped.
func axisLabelRow(gutterW, width int, ticks []axisTick) string {
	row := make([]byte, 0, width)
	for _, t := range ticks {
		at := gutterW + t.col - len(t.text)/2
		if at < gutterW {
			at = gutterW
		}
		if at+len(t.text) > width {
			at = width - len(t.text)
		}
		if at < len(row)+1 || at < gutterW {
			continue
		}
		row = append(row, strings.Repeat(" ", at-len(row))...)
		row = append(row, t.text...)
	}
	return string(row)
}

// liveStreamEnd is what a live view does when its bulk stream closes: nothing
// on Ctrl-C, the daemon's error where there is one, and otherwise a sentence
// explaining the close, because the daemon never closes a stream as normal
// completion. The daemon closes a stream when its descriptor is out of date
// (a rate, mode or bandwidth write re-planned the channel) or when the channel
// or its capture goes away; a clean exit would leave a frozen picture with no
// explanation. A run that reaches --count returns before the stream closes, so
// it never lands here. `stream` names the stream and `unit` what one picture
// of it is called.
func liveStreamEnd(ctx context.Context, err error, drawn int, stream, unit string) error {
	if ctx.Err() != nil {
		return nil
	}
	if err != nil {
		return err
	}
	if drawn == 0 {
		return fmt.Errorf("the %s ended before a %s could be drawn. Check the channel is still running with: ley state", stream, unit)
	}
	return fmt.Errorf("the daemon ended the %s after %s: the channel it read was changed, stopped or destroyed. Check it with: ley state, then run the command again", stream, plural(drawn, unit))
}

// chartAxis is the timebase under a trace or a clip: the rule, then the
// labels, both of them muted, and both starting where the gutter ends.
func chartAxis(st ui.Style, gutterW, cols int, ticks []axisTick) []string {
	return []string{
		strings.Repeat(" ", gutterW-1) + axisRule(st, cols, ticks),
		st.Muted(axisLabelRow(gutterW, gutterW+cols, ticks)),
	}
}
