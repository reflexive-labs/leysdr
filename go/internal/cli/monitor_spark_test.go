// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/reflexive-labs/leysdr/go/internal/ui"
)

// activity is the carrier's on-air share of each eighth of the watch, from the
// arrival times of its updates against the detector's row rate: a carrier
// heard every row reads full across, one heard in a single row reads one
// partial cell where it happened.
func TestMonitorActivity(t *testing.T) {
	const watched, rate = 8.0, 4.0 // 8 s at 4 rows/s: 4 rows per slice
	held := &monitorCarrier{}
	for i := 0; i < 32; i++ {
		held.hits = append(held.hits, float64(i)*0.25)
	}
	for i, f := range held.activity(watched, rate) {
		if f != 1 {
			t.Errorf("a carrier heard every row: slice %d = %v, want 1", i, f)
		}
	}
	burst := &monitorCarrier{hits: []float64{5.5, 5.75}}
	got := burst.activity(watched, rate)
	for i, f := range got {
		want := 0.0
		if i == 5 {
			want = 0.5
		}
		if f != want {
			t.Errorf("a two-row burst at 5.5 s: slice %d = %v, want %v (all %v)", i, f, want, got)
		}
	}
	// No look counts, no row rate: a slice with any update reads full rather
	// than a share nobody measured.
	if got := burst.activity(watched, 0); got[5] != 1 || got[0] != 0 {
		t.Errorf("without a row rate a heard slice should read full: %v", got)
	}
	// The rate is read off the carrier with the most rows to its last sighting.
	carriers := map[string]*monitorCarrier{
		"a": {lastS: 10, looksPossible: 40},
		"b": {lastS: 2, looksPossible: 6},
		"c": {lastS: 5, looksPossible: 0},
	}
	if got := monitorRowRate(carriers); got != 4 {
		t.Errorf("monitorRowRate = %v, want 4 rows/s", got)
	}
}

// The report renders twice to the same plain text, keeps every line inside
// the terminal it is on, and gives up the ACTIVITY column first when the
// table does not fit.
func TestMonitorReportSparklineFitsAndStrips(t *testing.T) {
	order := []string{"a", "b"}
	carriers := map[string]*monitorCarrier{
		"a": {id: "a", centerHz: 462_625_000, bwHz: 12_500, firstS: 0.1, lastS: 9.9, peakSNR: 40, looks: 40, looksPossible: 40},
		"b": {id: "b", centerHz: 462_662_500, bwHz: 12_500, firstS: 1, lastS: 6, peakSNR: 14, looks: 3, looksPossible: 24},
	}
	for i := 0; i < 40; i++ {
		carriers["a"].hits = append(carriers["a"].hits, 0.1+float64(i)*0.25)
	}
	carriers["b"].hits = []float64{1, 1.25, 6}
	o := monitorOptions{rangeInput: "gmrs", minHz: 462_500_000, maxHz: 462_750_000}
	render := func(st ui.Style) string {
		var out, errb bytes.Buffer
		app := &App{Stdout: &out, Stderr: &errb, Style: st, ErrStyle: st, IsTTY: func() bool { return true }}
		printMonitorReport(app, o, order, carriers, 10*time.Second)
		return out.String()
	}
	// 81, not 80: a GMRS interstitial (462.6625 MHz) costs the frequency column a fourth
	// decimal, and the report as laid out needs one column more than 80 to keep ACTIVITY.
	// At 80 the sparkline is the column dropped, which is the drop order this test pins.
	for _, width := range []int{40, 81, 160} {
		plain := render(ui.Style{Unicode: true, Width: width})
		styled := render(ui.Style{Color: true, Profile: ui.ProfileTrueColor, Unicode: true, Width: width})
		if ui.Strip(styled) != plain {
			t.Errorf("width %d:\n plain  %q\n styled %q", width, plain, ui.Strip(styled))
		}
		has := strings.Contains(plain, "ACTIVITY")
		if width == 40 {
			if has {
				t.Errorf("width 40 should drop ACTIVITY before anything else:\n%s", plain)
			}
			continue
		}
		if !has {
			t.Errorf("width %d should carry ACTIVITY:\n%s", width, plain)
		}
		for _, line := range strings.Split(strings.TrimRight(plain, "\n"), "\n") {
			if ui.Visible(line) > width {
				t.Errorf("width %d: %d columns: %q", width, ui.Visible(line), line)
			}
		}
		// The held carrier is full across; the burst has ink in two slices only.
		rows := strings.Split(strings.TrimRight(plain, "\n"), "\n")
		if len(rows) != 3 {
			t.Fatalf("want a header and two rows:\n%s", plain)
		}
		if !strings.Contains(rows[1], strings.Repeat("█", sparkCells)) {
			t.Errorf("a carrier heard every row should read full across: %q", rows[1])
		}
		if strings.Contains(rows[2], strings.Repeat("█", 2)) || !strings.ContainsAny(rows[2], "▁▂▃▄▅▆▇█") {
			t.Errorf("a burst should read as a few partial cells: %q", rows[2])
		}
	}
}

// The fake daemon publishes a carrier only in the rows it is heard, as leylined
// does, so the on-air slices from a real watch separate a carrier held down from
// one that keys now and then.
func TestMonitorActivityFromTheDaemon(t *testing.T) {
	t.Parallel()
	sock, _ := harness(t, monitorOpts())
	out := mustRun(t, sock, "--json", "monitor", "gmrs-462", "--for", "1s")
	slices := map[string][]float64{}
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		var c struct {
			Channel     string    `json:"channel"`
			OnAirSlices []float64 `json:"on_air_slices"`
		}
		if err := json.Unmarshal([]byte(line), &c); err != nil {
			t.Fatalf("%v\n%s", err, line)
		}
		if len(c.OnAirSlices) != sparkCells {
			t.Fatalf("%s: on_air_slices has %d entries, want %d", c.Channel, len(c.OnAirSlices), sparkCells)
		}
		slices[c.Channel] = c.OnAirSlices
	}
	lit := func(s []float64) int {
		n := 0
		for _, f := range s {
			if f < 0 || f > 1 {
				t.Errorf("a slice must be a share in [0, 1]: %v", s)
			}
			if f > 0 {
				n++
			}
		}
		return n
	}
	// ch18 is heard every cycle: nearly every slice lit (timing jitter may
	// leave one empty). ch5 is heard one cycle in four.
	if got := lit(slices["ch18"]); got < sparkCells-2 {
		t.Errorf("ch18 is on air the whole watch, got %d lit slices: %v", got, slices["ch18"])
	}
	if got := lit(slices["ch5"]); got == 0 || got > sparkCells/2 {
		t.Errorf("ch5 keys one cycle in four, got %d lit slices: %v", got, slices["ch5"])
	}
}
