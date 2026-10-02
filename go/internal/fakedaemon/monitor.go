// SPDX-License-Identifier: Apache-2.0

package fakedaemon

import (
	"context"
	"fmt"
	"math"
	"time"

	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
	"github.com/reflexive-labs/leysdr/go/pkg/units"
)

// The fake monitor job: it parks on a band and emits synthetic Detection messages over the
// requested duration, so the CLI's transmission log has carriers to fold without the Swift daemon.
// The shape is what matters, not the DSP: a RUNNING job, Detection messages on the telemetry
// plane as carriers come and go, and a COMPLETED job when the duration elapses (or CANCELLED).

// monitorCarriers is the synthetic band a watch reports: carriers on GMRS channels so the channel
// labels show, one weak enough for --min-snr to hide. They are not derived from any FFT --
// the CLI test is about the transmission log, not the detector.
type monitorSig struct {
	hz   uint64
	bw   uint32
	snr  float64
	busy float64 // the fraction of looks the carrier is detected in: its ON AIR share of the watch
}

var monitorCarriers = []monitorSig{
	{462_562_500, 12_500, 12.0, 1.00}, // ch1, weak but isolated: --min-snr 20 hides it, the default keeps it
	{462_600_000, 12_500, 21.0, 1.00}, // ch17, a real adjacent carrier: only 19 dB below ch18, so not a skirt
	{462_625_000, 12_500, 40.0, 1.00}, // ch18, the strongest, on air the whole watch
	{462_650_000, 12_500, 12.0, 1.00}, // ch19, a skirt of ch18: 28 dB below, one channel over, folds into it
	{462_662_500, 12_500, 14.0, 0.25}, // ch5, isolated but intermittent: a wide HELD, a small ON AIR
}

// monitorEmitInterval is how often the fake re-reports a carrier that is still up, so the client
// sees it first appear and be held for a span rather than as a single instant.
const monitorEmitInterval = 100 * time.Millisecond

// startMonitor mirrors the scan StartJob path: the allocator runs inside the job, so a missing or
// busy radio is a FAILED job with a reason, never an RPC error.
func (d *Daemon) startMonitor(ctx context.Context, mc *leylinev1.MonitorConfig) (*leylinev1.Job, error) {
	if mc.Range == nil || mc.Range.MaxHz <= mc.Range.MinHz {
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, "", "a monitor needs a frequency range with max above min"))
	}
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	d.mu.Lock()
	dev := d.scanDevice(mc.DeviceId, mc.Range)
	job := &leylinev1.Job{
		JobId:        newID("job_"),
		State:        leylinev1.JobState_RUNNING,
		CreatedAtNs:  time.Now().UnixNano(),
		CreatedBy:    ci,
		Config:       &leylinev1.Job_Monitor{Monitor: mc},
		StatusDetail: "starting",
	}
	d.jobs[job.JobId] = &fakeJob{proto: job, owner: ci.GetClientId()}
	d.jobOrder = append(d.jobOrder, job.JobId)
	d.trimJobsLocked()
	d.emit(byDaemon(), job)
	reply := proto.Clone(job).(*leylinev1.Job)
	d.mu.Unlock()

	go d.runMonitor(job.JobId, mc, dev)
	return reply, nil
}

