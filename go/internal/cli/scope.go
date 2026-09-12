// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"math"
	"slices"
	"strconv"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// What the window may be, in milliseconds. Below five there is less than a
// cycle of anything a radio carries; above five hundred a frame is slower than
// the eye and the trace stops being a picture of now.
const (
	scopeWindowMin = 5
	scopeWindowMax = 500
	scopeRateMax   = 20
)

// scopeScaleSteps are the vertical scales --scale auto chooses between: round
// numbers the gutter can be read at a glance, each about twice the one below,
// so a step up is a visible change of picture rather than a drift.
var scopeScaleSteps = []float64{0.02, 0.05, 0.1, 0.2, 0.5, 1}

// How the auto scale follows the signal. It is fitted to the ninetieth
// percentile of the peaks the last second held rather than to the loudest of
// them, so a signal that stays loud takes the scale up within a few frames
// while a single spike -- a squelch tail is several times full scale for one
// frame -- draws clamped and leaves the picture the size it was. A second is
// longer than a pause between syllables and shorter than a pause between
// words. The headroom keeps a steady tone off the top and bottom rows, where
// a peak and a clipped peak look the same.
const (
	scopeScaleHold     = time.Second
	scopeScaleMinHold  = 2
	scopeScaleHeadroom = 1.1
	scopeScalePercent  = 0.9
)

// scopeScale is what --scale asked for: how far from the centre the top of the
// trace stands, in the tap's own units, either pinned or fitted per frame.
type scopeScale struct {
	auto bool
	// fixed is the pinned scale, and the whole scale unless auto is set.
	fixed float64
}

// scopeFull is the whole range the tap can carry: a trace that grows is a
// signal that grew and never a scale that moved under it.
var scopeFull = scopeScale{fixed: 1}

// parseScopeScale reads the --scale flag: the two words, or a number in the
// range the steps cover.
func parseScopeScale(s string) (scopeScale, error) {
	switch s {
	case "full":
		return scopeFull, nil
	case "auto":
		return scopeScale{auto: true}, nil
	}
	v, err := strconv.ParseFloat(s, 64)
	if err != nil || v < scopeScaleSteps[0] || v > 1 {
		return scopeScale{}, usageErrorf(
			"--scale must be full, auto, or a number from %g to 1 (how far from the centre the top of the trace stands)",
			scopeScaleSteps[0])
	}
	return scopeScale{fixed: v}, nil
}

// named says whether the header states the scale. Full scale is the rule the
// view is read by, so it is worth a word only once something has changed it.
func (s scopeScale) named() bool { return s.auto || s.fixed != 1 }

// labelWidth is how many columns the gutter reserves for its labels. Auto
// reserves the widest step it could ever pick rather than resizing the trace
// when the scale moves: a picture that changes width mid-run is harder to read
// than a column of space.
func (s scopeScale) labelWidth() int {
	if !s.auto {
		return len(scopeScaleLabel(s.fixed))
	}
	w := 0
	for _, step := range scopeScaleSteps {
		w = max(w, len(scopeScaleLabel(step)))
	}
	return w
}

// scopeScaleLabel writes a scale the way the gutter and the header do: as few
// digits as say it, because the gutter is read, not measured.
func scopeScaleLabel(v float64) string { return fmt.Sprintf("%+g", v) }

// scopeScaler carries the auto scale between frames: the peaks of the frames
// the hold window covers, oldest overwritten first.
type scopeScaler struct {
	scale  scopeScale
	recent []float64
	// at is where the next peak goes once the window is full.
	at int
	// size is how many frames the hold window holds at this frame rate.
	size int
	// sorted is scratch the percentile is taken in, so a frame that moves the
	// scale allocates nothing.
	sorted []float64
}

func newScopeScaler(sc scopeScale, interval time.Duration) *scopeScaler {
	// Two frames is the shortest window a fit can mean anything in: one frame
	// has nothing to disagree with a burst, so at a frame rate slow enough
	// that a second holds a single frame the window runs long instead.
	size := scopeScaleMinHold
	if interval > 0 {
		size = max(int(math.Round(scopeScaleHold.Seconds()/interval.Seconds())), scopeScaleMinHold)
	}
	return &scopeScaler{scale: sc, size: size, recent: make([]float64, 0, size), sorted: make([]float64, 0, size)}
}

