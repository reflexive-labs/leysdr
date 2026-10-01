// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"fmt"
	"math"
	"strconv"
	"strings"
	"unicode"

	"github.com/spf13/cobra"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
	"github.com/reflexive-labs/leysdr/go/pkg/bandplan"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
	"github.com/reflexive-labs/leysdr/go/pkg/units"
)

// tuneFlags holds the raw flag values before parsing.
type tuneFlags struct {
	mode, device, squelch, bw, volume, gain string
	rate                                    uint64
	noAudio, persistent, retune             bool
}

// addTuneFlags registers the tune flag set on cmd (shared with play).
func addTuneFlags(cmd *cobra.Command, f *tuneFlags, withDevice bool) {
	addSignalFlags(cmd, f, withDevice)
	cmd.Flags().BoolVar(&f.noAudio, "no-audio", false, "decode but do not play through the speakers (use with --persistent or --json)")
	cmd.Flags().BoolVar(&f.persistent, "persistent", false, "leave the channel running after the command exits and print its ids (for scripts)")
	cmd.Flags().StringVar(&f.volume, "volume", "1", "speaker volume: 0 to 1, or a percentage like 50%")
}

// addSignalFlags registers the flags that describe the signal itself -- how
// to tune and decode it, not where the audio goes -- so listen, which has no
// speakers, shares tune's spelling and help without its playback flags.
func addSignalFlags(cmd *cobra.Command, f *tuneFlags, withDevice bool) {
	cmd.Flags().StringVar(&f.mode, "mode", "", "how to decode: nfm (two-way voice), wfm (broadcast), am (airband), usb, lsb, cw, raw; fm or ssb pick by frequency (default: by band; ley help modes)")
	cmd.Flags().StringVar(&f.bw, "bw", "", "how wide a slice of spectrum to listen to: a bare number is kHz (12.5), or 200k, 12500 (default: the mode's usual width)")
	if withDevice {
		addRadioFlags(cmd, f, true)
	}
	cmd.Flags().StringVar(&f.gain, "gain", "", gainHelp+"; default: leave the radio's setting")
	cmd.Flags().StringVar(&f.squelch, "squelch", "", "mute the audio when the signal is weaker than this level: auto (default for voice modes), off, or a level like -40 (dBFS; 0 is the loudest possible)")
}

// addRadioFlags registers the flags that say which radio to use and what may
// be done to it. withRate leaves out the capture rate, for a view whose own
// --rate is frames a second.
func addRadioFlags(cmd *cobra.Command, f *tuneFlags, withRate bool) {
	cmd.Flags().StringVar(&f.device, "device", "", "which radio: an id (dev_...), id prefix or row number from 'ley devices', e.g. --device 2 (default: the first)")
	if withRate {
		cmd.Flags().Uint64Var(&f.rate, "rate", 0, "sample rate in Hz when the radio is first tuned, e.g. 2400000; also the width of band it covers (default: the radio's own)")
	}
	cmd.Flags().BoolVar(&f.retune, "retune", false, "move the radio even when other channels are listening on it (they fall silent); without it tune refuses and says who is listening")
}

// modeDefault is what a caller knows about the mode before the flags are
// read: play passes the sidecar's mode, tune passes a preset's mode (or
// UNSPECIFIED to fall back to the band table). reason explains it. bw is the
// width that goes with the mode, when the source has one: a plan channel's own
// width (MURS 1 is 11.25 kHz) overrides the band's, as its mode does.
type modeDefault struct {
	mode   leylinev1.DemodMode
	reason string
	bw     uint32
}

