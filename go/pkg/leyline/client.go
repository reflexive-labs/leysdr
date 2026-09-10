package leyline

import (
	"context"
	"crypto/rand"
	"io"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/oklog/ulid/v2"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

// Metadata keys every RPC carries so the daemon can attribute events.
const (
	MetaClientID    = "leyline-client-id"
	MetaClientKind  = "leyline-client-kind"
	MetaClientLabel = "leyline-client-label"
)

var (
	processIDOnce sync.Once
	processID     string
)

// ProcessClientID returns the "cli_" ULID generated once per process and sent as
// leyline-client-id on every RPC.
func ProcessClientID() string {
	processIDOnce.Do(func() { processID = NewID("cli_") })
	return processID
}

// ulidEntropy is monotonic within a millisecond so ids minted back-to-back still sort in
// creation order (row numbers depend on it); ulid.Monotonic is not safe for concurrent use.
var (
	ulidMu      sync.Mutex
	ulidEntropy = ulid.Monotonic(rand.Reader, 0)
)

// NewID returns prefix + a fresh 26-character ULID (e.g. NewID("chan_")). Ids are monotonic:
// two ids from the same process sort in the order they were made, even within one millisecond.
func NewID(prefix string) string {
	ulidMu.Lock()
	defer ulidMu.Unlock()
	return prefix + ulid.MustNew(ulid.Timestamp(time.Now()), ulidEntropy).String()
}

// Option configures Dial.
type Option func(*Client)

// WithKind sets leyline-client-kind ("cli" | "app" | "mcp" | "job"). Default "cli".
func WithKind(kind string) Option { return func(c *Client) { c.kind = kind } }

// WithLabel sets leyline-client-label. Default: basename of os.Args[0].
func WithLabel(label string) Option { return func(c *Client) { c.label = label } }

// WithClientID overrides the per-process client id (tests, or a job impersonating
// its own identity). Default ProcessClientID().
func WithClientID(id string) Option { return func(c *Client) { c.id = id } }

// WithDialOptions appends extra grpc.DialOptions.
func WithDialOptions(opts ...grpc.DialOption) Option {
	return func(c *Client) { c.dialOpts = append(c.dialOpts, opts...) }
}

// Client is a connection to one daemon. The typed service clients are exposed
// directly; the helpers below wrap the common client workflows.
type Client struct {
	Control   leylinev1.ControlClient
	Telemetry leylinev1.TelemetryClient
	Bulk      leylinev1.BulkClient
	Jobs      leylinev1.JobsClient
	Resources leylinev1.ResourcesClient

	conn     *grpc.ClientConn
	path     string
	id       string
	kind     string
	label    string
	dialOpts []grpc.DialOption
}

// Dial connects to the daemon's UDS at socketPath (DefaultSocketPath() if empty).
// The connection is lazy; the first RPC fails with an UNAVAILABLE Error if no
// daemon is listening. ctx is not consulted — there is no connect-time work to
// bound — but stays in the signature so an eager-connect option can honour it
// without breaking callers.
func Dial(ctx context.Context, socketPath string, opts ...Option) (*Client, error) {
	if socketPath == "" {
		socketPath = DefaultSocketPath()
	}
	c := &Client{
		path:  socketPath,
		id:    ProcessClientID(),
		kind:  "cli",
		label: filepath.Base(os.Args[0]),
	}
	for _, o := range opts {
		o(c)
	}
	dialOpts := append([]grpc.DialOption{
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		// Fixed 1 MiB windows: enough for full-rate bulk streams over the local socket, and a
		// window above 64 KiB disables grpc-go's bandwidth-estimation PINGs, which otherwise fire
		// on every data frame of a busy stream.
		grpc.WithInitialWindowSize(1 << 20),
		grpc.WithInitialConnWindowSize(1 << 20),
		grpc.WithChainUnaryInterceptor(c.unaryInterceptor),
		grpc.WithChainStreamInterceptor(c.streamInterceptor),
	}, c.dialOpts...)
	conn, err := grpc.NewClient("unix://"+socketPath, dialOpts...)
	if err != nil {
		return nil, FromStatus(err)
	}
	c.conn = conn
	c.Control = leylinev1.NewControlClient(conn)
	c.Telemetry = leylinev1.NewTelemetryClient(conn)
	c.Bulk = leylinev1.NewBulkClient(conn)
	c.Jobs = leylinev1.NewJobsClient(conn)
	c.Resources = leylinev1.NewResourcesClient(conn)
	return c, nil
}

// ClientID returns the leyline-client-id this client sends.
func (c *Client) ClientID() string { return c.id }

// SocketPath returns the socket this client dialled.
func (c *Client) SocketPath() string { return c.path }

// Conn exposes the underlying connection for custom stubs.
func (c *Client) Conn() *grpc.ClientConn { return c.conn }

// Close closes the connection; open streams end with a CANCELED error.
func (c *Client) Close() error { return c.conn.Close() }

func (c *Client) withMeta(ctx context.Context) context.Context {
	return metadata.AppendToOutgoingContext(ctx,
		MetaClientID, c.id, MetaClientKind, c.kind, MetaClientLabel, c.label)
}

// unaryInterceptor attaches identity metadata and maps failures to *Error using
// the trailer-carried ErrorDetail when present.
func (c *Client) unaryInterceptor(ctx context.Context, method string, req, reply any, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
	var trailer metadata.MD
	opts = append(opts, grpc.Trailer(&trailer))
	err := invoker(c.withMeta(ctx), method, req, reply, cc, opts...)
	if err != nil {
		return FromStatusWithTrailer(err, trailer)
	}
	return nil
}

// streamInterceptor attaches identity metadata and wraps the stream so that
// RecvMsg/SendMsg/CloseSend failures are mapped to *Error.
func (c *Client) streamInterceptor(ctx context.Context, desc *grpc.StreamDesc, cc *grpc.ClientConn, method string, streamer grpc.Streamer, opts ...grpc.CallOption) (grpc.ClientStream, error) {
	s, err := streamer(c.withMeta(ctx), desc, cc, method, opts...)
	if err != nil {
		return nil, FromStatus(err)
	}
	return &errStream{ClientStream: s}, nil
}

type errStream struct{ grpc.ClientStream }

func (s *errStream) mapErr(err error) error {
	if err == nil || err == io.EOF {
		return err
	}
	return FromStatusWithTrailer(err, s.Trailer())
}

func (s *errStream) RecvMsg(m any) error { return s.mapErr(s.ClientStream.RecvMsg(m)) }
func (s *errStream) SendMsg(m any) error { return s.mapErr(s.ClientStream.SendMsg(m)) }
func (s *errStream) CloseSend() error    { return s.mapErr(s.ClientStream.CloseSend()) }

// State fetches the daemon-scoped GetState snapshot.
func (c *Client) State(ctx context.Context) (*leylinev1.GetStateResponse, error) {
	st, err := c.Control.GetState(ctx, &leylinev1.GetStateRequest{
		Scope: &leylinev1.EventScope{Scope: &leylinev1.EventScope_Daemon{Daemon: true}},
	})
	if err != nil {
		return nil, err
	}
	SortState(st)
	return st, nil
}

// SortState orders every list in a state snapshot by id. Ids are prefixed ULIDs, so this is
// creation order, and it is what makes the row numbers ley prints ("channel 2") stable no
// matter how a daemon happens to enumerate its tables.
func SortState(st *leylinev1.GetStateResponse) {
	if st == nil {
		return
	}
	sort.SliceStable(st.Devices, func(i, j int) bool { return st.Devices[i].DeviceId < st.Devices[j].DeviceId })
	sort.SliceStable(st.Captures, func(i, j int) bool { return st.Captures[i].CaptureId < st.Captures[j].CaptureId })
	sort.SliceStable(st.Channels, func(i, j int) bool { return st.Channels[i].ChannelId < st.Channels[j].ChannelId })
	sort.SliceStable(st.Sinks, func(i, j int) bool { return st.Sinks[i].SinkId < st.Sinks[j].SinkId })
}

// FindCapture returns the capture on deviceID (at most one exists), or nil.
// An empty deviceID returns the first capture, if any.
func FindCapture(state *leylinev1.GetStateResponse, deviceID string) *leylinev1.Capture {
	if state == nil {
		return nil
	}
	for _, cap := range state.Captures {
		if deviceID == "" || cap.DeviceId == deviceID {
			return cap
		}
	}
	return nil
}

// CurrentChannel picks the "current" channel from a snapshot: the most recently
// created ACTIVE channel (ULIDs sort by creation time), preferring channels
// owned by clientID. Returns nil when there are none.
func CurrentChannel(state *leylinev1.GetStateResponse, clientID string) *leylinev1.Channel {
	if state == nil {
		return nil
	}
	var mine, any *leylinev1.Channel
	for _, ch := range state.Channels {
		if ch.State != leylinev1.ChannelState_CHANNEL_ACTIVE {
			continue
		}
		if any == nil || ch.ChannelId > any.ChannelId {
			any = ch
		}
		if clientID != "" && ch.Owner != nil && ch.Owner.ClientId == clientID {
			if mine == nil || ch.ChannelId > mine.ChannelId {
				mine = ch
			}
		}
	}
	if mine != nil {
		return mine
	}
	return any
}

// Event is one WatchEvents message.
type Event = leylinev1.Event

// DaemonScope is the EventScope covering the whole daemon.
func DaemonScope() *leylinev1.EventScope {
	return &leylinev1.EventScope{Scope: &leylinev1.EventScope_Daemon{Daemon: true}}
}

// CaptureScope is the EventScope covering one capture.
func CaptureScope(captureID string) *leylinev1.EventScope {
	return &leylinev1.EventScope{Scope: &leylinev1.EventScope_CaptureId{CaptureId: captureID}}
}

// ScopeSince returns scope with since_seq set: WatchEvents replays the
// daemon's retained events newer than seq (a GetState snapshot's event_seq,
// 0 included) before going live, so "GetState then WatchEvents" misses
// nothing. A nil scope means the daemon scope.
func ScopeSince(scope *leylinev1.EventScope, seq uint64) *leylinev1.EventScope {
	if scope == nil {
		scope = DaemonScope()
	}
	out := proto.Clone(scope).(*leylinev1.EventScope)
	out.SinceSeq = proto.Uint64(seq)
	return out
}

// Events opens WatchEvents and pumps it into a channel. The event channel is
// closed when the stream ends; the error channel then receives exactly one value
// (nil on a clean end, ctx.Err() on cancellation, or the mapped *Error). Holding
// the stream open is what keeps this client's non-persistent channels alive.
// Pass ScopeSince(scope, state.EventSeq) to resume from a GetState snapshot.
func (c *Client) Events(ctx context.Context, scope *leylinev1.EventScope) (<-chan *Event, <-chan error, error) {
	if scope == nil {
		scope = DaemonScope()
	}
	stream, err := c.Control.WatchEvents(ctx, scope)
	if err != nil {
		return nil, nil, err
	}
	events, errs := pump(ctx, stream.Recv, 64)
	return events, errs, nil
}

// WatchTelemetry opens Telemetry.Subscribe and pumps it into a channel with
// the same contract as Events: the message channel closes when the stream
// ends and the error channel then carries exactly one value (nil on a clean
// end, ctx.Err() on cancellation, or the mapped *Error).
func (c *Client) WatchTelemetry(ctx context.Context, sub *leylinev1.TelemetrySubscription) (<-chan *leylinev1.TelemetryMsg, <-chan error, error) {
	stream, err := c.Telemetry.Subscribe(ctx, sub)
	if err != nil {
		return nil, nil, err
	}
	msgs, errs := pump(ctx, stream.Recv, 16)
	return msgs, errs, nil
}

// pump is the one server-stream reader behind Events, WatchTelemetry and
// Subscribe: recv until the stream ends, forward each message, close the
// message channel, then report exactly one terminal error: nil on io.EOF
// (the daemon ended the stream), ctx.Err() when ctx ended, else the error.
func pump[T any](ctx context.Context, recv func() (T, error), buffer int) (<-chan T, <-chan error) {
	out := make(chan T, buffer)
	errs := make(chan error, 1)
	go func() {
		defer close(out)
		for {
			m, err := recv()
			if err != nil {
				switch {
				case err == io.EOF:
					errs <- nil
				case ctx.Err() != nil:
					errs <- ctx.Err()
				default:
					errs <- err
				}
				return
			}
			select {
			case out <- m:
			case <-ctx.Done():
				errs <- ctx.Err()
				return
			}
		}
	}()
	return out, errs
}

// WriteParams opens one WriteParams stream, sends every write in order, closes
// the send side and returns the daemon's summary. Rejections are not returned
// here — they arrive as WriteRejected events tagged with the write's tag.
func (c *Client) WriteParams(ctx context.Context, writes ...*leylinev1.ParamWrite) (*leylinev1.WriteSummary, error) {
	stream, err := c.Control.WriteParams(ctx)
	if err != nil {
		return nil, err
	}
	for _, w := range writes {
		if err := stream.Send(w); err != nil {
			if err == io.EOF {
				break // server closed early; CloseAndRecv returns the real status
			}
			return nil, err
		}
	}
	return stream.CloseAndRecv()
}

// Frame is one bulk-plane frame.
type Frame = leylinev1.Frame

// Subscription is an open bulk-plane stream: the authoritative descriptor plus a
// channel of frames. Frames is closed when the stream ends; Err then yields the
// terminal error (nil on a clean end). Close unsubscribes on the daemon.
type Subscription struct {
	Descriptor *leylinev1.StreamDescriptor
	Frames     <-chan *Frame
	errs       <-chan error
	cancel     context.CancelFunc
	client     *Client

	// The pump sends its terminal error exactly once, so the first read has to keep
	// it: callers ask Err repeatedly, and separate goroutines may drain Frames and
	// check Err.
	mu      sync.Mutex
	errRead bool
	err     error
}

// Err returns the stream's terminal error once Frames is closed. It is
// repeatable: every call after the first returns the same error.
func (s *Subscription) Err() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.errRead {
		return s.err
	}
	select {
	case err := <-s.errs:
		s.errRead = true
		s.err = err
		return err
	default:
		return nil
	}
}

