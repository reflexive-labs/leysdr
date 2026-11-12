// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"encoding/json"
	"strings"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
)

// The line says why the squelch never closes, the channel first and the band plan after, names
// the host and says it is every minute, only for a SEGMENTED decoder that sends its audio
// somewhere.
func TestOpenSquelchCost(t *testing.T) {
	t.Parallel()
	speech := fakedaemon.SpeechManifest()
	const tail = ": this channel's squelch never closes, so every minute of its audio goes to api.openai.com (60 min an hour)"
	nfm, wfm := leylinev1.DemodMode_NFM, leylinev1.DemodMode_WFM
	for _, tc := range []struct {
		m    *leylinev1.DecoderManifest
		l    decodeListen
		want string
	}{
		{speech, decodeListen{hz: 98_500_000, mode: wfm}, "98.500 MHz WFM has no squelch" + tail},
		{speech, decodeListen{hz: 98_500_000, mode: nfm}, "98.500 MHz is FM broadcast, which never goes quiet" + tail},
		{speech, decodeListen{hz: 162_550_000, mode: nfm}, "162.550 MHz is NOAA weather, which never goes quiet" + tail},
		{speech, decodeListen{hz: 146_520_000, mode: nfm}, ""},
		{speech, decodeListen{hz: 146_520_000, mode: nfm, borrowed: true, squelchOff: true}, "146.520 MHz NFM has its squelch off" + tail},
		{speech, decodeListen{hz: 98_500_000, mode: wfm, borrowed: true, squelchOff: true}, "98.500 MHz WFM has its squelch off" + tail},
		{speech, decodeListen{hz: 146_520_000, mode: wfm, borrowed: true}, ""},
		{fakedaemon.ScriptedSpeechManifest(), decodeListen{hz: 98_500_000, mode: wfm}, ""},
		{fakedaemon.AprsManifest(), decodeListen{hz: 98_500_000, mode: wfm}, ""},
	} {
		if got := openSquelchCost(tc.m, tc.l); got != tc.want {
			t.Errorf("%s on %+v:\n got %q\nwant %q", tc.m.GetName(), tc.l, got, tc.want)
		}
	}
}

// --freq 98.5 makes a WFM channel, the band plan's mode there, which has no squelch.
const fmCostLine = "98.500 MHz WFM has no squelch: this channel's squelch never closes, so every minute of its audio goes to api.openai.com (60 min an hour)"

// A speech decoder, whose recipe names no frequency, makes its channel in the band plan's mode for
// --freq, as ley tune picks one; a decoder with a recipe of its own keeps the recipe's.
func TestDecodeTakesTheBandPlansMode(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		decoder, freq string
		want          leylinev1.DemodMode
	}{
		{"speech", "98.5", leylinev1.DemodMode_WFM},
		{"speech", "121.5", leylinev1.DemodMode_AM},
		{"speech", "146.52", leylinev1.DemodMode_NFM},
		{"aprs", "144.8", leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED},
	} {
		sock, c := transcribeHarness(t, speechLiveOpts(t))
		if _, errOut, err := runLey(t, sock, 80, false, "", "watch", tc.decoder, "--freq", tc.freq, "--detach", "--yes"); err != nil {
			t.Fatalf("%s at %s: %v\n%s", tc.decoder, tc.freq, err, errOut)
		}
		jobs, err := c.ListJobs(t.Context())
		if err != nil || len(jobs) != 1 {
			t.Fatalf("%s at %s: %d jobs, %v", tc.decoder, tc.freq, len(jobs), err)
		}
		if got := jobs[0].GetDecode().GetMode(); got != tc.want {
			t.Errorf("%s at %s: mode %v, want %v", tc.decoder, tc.freq, got, tc.want)
		}
	}
}

// --channel borrows a channel already open: the job names it and makes none of its own, and the
// cost line is the channel's.
func TestDecodeBorrowsAChannel(t *testing.T) {
	t.Parallel()
	sock, c := transcribeHarness(t, speechLiveOpts(t))
	mustRun(t, sock, "tune", "98.5", "--mode", "wfm", "--no-audio", "--persistent")
	st, err := c.State(t.Context())
	if err != nil || len(st.GetChannels()) != 1 {
		t.Fatalf("tune: %v, %d channels", err, len(st.GetChannels()))
	}
	channel := st.GetChannels()[0]
	_, errOut, err := runLey(t, sock, 80, false, "", "watch", "speech", "--channel", "this", "--detach")
	if exitCode(err) != ExitUsage || !strings.Contains(err.Error(), "ley watch speech --channel this --yes") ||
		!strings.Contains(errOut, "98.500 MHz WFM") || !strings.Contains(errOut, "never closes") {
		t.Errorf("a WFM channel without --yes: exit %d %v\n%s", exitCode(err), err, errOut)
	}
	if _, errOut, err := runLey(t, sock, 80, false, "", "watch", "speech", "--channel", "this", "--detach", "--yes"); err != nil {
		t.Fatalf("--yes: %v\n%s", err, errOut)
	}
	jobs, _ := c.ListJobs(t.Context())
	if len(jobs) != 1 || jobs[0].GetDecode().GetChannelId() != channel.GetChannelId() {
		t.Fatalf("jobs %v, want one on %s", jobs, channel.GetChannelId())
	}
	if st, _ := c.State(t.Context()); len(st.GetChannels()) != 1 {
		t.Errorf("the job made a channel of its own: %v", st.GetChannels())
	}
	for _, args := range [][]string{
		{"decode", "speech", "--channel", "this", "--freq", "98.5"},
		{"watch", "speech", "--channel", "this", "--take-over"},
		{"decode", "speech", "--channel", "this", "--recording", "job_01X"},
	} {
		if _, _, err := runLey(t, sock, 80, false, "", args...); exitCode(err) != ExitUsage {
			t.Errorf("ley %v: exit %d %v, want a usage error", args, exitCode(err), err)
		}
	}
}

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
