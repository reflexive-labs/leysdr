package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"math"
	"strings"
	"sync"
	"testing"
	"time"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/fakedaemon"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

func TestTunePersistent(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	out, errOut, err := run(t, context.Background(), sock, "tune", "146.52M", "--no-audio", "--persistent")
	if err != nil {
		t.Fatalf("persistent tune: %v", err)
	}
	if !strings.Contains(out, "capture cap_") || !strings.Contains(out, "channel chan_") || strings.Contains(out, "sink") {
		t.Fatalf("persistent output:\n%s", out)
	}
	// The measured threshold is a decision, so it goes to stderr and leaves
	// stdout the ids a script reads.
	if !strings.Contains(errOut, "Squelch auto → -80 dBFS") {
		t.Fatalf("persistent tune should say what squelch it measured:\n%s", errOut)
	}
	st, err := c.State(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Captures) != 1 || len(st.Channels) != 1 || !st.Channels[0].Persistent {
		t.Fatalf("state after persistent tune: %v", st)
	}
	if st.Captures[0].CenterHz != 146_520_000 || st.Channels[0].OffsetHz != 0 || leyline.ModeName(st.Channels[0].Mode) != "nfm" {
		t.Fatalf("channel: %v", st.Channels[0])
	}
	// A voice channel squelches by default however the run is spelled: a
	// persistent NFM channel left open would play band noise until somebody
	// noticed.
	if got := st.Channels[0].SquelchDb; math.IsNaN(got) || math.Abs(got-(-80)) > 1.5 {
		t.Fatalf("persistent tune should measure squelch: %v", got)
	}
	// A second persistent tune inside the span reuses the capture with an offset.
	out = mustRun(t, sock, "--json", "tune", "146.6M", "--no-audio", "--persistent", "--mode", "am", "--squelch", "-50")
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 2 {
		t.Fatalf("json persistent lines: %s", out)
	}
	var ch map[string]any
	if err := json.Unmarshal([]byte(lines[1]), &ch); err != nil || ch["offsetHz"] != "80000" || ch["mode"] != "AM" {
		t.Fatalf("json channel: %v %s", err, lines[1])
	}
	st, _ = c.State(context.Background())
	if len(st.Captures) != 1 || len(st.Channels) != 2 {
		t.Fatalf("expected capture reuse: %d captures %d channels", len(st.Captures), len(st.Channels))
	}
	// Out of span with two channels listening: refused with the centre, the
	// count and the fix, exit 1; nothing moved. A bare number is MHz.
	_, _, err = run(t, context.Background(), sock, "tune", "150", "--no-audio", "--persistent")
	if exitCode(err) != 1 {
		t.Fatalf("shared capture retune: exit %d %v", exitCode(err), err)
	}
	for _, want := range []string{"the radio is on 146.520 MHz with 2 channels listening", "retuning to 150.000 MHz would silence them", "Add --retune", "ley stop --all"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("refusal lacks %q: %v", want, err)
		}
	}
	st, _ = c.State(context.Background())
	if st.Captures[0].CenterHz != 146_520_000 || len(st.Channels) != 2 {
		t.Fatalf("refusal must not touch the capture: %v", st.Captures[0])
	}
	// --retune moves it anyway and says so.
	out = mustSay(t, sock, "tune", "150", "--no-audio", "--persistent", "--retune")
	if !strings.Contains(out, "retuning capture") {
		t.Fatalf("expected retune notice:\n%s", out)
	}
	st, _ = c.State(context.Background())
	if st.Captures[0].CenterHz != 150_000_000 {
		t.Fatalf("capture not retuned: %d", st.Captures[0].CenterHz)
	}
}

// With nothing else listening, an out-of-span tune retunes the capture as
// before and reports it.
func TestTuneRetunesIdleCapture(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	st, _ := c.State(context.Background())
	if _, err := c.Control.CreateCapture(context.Background(), &leylinev1.CreateCaptureRequest{DeviceId: st.Devices[0].DeviceId, CenterHz: 101_100_000}); err != nil {
		t.Fatal(err)
	}
	out := mustSay(t, sock, "tune", "146.52", "--no-audio", "--persistent")
	if !strings.Contains(out, "retuning capture") || !strings.Contains(out, "101.100 MHz to 146.520 MHz") {
		t.Fatalf("expected retune notice:\n%s", out)
	}
	st, _ = c.State(context.Background())
	if st.Captures[0].CenterHz != 146_520_000 {
		t.Fatalf("capture not retuned: %d", st.Captures[0].CenterHz)
	}
}

