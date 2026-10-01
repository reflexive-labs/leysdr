// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"math"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// How the meter asks for its rows. The daemon windows 2 x bins samples, so 1024
// bins is a 2048-sample window: at a 48 kHz audio rate, 43 ms and 23 Hz a bin,
// which puts a sub-audible tone in a band of its own rather than in the skirt
// of the one above it and keeps a transient inside one row at the top rate.
// Twenty rows a second is about as fast as a bar meter can be read, and the
// daemon will not send more.
const (
	levelsBins    = 1024
	levelsRateMax = 20
	// levelsChromeRows is what a frame spends on everything that is not a
	// ladder: the header, the overload line, the axis, two label lines and the
	// status line, plus the row of headroom a redraw needs.
	levelsChromeRows = 7
	// levelsBorderRows is what the chart's frame costs on top of that: the
	// edge above the ladders and the one under the labels.
	levelsBorderRows = 2
)

// LevelsRow is one JSON row of `ley levels`: the daemon's own numbers for one
// spectrum row, in dB, before any of the ballistics that shape the bars. Bulk
// frames have no proto message, so this shape is part of the documented
// bulk-row exception to the proto3 rule; see docs/reference/cli.md.
type LevelsRow struct {
	Seq         uint64      `json:"seq"`
	SampleIndex uint64      `json:"sample_index"`
	Tap         string      `json:"tap"`
	Bands       []LevelsBin `json:"bands"`
	// RmsDbfs and PeakDbfs are the daemon's meter. They are null until it has
	// measured a block, and null whenever it did not measure one: any number
	// there would be a level the daemon never reported, and even -0 dBFS is a
	// real level.
	RmsDbfs  *float64 `json:"rms_dbfs"`
	PeakDbfs *float64 `json:"peak_dbfs"`
	// SquelchOpen is the daemon's squelch state at the row, which tells whether
	// the bands show a signal or only detector noise. It is null on the same
	// rule as the pair: the telemetry stream, not the spectrum, carries it, and
	// false would report a closed squelch the daemon never reported.
	SquelchOpen *bool `json:"squelch_open"`
}

// levelsMeasured is a meter value for a JSON row: the number where there is
// one, and nothing at all where the daemon said NaN.
func levelsMeasured(db float64) *float64 {
	if math.IsNaN(db) {
		return nil
	}
	return &db
}

// LevelsBin is one band of a JSON row: the ISO centre it is named by and the
// power its bins add up to.
type LevelsBin struct {
	CenterHz float64 `json:"center_hz"`
	Db       float64 `json:"db"`
}

// levelsTuneFlags are the tune flags the meter registers; the capture rate is
// not among them, so --rate stays the view's own rows a second.
var levelsTuneFlags = []string{"mode", "bw", "squelch", "gain", "device", "retune"}

type levelsOptions struct {
	channel string
	tune    *tuneOptions
	tap     leylinev1.AudioTap
	third   bool
	watch   bool
	rate    float64
	count   int
	width   int
	height  int
}

