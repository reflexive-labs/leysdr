// SPDX-License-Identifier: Apache-2.0

// Package fakedaemon is an in-memory implementation of every leyline.v1 service.
// It is the reference behaviour of the contract for the Go clients: the same
// error codes, event attribution, presence rules and stream negotiation as the
// Swift daemon, with synthetic signal in place of hardware.
package fakedaemon

import (
	"context"
	"errors"
	"net"
	"os"
	"sort"
	"sync"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// Version is what DaemonInfo.version reports.
const Version = "fake-0.1"

// Options configure New.
type Options struct {
	// PresenceGrace is how long a client's non-persistent channels survive after
	// its last streaming RPC ends. Default 5 s.
	PresenceGrace time.Duration
	// MeterInterval is the Meter cadence. Default 100 ms (10 Hz).
	MeterInterval time.Duration
	// NoDevice suppresses the built-in fake RTL-SDR device.
	NoDevice bool
	// ExtraDevices are additional descriptors attached at construction (see
	// HeldRTLSDR); they are served as-is alongside the built-in device.
	ExtraDevices []*leylinev1.DeviceDescriptor
	// SocketPath is reported in DaemonInfo; Serve sets it.
	SocketPath string
	// WriteAwaitsWatcher makes WriteParams hold every write until the writing
	// client has a WatchEvents stream registered (or WatcherWait elapses), so a
	// WriteRejected emitted for it can never precede the watcher. A sequencing
	// aid for tests of clients that open a session (GetState + WatchEvents)
	// and write straight away: the real daemon may register the stream after
	// the write lands, and a session resumes from the snapshot's seq rather
	// than from zero.
	WriteAwaitsWatcher bool
	// WatcherWait bounds WriteAwaitsWatcher. Default 2 s.
	WatcherWait time.Duration
	// RejectWrites, when set, is consulted before every ParamWrite: a non-nil
	// error rejects the write (WriteRejected with that code) in place of the
	// fake's own validation. A test hook for clients' rejection handling.
	RejectWrites func(w *leylinev1.ParamWrite) *leyline.Error
	// RecordingsDir is where record jobs write their files. A test that wants
	// to look at what was written names a directory of its own; the default is
	// a temp directory, which is enough for a client that only reads the
	// manifest back through the contract.
	RecordingsDir string
	// NoSystemAudio makes the fake answer StartPlayback (and a system-audio sink) with
	// PLATFORM_UNSUPPORTED, which is what a headless daemon does. It is how a client's fallback
	// to the machine's own player is tested.
	NoSystemAudio bool
	// Clipping, when set, is what the fake's CaptureLevel reports for a
	// capture: samples at the converter's rails out of the interval's total,
	// and the peak. nil reports a quarter second of samples with none at a
	// rail and a -12 dBFS peak, which is a radio with headroom.
	Clipping func(captureID string) (clipped, total uint64, peakDbfs float64)
	// RecordGateAt is the schedule the fake's squelch gate follows, in
	// milliseconds from the start of a recording, alternating open, close,
	// open, ... Empty keeps the gate open for the whole recording, which is
	// what a continuous recording wants anyway.
	RecordGateAt []int64
	// DCS puts a DCS code on fake carriers, keyed by the carrier's frequency in the fake's band
	// (145.23, 146.52, 146.94, 162.4 or 101.1 MHz, in Hz). A channel on such a carrier reports
	// SUB_AUDIBLE_DCS with that code, on the same edges and heartbeat as a CTCSS tone, and no
	// CTCSS tone, which the daemon suppresses while DCS is locked. The demod tap then carries no
	// sub-audible tone either. Empty keeps every carrier as the table has it.
	DCS map[uint64]DCSCode
}

// DCSCode is a DCS code the fake sends on a carrier (Options.DCS).
type DCSCode struct {
	// Code is the contract's dcs_code: the octal digits read as decimal, 23 for DCS 023.
	Code uint32
	// Inverted is the contract's dcs_inverted.
	Inverted bool
}

// Daemon is the in-memory state store plus all six service implementations.
type Daemon struct {
	leylinev1.UnimplementedControlServer
	leylinev1.UnimplementedJobsServer
	leylinev1.UnimplementedResourcesServer
	leylinev1.UnimplementedDecodersServer

	opts      Options
	startedNs int64

	mu       sync.Mutex
	seq      uint64
	devices  map[string]*leylinev1.DeviceDescriptor
	files    map[string]fileInfo // playback files by device id
	captures map[string]*capture
	channels map[string]*leylinev1.Channel
	sinks    map[string]*leylinev1.Sink
	// Recordings the fake is "playing": the state object and its position, so a client is tested
	// against the shape without the fake owning an audio device.
	playbacks map[string]*playback
	streams   map[string]*stream
	watchers  map[*watcher]struct{}
	presence  map[string]*presence // by client id
	jobs      map[string]*fakeJob
	jobOrder  []string
	// recordSubs are the open SubscribeRecords streams, and store is the fake's record store:
	// one entry per kept decode job, which is what QueryRecords reads.
	recordSubs map[*recordSub]struct{}
	store      []*storedJob
	// notifyCounts records notifier fires by kind (shell, webhook, macos) so a test can assert
	// a notifier fired without the Swift daemon; the real daemon logs webhook and macOS
	// deliveries. Guarded by notifyMu, not mu: a notifier runs off the record path.
	notifyMu     sync.Mutex
	notifyCounts map[string]int
	// sweeping is the device a scan currently owns, so a second scan is declined and a channel
	// cannot join a capture that is walking a band (the daemon's `swept` set).
	sweeping string
	// detectionLog is append-only and capped; every telemetry subscriber reads it from its own
	// cursor, so a detection reaches all of them exactly once.
	detectionLog []*leylinev1.Detection
	// Where the current scan's detections begin in the log, so a carrier is deduped within a scan
	// and reported afresh by the next one.
	detectionEpoch int
	socket         string
	// history holds the last eventHistoryLimit events, oldest first, for
	// WatchEvents(since_seq) replay (the Swift daemon keeps the same window).
	history []retainedEvent
	// closing is closed when Serve's context ends so streaming handlers
	// return cleanly (EOF on the client) before the server is stopped, as the
	// Swift daemon finishes its subscriber streams on shutdown.
	closing chan struct{}
}

// eventHistoryLimit is how many events WatchEvents(since_seq) can replay.
const eventHistoryLimit = 256

type retainedEvent struct {
	captureID string // "" = daemon-wide
	event     *leylinev1.Event
}

type capture struct {
	*leylinev1.Capture
	startedAt time.Time
	// file is set for captures on a playback device: without loop the sample
	// index stops at file.samples and the capture detaches there (EOF).
	file fileInfo
	// manualGain is the last level each element was written to by hand, which is what
	// `auto: false` puts back: turning automatic gain off asks for the manual level, and the
	// one the client last confirmed is the one it means.
	manualGain map[string]float64
}

// sampleIndex returns the capture's current sample position: wall-clock
// elapsed at the capture rate, held at the file's end for a non-looping
// playback device (a looping one keeps counting, like the daemon's runningIndex).
func (c *capture) sampleIndex(now time.Time) uint64 {
	idx := c.elapsedSamples(now)
	if c.file.samples > 0 && !c.file.loop && idx > c.file.samples {
		return c.file.samples
	}
	return idx
}

func (c *capture) elapsedSamples(now time.Time) uint64 {
	return uint64(now.Sub(c.startedAt).Seconds() * float64(c.SampleRate))
}

// atEOF reports whether a non-looping playback capture has consumed its file.
func (c *capture) atEOF(now time.Time) bool {
	return c.file.samples > 0 && !c.file.loop && c.elapsedSamples(now) >= c.file.samples
}

type watcher struct {
	scope  *leylinev1.EventScope
	ch     chan *leylinev1.Event
	client string // ClientInfo.client_id of the watching client
}

type presence struct {
	open  int
	timer *time.Timer
}

// New returns a daemon with one fake RTL-SDR device attached (unless NoDevice).
func New(opts Options) *Daemon {
	if opts.PresenceGrace == 0 {
		opts.PresenceGrace = 5 * time.Second
	}
	if opts.MeterInterval == 0 {
		opts.MeterInterval = 100 * time.Millisecond
	}
	d := &Daemon{
		opts:         opts,
		startedNs:    time.Now().UnixNano(),
		devices:      map[string]*leylinev1.DeviceDescriptor{},
		files:        map[string]fileInfo{},
		captures:     map[string]*capture{},
		playbacks:    map[string]*playback{},
		channels:     map[string]*leylinev1.Channel{},
		sinks:        map[string]*leylinev1.Sink{},
		jobs:         map[string]*fakeJob{},
		streams:      map[string]*stream{},
		watchers:     map[*watcher]struct{}{},
		recordSubs:   map[*recordSub]struct{}{},
		notifyCounts: map[string]int{},
		presence:     map[string]*presence{},
		socket:       opts.SocketPath,
		closing:      make(chan struct{}),
	}
	if !opts.NoDevice {
		dev := fakeRTLSDR()
		d.devices[dev.DeviceId] = dev
	}
	for _, dev := range opts.ExtraDevices {
		d.devices[dev.DeviceId] = dev
	}
	return d
}

// Register registers all six services on s.
func (d *Daemon) Register(s grpc.ServiceRegistrar) {
	leylinev1.RegisterControlServer(s, d)
	leylinev1.RegisterTelemetryServer(s, telemetrySvc{d: d})
	leylinev1.RegisterBulkServer(s, bulkSvc{d: d})
	leylinev1.RegisterJobsServer(s, d)
	leylinev1.RegisterResourcesServer(s, d)
	leylinev1.RegisterDecodersServer(s, d)
}

// Serve listens on the UDS at socketPath until ctx is cancelled. A stale socket
// file is removed first; the file is unlinked on return.
func (d *Daemon) Serve(ctx context.Context, socketPath string) error {
	_ = os.Remove(socketPath)
	l, err := net.Listen("unix", socketPath)
	if err != nil {
		return err
	}
	d.mu.Lock()
	d.socket = socketPath
	d.mu.Unlock()
	srv := grpc.NewServer()
	d.Register(srv)
	done := make(chan error, 1)
	go func() { done <- srv.Serve(l) }()
	select {
	case <-ctx.Done():
		// End every stream cleanly first (clients see EOF, not a dropped
		// transport), then wait briefly for handlers before forcing the stop.
		close(d.closing)
		graceful := make(chan struct{})
		go func() { srv.GracefulStop(); close(graceful) }()
		select {
		case <-graceful:
		case <-time.After(2 * time.Second):
			srv.Stop()
		}
		<-done
		_ = os.Remove(socketPath)
		return nil
	case err := <-done:
		_ = os.Remove(socketPath)
		if errors.Is(err, grpc.ErrServerStopped) {
			return nil
		}
		return err
	}
}

// newID mints a monotonic prefixed ULID (creation order sorts, even within a millisecond).
func newID(prefix string) string { return leyline.NewID(prefix) }

// clientFrom parses the identity metadata; missing metadata gets a fresh id and
// kind "unknown", as the Swift daemon does.
func clientFrom(ctx context.Context) *leylinev1.ClientInfo {
	md, _ := metadata.FromIncomingContext(ctx)
	first := func(k string) string {
		if v := md.Get(k); len(v) > 0 {
			return v[0]
		}
		return ""
	}
	ci := &leylinev1.ClientInfo{
		ClientId: first(leyline.MetaClientID),
		Kind:     first(leyline.MetaClientKind),
		Label:    first(leyline.MetaClientLabel),
	}
	if ci.ClientId == "" {
		ci.ClientId = newID("cli_")
	}
	if ci.Kind == "" {
		ci.Kind = "unknown"
	}
	return ci
}

// fail returns err as the gRPC status "CODE: message" and sets the
// leyline-error-bin trailer carrying the ErrorDetail.
func fail(ctx context.Context, err *leyline.Error) error {
	_ = grpc.SetTrailer(ctx, err.Trailer())
	return err.ToStatus().Err()
}

func errorf(code, target, msg string) *leyline.Error {
	return &leyline.Error{Code: code, Message: msg, Target: target}
}

func pid() int { return os.Getpid() }

func sortByID[T any](xs []T, key func(T) string) {
	sort.Slice(xs, func(i, j int) bool { return key(xs[i]) < key(xs[j]) })
}
