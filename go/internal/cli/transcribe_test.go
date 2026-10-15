// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// transcribeID is the seeded recording's id.
const transcribeID = "job_01SEEDSEEDSEEDSEEDSEEDSE"

// transcribeStart is when the seeded recording's first sample was heard, in the local zone, so the
// clock ley prints is the one written here.
var transcribeStart = time.Date(2026, 10, 13, 14, 3, 0, 0, time.Local)

// transcribeOpts is a fake with a two-part gated recording: part 1 has three overs, the first two
// inside the 500 ms hang of each other, and part 2 has one, so the job makes three records.
func transcribeOpts(t *testing.T, noOpenMs bool) fakedaemon.Options {
	t.Helper()
	return fakedaemon.Options{
		RecordingsDir: t.TempDir(),
		Recordings: []fakedaemon.SeedRecording{{
			JobID: transcribeID, StartedAt: transcribeStart, NoSquelchOpenMs: noOpenMs,
			Parts: [][]fakedaemon.SeedOver{
				{{OpenMs: 600, CloseMs: 1600}, {OpenMs: 1900, CloseMs: 2500}, {OpenMs: 4000, CloseMs: 5000}},
				{{OpenMs: 600, CloseMs: 1200}},
			},
		}},
		SpeechScript: []string{"this is whiskey six alpha bravo charlie", "kilo delta two x-ray yankee zulu, go ahead", "roger, see you at six alpha"},
	}
}

const transcribeStatementWant = "Transcribe 2 parts, 0.1 min of squelch-open audio from 146.520 MHz NFM, with speech (on this Mac; no audio leaves it)"

// Without a terminal to answer and without --yes, transcribe states what it would send and
// refuses with a usage error, starting nothing. The minutes are the same whether the manifest
// carries squelch_open_ms or the sidecars are summed.
func TestTranscribeRefusesWithoutATerminal(t *testing.T) {
	t.Parallel()
	for _, noOpenMs := range []bool{false, true} {
		sock, c := harness(t, transcribeOpts(t, noOpenMs))
		out, errOut, err := runLey(t, sock, 80, false, "", "transcribe", transcribeID)
		if exitCode(err) != ExitUsage || !strings.Contains(err.Error(), "ley transcribe "+transcribeID+" --yes") {
			t.Fatalf("want a usage error naming --yes, got exit %d: %v", exitCode(err), err)
		}
		if !strings.Contains(errOut, transcribeStatementWant+".\n") {
			t.Errorf("summed from sidecars %v: stderr lacks the statement:\n%s", noOpenMs, errOut)
		}
		if out != "" {
			t.Errorf("a refusal prints nothing on stdout: %q", out)
		}
		jobs, err := c.ListJobs(t.Context())
		if err != nil {
			t.Fatal(err)
		}
		for _, j := range jobs {
			if j.GetDecode() != nil {
				t.Errorf("a refused transcription started %s", j.GetJobId())
			}
		}
	}
}

// At a terminal it asks, and anything but yes sends nothing.
func TestTranscribeAsks(t *testing.T) {
	t.Parallel()
	sock, c := harness(t, transcribeOpts(t, false))
	app := &App{Socket: sock, Stdin: strings.NewReader("n\n"), IsInTTY: func() bool { return true }}
	_, errOut, err := runApp(t, app, "transcribe", transcribeID)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(errOut, transcribeStatementWant+"? [y/N] ") || !strings.Contains(errOut, "Nothing was sent") {
		t.Errorf("stderr:\n%s", errOut)
	}
	if jobs, _ := c.ListJobs(t.Context()); len(jobs) != 1 {
		t.Errorf("declining started a job: %v", jobs)
	}

	app = &App{Socket: sock, Stdin: strings.NewReader("y\n"), IsInTTY: func() bool { return true }}
	out, _, err := runApp(t, app, "transcribe", transcribeID)
	if err != nil || strings.Count(out, "\n") != 3 {
		t.Errorf("yes: %v\n%s", err, out)
	}
}

