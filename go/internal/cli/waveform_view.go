package cli

import (
	"fmt"
	"math"
	"strings"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
)

// waveformMinCols is the narrowest clip the view will draw into; the style
// never resolves a width below 40, so it is a floor and not a layout.
const waveformMinCols = 16

// waveformCol is one column of the picture: the slice of the stream it covers,
// measured, and never the samples themselves.
type waveformCol struct {
	// present is false for a column the run has not reached yet, which is
	// drawn as the blank it is rather than as silence.
	present bool
	index   uint64
	seconds float64
	// open is the daemon's squelch over the slice. A closed slice is left
	// blank, because a gap between transmissions should look like a gap.
	open bool
	// dc is the slice's offset, removed from the envelope on the demod tap
	// and named in the header.
	dc float64
	// peak is the envelope the column draws, above and below the centre.
	peak              float64
	peakDbfs, rmsDbfs float64
}

// waveformFrame is one still of the clip: the window of columns, oldest first,
// and what the daemon says about the stream they came from.
type waveformFrame struct {
	cols []waveformCol
	tap  leylinev1.AudioTap
	what string
	// seconds is how much of the past the window holds, which is what the
	// axis counts back through.
	seconds float64
	// dc is the offset taken out of the newest column, NaN on a tap that
	// keeps its own.
	dc          float64
	squelchOpen bool
	// squelchKnown is false until the daemon has sent a meter, because a view
	// that announced a closed squelch before then would be guessing.
	squelchKnown bool
}

// waveformView draws the clip: a header of facts, the envelope under a
// playhead, and the seconds the picture runs back through.
type waveformView struct {
	st      ui.Style
	width   int
	seconds float64
	// scale is what --scale asked for; the frame is drawn at the number it
	// came out at, which under auto moves as the signal does.
	scale scopeScale
	// gutterW is the level axis left of the clip, sized the way the scope's
	// is, so a clip and a trace asked for the same --width line up.
	gutterW int
}

func newWaveformView(st ui.Style, width int, seconds float64, scale scopeScale) *waveformView {
	if width <= 0 {
		width = ui.DefaultWidth
	}
	return &waveformView{st: st, width: width, seconds: seconds, scale: scale, gutterW: scale.labelWidth() + 1}
}

// cols is the clip's width: the resolved width less the level axis and the
// playhead, which stand either side of it.
func (v *waveformView) cols() int {
	if c := v.width - v.gutterW - 1; c >= waveformMinCols {
		return c
	}
	return waveformMinCols
}

// render draws one still at the scale the frame was fitted to.
func (v *waveformView) render(f waveformFrame, scale float64) string {
	var b strings.Builder
	for _, l := range v.header(f, scale) {
		b.WriteString(l + "\n")
	}
	// The playhead is the now edge: the newest column is under it, and the
	// picture runs backwards from there.
	head := v.st.Label(v.st.Glyphs().TreeTrunk)
	for r := range scopeHeight {
		b.WriteString(scopeGutter(v.st, v.gutterW, r, scale) + v.row(f, r, scale) + head + "\n")
	}
	for _, l := range v.axis() {
		b.WriteString(l + "\n")
	}
	return b.String()
}

// header names the channel, the stage being drawn, how much of the past the
// picture holds, what the rows are worth, the offset the demod tap had taken
// out of it, and whether the squelch is passing anything.
func (v *waveformView) header(f waveformFrame, scale float64) []string {
	segs := []headerSeg{
		{value: f.what},
		{name: "tap ", value: scopeTapName(f.tap)},
		{value: fmt.Sprintf("%g s", f.seconds)},
	}
	if v.scale.named() {
		segs = append(segs, headerSeg{name: "scale ", value: fmt.Sprintf("±%g", scale)})
	}
	if !math.IsNaN(f.dc) {
		segs = append(segs, headerSeg{name: "dc removed ", value: fmt.Sprintf("%+.3f", f.dc)})
	}
	if f.squelchKnown {
		word, ink := "open", v.st.Ok
		if !f.squelchOpen {
			word, ink = "closed", v.st.Warn
		}
		segs = append(segs, headerSeg{
			name: "squelch ", value: ink(word), width: len("squelch ") + len(word),
		})
	}
	return packSegments(v.st, segs, v.width)
}

// row draws one row of the clip, a column at a time: the envelope where the
// window holds one, the centre rule through an open slice too quiet to draw,
// and blank where the squelch was shut or the run has not reached yet.
func (v *waveformView) row(f waveformFrame, r int, scale float64) string {
	line := &inkedLine{st: v.st}
	for _, c := range f.cols {
		cell, ink := v.cell(c, r, scale)
		line.add(cell, ink)
	}
	return line.String()
}

