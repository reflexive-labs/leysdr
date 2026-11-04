// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/session"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
	"github.com/reflexive-labs/leysdr/go/pkg/records"
	"github.com/reflexive-labs/leysdr/go/pkg/units"
)

type decodeOptions struct {
	decoder  string
	freqHz   uint64
	device   string
	deviceID string
	takeOver bool
	keep     bool
	count    int
	// gain is --gain as typed: stages for a radio the decoder has to itself, over the recipe's.
	gain string
	// recording is --recording: a stored recording to decode instead of a radio.
	recording string
	// dryRun is --dry-run: say where the job would go and start nothing.
	dryRun bool
}

func newDecodeCommand(app *App) *cobra.Command {
	var (
		o    decodeOptions
		freq string
	)
	cmd := &cobra.Command{
		Use:   "decode <decoder>",
		Short: "Run a decoder and print what it hears",
		Long: `decode runs one of the daemon's decoders ('ley decoders' lists them) and
prints a line for every packet it decodes: the time, who sent it, what kind
of record it is, and what it said.

The decoder's recipe carries the frequency, the mode and the bandwidth, so
decode needs no tune flags: 'ley decode aprs' tunes 144.390 MHz NFM because
that is where APRS lives in North America. --freq puts it somewhere else,
which is what a region with another allocation needs.

A decoder with no frequency of its own, such as speech, needs --freq to say
where to listen. A speech decoder hears overs: the daemon cuts the channel's
audio at the squelch, records it as a gated recording under the job's id
(ley://recordings/<job>), and each line gives the words with the part and over
of that recording that hold them. The recording is kept with --job and goes
when an unkept job ends.

The daemon finds a capture that already covers the frequency, or makes one on
an idle radio, or says who has the radio instead; --take-over insists. A
decoder may fix the gain in its recipe (ADS-B's is 40 dB), and --gain sets
another; either is set only on a radio the job tunes and is put back when it
ends. On a capture somebody else made, the gain stays theirs and the job's
status says what it was left at. All of
the decoding happens in the daemon, so an agent or a script reading --json
sees exactly what the terminal shows.

Ctrl-C stops the job and hands the radio back. With --job the job stays
running after ley exits and its records become a resource 'ley records'
reads; 'ley jobs cancel' is how to stop one.

--recording decodes a stored recording instead of the radio, faster than real
time, and stops when it has read every part: an IQ decoder reads an IQ
recording (ley record --iq) and any other decoder an audio one. Its records
are kept, so 'ley records --job-id <job>' reads them again.

--dry-run asks the daemon where the job would go and prints it in a
sentence: the capture it would share, the radio it would open, or the radio
it would retune and whose channels that would pause. It starts nothing, and
exits 1 with the reason when the job would be declined.

--json prints one DecodeRecord per line (NDJSON) and nothing else on stdout;
with --dry-run, the CapturePlan.`,
		Example: `  ley decode aprs                         # what is on 144.390 MHz?
  ley decode aprs --count 5               # five packets, then stop
  ley decode aprs --freq 144.8            # the European allocation
  ley decode aprs --job                   # keep decoding after ley exits
  ley decode adsb --gain 49.6             # more than the recipe's 40 dB
  ley decode speech --freq 146.94 --job   # transcribe a repeater all day
  ley decode iqstat --recording job_01J...  # an IQ decoder over an IQ recording
  ley decode aprs --json | jq -r .deviceId`,
		GroupID: GroupLooking,
		Args:    cobra.ExactArgs(1),
		ValidArgsFunction: func(_ *cobra.Command, args []string, toComplete string) ([]cobra.Completion, cobra.ShellCompDirective) {
			if len(args) != 0 {
				return nil, cobra.ShellCompDirectiveNoFileComp
			}
			return completeDecoders(app, toComplete)
		},
		RunE: func(cmd *cobra.Command, args []string) error {
			o.decoder = args[0]
			if o.recording != "" && o.dryRun {
				return usageErrorf("--dry-run says where on a radio the job would go, and --recording needs no radio")
			}
			if o.recording != "" && (freq != "" || o.device != "" || o.takeOver || o.keep) {
				return usageErrorf("--recording decodes a stored recording, so --freq, --device, --take-over and --job do not apply; its records are kept anyway")
			}
			if err := checkDecodeGain(o.gain, o.recording); err != nil {
				return err
			}
			if freq != "" {
				hz, err := units.ParseFrequency(freq)
				if err != nil {
					return usageErrorf("--freq %v", err)
				}
				o.freqHz = hz
			}
			s, err := openSession(cmd.Context(), app)
			if err != nil {
				return err
			}
			defer s.Close()
			if o.device != "" {
				d, derr := pickDevice(s.State, o.device)
				if derr != nil {
					return derr
				}
				o.deviceID = d.DeviceId
			}
			// Every line decode prints for a person is stderr; stdout carries the records.
			s.proseToStderr = true
			return runDecode(cmd.Context(), s, o)
		},
	}
	cmd.Flags().StringVar(&freq, "freq", "", "decode somewhere other than the recipe's frequency, e.g. 144.8 (a bare number is MHz)")
	cmd.Flags().StringVar(&o.device, "device", "", "which radio: an id (dev_...), id prefix or row number from 'ley devices' (default: the first real radio)")
	cmd.Flags().BoolVar(&o.takeOver, "take-over", false, "decode even when somebody is using the radio; it is theirs again afterwards")
	cmd.Flags().StringVar(&o.gain, "gain", "", gainHelp+"; "+decodeGainNote)
	cmd.Flags().BoolVar(&o.keep, "job", false, "keep the job and its records after ley exits ('ley jobs cancel' stops it)")
	cmd.Flags().IntVar(&o.count, "count", 0, "stop after this many records, e.g. 5 (default: until Ctrl-C)")
	cmd.Flags().StringVar(&o.recording, "recording", "", "decode a stored recording instead of the radio: a job id, id prefix or ley://recordings/ URI")
	cmd.Flags().BoolVar(&o.dryRun, "dry-run", false, "say which radio the job would use and what it would pause, and start nothing")
	return cmd
}

