// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"fmt"
	"math"
	"strings"

	"github.com/dpup/leysdr/go/pkg/leyline"
)

// header states what band this is, how wide, and what the floor is, then the
// scaffolding: the edges and the bin size. Segments are packed greedily into
// lines that fit the width, so a narrow terminal gets more lines rather than a
// truncated fact.
func (v *spectrumView) header(nbins int, floor float64, centerHz, spanHz uint64) []string {
	lo, hi := spectrumEdges(centerHz, spanHz)
	binWidth := float64(spanHz) / math.Max(1, float64(nbins))
	segs := []headerSeg{
		{value: leyline.FormatFrequency(centerHz)},
		{name: "span ", value: leyline.FormatFrequency(spanHz)},
		{name: "floor ", value: fmtDb(floor) + " dBFS"},
		{value: leyline.FormatFrequency(lo) + " to " + leyline.FormatFrequency(hi), dim: true},
		{value: fmt.Sprintf("%d bins of %s", nbins, leyline.FormatFrequency(uint64(math.Round(binWidth)))), dim: true},
	}
	return packSegments(v.st, segs, v.inner())
}

// gutter is the level axis' left column: the level, and the unit written once
// beside the top of the axis. The level is plain so it reads over the trace
// beside it. The caller adds the axis column itself.
func (v *spectrumView) gutter(label string, unit bool) string {
	suffix := "     "
	if unit {
		suffix = " dBFS"
	}
	return chartGutterField(v.st, spectrumGutter, label, suffix)
}

// chart draws the band as a trace: one glyph per column, on the row that
// column's level falls in and picking its eighth-block from the sub-row
// remainder, with nothing painted beneath it. Filling every cell below a column
// made the picture mostly noise by area -- a flat floor covers two whole rows,
// some two hundred cells, where a carrier covers a dozen -- so the chart read as
// one cold mass whatever was on the air, and the flatness of the floor, which is
// the thing a reader is checking, had no shape to be seen in. A trace gives the
// floor a line, a carrier a spike and a broadcast signal a plateau.
//
// Each column takes the ramp ink of its own level, so the floor reads cold and a
// carrier hot; the floor itself is a rule across the chart, labelled on the
// axis, so height above it is read as signal margin. With --watch a Muted
// max-hold trace marks the columns whose recent peak still stands clear of the
// live one.
func (v *spectrumView) chart(b *strings.Builder, colDb []float64, floor float64) {
	g := v.st.Glyphs()
	step := (v.top - v.bottom) / spectrumHeight
	if step <= 0 {
		step = 1
	}
	floorRow := int((v.noise-v.bottom)/step) + 1
	if floorRow < 1 {
		floorRow = 1
	}
	if floorRow >= spectrumHeight {
		floorRow = spectrumHeight - 1
	}
	for r := spectrumHeight; r >= 1; r-- {
		base := v.bottom + float64(r-1)*step
		label, unit := "", false
		switch r {
		case spectrumHeight:
			label, unit = fmtDb(v.top), true
		case floorRow:
			// The one interior label worth its four columns is the floor
			// itself: with the rule drawn across the chart at this level, a
			// column's height above it reads directly as signal margin.
			label = fmtDb(v.noise)
		}
		cells := make([]string, len(colDb))
		bands := make([]int, len(colDb))
		last := -1
		for c, db := range colDb {
			cell, band := " ", inkMuted
			fill := (db - base) / step
			switch {
			case v.traceRow(db, step) == r:
				// The top edge of this column, and only it: the block is the
				// part of this row the level reaches into, so a run of columns
				// at one level draws as a line rather than as a wall.
				cell = v.st.Ramp(fill)
				if cell == " " {
					cell = v.st.Ramp(0.125)
				}
				band = v.levelBand(db)
			case fill > 1 && r > floorRow:
				// Below the trace and above the floor: a thin stem, not a
				// filled block, so a tall column still reads as one thing
				// standing at one frequency without the fill becoming the
				// picture. A stem costs a stroke where a block costs a whole
				// cell of ink, which is what turned a flat floor into a wall of
				// colour. Nothing is stemmed down through the floor: a column
				// sitting on the noise line is the line, and drawing its stem
				// would rebuild the wall one row lower.
				cell = g.TreeTrunk
				band = v.levelBand(db)
			case v.holdOn && c < len(v.hold) && v.hold[c] >= db+spectrumHoldMarginDb:
				// A thin line, not a filled block, and only where the hold
				// stands clear of the live column: what is left is the mark
				// of a real transient, and noise leaves nothing.
				if h := (v.hold[c] - base) / step; h > 0 && h <= 1 {
					cell = string(g.Rule)
				}
			}
			if cell == " " && r == floorRow {
				cell = string(g.Rule)
			}
			cells[c], bands[c] = cell, band
			if cell != " " {
				last = c
			}
		}
		// Trailing blanks are dropped before any ink is applied, so the plain
		// and the coloured renderings differ by escape bytes and nothing else.
		line := &inkedLine{st: v.st}
		line.add(v.gutter(label, unit), inkPlain)
		line.add(v.st.Muted(g.TreeTrunk), inkPlain)
		for c := 0; c <= last; c++ {
			line.add(cells[c], bands[c])
		}
		b.WriteString(line.String() + "\n")
	}
}

// traceRow is the chart row a column's top edge is drawn in: the level's
// position on the scale, in rows, rounded up. A column at or under the bottom
// of the scale is pinned to the first row rather than dropped, so a dip does
// not open a hole in the trace, and one over the top is pinned to the last.
func (v *spectrumView) traceRow(db, step float64) int {
	if math.IsNaN(db) || math.IsInf(db, 0) {
		return 0 // no row: an absent column draws nothing
	}
	r := int(math.Ceil((db - v.bottom) / step))
	if r < 1 {
		return 1
	}
	if r > spectrumHeight {
		return spectrumHeight
	}
	return r
}

// levelBand is where a level sits on the ramp, as a step of chartLevelSteps.
// The cold end is the noise line and the hot end the loudest column the run has
// seen, so hue says what a reader actually wants to know: how far over the
// floor this is. Keying it to the bottom of the axis instead would count the
// row of air reserved under the floor as levels to ink, so every noise column
// would draw a little warm and the whole ramp would be offset.
func (v *spectrumView) levelBand(db float64) int {
	if math.IsInf(db, 0) {
		// A bin with no power in it is not a level and takes the coldest ink
		// there is rather than either end of the ramp.
		return 0
	}
	frac := rampFrac(db, v.noise, v.peak)
	if v.quiet {
		// Nothing was detected, so the span this is keyed to is noise against
		// noise. Hold the ramp to its cold end: the texture still shows, but
		// an empty band never wears the colours of a busy one.
		frac *= spectrumQuietRampCap
	}
	return rampBand(frac)
}

// levelInk is levelBand as ink, for the values outside the chart that must
// agree with it.
func (v *spectrumView) levelInk(db float64, text string) string {
	return v.st.Level(rampFrac(float64(v.levelBand(db)), 0, chartLevelSteps-1), text)
}

// spectrumEdges is the band's low and high frequency.
func spectrumEdges(centerHz, spanHz uint64) (uint64, uint64) {
	lo := float64(centerHz) - float64(spanHz)/2
	return uint64(math.Max(0, lo)), centerHz + spanHz/2
}
