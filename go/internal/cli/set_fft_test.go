package cli

import (
	"context"
	"encoding/json"
	"math"
	"strings"
	"testing"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/fakedaemon"
)

func TestSetParams(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	if _, _, err := run(t, context.Background(), sock, "set", "squelch", "-40"); err == nil || !strings.Contains(err.Error(), "no active channel") {
		t.Fatalf("expected no-channel error, got %v", err)
	}
	mustRun(t, sock, "tune", "146.52M", "--no-audio", "--persistent")
	state := func() *leylinev1.GetStateResponse {
		st, err := c.State(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		return st
	}
	out := mustRun(t, sock, "set", "squelch", "-40")
	if !strings.Contains(out, "squelch -40.0 dB") {
		t.Fatalf("squelch confirmation: %s", out)
	}
	if st := state(); st.Channels[0].SquelchDb != -40 {
		t.Fatalf("squelch not applied: %v", st.Channels[0].SquelchDb)
	}
	mustRun(t, sock, "set", "squelch", "off")
	if st := state(); !math.IsNaN(st.Channels[0].SquelchDb) {
		t.Fatalf("squelch off not applied: %v", st.Channels[0].SquelchDb)
	}
	out = mustRun(t, sock, "--json", "set", "gain", "20")
	var ev map[string]any
	if err := json.Unmarshal([]byte(out), &ev); err != nil || ev["capture"] == nil {
		t.Fatalf("gain confirmation event: %v %s", err, out)
	}
	if st := state(); len(st.Captures[0].Gains) == 0 || math.Abs(st.Captures[0].Gains[0].Db-20) > 1 || st.Captures[0].Gains[0].Auto {
		t.Fatalf("gain not applied: %v", st.Captures[0].Gains)
	}
	// The R820T table has gaps > 1 dB (3.7 -> 7.7, 44.5 -> 48.0): the request
	// is snapped client-side so the confirmation matches what the daemon applied.
	out = mustRun(t, sock, "set", "gain", "6")
	if st := state(); st.Captures[0].Gains[0].Db != 7.7 {
		t.Fatalf("gain 6 not snapped to 7.7: %v", st.Captures[0].Gains)
	}
	if !strings.Contains(out, "gain TUNER 7.7 dB") {
		t.Fatalf("confirmation should show the snapped gain: %s", out)
	}
	mustRun(t, sock, "set", "gain", "46")
	if st := state(); st.Captures[0].Gains[0].Db != 44.5 {
		t.Fatalf("gain 46 not snapped to 44.5: %v", st.Captures[0].Gains)
	}
	mustRun(t, sock, "set", "gain", "auto")
	if st := state(); !st.Captures[0].Gains[0].Auto {
		t.Fatalf("gain auto not applied: %v", st.Captures[0].Gains)
	}
	// freq inside the span moves the offset.
	out = mustRun(t, sock, "set", "freq", "146.6M")
	if st := state(); st.Channels[0].OffsetHz != 80_000 || st.Captures[0].CenterHz != 146_520_000 {
		t.Fatalf("freq offset: %v / %s", st.Channels[0], out)
	}
	// freq outside the span retunes the capture and zeroes the offset.
	out = mustRun(t, sock, "set", "freq", "155M")
	if !strings.Contains(out, "retuning capture") {
		t.Fatalf("expected retune notice: %s", out)
	}
	if st := state(); st.Channels[0].OffsetHz != 0 || st.Captures[0].CenterHz != 155_000_000 {
		t.Fatalf("freq retune: %v %v", st.Channels[0], st.Captures[0])
	}
	mustRun(t, sock, "set", "mode", "am")
	mustRun(t, sock, "set", "bw", "8k")
	if st := state(); st.Channels[0].Mode != leylinev1.DemodMode_AM || st.Channels[0].BandwidthHz != 8000 {
		t.Fatalf("mode/bw: %v", st.Channels[0])
	}
	// A rejection is reported with its code.
	_, _, err := run(t, context.Background(), sock, "set", "gain", "20", "--element", "nope")
	if err == nil || !strings.Contains(err.Error(), "rejected") {
		t.Fatalf("expected rejection, got %v", err)
	}
	if _, _, err := run(t, context.Background(), sock, "set", "volume", "0.5"); err == nil || !strings.Contains(err.Error(), "SINK_NOT_FOUND") {
		t.Fatalf("expected sink error, got %v", err)
	}
	mustRun(t, sock, "tune", "155.1M", "--no-audio", "--persistent")
	if _, _, err := run(t, context.Background(), sock, "set", "squelch", "-40"); err == nil || !strings.Contains(err.Error(), "2 active channels") {
		t.Fatalf("expected ambiguity error, got %v", err)
	}
}

func TestFFTJSONAndBin(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	if _, _, err := run(t, context.Background(), sock, "fft", "--count", "1"); err == nil || !strings.Contains(err.Error(), "--freq") {
		t.Fatalf("expected --freq requirement, got %v", err)
	}
	out := mustRun(t, sock, "fft", "--count", "2", "--bins", "256", "--rate", "30", "--freq", "100M")
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 2 {
		t.Fatalf("want 2 rows, got %d:\n%s", len(lines), out)
	}
	for _, l := range lines {
		var row FFTRow
		if err := json.Unmarshal([]byte(l), &row); err != nil {
			t.Fatalf("row %q: %v", l, err)
		}
		if row.CenterHz != 100_000_000 || row.SpanHz == 0 || len(row.Bins) != 256 {
			t.Fatalf("row shape: center %d span %d bins %d", row.CenterHz, row.SpanHz, len(row.Bins))
		}
	}
	if st, _ := c.State(context.Background()); len(st.Captures) != 0 {
		t.Fatalf("temporary capture not destroyed")
	}
	out = mustRun(t, sock, "fft", "--count", "2", "--bins", "256", "--rate", "30", "--freq", "100M", "--format", "bin", "--u8")
	b := []byte(out)
	for i := 0; i < 2; i++ {
		bins, seq, err := ParseFFTRecord(b)
		if err != nil || bins != 256 {
			t.Fatalf("record %d: bins %d seq %d err %v", i, bins, seq, err)
		}
		if len(b) < 16+int(bins) {
			t.Fatalf("record %d truncated: %d bytes", i, len(b))
		}
		b = b[16+int(bins):]
	}
	if len(b) != 0 {
		t.Fatalf("%d trailing bytes", len(b))
	}
}

func TestSnapGain(t *testing.T) {
	table := &leylinev1.GainElement{ValidDb: []float64{0, 3.7, 7.7, 44.5, 48.0}}
	for _, tc := range []struct{ in, want float64 }{{6, 7.7}, {46, 44.5}, {-3, 0}, {99, 48.0}, {3.7, 3.7}} {
		if got, tol := snapGain(table, tc.in); got != tc.want || tol != 0.05 {
			t.Errorf("table snap %v: got %v tol %v, want %v", tc.in, got, tol, tc.want)
		}
	}
	grid := &leylinev1.GainElement{MinDb: -10, MaxDb: 20, StepDb: 0.5}
	for _, tc := range []struct{ in, want float64 }{{6.2, 6}, {6.3, 6.5}, {-30, -10}, {25, 20}} {
		if got, tol := snapGain(grid, tc.in); got != tc.want || tol != 0.3 {
			t.Errorf("grid snap %v: got %v tol %v, want %v", tc.in, got, tol, tc.want)
		}
	}
	if got, tol := snapGain(&leylinev1.GainElement{}, 6.2); got != 6.2 || tol != 1.0 {
		t.Errorf("passthrough: got %v tol %v", got, tol)
	}
}
