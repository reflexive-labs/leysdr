package cli

import (
	"context"
	"fmt"
	"math"
	"strconv"
	"strings"
	"unicode"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// tuneFlags holds the raw flag values before parsing.
type tuneFlags struct {
	mode, device, squelch, bw, volume, gain string
	rate                                    uint64
	noAudio, persistent, retune             bool
}

// addTuneFlags registers the tune flag set on cmd (shared with play).
func addTuneFlags(cmd *cobra.Command, f *tuneFlags, withDevice bool) {
	cmd.Flags().StringVar(&f.mode, "mode", "", "how to decode: nfm (two-way voice), wfm (broadcast), am (airband), usb, lsb, cw, raw; fm or ssb pick by frequency (default: by band; ley help modes)")
	cmd.Flags().StringVar(&f.bw, "bw", "", "how wide a slice of spectrum to listen to: a bare number is kHz (12.5), or 200k, 12500 (default: the mode's usual width)")
	if withDevice {
		cmd.Flags().StringVar(&f.device, "device", "", "which radio: an id (dev_...), id prefix or row number from 'ley devices', e.g. --device 2 (default: the first)")
		cmd.Flags().Uint64Var(&f.rate, "rate", 0, "sample rate in Hz when the radio is first tuned, e.g. 2400000; also the width of band it covers (default: the radio's own)")
		cmd.Flags().BoolVar(&f.retune, "retune", false, "move the radio even when other channels are listening on it (they fall silent); without it tune refuses and says who is listening")
	}
	cmd.Flags().StringVar(&f.gain, "gain", "", "receiver gain once the radio is tuned: auto, or dB such as 30 (default: leave the radio's setting; ley help gain)")
	cmd.Flags().StringVar(&f.squelch, "squelch", "", "mute the audio when the signal is weaker than this level: auto (default for voice modes), off, or a level like -40 (dBFS; 0 is the loudest possible)")
	cmd.Flags().BoolVar(&f.noAudio, "no-audio", false, "decode but do not play through the speakers (use with --persistent or --json)")
	cmd.Flags().BoolVar(&f.persistent, "persistent", false, "leave the channel running after the command exits and print its ids (for scripts)")
	cmd.Flags().StringVar(&f.volume, "volume", "1", "speaker volume: 0 to 1, or a percentage like 50% (default: full)")
}

// modeDefault is what a caller knows about the mode before the flags are
// read: play passes the sidecar's mode, tune passes a preset's mode (or
// UNSPECIFIED to fall back to the band table). reason explains it.
type modeDefault struct {
	mode   leylinev1.DemodMode
	reason string
}

// parse converts raw flags into tuneOptions. Mode precedence: explicit
// --mode > def (sidecar/preset) > band default > NFM; the rationale is kept
// only when the mode was inferred. Squelch: explicit flag, else auto for NFM
// and AM in interactive runs, else off.
func (f *tuneFlags) parse(app *App, input string, freq uint64, def modeDefault) (*tuneOptions, error) {
	o := &tuneOptions{freq: freq, input: input, device: f.device, rate: f.rate, noAudio: f.noAudio, persistent: f.persistent, squelch: math.NaN(), retune: f.retune, gain: f.gain}
	if f.gain != "" {
		if _, _, err := leyline.ParseGain(f.gain); err != nil {
			return nil, usageError(fmt.Errorf("--gain: %w", err))
		}
	}
	o.band = leyline.BandFor(freq)
	switch {
	case f.mode != "":
		m, reason, err := leyline.ResolveMode(f.mode, freq)
		if err != nil {
			return nil, usageError(fmt.Errorf("--mode: %w", err))
		}
		o.mode, o.modeReason = m, reason
	case def.mode != leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED:
		o.mode, o.modeReason = def.mode, def.reason
	default:
		m, band := leyline.DefaultMode(freq)
		o.mode = m
		if band != nil {
			o.modeReason = band.Name + " band default"
		} else {
			o.modeReason = "no band recognised, using NFM"
		}
	}
	if f.bw != "" {
		bw, err := leyline.ParseBandwidth(f.bw)
		if err != nil {
			return nil, usageError(fmt.Errorf("--bw: %w (examples: 12.5, 12.5k, 200k, 12500)", err))
		}
		o.bw = bw
	} else {
		o.bw = leyline.BandwidthFor(freq, o.mode)
	}
	if f.squelch != "" {
		db, auto, err := leyline.ParseSquelch(f.squelch)
		if err != nil {
			return nil, usageError(fmt.Errorf("--squelch: %w (examples: -40, -40dB, off, auto)", err))
		}
		o.squelch, o.squelchAuto = db, auto
	} else if !app.JSON && !f.persistent && (o.mode == leylinev1.DemodMode_NFM || o.mode == leylinev1.DemodMode_AM) {
		o.squelchAuto = true
	}
	v, err := leyline.ParseVolume(f.volume)
	if err != nil {
		return nil, usageError(fmt.Errorf("--volume: %w (examples: 0.5, 50%%)", err))
	}
	o.volume = v
	return o, nil
}

// resolveTuneTarget reads tune's positional: a frequency (bare numbers are MHz)
// first, then a preset name; anything else lists the nearest presets.
func resolveTuneTarget(arg string) (hz uint64, def modeDefault, err error) {
	if arg == "" {
		return 0, def, usageErrorf("tune needs a frequency or preset: ley tune 146.52, ley tune noaa (ley help presets lists them)")
	}
	if r := rune(arg[0]); unicode.IsDigit(r) || r == '.' || r == '-' || r == '+' {
		hz, err = leyline.ParseUserFrequency(arg)
		return hz, def, usageError(err)
	}
	p, err := leyline.ResolvePreset(arg)
	if err != nil {
		return 0, def, usageError(fmt.Errorf("%w; or give a frequency such as 146.52 (MHz)", err))
	}
	return p.Hz, modeDefault{mode: p.Mode, reason: "preset " + p.Name + ": " + p.Description}, nil
}

func newTuneCommand(app *App) *cobra.Command {
	var f tuneFlags
	cmd := &cobra.Command{
		Use:   "tune <frequency|preset>",
		Short: "Listen to a frequency through the speakers",
		Long: `tune picks a radio, tunes it to the frequency (or a preset such as noaa or
calling; see ley help presets), decodes it and plays the audio until Ctrl-C.

A bare number is MHz (146.52, 7.040, 121.5); add a unit to be exact (1010k,
146520000). The mode (how the signal is decoded: nfm, am, wfm, ...) is
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
  ley tune noaa              NOAA weather channel 1 (162.550 MHz); try noaa2..7
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
			freq, def, err := resolveTuneTarget(arg)
			if err != nil {
				return err
			}
			o, err := f.parse(app, arg, freq, def)
			if err != nil {
				return err
			}
			s, err := openSession(cmd.Context(), app)
			if err != nil {
				return err
			}
			defer s.close()
			if s.device, err = pickDevice(s.state, o.device); err != nil {
				return err
			}
			return runTune(cmd.Context(), s, o)
		},
	}
	addTuneFlags(cmd, &f, true)
	return cmd
}

// runTune performs the tune lifecycle on an open session whose device is set.
func runTune(ctx context.Context, s *session, o *tuneOptions) error {
	// An impossible frequency fails before any decision is announced, so the
	// error is the whole story. The capture centre is what the device tunes.
	target := o.freq
	if o.captureCenter != 0 {
		target = o.captureCenter
	}
	if cap := leyline.FindCapture(s.state, s.device.DeviceId); cap == nil || !covers(cap, o.freq, o.bw) {
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
			s.teardown()
		}
		return err
	}
	if err := s.createChannel(ctx, o); err != nil {
		// The channel may exist already (a rejected initial squelch): remove
		// what this tune created, the capture included when it was ours.
		s.teardown()
		return err
	}
	if !o.noAudio {
		if err := s.attachAudio(ctx, o); err != nil {
			s.teardown()
			return err
		}
	}
	if o.persistent {
		return s.printCreated()
	}
	defer s.teardown()
	return s.live(ctx, o)
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
	if err != nil || v <= 0 || leyline.BandFor(hz) != nil {
		return ""
	}
	khz := uint64(math.Round(v * 1e3))
	b := leyline.BandFor(khz)
	if b == nil || khz == hz {
		return ""
	}
	return fmt.Sprintf("%s MHz is not a band I know; for %s kHz %s type %sk", input, input, b.Name, input)
}

// printCreated reports the created objects (persistent mode).
func (s *session) printCreated() error {
	if s.app.JSON {
		if err := s.app.printJSON(s.capture); err != nil {
			return err
		}
		if err := s.app.printJSON(s.channel); err != nil {
			return err
		}
		if s.sink != nil {
			return s.app.printJSON(s.sink)
		}
		return nil
	}
	fmt.Fprintf(s.app.Stdout, "capture %s\nchannel %s\n", s.capture.CaptureId, s.channel.ChannelId)
	if s.sink != nil {
		fmt.Fprintf(s.app.Stdout, "sink %s\n", s.sink.SinkId)
	}
	fmt.Fprintf(s.app.Stdout, "adjust with: ley set squelch -40 --channel %s\n", s.channel.ChannelId)
	return nil
}

// banner is the first line of a live run: what is playing, on what, and how
// to adjust it from another terminal.
func (s *session) banner(o *tuneOptions) string {
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
	return fmt.Sprintf("Listening to %s (%s) on %s, %s. %s Ctrl-C stops.\nFrom another terminal: ley set squelch -50 · ley set gain 30 · ley spectrum\n",
		leyline.FormatFrequency(o.freq), where, s.device.Model, gainString(s.capture), squelch)
}

// live holds the session open, refreshing the meter line in place and
// printing events caused by other clients, until ctx is cancelled (Ctrl-C).
// Under --json stdout carries NDJSON only; the banner goes to stderr.
func (s *session) live(ctx context.Context, o *tuneOptions) error {
	lastLen := 0
	clear := func() {
		if lastLen > 0 {
			fmt.Fprintf(s.app.Stdout, "\r%s\r", strings.Repeat(" ", lastLen))
			lastLen = 0
		}
	}
	tctx, cancel := context.WithCancel(ctx)
	defer cancel()
	msgs, terrs, err := s.client.WatchTelemetry(tctx, &leylinev1.TelemetrySubscription{
		Scope: &leylinev1.TelemetrySubscription_ChannelId{ChannelId: s.channel.ChannelId},
		Types: []leylinev1.TelemetryType{leylinev1.TelemetryType_METER, leylinev1.TelemetryType_SQUELCH_TRANSITION},
	})
	if err != nil {
		return err
	}
	// ended handles a stream's end: Ctrl-C and a daemon error are the
	// caller's; a clean end (the daemon closed the stream, as it does when
	// shutting down) is said once on stderr and the run stops with exit 0.
	ended := func(what string, err error) error {
		clear()
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
	for {
		select {
		case <-ctx.Done():
			clear()
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
			if mt, ok := m.Body.(*leylinev1.TelemetryMsg_Meter); ok {
				line := meterLine(channelFreq(s.channel, s.capture), s.channel.Mode, mt.Meter)
				fmt.Fprintf(s.app.Stdout, "\r%-*s", lastLen, line)
				lastLen = len(line)
			}
		case ev, ok := <-s.events:
			if !ok {
				return ended("event", <-s.eventErrs)
			}
			if !s.apply(ev) {
				continue
			}
			if ch, gone := ev.Body.(*leylinev1.Event_Channel); gone && ch.Channel.ChannelId == s.channel.ChannelId && ch.Channel.State == leylinev1.ChannelState_OUT_OF_CAPTURE && !s.mine(ev) {
				clear()
				fmt.Fprintln(s.app.Stderr, "another client retuned the radio away from this channel; ley state shows who, ley tune again to follow")
			}
			if s.app.JSON {
				if err := s.app.printJSON(ev); err != nil {
					return err
				}
				continue
			}
			if !s.mine(ev) {
				clear()
				fmt.Fprintln(s.app.Stdout, eventLine(ev, s.state))
			}
		}
	}
}
