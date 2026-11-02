// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"fmt"
	"sort"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/session"
	"github.com/reflexive-labs/leysdr/go/internal/words"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// runDecodeRecording runs the decoder over a stored recording (DecodeConfig.source_uri) rather
// than a radio: an IQ decoder over an IQ recording, an audio decoder over an audio one. The daemon
// reads the parts faster than real time and the job ends on its own. Its records are kept, as a
// transcription's are, so every one of them is printed however fast they came, and 'ley records'
// reads them again.
func runDecodeRecording(ctx context.Context, s *verbSession, o decodeOptions) error {
	id, err := resolveRecordingID(ctx, s.Client, o.recording)
	if err != nil {
		return err
	}
	uri := leyline.RecordingURI(id)
	job, err := s.Client.StartDecode(ctx, &leylinev1.DecodeConfig{Decoder: o.decoder, SourceUri: uri, Keep: true})
	if err != nil {
		return decodeFailure(s, o, err)
	}
	from := uint64(0)
	sctx, stop := context.WithCancel(ctx)
	defer stop()
	recs, errs, err := s.Client.SubscribeRecords(sctx, leyline.RecordScopeJob(job.GetJobId(), &from))
	if err != nil {
		return err
	}
	s.say("decoding %s with %s. %s\n", uri, o.decoder, s.app.ErrStyle.Muted("Ctrl-C stops"))
	printed := map[uint64]bool{}
	show := func(rec *leylinev1.DecodeRecord) (bool, error) {
		if printed[rec.GetSeq()] {
			return false, nil
		}
		printed[rec.GetSeq()] = true
		if err := printRecord(s, rec); err != nil {
			return false, err
		}
		return o.count > 0 && len(printed) >= o.count, nil
	}
	poll := time.NewTicker(time.Second)
	defer poll.Stop()
	final := job
	for isLiveJob(final) {
		select {
		case <-ctx.Done():
			return decodeRecordingStopped(ctx, s, job, len(printed))
		case rec, ok := <-recs:
			if !ok {
				recs = nil
				continue
			}
			done, err := show(rec)
			if err != nil {
				return err
			}
			if done {
				return decodeRecordingStopped(ctx, s, job, len(printed))
			}
		case err := <-errs:
			if err != nil && ctx.Err() == nil {
				return err
			}
			errs = nil
		case <-poll.C:
			if j, err := s.Client.Jobs.GetJob(ctx, &leylinev1.JobRef{JobId: job.GetJobId()}); err == nil {
				final = j
			}
		}
	}
	stop()
	// The live stream may have dropped or not yet delivered the last records; the store has them all.
	page, err := s.Client.QueryRecords(ctx, &leylinev1.RecordQuery{JobId: job.GetJobId()})
	if err != nil {
		return err
	}
	rest := page.GetRecords()
	sort.Slice(rest, func(i, j int) bool { return rest[i].GetSeq() < rest[j].GetSeq() })
	for _, rec := range rest {
		if done, err := show(rec); err != nil || done {
			return err
		}
	}
	switch final.GetState() {
	case leylinev1.JobState_FAILED:
		return &ExitError{Code: 1, Message: recordFailureDetail(final)}
	case leylinev1.JobState_CANCELLED:
		return &ExitError{Code: 1, Message: fmt.Sprintf("the decode was cancelled before it finished; %s kept",
			words.Count(len(printed), "record"))}
	}
	s.say("%s. %s reads them again\n", final.GetStatusDetail(),
		s.app.ErrStyle.Cmd("ley records --job-id "+job.GetJobId()))
	return nil
}

// decodeRecordingStopped cancels a recording's decode that Ctrl-C or --count ended early: the
// job would otherwise read the rest of the recording for nobody.
func decodeRecordingStopped(ctx context.Context, s *verbSession, job *leylinev1.Job, n int) error {
	cctx, cancel := session.CleanupContext(ctx, confirmTimeout)
	defer cancel()
	st := s.app.ErrStyle
	if _, err := s.Client.Jobs.CancelJob(cctx, &leylinev1.JobRef{JobId: job.GetJobId()}); err != nil {
		s.say("the job is still running: %s stops it\n", st.Cmd("ley jobs cancel "+job.GetJobId()))
		return nil
	}
	s.say("Stopped; %s kept: %s\n", words.Count(n, "record"), st.Cmd("ley records --job-id "+job.GetJobId()))
	return nil
}
