# Leyline SDR

[![CI](https://github.com/reflexive-labs/leysdr/actions/workflows/ci.yml/badge.svg)](https://github.com/reflexive-labs/leysdr/actions/workflows/ci.yml)
[![Licence: Apache-2.0 and GPL-3.0-or-later](https://img.shields.io/badge/licence-Apache--2.0%20%7C%20GPL--3.0--or--later-blue)](#contributing-security-licence)

Leyline SDR lets you listen to, scan, record and decode radio on a Mac. It works with an RTL-SDR
or a HackRF, plugged in or served over the network with `rtl_tcp`. It only receives; it never
transmits.

**Status:** pre-release. There are no binaries yet; you build it from source.

**Requirements:** macOS 26 with Xcode 26 (the Swift 6.2 toolchain), Homebrew, and Go 1.25 or
later. A radio is optional: an IQ recording plays through the same pipeline.

<!-- screenshot: app window -->

## How it works

A background daemon, `leylined` (Swift), owns the radio and does all the signal processing. The
`ley` command (Go) drives it over a Unix socket using one gRPC contract, `leyline.v1`. The Mac app,
a script or an agent speaks the same contract. Each is a peer of `ley`; none has a second path to
the hardware.

## What works today

- **Radios.** An RTL-SDR or HackRF on USB, an RTL-SDR another machine serves with `rtl_tcp`
  (`ley devices attach rtltcp pi.local:1234`, remembered from then on), or an IQ recording.
- **Listening.** NFM, WFM, AM, USB, LSB and CW demodulation, squelch, CTCSS and DCS tone
  detection, and audio out through the Mac's speakers. Two channels can play from one radio, and a
  second terminal can adjust the channel the first is playing.
- **Seeing the band.** Live spectrum, waterfall and persistence views in the terminal, band-level
  meters, and a few seconds of a channel's waveform.
- **Scanning.** A band scan with an energy detector that reports what it found and never guesses
  a modulation, and `ley monitor`, which logs each transmission on a band.
- **Recording.** Audio or IQ to files through a job the daemon runs, and playback of what was
  recorded.
- **Decoding.** APRS, SAME weather alerts and marine AIS, with `ley watch` to notify on matching
  records.
- **Bands and bookmarks.** Channel plans for common bands, bookmarks, and CHIRP CSV import.
- **Scripts and agents.** `--json` on every verb, and `ley mcp`, which serves the same verbs as MCP
  tools.
- **The Mac app**, built from source with `make app-run`. It shows a spectrum and waterfall, plays
  and tunes a channel, records, lists bands and bookmarks, and has an inspector for signal, tuning
  error, deviation and recent transmissions.

"Where things stand" below lists what is partial or not built yet.

<!-- screenshot: ley spectrum --watch -->

## Receive only

Leyline has no transmit path. Listening is legal in most places, but some countries and states
restrict decoding, recording or sharing certain transmissions. Check the rules where you are.

## Install (from source)

```sh
brew install go
brew install librtlsdr                 # for a local RTL-SDR
brew install hackrf                    # for a local HackRF; install either or both drivers
git clone https://github.com/reflexive-labs/leysdr.git && cd leysdr
make go swift-release fixtures       # go/bin/ley + leyfix, engine/.build/release/leylined, IQ fixtures
make install-decoders                # the APRS, SAME and AIS decoders
export PATH=$PWD/go/bin:$PATH
ley daemon start --bin $PWD/engine/.build/release/leylined
```

`scripts/bootstrap-mac.sh` runs the same steps; pass `--rtl-only` or `--hackrf-only` to install
just one native driver. The daemon builds and runs if either or both drivers are absent. It logs
each unavailable backend once and carries on with the others, `rtl_tcp` and file radios. Restart
the daemon after installing a missing library. `ley daemon install --bin …` instead of `start`
writes a LaunchAgent so the daemon starts at login; after that `ley daemon start|stop|status|logs`
go through launchd. Starting at login, a radio on another machine over `rtl_tcp`, where the daemon
keeps its files and uninstalling are in [`docs/guide/install.md`](docs/guide/install.md); when
something fails, [`docs/guide/troubleshooting.md`](docs/guide/troubleshooting.md). Building for
development (the gate, `make reload`, Linux) is [`docs/dev/setup.md`](docs/dev/setup.md).

## Quickstart

Five commands take you from nothing to a station playing. The output below was recorded against the
contract's fake daemon (`go/internal/fakedaemon`), so your ids, model and levels will differ.

```console
$ ley devices                           # 1. is my radio visible?
MODEL                     STATE      RANGE                    RATES                GAIN
Generic RTL2832U (R820T)  AVAILABLE  24.000 MHz to 1.766 GHz  0.25..3.2 MSPS (11)  TUNER 0–49.6 dB auto

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

Back in the first terminal the session reports what the other one did (`another terminal set the
squelch to -45 dBFS`) and keeps playing. `ley scan 144M..148M` sweeps a band and lists what it
found with frequency, width, SNR and how often it was seen; `ley waterfall` and `ley phosphor` show
what comes and goes; `ley bands 146.52` shows which band a frequency is in and what `tune` will do
with it. Bare `ley` shows the current state and what to type next; `ley help glossary` explains the
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
| `engine/` | SwiftPM package: `EngineCore` (devices, capture, DSP, sinks) and `LeylineDaemon` (`leylined`: services, session store, jobs). GPL-3.0-or-later |
| `app/` | SwiftPM package: the Mac app and its client façade (`docs/dev/app.md`) |
| `swift/LeylineProto` | SwiftPM package: the generated Swift contract (`make proto`), shared by the engine and the app |
| `go/` | Go module: the `pkg/leyline` client library, `ley`, the decoders' binaries, `leyfix` (fixture generator), `leyeval` (agent evals), the fake daemon the `ley` tests run against, and the end-to-end tests |
| `decoders/` | decoder manifests (APRS, SAME, AIS, and the `iqstat` test decoder); `make install-decoders` installs them |
| `evals/` | scenarios that grade an agent's use of `ley mcp` (`docs/dev/evals.md`) |
| `scripts/` | setup, code generation, licence checks, bundling the app |
| `third_party/` | licence texts of the dependencies (`third_party/licenses/MANIFEST.txt`) |
| `fixtures/` | generated IQ signals with expected demod outputs (`make fixtures`; gitignored) |
| `docs/` | [`docs/README.md`](docs/README.md) is the map: `guide/` for using Leyline, `reference/` for `ley` and the contract, `design/` for why it is built this way, `dev/` for contributors, `decisions/`, `plans/` |

## Where things stand

"Works" means built, tested in CI, and used with a real radio or a recording. The milestone
detail is [`docs/plans/build-order.md`](docs/plans/build-order.md).

| feature | status | notes |
|---|---|---|
| RTL-SDR on USB | works | tested on real RF with a Nooelec RTL-SDR |
| HackRF on USB | works | HackRF One and HackRF Pro, through libhackrf |
| RTL-SDR over `rtl_tcp` | works | no authentication or encryption on the link |
| IQ file playback | works | `.cf32` with a JSON sidecar; files from other software are not read yet |
| Demodulation: NFM, WFM, AM, USB, LSB, CW | works | with squelch and audio out on macOS |
| CTCSS and DCS detection | works | |
| Terminal views | works | `spectrum`, `waterfall`, `phosphor`, `scope`, `levels`, `waveform` |
| Band scan and `ley monitor` | works | energy detector; no modulation guess |
| Two channels on one radio, several clients | works | |
| Recording and playback | works | audio (WAV) or IQ; a squelch-gated recording writes one file per transmission |
| Bands, channel plans, bookmarks, CHIRP import | works | in `ley` and the app |
| Decoders: APRS, SAME, AIS | works | more are planned (`docs/plans/decoders.md`) |
| `ley watch` notifications | works | webhook, shell command or macOS notification |
| MCP adapter (`ley mcp`) | partial | resource tools, signal identification and transcripts are planned (`docs/plans/mcp.md`) |
| Mac app | partial | build from source; does not start the daemon itself yet; no settings inspector |
| Signed app bundle and installer | planned | the bundle layout exists, signed for local use only |
| Terminal dashboard | planned | |
| Durable watch jobs | partial | kept decode jobs survive a daemon restart; other jobs do not |
| Audio transcripts | planned | |
| Channel occupancy and burst capture | planned | `docs/plans/band-watching.md` |
| Audio spectrogram (`ley sonogram`) | planned | |
| Transmit | not planned | Leyline is receive only |

## Writing a client

Every verb's `--json` is the standard proto3 JSON mapping of the contract, and everything a person
reads goes to stderr, so stdout is always parseable (`ley help scripting`). If you write your own
client, read [`docs/reference/clients.md`](docs/reference/clients.md) first: the daemon's HTTP/2
stack drops connections that ping on every data frame, which grpc-go and grpc-python do by default,
and the fix is one dial option.

## Contributing, security, licence

[`CONTRIBUTING.md`](CONTRIBUTING.md) says how to build, test and propose a change.
[`SECURITY.md`](SECURITY.md) describes what the daemon trusts (a local socket, your user, no
authentication) and how to report a problem.

Everything here is open source. The engine under `engine/` (`leylined`) is GPL-3.0-or-later because
it links librtlsdr; everything else, the `leyline.v1` contract, the generated code, the client
library and `ley` included, is Apache-2.0, so a program that talks to the daemon can be licensed
however you like. [`NOTICE`](NOTICE) lists what the binaries carry,
[`docs/decisions/D2-licensing.md`](docs/decisions/D2-licensing.md) explains the split, and
[`TRADEMARK.md`](TRADEMARK.md) covers the name. Problems and questions: open an issue on the
repository.
