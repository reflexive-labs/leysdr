// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"math"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
)

// The history keeps the last eight seconds of reported levels and gives back
// the loudest of each second, oldest first, on the meter's own scale.
func TestMeterHistoryFracs(t *testing.T) {
	var h meterHistory
	if got := h.fracs(time.Now()); got != nil {
		t.Errorf("a meter with no past should draw none, got %v", got)
	}
	t0 := time.Unix(1_700_000_000, 0)
	h.add(-80, t0.Add(-20*time.Second)) // forgotten: outside the span
	h.add(-45, t0.Add(-4*time.Second))
	h.add(-30, t0.Add(-3500*time.Millisecond)) // the louder report in that second wins
	h.add(-60, t0.Add(-3200*time.Millisecond))
	h.add(-20, t0)
	got := h.fracs(t0)
	if len(got) != sparkCells {
		t.Fatalf("fracs = %v, want %d cells", got, sparkCells)
	}
	if got[4] != meterFrac(-30) {
		t.Errorf("the second 4 s ago should hold its loudest report (-30 dBFS): %v", got)
	}
	if got[sparkCells-1] != meterFrac(-20) {
		t.Errorf("the current second should be the latest report: %v", got)
	}
	for i, f := range got {
		if i != 4 && i != sparkCells-1 && f != 0 {
			t.Errorf("a second with no report should be 0: slice %d = %v", i, f)
		}
	}
	if len(h.at) != 4 {
		t.Errorf("a report older than the span should be forgotten, kept %d", len(h.at))
	}
}

// The sparkline sits on the signal detail row, is inked by level, strips to
// the plain row, and never pushes a row past the terminal.
func TestMeterHistoryOnTheSignalRow(t *testing.T) {
	m := &leylinev1.Meter{PowerDbfs: -42, SquelchOpen: true, AudioDbfs: -20, AudioPeakDbfs: -10, SnrDb: math.NaN()}
	hist := []float64{0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1}
	for _, width := range []int{60, 80, 160} {
		plain := meterRenderHistory(ui.Style{Unicode: true, Width: width}, 146_620_000, leylinev1.DemodMode_NFM, m, -60, hist, onAir{})
		styled := meterRenderHistory(ui.Style{Color: true, Profile: ui.ProfileTrueColor, Unicode: true, Width: width}, 146_620_000, leylinev1.DemodMode_NFM, m, -60, hist, onAir{})
		if ui.Strip(styled) != plain {
			t.Errorf("width %d:\n plain  %q\n styled %q", width, plain, ui.Strip(styled))
		}
		rows := strings.Split(plain, "\n")
		if len(rows) != 3 {
			t.Fatalf("width %d: want the line and two detail rows:\n%s", width, plain)
		}
		for _, r := range rows {
			if ui.Visible(r) > width {
				t.Errorf("width %d: a row is %d columns: %q", width, ui.Visible(r), r)
			}
		}
		if !strings.HasSuffix(rows[1], "▁▂▃▄▅▆▇█") {
			t.Errorf("width %d: the signal row should end with the history: %q", width, rows[1])
		}
		if strings.ContainsAny(rows[2], "▁▂▃▄▅▆▇") {
			t.Errorf("width %d: the audio row carries no history: %q", width, rows[2])
		}
	}
	// No history, no cells: the row is what it was before.
	before := meterRender(ui.Style{Unicode: true, Width: 80}, 146_620_000, leylinev1.DemodMode_NFM, m, -60)
	if got := meterRenderHistory(ui.Style{Unicode: true, Width: 80}, 146_620_000, leylinev1.DemodMode_NFM, m, -60, nil, onAir{}); got != before {
		t.Errorf("a nil history should change nothing:\n%q\n%q", got, before)
	}
}

// The sink times its own history, so the line it draws carries the levels of
// the last few seconds.
func TestMeterSinkKeepsHistory(t *testing.T) {
	var out strings.Builder
	now := time.Unix(1_700_000_000, 0)
	sink := &meterSink{w: &out, style: ui.Style{Unicode: true, Width: 100}, tty: true, now: func() time.Time { return now }}
	m := &leylinev1.Meter{PowerDbfs: -30, SquelchOpen: true, AudioDbfs: -20, AudioPeakDbfs: -10, SnrDb: math.NaN()}
	sink.line(146_620_000, leylinev1.DemodMode_NFM, m, -60, onAir{})
	now = now.Add(3 * time.Second)
	quiet := &leylinev1.Meter{PowerDbfs: -85, SquelchOpen: false, AudioDbfs: -60, AudioPeakDbfs: -50, SnrDb: math.NaN()}
	line := sink.line(146_620_000, leylinev1.DemodMode_NFM, quiet, -60, onAir{})
	signal := strings.Split(line, "\n")[1]
	// Three seconds ago was loud (slot 5 of the eight-second span), now is
	// quiet (slot 7, lifted to the first step because something was
	// measured); the rest is blank.
	want := "     " + string([]rune(ui.Style{Unicode: true}.Glyphs().Ramp)[5]) + " " + "▁"
	if !strings.HasSuffix(signal, want) {
		t.Errorf("signal row = %q, want it to end with %q", signal, want)
	}
}
