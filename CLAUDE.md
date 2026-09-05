# CLAUDE.md — Leyline

Native macOS SDR engine + app. Read `docs/design-*.md` before structural changes — every invariant below has a rationale there. This file is the enforcement summary.

## What this is

A launchd daemon (the engine) owning SDR hardware, with the SwiftUI app, `ley` CLI/TUI, and MCP adapter as peer clients over one gRPC contract (`proto/leyline.v1`). Mac-only on purpose — use platform frameworks (vDSP, CoreAudio, Metal, IOUSBHost, os_signpost) without apology. Languages: **Swift** for the engine and Mac app; **Go** for terminal clients — `ley` is one Go binary (CLI verbs + Bubble Tea TUI) and the MCP adapter shares its Go client library. The Go clients are the living proof of the cross-language contract; never let a feature ship that only works from Swift.

## Invariants — do not violate without a design-doc change

1. **One protocol.** All clients speak leyline.v1 over gRPC (UDS). No XPC, no side channels. The shm ring for local bulk streams is the single documented bypass, negotiated via `Bulk.Subscribe`.
2. **Daemon-side DSP.** Capture, channelize, demod, FFT all run in the daemon. Clients render. Never move DSP client-side for convenience — it breaks CLI/agent parity.
3. **No lossless network stream.** Delivery is LATEST_WINS or GAP_MARKED, nothing else. Anything that must not drop samples is a daemon-side FileSink.
4. **Hot path is allocation-free.** `Demodulator.process`, `AudioSink.write`, ring writes: no allocation, no locks held across calls, no async, buffers borrowed via `SampleBuffer`. If you need to allocate, you're in the wrong layer.
5. **Sample timebase everywhere.** Every frame and telemetry message carries `SampleTime`. Wall clock is derived from `CaptureAnchor` only. Never add a per-frame wall-clock field.
6. **Events carry full object state.** Never deltas. Reconnect = `GetState` + resume from seq.
7. **State lives in the daemon.** Clients render subscribed state; their own writes are confirmed by events like everyone else's. No client-side authoritative state.
8. **Persistence follows intent.** Job outputs are resources; interactive actions are ephemeral unless explicitly kept.
9. **Jobs go through `CaptureAllocator`.** It owns the don't-disturb policy. Jobs never touch captures directly.
10. **One device per capture.** Multi-SDR coherence, if ever, is a composite *device*.
11. **TX is a sibling, never a retrofit.** Transmissions arrive as their own concept beside Capture, with their own timeline IDs and an emission lease. Never bolt TX onto Channel, Sink, or RadioDevice; TX-capable hardware composes a separate protocol. See the control-plane doc's TX forward-compatibility entry.
12. **The detector stays honest.** `modulation_guess` is empty or cheap-heuristic with stated confidence. No dressed-up guessing.
13. **The wire contract is generated; engine protocols are not.** Never hand-edit generated code; never generate `engine/CoreProtocols.swift`.

## Conventions

- IDs: prefixed ULIDs (`cap_`, `chan_`, `job_`…). Resource URIs: `ley://<kind>/<id>`.
- `--json` CLI output is the standard proto3 JSON mapping — no custom shapes.
- Proto changes: additive only within v1; run `protoc` validation in CI; reserved field numbers stay reserved.
- Instrument the sample path with `os_signpost` from the start — the spikes depend on it.
- Errors: stable machine codes in `ErrorDetail.code`; prose goes in `message`.
- Licensing: GPL is fine (open-source engine); prefer first-party driver bindings (librtlsdr, libhackrf, vendor SDKs) wrapped behind `RadioDevice`.

## Testing without hardware

`FilePlaybackDevice` is the test harness: the entire pipeline runs headless from IQ fixtures. `fixtures/` contains generated signals (NFM tone, AM, USB, CW, noise-floor calibration) with expected demod outputs. Every DSP change must pass fixture round-trips. Hardware-in-the-loop tests are a separate, manually-run suite.

## Build order

Follow `docs/build-order.md`. Spikes S1–S3 gate everything: if S2 (20 MSPS throughput) fails its threshold, stop and escalate — the all-Swift decision gets revisited, not worked around silently.