// next is the scale to draw a window of this peak at: the pinned one, or the
// hold window's percentile snapped up to a step the gutter can name. Snapping
// up is what keeps a fitted trace inside the rows: it is never clipped, only
// drawn coarser than the signal deserves. A peak above the fit is drawn
// clamped, which is the honest picture of a spike the rest of the second
// disagrees with.
func (s *scopeScaler) next(peak float64) float64 {
	if !s.scale.auto {
		return s.scale.fixed
	}
	if len(s.recent) < s.size {
		s.recent = append(s.recent, peak)
	} else {
		s.recent[s.at] = peak
		s.at = (s.at + 1) % s.size
	}
	s.sorted = append(s.sorted[:0], s.recent...)
	slices.Sort(s.sorted)
	fit := scopePercentile(s.sorted, scopeScalePercent) * scopeScaleHeadroom
	for _, step := range scopeScaleSteps {
		if fit <= step {
			return step
		}
	}
	return 1
}

// scopePercentile is the largest of an ascending slice once its loudest tail
// is dropped: p of 1 keeps everything, and p of 0.9 drops the loudest tenth,
// rounded up so that at least one value goes whenever there is more than one
// to rank. Rounding up is what makes the fit mean the same thing in a short
// window as in a long one: a nearest-rank tenth of nine or fewer values is no
// values at all, which would hand a single burst the whole scale at the low
// frame rates and over the first frames of any run. Zero where there is
// nothing to rank yet.
func scopePercentile(sorted []float64, p float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	drop := int(math.Ceil((1 - p) * float64(len(sorted))))
	i := len(sorted) - 1 - drop
	return sorted[max(0, min(i, len(sorted)-1))]
}

// scopePeak is the window's largest excursion either side of zero, which is
// what the auto scale is fitted to; the header's peak is the same number said
// as a level.
func scopePeak(samples []float32) float64 {
	peak := 0.0
	for _, s := range samples {
		if a := math.Abs(float64(s)); a > peak {
			peak = a
		}
	}
	return peak
}

// ScopeRow is one JSON row of `ley scope --json`: the frame's statistics and
// what the daemon says is under them, never the samples -- those are `ley
// listen --format json`. Bulk frames have no proto message, so this shape is
// part of the documented bulk-row exception to the proto3 rule; see
// docs/reference/cli.md. Seq and SampleIndex name the daemon frame the window
// closed on.
type ScopeRow struct {
	Seq         uint64  `json:"seq"`
	SampleIndex uint64  `json:"sample_index"`
	SampleRate  uint32  `json:"sample_rate"`
	Tap         string  `json:"tap"`
	WindowMs    int     `json:"window_ms"`
	PeakDbfs    float64 `json:"peak_dbfs"`
	RmsDbfs     float64 `json:"rms_dbfs"`
	DC          float64 `json:"dc"`
	// Scale is the vertical scale the frame was drawn at, so a row says what
	// the picture beside it meant: 1 at full scale, the fitted step under
	// --scale auto.
	Scale float64 `json:"scale"`
	// ToneHz is the sub-audible tone the daemon named, or its measurement when
	// it named none; it is absent until the daemon has reported one, because a
	// zero there would read as "no tone" rather than "not looked yet".
	ToneHz *float64 `json:"tone_hz,omitempty"`
}

// scopeTuneFlags are the tune flags scope registers; the capture rate is not
// among them, so --rate stays the view's own frames a second.
var scopeTuneFlags = []string{"mode", "bw", "squelch", "gain", "device", "retune"}

type scopeOptions struct {
	// channel, when non-empty, is an existing channel id (or id prefix) to
	// tap instead of making one.
	channel  string
	tune     *tuneOptions
	tap      leylinev1.AudioTap
	scale    scopeScale
	windowMs int
	trigger  bool
	rate     float64
	count    int
	width    int
}

