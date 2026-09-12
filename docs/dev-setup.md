# Developer setup

Two halves, two toolchains. The engine (Swift) only *runs* on macOS; the Go clients build anywhere.
Everything meets at the checked-in generated code for `leyline.v1`.

## macOS host (the real thing — needed to talk to a Nooelec / any RTL-SDR)

Requirements: macOS 26+, Xcode 26 or later (Swift 6.2 toolchain), Homebrew, Go 1.25+. The deployment target is macOS 26 because Homebrew builds `librtlsdr` for the host OS; older macOS would need a librtlsdr built with a lower `MACOSX_DEPLOYMENT_TARGET`.

```sh
brew install librtlsdr go            # librtlsdr pulls libusb
git clone <this repo> leysdr && cd leysdr
make go                              # → go/bin/ley, go/bin/leyfix
make swift-release                   # → engine/.build/release/leylined
make fixtures                        # IQ fixtures for hardware-free tests (make swift-test / make e2e need them)
make check                           # what CI runs: proto drift, Go tests, lint, engine build + tests, e2e
```

`make check` never skips silently: `swift-test` depends on `fixtures` so the fixture round-trips run,
and `make e2e` builds `ley` and `leylined` and drives the daemon over UDS (`go/internal/e2e`, which
skips itself when `LEYLINED_BIN`/`LEY_BIN` are unset — the Makefile target is the only place it
runs). `FIXTURE_DURATION=0.5` shortens the fixtures for a quick pass (CI uses that).

### First run against a dongle

```sh
# terminal 1 — run the daemon in the foreground so you see its logs
./engine/.build/release/leylined --log-level debug

# terminal 2
export PATH=$PWD/go/bin:$PATH
ley devices                          # the Nooelec shows up as driver=rtlsdr with its tuner gain table
ley tune 162.55M --mode nfm          # NOAA weather (pick your local one); Ctrl-C stops
ley tune 101.1M --mode wfm           # broadcast FM — the "is my dongle alive" test
ley set gain 30                      # from a third terminal, while tune is running
ley set squelch -45
ley fft --bins 1024 --rate 5 --count 3 --json | head -c 400
ley state
```

No RF? `ley play fixtures/nfm_tone.cf32` runs the same pipeline from an IQ file and you should hear a
1 kHz tone. `ley play --persistent` leaves the file device attached; `ley devices detach <id>` removes it.

How to *use* `ley` — presets, auto squelch, `ley spectrum`, `--json` and exit codes for scripts, what
each error means — is in [`cli-guide.md`](cli-guide.md) and in `ley help <topic>`.

### Remote dongle over rtl_tcp

A dongle plugged into another machine (a Raspberry Pi on the roof, a Linux box in the shack) can be
served with osmocom's `rtl_tcp` and used by `leylined` as a virtual device:

```sh
# on the machine with the dongle
rtl_tcp -a 0.0.0.0 -p 1234

# on the Mac
ley devices attach rtltcp pi.local:1234    # the way in: the daemon remembers it across restarts
ley devices                                # shows driver rtltcp, model "rtl_tcp pi.local:1234 (R820T)"
ley devices detach 2                       # the way out: the daemon forgets it
```

Attaching is a client asking the running daemon, so nothing needs restarting and the remembered
list (`devices.json` beside the socket) survives one. A foreground run started from a terminal can
still be given its radios on the command line, which is what `--rtltcp` is for:

```sh
leylined --rtltcp pi.local:1234            # repeatable: --rtltcp a:1234 --rtltcp b:1234
LEYLINE_RTLTCP=pi.local:1234,shack:1234 leylined   # same thing via the environment
```

