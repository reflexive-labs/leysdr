// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/dpup/leysdr/go/pkg/leyline"
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
	out, errOut, err := run(t, context.Background(), sock, "presets")
	if err != nil || errOut != "" {
		t.Fatalf("ley presets: err=%v stderr=%q", err, errOut)
	}
	// Rows are indented under their band's heading; the header row and the
	// headings are the only unindented lines.
	if rows := indentedRows(out); rows != len(leyline.Presets()) {
		t.Fatalf("want %d preset rows, got %d:\n%s", len(leyline.Presets()), rows, out)
	}
	if !strings.Contains(out, "NAME") || !strings.Contains(out, "noaa, wx1, weather") {
		t.Fatalf("preset table shape:\n%s", out)
	}
	for _, head := range []string{"NOAA weather", "2 m amateur", "marine VHF", "airband"} {
		if !strings.Contains(out, "\n"+head+"\n") {
			t.Fatalf("preset table is missing the %q group heading:\n%s", head, out)
		}
	}
	// The description must not restate the frequency printed beside it.
	if strings.Contains(out, "(162.550 MHz)") {
		t.Fatalf("description still restates the frequency column:\n%s", out)
	}

	out, errOut, err = run(t, context.Background(), sock, "--json", "presets")
	if err != nil || errOut != "" {
		t.Fatalf("ley presets --json: err=%v stderr=%q", err, errOut)
	}
	var ps []presetJSON
	if err := json.Unmarshal([]byte(out), &ps); err != nil {
		t.Fatalf("presets --json: %v\n%s", err, out)
	}
	if len(ps) != len(leyline.Presets()) {
		t.Fatalf("presets --json: %d rows, want %d", len(ps), len(leyline.Presets()))
	}
	if ps[0].Name != "noaa1" || ps[0].Hz != 162_550_000 || ps[0].Mode != "nfm" || len(ps[0].Aliases) == 0 {
		t.Fatalf("presets --json first row: %+v", ps[0])
	}

	out, errOut, err = run(t, context.Background(), sock, "bands")
	if err != nil || errOut != "" {
		t.Fatalf("ley bands: err=%v stderr=%q", err, errOut)
	}
	// The bands, then the groups (gmrs, the whole service) under the family they belong to.
	if want := len(leyline.Bands()) + len(leyline.BandGroups()); indentedRows(out) != want {
		t.Fatalf("want %d band rows, got %d:\n%s", want, indentedRows(out), out)
	}
	for _, head := range []string{"broadcast", "amateur radio", "other services", "GMRS"} {
		if !strings.Contains(out, "\n"+head+"\n") {
			t.Fatalf("band table is missing the %q group heading:\n%s", head, out)
		}
	}
	// The heading carries "amateur radio", so the note keeps only what differs.
	if strings.Contains(out, "amateur radio, LSB voice") {
		t.Fatalf("note still repeats its group heading:\n%s", out)
	}

	out, errOut, err = run(t, context.Background(), sock, "--json", "bands")
	if err != nil || errOut != "" {
		t.Fatalf("ley bands --json: err=%v stderr=%q", err, errOut)
	}
	var bs []bandJSON
	if err := json.Unmarshal([]byte(out), &bs); err != nil {
		t.Fatalf("bands --json: %v\n%s", err, out)
	}
	if want := len(leyline.Bands()) + len(leyline.BandGroups()); len(bs) != want {
		t.Fatalf("bands --json: %d rows, want %d", len(bs), want)
	}
	if last := bs[len(bs)-1]; last.Aliases[0] != "gmrs" || strings.Join(last.Parts, " ") != "gmrs-462 gmrs-467" {
		t.Fatalf("bands --json should end with the gmrs group and its parts: %+v", last)
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

// TestPresetsTopicKeepsProse: `ley presets` is the table while `ley help
// presets` stays the prose topic (the verb owns the bare name).
func TestPresetsTopicKeepsProse(t *testing.T) {
	sock := "/nonexistent/leyline-tables.sock"
	table, _, err := run(t, context.Background(), sock, "presets")
	if err != nil {
		t.Fatal(err)
	}
	prose, _, err := run(t, context.Background(), sock, "help", "presets")
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
// what `ley bands --json` prints (docs/design/app-design-handoff.md, "Bands and bookmarks are
// files"). This is the drift test the help goldens are: the resource is the exact bytes, and a
// change to the table without a regeneration fails here rather than in a window.
func TestBandsJSONResource(t *testing.T) {
	const resource = "../../../app/Sources/LeylineClient/Resources/bands.json"
	want, err := os.ReadFile(resource)
	if err != nil {
		t.Fatalf("%v; run: make bands-json", err)
	}
	got, errOut, err := run(t, context.Background(), "/nonexistent/leyline-tables.sock", "--json", "bands")
	if err != nil || errOut != "" {
		t.Fatalf("ley bands --json: err=%v stderr=%q", err, errOut)
	}
	if string(want) != got {
		t.Errorf("app/Sources/LeylineClient/Resources/bands.json is not what ley bands --json prints;\nrun: make bands-json\n--- file\n%s\n--- command\n%s", want, got)
	}
}