func newLevelsCommand(app *App) *cobra.Command {
	var (
		f     tuneFlags
		o     levelsOptions
		tap   string
		bands string
	)
	cmd := &cobra.Command{
		Use:     "levels <frequency|preset|channel>",
		Short:   "Watch the audio level band by band",
		GroupID: GroupLooking,
		Long: `levels is the spectrum-analyser display off the front of a rack unit,
drawn over the daemon's audio spectrum: one bar per octave band, each an LED
ladder with a peak cap that hangs and falls, and a master pair at the right
showing the rms and peak levels the daemon's meter reports. It answers the
questions a number cannot -- is that voice or noise, is there bass under it,
is a tone riding below the speech.

It takes a frequency, a preset or a channel id the way 'ley listen' does,
making a capture and a channel when none exists and removing what it made on
exit, and it opens no speakers.

--tap audio is what the speakers get, after the high-pass, de-emphasis and
gain control. --tap demod is the detector's own output before any of that,
which is where a CTCSS tone still stands in the 125 Hz band.

It draws once by default: one still of the bands as they were measured, no
ballistics and no caps. --watch is the meter itself, redrawn twenty times a
second until Ctrl-C, where --rate and --count apply. There bars rise
instantly and fall at 20 dB a second so a syllable leaves a trail, and the
caps hold the loudest of the last second and a half. That shaping is
presentation: the numbers under the master pair are the current row's own,
and --json carries the raw rows.

While the daemon's squelch is shut nothing is coming through, so the ladders
draw unlit and the header says so; the rows still go out under --json with
the squelch state on them.

The scale is a meter's and not a chart's: 6 dB a row from 0 to -24 dBFS, then
10 dB a row to -60, held whatever the signal does, with the -18 dBFS
alignment level drawn across as a dashed rule.

--bands third draws the twenty-five third-octave bands instead of the nine
octaves, on a terminal at least 100 columns wide.

--json prints one object per row: {seq, sample_index, tap, bands:
[{center_hz, db}], rms_dbfs, peak_dbfs, squelch_open}.`,
		Example: `  ley levels 146.52                     # nine bands of what the speaker hears
  ley levels 145.23 --tap demod         # the PL tone standing in the low bands
  ley levels 101.1 --bands third        # twenty-five bands, at 100 columns and up
  ley levels 146.52 -w                  # the live meter, until Ctrl-C
  ley levels 145.23 -w --count 20 --json`,
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			switch tap {
			case "audio":
				o.tap = leylinev1.AudioTap_TAP_AUDIO
			case "demod":
				o.tap = leylinev1.AudioTap_TAP_DEMOD
			default:
				return usageErrorf("--tap must be audio (what the speakers get) or demod (the detector's own output)")
			}
			switch bands {
			case "octave":
				o.third = false
			case "third":
				o.third = true
			default:
				return usageErrorf("--bands must be octave (nine bands) or third (twenty-five, at 100 columns and up)")
			}
			if o.rate <= 0 || o.rate > levelsRateMax {
				return usageErrorf("--rate must be more than 0 and at most %d rows a second", levelsRateMax)
			}
			if o.height < levelsMinRows || o.height > levelsMaxRows {
				return usageErrorf("--height must be %d..%d rows, got %d", levelsMinRows, levelsMaxRows, o.height)
			}
			arg := ""
			if len(args) == 1 {
				arg = args[0]
			}
			channel, tune, err := tapTarget(cmd, &f, "levels", arg, levelsTuneFlags)
			if err != nil {
				return err
			}
			o.channel, o.tune = channel, tune
			s, err := openSession(cmd.Context(), app)
			if err != nil {
				return err
			}
			defer s.Close()
			s.proseToStderr = true
			// Width comes from the resolved style, which has already applied
			// --width, COLUMNS, the terminal's own size and the [40, 160]
			// clamp (docs/dev/cli-style.md section 2).
			if o.width = app.Style.Width; o.width <= 0 {
				o.width = ui.DefaultWidth
			}
			o.height = levelsFitHeight(o.height, app.Style.Height,
				chartFramed(app.Style, o.width, app.IsTTY()))
			if o.tune != nil {
				if s.device, err = pickDevice(s.State, o.tune.device); err != nil {
					return err
				}
			}
			return runLevels(cmd.Context(), s, o)
		},
	}
	addSignalFlags(cmd, &f, false)
	// The radio flags without the capture rate: --rate here is rows a second.
	addRadioFlags(cmd, &f, false)
	cmd.Flags().StringVar(&tap, "tap", "audio", "which stage to measure: audio (what the speakers get) or demod (the detector's output, before the audio chain)")
	cmd.Flags().StringVar(&bands, "bands", "octave", "octave (nine bands) or third (twenty-five third-octave bands, at 100 columns and up)")
	cmd.Flags().BoolVarP(&o.watch, "watch", "w", false, "keep the meter live until Ctrl-C")
	cmd.Flags().Float64Var(&o.rate, "rate", 20, "with --watch: rows a second (at most 20)")
	cmd.Flags().IntVar(&o.count, "count", 0, "with --watch: stop after this many rows, e.g. 10 (0 = until Ctrl-C)")
	cmd.Flags().IntVar(&o.width, "width", 0, "meter width in columns (default: the terminal's, or 80 when piped)")
	cmd.Flags().IntVar(&o.height, "height", levelsHeight, "ladder height in rows (6..24, clamped to the terminal)")
	return cmd
}

// levelsFitHeight is the height a meter is drawn at: what was asked for, less
// whatever the terminal cannot hold, because a block taller than the screen
// cannot be redrawn in place at all. A framed meter has two rows less to
// spend, since the border is drawn around everything the chrome already counts.
func levelsFitHeight(want, term int, framed bool) int {
	if term <= 0 {
		return want
	}
	chrome := levelsChromeRows
	if framed {
		chrome += levelsBorderRows
	}
	return max(min(want, term-chrome), levelsMinRows)
}

