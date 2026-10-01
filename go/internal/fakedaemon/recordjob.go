// SPDX-License-Identifier: Apache-2.0

package fakedaemon

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// Record jobs in the fake are real: they write real WAV or cf32 files with real
// sidecars and a real manifest into RecordingsDir, so `ley record`, `ley
// recordings`, `ley recordings path` and `ley play` on a URI are tested end to
// end here before they meet the Swift daemon. The signal is a synthetic tone
// rather than a demodulated radio; everything about the files, the parts, the
// gate and the manifest is the shape the daemon writes
// (docs/design/recording.md, "Testing without hardware").

// fakeAudioRate is the audio rate a fake recording is written at, matching the
// 48 kHz a 2.4 MSPS capture decimates to.
const fakeAudioRate = 48000

// fakeRecordTick is how often the fake advances a recording. Short enough that
// a test asking for a second of audio does not wait a second for every write.
const fakeRecordTick = 50 * time.Millisecond

// recordJob is the fake's side of a running recording: where it is writing and
// how far it has got.
type recordJob struct {
	dir      string
	manifest *leyline.RecordingManifest
	// gateAt is the schedule the fake's squelch opens and closes on, in
	// milliseconds from the start of the recording, alternating open, close,
	// open, ... Empty means the gate opens at once and stays open.
	gateAt []int64
}

// startRecord is Jobs.StartJob(record) in the fake. The refusals the daemon
// answers synchronously are answered synchronously here too, with the same
// codes and the same sentences, so a client exercises the same paths.
func (d *Daemon) startRecord(ctx context.Context, cfg *leylinev1.RecordConfig) (*leylinev1.Job, error) {
	if cfg.GetStartAtNs() != 0 {
		return nil, fail(ctx, errorf(leyline.CodeUnimplemented, "", "a recording scheduled for later is not implemented in v0"))
	}
	iq := cfg.GetMode() == leylinev1.DemodMode_RAW_IQ
	gated := cfg.GetGate() == leylinev1.RecordGate_SQUELCH
	if gated && iq {
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, "",
			"a squelch gate needs a channel's squelch, and an IQ recording has no channel; record audio, or record IQ continuously"))
	}
	if cfg.GetStopAfterQuietMs() != 0 && !gated {
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, "",
			"stop-after-quiet needs a squelch gate: without one nothing is watching the squelch"))
	}
	ci := clientFrom(ctx)
	d.touchUnary(ci)

	d.mu.Lock()
	hz := cfg.GetFrequencyHz()
	var lease channelLease
	if chID := cfg.GetChannelId(); chID != "" {
		ch := d.channels[chID]
		if ch == nil {
			d.mu.Unlock()
			return nil, fail(ctx, errorf(leyline.CodeChannelNotFound, chID, "no channel called "+quoted(chID)+" is open"))
		}
		if gated && math.IsNaN(ch.GetSquelchDb()) {
			d.mu.Unlock()
			return nil, fail(ctx, errorf(leyline.CodeFailedPrecondition, chID,
				"squelch is off on "+chID+"; set one with ley set squelch"))
		}
		c := d.captures[ch.GetCaptureId()]
		lease = channelLease{channelID: chID, captureID: ch.GetCaptureId(), deviceID: c.GetDeviceId()}
		hz = uint64(int64(c.GetCenterHz()) + ch.GetOffsetHz())
	} else {
		// The allocator's own path, borrowed from a decode job: it wants one channel at a
		// frequency and does not care which radio serves it.
		var err *leyline.Error
		lease, err = d.leaseChannelLocked(ci, &leylinev1.DecodeConfig{
			DeviceId: cfg.GetDeviceId(), TakeOver: cfg.GetTakeOver(),
		}, hz, recordBandwidth(cfg), cfg.GetMode())
		if err != nil {
			d.mu.Unlock()
			return nil, fail(ctx, err)
		}
	}
	// The gain the request asked for, on the capture the lease made; a borrowed channel is left
	// as its owner set it. An empty element is the first the device lists, and a refusal fails
	// the job with the radio's reason, as the daemon's record path does.
	// `gains` wins over `gain` when both are sent (jobs.proto, RecordConfig), and the writes land
	// in order; the stages set before a refusal stay set, as on the radio.
	var gainErr *leyline.Error
	writes := cfg.GetGains()
	if len(writes) == 0 && cfg.GetGain() != nil {
		writes = []*leylinev1.GainWrite{cfg.GetGain()}
	}
	if c := d.captures[lease.captureID]; cfg.GetChannelId() == "" && c != nil && len(writes) > 0 {
		for _, w := range writes {
			if gainErr = d.applyGainLocked(c, d.devices[c.GetDeviceId()], w, lease.captureID); gainErr != nil {
				break
			}
		}
		d.emit(byDaemon(), c.Capture)
	}
	job := &leylinev1.Job{
		JobId:        newID("job_"),
		State:        leylinev1.JobState_RUNNING,
		CreatedAtNs:  time.Now().UnixNano(),
		CreatedBy:    ci,
		Config:       &leylinev1.Job_Record{Record: proto.Clone(cfg).(*leylinev1.RecordConfig)},
		StatusDetail: "starting",
	}
	job.ResultUris = []string{leyline.RecordingURI(job.JobId)}
	fj := &fakeJob{
		proto: job, owner: ci.GetClientId(), hz: hz,
		channelID: lease.channelID, captureID: lease.captureID, createdCapture: lease.created,
		// A recording outlives the client that started it, exactly as a kept decode job does.
		keep: true,
	}
	if gainErr != nil {
		// The daemon answers with the running job and fails it from the job's task, once the
		// allocation it waited on has returned; the fake does the same a tick later.
		d.jobs[job.JobId] = fj
		d.jobOrder = append(d.jobOrder, job.JobId)
		d.trimJobsLocked()
		d.emit(byDaemon(), job)
		reply := proto.Clone(job).(*leylinev1.Job)
		d.mu.Unlock()
		go d.failRecord(job.JobId, gainErr.Code, "the gain asked for could not be set: "+gainErr.Message)
		return reply, nil
	}
	rec, err := d.openRecordingLocked(fj, cfg, hz, iq, gated)
	if err != nil {
		d.mu.Unlock()
		return nil, fail(ctx, errorf(leyline.CodeInternal, "", err.Error()))
	}
	fj.record = rec
	d.jobs[job.JobId] = fj
	d.jobOrder = append(d.jobOrder, job.JobId)
	d.trimJobsLocked()
	d.emit(byDaemon(), job)
	reply := proto.Clone(job).(*leylinev1.Job)
	d.mu.Unlock()

	go d.runRecord(job.JobId)
	return reply, nil
}

