// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// --gain on decode and watch is read as record's is, and a syntax error or a gain for a stored
// recording is a usage error before anything starts.
func TestDecodeGainFlagParsing(t *testing.T) {
	t.Parallel()
	sock, c := harness(t, fakedaemon.Options{})
	for _, args := range [][]string{
		{"decode", "aprs", "--gain", "loud"},
		{"decode", "aprs", "--gain", "-3"},
		{"watch", "aprs", "--gain", "LNA="},
		{"decode", "iqstat", "--recording", "job_01J", "--gain", "30"},
	} {
		_, _, err := run(t, t.Context(), sock, args...)
		if exitCode(err) != 2 || !strings.Contains(err.Error(), "--gain") {
			t.Errorf("ley %s: exit %d (%v), want a usage error about --gain", strings.Join(args, " "), exitCode(err), err)
		}
	}
	if jobs, _ := c.ListJobs(t.Context()); len(jobs) != 0 {
		t.Errorf("a refused --gain started a job: %v", jobs)
	}
	writes := gainWrites("lna=16,VGA=auto")
	if len(writes) != 2 || writes[0].GetElement() != "lna" || writes[0].GetDb() != 16 || !writes[1].GetAuto() {
		t.Errorf("stages go as typed, in order: %v", writes)
	}
}

// The gain reaches the daemon as DecodeConfig.gains, lands on the capture the job made, and a
// stage the radio does not have fails the job with the daemon's words.
func TestDecodeGainReachesTheRadio(t *testing.T) {
	t.Parallel()
	sock, c := harness(t, fakedaemon.Options{PresenceGrace: 100 * time.Millisecond})
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	if _, errOut, err := run(t, ctx, sock, "decode", "aprs", "--gain", "49.6", "--job", "--count", "1"); err != nil {
		t.Fatalf("ley decode --gain: %v\n%s", err, errOut)
	}
	jobs, err := c.ListJobs(ctx)
	if err != nil || len(jobs) != 1 {
		t.Fatalf("jobs: %v (%v)", jobs, err)
	}
	gains := jobs[0].GetDecode().GetGains()
	if len(gains) != 1 || gains[0].GetElement() != "" || gains[0].GetDb() != 49.6 {
		t.Errorf("the job's gains: %v", gains)
	}
	st, err := c.State(ctx)
	if err != nil || len(st.Captures) != 1 {
		t.Fatalf("state: %v", err)
	}
	if g := st.Captures[0].GetGains(); len(g) != 1 || g[0].GetAuto() || g[0].GetDb() != 49.6 {
		t.Errorf("the capture the job made is at %v, want TUNER 49.6 dB", g)
	}
	if _, err := c.Jobs.CancelJob(ctx, &leylinev1.JobRef{JobId: jobs[0].GetJobId()}); err != nil {
		t.Fatal(err)
	}

	_, _, err = run(t, ctx, sock, "decode", "aprs", "--gain", "LNA=0")
	if err == nil || !strings.Contains(err.Error(), "the gain asked for could not be set") ||
		!strings.Contains(err.Error(), "["+leyline.CodeGainElementUnknown+"]") {
		t.Errorf("a stage the radio lacks must end decode with the daemon's words: %v", err)
	}
}

// On a capture somebody else made the gain stays theirs, and the job says what it was left at.
func TestDecodeGainOnASharedCaptureIsLeftAlone(t *testing.T) {
	t.Parallel()
	sock, c := harness(t, fakedaemon.Options{PresenceGrace: 100 * time.Millisecond})
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	st, err := c.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	capture, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: st.Devices[0].DeviceId, CenterHz: 144_200_000})
	if err != nil {
		t.Fatal(err)
	}
	before := capture.GetGains()
	if _, _, err := run(t, ctx, sock, "watch", "aprs", "--gain", "49.6", "--take-over", "--detach"); err != nil {
		t.Fatalf("ley watch --gain: %v", err)
	}
	jobs, err := c.ListJobs(ctx)
	if err != nil || len(jobs) != 1 {
		t.Fatalf("jobs: %v (%v)", jobs, err)
	}
	if !strings.Contains(jobs[0].GetStatusDetail(), "gain left at the radio's") {
		t.Errorf("the job must say the gain it was left at: %q", jobs[0].GetStatusDetail())
	}
	if len(jobs[0].GetDecode().GetGains()) != 1 {
		t.Errorf("watch sends its --gain too: %v", jobs[0].GetDecode())
	}
	st, err = c.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	for _, cp := range st.Captures {
		if cp.GetCaptureId() == capture.GetCaptureId() && cp.GetGains()[0].GetDb() != before[0].GetDb() {
			t.Errorf("the shared capture's gain moved: %v, was %v", cp.GetGains(), before)
		}
	}
	_, _ = c.Jobs.CancelJob(ctx, &leylinev1.JobRef{JobId: jobs[0].GetJobId()})
}

// start_decode_job and watch take the gain the verbs do.
func TestMCPDecodeToolsTakeAGain(t *testing.T) {
	t.Parallel()
	h := newMCPHarness(t)
	if r := h.call(t, "start_decode_job", map[string]any{"decoder": "aprs", "gain": "loud"}); !r.IsError {
		t.Errorf("a gain that does not parse must be refused: %s", resultText(r))
	}
	res := h.must(t, "start_decode_job", map[string]any{"decoder": "aprs", "gain": "TUNER=40"})
	var job leylinev1.Job
	structured(t, res, &job)
	if g := job.GetDecode().GetGains(); len(g) != 1 || g[0].GetElement() != "TUNER" || g[0].GetDb() != 40 {
		t.Errorf("start_decode_job's gains: %v", g)
	}
	h.must(t, "cancel_job", map[string]any{"job": job.GetJobId()})
	res = h.must(t, "watch", map[string]any{"decoder": "aprs", "gain": "30"})
	structured(t, res, &job)
	if g := job.GetDecode().GetGains(); len(g) != 1 || g[0].GetDb() != 30 {
		t.Errorf("watch's gains: %v", g)
	}
	h.must(t, "cancel_job", map[string]any{"job": job.GetJobId()})
}