// --gain is applied to the capture after it exists and shown in the banner.
func TestTuneGain(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	mustRun(t, sock, "tune", "146.52", "--no-audio", "--persistent", "--gain", "30")
	st, _ := c.State(context.Background())
	if g := st.Captures[0].Gains[0]; g.Auto || math.Abs(g.Db-29.7) > 0.01 {
		t.Fatalf("gain 30 should snap to 29.7 dB: %v", g)
	}
	mustRun(t, sock, "tune", "146.52", "--no-audio", "--persistent", "--gain", "auto")
	st, _ = c.State(context.Background())
	if !st.Captures[0].Gains[0].Auto {
		t.Fatalf("gain auto not applied: %v", st.Captures[0].Gains[0])
	}
	if _, _, err := run(t, context.Background(), sock, "tune", "146.52", "--no-audio", "--persistent", "--gain", "loud"); err == nil || !strings.Contains(err.Error(), "--gain") {
		t.Fatalf("bad --gain error: %v", err)
	}
	if _, _, err := run(t, context.Background(), sock, "tune", "146.52", "--no-audio", "--persistent", "--gain", "80"); err == nil || !strings.Contains(err.Error(), "49.6") {
		t.Fatalf("out-of-range --gain should name the range: %v", err)
	}
}

// syncBuffer is a bytes.Buffer safe to read while the verb writes to it.
type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

// liveTune runs tune in the background until want appears on either stream
// (the meter line, usually, which is stderr's) or the deadline passes, then
// cancels and returns the captured stdout/stderr.
func liveTune(t *testing.T, sock string, want string, args ...string) (string, string) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	var out, errOut syncBuffer
	app := &App{Stdout: &out, Stderr: &errOut, LookupEnv: func(string) (string, bool) { return "", false }}
	go func() { done <- Execute(ctx, app, append([]string{"--socket", sock}, args...)) }()
	deadline := time.Now().Add(5 * time.Second)
	for !strings.Contains(out.String()+errOut.String(), want) {
		select {
		case err := <-done:
			t.Fatalf("tune exited before printing %q: %v\n%s\n%s", want, err, out.String(), errOut.String())
		case <-time.After(10 * time.Millisecond):
		}
		if time.Now().After(deadline) {
			cancel()
			t.Fatalf("tune never printed %q:\n%s\n%s", want, out.String(), errOut.String())
		}
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("tune returned error on cancel: %v\n%s\n%s", err, out.String(), errOut.String())
		}
	case <-time.After(5 * time.Second):
		t.Fatal("tune did not exit after cancel")
	}
	return out.String(), errOut.String()
}

func TestTuneLifecycle(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{MeterInterval: 20 * time.Millisecond})
	stdout, errOut := liveTune(t, sock, " dBFS  ", "tune", "146.52", "--no-audio", "--squelch", "-40")
	// The banner is stdout's and the meter is stderr's (docs/cli-style.md 3):
	// what a person sees is the two together.
	out := stdout + errOut
	if strings.Contains(stdout, "signal ") {
		t.Fatalf("the meter belongs on stderr, not in a script's stdout:\n%s", stdout)
	}
	for _, want := range []string{"Listening to 146.520 MHz (NFM, 2 m amateur)", "gain auto", "Squelch -40 dBFS.", "Ctrl-C stops", "From another terminal: ley set squelch -50", "146.520 MHz NFM  signal ", " dBFS  "} {
		if !strings.Contains(out, want) {
			t.Fatalf("live output lacks %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "OPEN") || strings.Contains(out, "CLOSED") {
		t.Fatalf("OPEN/CLOSED belong to --json only:\n%s", out)
	}
	// The band default was not needed (explicit squelch, inferred mode is still announced once).
	if strings.Count(out, "using NFM: 2 m amateur band default") != 1 {
		t.Fatalf("expected one rationale line:\n%s", out)
	}
	st, err := c.State(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Channels) != 0 || len(st.Captures) != 0 {
		t.Fatalf("expected teardown, got %d channels %d captures", len(st.Channels), len(st.Captures))
	}
}

func TestTuneJSONMeter(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{MeterInterval: 20 * time.Millisecond})
	// Wait for the first meter line, then cancel: a fixed deadline can fire during setup on a
	// loaded machine and turn the run into DEADLINE_EXCEEDED.
	out, errOut := liveTune(t, sock, `"meter"`, "--json", "tune", "146.52M", "--no-audio")
	var sawMeter bool
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		var m map[string]any
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			t.Fatalf("bad NDJSON line %q: %v", line, err)
		}
		if m["meter"] != nil {
			sawMeter = true
		}
	}
	if !sawMeter {
		t.Fatalf("no meter JSON:\n%s", out)
	}
	// Prose goes to stderr under --json.
	if !strings.Contains(errOut, "Listening to 146.520 MHz") || !strings.Contains(errOut, "using NFM") {
		t.Fatalf("banner should be on stderr under --json:\n%s", errOut)
	}
}

