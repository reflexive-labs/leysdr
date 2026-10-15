// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/reflexive-labs/leysdr/go/internal/daemonrun"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
	"github.com/reflexive-labs/leysdr/go/pkg/wer"
)

// The spike's tool end to end: the real daemon records the keyed fixture gated on its squelch,
// a hand transcript is written that says what the scripted engine says, and leyspeech runs ley
// transcribe with the scripted engine and scores it. The script has one line, which the engine
// repeats for every over, so the transcript is known before the run.
const spikeScript = "whiskey six alpha bravo charlie checking in"

// spikeFreq is where the keyed fixture's carrier is.
const spikeFreq = "146.62"

func TestSpeechSpikeAgainstRealDaemon(t *testing.T) {
	daemonBin, leyBin, decoders := os.Getenv("LEYLINED_BIN"), os.Getenv("LEY_BIN"), os.Getenv("LEYLINE_DECODERS")
	if daemonBin == "" || leyBin == "" || decoders == "" {
		t.Skip("set LEYLINED_BIN, LEY_BIN and LEYLINE_DECODERS, with leydec-speech on PATH, to run against a real daemon")
	}
	fixture := keyedFixture(t)
	script := filepath.Join(t.TempDir(), "script.txt")
	if err := os.WriteFile(script, []byte(spikeScript+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// The daemon's environment is the plugin's, so the scripted engine finds its words.
	t.Setenv("LEYDEC_SPEECH_SCRIPT", script)

	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	d, err := daemonrun.Start(ctx, daemonrun.Options{Bin: daemonBin, Dir: t.TempDir(), Decoders: decoders, Label: "leyspeech-test"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		d.Stop()
		if t.Failed() {
			b, _ := os.ReadFile(d.Log)
			t.Logf("leylined log:\n%s", b)
		}
	})
	g := &globals{ley: leyBin, socket: d.Socket}
	id := recordKeyed(ctx, t, g.runner(), d, fixture)
	dir := filepath.Join(d.Recordings, id)
	rec, err := readRecording(dir)
	if err != nil {
		t.Fatal(err)
	}
	overs := rec.overs(leyline.OverPreRollMs, leyline.OverHangMs)
	if len(overs) < 3 {
		t.Fatalf("the recording has %d overs, want at least 3", len(overs))
	}
	// "w6abc checking in": three words an over after normalising.
	words := 3 * len(overs)

	t.Run("a transcript that matches scores 0", func(t *testing.T) {
		writeRef(t, filepath.Join(dir, wer.TranscriptFile), overs, -1)
		r := measureOne(ctx, t, g, daemonOptions{}, id, "")
		checkScore(t, r, len(overs), 0, 0)
		if r.Ref != filepath.Join(dir, wer.TranscriptFile) {
			t.Errorf("ref %q, want the transcript beside the recording", r.Ref)
		}
		if r.Usage.Requests != float64(len(overs)) || r.Usage.AudioSeconds <= 0 || r.Usage.Provider != "scripted" {
			t.Errorf("usage %+v, want scripted, %d requests and some audio", r.Usage, len(overs))
		}
		if r.OpenSeconds <= 0 || r.Speed <= 0 || r.PerOpenHour.Requests <= r.Usage.Requests {
			t.Errorf("open %.1f s, speed %.1f, per hour %+v", r.OpenSeconds, r.Speed, r.PerOpenHour)
		}
		var out bytes.Buffer
		if err := report(&out, []*result{r}, false); err != nil {
			t.Fatal(err)
		}
		t.Logf("leyspeech run:\n%s", out.String())
		if row := fmt.Sprintf("%d/%d", len(overs), len(overs)); !strings.Contains(out.String(), row) || !strings.Contains(out.String(), "0.0%") {
			t.Errorf("the table lacks %s and 0.0%%:\n%s", row, out.String())
		}
	})

	t.Run("one wrong word", func(t *testing.T) {
		ref := filepath.Join(t.TempDir(), "wrong.txt")
		writeRef(t, ref, overs, 0)
		r := measureOne(ctx, t, g, daemonOptions{}, id, ref)
		checkScore(t, r, len(overs), 1, 1/float64(words))
		var out bytes.Buffer
		_ = report(&out, []*result{r}, false)
		t.Logf("leyspeech run --ref:\n%s", out.String())
		if r.Score.Overs[0].Counts.Subs != 1 {
			t.Errorf("the first over: %+v, want one substitution", r.Score.Overs[0])
		}
	})

	t.Run("compare runs each engine", func(t *testing.T) {
		ref := filepath.Join(t.TempDir(), "ref.txt")
		writeRef(t, ref, overs, -1)
		var stderr bytes.Buffer
		// transcribe is the speech decoder's alias: two jobs, two rows, one decoder.
		results, err := measureRecording(ctx, g, daemonOptions{}, id, ref, []engineSpec{{name: "speech"}, {name: "transcribe"}}, &stderr)
		if err != nil {
			t.Fatalf("%v\n%s", err, stderr.String())
		}
		if len(results) != 2 || results[0].JobID == results[1].JobID {
			t.Fatalf("compare gave %d results, want 2 from two jobs: %+v", len(results), results)
		}
		for _, r := range results {
			checkScore(t, r, len(overs), 0, 0)
		}
	})

	t.Run("no transcript scores nothing", func(t *testing.T) {
		if err := os.Remove(filepath.Join(dir, wer.TranscriptFile)); err != nil {
			t.Fatal(err)
		}
		r := measureOne(ctx, t, g, daemonOptions{}, id, "")
		if r.Score != nil || r.Records != len(overs) {
			t.Errorf("without a transcript: score %+v, %d records", r.Score, r.Records)
		}
		var out bytes.Buffer
		_ = report(&out, []*result{r}, false)
		if !strings.Contains(out.String(), "nothing was scored") {
			t.Errorf("the report does not say nothing was scored:\n%s", out.String())
		}
	})

	// Through the command line, so the flags and --json are what is tested.
	t.Run("a hermetic daemon on a copy", func(t *testing.T) {
		ref := filepath.Join(t.TempDir(), "ref.txt")
		writeRef(t, ref, overs, -1)
		root := newRoot()
		var out, stderr bytes.Buffer
		root.SetOut(&out)
		root.SetErr(&stderr)
		root.SetArgs([]string{
			"--ley", leyBin, "run", "--daemon", "--leylined", daemonBin, "--decoders", decoders,
			"--recording", dir, "--engine", "speech", "--ref", ref, "--json",
		})
		if err := root.ExecuteContext(ctx); err != nil {
			t.Fatalf("leyspeech run --daemon: %v\n%s", err, stderr.String())
		}
		var results []*result
		if err := json.Unmarshal(out.Bytes(), &results); err != nil || len(results) != 1 {
			t.Fatalf("leyspeech run --json printed %d results (%v):\n%s", len(results), err, out.String())
		}
		checkScore(t, results[0], len(overs), 0, 0)
		if !strings.Contains(stderr.String(), "a hermetic daemon on") {
			t.Errorf("stderr does not name the hermetic daemon:\n%s", stderr.String())
		}
	})

	t.Run("live", func(t *testing.T) {
		var stderr bytes.Buffer
		s, err := openLiveSession(ctx, g, &stderr)
		if err != nil {
			t.Fatal(err)
		}
		defer s.close()
		r, err := s.live(ctx, spikeFreq, engineSpec{name: "speech"}, 14*time.Second)
		if err != nil {
			t.Fatalf("%v\n%s", err, stderr.String())
		}
		l := r.Latency
		t.Logf("live: %d records, delays %+v", r.Records, l.Overs)
		if r.Records < 2 || len(l.Overs) != r.Records || l.Unplaced != 0 {
			t.Fatalf("live: %d records, %d placed, %d unplaced; want at least 2, all placed\n%s", r.Records, len(l.Overs), l.Unplaced, stderr.String())
		}
		// The delay holds the half-second hang, so it is at least that; the scripted engine
		// answers at once, so it is well under a few seconds.
		if l.MedianSeconds < 0.4 || l.MaxSeconds > 3 {
			t.Errorf("delays median %.2f s, max %.2f s; want from the hang to a few seconds", l.MedianSeconds, l.MaxSeconds)
		}
		if l.HangMs != leyline.OverHangMs {
			t.Errorf("hang %d ms, want %d", l.HangMs, leyline.OverHangMs)
		}
	})
}

func keyedFixture(t *testing.T) string {
	t.Helper()
	dir := os.Getenv("LEYLINE_FIXTURES")
	if dir == "" {
		dir = "../../../fixtures"
	}
	fixture, err := filepath.Abs(filepath.Join(dir, "nfm_keyed.cf32"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(fixture); err != nil {
		t.Skipf("fixture missing (%v); run make fixtures or set LEYLINE_FIXTURES", err)
	}
	return fixture
}

// recordKeyed makes the fixture an idle looping radio and records ~14 s of it gated on the
// squelch, as the transcribe e2e does: the fixture keys at 1, 5 and 8.5 s of every 10.5 s.
func recordKeyed(ctx context.Context, t *testing.T, l *leyRunner, d *daemonrun.Daemon, fixture string) string {
	t.Helper()
	mustLey(ctx, t, l, "play", fixture, "--no-audio", "--loop", "--persistent", "--json")
	mustLey(ctx, t, l, "stop", "all")
	deadline := time.Now().Add(5 * time.Second)
	for {
		st, err := d.Client.State(ctx)
		if err == nil && len(st.GetCaptures()) == 0 && len(st.GetDevices()) > 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the fixture never became an idle radio: %v %v", st, err)
		}
		time.Sleep(50 * time.Millisecond)
	}
	out := mustLey(ctx, t, l, "record", spikeFreq, "--gate", "squelch", "--squelch", "-40", "--hang", "2s", "--for", "14s")
	id, part, ok := leyline.ParseRecordingURI(strings.TrimSpace(out))
	if !ok || part != 0 {
		t.Fatalf("ley record printed %q, want the recording's uri", out)
	}
	return id
}

func mustLey(ctx context.Context, t *testing.T, l *leyRunner, args ...string) string {
	t.Helper()
	out, err := l.output(ctx, args...)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// writeRef writes a transcript giving every over the script's words, except over wrong (an index
// into overs, or -1 for none), whose last word is changed.
func writeRef(t *testing.T, path string, overs []overSpan, wrong int) {
	t.Helper()
	var b strings.Builder
	b.WriteString("# written by the test\n")
	for i, o := range overs {
		text := spikeScript
		if i == wrong {
			text = strings.TrimSuffix(spikeScript, "in") + "out"
		}
		fmt.Fprintf(&b, "%s\t%s\n", o.key, text)
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		t.Fatal(err)
	}
}

func measureOne(ctx context.Context, t *testing.T, g *globals, o daemonOptions, recordingRef, ref string) *result {
	t.Helper()
	var stderr bytes.Buffer
	results, err := measureRecording(ctx, g, o, recordingRef, ref, []engineSpec{{name: "speech"}}, &stderr)
	if err != nil {
		t.Fatalf("%v\n%s", err, stderr.String())
	}
	if len(results) != 1 {
		t.Fatalf("%d results, want 1", len(results))
	}
	return results[0]
}

func checkScore(t *testing.T, r *result, overs, errors int, rate float64) {
	t.Helper()
	sc := r.Score
	if sc == nil {
		t.Fatalf("no score: %+v", r)
	}
	if sc.Counts.Errors() != errors || math.Abs(sc.Rate-rate) > 1e-9 {
		t.Errorf("WER %.4f with %+v, want %.4f with %d errors", sc.Rate, sc.Counts, rate, errors)
	}
	if sc.CallsignHits != overs || sc.CallsignTotal != overs || sc.Recall != 1 {
		t.Errorf("callsigns %d/%d (%.2f), want %d/%d", sc.CallsignHits, sc.CallsignTotal, sc.Recall, overs, overs)
	}
	if sc.RefOvers != overs || sc.HypOvers != overs || sc.Missing != 0 || sc.Extra != 0 || r.Records != overs {
		t.Errorf("overs: %d ref, %d hyp, %d missing, %d extra, %d records; want %d each and none missing", sc.RefOvers, sc.HypOvers, sc.Missing, sc.Extra, r.Records, overs)
	}
}
