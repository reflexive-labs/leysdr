// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"strings"
	"testing"

	"github.com/reflexive-labs/leysdr/go/internal/ui"
)

// A sparkline is eight cells of the column ramp, oldest left, and a slice with
// anything in it is never blank: the picture exists to show a carrier that
// keyed once, so rounding it away would defeat it.
func TestSparklineNeverHidesASlice(t *testing.T) {
	st := ui.Style{Unicode: true}
	fracs := []float64{0, 0.01, 0.125, 0.5, 1, 2, -1, 0.99}
	got := sparkline(st, fracs)
	cells := []rune(got)
	if len(cells) != sparkCells {
		t.Fatalf("sparkline of %d values is %d cells: %q", len(fracs), len(cells), got)
	}
	ramp := []rune(st.Glyphs().Ramp)
	want := []rune{ramp[0], ramp[1], ramp[1], ramp[4], ramp[8], ramp[8], ramp[0], ramp[8]}
	if string(cells) != string(want) {
		t.Errorf("sparkline(%v) = %q, want %q", fracs, got, string(want))
	}
	ascii := sparkline(ui.Style{}, fracs)
	if strings.ContainsAny(ascii, "▁▂▃▄▅▆▇█") || len([]rune(ascii)) != sparkCells {
		t.Errorf("ASCII sparkline should use the fallback ramp: %q", ascii)
	}
}

// A level sparkline inks each cell by its level and strips back to the plain
// one character for character (docs/dev/cli-style.md, section 8).
func TestLevelSparklineStripsToPlain(t *testing.T) {
	fracs := []float64{0, 0.2, 0.4, 0.6, 0.8, 1, 0.5, 0}
	for _, uni := range []bool{false, true} {
		plain := sparkline(ui.Style{Unicode: uni}, fracs)
		styled := levelSparkline(ui.Style{Color: true, Profile: ui.ProfileTrueColor, Unicode: uni}, fracs)
		if ui.Strip(styled) != plain {
			t.Errorf("unicode %v: Strip(levelSparkline) = %q, want %q", uni, ui.Strip(styled), plain)
		}
		if !strings.Contains(styled, "\x1b[38;2;") {
			t.Errorf("unicode %v: a level sparkline with colour on drew no ramp ink: %q", uni, styled)
		}
		if got := levelSparkline(ui.Style{Unicode: uni}, fracs); got != plain {
			t.Errorf("unicode %v: colour off should be the plain sparkline, got %q", uni, got)
		}
	}
}

// sliceCounts puts each event in the slice its time falls in, and an event at
// the very end of the span in the last slice rather than off the end.
func TestSliceCounts(t *testing.T) {
	got := sliceCounts([]float64{0, 0.1, 7.9, 8, 8.4, 3.99, 4, -1}, 8, sparkCells)
	want := []int{2, 0, 0, 1, 1, 0, 0, 3}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("sliceCounts = %v, want %v", got, want)
		}
	}
	if got := sliceCounts([]float64{1, 2}, 0, sparkCells); got[0] != 0 || len(got) != sparkCells {
		t.Errorf("an empty span should count nothing, got %v", got)
	}
}