// cell is one column of one row. The envelope is drawn symmetric about the
// centre from the slice's peak, which is how an editor draws a clip: the
// picture is the shape of the transmission, not the wave inside it. Its ink
// is the level ramp for that peak, so a shout is hot and a murmur is cold
// before the height says so, in the same colours `ley levels` uses.
func (v *waveformView) cell(c waveformCol, r int, scale float64) (string, int) {
	if !c.present || !c.open {
		return " ", inkPlain
	}
	g := v.st.Glyphs()
	// Braille cells are 2 x 4 dots, so the picture resolves the envelope four
	// times as finely as the character grid the ASCII set has to draw it on.
	rows, dots := scopeHeight*4, 4
	if g.Trace != "" {
		rows, dots = scopeHeight, 1
	}
	top, bottom := scopeRow(c.peak, scale, rows), scopeRow(-c.peak, scale, rows)
	if bottom-top <= 1 {
		// An envelope that reaches no dot either side of the centre is under
		// the resolution of the picture, and a mark around the centre would
		// claim more of it than the view knows.
		return v.centre(r, scopeRow(0, scale, rows)/dots)
	}
	ink := levelsInk(levelsFrac(c.peakDbfs))
	if dots == 1 {
		if r < top || r > bottom {
			return " ", inkPlain
		}
		return string(g.BarFull), ink
	}
	// A column fills both dot columns of the cell it stands in, so the
	// envelope reads as a solid clip rather than as a comb.
	bits := byte(0)
	for dot := range dots {
		if d := r*dots + dot; d >= top && d <= bottom {
			bits |= brailleDots[0][dot] | brailleDots[1][dot]
		}
	}
	if bits == 0 {
		return " ", inkPlain
	}
	return string(rune(brailleBase + int(bits))), ink
}

// centre draws the rule a slice with nothing in it leaves behind: the line the
// clip is read against, which is what tells silence the squelch let through
// from silence it did not.
func (v *waveformView) centre(row, at int) (string, int) {
	if row != at {
		return " ", inkPlain
	}
	return string(v.st.Glyphs().Rule), inkMuted
}

// waveformStepsS are the tick spacings the axis may use: the round numbers a
// person counts seconds and minutes in.
var waveformStepsS = []float64{1, 2, 5, 10, 15, 30, 60}

// waveformAgeLabel writes how far back a mark stands, counting from the
// playhead: the past is behind the picture's now, so every mark is negative,
// the newest of them -0 s.
func waveformAgeLabel(age float64) string { return fmt.Sprintf("-%g s", age) }

// waveformTickStep picks the spacing: the finest round step that keeps the
// axis to eight marks and still leaves the width room to write them all.
func waveformTickStep(seconds float64, cols int) float64 {
	room := cols / (len(waveformAgeLabel(seconds)) + 2)
	for _, step := range waveformStepsS {
		if n := int(seconds/step) + 1; n <= 8 && n <= room {
			return step
		}
	}
	return waveformStepsS[len(waveformStepsS)-1]
}

// waveformTicks is the marks the axis draws: the round steps back from the
// playhead, oldest first. Two steps that land in one column are one mark.
func waveformTicks(seconds float64, cols int) []axisTick {
	if seconds <= 0 || cols <= 0 {
		return nil
	}
	step := waveformTickStep(seconds, cols)
	var ticks []axisTick
	last := -1
	for n := int(seconds / step); n >= 0; n-- {
		age := float64(n) * step
		c := int(math.Round(float64(cols-1) * (1 - age/seconds)))
		if c <= last {
			continue
		}
		ticks = append(ticks, axisTick{col: c, text: waveformAgeLabel(age)})
		last = c
	}
	return ticks
}

// axis draws the timebase under the clip: a rule with a mark at every labelled
// instant, then the labels. Time runs backwards from the playhead, because
// that is the direction the picture scrolls.
func (v *waveformView) axis() []string {
	g := v.st.Glyphs()
	cols := v.cols()
	ticks := waveformTicks(v.seconds, cols)
	rule := []rune(strings.Repeat(string(g.Rule), cols+1))
	for _, t := range ticks {
		rule[t.col+1] = []rune(g.TreeTrunk)[0]
	}
	return []string{
		strings.Repeat(" ", v.gutterW-1) + v.st.Muted(string(rule)),
		v.st.Muted(axisLabelRow(v.gutterW, cols, ticks)),
	}
}
