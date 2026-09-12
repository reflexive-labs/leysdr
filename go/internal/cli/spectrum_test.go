// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"encoding/json"
	"math"
	"regexp"
	"strings"
	"testing"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/fakedaemon"
	"github.com/dpup/leysdr/go/internal/ui"
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
	for _, k := range []string{"seq", "sample_index", "center_hz", "span_hz", "bins", "floor_db", "peaks"} {
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
	if !strings.HasPrefix(text, "146.520 MHz  span "+leyline.FormatFrequency(typed.SpanHz)) || !strings.Contains(text, "256 bins of") || !strings.Contains(text, "floor -") {
		t.Fatalf("header:\n%s", text)
	}
	wantPeak := "peak    " + leyline.FormatFrequency(top.CenterHz) + "  -40 dBFS"
	if !strings.Contains(text, wantPeak) {
		t.Fatalf("want %q in:\n%s", wantPeak, text)
	}
	// The strongest peak's margin above the floor is the number the reader
	// came for, and the screen ends with the command that acts on it.
	if !strings.Contains(text, "dB above the floor") || !strings.Contains(text, "tune with: ley tune ") {
		t.Fatalf("peak block and next step:\n%s", text)
	}
	for _, banned := range []string{"signal", "SNR", "bandwidth"} {
		if strings.Contains(strings.ToLower(text), strings.ToLower(banned)) {
			t.Errorf("spectrum must not say %q:\n%s", banned, text)
		}
	}
	for _, l := range strings.Split(strings.TrimRight(text, "\n"), "\n") {
		if ui.Visible(l) > 60 {
			t.Errorf("line wider than --width 60: %q", l)
		}
	}
	if !strings.ContainsAny(text, ".:-=+*#%") {
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
	if got := strings.Count(text, "peak    "); got != 2 {
		t.Fatalf("piped --watch should append 2 charts, got %d:\n%s", got, text)
	}
	// No channel: the fake's row is floor only, and spectrum says so instead of listing noise.
	if !strings.Contains(text, "peak    nothing above the floor") {
		t.Fatalf("a flat row should report nothing above the floor:\n%s", text)
	}
	if strings.Contains(text, "\x1b[") {
		t.Fatalf("piped output must not carry cursor moves:\n%s", text)
	}
	// On a terminal the redraw moves the cursor up instead of appending, erases
	// each line it rewrites so a shorter frame cannot leave a tail behind, and
	// gives the cursor back at the end.
	tty, _, err := runApp(t, ttyApp(sock), "spectrum", "101.1", "--watch", "--count", "2", "--rate", "30")
	if err != nil {
		t.Fatalf("tty redraw: %v\n%q", err, tty)
	}
	if up := regexp.MustCompile(`\x1b\[\d+A`).FindAllString(tty, -1); len(up) != 1 {
		t.Fatalf("second frame should redraw in place, got %v:\n%q", up, tty)
	}
	if !strings.Contains(tty, ansiHideCursor) || !strings.HasSuffix(tty, ansiShowCursor) {
		t.Fatalf("the cursor must be hidden for the run and restored at the end:\n%q", tty)
	}
	if n := strings.Count(tty, ansiEraseLine); n < 2 {
		t.Fatalf("every redrawn line should erase to end of line, got %d:\n%q", n, tty)
	}
	// Out of the device's range: says so, exit 2, no capture left behind.
	_, _, err = run(t, ctx, sock, "spectrum", "1.010")
	if exitCode(err) != ExitUsage || !strings.Contains(err.Error(), "range") {
		t.Fatalf("out of range: exit %d %v", exitCode(err), err)
	}
}

// --span is the capture width: a fresh capture snaps it to the nearest rate
// the radio supports (with a note on stderr); an existing capture at a
// different width is refused with exit 2 rather than ignored.
func TestSpectrumSpan(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	ctx := context.Background()
	out, errOut, err := run(t, ctx, sock, "--json", "spectrum", "101.1", "--span", "200k", "--bins", "256")
	if err != nil {
		t.Fatalf("fresh capture with --span 200k: %v\n%s", err, errOut)
	}
	var row SpectrumRow
	if err := json.Unmarshal([]byte(strings.TrimSpace(out)), &row); err != nil || row.SpanHz != 250_000 {
		t.Fatalf("span should snap to 250 kHz: %v %+v", err, row)
	}
	if want := "showing 250.000 kHz, the closest this radio can do to 200.000 kHz"; !strings.Contains(errOut, want) {
		t.Fatalf("stderr should note the snap %q:\n%s", want, errOut)
	}
	// An exact rate: no note.
	_, errOut, err = run(t, ctx, sock, "--json", "spectrum", "101.1", "--span", "2.4M", "--bins", "256")
	if err != nil || strings.Contains(errOut, "closest") {
		t.Fatalf("exact span: %v\n%s", err, errOut)
	}
	// An existing capture keeps its width: a different span exits 2 and names the current width.
	st, err := c.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: st.Devices[0].DeviceId, CenterHz: 101_100_000, SampleRate: 2_400_000}); err != nil {
		t.Fatal(err)
	}
	_, _, err = run(t, ctx, sock, "spectrum", "--span", "250k")
	if exitCode(err) != ExitUsage || !strings.Contains(err.Error(), "2.400 MHz wide") || !strings.Contains(err.Error(), "ley stop all") {
		t.Fatalf("existing capture with a different span: exit %d %v", exitCode(err), err)
	}
	// The capture's own width (or one that snaps to it) is fine.
	out, errOut, err = run(t, ctx, sock, "--json", "spectrum", "--span", "2.3M", "--bins", "256")
	if err != nil {
		t.Fatalf("matching span: %v\n%s", err, errOut)
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(out)), &row); err != nil || row.SpanHz != 2_400_000 {
		t.Fatalf("row: %v %+v", err, row)
	}
	if !strings.Contains(errOut, "showing 2.400 MHz, the closest this radio can do to 2.300 MHz") {
		t.Fatalf("stderr should note the snap:\n%s", errOut)
	}
	if st, err := c.State(ctx); err != nil || len(st.Captures) != 1 {
		t.Fatalf("the shared capture must survive the run: %v %v", err, st.GetCaptures())
	}
}