// runLevels taps the channel's audio spectrum, folds each row into bands and
// draws the meter: the ladders under their ballistics, the master pair from
// the daemon's own meter, and the numbers that are neither.
func runLevels(ctx context.Context, s *verbSession, o levelsOptions) error {
	stop, err := s.openChannel(ctx, o.tune, o.channel)
	if err != nil {
		return err
	}
	defer stop()
	sctx, cancel := context.WithCancel(ctx)
	defer cancel()
	// A snapshot asks for rows as fast as the daemon sends them, because the
	// only one it draws is the first: --rate is how often a live meter moves.
	rate := o.rate
	if !o.watch {
		rate = levelsRateMax
	}
	// DB_F32 because the bands are power sums: quantising every bin to a
	// whole dB before adding them up would show in the total.
	sub, err := s.Client.SubscribeAudioSpectrum(sctx, s.Channel.ChannelId, levelsBins, rate,
		leylinev1.FftBinFormat_DB_F32, o.tap)
	if err != nil {
		return err
	}
	defer sub.Close()
	fp := sub.Descriptor.GetFft()
	binHz := float64(sub.Descriptor.GetSpanHz()) / float64(fp.GetBins())
	tap := fp.GetTap()
	// The master pair and the squelch are the daemon's measurements, not the
	// view's: rms and peak come off the meter, never off the spectrum row, so
	// two clients watching one channel report the same numbers. The stream's
	// error is not read: a telemetry stream that ends takes the pair and the
	// header's PL with it and leaves the bands drawing.
	msgs, _, err := s.Client.WatchTelemetry(sctx, &leylinev1.TelemetrySubscription{
		Scope: &leylinev1.TelemetrySubscription_ChannelId{ChannelId: s.Channel.ChannelId},
		Types: []leylinev1.TelemetryType{
			leylinev1.TelemetryType_SUB_AUDIBLE,
			leylinev1.TelemetryType_METER,
		},
	})
	if err != nil {
		return err
	}
	// The capture's level drives OVER and the header's peak. It has its own
	// subscription, scoped to the capture: the level is the radio's, not the
	// channel's, and a channel-scoped stream carries none.
	levels := s.watchLevel(sctx, s.Channel.GetCaptureId())
	what := audioWhat(s)
	if o.watch {
		s.say("metering %s: the %s tap, %g rows a second. Ctrl-C stops. %s\n",
			what, scopeTapName(tap), fp.GetRowsPerSecond(), s.app.ErrStyle.Muted("from "+s.Channel.ChannelId))
	} else {
		s.say("metering %s: the %s tap. %s\n",
			what, scopeTapName(tap), s.app.ErrStyle.Muted("from "+s.Channel.ChannelId))
	}
	// Keep the event stream flowing (and the mirror current) while frames are
	// drawn; the drain owns the mirror, so it starts after the last read of it
	// and stops before teardown.
	// The full scale is read from the channel before the drain starts: the drain owns the mirror
	// from then on, and the race detector flagged a channel event folding in during this read.
	fullScaleHz := scopeFullScaleHz(nil, s.Channel)
	stopDrain := s.DrainEvents()
	defer stopDrain()

	view := newLevelsView(s.app.Style, o.width, o.height, o.third, s.app.IsTTY())
	out := bufio.NewWriter(s.app.Stdout)
	defer out.Flush()
	var w *chartWriter
	if !s.app.JSON {
		w = newChartWriter(s.app, out, o.watch, rate)
		defer w.finish()
	}
	frame := levelsFrame{
		bands: make([]levelsBar, len(view.bands)),
		rms:   newLevelsBar(), peak: newLevelsBar(),
		rmsDb: math.NaN(), peakDb: math.NaN(), tap: tap, what: what,
		// The bands are dB against full scale, and on the demod tap of an FM
		// mode full scale is a deviation. The FFT descriptor carries no such
		// field, so the meter derives it from the channel by the rule the
		// daemon documents in the audio descriptor.
		fullScaleHz: fullScaleHz,
	}
	for i := range frame.bands {
		frame.bands[i] = newLevelsBar()
	}
	start := time.Now()
	last := start
	rows := 0
	// emit draws one frame, and reports when the verb is done: a still after
	// its one row, a watch after --count.
	emit := func(fr *leylinev1.Frame) (bool, error) {
		bins := leyline.DecodeFFTBins(fr.Payload, fp.GetBinFormat())
		now := time.Now()
		dt := now.Sub(last)
		last = now
		levels := make([]float64, len(view.bands))
		for i, b := range view.bands {
			levels[i] = levelsBandDb(bins, binHz, b)
		}
		frame.advance(levels, dt, o.watch)
		if s.app.JSON {
			row := LevelsRow{
				Seq: fr.Seq, SampleIndex: fr.Time.GetSampleIndex(), Tap: scopeTapName(tap),
				Bands:   make([]LevelsBin, len(view.bands)),
				RmsDbfs: levelsMeasured(frame.rmsDb), PeakDbfs: levelsMeasured(frame.peakDb),
				SquelchOpen: frame.squelch(),
			}
			for i, b := range view.bands {
				row.Bands[i] = LevelsBin{CenterHz: b.centerHz, Db: levels[i]}
			}
			b, err := json.Marshal(row)
			if err != nil {
				return false, err
			}
			out.Write(b)
			out.WriteByte('\n')
		} else {
			w.frame(view.render(frame), "")
		}
		if err := out.Flush(); err != nil {
			return false, err
		}
		rows++
		if !o.watch || (o.count > 0 && rows >= o.count) {
			return true, nil
		}
		return false, nil
	}
	// The frame a still holds while it waits for the capture's level: held,
	// not dropped, because a 300 ms playback part ends before the probe
	// does, and a dropped frame would be the only one.
	var held *leylinev1.Frame
	// release emits the held frame, if any.
	release := func() (bool, error) {
		if held == nil {
			return false, nil
		}
		fr := held
		held = nil
		return emit(fr)
	}
	telemetryOpen, levelOpen := true, levels != nil
	return liveLoop{
		w: w,
		onTick: func() (bool, error) {
			if time.Since(start) >= levelProbeTimeout {
				if done, err := release(); done || err != nil {
					return done, err
				}
			}
			// A snapshot draws one frame and exits; waiting for ever would
			// leave a blank screen.
			if !o.watch && rows == 0 && time.Since(start) > chartFirstRow {
				return true, fmt.Errorf("no complete levels row arrived in %.0f s, so there is nothing to draw. Check the channel is still running with: ley state", chartFirstRow.Seconds())
			}
			return false, nil
		},
		level: levels,
		onLevel: func(m *leylinev1.TelemetryMsg) (bool, error) {
			if m == nil {
				levelOpen, frame.level = false, nil
			} else if b, ok := m.Body.(*leylinev1.TelemetryMsg_CaptureLevel); ok {
				frame.level = b.CaptureLevel
			}
			// The level the still was waiting for, or the stream that was never
			// going to send one: either way the held frame goes out now.
			if frame.level != nil || !levelOpen {
				return release()
			}
			return false, nil
		},
		telemetry: msgs,
		onTelemetry: func(m *leylinev1.TelemetryMsg) (bool, error) {
			if m == nil {
				telemetryOpen, frame.tone, frame.squelchKnown = false, nil, false
				return false, nil
			}
			switch b := m.Body.(type) {
			case *leylinev1.TelemetryMsg_SubAudible:
				frame.tone = b.SubAudible
			case *leylinev1.TelemetryMsg_Meter:
				frame.squelchOpen, frame.squelchKnown = b.Meter.GetSquelchOpen(), true
				frame.rmsDb, frame.peakDb = b.Meter.GetAudioDbfs(), b.Meter.GetAudioPeakDbfs()
			}
			return false, nil
		},
		frames: sub.Frames,
		end:    func() error { return levelsEnd(ctx, sub.Err(), rows) },
		onFrame: func(fr *leylinev1.Frame) (bool, error) {
			// A still is complete once the daemon has also reported whether the
			// squelch is open: a band level means something behind an open
			// squelch and nothing behind a closed one, and a snapshot's only
			// frame has to show which. A --watch meter does not wait: later
			// frames can show the state, and a slow or absent daemon meter must
			// not keep the bands off the screen. If the telemetry stream has
			// ended the squelch state will never arrive, so the still is
			// printed without it.
			if !o.watch && rows == 0 && !frame.squelchKnown && telemetryOpen {
				return false, nil
			}
			// The still's OVER is the capture's level, which is a quarter of a
			// second away at most; a daemon that sends none (an older one) is
			// waited on this long and then left to the bars' own rule.
			if !o.watch && rows == 0 && frame.level == nil && levelOpen && time.Since(start) < levelProbeTimeout {
				held = fr
				return false, nil
			}
			return emit(fr)
		},
	}.run(ctx)
}

// levelsEnd turns the end of the spectrum stream into what to do next, by the
// one rule the live views share.
func levelsEnd(ctx context.Context, err error, rows int) error {
	return liveStreamEnd(ctx, err, rows, "audio spectrum", "row")
}
