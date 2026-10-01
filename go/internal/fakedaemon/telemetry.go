// SPDX-License-Identifier: Apache-2.0

package fakedaemon

import (
	"math"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// Subscribe implements Telemetry. Meter at 10 Hz for every active channel in
// scope, a SquelchTransition when the synthetic signal crosses the threshold,
// CaptureActivity at 1 Hz and CaptureLevel at 4 Hz per capture.
func (t telemetrySvc) Subscribe(sub *leylinev1.TelemetrySubscription, srv grpc.ServerStreamingServer[leylinev1.TelemetryMsg]) error {
	d := t.d
	ctx, stop := d.streamContext(srv.Context())
	defer stop()
	done := d.streamOpened(ctx)
	defer done()

	f := newTelemetryFeed(d, sub)
	d.mu.Lock()
	if f.capFilter != "" && d.captures[f.capFilter] == nil {
		d.mu.Unlock()
		return fail(ctx, errorf(leyline.CodeCaptureNotFound, f.capFilter, "no such capture"))
	}
	if f.chanFilter != "" && d.channels[f.chanFilter] == nil {
		d.mu.Unlock()
		return fail(ctx, errorf(leyline.CodeChannelNotFound, f.chanFilter, "no such channel"))
	}
	// Detections are pushed by a running scan rather than produced on the tick, so each
	// subscriber walks the shared log from its own cursor -- starting at the end, because
	// telemetry is live. The daemon's hub has no history at all; replaying a finished scan's
	// detections to a subscriber that arrived afterwards would report old readings as current.
	f.detectionCursor = len(d.detectionLog)
	d.mu.Unlock()

	var seq uint64
	ticker := time.NewTicker(d.opts.MeterInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case now := <-ticker.C:
			d.mu.Lock()
			out := f.next(now)
			d.mu.Unlock()
			for _, m := range out {
				seq++
				m.Seq = seq
				if err := srv.Send(m); err != nil {
					return nil
				}
			}
		}
	}
}

// telemetryFeed is one subscriber's telemetry: its scope and types, and the per-channel state
// the daemon keeps per subscriber (squelch edges, the open transmission's peaks, the sub-audible
// heartbeat). Each tick produces one batch of messages, one method per kind.
type telemetryFeed struct {
	d                     *Daemon
	want                  map[leylinev1.TelemetryType]bool
	capFilter, chanFilter string
	detectionCursor       int
	squelchOpen           map[string]bool
	// The last sub-audible report per channel, and the tick it went out on: the detector is
	// edge-triggered with a heartbeat, and both halves are per channel.
	subAudible     map[string]*leylinev1.SubAudible
	subAudibleTick map[string]int64
	// What the real daemon accumulates on the DSP thread while the squelch is
	// open, so the close edge can summarise the transmission that just ended.
	openedAt  map[string]uint64
	peakPower map[string]float64
	peakSNR   map[string]float64
	// At least one tick, so a Meter cadence slower than a second still has a tick to land on.
	activityEvery, levelEvery int64
	tick                      int64
}

func newTelemetryFeed(d *Daemon, sub *leylinev1.TelemetrySubscription) *telemetryFeed {
	f := &telemetryFeed{
		d:              d,
		want:           map[leylinev1.TelemetryType]bool{},
		squelchOpen:    map[string]bool{},
		subAudible:     map[string]*leylinev1.SubAudible{},
		subAudibleTick: map[string]int64{},
		openedAt:       map[string]uint64{},
		peakPower:      map[string]float64{},
		peakSNR:        map[string]float64{},
		activityEvery:  max(int64(1), int64(time.Second/d.opts.MeterInterval)),
		levelEvery:     max(int64(1), int64(levelInterval/d.opts.MeterInterval)),
	}
	for _, ty := range sub.GetTypes() {
		f.want[ty] = true
	}
	switch s := sub.GetScope().(type) {
	case *leylinev1.TelemetrySubscription_CaptureId:
		f.capFilter = s.CaptureId
	case *leylinev1.TelemetrySubscription_ChannelId:
		f.chanFilter = s.ChannelId
	}
	return f
}

// wants reports whether the subscriber asked for ty; no types means every type.
func (f *telemetryFeed) wants(ty leylinev1.TelemetryType) bool {
	return len(f.want) == 0 || f.want[ty]
}

// next is one tick's messages, in the order the daemon sends them: detections, each channel's
// squelch edge, meter and sub-audible report, then capture activity and capture level on their
// slower cadences. d.mu is held.
func (f *telemetryFeed) next(now time.Time) []*leylinev1.TelemetryMsg {
	f.tick++
	var out []*leylinev1.TelemetryMsg
	out = f.detections(out)
	for _, ch := range f.d.channels {
		if ch.State != leylinev1.ChannelState_CHANNEL_ACTIVE {
			continue
		}
		if (f.chanFilter != "" && ch.ChannelId != f.chanFilter) || (f.capFilter != "" && ch.CaptureId != f.capFilter) {
			continue
		}
		c := f.d.captures[ch.CaptureId]
		if c == nil {
			continue
		}
		out = f.channel(out, ch, c, now)
	}
	if f.tick%f.activityEvery == 0 {
		out = f.activity(out, now)
	}
	if f.tick%f.levelEvery == 0 {
		out = f.levels(out, now)
	}
	return out
}

