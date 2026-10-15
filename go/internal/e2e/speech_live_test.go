// SPDX-License-Identifier: Apache-2.0

package e2e

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// Live speech end to end (docs/plans/ai-features.md, AI-7): the real daemon plays the keyed
// fixture on a loop, the real leydec-speech with its scripted engine names each over, and the
// daemon records the overs as clips under the job's id. The clips are transcribed again and give
// the same parts and overs; a watch for a word fires its webhook on the over that says it and on
// no other; and a kept watch comes back after a daemon restart as the same job, writing new parts
// to the same recording.

// speechLiveFreq is where the keyed fixture's carrier is, as transcribe_test.go records it.
const speechLiveFreq = "146.62"

func TestLiveSpeechAgainstRealDaemon(t *testing.T) {
	decoders := os.Getenv("LEYLINE_DECODERS")
	if decoders == "" {
		t.Skip("set LEYLINE_DECODERS to the repository's decoders/ directory (make e2e does)")
	}
	fixture, err := filepath.Abs("../../../fixtures/nfm_keyed.cf32")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(fixture); err != nil {
		t.Skipf("fixture missing (%v); run `go run ./cmd/leyfix generate --out ../../../fixtures`", err)
	}
	r := newSpeechLiveRig(t, decoders)
	r.attachLooping(fixture)

	jobID, live := r.decodeLive(t)
	t.Run("the clips are a recording with parts", func(t *testing.T) { r.checkClipsListed(t, jobID) })
	t.Run("transcribing the clips gives the same overs", func(t *testing.T) { r.checkRetranscribed(t, jobID, live) })
	t.Run("a watch fires on its word and survives a restart", func(t *testing.T) { r.checkWatchAndRestart(t, fixture) })
}

