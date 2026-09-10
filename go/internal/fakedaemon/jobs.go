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
//
// Deduped within a scan (the sweep re-reports the same carrier as it accumulates looks) but not
// across scans, which are separate observations of the band.
func (d *Daemon) publishDetection(det *leylinev1.Detection) {
	for _, x := range d.detectionLog[d.detectionEpoch:] {
		if x.CenterHz == det.CenterHz {
			return
		}
	}
	d.detectionLog = append(d.detectionLog, proto.Clone(det).(*leylinev1.Detection))
	if n := len(d.detectionLog) - 256; n > 0 {
		d.detectionLog = d.detectionLog[n:]
		d.detectionEpoch = max(0, d.detectionEpoch-n)
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
	// The daemon allocates inside the job, not inside StartJob: a radio that is missing or busy is
	// a FAILED job with a reason, never an RPC error. A fake that refused synchronously would give
	// every CLI test a code path the real daemon never takes.
	dev := d.scanDevice(sc.DeviceId, sc.Range)
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
	rate := uint64(2_400_000)
	if dev != nil && len(dev.SampleRates) > 0 {
		rate = dev.SampleRates[len(dev.SampleRates)-1]
	}
	stored := proto.Clone(sc).(*leylinev1.ScanConfig)
	stored.StepHz = uint32(0.4 * float64(rate))
	d.jobs[job.JobId] = &fakeJob{proto: job, scan: &leylinev1.Scan{
		ScanId: scanID, Config: stored, StartedAtNs: job.CreatedAtNs,
		ResolutionHz: uint32(rate / 1024),
	}, owner: ci.GetClientId()}
	d.jobOrder = append(d.jobOrder, job.JobId)
	d.detectionEpoch = len(d.detectionLog)
	d.trimJobsLocked()
	d.emit(ci, job)
	// The scan goroutine edits this job under the lock as it runs, so the reply is copied while
	// the lock is still held.
	reply := proto.Clone(job).(*leylinev1.Job)
	d.mu.Unlock()

	go d.runScan(job.JobId, sc, dev)
	return reply, nil
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
		if last := cap.GetActivity().GetLastInteractiveWriteNs(); last > 0 {
			if age := time.Since(time.Unix(0, last)); age < dontDisturb {
				return fmt.Sprintf("somebody was tuning this radio %d s ago", int(age.Seconds()))
			}
		}
	}
	return ""
}