// Close cancels the frame pump and unsubscribes on the daemon.
func (s *Subscription) Close() error {
	s.cancel()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_, err := s.client.Bulk.Unsubscribe(ctx, &leylinev1.StreamRef{StreamId: s.Descriptor.StreamId})
	return err
}

// Subscribe negotiates a bulk stream and starts pulling frames over gRPC. The
// request's transport is forced to GRPC (the shm ring reader is a later
// milestone) and start defaults to live.
func (c *Client) Subscribe(ctx context.Context, req *leylinev1.SubscribeRequest) (*Subscription, error) {
	// The caller keeps its request — to retry with, or to log what it asked for — so
	// the transport and start defaults go on a copy.
	req = proto.Clone(req).(*leylinev1.SubscribeRequest)
	req.Transport = leylinev1.Transport_GRPC
	if req.Start == nil {
		req.Start = &leylinev1.StreamPosition{Position: &leylinev1.StreamPosition_Live{Live: true}}
	}
	desc, err := c.Bulk.Subscribe(ctx, req)
	if err != nil {
		return nil, err
	}
	sctx, cancel := context.WithCancel(ctx)
	stream, err := c.Bulk.Stream(sctx, &leylinev1.StreamRef{StreamId: desc.StreamId})
	if err != nil {
		cancel()
		return nil, err
	}
	frames, errs := pump(sctx, stream.Recv, 16)
	return &Subscription{Descriptor: desc, Frames: frames, errs: errs, cancel: cancel, client: c}, nil
}

