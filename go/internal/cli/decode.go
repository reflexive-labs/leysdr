// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
	"github.com/dpup/leysdr/go/pkg/records"
)

type decodeOptions struct {
	decoder  string
	freqHz   uint64
	device   string
	deviceID string
	takeOver bool
	keep     bool
	count    int
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

The daemon finds a capture that already covers the frequency, or makes one on
an idle radio, or says who has the radio instead; --take-over insists. All of
the decoding happens in the daemon, so an agent or a script reading --json
sees exactly what the terminal shows.

Ctrl-C stops the job and hands the radio back. With --job the job stays
running after ley exits and its records become a resource 'ley records'
reads; 'ley jobs cancel' is how to stop one.

--json prints one DecodeRecord per line (NDJSON) and nothing else on stdout.`,
		Example: `  ley decode aprs                     # what is on 144.390 MHz?
  ley decode aprs --count 5           # five packets, then stop
  ley decode aprs --freq 144.8        # the European allocation
  ley decode aprs --job               # keep decoding after ley exits
  ley decode aprs --json | jq -r .deviceId`,
		GroupID: GroupLooking,
		Args:    cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			o.decoder = args[0]
			if freq != "" {
				hz, err := leyline.ParseUserFrequency(freq)
				if err != nil {
					return usageErrorf("--freq: %v", err)
				}
				o.freqHz = hz
			}
			s, err := openSession(cmd.Context(), app)
			if err != nil {
				return err
			}
			defer s.close()
			if o.device != "" {
				d, derr := pickDevice(s.state, o.device)
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
	cmd.Flags().BoolVar(&o.keep, "job", false, "keep the job and its records after ley exits ('ley jobs cancel' stops it)")
	cmd.Flags().IntVar(&o.count, "count", 0, "stop after this many records, e.g. 5 (default: until Ctrl-C)")
	return cmd
}

// runDecode starts the job, subscribes from the beginning of its records and prints them until
// --count, Ctrl-C or the end of the stream.
func runDecode(ctx context.Context, s *session, o decodeOptions) error {
	cfg := &leylinev1.DecodeConfig{
		Decoder:     o.decoder,
		FrequencyHz: o.freqHz,
		DeviceId:    o.deviceID,
		TakeOver:    o.takeOver,
		Keep:        o.keep,
	}
	job, err := s.client.StartDecode(ctx, cfg)
	if err != nil {
		return decodeFailure(s, o, err)
	}
	// Subscribing from seq 0 replays the retained window, so a record decoded between StartJob
	// and the subscription is printed rather than lost.
	from := uint64(0)
	sctx, stop := context.WithCancel(ctx)
	defer stop()
	recs, errs, err := s.client.SubscribeRecords(sctx, leyline.RecordScopeJob(job.GetJobId(), &from))
	if err != nil {
		return err
	}
	s.say("%s\n", decodeBanner(s, job, o))
	n := 0
	for {
		select {
		case <-ctx.Done():
			return decodeStopped(s, job, o)
		case err := <-errs:
			if err != nil && ctx.Err() == nil {
				return err
			}
			return decodeStopped(s, job, o)
		case rec, ok := <-recs:
			if !ok {
				return decodeStopped(s, job, o)
			}
			if err := printRecord(s, rec); err != nil {
				return err
			}
			n++
			if o.count > 0 && n >= o.count {
				return decodeStopped(s, job, o)
			}
		}
	}
}

// decodeFailure turns the daemon's refusal into the sentence the reader acts on.
func decodeFailure(s *session, o decodeOptions, err error) error {
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
	}
	return err
}

// leylineMessage is the daemon's own sentence, or fallback when the error carries none. The
// daemon says why in prose; ley adds the command to type next.
func leylineMessage(err error, fallback string) string {
	var le *leyline.Error
	if errors.As(err, &le) && le.Message != "" {
		return le.Message
	}
	return fallback
}

// decodeBanner states what the job got: the decoder, where it is listening, and the channel and
// capture the daemon allocated, because a decoder tuned somewhere the reader did not ask for is
// a decoder that hears nothing.
func decodeBanner(s *session, job *leylinev1.Job, o decodeOptions) string {
	st := s.app.ErrStyle
	where := ""
	if hz := decodeFrequency(s, job); hz > 0 {
		where = " on " + leyline.FormatFrequency(hz)
	}
	line := fmt.Sprintf("decoding %s%s", o.decoder, where)
	if ch := decodeChannel(s); ch != nil {
		line += ", " + st.Muted(ch.GetChannelId()+" on "+ch.GetCaptureId())
	}
	if o.keep {
		return line + ". " + st.Muted("kept: it runs on after ley exits")
	}
	return line + ". Ctrl-C stops"
}

// decodeFrequency is where the job is listening: what was asked for, else the channel the daemon
// made, so the banner never quotes a frequency nobody tuned.
func decodeFrequency(s *session, job *leylinev1.Job) uint64 {
	if hz := job.GetDecode().GetFrequencyHz(); hz > 0 {
		return hz
	}
	if ch := decodeChannel(s); ch != nil {
		return ch.GetRequiredHz()
	}
	return 0
}

// decodeChannel finds the channel the job owns in a fresh snapshot: the daemon allocated it, and
// the Job message names a job's work rather than its plumbing.
func decodeChannel(s *session) *leylinev1.Channel {
	ctx, cancel := context.WithTimeout(context.Background(), confirmTimeout)
	defer cancel()
	st, err := s.client.State(ctx)
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
				s.capture = c
			}
		}
	}
	return best
}

// printRecord writes one record: the time it arrived, who sent it, what kind of thing it was,
// and what it said. A fixed layout rather than a table, because the rows arrive one at a time
// and a table that re-laid itself on every packet could not be read.
func printRecord(s *session, rec *leylinev1.DecodeRecord) error {
	if s.app.JSON {
		return s.app.printJSON(rec)
	}
	st := s.app.Style
	when := recordClock(s, rec)
	line := fmt.Sprintf("%s  %s  %s  %s",
		st.Muted(when),
		st.Pad(st.Truncate(rec.GetDeviceId(), 12), 12),
		st.Pad(st.Truncate(rec.GetKind(), 9), 9),
		records.Summary(rec))
	_, err := fmt.Fprintln(s.app.Stdout, strings.TrimRight(line, " "))
	return err
}

// recordClock is the record's wall time, derived from the capture's anchor as every other
// timestamp in ley is (CLAUDE.md invariant 5). A record on a capture whose anchor ley has not
// seen prints the time it arrived here instead of inventing one.
func recordClock(s *session, rec *leylinev1.DecodeRecord) string {
	if a := s.capture.GetAnchor(); a != nil && a.GetCaptureId() == rec.GetTime().GetCaptureId() {
		if at, ok := leyline.AnchorWallTime(a, rec.GetTime().GetSampleIndex()); ok {
			return at.Format("15:04:05")
		}
	}
	return time.Now().Format("15:04:05")
}

// decodeStopped ends the run: an ephemeral job is cancelled here, because the next thing
// somebody does after Ctrl-C is usually tune, and a kept one is left running with the command
// that stops it.
func decodeStopped(s *session, job *leylinev1.Job, o decodeOptions) error {
	st := s.app.ErrStyle
	if o.keep {
		s.say("left running; %s stops it\n", st.Cmd("ley jobs cancel "+jobRowName(s, job)))
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), confirmTimeout)
	defer cancel()
	if _, err := s.client.Jobs.CancelJob(ctx, &leylinev1.JobRef{JobId: job.GetJobId()}); err != nil {
		s.say("the job is still running: %s stops it\n", st.Cmd("ley jobs cancel "+jobRowName(s, job)))
	}
	return nil
}

// jobRowName is how to name this job to `ley jobs cancel`: its row number when ley can see the
// list, else its id, which always works.
func jobRowName(s *session, job *leylinev1.Job) string {
	ctx, cancel := context.WithTimeout(context.Background(), confirmTimeout)
	defer cancel()
	jobs, err := s.client.ListJobs(ctx)
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
