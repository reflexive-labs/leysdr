package cli

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// AudioRow is one JSON row of `ley listen --format json`. Bulk audio frames
// have no proto message, so this shape (snake_case, pcm base64) is part of
// the documented bulk-row exception to the proto3 rule; see docs/interfaces.md.
type AudioRow struct {
	Seq         uint64 `json:"seq"`
	SampleIndex uint64 `json:"sample_index"`
	SampleRate  uint32 `json:"sample_rate"`
	Format      string `json:"format"`
	PCM         []byte `json:"pcm"`
}

// listenChannelPrefix is the id prefix that marks the positional argument as
// an existing channel rather than a frequency or preset.
const listenChannelPrefix = "chan_"

// listenTuneFlags are the tune flags listen accepts; they are meaningless
// when it attaches to a channel someone else already made.
var listenTuneFlags = []string{"mode", "bw", "squelch", "gain", "device", "rate", "retune"}

type listenOptions struct {
	// channel, when non-empty, is an existing channel id (or id prefix) to
	// tap instead of making one.
	channel string
	bin     bool
	count   int
}

func newListenCommand(app *App) *cobra.Command {
	var (
		f      tuneFlags
		format string
		count  int
	)
	cmd := &cobra.Command{
		Use:   "listen <frequency|preset|channel>",
		Short: "Stream a channel's decoded audio, for tools",
		Long: `listen is the audio feed behind 'ley tune': the daemon decodes the station
and listen writes the samples to stdout instead of the speakers. It resolves
its argument the way tune does (a frequency, a bare number being MHz, or a
preset such as noaa), creating a capture and a channel when none exists and
removing what it created on exit. Give a channel id (chan_...) instead to tap
a channel that is already running, such as one 'ley tune --persistent' left
behind; the tune flags are rejected in that case, because the channel's owner
chose them.

Unlike tune, listen attaches no system-audio sink and leaves the squelch off
unless --squelch asks for one, so a script gets every sample the daemon made.
Everything meant for a person goes to stderr; stdout is only the stream.

--format json: one row per line
               {seq, sample_index, sample_rate, format, pcm}
               with pcm base64-encoded. Bulk rows have no proto message, so
               this shape is part of the documented exception to ley's proto3
               JSON rule; see docs/interfaces.md.
--format bin:  the raw PCM frames as the daemon delivers them, back to back
               and nothing else (mono, little-endian, the sample rate and
               format named on stderr; S16 in this build).

--json asks for the same rows --format json prints, so it changes nothing
here; with --format bin it is a usage error.`,
		Example: `  ley listen 162.55 --count 10               # ten rows of NOAA audio
  ley listen noaa --format json | jq .seq    # rows into a tool
  ley listen 146.52 --format bin > audio.s16 # raw mono PCM
  ley listen chan_01J... --count 1           # tap a channel already running`,
		GroupID: GroupData,
		Args:    cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			if format != "json" && format != "bin" {
				return usageErrorf("--format must be json or bin")
			}
			// --json is listen's default shape already; asked for together
			// with raw frames it can only be a mistake.
			if app.JSON && format == "bin" {
				return usageErrorf("--format bin contradicts --json: bin writes raw PCM frames, --json the documented rows (the default)")
			}
			arg := ""
			if len(args) == 1 {
				arg = args[0]
			}
			lo := listenOptions{bin: format == "bin", count: count}
			var o *tuneOptions
			switch {
			case arg == "":
				return usageErrorf("listen needs a frequency, preset or channel id: ley listen 146.52, ley listen noaa, ley listen chan_01J... (ley help presets lists the presets)")
			case strings.HasPrefix(arg, listenChannelPrefix):
				for _, name := range listenTuneFlags {
					if cmd.Flags().Changed(name) {
						return usageErrorf("--%s cannot be used with a channel id: %s already has its settings; change them with: ley set --channel %s", name, arg, arg)
					}
				}
				lo.channel = arg
			default:
				hz, def, err := resolveTuneTarget(arg)
				if err != nil {
					return err
				}
				f.noAudio, f.volume = true, "1"
				if o, err = f.parse(app, arg, hz, def); err != nil {
					return err
				}
				// A machine verb takes no interactive default: without an
				// explicit --squelch the channel passes everything through.
				if f.squelch == "" {
					o.squelchAuto = false
				}
			}
			s, err := openSession(cmd.Context(), app)
			if err != nil {
				return err
			}
			defer s.close()
			s.proseToStderr = true
			if o != nil {
				if s.device, err = pickDevice(s.state, o.device); err != nil {
					return err
				}
			}
			return runListen(cmd.Context(), s, o, lo)
		},
	}
	// No --no-audio/--volume/--persistent: listen never opens the speakers,
	// and the channel it makes is torn down when the stream ends.
	addSignalFlags(cmd, &f, true)
	cmd.Flags().StringVar(&format, "format", "json", "output format: json (one row per line) or bin (raw PCM frames, see below)")
	cmd.Flags().IntVar(&count, "count", 0, "stop after this many rows, e.g. 10 (default: until Ctrl-C)")
	return cmd
}