// runDecode starts the job, subscribes from the beginning of its records and prints them until
// --count, Ctrl-C or the end of the stream.
func runDecode(ctx context.Context, s *verbSession, o decodeOptions) error {
	// A friendly name (vessels -> ais) becomes the canonical decoder before anything starts, so the
	// job, the records and the banner all use the canonical name.
	if name, _, err := s.Client.ResolveDecoder(ctx, o.decoder); err == nil {
		o.decoder = name
	}
	if o.recording != "" {
		return runDecodeRecording(ctx, s, o)
	}
	if err := requireFrequency(ctx, s, o.decoder, o.freqHz); err != nil {
		return err
	}
	s.displays = decoderDisplays(ctx, s.Client)
	cfg := &leylinev1.DecodeConfig{
		Decoder:     o.decoder,
		FrequencyHz: o.freqHz,
		DeviceId:    o.deviceID,
		TakeOver:    o.takeOver,
		Keep:        o.keep,
		Gains:       gainWrites(o.gain),
	}
	if o.dryRun {
		if err := s.dryRun(ctx, &leylinev1.PlanRequest{Request: &leylinev1.PlanRequest_Decode{Decode: cfg}}, false, o.takeOver); err != nil {
			return dryRunFailure(err, func(err error) error { return decodeFailure(s, o, err) })
		}
		return nil
	}
	job, err := s.Client.StartDecode(ctx, cfg)
	if err != nil {
		return decodeFailure(s, o, err)
	}
	// Subscribing from seq 0 replays the retained window, so a record decoded between StartJob
	// and the subscription is printed rather than lost.
	from := uint64(0)
	sctx, stop := context.WithCancel(ctx)
	defer stop()
	recs, errs, err := s.Client.SubscribeRecords(sctx, leyline.RecordScopeJob(job.GetJobId(), &from))
	if err != nil {
		return err
	}
	s.say("%s\n", decodeBanner(ctx, s, job, o))
	// The daemon can still decline the job after StartJob answered (a radio that cannot tune to
	// the frequency), and a running job can fail. Its end arrives on the event stream, with a
	// GetJob poll behind it, and ends the run with the reason.
	ended := func(j *leylinev1.Job) error {
		return decodeJobEnded(s.app.ErrStyle, j, func(err error) error { return decodeFailure(s, o, err) }, "ley decode "+o.decoder)
	}
	events := s.Events()
	poll := time.NewTicker(time.Second)
	defer poll.Stop()
	n := 0
	for {
		select {
		case <-ctx.Done():
			return decodeStopped(ctx, s, job, o)
		case ev, ok := <-events:
			if !ok {
				events = nil
				continue
			}
			if j := s.jobEvent(ev, job.GetJobId()); j != nil && !isLiveJob(j) {
				return ended(j)
			}
		case <-poll.C:
			if j := s.endedJob(ctx, job.GetJobId()); j != nil {
				return ended(j)
			}
		case err := <-errs:
			if err != nil && ctx.Err() == nil {
				return err
			}
			if j := s.endedJob(ctx, job.GetJobId()); j != nil {
				return ended(j)
			}
			return decodeStopped(ctx, s, job, o)
		case rec, ok := <-recs:
			if !ok {
				if j := s.endedJob(ctx, job.GetJobId()); j != nil {
					return ended(j)
				}
				return decodeStopped(ctx, s, job, o)
			}
			if err := printRecord(s, rec); err != nil {
				return err
			}
			n++
			if o.count > 0 && n >= o.count {
				return decodeStopped(ctx, s, job, o)
			}
		}
	}
}