// recordBandwidth is the channel width the recording asks for, or the mode's own.
func recordBandwidth(cfg *leylinev1.RecordConfig) uint32 {
	if bw := cfg.GetBandwidthHz(); bw != 0 {
		return bw
	}
	switch cfg.GetMode() {
	case leylinev1.DemodMode_WFM:
		return 200_000
	case leylinev1.DemodMode_AM:
		return 10_000
	case leylinev1.DemodMode_USB, leylinev1.DemodMode_LSB:
		return 2_800
	case leylinev1.DemodMode_CW:
		return 500
	}
	return 12_500
}

// openRecordingLocked makes the recording's directory and its first manifest.
// Caller holds the lock.
func (d *Daemon) openRecordingLocked(j *fakeJob, cfg *leylinev1.RecordConfig, hz uint64, iq, gated bool) (*recordJob, error) {
	root := d.opts.RecordingsDir
	if root == "" {
		root = filepath.Join(os.TempDir(), "leyline-fake-recordings")
	}
	dir := filepath.Join(root, j.proto.GetJobId())
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	c := d.captures[j.captureID]
	m := &leyline.RecordingManifest{
		JobID:       j.proto.GetJobId(),
		URI:         leyline.RecordingURI(j.proto.GetJobId()),
		Kind:        recordKind(iq),
		FrequencyHz: hz,
		Mode:        recordModeName(cfg.GetMode(), iq),
		BandwidthHz: recordBandwidth(cfg),
		SampleRate:  fakeAudioRate,
		Format:      "wav-s16",
		PartMs:      cfg.GetPartMs(),
		StartedAtNS: time.Now().UnixNano(),
		CreatedBy: &leyline.RecordingClient{
			ClientID: j.proto.GetCreatedBy().GetClientId(),
			Kind:     j.proto.GetCreatedBy().GetKind(),
			Label:    j.proto.GetCreatedBy().GetLabel(),
		},
		Parts: []leyline.RecordingPart{},
	}
	if iq {
		m.Format = "cf32"
		m.SampleRate = c.GetSampleRate()
		m.FrequencyHz = c.GetCenterHz()
		if m.PartMs == 0 {
			m.PartMs = 60_000
		}
	}
	if gated {
		m.Gate = &leyline.RecordingGate{
			Kind:      "squelch",
			PreRollMs: defaultUint32(cfg.GetPreRollMs(), 500),
			HangMs:    defaultUint32(cfg.GetHangMs(), 5000),
		}
		// 0 and NaN both ask a gated recording for the channel default, as the daemon reads them.
		db := cfg.GetSquelchDbfs()
		if db == 0 || math.IsNaN(db) {
			db = -80
		}
		m.SquelchDBFS = &db
	}
	if dev := d.devices[c.GetDeviceId()]; dev != nil {
		m.Device = &leyline.RecordingDevice{Driver: dev.GetDriver(), Model: dev.GetModel(), Serial: dev.GetSerial()}
	}
	// The gains the take starts at, each stage set by hand; the daemon leaves a stage on auto out,
	// because it has no level to write down.
	for _, g := range c.GetGains() {
		if !g.GetAuto() {
			m.Gains = append(m.Gains, leyline.RecordingGain{Element: g.GetElement(), ValueDB: g.GetDb()})
		}
	}
	if a := c.GetAnchor(); a != nil {
		m.Anchors = []leyline.RecordingAnchor{{
			CaptureID: a.GetCaptureId(), HostTimeNS: a.GetHostTimeNs(),
			SampleRate: a.GetSampleRate(), DriftPPM: a.GetDriftPpm(),
		}}
	}
	rec := &recordJob{dir: dir, manifest: m, gateAt: d.opts.RecordGateAt}
	if err := writeManifest(rec); err != nil {
		return nil, err
	}
	return rec, nil
}

