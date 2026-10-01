// SPDX-License-Identifier: Apache-2.0

package fakedaemon

import (
	"context"
	"fmt"
	"math"
	"strings"
	"time"

	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
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
	// The decode job's own state: what it is decoding, the channel and capture it holds, the
	// records it has emitted (the last retainedRecords of them, for since_seq replay) and the
	// seq it has reached.
	protocol       string
	hz             uint64
	channelID      string
	captureID      string
	createdCapture bool
	keep           bool
	seq            uint64
	records        []*leylinev1.DecodeRecord
	// cancelled is CancelJob's request to stop. The sweep is what ends the job, so the partial
	// results are stored before the terminal event goes out.
	cancelled bool
	// record is the recording a record job is writing: its directory, its manifest and the
	// schedule its gate follows. Nil for every other kind.
	record *recordJob
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
	if dec, isDecode := req.Config.(*leylinev1.StartJobRequest_Decode); isDecode && dec.Decode != nil {
		return d.startDecode(ctx, dec.Decode)
	}
	if mon, isMon := req.Config.(*leylinev1.StartJobRequest_Monitor); isMon && mon.Monitor != nil {
		return d.startMonitor(ctx, mon.Monitor)
	}
	if r, isRecord := req.Config.(*leylinev1.StartJobRequest_Record); isRecord && r.Record != nil {
		return d.startRecord(ctx, r.Record)
	}
	cfg, ok := req.Config.(*leylinev1.StartJobRequest_Scan)
	if !ok || cfg.Scan == nil {
		if req.Config == nil {
			return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, "", "StartJob needs a config: scan, monitor, decode and record are the ones in v0"))
		}
		return nil, unimplemented(ctx, "Jobs.StartJob(watch)")
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
	// The plan's numbers -- how far each step moves and how finely it looks -- are stamped once
	// the radio is in hand and the geometry exists. A job that never got a radio has none.
	stored := proto.Clone(sc).(*leylinev1.ScanConfig)
	d.jobs[job.JobId] = &fakeJob{proto: job, scan: &leylinev1.Scan{
		ScanId: scanID, Config: stored, StartedAtNs: job.CreatedAtNs,
	}, owner: ci.GetClientId()}
	d.jobOrder = append(d.jobOrder, job.JobId)
	d.trimJobsLocked()
	d.emit(byDaemon(), job)
	// The scan goroutine edits this job under the lock as it runs, so the reply is copied while
	// the lock is still held.
	reply := proto.Clone(job).(*leylinev1.Job)
	d.mu.Unlock()

	go d.runScan(job.JobId, sc, dev)
	return reply, nil
}

