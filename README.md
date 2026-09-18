# Leyline

A native macOS SDR engine with peer clients. A background daemon (`leylined`, Swift) owns the radio
and does all the signal processing; the `ley` command-line tool (Go) drives it over a Unix socket
using one gRPC contract, `leyline.v1`. Anything else that speaks the contract — a script, an agent,
a future app — is a peer of the CLI, never a second path into the hardware.

**What works today:** an RTL-SDR plugged into the Mac (or one another machine serves with
`rtl_tcp`, added by `ley devices attach rtltcp pi.local:1234` and remembered from then on), or an
IQ recording, through capture, channelizing, NFM / WFM / AM / USB / LSB / CW demodulation,
squelch, CTCSS detection and the Mac's audio output; live spectrum, waterfall and persistence
views in the terminal; band-level meters and a seconds-wide clip of the waveform over what a
channel is hearing; a band scan with an honest energy detector; two channels on one radio; a
second terminal adjusting what the first is hearing; `--json` for scripts and `ley mcp` for agents,
which serves the same verbs as MCP tools.

**Not yet:** recording to files, watch jobs and transcripts, the terminal dashboard, the Mac app. `docs/plans/build-order.md` is the order they arrive in and
`docs/plans/v1-release.md` is the gap analysis for the first shared release.

## Requirements

- macOS 26 with Xcode 26 (the Swift 6.2 toolchain). The floor is set by Homebrew's `librtlsdr`,
  which is built for the host OS.
- Homebrew, Go 1.25 or later.
- An RTL-SDR (any RTL2832U dongle: R820T, R828D, E4000, FC0012/13 tuners are known to the driver).
  No radio? See "Without a radio" below.

## Install (from source)

```sh
brew install librtlsdr go
git clone https://github.com/dpup/leysdr.git && cd leysdr
make go swift-release fixtures       # go/bin/ley + leyfix, engine/.build/release/leylined, IQ fixtures
export PATH=$PWD/go/bin:$PATH
ley daemon start --bin $PWD/engine/.build/release/leylined
```

`scripts/bootstrap-mac.sh` runs the same steps. `ley daemon install --bin …` instead of `start`
writes a LaunchAgent so the daemon starts at login; after that `ley daemon start|stop|status|logs`
go through launchd. Starting at login, a radio on another machine over `rtl_tcp`, where the daemon
keeps its files and uninstalling are in [`docs/guide/install.md`](docs/guide/install.md); when
something fails, [`docs/guide/troubleshooting.md`](docs/guide/troubleshooting.md). Building for
development (the gate, `make reload`, the Linux container) is [`docs/dev/setup.md`](docs/dev/setup.md).

## Quickstart

Five commands take you from nothing to a station playing. The output below was recorded against the
contract's fake daemon (`go/internal/fakedaemon`), so your ids, model and levels will differ.

```console
$ ley devices                           # 1. is my radio visible?
MODEL                     STATE      RANGE                    RATES                GAIN
Generic RTL2832U (R820T)  AVAILABLE  24.000 MHz to 1.766 GHz  0.25..3.2 MSPS (11)  TUNER 0..49.6dB(auto)

$ ley tune 146.52                       # 2. listen: a bare number is MHz; mode and squelch are chosen for you
using NFM: 2 m amateur band default
Listening to 146.520 MHz (NFM, 2 m amateur)
Radio Generic RTL2832U (R820T), gain auto
Squelch auto → -80 dBFS (10 dB above the band's noise floor, -90 dBFS).
Ctrl-C stops.
From another terminal: ley set squelch -50 · ley set gain 30 · ley spectrum
146.520 MHz NFM  signal -39 dBFS  audio
transmission  0.3 s  peak snr 51 dB  peak -39 dBFS
146.520 MHz NFM  signal -69 dBFS  muted, waiting for a signal
```

Leave that running and open a second terminal:

```console
$ ley set squelch -45                   # 3. adjust it while it plays
squelch -80 dBFS → -45 dBFS on 146.520 MHz NFM (channel 1)

$ ley set gain 30                       # 4. the radio's gain snaps to what the tuner can do
gain auto → 29.7 dB on the radio (TUNER)

$ ley spectrum                          # 5. see the band the radio is tuned to
146.520 MHz  span 2.400 MHz  floor -100 dBFS  145.320 MHz to 147.720 MHz
1024 bins of 2.344 kHz
 -35 dBFS|                                   :
         |                                  .|
         |                                  ||
         |                                  ||
 -97     |..................................--..................................
         |
-105     ------|-------------|--------------|--------------|-------------|------
          145.500 MHz   146.000 MHz    146.500 MHz    147.000 MHz   147.500 MHz
peak    146.521 MHz  -40 dBFS  60 dB above the floor
tune with: ley tune 146.521
```

Back in the first terminal the session says what the other one did (`another terminal set the
squelch to -45 dBFS`) and keeps playing. `ley scan 144M..148M` sweeps a band and lists what it
found with frequency, width, SNR and how often it was seen; `ley waterfall` and `ley phosphor` show
what comes and goes; `ley bands 146.52` says what a frequency is and what `tune` will do with it.
Bare `ley` tells you where things stand and what to type next; `ley help glossary` explains the
words (capture, channel, dBFS, FFT, squelch); `ley help presets` lists names like `noaa` and
`calling` that `tune` accepts in place of a frequency. The task-by-task walkthrough, including
`--json` and exit codes for scripts and what to do when something fails, is
[`docs/guide/using-ley.md`](docs/guide/using-ley.md).

