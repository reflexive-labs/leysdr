// SPDX-License-Identifier: Apache-2.0

package fakedaemon

import (
	"context"
	"fmt"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
	"github.com/reflexive-labs/leysdr/go/pkg/units"
)

// Plan answers Control.Plan from the fake's own allocator (leaseChannelLocked, runScan), without
// carrying anything out, so a dry run here predicts what the fake's StartJob does. The daemon's
// CapturePlanner is the real rule; this keeps the fake's shape of it.
func (d *Daemon) Plan(ctx context.Context, req *leylinev1.PlanRequest) (*leylinev1.CapturePlan, error) {
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	switch r := req.GetRequest().(type) {
	case *leylinev1.PlanRequest_Decode:
		cfg := r.Decode
		man := d.decoderByName(cfg.GetDecoder())
		if man == nil {
			return nil, fail(ctx, errorf(leyline.CodeDecoderNotFound, cfg.GetDecoder(),
				"no decoder called "+quoted(cfg.GetDecoder())+" is installed"))
		}
		if cfg.GetSourceUri() != "" {
			return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, cfg.GetSourceUri(),
				"a decode of a stored recording needs no radio, so it has no plan"))
		}
		hz := cfg.GetFrequencyHz()
		if hz == 0 && len(man.GetRecipe().GetFrequenciesHz()) > 0 {
			hz = man.GetRecipe().GetFrequenciesHz()[0]
		}
		if hz == 0 {
			return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, cfg.GetDecoder(),
				cfg.GetDecoder()+" names no frequency of its own; say which with --freq"))
		}
		d.mu.Lock()
		defer d.mu.Unlock()
		return d.planChannelLocked(cfg.GetDeviceId(), cfg.GetTakeOver(), hz, man.GetRecipe().GetBandwidthHz()), nil
	case *leylinev1.PlanRequest_Record:
		cfg := r.Record
		d.mu.Lock()
		defer d.mu.Unlock()
		if chID := cfg.GetChannelId(); chID != "" {
			ch := d.channels[chID]
			if ch == nil {
				return nil, fail(ctx, errorf(leyline.CodeChannelNotFound, chID, "no channel called "+quoted(chID)+" is open"))
			}
			return shareOf(d.captures[ch.GetCaptureId()]), nil
		}
		if cfg.GetFrequencyHz() == 0 {
			return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, "", "a recording needs a frequency, a preset or a channel to record"))
		}
		return d.planChannelLocked(cfg.GetDeviceId(), cfg.GetTakeOver(), cfg.GetFrequencyHz(), recordBandwidth(cfg)), nil
	case *leylinev1.PlanRequest_Scan:
		d.mu.Lock()
		defer d.mu.Unlock()
		return d.planSweepLocked(r.Scan.GetDeviceId(), r.Scan.GetRange(), r.Scan.GetTakeOver()), nil
	case *leylinev1.PlanRequest_Monitor:
		d.mu.Lock()
		defer d.mu.Unlock()
		return d.planSweepLocked(r.Monitor.GetDeviceId(), r.Monitor.GetRange(), r.Monitor.GetTakeOver()), nil
	case *leylinev1.PlanRequest_Retune:
		d.mu.Lock()
		defer d.mu.Unlock()
		c := d.captures[r.Retune.GetCaptureId()]
		if c == nil {
			return nil, fail(ctx, errorf(leyline.CodeCaptureNotFound, r.Retune.GetCaptureId(), "no such capture"))
		}
		rate := r.Retune.GetSampleRateHz()
		if rate == 0 {
			rate = c.SampleRate
		}
		var moved []*leylinev1.Claim
		for _, cl := range d.channelClaimsLocked(c) {
			if cl.GetHolder().GetClientId() != ci.GetClientId() && !spanFits(cl, r.Retune.GetCenterHz(), rate) {
				moved = append(moved, cl)
			}
		}
		return retuneOf(c, r.Retune.GetCenterHz(), rate, moved), nil
	}
	return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, "", "a plan needs a request: a decode, a record, a scan, a monitor or a retune"))
}

