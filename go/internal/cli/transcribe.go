// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bufio"
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/session"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
	"github.com/reflexive-labs/leysdr/go/internal/words"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
	"github.com/reflexive-labs/leysdr/go/pkg/records"
	"github.com/reflexive-labs/leysdr/go/pkg/units"
)

type transcribeOptions struct {
	ref     string
	decoder string
	model   string
	yes     bool
}

func newTranscribeCommand(app *App) *cobra.Command {
	var o transcribeOptions
	cmd := &cobra.Command{
		Use:   "transcribe <recording>",
		Short: "Turn a recording's overs into speech records",
		Long: `transcribe runs a speech decoder over a gated audio recording and prints the
words of each over as the records arrive: the time the over was heard, its
part and its number in that part, the text, and any callsigns a pattern found
in it.

The daemon reads the stored parts, faster than real time, and hands the
decoder one over at a time, cut at the squelch with half a second either
side; the audio between overs is never sent. Before it starts, transcribe
states how many minutes the squelch was open and where the audio goes (the
hosts the decoder's manifest lists, or this Mac), and asks. --yes skips the
question, and is required when stdin is not a terminal.

The records are kept, so 'ley records --protocol speech' reads them later,
and transcribing again with another model adds records beside these.

--engine picks the speech decoder ('ley decoders' lists them; the default is
speech). --model sets the model the speech feature uses with the decoder's
provider, as 'ley ai use speech' does, so this job and later ones use it; if
the daemon refuses the job, the previous choice is put back. A decoder that
calls no provider has no model to choose.

The recording is a job id, an id prefix, or a ley://recordings/ URI.

--json prints one DecodeRecord per line (NDJSON) and nothing else on stdout.`,
		Example: `  ley transcribe job_01J...                 # asks first
  ley transcribe job_01J... --yes           # no question, for a script
  ley transcribe ley://recordings/job_01J... --json | jq -r '.fields.text.text'
  ley records --protocol speech --job-id job_01K...   # read them again`,
		GroupID: GroupLooking,
		Args:    cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			o.ref = args[0]
			if id, part, ok := leyline.ParseRecordingURI(o.ref); ok && part != 0 {
				return usageErrorf("transcribe reads a whole recording, every part of it; give %s", leyline.RecordingURI(id))
			}
			s, err := openSession(cmd.Context(), app)
			if err != nil {
				return err
			}
			defer s.Close()
			s.proseToStderr = true
			return runTranscribe(cmd.Context(), s, o)
		},
	}
	cmd.Flags().StringVar(&o.decoder, "engine", "speech", "the speech decoder to run ('ley decoders' lists them)")
	cmd.Flags().StringVar(&o.model, "model", "", "the speech model for this and later jobs, as 'ley ai use speech' sets it")
	cmd.Flags().BoolVarP(&o.yes, "yes", "y", false, "start without asking")
	return cmd
}

// transcribeRun is what one transcription is about: the recording, where it is, and the decoder.
type transcribeRun struct {
	jobID    string
	manifest *leyline.RecordingManifest
	decoder  *leylinev1.DecoderManifest
	anchors  []*leylinev1.RecordAnchor
	printed  map[uint64]bool
}

func runTranscribe(ctx context.Context, s *verbSession, o transcribeOptions) error {
	run, open, err := prepareTranscribe(ctx, s, o)
	if err != nil {
		return err
	}
	if ok, err := confirmTranscribe(s, run, open, o); !ok || err != nil {
		return err
	}
	// The daemon hands the speech model to the decoder when it starts it, so --model is set
	// before the job and put back if the job is refused.
	restore, err := setSpeechModel(ctx, s, run, o.model)
	if err != nil {
		return err
	}
	job, err := s.Client.StartDecode(ctx, &leylinev1.DecodeConfig{
		Decoder: run.decoder.GetName(), SourceUri: leyline.RecordingURI(run.jobID), Keep: true,
	})
	if err != nil {
		restore()
		return decodeFailure(s, decodeOptions{decoder: run.decoder.GetName()}, err)
	}
	return followTranscribe(ctx, s, run, job)
}

