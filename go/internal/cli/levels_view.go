package cli

import (
	"fmt"
	"math"
	"strings"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
)

// The meter's geometry. The gutter holds the widest mark (-60) and the axis
// beside it; the bars are two cells wide with a gap, three where the width
// allows, because an LED ladder one cell wide reads as a line rather than as a
// bar. Height is the terminal's to limit but not to choose: twelve rows put
// every mark of the scale on its own row.
const (
	levelsGutterW = 5
	levelsHeight  = 12
	levelsMinRows = 6
	levelsMaxRows = 24
	// levelsThirdCols is the width a third-octave meter needs before it is
	// drawn: twenty-five bars below that are too thin to read a level off.
	levelsThirdCols = 100
	// levelsNarrowCols is where the nine octaves drop to the six speech lives
	// in, and where the master pair loses its words.
	levelsNarrowCols = 44
	levelsWordsCols  = 60
	// levelsMinCols is the narrowest plot the meter will draw into; the style
	// never resolves a width below 40, so it is a floor and not a layout.
	levelsMinCols = 20
	// levelsMasterGap separates the master pair from the bands, so the eye
	// reads them as a second instrument rather than as two more bands, and
	// leaves the band labels room for their unit.
	levelsMasterGap = 5
)

// levelsFrame is one still of the meter: what the bars stand at after the
// ballistics, and the daemon's own numbers, which are never smoothed.
type levelsFrame struct {
	bands []levelsBar
	// rms and peak are the master pair, from the daemon's meter.
	rms, peak levelsBar
	// rmsDb and peakDb are what the current meter says, which is what the
	// numbers under the pair print: the bars move, the numbers do not lie.
	rmsDb, peakDb float64
	tap           leylinev1.AudioTap
	what          string
	squelchOpen   bool
	// squelchKnown is false until the daemon has sent a meter, because a view
	// that announced a closed squelch before then would be guessing.
	squelchKnown bool
	tone         *leylinev1.SubAudible
}

// levelsView draws the meter: a header of facts, the ladders, and the scale
// they are read against.
type levelsView struct {
	st     ui.Style
	width  int
	height int
	bands  []levelsBand
	// bar and gap are the ladder's width and the space between two of them.
	bar, gap int
	// x is the left column of every bar inside the plot: the bands in order,
	// then rms and peak.
	x []int
}

// newLevelsView fits the meter to the width: the third-octave set only on a
// screen wide enough to draw it, the six speech bands on a narrow one, and the
// widest bars and gaps the bands and the master pair both fit in.
func newLevelsView(st ui.Style, width, height int, third bool) *levelsView {
	if width <= 0 {
		width = ui.DefaultWidth
	}
	centres := levelsOctaveHz
	edge := levelsOctaveEdge
	switch {
	case width < levelsNarrowCols:
		centres = levelsNarrowHz
	case third && width >= levelsThirdCols:
		centres, edge = levelsThirdHz, levelsThirdEdge
	}
	v := &levelsView{
		st: st, width: width, height: min(max(height, levelsMinRows), levelsMaxRows),
		bands: levelsBands(centres, edge), bar: 2, gap: 1,
	}
	plot := v.cols()
	n := len(v.bands)
	for _, bar := range []int{3, 2} {
		for _, gap := range []int{3, 2, 1} {
			if levelsSpan(n, bar, gap) <= plot {
				v.bar, v.gap = bar, gap
				v.layout(n)
				return v
			}
		}
	}
	v.layout(n)
	return v
}

// levelsSpan is how many columns a meter of n bands takes at this bar width
// and gap: the bands, then the master pair beyond a wider gap of its own.
func levelsSpan(n, bar, gap int) int {
	return n*(bar+gap) - gap + levelsMasterGap + 2*bar + levelsPairGap(gap)
}

// levelsPairGap is the space inside the master pair. It is never as tight as
// the bands' gap, because "rms" and "peak" are written under those two bars
// and a label that collides with its neighbour is dropped.
func levelsPairGap(gap int) int { return max(gap, 3) }

// layout places the bars: the bands packed from the left, then the master pair
// beyond a gap of its own, so the meter is one block whatever the width is and
// the pair reads as a second instrument rather than as two more bands.
func (v *levelsView) layout(n int) {
	v.x = make([]int, 0, n+2)
	for i := range n {
		v.x = append(v.x, i*(v.bar+v.gap))
	}
	rms := n*(v.bar+v.gap) - v.gap + levelsMasterGap
	v.x = append(v.x, rms, rms+v.bar+levelsPairGap(v.gap))
}

// cols is the plot's width: everything right of the gutter.
func (v *levelsView) cols() int { return max(v.width-levelsGutterW, levelsMinCols) }

