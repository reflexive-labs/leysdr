package cli

import (
	"fmt"
	"math"
	"strconv"
	"strings"

	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// The three ink bands a chart column can be drawn in. They are indices, not
// colours: a run of columns sharing one band is inked once, so a row carries a
// handful of escape sequences rather than one per column.
const (
	inkPlain = iota
	inkMuted
	inkOk
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
	switch l.band {
	case inkMuted:
		text = l.st.Muted(text)
	case inkOk:
		text = l.st.Ok(text)
	}
	l.out.WriteString(text)
}

func (l *inkedLine) String() string {
	l.flush()
	return l.out.String()
}

// fmtDb is a level as the axis writes it: whole dB, no unit (the unit is
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
}

func (s headerSeg) width() int { return len(s.name) + len(s.value) }

func (s headerSeg) render(st ui.Style) string {
	if s.dim {
		return st.Muted(s.name + s.value)
	}
	return st.Muted(s.name) + s.value
}

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
	var lines []string
	var cur strings.Builder
	curw := 0
	for _, s := range segs {
		w := s.width()
		switch {
		case curw == 0:
			cur.WriteString(s.render(v.st))
			curw = w
		case curw+2+w <= v.width:
			cur.WriteString("  " + s.render(v.st))
			curw += 2 + w
		default:
			lines = append(lines, cur.String())
			cur.Reset()
			cur.WriteString(s.render(v.st))
			curw = w
		}
	}
	if curw > 0 {
		lines = append(lines, cur.String())
	}
	return lines
}

// gutter is the level axis' left column: the level, and the unit written once
// beside the top of the axis. It is spectrumGutter-1 columns wide; the caller
// adds the axis column itself.
func (v *spectrumView) gutter(label string, unit bool) string {
	suffix := "     "
	if unit {
		suffix = " dBFS"
	}
	return fmt.Sprintf("%4s", label) + v.st.Muted(suffix)
}

// chart draws the bars: one eighth-block per column per row, so ten rows carry
// eighty levels. Columns within spectrumQuietDb of the floor are Muted, so the
// noise reads as a low stipple rather than a wall; the floor itself is drawn as
// a rule across the chart. With --watch a Muted max-hold trace marks the
// loudest each column has been.
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
		case spectrumHeight / 2:
			label = fmtDb(base)
		}
		cells := make([]string, len(colDb))
		bands := make([]int, len(colDb))
		last := -1
		for c, db := range colDb {
			cell, band := " ", inkMuted
			fill := (db - base) / step
			switch {
			case fill > 0:
				cell = v.st.Ramp(fill)
				if cell == " " {
					cell = v.st.Ramp(0.125)
				}
				band = spectrumBand(db - v.noise)
			case v.holdOn && c < len(v.hold) && v.hold[c] > db:
				if h := (v.hold[c] - base) / step; h > 0 && h <= 1 {
					cell = string(g.BarEmpty)
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

// spectrumBand is how loud a column is relative to the noise floor, as an ink
// band: noise, something, or loud enough to tune to.
func spectrumBand(aboveFloor float64) int {
	switch {
	case aboveFloor < spectrumQuietDb:
		return inkMuted
	case aboveFloor < spectrumLoudDb:
		return inkPlain
	default:
		return inkOk
	}
}

// spectrumEdges is the band's low and high frequency.
func spectrumEdges(centerHz, spanHz uint64) (uint64, uint64) {
	lo := float64(centerHz) - float64(spanHz)/2
	return uint64(math.Max(0, lo)), centerHz + spanHz/2
}
