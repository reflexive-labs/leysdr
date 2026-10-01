// SPDX-License-Identifier: Apache-2.0

package fakedaemon

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// Resources over the same manifests the fake's record jobs write, plus the kept
// decode jobs the record store holds. Every kind that has a store is answered
// rather than one kind of it, and a kind that has no store yet returns an empty
// list -- none exist, so that is not an error
// (docs/design/recording.md, "The wire").

// ListResources implements Resources.
func (d *Daemon) ListResources(ctx context.Context, req *leylinev1.ListResourcesRequest) (*leylinev1.ListResourcesResponse, error) {
	d.touchUnary(clientFrom(ctx))
	d.mu.Lock()
	defer d.mu.Unlock()
	var out []*leylinev1.Resource
	kind := req.GetKind()
	if kind == leylinev1.ResourceKind_RECORDING || kind == leylinev1.ResourceKind_RESOURCE_KIND_UNSPECIFIED {
		for _, id := range d.jobOrder {
			j := d.jobs[id]
			if j == nil || j.record == nil {
				continue
			}
			out = append(out, recordingResource(j))
		}
	}
	if kind == leylinev1.ResourceKind_RECORDS || kind == leylinev1.ResourceKind_RESOURCE_KIND_UNSPECIFIED {
		for _, s := range d.store {
			r := &leylinev1.Resource{
				Uri: "ley://records/" + s.jobID, Kind: leylinev1.ResourceKind_RECORDS,
				OriginatingJobId: s.jobID,
				Metadata: map[string]string{
					"protocol": s.protocol,
					"records":  strconv.Itoa(len(s.records)),
				},
			}
			if j := d.jobs[s.jobID]; j != nil {
				r.CreatedAtNs = j.proto.GetCreatedAtNs()
			}
			out = append(out, r)
		}
	}
	if kind == leylinev1.ResourceKind_SCAN || kind == leylinev1.ResourceKind_RESOURCE_KIND_UNSPECIFIED {
		for _, id := range d.jobOrder {
			j := d.jobs[id]
			if j == nil || j.scan == nil {
				continue
			}
			out = append(out, &leylinev1.Resource{
				Uri: "ley://scans/" + j.scan.GetScanId(), Kind: leylinev1.ResourceKind_SCAN,
				CreatedAtNs: j.proto.GetCreatedAtNs(), OriginatingJobId: j.proto.GetJobId(),
				Metadata: map[string]string{"state": j.proto.GetState().String()},
			})
		}
	}
	kept := out[:0]
	for _, r := range out {
		if matchesResourceFilter(r, req.GetMetadataFilter()) {
			kept = append(kept, r)
		}
	}
	out = kept
	sort.SliceStable(out, func(i, j int) bool { return out[i].GetCreatedAtNs() > out[j].GetCreatedAtNs() })
	return &leylinev1.ListResourcesResponse{Resources: out}, nil
}

// GetResource implements Resources.
func (d *Daemon) GetResource(ctx context.Context, req *leylinev1.ResourceRef) (*leylinev1.Resource, error) {
	d.touchUnary(clientFrom(ctx))
	jobID, _, ok := leyline.ParseRecordingURI(req.GetUri())
	if !ok {
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, req.GetUri(),
			req.GetUri()+" is not a resource uri; they look like ley://recordings/job_01J..."))
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	j := d.jobs[jobID]
	if j == nil || j.record == nil {
		return nil, fail(ctx, errorf(leyline.CodeJobNotFound, jobID, "no recording called "+quoted(jobID)))
	}
	return recordingResource(j), nil
}

// ResolveLocalPath implements Resources: a recording's directory, or one part's
// samples file. Nothing is streamed.
func (d *Daemon) ResolveLocalPath(ctx context.Context, req *leylinev1.ResourceRef) (*leylinev1.LocalPath, error) {
	d.touchUnary(clientFrom(ctx))
	jobID, part, ok := leyline.ParseRecordingURI(req.GetUri())
	if !ok {
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, req.GetUri(),
			req.GetUri()+" has no file on this machine; recordings and kept records do"))
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	j := d.jobs[jobID]
	if j == nil || j.record == nil {
		return nil, fail(ctx, errorf(leyline.CodeJobNotFound, jobID, "no recording called "+quoted(jobID)))
	}
	if part == 0 {
		return &leylinev1.LocalPath{Path: j.record.dir}, nil
	}
	for _, p := range j.record.manifest.Parts {
		if p.Part == part {
			return &leylinev1.LocalPath{Path: filepath.Join(j.record.dir, p.File)}, nil
		}
	}
	return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, req.GetUri(),
		req.GetUri()+" names a part this recording does not have"))
}

