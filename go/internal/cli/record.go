// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/session"
	"github.com/reflexive-labs/leysdr/go/pkg/bandplan"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
	"github.com/reflexive-labs/leysdr/go/pkg/units"
)

type recordOptions struct {
	// input is the positional as the user typed it, for the banner and the errors.
	input     string
	freqHz    uint64
	channelID string
	iq        bool
	forDur    time.Duration
	gated     bool
	pre       time.Duration
	hang      time.Duration
	quiet     time.Duration
	part      time.Duration
	detach    bool
	// listen plays the channel through the daemon's speakers while it records, so you hear what
	// is going into the file without a second command holding a second channel.
	listen    bool
	mode      leylinev1.DemodMode
	bwHz      uint32
	squelchDB float64
	gain      string
	device    string
	deviceID  string
	takeOver  bool
	// audio backs the hidden `--audio`, which asks for what record already does; it is read
	// only to refuse the pair with --iq. A field, not a package variable: every Execute builds
	// its own command tree, and tests run several at once.
	audio bool
}

func newRecordCommand(app *App) *cobra.Command {
	var (
		o                                       recordOptions
		gate, forStr, mode, bw, squelch, preStr string
		hangStr, quietStr, partStr              string
	)
	cmd := &cobra.Command{
		Use:   "record <frequency|preset|channel>",
		Short: "Record a channel or the raw capture to a file",
		Long: `record writes what the radio hears to files the daemon keeps: audio as WAV
by default, or the raw samples with --iq. Audio is the default because it is
the one you can listen to and it is two hundred times smaller -- 96 KB a
second against 19 MB. It is a job, so it outlives the terminal that started
it and what it writes is a resource -- 'ley recordings' lists them,
'ley recordings path' says where they are.

Given a frequency or preset, record tunes for itself (the mode comes from the
band unless --mode says otherwise). Given a channel id from 'ley state' it
records what you are already listening to, with your mode, bandwidth and
squelch, and stops when you do.

--gate squelch records only while the squelch is open, one file per exchange:
the pauses between overs stay inside one file (--hang) and half a second
before each key-up is kept (--pre). Silence is never edited out of a file --
the gaps between files are stated in the manifest instead, so a recording
played back sounds like the air did.

record runs in the foreground and prints what it is doing until --for elapses
or Ctrl-C, which stops the job and leaves the recording complete. --detach
starts it and exits with the job id; 'ley jobs cancel' stops one.

--json prints the Job as each state change arrives, one object per line.`,
		Example: `  ley record 146.52 --for 5m             # five minutes of audio
  ley record noaa --gate squelch         # only while something is on the air
  ley record chan_01J... --for 10m       # what this channel is hearing
  ley record 146.52 --iq --for 30s       # raw samples, for another tool
  ley record 462.6 --gate squelch --stop-after-quiet 10m --detach
  ley play "$(ley record 146.52 --iq --for 10s --json | tail -1 | jq -r .resultUris[0])"`,
		GroupID: GroupListening,
		Args:    recordPositional,
		RunE: func(cmd *cobra.Command, args []string) error {
			arg := ""
			if len(args) == 1 {
				arg = args[0]
			}
			if err := o.parse(arg, gate, forStr, mode, bw, squelch, preStr, hangStr, quietStr, partStr); err != nil {
				return err
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
			if err := o.resolveChannel(s); err != nil {
				return err
			}
			// Everything record prints while it runs goes to stderr; stdout carries the ids and
			// the URI a script reads.
			s.proseToStderr = true
			return runRecord(cmd.Context(), s, o)
		},
	}
	cmd.Flags().BoolVar(&o.iq, "iq", false, "record the radio's raw samples (.cf32) instead of demodulated audio: about 19 MB a second at 2.4 MSPS against 96 KB a second for audio, so it is cut into parts (see --part)")
	cmd.Flags().StringVar(&forStr, "for", "", "how long to record, e.g. 30s, 5m, 2h (default: until Ctrl-C or ley jobs cancel)")
	cmd.Flags().StringVar(&gate, "gate", "", "record only while something is on the air: squelch (default: record continuously)")
	cmd.Flags().StringVar(&preStr, "pre", "", "how much audio to keep from before each key-up, e.g. 500ms (default 500ms; needs --gate)")
	cmd.Flags().StringVar(&hangStr, "hang", "", "how long a file stays open after a key-down, so the pauses between overs stay in one file, e.g. 5s (default 5s; needs --gate)")
	cmd.Flags().StringVar(&quietStr, "stop-after-quiet", "", "stop recording after this long with nothing on the air, e.g. 10m (needs --gate)")
	cmd.Flags().StringVar(&partStr, "part", "", "cut a new file every so often, e.g. 60s (default: audio is one file, IQ is cut every 60s)")
	cmd.Flags().BoolVar(&o.listen, "listen", false, "also play what is being recorded through the speakers, so you can hear it go in (not with --iq or --detach)")
	// Audio is what record writes unless --iq says otherwise, so this asks for the default. It is
	// accepted because the user stories spell the pair `--iq` and `--audio`
	// (docs/plans/user-stories.md), and a user following them should not get "unknown flag".
	cmd.Flags().BoolVar(&o.audio, "audio", false, "record demodulated audio (the default; --iq records raw samples instead)")
	_ = cmd.Flags().MarkHidden("audio")
	cmd.Flags().BoolVar(&o.detach, "detach", false, "start the recording and exit, printing its job id and URI (for scripts; 'ley jobs cancel' stops it)")
	cmd.Flags().StringVar(&mode, "mode", "", "how to decode: nfm, wfm, am, usb, lsb, cw (default: by band; ley help modes)")
	cmd.Flags().StringVar(&bw, "bw", "", "how wide a slice of spectrum to record: a bare number is kHz (12.5), or 200k, 12500 (default: the mode's usual width)")
	// `--bw` is what every other verb calls it and what the help shows; `--bandwidth` is the
	// spelling docs/design/recording.md uses, kept working but hidden so help shows one spelling.
	cmd.Flags().StringVar(&bw, "bandwidth", "", "another spelling of --bw")
	_ = cmd.Flags().MarkHidden("bandwidth")
	cmd.Flags().StringVar(&squelch, "squelch", "", "mute below this level: auto (default with --gate), off, or a level like -40 (dBFS)")
	cmd.Flags().StringVar(&o.gain, "gain", "", gainHelp+"; default: leave the radio's setting")
	cmd.Flags().StringVar(&o.device, "device", "", "which radio: an id (dev_...), id prefix or row number from 'ley devices' (default: the first real radio)")
	cmd.Flags().BoolVar(&o.takeOver, "take-over", false, "record even when somebody is using the radio; it is theirs again afterwards")
	return cmd
}

// recordPositional takes the one positional and explains the rest. `ley record 88.5 for 10s` is the
// slip a shell habit produces, and Cobra's "accepts at most 1 arg(s), received 3" does not say
// what to type instead. A word that matches a flag name without its dashes is reported as that
// flag.
func recordPositional(cmd *cobra.Command, args []string) error {
	if len(args) <= 1 {
		return nil
	}
	extra := args[1:]
	if f := cmd.Flags().Lookup(strings.TrimLeft(extra[0], "-")); f != nil {
		rest := ""
		if len(extra) > 1 {
			rest = " " + extra[1]
		}
		return usageErrorf("%s is a flag and needs its dashes: ley record %s --%s%s",
			extra[0], args[0], f.Name, rest)
	}
	return usageErrorf("record takes one frequency, preset or channel and then flags, but %s followed it: ley record %s --for 30s",
		quoteWords(extra), args[0])
}

// quoteWords renders the stray words a usage error is about.
func quoteWords(words []string) string {
	out := make([]string, len(words))
	for i, w := range words {
		out[i] = strconv.Quote(w)
	}
	if len(out) == 1 {
		return out[0]
	}
	return strings.Join(out[:len(out)-1], ", ") + " and " + out[len(out)-1]
}

// parse turns the raw flags into the config, refusing the combinations the CLI can judge on its
// own. The daemon refuses the rest, with its own sentence.
func (o *recordOptions) parse(arg, gate, forStr, mode, bw, squelch, pre, hang, quiet, part string) error {
	o.input = arg
	o.squelchDB = 0
	switch gate {
	case "":
	case "squelch":
		o.gated = true
	default:
		return usageErrorf("--gate %q is not a gate; squelch is the one there is", gate)
	}
	for _, f := range []struct {
		name, value string
		dst         *time.Duration
	}{
		{"--for", forStr, &o.forDur},
		{"--pre", pre, &o.pre},
		{"--hang", hang, &o.hang},
		{"--stop-after-quiet", quiet, &o.quiet},
		{"--part", part, &o.part},
	} {
		if f.value == "" {
			continue
		}
		d, err := parseAge(f.value)
		if err != nil {
			return usageErrorf("%s %v", f.name, err)
		}
		*f.dst = d
	}
	// The gate flags need a gate: without one nothing is watching the squelch, and a recording
	// that silently ignored --hang would be the wrong length with no way to tell.
	if !o.gated {
		for _, f := range []struct{ name, value string }{
			{"--pre", pre}, {"--hang", hang}, {"--stop-after-quiet", quiet},
		} {
			if f.value != "" {
				return usageErrorf("%s needs --gate squelch: without a gate nothing is watching the squelch", f.name)
			}
		}
	}
	if o.iq && o.gated {
		return usageErrorf("--iq and --gate squelch do not go together: a gate needs a channel's squelch, and an IQ recording has no channel. Record audio, or record IQ continuously")
	}
	if o.listen {
		// There is nothing to listen to in an IQ recording -- it is the signal before a
		// demodulator -- and a detached job outlives the speakers this would attach.
		if o.iq {
			return usageErrorf("--listen and --iq do not go together: an IQ recording is the signal before a demodulator, so there is nothing to play. Record audio, or listen with ley tune on another terminal")
		}
		if o.detach {
			return usageErrorf("--listen and --detach do not go together: the speakers belong to this terminal and stop when it exits, while the recording runs on. Use ley tune to listen to a detached recording")
		}
	}
	// `--audio` names the default rather than contradicting `--iq`; both at once is a request for
	// two different files and there is only one recording.
	if o.audio && o.iq {
		return usageErrorf("--audio and --iq ask for two different recordings: audio is what record writes unless --iq says otherwise, so give one or neither")
	}
	if o.iq {
		o.mode = leylinev1.DemodMode_RAW_IQ
		if mode != "" {
			return usageErrorf("--iq records the radio's raw samples, so --mode has nothing to decode")
		}
	}
	// A channel id says everything about the signal, so the flags that describe one are refused
	// rather than ignored.
	if isChannelID(arg) {
		for _, f := range []struct{ name, value string }{{"--mode", mode}, {"--bw", bw}, {"--squelch", squelch}} {
			if f.value != "" {
				return usageErrorf("%s does not apply when recording a channel: the recording uses the mode, bandwidth and squelch you are listening with", f.name)
			}
		}
		o.channelID = arg
		return nil
	}
	t, err := resolveDialTarget(arg, "record", "ley record 146.52, ley record noaa", "146.52 (MHz)", nil)
	if err != nil {
		return err
	}
	o.freqHz = t.Hz
	if !o.iq {
		switch {
		case mode != "":
			m, _, merr := bandplan.ResolveMode(mode, o.freqHz)
			if merr != nil {
				return usageErrorf("--mode %v", merr)
			}
			o.mode = m
		case t.Preset != nil && t.Preset.Mode != leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED:
			o.mode = t.Preset.Mode
		default:
			o.mode, _ = bandplan.DefaultMode(o.freqHz)
		}
	}
	if bw != "" {
		hz, berr := units.ParseBandwidth(bw)
		if berr != nil {
			return usageErrorf("--bw %v (examples: 12.5, 12.5k, 200k, 12500)", berr)
		}
		o.bwHz = hz
	}
	if squelch != "" {
		db, auto, serr := units.ParseSquelch(squelch)
		if serr != nil {
			return usageErrorf("--squelch %v (examples: -40, -40dB, off, auto)", serr)
		}
		switch {
		case auto:
			// The daemon measures it from the channel's own noise floor, as ley tune does.
			o.squelchDB = 0
		case math.IsNaN(db):
			if o.gated {
				return usageErrorf("--squelch off and --gate squelch contradict each other: a gate needs a squelch to watch")
			}
			o.squelchDB = math.NaN()
		default:
			o.squelchDB = db
		}
	}
	if o.gain != "" {
		if _, gerr := units.ParseGains(o.gain); gerr != nil {
			return usageError(fmt.Errorf("--gain %w", gerr))
		}
	}
	return nil
}

// isChannelID reports whether the positional names a channel rather than a point on the dial.
func isChannelID(arg string) bool { return strings.HasPrefix(arg, "chan_") }

// resolveChannel checks a named channel exists before the job is started, so a typo is a usage
// error here rather than a job that failed somewhere else.
func (o *recordOptions) resolveChannel(s *verbSession) error {
	if o.channelID == "" {
		return nil
	}
	for _, ch := range s.State.GetChannels() {
		if ch.GetChannelId() == o.channelID {
			return nil
		}
	}
	return usageErrorf("no channel called %s; %s lists the ones open", o.channelID, s.app.ErrStyle.Cmd("ley state"))
}

func (o *recordOptions) config() *leylinev1.RecordConfig {
	cfg := &leylinev1.RecordConfig{
		FrequencyHz:      o.freqHz,
		Mode:             o.mode,
		ChannelId:        o.channelID,
		DeviceId:         o.deviceID,
		TakeOver:         o.takeOver,
		BandwidthHz:      o.bwHz,
		SquelchDbfs:      o.squelchDB,
		DurationMs:       o.forDur.Milliseconds(),
		PreRollMs:        uint32(o.pre.Milliseconds()),
		HangMs:           uint32(o.hang.Milliseconds()),
		StopAfterQuietMs: o.quiet.Milliseconds(),
		PartMs:           o.part.Milliseconds(),
		Gate:             leylinev1.RecordGate_NONE,
	}
	if o.gated {
		cfg.Gate = leylinev1.RecordGate_SQUELCH
	}
	cfg.Gains = gainWrites(o.gain)
	return cfg
}

// runRecord starts the job and, unless --detach, follows it until it ends.
func runRecord(ctx context.Context, s *verbSession, o recordOptions) error {
	job, err := s.Client.StartRecord(ctx, o.config())
	if err != nil {
		return recordFailure(s, o, err)
	}
	uri := recordURI(job)
	// The speakers are this terminal's, attached to the channel the daemon is recording, so what
	// you hear is what is going into the file rather than a second demodulator's output.
	// Attached before the banner is printed, so the banner reports what happened rather than what
	// was asked for: a host with no audio prints a warning and the banner omits the line.
	playing := false
	if o.listen {
		if sink := s.attachRecordAudio(ctx, job, o); sink != "" {
			playing = true
			defer func() {
				cctx, cancel := session.CleanupContext(ctx, confirmTimeout)
				defer cancel()
				_ = s.Client.DetachSink(cctx, sink)
			}()
		}
	}
	if s.app.JSON {
		if err := s.app.printJSON(job); err != nil {
			return err
		}
	} else {
		// The banner states what the daemon decided, not what was asked for, so a recording of
		// the wrong thing is caught in the first line rather than in the file. That means waiting
		// for the manifest, which appears as soon as the job has its radio.
		manifest, dir, ended := awaitManifest(ctx, s, job.GetJobId())
		if ended.GetState() == leylinev1.JobState_FAILED {
			// It failed before it wrote anything (a gain the radio refused, a radio gone): a
			// banner would describe a recording that does not exist.
			return &ExitError{Code: 1, Message: recordFailureDetail(ended)}
		}
		s.say("%s\n", recordBanner(s, o, manifest, dir, playing))
	}
	if o.detach {
		// Under --json stdout is the Job stream and nothing else; the URI is in its resultUris.
		if !s.app.JSON {
			s.say("%s %s stops it\n", s.app.ErrStyle.Muted("Left running;"),
				s.app.ErrStyle.Cmd("ley jobs cancel "+jobRowName(ctx, s, job)))
			fmt.Fprintln(s.app.Stdout, job.GetJobId())
			fmt.Fprintln(s.app.Stdout, uri)
		}
		return nil
	}
	final, err := s.followRecord(ctx, job)
	if err != nil {
		return err
	}
	// Ctrl-C stops the job: the next thing somebody does is usually tune, and a cancelled
	// recording is complete rather than damaged.
	if ctx.Err() != nil && isLiveJob(final) {
		cctx, cancel := session.CleanupContext(ctx, confirmTimeout)
		defer cancel()
		if j, cerr := s.Client.Jobs.CancelJob(cctx, &leylinev1.JobRef{JobId: job.GetJobId()}); cerr == nil {
			final = j
			if s.app.JSON {
				if err := s.app.printJSON(final); err != nil {
					return err
				}
			}
		}
	}
	if final.GetState() == leylinev1.JobState_FAILED {
		return &ExitError{Code: 1, Message: recordFailureDetail(final)}
	}
	if !s.app.JSON {
		// A recording that heard nothing is not kept, so there is no URI to hand a script and
		// nothing for `ley recordings show` to find (docs/design/recording.md, "Nothing heard").
		if final.GetStatusDetail() == leyline.NothingHeard {
			s.say("%s\n", recordedNothing(s, o))
			return nil
		}
		s.say("%s\n", recordClosing(s, final, job.GetJobId(), o.iq))
		fmt.Fprintln(s.app.Stdout, uri)
	}
	return nil
}

// recordedNothing is the closing line of a recording the daemon discarded because no part was
// written. A gated recording heard nothing because its squelch stayed shut; a continuous one
// because no audio reached it before it ended.
func recordedNothing(s *verbSession, o recordOptions) string {
	return s.app.ErrStyle.Label("Recorded nothing:") + " " + nothingHeardReason(o.gated)
}

// nothingHeardReason is why a discarded recording held nothing, for the CLI and the MCP tool.
func nothingHeardReason(gated bool) string {
	if gated {
		return "the squelch never opened."
	}
	return "no audio arrived before it ended."
}

// attachRecordAudio puts this terminal's speakers on the channel the recording is writing from,
// and returns the sink id to detach afterwards. A host with no audio is a warning, not a failure:
// the recording is already running and does not depend on the speakers.
func (s *verbSession) attachRecordAudio(ctx context.Context, job *leylinev1.Job, o recordOptions) string {
	ch := s.recordChannel(ctx, job, o)
	if ch == "" {
		fmt.Fprintln(s.app.Stderr, s.app.ErrStyle.Warn("could not find the channel the recording is on; it is recording, but nothing is playing"))
		return ""
	}
	sink, err := s.Client.Control.AttachSink(ctx, &leylinev1.AttachSinkRequest{
		ChannelId: ch,
		Sink:      &leylinev1.Sink{Kind: &leylinev1.Sink_SystemAudio{SystemAudio: &leylinev1.SystemAudioSink{Volume: proto.Float64(1)}}},
	})
	if err != nil {
		if leyline.Code(err) == leyline.CodePlatformUnsupported {
			fmt.Fprintln(s.app.Stderr, s.app.ErrStyle.Warn("system audio is not available on the daemon's host; recording without it"))
			return ""
		}
		fmt.Fprintln(s.app.Stderr, s.app.ErrStyle.Warn("could not play the recording: "+leylineMessage(err, err.Error())))
		return ""
	}
	return sink.GetSinkId()
}

// recordChannel is the channel the job is recording: the one it was told to borrow, or the one
// the allocator made for it. A job's channel carries the frequency it was asked for in
// required_hz, which is what tells it apart from anything else on the radio.
func (s *verbSession) recordChannel(ctx context.Context, _ *leylinev1.Job, o recordOptions) string {
	if o.channelID != "" {
		return o.channelID
	}
	// The channel appears when the daemon has its radio, which is when the manifest does.
	deadline := time.Now().Add(recordManifestWait)
	for {
		st, err := s.Client.State(ctx)
		if err == nil {
			for _, ch := range st.GetChannels() {
				if ch.GetOwner().GetKind() == "job" && ch.GetRequiredHz() == o.freqHz {
					s.State = st
					return ch.GetChannelId()
				}
			}
		}
		if time.Now().After(deadline) || ctx.Err() != nil {
			return ""
		}
		select {
		case <-ctx.Done():
			return ""
		case <-time.After(50 * time.Millisecond):
		}
	}
}

// awaitManifest waits briefly for the recording the daemon is writing, so the banner can state
// the rate, format, radio and gain it really chose. A job still looking for a radio has no
// manifest yet; the banner falls back to what was asked for rather than making the reader wait.
// A job that ended before writing one is returned as well, so a gain the radio refused is
// reported at once rather than after the wait.
func awaitManifest(ctx context.Context, s *verbSession, jobID string) (*leyline.RecordingManifest, string, *leylinev1.Job) {
	deadline := time.Now().Add(recordManifestWait)
	for {
		if dir, err := s.Client.ResolveLocalPath(ctx, leyline.RecordingURI(jobID)); err == nil {
			if m, merr := leyline.ReadRecordingManifest(dir); merr == nil {
				return m, dir, nil
			}
		}
		if j, err := s.Client.Jobs.GetJob(ctx, &leylinev1.JobRef{JobId: jobID}); err == nil && !isLiveJob(j) {
			return nil, "", j
		}
		if time.Now().After(deadline) || ctx.Err() != nil {
			return nil, "", nil
		}
		select {
		case <-ctx.Done():
			return nil, "", nil
		case <-time.After(50 * time.Millisecond):
		}
	}
}

// recordManifestWait bounds that: allocating a radio takes a few hundred milliseconds, and
// printing the request after this long is better than holding the banner back.
const recordManifestWait = 2 * time.Second

// recordClosing is the line a finished recording ends with, and what to type next: raw samples
// tune back through play, and an audio recording's own manifest offers the player.
func recordClosing(s *verbSession, final *leylinev1.Job, jobID string, iq bool) string {
	st := s.app.ErrStyle
	detail := final.GetStatusDetail()
	lead, rest, _ := strings.Cut(detail, " ")
	line := st.Label(strings.ToUpper(lead[:1])+lead[1:]) + " " + rest
	next := "ley recordings show " + jobID
	if iq {
		next = "ley play " + jobID
	}
	return line + "\n" + st.Muted("Next: ") + st.Cmd(next)
}

// isLiveJob reports whether the daemon is still working on it.
func isLiveJob(j *leylinev1.Job) bool {
	return j.GetState() == leylinev1.JobState_RUNNING || j.GetState() == leylinev1.JobState_DEGRADED
}

// followRecord renders the job's own progress until it ends. Job state arrives on the event
// stream every client already drains; the poll is a backstop, as it is for a sweep.
func (s *verbSession) followRecord(ctx context.Context, job *leylinev1.Job) (*leylinev1.Job, error) {
	progress := newScanProgress(s.app)
	defer progress.clear()
	last := job
	poll := time.NewTicker(2 * time.Second)
	defer poll.Stop()
	for {
		select {
		case <-ctx.Done():
			return last, nil
		case <-poll.C:
			j, err := s.Client.Jobs.GetJob(ctx, &leylinev1.JobRef{JobId: job.GetJobId()})
			if err != nil {
				if ctx.Err() != nil {
					return last, nil
				}
				return last, err
			}
			if s.app.JSON && j.GetStatusDetail() != last.GetStatusDetail() {
				if err := s.app.printJSON(j); err != nil {
					return last, err
				}
			}
			last = j
			// The terminal detail is the closing line, printed properly below; showing it here
			// too would say the same thing twice.
			if !isLiveJob(last) {
				return last, nil
			}
			progress.show(last.GetStatusDetail())
		case ev, ok := <-s.Events():
			if !ok {
				if err := <-s.EventErrs(); err != nil {
					return last, err
				}
				j, err := s.Client.Jobs.GetJob(ctx, &leylinev1.JobRef{JobId: job.GetJobId()})
				if err != nil {
					if ctx.Err() != nil {
						return last, nil
					}
					return last, err
				}
				return j, nil
			}
			b, isJob := ev.Body.(*leylinev1.Event_Job)
			if !isJob || b.Job.GetJobId() != job.GetJobId() {
				s.Apply(ev)
				continue
			}
			last = b.Job
			if s.app.JSON {
				if err := s.app.printJSON(last); err != nil {
					return last, err
				}
			}
			if !isLiveJob(last) {
				return last, nil
			}
			progress.show(last.GetStatusDetail())
		}
	}
}

// recordURI is the recording the job produces. A record job always names one, from the moment it
// exists; falling back to the id keeps the line printable if a future daemon ever does not.
func recordURI(job *leylinev1.Job) string {
	for _, u := range job.GetResultUris() {
		if strings.HasPrefix(u, "ley://recordings/") {
			return u
		}
	}
	return leyline.RecordingURI(job.GetJobId())
}

// recordBanner is the first block of a run: what is being recorded, in what, what opens and
// closes the files, and when it stops. One fact per line, each led by a label word, as
// `ley tune`'s banner is. `m` is the manifest the daemon wrote, or nil when it is not there yet.
func recordBanner(s *verbSession, o recordOptions, m *leyline.RecordingManifest, dir string, playing bool) string {
	st := s.app.ErrStyle
	lines := []string{
		leadLabel(st, "Recording", recordWhat(o, m)),
		leadLabel(st, "Writing  ", recordFormat(o, m)),
	}
	if o.gated {
		gate := fmt.Sprintf("squelch, %s pre-roll, %s hang",
			recordSpan(o.pre, 500*time.Millisecond), recordSpan(o.hang, 5*time.Second))
		if m != nil && m.Gate != nil {
			gate = fmt.Sprintf("squelch, %s pre-roll, %s hang",
				recordSpan(time.Duration(m.Gate.PreRollMs)*time.Millisecond, 0),
				recordSpan(time.Duration(m.Gate.HangMs)*time.Millisecond, 0))
		}
		if m != nil && m.SquelchDBFS != nil {
			gate += fmt.Sprintf(", below %.0f dBFS is silence", *m.SquelchDBFS)
		}
		lines = append(lines, leadLabel(st, "Gate     ", gate))
	}
	if radio := recordRadio(m, manifestGainElements(s.State.GetDevices(), m)); radio != "" {
		lines = append(lines, leadLabel(st, "Radio    ", radio))
	}
	lines = append(lines, leadLabel(st, "Until    ", recordUntil(o)))
	if playing {
		lines = append(lines, leadLabel(st, "Audio    ", "playing through the daemon's speakers while it records"))
	}
	if dir != "" {
		lines = append(lines, st.Muted(dir))
	}
	if !o.detach {
		lines = append(lines, st.Muted("Ctrl-C stops; the recording stays."))
	}
	return strings.Join(lines, "\n")
}

// gainWrites is --gain as a job's writes (RecordConfig.gains, ScanConfig.gains), in the order
// typed: one with no element for a bare level (the daemon's first stage, common.proto GainWrite),
// one per stage for pairs. The stage names go as typed; the daemon matches them ignoring case and
// fails the job on one the radio does not have. nil leaves the radio's gain alone.
func gainWrites(flag string) []*leylinev1.GainWrite {
	settings, err := units.ParseGains(flag)
	if flag == "" || err != nil {
		return nil
	}
	writes := make([]*leylinev1.GainWrite, len(settings))
	for i, g := range settings {
		writes[i] = &leylinev1.GainWrite{Element: g.Element}
		if g.Auto {
			writes[i].Value = &leylinev1.GainWrite_Auto{Auto: true}
		} else {
			writes[i].Value = &leylinev1.GainWrite_Db{Db: g.DB}
		}
	}
	return writes
}

// recordRadio is the banner's radio line: the model and the gain the take started at, from the
// manifest, so a gain the daemon did not apply shows here rather than in the file. The gain
// prints as every screen prints it (stageGainWords); els is the radio's gain elements when the
// daemon still lists it, which is how a switch reads on or off. A stage on auto has no level in
// the manifest and is left out, and the line is "" without a manifest, a device or a stage set
// by hand.
func recordRadio(m *leyline.RecordingManifest, els []*leylinev1.GainElement) string {
	if m == nil || m.Device == nil || m.Device.Model == "" || len(m.Gains) == 0 {
		return ""
	}
	return m.Device.Model + ", " + stageGainWords(manifestGains(m), els)
}

// manifestGains is a manifest's gains as the contract's GainState, for stageGainWords.
func manifestGains(m *leyline.RecordingManifest) []*leylinev1.GainState {
	gains := make([]*leylinev1.GainState, len(m.Gains))
	for i, g := range m.Gains {
		gains[i] = &leylinev1.GainState{Element: g.Element, Db: g.ValueDB}
	}
	return gains
}

// manifestGainElements is the gain elements of the radio a recording was made on, from the
// daemon's device list: the device with the manifest's driver and serial (and model, when it has
// no serial). nil when the daemon no longer lists it.
func manifestGainElements(devs []*leylinev1.DeviceDescriptor, m *leyline.RecordingManifest) []*leylinev1.GainElement {
	if m == nil || m.Device == nil {
		return nil
	}
	for _, d := range devs {
		if d.GetDriver() == m.Device.Driver && d.GetSerial() == m.Device.Serial && (m.Device.Serial != "" || d.GetModel() == m.Device.Model) {
			return d.GetGainElements()
		}
	}
	return nil
}

// recordWhat is the banner's first value: where the recording is listening, and what that is.
func recordWhat(o recordOptions, m *leyline.RecordingManifest) string {
	hz := o.freqHz
	if m != nil && m.FrequencyHz != 0 {
		hz = m.FrequencyHz
	}
	where := units.FormatFrequency(hz)
	if o.channelID != "" {
		where += " " + o.channelID
	}
	var about []string
	if !o.iq {
		mode := strings.ToUpper(leyline.ModeName(o.mode))
		if m != nil && m.Mode != "" {
			mode = m.Mode
		}
		about = append(about, mode)
	}
	if b := bandplan.BandFor(hz); b != nil {
		about = append(about, b.Name)
	}
	if len(about) == 0 {
		return where
	}
	return where + " (" + strings.Join(about, ", ") + ")"
}

// recordFormat is the banner's second value: what is being written, at what rate.
func recordFormat(o recordOptions, m *leyline.RecordingManifest) string {
	if m == nil {
		if o.iq {
			return "raw samples, cf32"
		}
		return "audio WAV"
	}
	if m.Kind == "iq" {
		return fmt.Sprintf("raw samples, cf32 at %.3f MSPS", float64(m.SampleRate)/1e6)
	}
	return fmt.Sprintf("audio WAV, %g kHz mono", float64(m.SampleRate)/1000)
}

// recordUntil is the banner's third value: what ends the recording.
func recordUntil(o recordOptions) string {
	switch {
	case o.forDur > 0:
		return recordSpan(o.forDur, 0) + " have passed"
	case o.quiet > 0:
		return recordSpan(o.quiet, 0) + " with nothing on the air"
	default:
		return "cancelled"
	}
}

// recordSpan renders a duration the daemon may have defaulted: the flag when it was given, the
// daemon's own default otherwise, so the banner never states a number nobody chose.
func recordSpan(given, def time.Duration) string {
	if given == 0 {
		given = def
	}
	if given < time.Second {
		return fmt.Sprintf("%d ms", given.Milliseconds())
	}
	return forPhrase(given)
}

// recordFailure turns the daemon's refusal into the sentence the reader acts on.
func recordFailure(s *verbSession, o recordOptions, err error) error {
	st := s.app.ErrStyle
	switch leyline.Code(err) {
	case leyline.CodeDeviceBusy:
		msg := leylineMessage(err, "the radio is busy")
		return &friendlyError{msg: msg + ". " + st.Cmd("ley record "+o.input+" --take-over") + " records anyway, and hands the radio back afterwards", cause: err}
	case leyline.CodeFailedPrecondition:
		return &friendlyError{msg: leylineMessage(err, "the recording cannot start"), cause: err}
	case leyline.CodeNoDevice, leyline.CodeFreqOutOfRange:
		return &friendlyError{msg: leylineMessage(err, "no radio here can hear that") + ". " + st.Cmd("ley devices") + " lists what is here and what it can tune", cause: err}
	}
	return err
}

// recordFailureDetail is a FAILED job's status detail, with its stable code kept.
func recordFailureDetail(job *leylinev1.Job) string {
	detail := job.GetStatusDetail()
	if code := job.GetError().GetCode(); code != "" {
		return detail + " [" + code + "]"
	}
	return detail
}