func newSpeechLiveRig(t *testing.T, decoders string) *aiRig {
	t.Helper()
	dir := t.TempDir()
	script := filepath.Join(dir, "script.txt")
	if err := os.WriteFile(script, []byte(strings.Join(speechScript, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// The daemon's environment is the plugin's, so the scripted engine finds its words.
	t.Setenv("LEYDEC_SPEECH_SCRIPT", script)
	r := &aiRig{
		t: t, dir: dir, data: filepath.Join(dir, "data"), store: filepath.Join(dir, "store"),
		logFile: filepath.Join(dir, "leylined.log"), workerBin: filepath.Join(dir, "ley"),
	}
	r.daemonArgs = []string{
		"--no-hardware", "--data", r.data, "--store", r.store, "--ley", r.workerBin, "--log-file", r.logFile,
		"--recordings", filepath.Join(dir, "recordings"), "--decoders", decoders,
	}
	t.Cleanup(func() {
		if t.Failed() {
			b, _ := os.ReadFile(r.logFile)
			t.Logf("leylined log file:\n%s\nley transcript:\n%s", b, r.transcript.String())
		}
	})
	r.useWorker("accepted")
	r.start()
	return r
}

// attachLooping makes the fixture an idle radio that plays from its start whenever a job opens a
// capture on it. A file device goes with the daemon, so a restarted daemon needs it again.
func (r *aiRig) attachLooping(fixture string) {
	r.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	c, err := leyline.Dial(ctx, r.socket, leyline.WithLabel("e2e"))
	if err != nil {
		r.t.Fatal(err)
	}
	defer c.Close()
	if _, err := c.Control.AttachFileDevice(ctx, &leylinev1.AttachFileDeviceRequest{Path: fixture, Loop: true}); err != nil {
		r.t.Fatalf("AttachFileDevice: %v", err)
	}
}

// decodeLive runs `ley decode speech --job --json` for three overs, then cancels the kept job and
// returns its id and every record it kept, in time order.
func (r *aiRig) decodeLive(t *testing.T) (string, []*leylinev1.DecodeRecord) {
	t.Helper()
	out, errOut, code := r.callWithin(60*time.Second, "decode", "speech", "--freq", speechLiveFreq, "--job", "--json", "--count", "3")
	if code != 0 {
		t.Fatalf("ley decode speech: exit %d\n%s\n%s", code, out, errOut)
	}
	var printed []*leylinev1.DecodeRecord
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		rec := &leylinev1.DecodeRecord{}
		unmarshalProto(t, line, rec)
		printed = append(printed, rec)
	}
	if len(printed) != 3 {
		t.Fatalf("want three records, got %d:\n%s", len(printed), out)
	}
	jobID := printed[0].GetJobId()
	if !strings.Contains(errOut, "The overs are recorded as ley://recordings/"+jobID+".") {
		t.Errorf("the banner does not say where the clips are:\n%s", errOut)
	}
	for i, rec := range printed {
		if got := rec.GetFields()["text"].GetText(); got != speechScript[i] {
			t.Errorf("record %d: text %q, want the script's %q", i, got, speechScript[i])
		}
		if !strings.HasPrefix(rec.GetClipUri(), leyline.RecordingURI(jobID)+"/") || rec.GetOver() < 1 {
			t.Errorf("record %d: clip %q over %d, want a part of %s and an over from 1", i, rec.GetClipUri(), rec.GetOver(), jobID)
		}
	}
	r.mustLey("", "jobs", "cancel", jobID)
	stored, _ := r.mustLey("", "records", "--job-id", jobID, "--json")
	var page leylinev1.RecordPage
	unmarshalProto(t, stored, &page)
	kept := page.GetRecords()
	sortBySample(kept)
	if len(kept) < len(printed) {
		t.Fatalf("the store holds %d records, ley printed %d", len(kept), len(printed))
	}
	return jobID, kept
}

// checkClipsListed: ley recordings lists the job's clips, and the manifest has closed parts.
func (r *aiRig) checkClipsListed(t *testing.T, jobID string) {
	listed, _ := r.mustLey("", "recordings", "--json")
	if !strings.Contains(listed, leyline.RecordingURI(jobID)) {
		t.Errorf("ley recordings --json does not list %s:\n%s", jobID, listed)
	}
	shown, _ := r.mustLey("", "recordings", "show", jobID, "--json")
	m := parseJSON(t, shown)
	if parts := list(m, "parts"); len(parts) == 0 || m["ended_by"] != "cancelled" {
		t.Errorf("the clips' manifest: %d parts, ended_by %v, want parts and cancelled:\n%s", len(parts), m["ended_by"], shown)
	}
}

// checkRetranscribed: `ley transcribe` over the clips cuts the same segments the live job did, so
// every live record's part and over, and its words, come back in the same order. The stored cut
// may hold one segment more at the end: an over the cancel cut short, which the live job never
// finished.
func (r *aiRig) checkRetranscribed(t *testing.T, jobID string, live []*leylinev1.DecodeRecord) {
	out, errOut, code := r.callWithin(30*time.Second, "transcribe", jobID, "--yes", "--json")
	if code != 0 {
		t.Fatalf("ley transcribe %s: exit %d\n%s", jobID, code, errOut)
	}
	var again []*leylinev1.DecodeRecord
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		rec := &leylinev1.DecodeRecord{}
		unmarshalProto(t, line, rec)
		again = append(again, rec)
	}
	sortBySample(again)
	t.Logf("live: %d records, the first %s over %d; transcribed again: %d", len(live), live[0].GetClipUri(), live[0].GetOver(), len(again))
	if len(again) < len(live) || len(again) > len(live)+1 {
		t.Fatalf("transcribing the clips gave %d records, the live job %d", len(again), len(live))
	}
	for i, rec := range live {
		got, want := again[i], rec
		if got.GetClipUri() != want.GetClipUri() || got.GetOver() != want.GetOver() {
			t.Errorf("segment %d: transcribed as %s over %d, live as %s over %d",
				i, got.GetClipUri(), got.GetOver(), want.GetClipUri(), want.GetOver())
		}
		if got.GetFields()["text"].GetText() != want.GetFields()["text"].GetText() {
			t.Errorf("segment %d: transcribed %q, live %q", i, got.GetFields()["text"].GetText(), want.GetFields()["text"].GetText())
		}
	}
}

// webhookHits collects what the daemon POSTs.
type webhookHits struct {
	mu     sync.Mutex
	bodies []string
}

func (h *webhookHits) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	b, _ := io.ReadAll(req.Body)
	h.mu.Lock()
	h.bodies = append(h.bodies, string(b))
	h.mu.Unlock()
	w.WriteHeader(http.StatusNoContent)
}

