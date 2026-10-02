// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"fmt"
	"math"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// The level probe a tune runs once: the capture's first CaptureLevel and one spectrum row, which
// set auto squelch and the banner's band and clipping notes.

// squelchProbeTimeout bounds the wait for the spectrum row auto squelch needs.
const squelchProbeTimeout = 2 * time.Second

// levelProbeTimeout bounds the wait for the capture's first CaptureLevel once
// the row is in hand: the daemon sends one a quarter of a second, so two
// intervals is one missed and one caught, and an older daemon that sends none
// costs a session this much once.
const levelProbeTimeout = 600 * time.Millisecond

// watchLevel subscribes to the capture's CaptureLevel and nothing else. The
// stream's error is not read: a daemon that sends no levels leaves the channel
// silent, and every reader of it is bounded by something else. A subscription
// that could not be opened is a nil channel, which blocks the same way.
func (s *verbSession) watchLevel(ctx context.Context, captureID string) <-chan *leylinev1.TelemetryMsg {
	msgs, _, err := s.Client.WatchTelemetry(ctx, &leylinev1.TelemetrySubscription{
		Scope: &leylinev1.TelemetrySubscription_CaptureId{CaptureId: captureID},
		Types: []leylinev1.TelemetryType{leylinev1.TelemetryType_CAPTURE_LEVEL},
	})
	if err != nil {
		return nil
	}
	return msgs
}

// awaitLevel is the first CaptureLevel off a watchLevel channel, or nil when
// none arrives within wait.
func awaitLevel(ctx context.Context, msgs <-chan *leylinev1.TelemetryMsg, wait time.Duration) *leylinev1.CaptureLevel {
	deadline := time.NewTimer(wait)
	defer deadline.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-deadline.C:
			return nil
		case m, ok := <-msgs:
			if !ok {
				return nil
			}
			if b, ok := m.Body.(*leylinev1.TelemetryMsg_CaptureLevel); ok {
				return b.CaptureLevel
			}
		}
	}
}

// measureSquelch derives a squelch threshold from one FFT row of the capture:
// the row's median bin is the noise floor per bin (a median is presentation,
// the spectrum itself is the daemon's), scaled to the channel bandwidth with
// 10·log10(bw / bin width); the threshold sits 10 dB above that. It returns
// an error when no row arrives within squelchProbeTimeout so callers can
// leave squelch off and say so.
func (s *verbSession) measureSquelch(ctx context.Context, capture *leylinev1.Capture, bw uint32) (threshold, floor float64, err error) {
	sctx, cancel := context.WithTimeout(ctx, squelchProbeTimeout+levelProbeTimeout)
	defer cancel()
	// The capture's level is asked for first, so its first reading, a quarter
	// of a second away at most, is usually in hand by the time the row is: it
	// shows whether the radio is clipping, which the row cannot.
	levels := s.watchLevel(sctx, capture.CaptureId)
	sub, err := s.Client.SubscribeFFT(sctx, capture.CaptureId, 2048, 10, leylinev1.FftBinFormat_DB_F32)
	if err != nil {
		return 0, 0, fmt.Errorf("no spectrum available (%w)", err)
	}
	defer sub.Close()
	var fr *leylinev1.Frame
	select {
	case f, ok := <-sub.Frames:
		if !ok {
			return 0, 0, fmt.Errorf("spectrum stream ended before a row arrived")
		}
		fr = f
	case <-time.After(squelchProbeTimeout):
		return 0, 0, fmt.Errorf("no spectrum row arrived within %s", squelchProbeTimeout)
	case <-ctx.Done():
		return 0, 0, ctx.Err()
	}
	vals := leyline.DecodeFFTBins(fr.Payload, sub.Descriptor.GetFft().GetBinFormat())
	if len(vals) == 0 {
		return 0, 0, fmt.Errorf("spectrum row in an unexpected format")
	}
	// The same row answers whether the band is heard at all; a second
	// subscription would be another wait for the same numbers. The level
	// answers whether the radio is clipping, and a daemon that sends none
	// leaves the row's own full-scale rule to say so.
	level := awaitLevel(sctx, levels, levelProbeTimeout)
	s.failureNote = failureWords(vals, level, capture.GetGains(), s.device.GetGainElements())
	s.bandNote = bandWords(vals, level != nil, capture.GetGains(), s.device.GetGainElements())
	median := medianDb(vals)
	binWidth := float64(capture.SampleRate) / float64(len(vals))
	floor = median + 10*math.Log10(float64(bw)/binWidth)
	return math.Round(floor + 10), floor, nil
}