// runMonitor holds the band for the duration and reports the carriers on it that fall inside the
// requested range, each re-reported on a heartbeat so the client can time how long it was held.
func (d *Daemon) runMonitor(jobID string, mc *leylinev1.MonitorConfig, dev *leylinev1.DeviceDescriptor) {
	if dev == nil {
		if mc.DeviceId != "" {
			d.failMonitor(jobID, leyline.CodeNoDevice, mc.DeviceId+" cannot tune that range, or is not here")
		} else {
			d.failMonitor(jobID, leyline.CodeNoDevice, "no radio here can tune that range")
		}
		return
	}
	rate := uint64(2_400_000)
	if n := len(dev.SampleRates); n > 0 {
		rate = dev.SampleRates[n-1]
	}
	// A band wider than one capture can watch is scan's job, not a monitor's.
	if mc.Range.MaxHz-mc.Range.MinHz > rate {
		d.failMonitor(jobID, leyline.CodeInvalidArgument, fmt.Sprintf(
			"%s is wider than one capture can watch", units.FormatFrequency(mc.Range.MaxHz-mc.Range.MinHz)))
		return
	}
	d.mu.Lock()
	reason := ""
	if !mc.TakeOver {
		reason = d.busyReason(dev.DeviceId)
	}
	// The capture the watch listens on, so a telemetry subscriber scoped to another radio is not
	// shown this one's detections; a daemon-wide subscriber (what monitor uses) sees them anyway.
	watchCapture := ""
	for _, c := range d.captures {
		if c.DeviceId == dev.DeviceId {
			watchCapture = c.CaptureId
		}
	}
	d.mu.Unlock()
	if reason != "" {
		d.failMonitor(jobID, leyline.CodeDeviceBusy, reason)
		return
	}

	carriers := monitorCarriersIn(mc.Range)
	d.setMonitorRunning(jobID, mc)

	interval := monitorEmitInterval
	var deadline time.Time
	if mc.DurationMs > 0 {
		deadline = time.Now().Add(time.Duration(mc.DurationMs) * time.Millisecond)
		// Short watches still get several heartbeats, so a carrier reads as held rather than as
		// a single instant.
		if step := time.Duration(mc.DurationMs) * time.Millisecond / 8; step > 0 && step < interval {
			interval = step
		}
	}
	if interval < 10*time.Millisecond {
		interval = 10 * time.Millisecond
	}
	looksPossible := uint32(0)
	for {
		if d.jobCancelled(jobID) {
			d.cancelMonitor(jobID)
			return
		}
		// Every cycle is a look every carrier's frequency had; a carrier is "detected" in its busy
		// fraction of them, so looks/looksPossible is its ON AIR share, exactly as the daemon reports.
		looksPossible++
		for _, sig := range carriers {
			// The daemon re-publishes a carrier only in the rows it actually found it, so
			// this cycle publishes only when the carrier's look count grows: a client
			// timing the arrivals sees the same on-air pattern it would from leylined.
			looks := uint32(math.Round(float64(looksPossible) * sig.busy))
			if before := uint32(math.Round(float64(looksPossible-1) * sig.busy)); looks == before {
				continue
			}
			d.publishMonitorDetection(&leylinev1.Detection{
				DetectionId:   fmt.Sprintf("det_%d", sig.hz),
				CaptureId:     watchCapture,
				CenterHz:      sig.hz,
				BandwidthHz:   sig.bw,
				SnrDb:         sig.snr,
				FloorDbfs:     fakeFloorDbfs,
				Looks:         looks,
				LooksPossible: looksPossible,
			})
		}
		if mc.DurationMs > 0 && !time.Now().Before(deadline) {
			break
		}
		time.Sleep(interval)
	}
	d.finishMonitor(jobID, len(carriers))
}

// monitorCarriersIn keeps the synthetic carriers that fall inside the watched range.
func monitorCarriersIn(r *leylinev1.FrequencyRange) []monitorSig {
	var out []monitorSig
	for _, sig := range monitorCarriers {
		if sig.hz >= r.MinHz && sig.hz <= r.MaxHz {
			out = append(out, sig)
		}
	}
	return out
}

// publishMonitorDetection appends to the telemetry log every subscriber reads. Unlike a scan's
// publish it does not dedupe by frequency: a monitor re-reports a carrier that is still up, and
// each re-report is how the client measures how long it was held.
func (d *Daemon) publishMonitorDetection(det *leylinev1.Detection) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.detectionLog = append(d.detectionLog, proto.Clone(det).(*leylinev1.Detection))
	if n := len(d.detectionLog) - 256; n > 0 {
		d.detectionLog = d.detectionLog[n:]
		d.detectionEpoch = max(0, d.detectionEpoch-n)
	}
}

// setMonitorRunning stamps the watch as under way, as the daemon does once the lease is in hand.
func (d *Daemon) setMonitorRunning(jobID string, mc *leylinev1.MonitorConfig) {
	d.mu.Lock()
	defer d.mu.Unlock()
	j := d.jobs[jobID]
	if j == nil || j.proto.State != leylinev1.JobState_RUNNING {
		return
	}
	j.proto.StatusDetail = fmt.Sprintf("watching %s to %s",
		units.FormatFrequency(mc.Range.MinHz), units.FormatFrequency(mc.Range.MaxHz))
	d.emit(byDaemon(), j.proto)
}

func (d *Daemon) finishMonitor(jobID string, carriers int) {
	d.mu.Lock()
	defer d.mu.Unlock()
	j := d.jobs[jobID]
	if j == nil || j.proto.State != leylinev1.JobState_RUNNING {
		return
	}
	j.proto.State = leylinev1.JobState_COMPLETED
	noun := "carriers"
	if carriers == 1 {
		noun = "carrier"
	}
	j.proto.StatusDetail = fmt.Sprintf("%d %s heard", carriers, noun)
	d.emit(byDaemon(), j.proto)
	d.trimJobsLocked()
}

func (d *Daemon) cancelMonitor(jobID string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	j := d.jobs[jobID]
	if j == nil || j.proto.State != leylinev1.JobState_RUNNING {
		return
	}
	j.proto.State = leylinev1.JobState_CANCELLED
	j.proto.StatusDetail = "stopped"
	d.emit(byDaemon(), j.proto)
	d.trimJobsLocked()
}

func (d *Daemon) failMonitor(jobID, code, reason string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	j := d.jobs[jobID]
	if j == nil || j.proto.State != leylinev1.JobState_RUNNING {
		return
	}
	j.proto.State = leylinev1.JobState_FAILED
	j.proto.StatusDetail = reason
	j.proto.Error = &leylinev1.ErrorDetail{Code: code, Message: reason, Target: jobID}
	d.emit(byDaemon(), j.proto)
}
