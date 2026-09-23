# AGENTS.md — Leyline

Native macOS SDR engine + app. Read `docs/design/*.md` before structural changes — every invariant below has a rationale there; `docs/dev/engine-internals.md` is the implementation contract (threads, hot path, pipeline math, daemon rules); `docs/writing-guide.md` is how every document, help text, error line, comment and commit message is written, and `docs/README.md` says which page is for whom. This file is the enforcement summary.

## What this is

A launchd daemon (the engine) owning SDR hardware, with the SwiftUI app (`app/`, its own SwiftPM package; `docs/dev/app.md`), `ley` CLI/TUI, and MCP adapter as peer clients over one gRPC contract (`proto/leyline.v1`). Mac-only, so use platform frameworks (vDSP, CoreAudio, Metal, IOUSBHost, os_signpost) directly. Languages: **Swift** for the engine and Mac app; **Go** for terminal clients — `ley` is one Go binary (CLI verbs + terminal live views today: `spectrum --watch`, `waterfall`,
`phosphor`; the dashboard is Milestone D.14) and the MCP adapter shares its Go client library. The Go clients show that the contract works across languages; never ship a feature that only works from Swift.

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
12. **The detector does not overclaim.** `modulation_guess` is empty or a cheap heuristic with a stated confidence. Never present a guess as more certain than that.
13. **The wire contract is generated; engine protocols are not.** Never hand-edit generated code (`go/gen`, `swift/LeylineProto` — run `make proto`); never generate `engine/Sources/EngineCore/CoreProtocols.swift`.

## Conventions

- IDs: prefixed ULIDs (`cap_`, `chan_`, `job_`…). Resource URIs: `ley://<kind>/<id>`.
- The app (`app/`) links `LeylineProto` and never `EngineCore` (`make license-check` refuses it); its
  views render `AppSession`, a copy of `DaemonMirror`, and write through `WriteCoalescer`, never a
  state of their own; its
  tests run against `leylined --no-hardware` with a fixture as the radio (`make app-e2e`). Colours
  and type live in `Theme.swift` only. Every contract addition the app needs ships with its `ley`
  mirror. `LeylineApp` is declared under `#if os(macOS)` and is never compiled in the container, so
  a passing Linux run does not test any view: read the diff by eye for isolation, scope, `Sendable`
  and layout, and name the files and behaviours left unverified when handing over
  (`docs/dev/swift-style.md`, "Working as an agent on this repository").
- `--json` CLI output is the standard proto3 JSON mapping — no custom shapes.
- Proto changes: additive only within v1; run `protoc` validation in CI. Reserved field numbers stay reserved once a field people depend on has been retired; before the first public release a number a plan parked as a placeholder (`Meter` 7 and 8, the signal-views plan) is taken by that plan's item, not skipped.
- Instrument the sample path with `os_signpost` from the start — the spikes depend on it.
- Errors: stable machine codes in `ErrorDetail.code`; prose goes in `message`.
- Licensing: GPL is fine (open-source engine); prefer first-party driver bindings (librtlsdr, libhackrf, vendor SDKs) wrapped behind `RadioDevice`.
- Docs: `docs/README.md` is the map, by reader (`guide/`, `reference/`, `design/`, `dev/`, `decisions/`, `plans/`); prose follows `docs/writing-guide.md`, and Swift follows `docs/dev/swift-style.md` as `ley`'s output follows `docs/dev/cli-style.md`. A moved page takes every `docs/` reference with it. The "Error codes" table in `docs/dev/engine-internals.md` and the help goldens are parsed by tests.

## Testing without hardware

`FilePlaybackDevice` is the test harness: the entire pipeline runs headless from IQ fixtures. `fixtures/` contains generated signals (NFM tone, AM, USB, CW, noise-floor calibration) with expected demod outputs. Every DSP change must pass fixture round-trips. Hardware-in-the-loop tests are a separate, manually-run suite.

## Agent evals

`evals/scenarios/*.yaml` grade how an agent uses `ley mcp` against a daemon playing recordings
(`docs/dev/evals.md` is the full page; `make eval` runs them, costs tokens, and is not part of
`make check`). The rules:

- **Add a scenario when the adapter gains a tool or a tool's contract changes, and when a real
  session shows an agent working around the tools** (a shell detour, a second call to learn what
  the first meant, a wrong conclusion the result invited). The scenario reproduces the situation;
  the fix to the adapter makes it pass. Two runs of one scenario is the cheapest way to see a
  tool change land.
- **The expected answer comes from the fixture and is known before the agent starts.** Recordings go
  in under neutral names (`radio-a`) with a sidecar that gives only format, rate and centre; a
  descriptive filename or description would give the answer away. Nothing may depend on what is on
  the air or on the clock (fixtures loop, so counts per minute are not stable; "which stations" is).
  Noise fixtures may be placed on any centre with `center:`; every other file device tunes only
  where it was recorded, so a task that needs the radio moved fails before the agent does anything.
- **Every check is a string or number comparison** (`docs/dev/evals.md`, "Check types"): the verdict
  is the same on every run of one log, and no check needs a judge. Ask for one JSON block in
  `answer_schema`, grade that block, and grade the path too (`used_tool`, `no_shell`,
  `max_tool_calls`, `take_over_after_refusal`). A budget is a target to reduce, not a hard limit:
  set it from what a careful operator would need, and raise it with a `why` when a run shows a
  thorough method that costs more (a control decoder, say).
- **Read the transcript before touching the scenario.** A failed check is as often the scenario's
  fault as the agent's (the first quiet-or-broken put a strong tone under a "quiet" band). A passing
  run still shows what the tools made the agent do, and each of these is adapter work to fix: a
  redundant call, a result the agent had to explain away, a number it could not read.
- **Keep the run hermetic.** The eval daemon starts with `--no-hardware` and its own socket, store
  and log; the agent's `ley mcp` is pointed at that log. A scenario must not reach the machine's
  radios, the default daemon, or anything on the network.

## Build order

Follow `docs/plans/build-order.md`. Spikes S1–S3 gate everything: if S2 (20 MSPS throughput) fails its threshold, stop and escalate — the all-Swift decision gets revisited, not worked around silently.

## Working from the Moat container

The Linux container (`run_*`, aarch64, no root) reaches the owner's Mac as `moat-host`
(`192.168.64.1`); `localhost` is the container. When the owner runs `rtl_tcp` on the Mac it is
`moat-host:1234`, so a real-radio capture needs no dongle in the container:
either attach it to a local daemon (`ley devices attach rtltcp moat-host:1234`) or speak rtl_tcp
directly and write cu8 (a recorder lives in the session scratchpad; `rf-captures/` is gitignored
and holds what has been recorded). The container's Swift toolchain, stub librtlsdr and e2e
environment are in `docs/dev/setup.md`; `LD_LIBRARY_PATH` must include the stub before any built
`leylined` will start.