// The fake's spectrum is a -100 dB floor (±3 dB) so the auto threshold is
// deterministic: -100 + 10·log10(12.5 kHz / (2.4 MHz / 2048)) + 10 ≈ -80.
func TestTuneAutoSquelch(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{MeterInterval: 20 * time.Millisecond})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	var out string
	go func() {
		// The banner is prose and lives on stderr; the assertion below is about
		// what a person saw, so it reads both streams.
		o, e, err := run(t, ctx, sock, "tune", "146.52", "--no-audio")
		out = o + e
		done <- err
	}()
	deadline := time.Now().Add(5 * time.Second)
	for {
		st, err := c.State(context.Background())
		if err == nil && len(st.Channels) == 1 && !math.IsNaN(st.Channels[0].SquelchDb) {
			if got := st.Channels[0].SquelchDb; math.Abs(got-(-80)) > 1.5 {
				t.Fatalf("auto squelch: got %v, want about -80", got)
			}
			break
		}
		if time.Now().After(deadline) {
			cancel()
			t.Fatalf("auto squelch never applied")
		}
		time.Sleep(10 * time.Millisecond)
	}
	time.Sleep(100 * time.Millisecond)
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("tune: %v\n%s", err, out)
	}
	if !strings.Contains(out, "Squelch auto → -80 dBFS (10 dB above the band's noise floor") {
		t.Fatalf("banner should report the measured squelch:\n%s", out)
	}
}

func TestTuneModePrecedence(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	cases := []struct {
		args       []string
		mode, said string
	}{
		{[]string{"tune", "101.1", "--mode", "fm"}, "wfm", "using WFM: fm on the FM broadcast band means WFM"},
		{[]string{"tune", "146.52", "--mode", "fm"}, "nfm", "using NFM: fm outside the FM broadcast band means NFM"},
		{[]string{"tune", "101.1"}, "wfm", "using WFM: FM broadcast band default"},
		{[]string{"tune", "500"}, "nfm", "using NFM: no band recognised, using NFM"},
		{[]string{"tune", "121.5"}, "am", "using AM: airband band default"},
		{[]string{"tune", "146.52", "--mode", "am"}, "am", ""},
		{[]string{"tune", "guard"}, "am", "using AM: preset guard: aviation emergency guard frequency (121.500 MHz)"},
	}
	for _, tc := range cases {
		out := mustSay(t, sock, append(tc.args, "--no-audio", "--persistent", "--retune")...)
		st, _ := c.State(context.Background())
		ch := st.Channels[len(st.Channels)-1]
		if leyline.ModeName(ch.Mode) != tc.mode {
			t.Errorf("%v: mode %s, want %s", tc.args, leyline.ModeName(ch.Mode), tc.mode)
		}
		if tc.said == "" && strings.Contains(out, "using ") {
			t.Errorf("%v: explicit mode should print no rationale:\n%s", tc.args, out)
		}
		if tc.said != "" && !strings.Contains(out, tc.said) {
			t.Errorf("%v: want %q in:\n%s", tc.args, tc.said, out)
		}
	}
	st, _ := c.State(context.Background())
	// FM broadcast default bandwidth follows the band table; --bw is parsed
	// with ParseBandwidth (bare numbers are kHz).
	if st.Channels[2].BandwidthHz != 200_000 {
		t.Errorf("wfm bandwidth: %d", st.Channels[2].BandwidthHz)
	}
	mustRun(t, sock, "tune", "146.52", "--no-audio", "--persistent", "--retune", "--bw", "25", "--volume", "50%")
	st, _ = c.State(context.Background())
	if st.Channels[len(st.Channels)-1].BandwidthHz != 25_000 {
		t.Errorf("--bw 25 should be 25 kHz: %d", st.Channels[len(st.Channels)-1].BandwidthHz)
	}
	if _, _, err := run(t, context.Background(), sock, "tune", "146.52", "--bw", "wide"); err == nil || !strings.Contains(err.Error(), "--bw") || !strings.Contains(err.Error(), "12.5k") {
		t.Errorf("bad --bw error: %v", err)
	}
	if _, _, err := run(t, context.Background(), sock, "tune", "146.52", "--volume", "loud"); err == nil || !strings.Contains(err.Error(), "--volume") {
		t.Errorf("bad --volume error: %v", err)
	}
}