// detections appends the scan detections logged since the last tick.
func (f *telemetryFeed) detections(out []*leylinev1.TelemetryMsg) []*leylinev1.TelemetryMsg {
	if f.wants(leylinev1.TelemetryType_DETECTION) && f.chanFilter == "" {
		for ; f.detectionCursor < len(f.d.detectionLog); f.detectionCursor++ {
			det := proto.Clone(f.d.detectionLog[f.detectionCursor]).(*leylinev1.Detection)
			// A sweep runs on one capture, and a subscriber scoped to another one is not
			// looking at that radio: the daemon's job hub filters detections the same way.
			if f.capFilter != "" && det.CaptureId != f.capFilter {
				continue
			}
			out = append(out, &leylinev1.TelemetryMsg{
				Time: &leylinev1.SampleTime{CaptureId: det.CaptureId},
				Body: &leylinev1.TelemetryMsg_Detection{Detection: det},
			})
		}
	} else if f.chanFilter == "" {
		f.detectionCursor = len(f.d.detectionLog)
	}
	return out
}

// channel appends one active channel's squelch edge, meter and sub-audible report.
func (f *telemetryFeed) channel(out []*leylinev1.TelemetryMsg, ch *leylinev1.Channel, c *capture, now time.Time) []*leylinev1.TelemetryMsg {
	st := &leylinev1.SampleTime{CaptureId: c.CaptureId, SampleIndex: c.sampleIndex(now)}
	power := syntheticPower(now)
	open := math.IsNaN(ch.SquelchDb) || power >= ch.SquelchDb
	if open {
		if p, seen := f.peakPower[ch.ChannelId]; !seen || power > p {
			f.peakPower[ch.ChannelId] = power
			f.peakSNR[ch.ChannelId] = power + 90
		}
	}
	// Only a change of state is an edge. A subscriber that arrives mid-transmission
	// has no open to report the close against, and the daemon forwards only the
	// edges the engine actually crossed.
	prev, seen := f.squelchOpen[ch.ChannelId]
	edge := seen && prev != open
	if edge || !seen {
		if edge && f.wants(leylinev1.TelemetryType_SQUELCH_TRANSITION) {
			sq := &leylinev1.SquelchTransition{ChannelId: ch.ChannelId, Open: open}
			if open {
				// A transmission in progress has no duration and no
				// final peak; NaN says "not measured", which is not
				// the same as a peak of zero.
				sq.PeakSnrDb, sq.PeakAudioDbfs = math.NaN(), math.NaN()
			} else {
				sq.DurationSamples = st.SampleIndex - f.openedAt[ch.ChannelId]
				sq.PeakSnrDb = f.peakSNR[ch.ChannelId]
				sq.PeakAudioDbfs = f.peakPower[ch.ChannelId]
			}
			out = append(out, &leylinev1.TelemetryMsg{Time: st, Body: &leylinev1.TelemetryMsg_Squelch{Squelch: sq}})
		}
		if open {
			f.openedAt[ch.ChannelId] = st.SampleIndex
			f.peakPower[ch.ChannelId] = power
			f.peakSNR[ch.ChannelId] = power + 90
		} else {
			delete(f.peakPower, ch.ChannelId)
			delete(f.peakSNR, ch.ChannelId)
		}
	}
	f.squelchOpen[ch.ChannelId] = open
	if f.wants(leylinev1.TelemetryType_METER) {
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
		// The discriminator the demod tap draws: a 1 kHz sine at
		// half of full scale riding on demodTapDC, so the meter's
		// deviation and tuning error are the tap's own numbers in
		// hertz. NaN outside the FM modes, and the error NaN while
		// the squelch is shut, as the engine sends them.
		deviation, freqError := math.NaN(), math.NaN()
		if fs := float64(leyline.FullScaleDeviationHz(ch.Mode, ch.BandwidthHz)); fs != 0 {
			deviation = 0.5 * fs
			if open {
				freqError = demodTapDC * fs
			}
		}
		out = append(out, &leylinev1.TelemetryMsg{Time: st, Body: &leylinev1.TelemetryMsg_Meter{
			Meter: &leylinev1.Meter{
				ChannelId: ch.ChannelId, PowerDbfs: power, SnrDb: power + 90, SquelchOpen: open,
				AudioDbfs: audio, AudioPeakDbfs: peak,
				DeviationHz: deviation, FreqErrorHz: freqError,
			},
		}})
	}
	// A tone rides on a transmission, so the detector has something to measure only
	// while the squelch is open. It reports a change at once and repeats itself on a
	// heartbeat, because the telemetry plane has no GetState and a client that
	// subscribed mid-transmission has to be told what is already there.
	if f.wants(leylinev1.TelemetryType_SUB_AUDIBLE) && ch.SubaudibleDetect {
		hz := uint64(int64(c.CenterHz) + ch.OffsetHz)
		tone, code := f.d.subTone(hz)
		sa := subAudibleReport(ch.ChannelId, tone, code, open)
		prev := f.subAudible[ch.ChannelId]
		changed := prev == nil || prev.Kind != sa.Kind || prev.StandardToneHz != sa.StandardToneHz ||
			prev.DcsCode != sa.DcsCode || prev.DcsInverted != sa.DcsInverted
		if changed || f.tick-f.subAudibleTick[ch.ChannelId] >= f.activityEvery {
			f.subAudible[ch.ChannelId], f.subAudibleTick[ch.ChannelId] = sa, f.tick
			out = append(out, &leylinev1.TelemetryMsg{Time: st, Body: &leylinev1.TelemetryMsg_SubAudible{SubAudible: sa}})
		}
	}
	return out
}

