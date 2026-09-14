# Design: Semantic Tier

Status: draft. Covers §4 of the planning doc. Companion to `control-plane.md` and `data-planes.md`.

## Context

The layer that turns samples into things an agent — or a script, or a future UI feature — can reason about. It lives partly in the daemon (anything computed from signals, shared by all clients) and partly in adapters (anything that is presentation). The MCP surface and CLI are two renderings of the same contract.

## Principles

**Persistence follows intent.** Jobs are declared intents; their outputs are durable resources. Interactive actions are ephemeral unless explicitly kept. This one rule answers scans (job scans persist, ad-hoc don't), transcripts (watch jobs produce them, casual monitoring doesn't), and snapshots (kept only when requested).

**The engine computes signal truth; adapters render presentation.** Detections, segments, and measurements come from the daemon so every client sees the same answer. Images, prose summaries, and format conversions happen in the adapter that needs them — the daemon never links an image library.

**One contract, three consumers.** MCP tool schemas and CLI verbs are mapped one-to-one from the same protos as the app's client library. An agent, a shell script, and the UI can each do anything the others can.

## Derived products

**Detection** — the atom of the tier: center frequency, bandwidth, SNR, first/last seen (sample timebase), optional modulation guess. Streamed on telemetry; aggregated into scans and watch results.

**Scan** — a sweep's aggregated detections plus sweep metadata (range, resolution, dwell, noise floor per segment). Job scans persist as `ley://scans/<id>`; ad-hoc scans return the same shape inline and are gone when the client is.

**Activity segment** — a contiguous interval where a watched channel's squelch was open: start/end timestamps, peak/mean signal, and optionally a recorded audio clip. The building block of transcripts.

**Transcript** — a watch job's rolling log: ordered activity segments with clip references. `ley://watches/<id>/transcript`. "Watch 146.52 and log anything heard" produces exactly this. Speech-to-text is explicitly not the engine's job — a transcript is what the radio observed, not what was said. (Apple's Speech framework in the adapter or app is a candidate later; flagged in open questions.)

**Snapshot** — a spectrum capture at a moment: binned FFT data plus capture context. The daemon produces the data; the MCP adapter renders PNG when an agent wants to look at it. Persisted only on request: `ley://snapshots/<id>`.

**Recording** — already defined as a sink; here it gains queryable metadata (frequency, mode, timebase anchor, duration, originating job if any) so agents can find and fetch by description rather than filename.

## The v0 detector

Scope deliberately narrow: energy detection over the FFT ladder. Noise-floor estimation per segment, threshold crossing, carrier center and bandwidth estimation, SNR, persistence tracking (merge across sweep passes, assign first/last seen). Modulation classification ships as a guess field that v0 populates only with cheap heuristics (bandwidth class, carrier presence) or leaves empty — a real classifier is a later, isolated improvement that slots into the existing field. The detector runs daemon-side and feeds both the telemetry stream and scan/watch aggregation.

## Jobs

Three job types at v0, each a typed config payload on the small job API from the control-plane doc:

- **watch** — required frequency/mode, optional clip recording, optional end time. Owns a persistent channel; produces a transcript; logs coverage gaps when `out-of-capture`.
- **scan** — range, step/resolution, dwell, schedule (once or recurring). Produces persisted scans. Respects don't-disturb: uses an idle device or declines with a stated reason.
- **record** — frequency/mode/window. Produces a recording with full metadata.

Results flow twice: live as telemetry/events while running, and durable as resources. An agent that started a watch and disconnected queries the transcript later; an agent that stays connected streams segments as they happen.

## MCP surface

This is the design for Milestone D.16. The build plan -- where the MCP server runs and the order the
tools land -- is `docs/plans/mcp.md`, and the tools the daemon can back are implemented as `ley mcp`
(2026-09-14; the reference is `docs/reference/mcp.md`). Of the table below, `start_job` exists as
`start_decode_job`, since decode is the one job an agent can start today (watch and record configs
are Milestone D.15); `get_transcript` and `find_recordings` wait on D.15 and C.12; the decoder
tools the plan added (`list_decoders`, `query_records`, `list_entities`) are in the reference. Tools
map one-to-one onto RPCs (names indicative):

| Tool | Maps to | Notes |
|---|---|---|
| `list_devices` | Control.ListDevices | descriptors with capability detail |
| `get_state` | Control.GetState | orientation: captures, channels, activity |
| `tune` | CreateCapture/CreateChannel/WriteParams | refuses to retune active captures (don't-disturb) unless `override: true`; returns refusal reason |
| `listen_summary` | Telemetry.Subscribe (bounded) | subscribes for `duration_s`, returns activity segments observed |
| `scan` | Jobs.StartJob(ScanConfig{once}) + Jobs.GetScan | inline results, ephemeral: the job dies with the client that started it. Recurring scans need the durable store (D.15) and are refused |
| `snapshot` | Bulk.Subscribe(FFT, one row) | returns PNG (adapter-rendered) + binned data |
| `start_job` / `list_jobs` / `get_job` / `cancel_job` | Jobs service | watch, scan, record configs as typed payloads |
| `get_transcript` | Jobs.GetTranscript | segments + coverage gaps; adapter adds waterfall thumbnails |
| `find_recordings` | Resources.ListResources | metadata-filtered; returns `ley://` URIs |

Resources map one-to-one onto `ley://` URIs. The adapter's value-adds beyond proto transcription: PNG rendering for snapshots, waterfall thumbnails for transcripts, and compact text summaries of scans (band-plan labels applied to detections) so agents spend context on reasoning rather than JSON.

The don't-disturb default from the control-plane doc is enforced adapter-side as refusal-with-reason, and daemon-side as policy — belt and suspenders, since not every MCP client will be polite.

## CLI mirror

Every tool above has a verb: `ley devices`, `ley tune`, `ley scan`, `ley watch`, `ley jobs`, `ley recordings`. `--json` output is the proto's JSON mapping, so a shell script and an agent parse identical shapes. The CLI adds nothing the protocol doesn't have — it is the reference client and the compatibility test.

## Open questions

- Modulation classification — how far to take the guess field before it needs real DSP or a model. Defer until detections exist in practice.
- Speech-to-text on transcripts via Apple's Speech framework — app-side feature candidate, not engine scope. Decide when transcripts are real.
- Store retention — clips and scans accumulate; need a policy (size cap + age, user-visible). Decide before v1b ships, not before it's built.

## Phase exit

With the two companion docs, the contract is fully specified in prose. §5 transcribes: proto files (control, telemetry, bulk, jobs, resources), Swift protocols, MCP manifest, CLI tree.
