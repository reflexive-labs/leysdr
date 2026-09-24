// SPDX-License-Identifier: Apache-2.0

package fakedaemon_test

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/fakedaemon"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// awaitJob polls a job until it leaves RUNNING.
func awaitJob(t *testing.T, c *leyline.Client, id string) *leylinev1.Job {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		j, err := c.Jobs.GetJob(t.Context(), &leylinev1.JobRef{JobId: id})
		if err != nil {
			t.Fatal(err)
		}
		if j.GetState() != leylinev1.JobState_RUNNING {
			return j
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("job %s never ended", id)
	return nil
}

func record(t *testing.T, c *leyline.Client, cfg *leylinev1.RecordConfig) *leylinev1.Job {
	t.Helper()
	job, err := c.StartRecord(t.Context(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	return job
}

// A part recorded while the capture's CaptureLevel is over the clipping floor carries
// clipped_ms; one recorded on a clean radio leaves the key out of the manifest.
func TestARecordingWhileClippingSaysForHowLong(t *testing.T) {
	dir := t.TempDir()
	var clean atomic.Bool
	c, _ := harness(t, fakedaemon.Options{RecordingsDir: dir, Clipping: func(string) (uint64, uint64, float64) {
		if !clean.Load() {
			return 600, 600_000, 0
		}
		return 0, 600_000, -12
	}})
	cfg := &leylinev1.RecordConfig{FrequencyHz: 146_520_000, Mode: leylinev1.DemodMode_NFM, DurationMs: 300}
	clipped := awaitJob(t, c, record(t, c, cfg).GetJobId())
	m, err := leyline.ReadRecordingManifest(filepath.Join(dir, clipped.GetJobId()))
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Parts) != 1 || m.Parts[0].ClippedMs < 250 {
		t.Fatalf("a part recorded at the rails says for how long: %+v", m.Parts)
	}
	clean.Store(true)
	cleanJob := awaitJob(t, c, record(t, c, cfg).GetJobId())
	raw, err := os.ReadFile(filepath.Join(dir, cleanJob.GetJobId(), "recording.json"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), `"clipped_ms"`) {
		t.Errorf("a clean part carries clipped_ms:\n%s", raw)
	}
}

// A gated recording whose squelch never opens writes no part: the fake discards it as the
// daemon does, the job ends COMPLETED saying nothing was heard, and the URI finds nothing.
func TestARecordingThatHeardNothingIsDiscarded(t *testing.T) {
	dir := t.TempDir()
	// The squelch opens an hour in: never, for a test.
	c, _ := harness(t, fakedaemon.Options{RecordingsDir: dir, RecordGateAt: []int64{3_600_000}})
	job := record(t, c, &leylinev1.RecordConfig{
		FrequencyHz: 146_520_000, Mode: leylinev1.DemodMode_NFM, Gate: leylinev1.RecordGate_SQUELCH,
	})
	time.Sleep(200 * time.Millisecond)
	done, err := c.Jobs.CancelJob(t.Context(), &leylinev1.JobRef{JobId: job.GetJobId()})
	if err != nil {
		t.Fatal(err)
	}
	if done.GetState() != leylinev1.JobState_COMPLETED || done.GetStatusDetail() != leyline.NothingHeard {
		t.Fatalf("the job must say nothing was heard: %v %q", done.GetState(), done.GetStatusDetail())
	}
	if _, err := os.Stat(filepath.Join(dir, job.GetJobId())); !os.IsNotExist(err) {
		t.Errorf("the directory is still there: %v", err)
	}
	if _, err := c.GetResource(t.Context(), leyline.RecordingURI(job.GetJobId())); leyline.Code(err) != leyline.CodeJobNotFound {
		t.Errorf("the discarded recording resolved: %v", err)
	}
	listed, err := c.ListRecordings(t.Context(), nil)
	if err != nil || len(listed) != 0 {
		t.Errorf("the listing has it: %v %v", err, listed)
	}
}

// Pausing holds the position and resuming moves it on, in the reply, in GetState and on the
// event; any client may pause, and a playback that does not exist is SINK_NOT_FOUND.
func TestPausingAPlaybackHoldsItsPosition(t *testing.T) {
	dir := t.TempDir()
	c, _ := harness(t, fakedaemon.Options{RecordingsDir: dir})
	job := awaitJob(t, c, record(t, c, &leylinev1.RecordConfig{
		FrequencyHz: 146_520_000, Mode: leylinev1.DemodMode_NFM, DurationMs: 2000,
	}).GetJobId())
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	events, _, err := c.Events(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	pb, err := c.StartPlayback(t.Context(), leyline.RecordingURI(job.GetJobId()), -1)
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(200 * time.Millisecond)
	paused, err := c.SetPlaybackPaused(t.Context(), pb.GetPlaybackId(), true)
	if err != nil {
		t.Fatal(err)
	}
	if !paused.GetPaused() || paused.GetPosition() == 0 {
		t.Fatalf("paused: %v at %d", paused.GetPaused(), paused.GetPosition())
	}
	time.Sleep(500 * time.Millisecond)
	st := mustState(t, c)
	if len(st.GetPlaybacks()) != 1 || st.GetPlaybacks()[0].GetPosition() != paused.GetPosition() || !st.GetPlaybacks()[0].GetPaused() {
		t.Fatalf("half a second paused moved it: %v", st.GetPlaybacks())
	}
	if _, err := c.SetPlaybackPaused(t.Context(), pb.GetPlaybackId(), false); err != nil {
		t.Fatal(err)
	}
	time.Sleep(300 * time.Millisecond)
	st = mustState(t, c)
	if len(st.GetPlaybacks()) != 1 || st.GetPlaybacks()[0].GetPosition() <= paused.GetPosition() {
		t.Fatalf("resuming did not move it on: %v", st.GetPlaybacks())
	}
	if moved := st.GetPlaybacks()[0].GetPosition() - paused.GetPosition(); moved > 48000*6/10 {
		t.Errorf("the pause was paid back as a jump of %d frames", moved)
	}
	sawPause := false
	for !sawPause {
		select {
		case ev := <-events:
			if p := ev.GetPlayback(); p.GetPlaybackId() == pb.GetPlaybackId() && p.GetPaused() {
				sawPause = true
			}
		case <-time.After(2 * time.Second):
			t.Fatal("no event carried the pause")
		}
	}
	if _, err := c.SetPlaybackPaused(t.Context(), "pb_nothing", true); leyline.Code(err) != leyline.CodeSinkNotFound {
		t.Errorf("a playback that does not exist: %v", err)
	}
}