// setSpeechModel makes model the speech feature's model for the decoder's provider and returns
// the function that puts the previous choice back, or clears it when there was none. With no
// model it changes nothing.
func setSpeechModel(ctx context.Context, s *verbSession, run *transcribeRun, model string) (func(), error) {
	if model == "" {
		return func() {}, nil
	}
	st, err := s.Client.Credentials.GetAIState(ctx, &leylinev1.GetAIStateRequest{})
	if err != nil {
		return nil, err
	}
	previous := &leylinev1.FeatureModel{Feature: "speech"} // empty provider and model clear it
	for _, f := range st.GetFeatures() {
		if f.GetFeature() == "speech" {
			previous = f
		}
	}
	fm := &leylinev1.FeatureModel{Feature: "speech", Provider: run.decoder.GetCredentialProvider(), Model: model}
	if _, err := s.Client.Credentials.SetFeatureModel(ctx, fm); err != nil {
		return nil, err
	}
	return func() {
		cctx, cancel := session.CleanupContext(ctx, confirmTimeout)
		defer cancel()
		if _, err := s.Client.Credentials.SetFeatureModel(cctx, previous); err != nil {
			s.say("the speech model is still %s: %s puts it back\n", model,
				s.app.ErrStyle.Cmd("ley ai use speech "+previous.GetProvider()+" "+previous.GetModel()))
		}
	}, nil
}

// confirmTranscribe states what will be sent and where, and asks unless --yes. Without a terminal
// to answer and without --yes it refuses with a usage error, because nobody agreed to send audio.
func confirmTranscribe(s *verbSession, run *transcribeRun, open time.Duration, o transcribeOptions) (bool, error) {
	if o.yes {
		fmt.Fprintf(s.app.Stderr, "%s.\n", transcribeStatement("Transcribing", run, open, o.model))
		return true, nil
	}
	statement := transcribeStatement("Transcribe", run, open, o.model)
	if !s.app.IsInTTY() {
		fmt.Fprintf(s.app.Stderr, "%s.\n", statement)
		return false, usageErrorf("stdin is not a terminal, so nobody can confirm sending the audio. Run: ley transcribe %s --yes", o.ref)
	}
	fmt.Fprintf(s.app.Stderr, "%s? [y/N] ", statement)
	answer, _ := bufio.NewReader(s.app.Stdin).ReadString('\n')
	if a := strings.ToLower(strings.TrimSpace(answer)); a != "y" && a != "yes" {
		fmt.Fprintln(s.app.Stderr, "Nothing was sent; "+run.jobID+" is as it was.")
		return false, nil
	}
	return true, nil
}

// prepareTranscribe finds the recording, reads its manifest and the squelch-open time, and picks
// the decoder, refusing before anything is asked when there is nothing to transcribe or the
// decoder does not read overs.
func prepareTranscribe(ctx context.Context, s *verbSession, o transcribeOptions) (*transcribeRun, time.Duration, error) {
	app := s.app
	jobID, err := resolveRecordingID(ctx, s.Client, o.ref)
	if err != nil {
		return nil, 0, err
	}
	dir, err := s.Client.ResolveLocalPath(ctx, leyline.RecordingURI(jobID))
	if err != nil {
		return nil, 0, recordingNotFound(app, o.ref, err)
	}
	m, err := leyline.ReadRecordingManifest(dir)
	if err != nil {
		return nil, 0, fmt.Errorf("the recording's manifest could not be read (%s): %w", dir, err)
	}
	if m.Kind == "iq" {
		return nil, 0, &friendlyError{msg: fmt.Sprintf("%s is an IQ recording, and speech is decoded from audio. %s makes an audio one",
			jobID, app.ErrStyle.Cmd(gatedRecordCommand(m)))}
	}
	open, err := m.SquelchOpenTime(dir)
	if err != nil {
		return nil, 0, fmt.Errorf("how long %s's squelch was open could not be read: %w", jobID, err)
	}
	if open == 0 {
		return nil, 0, &friendlyError{msg: fmt.Sprintf("%s lists no squelch openings, so there is nothing to transcribe: speech is cut at the squelch, and only a gated recording records where it opened. %s makes one",
			jobID, app.ErrStyle.Cmd(gatedRecordCommand(m)))}
	}
	dec, err := speechDecoder(ctx, s, o)
	if err != nil {
		return nil, 0, err
	}
	run := &transcribeRun{jobID: jobID, manifest: m, decoder: dec, printed: map[uint64]bool{}}
	for _, a := range m.Anchors {
		run.anchors = append(run.anchors, &leylinev1.RecordAnchor{
			Anchor:     &leylinev1.CaptureAnchor{CaptureId: a.CaptureID, HostTimeNs: a.HostTimeNS, SampleRate: a.SampleRate, DriftPpm: a.DriftPPM},
			FromSample: a.FromSample,
		})
	}
	return run, open, nil
}