func TestTunePresetsAndErrors(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	out := mustRun(t, sock, "tune", "NOAA", "--no-audio", "--persistent")
	st, err := c.State(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if st.Captures[0].CenterHz != 162_550_000 || leyline.ModeName(st.Channels[0].Mode) != "nfm" {
		t.Fatalf("preset noaa: %v %v\n%s", st.Captures[0], st.Channels[0], out)
	}
	// Unknown preset: the nearest names, and the frequency alternative.
	_, _, err = run(t, context.Background(), sock, "tune", "nooa", "--no-audio")
	if err == nil || !strings.Contains(err.Error(), "noaa") || !strings.Contains(err.Error(), "146.52") {
		t.Fatalf("unknown preset error: %v", err)
	}
	if _, _, err := run(t, context.Background(), sock, "tune", "--no-audio"); err == nil || !strings.Contains(err.Error(), "ley tune 146.52") {
		t.Fatalf("missing positional error: %v", err)
	}
	// Commas are rejected with a hint rather than misread.
	if _, _, err := run(t, context.Background(), sock, "tune", "146,520"); err == nil || !strings.Contains(err.Error(), "comma") {
		t.Fatalf("comma error: %v", err)
	}
	// Out of range: the device range, plus the kHz re-read hint when that lands in a band.
	out, errOut, err := run(t, context.Background(), sock, "tune", "1800", "--no-audio", "--persistent")
	if err == nil || leyline.Code(err) != leyline.CodeFreqOutOfRange {
		t.Fatalf("expected FREQ_OUT_OF_RANGE, got %v", err)
	}
	// The error is the whole story: no decision lines or warnings before it.
	if strings.Contains(out, "using ") || strings.Contains(errOut, "not a band I know") {
		t.Errorf("decisions printed before the range check failed:\n%s\n%s", out, errOut)
	}
	for _, want := range []string{"1.800 GHz", "Generic RTL2832U (R820T)", "24.000 MHz", "1.766 GHz", "did you mean 1.800 MHz (160 m amateur)? write 1800k"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("out-of-range error lacks %q: %v", want, err)
		}
	}
	// In range but in no band, while the same digits as kHz are: warn and continue.
	out, errOut, err = run(t, context.Background(), sock, "tune", "1010", "--no-audio", "--persistent", "--retune")
	if err != nil || !strings.Contains(out, "channel chan_") {
		t.Fatalf("tune 1010: %v\n%s", err, out)
	}
	if !strings.Contains(errOut, "1010 MHz is not a band I know; for 1010 kHz AM broadcast type 1010k") {
		t.Errorf("expected the kHz warning on stderr:\n%s", errOut)
	}
	if _, errOut, _ = run(t, context.Background(), sock, "tune", "1800", "--no-audio", "--persistent", "--retune"); strings.Contains(errOut, "not a band I know") {
		t.Errorf("out of range keeps the hint, not the warning:\n%s", errOut)
	}
	_, _, err = run(t, context.Background(), sock, "tune", "5", "--no-audio", "--persistent")
	if err == nil || !strings.Contains(err.Error(), "cannot tune below 24.000 MHz") || !strings.Contains(err.Error(), "upconverter") {
		t.Errorf("HF error should give the honest reason: %v", err)
	}
	// Device selectors: row number and prefix.
	mustRun(t, sock, "tune", "146.52", "--no-audio", "--persistent", "--retune", "--device", "1")
	mustRun(t, sock, "tune", "146.52", "--no-audio", "--persistent", "--device", st.Devices[0].DeviceId[:8])
	if _, _, err := run(t, context.Background(), sock, "tune", "146.52", "--no-audio", "--device", "9"); err == nil || !strings.Contains(err.Error(), "device") {
		t.Errorf("bad device selector: %v", err)
	}
}

func TestTuneNoDevice(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{NoDevice: true})
	_, _, err := run(t, context.Background(), sock, "tune", "146.52", "--no-audio")
	if err == nil {
		t.Fatal("expected an error with no device")
	}
	for _, want := range []string{"no radio found", "plugged in", "rtl_test", "ley daemon logs"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("no-device checklist lacks %q: %v", want, err)
		}
	}
}

