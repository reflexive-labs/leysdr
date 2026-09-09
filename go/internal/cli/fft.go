package cli

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"math"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// FFTMagic is the 4-byte magic that starts every binary FFT record.
const FFTMagic = "LEYF"

// FFTRow is one JSON row of `ley fft --format json`.
type FFTRow struct {
	Seq         uint64    `json:"seq"`
	SampleIndex uint64    `json:"sample_index"`
	CenterHz    uint64    `json:"center_hz"`
	SpanHz      uint64    `json:"span_hz"`
	Bins        []float64 `json:"bins"`
}

func newFFTCommand(app *App) *cobra.Command {
	var (
		bins           uint32
		rate           float64
		format, device string
		count          int
		u8             bool
		freq           string
	)
	cmd := &cobra.Command{
		Use:   "fft",
		Short: "Stream spectrum rows as numbers, for tools",
		Long: `fft is the number feed behind 'ley spectrum'. The daemon slices the band a
device is tuned to into bins (a bin is one narrow slice of frequency, a few
kHz wide) and measures how loud each one is; one such measurement across
the whole band is a row. fft prints those rows as they arrive, --rate times
a second, until --count rows or Ctrl-C. To look at the band yourself, use
'ley spectrum': it draws the same rows as a chart.

If the device has no capture, --freq is required and a capture is created
for the run (destroyed on exit).

--format json: one row per line
               {seq, sample_index, center_hz, span_hz, bins:[dB...]}
               Bulk rows have no proto message, so this shape (and the
               matching 'spectrum --json') is the documented exception to
               ley's proto3 JSON rule; see docs/interfaces.md. Rows are
               delivered gap-marked: when the daemon had to drop rows, a
               line {"gap":{"from_sample":A,"to_sample":B}} precedes the
               next row and names the samples it skipped.
--format bin:  binary, so it is refused when stdout is a terminal:
               redirect it ('> rows.bin') or pipe it.
               One record per row: a 16-byte little-endian header
               magic "LEYF" | u32 bins | u64 seq
               followed by the payload as delivered by the daemon
               (bins x f32 dB little-endian, or bins x u8 with --u8, where
               u8 = clamp(round((dB + 120) * 2), 0, 255)).`,
		Example: `  ley fft --freq 101.1M --count 1          # one row of the FM broadcast band
  ley fft --rate 10 | jq .bins[0]           # ten rows a second into a tool
  ley fft --format bin --u8 > rows.bin      # compact binary records
  ley spectrum 101.1                        # the same rows, drawn`,
		GroupID: GroupData,
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if format != "json" && format != "bin" {
				return usageErrorf("--format must be json or bin")
			}
			// Binary records to a terminal are a screenful of garbage and can
			// wedge it, so refuse rather than write. Piped, nothing changes.
			if format == "bin" && app.IsTTY() {
				return usageErrorf("--format bin writes binary records, not text; redirect it: ley fft --format bin > rows.bin")
			}
			var hz uint64
			if freq != "" {
				v, err := leyline.ParseUserFrequency(freq)
				if err != nil {
					return usageErrorf("--freq: %v", err)
				}
				hz = v
			}
			s, err := openSession(cmd.Context(), app)
			if err != nil {
				return err
			}
			defer s.close()
			if s.device, err = pickDevice(s.state, device); err != nil {
				return err
			}
			return runFFT(cmd.Context(), s, fftOptions{bins: bins, rate: rate, bin: format == "bin", count: count, u8: u8, freq: hz})
		},
	}
	cmd.Flags().Uint32Var(&bins, "bins", 1024, "number of bins (slices) across the band, e.g. 1024; the daemon may round it to a size it supports")
	cmd.Flags().Float64Var(&rate, "rate", 10, "rows per second, e.g. 10")
	cmd.Flags().StringVar(&format, "format", "json", "output format: json (one row per line) or bin (binary records, see below)")
	cmd.Flags().StringVar(&device, "device", "", "which radio: an id (dev_...), id prefix or row number from 'ley devices' (default: the first real radio)")
	cmd.Flags().IntVar(&count, "count", 0, "stop after this many rows, e.g. 1 (default: until Ctrl-C)")
	cmd.Flags().BoolVar(&u8, "u8", false, "ask for 1-byte bins (DB_U8) instead of 4-byte floats (DB_F32); smaller, coarser")
	cmd.Flags().StringVar(&freq, "freq", "", "centre frequency when the radio is not tuned yet; a bare number is MHz, e.g. 101.1")
	return cmd
}

