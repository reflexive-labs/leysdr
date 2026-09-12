// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"math"
	"slices"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// How much of the past a frame may hold. Under two seconds the picture is the
// scope's job and a column is too short to hold a syllable; over two minutes a
// column is wider than a transmission, and the shape of a clip stops being
// readable at all.
const (
	waveformSecondsMin = 2
	waveformSecondsMax = 120
)

// WaveformRow is one JSON row of `ley waveform`: one column of the picture as
// it completes, the statistics taken over the slice it covers and the state
// the daemon's squelch was in while it arrived. Bulk frames have no proto
// message, so this shape is part of the documented bulk-row exception to the
// proto3 rule; see docs/interfaces.md.
type WaveformRow struct {
	// SampleIndex is the daemon's own index for the first sample of the slice.
	// Seconds is how much audio the picture holds by the end of it, which is
	// what the axis under the picture counts back through.
	SampleIndex uint64  `json:"sample_index"`
	Seconds     float64 `json:"seconds"`
	PeakDbfs    float64 `json:"peak_dbfs"`
	RmsDbfs     float64 `json:"rms_dbfs"`
	// SquelchOpen is the daemon's own state, taken as open until its first
	// meter arrives: a view that blanked a column before then would be hiding
	// signal it has rather than reporting one it does not.
	SquelchOpen bool `json:"squelch_open"`
}

// waveformTuneFlags are the tune flags the view registers; the capture rate is
// not among them, so --rate stays the view's own frames a second.
var waveformTuneFlags = []string{"mode", "bw", "squelch", "gain", "device", "retune"}

type waveformOptions struct {
	channel string
	tune    *tuneOptions
	tap     leylinev1.AudioTap
	scale   scopeScale
	seconds float64
	rate    float64
	count   int
	width   int
}

func newWaveformCommand(app *App) *cobra.Command {
	var (
		f     tuneFlags
		o     waveformOptions
		tap   string
		scale string
	)
	cmd := &cobra.Command{
		Use:     "waveform <frequency|preset|channel>",
		Short:   "Draw the last minutes of audio as a clip",
		GroupID: GroupLooking,
		Long: `waveform draws the audio the way an editor draws a recording: every column
is the loudest the signal got in the slice of time it covers, above and below
a centre line, with the newest at the right and the past scrolling away to
the left. Where 'ley scope' shows one window of the wave itself, this shows
the shape of a transmission -- where the words are, how long the pauses ran,
whether the level held.

It takes a frequency, a preset or a channel id the way 'ley listen' does,
making a capture and a channel when none exists and removing what it made on
exit, and it opens no speakers.

--tap audio is what the speakers get, after the high-pass, de-emphasis and
gain control. --tap demod is the detector's own output before any of that,
with its DC offset taken out so the clip sits on its centre line; the header
names the offset that was removed.

A slice the daemon's squelch was closed for is left blank rather than drawn
flat, so a gap between transmissions looks like a gap. A slice that is open
and silent keeps the centre rule.

--seconds is how much of the past one frame holds, 2 to 120. --scale auto,
the default, fits the clip to the bulk of the last few seconds, because the
point of the view is the shape; a column louder than the rest of them draws
clamped rather than shrinking the picture. --scale full draws the whole range
the tap can carry, and on the demod tap that range is the channel's own full
deviation, which the header names in hertz; a number pins it.

--json prints one object per column as it completes: {sample_index, seconds,
peak_dbfs, rms_dbfs, squelch_open}.`,
		Example: `  ley waveform 146.52                   # the last ten seconds of the speaker
  ley waveform 145.23 --seconds 60      # a minute of traffic, gaps and all
  ley waveform 145.23 --tap demod       # the detector's own clip, DC removed
  ley waveform 101.1 --seconds 2 --count 20 --json`,
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
			sc, err := parseScopeScale(scale)
			if err != nil {
				return err
			}
			o.scale = sc
			if o.seconds < waveformSecondsMin || o.seconds > waveformSecondsMax {
				return usageErrorf("--seconds must be %d..%d, got %g", waveformSecondsMin, waveformSecondsMax, o.seconds)
			}
			if o.rate <= 0 || o.rate > scopeRateMax {
				return usageErrorf("--rate must be more than 0 and at most %d frames a second", scopeRateMax)
			}
			arg := ""
			if len(args) == 1 {
				arg = args[0]
			}
			channel, tune, err := tapTarget(cmd, &f, "waveform", arg, waveformTuneFlags)
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
			if o.tune != nil {
				if s.device, err = pickDevice(s.state, o.tune.device); err != nil {
					return err
				}
			}
			return runWaveform(cmd.Context(), s, o)
		},
	}
	addSignalFlags(cmd, &f, false)
	// The radio flags without the capture rate: --rate here is frames a second.
	addRadioFlags(cmd, &f, false)
	cmd.Flags().StringVar(&tap, "tap", "audio", "which stage to draw: audio (what the speakers get) or demod (the detector's output, before the audio chain)")
	cmd.Flags().Float64Var(&o.seconds, "seconds", 10, "how much of the past one frame holds (2..120)")
	cmd.Flags().StringVar(&scale, "scale", "auto", "how far from the centre the top of the clip stands: auto (fit the signal), full (±1.0), or a number such as 0.2")
	cmd.Flags().Float64Var(&o.rate, "rate", 20, "frames a second (at most 20)")
	cmd.Flags().IntVar(&o.count, "count", 0, "stop after this many columns, e.g. 10 (default: until Ctrl-C)")
	cmd.Flags().IntVar(&o.width, "width", 0, "picture width in columns (default: the terminal's, or 80 when piped)")
	return cmd
}

