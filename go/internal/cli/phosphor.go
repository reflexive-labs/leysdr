// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// phosphorRangeDb is how far above the floor the level axis reaches. The same
// 50 dB ley spectrum holds its scale over, so the two charts are read the same
// way and a signal of a given height means the same thing on both.
const phosphorRangeDb = 50

type phosphorOptions struct {
	bandFlags
	levels   uint32
	halfLife float64
}

func newPhosphorCommand(app *App) *cobra.Command {
	var o phosphorOptions
	var span string
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
'ley spectrum', and for when things happened use 'ley waterfall'.

--json prints the histogram instead of drawing it, one frame per line:
{seq, sample_index, center_hz, span_hz, bins, levels, floor_db, range_db,
counts}, where counts is the daemon's bins x levels grid of little-endian
uint16 counts, bin-major, base64-encoded the way 'ley listen' carries pcm.`,
		Example: `  ley phosphor 910                      # what lives on the 915 ISM band?
  ley phosphor 462.5625 --half-life 60  # a slower fade, for rare traffic
  ley phosphor 144.39 --span 250k       # narrow in on one channel`,
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := o.parse(app, args, span, bandUsage{
				verb:     "phosphor",
				examples: "ley phosphor 910, ley phosphor noaa",
				freqHint: "910 (MHz) or 910M",
				spanHint: "--span 2.4M or --span 250k",
			}); err != nil {
				return err
			}
			if o.halfLife <= 0 {
				return usageErrorf("--half-life must be greater than 0")
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
	cmd.Flags().IntVar(&o.width, "width", 0, "chart width in columns (default: the terminal's, or 80 when piped)")
	o.bindCommon(cmd)
	return cmd
}

// runPhosphor finds or creates the capture, learns the noise floor from one FFT
// row, then subscribes to the persistence histogram accumulated on that scale.
func runPhosphor(ctx context.Context, app *App, o phosphorOptions) error {
	s, err := openSession(ctx, app)
	if err != nil {
		return err
	}
	defer s.Close()
	if err := s.openBand(ctx, app, bandOptions{
		freq: o.freq, span: o.span, freqInput: o.freqInput,
		band: o.band, retune: o.retune, device: o.device, verb: "phosphor",
	}); err != nil {
		return err
	}
	if s.createdCapture {
		defer s.teardown(ctx)
	}
	sctx, cancel := context.WithCancel(ctx)
	defer cancel()

	// The client must supply the scale, so find it the same way a one-shot
	// ley spectrum does: take a row and read its floor. The daemon will not
	// guess, because a histogram on the wrong scale is not obviously wrong to
	// look at, and by the time the descriptor is written no row has arrived.
	floor, err := s.firstFloorDb(sctx, o.bins)
	if err != nil {
		return err
	}
	sub, err := s.Client.SubscribePersistence(sctx, s.Capture.CaptureId, o.bins, o.levels,
		floor, phosphorRangeDb, o.halfLife, o.rate)
	if err != nil {
		return err
	}
	defer sub.Close()
	// Keep the event stream flowing (and the mirror current) while frames render; the drain owns
	// the mirror while it runs, so it starts after the last read of it and stops before teardown.
	stopDrain := s.DrainEvents()
	defer stopDrain()

	desc := sub.Descriptor
	p := desc.GetPersistence()
	if app.JSON {
		return phosphorRows(ctx, app, desc, sub, o)
	}
	view := newPhosphorView(app.Style, o.width, o.freq)
	view.centerHz, view.spanHz = desc.CenterHz, desc.SpanHz
	view.floorDb, view.rangeDb = p.GetFloorDb(), p.GetRangeDb()
	view.halfLife = p.GetHalfLifeSeconds()
	out := bufio.NewWriter(app.Stdout)
	defer out.Flush()
	w := newChartWriter(app, out, true, o.rate)
	defer w.finish()
	tick := time.NewTicker(chartTickInterval)
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
				return spectrumEnd(ctx, "persistence", sub.Err(), n)
			}
			h, ok := leyline.DecodePersistence(fr.Payload, int(p.GetBins()), int(p.GetLevels()))
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
func (s *verbSession) firstFloorDb(ctx context.Context, bins uint32) (float64, error) {
	fctx, cancel := context.WithCancel(ctx)
	defer cancel()
	sub, err := s.Client.SubscribeFFT(fctx, s.Capture.CaptureId, bins, 4, leylinev1.FftBinFormat_DB_F32)
	if err != nil {
		return 0, err
	}
	defer sub.Close()
	binFormat := sub.Descriptor.GetFft().GetBinFormat()
	deadline := time.NewTimer(chartFirstRow)
	defer deadline.Stop()
	for {
		select {
		case <-ctx.Done():
			return 0, ctx.Err()
		case <-deadline.C:
			return 0, fmt.Errorf("no spectrum row arrived in %.0f s, so there is no noise floor to measure against. Check the radio is still capturing with: ley state", chartFirstRow.Seconds())
		case fr, ok := <-sub.Frames:
			if !ok {
				return 0, spectrumEnd(ctx, "spectrum", sub.Err(), 0)
			}
			if len(fr.Payload) == 0 {
				continue
			}
			return medianDb(leyline.DecodeFFTBins(fr.Payload, binFormat)), nil
		}
	}
}

// PersistenceRow is one JSON row of `ley phosphor --json`. The histogram has no
// proto message of its own, so this shape is part of the CLI contract: Counts
// is the daemon's grid exactly as it arrived -- Bins x Levels little-endian
// uint16 counts, bin-major -- carried base64 the way `ley listen` carries pcm,
// because a JSON array of tens of thousands of small integers costs more to
// write and to read than the bytes themselves. FloorDb and RangeDb are what the
// levels are measured against: level l covers floor_db + l*range_db/levels
// upwards.
type PersistenceRow struct {
	Seq         uint64  `json:"seq"`
	SampleIndex uint64  `json:"sample_index"`
	CenterHz    uint64  `json:"center_hz"`
	SpanHz      uint64  `json:"span_hz"`
	Bins        uint32  `json:"bins"`
	Levels      uint32  `json:"levels"`
	FloorDb     float64 `json:"floor_db"`
	RangeDb     float64 `json:"range_db"`
	Counts      []byte  `json:"counts"`
}

// phosphorRows is `ley phosphor --json`: one NDJSON row per persistence frame,
// and no chart.
func phosphorRows(ctx context.Context, app *App, desc *leylinev1.StreamDescriptor,
	sub *leyline.Subscription, o phosphorOptions,
) error {
	p := desc.GetPersistence()
	bins, levels := int(p.GetBins()), int(p.GetLevels())
	out := bufio.NewWriter(app.Stdout)
	defer out.Flush()
	n := 0
	for {
		select {
		case <-ctx.Done():
			return nil
		case fr, ok := <-sub.Frames:
			if !ok {
				return spectrumEnd(ctx, "persistence", sub.Err(), n)
			}
			// A frame too short for the grid the descriptor specifies is
			// dropped rather than half-read, as the chart drops it.
			if bins <= 0 || levels <= 0 || len(fr.Payload) < bins*levels*2 {
				continue
			}
			row := PersistenceRow{
				Seq: fr.Seq, SampleIndex: fr.Time.GetSampleIndex(),
				CenterHz: desc.CenterHz, SpanHz: desc.SpanHz,
				Bins: p.GetBins(), Levels: p.GetLevels(),
				FloorDb: p.GetFloorDb(), RangeDb: p.GetRangeDb(),
				Counts: fr.Payload[:bins*levels*2],
			}
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