// SubscribeFFT subscribes to the FFT ladder of a capture. bins/rowsPerSecond/format
// are desires; read the returned Descriptor for what the daemon serves. FFT rows
// are requested GAP_MARKED so a consumer processing rows (rather than painting
// them) sees a Gap on the first frame after a drop; audio and IQ stay LATEST_WINS.
func (c *Client) SubscribeFFT(ctx context.Context, captureID string, bins uint32, rowsPerSecond float64, format leylinev1.FftBinFormat) (*Subscription, error) {
	return c.SubscribeFFTAccumulated(ctx, captureID, bins, rowsPerSecond, format, leylinev1.FftAccumulation_ROW_SNAPSHOT)
}

// SubscribeFFTAccumulated is SubscribeFFT with a say in how each row is built.
// ROW_SNAPSHOT takes one periodogram per row, which covers a fraction of a
// percent of it: right for a chart of "now", wrong for anything reading duty
// cycle. ROW_MAX looks across the whole row, so a burst shorter than a row is
// still drawn. The descriptor answers with the looks actually taken.
func (c *Client) SubscribeFFTAccumulated(ctx context.Context, captureID string, bins uint32, rowsPerSecond float64,
	format leylinev1.FftBinFormat, acc leylinev1.FftAccumulation,
) (*Subscription, error) {
	return c.Subscribe(ctx, &leylinev1.SubscribeRequest{
		Source: &leylinev1.SubscribeRequest_CaptureId{CaptureId: captureID},
		Kind:   leylinev1.StreamKind_FFT,
		Policy: leylinev1.DeliveryPolicy_GAP_MARKED,
		Params: &leylinev1.SubscribeRequest_Fft{Fft: &leylinev1.FftParams{
			Bins: bins, BinFormat: format, RowsPerSecond: rowsPerSecond, Accumulation: acc,
		}},
	})
}

