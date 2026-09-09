package cli

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"sort"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// spectrumPeaks is the most peaks the chart's peak block and the JSON peaks
// array carry. Fewer is normal: the list is as long as the evidence.
const spectrumPeaks = 5

// Peak is one entry of `ley spectrum --json`'s peaks: a loud bin's centre.
type Peak struct {
	CenterHz uint64  `json:"center_hz"`
	Db       float64 `json:"db"`
}

// SpectrumRow is one JSON line of `ley spectrum --json`: the FFT row shape
// (see FFTRow) plus the noise floor the peaks were judged against and the
// loudest bins.
type SpectrumRow struct {
	FFTRow
	FloorDb float64 `json:"floor_db"`
	Peaks   []Peak  `json:"peaks"`
}

type spectrumOptions struct {
	freq, span   uint64
	freqInput    string
	bins         uint32
	rate         float64
	count, width int
	watch        bool
	retune       bool
	device       string
}

func newSpectrumCommand(app *App) *cobra.Command {
	var o spectrumOptions
	var freq, span string
	cmd := &cobra.Command{
		Use:   "spectrum [frequency]",
		Short: "Show what is on the air around a frequency",
		Long: `spectrum draws the band around a frequency as a bar chart: left to right is
frequency, taller is louder. Under the chart it names the loudest bins and
how far the strongest sits above the noise, so you can read a frequency
straight off. Levels are dBFS (0 is the loudest the radio can hear; the
header prints the noise floor, which depends on gain). Only bins well clear
of the floor are named, so a quiet band names none.

Without a frequency it shows the band the device is already tuned to (what
'ley tune' is listening to). With a frequency it needs the device to be
free, or already tuned to a band that covers it; a capture is created for
the run and removed when spectrum exits. When other channels are listening
on a band that does not cover the frequency, spectrum refuses to move the
radio unless --retune is given.

--span is the width of the band shown, which is the capture's sample rate.
For a fresh capture it is snapped to the nearest rate the radio supports
(spectrum says so on stderr); when the radio is already capturing at a
different width, spectrum exits 2 and names it: drop --span, ask for that
width, or free the radio with 'ley stop all'.

It draws once by default. --watch keeps redrawing (--rate times a second)
until Ctrl-C: the dB scale is held for the run so frames can be compared, a
faint trace marks the loudest each column has been, and a status line says
how many rows have arrived or that the stream has gone quiet. Everything
here comes from the daemon's FFT stream: 'ley fft' prints the same rows as
numbers for tools.`,
		Example: `  ley spectrum 101.1          # the FM broadcast band around 101.1 MHz
  ley spectrum                # the band ley tune is listening to
  ley spectrum 146.52 -w      # keep redrawing until Ctrl-C
  ley spectrum 7.1 --span 250k --bins 2048   # 250 kHz is the narrowest an RTL-SDR captures
  ley spectrum 101.1 --json   # one row: {seq, sample_index, center_hz, span_hz, bins, floor_db, peaks}`,
		GroupID: GroupLooking,
		Args:    cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			if len(args) == 1 {
				freq = args[0]
				o.freqInput = args[0]
			}
			var err error
			if freq != "" {
				if o.freq, err = leyline.ParseUserFrequency(freq); err != nil {
					return usageErrorf("%v. Example: ley spectrum 101.1 (MHz) or ley spectrum 1010k", err)
				}
			}
			if span != "" {
				if o.span, err = leyline.ParseUserFrequency(span); err != nil {
					return usageErrorf("--span: %v. Example: --span 2.4M or --span 200k", err)
				}
			}
			if o.count < 0 {
				return usageErrorf("--count must be 0 or more")
			}
			// Width comes from the resolved style, which has already applied
			// --width, COLUMNS, the terminal's own size and the [40, 160]
			// clamp (docs/cli-style.md section 2).
			o.width = app.Style.Width
			if o.width <= 0 {
				o.width = ui.DefaultWidth
			}
			return runSpectrum(cmd.Context(), app, o)
		},
	}
	cmd.Flags().StringVar(&span, "span", "", "width of the band to show, e.g. 2.4M or 250k; this is the capture's sample rate, snapped to the nearest rate the radio supports (default: the device's default rate, or the width it is already capturing)")
	cmd.Flags().Uint32Var(&o.bins, "bins", 1024, "number of bins across the band (the daemon may round it)")
	cmd.Flags().BoolVarP(&o.watch, "watch", "w", false, "keep redrawing until Ctrl-C")
	cmd.Flags().Float64Var(&o.rate, "rate", 2, "redraws per second with --watch")
	cmd.Flags().IntVar(&o.count, "count", 0, "with --watch: stop after N rows (0 = until Ctrl-C)")
	cmd.Flags().StringVar(&o.device, "device", "", "device: an id, id prefix, list index or frequency (default: the first real radio)")
	cmd.Flags().BoolVar(&o.retune, "retune", false, "move the radio to the frequency even when other channels are listening on it (they fall silent)")
	cmd.Flags().IntVar(&o.width, "width", 0, "chart width in columns (default: the terminal's, or 80 when piped)")
	return cmd
}

