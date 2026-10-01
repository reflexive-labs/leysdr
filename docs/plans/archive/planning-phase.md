# Plan: Leyline SDR planning and design phase

Goal for this phase: resolve the open architectural questions and land interface designs in code (types, interfaces, protocol schemas) — no function bodies yet.

## 0. User stories (do first)
- [x] Define v0 user stories (CLI-only) — see `docs/plans/user-stories.md`.
- [x] Define v1a (initial UI) and v1b (MVP agent access) stories.
- [x] Sketch v2 candidates (visual showcase) without committing scope.
- [x] Use stories to pressure-test the control/data plane split before schema work. → Findings: three planes not two (add telemetry); sinks and sessions first-class; detector moves to V0; sample-indexed timebase everywhere; seekable stream API shape from day one.

## 1. Architecture decisions
- [x] **Engine language:** All-Swift. Engine as a Swift package (SwiftNIO daemon, swift-argument-parser CLI), vDSP/Accelerate directly in-process — no cgo boundary, no C core to maintain. GC concern replaced by ARC/copy discipline in the sample path (still spike-gated, see §6).
- [x] **DSP placement:** daemon-side end-to-end (capture → channelize → demod → FFT); clients render only. Forced by V0 stories — CLI/agent parity.
- [x] **Process model:** launchd daemon owning hardware; app/CLI/MCP as peer clients. Lifecycle + arbitration details land with the session schema (§2).
- [x] **Licensing strategy:** engine is open source — GPL question dissolves; link librtlsdr directly. Distribution: direct + notarized only, no App Store. Paid app vs. sponsorship deferred. → Decided in full 2026-09-12: everything open (engine GPL-3.0-or-later, all else Apache-2.0), revenue from the notarized build and a content layer; `docs/decisions/D2-licensing.md`.

## 2. Control plane
- [x] Define the self-describing device/capability model (borrow SoapySDR's introspection shape). → `docs/design/control-plane.md`
- [x] Choose protocol: gRPC (grpc-swift) over UDS/TCP, one protocol everywhere, shm ring as documented local bypass. → `docs/design/control-plane.md`
- [x] Draft the session model: captures → channels → sinks; jobs; arbitration via attribution + requirements + don't-disturb. → `docs/design/control-plane.md`

## 3. Data plane
- [x] Tiered transport design: shm ring (local) / gRPC streams (everything else); offer-answer negotiation; two delivery policies (latest-wins, gap-marked); lossless work stays daemon-side as sinks. → `docs/design/data-planes.md`
- [x] Wire formats for IQ, FFT rows, audio, decoded frames; sample-indexed timebase; seekable subscription shape (live-only in v0); versioned envelopes. → `docs/design/data-planes.md`

## 4. Semantic / agent tier
- [x] Define derived products: detections, scans, activity segments, transcripts, snapshots, recording metadata. → `docs/design/semantic-tier.md`
- [x] MCP tool surface + CLI verb mirror, both mapped one-to-one from protos; adapter value-adds (image rendering, summaries). → `docs/design/semantic-tier.md`
- [x] Job/watch model semantics — three job types; results live as events + durable as resources. → `docs/design/semantic-tier.md`

## 5. Interface design in code (phase exit deliverable)
Conventions decided: monorepo (engine, app, CLI, MCP adapter, protos; split app later only if monetization demands); proto package `leyline.v1`, one file per plane; prefixed ULIDs for IDs; standard proto3 JSON mapping for `--json`; engine-internal protocols hand-designed, never generated. **Languages: Swift for engine + Mac app (vDSP/CoreAudio/Metal); Go for terminal clients** — `ley` is
one Go binary (CLI verbs + terminal live views today: `spectrum --watch`, `waterfall`, `phosphor`;
the dashboard is Milestone D.14) and doubles as the cross-language contract test; MCP adapter in Go sharing the same client library; Swift client façade is app-only. **Name: Leyline** (brand) / **leysdr** (repo, domain, unique handle); CLI binary `ley`; scheme `ley://`. USPTO check on "Leyline" before first public release.
- [x] Swift: engine package layout; core protocols (Device, Stream, DemodChain, Sink, Job, Detector) — signatures only. → `leysdr/engine/CoreProtocols.swift`
- [x] Protobuf/schema files for control + telemetry + bulk planes (+ jobs/resources). Validated with protoc. → `leysdr/proto/*.proto`
- [x] MCP tool surface + CLI command tree, mapped to the protos. → `leysdr/docs/reference/cli.md`. The Swift client façade transcribes from the protos at build time — first implementation task, not a design artifact.

## 6. Validation spikes (de-risk before committing)
- [ ] RTL-SDR → daemon → shared memory → Metal waterfall end-to-end latency measurement.
- [ ] Swift sample-path throughput at 20 MSPS (HackRF rate): allocation-free buffer discipline, vDSP pipeline, worst-case latency under load.
- [x] Sandboxed vs. unsandboxed USB access check on current macOS (informs how far "direct + notarized" can harden). → `docs/decisions/S3-usb-posture.md` (one host-side check outstanding).

## Out of scope this phase
Function implementations, UI visual design, digital decoders, TX.
