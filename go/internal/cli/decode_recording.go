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
	// The job's end arrives on the event stream the session already holds; a GetJob poll takes
	// over only if that stream ends.
	events := s.Events()
	var poll <-chan time.Time
	final := job
	for isLiveJob(final) {
		select {
		case ev, ok := <-events:
			if !ok {
				events = nil
				ticker := time.NewTicker(time.Second)
				defer ticker.Stop()
				poll = ticker.C
				continue
			}
			if b, isJob := ev.Body.(*leylinev1.Event_Job); isJob && b.Job.GetJobId() == job.GetJobId() {
				final = b.Job
				continue
			}
			s.Apply(ev)
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
		case <-poll:
			j, err := s.Client.Jobs.GetJob(ctx, &leylinev1.JobRef{JobId: job.GetJobId()})
			if err != nil {
				if ctx.Err() != nil {
					return decodeRecordingStopped(ctx, s, job, len(printed))
				}
				return err
			}
			final = j
		}
	}
	stop()
	// The live stream may have dropped or not yet delivered the last records; the store has them all.
	rest, err := jobRecords(ctx, s.Client.QueryRecords, job.GetJobId())
	if err != nil {
		return err
	}
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
// job would otherwise read the rest of the recording for nobody. A cancel that fails is an error,
// with the command that stops the job.
func decodeRecordingStopped(ctx context.Context, s *verbSession, job *leylinev1.Job, n int) error {
	cctx, cancel := session.CleanupContext(ctx, confirmTimeout)
	defer cancel()
	st := s.app.ErrStyle
	if _, err := s.Client.Jobs.CancelJob(cctx, &leylinev1.JobRef{JobId: job.GetJobId()}); err != nil {
		return &ExitError{Code: 1, Err: err, Message: fmt.Sprintf("could not stop the decode (%s), so it may still be running; %s stops it",
			leylineMessage(err, err.Error()), "ley jobs cancel "+job.GetJobId())}
	}
	s.say("Stopped; %s kept: %s\n", words.Count(n, "record"), st.Cmd("ley records --job-id "+job.GetJobId()))
	return nil
}

// recordPageSize is how many records each QueryRecords asks for while reading a job's back.
const recordPageSize = 1000

// jobRecords reads every record a kept job has in the store, oldest first. The store answers
// newest first and cuts at the limit, with no cursor, so each further page asks for the records no
// newer than the oldest so far, plus a millisecond for the two sides' rounding of the anchor
// (until_ns is inclusive), and drops the seqs already read. A page with nothing new, which only
// many records at one instant can cause, asks again for twice as many.
func jobRecords(ctx context.Context, query func(context.Context, *leylinev1.RecordQuery) (*leylinev1.RecordPage, error), jobID string) ([]*leylinev1.DecodeRecord, error) {
	q := &leylinev1.RecordQuery{JobId: jobID, Limit: recordPageSize}
	seen := map[uint64]bool{}
	var out []*leylinev1.DecodeRecord
	for {
		page, err := query(ctx, q)
		if err != nil {
			return nil, err
		}
		fresh := 0
		var oldest time.Time
		for _, rec := range page.GetRecords() {
			if at, ok := leyline.RecordWallTime(rec, page.GetAnchors()); ok && (oldest.IsZero() || at.Before(oldest)) {
				oldest = at
			}
			if seen[rec.GetSeq()] {
				continue
			}
			seen[rec.GetSeq()] = true
			out = append(out, rec)
			fresh++
		}
		if !page.GetTruncated() {
			break
		}
		switch {
		case fresh > 0 && !oldest.IsZero():
			q.UntilNs = oldest.Add(time.Millisecond).UnixNano()
		case q.GetLimit() < 1<<30:
			q.Limit *= 2
		default:
			return nil, fmt.Errorf("the store keeps answering %d records for job %s without the rest", q.GetLimit(), jobID)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].GetSeq() < out[j].GetSeq() })
	return out, nil
}
