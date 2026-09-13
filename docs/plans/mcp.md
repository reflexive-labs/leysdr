# Plan: MCP adapter

Status: draft, not started. Implements the "MCP surface" of `docs/design/semantic-tier.md` and §9
of `docs/design/decoders.md`; companion to `docs/plans/decoders.md`, whose DEC-14 ("The MCP families
and `ley identify`") is the same work seen from the decoder tier. Milestone D.16 in
`docs/plans/build-order.md`.

This is a plan and not a design because the surface it builds is already designed: the two design
docs above own the tool tables, the state boundary and the honest-detector rule, and a change that
contradicts them changes them first. What this doc adds is one architecture decision the designs left
open — where the MCP server runs — and the order the tools land in, each with how it is verified.

## The design this implements

Three principles carry over from the design docs and constrain everything below.

**One contract, three consumers** (`semantic-tier.md`). MCP tool schemas and `ley` verbs are two
renderings of the same protos as the app's client library. Every tool has a `ley` mirror, and its
`--json` output is the same proto3 JSON mapping the tool returns, so an agent and a shell script
parse identical shapes. The CLI mirror is the compatibility test for the tool.

**The engine computes signal truth; adapters render presentation** (`semantic-tier.md`,
invariant 2). Detections, measurements and records come from the daemon so every client sees the same
answer. Images, prose summaries and format conversions happen in the adapter that needs them; the
daemon never links an image library.

**Decode state lives in the decoder; interpretation state lives in the client library**
(`decoders.md` §3). Entity tables, station registries, first/last seen and "gone quiet" are a
deterministic fold over the record log, and that fold is `go/pkg/records`, shared by `ley`, the
dashboard and this adapter. External enrichment (ICAO hex to registration, MMSI to vessel) happens
"adapter-side, never in the daemon" (`decoders.md` §9). Both rules place interpretation and
enrichment in Go, in the client, not in the daemon.

## Where the server lives

The decision, made decisively: **the MCP server is a Go program that reuses `go/pkg/leyline`, shipped
as a `ley mcp` subcommand. It dials the daemon's UDS and translates MCP tool calls into leyline.v1
RPCs. It is a client of the daemon, not a second surface on it.** The two options weighed:

**(a) A Go MCP server reusing the client library.** `ley mcp` runs an MCP server; the agent's MCP
client speaks to it, and it speaks leyline.v1 to the daemon over the same UDS every other client
uses. This is what `CLAUDE.md`'s top line already names — "the MCP adapter shares its Go client
library" — and what invariant 1 requires: the adapter is a client that speaks the contract, not a
new protocol on the daemon. The interpretation folds it needs already exist in Go (`records.Table`,
`records.Summary`), and enrichment is a Go HTTP call the daemon is forbidden to make. The Go MCP SDK
is official and stable (below).

**(b) The Swift daemon exposes MCP directly.** Its real cost, item by item: it adds a second
protocol surface to the daemon, which invariant 1 calls a side channel and forbids; it reimplements
the `go/pkg/records` folds and the enrichment lookups in Swift, duplicating code the Go client
already has; it pulls interpretation state — entity tables, labels — into the daemon, against the
state boundary and the spirit of invariant 7; it makes external HTTP enrichment calls from the
daemon, which `decoders.md` §9 forbids in as many words; and it leans on less-mature Swift MCP
tooling for a process whose hot path (invariant 4) should carry no agent-driven concurrency it does
not have to.

**Verdict: (a), strongly, as a `ley mcp` subcommand.** Option (b) conflicts with three load-bearing
invariants (1, 2, 7) and one explicit design rule (enrichment adapter-side), and buys nothing in
return: `ley` is Go and always present on the machine, so there is no "the daemon is the only process
here" case that would justify a daemon-native server. No genuine reason for (b) was found.

The owner's steer — "the daemon should be able to expose the MCP server" — is honored not by putting
MCP inside `leylined` but by a `ley mcp --http` mode a launchd job can run beside the daemon (see
transport, below). The machine then offers an MCP endpoint managed alongside the daemon, with no
second protocol inside it. A subcommand of `ley` rather than a separate `leymcp` binary keeps one Go
binary to build, install and version, matching `ley` today (one binary, many verbs and views).

## Transport and trust

Two transports, from the Go MCP SDK, which offers both stdio and streamable HTTP.

**stdio, the default.** The agent's MCP client spawns `ley mcp` as a subprocess and speaks over its
stdin/stdout; the subprocess dials the daemon UDS. This inherits the local-user trust model exactly
as `ley` does: anything that can spawn `ley mcp` could already run `ley`, so the adapter grants an
agent no privilege a shell did not already have. Ship this first.

**streamable HTTP, behind auth, later.** `ley mcp --http :PORT` serves a persistent endpoint for a
remote or long-lived agent, the mode a launchd job would run. This is a network listener, and unlike
the UDS it is reachable off the box, so it must require a bearer token at minimum — an unauthenticated
HTTP mode is never shipped. This tracks the control-plane decision that remote access "becomes its own
milestone with auth designed properly" (`control-plane.md`, "Auth for TCP remote access"); the HTTP
transport waits on that milestone and is a later build item, not the first.

**The trust the adapter exposes, stated plainly.** The daemon socket has no authentication: anything
that opens it can tune, take over a sweep, destroy another client's capture and read samples
(`SECURITY.md`, "What the daemon trusts"). An MCP server hands that surface to an agent. Over stdio
that is the same boundary a local shell already crosses, and acceptable. Over HTTP it is a new
boundary and needs the token above. Two further guards carry over from the designs: the don't-disturb
default is enforced adapter-side as refusal-with-reason and daemon-side as policy, belt and
suspenders (`semantic-tier.md`), so a `tune`-like tool refuses to retune an active capture unless the
user said to take over; and the TX interlock (`decoders.md` §10, invariant 11) means no tool ever
transmits — there is no TX in the contract yet, and when there is, an emission lease gates it, never
an MCP tool.

## The tool surface

One surface unifying the semantic-tier control/observe tools, the decoder families and the composite.
Each tool names the leyline.v1 RPC it calls and the `ley` verb that mirrors it. "Build" marks what
maps onto RPCs and a verb that exist today; "Blocked" names the dependency.

| Tool | Maps to | `ley` mirror | Status |
|---|---|---|---|
| `list_devices` | `Control.ListDevices` | `ley devices` | build |
| `get_state` | `Control.GetState` | `ley state` | build |
| `tune` | `Control.CreateCapture`/`CreateChannel`/`WriteParams` | `ley tune`, `ley set` | build |
| `scan` | `Jobs.StartJob(ScanConfig{once})` + `Jobs.GetScan` | `ley scan` | build |
| `listen_summary` | `Telemetry.Subscribe` (bounded) | `ley listen` | build |
| `snapshot` | `Bulk.Subscribe(FFT, one row)` | `ley spectrum` / `ley fft` | partial: data now, PNG render and `ley://snapshots` persistence to build |
| `list_decoders` | `Decoders.ListDecoders` | `ley decoders` | build |
| `query_records` | `Decoders.QueryRecords` | `ley records` | build |
| `list_entities` | `Decoders.SubscribeRecords` + `records.Table` fold | `ley track` | build |
| `start_decode_job` | `Jobs.StartJob(DecodeConfig)` | `ley decode --job`, `ley watch` | build |
| `list_jobs` / `get_job` / `cancel_job` | `Jobs.ListJobs`/`GetJob`/`CancelJob` | `ley jobs` | build |
| `find_recordings` | `Resources.ListResources` | `ley recordings` | blocked: the Resources service and the recording store are unbuilt (C.12; `jobs.proto` notes GetScan "is not yet a Resource"). `ley://records/<job_id>` exists now via the record store |
| `get_transcript` | `Jobs.GetTranscript` | `ley watch` (audio) | blocked: audio-transcript watch jobs are D.15 |
| `identify_signal` | characteriser + snapshot | `ley identify` | blocked: needs the honest characteriser and `ley identify` (DEC-14) |
| `lookup_identity` | adapter-side external lookups | (enrichment; no verb yet) | blocked: no external lookup adapters exist |
| `whats_out_there` | composite (below) | — | blocked: needs `identify_signal` |

The buildable tools cover orientation, control, observing the band, and the highest-value decoder
family: `query_records` is the tool `decoders.md` §9 calls "the highest-value tool; agents are good
at it," and it, `start_decode_job`, `list_decoders` and `list_entities` all read RPCs that shipped
with the decoder tier (`Decoders.QueryRecords`/`SubscribeRecords`, `Jobs.StartJob(DecodeConfig)`,
`go/pkg/records`). The blocked tools wait on capabilities named in other plans, not on the adapter.

**`identify_signal` stays honest.** It returns measured characteristics — bandwidth, burst timing, a
symbol-rate estimate, spectral shape — from the daemon, plus a modulation guess carrying its
confidence, and a snapshot image the adapter renders. It never asserts a protocol. This is invariant
12 and the honest-detector rule of `semantic-tier.md`: a guess is labelled a guess, a peak is never
called a signal, and the tool's contract says so in its own description so an agent does not read more
into it than the daemon measured.

## `whats_out_there`, the composite

The one tool that is a new capability rather than a rendering of one RPC, and the demonstration that
sells the project (`decoders.md` §9). It runs a pipeline over pieces that already exist:

1. **Sweep** a frequency range: `Jobs.StartJob(ScanConfig{once})` then `Jobs.GetScan`, the same path
   as the `scan` tool and `ley scan`. Out come detections: centre, bandwidth, SNR, first/last seen.
2. **Characterise** each detection with `identify_signal`: measured characteristics plus a
   confidence-stated guess. This is the step that blocks the composite until DEC-14 lands.
3. **Match installed decoders**: read `Decoders.ListDecoders` (`ley decoders`) and compare each
   detection's centre and bandwidth against every manifest's recipe. A decoder whose recipe covers
   the frequency is a candidate; optionally start a short `start_decode_job` to confirm records
   actually appear before claiming the match.
4. **Return a labelled inventory**: per detection, the measured characteristics, the guess and its
   confidence, any candidate decoder, and any records the confirmation step decoded, each record
   rendered one-line by `records.Summary`.

It reuses scan (built), `ListDecoders`/`StartDecode`/`QueryRecords` and the `records` folds (built);
the new parts are the orchestration and `identify_signal`. Honesty carries through the whole tool: a
candidate decoder is a match hypothesis, not a claim the signal is that protocol until records
decode, and every label carries the confidence the characteriser stated.

## Resources

MCP resources map one-to-one onto `ley://` URIs, read through `Resources.ListResources`,
`Resources.GetResource` and `Resources.ResolveLocalPath` (a UDS client reads the file directly):
`ley://recordings/<id>`, `ley://scans/<id>`, `ley://snapshots/<id>`, `ley://records/<job_id>` and
`ley://watches/<id>/transcript`. Of these, only `ley://records/<job_id>` has a store behind it today
(the decoder record store, `docs/plans/decoders.md` DEC-5); recordings, scans and snapshots become
resources when the Resources service and their stores are built, so the resource tools land with that
store, not before.

The adapter's value-adds beyond proto transcription are presentation, and so client-side: PNG
rendering for snapshots, waterfall thumbnails for transcripts, and compact text summaries of scans
and records (band-plan labels on detections; `records.Summary` already renders a record as the line
`ley decode` prints) so an agent spends context on reasoning rather than JSON. The daemon does none
of this.

## Status legend and build items

`[ ]` pending, `[x]` done, `[-]` dropped with the reason, `[d]` waiting on a decision. Nothing here
is started. Every item is verified three ways, matching the repository's pattern: fake-daemon tests
for the tool-to-RPC mapping (`go/internal/fakedaemon`, which already fakes the decoder RPCs, DEC-6),
one end-to-end test against the real daemon (`go/internal/e2e`, as `TestDecodeAgainstRealDaemon`
does), and the `ley` mirror as the compatibility check that tool and verb read the same shape.

### MCP-1 `[ ]` The server and the stdio transport

`ley mcp` runs an MCP stdio server built on the official Go SDK, dialling the daemon UDS through
`go/pkg/leyline` — the same `Dial` every verb uses, so the adapter is provably a client. Tool
registration is a table; the first tool can be `list_devices` to prove the round trip. Verify: an MCP
client lists the server's tools; a fake-daemon test that the server's daemon connection is the shared
client and nothing else.

### MCP-2 `[ ]` Orient and control tools

`list_devices`, `get_state`, `tune`, mapped to the `Control` RPCs, with `tune` refusing to retune an
active capture unless told to take over (don't-disturb, adapter-side). Verify: a fake-daemon test per
tool; an e2e that `tune` refuses an active capture and names why.

### MCP-3 `[ ]` Observe tools

`scan`, `listen_summary`, and `snapshot`'s data (binned FFT from `Bulk.Subscribe`, one row). Verify:
fake-daemon per tool; an e2e that `scan` over `ley play` of a fixture returns the fixture's
detections.

### MCP-4 `[ ]` Decoder tools

`list_decoders`, `query_records`, `list_entities` (the `records.Table` fold over
`SubscribeRecords`), `start_decode_job`. Verify: fake-daemon over the DEC-6 decoders fake; an e2e that
`ley decode aprs` on the `aprs_afsk` fixture writes records a `query_records` call then returns.

### MCP-5 `[ ]` Job control

`list_jobs`, `get_job`, `cancel_job` over the `Jobs` RPCs. Verify: fake-daemon; the `ley jobs` mirror
returns the same job shapes.

### MCP-6 `[ ]` Value-add renders

`snapshot` PNG rendering and compact text summaries for scans and records (`records.Summary`), all
adapter-side. Verify: a snapshot render produces a PNG of the negotiated bin count; a summary matches
the line `ley` prints for the same record.

### MCP-7 `[ ]` Resource tools

`find_recordings` and the other `ley://` resources, once the Resources service and the recording,
scan and snapshot stores exist. `ley://records/<job_id>` can be exposed ahead of the rest, since its
store is built. Verify: fake-daemon over faked resources; `ley recordings` returns the same URIs.
Blocked on the Resources service (C.12).

### MCP-8 `[ ]` `identify_signal`

The honest characteriser and `ley identify` (DEC-14) land first; the tool renders their output plus a
snapshot. Verify: characteristics equal the daemon's measurements; the guess carries confidence and
the tool's own description forbids reading a protocol into it. Blocked on DEC-14.

### MCP-9 `[ ]` `lookup_identity` enrichment

Adapter-side external lookups (ICAO hex to registration and type, MMSI to vessel, callsign to
licence) with a cache, plus the `device_id`-to-label lookup that reads the client-side label store.
Verify: fake lookup fixtures; the tool works offline for the label case and degrades to
"unknown" with no network for the external ones. Blocked: no lookup adapters exist.

### MCP-10 `[ ]` `whats_out_there`

The composite, once `identify_signal` exists (MCP-8). Verify: an e2e over a fixture carrying two
known signals returns a labelled inventory naming a matched decoder for the one a decoder covers.
Blocked on MCP-8.

### MCP-11 `[ ]` `get_transcript` and audio-watch tools

Once D.15 audio-transcript watch jobs land, `get_transcript` and a watch tool over
`Jobs.GetTranscript`. Verify: fake-daemon; `ley watch` mirror. Blocked on D.15.

### MCP-12 `[d]` streamable HTTP transport, behind auth

`ley mcp --http :PORT` with a bearer token, for a remote or launchd-run endpoint. Held for the
remote-access milestone that designs auth (`control-plane.md`). Verify, when built: the endpoint
refuses an unauthenticated request; a token-bearing MCP client drives the same tools as stdio.

## Deliberately not

- **MCP inside the daemon.** The rejected option: a second protocol surface (invariant 1), Swift
  reimplementation of Go folds and enrichment, interpretation state and external HTTP in the daemon
  (invariant 7 and `decoders.md` §9). The daemon stays a radio.
- **Custom tool shapes.** Tools return the standard proto3 JSON mapping, the same as `ley --json`; no
  bespoke schemas an agent would learn separately from the contract.
- **Client-side DSP in the adapter** (invariant 2). Characterisation measurements come from the
  daemon; the adapter renders and orchestrates, never demodulates or measures.
- **Authoritative interpretation state in the adapter.** Folds are deterministic over the record log
  (`go/pkg/records`); the adapter holds no state a reconnect could not rebuild, matching invariant 7's
  spirit on the client side.
- **Unauthenticated HTTP.** stdio inherits local-user trust; HTTP does not, and never ships without a
  token.
- **Speech-to-text on transcripts.** An app- or adapter-side candidate later (`semantic-tier.md` open
  questions), not this plan.
- **TX tools.** No TX exists (invariant 11); when it does, an emission lease gates it, not a tool.

## Open questions

- **The HTTP auth model** — bearer token, mTLS, or fold into the remote-access milestone whole.
  Decide when a remote-agent story is real, not before (`control-plane.md`, "Auth for TCP remote
  access").
- **`list_entities` as a tool versus leaving agents to call `query_records` and fold themselves.**
  Leaning tool, because the fold is the value and it is already written; revisit if the tool count
  starts to crowd an agent's choices.
- **`identify_signal` characteristics as a resource** — persist only when job-initiated, under
  persistence-follows-intent (the same question `decoders.md` open item 12 leaves for the
  characteriser).
- **Enrichment sources and offline behaviour** — which registries, cache policy, and what a lookup
  returns with no network. Decide when the first lookup adapter is written.
- **Tool granularity against an agent's context budget** — how many tools before an agent chooses
  badly; job control may collapse into fewer tools if the count grows.

## The Go MCP SDK

`github.com/modelcontextprotocol/go-sdk` is the official Go SDK for MCP, maintained in collaboration
with Google, and reached a stable v1.0.0 that guarantees no breaking API changes going forward; it
implements essentially the whole MCP spec and offers both the stdio and streamable-HTTP transports
this plan uses. Checked 2026-09-13 against the SDK's releases page
(https://github.com/modelcontextprotocol/go-sdk/releases) and package docs
(https://pkg.go.dev/github.com/modelcontextprotocol/go-sdk/mcp); the v1.0.0 notes are at
https://github.com/modelcontextprotocol/go-sdk/releases/tag/v1.0.0. Pin the version in `go.mod` at
build time and record the pinned version in the closing section when MCP-1 lands.
</content>
</invoke>