// parse converts raw flags into tuneOptions. Mode precedence: explicit
// --mode > def (sidecar/preset) > band default > NFM; the rationale is kept
// only when the mode was inferred. Squelch: explicit flag, else auto for NFM
// and AM, else off.
func (f *tuneFlags) parse(input string, freq uint64, def modeDefault) (*tuneOptions, error) {
	o := &tuneOptions{freq: freq, input: input, device: f.device, rate: f.rate, noAudio: f.noAudio, persistent: f.persistent, squelch: math.NaN(), retune: f.retune, gain: f.gain}
	if f.gain != "" {
		if _, err := units.ParseGains(f.gain); err != nil {
			return nil, usageError(fmt.Errorf("--gain %w", err))
		}
	}
	o.band = bandplan.BandFor(freq)
	switch {
	case f.mode != "":
		m, reason, err := bandplan.ResolveMode(f.mode, freq)
		if err != nil {
			return nil, usageError(fmt.Errorf("--mode %w", err))
		}
		o.mode, o.modeReason = m, reason
	case def.mode != leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED:
		o.mode, o.modeReason = def.mode, def.reason
	default:
		m, band := bandplan.DefaultMode(freq)
		o.mode = m
		if band != nil {
			o.modeReason = band.Name + " band default"
		} else {
			o.modeReason = "no band recognised, using NFM"
		}
	}
	switch {
	case f.bw != "":
		bw, err := units.ParseBandwidth(f.bw)
		if err != nil {
			return nil, usageError(fmt.Errorf("--bw %w (examples: 12.5, 12.5k, 200k, 12500)", err))
		}
		o.bw = bw
	case def.bw > 0 && o.mode == def.mode:
		// The channel's width goes with the channel's mode; under an explicit
		// --mode the mode's own default applies, as it does for a band.
		o.bw = def.bw
	default:
		o.bw = bandplan.BandwidthFor(freq, o.mode)
	}
	if f.squelch != "" {
		db, auto, err := units.ParseSquelch(f.squelch)
		if err != nil {
			return nil, usageError(fmt.Errorf("--squelch %w (examples: -40, -40dB, off, auto)", err))
		}
		o.squelch, o.squelchAuto = db, auto
	} else if o.mode == leylinev1.DemodMode_NFM || o.mode == leylinev1.DemodMode_AM {
		// Voice modes squelch by default whatever the output looks like: a
		// channel left open plays band noise, and a script that wants that
		// asks for it with --squelch off.
		o.squelchAuto = true
	}
	v, err := units.ParseVolume(f.volume)
	if err != nil {
		return nil, usageError(fmt.Errorf("--volume %w (examples: 0.5, 50%%)", err))
	}
	o.volume = v
	return o, nil
}

// resolveTuneTarget reads tune's positional: a frequency (bare numbers are MHz)
// first, then a preset name; anything else lists the nearest presets. Under
// --band the positional is a channel of that band's plan (the plan's KTD8).
func resolveTuneTarget(arg, bandName string) (hz uint64, def modeDefault, err error) {
	band, err := bandFlag(bandName)
	if err != nil {
		return 0, def, err
	}
	t, err := resolveDialTarget(arg, "tune", "ley tune 146.52, ley tune noaa, ley tune 16 --band marine", "146.52 (MHz)", band)
	if err != nil {
		return 0, def, err
	}
	if t.Preset != nil {
		def = modeDefault{mode: t.Preset.Mode, reason: "preset " + t.Preset.Name + ": " + t.Preset.Description, bw: t.Preset.BandwidthHz}
	}
	return t.Hz, def, nil
}

