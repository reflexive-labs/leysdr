# Developer setup

Two halves, two toolchains. The engine (Swift) only *runs* on macOS; the Go clients build anywhere.
Everything meets at the checked-in generated code for `leyline.v1`.

## macOS host (the real thing — needed to talk to an RTL-SDR or HackRF)

Requirements: macOS 26+, Xcode 26 or later (Swift 6.2 toolchain), Homebrew, Go 1.25+. [Installing Leyline](../guide/install.md) is
the user's version of this section: the same build, plus the LaunchAgent, a remote dongle over
`rtl_tcp`, and where the daemon keeps its files.

```sh
brew install go
brew install librtlsdr               # only if testing a local RTL-SDR
brew install hackrf                  # only if testing a local HackRF
git clone <this repo> leysdr && cd leysdr
make go                              # → go/bin/ley, go/bin/leyfix
make swift-release                   # → engine/.build/release/leylined
make fixtures                        # IQ fixtures for hardware-free tests (make swift-test / make e2e need them)
make check                           # what CI runs: proto drift, Go tests, lint, engine build + tests, e2e, the app
make app-run                         # the Mac app, straight from app/ (or: open app/Package.swift in Xcode)
```

The app is its own SwiftPM package at `app/`, depending on the engine package for the generated
contract only; `make app` builds it, `make app-bundle` lays out `app/dist/Leyline.app`, and
`make app-test app-e2e` runs its suites, the second against a `leylined --no-hardware` playing a
fixture. [App internals](app.md) is the page for working on it.

`make check` never skips silently: `swift-test` depends on `fixtures` so the fixture round-trips run,
and `make e2e` builds `ley` and `leylined` and drives the daemon over UDS (`go/internal/e2e`, which
skips itself when `LEYLINED_BIN`/`LEY_BIN` are unset — the Makefile target is the only place it
runs). `FIXTURE_DURATION=0.5` shortens the fixtures for a quick pass (CI uses that).

### The edit-build-try loop

After a change, `make reload` is the whole loop: it rebuilds `ley` and the release `leylined`, stops
the daemon that is running (launchd job or bare spawn), reinstalls the LaunchAgent on the fresh
binary and prints `ley daemon status` so you can see the version it came up with.

Something not working on the Mac (no radio listed, a busy dongle, no audio)?
[Troubleshooting](../guide/troubleshooting.md).

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
`protoc-gen-grpc-swift-2` built from the `LeylineProto` package's resolved dependencies
(`swift/LeylineProto/Package.resolved`, rebuilt when that file changes). Nothing on your `PATH`
influences the output, so `make proto-check` fails only on real drift. To bump a plugin: `cd go &&
go get -tool <module>@<version>` or update that package's dependency, then `make proto` and commit
the regenerated code.

### Cutting a release

The root `VERSION` file is the one number. `make go` stamps it into `ley` and `leyfix` at link time,
adding the git description of the tree (`0.1.0+3-gd34db33`) for anything that is not a build of the
tagged commit; `make version` writes it into `engine/Sources/LeylineDaemon/Version.swift`, which is
committed because Swift has no link-time equivalent. `make version-check` (part of `make check` and
of CI) fails if the generated constant or the Go fallback literal has drifted.

To release: bump `VERSION`, edit `defaultVersion` in `go/internal/cli/root.go` to match, run `make
version`, commit the three files, then tag `v<VERSION>`. Builds from that commit print the bare
number. `docs/dev/release-checklist.md` has the rest, including what a binary release must carry under
the licences.

### Licences

`make license-check` (part of `make check` and of CI) runs `scripts/check-licenses.sh`: every source
file carries an `SPDX-License-Identifier` line matching its directory (GPL-3.0-or-later under
`engine/`, Apache-2.0 everywhere else, the generated `LeylineProto` included because it inherits the
line from the `.proto` and lives outside `engine/`), `third_party/licenses/MANIFEST.txt` equals what
`go.mod` and the three `Package.resolved` files pull in, each vendored text still matches the
module's own (and so does its NOTICE, where it ships one), `NOTICE` names every row, and nothing
outside `engine/` imports copyleft code. A module whose files are under two licences lists both,
comma-separated (`Apache-2.0,MIT`), and each must be allowed. `scripts/check-licenses.sh
--fix` adds a missing header to a new file. Adding a dependency means adding its manifest row,
copying its licence text (and NOTICE, if it ships one) beside it, and naming it in `NOTICE`; the
check tells you which of those you forgot. `docs/decisions/D2-licensing.md` is the decision.