// waveformAcc gathers one column's slice of the stream without keeping it: the
// running numbers a peak envelope and its levels are drawn from, so a picture
// holding two minutes of audio costs no more than one holding two seconds.
type waveformAcc struct {
	n              int
	sum, sumSquare float64
	lo, hi         float64
	// index is the stream's own index of the slice's first sample.
	index uint64
	// open is the daemon's squelch over the slice, true where it passed
	// anything at all: a column is blanked because nothing came through it,
	// and a transmission that opened halfway through one did come through.
	open bool
}

// start begins a slice at a sample of the stream, in the squelch state the
// daemon last reported.
func (a *waveformAcc) start(index uint64, open bool) {
	*a = waveformAcc{index: index, lo: math.Inf(1), hi: math.Inf(-1), open: open}
}

func (a *waveformAcc) add(v float64) {
	a.n++
	a.sum += v
	a.sumSquare += v * v
	a.lo, a.hi = math.Min(a.lo, v), math.Max(a.hi, v)
}

// column closes the slice into what the picture and a JSON row are drawn from.
// The demod tap's DC offset is taken out first -- it is the tuning error, and
// an editor's view of a clip shifted off its centre line says nothing the
// scope's trace does not say better -- so the envelope is symmetric about the
// centre by construction rather than by drawing.
func (a *waveformAcc) column(removeDC bool, seconds float64) waveformCol {
	if a.n == 0 {
		return waveformCol{}
	}
	n := float64(a.n)
	dc := a.sum / n
	offset := 0.0
	if removeDC {
		offset = dc
	}
	peak := math.Max(a.hi-offset, offset-a.lo)
	// The mean square about the offset, which is the plain mean square where
	// nothing was removed.
	square := a.sumSquare/n - offset*(2*dc-offset)
	return waveformCol{
		present: true, index: a.index, seconds: seconds, open: a.open, dc: dc,
		peak: peak, peakDbfs: scopeDbfs(peak), rmsDbfs: scopeDbfs(math.Sqrt(math.Max(square, 0))),
	}
}

