// SPDX-License-Identifier: Apache-2.0

package fakedaemon

import (
	"context"
	"sort"
	"time"

	"github.com/dpup/leysdr/go/pkg/leyline"

	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

// telemetrySvc and bulkSvc give the two Subscribe RPCs distinct receivers.
type (
	telemetrySvc struct {
		leylinev1.UnimplementedTelemetryServer
		d *Daemon
	}
	bulkSvc struct {
		leylinev1.UnimplementedBulkServer
		d *Daemon
	}
)

// byDaemon attributes an event to the daemon itself, as SessionStore.publishJob does: a sweep
// makes its own progress, with no client behind it, and every job event says so.
func byDaemon() *leylinev1.ClientInfo {
	return &leylinev1.ClientInfo{ClientId: "daemon", Kind: "daemon", Label: "leylined"}
}

// emit publishes an event carrying the full state of the changed object. Call
// with d.mu held; the body is cloned so later mutation cannot leak.
func (d *Daemon) emit(by *leylinev1.ClientInfo, body any) {
	d.seq++
	ev := &leylinev1.Event{Seq: d.seq, CausedBy: proto.Clone(by).(*leylinev1.ClientInfo)}
	var captureID string
	switch b := body.(type) {
	case *leylinev1.DeviceDescriptor:
		ev.Body = &leylinev1.Event_Device{Device: proto.Clone(b).(*leylinev1.DeviceDescriptor)}
	case *leylinev1.Capture:
		ev.Body = &leylinev1.Event_Capture{Capture: proto.Clone(b).(*leylinev1.Capture)}
		captureID = b.CaptureId
	case *leylinev1.Channel:
		ev.Body = &leylinev1.Event_Channel{Channel: proto.Clone(b).(*leylinev1.Channel)}
		captureID = b.CaptureId
	case *leylinev1.Sink:
		ev.Body = &leylinev1.Event_Sink{Sink: proto.Clone(b).(*leylinev1.Sink)}
		if ch := d.channels[b.ChannelId]; ch != nil {
			captureID = ch.CaptureId
		}
	case *leylinev1.Job:
		ev.Body = &leylinev1.Event_Job{Job: proto.Clone(b).(*leylinev1.Job)}
	case *leylinev1.WriteRejected:
		ev.Body = &leylinev1.Event_WriteRejected{WriteRejected: proto.Clone(b).(*leylinev1.WriteRejected)}
	case *leylinev1.CaptureAnchor:
		ev.Body = &leylinev1.Event_Anchor{Anchor: proto.Clone(b).(*leylinev1.CaptureAnchor)}
		captureID = b.CaptureId
	case *leylinev1.Playback:
		// A playback has no capture: it is a file playing, with no radio in it, so it is
		// daemon-scoped like a job.
		ev.Body = &leylinev1.Event_Playback{Playback: proto.Clone(b).(*leylinev1.Playback)}
	}
	d.history = append(d.history, retainedEvent{captureID: captureID, event: ev})
	if n := len(d.history) - eventHistoryLimit; n > 0 {
		d.history = d.history[n:]
	}
	for w := range d.watchers {
		if w.admits(captureID) {
			w.offer(ev)
		}
	}
}

// admits reports whether an event scoped to captureID ("" = daemon-wide)
// is delivered to this watcher's scope.
func (w *watcher) admits(captureID string) bool {
	cid, ok := w.scope.Scope.(*leylinev1.EventScope_CaptureId)
	return !ok || captureID == "" || cid.CaptureId == captureID
}

// offer queues ev for the watcher; bufferingNewest: a full buffer drops the
// oldest event and keeps the newest, so a slow watcher sees a seq gap.
func (w *watcher) offer(ev *leylinev1.Event) {
	select {
	case w.ch <- ev:
	default:
		select {
		case <-w.ch:
		default:
		}
		select {
		case w.ch <- ev:
		default:
		}
	}
}

// streamContext derives a streaming handler's context that also ends when
// the daemon is shutting down (Serve's context cancelled), so the handler
// returns nil and the client sees a clean end of stream.
func (d *Daemon) streamContext(ctx context.Context) (context.Context, context.CancelFunc) {
	sctx, cancel := context.WithCancel(ctx)
	go func() {
		select {
		case <-d.closing:
			cancel()
		case <-sctx.Done():
		}
	}()
	return sctx, cancel
}

// snapshot builds a GetStateResponse. Call with d.mu held.
func (d *Daemon) snapshot(scope *leylinev1.EventScope) *leylinev1.GetStateResponse {
	capFilter := ""
	if scope != nil {
		if s, ok := scope.Scope.(*leylinev1.EventScope_CaptureId); ok {
			capFilter = s.CaptureId
		}
	}
	resp := &leylinev1.GetStateResponse{
		EventSeq: d.seq,
		Daemon: &leylinev1.DaemonInfo{
			Version: Version, Pid: int64(pid()), StartedAtNs: d.startedNs, SocketPath: d.socket,
		},
	}
	for _, dev := range d.devices {
		resp.Devices = append(resp.Devices, proto.Clone(dev).(*leylinev1.DeviceDescriptor))
	}
	// Daemon-scoped only, like the Swift daemon: a job is not tied to one capture's lifetime, and
	// the whole reason GetStateResponse.jobs exists is that reconnect stays GetState +
	// resume-from-seq for jobs too.
	if capFilter == "" {
		for _, id := range d.jobOrder {
			if j := d.jobs[id]; j != nil {
				resp.Jobs = append(resp.Jobs, proto.Clone(j.proto).(*leylinev1.Job))
			}
		}
		// A playback is not tied to a capture either.
		ids := make([]string, 0, len(d.playbacks))
		for id := range d.playbacks {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		for _, id := range ids {
			resp.Playbacks = append(resp.Playbacks, proto.Clone(d.playbacks[id].proto).(*leylinev1.Playback))
		}
	}
	for _, c := range d.captures {
		if capFilter == "" || c.CaptureId == capFilter {
			resp.Captures = append(resp.Captures, proto.Clone(c.Capture).(*leylinev1.Capture))
		}
	}
	for _, ch := range d.channels {
		if capFilter == "" || ch.CaptureId == capFilter {
			resp.Channels = append(resp.Channels, proto.Clone(ch).(*leylinev1.Channel))
		}
	}
	for _, s := range d.sinks {
		ch := d.channels[s.ChannelId]
		if capFilter == "" || (ch != nil && ch.CaptureId == capFilter) {
			resp.Sinks = append(resp.Sinks, proto.Clone(s).(*leylinev1.Sink))
		}
	}
	// Maps enumerate in random order; clients number rows by creation (id) order.
	leyline.SortState(resp)
	sortByID(resp.Devices, func(x *leylinev1.DeviceDescriptor) string { return x.DeviceId })
	sortByID(resp.Captures, func(x *leylinev1.Capture) string { return x.CaptureId })
	sortByID(resp.Channels, func(x *leylinev1.Channel) string { return x.ChannelId })
	sortByID(resp.Sinks, func(x *leylinev1.Sink) string { return x.SinkId })
	return resp
}

// ---------- presence ----------

// streamOpened marks a client present for the life of a streaming RPC; the
// returned func ends it and starts the grace timer.
func (d *Daemon) streamOpened(ctx context.Context) func() {
	ci := clientFrom(ctx)
	d.mu.Lock()
	p := d.presence[ci.ClientId]
	if p == nil {
		p = &presence{}
		d.presence[ci.ClientId] = p
	}
	p.open++
	if p.timer != nil {
		p.timer.Stop()
		p.timer = nil
	}
	d.mu.Unlock()
	return func() {
		d.mu.Lock()
		defer d.mu.Unlock()
		p.open--
		if p.open <= 0 {
			p.open = 0
			d.armGraceLocked(ci.ClientId, p)
		}
	}
}

// touchUnary marks a client present for one grace period after a unary call.
func (d *Daemon) touchUnary(ci *leylinev1.ClientInfo) {
	d.mu.Lock()
	defer d.mu.Unlock()
	p := d.presence[ci.ClientId]
	if p == nil {
		p = &presence{}
		d.presence[ci.ClientId] = p
	}
	if p.open == 0 {
		d.armGraceLocked(ci.ClientId, p)
	}
}

func (d *Daemon) armGraceLocked(clientID string, p *presence) {
	if p.timer != nil {
		p.timer.Stop()
	}
	p.timer = time.AfterFunc(d.opts.PresenceGrace, func() { d.reap(clientID) })
}

// reap tears down the non-persistent channels (and their sinks) of a client
// whose presence has ended.
func (d *Daemon) reap(clientID string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	p := d.presence[clientID]
	if p == nil || p.open > 0 {
		return
	}
	delete(d.presence, clientID)
	by := &leylinev1.ClientInfo{ClientId: "daemon", Kind: "daemon", Label: "presence"}
	// A sweep nobody is reading is a radio nobody can use; the daemon's clientGone hook does the
	// same. A hard-killed `ley scan` must not leave the fake sweeping for ever either. The flag is
	// all it takes: the sweep ends itself at its next step, writing what it found before the
	// terminal event goes out, exactly as a CancelJob does.
	//
	// A kept decode job is the exception the design doc states: persistence follows intent, so
	// `ley decode --job` outlives the terminal that started it and its records stay a resource.
	for _, j := range d.jobs {
		if j.owner == clientID && j.proto.State == leylinev1.JobState_RUNNING && !j.keep {
			j.cancelled = true
		}
	}
	for id, ch := range d.channels {
		if ch.Persistent || ch.Owner == nil || ch.Owner.ClientId != clientID {
			continue
		}
		d.destroyChannelLocked(id, by)
	}
	// The sound belongs to whoever asked for it, which is what makes Ctrl-C in `ley play` stop it.
	d.reapPlaybacksLocked(clientID)
}

// destroyChannelLocked removes a channel, its sinks and its bulk streams,
// emitting a terminal event for each. Call with d.mu held.
func (d *Daemon) destroyChannelLocked(id string, by *leylinev1.ClientInfo) {
	ch := d.channels[id]
	if ch == nil {
		return
	}
	for sid, s := range d.sinks {
		if s.ChannelId == id {
			d.detachSinkLocked(sid, by)
		}
	}
	for sid, s := range d.streams {
		if s.channelID == id {
			s.close()
			delete(d.streams, sid)
		}
	}
	delete(d.channels, id)
	ch.State = leylinev1.ChannelState_CHANNEL_STATE_UNSPECIFIED
	d.emit(by, ch)
}

func (d *Daemon) detachSinkLocked(id string, by *leylinev1.ClientInfo) {
	s := d.sinks[id]
	if s == nil {
		return
	}
	delete(d.sinks, id)
	if sa, ok := s.Kind.(*leylinev1.Sink_SystemAudio); ok && sa != nil {
		if ch := d.channels[s.ChannelId]; ch != nil {
			if c := d.captures[ch.CaptureId]; c != nil && c.Activity.LiveAudioSinks > 0 {
				c.Activity.LiveAudioSinks--
				d.emit(by, c.Capture)
			}
		}
	}
	// Terminal event: state unset says "gone" (control.proto's SinkState), the
	// same tombstone a destroyed channel gets.
	gone := proto.Clone(s).(*leylinev1.Sink)
	gone.State = leylinev1.SinkState_SINK_STATE_UNSPECIFIED
	d.emit(by, gone)
}