Attaching connects once (5 s timeout) and fails naming the endpoint if the server does not answer,
remembering nothing. A remembered or flag-given server that is unreachable at startup is logged and
kept, so a dead remote never stops local dongles from working. Tune, gain, sample rate, bias tee,
ppm and AGC all work the same as on a local dongle (they are sent as rtl_tcp commands). `rtl_tcp`
serves one client at a time and drops one that stops reading, so do not point two daemons at the
same server. If the link drops, the device goes `disconnected` (its capture detaches) and the
daemon retries the connection on every device poll (about once a second, 5 s timeout per attempt);
once the server is back the device is `available` again under the same id and a detached capture
rebinds to it by itself. Samples cross the network as raw 8-bit I/Q (2.4 MSPS ≈ 4.8 MB/s), so a
wired LAN or good Wi-Fi is needed.

### Running as a launchd agent

```sh
ley daemon install --bin $PWD/engine/.build/release/leylined   # writes ~/Library/LaunchAgents/com.leyline.daemon.plist
ley daemon status
ley daemon logs --follow
ley daemon uninstall
```

`ley daemon start|stop` work with or without the plist (without it they spawn/kill the binary directly).

After a change, `make reload` is the whole loop: it rebuilds `ley` and the release `leylined`, stops
the daemon that is running (launchd job or bare spawn), reinstalls the LaunchAgent on the fresh
binary and prints `ley daemon status` so you can see the version it came up with.

### Troubleshooting

- `ley devices` is empty but the dongle is plugged in: check `rtl_test -t` (from `brew install librtlsdr`).
  If `rtl_test` sees it and `leylined` does not, the daemon is running with a different `librtlsdr`
  (`otool -L engine/.build/release/leylined | grep rtlsdr`).
- `DEVICE_BUSY: another program has the device`, or `ley devices` shows the dongle `IN_USE` with a
  `0..0dB` gain column while nothing of yours is tuned: another process (SDR++, GQRX, `rtl_tcp`) holds
  it. Quit that program; the daemon re-checks with a backoff of up to 60 s (the `usb_claim_interface
  error` lines in the daemon log are librtlsdr reporting each check), or just tune: a capture that
  opens the dongle clears the flag at once.
- No audio: `ley state` must show a `system_audio` sink on your channel; check the Mac's output device;
  try `ley set volume 1`. The daemon plays through AVAudioEngine's default output.
- Nooelec dongles often ship with serial `00000001`. Two identical serials get distinct IDs by
  enumeration order and a `serial_collision` feature flag; set unique serials with `rtl_eeprom -s`.

### Previewing a view without a terminal

`ley … --color always` under `COLORTERM=truecolor` and a UTF-8 `LANG` writes the same escapes a
terminal would get, and `scripts/ansi2html.py` turns a capture into an HTML block with the real
level-ramp colours, so a picture can be reviewed in a browser or attached to a review. The guide's
transcripts are plain text; this is for the colour.

### Regenerating the protos

`make proto` needs only `protoc` from outside the repo (`brew install protobuf`; any current version).
`scripts/gen-proto.sh` installs the pinned plugins into `.tools/<os>-<arch>/bin` (gitignored, per host so a
checkout shared with a Linux container keeps separate binaries): `protoc-gen-go` and
`protoc-gen-go-grpc` from the `tool` directives in `go/go.mod`, and `protoc-gen-swift` /
`protoc-gen-grpc-swift-2` built from the engine package's resolved dependencies (`engine/Package.resolved`,
rebuilt when that file changes). Nothing on your `PATH` influences the output, so `make proto-check` fails
only on real drift. To bump a plugin: `cd go && go get -tool <module>@<version>` or update the engine's
package dependency, then `make proto` and commit the regenerated code.

### Cutting a release

The root `VERSION` file is the one number. `make go` stamps it into `ley` and `leyfix` at link time,
adding the git description of the tree (`0.1.0+3-gd34db33`) for anything that is not a build of the
tagged commit; `make version` writes it into `engine/Sources/LeylineDaemon/Version.swift`, which is
committed because Swift has no link-time equivalent. `make version-check` (part of `make check` and
of CI) fails if the generated constant or the Go fallback literal has drifted.

