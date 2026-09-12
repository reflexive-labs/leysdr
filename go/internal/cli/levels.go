package cli

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"math"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// How the meter asks for its rows. The daemon windows 2 x bins samples, so 1024
// bins is a 2048-sample window: at a 48 kHz audio rate, 43 ms and 23 Hz a bin,
// which puts a sub-audible tone in a band of its own rather than in the skirt
// of the one above it and keeps a transient inside one row at the top rate.
// Twenty rows a second is as fast as a meter is read, and the daemon will not
// send more.
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
// bulk-row exception to the proto3 rule; see docs/interfaces.md.
type LevelsRow struct {
	Seq         uint64      `json:"seq"`
	SampleIndex uint64      `json:"sample_index"`
	Tap         string      `json:"tap"`
	Bands       []LevelsBin `json:"bands"`
	// RmsDbfs and PeakDbfs are the daemon's meter. They are null until it has
	// measured a block, and null whenever it did not measure one: a number
	// there would be a level nobody reported, and -0 dBFS is a real level.
	RmsDbfs  *float64 `json:"rms_dbfs"`
	PeakDbfs *float64 `json:"peak_dbfs"`
	// SquelchOpen is the daemon's squelch state at the row, which is what says
	// whether the bands are a signal or the detector talking to itself. It is
	// null on the same rule as the pair: the telemetry stream, not the
	// spectrum, carries it, and false would claim a shut squelch nobody
	// reported.
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
			defer s.close()
			s.proseToStderr = true
			// Width comes from the resolved style, which has already applied
			// --width, COLUMNS, the terminal's own size and the [40, 160]
			// clamp (docs/cli-style.md section 2).
			if o.width = app.Style.Width; o.width <= 0 {
				o.width = ui.DefaultWidth
			}
			o.height = levelsFitHeight(o.height, app.Style.Height,
				chartFramed(app.Style, o.width, app.IsTTY()))
			if o.tune != nil {
				if s.device, err = pickDevice(s.state, o.tune.device); err != nil {
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
func runLevels(ctx context.Context, s *session, o levelsOptions) error {
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
	sub, err := s.client.SubscribeAudioSpectrum(sctx, s.channel.ChannelId, levelsBins, rate,
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
	// error is deliberately not read: a telemetry stream that ends takes the
	// pair and the header's PL with it and leaves the bands drawing.
	msgs, _, err := s.client.WatchTelemetry(sctx, &leylinev1.TelemetrySubscription{
		Scope: &leylinev1.TelemetrySubscription_ChannelId{ChannelId: s.channel.ChannelId},
		Types: []leylinev1.TelemetryType{
			leylinev1.TelemetryType_SUB_AUDIBLE,
			leylinev1.TelemetryType_METER,
		},
	})
	if err != nil {
		return err
	}
	what := audioWhat(s)
	if o.watch {
		s.say("metering %s: the %s tap, %g rows a second. Ctrl-C stops. %s\n",
			what, scopeTapName(tap), fp.GetRowsPerSecond(), s.app.ErrStyle.Muted("from "+s.channel.ChannelId))
	} else {
		s.say("metering %s: the %s tap. %s\n",
			what, scopeTapName(tap), s.app.ErrStyle.Muted("from "+s.channel.ChannelId))
	}
	// Keep the event stream flowing (and the mirror current) while frames are
	// drawn; the drain owns the mirror, so it starts after the last read of it
	// and stops before teardown.
	stopDrain := s.drainEvents()
	defer stopDrain()

	view := newLevelsView(s.app.Style, o.width, o.height, o.third, s.app.IsTTY())
	out := bufio.NewWriter(s.app.Stdout)
	defer out.Flush()
	var w *spectrumWriter
	if !s.app.JSON {
		w = newSpectrumWriter(s.app, out, spectrumOptions{
			bandFlags: bandFlags{rate: o.rate, width: o.width}, watch: o.watch,
		}, rate)
		defer w.finish()
	}
	tick := time.NewTicker(spectrumTickInterval)
	defer tick.Stop()
	frame := levelsFrame{
		bands: make([]levelsBar, len(view.bands)),
		rms:   newLevelsBar(), peak: newLevelsBar(),
		rmsDb: math.NaN(), peakDb: math.NaN(), tap: tap, what: what,
	}
	for i := range frame.bands {
		frame.bands[i] = newLevelsBar()
	}
	start := time.Now()
	last := start
	rows := 0
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-tick.C:
			if w != nil {
				w.idle()
			}
			// A snapshot draws one frame and leaves; waiting for ever with a
			// blank screen is not a still of anything.
			if !o.watch && rows == 0 && time.Since(start) > spectrumFirstRow {
				return fmt.Errorf("no complete levels row arrived in %.0f s, so there is nothing to draw. Check the channel is still running with: ley state", spectrumFirstRow.Seconds())
			}
		case m, ok := <-msgs:
			if !ok {
				msgs, frame.tone, frame.squelchKnown = nil, nil, false
				continue
			}
			switch b := m.Body.(type) {
			case *leylinev1.TelemetryMsg_SubAudible:
				frame.tone = b.SubAudible
			case *leylinev1.TelemetryMsg_Meter:
				frame.squelchOpen, frame.squelchKnown = b.Meter.GetSquelchOpen(), true
				frame.rmsDb, frame.peakDb = b.Meter.GetAudioDbfs(), b.Meter.GetAudioPeakDbfs()
			}
		case fr, ok := <-sub.Frames:
			if !ok {
				return levelsEnd(ctx, sub.Err(), rows)
			}
			// A still is complete once the daemon has also said whether the
			// squelch is passing anything: a band level means one thing behind
			// an open squelch and nothing at all behind a shut one, and the one
			// frame a snapshot prints has to say which. The meter waits on
			// nothing but its own rows -- it has later frames to say it in, and
			// a slow or absent meter must not hold the bands off the screen.
			// A telemetry stream that has ended is never going to say it, so
			// the still goes out with the squelch unstated rather than never.
			if !o.watch && rows == 0 && !frame.squelchKnown && msgs != nil {
				continue
			}
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
					return err
				}
				out.Write(b)
				out.WriteByte('\n')
			} else {
				w.frame(view.render(frame), "")
			}
			if err := out.Flush(); err != nil {
				return err
			}
			rows++
			if !o.watch || (o.count > 0 && rows >= o.count) {
				return nil
			}
		}
	}
}

// levelsEnd turns the end of the spectrum stream into what to do next: nothing
// on Ctrl-C, the daemon's error where there is one, and a sentence where the
// stream ended before a single row arrived.
func levelsEnd(ctx context.Context, err error, rows int) error {
	if ctx.Err() != nil {
		return nil
	}
	if err != nil {
		return err
	}
	if rows == 0 {
		return fmt.Errorf("the audio spectrum ended before a row could be drawn. Check the channel is still running with: ley state")
	}
	return nil
}