// DeleteResource implements Resources: a recording is removed whole, never while
// its job runs. A playback of one of its parts is stopped first, as StopPlayback
// stops it, so its tombstone is the one event a delete sends -- the recording is
// a resource, not state, and the job's entry stays as it is
// (docs/design/recording.md, "The wire").
func (d *Daemon) DeleteResource(ctx context.Context, req *leylinev1.ResourceRef) (*leylinev1.DeletedResource, error) {
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	jobID, part, ok := leyline.ParseRecordingURI(req.GetUri())
	if !ok {
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, req.GetUri(),
			req.GetUri()+" is not a recording; only ley://recordings/<id> can be deleted"))
	}
	if part != 0 {
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, req.GetUri(),
			req.GetUri()+" names one part; a recording is deleted whole, as "+leyline.RecordingURI(jobID)))
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	j := d.jobs[jobID]
	if j == nil || j.record == nil {
		return nil, fail(ctx, errorf(leyline.CodeJobNotFound, jobID, "no recording called "+quoted(jobID)))
	}
	if st := j.proto.GetState(); st == leylinev1.JobState_RUNNING || st == leylinev1.JobState_DEGRADED {
		return nil, fail(ctx, errorf(leyline.CodeFailedPrecondition, jobID,
			jobID+" is still recording; cancel the job first, then delete it"))
	}
	uri := leyline.RecordingURI(jobID)
	for id, p := range d.playbacks {
		if pu := p.proto.GetResourceUri(); pu == uri || strings.HasPrefix(pu, uri+"/") {
			d.endPlaybackLocked(id, ci)
		}
	}
	freed := dirSize(j.record.dir)
	if err := os.RemoveAll(j.record.dir); err != nil {
		return nil, fail(ctx, errorf(leyline.CodeInternal, jobID,
			"could not remove the recording's directory: "+err.Error()))
	}
	j.record = nil
	return &leylinev1.DeletedResource{Uri: leyline.RecordingURI(jobID), FreedBytes: freed}, nil
}

// dirSize is what a recording's directory holds on disk, parts and sidecars and
// manifest, as the daemon reports freed_bytes.
func dirSize(dir string) uint64 {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0
	}
	var n uint64
	for _, e := range entries {
		if info, ierr := e.Info(); ierr == nil && info.Mode().IsRegular() {
			n += uint64(info.Size())
		}
	}
	return n
}

// recordingResource is the manifest as the contract carries it, with the frozen
// metadata keys a filter matches on by exact string. Caller holds the lock.
func recordingResource(j *fakeJob) *leylinev1.Resource {
	m := j.record.manifest
	device := ""
	if m.Device != nil {
		device = m.Device.Model
	}
	// What the directory takes on disk, sidecars and the part being written included, as the
	// daemon reports it; so the size listed is the size DeleteResource frees.
	size := dirSize(j.record.dir)
	if size == 0 {
		size = m.Bytes
	}
	return &leylinev1.Resource{
		Uri:              m.URI,
		Kind:             leylinev1.ResourceKind_RECORDING,
		CreatedAtNs:      m.StartedAtNS,
		SizeBytes:        size,
		OriginatingJobId: m.JobID,
		Metadata: map[string]string{
			"kind":          m.Kind,
			"frequency_hz":  strconv.FormatUint(m.FrequencyHz, 10),
			"mode":          m.Mode,
			"bandwidth_hz":  strconv.FormatUint(uint64(m.BandwidthHz), 10),
			"sample_rate":   strconv.FormatUint(m.SampleRate, 10),
			"format":        m.Format,
			"duration_ms":   strconv.FormatInt(m.DurationMs(), 10),
			"parts":         strconv.Itoa(len(m.Parts)),
			"started_at_ns": strconv.FormatInt(m.StartedAtNS, 10),
			"ended_at_ns":   strconv.FormatInt(m.EndedAtNS, 10),
			"ended_by":      m.EndedBy,
			"device":        device,
		},
	}
}