func recordKind(iq bool) string {
	if iq {
		return "iq"
	}
	return "audio"
}

func recordModeName(mode leylinev1.DemodMode, iq bool) string {
	if iq {
		return ""
	}
	if mode == leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED {
		mode = leylinev1.DemodMode_NFM
	}
	return strings.ToUpper(leyline.ModeName(mode))
}

func defaultUint32(v, def uint32) uint32 {
	if v == 0 {
		return def
	}
	return v
}

// runRecord advances the recording until its duration elapses or it is
// cancelled, opening and closing parts the way the gate would.
func (d *Daemon) runRecord(jobID string) {
	started := time.Now()
	var partOpen bool
	var partStartMs int64
	for {
		time.Sleep(fakeRecordTick)
		elapsed := time.Since(started).Milliseconds()
		if d.jobCancelled(jobID) {
			// A part open at the cancel is closed with what it holds, as the daemon's teardown
			// closes it, so a cancelled recording is complete.
			if partOpen {
				d.mu.Lock()
				if j := d.jobs[jobID]; j != nil && j.record != nil {
					j.record.closePart(partStartMs, elapsed, d.clippingLocked(j.captureID))
				}
				d.mu.Unlock()
			}
			d.finishRecord(jobID, leylinev1.JobState_CANCELLED, "cancelled")
			return
		}
		d.mu.Lock()
		j := d.jobs[jobID]
		if j == nil || j.record == nil || j.proto.State != leylinev1.JobState_RUNNING {
			d.mu.Unlock()
			return
		}
		cfg := j.proto.GetRecord()
		rec := j.record
		clipped := d.clippingLocked(j.captureID)
		want := rec.wantsPart(elapsed)
		switch {
		case want && !partOpen:
			partOpen, partStartMs = true, elapsed
		case !want && partOpen:
			partOpen = false
			rec.closePart(partStartMs, elapsed, clipped)
		}
		j.proto.StatusDetail = fmt.Sprintf("recording %s: %s, %d part%s, %d KB",
			rec.manifest.Kind, forSeconds(elapsed), rec.parts(partOpen), plural(rec.parts(partOpen)), rec.kb(partOpen, elapsed-partStartMs))
		done := cfg.GetDurationMs() > 0 && elapsed >= cfg.GetDurationMs()
		if done && partOpen {
			partOpen = false
			rec.closePart(partStartMs, elapsed, clipped)
		}
		d.emit(byDaemon(), proto.Clone(j.proto).(*leylinev1.Job))
		d.mu.Unlock()
		if done {
			d.finishRecord(jobID, leylinev1.JobState_COMPLETED, "duration")
			return
		}
	}
}

