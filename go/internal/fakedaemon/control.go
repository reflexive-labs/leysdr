// SPDX-License-Identifier: Apache-2.0

package fakedaemon

import (
	"context"
	"fmt"
	"math"
	"strings"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
	"github.com/reflexive-labs/leysdr/go/pkg/units"
)

// ListDevices implements Control.
func (d *Daemon) ListDevices(ctx context.Context, _ *leylinev1.ListDevicesRequest) (*leylinev1.ListDevicesResponse, error) {
	d.touchUnary(clientFrom(ctx))
	d.mu.Lock()
	defer d.mu.Unlock()
	return &leylinev1.ListDevicesResponse{Devices: d.snapshot(nil).Devices}, nil
}

// GetState implements Control.
func (d *Daemon) GetState(ctx context.Context, req *leylinev1.GetStateRequest) (*leylinev1.GetStateResponse, error) {
	d.touchUnary(clientFrom(ctx))
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.snapshot(req.GetScope()), nil
}

// WatchEvents implements Control. Events carry the full state of the changed
// object; the stream keeps the caller present.
func (d *Daemon) WatchEvents(scope *leylinev1.EventScope, srv grpc.ServerStreamingServer[leylinev1.Event]) error {
	ctx, stop := d.streamContext(srv.Context())
	defer stop()
	if scope == nil {
		scope = &leylinev1.EventScope{}
	}
	if scope.Scope == nil {
		scope = &leylinev1.EventScope{Scope: &leylinev1.EventScope_Daemon{Daemon: true}, SinceSeq: scope.SinceSeq}
	}
	if cid, ok := scope.Scope.(*leylinev1.EventScope_CaptureId); ok {
		d.mu.Lock()
		_, exists := d.captures[cid.CaptureId]
		d.mu.Unlock()
		if !exists {
			return fail(ctx, errorf(leyline.CodeCaptureNotFound, cid.CaptureId, "no such capture"))
		}
	}
	done := d.streamOpened(ctx)
	defer done()
	w := &watcher{scope: scope, ch: make(chan *leylinev1.Event, eventHistoryLimit), client: clientFrom(ctx).ClientId}
	d.mu.Lock()
	// Replay the retained events newer than since_seq before registering for
	// live ones, under the lock, so the two cannot interleave out of order.
	if scope.SinceSeq != nil {
		for _, kept := range d.history {
			if kept.event.Seq > *scope.SinceSeq && w.admits(kept.captureID) {
				w.offer(kept.event)
			}
		}
	}
	d.watchers[w] = struct{}{}
	d.mu.Unlock()
	defer func() {
		d.mu.Lock()
		delete(d.watchers, w)
		d.mu.Unlock()
	}()
	for {
		select {
		case <-ctx.Done():
			return nil
		case ev := <-w.ch:
			if err := srv.Send(ev); err != nil {
				return nil
			}
		}
	}
}