// runSpectrum finds or creates the capture, subscribes to its FFT stream and
// renders rows until --count, one row (no --watch) or Ctrl-C (exit 0).
func runSpectrum(ctx context.Context, app *App, o spectrumOptions) error {
	s, err := openSession(ctx, app)
	if err != nil {
		return err
	}
	defer s.close()
	if s.device, err = pickDevice(s.state, o.device); err != nil {
		return err
	}
	cap := leyline.FindCapture(s.state, s.device.DeviceId)
	if cap == nil && o.freq == 0 {
		return usageErrorf("%s is not tuned to anything yet; say where to look, e.g.: ley spectrum 101.1", deviceName(s.device))
	}
	if o.freq != 0 && (cap == nil || !leyline.CaptureCovers(cap, o.freq)) {
		if !leyline.InRanges(o.freq, s.device.TuningRanges) && len(s.device.TuningRanges) > 0 {
			msg := fmt.Sprintf("%s is outside %s's range (%s)", leyline.FormatFrequency(o.freq), deviceName(s.device), leyline.FormatRanges(s.device.TuningRanges))
			if hint := leyline.FrequencyHint(o.freqInput, o.freq, s.device.TuningRanges); hint != "" {
				msg += "; " + hint
			}
			return usageErrorf("%s", msg)
		}
	}
	// --span is the capture width. A fresh capture gets the nearest rate the
	// radio supports (said on stderr); an existing capture keeps its width, so
	// a different span is refused up front rather than silently ignored.
	span := o.span
	if span != 0 {
		span = leyline.NearestRate(s.device.SampleRates, o.span)
		if cap != nil && cap.SampleRate != span {
			return usageErrorf("the radio is already capturing %s wide, and spectrum shows the capture's width; drop --span, ask for --span %s, or free the radio with: ley stop all",
				leyline.FormatFrequency(cap.SampleRate), leyline.FormatFrequency(cap.SampleRate))
		}
		if span != o.span {
			fmt.Fprintf(app.Stderr, "showing %s, the closest this radio can do to %s\n", leyline.FormatFrequency(span), leyline.FormatFrequency(o.span))
		}
	}
	// ensureCapture reuses a capture that covers the frequency, refuses to
	// move one other channels ride on (unless --retune), and creates one
	// otherwise; the capture created for this run is removed on exit.
	freq := o.freq
	if freq == 0 {
		freq = cap.CenterHz
	}
	if err := s.ensureCapture(ctx, &tuneOptions{freq: freq, input: o.freqInput, rate: span, retune: o.retune}); err != nil {
		return err
	}
	if s.createdCapture {
		defer s.teardown()
	}
	// A reused capture keeps its own centre, so the chart can be centred
	// somewhere other than the frequency that was asked for. Say so rather
	// than let the axis be a surprise.
	if o.freq != 0 && s.capture != nil && s.capture.CenterHz != o.freq {
		fmt.Fprintf(app.Stderr, "showing the capture at %s, which covers %s\n", leyline.FormatFrequency(s.capture.CenterHz), leyline.FormatFrequency(o.freq))
	}
	sctx, cancel := context.WithCancel(ctx)
	defer cancel()
	rate := o.rate
	if !o.watch {
		rate = 2
	}
	sub, err := s.client.SubscribeFFT(sctx, s.capture.CaptureId, o.bins, rate, leylinev1.FftBinFormat_DB_F32)
	if err != nil {
		return err
	}
	defer sub.Close()
	// Keep the event stream flowing (and the mirror current) while rows render;
	// stopped before teardown reads the mirror.
	stopDrain := s.drainEvents()
	defer stopDrain()
	desc := sub.Descriptor
	u8 := desc.GetFft().GetBinFormat() == leylinev1.FftBinFormat_DB_U8
	out := bufio.NewWriter(app.Stdout)
	defer out.Flush()
	// The frame is a terminal's: piped output stays plain lines a script can
	// read, and newSpectrumView drops it again on an ASCII or narrow screen.
	view := newSpectrumView(app.Style, o.width, o.freq, o.watch, app.IsTTY())
	w := newSpectrumWriter(app, out, o, rate)
	defer w.finish()
	tick := time.NewTicker(spectrumTickInterval)
	defer tick.Stop()
	n := 0
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-tick.C:
			// A row every so often is normal; no row at all is the failure the
			// status line and the stderr note exist to make visible. A one-shot
			// gives up rather than hanging for ever with nothing on screen;
			// --watch keeps waiting, and says so.
			w.idle()
			if !o.watch && n == 0 && time.Since(w.start) > spectrumFirstRow {
				return fmt.Errorf("no spectrum row arrived in %.0f s, so there is nothing to draw. Check the radio is still capturing with: ley state", spectrumFirstRow.Seconds())
			}
		case fr, ok := <-sub.Frames:
			if !ok {
				return spectrumEnd(ctx, sub.Err(), n)
			}
			if len(fr.Payload) == 0 {
				continue
			}
			bins := decodeBins(fr.Payload, u8)
			floor := medianDb(bins)
			peaks := loudestBins(bins, desc.CenterHz, desc.SpanHz, spectrumPeaks, floor+peakAboveFloorDb)
			if app.JSON {
				row := SpectrumRow{FFTRow: FFTRow{Seq: fr.Seq, SampleIndex: fr.Time.GetSampleIndex(), CenterHz: desc.CenterHz, SpanHz: desc.SpanHz, Bins: bins}, FloorDb: floor, Peaks: peaks}
				b, err := json.Marshal(row)
				if err != nil {
					return err
				}
				out.Write(b)
				out.WriteByte('\n')
				w.row()
			} else {
				text := view.render(bins, peaks, floor, desc.CenterHz, desc.SpanHz)
				w.frame(text, view.note())
				if !o.watch {
					w.footer(view.nextStep(peaks))
				}
			}
			if err := out.Flush(); err != nil {
				return err
			}
			n++
			if !o.watch || (o.count > 0 && n >= o.count) {
				return nil
			}
		}
	}
}