// matchesResourceFilter is exact-string equality on every key given: an unknown
// key matches nothing, because the resource does not have that field.
func matchesResourceFilter(r *leylinev1.Resource, filter map[string]string) bool {
	for k, want := range filter {
		if r.GetMetadata()[k] != want {
			return false
		}
	}
	return true
}

// Playing a recording back (docs/design/recording.md, "Playing a recording back"). The fake owns
// no audio device, so it plays nothing; what it has is the shape -- a Playback object with a
// position that advances at the file's own rate, events as it starts, four times a second while
// it plays and as it ends, and a client that takes its playbacks with it. That is what a client
// is tested against.

// playbackInterval is how often a playing playback is published with its position, the
// daemon's SessionStore.playbackInterval.
const playbackInterval = 250 * time.Millisecond

// playback is one recording the fake is "playing": the state object plus when it started, which
// is what the position is derived from.
type playback struct {
	proto   *leylinev1.Playback
	owner   string
	started time.Time
	done    chan struct{}
	// pausedAt is when the current pause began, zero while playing; pausedFor is the time
	// spent in earlier pauses. The position is the time since started less both, so a pause
	// holds it and a resume continues from it.
	pausedAt  time.Time
	pausedFor time.Duration
}

// playedFor is how long the playback has been playing, pauses left out.
func (p *playback) playedFor(now time.Time) time.Duration {
	d := now.Sub(p.started) - p.pausedFor
	if !p.pausedAt.IsZero() {
		d -= now.Sub(p.pausedAt)
	}
	return d
}

// StartPlayback implements Control.
func (d *Daemon) StartPlayback(ctx context.Context, req *leylinev1.StartPlaybackRequest) (*leylinev1.Playback, error) {
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	if d.opts.NoSystemAudio {
		return nil, fail(ctx, errorf(leyline.CodePlatformUnsupported, "", "system audio requires macOS"))
	}
	jobID, part, ok := leyline.ParseRecordingURI(req.GetResourceUri())
	if !ok {
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, req.GetResourceUri(),
			req.GetResourceUri()+" is not a recording; playback takes ley://recordings/<id> or ley://recordings/<id>/<part>"))
	}
	d.mu.Lock()
	j := d.jobs[jobID]
	if j == nil || j.record == nil {
		d.mu.Unlock()
		return nil, fail(ctx, errorf(leyline.CodeJobNotFound, jobID, "no recording called "+quoted(jobID)))
	}
	m := j.record.manifest
	if m.Kind == "iq" {
		d.mu.Unlock()
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, req.GetResourceUri(),
			jobID+" is an IQ recording: those are tuned rather than played. Attach it as a device instead"))
	}
	if part == 0 && len(m.Parts) > 0 {
		part = m.Parts[0].Part
	}
	var chosen *leyline.RecordingPart
	for i := range m.Parts {
		if m.Parts[i].Part == part {
			chosen = &m.Parts[i]
		}
	}
	if chosen == nil {
		d.mu.Unlock()
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, req.GetResourceUri(),
			fmt.Sprintf("%s has no part %d", jobID, part)))
	}
	volume := 1.0
	if req.Volume != nil {
		volume = req.GetVolume()
	}
	p := &playback{
		owner: ci.GetClientId(), started: time.Now(), done: make(chan struct{}),
		proto: &leylinev1.Playback{
			PlaybackId:  newID("pb_"),
			ResourceUri: leyline.RecordingPartURI(jobID, part),
			Path:        filepath.Join(j.record.dir, chosen.File),
			SampleRate:  uint32(m.SampleRate),
			Samples:     chosen.Samples,
			Volume:      volume,
			CreatedBy:   ci,
			State:       leylinev1.PlaybackState_PLAYBACK_PLAYING,
		},
	}
	d.playbacks[p.proto.PlaybackId] = p
	d.emit(ci, proto.Clone(p.proto).(*leylinev1.Playback))
	reply := proto.Clone(p.proto).(*leylinev1.Playback)
	d.mu.Unlock()
	go d.runPlayback(p)
	return reply, nil
}