// planChannelLocked is leaseChannelLocked's decision without its effects. Caller holds the lock.
func (d *Daemon) planChannelLocked(deviceID string, takeOver bool, hz uint64, bw uint32) *leylinev1.CapturePlan {
	for _, c := range d.captures {
		if deviceID != "" && c.DeviceId != deviceID {
			continue
		}
		if !captureCovers(c, hz, bw) {
			continue
		}
		if !takeOver {
			if why := d.busyReason(c.DeviceId); why != "" {
				return declineOf(leyline.CodeDeviceBusy, why, d.channelClaimsLocked(c))
			}
		}
		return shareOf(c)
	}
	dev := d.scanDevice(deviceID, &leylinev1.FrequencyRange{MinHz: hz, MaxHz: hz + 1})
	if dev == nil {
		return declineOf(leyline.CodeNoDevice, "no radio here can tune "+units.FormatFrequency(hz), nil)
	}
	existing := d.deviceCaptureLocked(dev.DeviceId)
	// A radio a sweep holds takes nothing else, take_over or not, and says which sweep.
	if existing != nil && d.sweeping == dev.DeviceId {
		return declineOf(leyline.CodeDeviceBusy,
			"a scan is sweeping "+dev.GetModel()+"; it is free again when the scan ends", nil)
	}
	rate := RTLSDRDefaultRate
	if dev.Driver == "file" && len(dev.SampleRates) > 0 {
		rate = dev.SampleRates[0]
	}
	centre := hz - rate/8
	if !inRange(dev, centre) {
		centre = hz
	}
	if existing != nil {
		var moved []*leylinev1.Claim
		for _, cl := range d.channelClaimsLocked(existing) {
			if !spanFits(cl, centre, existing.SampleRate) {
				moved = append(moved, cl)
			}
		}
		// Only what the retune would displace stops it, and a person at the controls: a
		// channel the new centre still covers is no reason.
		if !takeOver {
			if len(moved) > 0 {
				return declineOf(leyline.CodeDeviceBusy, listeningOn(moved[0]), moved)
			}
			if why := presenceReason(existing); why != "" {
				return declineOf(leyline.CodeDeviceBusy, why, nil)
			}
		}
		return retuneOf(existing, centre, existing.SampleRate, moved)
	}
	return &leylinev1.CapturePlan{Outcome: &leylinev1.CapturePlan_Create{Create: &leylinev1.PlanCreate{
		DeviceId: dev.DeviceId, CenterHz: centre, SampleRateHz: rate,
	}}}
}

// planSweepLocked is runScan's decision without its effects. Caller holds the lock.
func (d *Daemon) planSweepLocked(deviceID string, r *leylinev1.FrequencyRange, takeOver bool) *leylinev1.CapturePlan {
	dev := d.scanDevice(deviceID, r)
	if dev == nil {
		if deviceID != "" {
			return declineOf(leyline.CodeNoDevice, deviceID+" cannot tune that range, or is not here", nil)
		}
		return declineOf(leyline.CodeNoDevice, "no radio here can tune that range", nil)
	}
	existing := d.deviceCaptureLocked(dev.DeviceId)
	if !takeOver {
		if why := d.busyReason(dev.DeviceId); why != "" {
			return declineOf(leyline.CodeDeviceBusy, why, d.channelClaimsLocked(existing))
		}
	}
	if d.sweeping != "" {
		return declineOf(leyline.CodeDeviceBusy, "another scan already has "+d.devices[d.sweeping].GetModel(), nil)
	}
	mid := r.GetMinHz() + (r.GetMaxHz()-r.GetMinHz())/2
	if existing != nil {
		return retuneOf(existing, mid, existing.SampleRate, d.channelClaimsLocked(existing))
	}
	rate := uint64(2_400_000)
	if n := len(dev.SampleRates); n > 0 {
		rate = dev.SampleRates[n-1]
	}
	return &leylinev1.CapturePlan{Outcome: &leylinev1.CapturePlan_Create{Create: &leylinev1.PlanCreate{
		DeviceId: dev.DeviceId, CenterHz: mid, SampleRateHz: rate,
	}}}
}