// CreateCapture implements Control: one capture per device, validated against
// the descriptor; rate 0 picks the device default.
func (d *Daemon) CreateCapture(ctx context.Context, req *leylinev1.CreateCaptureRequest) (*leylinev1.Capture, error) {
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	d.mu.Lock()
	defer d.mu.Unlock()
	dev := d.devices[req.DeviceId]
	if dev == nil {
		return nil, fail(ctx, errorf(leyline.CodeDeviceNotFound, req.DeviceId, "no such device"))
	}
	if dev.State == leylinev1.DeviceState_DISCONNECTED {
		return nil, fail(ctx, errorf(leyline.CodeDeviceDetached, req.DeviceId, "device is disconnected"))
	}
	if err := d.refuseIfSweeping(ctx, req.DeviceId, req.DeviceId); err != nil {
		return nil, err
	}
	for _, c := range d.captures {
		if c.DeviceId == req.DeviceId {
			return nil, fail(ctx, errorf(leyline.CodeDeviceBusy, req.DeviceId, "device already has a capture"))
		}
	}
	if !inRange(dev, req.CenterHz) {
		return nil, fail(ctx, errorf(leyline.CodeFreqOutOfRange, req.DeviceId, fmt.Sprintf("%d Hz is outside the device tuning range", req.CenterHz)))
	}
	rate := req.SampleRate
	if rate == 0 {
		rate = RTLSDRDefaultRate
		if dev.Driver == "file" && len(dev.SampleRates) > 0 {
			rate = dev.SampleRates[0]
		}
	}
	if !rateOK(dev, rate) {
		return nil, fail(ctx, errorf(leyline.CodeRateUnsupported, req.DeviceId, fmt.Sprintf("%d sps is not a supported sample rate", rate)))
	}
	now := time.Now()
	c := &capture{startedAt: now, manualGain: map[string]float64{}, Capture: &leylinev1.Capture{
		CaptureId:  newID("cap_"),
		DeviceId:   req.DeviceId,
		CenterHz:   req.CenterHz,
		SampleRate: rate,
		State:      leylinev1.CaptureState_CAPTURE_ACTIVE,
		Activity:   &leylinev1.CaptureActivity{},
		CreatedBy:  proto.Clone(ci).(*leylinev1.ClientInfo),
	}}
	c.Anchor = &leylinev1.CaptureAnchor{CaptureId: c.CaptureId, HostTimeNs: now.UnixNano(), SampleRate: rate}
	c.file = d.files[dev.DeviceId]
	for _, el := range dev.GainElements {
		c.Gains = append(c.Gains, &leylinev1.GainState{Element: el.Name, Auto: el.SupportsAuto, Db: units.SnapGain(el, el.MaxDb/2)})
	}
	d.captures[c.CaptureId] = c
	dev.State = leylinev1.DeviceState_IN_USE
	d.emit(ci, dev)
	d.emit(ci, c.Capture)
	d.emit(ci, c.Anchor)
	return proto.Clone(c.Capture).(*leylinev1.Capture), nil
}

// DestroyCapture implements Control; channels and sinks under it go too.
func (d *Daemon) DestroyCapture(ctx context.Context, req *leylinev1.DestroyCaptureRequest) (*leylinev1.Empty, error) {
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.captures[req.CaptureId] == nil {
		return nil, fail(ctx, errorf(leyline.CodeCaptureNotFound, req.CaptureId, "no such capture"))
	}
	d.destroyCaptureLocked(req.CaptureId, ci)
	return &leylinev1.Empty{}, nil
}

// destroyCaptureLocked removes a capture, the channels and streams riding on it, and frees the
// radio, emitting a terminal event for each. Call with d.mu held.
func (d *Daemon) destroyCaptureLocked(id string, ci *leylinev1.ClientInfo) {
	c := d.captures[id]
	if c == nil {
		return
	}
	for chID, ch := range d.channels {
		if ch.CaptureId == c.CaptureId {
			d.destroyChannelLocked(chID, ci)
		}
	}
	for sid, s := range d.streams {
		if s.captureID == c.CaptureId {
			s.close()
			delete(d.streams, sid)
		}
	}
	delete(d.captures, c.CaptureId)
	// Terminal event: state unset means "gone" (see Capture.state in
	// control.proto). CAPTURE_DETACHED is reserved for an unplugged radio,
	// which stays in state and rebinds.
	gone := proto.Clone(c.Capture).(*leylinev1.Capture)
	gone.State = leylinev1.CaptureState_CAPTURE_STATE_UNSPECIFIED
	d.emit(ci, gone)
	if dev := d.devices[c.DeviceId]; dev != nil && dev.State == leylinev1.DeviceState_IN_USE {
		dev.State = leylinev1.DeviceState_AVAILABLE
		d.emit(ci, dev)
	}
}

// channelFits reports whether |offset| + bw/2 <= Fs/2.
func channelFits(c *capture, offset int64, bw uint32) bool {
	return math.Abs(float64(offset))+float64(bw)/2 <= float64(c.SampleRate)/2
}

// maxNarrowBandwidth is the widest channel any mode but WFM can carry: the engine's ChannelPlan
// filters those at the second-stage rate r2 (~48 kHz at 2.4 MSPS), and a channel asking for more
// would be filtered narrower than it reports.
func maxNarrowBandwidth(rate uint64) float64 {
	return 0.9 * audioRateHz(rate)
}

