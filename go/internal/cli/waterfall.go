// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

type waterfallOptions struct {
	bandFlags
}

func newWaterfallCommand(app *App) *cobra.Command {
	var o waterfallOptions
	var span string
	cmd := &cobra.Command{
		Use:     "waterfall [frequency]",
		Short:   "Watch a band over time, so you can see what comes and goes",
		GroupID: GroupLooking,
		Long: `waterfall draws the band as a scrolling map: left to right is frequency,
down the screen is time, and a denser cell means a stronger signal. Each row
is one look at the band; the newest is at the bottom.

It answers the one question 'ley spectrum' cannot: is that signal always
there, or did it start and stop? A birdie draws a dead straight line down the
screen. A transmission draws a block with a beginning and an end. A pager
burst draws a dash. None of the three can be told apart in a single spectrum
frame.

Each row covers the whole interval between rows, not an instant, so a
transmission shorter than a row still shows up. The dB scale is chosen from
the first rows and then held for the run: if it moved, the same signal would
change shade because something else got louder, and two rows could not be
compared.

Read the header: at a wide span each column covers tens of kHz, so this is a
map of where energy is, not a picture of a signal's shape. Narrow the span
with --span to see shape, or use 'ley spectrum' for levels.

--json prints the rows instead of drawing them, one per line:
{seq, sample_index, center_hz, span_hz, bins, floor_db, looks} -- what
'ley fft' prints plus the looks folded into the row. A drop shows up as a
{"gap":{"from_sample":A,"to_sample":B}} line, as it does there.`,
		Example: `  ley waterfall 146.52              # is the local repeater busy?
  ley waterfall 162.55 --span 250k  # narrow: a channel at a time
  ley waterfall --rate 4            # four rows a second
  ley waterfall 101.1 --count 40    # forty rows, then stop`,
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := o.parse(app, args, span, bandUsage{
				verb:     "waterfall",
				examples: "ley waterfall 146.52, ley waterfall noaa",
				freqHint: "146.52 (MHz) or 146520k",
				spanHint: "--span 2.4M or --span 250k",
			}); err != nil {
				return err
			}
			return runWaterfall(cmd.Context(), app, o)
		},
	}
	cmd.Flags().StringVar(&span, "span", "", "width of the band to show, e.g. 2.4M or 250k; this is the capture's sample rate (default: the device's own, or the width it is already capturing)")
	cmd.Flags().Uint32Var(&o.bins, "bins", 1024, "number of bins across the band before they are folded into columns (the daemon may round it)")
	cmd.Flags().Float64Var(&o.rate, "rate", 2, "rows per second")
	cmd.Flags().IntVar(&o.count, "count", 0, "stop after N rows (0 = until Ctrl-C)")
	cmd.Flags().IntVar(&o.width, "width", 0, "map width in columns (default: the terminal's, or 80 when piped)")
	o.bindCommon(cmd)
	return cmd
}

