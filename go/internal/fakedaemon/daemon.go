// Package fakedaemon is an in-memory implementation of every leyline.v1 service.
// It is the reference behaviour of the contract for the Go clients: the same
// error codes, event attribution, presence rules and stream negotiation as the
// Swift daemon, with synthetic signal in place of hardware.
package fakedaemon

import (
	"context"
	"crypto/rand"
	"errors"
	"net"
	"os"
	"sort"
	"sync"
	"time"

	"github.com/oklog/ulid/v2"
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
	// SocketPath is reported in DaemonInfo; Serve sets it.
	SocketPath string
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
	captures map[string]*capture
	channels map[string]*leylinev1.Channel
	sinks    map[string]*leylinev1.Sink
	streams  map[string]*stream
	watchers map[*watcher]struct{}
	presence map[string]*presence // by client id
	socket   string
}

type capture struct {
	*leylinev1.Capture
	startedAt time.Time
}

// sampleIndex returns the capture's current sample position.
func (c *capture) sampleIndex(now time.Time) uint64 {
	return uint64(now.Sub(c.startedAt).Seconds() * float64(c.SampleRate))
}

type watcher struct {
	scope *leylinev1.EventScope
	ch    chan *leylinev1.Event
}

type presence struct {
	open    int
	expires time.Time
	timer   *time.Timer
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
		captures:  map[string]*capture{},
		channels:  map[string]*leylinev1.Channel{},
		sinks:     map[string]*leylinev1.Sink{},
		streams:   map[string]*stream{},
		watchers:  map[*watcher]struct{}{},
		presence:  map[string]*presence{},
		socket:    opts.SocketPath,
	}
	if !opts.NoDevice {
		dev := fakeRTLSDR()
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
		srv.Stop()
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

func newID(prefix string) string {
	return prefix + ulid.MustNew(ulid.Timestamp(time.Now()), rand.Reader).String()
}

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