// With --yes it prints one line per over, as the recording's anchor dates it, then the count and
// the command that reads them again.
func TestTranscribePrintsEachOver(t *testing.T) {
	t.Parallel()
	sock, _ := harness(t, transcribeOpts(t, true))
	out, errOut, err := runLey(t, sock, 80, false, "", "transcribe", leyline.RecordingURI(transcribeID), "--yes")
	if err != nil {
		t.Fatalf("%v\n%s", err, errOut)
	}
	t.Logf("ley transcribe:\n%s%s", errOut, out)
	part2 := transcribeStart.Add(16*time.Second + 100*time.Millisecond).Format("15:04:05")
	want := strings.Join([]string{
		"14:03:00 part 1 over 1  this is whiskey six alpha bravo charlie (W6ABC)",
		"14:03:03 part 1 over 3  kilo delta two x-ray yankee zulu, go ahead (KD2XYZ)",
		part2 + " part 2 over 1  roger, see you at six alpha",
	}, "\n") + "\n"
	if out != want {
		t.Errorf("stdout:\n%s\nwant:\n%s", out, want)
	}
	if !strings.Contains(errOut, "Transcribing 2 parts, 0.1 min") ||
		!strings.Contains(errOut, "Transcribed 3 records, kept as ley://records/job_") ||
		!strings.Contains(errOut, "Next: ley records --protocol speech --job-id job_") {
		t.Errorf("stderr:\n%s", errOut)
	}

	// Colour adds ink and changes no words.
	inked, inkedErr, err := runLey(t, sock, 80, true, "", "transcribe", transcribeID, "--yes")
	if err != nil {
		t.Fatal(err)
	}
	if ui.Strip(inked) != out || !strings.Contains(inked, "\x1b[") {
		t.Errorf("colour changed the words or added no ink:\n%s", inked)
	}
	if !strings.Contains(ui.Strip(inkedErr), "Transcribed 3 records") {
		t.Errorf("inked stderr:\n%s", inkedErr)
	}
}

// --json is the records, one DecodeRecord per line, with their part and over, and no ink.
func TestTranscribeJSON(t *testing.T) {
	t.Parallel()
	sock, _ := harness(t, transcribeOpts(t, false))
	out, _, err := runLey(t, sock, 80, true, "", "--json", "transcribe", transcribeID, "--yes")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out, "\x1b") {
		t.Errorf("--json carries ink: %q", out)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 3 {
		t.Fatalf("want 3 records, got:\n%s", out)
	}
	var first struct {
		Protocol string `json:"protocol"`
		ClipURI  string `json:"clipUri"`
		Over     int    `json:"over"`
		Fields   map[string]struct {
			Text string `json:"text"`
		} `json:"fields"`
	}
	if err := json.Unmarshal([]byte(lines[0]), &first); err != nil {
		t.Fatal(err)
	}
	if first.Protocol != "speech" || first.ClipURI != leyline.RecordingPartURI(transcribeID, 1) || first.Over != 1 || first.Fields["callsigns"].Text != "W6ABC" {
		t.Errorf("first record: %s", lines[0])
	}
}

