package fakedaemon

import (
	"math"
	"time"

	"google.golang.org/grpc"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// Subscribe implements Telemetry. Meter at 10 Hz for every active channel in
// scope, a SquelchTransition when the synthetic signal crosses the threshold,
// and CaptureActivity at 1 Hz per capture.
func (t telemetrySvc) Subscribe(sub *leylinev1.TelemetrySubscription, srv grpc.ServerStreamingServer[leylinev1.TelemetryMsg]) error {
	d := t.d
	ctx := srv.Context()
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
	squelchOpen := map[string]bool{}
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
				if prev, seen := squelchOpen[ch.ChannelId]; (!seen || prev != open) && wants(leylinev1.TelemetryType_SQUELCH_TRANSITION) {
					out = append(out, &leylinev1.TelemetryMsg{Time: st, Body: &leylinev1.TelemetryMsg_Squelch{
						Squelch: &leylinev1.SquelchTransition{ChannelId: ch.ChannelId, Open: open},
					}})
				}
				squelchOpen[ch.ChannelId] = open
				if wants(leylinev1.TelemetryType_METER) {
					out = append(out, &leylinev1.TelemetryMsg{Time: st, Body: &leylinev1.TelemetryMsg_Meter{
						Meter: &leylinev1.Meter{ChannelId: ch.ChannelId, PowerDbfs: power, SnrDb: power + 90, SquelchOpen: open},
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
