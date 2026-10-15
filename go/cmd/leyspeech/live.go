// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bufio"
	"context"
	"fmt"
	"math"
	"os"
	"slices"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
	"github.com/reflexive-labs/leysdr/go/pkg/wer"
)

// latency is the delay from each over's squelch close to its record reaching leyspeech.
type latency struct {
	// HangMs is how long the daemon waits after the close before it ends the segment, which is
	// inside every delay: no engine can start on an over before then.
	HangMs        uint32        `json:"hang_ms"`
	Overs         []overLatency `json:"overs"`
	MedianSeconds float64       `json:"median_seconds"`
	P90Seconds    float64       `json:"p90_seconds"`
	MaxSeconds    float64       `json:"max_seconds"`
	// Unplaced is records whose over leyspeech could not find in the recording's sidecars, so
	// their delay is not counted.
	Unplaced int `json:"unplaced,omitempty"`
}

type overLatency struct {
	Over    string  `json:"over"`
	Text    string  `json:"text"`
	Seconds float64 `json:"seconds"`
}

// arrival is one record and when its line reached leyspeech.
type arrival struct {
	rec *leylinev1.DecodeRecord
	at  time.Time
}

// liveJobSettle bounds how long leyspeech waits for a cancelled live job's recording to close.
const liveJobSettle = 15 * time.Second

// live runs `ley decode <engine> --freq F --job --json` for d, stamping each record as it
// arrives, then cancels the job and reads the over's close from the recording the job kept of
// its overs. The delay runs from the squelch close (on the capture's clock, through the anchor)
// to the arrival (on this machine's), so it holds the hang, the engine's time and the trip back.
func (s *session) live(ctx context.Context, freq string, e engineSpec, d time.Duration) (*result, error) {
	dec, err := s.decoder(ctx, e.name)
	if err != nil {
		return nil, err
	}
	restore, err := s.keepSpeechModel(ctx, e.model)
	if err != nil {
		return nil, err
	}
	defer restore()
	if e.model != "" {
		fm := &leylinev1.FeatureModel{Feature: "speech", Provider: dec.GetCredentialProvider(), Model: e.model}
		if _, err := s.client.Credentials.SetFeatureModel(ctx, fm); err != nil {
			return nil, err
		}
	}
	before, err := s.jobIDs(ctx)
	if err != nil {
		return nil, err
	}
	arrivals, decodeErr := s.decodeFor(ctx, dec.GetName(), freq, d)
	// The job is kept (--job), so it outlives ley: it is cancelled here on every path, a failed
	// decode and Ctrl-C included, or it would run on in the owner's daemon holding the radio.
	jobID, err := s.endNewJob(ctx, before, arrivals, func(j *leylinev1.Job) bool {
		return j.GetDecode().GetDecoder() == dec.GetName()
	})
	switch {
	case decodeErr != nil:
		return nil, decodeErr
	case err != nil:
		return nil, err
	case jobID == "":
		return nil, fmt.Errorf("ley decode %s started no job leyspeech can find; 'ley jobs' lists what is running", dec.GetName())
	}
	res := &result{Engine: dec.GetName(), Model: e.model, Recording: jobID, JobID: jobID, Records: len(arrivals), WallSeconds: d.Seconds()}
	_, hangMs := segmentRule(dec)
	res.Latency = &latency{HangMs: hangMs}
	if len(arrivals) == 0 {
		return res, nil
	}
	rec, err := s.closedRecording(ctx, jobID)
	if err != nil {
		return nil, err
	}
	recs := make([]*leylinev1.DecodeRecord, len(arrivals))
	for i, a := range arrivals {
		recs[i] = a.rec
	}
	measured, err := s.measure(ctx, rec, dec, e, jobID, recs)
	if err != nil {
		return nil, err
	}
	measured.WallSeconds, measured.Latency = res.WallSeconds, res.Latency
	placeArrivals(measured.Latency, rec, dec, arrivals)
	return measured, nil
}

// decodeFor runs ley decode for d, or until ctx ends, and returns every record with its arrival.
// It stops ley with an interrupt, as a person would, and with --job ley leaves the job for the
// caller to cancel once the records are in.
func (s *session) decodeFor(ctx context.Context, decoder, freq string, d time.Duration) ([]arrival, error) {
	runCtx, stop := context.WithTimeout(ctx, d)
	defer stop()
	cmd := s.ley.command(runCtx, "decode", decoder, "--freq", freq, "--job", "--json")
	cmd.Cancel = func() error { return cmd.Process.Signal(os.Interrupt) }
	cmd.WaitDelay = 10 * time.Second
	cmd.Stderr = s.stderr
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	var arrivals []arrival
	sc := bufio.NewScanner(out)
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		at := time.Now()
		if len(sc.Bytes()) == 0 {
			continue
		}
		rec, err := parseRecord(sc.Bytes())
		if err != nil {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
			return nil, err
		}
		arrivals = append(arrivals, arrival{rec: rec, at: at})
	}
	err = cmd.Wait()
	if runCtx.Err() == nil && err != nil {
		// ley ended before the time was up: it refused, or the job failed.
		return nil, fmt.Errorf("ley decode %s --freq %s: %w", decoder, freq, err)
	}
	return arrivals, nil
}

