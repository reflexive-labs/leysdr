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
}

// Daemon is the in-memory state store plus all five service implementations.
type Daemon struct {
	leylinev1.UnimplementedControlServer
	leylinev1.UnimplementedJobsServer
	leylinev1.UnimplementedResourcesServer

	opts      Options
	startedNs int64

	mu       sync.Mutex
	seq      uint64
	devices  map[string]*leylinev1.DeviceDescriptor
	files    map[string]fileInfo // playback files by device id
	captures map[string]*capture
	channels map[string]*leylinev1.Channel
	sinks    map[string]*leylinev1.Sink
	streams  map[string]*stream
	watchers map[*watcher]struct{}
	presence map[string]*presence // by client id
	jobs     map[string]*fakeJob
	jobOrder []string
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
		opts:      opts,
		startedNs: time.Now().UnixNano(),
		devices:   map[string]*leylinev1.DeviceDescriptor{},
		files:     map[string]fileInfo{},
		captures:  map[string]*capture{},
		channels:  map[string]*leylinev1.Channel{},
		sinks:     map[string]*leylinev1.Sink{},
		jobs:      map[string]*fakeJob{},
		streams:   map[string]*stream{},
		watchers:  map[*watcher]struct{}{},
		presence:  map[string]*presence{},
		socket:    opts.SocketPath,
		closing:   make(chan struct{}),
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

// Register registers all five services on s.
func (d *Daemon) Register(s grpc.ServiceRegistrar) {
	leylinev1.RegisterControlServer(s, d)
	leylinev1.RegisterTelemetryServer(s, telemetrySvc{d: d})
	leylinev1.RegisterBulkServer(s, bulkSvc{d: d})
	leylinev1.RegisterJobsServer(s, d)
	leylinev1.RegisterResourcesServer(s, d)
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
