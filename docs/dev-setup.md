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

### Running as a launchd agent

```sh
ley daemon install --bin $PWD/engine/.build/release/leylined   # writes ~/Library/LaunchAgents/com.leyline.daemon.plist
ley daemon status
ley daemon logs --follow
ley daemon uninstall
```

`ley daemon start|stop` work with or without the plist (without it they spawn/kill the binary directly).

### Troubleshooting

- `ley devices` is empty but the dongle is plugged in: check `rtl_test -t` (from `brew install librtlsdr`).
  If `rtl_test` sees it and `leylined` does not, the daemon is running with a different `librtlsdr`
  (`otool -L engine/.build/release/leylined | grep rtlsdr`).
- `DEVICE_IO: rtlsdr_open ... -6`: another process has the device (SDR++, GQRX, `rtl_tcp`). Quit it.
- No audio: `ley state` must show a `system_audio` sink on your channel; check the Mac's output device;
  try `ley set volume 1`. The daemon plays through AVAudioEngine's default output.
- Nooelec dongles often ship with serial `00000001`. Two identical serials get distinct IDs by
  enumeration order and a `serial_collision` feature flag; set unique serials with `rtl_eeprom -s`.

### Regenerating the protos on macOS

`protoc` is pinned to **25.1** (`scripts/gen-proto.sh`): `protoc-gen-go` embeds the protoc version in
every generated header, so a different protoc rewrites `go/gen` and fails the CI drift check. CI installs
25.1 via `arduino/setup-protoc`; locally use the same version — Homebrew's `protobuf` moves, so either
`brew install protobuf@25` (if present) or the `protoc-25.1-osx-*.zip` from the protobuf GitHub releases
on `PATH`. `ALLOW_PROTOC_MISMATCH=1 make proto` runs with whatever protoc is installed (expect header churn).
The Go plugins are pinned too (`protoc-gen-go` v1.36.12, `protoc-gen-go-grpc` v1.6.2); the Swift ones
are `swift-protobuf` from Homebrew and `grpc-swift-protobuf` 2.4.1 built from source once:

```sh
brew install swift-protobuf
go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.12
go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.6.2
git clone -b 2.4.1 https://github.com/grpc/grpc-swift-protobuf /tmp/gsp && \
  (cd /tmp/gsp && swift build -c release --product protoc-gen-grpc-swift-2) && \
  cp /tmp/gsp/.build/release/protoc-gen-grpc-swift-2 /opt/homebrew/bin/
make proto
```

## Linux / the moat container (Go clients, contract tests, engine compile checks)

- Go side: `make go go-test lint`. `ley` is tested against `go/internal/fakedaemon`, an in-memory
  implementation of the contract.
- Swift side: the package builds on Linux with a Swift 6.2 toolchain and `librtlsdr-dev`
  (`apt install librtlsdr-dev`, or the header+stub `.so` the container uses). Accelerate/AVFoundation
  code is compiled out; the portable DSP kernels run the DSP tests and the daemon's control plane
  end to end (`go/internal/e2e` drives a Linux-built `leylined` with `ley`). System audio is
  `PLATFORM_UNSUPPORTED` there by design.
- In the moat container the Swift toolchain lives in `/home/moatuser/swift-toolchain` with wrapper
  scripts on `PATH` (`/home/moatuser/bin/swift`) and a stub `librtlsdr` at `/home/moatuser/rtlsdr-stub`.
  The stub is not on the loader path, so running `leylined` there (and therefore `make e2e` / `make check`)
  needs `LD_LIBRARY_PATH=/home/moatuser/rtlsdr-stub/lib`; `protoc` 25.1 is already installed.

## Spikes (docs/build-order.md)

- **S1 latency chain** — not run (needs Metal waterfall + hardware; Milestone V1a).
- **S2 throughput** — harness ships as `swift run s2-throughput --seconds 10` (synthetic 20 MSPS → NFM →
  null sink). Run it on an M-series Mac under Instruments (Allocations + Time Profiler); the pass
  criteria are in build-order.md. Numbers from the Linux container are not meaningful.
- **S3 USB posture** — decided: `docs/decisions/S3-usb-posture.md` (one host-side check outstanding).