func newTuneCommand(app *App) *cobra.Command {
	var f tuneFlags
	var band string
	cmd := &cobra.Command{
		Use:   "tune <frequency|preset|channel --band BAND>",
		Short: "Listen to a frequency through the speakers",
		Long: `tune picks a radio, tunes it to the frequency (or a preset such as noaa or
calling; see ley help presets), decodes it and plays the audio until Ctrl-C.

A bare number is MHz (146.52, 7.040, 121.5); add a unit to be exact (1010k,
146520000). A channel of a band's plan is named by its own word (wx3,
marine16, cb19, ch5) or, with --band, the way the radio prints it: 'ley tune
16 --band marine' is marine channel 16, where bare '16' is 16 MHz ('ley bands
marine' lists the plan). The mode (how the signal is decoded: nfm, am, wfm, ...) is
chosen from the band when --mode is not given, and the squelch (mute the
audio while the signal is weaker than a level) is measured from the band's
noise floor unless you set one. tune prints every decision it made so a
wrong guess is easy to correct with 'ley set' from another terminal. With
--persistent the channel keeps running after tune exits and its ids are
printed for scripts. Longer explanations: ley help squelch, modes, gain.

When the radio is already tuned for someone else and the new frequency falls
outside the band it covers, tune refuses rather than silence them; --retune
moves it anyway.`,
		Example: `  ley tune 146.52            2 m calling frequency, NFM, squelch auto
  ley tune noaa              NOAA weather channel 1 (162.550 MHz); try wx2..7
  ley tune 16 --band marine  marine channel 16 by its own number (156.800 MHz)
  ley tune 101.1 --mode fm   FM broadcast (fm means WFM here)
  ley tune 7.040 --mode lsb  40 m amateur band, lower sideband
  ley tune 162.55 --squelch -50 --volume 50%
  ley tune 101.1 --gain 30 --retune   set the gain; move a radio others are using`,
		GroupID: GroupListening,
		Args:    cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			arg := ""
			if len(args) == 1 {
				arg = args[0]
			}
			freq, def, err := resolveTuneTarget(arg, band)
			if err != nil {
				return err
			}
			o, err := f.parse(arg, freq, def)
			if err != nil {
				return err
			}
			s, err := openSession(cmd.Context(), app)
			if err != nil {
				return err
			}
			// A live session's prose goes to stderr, not to stdout where a script
			// reads: the meter is already on stderr, and a banner on stdout split
			// one screen across two streams. Set here rather than in runTune,
			// because play prints its first line before runTune is reached. Ids
			// stay on stdout in printCreated.
			s.proseToStderr = true
			defer s.Close()
			if s.device, err = pickDevice(s.State, o.device); err != nil {
				return err
			}
			return runTune(cmd.Context(), s, o)
		},
	}
	addTuneFlags(cmd, &f, true)
	cmd.Flags().StringVar(&band, "band", "", "read the argument as a channel of this band's plan, as its radios print it: --band marine 16, --band gmrs 5 (ley bands)")
	return cmd
}

// runTune performs the tune lifecycle on an open session whose device is set.
func runTune(ctx context.Context, s *verbSession, o *tuneOptions) error {
	if err := s.bringUp(ctx, o); err != nil {
		return err
	}
	if o.persistent {
		if s.squelchNote != "" {
			// A persistent tune has no banner to carry the measurement, and the
			// threshold it chose is a decision like every other: stderr, so the
			// ids on stdout stay a script's.
			fmt.Fprintln(s.app.Stderr, s.squelchNote)
		}
		if s.failureNote != "" {
			fmt.Fprintln(s.app.Stderr, s.failureNote)
		}
		return s.printCreated()
	}
	err := s.live(ctx, o)
	s.teardown(ctx)
	if err == nil && (ctx.Err() != nil || s.channelGone) {
		s.sayClosed()
	}
	return err
}

// bringUp is the first half of a tune: the capture (reused, retuned or
// created), the gain, the channel with its initial squelch, and the speakers
// when asked for. It announces each decision as it makes it and removes what
// it created when a later step fails, so a caller that returns its error
// leaves the radio as it found it. `ley tune` goes on to the live phase or
// prints the ids; the MCP adapter's tune tool stops here.
func (s *verbSession) bringUp(ctx context.Context, o *tuneOptions) error {
	// An impossible frequency fails before any decision is announced, so the
	// error is the only output. The capture centre is what the device tunes.
	target := o.freq
	if o.captureCenter != 0 {
		target = o.captureCenter
	}
	if capture := leyline.FindCapture(s.State, s.device.DeviceId); capture == nil || !covers(capture, o.freq, o.bw) {
		if err := s.checkRange(o.input, target); err != nil {
			return err
		}
	}
	if warn := bandWarning(o.input, o.freq); warn != "" {
		fmt.Fprintln(s.app.Stderr, warn)
	}
	if o.modeReason != "" {
		s.say("using %s: %s\n", strings.ToUpper(leyline.ModeName(o.mode)), o.modeReason)
	}
	if err := s.ensureCapture(ctx, o); err != nil {
		return err
	}
	if err := s.applyGain(ctx, o); err != nil {
		if s.createdCapture {
			s.teardown(ctx)
		}
		return err
	}
	if err := s.createChannel(ctx, o); err != nil {
		// The channel may exist already (a rejected initial squelch): remove
		// what this tune created, the capture included when it was ours.
		s.teardown(ctx)
		return err
	}
	if !o.noAudio {
		if err := s.attachAudio(ctx, o); err != nil {
			s.teardown(ctx)
			return err
		}
	}
	return nil
}