// requireFrequency refuses, before anything starts, a decoder whose manifest names no frequency
// when --freq names none either: speech decodes whatever it is pointed at, so there is nothing
// to default to. A decoder ley cannot look up is left for the daemon to refuse.
func requireFrequency(ctx context.Context, s *verbSession, decoder string, hz uint64) error {
	if hz != 0 {
		return nil
	}
	resp, err := s.Client.ListDecoders(ctx)
	if err != nil {
		return nil
	}
	for _, m := range resp.GetDecoders() {
		if m.GetName() == decoder && len(m.GetRecipe().GetFrequenciesHz()) == 0 {
			return usageErrorf("%s has no frequency of its own; say where to listen with --freq, e.g. --freq 146.94", decoder)
		}
	}
	return nil
}

// decodeFailure turns the daemon's refusal into an error that says what to do next.
func decodeFailure(s *verbSession, o decodeOptions, err error) error {
	st := s.app.ErrStyle
	switch leyline.Code(err) {
	case leyline.CodeDecoderNotFound:
		return &friendlyError{msg: fmt.Sprintf("there is no decoder called %q. %s lists the ones installed", o.decoder, st.Cmd("ley decoders")), cause: err}
	case leyline.CodeDeviceBusy:
		msg := leylineMessage(err, "the radio is busy")
		return &friendlyError{msg: msg + ". " + st.Cmd("ley decode "+o.decoder+" --take-over") + " decodes anyway, and hands the radio back afterwards", cause: err}
	case leyline.CodeDecoderFailed:
		msg := leylineMessage(err, "the decoder would not start")
		return &friendlyError{msg: msg + ". " + st.Cmd("ley daemon logs") + " carries what the plugin wrote", cause: err}
	case leyline.CodeNoDevice, leyline.CodeFreqOutOfRange:
		msg := leylineMessage(err, "no radio here can hear that")
		return &friendlyError{msg: msg + ". " + st.Cmd("ley devices") + " lists what is here and what it can tune", cause: err}
	}
	return err
}