// jobIDs is every job the daemon lists now.
func (s *session) jobIDs(ctx context.Context) (map[string]bool, error) {
	resp, err := s.client.Jobs.ListJobs(ctx, &leylinev1.ListJobsRequest{})
	if err != nil {
		return nil, err
	}
	ids := map[string]bool{}
	for _, j := range resp.GetJobs() {
		ids[j.GetJobId()] = true
	}
	return ids, nil
}

// jobCleanup bounds the lookups and the cancel that end a run's job, which run after ctx may
// have ended (Ctrl-C).
const jobCleanup = 5 * time.Second

// endNewJob finds the job ley started, from its first record or else as the job matching it that
// was not in before, and cancels it if it is still running. It returns the job's id, or "" when
// ley started none.
func (s *session) endNewJob(ctx context.Context, before map[string]bool, arrivals []arrival, match func(*leylinev1.Job) bool) (string, error) {
	cctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), jobCleanup)
	defer cancel()
	jobID := ""
	if len(arrivals) > 0 {
		jobID = arrivals[0].rec.GetJobId()
	} else {
		var err error
		if jobID, err = s.newJob(cctx, before, match); err != nil || jobID == "" {
			return "", err
		}
	}
	if _, err := s.client.Jobs.CancelJob(cctx, &leylinev1.JobRef{JobId: jobID}); err != nil && leyline.Code(err) != leyline.CodeJobNotFound {
		// A job that has ended already refuses a cancel; ask for it and only report one still
		// running.
		if j, gerr := s.client.Jobs.GetJob(cctx, &leylinev1.JobRef{JobId: jobID}); gerr != nil || j.GetState() == leylinev1.JobState_RUNNING {
			return jobID, fmt.Errorf("%s is still running and leyspeech could not cancel it (%w); 'ley jobs cancel %s' stops it", jobID, err, jobID)
		}
	}
	return jobID, nil
}

// newJob is the job that matches and was not in before: the one ley started. "" when none is.
func (s *session) newJob(ctx context.Context, before map[string]bool, match func(*leylinev1.Job) bool) (string, error) {
	resp, err := s.client.Jobs.ListJobs(ctx, &leylinev1.ListJobsRequest{})
	if err != nil {
		return "", err
	}
	for _, j := range resp.GetJobs() {
		if !before[j.GetJobId()] && match(j) {
			return j.GetJobId(), nil
		}
	}
	return "", nil
}

// closedRecording waits for the recording a cancelled live job kept of its overs to close, and
// reads it.
func (s *session) closedRecording(ctx context.Context, jobID string) (*recording, error) {
	deadline := time.Now().Add(liveJobSettle)
	for {
		dir, err := s.client.ResolveLocalPath(ctx, leyline.RecordingURI(jobID))
		if err == nil {
			if m, merr := leyline.ReadRecordingManifest(dir); merr == nil && m.EndedBy != "" {
				return readRecording(dir)
			}
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("the recording of %s's overs did not close within %s after the job was cancelled", jobID, liveJobSettle)
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(200 * time.Millisecond):
		}
	}
}

// placeArrivals finds each record's segment in the recording and its last squelch close, and
// fills in the delays and their median, 90th percentile and maximum.
func placeArrivals(l *latency, rec *recording, dec *leylinev1.DecoderManifest, arrivals []arrival) {
	spans := map[wer.Key]overSpan{}
	for _, s := range rec.overs(segmentRule(dec)) {
		spans[s.key] = s
	}
	var delays []float64
	for _, a := range arrivals {
		k, ok := recordKey(a.rec)
		span, found := spans[k]
		if !ok || !found {
			l.Unplaced++
			continue
		}
		closed, ok := span.part.wallTime(span.closeAt)
		if !ok {
			l.Unplaced++
			continue
		}
		secs := a.at.Sub(closed).Seconds()
		l.Overs = append(l.Overs, overLatency{Over: k.String(), Text: a.rec.GetFields()["text"].GetText(), Seconds: secs})
		delays = append(delays, secs)
	}
	if len(delays) == 0 {
		return
	}
	slices.Sort(delays)
	l.MedianSeconds = percentile(delays, 0.5)
	l.P90Seconds = percentile(delays, 0.9)
	l.MaxSeconds = delays[len(delays)-1]
}

// percentile is the nearest-rank percentile of sorted values.
func percentile(sorted []float64, p float64) float64 {
	i := int(math.Ceil(p*float64(len(sorted)))) - 1
	return sorted[min(max(i, 0), len(sorted)-1)]
}
