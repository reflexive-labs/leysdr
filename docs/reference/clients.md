# Writing a client

`ley` is one client of the daemon. The app, scripts, agents and third-party programs are peers
when they speak the `leyline.v1` contract over the daemon's Unix socket. This page contains the
requirements a client author needs before the first RPC.

## The contract

`proto/leyline/v1` is the whole contract, one file per plane plus jobs and the shared types:
`control.proto` (discovery, captures, channels, sinks, events), `telemetry.proto` (meters, squelch
transitions, detections), `bulk.proto` (IQ, FFT rows, audio), `jobs.proto` (scan, monitor,
recording and decoder jobs, with watch reserved) and `common.proto` (`SampleTime`,
`CaptureAnchor`, `Gap`, `ErrorDetail`). Changes within v1 are additive only: new fields get
new numbers, nothing is renamed or retyped, and reserved numbers stay reserved.

Ids are prefixed ULIDs (`dev_`, `cap_`, `chan_`, `job_`); resources are `ley://<kind>/<id>` URIs.
Every frame and telemetry message carries a `SampleTime`, and wall clock is derived from the
capture's anchor, never carried per frame ([data planes](../design/data-planes.md)).

## Before the first RPC

- **The socket has no authentication.** Any local process that can open it has full control of the
  radio. Client identity on the wire is attribution for the event log, not a credential.
  [SECURITY.md](../../SECURITY.md) is the full statement.
- **Use fixed HTTP/2 flow-control windows.** The daemon's HTTP/2 stack (swift-nio-http2) drops a
  connection with `GOAWAY ENHANCE_YOUR_CALM` when a client sends more than 200 control frames
  (PING, SETTINGS, PRIORITY) in 30 s, and the gRPC transport does not expose that limit. Clients
  that ping for bandwidth estimation on every data frame (grpc-go's default dynamic windows,
  grpc-python's BDP probing) therefore lose every busy bulk stream after about a second. The Go
  client library dials with 1 MiB initial stream and connection windows, which disables grpc-go's
  estimator. Other clients must do the equivalent (grpc-go: `WithInitialWindowSize` and
  `WithInitialConnWindowSize` above 64 KiB; grpc-core: `grpc.http2.bdp_probe=0`).
- **Events carry the whole object, never a delta.** Reconnect is `GetState` plus resume from the
  event `seq`. There is no client-side authoritative state: your own writes are confirmed by events
  like everyone else's ([control plane](../design/control-plane.md)).
- **Streams drop data and mark where.** Delivery is `LATEST_WINS` or `GAP_MARKED`, nothing else;
  there is no lossless network stream. A gap-marked subscription (FFT rows, IQ) gets a gap record
  naming the missing sample range before the next frame; latest-wins (audio, meters) exposes gaps
  through sequence numbers. Anything that must not drop samples belongs in a daemon-side sink.
- **Errors carry a stable code.** `ErrorDetail.code` is the machine-readable part; the message is
  prose for a person. The daemon serialises the `ErrorDetail` into the trailing metadata key
  `leyline-error-bin`, and the gRPC status it is served with follows one table, "Error codes" in
  [engine internals](../dev/engine-internals.md). A client keys on the code, never on the message.
- **A busy radio is not an error to retry.** `DEVICE_BUSY` (another client holds the radio) and
  `DEVICE_SWEEPING` (a scan job owns it for seconds) are served as `FAILED_PRECONDITION`, not
  `RESOURCE_EXHAUSTED`, so a default retry policy does not hammer a radio somebody is using.

## The Go client library

`go/pkg/leyline` (Apache-2.0) is what `ley` is built on and what the MCP adapter (`ley mcp`) shares:
the dial with the right windows, the error-code registry, subscriptions, selectors (a device,
capture or channel by id, id prefix, row number or frequency) and the recording and decoder
helpers. A Go client should start there rather than at the generated stubs in `go/gen`. Two
smaller packages beside it hold the tables `ley` reads its input with: `go/pkg/units` parses
frequencies, squelch and gain levels, bandwidths and volumes the way a person types them, and
`go/pkg/bandplan` is the band table, its channel plans and the presets drawn from them.

## Testing a client

`go/internal/fakedaemon` is an in-memory implementation of the contract that the `ley` tests run
against; it reproduces the daemon's behaviour (busy radios, sweeps, gap marks) without hardware.
`make e2e` drives a real, locally built `leylined` over a socket, and runs on Linux as well as
macOS, so a client can be tested against the daemon without a radio: `FilePlaybackDevice` plays IQ
fixtures through the whole pipeline ([IQ files and fixtures](iq-files.md)).

## `ley --json` as a worked example

Every `ley` verb's `--json` is the proto3 JSON mapping of the messages above (lowerCamelCase keys,
64-bit integers as strings, one object per line for streams), so watching `ley state --json`,
`ley tune --json` and `ley set --json` is a quick way to see the contract's shapes with real
values. The [`ley` reference](cli.md) lists the documented exceptions (bulk rows, `ley version`,
the client-local tables).

## Not yet

There is no TCP listener or remote access. `ley mcp` ([MCP adapter reference](mcp.md)) serves stdin
and stdout only. Watch jobs and transcripts, signal identification and identity lookups are not
implemented; the MCP reference lists the unavailable tools and current alternatives.