// decodeJobEnded is the error for a decode job that ended while ley was following it: declined
// after StartJob answered, failed while it ran, or cancelled by another client. failure turns
// the job's reason into the verb's own sentence (a friendlyError), as it does a refusal from
// StartJob; a reason it leaves alone gets the daemon's log as the next step, unless it names a
// command already. A job that completed is no error.
func decodeJobEnded(st ui.Style, job *leylinev1.Job, failure func(error) error, again string) error {
	switch job.GetState() {
	case leylinev1.JobState_FAILED:
		e := job.GetError()
		msg := job.GetStatusDetail()
		if msg == "" {
			msg = e.GetMessage()
		}
		if msg == "" {
			msg = "the decoder stopped"
		}
		cause := &leyline.Error{Code: e.GetCode(), Message: msg, Target: e.GetTarget()}
		var fe *friendlyError
		if err := failure(cause); errors.As(err, &fe) {
			return err
		}
		if !strings.Contains(msg, "ley ") {
			msg += ". " + st.Cmd("ley daemon logs") + " carries what the daemon wrote"
		}
		if cause.Code == "" {
			return &ExitError{Code: 1, Message: msg}
		}
		return &friendlyError{msg: msg, cause: cause}
	case leylinev1.JobState_CANCELLED:
		return &ExitError{Code: 1, Message: fmt.Sprintf("another client cancelled the decode (%s); %s starts another",
			job.GetStatusDetail(), st.Cmd(again))}
	}
	return nil
}

// jobEvent applies ev to the session and returns the job it carries when it is a Job event for
// jobID, else nil.
func (s *verbSession) jobEvent(ev *leylinev1.Event, jobID string) *leylinev1.Job {
	s.Apply(ev)
	if b, ok := ev.Body.(*leylinev1.Event_Job); ok && b.Job.GetJobId() == jobID {
		return b.Job
	}
	return nil
}

// endedJob reads the job back and returns it when it has ended, else nil: a read that fails says
// nothing about the job, so the caller carries on.
func (s *verbSession) endedJob(ctx context.Context, jobID string) *leylinev1.Job {
	ctx, cancel := session.CleanupContext(ctx, confirmTimeout)
	defer cancel()
	j, err := s.Client.Jobs.GetJob(ctx, &leylinev1.JobRef{JobId: jobID})
	if err != nil || isLiveJob(j) {
		return nil
	}
	return j
}

// detachSettle bounds how long a detached verb waits for its job to settle. The daemon answers
// StartJob before it has looked for a radio, and allocating one takes a few hundred milliseconds.
const detachSettle = 3 * time.Second

// settledJob waits, up to detachSettle, for the job StartJob returned to move on: to end (the
// daemon declined it, or it failed) or to publish anything after the reply (it has its radio and
// is under way). It returns the job as last seen, which after the wait may still be the reply.
// The follow is decode's: Job events, with a GetJob poll behind them.
func (s *verbSession) settledJob(ctx context.Context, job *leylinev1.Job) *leylinev1.Job {
	moved := func(j *leylinev1.Job) bool {
		return !isLiveJob(j) || j.GetState() != job.GetState() || j.GetStatusDetail() != job.GetStatusDetail()
	}
	events := s.Events()
	poll := time.NewTicker(100 * time.Millisecond)
	defer poll.Stop()
	deadline := time.NewTimer(detachSettle)
	defer deadline.Stop()
	for {
		select {
		case <-ctx.Done():
			return job
		case <-deadline.C:
			return job
		case ev, ok := <-events:
			if !ok {
				events = nil
				continue
			}
			if j := s.jobEvent(ev, job.GetJobId()); j != nil && moved(j) {
				return j
			}
		case <-poll.C:
			cctx, cancel := session.CleanupContext(ctx, confirmTimeout)
			j, err := s.Client.Jobs.GetJob(cctx, &leylinev1.JobRef{JobId: job.GetJobId()})
			cancel()
			if err == nil && moved(j) {
				return j
			}
		}
	}
}

// leylineMessage is the daemon's own sentence, or fallback when the error carries none. The
// daemon's message gives the reason; ley adds the command to type next.
func leylineMessage(err error, fallback string) string {
	var le *leyline.Error
	if errors.As(err, &le) && le.Message != "" {
		return le.Message
	}
	return fallback
}