// SubscribePersistence subscribes to a capture's persistence (phosphor)
// histogram: for each frequency bin, how often each level has been seen lately.
//
// floorDb and rangeDb are required and the daemon does not guess them: a
// histogram on the wrong scale is not obviously wrong to look at. Take one FFT
// row first to find the floor.
func (c *Client) SubscribePersistence(ctx context.Context, captureID string, bins, levels uint32,
	floorDb, rangeDb, halfLifeSeconds, rowsPerSecond float64,
) (*Subscription, error) {
	return c.Subscribe(ctx, &leylinev1.SubscribeRequest{
		Source: &leylinev1.SubscribeRequest_CaptureId{CaptureId: captureID},
		Kind:   leylinev1.StreamKind_PERSISTENCE,
		Policy: leylinev1.DeliveryPolicy_LATEST_WINS,
		Params: &leylinev1.SubscribeRequest_Persistence{Persistence: &leylinev1.PersistenceParams{
			Bins: bins, Levels: levels, FloorDb: floorDb, RangeDb: rangeDb,
			HalfLifeSeconds: halfLifeSeconds, RowsPerSecond: rowsPerSecond,
		}},
	})
}

// SubscribeAudio subscribes to a channel's demodulated audio. sampleRate 0 asks
// for the channel's native audio rate.
func (c *Client) SubscribeAudio(ctx context.Context, channelID string, sampleRate uint32, format leylinev1.AudioSampleFormat) (*Subscription, error) {
	return c.Subscribe(ctx, &leylinev1.SubscribeRequest{
		Source: &leylinev1.SubscribeRequest_ChannelId{ChannelId: channelID},
		Kind:   leylinev1.StreamKind_AUDIO,
		Params: &leylinev1.SubscribeRequest_Audio{Audio: &leylinev1.AudioParams{SampleRate: sampleRate, Format: format}},
	})
}

// SubscribeIQ subscribes to a capture's raw IQ at the capture rate, CF32.
func (c *Client) SubscribeIQ(ctx context.Context, captureID string) (*Subscription, error) {
	return c.Subscribe(ctx, &leylinev1.SubscribeRequest{
		Source: &leylinev1.SubscribeRequest_CaptureId{CaptureId: captureID},
		Kind:   leylinev1.StreamKind_IQ,
		Params: &leylinev1.SubscribeRequest_Iq{Iq: &leylinev1.IqParams{Format: leylinev1.SampleFormat_CF32}},
	})
}
