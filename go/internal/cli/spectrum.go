package cli

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// spectrumPeaks is how many loudest bins the "loudest bins:" line and the
// JSON peaks array carry.
const spectrumPeaks = 5

// spectrumHeight is the bar chart's height in rows.
const spectrumHeight = 10

// defaultSpectrumWidth is used when the terminal width is unknown (piped).
const defaultSpectrumWidth = 80

// Peak is one entry of `ley spectrum --json`'s peaks: a loud bin's centre.
type Peak struct {
	CenterHz uint64  `json:"center_hz"`
	Db       float64 `json:"db"`
}

// SpectrumRow is one JSON line of `ley spectrum --json`: the FFT row shape
// (see FFTRow) plus the loudest bins.
type SpectrumRow struct {
	FFTRow
	Peaks []Peak `json:"peaks"`
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
frequency, taller is louder. Under the chart it lists the loudest bins so
you can read a frequency straight off. Levels are dBFS (0 is the loudest
the radio can hear; the header prints the noise floor, which depends on gain).

Without a frequency it shows the band the device is already tuned to (what
'ley tune' is listening to). With a frequency it needs the device to be
free, or already tuned to a band that covers it; a capture is created for
the run and removed when spectrum exits. When other channels are listening
on a band that does not cover the frequency, spectrum refuses to move the
radio unless --retune is given.

It draws once by default. --watch keeps redrawing (--rate times a second)
until Ctrl-C. Everything here comes from the daemon's FFT stream: 'ley fft'
prints the same rows as numbers for tools.`,
		Example: `  ley spectrum 101.1          # the FM broadcast band around 101.1 MHz
  ley spectrum                # the band ley tune is listening to
  ley spectrum 146.52 -w      # keep redrawing until Ctrl-C
  ley spectrum 7.1 --span 200k --bins 2048
  ley spectrum 101.1 --json   # one row: {seq, sample_index, center_hz, span_hz, bins, peaks}`,
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
			if o.width == 0 {
				o.width = app.TermWidth()
			}
			if o.width <= 0 {
				o.width = defaultSpectrumWidth
			}
			return runSpectrum(cmd.Context(), app, o)
		},
	}
	cmd.Flags().StringVar(&span, "span", "", "width of the band to show, e.g. 2.4M or 200k (default: the device's default rate)")
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
	// ensureCapture reuses a capture that covers the frequency, refuses to
	// move one other channels ride on (unless --retune), and creates one
	// otherwise; the capture created for this run is removed on exit.
	freq := o.freq
	if freq == 0 {
		freq = cap.CenterHz
	}
	if err := s.ensureCapture(ctx, &tuneOptions{freq: freq, input: o.freqInput, rate: o.span, retune: o.retune}); err != nil {
		return err
	}
	if s.createdCapture {
		defer s.teardown()
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
	redraw := o.watch && !app.JSON && app.IsTTY()
	n, lastLines := 0, 0
	for fr := range sub.Frames {
		if len(fr.Payload) == 0 {
			continue
		}
		bins := decodeBins(fr.Payload, u8)
		peaks := loudestBins(bins, desc.CenterHz, desc.SpanHz, spectrumPeaks, medianDb(bins)+peakAboveFloorDb)
		if app.JSON {
			row := SpectrumRow{FFTRow: FFTRow{Seq: fr.Seq, SampleIndex: fr.Time.GetSampleIndex(), CenterHz: desc.CenterHz, SpanHz: desc.SpanHz, Bins: bins}, Peaks: peaks}
			b, err := json.Marshal(row)
			if err != nil {
				return err
			}
			out.Write(b)
			out.WriteByte('\n')
		} else {
			text := renderSpectrum(bins, peaks, desc.CenterHz, desc.SpanHz, o.width)
			if redraw && lastLines > 0 {
				fmt.Fprintf(out, "\x1b[%dA", lastLines)
			}
			out.WriteString(text)
			lastLines = strings.Count(text, "\n")
			if !redraw && o.watch {
				out.WriteString("\n")
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
	if err := sub.Err(); err != nil && ctx.Err() == nil {
		return err
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

// peakAboveFloorDb is how far above the noise floor (the row's median) a
// bin must be to count as a peak; below that it is noise, not a signal.
const peakAboveFloorDb = 6

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
	if len(peaks) > n {
		peaks = peaks[:n]
	}
	if peaks == nil {
		peaks = []Peak{}
	}
	return peaks
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

// renderSpectrum draws the header, the bar chart and the loudest-bins line.
func renderSpectrum(bins []float64, peaks []Peak, centerHz, spanHz uint64, width int) string {
	var b strings.Builder
	floor := medianDb(bins)
	lo := float64(centerHz) - float64(spanHz)/2
	hi := float64(centerHz) + float64(spanHz)/2
	binWidth := float64(spanHz) / math.Max(1, float64(len(bins)))
	fmt.Fprintf(&b, "%s, span %s (%s to %s), %d bins of %s, floor %.0f dB\n",
		leyline.FormatFrequency(centerHz), leyline.FormatFrequency(spanHz),
		leyline.FormatFrequency(uint64(math.Max(0, lo))), leyline.FormatFrequency(uint64(hi)),
		len(bins), leyline.FormatFrequency(uint64(math.Round(binWidth))), floor)
	const gutter = 7 // "-100 |" plus a space
	cols := width - gutter
	if cols < 10 {
		cols = 10
	}
	if cols > len(bins) {
		cols = len(bins)
	}
	// Each column shows the loudest bin it covers.
	colDb := make([]float64, cols)
	for c := range colDb {
		from, to := c*len(bins)/cols, (c+1)*len(bins)/cols
		if to <= from {
			to = from + 1
		}
		m := math.Inf(-1)
		for _, v := range bins[from:to] {
			m = math.Max(m, v)
		}
		colDb[c] = m
	}
	top := floor
	for _, v := range colDb {
		top = math.Max(top, v)
	}
	bottom := floor - 5
	top = math.Max(top, bottom+10)
	for r := spectrumHeight; r >= 1; r-- {
		level := bottom + (top-bottom)*float64(r)/spectrumHeight
		fmt.Fprintf(&b, "%4.0f |", level)
		for _, v := range colDb {
			if v >= level {
				b.WriteByte('#')
			} else {
				b.WriteByte(' ')
			}
		}
		b.WriteByte('\n')
	}
	b.WriteString("     +" + strings.Repeat("-", cols) + "\n")
	l, m, h := leyline.FormatFrequency(uint64(math.Max(0, lo))), leyline.FormatFrequency(centerHz), leyline.FormatFrequency(uint64(hi))
	pad := cols - len(l) - len(m) - len(h)
	if pad < 2 {
		pad = 2
	}
	fmt.Fprintf(&b, "      %s%s%s%s%s\n", l, strings.Repeat(" ", pad/2), m, strings.Repeat(" ", pad-pad/2), h)
	if len(peaks) == 0 {
		b.WriteString("loudest bins: nothing above the floor\n")
		return b.String()
	}
	parts := make([]string, len(peaks))
	for i, p := range peaks {
		parts[i] = fmt.Sprintf("%s %.0f dB", leyline.FormatFrequency(p.CenterHz), p.Db)
	}
	b.WriteString("loudest bins: " + strings.Join(parts, ", ") + "\n")
	return b.String()
}