// StopPlayback implements Control.
func (d *Daemon) StopPlayback(ctx context.Context, req *leylinev1.StopPlaybackRequest) (*leylinev1.Empty, error) {
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.playbacks[req.GetPlaybackId()] == nil {
		return nil, fail(ctx, errorf(leyline.CodeSinkNotFound, req.GetPlaybackId(), "no such playback"))
	}
	d.endPlaybackLocked(req.GetPlaybackId(), ci)
	return &leylinev1.Empty{}, nil
}

// SetPlaybackPaused implements Control: the position holds while paused and a resume continues
// from it. Any client may pause a playback, as any client may stop one; the event names who did,
// and asking for the state it is already in sends no event.
func (d *Daemon) SetPlaybackPaused(ctx context.Context, req *leylinev1.SetPlaybackPausedRequest) (*leylinev1.Playback, error) {
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	d.mu.Lock()
	defer d.mu.Unlock()
	p := d.playbacks[req.GetPlaybackId()]
	if p == nil {
		return nil, fail(ctx, errorf(leyline.CodeSinkNotFound, req.GetPlaybackId(), "no such playback"))
	}
	if p.proto.GetPaused() != req.GetPaused() {
		now := time.Now()
		if req.GetPaused() {
			p.pausedAt = now
		} else {
			p.pausedFor += now.Sub(p.pausedAt)
			p.pausedAt = time.Time{}
		}
		p.proto.Paused = req.GetPaused()
		p.proto.Position = p.position(now)
		d.emit(ci, proto.Clone(p.proto).(*leylinev1.Playback))
	}
	return proto.Clone(p.proto).(*leylinev1.Playback), nil
}

// position is the frames played by now, at the file's rate.
func (p *playback) position(now time.Time) uint64 {
	return uint64(max(p.playedFor(now).Seconds(), 0) * float64(p.proto.GetSampleRate()))
}

// runPlayback advances the position at the file's own rate, publishes the whole playback every
// playbackInterval as the daemon does, and ends it when the file runs out, so a client following
// one sees it move and finish from the event plane alone. A paused playback is not published:
// its position has not moved, and the pause already sent its state.
func (d *Daemon) runPlayback(p *playback) {
	rate := float64(p.proto.GetSampleRate())
	if rate <= 0 {
		rate = 1
	}
	total := time.Duration(float64(p.proto.GetSamples()) / rate * float64(time.Second))
	tick := time.NewTicker(50 * time.Millisecond)
	defer tick.Stop()
	published := p.started
	for {
		select {
		case <-p.done:
			return
		case <-tick.C:
			d.mu.Lock()
			if d.playbacks[p.proto.PlaybackId] == nil {
				d.mu.Unlock()
				return
			}
			if p.proto.GetPaused() {
				d.mu.Unlock()
				continue
			}
			elapsed := p.playedFor(time.Now())
			if elapsed >= total {
				d.endPlaybackLocked(p.proto.PlaybackId, byDaemon())
				d.mu.Unlock()
				return
			}
			p.proto.Position = uint64(elapsed.Seconds() * rate)
			if time.Since(published) >= playbackInterval {
				published = time.Now()
				d.emit(byDaemon(), proto.Clone(p.proto).(*leylinev1.Playback))
			}
			d.mu.Unlock()
		}
	}
}

// endPlaybackLocked removes a playback and emits the tombstone: the same message with state
// unset, the rule every other object here follows. Caller holds the lock.
func (d *Daemon) endPlaybackLocked(id string, by *leylinev1.ClientInfo) {
	p := d.playbacks[id]
	if p == nil {
		return
	}
	delete(d.playbacks, id)
	close(p.done)
	tomb := proto.Clone(p.proto).(*leylinev1.Playback)
	tomb.State = leylinev1.PlaybackState_PLAYBACK_STATE_UNSPECIFIED
	d.emit(by, tomb)
}

// reapPlaybacksLocked ends the playbacks of a client that has gone: a playback ends with the
// client that started it. Caller holds the lock.
func (d *Daemon) reapPlaybacksLocked(clientID string) {
	for id, p := range d.playbacks {
		if p.owner == clientID {
			d.endPlaybackLocked(id, byDaemon())
		}
	}
}