// End to end, the frame and the ramp are a terminal's: a UTF-8 terminal wide
// enough gets the chart in a box with its levels coloured, and the same run
// piped is the bare lines a script already reads.
func TestSpectrumFrameOnATerminal(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	listening(t, c)
	app := ttyApp(sock)
	app.TermWidth = func() int { return 100 }
	app.LookupEnv = func(name string) (string, bool) {
		switch name {
		case "LANG":
			return "en_US.UTF-8", true
		case "TERM":
			return "xterm-256color", true
		}
		return "", false
	}
	tty, _, err := runApp(t, app, "spectrum", "--bins", "256")
	if err != nil {
		t.Fatalf("spectrum on a terminal: %v\n%s", err, tty)
	}
	if !strings.HasPrefix(tty, "╭") || !strings.Contains(tty, "╰") {
		t.Fatalf("a wide UTF-8 terminal should frame the chart:\n%s", tty)
	}
	if !strings.Contains(tty, "\x1b[") {
		t.Fatalf("the chart should be inked on a terminal:\n%s", tty)
	}
	// The peak list is under the frame, not in it.
	for _, l := range strings.Split(strings.TrimRight(tty, "\n"), "\n") {
		if strings.Contains(ui.Strip(l), "peak ") && strings.Contains(l, "│") {
			t.Errorf("the peak list belongs outside the frame: %q", l)
		}
	}
	// --ascii keeps the same screen without either alphabet's frame.
	plain, _, err := runApp(t, app, "--ascii", "spectrum", "--bins", "256")
	if err != nil {
		t.Fatalf("ascii spectrum: %v\n%s", err, plain)
	}
	if framed(plain) {
		t.Fatalf("--ascii draws no frame:\n%s", plain)
	}
	if piped := mustRun(t, sock, "spectrum", "--bins", "256", "--width", "100"); framed(piped) {
		t.Fatalf("piped output draws no frame:\n%s", piped)
	}
}

// framed reports whether a screen is boxed. A border is detected by its top-left
// corner, not by the corner glyph appearing anywhere: the ASCII alphabet draws
// its corner with '+', which is also the sixth step of the ASCII column ramp, so
// a chart with signal in it carries plenty of them.
func framed(screen string) bool {
	for _, l := range strings.Split(screen, "\n") {
		if t := strings.TrimLeft(ui.Strip(l), " "); strings.HasPrefix(t, "╭") || strings.HasPrefix(t, "+-") {
			return true
		}
	}
	return false
}

// A reused capture keeps its own centre, so the chart can be drawn around a
// frequency other than the one that was asked for. That is never a surprise:
// spectrum names the capture's centre on stderr and says what it covers.
func TestSpectrumSaysWhenTheCaptureIsOffCentre(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	ctx := context.Background()
	st, err := c.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: st.Devices[0].DeviceId, CenterHz: 146_520_000, SampleRate: 2_400_000}); err != nil {
		t.Fatal(err)
	}
	_, errOut, err := run(t, ctx, sock, "--json", "spectrum", "146", "--bins", "256")
	if err != nil {
		t.Fatalf("a covered frequency should draw the capture: %v\n%s", err, errOut)
	}
	if want := "showing the capture at 146.520 MHz, which covers 146.000 MHz"; !strings.Contains(errOut, want) {
		t.Fatalf("stderr should say %q:\n%s", want, errOut)
	}
	// The capture's own centre, and no frequency at all, say nothing.
	for _, args := range [][]string{
		{"--json", "spectrum", "146.52", "--bins", "256"},
		{"--json", "spectrum", "--bins", "256"},
	} {
		_, errOut, err := run(t, ctx, sock, args...)
		if err != nil {
			t.Fatalf("%v: %v\n%s", args, err, errOut)
		}
		if strings.Contains(errOut, "which covers") {
			t.Errorf("%v is centred where it was asked for and must say nothing:\n%s", args, errOut)
		}
	}
}
