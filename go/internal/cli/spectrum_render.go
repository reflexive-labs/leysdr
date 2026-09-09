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

// How the chart carries level as colour. Every column takes the ramp ink its
// own dB lands on, so the noise floor reads cold and a carrier hot; the
// three-band Muted/plain/Ok inking this replaced collapsed to plain across most
// of a live band. The steps quantise the ramp so a row of eighty columns emits
// a handful of escape sequences rather than one per column: neighbouring
// columns that land on the same step share one run of ink.
const spectrumLevelSteps = 24

// spectrumFrameMinWidth is the narrowest terminal that gets a frame around the
// chart. The border and its padding cost ui.BoxPadding columns of chart, which
// a cramped screen cannot spare.
const spectrumFrameMinWidth = 60

// How the scale is chosen, and how the max-hold trace behaves. The top used to
// reserve 30 dB above the noise line whatever the data did, which crushed a
// quiet band into the bottom third of the chart and left 70% of the rows
// blank; it now tracks the loudest column with a little headroom, and only a
// dead-flat band falls back to the minimum span. The hold used to be a running
// maximum that never decayed, so tens of frames of noise built a solid ceiling
// above the live trace: it now falls back toward the live column every frame
// and is drawn only where it stands clear of it, which is what a transient
// looks like.
const (
	spectrumHeadroomDb   = 3   // dB of air above the loudest column, before the scale rounds to 5
	spectrumMinSpanDb    = 10  // the least the top may sit above the noise line
	spectrumHoldDecayDb  = 1.5 // dB the hold falls toward the live column each frame
	spectrumScaleDecayDb = 2   // dB the scale top and the ramp's hot end give back each frame
	spectrumHoldMarginDb = 6   // dB a hold must stand above the live column to be drawn
)

// spectrumView draws one FFT row as a chart. It carries the state that must
// survive between frames of a --watch run: the frozen dB scale (so the axis
// does not twitch) and the max-hold trace.
type spectrumView struct {
	st     ui.Style
	width  int
	mark   uint64 // the frequency the user asked for, 0 when they did not
	holdOn bool   // keep a max-hold trace (--watch only)
	framed bool   // draw the chart and its header inside a Box

	top, bottom float64   // the frozen scale, in dBFS
	noise       float64   // the median column: the noise line the eye sees
	peak        float64   // the loudest column the run has seen: the ramp's hot end
	scaled      bool      // top/bottom have been chosen
	rescaled    bool      // the last frame had to move the scale
	quiet       bool      // the last frame held no detection
	hold        []float64 // per-column decaying max-hold trace
}

// newSpectrumView sizes a chart for one run. width is the resolved width;
// mark is the frequency the user typed, or 0; frame asks for the border, which
// is drawn only on a screen that has the alphabet and the columns for it.
func newSpectrumView(st ui.Style, width int, mark uint64, hold, frame bool) *spectrumView {
	if width <= 0 {
		width = ui.DefaultWidth
	}
	return &spectrumView{
		st:     st,
		width:  width,
		mark:   mark,
		holdOn: hold,
		framed: frame && st.Unicode && width >= spectrumFrameMinWidth,
	}
}

// inner is the width the chart itself may use: the whole width, less what the
// frame spends on its border and padding when there is one.
func (v *spectrumView) inner() int {
	if v.framed {
		return v.width - ui.BoxPadding
	}
	return v.width
}

// cols is the chart's width in columns, never less than spectrumMinCols even
// on a terminal too narrow to deserve one, and never more than there are bins.
func (v *spectrumView) cols(bins int) int {
	c := v.inner() - spectrumGutter
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
		v.updateHold(colDb)
	}
	// A frame with no detection is drawn cold whatever its levels are, so a
	// quiet band and a busy one do not look alike (the peak block says the
	// same thing in words).
	v.quiet = len(peaks) == 0
	// The chart, its header and its axis are one object and are framed as
	// one; the peak list reads as prose under it and stays outside.
	var chart strings.Builder
	for _, line := range v.header(len(bins), floor, centerHz, spanHz) {
		chart.WriteString(line + "\n")
	}
	v.chart(&chart, colDb, floor)
	v.axis(&chart, cols, centerHz, spanHz)
	var b strings.Builder
	if v.framed {
		b.WriteString(v.st.Box(strings.TrimRight(chart.String(), "\n")) + "\n")
	} else {
		b.WriteString(chart.String())
	}
	v.peakBlock(&b, peaks, floor)
	return b.String()
}

// updateHold folds one frame into the max-hold trace: a column louder than
// its hold takes it, and every other column is pulled back toward the live
// value. Without that decay the hold is a running maximum that never falls,
// so after tens of noise frames every column holds the noise peak and the
// trace draws as a wall above the live one.
func (v *spectrumView) updateHold(colDb []float64) {
	if len(v.hold) != len(colDb) {
		v.hold = append([]float64(nil), colDb...)
		return
	}
	for i, d := range colDb {
		switch {
		case math.IsNaN(d) || math.IsInf(d, 0):
			// Nothing to hold and nothing to decay toward.
		case d >= v.hold[i] || math.IsNaN(v.hold[i]):
			v.hold[i] = d
		default:
			v.hold[i] = math.Max(d, v.hold[i]-spectrumHoldDecayDb)
		}
	}
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

// rescale picks the dB scale on the first frame and then follows the band
// asymmetrically: it rises at once so a signal is never clipped, and falls by
// at most spectrumScaleDecayDb a frame so a passing transient does not cost
// the rest of the run its rows. Either move is visible in the status line.
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
	// The top tracks the data: the loudest column plus a little headroom, and
	// never closer to the noise line than spectrumMinSpanDb, so a dead-flat
	// band still has rows to draw in without a quiet one being crushed into
	// the bottom of the chart.
	top := math.Ceil(math.Max(peak+spectrumHeadroomDb, v.noise+spectrumMinSpanDb)/5) * 5
	if !v.scaled {
		v.bottom, v.top, v.peak, v.scaled = bottom, top, peak, true
		return
	}
	// The ramp's hot end and the scale follow the band, but slowly: a single
	// transient must not permanently cost the chart its rows. Rising is
	// immediate so a signal is never clipped; falling is gradual, so a burst
	// that has passed gives its space back after a few seconds instead of
	// leaving the rest of the run crushed into the bottom of the chart.
	if peak > v.peak {
		v.peak = peak
	} else {
		v.peak = math.Max(peak, v.peak-spectrumScaleDecayDb)
	}
	if top < v.top {
		// Step down by whole label increments: the scale is rounded to 5 dB, so
		// a decay smaller than that would round straight back to where it was.
		if relaxed := math.Max(math.Floor((v.top-spectrumScaleDecayDb)/5)*5, top); relaxed < v.top {
			v.top, v.rescaled = relaxed, true
		}
	}
	if top > v.top {
		v.top, v.rescaled = top, true
	}
	if bottom < v.bottom {
		v.bottom, v.rescaled = bottom, true
	}
}
