package cli

import (
	"bufio"
	"context"
	"fmt"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

type waterfallOptions struct {
	freq, span   uint64
	freqInput    string
	bins         uint32
	rate         float64
	count, width int
	retune       bool
	device       string
}

func newWaterfallCommand(app *App) *cobra.Command {
	var o waterfallOptions
	var freq, span string
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
with --span to see shape, or use 'ley spectrum' for levels.`,
		Example: `  ley waterfall 146.52              # is the local repeater busy?
  ley waterfall 162.55 --span 250k  # narrow: a channel at a time
  ley waterfall --rate 4            # four rows a second
  ley waterfall 101.1 --count 40    # forty rows, then stop`,
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			var err error
			if len(args) == 1 {
				freq, o.freqInput = args[0], args[0]
			}
			if freq != "" {
				if o.freq, err = leyline.ParseUserFrequency(freq); err != nil {
					return usageErrorf("%v. Example: ley waterfall 146.52 (MHz) or ley waterfall 146520k", err)
				}
			}
			if span != "" {
				if o.span, err = leyline.ParseUserFrequency(span); err != nil {
					return usageErrorf("--span: %v. Example: --span 2.4M or --span 250k", err)
				}
			}
			if o.count < 0 {
				return usageErrorf("--count must be 0 or more")
			}
			if o.rate <= 0 {
				return usageErrorf("--rate must be greater than 0")
			}
			o.width = app.Style.Width
			if o.width <= 0 {
				o.width = ui.DefaultWidth
			}
			return runWaterfall(cmd.Context(), app, o)
		},
	}
	cmd.Flags().StringVar(&span, "span", "", "width of the band to show, e.g. 2.4M or 250k; this is the capture's sample rate (default: the device's own, or the width it is already capturing)")
	cmd.Flags().Uint32Var(&o.bins, "bins", 1024, "number of bins across the band before they are folded into columns (the daemon may round it)")
	cmd.Flags().Float64Var(&o.rate, "rate", 2, "rows per second")
	cmd.Flags().IntVar(&o.count, "count", 0, "stop after N rows (0 = until Ctrl-C)")
	cmd.Flags().StringVar(&o.device, "device", "", "device: an id, id prefix, list index or frequency (default: the first real radio)")
	cmd.Flags().BoolVar(&o.retune, "retune", false, "move the radio to the frequency even when other channels are listening on it (they fall silent)")
	cmd.Flags().IntVar(&o.width, "width", 0, "map width in columns (default: the terminal's, or 80 when piped)")
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
		retune: o.retune, device: o.device, verb: "waterfall",
	}); err != nil {
		return err
	}
	if s.createdCapture {
		defer s.teardown()
	}
	sctx, cancel := context.WithCancel(ctx)
	defer cancel()
	// ROW_MAX, not the default: a row that samples one block of its interval
	// misses most of what happens in it, and duty cycle is the whole point of
	// this view. The daemon answers with the looks it actually took.
	sub, err := s.client.SubscribeFFTAccumulated(sctx, s.capture.CaptureId, o.bins, o.rate,
		leylinev1.FftBinFormat_DB_F32, leylinev1.FftAccumulation_ROW_MAX)
	if err != nil {
		return err
	}
	defer sub.Close()
	stopDrain := s.drainEvents()
	defer stopDrain()

	desc := sub.Descriptor
	u8 := desc.GetFft().GetBinFormat() == leylinev1.FftBinFormat_DB_U8
	out := bufio.NewWriter(app.Stdout)
	defer out.Flush()

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
				return spectrumEnd(ctx, sub.Err(), n)
			}
			if len(fr.Payload) == 0 {
				continue
			}
			bins := decodeBins(fr.Payload, u8)
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
			// silently missing makes time compress, which is exactly the thing
			// this view is read for.
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
