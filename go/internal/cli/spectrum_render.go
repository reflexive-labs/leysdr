package cli

import (
	"math"
	"strings"

	"github.com/dpup/leysdr/go/internal/ui"
)

// The chart's geometry. The gutter is the level axis: four columns of level,
// five for the unit written once beside the top level, and the axis column
// itself. Everything right of it is spectrum.
const (
	spectrumHeight  = 10 // chart rows, the floor rule included
	spectrumGutter  = 10 // level label + " dBFS" + the axis column
	spectrumMinCols = 10
)

// Level bands, in dB above the noise floor. Below spectrumQuietDb a column is
// noise and is drawn Muted; at or above spectrumLoudDb it is loud enough to be
// worth tuning to and is drawn Ok. Between them it is plain: something is
// there, read it.
const (
	spectrumQuietDb = 6
	spectrumLoudDb  = 20
)

// spectrumView draws one FFT row as a chart. It carries the state that must
// survive between frames of a --watch run: the frozen dB scale (so the axis
// does not twitch) and the max-hold trace.
type spectrumView struct {
	st     ui.Style
	width  int
	mark   uint64 // the frequency the user asked for, 0 when they did not
	holdOn bool   // keep a max-hold trace (--watch only)

	top, bottom float64   // the frozen scale, in dBFS
	noise       float64   // the median column: the noise line the eye sees
	scaled      bool      // top/bottom have been chosen
	rescaled    bool      // the last frame had to move the scale
	hold        []float64 // per-column max since the run started
}

// newSpectrumView sizes a chart for one run. width is the resolved width;
// mark is the frequency the user typed, or 0.
func newSpectrumView(st ui.Style, width int, mark uint64, hold bool) *spectrumView {
	if width <= 0 {
		width = ui.DefaultWidth
	}
	return &spectrumView{st: st, width: width, mark: mark, holdOn: hold}
}

// cols is the chart's width in columns, never less than spectrumMinCols even
// on a terminal too narrow to deserve one, and never more than there are bins.
func (v *spectrumView) cols(bins int) int {
	c := v.width - spectrumGutter
	if c < spectrumMinCols {
		c = spectrumMinCols
	}
	if bins > 0 && c > bins {
		c = bins
	}
	return c
}

// render draws the header, the chart, the axis and the peak block for one
// row. Every line it returns fits the resolved width.
func (v *spectrumView) render(bins []float64, peaks []Peak, floor float64, centerHz, spanHz uint64) string {
	cols := v.cols(len(bins))
	colDb := columnLevels(bins, cols)
	v.rescale(colDb, floor)
	if v.holdOn {
		if len(v.hold) != len(colDb) {
			v.hold = append([]float64(nil), colDb...)
		}
		for i, d := range colDb {
			v.hold[i] = math.Max(v.hold[i], d)
		}
	}
	var b strings.Builder
	for _, line := range v.header(len(bins), floor, centerHz, spanHz) {
		b.WriteString(line + "\n")
	}
	v.chart(&b, colDb, floor)
	v.axis(&b, cols, centerHz, spanHz)
	v.peakBlock(&b, peaks, floor)
	return b.String()
}

// note is what the status line should say about the scale, if anything: a
// frozen scale that had to move is the one thing a watcher must be told, or
// two frames are not comparable.
func (v *spectrumView) note() string {
	if !v.rescaled {
		return ""
	}
	return "scale now " + fmtDb(v.bottom) + " to " + fmtDb(v.top) + " dBFS"
}

// columnLevels folds bins into cols columns, each carrying the loudest bin it
// covers: a chart column is wider than a bin, and a signal must not vanish
// into an average.
func columnLevels(bins []float64, cols int) []float64 {
	out := make([]float64, cols)
	if len(bins) == 0 {
		for i := range out {
			out[i] = math.Inf(-1)
		}
		return out
	}
	for c := range out {
		from, to := c*len(bins)/cols, (c+1)*len(bins)/cols
		if to <= from {
			to = from + 1
		}
		if to > len(bins) {
			to = len(bins)
		}
		m := math.Inf(-1)
		for _, d := range bins[from:to] {
			m = math.Max(m, d)
		}
		out[c] = m
	}
	return out
}

// rescale picks the dB scale on the first frame and then holds it, so a
// --watch run is comparable with itself. A frame louder than the top raises it
// once, visibly (the status line says so); the scale never contracts.
func (v *spectrumView) rescale(colDb []float64, floor float64) {
	peak := floor
	for _, d := range colDb {
		if !math.IsInf(d, -1) && !math.IsNaN(d) {
			peak = math.Max(peak, d)
		}
	}
	// A column carries the loudest bin it covers, so even an empty column sits
	// several dB above the row's median: the noise line the eye sees is the
	// median column, and that is what the scale and the ink bands work from.
	// floor stays the median bin, which is what the header reports and what
	// squelch measures against.
	v.noise = medianDb(colDb)
	if math.IsNaN(v.noise) || math.IsInf(v.noise, 0) {
		v.noise = floor
	}
	v.rescaled = false
	// The chart starts at the noise line, so noise reads as a low stipple with
	// the floor rule showing through it rather than as a solid wall, and every
	// row above it is signal.
	bottom := math.Floor(v.noise/5) * 5
	top := math.Ceil(math.Max(peak, v.noise+30)/5) * 5
	if !v.scaled {
		v.bottom, v.top, v.scaled = bottom, top, true
		return
	}
	if top > v.top {
		v.top, v.rescaled = top, true
	}
	if bottom < v.bottom {
		v.bottom, v.rescaled = bottom, true
	}
}