// wantsPart reports whether the gate would have a part open at this point.
func (r *recordJob) wantsPart(elapsedMs int64) bool {
	if r.manifest.Gate == nil {
		return true
	}
	if len(r.gateAt) == 0 {
		return true
	}
	open := false
	for _, at := range r.gateAt {
		if elapsedMs >= at {
			open = !open
			continue
		}
		break
	}
	return open
}

func (r *recordJob) parts(partOpen bool) int {
	n := len(r.manifest.Parts)
	if partOpen {
		n++
	}
	return n
}

func (r *recordJob) kb(partOpen bool, openMs int64) uint64 {
	total := r.manifest.Bytes
	if partOpen && openMs > 0 {
		total += uint64(openMs) * fakeAudioRate * 2 / 1000
	}
	return total / 1024
}

// clippingLocked reports whether the capture's CaptureLevel is over the
// window's 1e-4 clipping floor, from Options.Clipping, which is what the fake's
// telemetry reports too. Caller holds the lock.
func (d *Daemon) clippingLocked(captureID string) bool {
	if d.opts.Clipping == nil {
		return false
	}
	clipped, total, _ := d.opts.Clipping(captureID)
	return total > 0 && float64(clipped)/float64(total) >= 1e-4
}

// closePart writes the part's samples, its sidecar and the manifest, exactly as
// the daemon's PartWriter does: a synthetic 1 kHz tone at the recording's rate.
// clipped charges the whole part to clipped_ms: the fake's level does not vary
// over a part, so every reading inside it clipped or none did.
func (r *recordJob) closePart(startMs, endMs int64, clipped bool) {
	if endMs <= startMs {
		return
	}
	m := r.manifest
	n := int(float64(endMs-startMs) / 1000 * float64(m.SampleRate))
	if n <= 0 {
		return
	}
	part := len(m.Parts) + 1
	name := fmt.Sprintf("%s_%.3fMHz_%s_%03d", time.Now().Format("2006-01-02_15-04-05"),
		float64(m.FrequencyHz)/1e6, partTag(m), part)
	var data []byte
	if m.Format == "cf32" {
		data = fakeCF32(n)
		name += ".cf32"
	} else {
		data = fakeWAV(n, m.SampleRate)
		name += ".wav"
	}
	if err := os.WriteFile(filepath.Join(r.dir, name), data, 0o644); err != nil {
		return
	}
	peak, mean := -6.0, -9.0
	// The samples are on the capture's timeline, at the capture rate the anchor names.
	rate := m.SampleRate
	if len(m.Anchors) > 0 && m.Anchors[0].SampleRate > 0 {
		rate = m.Anchors[0].SampleRate
	}
	entry := leyline.RecordingPart{
		Part: part, File: name,
		StartSample: uint64(float64(startMs) / 1000 * float64(rate)),
		EndSample:   uint64(float64(endMs) / 1000 * float64(rate)),
		Samples:     uint64(n), Bytes: uint64(len(data)),
		PeakDBFS: &peak, MeanDBFS: &mean,
	}
	if m.Gate != nil {
		entry.SquelchOpens = 1
	}
	if clipped {
		entry.ClippedMs = endMs - startMs
	}
	// A gated recording's gaps are stated rather than hidden inside a file.
	if last := len(m.Parts) - 1; last >= 0 && m.Parts[last].EndSample < entry.StartSample {
		m.Gaps = append(m.Gaps, leyline.RecordingGap{
			FromSample: m.Parts[last].EndSample, ToSample: entry.StartSample, Reason: "squelch closed",
		})
	}
	m.Parts = append(m.Parts, entry)
	m.Bytes += entry.Bytes
	writePartSidecar(r, entry)
	_ = writeManifest(r)
}