// decodeBanner prints what the job was given: the decoder, where it is listening, the gain the
// radio is at, and the channel and capture the daemon allocated, because a decoder tuned to the
// wrong frequency, or run at 0 dB, decodes nothing.
func decodeBanner(ctx context.Context, s *verbSession, job *leylinev1.Job, o decodeOptions) string {
	st := s.app.ErrStyle
	capture, claim, gain := decodeCapture(ctx, s, job.GetJobId())
	where := ""
	hz := decodeFrequency(ctx, s, job)
	if hz == 0 {
		hz = claimFrequency(claim)
	}
	if hz > 0 {
		where = " on " + units.FormatFrequency(hz)
	}
	line := fmt.Sprintf("decoding %s%s", o.decoder, where)
	if gain != "" {
		line += ", " + gain
	}
	if ch := decodeChannel(ctx, s); ch != nil {
		line += ", " + st.Muted(ch.GetChannelId()+" on "+ch.GetCaptureId())
	} else if capture != nil {
		line += ", " + st.Muted(capture.GetCaptureId())
	}
	line += "."
	if clips := clipsURI(job); clips != "" {
		line += " The overs are recorded as " + clips
		if !o.keep {
			line += " until the job ends"
		}
		line += "."
	}
	if o.keep {
		return line + " " + st.Muted("kept: it runs on after ley exits")
	}
	return line + " Ctrl-C stops"
}

// clipsURI is the recording a live speech job writes its overs to, from the job's result URIs, or
// "" for a decoder that records nothing.
func clipsURI(job *leylinev1.Job) string {
	for _, uri := range job.GetResultUris() {
		if id, part, ok := leyline.ParseRecordingURI(uri); ok && part == 0 {
			return leyline.RecordingURI(id)
		}
	}
	return ""
}

// decodeCapture is the capture the job reads, found by the claim it holds there (its channel's,
// or an IQ decoder's on the whole capture), that claim, and the gain words for the capture
// (stageGainWords, "" for a radio with no gain stage). The daemon answers StartJob before it has
// found a radio, and sets the job's gain before the claim appears, so this waits up to
// detachSettle for the claim; nil and "" when none appears or the job has ended.
func decodeCapture(ctx context.Context, s *verbSession, jobID string) (*leylinev1.Capture, *leylinev1.Claim, string) {
	poll := time.NewTicker(100 * time.Millisecond)
	defer poll.Stop()
	deadline := time.NewTimer(detachSettle)
	defer deadline.Stop()
	for {
		cctx, cancel := session.CleanupContext(ctx, confirmTimeout)
		st, err := s.Client.State(cctx)
		cancel()
		if err == nil {
			for _, c := range st.GetCaptures() {
				for _, cl := range c.GetClaims() {
					if cl.GetHolder().GetClientId() != jobID {
						continue
					}
					gain := ""
					if len(c.GetGains()) > 0 {
						var els []*leylinev1.GainElement
						for _, d := range st.GetDevices() {
							if d.GetDeviceId() == c.GetDeviceId() {
								els = d.GetGainElements()
							}
						}
						gain = stageGainWords(c.GetGains(), els)
					}
					return c, cl, gain
				}
			}
			for _, j := range st.GetJobs() {
				if j.GetJobId() == jobID && !isLiveJob(j) {
					return nil, nil, ""
				}
			}
		}
		select {
		case <-ctx.Done():
			return nil, nil, ""
		case <-deadline.C:
			return nil, nil, ""
		case <-poll.C:
		}
	}
}

// claimFrequency is the frequency a claim holds its capture to, 0 for none.
func claimFrequency(cl *leylinev1.Claim) uint64 {
	if hz := cl.GetCentred().GetFrequencyHz(); hz > 0 {
		return hz
	}
	return cl.GetCovers().GetFrequencyHz()
}

// decodeFrequency is where the job is listening: what was asked for, else the channel the daemon
// made, so the banner never quotes a frequency nobody tuned.
func decodeFrequency(ctx context.Context, s *verbSession, job *leylinev1.Job) uint64 {
	if hz := job.GetDecode().GetFrequencyHz(); hz > 0 {
		return hz
	}
	if ch := decodeChannel(ctx, s); ch != nil {
		return ch.GetRequiredHz()
	}
	return 0
}

