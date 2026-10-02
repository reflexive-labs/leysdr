// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// liveLoop is the select loop every frame-drawing view runs (spectrum, phosphor, levels,
// waveform, scope). It refreshes the chart writer's status line on a ticker while no frame
// arrives, hands telemetry and frames to the view, and ends on Ctrl-C (nil), when a callback
// reports done or fails, or when the frame stream closes. The views keep their own state; the
// loop owns only the channels, so a stream that ends is read no more.
type liveLoop struct {
	// frames is the bulk stream the view draws, and end turns its closing into the run's result.
	frames  <-chan *leylinev1.Frame
	end     func() error
	onFrame func(fr *leylinev1.Frame) (done bool, err error)
	// w, when set, has its idle status refreshed on every tick; onTick runs after it.
	w      *chartWriter
	onTick func() (done bool, err error)
	// telemetry and level are optional telemetry streams. Their callback receives each message,
	// and nil once when the stream ends.
	telemetry   <-chan *leylinev1.TelemetryMsg
	onTelemetry func(m *leylinev1.TelemetryMsg) (done bool, err error)
	level       <-chan *leylinev1.TelemetryMsg
	onLevel     func(m *leylinev1.TelemetryMsg) (done bool, err error)
}

// run drives the loop until it ends; see liveLoop.
func (l liveLoop) run(ctx context.Context) error {
	tick := time.NewTicker(chartTickInterval)
	defer tick.Stop()
	telemetry, level := l.telemetry, l.level
	for {
		var done bool
		var err error
		select {
		case <-ctx.Done():
			return nil
		case <-tick.C:
			if l.w != nil {
				l.w.idle()
			}
			if l.onTick != nil {
				done, err = l.onTick()
			}
		case m, ok := <-telemetry:
			if !ok {
				telemetry, m = nil, nil
			}
			done, err = l.onTelemetry(m)
		case m, ok := <-level:
			if !ok {
				level, m = nil, nil
			}
			done, err = l.onLevel(m)
		case fr, ok := <-l.frames:
			if !ok {
				return l.end()
			}
			done, err = l.onFrame(fr)
		}
		if done || err != nil {
			return err
		}
	}
}