func newScopeCommand(app *App) *cobra.Command {
	var (
		f       tuneFlags
		o       scopeOptions
		tap     string
		trigger string
		scale   string
	)
	cmd := &cobra.Command{
		Use:     "scope <frequency|preset|channel>",
		Short:   "Draw the waveform a mode produces",
		GroupID: GroupLooking,
		Long: `scope draws what the demodulator made: one window of samples per frame,
fitted to the signal top to bottom, redrawn where it stands. It is the view
that tells the modes apart -- FM voice through the AM detector is a flat
line with ripple, a carrier in CW is a sine, NFM voice is a voice -- and on
the demod tap it is the only view that shows what rides under the audio.

It takes a frequency, a preset or a channel id the way 'ley listen' does,
making a capture and a channel when none exists and removing what it made on
exit, and it opens no speakers.

--tap audio is what the speakers get, after the high-pass, de-emphasis and
gain control. --tap demod is the detector's own output before any of that: an
NFM trace still carries its CTCSS tone and the DC offset that is the tuning
error, and it keeps drawing while the squelch is closed, which is how you see
what a transmitter sends between words. While the squelch is closed the audio
tap says under the header that it is muted, because a flat trace under a
header that still names a tone reads as a fault. A raw-IQ channel has no
detector, and the daemon refuses the demod tap on one.

--trigger auto starts each frame at a rising zero crossing when the window
repeats steadily, which holds a tone still; free lets the trace run. The
trigger is presentation, the same as a bench scope's.

--scale auto, the default, fits the trace to the signal and holds the fit for
about a second so it does not flicker between syllables; a spike louder than
the rest of that second draws clamped rather than shrinking the picture.
--scale full draws the whole range the tap can carry, so a trace that grows
is a signal that grew, and on the demod tap that range is the channel's own
full deviation, which the header names in hertz; --scale 0.2 pins it. The
gutter names whichever is in force.

The tone in the header is the daemon's measurement. scope never estimates one
itself, so the picture and the claim can disagree, which is the point of
having both.

--json prints one object per frame and no samples:
{seq, sample_index, sample_rate, tap, window_ms, peak_dbfs, rms_dbfs, dc,
scale, tone_hz}. The samples themselves are 'ley listen --format json'.`,
		Example: `  ley scope 146.52                      # what the speaker would hear
  ley scope 145.23 --tap demod          # the PL tone riding under the voice
  ley scope chan_01J... --window 100    # a wider window on a channel already running
  ley scope 145.23 --tap demod --scale full --window 250   # the whole deviation
  ley scope 101.1 --tap demod --count 20 --json`,
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
			switch trigger {
			case "auto":
				o.trigger = true
			case "free":
				o.trigger = false
			default:
				return usageErrorf("--trigger must be auto (hold a repeating window still) or free (never trigger)")
			}
			sc, err := parseScopeScale(scale)
			if err != nil {
				return err
			}
			o.scale = sc
			if o.windowMs < scopeWindowMin || o.windowMs > scopeWindowMax {
				return usageErrorf("--window must be %d..%d ms, got %d", scopeWindowMin, scopeWindowMax, o.windowMs)
			}
			if o.rate <= 0 || o.rate > scopeRateMax {
				return usageErrorf("--rate must be more than 0 and at most %d frames a second", scopeRateMax)
			}
			arg := ""
			if len(args) == 1 {
				arg = args[0]
			}
			channel, tune, err := tapTarget(cmd, &f, "scope", arg, scopeTuneFlags)
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
			// clamp (docs/dev/cli-style.md section 2).
			if o.width = app.Style.Width; o.width <= 0 {
				o.width = ui.DefaultWidth
			}
			if o.tune != nil {
				if s.device, err = pickDevice(s.state, o.tune.device); err != nil {
					return err
				}
			}
			return runScope(cmd.Context(), s, o)
		},
	}
	addSignalFlags(cmd, &f, false)
	// The radio flags without the capture rate: --rate here is frames a second.
	addRadioFlags(cmd, &f, false)
	cmd.Flags().StringVar(&tap, "tap", "audio", "which stage to draw: audio (what the speakers get) or demod (the detector's output, before the audio chain)")
	cmd.Flags().IntVar(&o.windowMs, "window", 40, "how much of the signal one frame covers, in milliseconds (5..500)")
	cmd.Flags().StringVar(&trigger, "trigger", "auto", "auto holds a repeating window still; free lets the trace run")
	cmd.Flags().StringVar(&scale, "scale", "auto", "how far from the centre the top of the trace stands: auto (fit the signal), full (±1.0), or a number such as 0.2")
	cmd.Flags().Float64Var(&o.rate, "rate", 20, "frames a second (at most 20)")
	cmd.Flags().IntVar(&o.count, "count", 0, "stop after this many frames, e.g. 10 (default: until Ctrl-C)")
	cmd.Flags().IntVar(&o.width, "width", 0, "trace width in columns (default: the terminal's, or 80 when piped)")
	return cmd
}

