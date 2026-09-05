# Leyline

A native macOS SDR engine with peer clients. A launchd daemon (`leylined`, Swift) owns the radio
hardware and does all the DSP; the `ley` CLI/TUI (Go), the Mac app (SwiftUI) and the MCP adapter (Go)
are peers speaking one gRPC contract, `leyline.v1`, over a Unix socket.

Status: **v0 in progress** — daemon + CLI. Works today against an RTL-SDR (e.g. a Nooelec NESDR)
and against IQ files. Building it is in [`docs/dev-setup.md`](docs/dev-setup.md); using it is in
[`docs/cli-guide.md`](docs/cli-guide.md).

## Quickstart

You need an RTL-SDR plugged in and the two binaries built (`brew install librtlsdr go && make go
swift-release`; see dev-setup). `ley daemon start` looks for `leylined` via `--bin`,
`$LEYLINE_DAEMON_BIN`, next to `ley`, then `PATH`; from a fresh checkout pass
`--bin engine/.build/release/leylined` once (or `ley daemon install --bin ...` to start it at
login). Five commands take you from nothing to a station playing. The output below is what
`ley` prints (recorded against the contract fake daemon, so your ids, model and levels will
differ).

```console
$ ley daemon start                      # 1. start the background process that owns the radio
started leylined (pid 4242); check with: ley daemon status

$ ley devices                           # 2. is my radio visible?
ID                              DRIVER  MODEL                     SERIAL    STATE      RANGE                 RATES                GAIN
dev_01M1S9TR56S46QTCK0SZS2YPJA  rtlsdr  Generic RTL2832U (R820T)  00000001  AVAILABLE  24.000 MHz-1.766 GHz  0.25..3.2 MSPS (11)  TUNER 0..49.6dB(auto)

$ ley tune 146.52                       # 3. listen: a bare number is MHz, mode and squelch are chosen for you
using NFM: 2 m amateur band default
Listening to 146.520 MHz (NFM, 2 m amateur) on Generic RTL2832U (R820T), gain auto. Squelch auto → -80 dBFS (10 dB above the band's noise floor, -90 dBFS). Ctrl-C stops.
From another terminal: ley set squelch -50 · ley set gain 30 · ley spectrum
146.520 MHz NFM  signal -39 dBFS  audio
```

Leave that running and open a second terminal:

```console
$ ley set squelch -45                   # 4. adjust it while it plays
squelch → -45 dBFS on 146.520 MHz NFM (channel 1, chan_01M1S9VA2F5E5G6KK85YNJQ7MS)

$ ley spectrum                          # 5. see the band the radio is tuned to
146.520 MHz, span 2.400 MHz (145.320 MHz to 147.720 MHz), 1024 bins of 2.344 kHz, floor -100 dB
 -41 |                                   #
 ...
 -99 |#################################################################
     +-----------------------------------------------------------------
      145.320 MHz                146.520 MHz                147.720 MHz
loudest bins: 146.622 MHz -41 dB
```

No radio? `ley play fixtures/nfm_tone.cf32` runs the same pipeline from a recording. Bare `ley`
tells you where things stand and what to type next; `ley help glossary` explains the words
(capture, channel, dBFS, FFT, squelch); `ley help presets` lists names like `noaa` and `calling`
that `tune` accepts in place of a frequency. The task-by-task walkthrough, including `--json` and
exit codes for scripts and what to do when something fails, is
[`docs/cli-guide.md`](docs/cli-guide.md).

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
- **Verified on real RF** (2026-09-05): built on macOS 26 against a Nooelec RTL-SDR (`ley tune` with
  audio confirmed by ear), and from Linux over `rtl_tcp` — FFT peaks on known broadcasters, WFM audio
  with the 19 kHz stereo pilot intact, NFM squelch transitions and a 100 Hz CTCSS tone recovered
  from a handheld on 147.555 MHz, live `ley set` from a second terminal.

CLAUDE.md is the review checklist; `docs/engine-internals.md` says how the engine keeps its invariants.
