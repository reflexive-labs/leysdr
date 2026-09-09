package cli

import (
	"fmt"
	"math"
	"strconv"
	"strings"

	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// spectrumTick is one frequency the axis names: a round number and the chart
// column it falls in.
type spectrumTick struct {
	hz  uint64
	col int
}

// spectrumTicks picks the frequencies the axis marks: round numbers, as many
// as the width has room to label, always at least one.
func spectrumTicks(lo, hi uint64, cols int) []spectrumTick {
	span := float64(hi) - float64(lo)
	if span <= 0 || cols <= 0 {
		return nil
	}
	label := len(leyline.FormatFrequency(hi)) + 2
	want := cols / label
	if want < 1 {
		want = 1
	}
	if want > 9 {
		want = 9
	}
	step := niceStep(span / float64(want))
	var ticks []spectrumTick
	first := math.Ceil(float64(lo)/step) * step
	for f := first; f <= float64(hi); f += step {
		col := int((f - float64(lo)) / span * float64(cols))
		if col < 0 || col >= cols {
			continue
		}
		ticks = append(ticks, spectrumTick{hz: uint64(math.Round(f)), col: col})
	}
	if len(ticks) == 0 {
		mid := (float64(lo) + float64(hi)) / 2
		ticks = append(ticks, spectrumTick{hz: uint64(math.Round(mid)), col: cols / 2})
	}
	return ticks
}

// niceStep rounds a raw tick spacing up to 1, 2, 2.5 or 5 times a power of ten,
// so the labels land on frequencies a person would say out loud.
func niceStep(raw float64) float64 {
	if raw <= 0 {
		return 1
	}
	mag := math.Pow(10, math.Floor(math.Log10(raw)))
	for _, m := range []float64{1, 2, 2.5, 5} {
		if raw <= m*mag {
			return m * mag
		}
	}
	return 10 * mag
}

// axis draws the frequency axis: a rule with a tick at every labelled
// frequency, a marker under the frequency the user asked for, and the labels
// themselves.
func (v *spectrumView) axis(b *strings.Builder, cols int, centerHz, spanHz uint64) {
	g := v.st.Glyphs()
	lo, hi := spectrumEdges(centerHz, spanHz)
	ticks := spectrumTicks(lo, hi, cols)
	rule := []rune(strings.Repeat(string(g.Rule), cols+1))
	for _, t := range ticks {
		rule[t.col+1] = []rune(g.TreeTrunk)[0]
	}
	b.WriteString(v.gutter(fmtDb(v.bottom), false) + v.st.Muted(string(rule)) + "\n")
	if line := v.markerRow(cols, lo, hi); line != "" {
		b.WriteString(line + "\n")
	}
	b.WriteString(v.labelRow(cols, ticks) + "\n")
}

// markerRow points at the frequency the user typed, so `ley spectrum 146.62`
// does not render the same as a bare `ley spectrum`. Empty when no frequency
// was given, or when it falls outside the band on screen.
func (v *spectrumView) markerRow(cols int, lo, hi uint64) string {
	if v.mark == 0 || v.mark < lo || v.mark > hi || hi <= lo {
		return ""
	}
	col := int(float64(v.mark-lo) / float64(hi-lo) * float64(cols))
	if col >= cols {
		col = cols - 1
	}
	if col < 0 {
		col = 0
	}
	label := " " + leyline.FormatFrequency(v.mark)
	line := strings.Repeat(" ", spectrumGutter+col) + string(v.st.Glyphs().Marker)
	if ui.Visible(line)+len(label) <= v.inner() {
		return line + label
	}
	return line
}

// labelRow writes each tick's frequency under its tick, dropping any label the
// width cannot fit beside its neighbour.
func (v *spectrumView) labelRow(cols int, ticks []spectrumTick) string {
	row := make([]byte, 0, v.inner())
	for _, t := range ticks {
		text := leyline.FormatFrequency(t.hz)
		at := spectrumGutter + t.col - len(text)/2
		if at < spectrumGutter {
			at = spectrumGutter
		}
		if at+len(text) > v.inner() {
			at = v.inner() - len(text)
		}
		if at < len(row)+1 || at < spectrumGutter {
			continue
		}
		row = append(row, strings.Repeat(" ", at-len(row))...)
		row = append(row, text...)
	}
	return v.st.Muted(string(row))
}

// peakBlock names the loudest bins as a label block: the strongest first, with
// its margin above the noise floor, which is the number that decides whether a
// frequency is worth tuning to. Every level here takes the same ramp ink the
// chart gave that column, so the list and the chart agree on what is hot.
func (v *spectrumView) peakBlock(b *strings.Builder, peaks []Peak, floor float64) {
	const col = 8
	label := func(word string) string { return v.st.Pad(v.st.Label(word), col) }
	if len(peaks) == 0 {
		b.WriteString(label("peak") + v.st.Muted("nothing above the floor") + "\n")
		return
	}
	top := peaks[0]
	head := fmt.Sprintf("%s  %s dBFS", leyline.FormatFrequency(top.CenterHz), v.levelInk(top.Db, fmtDb(top.Db)))
	margin := fmt.Sprintf("%s dB above the floor", fmtDb(top.Db-floor))
	if col+ui.Visible(head)+2+len(margin) <= v.width {
		b.WriteString(label("peak") + head + "  " + v.st.Muted(margin) + "\n")
	} else {
		b.WriteString(label("peak") + head + "\n")
		b.WriteString(strings.Repeat(" ", col) + v.st.Muted(margin) + "\n")
	}
	if len(peaks) > 1 {
		parts := make([]string, 0, len(peaks)-1)
		for _, p := range peaks[1:] {
			parts = append(parts, fmt.Sprintf("%s %s", leyline.FormatFrequency(p.CenterHz), v.levelInk(p.Db, fmtDb(p.Db))))
		}
		rest := v.st.Truncate(strings.Join(parts, ", "), v.width-col)
		b.WriteString(label("others") + rest + "\n")
	}
}

// spectrumNextStep is the one line a one-shot chart ends with: the command
// that tunes to what it just found.
func (v *spectrumView) nextStep(peaks []Peak) string {
	if len(peaks) == 0 {
		return ""
	}
	return "tune with: " + v.st.Cmd("ley tune "+megahertz(peaks[0].CenterHz)) + "\n"
}

// megahertz writes a frequency the way a person types it back into ley: MHz,
// no trailing zeros, no unit (a bare number is MHz).
func megahertz(hz uint64) string {
	s := strconv.FormatFloat(float64(hz)/1e6, 'f', 3, 64)
	s = strings.TrimRight(s, "0")
	return strings.TrimSuffix(s, ".")
}