// busyReason names who has the radio, or "" when nobody does: the allocator's rule -- no
// channels, no live audio sink, and nobody tuning it in the last minute. Caller holds the lock.
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
			d.failScan(jobID, leyline.CodeNoDevice, sc.DeviceId+" cannot tune that range, or is not here")
		} else {
			d.failScan(jobID, leyline.CodeNoDevice, "no radio here can tune that range")
		}
		return
	}
	rate := uint64(2_400_000)
	if len(dev.SampleRates) > 0 {
		rate = dev.SampleRates[len(dev.SampleRates)-1]
	}
	// The fake does not wait out a real dwell, so tests stay fast, but each step still yields
	// the number of looks the daemon would take at this dwell and rate.
	dwellMs := float64(sc.DwellMs)
	if dwellMs <= 0 {
		dwellMs = defaultDwellMs
	}
	sleep := time.Duration(sc.DwellMs) * time.Millisecond
	if sleep <= 0 {
		sleep = 20 * time.Millisecond
	}
	if sleep > 200*time.Millisecond {
		sleep = 200 * time.Millisecond
	}
	d.mu.Lock()
	reason := ""
	if !sc.TakeOver {
		reason = d.busyReason(dev.DeviceId)
	}
	if reason == "" && d.sweeping != "" {
		reason = "another scan already has " + d.devices[d.sweeping].GetModel()
	}
	sweepCapture := ""
	if reason == "" {
		d.sweeping = dev.DeviceId
		// Only a sweep that actually starts opens a new dedup epoch: a declined second scan that
		// reset it would have the running one re-report carriers it has already published.
		d.detectionEpoch = len(d.detectionLog)
		// The capture the sweep listens on, so a telemetry subscriber scoped to another radio is
		// not shown this one's detections. The daemon's lease always has one; the fake borrows the
		// capture already on the device, and reports no capture when there is none.
		for _, c := range d.captures {
			if c.DeviceId == dev.DeviceId {
				sweepCapture = c.CaptureId
			}
		}
	}
	d.mu.Unlock()
	if reason != "" {
		d.failScan(jobID, leyline.CodeDeviceBusy, reason)
		return
	}
	defer func() {
		d.mu.Lock()
		d.sweeping = ""
		d.mu.Unlock()
	}()
	// The radio is in hand, so now the geometry: where the steps go, and which parts of each span
	// the detector uses.
	plan := planSweep(sc.Range.MinHz, sc.Range.MaxHz, rate, dev.TuningRanges)
	if plan == nil {
		d.failScan(jobID, leyline.CodeFreqOutOfRange, "this radio cannot tune any of that range")
		return
	}
	if plan.analysedHz() == 0 {
		// Every window missed the request, which happens when the whole of it sits in one step's
		// DC guard: a radio with a single tuning point has no neighbouring step to cover its hole.
		centre := sc.Range.MinHz
		if len(plan.steps) > 0 {
			centre = plan.steps[0].centerHz
		}
		d.failScan(jobID, leyline.CodeBlindSpot, fmt.Sprintf(
			"all of that range sits within %s of %s, where this radio's own DC spike is; a scan does not look there",
			leyline.FormatFrequency(uint64(guardFraction*float64(rate))), leyline.FormatFrequency(centre)))
		return
	}
	d.planScan(jobID, plan, rate)
	gains, gerr := d.sweepGains(dev, sc)
	if gerr != nil {
		d.failScan(jobID, leyline.CodeGainElementUnknown, gerr.Error())
		return
	}
	// Rows the dwell is meant to yield, fixed up front the way the daemon fixes its threshold:
	// each row is one chance a signal has to appear, so this is what looks are counted in.
	rows := uint32(max(2, int(dwellMs/rowIntervalMs(rate))))
	lo, hi := plan.covered.lo, plan.covered.hi
	started := time.Now()
	var found []*leylinev1.Detection
	var floors []*leylinev1.NoiseFloorSegment
	for i, step := range plan.steps {
		if d.jobCancelled(jobID) {
			d.stopScan(jobID, found, floors, gains, lo, hi, i, len(plan.steps))
			return
		}
		time.Sleep(sleep)
		seen := d.sweepSample(sweepCapture, rate, started)
		for _, w := range []sweepWindow{step.low, step.high} {
			for _, sig := range fakeCarriers {
				if !w.contains(sig.hz) || sig.hz < lo || sig.hz >= hi {
					continue
				}
				at := &leylinev1.SampleTime{CaptureId: sweepCapture, SampleIndex: seen}
				found = mergeDetection(found, &leylinev1.Detection{
					DetectionId: fmt.Sprintf("det_%d", sig.hz),
					CaptureId:   sweepCapture,
					CenterHz:    sig.hz,
					BandwidthHz: sig.bw,
					SnrDb:       sig.snr,
					FloorDbfs:   fakeFloorDbfs,
					// A synthetic carrier is on for the whole dwell, so every row of the step
					// that covered it found it.
					Looks:         rows,
					LooksPossible: rows,
					FirstSeen:     at,
					LastSeen:      at,
				})
			}
		}
		floors = append(floors, &leylinev1.NoiseFloorSegment{
			Range:     &leylinev1.FrequencyRange{MinHz: step.low.lo, MaxHz: step.high.hi},
			FloorDbfs: fakeFloorDbfs,
		})
		d.setJobDetail(jobID, fmt.Sprintf("step %d/%d, %d found", i+1, len(plan.steps), len(found)), found, floors, lo, hi)
	}
	// Every row of every step whose window covered this frequency was a chance the signal had to
	// appear, whether or not that step found it.
	for _, det := range found {
		if chances := rows * uint32(plan.looksAt(det.CenterHz)); chances > det.LooksPossible {
			det.LooksPossible = chances
		}
	}
	d.finishScan(jobID, found, floors, gains, len(plan.steps), len(plan.steps), plan.clipped)
}