// gatedRecordCommand is the command that records the same frequency gated, which is what a speech
// decoder can read.
func gatedRecordCommand(m *leyline.RecordingManifest) string {
	return fmt.Sprintf("ley record %s --gate squelch", strconv.FormatFloat(float64(m.FrequencyHz)/1e6, 'f', -1, 64))
}

// speechDecoder is the installed decoder --engine names, by name or alias, which must read overs.
func speechDecoder(ctx context.Context, s *verbSession, o transcribeOptions) (*leylinev1.DecoderManifest, error) {
	resp, err := s.Client.ListDecoders(ctx)
	if err != nil {
		return nil, err
	}
	var dec *leylinev1.DecoderManifest
	for _, m := range resp.GetDecoders() {
		if m.GetName() == o.decoder {
			dec = m
			break
		}
		for _, alias := range m.GetAliases() {
			if alias == o.decoder && dec == nil {
				dec = m
			}
		}
	}
	st := s.app.ErrStyle
	switch {
	case dec == nil:
		return nil, &friendlyError{msg: fmt.Sprintf("there is no decoder called %q. %s lists the ones installed", o.decoder, st.Cmd("ley decoders"))}
	case dec.GetInput().GetMode() != leylinev1.InputMode_SEGMENTED:
		return nil, usageErrorf("--engine %s decodes a continuous stream, not overs; transcribe runs a speech decoder such as speech", o.decoder)
	case o.model != "" && dec.GetCredentialProvider() == "":
		return nil, usageErrorf("--model needs a decoder that calls a provider; %s calls none, so there is no model to choose", dec.GetName())
	}
	return dec, nil
}

// transcribeStatement is what the job will send and where: the parts, the minutes of
// squelch-open audio, the recording's frequency and mode, the decoder and the hosts it contacts.
func transcribeStatement(lead string, run *transcribeRun, open time.Duration, model string) string {
	m := run.manifest
	with := run.decoder.GetName()
	if model != "" {
		with += ", model " + model
	}
	where := "on this Mac; no audio leaves it"
	if hosts := run.decoder.GetContactsHosts(); len(hosts) > 0 {
		where = "sends the audio to " + strings.Join(hosts, ", ")
	}
	statement := fmt.Sprintf("%s %s, %.1f min of squelch-open audio from %s %s, with %s (%s)", lead,
		words.Count(len(m.Parts), "part"), open.Minutes(), units.FormatFrequency(m.FrequencyHz), m.Mode, with, where)
	if model != "" {
		statement += "; the speech model is set to " + model + " for this and later jobs"
	}
	return statement
}

// followTranscribe prints the job's records as they arrive until the job ends, then any the live
// stream did not deliver, read back from the store in order, and the closing line.
func followTranscribe(ctx context.Context, s *verbSession, run *transcribeRun, job *leylinev1.Job) error {
	from := uint64(0)
	sctx, stop := context.WithCancel(ctx)
	defer stop()
	recs, errs, err := s.Client.SubscribeRecords(sctx, leyline.RecordScopeJob(job.GetJobId(), &from))
	if err != nil {
		return err
	}
	poll := time.NewTicker(time.Second)
	defer poll.Stop()
	events := s.Events()
	final := job
	for isLiveJob(final) {
		select {
		case <-ctx.Done():
			return transcribeInterrupted(ctx, s, run, job)
		case rec, ok := <-recs:
			if !ok {
				recs = nil
				continue
			}
			if err := printSpeechRecord(s, run, rec); err != nil {
				return err
			}
		case err := <-errs:
			if err != nil && ctx.Err() == nil {
				return err
			}
			errs = nil
		case ev, ok := <-events:
			if !ok {
				// The poll carries the job's state from here.
				events = nil
				continue
			}
			if b, isJob := ev.Body.(*leylinev1.Event_Job); isJob && b.Job.GetJobId() == job.GetJobId() {
				final = b.Job
				continue
			}
			s.Apply(ev)
		case <-poll.C:
			if j, err := s.Client.Jobs.GetJob(ctx, &leylinev1.JobRef{JobId: job.GetJobId()}); err == nil {
				final = j
			}
		}
	}
	stop()
	if err := printRemainingSpeech(ctx, s, run, job.GetJobId()); err != nil {
		return err
	}
	next := "ley records --protocol " + run.decoder.GetName() + " --job-id " + job.GetJobId()
	switch final.GetState() {
	case leylinev1.JobState_FAILED:
		return &ExitError{Code: 1, Message: recordFailureDetail(final)}
	case leylinev1.JobState_CANCELLED:
		// Somebody else cancelled it (Ctrl-C here returns before this): the transcription is
		// incomplete, which a script must not read as success.
		return &ExitError{Code: 1, Message: fmt.Sprintf("the transcription was cancelled before it finished; %s kept. Read them with: %s",
			words.Count(len(run.printed), "record"), next)}
	}
	st := s.app.ErrStyle
	s.say("%s %s, kept as %s\n%s%s\n", st.Label("Transcribed"), words.Count(len(run.printed), "record"),
		"ley://records/"+job.GetJobId(), st.Muted("Next: "),
		st.Cmd(next))
	return nil
}

