# Leyline — Build Order

Agent-sized tasks with acceptance criteria. V0 user stories in `docs/plans/user-stories.md` are the acceptance tests of record; tasks reference them. Sequence matters: each task's dependencies are the tasks above it.

## Spikes (gate everything)

**S1 — Latency chain.** RTL-SDR → daemon → shm ring → minimal Metal waterfall. Measure antenna-to-pixels with os_signpost. Pass: p95 under 50 ms, no dropped ring slots at 2.4 MSPS over 10 minutes. Artifact: an Instruments trace and a one-page findings note.

**S2 — Throughput.** Synthetic 20 MSPS cf32 source → channelizer → one NFM demod → null sink, allocation-free. Pass: sustained 10 min, zero allocations in the sample path (verified with Instruments allocations track), CPU headroom ≥ 50% on a base M-series. Fail = stop; revisit the all-Swift decision explicitly.

**S3 — USB posture.** IOUSBHost vs libusb for RTL-SDR and HackRF, sandboxed and not, current macOS. Artifact: a decision note updating the CLAUDE.md licensing/driver line if needed.

## Milestone A — skeleton that talks

1. Repo scaffold: SwiftPM workspace (EngineCore, Daemon, App) + Go module (`ley` CLI/TUI, McpAdapter, shared client lib); proto codegen wired for both languages (protoc-gen-swift, protoc-gen-go/go-grpc); CI running protoc validation + both test suites.
2. Daemon lifecycle: launchd plist, UDS listener, `ley daemon start|stop|status`, `ley state` returning an empty GetState.
3. Fixtures: IQ signal generator producing `fixtures/` (NFM tone, AM, USB, CW, calibrated noise); FilePlaybackDevice implementing RadioDevice. *(V0 story: playback through the same pipeline.)*

## Milestone B — samples flow

4. DeviceRegistry + RTLSDRDevice (per S3's decision); hot-plug events; stable IDs across replug. *(Story: devices list; unplug/replug.)*
5. CaptureEngine: device stream → fan-out, CaptureAnchor, detached/rebind states.
6. FFT ladder + shm ring + gRPC FFT stream. `ley fft` works against fixtures. *(Story: fft stream.)*
7. NFM demod + CoreAudioSink: `ley tune 146.52M` produces audio. Fixture round-trip test. *(Story: tune and hear.)*

## Milestone C — the contract proves out

8. WriteParams coalescing; `ley set` live adjust; events with attribution. *(Story: live adjust.)*
9. Second client concurrency: two CLIs, one device; state sync verified. *(Story: no device-busy.)*
10. Remaining demods (AM, WFM, SSB, CW) — one task each, fixture-gated.
11. Dual channels in one capture. *(Story: two NFM channels.)*
12. FileSink recording + Resources + `ley record` / `ley play` / `ley recordings`. *(Story: record/playback.)*

## Milestone D — semantic tier

13. **Done.** Detector (energy detection, noise floor, persistence tracking); telemetry plane; `ley scan`. *(Story: scan with detections.)* Design and measured numbers: `docs/design/scan.md`.
14. TUI dashboard: bare `ley` opens a Bubble Tea dashboard — shaded-cell waterfall from a negotiated low-rate FFT stream, tuning controls, channel list, meters from telemetry. First real exercise of stream negotiation by a constrained consumer.
15. Jobs: store, JobRunner respawn, CaptureAllocator with don't-disturb; watch job → ActivitySegments → transcript.
16. MCP adapter (Go, sharing the `ley` client library); tools from `docs/reference/cli.md`; snapshot PNG rendering.
17. Decoders: the out-of-process plugin contract, the record envelope and store, decode jobs, and
    APRS as the first decoder (`ley decoders`, `ley decode aprs`, `ley records`, `ley track aprs`).
    Design and the build plan: `docs/design/decoders.md`, `docs/plans/decoders.md`. Started ahead
    of D.14 to D.16 because the contract it proves (plugins, records, the store) is what the MCP
    adapter's highest-value tools read.

Each task lands with: tests (fixture-based where DSP), os_signpost instrumentation on any new sample-path code, and no invariant violations (CLAUDE.md is the review checklist).
