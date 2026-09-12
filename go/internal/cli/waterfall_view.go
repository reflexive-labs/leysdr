package cli

import (
	"fmt"
	"math"
	"strings"

	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// The waterfall's geometry. The gutter is the time axis: mm:ss and the axis
// column itself. Everything right of it is one cell per column of band.
const (
	waterfallGutter  = 7 // "mm:ss" + the axis column + a space
	waterfallMinCols = 10
	// waterfallAxisEvery is how often the frequency axis is reprinted. The
	// rows scroll away, so an axis printed once at the top is gone by the time
	// a reader wants it.
	waterfallAxisEvery = 20
	// waterfallTimeEvery is how often the elapsed time is stamped in the
	// gutter: often enough to read a transmission's length off the column,
	// rarely enough that the number does not blur into the shading.
	waterfallTimeEvery = 4
)

// waterfallRangeDb is how far above the floor the shade ramp reaches. A signal
// this far up is drawn at full density and anything louder is drawn the same:
// a waterfall answers "is something here and when", and 40 dB of range is more
// than enough to say so.
const waterfallRangeDb = 40

// waterfallView draws FFT rows as a scrolling activity map: one line per row,
// newest at the bottom, one shaded cell per column of band.
//
// The scale is chosen from the first rows and then held. Auto-scaling per row
// would make the time axis lie: the same signal would change shade because
// something else on the band got louder, and a reader comparing two rows would
// be comparing two different scales.
type waterfallView struct {
	st    ui.Style
	width int
	mark  uint64 // the frequency the user asked for, 0 when they did not

	centerHz, spanHz uint64
	floor            float64 // dBFS the ramp starts at; NaN until chosen
	rows             int     // rows drawn, for the axis cadence
}

// newWaterfallView sizes a waterfall for one run.
func newWaterfallView(st ui.Style, width int, mark uint64) *waterfallView {
	if width <= 0 {
		width = ui.DefaultWidth
	}
	return &waterfallView{st: st, width: width, mark: mark, floor: math.NaN()}
}

// cols is the map's width in columns, never more than there are bins.
func (v *waterfallView) cols(bins int) int {
	c := v.width - waterfallGutter
	if c < waterfallMinCols {
		c = waterfallMinCols
	}
	if bins > 0 && c > bins {
		c = bins
	}
	return c
}

// binWidthHz is how much band one column covers. It goes in the header,
// because it is the difference between a picture of a signal and a picture of
// where energy is: at 2.4 MHz over 100 columns a column is 24 kHz, which
// cannot separate two 12.5 kHz channels.
func (v *waterfallView) binWidthHz(cols int) uint64 {
	if cols <= 0 {
		return 0
	}
	return uint64(math.Round(float64(v.spanHz) / float64(cols)))
}

// header names the band and the scale, once, before any rows.
func (v *waterfallView) header(cols int) []string {
	lo, hi := spectrumEdges(v.centerHz, v.spanHz)
	segs := []headerSeg{
		{value: leyline.FormatFrequency(v.centerHz)},
		{name: "span ", value: leyline.FormatFrequency(v.spanHz)},
		{name: "floor ", value: fmtDb(v.floor) + " dBFS"},
		{name: "range ", value: fmt.Sprintf("%d dB", waterfallRangeDb)},
		{value: leyline.FormatFrequency(lo) + " to " + leyline.FormatFrequency(hi), dim: true},
		// What a column covers is the difference between a picture of a signal
		// and a map of where energy is, so it is a fact, not scaffolding.
		{value: fmt.Sprintf("%d columns of %s", cols, leyline.FormatFrequency(v.binWidthHz(cols))), dim: true},
	}
	return packSegments(v.st, segs, v.width)
}

// key is the legend: what each shade means, in dB over the floor. Without it
// the picture is pretty and unreadable.
func (v *waterfallView) key() []string {
	g := []rune(v.st.Glyphs().Shade)
	segs := make([]headerSeg, 0, len(g))
	for i := 1; i < len(g); i++ {
		frac := float64(i) / float64(len(g)-1)
		step := int(float64(waterfallRangeDb) * frac)
		segs = append(segs, headerSeg{
			name:  v.st.Level(frac, string(g[i])),
			value: fmt.Sprintf(" +%d", step),
			inked: true,
			// The glyph is one cell however many bytes of ink it carries.
			width: 1 + len(fmt.Sprintf(" +%d", step)),
		})
	}
	segs = append(segs, headerSeg{value: "dB over the floor", dim: true})
	return packSegments(v.st, segs, v.width)
}

// setScale chooses the floor from the first row and then holds it for the run.
// One row of eighty-odd columns is plenty of evidence for a median, and taking
// it immediately means the header can state the floor its shades are measured
// from rather than a number chosen a second later.
func (v *waterfallView) setScale(colDb []float64) {
	if !math.IsNaN(v.floor) || len(colDb) == 0 {
		return
	}
	v.floor = medianDb(colDb)
}

// row draws one FFT row: the time gutter, then one shaded cell per column.
func (v *waterfallView) row(bins []float64, elapsed float64) string {
	cols := v.cols(len(bins))
	colDb := columnLevels(bins, cols)
	v.setScale(colDb)
	line := &inkedLine{st: v.st}
	line.add(v.gutter(elapsed), inkPlain)
	last := -1
	cells := make([]string, cols)
	bands := make([]int, cols)
	for i, db := range colDb {
		frac := rampFrac(db, v.floor, v.floor+waterfallRangeDb)
		cell := v.st.Shade(frac)
		cells[i] = cell
		bands[i] = inkPlain
		if cell != " " {
			last = i
			bands[i] = rampBand(frac)
		}
	}
	for i := 0; i <= last; i++ {
		line.add(cells[i], bands[i])
	}
	v.rows++
	return line.String()
}

// gutter is the elapsed time, printed on every waterfallTimeEvery-th row so
// the column stays readable without repeating a number that barely changes.
func (v *waterfallView) gutter(elapsed float64) string {
	label := ""
	if v.rows%waterfallTimeEvery == 0 {
		m := int(elapsed) / 60
		s := int(elapsed) % 60
		label = fmt.Sprintf("%02d:%02d", m, s)
	}
	return fmt.Sprintf("%-5s", label) + v.st.Muted(v.st.Glyphs().TreeTrunk) + " "
}

// gapRow marks rows the daemon dropped. Delivery is GAP_MARKED, and a gap that
// is simply not drawn makes time silently compress: the reader would see a
// transmission as shorter than it was, which is the one thing this view exists
// to report.
func (v *waterfallView) gapRow(rows uint64) string {
	g := v.st.Glyphs()
	text := " " + plural(int(rows), "row") + " lost "
	width := v.width - waterfallGutter
	side := (width - len(text)) / 2
	if side < 2 {
		side = 2
	}
	rule := strings.Repeat(string(g.Rule), side)
	v.rows++
	return strings.Repeat(" ", waterfallGutter) + v.st.Warn(rule+text+rule)
}

// axis is the frequency scale under the map, reprinted periodically because
// the rows scroll away from whatever was printed at the top.
func (v *waterfallView) axis(cols int) []string {
	g := v.st.Glyphs()
	lo, hi := spectrumEdges(v.centerHz, v.spanHz)
	ticks := spectrumTicks(lo, hi, cols)
	rule := []rune(strings.Repeat(string(g.Rule), cols))
	for _, t := range ticks {
		if t.col >= 0 && t.col < cols {
			rule[t.col] = []rune(g.TreeTrunk)[0]
		}
	}
	pad := strings.Repeat(" ", waterfallGutter)
	out := []string{pad + v.st.Muted(string(rule))}

	// Labels, centred under their tick and never overlapping.
	row := make([]byte, 0, v.width)
	for _, t := range ticks {
		text := leyline.FormatFrequency(t.hz)
		at := waterfallGutter + t.col - len(text)/2
		if at < waterfallGutter {
			at = waterfallGutter
		}
		if at+len(text) > v.width {
			continue
		}
		if at < len(row) {
			continue // would collide with the label already placed
		}
		for len(row) < at {
			row = append(row, ' ')
		}
		row = append(row, text...)
	}
	if len(row) > 0 {
		out = append(out, v.st.Muted(string(row)))
	}
	// The marker points at the frequency the user typed, so `ley waterfall
	// 146.62` does not draw the same picture as a bare `ley waterfall`.
	if v.mark != 0 && v.mark >= lo && v.mark <= hi && hi > lo {
		col := int(float64(v.mark-lo) / float64(hi-lo) * float64(cols))
		if col >= cols {
			col = cols - 1
		}
		text := string(g.Marker) + " " + leyline.FormatFrequency(v.mark)
		at := waterfallGutter + col
		if at+len(text) <= v.width {
			out = append(out, strings.Repeat(" ", at)+text)
		}
	}
	return out
}

// due reports whether the axis should be reprinted before this row.
func (v *waterfallView) due() bool { return v.rows > 0 && v.rows%waterfallAxisEvery == 0 }
