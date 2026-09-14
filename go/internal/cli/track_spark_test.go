// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bytes"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/records"
)

// HEARD spreads a station's records across the window, an eighth per cell,
// one ramp step per record: a beaconing station and a one-off packet read
// differently, and the header says what a cell covers.
func TestTrackHeardColumn(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	table := records.NewTable()
	clock := now.Add(-25 * time.Minute)
	table.Now = func() time.Time { return clock }
	rec := func(id string) *leylinev1.DecodeRecord {
		return &leylinev1.DecodeRecord{
			Protocol: "aprs", DeviceId: id, Kind: "status",
			Fields: map[string]*leylinev1.FieldValue{"text": {Value: &leylinev1.FieldValue_Text{Text: "hi"}}},
		}
	}
	for _, ago := range []time.Duration{25, 15, 5, 0} {
		clock = now.Add(-ago * time.Minute)
		table.Apply(rec("BEACON"))
	}
	clock = now.Add(-time.Minute)
	table.Apply(rec("ONCE"))
	table.Apply(rec("ONCE"))
	const window = 30 * time.Minute
	rows := table.Rows()
	byID := map[string]*records.Entity{}
	for _, e := range rows {
		byID[e.DeviceID] = e
	}
	// 30 min in 8 slices of 3.75 min: 25 min ago is slice 1, 15 is slice 4,
	// 5 is slice 6, now is slice 7.
	if got := heardSlices(byID["BEACON"], now, window); got[1] != 1 || got[4] != 1 || got[6] != 1 || got[7] != 1 || got[0]+got[2]+got[3]+got[5] != 0 {
		t.Errorf("BEACON slices = %v", got)
	}
	if got := heardSlices(byID["ONCE"], now, window); got[7] != 2 || got[0]+got[1]+got[2]+got[3]+got[4]+got[5]+got[6] != 0 {
		t.Errorf("ONCE slices = %v", got)
	}
	clock = now
	render := func(st ui.Style) string {
		var out bytes.Buffer
		app := &App{Stdout: &out, Style: st, ErrStyle: st, IsTTY: func() bool { return true }}
		return renderTrack(app, table, window)
	}
	for _, width := range []int{40, 80, 160} {
		plain := render(ui.Style{Unicode: true, Width: width})
		styled := render(ui.Style{Color: true, Profile: ui.ProfileTrueColor, Unicode: true, Width: width})
		if ui.Strip(styled) != plain {
			t.Errorf("width %d:\n plain  %q\n styled %q", width, plain, ui.Strip(styled))
		}
		for _, line := range strings.Split(strings.TrimRight(plain, "\n"), "\n") {
			if ui.Visible(line) > width {
				t.Errorf("width %d: %d columns: %q", width, ui.Visible(line), line)
			}
		}
		if width == 40 {
			continue
		}
		if !strings.Contains(plain, "HEARD (30 m)") {
			t.Errorf("width %d: the header should name the window:\n%s", width, plain)
		}
		lines := strings.Split(strings.TrimRight(plain, "\n"), "\n")
		var beacon, once string
		for _, l := range lines {
			switch {
			case strings.HasPrefix(l, "BEACON"):
				beacon = l
			case strings.HasPrefix(l, "ONCE"):
				once = l
			}
		}
		if strings.Count(beacon, "▁") != 4 {
			t.Errorf("width %d: BEACON should show four single-record cells: %q", width, beacon)
		}
		if strings.Count(once, "▂") != 1 || strings.Contains(once, "▁") {
			t.Errorf("width %d: ONCE should show one two-record cell: %q", width, once)
		}
	}
}
