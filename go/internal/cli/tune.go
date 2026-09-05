package cli

import (
	"context"
	"fmt"
	"math"
	"strings"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// tuneFlags holds the raw flag values before parsing.
type tuneFlags struct {
	mode, device, squelch string
	bw                    uint32
	rate                  uint64
	noAudio, persistent   bool
	volume                float64
}

// addTuneFlags registers the tune flag set on cmd (shared with play).
func addTuneFlags(cmd *cobra.Command, f *tuneFlags, withDevice bool) {
	cmd.Flags().StringVar(&f.mode, "mode", "", "demod mode: nfm|am|wfm|usb|lsb|cw (default nfm)")
	cmd.Flags().Uint32Var(&f.bw, "bw", 0, "channel bandwidth in Hz (default: mode default)")
	if withDevice {
		cmd.Flags().StringVar(&f.device, "device", "", "device ID (default: first non-file device)")
		cmd.Flags().Uint64Var(&f.rate, "rate", 0, "capture sample rate when creating a capture (default: device default)")
	}
	cmd.Flags().StringVar(&f.squelch, "squelch", "", "squelch threshold in dBFS, or 'off'")
	cmd.Flags().BoolVar(&f.noAudio, "no-audio", false, "do not attach a system_audio sink")
	cmd.Flags().BoolVar(&f.persistent, "persistent", false, "create a persistent channel, print its IDs and exit")
	cmd.Flags().Float64Var(&f.volume, "volume", 1, "system audio volume 0..1")
}

// parse converts raw flags into tuneOptions; mode "" falls back to defMode.
func (f *tuneFlags) parse(freq uint64, defMode leylinev1.DemodMode) (*tuneOptions, error) {
	o := &tuneOptions{freq: freq, device: f.device, rate: f.rate, noAudio: f.noAudio, persistent: f.persistent, volume: f.volume, squelch: math.NaN()}
	o.mode = defMode
	if f.mode != "" {
		m, err := leyline.ParseMode(f.mode)
		if err != nil {
			return nil, err
		}
		o.mode = m
	}
	if o.mode == leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED {
		o.mode = leylinev1.DemodMode_NFM
	}
	o.bw = f.bw
	if o.bw == 0 {
		o.bw = leyline.DefaultBandwidth(o.mode)
	}
	if f.squelch != "" {
		db, err := leyline.ParseSquelch(f.squelch)
		if err != nil {
			return nil, err
		}
		o.squelch = db
	}
	if o.volume < 0 || o.volume > 1 {
		return nil, fmt.Errorf("--volume must be within 0..1")
	}
	return o, nil
}

func newTuneCommand(app *App) *cobra.Command {
	var f tuneFlags
	cmd := &cobra.Command{
		Use:   "tune <freq>",
		Short: "Create a capture, channel and system-audio sink for a frequency and hold it live",
		Long: `tune picks a device, reuses or creates its capture, creates a demod channel at
<freq> and attaches a system_audio sink. It then prints a live meter line until
Ctrl-C, at which point the channel (and any capture this run created) is destroyed.
With --persistent the channel outlives the command.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			freq, err := leyline.ParseFrequency(args[0])
			if err != nil {
				return err
			}
			o, err := f.parse(freq, leylinev1.DemodMode_NFM)
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
	if err := s.ensureCapture(ctx, o); err != nil {
		return err
	}
	if err := s.createChannel(ctx, o); err != nil {
		if s.createdCapture {
			s.teardown()
		}
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
	return nil
}

// telemetryPump opens Telemetry.Subscribe on the channel and pumps messages
// into a channel; the returned error channel gets one value when it ends.
func telemetryPump(ctx context.Context, c *leyline.Client, channelID string) (<-chan *leylinev1.TelemetryMsg, <-chan error, error) {
	stream, err := c.Telemetry.Subscribe(ctx, &leylinev1.TelemetrySubscription{
		Scope: &leylinev1.TelemetrySubscription_ChannelId{ChannelId: channelID},
		Types: []leylinev1.TelemetryType{leylinev1.TelemetryType_METER, leylinev1.TelemetryType_SQUELCH_TRANSITION},
	})
	if err != nil {
		return nil, nil, err
	}
	msgs := make(chan *leylinev1.TelemetryMsg, 16)
	errs := make(chan error, 1)
	go func() {
		defer close(msgs)
		for {
			m, err := stream.Recv()
			if err != nil {
				if ctx.Err() != nil {
					errs <- ctx.Err()
				} else {
					errs <- err
				}
				return
			}
			select {
			case msgs <- m:
			case <-ctx.Done():
				errs <- ctx.Err()
				return
			}
		}
	}()
	return msgs, errs, nil
}

// live holds the session open, refreshing the meter line in place and
// printing events caused by other clients, until ctx is cancelled (Ctrl-C).
func (s *session) live(ctx context.Context, o *tuneOptions) error {
	tctx, cancel := context.WithCancel(ctx)
	defer cancel()
	msgs, terrs, err := telemetryPump(tctx, s.client, s.channel.ChannelId)
	if err != nil {
		return err
	}
	if !s.app.JSON {
		fmt.Fprintf(s.app.Stdout, "tuned %s %s on channel %s (capture %s); Ctrl-C to stop\n",
			leyline.FormatFrequency(o.freq), strings.ToUpper(leyline.ModeName(o.mode)), s.channel.ChannelId, s.capture.CaptureId)
	}
	lastLen := 0
	clear := func() {
		if lastLen > 0 {
			fmt.Fprintf(s.app.Stdout, "\r%s\r", strings.Repeat(" ", lastLen))
			lastLen = 0
		}
	}
	for {
		select {
		case <-ctx.Done():
			clear()
			return nil
		case m, ok := <-msgs:
			if !ok {
				if err := <-terrs; err != nil && ctx.Err() == nil {
					return err
				}
				return nil
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
				if err := <-s.eventErrs; err != nil && ctx.Err() == nil {
					return err
				}
				return nil
			}
			s.apply(ev)
			if ch, gone := ev.Body.(*leylinev1.Event_Channel); gone && ch.Channel.ChannelId == s.channel.ChannelId && ch.Channel.State == leylinev1.ChannelState_OUT_OF_CAPTURE && !s.mine(ev) {
				clear()
				fmt.Fprintln(s.app.Stderr, "channel moved out of capture by another client")
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
