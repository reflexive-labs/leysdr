package cli

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"strings"
	"testing"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/fakedaemon"
	"github.com/dpup/leysdr/go/internal/testutil"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

func TestSetParams(t *testing.T) {
	// WriteAwaitsWatcher: the fake holds each write until this session's
	// WatchEvents stream is registered, so the WriteRejected asserted below
	// cannot be emitted before the CLI is listening.
	sock, c := harness(t, fakedaemon.Options{WriteAwaitsWatcher: true})
	if _, _, err := run(t, context.Background(), sock, "set", "squelch", "-40"); err == nil || !strings.Contains(err.Error(), "nothing is playing; start with: ley tune 146.52") {
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
	if !strings.Contains(out, "squelch off (audio always on) → -40 dBFS on 146.520 MHz NFM (channel 1)") || strings.Contains(out, "cli:") {
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
	if !strings.Contains(out, "→ 7.7 dB on the radio (TUNER)") {
		t.Fatalf("confirmation should show the snapped gain: %s", out)
	}
	mustRun(t, sock, "set", "gain", "46")
	if st := state(); st.Captures[0].Gains[0].Db != 44.5 {
		t.Fatalf("gain 46 not snapped to 44.5: %v", st.Captures[0].Gains)
	}
	if out = mustRun(t, sock, "set", "gain", "auto"); !strings.Contains(out, "→ auto on the radio (TUNER)") {
		t.Fatalf("gain auto confirmation: %s", out)
	}
	if st := state(); !st.Captures[0].Gains[0].Auto {
		t.Fatalf("gain auto not applied: %v", st.Captures[0].Gains)
	}
	// freq inside the span moves the offset.
	out = mustRun(t, sock, "set", "frequency", "146.6M") // alias of freq
	if st := state(); st.Channels[0].OffsetHz != 80_000 || st.Captures[0].CenterHz != 146_520_000 {
		t.Fatalf("freq offset: %v / %s", st.Channels[0], out)
	}
	if !strings.Contains(out, "frequency 146.520 MHz → 146.600 MHz on channel 1 (NFM)") {
		t.Fatalf("freq confirmation: %s", out)
	}
	// freq outside the span retunes the capture and zeroes the offset.
	out = mustRun(t, sock, "set", "freq", "155M")
	if !strings.Contains(out, "retuning capture") {
		t.Fatalf("expected retune notice: %s", out)
	}
	if st := state(); st.Channels[0].OffsetHz != 0 || st.Captures[0].CenterHz != 155_000_000 {
		t.Fatalf("freq retune: %v %v", st.Channels[0], st.Captures[0])
	}
	if out = mustRun(t, sock, "set", "mode", "am"); !strings.Contains(out, "mode NFM → AM on 155.000 MHz (channel 1)") {
		t.Fatalf("mode confirmation: %s", out)
	}
	if out = mustRun(t, sock, "set", "filter", "8k"); !strings.Contains(out, "→ 8.000 kHz on 155.000 MHz AM (channel 1)") { // filter is an alias of bw
		t.Fatalf("bw confirmation: %s", out)
	}
	if st := state(); st.Channels[0].Mode != leylinev1.DemodMode_AM || st.Channels[0].BandwidthHz != 8000 {
		t.Fatalf("mode/bw: %v", st.Channels[0])
	}
	// A rejection is reported with its code.
	_, _, err := run(t, context.Background(), sock, "set", "gain", "20", "--element", "nope")
	if err == nil || !strings.Contains(err.Error(), "rejected") || exitCode(err) != 1 {
		t.Fatalf("expected rejection, got %v", err)
	}
	// Under --json the WriteRejected event is the report: on stdout, exit 1, no prose.
	out, errOut, err := run(t, context.Background(), sock, "--json", "set", "gain", "20", "--element", "nope")
	var ee *ExitError
	if !errors.As(err, &ee) || ee.Code != 1 || ee.Message != "" || errOut != "" {
		t.Fatalf("set --json rejection: %v stderr=%q", err, errOut)
	}
	ev = map[string]any{}
	if err := json.Unmarshal([]byte(out), &ev); err != nil || ev["writeRejected"] == nil {
		t.Fatalf("set --json rejection stdout: %v %s", err, out)
	}
	if rej := ev["writeRejected"].(map[string]any); rej["error"].(map[string]any)["code"] != leyline.CodeGainElementUnknown {
		t.Fatalf("set --json rejection code: %s", out)
	}
	if _, _, err := run(t, context.Background(), sock, "set", "volume", "0.5"); err == nil || leyline.Code(err) != leyline.CodeSinkNotFound || !strings.Contains(err.Error(), "not playing through the speakers") {
		t.Fatalf("expected sink error, got %v", err)
	}
	// Two channels made by ley: a numbered list with the example.
	mustRun(t, sock, "tune", "155.1M", "--no-audio", "--persistent")
	_, _, err = run(t, context.Background(), sock, "set", "squelch", "-40")
	if err == nil || !strings.Contains(err.Error(), "2 channels are playing") || !strings.Contains(err.Error(), "  2  155.100 MHz NFM") || !strings.Contains(err.Error(), "ley set squelch -40 --channel 2") {
		t.Fatalf("expected ambiguity list, got %v", err)
	}
	// Selectors: row number, frequency, id prefix.
	mustRun(t, sock, "set", "squelch", "-41", "--channel", "1")
	mustRun(t, sock, "set", "squelch", "-42", "--channel", "155.1")
	st := state()
	if st.Channels[1].SquelchDb != -42 || st.Channels[0].SquelchDb != -41 {
		t.Fatalf("selector writes: %v", st.Channels)
	}
	id := st.Channels[0].ChannelId
	mustRun(t, sock, "set", "squelch", "-43", "--channel", id[:len(id)-2])
	if st := state(); st.Channels[0].SquelchDb != -43 {
		t.Fatalf("prefix selector: %v", st.Channels)
	}
	if _, _, err := run(t, context.Background(), sock, "set", "squelch", "-40", "--channel", "9"); err == nil || !strings.Contains(err.Error(), "--channel") {
		t.Fatalf("bad selector: %v", err)
	}
	// A frequency that matches no channel lists rows a person can pick from.
	_, _, err = run(t, context.Background(), sock, "set", "squelch", "-40", "--channel", "162.55")
	if err == nil || !strings.Contains(err.Error(), "pick one:\n  1  chan_") || !strings.Contains(err.Error(), "  2  chan_") || !strings.Contains(err.Error(), "  155.100 MHz NFM") {
		t.Fatalf("no-match rows: %v", err)
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

func TestSetNoArgsAndTargetRule(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	// Nothing playing: the same next-step error as a write.
	if _, _, err := run(t, context.Background(), sock, "set"); err == nil || !strings.Contains(err.Error(), "ley tune 146.52") {
		t.Fatalf("set with nothing playing: %v", err)
	}
	mustRun(t, sock, "tune", "146.52", "--persistent", "--squelch", "-45", "--volume", "50%")
	out := mustRun(t, sock, "set")
	for _, want := range []string{"channel chan_", "on Generic RTL2832U (R820T)", "frequency  146.520 MHz (2 m amateur)", "mode       NFM", "bandwidth  12.500 kHz", "squelch    -45 dBFS", "gain       auto", "volume     50%", "change one with: ley set squelch -50"} {
		if !strings.Contains(out, want) {
			t.Errorf("set view lacks %q:\n%s", want, out)
		}
	}
	out = mustRun(t, sock, "--json", "set")
	var ch map[string]any
	if err := json.Unmarshal([]byte(out), &ch); err != nil || ch["channelId"] == nil || ch["squelchDb"] != -45.0 {
		t.Fatalf("json set view: %v %s", err, out)
	}
	// A second channel owned by the app: set still knows which one ley made and says so.
	app, err := leyline.Dial(context.Background(), sock, leyline.WithKind("app"), leyline.WithLabel("Leyline.app"), leyline.WithClientID("app_test"))
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	st, _ := c.State(context.Background())
	if _, err := app.Control.CreateChannel(context.Background(), &leylinev1.CreateChannelRequest{CaptureId: st.Captures[0].CaptureId, OffsetHz: 100_000, BandwidthHz: 12_500, Mode: leylinev1.DemodMode_NFM, Persistent: true}); err != nil {
		t.Fatal(err)
	}
	out = mustRun(t, sock, "set", "squelch", "-50")
	if !strings.Contains(out, "using channel 1, 146.520 MHz NFM, chan_") || !strings.Contains(out, "(cli:ley) (the only active channel ley made)") {
		t.Fatalf("expected the cli-owned channel to be chosen and announced:\n%s", out)
	}
	st, _ = c.State(context.Background())
	if st.Channels[0].SquelchDb != -50 || !math.IsNaN(st.Channels[1].SquelchDb) {
		t.Fatalf("wrong channel written: %v", st.Channels)
	}
	// Under --json the choice is announced on stderr, stdout stays JSON.
	out, errOut, err := run(t, context.Background(), sock, "--json", "set", "squelch", "-51")
	if err != nil || !strings.HasPrefix(out, "{") || !strings.Contains(errOut, "using channel 1") {
		t.Fatalf("json target notice: %v\nstdout: %s\nstderr: %s", err, out, errOut)
	}
	// The app's channel is reachable by frequency.
	mustRun(t, sock, "set", "squelch", "-52", "--channel", "146.62")
	if st, _ = c.State(context.Background()); st.Channels[1].SquelchDb != -52 {
		t.Fatalf("frequency selector: %v", st.Channels)
	}
}

func TestSetSquelchAuto(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	mustRun(t, sock, "tune", "146.52", "--no-audio", "--persistent")
	out := mustRun(t, sock, "set", "squelch", "auto")
	if !strings.Contains(out, "squelch auto → -80 dBFS (10 dB above the band's noise floor") {
		t.Fatalf("auto squelch report:\n%s", out)
	}
	st, _ := c.State(context.Background())
	if got := st.Channels[0].SquelchDb; math.Abs(got-(-80)) > 1.5 {
		t.Fatalf("auto squelch value: %v", got)
	}
	// A wider channel sits higher above the per-bin floor: 200 kHz → about -68.
	mustRun(t, sock, "set", "bw", "200k")
	mustRun(t, sock, "set", "squelch", "auto")
	if st, _ = c.State(context.Background()); math.Abs(st.Channels[0].SquelchDb-(-68)) > 1.5 {
		t.Fatalf("auto squelch at 200 kHz: %v", st.Channels[0].SquelchDb)
	}
}

func TestSetParameterErrors(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	// Unknown parameter: listed before any daemon or target lookup (dead socket).
	dead := testutil.SocketPath(t, "dead.sock")
	_, _, err := run(t, context.Background(), dead, "set", "foo", "1")
	if err == nil || !strings.Contains(err.Error(), `"foo" is not a setting`) || !strings.Contains(err.Error(), "squelch") || strings.Contains(err.Error(), "daemon") {
		t.Fatalf("unknown param: %v", err)
	}
	if _, _, err := run(t, context.Background(), dead, "set", "squelch"); err == nil || !strings.Contains(err.Error(), "needs a value (-40, -40dB, off, auto)") {
		t.Fatalf("missing value: %v", err)
	}
	if _, _, err := run(t, context.Background(), dead, "set", "squelch", "-40", "extra"); err == nil || !strings.Contains(err.Error(), "one parameter and one value") {
		t.Fatalf("too many words: %v", err)
	}
	mustRun(t, sock, "tune", "146.52", "--no-audio", "--persistent")
	cases := map[string][]string{
		"squelch: ":                     {"squelch", "5"},
		"accepted: -40, -40dB, off":     {"squelch", "loud"},
		"accepted: 30, 30dB, auto":      {"gain", "-5"},
		"accepted: 12.5 (kHz), 200k":    {"bw", "wide"},
		"accepted: 0.5, 50%":            {"volume", "loud"},
		"accepted: nfm, am, wfm":        {"mode", "morse"},
		"accepted: 146.52 (MHz), 1010k": {"freq", "146,520"},
	}
	for want, args := range cases {
		_, _, err := run(t, context.Background(), sock, append([]string{"set"}, args...)...)
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("set %v: want %q in %v", args, want, err)
		}
		if exitCode(err) != ExitUsage {
			t.Errorf("set %v: exit %d, want %d (usage error)", args, exitCode(err), ExitUsage)
		}
		if err != nil && strings.Contains(err.Error(), args[0]+": "+args[0]+": ") {
			t.Errorf("set %v: doubled prefix in %v", args, err)
		}
	}
	for _, args := range [][]string{{"set", "foo", "1"}, {"set", "squelch"}, {"set", "squelch", "-40", "extra"}} {
		if _, _, err := run(t, context.Background(), dead, args...); exitCode(err) != ExitUsage {
			t.Errorf("ley %v: exit %d (%v), want %d", args, exitCode(err), err, ExitUsage)
		}
	}
	if _, _, err := run(t, context.Background(), sock, "set", "gain", "-5"); err == nil || !strings.Contains(err.Error(), "gain: \"-5\" is negative") {
		t.Errorf("gain prefix once: %v", err)
	}
	if _, _, err := run(t, context.Background(), sock, "set", "squelch", "5"); err == nil || !strings.Contains(err.Error(), "dBFS") {
		t.Errorf("positive squelch should explain the scale: %v", err)
	}
	// Out-of-range frequency: device range and the honest reason.
	_, _, err = run(t, context.Background(), sock, "set", "freq", "5")
	if err == nil || leyline.Code(err) != leyline.CodeFreqOutOfRange || !strings.Contains(err.Error(), "cannot tune below 24.000 MHz") {
		t.Errorf("set freq out of range: %v", err)
	}
	// Inferred mode says why.
	if out := mustRun(t, sock, "set", "mode", "fm"); !strings.Contains(out, "using NFM: fm outside the FM broadcast band means NFM") {
		t.Errorf("mode rationale: %s", out)
	}
}

// The negative-number matrix for the DisableFlagParsing workaround.
func TestSetNegativeNumbers(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	mustRun(t, sock, "tune", "146.52", "--no-audio", "--persistent")
	for i, args := range [][]string{
		{"set", "squelch", "-40"},
		{"set", "--json", "squelch", "-41"},
		{"set", "squelch", "-42", "--json"},
		{"--json", "set", "squelch", "-43"},
	} {
		out := mustRun(t, sock, args...)
		st, _ := c.State(context.Background())
		if st.Channels[0].SquelchDb != float64(-40-i) {
			t.Errorf("%v: squelch %v", args, st.Channels[0].SquelchDb)
		}
		if i > 0 && !strings.HasPrefix(out, "{") {
			t.Errorf("%v: expected JSON output: %s", args, out)
		}
	}
	out, _, err := run(t, context.Background(), sock, "set", "-h")
	if err != nil || !strings.Contains(out, "Parameters:") || !strings.Contains(out, "squelch") || !strings.Contains(out, "--channel") {
		t.Fatalf("set -h: %v\n%s", err, out)
	}
}

// TestFFTGapLine: fft subscribes GAP_MARKED, so a drop reaches the consumer as
// the documented gap line. The fake marks every 50th frame; --count counts rows.
func TestFFTGapLine(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out := mustRun(t, sock, "fft", "--format", "json", "--count", "55", "--bins", "256", "--rate", "30", "--freq", "100M")
	lines := strings.Split(strings.TrimSpace(out), "\n")
	var rows int
	var gaps []string
	for _, l := range lines {
		if strings.HasPrefix(l, `{"gap":`) {
			gaps = append(gaps, l)
			continue
		}
		var row FFTRow
		if err := json.Unmarshal([]byte(l), &row); err != nil {
			t.Fatalf("row %q: %v", l, err)
		}
		rows++
	}
	if rows != 55 {
		t.Errorf("want 55 rows, got %d", rows)
	}
	if len(gaps) != 1 {
		t.Fatalf("want exactly one gap line, got %d:\n%s", len(gaps), out)
	}
	var gap struct {
		Gap struct {
			From uint64 `json:"from_sample"`
			To   uint64 `json:"to_sample"`
		} `json:"gap"`
	}
	if err := json.Unmarshal([]byte(gaps[0]), &gap); err != nil || gap.Gap.To <= gap.Gap.From {
		t.Errorf("gap line %q: err %v, from %d to %d", gaps[0], err, gap.Gap.From, gap.Gap.To)
	}
	// The gap precedes the 50th row: 49 rows, the gap, then the rest.
	if !strings.HasPrefix(lines[49], `{"gap":`) {
		t.Errorf("gap line at index %d, want 49", indexOfPrefix(lines, `{"gap":`))
	}
}

func indexOfPrefix(lines []string, prefix string) int {
	for i, l := range lines {
		if strings.HasPrefix(l, prefix) {
			return i
		}
	}
	return -1
}