// checkBandwidth is ChannelPlan.plan's refusal, which the daemon applies when a channel is created
// and again on every write that changes its bandwidth or its mode.
func checkBandwidth(c *capture, mode leylinev1.DemodMode, bw uint32) *leyline.Error {
	if c == nil || mode == leylinev1.DemodMode_WFM {
		return nil
	}
	maxBW := maxNarrowBandwidth(c.SampleRate)
	if float64(bw) <= maxBW {
		return nil
	}
	// Word for word the engine's refusal, target included: it names no object, because the
	// bandwidth is the caller's argument rather than something wrong with the channel.
	return errorf(leyline.CodeInvalidArgument, "", fmt.Sprintf(
		"bandwidth %d Hz exceeds %d Hz, the most a %s channel can carry at %d S/s (narrow modes run at r2 ≈ 48 kHz); use wfm for wide channels",
		bw, int(maxBW), leyline.ModeName(mode), c.SampleRate))
}

// CreateChannel implements Control. bandwidth 0 picks the mode default; the
// channel must fit inside the capture; owner is the calling client.
func (d *Daemon) CreateChannel(ctx context.Context, req *leylinev1.CreateChannelRequest) (*leylinev1.Channel, error) {
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	d.mu.Lock()
	defer d.mu.Unlock()
	c := d.captures[req.CaptureId]
	if c == nil {
		return nil, fail(ctx, errorf(leyline.CodeCaptureNotFound, req.CaptureId, "no such capture"))
	}
	if err := d.refuseIfSweeping(ctx, c.DeviceId, c.CaptureId); err != nil {
		return nil, err
	}
	mode := req.Mode
	if mode == leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED {
		mode = leylinev1.DemodMode_NFM
	}
	bw := req.BandwidthHz
	if bw == 0 {
		bw = leyline.DefaultBandwidth(mode)
	}
	if !channelFits(c, req.OffsetHz, bw) {
		return nil, fail(ctx, errorf(leyline.CodeOffsetOutOfCapture, req.CaptureId, fmt.Sprintf("offset %d Hz falls outside the capture bandwidth", req.OffsetHz)))
	}
	if e := checkBandwidth(c, mode, bw); e != nil {
		return nil, fail(ctx, e)
	}
	ch := &leylinev1.Channel{
		ChannelId:   newID("chan_"),
		CaptureId:   c.CaptureId,
		OffsetHz:    req.OffsetHz,
		BandwidthHz: bw,
		Mode:        mode,
		SquelchDb:   math.NaN(),
		Agc:         leylinev1.GainMode_AUTO,
		State:       leylinev1.ChannelState_CHANNEL_ACTIVE,
		// Sub-audible detection is on for NFM, the only mode CTCSS is sent under, and a mode
		// write re-decides it (writes.go), as the daemon does since 2026-09-20.
		SubaudibleDetect: mode == leylinev1.DemodMode_NFM,
		Persistent:       req.Persistent,
		RequiredHz:       req.RequiredHz,
		Owner:            proto.Clone(ci).(*leylinev1.ClientInfo),
	}
	d.channels[ch.ChannelId] = ch
	// Creating a channel is somebody tuning the radio, so it stamps the capture's activity and the
	// capture's own event goes first, the way a param write does.
	if ci.GetKind() != "job" {
		c.Activity.LastInteractiveWriteNs = time.Now().UnixNano()
	}
	d.emit(ci, c.Capture)
	d.emit(ci, ch)
	return proto.Clone(ch).(*leylinev1.Channel), nil
}

// DestroyChannel implements Control.
func (d *Daemon) DestroyChannel(ctx context.Context, req *leylinev1.DestroyChannelRequest) (*leylinev1.Empty, error) {
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.channels[req.ChannelId] == nil {
		return nil, fail(ctx, errorf(leyline.CodeChannelNotFound, req.ChannelId, "no such channel"))
	}
	d.destroyChannelLocked(req.ChannelId, ci)
	return &leylinev1.Empty{}, nil
}

