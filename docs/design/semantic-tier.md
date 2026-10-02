# Design: Semantic tier

Status: partial. Detections, scans, monitor jobs, recording resources, decoder records and the MCP
adapter are implemented. Watch jobs, durable transcripts, persisted spectrum snapshots, signal
identification and identity lookup are not. Companion to `control-plane.md`, `data-planes.md` and
`decoders.md`.

## Context

The semantic tier turns daemon measurements into objects that a script or agent can inspect. The
daemon computes measurements shared by every client. Client libraries and adapters format those
measurements for a terminal, app or tool call.

## State boundary

**Persistence follows intent.** A recording and a decode job marked `keep` produce durable
resources. Interactive tuning, one-time scans, monitor jobs and unkept decode jobs are ephemeral.
An ad-hoc scan remains available only while the daemon retains its finished job in memory.

**The daemon computes measurements.** Detections, levels and sample times come from the daemon.
Adapters may render images, apply band-plan labels or produce concise summaries; they do not run
signal detection or demodulation.

**Every client uses the contract.** MCP tools, `ley` verbs and the app call the same gRPC services.
A contract addition required by one client also has a `ley` representation.

## Current products

**Detection** — a centre frequency, bandwidth, SNR, floor, look count and sample time. The daemon
emits detections during scans and monitor jobs. `modulation_guess` remains empty unless a measured
heuristic can support it.

**Scan** — detections aggregated over a sweep, with its requested and covered ranges, resolution,
noise floors and gains. `ley scan` and the MCP `scan` tool start a one-time job and return the same
shape. The scan URI is valid while that job remains in the daemon's bounded finished-job table.

**Monitor result** — detections folded over time while a capture remains stationary. `ley monitor`
reports first seen, held time, on-air fraction and peak SNR. It does not create a durable resource.

**Recording** — a record job writes audio or IQ parts, a manifest and metadata under
`ley://recordings/<job_id>`. The `Resources` service lists recordings, returns their manifests,
resolves local paths and deletes whole recordings.

**Decoder records** — a decode job emits typed records. A job marked `keep` writes records under
`ley://records/<job_id>`, survives daemon restart and resumes with the same id. Client libraries
fold records into protocol-specific entity tables such as APRS stations and AIS vessels.

**Snapshot result** — the MCP `snapshot` tool subscribes to one FFT row and returns its numeric
shape with an adapter-rendered PNG. It does not create a `ley://snapshots/` resource.

## Missing products

**Activity segment and transcript** — a watch job would record squelch-open intervals, levels,
coverage gaps and optional clips under `ley://watches/<id>/transcript`. The `WatchConfig` and URI
shape are reserved, but the job runner and transcript store are not implemented. The MCP adapter
therefore does not register `get_transcript`; use `listen_summary` for one bounded observation.

**Persisted snapshot** — the contract reserves snapshot resource URIs, but no service stores an FFT
row as a resource. Use the MCP `snapshot` tool or `ley spectrum --json` for a current row.

**Signal identity** — the detector reports measured energy and never assigns a protocol or station
identity. `identify_signal`, `lookup_identity` and `whats_out_there` are not registered MCP tools.

## Jobs

The daemon implements four job configurations:

- **Scan** sweeps once and stores its result in memory.
- **Monitor** observes one stationary span for a bounded duration.
- **Record** writes a recording resource and ends on duration, quiet, cancellation or restart.
- **Decode** runs a decoder. `keep` persists its records and restarts the job after a daemon restart.

Recurring scans and watch jobs require a general durable job store and are refused. The jobs API
supports start, list, inspect and cancel; it is not a workflow engine.

## MCP surface

`ley mcp` maps tools to the same calls used by `ley`. Orientation tools list devices and state;
radio tools tune, scan, listen and take snapshots; decoder tools list decoders, query records, list
entities and start decode jobs; recording tools create, find, inspect and delete recordings; job
tools list, inspect and cancel jobs. `daemon_logs` reads the configured daemon log because the
socket cannot report why a process exited.

`docs/reference/mcp.md`, "Tools", is the complete tool schema. Each tool documents its `ley` mirror
and underlying RPC. The adapter may shorten text or render a PNG, but its structured result uses
the contract or the documented `ley --json` shape.

The capture allocator enforces the don't-disturb policy for jobs. The adapter also refuses an
implicit retune before issuing a write, so the agent receives the affected channel ids and the
`take_over` alternative.

## Open questions

- How far modulation classification can go before it requires a dedicated classifier rather than
  a measured detector heuristic.
- Whether speech-to-text belongs in the app or an adapter once watch transcripts exist.
- What retention policy a general durable job store should apply to scans, clips and transcripts.
