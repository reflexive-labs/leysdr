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
	"github.com/reflexive-labs/leysdr/go/pkg/callsign"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// A decode job whose source is a recording (DecodeConfig.source_uri) reads the recording's
// manifest and part sidecars, cuts segments from each part's squelch_opens with the manifest's
// pre-roll and hang as the daemon's RecordingSource does, and emits one record per segment. No
// plugin runs: the record is the one leydec-speech's scripted engine writes, with the fields the
// daemon stamps (clip_uri, over, the usage's feature and job) filled in, and the job ends
// COMPLETED when the last part is read. It takes no capture, channel or lease.

// sourceRecordInterval paces the records, so a client following the job sees them arrive one at a
// time, as from a plugin that is faster than real time but not instant.
const sourceRecordInterval = 20 * time.Millisecond

// speechSegment is one segment of a part: the samples from pre-roll before its first opening to
// hang after its last, on the capture's timeline, and the index of its first opening.
type speechSegment struct {
	part      int
	over      uint32
	captureID string
	from, to  uint64
	audioSecs float64
}

// startSourceDecode is StartJob(decode) with a source_uri. The refusals are answered at once,
// as the daemon answers them: a uri that is not a recording, a recording the store does not have,
// one still being written, and IQ, which needs an offline demodulator nobody has built.
func (d *Daemon) startSourceDecode(ctx context.Context, cfg *leylinev1.DecodeConfig, man *leylinev1.DecoderManifest) (*leylinev1.Job, error) {
	uri := cfg.GetSourceUri()
	recID, part, ok := leyline.ParseRecordingURI(uri)
	if !ok || part != 0 {
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, uri,
			uri+" is not a recording to decode; a source is ley://recordings/<id>"))
	}
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	d.mu.Lock()
	defer d.mu.Unlock()
	src := d.jobs[recID]
	if src == nil || src.record == nil {
		return nil, fail(ctx, errorf(leyline.CodeJobNotFound, recID, "no recording called "+quoted(recID)))
	}
	if st := src.proto.GetState(); st == leylinev1.JobState_RUNNING || st == leylinev1.JobState_DEGRADED {
		return nil, fail(ctx, errorf(leyline.CodeFailedPrecondition, recID,
			recID+" is still recording; decode it once its job has ended"))
	}
	m := src.record.manifest
	if m.Kind == "iq" {
		return nil, fail(ctx, errorf(leyline.CodeUnimplemented, recID,
			"decoding an IQ recording is not implemented: it needs an offline demodulator; decode an audio recording"))
	}
	job := &leylinev1.Job{
		JobId:        newID("job_"),
		State:        leylinev1.JobState_RUNNING,
		CreatedAtNs:  time.Now().UnixNano(),
		CreatedBy:    ci,
		Config:       &leylinev1.Job_Decode{Decode: proto.Clone(cfg).(*leylinev1.DecodeConfig)},
		StatusDetail: fmt.Sprintf("decoding %s from %s", man.GetName(), uri),
	}
	if cfg.GetKeep() {
		job.ResultUris = []string{"ley://records/" + job.JobId}
	}
	fj := &fakeJob{proto: job, owner: ci.GetClientId(), protocol: man.GetName(), hz: m.FrequencyHz, keep: cfg.GetKeep()}
	d.jobs[job.JobId] = fj
	d.jobOrder = append(d.jobOrder, job.JobId)
	d.trimJobsLocked()
	if cfg.GetKeep() {
		// The records are dated by the recording's anchors, the capture they were heard on.
		s := d.storeFor(fj)
		for _, a := range m.Anchors {
			s.anchors = append(s.anchors, &leylinev1.RecordAnchor{
				Anchor: &leylinev1.CaptureAnchor{
					CaptureId: a.CaptureID, HostTimeNs: a.HostTimeNS, SampleRate: a.SampleRate, DriftPpm: a.DriftPPM,
				},
				FromSample: a.FromSample,
			})
		}
	}
	d.emit(byDaemon(), job)
	reply := proto.Clone(job).(*leylinev1.Job)
	go d.runSourceDecode(job.JobId, man, src.record.dir, *m)
	return reply, nil
}

// runSourceDecode emits the recording's segments as records, then ends the job.
func (d *Daemon) runSourceDecode(jobID string, man *leylinev1.DecoderManifest, dir string, m leyline.RecordingManifest) {
	segs, err := speechSegments(dir, &m, man.GetInput())
	if err != nil {
		d.endSourceDecode(jobID, leylinev1.JobState_FAILED, &leylinev1.ErrorDetail{
			Code: leyline.CodeInternal, Message: "the recording could not be read: " + err.Error(), Target: m.JobID,
		})
		return
	}
	for _, seg := range segs {
		time.Sleep(sourceRecordInterval)
		if d.jobCancelled(jobID) {
			d.finishDecode(jobID)
			return
		}
		d.mu.Lock()
		j := d.jobs[jobID]
		if j == nil || j.proto.State != leylinev1.JobState_RUNNING {
			d.mu.Unlock()
			return
		}
		j.seq++
		rec := d.speechRecord(man, m.JobID, seg, j.seq)
		rec.JobId, rec.Seq = jobID, j.seq
		rec.Usage.JobId = jobID
		d.publishRecord(j, rec)
		line := d.foldUsage(rec.GetUsage())
		d.emit(byDaemon(), line)
		if cred := d.ai.credentials[line.GetProvider()]; cred != nil {
			cred.LastUsedAtNs = max(cred.LastUsedAtNs, line.GetLastAtNs())
			d.emit(byDaemon(), d.aiSnapshot())
		}
		j.proto.StatusDetail = fmt.Sprintf("decoding %s from %s: %s", man.GetName(), m.URI, pluralRecords(j.seq))
		d.mu.Unlock()
	}
	d.endSourceDecode(jobID, leylinev1.JobState_COMPLETED, nil)
}