func (h *webhookHits) snapshot() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]string(nil), h.bodies...)
}

// waitFor polls until the webhook has had n bodies, or fails.
func (h *webhookHits) waitFor(t *testing.T, n int, within time.Duration) []string {
	t.Helper()
	deadline := time.Now().Add(within)
	for {
		if got := h.snapshot(); len(got) >= n {
			return got
		}
		if time.Now().After(deadline) {
			t.Fatalf("the webhook had %d calls in %v, want %d: %v", len(h.snapshot()), within, n, h.snapshot())
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// checkWatchAndRestart: a detached watch for "bravo" fires its webhook on the over that says
// "bravo two" and on no other; the daemon restarts, the watch comes back as the same running job
// writing new parts to the same clips, and fires again.
func (r *aiRig) checkWatchAndRestart(t *testing.T, fixture string) {
	hits := &webhookHits{}
	server := httptest.NewServer(hits)
	defer server.Close()
	_, errOut, code := r.callWithin(30*time.Second, "watch", "speech", "--freq", speechLiveFreq,
		"--where", "text~bravo", "--notify=webhook:"+server.URL, "--detach")
	if code != 0 {
		t.Fatalf("ley watch speech --detach: exit %d\n%s", code, errOut)
	}
	jobID := r.runningSpeechJob(t)
	hits.waitFor(t, 1, 30*time.Second)
	// Past the next over, which says "charlie three" and must not fire.
	time.Sleep(6 * time.Second)
	bodies := hits.snapshot()
	for _, b := range bodies {
		if !strings.Contains(b, "bravo two") || strings.Contains(b, "alpha one") {
			t.Errorf("the webhook fired on a record that does not say bravo: %s", b)
		}
	}
	if len(bodies) != 1 {
		t.Errorf("the webhook fired %d times, want once for the one bravo over", len(bodies))
	}
	before := r.clipFiles(t, jobID)

	r.restart()
	r.attachLooping(fixture)
	deadline := time.Now().Add(30 * time.Second)
	for {
		out, _ := r.mustLey("", "jobs", "--json")
		var jobs leylinev1.ListJobsResponse
		unmarshalProto(t, out, &jobs)
		back := false
		for _, j := range jobs.GetJobs() {
			if j.GetJobId() == jobID && j.GetState() == leylinev1.JobState_RUNNING {
				back = true
			}
		}
		if back {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the kept watch %s is not RUNNING after the restart: %s", jobID, out)
		}
		time.Sleep(200 * time.Millisecond)
	}
	// The resumed plugin starts its script again, so the over that says "bravo two" comes round.
	hits.waitFor(t, 2, 40*time.Second)
	for {
		if after := r.clipFiles(t, jobID); len(after) > len(before) {
			break
		}
		if time.Now().After(deadline.Add(20 * time.Second)) {
			t.Fatalf("no new part in %s's clips after the restart: still %v", jobID, before)
		}
		time.Sleep(200 * time.Millisecond)
	}
	t.Logf("webhook calls: %d; clip files %d before the restart, %d after", len(hits.snapshot()), len(before), len(r.clipFiles(t, jobID)))
	r.mustLey("", "jobs", "cancel", jobID)
}

// runningSpeechJob is the one running decode job's id.
func (r *aiRig) runningSpeechJob(t *testing.T) string {
	t.Helper()
	out, _ := r.mustLey("", "jobs", "--json")
	var jobs leylinev1.ListJobsResponse
	unmarshalProto(t, out, &jobs)
	for _, j := range jobs.GetJobs() {
		if j.GetDecode() != nil && j.GetState() == leylinev1.JobState_RUNNING {
			if !j.GetDecode().GetKeep() {
				t.Errorf("a detached watch is not kept: %v", j)
			}
			return j.GetJobId()
		}
	}
	t.Fatalf("no running decode job: %s", out)
	return ""
}

// clipFiles is the part files in the job's clips directory, open ones included.
func (r *aiRig) clipFiles(t *testing.T, jobID string) []string {
	t.Helper()
	files, err := filepath.Glob(filepath.Join(r.dir, "recordings", jobID, "*.wav"))
	if err != nil {
		t.Fatal(err)
	}
	return files
}