## Linux / the moat container (Go clients, contract tests, engine compile checks)

- Go side: `make go go-test lint`. `ley` is tested against `go/internal/fakedaemon`, an in-memory
  implementation of the contract.
- App side: `make app app-test app-e2e` builds the client façade (`app/`, the `LeylineClient`
  target) and runs its suites against the Linux-built daemon; the SwiftUI target is declared only
  on macOS, so nothing under `app/Sources/LeylineApp` is compiled here (the same blind spot as
  Accelerate below). `make app-e2e` needs the same `LD_LIBRARY_PATH` as `make e2e`: the tests
  spawn `leylined` themselves.
- Swift side: the package builds on Linux with a Swift 6.2 toolchain and no SDR development
  packages. Accelerate/AVFoundation
  code is compiled out; the portable DSP kernels run the DSP tests and the daemon's control plane
  end to end (`go/internal/e2e` drives a Linux-built `leylined` with `ley`). System audio is
  `PLATFORM_UNSUPPORTED` there by design.
- A container needs a Swift 6.2 toolchain on `PATH` and `protoc`. `make swift-test` compiles tiny
  mock libraries and proves all four runtime combinations: neither driver, RTL-SDR only, HackRF
  only, and both. A checkout shared with a Mac should run the
  gate with a scratch install directory (`make check GOBIN=/tmp/ley-bin`) to keep the Linux
  `ley`/`leyfix` out of `go/bin`; `.tools/` and SwiftPM's build products are already per host.
- A bare `swift test` silently skips the fixture round-trips (`FixtureTests`, `ChannelTests`) when
  `fixtures/*.cf32` is missing, and a bare `go test ./...` silently skips the `go/internal/e2e`
  package when `LEYLINED_BIN`/`LEY_BIN` are unset — both report the skip only under `-v`. `make
  swift-test` (depends on `fixtures`) and `make e2e` (builds both binaries and sets the env) are the
  gate; a green bare `test` run does not exercise either suite.

### What a Linux build cannot check

The container has no Accelerate, so **everything under `#if canImport(Accelerate)` is never
compiled there**: `AccelerateKernels` in `DSP/Kernels.swift`, the vDSP half of `DSP/FFT.swift`, and
`KernelParityTests` itself. A green Linux build does not check any of it.

This has already cost one broken macOS build: a `dbToPower` kernel used `vvexp10f`, which does not
exist — it was assumed by analogy with `vvlog10f`, which does. So:

- **Adding a kernel means adding it to `KernelParityTests`.** That test is the only thing that
  compiles the Accelerate path, and it also checks behaviour parity.
- **Prefer an Accelerate symbol already used in the tree** (`grep -o 'vDSP_[a-zA-Z_]*'`). vForce is
  the risky family: only `vvatan2f` and `vvsincosf` are proven here.
- **A scalar loop is a legitimate answer** when a kernel is off the hot path. `dbToPower` delegates
  to `PortableKernels` on both platforms, with a comment explaining why.
- Two more things a Linux build gets wrong: the Glibc overlay has `Float` overloads of the math
  functions and Darwin's does not (use the `f`-suffixed forms — `powf`, `log10f`, `sinf`), and the
  package builds `swiftLanguageModes: [.v5]`, so an actor-isolation mistake is a warning here and
  an error under Swift 6. Read the warnings that say *"this is an error in the Swift 6 language
  mode"* rather than filtering them out.

## Spikes (docs/plans/build-order.md)

- **S1 latency chain** — not run; it is APP-2 in `docs/plans/app.md` (the Metal waterfall over the
  gRPC FFT stream, signposts on both ends, a dongle on the Mac).
- **S2 throughput** — measured and passed (`docs/decisions/S2-throughput.md`): 20 MSPS sustained for
  ten minutes on 19% of one core, no overruns, Accelerate kernels. The harness is
  `swift run -c release s2-throughput --seconds 600` (synthetic 20 MSPS → NFM → null sink); numbers
  from the Linux container are not meaningful, because it builds the portable kernels rather than
  the vDSP ones the gate is about. The allocations criterion passed as well, at 0.0165 per block:
  `scripts/hot-path-allocations.sh` is the half-minute terminal check (it differences allocation
  counts across two run lengths, so only per-block allocation shows) and is worth running after any
  change to a kernel or the capture path. Instruments' Allocations track shows where an allocation
  happens, and cannot attach to a SwiftPM binary until it is re-signed with `get-task-allow`; the
  decision note has the command.
- **S3 USB posture** — decided: `docs/decisions/S3-usb-posture.md` (one host-side check outstanding).