// sayClosed is the one line an interrupted live session leaves behind: what
// happened to the radio, on stderr because the run's stdout may be a
// script's. Under --json the events already said it.
func (s *verbSession) sayClosed() {
	if s.app.JSON {
		return
	}
	st := s.app.ErrStyle
	// "channel removed" is this session's own doing; when somebody else
	// removed it the line above already said so, and claiming it twice would
	// read as two channels having gone.
	did := "stopped; channel removed, "
	if s.channelGone {
		did = "stopped; "
	}
	if s.freedRadio {
		fmt.Fprintf(s.app.Stderr, "%s%s\n", did, st.Ok("radio free"))
		return
	}
	fmt.Fprintf(s.app.Stderr, "%sthe radio stays tuned (%s lists what is on it)\n", did, st.Cmd("ley state"))
}

// bandWarning catches the classic slip of typing a kHz figure as MHz: when
// the MHz reading falls in no known band but the same digits read as kHz do,
// it returns a one-line warning naming the kHz spelling; "" otherwise.
func bandWarning(input string, hz uint64) string {
	input = strings.TrimSpace(input)
	if input == "" || strings.IndexFunc(input, func(r rune) bool { return !unicode.IsDigit(r) && r != '.' }) >= 0 {
		return ""
	}
	v, err := strconv.ParseFloat(input, 64)
	if err != nil || v <= 0 || bandplan.BandFor(hz) != nil {
		return ""
	}
	khz := uint64(math.Round(v * 1e3))
	b := bandplan.BandFor(khz)
	if b == nil || khz == hz {
		return ""
	}
	return fmt.Sprintf("%s MHz is not a band I know; for %s kHz %s type %sk", input, input, b.Name, input)
}

// printCreated reports the created objects (persistent mode).
func (s *verbSession) printCreated() error {
	if s.app.JSON {
		if err := s.app.printJSON(s.Capture); err != nil {
			return err
		}
		if err := s.app.printJSON(s.Channel); err != nil {
			return err
		}
		if s.Sink != nil {
			return s.app.printJSON(s.Sink)
		}
		return nil
	}
	fmt.Fprintf(s.app.Stdout, "capture %s\nchannel %s\n", s.Capture.CaptureId, s.Channel.ChannelId)
	if s.Sink != nil {
		fmt.Fprintf(s.app.Stdout, "sink %s\n", s.Sink.SinkId)
	}
	fmt.Fprintf(s.app.Stdout, "adjust with: ley set squelch -40 --channel %s\n", s.Channel.ChannelId)
	return nil
}

// banner is the first line of a live run: what is playing, on what, and how
// to adjust it from another terminal.
func (s *verbSession) banner(o *tuneOptions) string {
	where := strings.ToUpper(leyline.ModeName(o.mode))
	if o.band != nil {
		where += ", " + o.band.Name
	}
	squelch := s.squelchNote
	if squelch == "" {
		if math.IsNaN(o.squelch) {
			squelch = "Squelch off."
		} else {
			squelch = fmt.Sprintf("Squelch %.0f dBFS.", o.squelch)
		}
	}
	st := s.app.Style
	if s.app.JSON || s.proseToStderr {
		st = s.app.ErrStyle
	}
	// One fact per line, each led by a label word. The lines
	// are not padded into a column because three golden substrings pin
	// "Squelch <value>" and "<device>, gain auto" with single spaces; the
	// leading word carries Label ink instead.
	lines := []string{
		leadLabel(st, "Listening to", fmt.Sprintf("%s (%s)", units.FormatFrequency(o.freq), where)),
		s.bannerSource(st),
		leadWord(st, squelch),
	}
	// The problem the squelch measurement row showed, if any: the line a
	// newcomer with no antenna most needs, said here and nowhere else in the
	// session. Clipping is the live loop's, once the hold has seen it last.
	if s.bandNote != "" {
		lines = append(lines, leadWord(st, s.bandNote))
	}
	lines = append(lines,
		st.Muted("Ctrl-C stops."),
		st.Muted("From another terminal:")+" "+st.Cmd("ley set squelch -50")+st.Muted(" · ")+st.Cmd(s.bannerSecondHint())+st.Muted(" · ")+st.Cmd("ley spectrum"),
	)
	return strings.Join(lines, "\n") + "\n"
}

