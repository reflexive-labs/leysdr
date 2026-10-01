// SPDX-License-Identifier: Apache-2.0

package e2e

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/reflexive-labs/leysdr/go/internal/cli"
)

// TestScopeAgainstRealDaemon taps the demodulator the daemon actually runs. The demod tap is the
// one view whose numbers come from before the audio chain, and the tone in its rows is the Swift
// sub-audible detector's result carried over telemetry, so only the real daemon can say whether the
// Go view reports the tone that is in the recording.
func TestScopeAgainstRealDaemon(t *testing.T) {
	e, _ := setup(t)
	pl, err := filepath.Abs("../../../fixtures/nfm_pl.cf32")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(pl); err != nil {
		t.Skipf("fixture missing (%v); run `go run ./cmd/leyfix generate --out ../../../fixtures`", err)
	}
	// Session holder: play keeps the channel the scope taps alive.
	stopPlay, _ := e.startLive("play", pl, "--no-audio", "--loop", "--json")
	defer func() { _ = stopPlay() }()
	st := e.waitChannels(1)
	chanID := list(st, "channels")[0].(map[string]any)["channelId"].(string)

	// nfm_pl.cf32 carries a 100.0 Hz CTCSS tone. The detector needs a few windows of audio before
	// it reports one, and a row printed before the first telemetry message carries no tone at all,
	// so keep drawing until one arrives.
	const wantTone = 100.0
	var tone *float64
	deadline := time.Now().Add(10 * time.Second)
	for tone == nil && time.Now().Before(deadline) {
		rows := scopeRows(t, e.mustRun("scope", chanID, "--tap", "demod", "--json", "--count", "20"))
		if len(rows) != 20 {
			t.Fatalf("scope --count 20: got %d rows", len(rows))
		}
		for i, r := range rows {
			checkScopeRow(t, i, r, "demod")
			if r.ToneHz != nil && tone == nil {
				tone = r.ToneHz
			}
		}
	}
	if tone == nil {
		t.Fatalf("no scope row carried a sub-audible tone within 10 s")
	}
	if math.Abs(*tone-wantTone) > 0.5 {
		t.Errorf("tone_hz %.2f, want %.1f ± 0.5", *tone, wantTone)
	}

	// The audio tap is the same frames after the high-pass that removes the tone, so it is asked
	// only to arrive and to measure.
	rows := scopeRows(t, e.mustRun("scope", chanID, "--tap", "audio", "--json", "--count", "5"))
	if len(rows) != 5 {
		t.Fatalf("scope --tap audio --count 5: got %d rows", len(rows))
	}
	for i, r := range rows {
		checkScopeRow(t, i, r, "audio")
	}
}

// checkScopeRow asserts what every row must carry regardless of tap: the tap it was asked for, a
// rate to read the window against, and statistics that are numbers.
func checkScopeRow(t *testing.T, i int, r cli.ScopeRow, tap string) {
	t.Helper()
	if r.Tap != tap {
		t.Fatalf("row %d: tap %q, want %q", i, r.Tap, tap)
	}
	if r.SampleRate == 0 {
		t.Fatalf("row %d: no sample rate: %+v", i, r)
	}
	for _, v := range []struct {
		name string
		val  float64
	}{{"rms_dbfs", r.RmsDbfs}, {"dc", r.DC}, {"peak_dbfs", r.PeakDbfs}} {
		if math.IsNaN(v.val) || math.IsInf(v.val, 0) {
			t.Fatalf("row %d: %s is %v: %+v", i, v.name, v.val, r)
		}
	}
}

func scopeRows(t *testing.T, out string) []cli.ScopeRow {
	t.Helper()
	var rows []cli.ScopeRow
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if line == "" {
			continue
		}
		var r cli.ScopeRow
		if err := json.Unmarshal([]byte(line), &r); err != nil {
			t.Fatalf("bad scope row %q: %v", line, err)
		}
		rows = append(rows, r)
	}
	return rows
}