// fakeCarriers is the synthetic band the fake daemon reports: what a scan finds, and what a
// channel tuned to one of them hears. They are not derived from the fake FFT: the CLI test
// checks the table, not the DSP.
//
// tone is the CTCSS tone the transmitter sends, or 0 for a frequency that carries none -- 146.52
// is the national calling channel, where a PL tone would be wrong.
var fakeCarriers = []struct {
	hz   uint64
	bw   uint32
	snr  float64
	tone float64
}{
	{145_230_000, 11_400, 21.4, 100.0},
	{146_520_000, 11_900, 34.2, 0},
	{146_940_000, 12_100, 18.7, 123.0},
	{162_400_000, 11_800, 12.0, 0},
	{101_100_000, 198_000, 41.5, 0},
}

// carrierAt is the fake carrier a channel at hz is sitting on: its own frequency and its CTCSS
// tone, 0 when it is sent in the clear.
func carrierAt(hz uint64) (carrierHz uint64, tone float64, ok bool) {
	for _, sig := range fakeCarriers {
		half := uint64(sig.bw / 2)
		if hz+half >= sig.hz && hz <= sig.hz+half {
			return sig.hz, sig.tone, true
		}
	}
	return 0, 0, false
}

// subTone is what the carrier a channel at hz is sitting on sends below the voice: its CTCSS
// tone, or the DCS code Options.DCS puts on it in its place. A DCS carrier reports no CTCSS tone,
// as the daemon suppresses the CTCSS claim while DCS is locked (docs/plans/signal-views.md, SV-7).
func (d *Daemon) subTone(hz uint64) (tone float64, code *DCSCode) {
	at, tone, ok := carrierAt(hz)
	if !ok {
		return 0, nil
	}
	if c, ok := d.opts.DCS[at]; ok {
		return 0, &c
	}
	return tone, nil
}

const fakeFloorDbfs = -88.2

// defaultDwellMs is the dwell the daemon applies when a scan asks for none.
const defaultDwellMs = 250

// rowIntervalMs is how long one analysis row takes at this capture rate. The ladder takes at most
// one look per block, so the row rate is chosen to fit the looks a row averages, and the dwell
// divided by this is how many rows -- how many chances -- a step gets.
func rowIntervalMs(rate uint64) float64 {
	const blockSize, targetLooks = 16384, 16
	rows := math.Max(0.5, float64(rate)/blockSize/targetLooks)
	return 1000 / rows
}

// sweepGains is what the sweep froze the tuner at. AGC is pinned for the duration -- SNR measured
// against a moving reference is meaningless -- and where it was pinned is part of the answer,
// because a scan without its gain is not comparable with another. The requested gains pin their
// elements, in order (`gains`, else `gain`: jobs.proto, ScanConfig): an empty element is the
// first, a name matches ignoring case, and auto pins where the fake's AGC "settles", the middle
// of the table. Otherwise an element already on a fixed level keeps it, and an automatic one is
// pinned at the middle of its table, which is what the allocator falls back to when the driver
// will not say where AGC settled. An element the device does not have fails the sweep with the
// ones it has, as the daemon's GAIN_ELEMENT_UNKNOWN does.
func (d *Daemon) sweepGains(dev *leylinev1.DeviceDescriptor, sc *leylinev1.ScanConfig) ([]*leylinev1.GainState, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	wants := sc.GetGains()
	if len(wants) == 0 && sc.GetGain() != nil {
		wants = []*leylinev1.GainWrite{sc.GetGain()}
	}
	asked := map[string]*leylinev1.GainWrite{}
	for _, w := range wants {
		name := w.GetElement()
		if name == "" && len(dev.GainElements) > 0 {
			name = dev.GainElements[0].Name
		}
		var el *leylinev1.GainElement
		for _, e := range dev.GainElements {
			if strings.EqualFold(e.Name, name) {
				el = e
			}
		}
		if el == nil {
			return nil, fmt.Errorf("the gain asked for could not be set: %s", unknownGainElement(w.GetElement(), dev, "").Message)
		}
		if w.GetValue() != nil {
			asked[el.Name] = w
		}
	}
	var out []*leylinev1.GainState
	for _, el := range dev.GainElements {
		g := &leylinev1.GainState{Element: el.Name, Db: leyline.SnapGain(el, el.MaxDb/2)}
		for _, c := range d.captures {
			if c.DeviceId == dev.DeviceId {
				for _, have := range c.Gains {
					if have.Element == el.Name {
						g = proto.Clone(have).(*leylinev1.GainState)
					}
				}
			}
		}
		if want := asked[el.Name]; want != nil {
			switch v := want.GetValue().(type) {
			case *leylinev1.GainWrite_Db:
				g = &leylinev1.GainState{Element: el.Name, Db: leyline.SnapGain(el, v.Db)}
			case *leylinev1.GainWrite_Auto:
				if v.Auto {
					g = &leylinev1.GainState{Element: el.Name, Auto: true}
				}
			}
		}
		if g.Auto {
			g.Auto = false
			if n := len(el.ValidDb); n > 0 {
				g.Db = el.ValidDb[n/2]
			} else {
				g.Db = (el.MinDb + el.MaxDb) / 2
			}
		}
		out = append(out, g)
	}
	return out, nil
}

