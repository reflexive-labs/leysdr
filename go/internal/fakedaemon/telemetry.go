package fakedaemon

import (
	"math"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// Subscribe implements Telemetry. Meter at 10 Hz for every active channel in
// scope, a SquelchTransition when the synthetic signal crosses the threshold,
// and CaptureActivity at 1 Hz per capture.
func (t telemetrySvc) Subscribe(sub *leylinev1.TelemetrySubscription, srv grpc.ServerStreamingServer[leylinev1.TelemetryMsg]) error {
	d := t.d
	ctx, stop := d.streamContext(srv.Context())
	defer stop()
	done := d.streamOpened(ctx)
	defer done()

	want := map[leylinev1.TelemetryType]bool{}
	for _, ty := range sub.GetTypes() {
		want[ty] = true
	}
	wants := func(ty leylinev1.TelemetryType) bool { return len(want) == 0 || want[ty] }

	var capFilter, chanFilter string
	switch s := sub.GetScope().(type) {
	case *leylinev1.TelemetrySubscription_CaptureId:
		capFilter = s.CaptureId
	case *leylinev1.TelemetrySubscription_ChannelId:
		chanFilter = s.ChannelId
	}
	d.mu.Lock()
	if capFilter != "" && d.captures[capFilter] == nil {
		d.mu.Unlock()
		return fail(ctx, errorf(leyline.CodeCaptureNotFound, capFilter, "no such capture"))
	}
	if chanFilter != "" && d.channels[chanFilter] == nil {
		d.mu.Unlock()
		return fail(ctx, errorf(leyline.CodeChannelNotFound, chanFilter, "no such channel"))
	}
	d.mu.Unlock()

	var seq uint64
	send := func(m *leylinev1.TelemetryMsg) error {
		seq++
		m.Seq = seq
		return srv.Send(m)
	}
	// Detections are pushed by a running scan rather than produced on the tick, so each
	// subscriber walks the shared log from its own cursor.
	detectionCursor := 0
	squelchOpen := map[string]bool{}
	// What the real daemon accumulates on the DSP thread while the squelch is
	// open, so the close edge can summarise the transmission that just ended.
	openedAt := map[string]uint64{}
	peakPower := map[string]float64{}
	peakSNR := map[string]float64{}
	ticker := time.NewTicker(d.opts.MeterInterval)
	defer ticker.Stop()
	activityEvery := time.Second / d.opts.MeterInterval
	var tick int64
	for {
		select {
		case <-ctx.Done():
			return nil
		case now := <-ticker.C:
			tick++
			var out []*leylinev1.TelemetryMsg
			d.mu.Lock()
			if wants(leylinev1.TelemetryType_DETECTION) && chanFilter == "" {
				for ; detectionCursor < len(d.detectionLog); detectionCursor++ {
					det := proto.Clone(d.detectionLog[detectionCursor]).(*leylinev1.Detection)
					out = append(out, &leylinev1.TelemetryMsg{
						Time: &leylinev1.SampleTime{CaptureId: det.CaptureId},
						Body: &leylinev1.TelemetryMsg_Detection{Detection: det},
					})
				}
			} else if chanFilter == "" {
				detectionCursor = len(d.detectionLog)
			}
			for _, ch := range d.channels {
				if ch.State != leylinev1.ChannelState_CHANNEL_ACTIVE {
					continue
				}
				if (chanFilter != "" && ch.ChannelId != chanFilter) || (capFilter != "" && ch.CaptureId != capFilter) {
					continue
				}
				c := d.captures[ch.CaptureId]
				if c == nil {
					continue
				}
				st := &leylinev1.SampleTime{CaptureId: c.CaptureId, SampleIndex: c.sampleIndex(now)}
				power := syntheticPower(now)
				open := math.IsNaN(ch.SquelchDb) || power >= ch.SquelchDb
				if open {
					if p, seen := peakPower[ch.ChannelId]; !seen || power > p {
						peakPower[ch.ChannelId] = power
						peakSNR[ch.ChannelId] = power + 90
					}
				}
				if prev, seen := squelchOpen[ch.ChannelId]; !seen || prev != open {
					if wants(leylinev1.TelemetryType_SQUELCH_TRANSITION) {
						sq := &leylinev1.SquelchTransition{ChannelId: ch.ChannelId, Open: open}
						if open {
							// A transmission in progress has no duration and no
							// final peak; NaN says "not measured", which is not
							// the same as a peak of zero.
							sq.PeakSnrDb, sq.PeakAudioDbfs = math.NaN(), math.NaN()
						} else {
							sq.DurationSamples = st.SampleIndex - openedAt[ch.ChannelId]
							sq.PeakSnrDb = peakSNR[ch.ChannelId]
							sq.PeakAudioDbfs = peakPower[ch.ChannelId]
						}
						out = append(out, &leylinev1.TelemetryMsg{Time: st, Body: &leylinev1.TelemetryMsg_Squelch{Squelch: sq}})
					}
					if open {
						openedAt[ch.ChannelId] = st.SampleIndex
						peakPower[ch.ChannelId] = power
						peakSNR[ch.ChannelId] = power + 90
					} else {
						delete(peakPower, ch.ChannelId)
						delete(peakSNR, ch.ChannelId)
					}
				}
				squelchOpen[ch.ChannelId] = open
				if wants(leylinev1.TelemetryType_METER) {
					// A closed squelch writes zeros to the sinks, so there is no
					// audio to hear: the engine floors that at -200 dBFS rather
					// than sending -inf, which does not survive JSON.
					audio, peak := -200.0, -200.0
					if open {
						// Demodulated level sits below the channel power; the
						// exact offset does not matter, only that the two are
						// different measurements of different things.
						audio, peak = power+6, power+10
					}
					out = append(out, &leylinev1.TelemetryMsg{Time: st, Body: &leylinev1.TelemetryMsg_Meter{
						Meter: &leylinev1.Meter{
							ChannelId: ch.ChannelId, PowerDbfs: power, SnrDb: power + 90, SquelchOpen: open,
							AudioDbfs: audio, AudioPeakDbfs: peak,
						},
					}})
				}
			}
			if tick%int64(activityEvery) == 0 && wants(leylinev1.TelemetryType_CAPTURE_ACTIVITY) && chanFilter == "" {
				for _, c := range d.captures {
					if capFilter != "" && c.CaptureId != capFilter {
						continue
					}
					out = append(out, &leylinev1.TelemetryMsg{
						Time: &leylinev1.SampleTime{CaptureId: c.CaptureId, SampleIndex: c.sampleIndex(now)},
						Body: &leylinev1.TelemetryMsg_Activity{Activity: &leylinev1.CaptureActivityMsg{
							CaptureId: c.CaptureId,
							Snapshot: &leylinev1.CaptureActivitySnapshot{
								LastInteractiveWriteNs: c.Activity.LastInteractiveWriteNs,
								LiveAudioSinks:         c.Activity.LiveAudioSinks,
							},
						}},
					})
				}
			}
			d.mu.Unlock()
			for _, m := range out {
				if err := send(m); err != nil {
					return nil
				}
			}
		}
	}
}

// syntheticPower is a slow -30..-70 dBFS swell (period 4 s) so squelch
// transitions actually happen at reasonable thresholds.
func syntheticPower(now time.Time) float64 {
	phase := float64(now.UnixNano()%4_000_000_000) / 4e9
	return -50 + 20*math.Sin(2*math.Pi*phase)
}
