// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"math"

	"github.com/dpup/leysdr/go/internal/ui"
)

// sparkCells is the width of every inline sparkline: eight cells, one line,
// never a chart. Eight is what fits beside a table row without becoming the
// widest thing in it, and it is the column ramp's own step count, so a
// sparkline of one event per slice climbs one glyph at a time.
const sparkCells = 8

// sparkline draws one column of the spectrum ramp per value, oldest on the
// left and newest on the right, the way a log reads. It exists for one
// question a table cannot answer in a number: was this busy the whole time,
// or busy once. It is allowed only where every cell is a measurement the
// daemon actually made in that slice (docs/dev/cli-style.md, section 5); a
// ramp drawn from a count would show history that was never measured.
//
// A slice with anything in it is never blank. The ramp rounds to the nearest
// step, so a fraction under a sixteenth would draw as a space and a carrier
// that keyed once in a slice would disappear from the sparkline. Muted ink:
// occupancy is not a level, the glyph carries it, and eight full blocks in the
// terminal's foreground would be the brightest thing on the screen, ahead of
// the numbers the row exists to report.
func sparkline(st ui.Style, fracs []float64) string {
	out := make([]rune, 0, len(fracs))
	for _, f := range fracs {
		out = append(out, []rune(st.Ramp(sparkFloor(f)))...)
	}
	return st.Muted(string(out))
}

// levelSparkline is sparkline for a series that is a level: each cell also
// takes the ramp ink its value lands on, as every chart cell does, so a loud
// second reads hot and a quiet one cold. Neighbouring cells on one step share
// a run of ink.
func levelSparkline(st ui.Style, fracs []float64) string {
	line := &inkedLine{st: st}
	for _, f := range fracs {
		f = sparkFloor(f)
		band := inkPlain
		if f > 0 {
			band = rampBand(f)
		}
		line.add(st.Ramp(f), band)
	}
	return line.String()
}

// sparkFloor lifts a small non-zero value to the ramp's first step.
func sparkFloor(f float64) float64 {
	if math.IsNaN(f) || f <= 0 {
		return 0
	}
	if f < 1.0/sparkCells {
		return 1.0 / sparkCells
	}
	return f
}

// sliceCounts buckets event times, in seconds from the start of a span, into
// n equal slices of that span. An event at or past the end lands in the last
// slice rather than off the end: the span is the watch as the clock measured
// it, and the last update of a run arrives a rounding after it.
func sliceCounts(times []float64, span float64, n int) []int {
	counts := make([]int, n)
	if n <= 0 || span <= 0 {
		return counts
	}
	for _, t := range times {
		if t < 0 || math.IsNaN(t) {
			continue
		}
		i := int(t / span * float64(n))
		if i >= n {
			i = n - 1
		}
		counts[i]++
	}
	return counts
}