func (d *Daemon) deviceCaptureLocked(deviceID string) *capture {
	for _, c := range d.captures {
		if c.DeviceId == deviceID {
			return c
		}
	}
	return nil
}

// channelClaimsLocked is the channels on a capture as the daemon's ledger lists them: a CHANNEL
// claim each, PERSON for a client's and JOB for a job's.
func (d *Daemon) channelClaimsLocked(c *capture) []*leylinev1.Claim {
	if c == nil {
		return nil
	}
	var out []*leylinev1.Claim
	for _, ch := range d.channels {
		if ch.GetCaptureId() != c.CaptureId {
			continue
		}
		priority := leylinev1.ClaimPriority_PRIORITY_PERSON
		holder := ch.GetOwner()
		if ch.GetOwner().GetKind() == "job" {
			priority = leylinev1.ClaimPriority_PRIORITY_JOB
			// The daemon's ledger names the job that holds the channel, not the client that
			// started it.
			for id, j := range d.jobs {
				if j.channelID == ch.GetChannelId() {
					holder = &leylinev1.ClientInfo{ClientId: id, Kind: "job", Label: ch.GetOwner().GetLabel()}
				}
			}
		}
		out = append(out, &leylinev1.Claim{
			ClaimId:  "clm_" + ch.GetChannelId(),
			Holder:   holder,
			Kind:     leylinev1.ClaimKind_CLAIM_CHANNEL,
			Priority: priority,
			State:    leylinev1.ClaimState_CLAIM_SATISFIED,
			Need: &leylinev1.Claim_Covers{Covers: &leylinev1.Span{
				FrequencyHz: uint64(int64(c.CenterHz) + ch.GetOffsetHz()), BandwidthHz: ch.GetBandwidthHz(),
			}},
		})
	}
	return out
}

// listeningOn names a channel claim the way busyReason names a channel.
func listeningOn(cl *leylinev1.Claim) string {
	who := cl.GetHolder().GetLabel()
	if who == "" {
		who = cl.GetHolder().GetKind()
	}
	return fmt.Sprintf("%s is listening on %s", who, units.FormatFrequency(cl.GetCovers().GetFrequencyHz()))
}

// presenceReason is busyReason's person at the controls: a live audio sink, or a write in the
// last minute.
func presenceReason(c *capture) string {
	if c.GetActivity().GetLiveAudioSinks() > 0 {
		return "audio is playing from this radio"
	}
	if last := c.GetActivity().GetLastInteractiveWriteNs(); last > 0 {
		if age := time.Since(time.Unix(0, last)); age < dontDisturb {
			return fmt.Sprintf("somebody was tuning this radio %d s ago", int(age.Seconds()))
		}
	}
	return ""
}

func spanFits(cl *leylinev1.Claim, centre, rate uint64) bool {
	s := cl.GetCovers()
	off := float64(int64(s.GetFrequencyHz()) - int64(centre))
	if off < 0 {
		off = -off
	}
	return off+float64(s.GetBandwidthHz())/2 <= float64(rate)/2
}

func shareOf(c *capture) *leylinev1.CapturePlan {
	return &leylinev1.CapturePlan{Outcome: &leylinev1.CapturePlan_Share{Share: &leylinev1.PlanShare{
		CaptureId: c.GetCaptureId(), DeviceId: c.GetDeviceId(), CenterHz: c.GetCenterHz(), SampleRateHz: c.GetSampleRate(),
	}}}
}

func retuneOf(c *capture, centre, rate uint64, moved []*leylinev1.Claim) *leylinev1.CapturePlan {
	return &leylinev1.CapturePlan{Outcome: &leylinev1.CapturePlan_Retune{Retune: &leylinev1.PlanRetune{
		CaptureId: c.CaptureId, DeviceId: c.DeviceId, CenterHz: centre, SampleRateHz: rate, Displaced: moved,
	}}}
}

func declineOf(code, reason string, blocking []*leylinev1.Claim) *leylinev1.CapturePlan {
	return &leylinev1.CapturePlan{Outcome: &leylinev1.CapturePlan_Decline{Decline: &leylinev1.PlanDecline{
		Code: code, Reason: reason, Blocking: blocking,
	}}}
}