// levelsOverWord is what an overload says. It is latched rather than drawn
// while it lasts: an overload is a thing that happened, and a flash too short
// to read is the same as no warning at all.
const levelsOverWord = "OVER"

// render draws one still of the meter: the header, the overload line, the
// ladders against their scale, and the labels that say what each one is.
func (v *levelsView) render(f levelsFrame) string {
	bars := make([]levelsBar, 0, len(f.bands)+2)
	bars = append(bars, f.bands...)
	bars = append(bars, f.rms, f.peak)
	var b strings.Builder
	for _, l := range v.header(f) {
		b.WriteString(l + "\n")
	}
	if over := v.overRow(bars); over != "" {
		b.WriteString(over + "\n")
	}
	for r := range v.height {
		b.WriteString(v.row(r, bars) + "\n")
	}
	b.WriteString(v.axis() + "\n")
	for _, l := range v.labels(f) {
		b.WriteString(l + "\n")
	}
	return b.String()
}

// header names the channel, the stage being measured, whether the squelch is
// passing anything, and the tone the daemon says is under it.
func (v *levelsView) header(f levelsFrame) []string {
	segs := []headerSeg{
		{value: f.what},
		{name: "tap ", value: scopeTapName(f.tap)},
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
	// The tone the daemon named, and only that: a meter is read at a glance,
	// and the measurement behind the name is `ley scope`'s header to carry.
	if hz := scopeToneHz(f.tone); hz != nil {
		segs = append(segs, headerSeg{name: "PL ", value: fmt.Sprintf("%.1f Hz", *hz)})
	}
	return packSegments(v.st, segs, v.width)
}

// overRow lights OVER over every bar that reached full scale, and is absent
// when none has: a row of blank columns inside a frame reads as the end of one
// where frames are separated by a blank line.
func (v *levelsView) overRow(bars []levelsBar) string {
	plot := v.cols()
	var segs []levelsSeg
	for i, b := range bars {
		if b.over <= 0 {
			continue
		}
		segs = append(segs, levelsSeg{
			at:    levelsGutterW + min(v.x[i], plot-len(levelsOverWord)),
			text:  v.st.Err(levelsOverWord),
			width: len(levelsOverWord),
		})
	}
	return levelsTextRow(segs)
}

// reach is how many columns the ladders themselves take: the rules are drawn
// across the meter and not across the rest of the terminal.
func (v *levelsView) reach() int { return min(v.x[len(v.x)-1]+v.bar, v.cols()) }

// row draws one row of the meter: the mark it carries, the horizon where it
// falls, and a cell of every ladder.
func (v *levelsView) row(r int, bars []levelsBar) string {
	plot := v.reach()
	g := v.st.Glyphs()
	text := make([]string, plot)
	band := make([]int, plot)
	horizon := r == v.markRow(levelsHorizonDb)
	for c := range plot {
		// The alignment level is a dashed rule the eye reads the bars
		// against, the way the noise floor works in `ley spectrum`.
		if horizon && c%2 == 0 {
			text[c], band[c] = string(g.Rule), inkMuted
			continue
		}
		text[c], band[c] = " ", inkPlain
	}
	top := float64(v.height-r) / float64(v.height)
	bottom := float64(v.height-1-r) / float64(v.height)
	for i, bar := range bars {
		cell, ink := v.cell(bar, top, bottom)
		for c := v.x[i]; c < v.x[i]+v.bar && c < plot; c++ {
			text[c], band[c] = cell, ink
		}
	}
	line := &inkedLine{st: v.st}
	for c := range plot {
		line.add(text[c], band[c])
	}
	return v.gutter(r) + strings.TrimRight(line.String(), " ")
}

// cell is one segment of one ladder: the peak cap where it hangs, the lit
// segment where the bar reaches, and the dark segment everywhere else. The
// dark segments are drawn because that is what lets the eye read a level
// against the scale when nothing is playing, and the lit ones take the level
// ramp by their own height, so a bar is green in the working range, amber
// approaching -6 and red at the top whatever it is measuring.
func (v *levelsView) cell(b levelsBar, top, bottom float64) (string, int) {
	g := v.st.Glyphs()
	if held := levelsFrac(b.cap); b.cap > levelsFloorDb && held > bottom && held <= top {
		return string(g.RuleHeavy), inkLabel
	}
	fill := (levelsFrac(b.db) - bottom) * float64(v.height)
	if lit := v.st.Ramp(fill); strings.TrimSpace(lit) != "" {
		return lit, levelsInk((top + bottom) / 2)
	}
	return string(g.BarEmpty), inkMuted
}

// levelsInk is a height on the meter as a step of the chart's level ramp, so
// the ladders and `ley spectrum` say the same level in the same colour.
func levelsInk(frac float64) int {
	return max(0, min(spectrumLevelSteps-1, int(math.Round(frac*float64(spectrumLevelSteps-1)))))
}

// markRow is the row a level falls in, top row first.
func (v *levelsView) markRow(db float64) int {
	r := v.height - int(math.Ceil(levelsFrac(db)*float64(v.height)))
	return max(0, min(v.height-1, r))
}

// gutter is the scale beside one row: the mark that falls in it, if any, and
// the axis. Where a short meter puts two marks in one row the higher one is
// written, because it is the one nearer the levels a person is watching.
func (v *levelsView) gutter(r int) string {
	label := ""
	for _, m := range levelsMarks {
		if v.markRow(m) == r {
			label = fmtDb(m)
			break
		}
	}
	return v.st.Muted(fmt.Sprintf("%3s ", label) + v.st.Glyphs().TreeTrunk)
}

// axis rules the meter off from its labels, with a mark under each of the
// master pair: they are a second instrument, and the marks say so.
func (v *levelsView) axis() string {
	g := v.st.Glyphs()
	plot := min(v.reach()+levelsMasterGap-2, v.cols())
	rule := []rune(strings.Repeat(string(g.Rule), plot+1))
	for _, i := range []int{len(v.bands), len(v.bands) + 1} {
		if c := v.x[i] + v.bar/2 + 1; c < len(rule) {
			rule[c] = []rune(g.TreeTrunk)[0]
		}
	}
	return strings.Repeat(" ", levelsGutterW-1) + v.st.Muted(string(rule))
}

// labels writes what the bars are: the band centres under the ladders, then
// the master pair's words and its numbers. The numbers are the current row's
// own, in plain ink, because they are the answer the picture is read for; the
// bars around them are shaped by ballistics and the numbers never are.
//
// A narrow screen loses the words rather than the numbers, and the pair goes
// on the one line: "rms" and "peak" are what the reader can infer from where
// the bars stand, and -18 dBFS is not.
func (v *levelsView) labels(f levelsFrame) []string {
	segs := make([]levelsSeg, 0, len(v.bands)+3)
	for i, b := range v.bands {
		segs = append(segs, v.centred(i, levelsBandLabel(b.centerHz), true))
	}
	if last := v.x[len(v.bands)-1] + v.bar; last+3 <= v.x[len(v.bands)] {
		segs = append(segs, levelsSeg{at: levelsGutterW + last + 1, text: v.st.Muted("Hz"), width: 2})
	}
	rms, peak := len(v.bands), len(v.bands)+1
	if v.width < levelsWordsCols {
		segs = append(segs,
			v.centred(rms, fmtDb(f.rmsDb), false),
			v.centred(peak, fmtDb(f.peakDb), false))
		return []string{levelsTextRow(segs)}
	}
	segs = append(segs, v.centred(rms, "rms", true), v.centred(peak, "peak", true))
	numbers := []levelsSeg{
		v.centred(rms, fmtDb(f.rmsDb), false),
		v.centred(peak, fmtDb(f.peakDb), false),
	}
	// The unit is written once, after the numbers, and only where the width
	// has room for it: it names what the two figures are, and a figure that
	// wrapped would be worse than an unnamed one.
	if at := levelsGutterW + v.x[peak] + v.bar + 1; at+4 <= v.width {
		numbers = append(numbers, levelsSeg{at: at, text: v.st.Muted("dBFS"), width: 4})
	}
	return []string{levelsTextRow(segs), levelsTextRow(numbers)}
}

// centred places a label under a bar.
func (v *levelsView) centred(i int, text string, muted bool) levelsSeg {
	at := levelsGutterW + v.x[i] + v.bar/2 - len(text)/2
	s := levelsSeg{at: max(at, levelsGutterW), text: text, width: len(text)}
	if muted {
		s.text = v.st.Muted(text)
	}
	return s
}

// levelsSeg is one piece of a label row: where it starts, what it says, and
// how many columns that is once any ink is discounted.
type levelsSeg struct {
	at    int
	text  string
	width int
}

// levelsTextRow lays segments out across a row, dropping any that would touch
// the one before it: a label that collides with its neighbour is worse than no
// label, because two run together into a number that is neither.
func levelsTextRow(segs []levelsSeg) string {
	var b strings.Builder
	col := 0
	for _, s := range segs {
		if s.text == "" || s.at < col+1 {
			continue
		}
		b.WriteString(strings.Repeat(" ", s.at-col))
		b.WriteString(s.text)
		col = s.at + max(s.width, 1)
	}
	return b.String()
}
