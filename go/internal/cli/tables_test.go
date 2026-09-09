package cli

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/dpup/leysdr/go/pkg/leyline"
)

// TestPresetsAndBands: both tables render every row from the client-local
// tables and need no daemon; --json is an array of the documented shape.
func TestPresetsAndBands(t *testing.T) {
	// A socket nothing listens on: these verbs never dial.
	sock := "/nonexistent/leyline-tables.sock"
	out, errOut, err := run(t, context.Background(), sock, "presets")
	if err != nil || errOut != "" {
		t.Fatalf("ley presets: err=%v stderr=%q", err, errOut)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != len(leyline.Presets())+1 {
		t.Fatalf("want a header and %d presets, got %d lines:\n%s", len(leyline.Presets()), len(lines), out)
	}
	if !strings.HasPrefix(lines[0], "NAME") || !strings.Contains(out, "noaa, wx1, weather") {
		t.Fatalf("preset table shape:\n%s", out)
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
	lines = strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != len(leyline.Bands())+1 || !strings.HasPrefix(lines[0], "NAME") {
		t.Fatalf("band table shape:\n%s", out)
	}

	out, errOut, err = run(t, context.Background(), sock, "--json", "bands")
	if err != nil || errOut != "" {
		t.Fatalf("ley bands --json: err=%v stderr=%q", err, errOut)
	}
	var bs []bandJSON
	if err := json.Unmarshal([]byte(out), &bs); err != nil {
		t.Fatalf("bands --json: %v\n%s", err, out)
	}
	if len(bs) != len(leyline.Bands()) {
		t.Fatalf("bands --json: %d rows, want %d", len(bs), len(leyline.Bands()))
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