// runScope taps the channel, collects the stream into windows and draws one
// every frame: the picture, the frame's statistics, and the daemon's tone.
func runScope(ctx context.Context, s *session, o scopeOptions) error {
	stop, err := s.openChannel(ctx, o.tune, o.channel)
	if err != nil {
		return err
	}
	defer stop()
	sctx, cancel := context.WithCancel(ctx)
	defer cancel()
	// F32 because the trace is drawn in the units the tap is defined in: full
	// scale is 1.0, and on the demod tap the DC offset is a small fraction of
	// it that a 16-bit round trip would coarsen.
	sub, err := s.client.SubscribeAudioTap(sctx, s.channel.ChannelId, 0,
		leylinev1.AudioSampleFormat_F32, o.tap)
	if err != nil {
		return err
	}
	defer sub.Close()
	ap := sub.Descriptor.GetAudio()
	rate, format, tap := ap.GetSampleRate(), ap.GetFormat(), ap.GetTap()
	fullScaleHz := scopeFullScaleHz(ap, s.channel)
	// The tone and the squelch are the daemon's to report; the view only carries
	// them. The stream's error is deliberately not read: both are garnish on the
	// picture, so a telemetry stream that ends takes the header's PL and its
	// squelch line with it and leaves the trace running.
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
	s.say("drawing %s: the %s tap at %d Hz, %d ms a frame. Ctrl-C stops. %s\n",
		what, scopeTapName(tap), rate, o.windowMs, s.app.ErrStyle.Muted("from "+s.channel.ChannelId))
	// Keep the event stream flowing (and the mirror current) while frames are
	// drawn; the drain owns the mirror, so it starts after the last read of it
	// and stops before teardown.
	stopDrain := s.drainEvents()
	defer stopDrain()

	view := newScopeView(s.app.Style, o.width, o.scale, s.app.IsTTY())
	out := bufio.NewWriter(s.app.Stdout)
	defer out.Flush()
	var w *chartWriter
	if !s.app.JSON {
		w = newChartWriter(s.app, out, true, o.rate)
		defer w.finish()
	}
	tick := time.NewTicker(chartTickInterval)
	defer tick.Stop()
	window := o.windowMs * int(rate) / 1000
	if window < 1 {
		window = 1
	}
	// Twice the window: one to draw, and one for the trigger to look back
	// through for the crossing that holds the picture still.
	buf := make([]float32, 0, 2*window)
	interval := time.Duration(float64(time.Second) / o.rate)
	var tone *leylinev1.SubAudible
	var last time.Time
	// Muted until the daemon says otherwise: a view that announced a closed
	// squelch before the first meter would be guessing at what it cannot see.
	muted := false
	scaler := newScopeScaler(o.scale, interval)
	frames := 0
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
				msgs, tone, muted = nil, nil, false
				continue
			}
			switch b := m.Body.(type) {
			case *leylinev1.TelemetryMsg_SubAudible:
				tone = b.SubAudible
			case *leylinev1.TelemetryMsg_Meter:
				muted = !b.Meter.GetSquelchOpen()
			}
		case fr, ok := <-sub.Frames:
			if !ok {
				return scopeEnd(ctx, sub.Err(), frames)
			}
			buf = append(buf, leyline.DecodeAudio(fr.Payload, format)...)
			if keep := 2 * window; len(buf) > keep {
				buf = append(buf[:0], buf[len(buf)-keep:]...)
			}
			if len(buf) < window || time.Since(last) < interval {
				continue
			}
			last = time.Now()
			start := len(buf) - window
			if o.trigger {
				start = scopeTrigger(buf, window)
			}
			samples := buf[start : start+window]
			peak, rms, dc := scopeStats(samples)
			// Every frame moves the auto scale on, drawn or not, so that the
			// hold measures the last second of signal rather than the last
			// second of JSON rows.
			scale := scaler.next(scopePeak(samples))
			if s.app.JSON {
				row := ScopeRow{
					Seq: fr.Seq, SampleIndex: fr.Time.GetSampleIndex(), SampleRate: rate,
					Tap: scopeTapName(tap), WindowMs: o.windowMs,
					PeakDbfs: peak, RmsDbfs: rms, DC: dc, Scale: scale, ToneHz: scopeToneHz(tone),
				}
				b, err := json.Marshal(row)
				if err != nil {
					return err
				}
				out.Write(b)
				out.WriteByte('\n')
			} else {
				w.frame(view.render(scopeFrame{
					samples: samples, tap: tap, windowMs: o.windowMs, scale: scale,
					peakDbfs: peak, rmsDbfs: rms, fullScaleHz: fullScaleHz,
					tuningHz: scopeTuningHz(tap, fullScaleHz, dc), what: what, tone: tone,
					// The squelch mutes the audio tap and not the detector, so
					// it is only the audio trace that needs explaining.
					muted: muted && tap == leylinev1.AudioTap_TAP_AUDIO,
				}), "")
			}
			if err := out.Flush(); err != nil {
				return err
			}
			frames++
			if o.count > 0 && frames >= o.count {
				return nil
			}
		}
	}
}

// scopeEnd turns the end of the audio stream into what to do next, by the one
// rule the live views share.
func scopeEnd(ctx context.Context, err error, frames int) error {
	return liveStreamEnd(ctx, err, frames, "audio stream", "window")
}