// AttachSink implements Control. system_audio is accepted (the fake "plays"
// nothing but counts it in activity); stream and file sinks are UNIMPLEMENTED
// in v0, as in the Swift daemon.
func (d *Daemon) AttachSink(ctx context.Context, req *leylinev1.AttachSinkRequest) (*leylinev1.Sink, error) {
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	d.mu.Lock()
	defer d.mu.Unlock()
	ch := d.channels[req.ChannelId]
	if ch == nil {
		return nil, fail(ctx, errorf(leyline.CodeChannelNotFound, req.ChannelId, "no such channel"))
	}
	if req.Sink == nil {
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, req.ChannelId, "sink is required"))
	}
	switch k := req.Sink.Kind.(type) {
	case *leylinev1.Sink_SystemAudio:
		sa := proto.Clone(k.SystemAudio).(*leylinev1.SystemAudioSink)
		// Proto3 presence: absent volume means full (1.0); an explicit 0 means muted.
		if sa.Volume == nil {
			sa.Volume = proto.Float64(1)
		}
		if *sa.Volume < 0 || *sa.Volume > 1 {
			return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, req.ChannelId, "volume must be within 0..1"))
		}
		s := &leylinev1.Sink{SinkId: newID("sink_"), ChannelId: ch.ChannelId, Kind: &leylinev1.Sink_SystemAudio{SystemAudio: sa}, State: leylinev1.SinkState_SINK_ACTIVE}
		d.sinks[s.SinkId] = s
		if c := d.captures[ch.CaptureId]; c != nil {
			c.Activity.LiveAudioSinks++
			d.emit(ci, c.Capture)
		}
		d.emit(ci, s)
		return proto.Clone(s).(*leylinev1.Sink), nil
	case *leylinev1.Sink_Stream:
		return nil, fail(ctx, errorf(leyline.CodeUnimplemented, req.ChannelId, "attaching a stream sink is not implemented in v0; use Bulk.Subscribe"))
	case *leylinev1.Sink_File:
		return nil, fail(ctx, errorf(leyline.CodeUnimplemented, req.ChannelId, "file sinks are not implemented in v0"))
	default:
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, req.ChannelId, "sink kind is required"))
	}
}

// DetachSink implements Control.
func (d *Daemon) DetachSink(ctx context.Context, req *leylinev1.DetachSinkRequest) (*leylinev1.Empty, error) {
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.sinks[req.SinkId] == nil {
		return nil, fail(ctx, errorf(leyline.CodeSinkNotFound, req.SinkId, "no such sink"))
	}
	d.detachSinkLocked(req.SinkId, ci)
	return &leylinev1.Empty{}, nil
}

// AttachFileDevice implements Control: opens and validates the recording the
// way the daemon does (regular file, sidecar present with a sane sample_rate)
// and registers a playback device.
func (d *Daemon) AttachFileDevice(ctx context.Context, req *leylinev1.AttachFileDeviceRequest) (*leylinev1.DeviceDescriptor, error) {
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	if req.Path == "" {
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, "", "path is required"))
	}
	dev, info, e := openFileDevice(req.Path, req.Loop)
	if e != nil {
		return nil, fail(ctx, e)
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	d.devices[dev.DeviceId] = dev
	d.files[dev.DeviceId] = info
	d.emit(ci, dev)
	return proto.Clone(dev).(*leylinev1.DeviceDescriptor), nil
}

// DetachFileDevice implements Control: removes a playback device and any capture on it.
func (d *Daemon) DetachFileDevice(ctx context.Context, req *leylinev1.DetachFileDeviceRequest) (*leylinev1.Empty, error) {
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	d.mu.Lock()
	dev := d.devices[req.DeviceId]
	if dev == nil || dev.Driver != "file" {
		d.mu.Unlock()
		return nil, fail(ctx, errorf(leyline.CodeDeviceNotFound, req.DeviceId, "no such file device"))
	}
	d.mu.Unlock()
	return d.detachVirtualDevice(ctx, ci, dev)
}

// AttachDevice implements Control: the general form the file RPCs are sugar over. A file source is
// ephemeral; an rtl_tcp source is a radio the station keeps until someone detaches it.
func (d *Daemon) AttachDevice(ctx context.Context, req *leylinev1.AttachDeviceRequest) (*leylinev1.DeviceDescriptor, error) {
	switch src := req.GetSource().GetSource().(type) {
	case *leylinev1.DeviceSource_File:
		return d.AttachFileDevice(ctx, &leylinev1.AttachFileDeviceRequest{Path: src.File.GetPath(), Loop: src.File.GetLoop()})
	case *leylinev1.DeviceSource_RtlTcp:
		return d.attachRTLTCP(ctx, src.RtlTcp)
	default:
		d.touchUnary(clientFrom(ctx))
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, "", "a source is required"))
	}
}