// endSourceDecode moves the job to its terminal state with the terminal event last.
func (d *Daemon) endSourceDecode(jobID string, state leylinev1.JobState, failure *leylinev1.ErrorDetail) {
	d.mu.Lock()
	defer d.mu.Unlock()
	j := d.jobs[jobID]
	if j == nil || j.proto.State != leylinev1.JobState_RUNNING {
		return
	}
	j.proto.State = state
	j.proto.StatusDetail = "decoded the recording: " + pluralRecords(j.seq)
	if failure != nil {
		j.proto.StatusDetail = failure.GetMessage()
		j.proto.Error = failure
	}
	d.emit(byDaemon(), proto.Clone(j.proto).(*leylinev1.Job))
	d.trimJobsLocked()
}

// speechRecord is the record leydec-speech's scripted engine writes for the n-th segment, with
// what the daemon stamps on it. Caller holds the lock.
func (d *Daemon) speechRecord(man *leylinev1.DecoderManifest, recID string, seg speechSegment, n uint64) *leylinev1.DecodeRecord {
	text := fmt.Sprintf("segment %d", n)
	if k := uint64(len(d.opts.SpeechScript)); k > 0 {
		text = d.opts.SpeechScript[min(n, k)-1]
	}
	provider, model := "scripted", "scripted"
	if p := man.GetCredentialProvider(); p != "" {
		provider = p
		if fm := d.ai.features["speech"]; fm != nil && fm.GetProvider() == p {
			model = fm.GetModel()
		}
	}
	return &leylinev1.DecodeRecord{
		RecordId: newID("rec_"),
		Protocol: man.GetName(),
		Time:     &leylinev1.SampleTime{CaptureId: seg.captureID, SampleIndex: seg.from},
		// Nothing measured the channel: the audio came from a file.
		RssiDbfs: math.NaN(),
		SnrDb:    math.NaN(),
		Fields: map[string]*leylinev1.FieldValue{
			"text":       textField(text),
			"language":   textField("en"),
			"model":      textField(model),
			"confidence": numberField(1),
			"callsigns":  textField(strings.Join(callsign.Find(text), ",")),
		},
		Raw:     []byte(text),
		ClipUri: leyline.RecordingPartURI(recID, seg.part),
		Over:    seg.over,
		Usage: &leylinev1.UsageReport{
			Provider: provider, Model: model, Feature: "speech",
			Requests: 1, AudioSeconds: seg.audioSecs, AtNs: time.Now().UnixNano(),
		},
	}
}

// speechSegments cuts every part's squelch_opens into segments: an opening that starts within the
// hang of the previous one's close continues its segment, and each segment runs from pre-roll
// before its first opening to hang after its last, inside the part.
func speechSegments(dir string, m *leyline.RecordingManifest, in *leylinev1.DecoderInput) ([]speechSegment, error) {
	preMs, hangMs := uint64(in.GetPreRollMs()), uint64(in.GetHangMs())
	if preMs == 0 {
		preMs = 500
	}
	if hangMs == 0 {
		hangMs = 500
	}
	var out []speechSegment
	for _, p := range m.Parts {
		sc, err := leyline.ReadPartSidecar(dir, p)
		if err != nil {
			return nil, err
		}
		rate := sc.Anchor.SampleRate
		if rate == 0 {
			return nil, fmt.Errorf("part %d's sidecar gives no capture rate", p.Part)
		}
		pre, hang := preMs*rate/1000, hangMs*rate/1000
		var cur *speechSegment
		var lastClose uint64
		closeSeg := func() {
			if cur == nil {
				return
			}
			cur.to = min(lastClose+hang, p.EndSample)
			cur.audioSecs = float64(cur.to-cur.from) / float64(rate)
			out = append(out, *cur)
			cur = nil
		}
		for i, o := range sc.Recording.SquelchOpens {
			if cur != nil && o.OpenSample <= lastClose+hang {
				lastClose = max(lastClose, o.CloseSample)
				continue
			}
			closeSeg()
			from := p.StartSample
			if o.OpenSample > p.StartSample+pre {
				from = o.OpenSample - pre
			}
			cur = &speechSegment{part: p.Part, over: uint32(i + 1), captureID: sc.Anchor.CaptureID, from: from}
			lastClose = o.CloseSample
		}
		closeSeg()
	}
	return out, nil
}
