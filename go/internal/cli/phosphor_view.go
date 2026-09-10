package cli

import (
	"encoding/binary"
	"fmt"
	"math"
	"strings"

	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// The chart's geometry, deliberately the same as ley spectrum's: frequency
// across, level up. It is the same picture with a different statistic in each
// cell, so a reader who knows one knows the other.
const (
	phosphorHeight  = 12 // chart rows; the level axis is the whole point, so it gets more than spectrum's 10
	phosphorGutter  = 10 // level label + " dBFS" + the axis column
	phosphorMinCols = 10
)

// phosphorHistogram is one decoded frame: counts[bin][level].
type phosphorHistogram struct {
	bins, levels int
	counts       []uint16 // bin-major
}

// decodePersistence reads the wire payload: bins*levels little-endian uint16,
// bin-major.
func decodePersistence(payload []byte, bins, levels int) (phosphorHistogram, bool) {
	if bins <= 0 || levels <= 0 || len(payload) < bins*levels*2 {
		return phosphorHistogram{}, false
	}
	h := phosphorHistogram{bins: bins, levels: levels, counts: make([]uint16, bins*levels)}
	for i := range h.counts {
		h.counts[i] = binary.LittleEndian.Uint16(payload[2*i:])
	}
	return h, true
}

func (h phosphorHistogram) at(bin, level int) uint16 { return h.counts[bin*h.levels+level] }

// peak is the largest count anywhere, which is what the shading normalises
// against. Normalising per frame rather than per column is deliberate: a column
// that is pure noise must look fainter than one carrying a carrier, and a
// per-column normaliser would make them identical.
func (h phosphorHistogram) peak() uint16 {
	var m uint16
	for _, v := range h.counts {
		if v > m {
			m = v
		}
	}
	return m
}

// phosphorView draws persistence frames. The scale is fixed for the run by
// construction: it is the scale the daemon was asked to accumulate on, so it
// cannot drift the way an auto-scaled chart would.
type phosphorView struct {
	st               ui.Style
	width            int
	mark             uint64
	centerHz, spanHz uint64
	floorDb, rangeDb float64
	halfLife         float64
}

func newPhosphorView(st ui.Style, width int, mark uint64) *phosphorView {
	if width <= 0 {
		width = ui.DefaultWidth
	}
	return &phosphorView{st: st, width: width, mark: mark}
}

func (v *phosphorView) cols(bins int) int {
	c := v.width - phosphorGutter
	if c < phosphorMinCols {
		c = phosphorMinCols
	}
	if bins > 0 && c > bins {
		c = bins
	}
	return c
}

// header names the band, the scale and the window. "usual" is meaningless
// without saying over what, so the half-life is a fact, not scaffolding.
func (v *phosphorView) header(cols int) []string {
	lo, hi := spectrumEdges(v.centerHz, v.spanHz)
	segs := []headerSeg{
		{value: leyline.FormatFrequency(v.centerHz)},
		{name: "span ", value: leyline.FormatFrequency(v.spanHz)},
		{name: "over the last ", value: fmtSeconds(v.halfLife)},
		{value: leyline.FormatFrequency(lo) + " to " + leyline.FormatFrequency(hi), dim: true},
		{value: fmt.Sprintf("%d columns of %s", cols, leyline.FormatFrequency(v.binWidthHz(cols))), dim: true},
	}
	return packSegments(v.st, segs, v.width)
}

// binWidthHz is how much band one column covers, as the waterfall reports it:
// the difference between a picture of a signal and a map of where energy is.
func (v *phosphorView) binWidthHz(cols int) uint64 {
	if cols <= 0 {
		return 0
	}
	return uint64(math.Round(float64(v.spanHz) / float64(cols)))
}

// shadeFor turns a count into a shade. The curve is logarithmic, and that is
// the whole feature rather than a cosmetic choice.
//
// A linear normaliser against the frame's peak makes persistence useless: the
// shade ramp has four steps, so anything under a quarter of the peak count
// draws as blank, and a signal present 1% of the time -- exactly the kind this
// display exists to find -- would be invisible. Every phosphor display
// compresses the count for the same reason. log(1+c)/log(1+peak) keeps a 1%
// signal visible while still putting a permanent one at full brightness.
func shadeFor(count, peak uint16) float64 {
	if peak == 0 || count == 0 {
		return 0
	}
	return math.Log1p(float64(count)) / math.Log1p(float64(peak))
}

// fmtSeconds is a decay window as a person says it.
func fmtSeconds(s float64) string {
	if s <= 0 || math.IsNaN(s) {
		return "-"
	}
	if s < 60 {
		return fmt.Sprintf("%.0f s", s)
	}
	return fmt.Sprintf("%.0f min", s/60)
}

// render draws one frame: one cell per (column, row), shaded by how often that
// frequency has been at that level.
func (v *phosphorView) render(h phosphorHistogram) string {
	cols := v.cols(h.bins)
	peak := h.peak()
	var b strings.Builder
	for _, l := range v.header(cols) {
		b.WriteString(l + "\n")
	}
	step := v.rangeDb / float64(phosphorHeight)
	// Every label names its row's top edge, so a cell lines up against the
	// number beside it rather than the one a row below.
	for r := phosphorHeight; r >= 1; r-- {
		label, unit := "", false
		switch r {
		case phosphorHeight:
			label, unit = fmtDb(v.floorDb+v.rangeDb), true
		case phosphorHeight / 2:
			label = fmtDb(v.floorDb + float64(r)*step)
		}
		line := &inkedLine{st: v.st}
		line.add(v.gutter(label, unit), inkPlain)
		cells := make([]string, cols)
		bands := make([]int, cols)
		last := -1
		for c := 0; c < cols; c++ {
			// Fold the histogram's bins and levels onto the chart's grid by
			// taking the largest count in the cell: a carrier one bin wide must
			// not be averaged away by the noise beside it.
			var best uint16
			b0, b1 := c*h.bins/cols, (c+1)*h.bins/cols
			l0, l1 := (r-1)*h.levels/phosphorHeight, r*h.levels/phosphorHeight
			if b1 <= b0 {
				b1 = b0 + 1
			}
			if l1 <= l0 {
				l1 = l0 + 1
			}
			for bi := b0; bi < b1 && bi < h.bins; bi++ {
				for li := l0; li < l1 && li < h.levels; li++ {
					if got := h.at(bi, li); got > best {
						best = got
					}
				}
			}
			frac := shadeFor(best, peak)
			cell := v.st.Shade(frac)
			cells[c], bands[c] = cell, inkPlain
			if cell != " " {
				last = c
				bands[c] = waterfallBand(frac)
			}
		}
		for c := 0; c <= last; c++ {
			line.add(cells[c], bands[c])
		}
		b.WriteString(line.String() + "\n")
	}
	v.axis(&b, cols)
	return b.String()
}

func (v *phosphorView) gutter(label string, unit bool) string {
	suffix := "     "
	if unit {
		suffix = " dBFS"
	}
	return fmt.Sprintf("%4s", label) + v.st.Muted(suffix)
}

// axis is the frequency scale, the marker and the key.
func (v *phosphorView) axis(b *strings.Builder, cols int) {
	g := v.st.Glyphs()
	lo, hi := spectrumEdges(v.centerHz, v.spanHz)
	ticks := spectrumTicks(lo, hi, cols)
	rule := []rune(strings.Repeat(string(g.Rule), cols+1))
	for _, t := range ticks {
		if t.col+1 < len(rule) {
			rule[t.col+1] = []rune(g.TreeTrunk)[0]
		}
	}
	b.WriteString(v.gutter(fmtDb(v.floorDb), false) + v.st.Muted(string(rule)) + "\n")
	if v.mark != 0 && v.mark >= lo && v.mark <= hi && hi > lo {
		col := int(float64(v.mark-lo) / float64(hi-lo) * float64(cols))
		if col >= cols {
			col = cols - 1
		}
		text := string(g.Marker) + " " + leyline.FormatFrequency(v.mark)
		at := phosphorGutter + col
		if at+len(text) <= v.width {
			b.WriteString(strings.Repeat(" ", at) + text + "\n")
		}
	}
	row := make([]byte, 0, v.width)
	for _, t := range ticks {
		text := leyline.FormatFrequency(t.hz)
		at := phosphorGutter + t.col - len(text)/2
		if at < phosphorGutter {
			at = phosphorGutter
		}
		if at+len(text) > v.width || at < len(row) {
			continue
		}
		for len(row) < at {
			row = append(row, ' ')
		}
		row = append(row, text...)
	}
	if len(row) > 0 {
		b.WriteString(v.st.Muted(string(row)) + "\n")
	}
	// The legend earns its line only where it fits; a wrapped one would be the
	// widest thing on screen and say the least.
	legend := "shade is how often that frequency sat at that level"
	if len(legend) > v.width {
		legend = "shade is how often"
	}
	if len(legend) <= v.width {
		b.WriteString(v.st.Muted(legend) + "\n")
	}
}
