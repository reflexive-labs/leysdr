# Contributing to Leyline

Leyline is a macOS SDR engine (`leylined`, Swift) with a Go CLI (`ley`) as its first client. The
two halves meet at one generated contract, `proto/leyline/v1`. This page is the short version of
how to work on it; the long version is `docs/dev-setup.md` (building), `docs/engine-internals.md`
(how the engine keeps its promises) and `docs/cli-style.md` (how `ley` talks).

## Before you change anything

Read `CLAUDE.md`. It is written as instructions to an agent, but it is also the review checklist:
thirteen invariants, each with a rationale in `docs/design-*.md`. A change that breaks one needs a
design-doc change first, not a clever workaround. The ones people trip on:

- **All DSP runs in the daemon.** Clients render. If a feature only works from Swift, or only from
  Go, it is not done.
- **The hot path allocates nothing.** `Demodulator.process`, `AudioSink.write` and ring writes: no
  allocation, no locks held across calls, no `async`.
- **Events carry the whole object, never a delta.** Reconnect is `GetState` plus resume from `seq`.
- **The wire contract is generated; the engine contract is not.** Never hand-edit `go/gen` or
  `engine/Sources/LeylineProto` (run `make proto`); never generate
  `engine/Sources/EngineCore/CoreProtocols.swift`.
- **Proto changes are additive within v1.** New fields get new numbers; reserved numbers stay
  reserved; nothing is renamed or retyped.

## The gate

`make check` is what CI runs: generated-code drift, Go tests, lint (`golangci-lint` + `gofumpt`,
pinned), the engine build and tests, and the cross-language e2e suite that drives a locally built
`leylined` with `ley` over a Unix socket. Run it on a Mac before opening a pull request; the Linux
job proves the Go half and the portable engine core, but only macOS compiles the Accelerate kernels
and the audio sink, and only macOS is the product.

Every DSP change must pass the fixture round-trips (`make fixtures` generates them; `docs/fixtures.md`
says what each signal is). Anything on the sample path gets `os_signpost` instrumentation.
Hardware-in-the-loop checks are manual: `docs/release-checklist.md`.

## Tests without hardware

`FilePlaybackDevice` plays IQ fixtures through the whole pipeline, so the engine tests and the e2e
suite need no radio. `go/internal/fakedaemon` is an in-memory implementation of the contract that
the `ley` tests run against; when you change what the daemon does, change the fake to match and
add the test that proves `ley` handles it, then confirm against the real daemon with `make e2e`.

## Commits and pull requests

One change per commit, with its tests. Subject line `area: what changed` in the imperative and under
72 characters (`engine:`, `ley:`, `proto:`, `docs:`, `fix(scan):` are all in use); the body says why,
in plain prose. Larger work starts from a plan in `docs/plans/` with `[ ]` work items, and a design
decision starts from a `docs/design-*.md` change.

## Where to ask

Open an issue on the repository. If it is a security matter, read `SECURITY.md` first.