// runWaterfall finds or creates the capture, subscribes to an accumulating FFT
// stream and prints one line per row until --count or Ctrl-C (exit 0).
func runWaterfall(ctx context.Context, app *App, o waterfallOptions) error {
	s, err := openSession(ctx, app)
	if err != nil {
		return err
	}
	defer s.close()
	if err := s.openBand(ctx, app, bandOptions{
		freq: o.freq, span: o.span, freqInput: o.freqInput,
		band: o.band, retune: o.retune, device: o.device, verb: "waterfall",
	}); err != nil {
		return err
	}
	if s.createdCapture {
		defer s.teardown()
	}
	sctx, cancel := context.WithCancel(ctx)
	defer cancel()
	// ROW_MAX, not the default: a row that samples one block of its interval
	// misses most of what happens in it, and this view exists to show duty
	// cycle. The daemon answers with the looks it actually took.
	sub, err := s.client.SubscribeFFTAccumulated(sctx, s.capture.CaptureId, o.bins, o.rate,
		leylinev1.FftBinFormat_DB_F32, leylinev1.FftAccumulation_ROW_MAX)
	if err != nil {
		return err
	}
	defer sub.Close()
	stopDrain := s.drainEvents()
	defer stopDrain()

	desc := sub.Descriptor
	binFormat := desc.GetFft().GetBinFormat()
	out := bufio.NewWriter(app.Stdout)
	defer out.Flush()

	if app.JSON {
		return waterfallRows(ctx, out, desc, sub, o)
	}
	view := newWaterfallView(app.Style, o.width, o.freq)
	view.centerHz, view.spanHz = desc.CenterHz, desc.SpanHz
	cols := view.cols(int(desc.GetFft().GetBins()))
	start := time.Now()
	n := 0
	var lastSeq uint64
	for {
		select {
		case <-ctx.Done():
			return nil
		case fr, ok := <-sub.Frames:
			if !ok {
				return spectrumEnd(ctx, "waterfall", sub.Err(), n)
			}
			if len(fr.Payload) == 0 {
				continue
			}
			bins := leyline.DecodeFFTBins(fr.Payload, binFormat)
			// The header waits for the scale, so it can state the floor the
			// shades are measured from rather than a number chosen later.
			if n == 0 {
				view.setScale(columnLevels(bins, cols))
				for _, l := range view.header(cols) {
					fmt.Fprintln(out, l)
				}
				for _, l := range view.key() {
					fmt.Fprintln(out, l)
				}
				for _, l := range view.axis(cols) {
					fmt.Fprintln(out, l)
				}
				if looks := desc.GetFft().GetLooksPerRow(); looks > 1 {
					fmt.Fprintf(app.Stderr, "each row is the loudest of %d looks across its interval\n", looks)
				}
			}
			// A gap is drawn, never skipped: delivery is GAP_MARKED, and a row
			// silently missing compresses the time axis, and timing is what this
			// view shows.
			if lastSeq != 0 && fr.Seq > lastSeq+1 {
				fmt.Fprintln(out, view.gapRow(fr.Seq-lastSeq-1))
			}
			lastSeq = fr.Seq
			if view.due() {
				for _, l := range view.axis(cols) {
					fmt.Fprintln(out, l)
				}
			}
			fmt.Fprintln(out, view.row(bins, time.Since(start).Seconds()))
			if err := out.Flush(); err != nil {
				return err
			}
			n++
			if o.count > 0 && n >= o.count {
				return nil
			}
		}
	}
}

// WaterfallRow is one JSON row of `ley waterfall --json`: the bulk-row shape
// `ley fft` prints, plus the number of looks the daemon folded into the row.
// Looks belongs on every row because this view asks for ROW_MAX accumulation:
// without it a reader cannot tell a row that saw the whole interval from one
// that sampled a single block of it, and the two mean different things.
type WaterfallRow struct {
	FFTRow
	Looks uint32 `json:"looks"`
}

// waterfallRows is `ley waterfall --json`: one NDJSON row per accumulated FFT
// row, gap-marked the way `ley fft` is, and no chart.
func waterfallRows(ctx context.Context, out *bufio.Writer, desc *leylinev1.StreamDescriptor,
	sub *leyline.Subscription, o waterfallOptions,
) error {
	binFormat := desc.GetFft().GetBinFormat()
	looks := desc.GetFft().GetLooksPerRow()
	n := 0
	for {
		select {
		case <-ctx.Done():
			return nil
		case fr, ok := <-sub.Frames:
			if !ok {
				return spectrumEnd(ctx, "waterfall", sub.Err(), n)
			}
			if fr.Gap != nil {
				if err := writeGap(out, fr.Gap); err != nil {
					return err
				}
			}
			if len(fr.Payload) == 0 {
				continue
			}
			bins := leyline.DecodeFFTBins(fr.Payload, binFormat)
			row := WaterfallRow{FFTRow{
				Seq: fr.Seq, SampleIndex: fr.Time.GetSampleIndex(),
				CenterHz: desc.CenterHz, SpanHz: desc.SpanHz,
				Bins: bins, FloorDb: floorOf(bins),
			}, looks}
			b, err := json.Marshal(row)
			if err != nil {
				return err
			}
			out.Write(b)
			out.WriteByte('\n')
			if err := out.Flush(); err != nil {
				return err
			}
			n++
			if o.count > 0 && n >= o.count {
				return nil
			}
		}
	}
}