// runWaveform taps the channel, folds the stream into one column of envelope
// per slice of the window and draws the window every frame, newest at the
// right.
func runWaveform(ctx context.Context, s *session, o waveformOptions) error {
	stop, err := s.openChannel(ctx, o.tune, o.channel)
	if err != nil {
		return err
	}
	defer stop()
	sctx, cancel := context.WithCancel(ctx)
	defer cancel()
	// F32 for the reason the scope asks for it: on the demod tap the DC offset
	// this view removes is a small fraction of full scale that a 16-bit round
	// trip would coarsen.
	sub, err := s.client.SubscribeAudioTap(sctx, s.channel.ChannelId, 0,
		leylinev1.AudioSampleFormat_F32, o.tap)
	if err != nil {
		return err
	}
	defer sub.Close()
	ap := sub.Descriptor.GetAudio()
	rate, format, tap := ap.GetSampleRate(), ap.GetFormat(), ap.GetTap()
	fullScaleHz := scopeFullScaleHz(ap, s.channel)
	// The squelch is the daemon's to report and the view's only to draw with.
	// The stream's error is deliberately not read: a telemetry stream that
	// ends leaves the clip drawing, on the last state it knew.
	msgs, _, err := s.client.WatchTelemetry(sctx, &leylinev1.TelemetrySubscription{
		Scope: &leylinev1.TelemetrySubscription_ChannelId{ChannelId: s.channel.ChannelId},
		Types: []leylinev1.TelemetryType{leylinev1.TelemetryType_METER},
	})
	if err != nil {
		return err
	}
	what := audioWhat(s)
	s.say("drawing %s: the %s tap, %g seconds across. Ctrl-C stops. %s\n",
		what, scopeTapName(tap), o.seconds, s.app.ErrStyle.Muted("from "+s.channel.ChannelId))
	// Keep the event stream flowing (and the mirror current) while frames are
	// drawn; the drain owns the mirror, so it starts after the last read of it
	// and stops before teardown.
	stopDrain := s.drainEvents()
	defer stopDrain()

	view := newWaveformView(s.app.Style, o.width, o.seconds, o.scale, s.app.IsTTY())
	out := bufio.NewWriter(s.app.Stdout)
	defer out.Flush()
	var w *chartWriter
	if !s.app.JSON {
		w = newChartWriter(s.app, out, true, o.rate)
		defer w.finish()
	}
	tick := time.NewTicker(chartTickInterval)
	defer tick.Stop()
	interval := time.Duration(float64(time.Second) / o.rate)
	frame := waveformFrame{
		cols: make([]waveformCol, view.cols()), tap: tap, what: what,
		seconds: o.seconds, dc: math.NaN(), fullScaleHz: fullScaleHz, squelchOpen: true,
	}
	// How much of the stream one column stands for. The columns are the
	// picture's own geometry, so --json carries the same slices the picture
	// would have drawn at this width.
	per := max(int(math.Round(o.seconds*float64(rate)/float64(len(frame.cols)))), 1)
	scaler := newScopeScaler(o.scale, interval)
	var acc waveformAcc
	// drawn counts the audio the picture is built from, which is what its own
	// axis measures: a column is a fixed number of samples, so the seconds a
	// row reports are the seconds of signal behind the playhead.
	var drawn uint64
	var last time.Time
	cols := 0
	draw := func() error {
		if s.app.JSON {
			return nil
		}
		last = time.Now()
		w.frame(view.render(frame, scaler.next(waveformPeak(frame.cols))), "")
		return out.Flush()
	}
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-tick.C:
			if w != nil {
				w.idle()
			}
		case m, ok := <-msgs:
			if !ok {
				msgs = nil
				continue
			}
			if b, is := m.Body.(*leylinev1.TelemetryMsg_Meter); is {
				frame.squelchOpen, frame.squelchKnown = b.Meter.GetSquelchOpen(), true
				acc.open = acc.open || frame.squelchOpen
			}
		case fr, ok := <-sub.Frames:
			if !ok {
				return waveformEnd(ctx, sub.Err(), cols)
			}
			index := fr.Time.GetSampleIndex()
			for _, v := range leyline.DecodeAudio(fr.Payload, format) {
				if acc.n == 0 {
					acc.start(index, frame.squelchOpen)
				}
				acc.add(float64(v))
				index++
				drawn++
				if acc.n < per {
					continue
				}
				col := acc.column(tap == leylinev1.AudioTap_TAP_DEMOD, float64(drawn)/float64(rate))
				acc = waveformAcc{}
				copy(frame.cols, frame.cols[1:])
				frame.cols[len(frame.cols)-1] = col
				if tap == leylinev1.AudioTap_TAP_DEMOD {
					frame.dc = col.dc
				}
				if s.app.JSON {
					b, err := json.Marshal(WaveformRow{
						SampleIndex: col.index, Seconds: col.seconds, PeakDbfs: col.peakDbfs,
						RmsDbfs: col.rmsDbfs, SquelchOpen: col.open,
					})
					if err != nil {
						return err
					}
					out.Write(b)
					out.WriteByte('\n')
					if err := out.Flush(); err != nil {
						return err
					}
				}
				cols++
				if o.count > 0 && cols >= o.count {
					return draw()
				}
				if time.Since(last) >= interval {
					if err := draw(); err != nil {
						return err
					}
				}
			}
		}
	}
}

// waveformEnd turns the end of the audio stream into what to do next: nothing
// on Ctrl-C, the daemon's error where there is one, and a sentence where the
// stream ended before a single column could be drawn.
func waveformEnd(ctx context.Context, err error, cols int) error {
	if ctx.Err() != nil {
		return nil
	}
	if err != nil {
		return err
	}
	if cols == 0 {
		return fmt.Errorf("the audio stream ended before a column could be drawn. Check the channel is still running with: ley state")
	}
	return nil
}

// waveformPeak is how loud the window is, which is what the auto scale fits
// the clip to: the percentile of the columns rather than the loudest of them,
// so one column of squelch tail at several times full scale does not shrink
// every other column in the picture for as long as it stays in view. A blank
// column is not a quiet one and does not count.
func waveformPeak(cols []waveformCol) float64 {
	peaks := make([]float64, 0, len(cols))
	for _, c := range cols {
		if c.present && c.open {
			peaks = append(peaks, c.peak)
		}
	}
	slices.Sort(peaks)
	return scopePercentile(peaks, scopeScalePercent)
}