// decodeChannel finds the channel the job owns in a fresh snapshot: the daemon allocated it, and
// the Job message names a job's work rather than its plumbing.
func decodeChannel(ctx context.Context, s *verbSession) *leylinev1.Channel {
	ctx, cancel := session.CleanupContext(ctx, confirmTimeout)
	defer cancel()
	st, err := s.Client.State(ctx)
	if err != nil {
		return nil
	}
	var best *leylinev1.Channel
	for _, ch := range st.GetChannels() {
		if ch.GetOwner().GetKind() != "job" {
			continue
		}
		if best == nil || ch.GetChannelId() > best.GetChannelId() {
			best = ch
		}
	}
	// The anchor of the capture it sits on is what turns a record's sample time into a clock.
	if best != nil {
		for _, c := range st.GetCaptures() {
			if c.GetCaptureId() == best.GetCaptureId() {
				s.Capture = c
			}
		}
	}
	return best
}

// printRecord writes one record: the time it arrived, the sender, the record kind and its
// content. A fixed layout rather than a table, because the rows arrive one at a time and a table
// that re-laid itself on every packet would be unreadable.
func printRecord(s *verbSession, rec *leylinev1.DecodeRecord) error {
	if s.app.JSON {
		return s.app.printJSON(rec)
	}
	st := s.app.Style
	when := recordClock(s, rec)
	if rec.GetClipUri() != "" {
		_, err := fmt.Fprintln(s.app.Stdout, overLine(st, when, rec))
		return err
	}
	line := fmt.Sprintf("%s  %s  %s  %s",
		st.Muted(when),
		st.Pad(st.Truncate(rec.GetDeviceId(), 12), 12),
		st.Pad(st.Truncate(rec.GetKind(), 9), 9),
		records.SummaryFor(s.displays[rec.GetProtocol()], rec, ""))
	_, err := fmt.Fprintln(s.app.Stdout, strings.TrimRight(line, " "))
	return err
}

// recordClock is the record's wall time, derived from the capture's anchor as every other
// timestamp in ley is (AGENTS.md invariant 5). A record on a capture whose anchor ley has not
// seen prints the time it arrived here instead of inventing one.
func recordClock(s *verbSession, rec *leylinev1.DecodeRecord) string {
	if a := s.Capture.GetAnchor(); a != nil && a.GetCaptureId() == rec.GetTime().GetCaptureId() {
		if at, ok := leyline.AnchorWallTime(a, rec.GetTime().GetSampleIndex()); ok {
			return at.Format("15:04:05")
		}
	}
	return time.Now().Format("15:04:05")
}

// decodeStopped ends the run: an ephemeral job is cancelled here, because the next thing
// somebody does after Ctrl-C is usually tune, and a kept one is left running with the command
// that stops it.
func decodeStopped(ctx context.Context, s *verbSession, job *leylinev1.Job, o decodeOptions) error {
	st := s.app.ErrStyle
	if o.keep {
		s.say("left running; %s stops it\n", st.Cmd("ley jobs cancel "+jobRowName(ctx, s, job)))
		return nil
	}
	ctx, cancel := session.CleanupContext(ctx, confirmTimeout)
	defer cancel()
	if _, err := s.Client.Jobs.CancelJob(ctx, &leylinev1.JobRef{JobId: job.GetJobId()}); err != nil {
		s.say("the job is still running: %s stops it\n", st.Cmd("ley jobs cancel "+jobRowName(ctx, s, job)))
	}
	return nil
}

// jobRowName is how to name this job to `ley jobs cancel`: its row number when ley can see the
// list, else its id, which always works.
func jobRowName(ctx context.Context, s *verbSession, job *leylinev1.Job) string {
	ctx, cancel := session.CleanupContext(ctx, confirmTimeout)
	defer cancel()
	jobs, err := s.Client.ListJobs(ctx)
	if err != nil {
		return job.GetJobId()
	}
	for i, j := range jobs {
		if j.GetJobId() == job.GetJobId() {
			return fmt.Sprint(i + 1)
		}
	}
	return job.GetJobId()
}