// A decoder that sends audio away says where, and without its key the daemon's refusal and the
// command that fixes it reach the reader with exit 1.
func TestTranscribeNamesTheHostAndNeedsTheKey(t *testing.T) {
	t.Parallel()
	opts := transcribeOpts(t, false)
	opts.SpeechProvider, opts.SpeechHosts = "deepgram", []string{"api.deepgram.com"}
	sock, c := harness(t, opts)
	// A speech model chosen earlier is what a refused job leaves in place.
	if _, err := c.Credentials.SetFeatureModel(t.Context(), &leylinev1.FeatureModel{Feature: "speech", Provider: "deepgram", Model: "nova-2"}); err != nil {
		t.Fatal(err)
	}
	_, errOut, err := runLey(t, sock, 80, false, "", "transcribe", transcribeID, "--yes", "--model", "nova-3")
	if exitCode(err) != 1 || leyline.Code(err) != leyline.CodeCredentialMissing || !strings.Contains(err.Error(), "ley ai add deepgram") {
		t.Errorf("want CREDENTIAL_MISSING naming ley ai add deepgram, got exit %d: %v", exitCode(err), err)
	}
	if !strings.Contains(errOut, "with speech, model nova-3 (sends the audio to api.deepgram.com)") {
		t.Errorf("stderr does not say where the audio goes:\n%s", errOut)
	}
	speechModel := func() string {
		st, err := c.Credentials.GetAIState(t.Context(), &leylinev1.GetAIStateRequest{})
		if err != nil {
			t.Fatal(err)
		}
		for _, f := range st.GetFeatures() {
			if f.GetFeature() == "speech" {
				return f.GetModel()
			}
		}
		return ""
	}
	if m := speechModel(); m != "nova-2" {
		t.Errorf("a refused job left the speech model at %q, want nova-2 put back", m)
	}

	// With a key, --model becomes the speech model before the job starts, so its records carry it.
	if _, err := c.Credentials.SetCredential(t.Context(), &leylinev1.SetCredentialRequest{Provider: "deepgram", Secret: "dg-1234"}); err != nil {
		t.Fatal(err)
	}
	out, errOut, err := runLey(t, sock, 80, false, "", "--json", "transcribe", transcribeID, "--yes", "--model", "nova-3")
	if err != nil {
		t.Fatalf("%v\n%s", err, errOut)
	}
	if !strings.Contains(errOut, "with speech, model nova-3 (sends the audio to api.deepgram.com); the speech model is set to nova-3 for this and later jobs.") ||
		strings.Count(out, `"model":{"text":"nova-3"}`) != 3 {
		t.Errorf("--model: stderr\n%s\nstdout\n%s", errOut, out)
	}
	if m := speechModel(); m != "nova-3" {
		t.Errorf("the speech model is %q, want nova-3", m)
	}
}

// A refused job with --model and no speech model chosen before clears the choice again.
func TestTranscribeClearsTheModelItSetWhenRefused(t *testing.T) {
	t.Parallel()
	opts := transcribeOpts(t, false)
	opts.SpeechProvider = "deepgram"
	sock, c := harness(t, opts)
	_, _, err := runLey(t, sock, 80, false, "", "transcribe", transcribeID, "--yes", "--model", "nova-3")
	if leyline.Code(err) != leyline.CodeCredentialMissing {
		t.Fatalf("want CREDENTIAL_MISSING, got %v", err)
	}
	st, err := c.Credentials.GetAIState(t.Context(), &leylinev1.GetAIStateRequest{})
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range st.GetFeatures() {
		if f.GetFeature() == "speech" {
			t.Errorf("a refused job left a speech model: %v", f)
		}
	}
}