// sweepSample is the sample position a detection is timed at: the capture's own clock when the
// sweep borrowed one, and otherwise the samples that have gone by since it started, so a
// detection carries a timebase either way.
func (d *Daemon) sweepSample(captureID string, rate uint64, started time.Time) uint64 {
	now := time.Now()
	d.mu.Lock()
	defer d.mu.Unlock()
	if c := d.captures[captureID]; c != nil {
		return c.sampleIndex(now)
	}
	return uint64(now.Sub(started).Seconds() * float64(rate))
}

// dontDisturb matches the daemon's dontDisturbNs.
const dontDisturb = 60 * time.Second

// mergeDetection folds a step's reading into what the sweep has found so far: the same carrier
// seen from another tuner position is one detection with more looks behind it, spanning from when
// it was first seen to when it was last.
func mergeDetection(list []*leylinev1.Detection, d *leylinev1.Detection) []*leylinev1.Detection {
	for _, x := range list {
		if x.CenterHz == d.CenterHz {
			x.Looks += d.Looks
			x.LooksPossible += d.LooksPossible
			if d.GetFirstSeen().GetSampleIndex() < x.GetFirstSeen().GetSampleIndex() {
				x.FirstSeen = d.FirstSeen
			}
			if d.GetLastSeen().GetSampleIndex() > x.GetLastSeen().GetSampleIndex() {
				x.LastSeen = d.LastSeen
			}
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
// loops over scans must see the same job list from the fake as from the daemon.
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
	return j == nil || j.cancelled || j.proto.State != leylinev1.JobState_RUNNING
}

// scanBins is how many bins a sweep step looks through, as ScanRunner does: the resolution every
// dB in a Scan is quoted per.
const scanBins = 1024

// planScan stamps the geometry on the job's Scan and says the sweep is under way. The daemon does
// both once the lease is in hand, so a job that never got a radio carries neither.
func (d *Daemon) planScan(id string, plan *sweepPlan, rate uint64) {
	d.mu.Lock()
	defer d.mu.Unlock()
	j := d.jobs[id]
	if j == nil || j.proto.State != leylinev1.JobState_RUNNING {
		return
	}
	// The advance the geometry uses, stated rather than measured off the step positions.
	j.scan.Config.StepHz = uint32(math.Round((edgeFraction - guardFraction) * float64(rate)))
	// How finely it looked, so a client can print a floor without knowing the geometry.
	j.scan.ResolutionHz = uint32(math.Round(float64(rate) / scanBins))
	steps := "1 step"
	if len(plan.steps) != 1 {
		steps = fmt.Sprintf("%d steps", len(plan.steps))
	}
	j.proto.StatusDetail = "sweeping " + steps
	d.emit(byDaemon(), j.proto)
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
	d.emit(byDaemon(), j.proto)
}

// stopScan ends an interrupted sweep: what it found is written first and the terminal event goes
// out last, so a client that calls GetScan when it sees CANCELLED reads the part that ran rather
// than an empty scan. The daemon stores and then finishes for the same reason.
func (d *Daemon) stopScan(id string, found []*leylinev1.Detection, floors []*leylinev1.NoiseFloorSegment,
	gains []*leylinev1.GainState, lo, hi uint64, stepsDone, steps int,
) {
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
	j.scan.Gains = gains
	if j.proto.State != leylinev1.JobState_RUNNING {
		return
	}
	j.proto.State = leylinev1.JobState_CANCELLED
	// The step it was in, not the ones it finished: "0 of 1" reads as having done nothing, when a
	// partial step can have found everything there was.
	j.proto.StatusDetail = fmt.Sprintf("stopped in step %d of %d, %d found", min(stepsDone+1, steps), steps, len(found))
	d.emit(byDaemon(), j.proto)
	d.trimJobsLocked()
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
	// A job that ends any way but completed has finished looking, and its Scan says when: a
	// client that reads a terminal job must not find a scan that looks like it is still running.
	if j.scan != nil {
		j.scan.CompletedAtNs = time.Now().UnixNano()
	}
	j.proto.State = leylinev1.JobState_FAILED
	// The daemon splits the two: prose in status_detail, the stable code in error.
	j.proto.StatusDetail = reason
	j.proto.Error = &leylinev1.ErrorDetail{Code: code, Message: reason, Target: id}
	d.emit(byDaemon(), j.proto)
}

// completedDetail is what a sweep that ran to the end says about itself: how many carriers it
// found and over how many steps, whether the range had to be clipped to what the radio can tune,
// and how many steps saw too few rows to be reliable and were left out of the coverage.
func completedDetail(found, stepsDone, steps int, clipped bool) string {
	if stepsDone < steps {
		return fmt.Sprintf("%d found; %d of %d steps saw too few rows to trust and were left out",
			found, steps-stepsDone, steps)
	}
	plural := fmt.Sprintf("%d steps", steps)
	if steps == 1 {
		plural = "1 step"
	}
	if clipped {
		return fmt.Sprintf("%d found in %s, clipped to what the radio can tune", found, plural)
	}
	return fmt.Sprintf("%d found in %s", found, plural)
}

func (d *Daemon) finishScan(id string, found []*leylinev1.Detection, floors []*leylinev1.NoiseFloorSegment, gains []*leylinev1.GainState, stepsDone, steps int, clipped bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	j := d.jobs[id]
	if j == nil || j.proto.State != leylinev1.JobState_RUNNING {
		return
	}
	j.scan.Detections = cloneDetections(found)
	j.scan.NoiseFloor = floors
	j.scan.CompletedAtNs = time.Now().UnixNano()
	j.scan.Gains = gains
	j.proto.State = leylinev1.JobState_COMPLETED
	j.proto.StatusDetail = completedDetail(len(found), stepsDone, steps, clipped)
	d.emit(byDaemon(), j.proto)
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
	d.touchUnary(clientFrom(ctx))
	d.mu.Lock()
	j := d.jobs[req.JobId]
	if j == nil {
		d.mu.Unlock()
		return nil, fail(ctx, errorf(leyline.CodeJobNotFound, req.JobId, "no such job"))
	}
	// A job that has already ended is answered as it stands: asking a finished sweep to stop
	// changes nothing about it, not even the flag its goroutine is no longer reading.
	running := j.proto.State == leylinev1.JobState_RUNNING
	if running {
		j.cancelled = true
	}
	d.mu.Unlock()
	if running {
		d.awaitStopped(ctx, req.JobId)
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	j = d.jobs[req.JobId]
	if j == nil {
		return nil, fail(ctx, errorf(leyline.CodeJobNotFound, req.JobId, "no such job"))
	}
	// The sweep did not stop within the wait: answer cancelled anyway. A stale answer
	// is better than an RPC that never returns, and the goroutine still ends on its own.
	if j.proto.State == leylinev1.JobState_RUNNING {
		j.proto.State = leylinev1.JobState_CANCELLED
		j.proto.StatusDetail = "cancelled"
		d.emit(byDaemon(), j.proto)
	}
	return proto.Clone(j.proto).(*leylinev1.Job), nil
}

// awaitStopped waits for a sweep to reach a terminal state after it has been asked to stop, so
// CancelJob answers with the partial scan already stored, as JobStore.cancel does. Bounded: a job
// whose sweep is wedged still answers.
func (d *Daemon) awaitStopped(ctx context.Context, id string) {
	deadline := time.Now().Add(cancelWait)
	for time.Now().Before(deadline) {
		if d.jobStopped(id) {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(5 * time.Millisecond):
		}
	}
}

func (d *Daemon) jobStopped(id string) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	j := d.jobs[id]
	return j == nil || j.proto.State != leylinev1.JobState_RUNNING
}

// cancelWait matches JobStore.cancelWaitSeconds. The fake's dwell is capped at 200 ms, so a sweep
// that is running notices well inside it.
const cancelWait = 3 * time.Second

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

// Resources lives in resources.go, over the manifests record jobs write.