// printRemainingSpeech prints, in order, the records the job kept that the live stream did not
// deliver before the job ended: the job's end and its last record travel on different streams.
func printRemainingSpeech(ctx context.Context, s *verbSession, run *transcribeRun, jobID string) error {
	page, err := s.Client.QueryRecords(ctx, &leylinev1.RecordQuery{JobId: jobID})
	if err != nil {
		return err
	}
	recs := page.GetRecords()
	sort.Slice(recs, func(i, j int) bool { return recs[i].GetSeq() < recs[j].GetSeq() })
	for _, rec := range recs {
		if err := printSpeechRecord(s, run, rec); err != nil {
			return err
		}
	}
	return nil
}

// printSpeechRecord writes one record, once: the time the over was heard, from the recording's
// anchor; its part and over; the words; and the callsigns in parentheses.
func printSpeechRecord(s *verbSession, run *transcribeRun, rec *leylinev1.DecodeRecord) error {
	if run.printed[rec.GetSeq()] {
		return nil
	}
	run.printed[rec.GetSeq()] = true
	if s.app.JSON {
		return s.app.printJSON(rec)
	}
	st := s.app.Style
	when := "--:--:--"
	if at, ok := leyline.RecordWallTime(rec, run.anchors); ok {
		when = at.Format("15:04:05")
	}
	_, err := fmt.Fprintln(s.app.Stdout, overLine(st, when, rec))
	return err
}

// overLine is one over's words as transcribe and a live speech decode print them: the time, the
// part and over of the clip that holds the audio, the text, and any callsigns in parentheses.
func overLine(st ui.Style, when string, rec *leylinev1.DecodeRecord) string {
	_, part, _ := leyline.ParseRecordingURI(rec.GetClipUri())
	line := fmt.Sprintf("%s %s  %s", st.Muted(when), st.Muted(fmt.Sprintf("part %d over %d", part, rec.GetOver())), records.Text(rec, "text"))
	if calls := records.Text(rec, "callsigns"); calls != "" {
		line += " (" + strings.ReplaceAll(calls, ",", ", ") + ")"
	}
	return line
}

// transcribeInterrupted stops the job on Ctrl-C: the audio not yet sent is not sent, and the
// records already made stay kept.
func transcribeInterrupted(ctx context.Context, s *verbSession, run *transcribeRun, job *leylinev1.Job) error {
	cctx, cancel := session.CleanupContext(ctx, confirmTimeout)
	defer cancel()
	st := s.app.ErrStyle
	if _, err := s.Client.Jobs.CancelJob(cctx, &leylinev1.JobRef{JobId: job.GetJobId()}); err != nil {
		s.say("the job is still running: %s stops it\n", st.Cmd("ley jobs cancel "+job.GetJobId()))
		return nil
	}
	s.say("Stopped; %s kept: %s\n", words.Count(len(run.printed), "record"),
		st.Cmd("ley records --protocol "+run.decoder.GetName()+" --job-id "+job.GetJobId()))
	return nil
}