// attachRTLTCP manufactures the descriptor a real daemon would build from the server's header. It
// stands in for the connection too: a host under .invalid is the endpoint that cannot be reached.
func (d *Daemon) attachRTLTCP(ctx context.Context, src *leylinev1.RtlTcpSource) (*leylinev1.DeviceDescriptor, error) {
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	host, port := src.GetHost(), src.GetPort()
	if host == "" {
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, "", "host is required"))
	}
	if port == 0 || port > 65535 {
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, "", fmt.Sprintf("port %d is outside 1...65535", port)))
	}
	endpoint := fmt.Sprintf("%s:%d", host, port)
	d.mu.Lock()
	defer d.mu.Unlock()
	// One endpoint is one radio: attaching it twice hands back the device already hosting it.
	for _, dev := range d.devices {
		if dev.Driver == "rtltcp" && dev.Serial == endpoint {
			return proto.Clone(dev).(*leylinev1.DeviceDescriptor), nil
		}
	}
	if strings.HasSuffix(host, ".invalid") {
		return nil, fail(ctx, errorf(leyline.CodeDeviceIO, endpoint, fmt.Sprintf("connect to %s failed: cannot resolve %s", endpoint, host)))
	}
	dev := rtlTCPDevice(host, port)
	d.devices[dev.DeviceId] = dev
	d.emit(ci, dev)
	return proto.Clone(dev).(*leylinev1.DeviceDescriptor), nil
}

// DetachDevice implements Control: any device a client attached goes, file or remote radio, along
// with the capture on it. A client cannot remove a dongle on this machine.
func (d *Daemon) DetachDevice(ctx context.Context, req *leylinev1.DetachDeviceRequest) (*leylinev1.Empty, error) {
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	d.mu.Lock()
	dev := d.devices[req.DeviceId]
	if dev == nil {
		d.mu.Unlock()
		return nil, fail(ctx, errorf(leyline.CodeDeviceNotFound, req.DeviceId, "no such device"))
	}
	if dev.Driver != "file" && dev.Driver != "rtltcp" {
		d.mu.Unlock()
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, req.DeviceId,
			fmt.Sprintf("%s is a radio plugged into this machine, not a device a client attached; unplug it", dev.Model)))
	}
	d.mu.Unlock()
	return d.detachVirtualDevice(ctx, ci, dev)
}

// detachVirtualDevice drops a hosted device: its capture ends first so clients see the session go
// before the radio does, then the device leaves as a DISCONNECTED event.
func (d *Daemon) detachVirtualDevice(ctx context.Context, ci *leylinev1.ClientInfo, dev *leylinev1.DeviceDescriptor) (*leylinev1.Empty, error) {
	d.mu.Lock()
	var capID string
	for _, c := range d.captures {
		if c.DeviceId == dev.DeviceId {
			capID = c.CaptureId
		}
	}
	d.mu.Unlock()
	if capID != "" {
		_, _ = d.DestroyCapture(ctx, &leylinev1.DestroyCaptureRequest{CaptureId: capID})
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	delete(d.devices, dev.DeviceId)
	delete(d.files, dev.DeviceId)
	dev.State = leylinev1.DeviceState_DISCONNECTED
	d.emit(ci, dev)
	return &leylinev1.Empty{}, nil
}

// refuseIfSweeping mirrors SessionStore.refuseIfSwept: while a scan owns a radio it is the only
// thing tuning it, and a channel created on a capture that is walking a band would be dragged
// across megahertz with no explanation. The target is the object the caller named -- the device
// for a capture, the capture for a channel or a write -- so a client that resolves it names the
// object it asked about. Caller holds the lock.
func (d *Daemon) refuseIfSweeping(ctx context.Context, deviceID, target string) error {
	if d.sweeping == "" || d.sweeping != deviceID {
		return nil
	}
	return fail(ctx, sweptError(target))
}

// sweptError is the refusal every path shares while a scan owns the radio.
func sweptError(target string) *leyline.Error {
	return errorf(leyline.CodeDeviceSweeping, target, "a scan is sweeping this radio; it is free again when the scan ends")
}
