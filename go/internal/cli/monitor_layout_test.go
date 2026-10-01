// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bytes"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// The report follows the layout rules of docs/dev/cli-style.md section 5: units
// once in the header and bare numbers in the cells, the time gutter dimmed and
// stamped only when it changes, a CHANNEL column only where a row has one, and
// the ACTIVITY header naming the span its cells cover.
func TestMonitorReportLayout(t *testing.T) {
	// The FM broadcast band: no named channels, three carriers, two of them
	// first heard in the same second.
	order := []string{"a", "b", "c"}
	carriers := map[string]*monitorCarrier{
		"a": {id: "a", centerHz: 88_505_000, bwHz: 180_000, firstS: 1.2, lastS: 60, peakSNR: 43, looks: 240, looksPossible: 240},
		"b": {id: "b", centerHz: 88_650_000, bwHz: 180_000, firstS: 1.4, lastS: 60, peakSNR: 13, looks: 170, looksPossible: 240},
		"c": {id: "c", centerHz: 88_309_000, bwHz: 180_000, firstS: 30, lastS: 30.4, peakSNR: 10, looks: 2, looksPossible: 121},
	}
	for _, c := range carriers {
		for i := 0; i < int(c.looks); i++ {
			c.hits = append(c.hits, c.firstS+float64(i)*0.25)
		}
	}
	o := monitorOptions{rangeInput: "88..89", minHz: 88_000_000, maxHz: 89_000_000, minSNR: 8}
	render := func(st ui.Style) (string, string) {
		var out, errb bytes.Buffer
		app := &App{Stdout: &out, Stderr: &errb, Style: st, ErrStyle: st, IsTTY: func() bool { return true }}
		printMonitorReport(app, o, order, carriers, time.Minute)
		return out.String(), errb.String()
	}
	plain, summary := render(ui.Style{Unicode: true, Width: 120})
	styled, _ := render(ui.Style{Color: true, Profile: ui.ProfileTrueColor, Unicode: true, Width: 120})
	if ui.Strip(styled) != plain {
		t.Errorf("\n plain  %q\n styled %q", plain, ui.Strip(styled))
	}
	lines := strings.Split(strings.TrimRight(plain, "\n"), "\n")
	if len(lines) != 4 {
		t.Fatalf("want a header and three rows:\n%s", plain)
	}
	head := lines[0]
	for _, want := range []string{"HELD (s)", "ON AIR (s)", "PEAK SNR (dB)", "ACTIVITY (1 min)"} {
		if !strings.Contains(head, want) {
			t.Errorf("header lacks %q: %q", want, head)
		}
	}
	if strings.Contains(head, "CHANNEL") {
		t.Errorf("a band with no named channels should have no CHANNEL column: %q", head)
	}
	for _, l := range lines[1:] {
		if strings.Contains(l, " s ") || strings.HasSuffix(l, " dB") || strings.Contains(l, "under 1") {
			t.Errorf("units belong in the header, not the cell: %q", l)
		}
	}
	// The gutter stamps 0:01 once for the two carriers heard in that second,
	// then 0:30 for the third, and the frequency is the first thing after it.
	if !strings.HasPrefix(lines[1], "0:01  88.505 MHz") || !strings.HasPrefix(lines[2], "      88.650 MHz") || !strings.HasPrefix(lines[3], "0:30  88.309 MHz") {
		t.Errorf("time gutter should stamp on change only:\n%s", plain)
	}
	// A sub-second hold reads "<1", not a value rounded to 0 and not prose.
	if !strings.Contains(lines[3], " <1 ") {
		t.Errorf("a sub-second HELD should read <1: %q", lines[3])
	}
	// The activity sparkline is Muted and the peak SNR takes the level ramp,
	// keyed from --min-snr, so 43 dB and 13 dB are different inks.
	srows := strings.Split(strings.TrimRight(styled, "\n"), "\n")
	// The first eighth of the watch starts at 1.2 s, so its cell is one step short.
	if !strings.Contains(srows[1], "\x1b[2m▇"+strings.Repeat("█", sparkCells-1)+"\x1b[0m") {
		t.Errorf("the activity cells should be Muted: %q", srows[1])
	}
	ink := ui.Style{Color: true, Profile: ui.ProfileTrueColor}
	hot, cold := ink.Level(rampFrac(43, 8, 48), "43"), ink.Level(rampFrac(13, 8, 48), "13")
	if !strings.Contains(srows[1], hot) || !strings.Contains(srows[2], cold) || hot[:12] == cold[:12] {
		t.Errorf("PEAK SNR should take the ramp from --min-snr upward:\n%s", styled)
	}
	// The summary names the strongest carrier once, with no parenthetical
	// repeating the number, and the whole table still fits at 80 columns
	// (and gives up ACTIVITY at 40).
	if !strings.Contains(summary, "strongest 88.505 MHz at 43 dB") || strings.Contains(summary, "(88.505)") {
		t.Errorf("summary should name an unlabelled carrier once: %q", summary)
	}
	// At 80 columns everything fits; at 40 the mandatory columns alone do not,
	// so ACTIVITY goes first and the rest prints wide rather than mangled.
	for _, width := range []int{40, 80, 160} {
		out, _ := render(ui.Style{Unicode: true, Width: width})
		if width >= 80 {
			for _, l := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
				if ui.Visible(l) > width {
					t.Errorf("width %d: %d columns: %q", width, ui.Visible(l), l)
				}
			}
		}
		if has := strings.Contains(out, "ACTIVITY"); has != (width >= 80) {
			t.Errorf("width %d: ACTIVITY present = %v", width, has)
		}
	}
	// A band with named channels keeps its CHANNEL column, and the summary
	// pairs the label with the number ley tune takes.
	gmrs := map[string]*monitorCarrier{"g": {id: "g", centerHz: 462_625_000, bwHz: 12_500, firstS: 1, lastS: 9, peakSNR: 40, looks: 30, looksPossible: 30, hits: []float64{1}}}
	var out, errb bytes.Buffer
	app := &App{Stdout: &out, Stderr: &errb, IsTTY: func() bool { return false }}
	printMonitorReport(app, monitorOptions{rangeInput: "gmrs"}, []string{"g"}, gmrs, 10*time.Second)
	if !strings.Contains(out.String(), "CHANNEL") || !strings.Contains(out.String(), "ch18") {
		t.Errorf("GMRS should keep its CHANNEL column:\n%s", out.String())
	}
	if !strings.Contains(errb.String(), "strongest ch18 (462.625) at 40 dB") {
		t.Errorf("a labelled carrier pairs label and number: %q", errb.String())
	}
}

