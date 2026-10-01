// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/reflexive-labs/leysdr/go/pkg/bandplan"
)

// indentedRows counts the body rows of a grouped table: rows sit indented
// under their heading, while the headings and the header row do not.
func indentedRows(out string) int {
	n := 0
	for _, l := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
		if strings.HasPrefix(l, "  ") && !strings.Contains(l, "NAME") {
			n++
		}
	}
	return n
}

// TestPresetsAndBands: both tables render every row from the client-local
// tables and need no daemon; --json is an array of the documented shape.
func TestPresetsAndBands(t *testing.T) {
	// A socket nothing listens on: these verbs never dial.
	sock := "/nonexistent/leyline-tables.sock"
	out, errOut, err := run(t, t.Context(), sock, "presets")
	if err != nil || errOut != "" {
		t.Fatalf("ley presets: err=%v stderr=%q", err, errOut)
	}
	// Rows are indented under their band's heading; the header row and the
	// headings are the only unindented lines.
	if rows := indentedRows(out); rows != len(bandplan.Presets()) {
		t.Fatalf("want %d preset rows, got %d:\n%s", len(bandplan.Presets()), rows, out)
	}
	if !strings.Contains(out, "NAME") || !strings.Contains(out, "noaa1, noaa, weather") {
		t.Fatalf("preset table shape:\n%s", out)
	}
	for _, head := range []string{"CB", "NOAA weather", "2 m amateur", "marine VHF", "airband", "GMRS", "MURS"} {
		if !strings.Contains(out, "\n"+head+"\n") {
			t.Fatalf("preset table is missing the %q group heading:\n%s", head, out)
		}
	}
	// The description must not restate the frequency printed beside it.
	if strings.Contains(out, "(162.550 MHz)") {
		t.Fatalf("description still restates the frequency column:\n%s", out)
	}

	out, errOut, err = run(t, t.Context(), sock, "--json", "presets")
	if err != nil || errOut != "" {
		t.Fatalf("ley presets --json: err=%v stderr=%q", err, errOut)
	}
	var ps []presetJSON
	if err := json.Unmarshal([]byte(out), &ps); err != nil {
		t.Fatalf("presets --json: %v\n%s", err, out)
	}
	if len(ps) != len(bandplan.Presets()) {
		t.Fatalf("presets --json: %d rows, want %d", len(ps), len(bandplan.Presets()))
	}
	if ps[0].Name != "cb1" || ps[0].Hz != 26_965_000 || ps[0].Mode != "am" || ps[0].BandwidthHz != 10_000 || len(ps[0].Aliases) == 0 {
		t.Fatalf("presets --json first row: %+v", ps[0])
	}

	out, errOut, err = run(t, t.Context(), sock, "bands")
	if err != nil || errOut != "" {
		t.Fatalf("ley bands: err=%v stderr=%q", err, errOut)
	}
	// The bands, then the groups (gmrs and murs, whole services) under the family they belong to.
	if want := len(bandplan.Bands()) + len(bandplan.BandGroups()); indentedRows(out) != want {
		t.Fatalf("want %d band rows, got %d:\n%s", want, indentedRows(out), out)
	}
	for _, head := range []string{"broadcast", "amateur radio", "other services", "GMRS and MURS"} {
		if !strings.Contains(out, "\n"+head+"\n") {
			t.Fatalf("band table is missing the %q group heading:\n%s", head, out)
		}
	}
	// The heading carries "amateur radio", so the note keeps only what differs.
	if strings.Contains(out, "amateur radio, LSB voice") {
		t.Fatalf("note still repeats its group heading:\n%s", out)
	}

	out, errOut, err = run(t, t.Context(), sock, "--json", "bands")
	if err != nil || errOut != "" {
		t.Fatalf("ley bands --json: err=%v stderr=%q", err, errOut)
	}
	var bs []bandJSON
	if err := json.Unmarshal([]byte(out), &bs); err != nil {
		t.Fatalf("bands --json: %v\n%s", err, out)
	}
	if want := len(bandplan.Bands()) + len(bandplan.BandGroups()); len(bs) != want {
		t.Fatalf("bands --json: %d rows, want %d", len(bs), want)
	}
	gmrs, murs := bs[len(bs)-2], bs[len(bs)-1]
	if gmrs.Aliases[0] != "gmrs" || strings.Join(gmrs.Parts, " ") != "gmrs-462 gmrs-467" || len(gmrs.Channels) != 22 {
		t.Fatalf("bands --json should end with the gmrs group, its parts and its plan: %+v", gmrs)
	}
	if murs.Aliases[0] != "murs" || strings.Join(murs.Parts, " ") != "murs-151 murs-154" || len(murs.Channels) != 5 {
		t.Fatalf("bands --json should end with the murs group after gmrs: %+v", murs)
	}
	// A band with no plan has no channels key at all, so the app's decoder sees it absent.
	if strings.Contains(out, `"name":"FM broadcast","aliases":["fm","fmbcast","broadcast"],"min_hz":87500000,"max_hz":108000000,"mode":"wfm","bandwidth_hz":200000,"step_hz":200000,"note":"wideband FM radio stations","channels"`) {
		t.Errorf("a band without a plan should omit channels: %s", out)
	}
	if !strings.Contains(out, `"channels":[{"name":"WX1","aliases":["wx1","noaa1","noaa","weather"],"hz":162550000,"note":"","decoder":"same"}`) {
		t.Errorf("NOAA's plan should open with WX1 in the documented shape: %s", out)
	}
	var hf, vhf *bandJSON
	for i := range bs {
		switch bs[i].Name {
		case "40 m amateur":
			hf = &bs[i]
		case "2 m amateur":
			vhf = &bs[i]
		}
	}
	if hf == nil || hf.Mode != "usb/lsb" || hf.MinHz != 7_000_000 {
		t.Fatalf("sideband-by-frequency band: %+v", hf)
	}
	if vhf == nil || vhf.Mode != "nfm" || vhf.BandwidthHz != 12_500 {
		t.Fatalf("2 m band: %+v", vhf)
	}
	// step_hz is the channel spacing the app tunes by, and it is not the bandwidth.
	if vhf.StepHz != 5_000 {
		t.Errorf("2 m steps 5 kHz, got %d", vhf.StepHz)
	}
	for _, b := range bs {
		if b.StepHz == 0 {
			t.Errorf("%s has no step_hz", b.Name)
		}
	}
}

