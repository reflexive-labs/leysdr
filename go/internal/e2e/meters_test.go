package e2e

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"

	"github.com/dpup/leysdr/go/internal/cli"
)

// TestMetersAgainstRealDaemon reads the audio meters off the daemon's own spectrum tap. The band
// levels come out of Swift's FFT and the squelch state out of its meter telemetry, so only the
// real daemon can say whether the Go views name the same signal the recording carries: the 100 Hz
// CTCSS tone standing in the 125 Hz band before the audio chain, and gone from it after.
func TestMetersAgainstRealDaemon(t *testing.T) {
	e, _ := setup(t)
	pl, err := filepath.Abs("../../../fixtures/nfm_pl.cf32")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(pl); err != nil {
		t.Skipf("fixture missing (%v); run `go run ./cmd/leyfix generate --out ../../../fixtures`", err)
	}
	// Session holder: play keeps the channel the meters tap alive.
	stopPlay, _ := e.startLive("play", pl, "--no-audio", "--loop", "--json")
	defer func() { _ = stopPlay() }()
	st := e.waitChannels(1)
	chanID := list(st, "channels")[0].(map[string]any)["channelId"].(string)

	// nfm_pl.cf32 is a 1 kHz voice tone over a 100.0 Hz PL, and 100 Hz falls in the 125 Hz octave
	// band (88..177 Hz). Before the audio chain both stand; the two bands are the loudest of the
	// nine.
	demod := levelsBands(t, e, chanID, "demod")
	got := twoLoudest(demod)
	if got != [2]float64{125, 1000} && got != [2]float64{1000, 125} {
		t.Errorf("demod tap: loudest bands %v Hz, want 125 and 1000: %v", got, demod)
	}
	// And they read as the levels the recording carries. A band is the sum of
	// its bins corrected for the Hann window, so a tone in one reads its own
	// level rather than the 1.76 dB the window spread it over.
	for _, tc := range []struct{ hz, want float64 }{{125, -17}, {1000, -6}} {
		if math.Abs(demod[tc.hz]-tc.want) > 1 {
			t.Errorf("demod tap: the %g Hz band reads %.1f dBFS, want %.0f within 1 dB: the tone is %.0f dBFS in the fixture",
				tc.hz, demod[tc.hz], tc.want, tc.want)
		}
	}

	// The audio tap is the same detector output past the high-pass that takes the PL out, so the
	// voice tone is alone at the top and the 125 Hz band has dropped well below where it stood.
	audio := levelsBands(t, e, chanID, "audio")
	if loudest := twoLoudest(audio)[0]; loudest != 1000 {
		t.Errorf("audio tap: loudest band %g Hz, want 1000: %v", loudest, audio)
	}
	if drop := demod[125] - audio[125]; drop < 10 {
		t.Errorf("125 Hz band %.1f dB on demod, %.1f dB on audio: dropped %.1f dB, want at least 10",
			demod[125], audio[125], drop)
	}
}

// TestWaveformAgainstRealDaemon asks the clip view for columns off the real audio stream: the
// statistics have to be numbers a picture could be drawn from, and the squelch the daemon reports
// over a fixture this loud has to be open.
func TestWaveformAgainstRealDaemon(t *testing.T) {
	e, _ := setup(t)
	pl, err := filepath.Abs("../../../fixtures/nfm_pl.cf32")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(pl); err != nil {
		t.Skipf("fixture missing (%v); run `go run ./cmd/leyfix generate --out ../../../fixtures`", err)
	}
	stopPlay, _ := e.startLive("play", pl, "--no-audio", "--loop", "--json")
	defer func() { _ = stopPlay() }()
	st := e.waitChannels(1)
	chanID := list(st, "channels")[0].(map[string]any)["channelId"].(string)

	out := e.mustRun("waveform", chanID, "--seconds", "2", "--json", "--count", "10")
	var rows []cli.WaveformRow
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if line == "" {
			continue
		}
		var r cli.WaveformRow
		if err := json.Unmarshal([]byte(line), &r); err != nil {
			t.Fatalf("bad waveform row %q: %v", line, err)
		}
		rows = append(rows, r)
	}
	if len(rows) != 10 {
		t.Fatalf("waveform --count 10: got %d columns", len(rows))
	}
	var last float64
	for i, r := range rows {
		for _, v := range []struct {
			name string
			val  float64
		}{{"peak_dbfs", r.PeakDbfs}, {"rms_dbfs", r.RmsDbfs}} {
			if math.IsNaN(v.val) || math.IsInf(v.val, 0) {
				t.Fatalf("column %d: %s is %v: %+v", i, v.name, v.val, r)
			}
		}
		if !r.SquelchOpen {
			t.Errorf("column %d: squelch_open false over a full-strength fixture: %+v", i, r)
		}
		// Each column covers a fixed slice of audio, so the seconds the picture holds only grows.
		if r.Seconds <= last {
			t.Errorf("column %d: seconds %g, want more than the column before it (%g)", i, r.Seconds, last)
		}
		last = r.Seconds
	}
}

// levelsBands runs the meter over one tap and returns each band's level, averaged over the rows so
// a single row caught between syllables of the fixture cannot decide the order.
func levelsBands(t *testing.T, e *env, chanID, tap string) map[float64]float64 {
	t.Helper()
	const want = 5
	sum := map[float64]float64{}
	rows := 0
	out := e.mustRun("levels", chanID, "--tap", tap, "--json", "--watch", "--count", strconv.Itoa(want))
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if line == "" {
			continue
		}
		var r cli.LevelsRow
		if err := json.Unmarshal([]byte(line), &r); err != nil {
			t.Fatalf("bad levels row %q: %v", line, err)
		}
		if r.Tap != tap {
			t.Fatalf("levels --tap %s: row says %q", tap, r.Tap)
		}
		if len(r.Bands) == 0 {
			t.Fatalf("levels --tap %s: row carries no bands: %+v", tap, r)
		}
		for _, b := range r.Bands {
			if math.IsNaN(b.Db) || math.IsInf(b.Db, 0) {
				t.Fatalf("levels --tap %s: band %g Hz is %v", tap, b.CenterHz, b.Db)
			}
			sum[b.CenterHz] += b.Db
		}
		rows++
	}
	if rows != want {
		t.Fatalf("levels --tap %s --count %d: got %d rows", tap, want, rows)
	}
	for hz := range sum {
		sum[hz] /= float64(rows)
	}
	return sum
}

// twoLoudest names the two bands carrying the most, loudest first.
func twoLoudest(bands map[float64]float64) [2]float64 {
	centres := make([]float64, 0, len(bands))
	for hz := range bands {
		centres = append(centres, hz)
	}
	sort.Slice(centres, func(i, j int) bool {
		if bands[centres[i]] != bands[centres[j]] {
			return bands[centres[i]] > bands[centres[j]]
		}
		return centres[i] < centres[j]
	})
	return [2]float64{centres[0], centres[1]}
}