// A job that somebody else cancels is not a finished transcription: transcribe says so and exits 1.
func TestTranscribeReportsACancelledJob(t *testing.T) {
	t.Parallel()
	opts := transcribeOpts(t, false)
	var overs []fakedaemon.SeedOver
	for i := range int64(300) {
		overs = append(overs, fakedaemon.SeedOver{OpenMs: 600 + 2000*i, CloseMs: 1600 + 2000*i})
	}
	opts.Recordings[0].Parts = [][]fakedaemon.SeedOver{overs}
	sock, c := harness(t, opts)
	type result struct {
		out string
		err error
	}
	done := make(chan result, 1)
	go func() {
		out, _, err := runLey(t, sock, 80, false, "", "transcribe", transcribeID, "--yes")
		done <- result{out, err}
	}()
	deadline := time.Now().Add(5 * time.Second)
	cancelled := false
	for !cancelled && time.Now().Before(deadline) {
		jobs, err := c.ListJobs(t.Context())
		if err != nil {
			t.Fatal(err)
		}
		for _, j := range jobs {
			if j.GetDecode() != nil && j.GetState() == leylinev1.JobState_RUNNING {
				if _, err := c.Jobs.CancelJob(t.Context(), &leylinev1.JobRef{JobId: j.GetJobId()}); err != nil {
					t.Fatal(err)
				}
				cancelled = true
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !cancelled {
		t.Fatal("the transcription job never appeared")
	}
	r := <-done
	if exitCode(r.err) != 1 || !strings.Contains(r.err.Error(), "cancelled before it finished") || !strings.Contains(r.err.Error(), "ley records --protocol speech --job-id job_") {
		t.Errorf("want exit 1 saying it was cancelled, got exit %d: %v", exitCode(r.err), r.err)
	}
	if strings.Count(r.out, "\n") >= 300 {
		t.Errorf("the job was not stopped early:\n%d lines", strings.Count(r.out, "\n"))
	}
}

// The refusals that come before any question.
func TestTranscribeRefusals(t *testing.T) {
	t.Parallel()
	sock, _ := harness(t, transcribeOpts(t, false))
	for _, tc := range []struct {
		args []string
		code int
		says string
	}{
		{[]string{"transcribe", transcribeID, "--model", "big", "--yes"}, ExitUsage, "--model needs a decoder that calls a provider"},
		{[]string{"transcribe", transcribeID, "--engine", "aprs", "--yes"}, ExitUsage, "decodes a continuous stream, not overs"},
		{[]string{"transcribe", transcribeID, "--engine", "whisper", "--yes"}, 1, "ley decoders"},
		{[]string{"transcribe", leyline.RecordingPartURI(transcribeID, 2)}, ExitUsage, "give " + leyline.RecordingURI(transcribeID)},
		{[]string{"transcribe", "job_01NOSUCHNOSUCHNOSUCHNOSUCH", "--yes"}, 1, "no recording called"},
	} {
		_, _, err := runLey(t, sock, 80, false, "", tc.args...)
		if exitCode(err) != tc.code || err == nil || !strings.Contains(err.Error(), tc.says) {
			t.Errorf("ley %v: exit %d %v, want exit %d saying %q", tc.args, exitCode(err), err, tc.code, tc.says)
		}
	}
	// A recording with no gate lists no squelch openings and has nothing to transcribe.
	ungated := mustRun(t, sock, "--json", "record", "146.52", "--for", "300ms")
	var job struct {
		JobID string `json:"jobId"`
	}
	if err := json.Unmarshal([]byte(strings.Split(ungated, "\n")[0]), &job); err != nil {
		t.Fatal(err)
	}
	_, _, err := runLey(t, sock, 80, false, "", "transcribe", job.JobID, "--yes")
	if exitCode(err) != 1 || !strings.Contains(err.Error(), "lists no squelch openings") || !strings.Contains(err.Error(), "ley record 146.52 --gate squelch") {
		t.Errorf("an ungated recording: exit %d %v", exitCode(err), err)
	}
}

// A job that fails ends transcribe with exit 1 and the job's own reason.
func TestTranscribeReportsAFailedJob(t *testing.T) {
	t.Parallel()
	opts := transcribeOpts(t, false)
	sock, _ := harness(t, opts)
	// The minutes come from the manifest, so the question is asked; the job then cannot read the
	// part's sidecar.
	sidecars, err := filepath.Glob(filepath.Join(opts.RecordingsDir, transcribeID, "*_001.json"))
	if err != nil || len(sidecars) != 1 {
		t.Fatalf("sidecars: %v %v", sidecars, err)
	}
	if err := os.Remove(sidecars[0]); err != nil {
		t.Fatal(err)
	}
	_, errOut, err := runLey(t, sock, 80, false, "", "transcribe", transcribeID, "--yes")
	if exitCode(err) != 1 || !strings.Contains(err.Error(), "the recording could not be read") || !strings.Contains(err.Error(), "[INTERNAL]") {
		t.Errorf("want exit 1 with the job's reason, got exit %d: %v\n%s", exitCode(err), err, errOut)
	}
}