### Without a radio

`make fixtures` generates IQ recordings of known signals (an NFM tone, AM, SSB, CW, a calibrated
noise floor, a band with four carriers); `ley play fixtures/nfm_tone.cf32 --loop` plays one through
the same pipeline as a radio, and you should hear a 1 kHz tone. The whole test suite runs this way.

## Layout

| path | what |
|---|---|
| `proto/leyline/v1` | the contract: control, telemetry and bulk planes; jobs and resources |
| `swift/LeylineProto` | SwiftPM package: the generated Swift contract (`make proto`), outside `engine/` so the Apache-2.0 code is outside the GPL directory and both Swift packages can depend on it |
| `engine/` | SwiftPM package: `EngineCore` (devices, capture, DSP, sinks), `LeylineDaemon` (`leylined`: services, session store, jobs), the `s2-throughput` spike harness |
| `go/` | Go module: `pkg/leyline` client library, `cmd/ley`, `cmd/leyfix` (fixture generator and analyser), `internal/fakedaemon` (an in-memory implementation of the contract the CLI tests run against), `internal/e2e` (`ley` driving a real `leylined`) |
| `fixtures/` | generated IQ signals with expected demod outputs (`make fixtures`; gitignored) |
| `docs/` | [`docs/README.md`](docs/README.md) is the map: `guide/` for using Leyline, `reference/` for `ley` and the contract, `design/` for why it is built this way, `dev/` for contributor contracts (engine internals, CLI style), `decisions/`, `plans/` |

## Where things stand

Against [`docs/plans/build-order.md`](docs/plans/build-order.md):

- Device backends: an RTL-SDR on USB (librtlsdr) and an RTL-SDR another machine serves with
  `rtl_tcp`. Both are supported, not experiments: the engine tests drive a fake `rtl_tcp` server and
  the e2e attaches one to the real daemon, on both CI hosts.
- Milestone A (scaffold, daemon lifecycle, fixtures and file playback): done.
- Milestone B (device registry and RTL-SDR, capture engine, FFT stream, NFM to CoreAudio): done.
- Milestone C (live adjust, second-client concurrency, AM/WFM/SSB/CW, two channels): done,
  C.12 included -- `ley record` writes WAV or raw IQ through a daemon-side job, the squelch gate
  writes one file per exchange, and `ley recordings` reads the store back through `Resources`.
- Milestone D: D.13 (the energy detector, the telemetry plane, `ley scan`) done; D.17 (decoders:
  the plugin contract, the record store, `ley decode`, `ley records`, `ley track`, `ley watch` with
  predicates and notifiers, `ley devices-seen`/`ley label`, and an IQ input mode) done for APRS,
  SAME weather alerts and marine AIS, the other four drivers listed in `docs/plans/decoders.md`; D.16
  (MCP adapter, `ley mcp`) done for the tools the daemon can back, the rest waiting on the milestones
  `docs/plans/mcp.md` names; D.14 (terminal dashboard) not started; of D.15 (durable jobs, watch, transcripts) only kept decode
  jobs surviving a daemon restart is done.
- Spikes: S3 (USB posture) and S2 (20 MSPS throughput) decided in `docs/decisions/`; S2 sustained
  the full rate for ten minutes on one fifth of a core, with no overruns and an allocation-free
  sample path, so the all-Swift engine stands. S1 (latency chain) is the app's first spectrum.
- Milestone E (the Mac app): E.1 done -- the `app/` package, a Swift client façade tested against
  the real daemon (`docs/dev/app.md`), and a window that names the daemon's state and lists what is
  tuned. No spectrum yet: that is E.2, with spike S1 (`docs/plans/app.md`).
- Verified on real RF (2026-09-05): built on macOS 26 against a Nooelec RTL-SDR (`ley tune` with
  audio confirmed by ear), and from Linux over `rtl_tcp`: FFT peaks on known broadcasters, WFM audio
  with the 19 kHz stereo pilot intact, NFM squelch transitions and a 100 Hz CTCSS tone recovered
  from a handheld, live `ley set` from a second terminal.

## Writing a client

Every verb's `--json` is the standard proto3 JSON mapping of the contract, and everything a person
reads goes to stderr, so stdout is always parseable (`ley help scripting`). If you write your own
client, read [`docs/reference/clients.md`](docs/reference/clients.md) first: the daemon's HTTP/2
stack drops connections that ping on every data frame, which grpc-go and grpc-python do by default,
and the fix is one dial option.

## Contributing, security, licence

[`CONTRIBUTING.md`](CONTRIBUTING.md) has the gate and the rules; `CLAUDE.md` is the invariant list
that doubles as the review checklist. [`SECURITY.md`](SECURITY.md) describes what the daemon trusts
(a local socket, your user, no authentication) and how to report a problem.

Everything here is open source. The engine under `engine/` (`leylined`) is GPL-3.0-or-later because
it links librtlsdr; everything else, the `leyline.v1` contract, the generated code, the client
library and `ley` included, is Apache-2.0, so a program that talks to the daemon can be licensed
however you like. [`NOTICE`](NOTICE) lists what the binaries carry,
[`docs/decisions/D2-licensing.md`](docs/decisions/D2-licensing.md) explains the split, and
[`TRADEMARK.md`](TRADEMARK.md) covers the name. Problems and questions: open an issue on the
repository.