// bannerSource is the banner's second line: the radio, or what is being played
// through it. A recording has no gain and no tuning range, so "Radio
// FilePlaybackDevice, no gain control" would be a wasted line.
func (s *verbSession) bannerSource(st ui.Style) string {
	if s.sourceLine == "" {
		return leadLabel(st, "Radio", fmt.Sprintf("%s, %s", s.device.Model, stageGainWords(s.Capture.GetGains(), s.device.GetGainElements())))
	}
	// An unknown width is not a narrow one: piped, the line must arrive whole.
	line := s.sourceLine
	if st.Width > 0 {
		line = st.Truncate(line, max(20, st.Width-8))
	}
	return leadLabel(st, "Playing", line)
}

// bannerSecondHint keeps the "from another terminal" line suggesting a command
// that works. A file device refuses every gain write, so `ley set gain` there
// would fail.
func (s *verbSession) bannerSecondHint() string {
	if len(s.Capture.GetGains()) == 0 {
		return "ley set mode am"
	}
	return "ley set gain 30"
}

// leadLabel writes one banner row: the topic in Label ink, then the value.
func leadLabel(st ui.Style, label, value string) string {
	return st.Label(label) + " " + value
}

// leadWord inks the first word of a ready-made sentence, so a line whose
// wording is pinned by a golden still starts with a Label-inked word.
func leadWord(st ui.Style, sentence string) string {
	i := strings.IndexByte(sentence, ' ')
	if i <= 0 {
		return st.Label(sentence)
	}
	return leadLabel(st, sentence[:i], sentence[i+1:])
}

