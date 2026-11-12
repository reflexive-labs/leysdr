// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"encoding/json"
	"strings"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
)

// The line names the band and the host, and says it is every minute, only for a SEGMENTED
// decoder that sends its audio somewhere and only on a band that never goes quiet.
func TestOpenSquelchCost(t *testing.T) {
	t.Parallel()
	speech := fakedaemon.SpeechManifest()
	for _, tc := range []struct {
		m    *leylinev1.DecoderManifest
		hz   uint64
		want string
	}{
		{speech, 98_500_000, "98.500 MHz is FM broadcast, which never goes quiet: this channel's squelch never closes, so every minute of its audio goes to api.openai.com (60 min an hour)"},
		{speech, 162_550_000, "162.550 MHz is NOAA weather, which never goes quiet: this channel's squelch never closes, so every minute of its audio goes to api.openai.com (60 min an hour)"},
		{speech, 146_520_000, ""},
		{fakedaemon.ScriptedSpeechManifest(), 98_500_000, ""},
		{fakedaemon.AprsManifest(), 98_500_000, ""},
	} {
		if got := openSquelchCost(tc.m, tc.hz); got != tc.want {
			t.Errorf("%s on %d:\n got %q\nwant %q", tc.m.GetName(), tc.hz, got, tc.want)
		}
	}
}

const fmCostLine = "98.500 MHz is FM broadcast, which never goes quiet: this channel's squelch never closes, so every minute of its audio goes to api.openai.com (60 min an hour)"

// decode and watch state the cost before a speech job on FM broadcast and ask, as transcribe
// asks: no terminal and no --yes is a usage error that starts nothing, no at the prompt starts
// nothing, and --yes states it and starts.
func TestSpeechOnABandThatNeverGoesQuietAsksFirst(t *testing.T) {
	t.Parallel()
	sock, c := transcribeHarness(t, speechLiveOpts(t))
	for _, verb := range []string{"decode", "watch"} {
		_, errOut, err := runLey(t, sock, 80, false, "", verb, "speech", "--freq", "98.5")
		if exitCode(err) != ExitUsage || !strings.Contains(err.Error(), "ley "+verb+" speech --freq 98.5 --yes") {
			t.Errorf("ley %s without a terminal: exit %d %v, want a usage error naming --yes", verb, exitCode(err), err)
		}
		if !strings.Contains(errOut, fmCostLine+".\n") {
			t.Errorf("ley %s: stderr lacks the cost line:\n%s", verb, errOut)
		}
		app := &App{Socket: sock, Stdin: strings.NewReader("n\n"), IsInTTY: func() bool { return true }}
		_, errOut, err = runApp(t, app, verb, "speech", "--freq", "98.5")
		if err != nil || !strings.Contains(errOut, fmCostLine+". Start? [y/N] ") || !strings.Contains(errOut, "Nothing was started") {
			t.Errorf("ley %s answered no: %v\n%s", verb, err, errOut)
		}
	}
	if jobs, _ := c.ListJobs(t.Context()); len(jobs) != 0 {
		t.Fatalf("nothing agreed, and jobs started: %v", jobs)
	}
	_, errOut, err := runLey(t, sock, 80, false, "", "watch", "speech", "--freq", "98.5", "--detach", "--yes")
	if err != nil || !strings.Contains(errOut, fmCostLine+".\n") {
		t.Errorf("--yes: %v\n%s", err, errOut)
	}
	if jobs, _ := c.ListJobs(t.Context()); len(jobs) != 1 {
		t.Errorf("--yes started %d jobs, want 1", len(jobs))
	}
	// Where the squelch closes between overs nothing is asked.
	sock, _ = transcribeHarness(t, speechLiveOpts(t))
	if _, errOut, err := runLey(t, sock, 80, false, "", "watch", "speech", "--freq", "146.52", "--detach"); err != nil || strings.Contains(errOut, "never goes quiet") {
		t.Errorf("146.52: %v\n%s", err, errOut)
	}
}

// A continuous recording has no overs: transcribe states every minute of it, and the records of
// its pieces after the first say they continue the one before.
func TestTranscribeAContinuousRecordingCountsAllOfIt(t *testing.T) {
	t.Parallel()
	opts := transcribeOpts(t, false)
	opts.Recordings = []fakedaemon.SeedRecording{{
		JobID: transcribeID, StartedAt: transcribeStart, FrequencyHz: 98_500_000, Mode: "WFM",
		ContinuousMs: []int64{40_000, 30_000},
	}}
	sock, _ := transcribeHarness(t, opts)
	_, errOut, err := runLey(t, sock, 80, false, "", "transcribe", transcribeID)
	want := "Transcribe 2 parts, 1.2 min of audio from 98.500 MHz WFM, every minute of it since no squelch gated the recording, with speech (sends the audio to api.openai.com)."
	if exitCode(err) != ExitUsage || !strings.Contains(errOut, want+"\n") {
		t.Errorf("exit %d %v; stderr:\n%s\nwant %q", exitCode(err), err, errOut, want)
	}
	out, _, err := runLey(t, sock, 80, false, "", "--json", "transcribe", transcribeID, "--yes")
	if err != nil {
		t.Fatal(err)
	}
	var got []struct {
		Over   uint32 `json:"over"`
		Fields map[string]struct {
			Flag *bool `json:"flag"`
		} `json:"fields"`
	}
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		var rec struct {
			Over   uint32 `json:"over"`
			Fields map[string]struct {
				Flag *bool `json:"flag"`
			} `json:"fields"`
		}
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			t.Fatalf("%v: %s", err, line)
		}
		got = append(got, rec)
	}
	// Part 1 is 40 s: a 30 s piece and a 10 s one. Part 2 is 30 s, which is not over the limit.
	if len(got) != 3 {
		t.Fatalf("%d records, want 3:\n%s", len(got), out)
	}
	for i, wantOver := range []uint32{1, 2, 1} {
		if got[i].Over != wantOver {
			t.Errorf("record %d: over %d, want %d", i+1, got[i].Over, wantOver)
		}
		f, ok := got[i].Fields["continues"]
		continues := ok && f.Flag != nil && *f.Flag
		if continues != (i > 0) {
			t.Errorf("record %d: continues %v, want %v", i+1, continues, i > 0)
		}
	}
}
