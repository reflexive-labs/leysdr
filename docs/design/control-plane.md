# Design: Control Plane

Status: draft. Covers §2 of the planning doc — capability model, protocol, session model. Telemetry and bulk planes get their own docs.

## Context

The engine is a launchd daemon that owns SDR hardware. The Mac app, CLI, MCP adapter, and any third-party client are peers speaking one protocol. The control plane carries everything low-rate and stateful: discovery, tuning, session lifecycle, jobs. It does not carry samples, FFT rows, audio, or meter readings — those belong to the bulk and telemetry planes.

Decisions already made that constrain this design: all-Swift engine, daemon-side DSP, one protocol everywhere (no XPC), open source, Mac-only.

## Protocol

Proposal: gRPC (grpc-swift) over UDS locally, TCP for remote. Protobuf is the single source of truth — the CLI, app client library, and MCP tool schemas are generated from it.

Why not custom framing: we would reinvent streaming, backpressure, versioning, and deadlines, and third-party clients would have to implement our invention. gRPC's cost is dependency weight in the daemon, which we accept once. The local shared-memory ring for the waterfall is the one documented bypass — negotiated over the control plane, transported outside it.

Server-streaming RPCs carry event subscriptions. Client-streaming carries coalesced parameter writes (below). No bidirectional streams in v0 — they complicate clients for no current story.

## Capability model

Devices self-describe. A client never hardcodes "RTL-SDR has one gain knob." Discovery returns a `DeviceDescriptor`:

- identity: driver, model, serial, USB location, connection state
- tuning: one or more frequency ranges (Hz)
- sampling: supported rates, native sample format
- gain: an ordered list of gain elements, each with name, range, step, and an auto flag
- clock: whether the device timestamps samples, drift characteristics if known
- features: bias-tee, direct sampling, TX capability — a string-keyed map with typed values, so drivers can expose vendor features without schema changes

The shape borrows from SoapySDR's introspection model. The string-keyed feature map is the escape hatch; everything with cross-device meaning gets a first-class field.

Virtual devices — IQ file playback, network sources — implement the same descriptor. Playback is not a special mode; it is a device whose "tuning range" is whatever the recording says.

## Session model

Three levels, matching the pressure-test findings:

**Capture** — an open stream on a device at a center frequency and sample rate. Captures are shared resources. The daemon owns them; clients hold references. One device supports one capture (v0; multi-capture devices later via the feature map).

**Channel** — a demod chain inside a capture: offset from center, bandwidth, mode, filter, squelch, AGC. A capture fans out to N channels. Channels are cheap; clients create them freely. Each channel is owned by the client that created it and dies with that client's last connection unless marked persistent (jobs create persistent channels).

**Sink** — where a channel's output goes: `system-audio` (daemon plays via CoreAudio), `stream` (client pulls over the bulk plane), `file` (daemon records with metadata). A channel supports multiple sinks. Recording is a sink, not a feature.

State lives in the daemon only. Clients are renderers of state they subscribe to. Every mutation produces an event on the capture's event stream; a client's own writes are confirmed the same way as everyone else's — there is no "my state" versus "their state."

## Arbitration

The contested resource is capture tuning — retuning a shared capture moves every channel riding on it. Scenario analysis (see planning notes) showed the realistic conflicts are human-vs-job and human-vs-agent, not human-vs-human. Leases were considered and rejected: they add protocol for the rarest case (two humans tuning simultaneously) while solving neither common one.

Decided approach — three simple mechanisms:

**Last-write-wins with attribution.** Any client may retune. Every state event names the client that caused it, so contention is visible and attributable without a lease protocol. Two windows retuning the same capture means one person is dragging in both, which does not need protocol support.

**Jobs declare requirements and degrade gracefully.** A job's channel records its required frequency. If the capture retunes away, the channel enters `out-of-capture`: the job logs a coverage gap and rebinds automatically when the capture returns (or claims an idle device if one exists). Nothing errors; the human is never blocked by a job.

**Agents observe a don't-disturb default.** Captures expose an activity signal (live audio sink, recent interactive writes). Agent clients refuse to retune an active capture by default — they use an idle device, work within the current capture, or report why they can't proceed. Explicit override available when the user tells the agent to take over.

Gated for later: true multi-operator arbitration (club-station scenario). If it ever matters, leases can be layered on without schema changes — attribution and the activity signal are the primitives a lease would need anyway.

## Parameter writes

Drag-to-tune emits writes at display rate. Setter RPCs are fire-and-forget within a client-streaming RPC: the client streams `ParamWrite` messages, the daemon coalesces (last value per parameter per tick), applies, and emits state events. No per-write acknowledgment. Correctness is restored by the event stream — the client renders confirmed state, optimistically previews its own writes, and reconciles on the next event. Validation failures (out-of-range frequency) come back as events referencing the write's client-assigned tag.

## Events and lifecycle

One event stream per scope: daemon scope (device arrival/removal, capture created/destroyed) and capture scope (state changes, lease changes, channel lifecycle, errors). Events carry the full new state of the changed object, not deltas — clients never patch state and can always render from the latest event. Sequence numbers per stream; a client that reconnects issues a state fetch and resumes from its seq (`WatchEvents` with `since_seq` replays the daemon's retained window of events newer than the snapshot before going live, so nothing between the fetch and the stream's registration is missed; a snapshot older than the window shows as a seq gap, and the client fetches state again).

Device removal does not destroy the capture: it enters `detached`, channels pause, and replug of a device with the same serial rebinds automatically. This makes the V1a unplug/replug story a state transition rather than a teardown.

## Jobs

A job is a daemon-owned persistent intent: watch, scheduled record, scan-and-log. Jobs own persistent channels and sinks, survive client disconnect and daemon restart (respawned from the store), and write results as resources. The job API is deliberately small — create, list, inspect, cancel — with job-type-specific config as typed payloads. This is a table of watches, not a workflow engine; there is no retry DAG, no replay. A watch that was down while the daemon was down simply missed that time.

## Resources

Recordings, spectrum snapshots, and job results are addressable: `ley://recordings/<id>`, with metadata queries over the control plane and content retrieval over the bulk plane (or direct file paths locally — the daemon's store is a plain directory the Finder can see). MCP resource URIs map onto these one-to-one.

## Open questions

- Multi-device captures — **decided:** a capture references exactly one device. Coherent multi-SDR rigs, if ever supported, are absorbed by the device abstraction (a composite device presenting N synchronized SDRs as one descriptor). The session model never changes.
- Auth for TCP remote access — **decided for v0:** UDS-only; no TCP listener ships. Local UDS trusts the user account. Remote access becomes its own milestone with auth designed properly (and Bonjour discovery alongside it). This decision is deferred; the protos reserve nothing for it yet, so field numbers for auth are not guaranteed to be free when that milestone lands.
- TX forward-compatibility — **direction set (implementation later):** TX is expected eventually and arrives as a sibling concept, not a retrofit. A `Transmission` (device + modulator + audio/IQ source + emission constraints) sits alongside `Capture`; channels and sinks stay RX-only. Transmissions own their own timeline (`SampleTime` scopes by ID string, so `tx_` IDs fit without schema change). Devices advertise `tx_capable` and `full_duplex` in the feature map; half-duplex devices (HackRF) suspend capture to emit, and that arbitration is device-level. Emitting requires an emission lease — a real lease, unlike tuning, because RF emission carries regulatory weight (license, band limits, power). All additive; nothing in v1 protos changes shape.

## Phase exit

This doc plus the telemetry/bulk doc feed directly into the proto files and Swift protocol definitions in §5.
