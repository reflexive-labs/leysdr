package fakedaemon

import (
	"context"
	"fmt"
	"math"
	"sort"
	"time"

	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

func unimplemented(ctx context.Context, what string) error {
	return fail(ctx, errorf(leyline.CodeUnimplemented, "", what+" is not implemented in v0"))
}

// Jobs: scan is implemented so the CLI is testable without the Swift daemon; the sweep is faked
// from the fake device's synthetic spectrum, and everything else stays UNIMPLEMENTED.
//
// The shape is what matters here, not the DSP: a RUNNING job, full-state Job events on the same
// seq stream as everything else, Detection messages on telemetry as they are found, a COMPLETED
// job, and a Scan that GetScan resolves. The real detector lives in the daemon and is tested there.

// fakeJob is one entry in the fake job table.
type fakeJob struct {
	proto *leylinev1.Job
	scan  *leylinev1.Scan
	owner string
}

// publishDetection appends to the log every telemetry subscriber reads. Caller holds the lock.
func (d *Daemon) publishDetection(det *leylinev1.Detection) {
	for _, x := range d.detectionLog {
		if x.CenterHz == det.CenterHz {
			return
		}
	}
	d.detectionLog = append(d.detectionLog, proto.Clone(det).(*leylinev1.Detection))
	if n := len(d.detectionLog) - 256; n > 0 {
		d.detectionLog = d.detectionLog[n:]
	}
}

// StartJob implements Jobs.
func (d *Daemon) StartJob(ctx context.Context, req *leylinev1.StartJobRequest) (*leylinev1.Job, error) {
	cfg, ok := req.Config.(*leylinev1.StartJobRequest_Scan)
	if !ok || cfg.Scan == nil {
		if req.Config == nil {
			return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, "", "StartJob needs a config: scan is the only one in v0"))
		}
		return nil, unimplemented(ctx, "Jobs.StartJob(watch/record)")
	}
	sc := cfg.Scan
	if _, recurring := sc.Schedule.(*leylinev1.ScanConfig_Recurring); recurring {
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, "",
			"a recurring scan needs a job store that survives a restart (Milestone D.15); use once"))
	}
	if sc.Range == nil || sc.Range.MaxHz <= sc.Range.MinHz {
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, "", "a scan needs a frequency range with max above min"))
	}
	ci := clientFrom(ctx)
	d.touchUnary(ci)

	d.mu.Lock()
	dev := d.scanDevice()
	if dev == nil {
		d.mu.Unlock()
		return nil, fail(ctx, errorf(leyline.CodeDeviceNotFound, "", "no radio here can tune that range"))
	}
	job := &leylinev1.Job{
		JobId:        newID("job_"),
		State:        leylinev1.JobState_RUNNING,
		CreatedAtNs:  time.Now().UnixNano(),
		CreatedBy:    ci,
		Config:       &leylinev1.Job_Scan{Scan: sc},
		StatusDetail: "starting",
	}
	scanID := newID("scan_")
	job.ResultUris = []string{"ley://scans/" + scanID}
	d.jobs[job.JobId] = &fakeJob{proto: job, scan: &leylinev1.Scan{
		ScanId: scanID, Config: sc, StartedAtNs: job.CreatedAtNs,
	}, owner: ci.GetClientId()}
	d.jobOrder = append(d.jobOrder, job.JobId)
	d.emit(ci, job)
	d.mu.Unlock()

	go d.runScan(job.JobId, sc, dev)
	return proto.Clone(job).(*leylinev1.Job), nil
}

// busyReason names who has the radio, or "" when nobody does. The real daemon's allocator applies
// the same rule (no channels, no live audio sink, no recent interactive write); the fake keeps the
// first two, which is what a CLI test can set up. Caller holds the lock.
func (d *Daemon) busyReason(deviceID string) string {
	for _, cap := range d.captures {
		if cap.DeviceId != deviceID {
			continue
		}
		for _, ch := range d.channels {
			if ch.CaptureId == cap.CaptureId {
				who := ch.GetOwner().GetLabel()
				if who == "" {
					who = ch.GetOwner().GetKind()
				}
				hz := uint64(int64(cap.CenterHz) + ch.OffsetHz)
				return fmt.Sprintf("%s is listening on %s", who, leyline.FormatFrequency(hz))
			}
		}
		if cap.GetActivity().GetLiveAudioSinks() > 0 {
			return "audio is playing from this radio"
		}
	}
	return ""
}

