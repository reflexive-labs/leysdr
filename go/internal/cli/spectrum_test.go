package cli

import (
	"context"
	"encoding/json"
	"math"
	"strings"
	"testing"

	"github.com/dpup/leysdr/go/internal/fakedaemon"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// The fake daemon renders a -100 dB floor with a -40 dB peak at every channel
// offset, so a channel at the capture centre gives a known loudest bin.
func TestSpectrumRenderAndJSON(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	listening(t, c)

	out := mustRun(t, sock, "--json", "spectrum", "--bins", "256")
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 1 {
		t.Fatalf("want one row without --watch, got %d:\n%s", len(lines), out)
	}
	var row map[string]json.RawMessage
	if err := json.Unmarshal([]byte(lines[0]), &row); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"seq", "sample_index", "center_hz", "span_hz", "bins", "peaks"} {
		if _, ok := row[k]; !ok {
			t.Errorf("row lacks %q: %s", k, lines[0])
		}
	}
	var typed SpectrumRow
	if err := json.Unmarshal([]byte(lines[0]), &typed); err != nil {
		t.Fatal(err)
	}
	// The fake's row is a flat floor with one -40 dB peak: peaks lists only
	// bins clear of the floor, so exactly one, never padded with noise.
	if typed.CenterHz != 146_520_000 || len(typed.Bins) != 256 || len(typed.Peaks) != 1 {
		t.Fatalf("row: center %d bins %d peaks %d", typed.CenterHz, len(typed.Bins), len(typed.Peaks))
	}
	binWidth := float64(typed.SpanHz) / 256
	top := typed.Peaks[0]
	if top.Db != -40 || math.Abs(float64(top.CenterHz)-146_520_000) > binWidth {
		t.Fatalf("loudest bin should be the channel's -40 dB peak near the centre: %+v", top)
	}
	for i := 1; i < len(typed.Peaks); i++ {
		if typed.Peaks[i].Db > typed.Peaks[i-1].Db {
			t.Fatalf("peaks not loudest-first: %+v", typed.Peaks)
		}
	}

	text := mustRun(t, sock, "spectrum", "--bins", "256", "--width", "60")
	if !strings.HasPrefix(text, "146.520 MHz, span "+leyline.FormatFrequency(typed.SpanHz)+" (") || !strings.Contains(text, "256 bins of") || !strings.Contains(text, "floor -") {
		t.Fatalf("header:\n%s", text)
	}
	wantPeak := "loudest bins: " + leyline.FormatFrequency(top.CenterHz) + " -40 dB"
	if !strings.Contains(text, wantPeak) {
		t.Fatalf("want %q in:\n%s", wantPeak, text)
	}
	for _, banned := range []string{"signal", "SNR", "bandwidth"} {
		if strings.Contains(strings.ToLower(text), strings.ToLower(banned)) {
			t.Errorf("spectrum must not say %q:\n%s", banned, text)
		}
	}
	for _, l := range strings.Split(strings.TrimRight(text, "\n"), "\n") {
		if len(l) > 60 && !strings.HasPrefix(l, "loudest bins") && !strings.Contains(l, "span") {
			t.Errorf("line wider than --width 60: %q", l)
		}
	}
	if bars := strings.Count(text, "#"); bars == 0 {
		t.Fatalf("no bars drawn:\n%s", text)
	}
	if _, _, err := run(t, context.Background(), sock, "spectrum", "--bins", "256", "--width", "60"); err != nil {
		t.Fatalf("second run must not have torn down the daemon's capture: %v", err)
	}
	// A frequency outside the band while a channel listens: refused with the
	// fix, exit 1, and the capture stays where it was; --retune moves it.
	_, _, err := run(t, context.Background(), sock, "spectrum", "101.1", "--bins", "256")
	if exitCode(err) != 1 || !strings.Contains(err.Error(), "the radio is on 146.520 MHz with 1 channel listening") || !strings.Contains(err.Error(), "--retune") {
		t.Fatalf("shared capture: exit %d %v", exitCode(err), err)
	}
	st, _ := c.State(context.Background())
	if st.Captures[0].CenterHz != 146_520_000 {
		t.Fatalf("refusal moved the capture: %v", st.Captures[0])
	}
	out = mustRun(t, sock, "--json", "spectrum", "101.1", "--retune", "--bins", "256")
	if err := json.Unmarshal([]byte(strings.TrimSpace(out)), &typed); err != nil || typed.CenterHz != 101_100_000 {
		t.Fatalf("--retune row: %v %+v", err, typed)
	}
	st, _ = c.State(context.Background())
	if st.Captures[0].CenterHz != 101_100_000 || len(st.Channels) != 1 {
		t.Fatalf("--retune should move the shared capture and keep the channel: %v %v", st.Captures, st.Channels)
	}
	// A comma is rejected once, without a doubled "frequency:" prefix.
	_, _, err = run(t, context.Background(), sock, "spectrum", "101,1")
	if exitCode(err) != ExitUsage || !strings.Contains(err.Error(), "comma") || strings.Contains(err.Error(), "frequency: frequency:") {
		t.Fatalf("comma error: %v", err)
	}
}

func TestSpectrumWatchCountAndCapture(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	ctx := context.Background()
	// No capture and no frequency: a usage error that shows the fix.
	_, _, err := run(t, ctx, sock, "spectrum")
	if exitCode(err) != ExitUsage || !strings.Contains(err.Error(), "ley spectrum 101.1") {
		t.Fatalf("no capture: exit %d %v", exitCode(err), err)
	}
	// --watch --count appends rows when piped; the capture is created for the run and destroyed after.
	out := mustRun(t, sock, "--json", "spectrum", "101.1", "--watch", "--rate", "30", "--count", "3", "--bins", "256")
	if n := len(strings.Split(strings.TrimSpace(out), "\n")); n != 3 {
		t.Fatalf("want 3 rows, got %d:\n%s", n, out)
	}
	var row SpectrumRow
	if err := json.Unmarshal([]byte(strings.SplitN(out, "\n", 2)[0]), &row); err != nil || row.CenterHz != 101_100_000 {
		t.Fatalf("row: %v %+v", err, row)
	}
	st, err := c.State(ctx)
	if err != nil || len(st.Captures) != 0 {
		t.Fatalf("capture must be destroyed after the run: %v %v", err, st.GetCaptures())
	}
	text := mustRun(t, sock, "spectrum", "101.1", "--watch", "--count", "2", "--rate", "30", "--width", "50")
	if got := strings.Count(text, "loudest bins:"); got != 2 {
		t.Fatalf("piped --watch should append 2 charts, got %d:\n%s", got, text)
	}
	// No channel: the fake's row is floor only, and spectrum says so instead of listing noise.
	if !strings.Contains(text, "loudest bins: nothing above the floor") {
		t.Fatalf("a flat row should report nothing above the floor:\n%s", text)
	}
	if strings.Contains(text, "\x1b[") {
		t.Fatalf("piped output must not carry cursor moves:\n%s", text)
	}
	// On a terminal the redraw moves the cursor up instead of appending.
	tty, _, err := runApp(t, ttyApp(sock), "spectrum", "101.1", "--watch", "--count", "2", "--rate", "30")
	if err != nil || strings.Count(tty, "\x1b[") != 1 {
		t.Fatalf("tty redraw: %v\n%q", err, tty)
	}
	// Out of the device's range: says so, exit 2, no capture left behind.
	_, _, err = run(t, ctx, sock, "spectrum", "1.010")
	if exitCode(err) != ExitUsage || !strings.Contains(err.Error(), "range") {
		t.Fatalf("out of range: exit %d %v", exitCode(err), err)
	}
}