To release: bump `VERSION`, edit `defaultVersion` in `go/internal/cli/root.go` to match, run `make
version`, commit the three files, then tag `v<VERSION>`. Builds from that commit print the bare
number.

## Linux / the moat container (Go clients, contract tests, engine compile checks)

- Go side: `make go go-test lint`. `ley` is tested against `go/internal/fakedaemon`, an in-memory
  implementation of the contract.
- Swift side: the package builds on Linux with a Swift 6.2 toolchain and `librtlsdr-dev`
  (`apt install librtlsdr-dev`, or the header+stub `.so` the container uses). Accelerate/AVFoundation
  code is compiled out; the portable DSP kernels run the DSP tests and the daemon's control plane
  end to end (`go/internal/e2e` drives a Linux-built `leylined` with `ley`). System audio is
  `PLATFORM_UNSUPPORTED` there by design.
- A container needs a Swift 6.2 toolchain on `PATH`, `librtlsdr` headers (a real install, or a stub
  `.so` that reports zero devices — enough to link `leylined` since the container has no hardware),
  and `protoc`. Running `leylined` against the stub (and therefore `make e2e` / `make check`) needs
  `LD_LIBRARY_PATH` pointed at the stub's lib directory. A checkout shared with a Mac should run the
  gate with a scratch install directory (`make check GOBIN=/tmp/ley-bin`) to keep the Linux
  `ley`/`leyfix` out of `go/bin`; `.tools/` and SwiftPM's build products are already per host.
- A bare `swift test` silently skips the fixture round-trips (`FixtureTests`, `ChannelTests`) when
  `fixtures/*.cf32` is missing, and a bare `go test ./...` silently skips the `go/internal/e2e`
  package when `LEYLINED_BIN`/`LEY_BIN` are unset — both report the skip only under `-v`. `make
  swift-test` (depends on `fixtures`) and `make e2e` (builds both binaries and sets the env) are the
  gate; a green bare `test` run proves nothing about either suite.

### What a Linux build cannot check

The container has no Accelerate, so **everything under `#if canImport(Accelerate)` is never
compiled there**: `AccelerateKernels` in `DSP/Kernels.swift`, the vDSP half of `DSP/FFT.swift`, and
`KernelParityTests` itself. A green Linux build says nothing about any of it.

This has already cost one broken macOS build: a `dbToPower` kernel used `vvexp10f`, which does not
exist — it was assumed by analogy with `vvlog10f`, which does. So:

- **Adding a kernel means adding it to `KernelParityTests`.** That test is the only thing that
  compiles the Accelerate path, and behaviour parity is the second half of what it buys.
- **Prefer an Accelerate symbol already used in the tree** (`grep -o 'vDSP_[a-zA-Z_]*'`). vForce is
  the risky family: only `vvatan2f` and `vvsincosf` are proven here.
- **A scalar loop is a legitimate answer** when a kernel is off the hot path. `dbToPower` delegates
  to `PortableKernels` on both platforms and says why in a comment.
- Two more things a Linux build gets wrong: the Glibc overlay has `Float` overloads of the math
  functions and Darwin's does not (use the `f`-suffixed forms — `powf`, `log10f`, `sinf`), and the
  package builds `swiftLanguageModes: [.v5]`, so an actor-isolation mistake is a warning here and
  an error under Swift 6. Read the warnings that say *"this is an error in the Swift 6 language
  mode"* rather than filtering them out.

## Spikes (docs/build-order.md)

- **S1 latency chain** — not run (needs Metal waterfall + hardware; Milestone V1a).
- **S2 throughput** — harness ships as `swift run s2-throughput --seconds 10` (synthetic 20 MSPS → NFM →
  null sink). Run it on an M-series Mac under Instruments (Allocations + Time Profiler); the pass
  criteria are in build-order.md. Numbers from the Linux container are not meaningful.
- **S3 USB posture** — decided: `docs/decisions/S3-usb-posture.md` (one host-side check outstanding).
