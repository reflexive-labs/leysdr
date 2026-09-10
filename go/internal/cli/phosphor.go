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

// phosphorRangeDb is how far above the floor the level axis reaches. The same
// 50 dB ley spectrum holds its scale over, so the two charts are read the same
// way and a signal of a given height means the same thing on both.
const phosphorRangeDb = 50

type phosphorOptions struct {
	freq, span   uint64
	freqInput    string
	bins         uint32
	levels       uint32
	halfLife     float64
	rate         float64
	count, width int
	retune       bool
	device       string
}

func newPhosphorCommand(app *App) *cobra.Command {
	var o phosphorOptions
	var freq, span string
	cmd := &cobra.Command{
		Use:     "phosphor [frequency]",
		Short:   "Show what is usually on a band, not just what is on it now",
		GroupID: GroupLooking,
		Long: `phosphor draws the band the same way 'ley spectrum' does -- frequency across,
level up -- but each cell is shaded by how often that frequency has sat at
that level, not by where it is right now. Bright means usual. Faint means it
happens, but rarely.

That is what makes it worth having: a signal that transmits for 80 ms every
minute is invisible on a live spectrum and obvious here, because the display
accumulates over time instead of trying to catch the moment. A steady carrier
piles up in one thin line; noise spreads into a band; an intermittent burst
leaves a faint mark exactly where it lives.

Counts fade with a half-life (--half-life), so "usual" means "usual lately"
rather than "at some point since you started". The header says the window.

Use it when you suspect something is on a band but never see it: ISM and
paging bands, telemetry, anything bursty. For reading levels right now use
'ley spectrum', and for when things happened use 'ley waterfall'.`,
		Example: `  ley phosphor 910                      # what lives on the 915 ISM band?
  ley phosphor 462.5625 --half-life 60  # a slower fade, for rare traffic
  ley phosphor 144.39 --span 250k       # narrow in on one channel`,
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			var err error
			if len(args) == 1 {
				freq, o.freqInput = args[0], args[0]
			}
			if freq != "" {
				if o.freq, err = leyline.ParseUserFrequency(freq); err != nil {
					return usageErrorf("%v. Example: ley phosphor 910 (MHz) or ley phosphor 910M", err)
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
			if o.halfLife <= 0 {
				return usageErrorf("--half-life must be greater than 0")
			}
			o.width = app.Style.Width
			if o.width <= 0 {
				o.width = ui.DefaultWidth
			}
			return runPhosphor(cmd.Context(), app, o)
		},
	}
	cmd.Flags().StringVar(&span, "span", "", "width of the band to show, e.g. 2.4M or 250k (default: the device's own, or the width it is already capturing)")
	cmd.Flags().Uint32Var(&o.bins, "bins", 256, "frequency bins across the band (the daemon may round it)")
	cmd.Flags().Uint32Var(&o.levels, "levels", 32, "level buckets the histogram keeps per bin")
	cmd.Flags().Float64Var(&o.halfLife, "half-life", 20, "seconds for a count to fade by half; longer remembers rarer traffic")
	cmd.Flags().Float64Var(&o.rate, "rate", 2, "redraws per second")
	cmd.Flags().IntVar(&o.count, "count", 0, "stop after N frames (0 = until Ctrl-C)")
	cmd.Flags().StringVar(&o.device, "device", "", "device: an id, id prefix, list index or frequency (default: the first real radio)")
	cmd.Flags().BoolVar(&o.retune, "retune", false, "move the radio to the frequency even when other channels are listening on it (they fall silent)")
	cmd.Flags().IntVar(&o.width, "width", 0, "chart width in columns (default: the terminal's, or 80 when piped)")
	return cmd
}

// runPhosphor finds or creates the capture, learns the noise floor from one FFT
// row, then subscribes to the persistence histogram accumulated on that scale.
func runPhosphor(ctx context.Context, app *App, o phosphorOptions) error {
	s, err := openSession(ctx, app)
	if err != nil {
		return err
	}
	defer s.close()
	if err := s.openBand(ctx, app, bandOptions{
		freq: o.freq, span: o.span, freqInput: o.freqInput,
		retune: o.retune, device: o.device, verb: "phosphor",
	}); err != nil {
		return err
	}
	if s.createdCapture {
		defer s.teardown()
	}
	sctx, cancel := context.WithCancel(ctx)
	defer cancel()
	stopDrain := s.drainEvents()
	defer stopDrain()

	// The scale is the client's to state, so find it the same way a one-shot
	// ley spectrum does: take a row and read its floor. The daemon will not
	// guess, because a histogram on the wrong scale is not obviously wrong to
	// look at, and by the time the descriptor is written no row has arrived.
	floor, err := s.firstFloorDb(sctx, o.bins)
	if err != nil {
		return err
	}
	sub, err := s.client.SubscribePersistence(sctx, s.capture.CaptureId, o.bins, o.levels,
		floor, phosphorRangeDb, o.halfLife, o.rate)
	if err != nil {
		return err
	}
	defer sub.Close()

	desc := sub.Descriptor
	p := desc.GetPersistence()
	view := newPhosphorView(app.Style, o.width, o.freq)
	view.centerHz, view.spanHz = desc.CenterHz, desc.SpanHz
	view.floorDb, view.rangeDb = p.GetFloorDb(), p.GetRangeDb()
	view.halfLife = p.GetHalfLifeSeconds()
	out := bufio.NewWriter(app.Stdout)
	defer out.Flush()
	w := newSpectrumWriter(app, out, spectrumOptions{watch: true, rate: o.rate, width: o.width}, o.rate)
	defer w.finish()
	tick := time.NewTicker(spectrumTickInterval)
	defer tick.Stop()
	n := 0
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-tick.C:
			w.idle()
		case fr, ok := <-sub.Frames:
			if !ok {
				return spectrumEnd(ctx, sub.Err(), n)
			}
			h, ok := decodePersistence(fr.Payload, int(p.GetBins()), int(p.GetLevels()))
			if !ok {
				continue
			}
			w.frame(view.render(h), "")
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

// firstFloorDb takes one FFT row and returns its median bin: the noise floor
// the persistence histogram is anchored on.
func (s *session) firstFloorDb(ctx context.Context, bins uint32) (float64, error) {
	fctx, cancel := context.WithCancel(ctx)
	defer cancel()
	sub, err := s.client.SubscribeFFT(fctx, s.capture.CaptureId, bins, 4, leylinev1.FftBinFormat_DB_F32)
	if err != nil {
		return 0, err
	}
	defer sub.Close()
	u8 := sub.Descriptor.GetFft().GetBinFormat() == leylinev1.FftBinFormat_DB_U8
	deadline := time.NewTimer(spectrumFirstRow)
	defer deadline.Stop()
	for {
		select {
		case <-ctx.Done():
			return 0, ctx.Err()
		case <-deadline.C:
			return 0, fmt.Errorf("no spectrum row arrived in %.0f s, so there is no noise floor to measure against. Check the radio is still capturing with: ley state", spectrumFirstRow.Seconds())
		case fr, ok := <-sub.Frames:
			if !ok {
				return 0, spectrumEnd(ctx, sub.Err(), 0)
			}
			if len(fr.Payload) == 0 {
				continue
			}
			return medianDb(decodeBins(fr.Payload, u8)), nil
		}
	}
}