// runListen taps an existing channel or makes one like tune (minus the
// speakers), then writes audio frames until --count, Ctrl-C or the end of the
// stream, tearing down whatever it created.
func runListen(ctx context.Context, s *session, o *tuneOptions, lo listenOptions) error {
	if lo.channel != "" {
		ch, err := leyline.ResolveChannel(s.state, lo.channel)
		if err != nil {
			return fmt.Errorf("%w. Run: ley state", err)
		}
		s.channel, s.capture = ch, captureByID(s.state, ch.CaptureId)
	} else {
		if cap := leyline.FindCapture(s.state, s.device.DeviceId); cap == nil || !covers(cap, o.freq, o.bw) {
			if err := s.checkRange(o.input, o.freq); err != nil {
				return err
			}
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
			s.teardown()
			return err
		}
		defer s.teardown()
	}
	sctx, cancel := context.WithCancel(ctx)
	defer cancel()
	// Rate 0 accepts the channel's own audio rate (v0 serves no other) and
	// UNSPECIFIED takes the daemon's default format; the descriptor says what
	// it settled on and every row repeats it.
	sub, err := s.client.SubscribeAudio(sctx, s.channel.ChannelId, 0, leylinev1.AudioSampleFormat_AUDIO_SAMPLE_FORMAT_UNSPECIFIED)
	if err != nil {
		return err
	}
	defer sub.Close()
	// Keep the event stream flowing (and the mirror current) while frames are
	// written; stopped before teardown reads the mirror.
	stopDrain := s.drainEvents()
	defer stopDrain()
	ap := sub.Descriptor.GetAudio()
	rate, name := ap.GetSampleRate(), ap.GetFormat().String()
	s.say("streaming %s from %s: %d Hz %s mono. Ctrl-C stops.\n", audioWhat(s), s.channel.ChannelId, rate, name)
	out := bufio.NewWriter(s.app.Stdout)
	defer out.Flush()
	n := 0
	for fr := range sub.Frames {
		if len(fr.Payload) == 0 {
			continue
		}
		if lo.bin {
			if _, err := out.Write(fr.Payload); err != nil {
				return err
			}
		} else {
			row := AudioRow{Seq: fr.Seq, SampleIndex: fr.Time.GetSampleIndex(), SampleRate: rate, Format: name, PCM: fr.Payload}
			b, err := json.Marshal(row)
			if err != nil {
				return err
			}
			out.Write(b)
			out.WriteByte('\n')
		}
		n++
		if lo.count > 0 && n >= lo.count {
			return nil
		}
		if err := out.Flush(); err != nil {
			return err
		}
	}
	if err := sub.Err(); err != nil && ctx.Err() == nil {
		return err
	}
	return nil
}

// audioWhat names the channel being streamed for the stderr note: its
// frequency and mode when the mirror knows the capture, else its mode alone.
func audioWhat(s *session) string {
	mode := strings.ToUpper(leyline.ModeName(s.channel.Mode))
	if hz, ok := leyline.ChannelFrequency(s.state, s.channel); ok {
		return leyline.FormatFrequency(hz) + " " + mode
	}
	return mode
}
