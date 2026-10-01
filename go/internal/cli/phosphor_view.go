// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"fmt"
	"math"
	"strings"

	"github.com/reflexive-labs/leysdr/go/internal/ui"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// The chart's geometry matches ley spectrum's: frequency across, level up. It
// is the same picture with a different statistic in each cell, so the two
// read the same way.
const (
	phosphorHeight  = 12 // chart rows; the level axis matters most here, so it gets more than spectrum's 10
	phosphorGutter  = 10 // level label + " dBFS" + the axis column
	phosphorMinCols = 10
)

// phosphorHistogram is one decoded frame: counts[bin][level].
type phosphorHistogram = leyline.PersistenceHistogram

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

// shadeFor turns a count into a shade. The curve is logarithmic; this is
// essential, not cosmetic.
//
// A linear normaliser against the frame's peak makes persistence useless: the
// shade ramp has four steps, so anything under a quarter of the peak count
// draws as blank, and a signal present 1% of the time -- the kind this display
// is for -- would be invisible. Every phosphor display
// compresses the count for the same reason. log(1+c)/log(1+peak) keeps a 1%
// signal visible while still putting a permanent one at full brightness.
func shadeFor(count, peak uint16) float64 {
	if peak == 0 || count == 0 {
		return 0
	}
	return math.Log1p(float64(count)) / math.Log1p(float64(peak))
}

// fmtSeconds renders a decay window in human-readable form.
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
	cols := v.cols(h.Bins)
	// Shading normalises against the frame's peak rather than each column's own: a
	// column of pure noise must look fainter than one carrying a carrier, and a
	// per-column normaliser would make them identical.
	peak := h.Peak()
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
			b0, b1 := c*h.Bins/cols, (c+1)*h.Bins/cols
			l0, l1 := (r-1)*h.Levels/phosphorHeight, r*h.Levels/phosphorHeight
			if b1 <= b0 {
				b1 = b0 + 1
			}
			if l1 <= l0 {
				l1 = l0 + 1
			}
			for bi := b0; bi < b1 && bi < h.Bins; bi++ {
				for li := l0; li < l1 && li < h.Levels; li++ {
					if got := h.At(bi, li); got > best {
						best = got
					}
				}
			}
			frac := shadeFor(best, peak)
			cell := v.st.Shade(frac)
			cells[c], bands[c] = cell, inkPlain
			if cell != " " {
				last = c
				bands[c] = rampBand(frac)
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

// gutter is the level axis' left column, the way `ley spectrum` writes it: the
// level plain so it reads over the map, the unit once beside the top.
func (v *phosphorView) gutter(label string, unit bool) string {
	suffix := "     "
	if unit {
		suffix = " dBFS"
	}
	return chartGutterField(v.st, phosphorGutter, label, suffix)
}

// axis is the frequency scale, the marker and the key.
func (v *phosphorView) axis(b *strings.Builder, cols int) {
	g := v.st.Glyphs()
	lo, hi := spectrumEdges(v.centerHz, v.spanHz)
	marks := spectrumMarks(spectrumTicks(lo, hi, cols))
	b.WriteString(v.gutter(fmtDb(v.floorDb), false) + axisRule(v.st, cols, marks) + "\n")
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
	// The labels are the toolkit's, so a label at the right edge is pulled in
	// to fit here exactly as it is under `ley spectrum`.
	if row := axisLabelRow(phosphorGutter, v.width, marks); row != "" {
		b.WriteString(v.st.Muted(row) + "\n")
	}
	// The legend is drawn only where it fits on one line; wrapped, it would
	// take the most space for the least information.
	legend := "shade is how often that frequency sat at that level"
	if len(legend) > v.width {
		legend = "shade is how often"
	}
	if len(legend) <= v.width {
		b.WriteString(v.st.Muted(legend) + "\n")
	}
}