// The live feed prints a carrier once, the first time it clears --min-snr,
// leaves the absent channel out rather than printing a dash beside the level,
// and inks the level by the ramp.
func TestMonitorLiveLine(t *testing.T) {
	o := monitorOptions{minSNR: 8}
	c := &monitorCarrier{centerHz: 88_309_000, peakSNR: 10}
	plain := liveLine(ui.Style{}, o, 61, c)
	if plain != "  1:01  88.309 MHz  10 dB" {
		t.Errorf("liveLine = %q", plain)
	}
	styled := liveLine(ui.Style{Color: true, Profile: ui.ProfileTrueColor}, o, 61, c)
	if ui.Strip(styled) != plain || !strings.Contains(styled, "\x1b[38;2;") {
		t.Errorf("styled live line = %q, want the plain line with ramp ink", styled)
	}
	g := &monitorCarrier{centerHz: 462_625_000, peakSNR: 40}
	if got := liveLine(ui.Style{}, o, 1, g); got != "  0:01  462.625 MHz  ch18  40 dB" {
		t.Errorf("a labelled carrier names its channel: %q", got)
	}
	// Announced once the peak clears the floor: refinedNote then says when the
	// table's frequency moved on from the one printed.
	rows := []*monitorCarrier{{centerHz: 88_505_000, announced: true, announcedHz: 88_506_000}, {centerHz: 88_650_000, announced: true, announcedHz: 88_653_000}}
	if refinedNote(rows) == "" {
		t.Errorf("a 3 kHz refinement should be stated once")
	}
	if refinedNote([]*monitorCarrier{{centerHz: 88_505_000, announced: true, announcedHz: 88_505_400}}) != "" {
		t.Errorf("a refinement under a kHz is not worth a line")
	}
}

// The daemon's own sentence for a too-wide band already names the remedy, so
// ley does not say it again in other words; and the range parser's sentences
// have no field prefix, since the error shape is "ley: <sentence>".
func TestMonitorFailureAndRangeWording(t *testing.T) {
	job := &leylinev1.Job{
		StatusDetail: "band 2.000 MHz wide is too wide to watch in one capture; use ley scan, which sweeps",
		Error:        &leylinev1.ErrorDetail{Code: leyline.CodeInvalidArgument},
	}
	st := ui.Style{Color: true}
	got := monitorFailure(job, st, nil)
	if strings.Count(ui.Strip(got), "ley scan") != 1 {
		t.Errorf("the remedy should appear once: %q", got)
	}
	// The daemon's "use ley scan, which sweeps" lead takes Cmd ink on the
	// command alone.
	if line := errorLine(st, got); !strings.Contains(line, st.Cmd("ley scan")+", which sweeps") {
		t.Errorf("the remedy after \"use \" should be Cmd up to the comma: %q", line)
	}
	other := &leylinev1.Job{StatusDetail: "no", Error: &leylinev1.ErrorDetail{Code: leyline.CodeInvalidArgument}}
	if got := monitorFailure(other, ui.Style{}, nil); !strings.Contains(got, "ley scan sweeps") {
		t.Errorf("a detail with no remedy still gets one: %q", got)
	}
	for _, in := range []string{"88.5", "89M..88M", "gmrs"} {
		_, _, err := parseRange(in)
		if err == nil || strings.HasPrefix(err.Error(), "range:") {
			t.Errorf("parseRange(%q) = %v, want a sentence with no field prefix", in, err)
		}
	}
}