func partTag(m *leyline.RecordingManifest) string {
	if m.Kind == "iq" {
		return "IQ"
	}
	if m.Mode == "" {
		return "REC"
	}
	return m.Mode
}

// failRecord ends a record job that never started writing: the channel and any capture it made
// go back, and the job is FAILED with the reason in status_detail and the code in error.
func (d *Daemon) failRecord(jobID, code, reason string) {
	time.Sleep(fakeRecordTick)
	d.mu.Lock()
	defer d.mu.Unlock()
	j := d.jobs[jobID]
	if j == nil || j.proto.State != leylinev1.JobState_RUNNING {
		return
	}
	by := &leylinev1.ClientInfo{ClientId: "daemon", Kind: "job", Label: "record"}
	if j.channelID != "" && j.proto.GetRecord().GetChannelId() == "" {
		d.destroyChannelLocked(j.channelID, by)
		j.channelID = ""
	}
	if j.createdCapture && j.captureID != "" {
		d.destroyCaptureLocked(j.captureID, by)
		j.createdCapture = false
	}
	j.proto.State = leylinev1.JobState_FAILED
	j.proto.StatusDetail = reason
	j.proto.Error = &leylinev1.ErrorDetail{Code: code, Message: reason, Target: jobID}
	d.emit(byDaemon(), proto.Clone(j.proto).(*leylinev1.Job))
	d.trimJobsLocked()
}

// finishRecord ends the job: the channel and any capture it made go back, the
// manifest says how it ended, and the terminal Job event goes out last.
func (d *Daemon) finishRecord(jobID string, state leylinev1.JobState, endedBy string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	j := d.jobs[jobID]
	if j == nil {
		return
	}
	by := &leylinev1.ClientInfo{ClientId: "daemon", Kind: "job", Label: "record"}
	if j.channelID != "" && j.proto.GetRecord().GetChannelId() == "" {
		d.destroyChannelLocked(j.channelID, by)
		j.channelID = ""
	}
	if j.createdCapture && j.captureID != "" {
		d.destroyCaptureLocked(j.captureID, by)
		j.createdCapture = false
	}
	heardNothing := false
	if rec := j.record; rec != nil {
		rec.manifest.EndedBy = endedBy
		rec.manifest.EndedAtNS = time.Now().UnixNano()
		_ = writeManifest(rec)
		// A recording with no part has nothing to hear and is not kept: the directory goes,
		// and the URI the job still names resolves to JOB_NOT_FOUND, as the daemon does it
		// (docs/design/recording.md, "Nothing heard").
		if len(rec.manifest.Parts) == 0 {
			heardNothing = true
			_ = os.RemoveAll(rec.dir)
			j.record = nil
		}
	}
	if j.proto.State != leylinev1.JobState_RUNNING {
		return
	}
	j.proto.State = state
	j.proto.StatusDetail = fmt.Sprintf("recorded %s in %s",
		forSeconds(recordedMs(j.record)), partsPhrase(j.record))
	if heardNothing {
		// Cancelled or not, the job did what it was asked and nothing was on the air.
		j.proto.State = leylinev1.JobState_COMPLETED
		j.proto.StatusDetail = leyline.NothingHeard
	}
	d.emit(byDaemon(), proto.Clone(j.proto).(*leylinev1.Job))
	d.trimJobsLocked()
}

func recordedMs(r *recordJob) int64 {
	if r == nil || r.manifest.SampleRate == 0 {
		return 0
	}
	var samples uint64
	for _, p := range r.manifest.Parts {
		samples += p.Samples
	}
	return int64(float64(samples) / float64(r.manifest.SampleRate) * 1000)
}