// runScan walks the range and reports the fake device's carriers that fall inside it.
func (d *Daemon) runScan(jobID string, sc *leylinev1.ScanConfig, dev *leylinev1.DeviceDescriptor) {
	rate := uint64(2_400_000)
	if len(dev.SampleRates) > 0 {
		rate = dev.SampleRates[len(dev.SampleRates)-1]
	}
	// The same geometry the daemon uses: quarter bands 5%-45% either side of centre, advancing
	// half a window, plus a step at each end.
	span := float64(rate)
	guardHz, edgeHz := 0.05*span, 0.45*span
	advance := edgeHz - guardHz
	lo, hi := float64(sc.Range.MinHz), float64(sc.Range.MaxHz)
	centers := []float64{lo - guardHz, hi + guardHz}
	if hi-lo > advance {
		for c := lo + edgeHz; c-edgeHz < hi; c += advance {
			centers = append(centers, c)
		}
	}
	sort.Float64s(centers)

	dwell := time.Duration(sc.DwellMs) * time.Millisecond
	if dwell <= 0 {
		dwell = 20 * time.Millisecond
	}
	if dwell > 200*time.Millisecond {
		dwell = 200 * time.Millisecond // tests must not wait for a real sweep
	}
	if !sc.TakeOver {
		d.mu.Lock()
		reason := d.busyReason(dev.DeviceId)
		d.mu.Unlock()
		if reason != "" {
			d.failScan(jobID, "DEVICE_BUSY", reason)
			return
		}
	}
	var found []*leylinev1.Detection
	var floors []*leylinev1.NoiseFloorSegment
	for i, c := range centers {
		if d.jobCancelled(jobID) {
			return
		}
		time.Sleep(dwell)
		windows := [2][2]float64{{c - edgeHz, c - guardHz}, {c + guardHz, c + edgeHz}}
		for _, w := range windows {
			for _, sig := range fakeCarriers {
				f := float64(sig.hz)
				if f < w[0] || f >= w[1] || f < lo || f > hi {
					continue
				}
				found = mergeDetection(found, &leylinev1.Detection{
					DetectionId:   fmt.Sprintf("det_%d", sig.hz),
					CaptureId:     "",
					CenterHz:      sig.hz,
					BandwidthHz:   sig.bw,
					SnrDb:         sig.snr,
					FloorDbfs:     fakeFloorDbfs,
					Looks:         4,
					LooksPossible: 4,
				})
			}
		}
		floors = append(floors, &leylinev1.NoiseFloorSegment{
			Range:     &leylinev1.FrequencyRange{MinHz: uint64(math.Max(0, c-edgeHz)), MaxHz: uint64(c + edgeHz)},
			FloorDbfs: fakeFloorDbfs,
		})
		d.setJobDetail(jobID, fmt.Sprintf("step %d/%d, %d found", i+1, len(centers), len(found)), found)
	}
	d.finishScan(jobID, found, floors)
}

// fakeCarriers is the synthetic band the fake daemon reports. Real enough to render, and
// deliberately not derived from the fake FFT: the CLI test is about the table, not the DSP.
var fakeCarriers = []struct {
	hz  uint64
	bw  uint32
	snr float64
}{
	{145_230_000, 11_400, 21.4},
	{146_520_000, 11_900, 34.2},
	{146_940_000, 12_100, 18.7},
	{162_400_000, 11_800, 12.0},
	{101_100_000, 198_000, 41.5},
}

const fakeFloorDbfs = -88.2

func mergeDetection(list []*leylinev1.Detection, d *leylinev1.Detection) []*leylinev1.Detection {
	for _, x := range list {
		if x.CenterHz == d.CenterHz {
			x.Looks += d.Looks
			x.LooksPossible += d.LooksPossible
			return list
		}
	}
	return append(list, d)
}

// scanDevice picks a radio for a sweep. Caller holds the lock.
func (d *Daemon) scanDevice() *leylinev1.DeviceDescriptor {
	var best *leylinev1.DeviceDescriptor
	for _, x := range d.devices {
		if x == nil || x.State == leylinev1.DeviceState_DISCONNECTED {
			continue
		}
		if best == nil || x.DeviceId < best.DeviceId {
			best = x
		}
	}
	return best
}

func (d *Daemon) jobCancelled(id string) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	j := d.jobs[id]
	return j == nil || j.proto.State != leylinev1.JobState_RUNNING
}

func (d *Daemon) setJobDetail(id, detail string, found []*leylinev1.Detection) {
	d.mu.Lock()
	defer d.mu.Unlock()
	j := d.jobs[id]
	if j == nil || j.proto.State != leylinev1.JobState_RUNNING {
		return
	}
	j.proto.StatusDetail = detail
	for _, det := range found {
		d.publishDetection(det)
	}
	d.emit(nil, j.proto)
}