// spectrumEnd turns the end of the FFT stream into an exit. A stream that
// closed before producing anything is a failure the user must be told about:
// it used to hang, then exit 0, with no output at all.
func spectrumEnd(ctx context.Context, err error, rows int) error {
	if ctx.Err() != nil {
		return nil
	}
	if err != nil {
		return err
	}
	if rows == 0 {
		return errors.New("the spectrum stream ended before it sent a row. Check the radio is still capturing with: ley state")
	}
	return nil
}

// deviceName is the model when known, else the id.
func deviceName(d *leylinev1.DeviceDescriptor) string {
	if d.Model != "" {
		return d.Model
	}
	return d.DeviceId
}

// peakAboveFloorDb is how far above the noise floor (the row's median) a bin
// must be to count as a peak. The loudest of a thousand noise bins sits about
// 10 dB above their median by chance alone, so a threshold near that admits
// noise: at 6 dB four of five "loudest bins" were random bumps quoted like
// carriers. 15 dB is above what noise reaches and below any carrier worth
// tuning to.
const peakAboveFloorDb = 15

// loudestBins returns up to n of the loudest local maxima at or above minDb,
// loudest first, as bin-centre frequencies. A run of equal-height bins
// counts once; a row with nothing above minDb yields an empty list.
func loudestBins(bins []float64, centerHz, spanHz uint64, n int, minDb float64) []Peak {
	if len(bins) == 0 {
		return []Peak{}
	}
	binWidth := float64(spanHz) / float64(len(bins))
	left := float64(centerHz) - float64(spanHz)/2
	var peaks []Peak
	for i, v := range bins {
		if v < minDb {
			continue
		}
		if i > 0 && bins[i-1] >= v {
			continue
		}
		if i+1 < len(bins) && bins[i+1] > v {
			continue
		}
		peaks = append(peaks, Peak{CenterHz: uint64(math.Round(left + (float64(i)+0.5)*binWidth)), Db: v})
	}
	sort.SliceStable(peaks, func(a, b int) bool { return peaks[a].Db > peaks[b].Db })
	// One carrier is one entry: its shoulders are the same signal, so a peak
	// too close to a louder one is dropped rather than quoted as a second find.
	gap := math.Max(3*binWidth, float64(spanHz)/128)
	kept := make([]Peak, 0, n)
	for _, p := range peaks {
		if len(kept) >= n {
			break
		}
		near := false
		for _, k := range kept {
			if math.Abs(float64(p.CenterHz)-float64(k.CenterHz)) < gap {
				near = true
				break
			}
		}
		if !near {
			kept = append(kept, p)
		}
	}
	return kept
}

// medianDb is the row's median level: the noise floor, as presentation.
func medianDb(bins []float64) float64 {
	if len(bins) == 0 {
		return math.NaN()
	}
	s := append([]float64(nil), bins...)
	sort.Float64s(s)
	return s[len(s)/2]
}