// activity appends each capture's activity snapshot.
func (f *telemetryFeed) activity(out []*leylinev1.TelemetryMsg, now time.Time) []*leylinev1.TelemetryMsg {
	if f.wants(leylinev1.TelemetryType_CAPTURE_ACTIVITY) && f.chanFilter == "" {
		for _, c := range f.d.captures {
			if f.capFilter != "" && c.CaptureId != f.capFilter {
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
	return out
}

// levels appends each capture's CaptureLevel.
func (f *telemetryFeed) levels(out []*leylinev1.TelemetryMsg, now time.Time) []*leylinev1.TelemetryMsg {
	if f.wants(leylinev1.TelemetryType_CAPTURE_LEVEL) && f.chanFilter == "" {
		for _, c := range f.d.captures {
			if f.capFilter != "" && c.CaptureId != f.capFilter {
				continue
			}
			// A quarter second of samples with none at a rail, unless the
			// test says the radio is clipping. The reading ends at the
			// capture's current sample, as the daemon's does.
			clipped, total, peak := uint64(0), c.SampleRate/uint64(time.Second/levelInterval), -12.0
			if f.d.opts.Clipping != nil {
				clipped, total, peak = f.d.opts.Clipping(c.CaptureId)
			}
			out = append(out, &leylinev1.TelemetryMsg{
				Time: &leylinev1.SampleTime{CaptureId: c.CaptureId, SampleIndex: c.sampleIndex(now)},
				Body: &leylinev1.TelemetryMsg_CaptureLevel{CaptureLevel: &leylinev1.CaptureLevel{
					CaptureId: c.CaptureId, ClippedSamples: clipped, TotalSamples: total, PeakDbfs: peak,
				}},
			})
		}
	}
	return out
}

// levelInterval is the CaptureLevel cadence: four readings a second, the
// daemon's own.
const levelInterval = 250 * time.Millisecond

// syntheticPower is a slow -30..-70 dBFS swell (period 4 s) so squelch
// transitions actually happen at reasonable thresholds.
func syntheticPower(now time.Time) float64 {
	phase := float64(now.UnixNano()%4_000_000_000) / 4e9
	return -50 + 20*math.Sin(2*math.Pi*phase)
}

// subAudibleReport is what the detector concluded about one window. A tone it does not
// report leaves every measured field NaN: "not measured" is not the same as zero, and only
// deviation separates a real 100.0 Hz PL from 50 Hz mains hum, so the fake sends a deviation a
// transmitter would. A DCS code, when the carrier sends one, is reported in place of any tone:
// no tone was measured, so tone_hz and tone_snr_db stay NaN, and the deviation is the bit
// amplitude a recorded GMRS handheld sends.
func subAudibleReport(channelID string, toneHz float64, code *DCSCode, open bool) *leylinev1.SubAudible {
	sa := &leylinev1.SubAudible{
		ChannelId:      channelID,
		Kind:           leylinev1.SubAudibleKind_SUB_AUDIBLE_NONE,
		ToneHz:         math.NaN(),
		DeviationHz:    math.NaN(),
		ToneSnrDb:      math.NaN(),
		StandardToneHz: 0,
	}
	if !open {
		return sa
	}
	if code != nil {
		sa.Kind = leylinev1.SubAudibleKind_SUB_AUDIBLE_DCS
		sa.DcsCode, sa.DcsInverted = code.Code, code.Inverted
		sa.DeviationHz = 550
		sa.Confidence = 0.9
		return sa
	}
	if toneHz == 0 {
		return sa
	}
	sa.Kind = leylinev1.SubAudibleKind_SUB_AUDIBLE_CTCSS
	// Measured, then classified: the measurement is never exactly the standard tone.
	sa.ToneHz = toneHz + 0.12
	sa.StandardToneHz = toneHz
	sa.DeviationHz = 620
	sa.ToneSnrDb = 17.5
	sa.Confidence = 0.9
	return sa
}
