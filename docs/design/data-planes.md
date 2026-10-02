# Design: Telemetry & Bulk Planes

Status: partial. Telemetry, gRPC bulk streams, FFT accumulation, channel-audio FFT and persistence
frames are implemented. The shared-memory transport, historical stream positions and decoded-byte
subscriptions are not. Companion to `control-plane.md`.

## Context

Three planes total. Control (previous doc) carries state and intent. This doc covers the other two: telemetry — low-rate structured observations (meters, squelch transitions, detections) — and bulk — sample-bearing streams (IQ, FFT rows, demodulated audio, decoded bytes). The split exists because the two have opposite delivery needs: telemetry is small, typed, and every message matters; bulk is large, negotiated, and mostly latest-wins.

## Timebase

Every frame on both planes carries a sample-indexed timestamp: `(capture_id, sample_index)` where index counts samples since capture start at the capture's rate. The daemon maintains one wall-clock anchor per capture (sample 0 → host time, plus measured drift). Consequences:

- Alignment across streams is exact by construction — an FFT row, a detection, and an audio block from the same capture can be placed on one timeline without clock math in clients.
- Wall-clock is derived, never carried per-frame. Clients that want it apply the anchor.
- Recordings store the anchor in metadata, so replayed captures keep an accurate timeline.

## Delivery policy

Per-stream, declared at subscription, two policies only:

- **latest-wins** — daemon drops oldest under backpressure; sequence numbers expose gaps. Default for everything a human is looking at: display FFT, meters, monitor audio.
- **gap-marked** — daemon still drops under sustained backpressure but never silently: a gap record with the missing sample range precedes the next frame. For clients doing external processing on IQ or decoded bytes.

There is no reliable or lossless network stream. Lossless work, including recording, writes to a
daemon-side store. Network backpressure can therefore discard bulk frames according to the
subscription's delivery policy.

## Bulk plane

### Transports

- **Shared-memory ring, reserved but not implemented.** The contract defines one ring per stream,
  with one daemon writer and multiple readers. A request for `SHM_RING` currently receives a gRPC
  descriptor. Clients must use the descriptor's transport rather than assuming the request was
  accepted.
- **gRPC server streams.** Every current subscription uses a protobuf frame containing the stream
  id, sequence, sample time, optional gap and opaque payload. Samples are not encoded as individual
  protobuf fields.

### Negotiation

A subscription request specifies the stream type, requested rate, resolution, format and delivery
policy. The returned `StreamDescriptor` is authoritative and contains the parameters required to
interpret each frame. The daemon may downgrade a request but never upgrades it.

### Stream types and formats

- **IQ** — complex samples at negotiated rate; formats cs8, cs16, cf32. Native device format is offered first to avoid daemon-side conversion when the client doesn't need it.
  - *v0 contract:* the daemon serves cf32 at the capture's native rate only. `Bulk.Subscribe(IQ)` validates the request instead of overriding it — `format` must be `UNSPECIFIED` or `CF32`, `sample_rate` must be `0` or the capture rate — and refuses anything else with `INVALID_ARGUMENT` ("downgrade, never upgrade" honoured by refusing). cs8/cs16 and decimated IQ are a v1 addition.
- **FFT rows** — (bins, bin format db-u8 or db-f32, row rate, window id, center, span). Resolution and rate are negotiated per subscriber; the daemon computes from a shared internal ladder of sizes so N subscribers don't mean N FFT passes at arbitrary sizes.
- **Audio** — demodulated output of a channel: negotiated rate (8/16/48 kHz), s16 or f32, mono. Compression (Opus) is an open question, gated until a remote-audio story demands it.
- **Decoded bytes** — reserved in `StreamKind`; current decoders exchange frames with the daemon's
  plugin runner and expose typed records through the decoder service instead.

### Seek shape

Every subscription takes a start position: `live` (default), `timestamp`, or `sample_index`. v0 implements `live` only and rejects the rest with UNIMPLEMENTED — but the field exists in the schema from day one, so DVR-style history reads later are an implementation, not a protocol revision. Historical reads will serve from daemon-side capture rings and recordings; that design is deferred.

## Telemetry plane

A gRPC server-stream of typed messages, subscribed with a scope filter (daemon, capture, or channel) and an optional type filter. Rates are 1–30 Hz per source. Types at v0:

- **Meter** — per-channel: signal power (dBFS), estimated SNR, squelch open/closed. Emitted at a fixed cadence while the channel is active.
- **Squelch transition** — edge-triggered open/close with sample timestamp. Redundant with Meter's level reads but exact in time — this is what transcript-style features key on.
- **Detection** — from the V0 detector: center frequency, bandwidth, SNR, first/last seen timestamps, optional modulation guess. Emitted during scans and by watch jobs.
- **Capture activity** — the aggregate signal agents use for don't-disturb: interactive-write recency, live audio sinks. Derived by the daemon from control-plane traffic.

Telemetry messages are full protobuf (unlike bulk payloads) — they are small, and the typed schema is why they exist as a separate plane. All carry the sample timebase. Delivery is drop-oldest with sequence numbers: when a subscriber falls behind, the daemon evicts the oldest unread readings (never the newest) and advances `seq` past each one, so a gap in `seq` is the only trace of a missed meter reading — not an event worth recovering.

Rationale for a separate plane rather than folding into control events: control events describe state someone changed; telemetry describes what the radio observes. Clients almost always want one without the other — the CLI tuning a channel doesn't want 30 Hz meters; a meter widget doesn't want session lifecycle. Separate subscriptions keep both simple.

## Open questions

- FFT ladder — **decided:** fixed power-of-two set for v0; revisit if subscriber-population data shows waste. The §6 spike measures the fixed ladder.
- Opus for remote audio — deferred; now tied to the remote-access milestone (see control plane doc: v0 is UDS-only).
- Detections as resources — **decided:** job-initiated scans persist as addressable resources (`ley://scans/<id>`); ad-hoc CLI/UI scans are stream-only and ephemeral. Details in the §4 semantic-tier doc.

The implemented wire shape is in `proto/leyline/v1/bulk.proto` and
`proto/leyline/v1/telemetry.proto`.