func partsPhrase(r *recordJob) string {
	n := 0
	if r != nil {
		n = len(r.manifest.Parts)
	}
	if n == 1 {
		return "1 part"
	}
	return fmt.Sprintf("%d parts", n)
}

func forSeconds(ms int64) string {
	s := float64(ms) / 1000
	if s < 60 {
		return fmt.Sprintf("%.0f s", s)
	}
	return fmt.Sprintf("%d m %02d s", int(s)/60, int(s)%60)
}

func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}

// ---------- the files ----------

func writeManifest(r *recordJob) error {
	data, err := json.MarshalIndent(r.manifest, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(r.dir, "recording.json"), append(data, '\n'), 0o644)
}

// writePartSidecar writes the iqfile sidecar with the recording block, which is
// what `ley play` reads off a part.
func writePartSidecar(r *recordJob, p leyline.RecordingPart) {
	m := r.manifest
	doc := map[string]any{
		"format":        m.Format,
		"sample_rate":   m.SampleRate,
		"center_hz":     m.FrequencyHz,
		"samples":       p.Samples,
		"created_at_ns": time.Now().UnixNano(),
		"anchor":        map[string]any{"host_time_ns": m.StartedAtNS, "sample_rate": m.SampleRate, "drift_ppm": 0},
		"metadata": map[string]string{
			"mode": m.Mode, "frequency_hz": strconv.FormatUint(m.FrequencyHz, 10), "kind": m.Kind,
		},
		"recording": map[string]any{
			"job_id": m.JobID, "part": p.Part, "kind": m.Kind,
			"start_sample": p.StartSample, "end_sample": p.EndSample,
			"bandwidth_hz": m.BandwidthHz, "peak_dbfs": p.PeakDBFS, "mean_dbfs": p.MeanDBFS,
			"squelch_opens": []any{},
		},
	}
	if p.ClippedMs > 0 {
		doc["recording"].(map[string]any)["clipped_ms"] = p.ClippedMs
	}
	data, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return
	}
	base := strings.TrimSuffix(p.File, filepath.Ext(p.File))
	_ = os.WriteFile(filepath.Join(r.dir, base+".json"), append(data, '\n'), 0o644)
}

// fakeWAV is a canonical 16-bit mono WAV holding a 1 kHz tone: a real file every
// audio tool reads, so a test can check the header agrees with the length.
func fakeWAV(frames int, rate uint64) []byte {
	out := make([]byte, 44+frames*2)
	copy(out[0:], "RIFF")
	binary.LittleEndian.PutUint32(out[4:], uint32(36+frames*2))
	copy(out[8:], "WAVEfmt ")
	binary.LittleEndian.PutUint32(out[16:], 16)
	binary.LittleEndian.PutUint16(out[20:], 1)
	binary.LittleEndian.PutUint16(out[22:], 1)
	binary.LittleEndian.PutUint32(out[24:], uint32(rate))
	binary.LittleEndian.PutUint32(out[28:], uint32(rate)*2)
	binary.LittleEndian.PutUint16(out[32:], 2)
	binary.LittleEndian.PutUint16(out[34:], 16)
	copy(out[36:], "data")
	binary.LittleEndian.PutUint32(out[40:], uint32(frames*2))
	for i := range frames {
		v := int16(16000 * math.Sin(2*math.Pi*1000*float64(i)/float64(rate)))
		binary.LittleEndian.PutUint16(out[44+i*2:], uint16(v))
	}
	return out
}

// fakeCF32 is interleaved little-endian float32 I/Q at a constant amplitude:
// what the IQ form of a recording holds, in the one format every reader here
// already handles.
func fakeCF32(samples int) []byte {
	out := make([]byte, samples*8)
	for i := range samples {
		phase := 2 * math.Pi * 1000 * float64(i) / fakeAudioRate
		binary.LittleEndian.PutUint32(out[i*8:], math.Float32bits(float32(0.5*math.Cos(phase))))
		binary.LittleEndian.PutUint32(out[i*8+4:], math.Float32bits(float32(0.5*math.Sin(phase))))
	}
	return out
}