func (d *Daemon) failScan(id, code, reason string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	j := d.jobs[id]
	if j == nil || j.proto.State != leylinev1.JobState_RUNNING {
		return
	}
	j.proto.State = leylinev1.JobState_FAILED
	j.proto.StatusDetail = code + ": " + reason
	d.emit(nil, j.proto)
}

func (d *Daemon) finishScan(id string, found []*leylinev1.Detection, floors []*leylinev1.NoiseFloorSegment) {
	d.mu.Lock()
	defer d.mu.Unlock()
	j := d.jobs[id]
	if j == nil || j.proto.State != leylinev1.JobState_RUNNING {
		return
	}
	j.scan.Detections = found
	j.scan.NoiseFloor = floors
	j.scan.CompletedAtNs = time.Now().UnixNano()
	j.scan.Gains = []*leylinev1.GainState{{Element: "TUNER", Db: 28.0}}
	j.proto.State = leylinev1.JobState_COMPLETED
	j.proto.StatusDetail = fmt.Sprintf("%d found", len(found))
	d.emit(nil, j.proto)
}

// ListJobs implements Jobs.
func (d *Daemon) ListJobs(ctx context.Context, req *leylinev1.ListJobsRequest) (*leylinev1.ListJobsResponse, error) {
	d.touchUnary(clientFrom(ctx))
	d.mu.Lock()
	defer d.mu.Unlock()
	want := map[leylinev1.JobState]bool{}
	for _, s := range req.States {
		want[s] = true
	}
	out := &leylinev1.ListJobsResponse{}
	for _, id := range d.jobOrder {
		j := d.jobs[id]
		if j == nil || (len(want) > 0 && !want[j.proto.State]) {
			continue
		}
		out.Jobs = append(out.Jobs, proto.Clone(j.proto).(*leylinev1.Job))
	}
	return out, nil
}

// GetJob implements Jobs.
func (d *Daemon) GetJob(ctx context.Context, req *leylinev1.JobRef) (*leylinev1.Job, error) {
	d.touchUnary(clientFrom(ctx))
	d.mu.Lock()
	defer d.mu.Unlock()
	j := d.jobs[req.JobId]
	if j == nil {
		return nil, fail(ctx, errorf(leyline.CodeJobNotFound, req.JobId, "no such job"))
	}
	return proto.Clone(j.proto).(*leylinev1.Job), nil
}

// CancelJob implements Jobs.
func (d *Daemon) CancelJob(ctx context.Context, req *leylinev1.JobRef) (*leylinev1.Job, error) {
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	d.mu.Lock()
	defer d.mu.Unlock()
	j := d.jobs[req.JobId]
	if j == nil {
		return nil, fail(ctx, errorf(leyline.CodeJobNotFound, req.JobId, "no such job"))
	}
	if j.proto.State == leylinev1.JobState_RUNNING {
		j.proto.State = leylinev1.JobState_CANCELLED
		j.proto.StatusDetail = "cancelled"
		d.emit(ci, j.proto)
	}
	return proto.Clone(j.proto).(*leylinev1.Job), nil
}

// GetTranscript implements Jobs.
func (d *Daemon) GetTranscript(ctx context.Context, _ *leylinev1.TranscriptRequest) (*leylinev1.Transcript, error) {
	return nil, unimplemented(ctx, "Jobs.GetTranscript")
}

// GetScan implements Jobs.
func (d *Daemon) GetScan(ctx context.Context, req *leylinev1.ScanRef) (*leylinev1.Scan, error) {
	d.touchUnary(clientFrom(ctx))
	d.mu.Lock()
	defer d.mu.Unlock()
	for _, id := range d.jobOrder {
		if j := d.jobs[id]; j != nil && j.scan != nil && j.scan.ScanId == req.ScanId {
			return proto.Clone(j.scan).(*leylinev1.Scan), nil
		}
	}
	return nil, fail(ctx, errorf(leyline.CodeScanNotFound, req.ScanId, "no such scan"))
}

// Resources service: UNIMPLEMENTED in v0.

// ListResources implements Resources.
func (d *Daemon) ListResources(ctx context.Context, _ *leylinev1.ListResourcesRequest) (*leylinev1.ListResourcesResponse, error) {
	return nil, unimplemented(ctx, "Resources.ListResources")
}

// GetResource implements Resources.
func (d *Daemon) GetResource(ctx context.Context, _ *leylinev1.ResourceRef) (*leylinev1.Resource, error) {
	return nil, unimplemented(ctx, "Resources.GetResource")
}

// ResolveLocalPath implements Resources.
func (d *Daemon) ResolveLocalPath(ctx context.Context, _ *leylinev1.ResourceRef) (*leylinev1.LocalPath, error) {
	return nil, unimplemented(ctx, "Resources.ResolveLocalPath")
}