// live holds the session open, refreshing the meter line in place and
// printing events caused by other clients, until ctx is cancelled (Ctrl-C).
// Under --json stdout carries NDJSON only; the banner goes to stderr.
func (s *verbSession) live(ctx context.Context, o *tuneOptions) error {
	meter := &meterSink{w: s.app.Stderr, style: s.app.ErrStyle, tty: s.app.IsErrTTY()}
	clearLine := meter.clear
	tctx, cancel := context.WithCancel(ctx)
	defer cancel()
	msgs, terrs, err := s.Client.WatchTelemetry(tctx, &leylinev1.TelemetrySubscription{
		Scope: &leylinev1.TelemetrySubscription_ChannelId{ChannelId: s.Channel.ChannelId},
		Types: []leylinev1.TelemetryType{
			leylinev1.TelemetryType_METER,
			leylinev1.TelemetryType_SQUELCH_TRANSITION,
			leylinev1.TelemetryType_SUB_AUDIBLE,
		},
	})
	if err != nil {
		return err
	}
	// The capture's level, for the clipping line: one more subscription,
	// scoped to the capture, because the level is the capture's and not the
	// channel's.
	levels := s.watchLevel(tctx, s.Channel.GetCaptureId())
	// ended handles a stream's end: Ctrl-C and a daemon error are the
	// caller's; a clean end (the daemon closed the stream, as it does when
	// shutting down) is reported once on stderr and the run stops with exit 0.
	ended := func(what string, err error) error {
		clearLine()
		if ctx.Err() != nil {
			return nil
		}
		if err != nil {
			return err
		}
		fmt.Fprintf(s.app.Stderr, "the daemon closed the %s stream (shutting down?); ley daemon status says whether it is still running\n", what)
		return nil
	}
	s.say("%s", s.banner(o))
	// opened is the open edge of the transmission in progress, so the meter
	// can count its time on air; nil while the squelch is closed and when the
	// session subscribed after the edge.
	var opened *leylinev1.SampleTime
	for {
		select {
		case <-ctx.Done():
			clearLine()
			return nil
		case m, ok := <-msgs:
			if !ok {
				return ended("telemetry", <-terrs)
			}
			if s.app.JSON {
				if err := s.app.printJSON(m); err != nil {
					return err
				}
				continue
			}
			switch b := m.Body.(type) {
			case *leylinev1.TelemetryMsg_Meter:
				hz, _ := leyline.ChannelFrequency(s.State, s.Channel)
				air := onAirSince(opened, m.Time, leyline.ChannelCaptureRate(s.State, s.Channel))
				meter.write(meter.line(hz, s.Channel.Mode, b.Meter, s.Channel.SquelchDb, air))
			case *leylinev1.TelemetryMsg_SubAudible:
				// A tone that has appeared or changed is worth a line; the
				// heartbeat that repeats it is not, so only a change prints.
				if line, ok := s.subAudible.line(b.SubAudible, s.app.ErrStyle); ok {
					clearLine()
					fmt.Fprintln(s.app.Stderr, line)
				}
			case *leylinev1.TelemetryMsg_Squelch:
				// A transmission that has ended is a fact worth keeping, so it
				// scrolls above the meter rather than replacing it, dated
				// through the capture's anchor when one covers it. The meter
				// redraws itself on its next tick.
				if b.Squelch.GetOpen() {
					opened = m.Time
					break
				}
				if t, ok := closedTransmission(b.Squelch, leyline.ChannelCaptureRate(s.State, s.Channel)); ok {
					t.start, _ = transmissionStart(b.Squelch, m.Time, captureAnchor(s.State, s.Channel.GetCaptureId()))
					clearLine()
					fmt.Fprintln(s.app.Stderr, t.render(s.app.ErrStyle))
				}
				opened = nil
			}
		case m, ok := <-levels:
			if !ok {
				levels = nil
				continue
			}
			if s.app.JSON {
				if err := s.app.printJSON(m); err != nil {
					return err
				}
				continue
			}
			b, ok := m.Body.(*leylinev1.TelemetryMsg_CaptureLevel)
			if !ok {
				continue
			}
			// One line when the hold raises clipping, carrying the reading
			// that raised it, and nothing when it clears: the transmission's
			// own line already carries its peak (plans/app.md, M2-10).
			if s.clip.fold(b.CaptureLevel, m.Time, leyline.ChannelCaptureRate(s.State, s.Channel)) {
				if note := clippingWords(b.CaptureLevel, s.Capture.GetGains(), s.device.GetGainElements()); note != "" {
					clearLine()
					fmt.Fprintln(s.app.Stderr, leadWord(s.app.ErrStyle, note))
				}
			}
		case ev, ok := <-s.Events():
			if !ok {
				return ended("event", <-s.EventErrs())
			}
			// The mirror's copy of the object, before the event replaces it:
			// what a person needs is which field moved, and the diff is the
			// only place that answer exists (invariant 6 sends whole objects).
			before := s.beforeEvent(ev)
			if !s.Apply(ev) {
				continue
			}
			line, ended := "", false
			if !s.Mine(ev) {
				line, ended = s.changeLine(before, ev)
			}
			switch {
			case s.app.JSON:
				if err := s.app.printJSON(ev); err != nil {
					return err
				}
			case line != "":
				clearLine()
				// Prose, and printed after meter.clear(), which only clears
				// stderr: on stdout it would corrupt the redraw whenever the
				// two streams point at different places.
				fmt.Fprintln(s.app.Stderr, line)
			}
			if ended {
				// The channel this session was listening to is gone. Carrying
				// on would draw a meter for something that no longer exists.
				clearLine()
				s.channelGone = true
				return nil
			}
		}
	}
}