// runScan walks the range and reports the fake device's carriers that fall inside it.
func (d *Daemon) runScan(jobID string, sc *leylinev1.ScanConfig, dev *leylinev1.DeviceDescriptor) {
	if dev == nil {
		if sc.DeviceId != "" {
			d.failScan(jobID, "NO_DEVICE", sc.DeviceId+" cannot tune that range, or is not here")
		} else {
			d.failScan(jobID, "NO_DEVICE", "no radio here can tune that range")
		}
		return
	}
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
	d.mu.Lock()
	reason := ""
	if !sc.TakeOver {
		reason = d.busyReason(dev.DeviceId)
	}
	if reason == "" && d.sweeping != "" {
		reason = "another scan already has " + d.devices[d.sweeping].GetModel()
	}
	if reason == "" {
		d.sweeping = dev.DeviceId
	}
	d.mu.Unlock()
	if reason != "" {
		d.failScan(jobID, "DEVICE_BUSY", reason)
		return
	}
	defer func() {
		d.mu.Lock()
		d.sweeping = ""
		d.mu.Unlock()
	}()
	var found []*leylinev1.Detection
	var floors []*leylinev1.NoiseFloorSegment
	for i, c := range centers {
		if d.jobCancelled(jobID) {
			d.keepPartial(jobID, found, floors, uint64(math.Max(0, lo)), uint64(hi))
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
		d.setJobDetail(jobID, fmt.Sprintf("step %d/%d, %d found", i+1, len(centers), len(found)), found, floors, uint64(math.Max(0, lo)), uint64(hi))
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

// dontDisturb matches the daemon's dontDisturbNs.
const dontDisturb = 60 * time.Second

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

// scanDevice picks a radio for a sweep, honouring an explicit id and the range it must hear.
// Caller holds the lock. Mirrors SessionCaptureAllocator: what a capture can hear, not just where
// the tuner can point, so a device whose range is one point still serves a sweep around it.
func (d *Daemon) scanDevice(want string, r *leylinev1.FrequencyRange) *leylinev1.DeviceDescriptor {
	var best *leylinev1.DeviceDescriptor
	for _, x := range d.devices {
		if x == nil || x.State == leylinev1.DeviceState_DISCONNECTED {
			continue
		}
		if want != "" && x.DeviceId != want {
			continue
		}
		if r != nil && !audible(x, r) {
			continue
		}
		if best == nil || x.DeviceId < best.DeviceId {
			best = x
		}
	}
	return best
}

// audible reports whether a capture on this device could hear any of the range.
func audible(dev *leylinev1.DeviceDescriptor, r *leylinev1.FrequencyRange) bool {
	rate := float64(2_400_000)
	if n := len(dev.SampleRates); n > 0 {
		rate = float64(dev.SampleRates[n-1])
	}
	edge := 0.45 * rate
	for _, t := range dev.TuningRanges {
		if float64(t.MinHz)-edge <= float64(r.MaxHz) && float64(t.MaxHz)+edge >= float64(r.MinHz) {
			return true
		}
	}
	return len(dev.TuningRanges) == 0
}

// trimJobsLocked keeps the last keepFinishedJobs finished jobs, as the daemon does: a client that
// loops over scans must not find the fake remembering what the daemon forgot.
func (d *Daemon) trimJobsLocked() {
	var finished []string
	for _, id := range d.jobOrder {
		if j := d.jobs[id]; j != nil && j.proto.State != leylinev1.JobState_RUNNING {
			finished = append(finished, id)
		}
	}
	for len(finished) > keepFinishedJobs {
		drop := finished[0]
		finished = finished[1:]
		delete(d.jobs, drop)
		for i, id := range d.jobOrder {
			if id == drop {
				d.jobOrder = append(d.jobOrder[:i], d.jobOrder[i+1:]...)
				break
			}
		}
	}
}

// keepFinishedJobs matches JobStore.keepFinished.
const keepFinishedJobs = 16

func (d *Daemon) jobCancelled(id string) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	j := d.jobs[id]
	return j == nil || j.proto.State != leylinev1.JobState_RUNNING
}

// setJobDetail also writes what has been found so far into the job's Scan, so a CancelJob that
// lands mid-sweep answers with the part that ran -- which is what the Swift daemon does, and what
// the CLI prints after Ctrl-C.
func (d *Daemon) setJobDetail(id, detail string, found []*leylinev1.Detection, floors []*leylinev1.NoiseFloorSegment, coveredLo, coveredHi uint64) {
	d.mu.Lock()
	defer d.mu.Unlock()
	j := d.jobs[id]
	if j == nil || j.proto.State != leylinev1.JobState_RUNNING {
		return
	}
	j.proto.StatusDetail = detail
	j.scan.Detections = cloneDetections(found)
	j.scan.NoiseFloor = floors
	j.scan.Covered = &leylinev1.FrequencyRange{MinHz: coveredLo, MaxHz: coveredHi}
	for _, det := range found {
		d.publishDetection(det)
	}
	d.emit(nil, j.proto)
}

// keepPartial writes what a stopped sweep found, the way the daemon does: somebody who
// interrupts a scan still wants the part that ran.
func (d *Daemon) keepPartial(id string, found []*leylinev1.Detection, floors []*leylinev1.NoiseFloorSegment, lo, hi uint64) {
	d.mu.Lock()
	defer d.mu.Unlock()
	j := d.jobs[id]
	if j == nil || j.scan == nil {
		return
	}
	j.scan.Detections = cloneDetections(found)
	j.scan.NoiseFloor = floors
	j.scan.Covered = &leylinev1.FrequencyRange{MinHz: lo, MaxHz: hi}
	if j.scan.CompletedAtNs == 0 {
		j.scan.CompletedAtNs = time.Now().UnixNano()
	}
}

func cloneDetections(in []*leylinev1.Detection) []*leylinev1.Detection {
	out := make([]*leylinev1.Detection, len(in))
	for i, d := range in {
		out[i] = proto.Clone(d).(*leylinev1.Detection)
	}
	return out
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
	j.scan.Detections = cloneDetections(found)
	j.scan.NoiseFloor = floors
	j.scan.CompletedAtNs = time.Now().UnixNano()
	j.scan.Gains = []*leylinev1.GainState{{Element: "TUNER", Db: 28.0}}
	j.proto.State = leylinev1.JobState_COMPLETED
	j.proto.StatusDetail = fmt.Sprintf("%d found", len(found))
	d.emit(nil, j.proto)
	d.trimJobsLocked()
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