func TestMeterLine(t *testing.T) {
	m := &leylinev1.Meter{PowerDbfs: -42.4, SquelchOpen: false}
	if got := meterLine(146_620_000, leylinev1.DemodMode_NFM, m); got != "146.620 MHz NFM  signal -42 dBFS  muted, waiting for a signal" {
		t.Errorf("closed: %q", got)
	}
	m.SquelchOpen = true
	if got := meterLine(146_620_000, leylinev1.DemodMode_NFM, m); got != "146.620 MHz NFM  signal -42 dBFS  audio" {
		t.Errorf("open: %q", got)
	}
}

// Output format is not a DSP decision: a voice channel squelches whether the
// run prints prose or NDJSON, and the threshold it measured is announced on
// stderr like every other decision.
func TestTuneJSONMeasuresSquelch(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out, errOut, err := run(t, context.Background(), sock, "--json", "tune", "146.52M", "--no-audio", "--persistent")
	if err != nil {
		t.Fatalf("json tune: %v (stderr: %s)", err, errOut)
	}
	if !strings.Contains(errOut, "Squelch auto → -80 dBFS") {
		t.Errorf("the measurement belongs on stderr:\n%s", errOut)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 2 {
		t.Fatalf("json lines: %s", out)
	}
	var ch map[string]any
	if err := json.Unmarshal([]byte(lines[1]), &ch); err != nil {
		t.Fatalf("json channel: %v %s", err, lines[1])
	}
	db, ok := ch["squelchDb"].(float64)
	if !ok || math.Abs(db-(-80)) > 1.5 {
		t.Errorf("squelchDb %v, want about -80", ch["squelchDb"])
	}
}

// The CTCSS line, end to end: an NFM channel on a carrier that sends a tone gets sub-audible
// telemetry from the daemon, and tune prints the tone once rather than on every heartbeat.
func TestTuneShowsTheTone(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{MeterInterval: 20 * time.Millisecond})
	stdout, errOut := liveTune(t, sock, "PL", "tune", "145.23", "--no-audio", "--squelch", "-45")
	out := stdout + errOut
	if !strings.Contains(out, "100.0 Hz") {
		t.Fatalf("expected the classified tone:\n%s", out)
	}
	if !strings.Contains(out, "dev ") || !strings.Contains(out, "tone/band ") {
		t.Errorf("the tone line should carry what was measured:\n%s", out)
	}
	if n := strings.Count(out, "PL"); n != 1 {
		t.Errorf("the tone is news once, not on every heartbeat: %d lines\n%s", n, out)
	}
}

// And a frequency that carries no tone says nothing: a channel that never had one must not
// narrate its absence.
func TestTuneSaysNothingWithoutATone(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{MeterInterval: 20 * time.Millisecond})
	// The detector still reports, so this waits for its answer rather than for a silence that
	// would also pass if nothing were looking: what it says is "looked, found nothing".
	stdout, errOut := liveTune(t, sock, `"subAudible"`, "--json", "tune", "146.52", "--no-audio", "--squelch", "-45")
	if !strings.Contains(stdout, "SUB_AUDIBLE_NONE") || strings.Contains(stdout, "SUB_AUDIBLE_CTCSS") {
		t.Fatalf("expected a NONE report on a frequency with no tone:\n%s", stdout)
	}
	if strings.Contains(errOut, "PL") {
		t.Errorf("no tone on this frequency, so no line:\n%s", errOut)
	}
}

// Whether a channel is listening for a tone is part of its state, not a client-side guess: NFM is
// the only mode CTCSS is sent under, so that is the mode the daemon turns the detector on for.
func TestChannelSaysWhetherItListensForATone(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	mustRun(t, sock, "tune", "146.52", "--no-audio", "--persistent")
	mustRun(t, sock, "tune", "146.6", "--no-audio", "--persistent", "--mode", "am")
	var st struct {
		Channels []struct {
			Mode             string `json:"mode"`
			SubaudibleDetect bool   `json:"subaudibleDetect"`
		} `json:"channels"`
	}
	out := mustRun(t, sock, "--json", "state")
	if err := json.Unmarshal([]byte(out), &st); err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	if len(st.Channels) != 2 {
		t.Fatalf("want two channels: %s", out)
	}
	for _, ch := range st.Channels {
		if want := ch.Mode == "NFM"; ch.SubaudibleDetect != want {
			t.Errorf("%s channel: subaudible_detect %v, want %v", ch.Mode, ch.SubaudibleDetect, want)
		}
	}
}
