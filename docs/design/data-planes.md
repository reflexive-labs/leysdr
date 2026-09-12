# Design: Telemetry & Bulk Planes

Status: draft. Covers §3 of the planning doc. Companion to `design-control-plane.md`.

## Context

Three planes total. Control (previous doc) carries state and intent. This doc covers the other two: telemetry — low-rate structured observations (meters, squelch transitions, detections) — and bulk — sample-bearing streams (IQ, FFT rows, demodulated audio, decoded bytes). The split exists because the two have opposite delivery needs: telemetry is small, typed, and every message matters; bulk is large, negotiated, and mostly latest-wins.

## Timebase

Every frame on both planes carries a sample-indexed timestamp: `(capture_id, sample_index)` where index counts samples since capture start at the capture's rate. The daemon maintains one wall-clock anchor per capture (sample 0 → host time, plus measured drift). Consequences:

- Alignment across streams is exact by construction — an FFT row, a detection, and an audio block from the same capture can be placed on one timeline without clock math in clients.
- Wall-clock is derived, never carried per-frame. Clients that want it apply the anchor.
- Recordings store the anchor in metadata, so replayed captures keep a truthful timeline. This is the foundation the V2 DVR and terrain views stand on.

## Delivery policy

Per-stream, declared at subscription, two policies only:

- **latest-wins** — daemon drops oldest under backpressure; sequence numbers expose gaps. Default for everything a human is looking at: display FFT, meters, monitor audio.
- **gap-marked** — daemon still drops under sustained backpressure but never silently: a gap record with the missing sample range precedes the next frame. For clients doing external processing on IQ or decoded bytes.

There is no reliable/lossless network stream. Anything that must be lossless (recording, job results) runs as a daemon-side sink and lands in the store. This single rule keeps backpressure trivial: the network never owes anyone perfect delivery.

## Bulk plane

### Transports

- **Local fast path: shared-memory ring.** One ring per subscribed stream, single producer (daemon), multiple readers. Layout: fixed header (magic, version, stream descriptor, slot size/count, monotonic write sequence) followed by slots of (sequence, sample timestamp, payload length, payload). Readers chase the write sequence; a reader that falls behind detects overrun by sequence check and resynchronizes — latest-wins by construction. Ring creation and teardown are negotiated over the control plane; the ring itself carries no control information.
- **Everything else: gRPC server-streams.** Frames are a thin protobuf envelope (stream id, sequence, timestamp, gap record if any) with payload as opaque bytes — samples are never protobuf-encoded per element. Remote full-rate IQ is possible but discouraged by defaults; the negotiation exists precisely so remote clients take decimated or derived streams instead.

### Negotiation

Subscription is an offer/answer over the control plane. The client states stream type, desired rate/resolution/format, and delivery policy; the daemon answers with what it will actually provide (it may downgrade, never upgrade). The answer is authoritative and appears in the stream descriptor, so a client can always interpret frames without out-of-band knowledge.

### Stream types and formats

- **IQ** — complex samples at negotiated rate; formats cs8, cs16, cf32. Native device format is offered first to avoid daemon-side conversion when the client doesn't need it.
  - *v0 contract:* the daemon serves cf32 at the capture's native rate only. `Bulk.Subscribe(IQ)` validates the request instead of overriding it — `format` must be `UNSPECIFIED` or `CF32`, `sample_rate` must be `0` or the capture rate — and refuses anything else with `INVALID_ARGUMENT` ("downgrade, never upgrade" honoured by refusing). cs8/cs16 and decimated IQ are a v1 addition.
- **FFT rows** — (bins, bin format db-u8 or db-f32, row rate, window id, center, span). Resolution and rate are negotiated per subscriber; the daemon computes from a shared internal ladder of sizes so N subscribers don't mean N FFT passes at arbitrary sizes.
- **Audio** — demodulated output of a channel: negotiated rate (8/16/48 kHz), s16 or f32, mono. Compression (Opus) is an open question, gated until a remote-audio story demands it.
- **Decoded bytes** — framed output of digital decoders when those arrive; the envelope is the same, payload semantics come from the channel's mode.

### Seek shape

Every subscription takes a start position: `live` (default), `timestamp`, or `sample_index`. v0 implements `live` only and rejects the rest with UNIMPLEMENTED — but the field exists in the schema from day one, so DVR-style history reads later are an implementation, not a protocol revision. Historical reads will serve from daemon-side capture rings and recordings; that design is deferred.

## Telemetry plane

A gRPC server-stream of typed messages, subscribed with a scope filter (daemon, capture, or channel) and an optional type filter. Rates are 1–30 Hz per source. Types at v0:

- **Meter** — per-channel: signal power (dBFS), estimated SNR, squelch open/closed. Emitted at a fixed cadence while the channel is active.
- **Squelch transition** — edge-triggered open/close with sample timestamp. Redundant with Meter's level reads but exact in time — this is what transcript-style features key on.
- **Detection** — from the V0 detector: center frequency, bandwidth, SNR, first/last seen timestamps, optional modulation guess. Emitted during scans and by watch jobs.
- **Capture activity** — the aggregate signal agents use for don't-disturb: interactive-write recency, live audio sinks. Derived by the daemon from control-plane traffic.

Telemetry messages are full protobuf (unlike bulk payloads) — they are small, and typed schema is the point. All carry the sample timebase. Delivery is drop-oldest with sequence numbers: when a subscriber falls behind, the daemon evicts the oldest unread readings (never the newest) and advances `seq` past each one, so a gap in `seq` is the only trace of a missed meter reading — not an event worth recovering.

Rationale for a separate plane rather than folding into control events: control events describe state someone changed; telemetry describes what the radio observes. Clients almost always want one without the other — the CLI tuning a channel doesn't want 30 Hz meters; a meter widget doesn't want session lifecycle. Separate subscriptions keep both simple.

## Open questions

- FFT ladder — **decided:** fixed power-of-two set for v0; revisit if subscriber-population data shows waste. The §6 spike measures the fixed ladder.
- Opus for remote audio — deferred; now tied to the remote-access milestone (see control plane doc: v0 is UDS-only).
- Detections as resources — **decided:** job-initiated scans persist as addressable resources (`ley://scans/<id>`); ad-hoc CLI/UI scans are stream-only and ephemeral. Details in the §4 semantic-tier doc.

## Phase exit

With `design-control-plane.md`, this completes the protocol surface. Next: §4 semantic tier doc, then the §5 proto files and Swift protocols fall out of the three docs.
