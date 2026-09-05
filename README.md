# Leyline

A native macOS SDR engine with peer clients. A launchd daemon (`leylined`, Swift) owns the radio
hardware and does all the DSP; the `ley` CLI/TUI (Go), the Mac app (SwiftUI) and the MCP adapter (Go)
are peers speaking one gRPC contract, `leyline.v1`, over a Unix socket.

Status: **v0 in progress** — daemon + CLI. Works today against an RTL-SDR (e.g. a Nooelec NESDR)
and against IQ files. Start at [`docs/dev-setup.md`](docs/dev-setup.md).

```sh
brew install librtlsdr go && make go swift-release
./engine/.build/release/leylined &                # or: ley daemon install --bin ...
ley devices
ley tune 162.55M --mode nfm                       # capture + channel + speakers, one verb
ley set squelch -45                               # from another terminal, while listening
ley fft --bins 1024 --rate 10 --json | head -3
ley play fixtures/nfm_tone.cf32                   # the same pipeline from an IQ file
```

## Layout

| path | what |
|---|---|
| `proto/leyline/v1` | the contract: control, telemetry, bulk planes; jobs and resources |
| `engine/` | SwiftPM package: `EngineCore` (devices, capture, DSP, sinks), `LeylineDaemon` (`leylined`), generated `LeylineProto` |
| `go/` | Go module: `pkg/leyline` client library, `cmd/ley` CLI, `cmd/leyfix` fixture generator, `internal/fakedaemon` contract fake |
| `fixtures/` | generated IQ signals with expected demod outputs (`make fixtures`) |
| `docs/` | design docs (read `design-*.md` before structural changes), `engine-internals.md`, `build-order.md`, `interfaces.md` |

## Where things stand (docs/build-order.md)

- Milestone A (scaffold, daemon lifecycle, fixtures + file playback): done.
- Milestone B (device registry + RTL-SDR, capture engine, FFT stream, NFM → CoreAudio): implemented;
  hardware-in-the-loop verification is a host-side step (`docs/dev-setup.md`).
- Milestone C: `ley set` live adjust and second-client concurrency are in; AM/WFM/SSB/CW demods ship
  alongside NFM (fixture-gated); recording/resources are not started.
- Milestones D (detector, TUI, jobs, MCP) not started.
- Spikes: S3 decided (`docs/decisions/`), S2 harness ready (`swift run s2-throughput`), S1 pending the app.
- **Not yet verified on macOS.** Everything above was built and tested on Linux (portable DSP kernels,
  a stub librtlsdr, the control plane end to end). The Apple-only code — vDSP kernels, the CoreAudio
  sink, real librtlsdr streaming — has been reviewed but never compiled; the first `make swift` on a
  Mac and the first `ley devices` against a dongle are the next milestone, not a formality.

CLAUDE.md is the review checklist; `docs/engine-internals.md` says how the engine keeps its invariants.