type fftOptions struct {
	bins  uint32
	rate  float64
	bin   bool
	count int
	u8    bool
	freq  uint64
}

// runFFT ensures a capture, subscribes and writes rows until count/cancel.
func runFFT(ctx context.Context, s *session, o fftOptions) error {
	if cap := leyline.FindCapture(s.state, s.device.DeviceId); cap != nil {
		s.capture = cap
	} else {
		if o.freq == 0 {
			return usageErrorf("the radio is idle; give a frequency: ley fft --freq 101.1 --count 1")
		}
		cap, err := s.client.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: s.device.DeviceId, CenterHz: o.freq})
		if err != nil {
			return err
		}
		s.capture, s.createdCapture = cap, true
		defer s.teardown()
	}
	format := leylinev1.FftBinFormat_DB_F32
	if o.u8 {
		format = leylinev1.FftBinFormat_DB_U8
	}
	sctx, cancel := context.WithCancel(ctx)
	defer cancel()
	sub, err := s.client.SubscribeFFT(sctx, s.capture.CaptureId, o.bins, o.rate, format)
	if err != nil {
		return err
	}
	defer sub.Close()
	// Keep the event stream flowing (and the mirror current) while rows are
	// written; stopped before teardown reads the mirror.
	stopDrain := s.drainEvents()
	defer stopDrain()
	desc := sub.Descriptor
	nbins := desc.GetFft().GetBins()
	u8 := desc.GetFft().GetBinFormat() == leylinev1.FftBinFormat_DB_U8
	out := bufio.NewWriter(s.app.Stdout)
	defer out.Flush()
	n := 0
	for fr := range sub.Frames {
		if fr.Gap != nil && !o.bin {
			if err := writeGap(out, fr.Gap); err != nil {
				return err
			}
		}
		if len(fr.Payload) == 0 {
			continue
		}
		if o.bin {
			if err := writeFFTRecord(out, nbins, fr); err != nil {
				return err
			}
		} else {
			row := FFTRow{Seq: fr.Seq, SampleIndex: fr.Time.GetSampleIndex(), CenterHz: desc.CenterHz, SpanHz: desc.SpanHz, Bins: decodeBins(fr.Payload, u8)}
			b, err := json.Marshal(row)
			if err != nil {
				return err
			}
			out.Write(b)
			out.WriteByte('\n')
		}
		n++
		if o.count > 0 && n >= o.count {
			return nil
		}
		if err := out.Flush(); err != nil {
			return err
		}
	}
	if err := sub.Err(); err != nil && ctx.Err() == nil {
		return err
	}
	return nil
}

// writeGap emits a JSON gap marker row.
func writeGap(w *bufio.Writer, g *leylinev1.Gap) error {
	_, err := fmt.Fprintf(w, "{\"gap\":{\"from_sample\":%d,\"to_sample\":%d}}\n", g.FromSample, g.ToSample)
	return err
}

// writeFFTRecord writes header (LEYF | u32 bins | u64 seq, little-endian) + payload.
func writeFFTRecord(w *bufio.Writer, bins uint32, fr *leylinev1.Frame) error {
	var hdr [16]byte
	copy(hdr[:4], FFTMagic)
	binary.LittleEndian.PutUint32(hdr[4:8], bins)
	binary.LittleEndian.PutUint64(hdr[8:16], fr.Seq)
	if _, err := w.Write(hdr[:]); err != nil {
		return err
	}
	_, err := w.Write(fr.Payload)
	return err
}

// ParseFFTRecord decodes one binary record header; it returns bins, seq and
// the payload length implied by the header for the given bin format.
func ParseFFTRecord(hdr []byte) (bins uint32, seq uint64, err error) {
	if len(hdr) < 16 || string(hdr[:4]) != FFTMagic {
		return 0, 0, fmt.Errorf("bad FFT record header")
	}
	return binary.LittleEndian.Uint32(hdr[4:8]), binary.LittleEndian.Uint64(hdr[8:16]), nil
}

// decodeBins converts a payload to dB values (f32 LE or u8-encoded).
func decodeBins(p []byte, u8 bool) []float64 {
	if u8 {
		out := make([]float64, len(p))
		for i, b := range p {
			out[i] = float64(b)/2 - 120
		}
		return out
	}
	out := make([]float64, len(p)/4)
	for i := range out {
		out[i] = float64(math.Float32frombits(binary.LittleEndian.Uint32(p[i*4:])))
	}
	return out
}