// scopeStats measures the window the frame draws: how far it swings, how much
// of it there is, and where its centre sits. They are presentation over the
// daemon's stream, the way spectrum's peaks are.
func scopeStats(samples []float32) (peakDbfs, rmsDbfs, dc float64) {
	if len(samples) == 0 {
		return scopeMinDbfs, scopeMinDbfs, 0
	}
	peak, sum, square := 0.0, 0.0, 0.0
	for _, s := range samples {
		v := float64(s)
		if a := math.Abs(v); a > peak {
			peak = a
		}
		sum += v
		square += v * v
	}
	n := float64(len(samples))
	return scopeDbfs(peak), scopeDbfs(math.Sqrt(square / n)), sum / n
}

// scopeDbfs is an amplitude as a level against full scale. Silence has no
// level, so the scale stops rather than running to negative infinity, which is
// not a number a JSON row can carry.
func scopeDbfs(amplitude float64) float64 {
	db := 20 * math.Log10(amplitude)
	if math.IsNaN(db) || db < scopeMinDbfs {
		return scopeMinDbfs
	}
	return db
}

// scopeFullScaleHz is what ±1.0 on the tap stands for in hertz: the deviation
// the daemon answered in the descriptor, which follows the channel's own
// bandwidth and so cannot be inferred from the mode alone. A daemon that left
// it at zero on an FM mode is answered from the same rule, and 0 stands for
// the amplitude modes, whose samples are not frequency at all.
func scopeFullScaleHz(ap *leylinev1.AudioParams, ch *leylinev1.Channel) uint32 {
	if hz := ap.GetFullScaleDeviationHz(); hz != 0 {
		return hz
	}
	return leyline.FullScaleDeviationHz(ch.GetMode(), ch.GetBandwidthHz())
}

// scopeTuningHz reads a demod tap's DC offset as a tuning error. Only the FM
// detectors have one: their output is frequency, so a constant offset is a
// constant frequency error, scaled by the deviation full scale stands for.
func scopeTuningHz(tap leylinev1.AudioTap, fullScaleHz uint32, dc float64) float64 {
	if tap != leylinev1.AudioTap_TAP_DEMOD || fullScaleHz == 0 {
		return math.NaN()
	}
	return dc * float64(fullScaleHz)
}

// scopeToneHz is the tone for the JSON row: the one the daemon named, or its
// measurement when it named none, and nothing at all until it has looked.
func scopeToneHz(sa *leylinev1.SubAudible) *float64 {
	if sa == nil || sa.Kind != leylinev1.SubAudibleKind_SUB_AUDIBLE_CTCSS {
		return nil
	}
	hz := sa.StandardToneHz
	if hz == 0 {
		hz = sa.ToneHz
	}
	if math.IsNaN(hz) || hz == 0 {
		return nil
	}
	return &hz
}

// How steady a window has to look before the trigger will hold it. Four
// crossings are three intervals, which is enough to tell a period from a
// coincidence, and a tenth of the period is the slack a tone riding under
// another one moves the crossing by.
const (
	scopeTriggerCrossings = 4
	scopeTriggerTolerance = 0.1
)

// scopeTrigger picks where the drawn window starts, so a repeating signal
// holds still from frame to frame instead of sliding across the screen: the
// latest rising crossing that still leaves a full window, when the crossings
// are evenly enough spaced to be a period. Anything else free-runs, which is
// the honest picture of a signal that does not repeat.
func scopeTrigger(buf []float32, window int) int {
	free := len(buf) - window
	if free <= 0 {
		return 0
	}
	// Crossings are counted against the buffer's own centre, not zero: a demod
	// tap sits off the axis by its tuning error, and a trigger at zero would
	// never fire on it.
	mid := 0.0
	for _, s := range buf {
		mid += float64(s)
	}
	mid /= float64(len(buf))
	var crossings []int
	for i := 1; i < len(buf); i++ {
		if float64(buf[i-1]) <= mid && float64(buf[i]) > mid {
			crossings = append(crossings, i)
		}
	}
	if len(crossings) < scopeTriggerCrossings {
		return free
	}
	period := float64(crossings[len(crossings)-1]-crossings[0]) / float64(len(crossings)-1)
	if period < 2 {
		return free
	}
	for i := 1; i < len(crossings); i++ {
		if math.Abs(float64(crossings[i]-crossings[i-1])-period) > scopeTriggerTolerance*period {
			return free
		}
	}
	for i := len(crossings) - 1; i >= 0; i-- {
		if crossings[i] <= free {
			return crossings[i]
		}
	}
	return free
}