// The CHANNELS count column is the first to go after BANDWIDTH when the terminal is narrow:
// ALIAS is what you type and NOTE is what a band is, so the count is the one a reader can live
// without (docs/design/channels.md, "The CLI").
func TestBandsChannelsColumnDropsFirst(t *testing.T) {
	at := func(width int) string {
		t.Helper()
		out, _, err := runApp(t, &App{IsTTY: func() bool { return true }, TermWidth: func() int { return width }}, "bands")
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	wide := at(200)
	for _, want := range []string{"CHANNELS", "BANDWIDTH", "NOTE"} {
		if !strings.Contains(wide, want) {
			t.Errorf("at 200 columns want %q:\n%s", want, wide)
		}
	}
	// The NOAA row counts its seven channels; a band with none shows a dash.
	for _, l := range strings.Split(wide, "\n") {
		switch {
		case strings.HasPrefix(l, "  NOAA weather") && !strings.Contains(l, "  7  "):
			t.Errorf("NOAA counts 7 channels: %q", l)
		case strings.HasPrefix(l, "  FM broadcast") && !strings.Contains(l, "  -  "):
			t.Errorf("FM broadcast has no channels: %q", l)
		}
	}
	ninety := at(90)
	if !strings.Contains(ninety, "CHANNELS") || strings.Contains(ninety, "BANDWIDTH") {
		t.Errorf("at 90 columns BANDWIDTH goes and CHANNELS stays:\n%s", ninety)
	}
	eighty := at(80)
	if strings.Contains(eighty, "CHANNELS") || strings.Contains(eighty, "BANDWIDTH") || !strings.Contains(eighty, "NOTE") {
		t.Errorf("at 80 columns CHANNELS goes after BANDWIDTH and NOTE stays:\n%s", eighty)
	}
}

// TestPresetsTopicKeepsProse: `ley presets` is the table while `ley help
// presets` stays the prose topic (the verb owns the bare name).
func TestPresetsTopicKeepsProse(t *testing.T) {
	sock := "/nonexistent/leyline-tables.sock"
	table, _, err := run(t, t.Context(), sock, "presets")
	if err != nil {
		t.Fatal(err)
	}
	prose, _, err := run(t, t.Context(), sock, "help", "presets")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(prose, "Presets are names 'ley tune' accepts") {
		t.Fatalf("ley help presets lost its prose:\n%s", prose)
	}
	if prose == table {
		t.Fatalf("ley presets and ley help presets should differ")
	}
}

// The Mac app has no Go library, so its sidebar reads the band table from a checked-in copy of
// what `ley bands --json` prints (docs/design/channels.md, "Bands and bookmarks are files"). This
// is the drift test the help goldens are: the resource is the exact bytes, and a change to the
// table without a regeneration fails here rather than in a window.
func TestBandsJSONResource(t *testing.T) {
	const resource = "../../../app/Sources/LeylineClient/Resources/bands.json"
	want, err := os.ReadFile(resource)
	if err != nil {
		t.Fatalf("%v; run: make bands-json", err)
	}
	got, errOut, err := run(t, t.Context(), "/nonexistent/leyline-tables.sock", "--json", "bands")
	if err != nil || errOut != "" {
		t.Fatalf("ley bands --json: err=%v stderr=%q", err, errOut)
	}
	if string(want) != got {
		t.Errorf("app/Sources/LeylineClient/Resources/bands.json is not what ley bands --json prints;\nrun: make bands-json\n--- file\n%s\n--- command\n%s", want, got)
	}
}
