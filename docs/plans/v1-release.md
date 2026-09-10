# Plan: v1.0 — what a release shared with other people is missing

Status: gap analysis of `main` at `36adcb8`, 2026-09-10. Measured against the promises of record —
`docs/sdr-user-stories.md`, `docs/build-order.md`, the `leyline.v1` protos and `docs/interfaces.md` —
by reading the code and running the suites, not by trusting the status sections of README.md or the
plan files (which, it turns out, disagree with each other). Every claim below has a `path:line` or a
test name behind it; the raw per-item evidence is long and lives in the review run, this file keeps
the conclusions.

The second half of this document is the work list. Items that need no decision are being done now;
items marked **decision** wait for the owner, because different answers lead to materially different
work.

## The short version

What exists is a complete V0 minus recording, plus one Milestone D feature (`ley scan`), and no app,
no TUI dashboard and no MCP adapter. The engine and CLI are in good shape: all nine V0 stories except
recording are implemented and tested, most against the real daemon, and both suites are green from a
clean checkout. What is not in good shape is everything a stranger meets before the code:

- **No licence.** Two documents call the project open source; no file grants anyone anything, and
  `leylined` links GPL-2.0 librtlsdr, so binary distribution carries obligations nothing satisfies.
- **No version.** `0.1.0-dev` is hard-coded twice (`go/internal/cli/root.go:30`,
  `engine/Sources/LeylineDaemon/Server.swift:12`), nothing stamps a build, there is no git remote and
  no tag.
- **Three status documents contradict each other.** README.md:76 says Milestone D is not started;
  `docs/build-order.md:36` marks D.13 done (it is: `ley scan`, the detector, the job store all ship
  and pass an e2e against the real daemon); `docs/sdr-planning-todo.md:38-40` still has S3 unticked
  while `docs/decisions/S3-usb-posture.md` decides it.
- **The README quickstart does not work as written** from a clean clone: `ley` is not on PATH,
  `leylined` is not found without `--bin`, and `fixtures/nfm_tone.cf32` does not exist until
  `make fixtures`.
- **The CLI has outrun its own contract.** `ley waterfall` and `ley phosphor` are polished, tested
  verbs that appear in no user-facing document, and both silently ignore `--json`, which breaks the
  V0 story "every verb has `--json`".
- **Two of the three advertised clients do not exist.** README.md:3 and CLAUDE.md describe a SwiftUI
  app and an MCP adapter as peers; there is no app target and `go/cmd` holds only `ley` and `leyfix`.
- **The fake daemon has drifted from the real one** in ten places (listed below), and the only tests
  that would notice — `go/internal/e2e` — skip themselves unless two environment variables name the
  binaries, and CI runs them only on Linux.

## Decisions needed

**D1 — What v1.0 is.** The stories define V0 (engine + CLI), V0.5 (TUI), V1a (app), V1b (MCP). The
honest options for a first public release:

| cut | contains | sizes the unbuilt part at |
|---|---|---|
| (a) engine + `ley` | V0 complete: recording lands (C.12), the docs tell the truth, it installs | L (recording) + the release plumbing |
| (b) = (a) + MCP adapter | the agent story, which is the positioning (`sdr-user-stories.md` "spectrum explorer … agents"); six of the nine MCP tools can be written against today's daemon | + L (adapter, after the client-library move in LIB-1) |
| (c) = (b) + durable watch jobs | the "watch 146.52 for an hour" story; needs the job store, respawn, transcript (D.15) | + XL |
| (d) = (b) + the native app | V1a; needs the app, the shm ring, and spikes S1/S2 run on hardware | + XL, and the architecture gate has not been passed |

Recommendation: **(b)**, with (c) and (d) as v1.1 and v2. The app is the showcase but it is the part
with the most unmeasured risk (S1 and S2 have never been run on target hardware); the adapter is the
differentiator and it is mostly plumbing over RPCs that already work. Recording is in every cut
because it is a V0 story and the MCP "hand a recording to another tool" story depends on it.

**D2 — Licence.** `docs/sdr-planning-todo.md:14` decided "engine is open source — GPL question
dissolves; link librtlsdr directly". That settles GPL-compatible, not which licence. `leylined` links
librtlsdr (GPL-2.0-or-later), so a distributed daemon binary is a GPL combined work whatever the repo
says; the Go clients link only Apache-2.0 and MIT code. Simplest: one licence for the repo,
GPL-3.0-or-later or GPL-2.0-or-later, plus a `NOTICE` for the Apache-2.0 Go dependencies (cobra,
grpc-go, protobuf, oklog/ulid). A split (permissive clients, GPL engine) is possible but is a second
thing to explain. Blocks REL-1/REL-2 below.

**D3 — The name.** `docs/sdr-planning-todo.md:32`: "USPTO check on 'Leyline' before first public
release." Not recorded as done. The name is now in the proto package, the launchd label
(`com.leyline.daemon`), the socket path and the URI scheme, so a rename after release is a breaking
change. Owner action, before the repo goes public.

**D4 — Distribution mechanics.** The plan of record is "direct + notarized, no App Store". Nothing
exists: no release workflow, no Homebrew tap, no signing. The minimum that works for strangers is a
tagged release with `go install github.com/dpup/leysdr/go/cmd/ley@<tag>` documented and a
`bootstrap-mac.sh` that builds the daemon; a tap formula is the next step; notarization needs an Apple
developer account. Owner decides how far v1.0 goes.

**D5 — Spikes.** S2 (20 MSPS, zero allocations, ≥50 % headroom on a base M-series) gates the all-Swift
decision and has never been run on a Mac; the harness exists (`swift run s2-throughput`) and passes its
own weaker check on Linux (19.99 MSPS, 0 overruns). S3's five-minute host check
(`docs/decisions/S3-usb-posture.md:34-40`) is also outstanding, as is the scan settle-constant
measurement in `docs/design-scan.md` Open questions. All three need the owner's Mac and dongle; the
results should be recorded as `docs/decisions/` notes before tagging.

Decisions taken here without waiting, because there is one reasonable answer and the work is small:
`ley waterfall --json` and `ley phosphor --json` get row shapes under the existing bulk-row exception
(R-5); the version gets one source of truth stamped at build time (R-2); the dead launchd template goes
(R-10); the container-specific setup text moves out of the shared developer doc (R-1).

## Gap map

### V0 stories (`docs/sdr-user-stories.md`)

| # | story | status | what is missing |
|---|---|---|---|
| V0-1 | `ley devices` with capabilities | done | copy still says "RTL-SDR or HackRF"; only rtlsdr, rtl_tcp and file drivers exist |
| V0-2 | second terminal, no device-busy | done | — |
| V0-3 | `ley tune` and hear audio | done, **unverified by any test** | `CoreAudioSink.swift` is entirely inside `#if canImport(AVFoundation)`; every automated run is Linux or `--no-audio`. The headline story has only a hand-written claim (README.md:80) behind it. Needs a Mac acceptance run (R-17) |
| V0-4 | live gain / squelch / filter | done | — |
| V0-5 | `ley record --iq` / `--audio`, play back | **missing** (playback half done) | no FileSink, no record job, no verb (`stubs.go:18`), no sidecar writer in the daemon. `go/pkg/iqfile` already has the writer and sidecar format. Also: a `.cf32` without a sidecar is refused by the daemon (`DEVICE_IO: cannot stat sidecar`) while `play.go:30` says a missing sidecar is not an error — third-party IQ cannot be played |
| V0-6 | `ley fft --rate 10` rows | done | — |
| V0-7 | `ley scan lo..hi` | done | — |
| V0-8 | two channels on one radio | done | — |
| V0-9 | every verb has `--json` | **partial** | `waterfall` and `phosphor` ignore the flag and print the picture (`waterfall.go:98`, `phosphor.go:105`, no reference to `app.JSON` in either file); `help --json` and `completion --json` print prose |

### Build order (`docs/build-order.md`)

| task | status | note |
|---|---|---|
| S1 latency chain | missing | needs the app and the shm ring; V1a |
| S2 throughput | harness only | never run on target hardware against its criteria (D5) |
| S3 USB posture | decided, one host check open | `docs/decisions/S3-usb-posture.md:34-40` |
| A.1 scaffold | partial | no App target, no MCP package, no Bubble Tea; the macOS CI job runs the Swift suite only — Go tests and the e2e run on Linux only |
| A.2 daemon lifecycle, A.3 fixtures | done | |
| B.4 registry + RTL-SDR, B.5 capture engine | done | |
| B.6 FFT ladder + **shm ring** + gRPC stream | partial | the shm ring does not exist: `StreamRegistry.swift:96` always answers `grpc`, `client.go:390` always asks for it, `FrameRing` is process-local. CLAUDE.md invariant 1 calls it "the single documented bypass" |
| B.7 NFM + CoreAudio | done | see V0-3 |
| C.8 – C.11 | done | |
| C.12 FileSink + Resources + record/play/recordings | **missing** except `ley play` | the largest hole in V0 |
| D.13 detector + telemetry + `ley scan` | done | `docs/design-scan.md` |
| D.14 TUI dashboard | partial | three live views exist (`spectrum --watch`, `waterfall`, `phosphor`) and negotiate low-rate streams; no dashboard, no event loop, no bubbletea dependency. README, CLAUDE.md and `interfaces.md` all still say "Bubble Tea TUI" |
| D.15 jobs | one of five pieces | `CaptureAllocator` with don't-disturb landed with scan; the store is in-memory (`JobStore.swift:3`), no respawn, no watch job (`JobsService.swift:22`), no transcript (`:51`) |
| D.16 MCP adapter | missing | |

Undocumented extras the plan never mentions: `RTLTCPDevice` (a remote dongle over `rtl_tcp`, 504 lines,
tested — it is what made the Linux real-RF verification possible), `ley phosphor`, `ley waterfall`,
`leyfix` (the fixture generator is a substantial second binary with its own FFT and analysis), and
the sub-audible tone detector. None is a problem; all need to be in the docs.

### The wire contract in three implementations

Every RPC and behaviour-bearing field was checked in the Swift daemon, the Go fake and the Go client
library. Implemented in all three and tested: the whole of `Control` except sinks other than
`system_audio`, the whole of `Telemetry`, `Bulk` for IQ/FFT/AUDIO/PERSISTENCE, `Jobs` for scans.

Accepted but ignored (a caller gets no warning):

- `ScanConfig.step_hz` — both daemons overwrite it with their own plan and report it back
  (`JobStore.swift:248`, `fakedaemon/jobs.go:91`); it is an output field wearing an input's name.
- `Channel.required_hz` — stored and echoed, read by nobody; its consumer is the unbuilt watch job.
- `AttachFileDeviceRequest.path` — the proto says it may be a `ley://recordings/<id>` URI; neither
  daemon parses `ley://`.
- `Bulk.Subscribe.transport = SHM_RING` — silently answered with `GRPC` rather than refused.

Unimplemented, and the proto says so or should: `StreamPosition.at_sample` / `at_host_time_ns`,
`Sink.file` (`SessionStore.swift:651`), `Sink.stream` via `AttachSink` (deliberate: use
`Bulk.Subscribe`), `StreamKind.DECODED`, `Jobs.StartJob` watch and record, `ScanConfig.recurring`,
`Jobs.GetTranscript`, the entire `Resources` service. `Job.result_uris` carries `ley://scans/<id>`
that nothing can resolve.

Client library (`go/pkg/leyline`): wrappers for 5 of 18 RPCs; the rest are reachable only as raw
stubs. `Control.DetachSink` and `Jobs.ListJobs` are implemented in both daemons and called by nothing.
Error codes `BLIND_SPOT`, `NO_DEVICE`, `FAILED_PRECONDITION`, `INTERNAL` are emitted by the daemon
and have no constant in `errors.go`; `scan.go:274` matches two of them as bare strings.

**Fake-vs-daemon divergences.** The fake is what every CLI test runs against, so each of these is a
CLI behaviour proven against the wrong answer:

1. `Bulk.Subscribe(PERSISTENCE)` has no case in the fake (`bulk.go:135-172`); `ley phosphor` has zero
   end-to-end coverage.
2. `FftParams.accumulation` / `looks_per_row` are ignored by the fake; the daemon honours
   ROW_SNAPSHOT/MEAN/MAX and answers the real look count (`StreamRegistry.swift:128-150`).
3. `GAP_MARKED`: the fake fabricates a gap every 50th frame (`bulk_stream.go:73`); the daemon emits
   one only when the ring dropped, with real bounds.
4. `Telemetry.SUB_AUDIBLE` is never emitted by the fake; `ley tune`'s CTCSS line has no e2e path.
5. `Channel.subaudible_detect` is true for every NFM channel in the daemon (`SessionStore.swift:593`),
   never set by the fake.
6. `Detection.first_seen` / `last_seen` are nil in the fake; `looks`/`looks_possible` hard-coded 4/4.
7. `Scan.gains` is empty in the fake; the proto argues at length that a scan without its gain is not
   comparable.
8. Don't-disturb: the fake checks channels and live audio but not a recent interactive write
   (`jobs.go:106-108` admits it); `ley scan` without `--take-over` against a recently-touched radio
   is untested.
9. `DeviceDescriptor.features`: the fake advertises `bias_tee`, `direct_sampling`, `tx_capable`; the
   real driver emits only `held_externally`, `serial_collision`, `tuner`.
10. Scan failure codes: the fake never raises `BLIND_SPOT`; `scan.go:274`'s branch for it is
    unreachable in tests.

### Later milestones

- **V0.5 TUI**: no bubbletea, no dashboard, no keyboard write path (every write is a cobra `RunE`
  that prints prose). The remote-access story needs a TCP listener and auth that do not exist —
  `--rtltcp` moves the *dongle*, not the control plane.
- **V1a app**: nothing — no Xcode project, no SwiftUI, no Metal, no Swift client façade, no
  shm-ring reader in any language. Bookmarks and CHIRP import have no proto messages. Of the five
  named newcomer presets only NOAA and Marine VHF exist as presets.
- **V1b MCP**: no server, no tool registry, no PNG rendering, no generator. Six of nine tools could be
  written today; `start_job(watch|record)`, `get_transcript`, `find_recordings` cannot. The band
  labelling and scan interpretation the adapter would add are trapped in `go/internal/cli`.
- **LIB-1**: `go/pkg/leyline` has the transport and the vocabulary (frequency, squelch, gain, band,
  preset, selector parsing; stable codes; socket discovery) but none of the behaviour: bringing a
  capture up, creating a channel, measuring auto squelch, following a job, folding events into a
  state mirror are all unexported methods on `cli.session` wired to `io.Writer`s. An adapter or a
  dashboard would duplicate them. This is the prerequisite for both D.14 and D.16.

### Release readiness

| id | finding | blocker |
|---|---|---|
| REL-1 | no LICENSE | yes |
| REL-2 | no NOTICE for librtlsdr (GPL-2.0) and Apache-2.0 Go deps | yes, for binary distribution |
| REL-3 | version hard-coded `0.1.0-dev` in Go and Swift; no ldflags, no tag, no remote | yes |
| REL-4 | no install story beyond clone-and-build; `scripts/bootstrap-mac.sh` is referenced by nothing | yes |
| REL-5 | README quickstart fails from a clean clone (PATH, `--bin`, fixtures) | yes |
| REL-6 | README status section a milestone behind | yes |
| REL-7 | README promises an app and an MCP adapter | yes |
| REL-8 | `interfaces.md` CLI tree lacks `waterfall`, `phosphor` | |
| REL-9 | `interfaces.md` opens with an MCP table nothing implements, unlabelled as a design | |
| REL-10 | `engine-internals.md` module map lacks `Jobs/`, `S2Throughput`, four DSP files; says fixture round-trips are macOS-only (CI runs them on Linux) | |
| REL-11 | `RTLTCPDeviceTests.testLinkLossReleasesSocketAndReopenReconnects` fails in roughly half of full `swift test` runs (`bad magic` on reconnect to a rebound ephemeral port), passes in isolation | yes — the gate is red at random |
| REL-12 | no macOS CI job runs `ley`, `make e2e`, or the launchd path | |
| REL-13 | no CONTRIBUTING, CHANGELOG, SECURITY, issue templates | |
| REL-14 | no contact, repository URL or issues link anywhere | |
| REL-15 | `dev-setup.md:118-124` ships one sandbox's `/home/moatuser` paths as instructions; `moat.yaml` at the root | |
| REL-16 | two plan files cite review reports under `/tmp` on one machine; their `#N` references resolve nowhere | |
| REL-17 | trademark check outstanding (D3) | |
| REL-18 | the macOS 26 floor (`Package.swift:18`) is stated only in `dev-setup.md`, not the README | yes |
| REL-19 | `engine/launchd/com.leyline.daemon.plist.template` is referenced by nothing and disagrees with the plist `daemon.go:151` writes | |
| REL-20–23, 25 | no secrets; build artefacts gitignored; both halves green from clean; `daemon start` without a binary fails well; stubs are honest | — |
| REL-24 | the repo root speaks to an agent (CLAUDE.md, moat.yaml) and not to a person | |
| REL-26 | S1/S2 never measured on hardware (D5) | |

### Documentation drift (facts, not style)

- README.md:26-27 `ley devices` example shows `--wide` columns and `MHz-GHz` ranges the default
  output does not print; :29-34 collapses the two-line tune banner into one sentence with "on <model>";
  :43 spectrum header format and "floor -100 dB" (renderer prints dBFS, floor first); :49 "loudest
  bins:" (renderer prints "peak …  N dB above the floor"). README.md:11 claims these were "recorded
  against the contract fake daemon"; they were not.
- `docs/interfaces.md:33` says spectrum's peak threshold is floor + 6 dB; the code uses 15 dB.
- `docs/cli-guide.md:105-106` says `--volume` takes the mode's usual value; it is 100 % for every mode.
  `:446` misquotes the BLIND_SPOT recovery line.
- `docs/engine-internals.md:30` "Jobs/Resources return UNIMPLEMENTED"; `:34` "macOS only, need
  Accelerate" for the whole test target.
- `docs/design-semantic-tier.md`, `design-control-plane.md`, `design-data-planes.md` use `sdr://`
  URIs; the code, CLAUDE.md and `interfaces.md` use `ley://`.
- `docs/sdr-user-stories.md` names every V0 verb `sdr …`; the binary has been `ley` since the naming
  decision in `sdr-planning-todo.md` §5.
- `docs/design-semantic-tier.md` and `interfaces.md` state the CLI verbs are "generated from the
  protos"; `go/internal/cli` is hand-written cobra. True claim: mapped one-to-one, by discipline.
- CLAUDE.md:9, `sdr-planning-todo.md:32`, `interfaces.md:153`: "Bubble Tea TUI"; no bubbletea.
- `docs/interfaces.md:174-183` documents the grpc-go ping / swift-nio GOAWAY landmine every third-party
  client will hit; it belongs where a client author looks first, not at the end of the CLI contract.

## Work list

Status legend: `[ ]` pending, `[x]` done, `[-]` dropped with reason, `[d]` waits on a decision above.
Sizes: S under a day, M a few days, L a week or two. "Sonnet"/"Opus"/"owner" says who does it: the
mechanical items go to the smaller model, the scoped code changes to the larger one, and the
measurements and decisions to the person with the hardware. The review findings from the same pass
have their own list, `docs/plans/v1-review-fixes.md`, and land first.

### R-1 `[ ]` The documents tell the truth (S, Sonnet)

Every item in "Documentation drift" above except README.md, which R-8 rewrites whole. Plus:

- `docs/interfaces.md`: add `waterfall` and `phosphor` to the CLI tree with their flags; head the MCP
  table with one sentence saying it is the design for Milestone D.16 and nothing implements it yet;
  the peak threshold is 15 dB; move the "Client requirements" (GOAWAY / BDP ping) section to the top
  of the doc under a heading a client author will find.
- `docs/engine-internals.md`: the module map lists `Jobs/` (JobStore, ScanRunner,
  SessionCaptureAllocator), `S2Throughput/`, and every file under `DSP/`; the Services line says
  what is implemented (scan jobs) and what is not (watch, record, transcript, Resources); the test
  line says which tests need macOS (`KernelParityTests`, anything under `canImport(Accelerate)` or
  `canImport(AVFoundation)`) rather than the whole target.
- `sdr://` → `ley://` in the three design docs; `sdr <verb>` → `ley <verb>` in the user stories;
  "generated from the protos" → "mapped one-to-one from the protos" wherever the CLI is described;
  "Bubble Tea TUI" → "terminal live views today (`spectrum --watch`, `waterfall`, `phosphor`); the
  dashboard is Milestone D.14" in CLAUDE.md, `interfaces.md` and `sdr-planning-todo.md`; tick S3 in
  `sdr-planning-todo.md` §6 and point at the decision note.
- `docs/dev-setup.md`: replace the `/home/moatuser` paragraph with the generic recipe (a Swift 6.2
  toolchain, librtlsdr headers or a stub `.so` that reports zero devices, `protoc`; `LD_LIBRARY_PATH`
  at the stub for `make e2e`) with no personal paths.
- `docs/plans/engine-review-fixes.md` and `cli-review-fixes.md` headers: the review reports were
  ephemeral; the `#N` numbers are kept because the commit messages cite them.
- Delete `engine/launchd/com.leyline.daemon.plist.template` (REL-19): `ley daemon install` writes
  the plist from `go/internal/cli/daemon.go`, and the template disagrees with it.
- `docs/cli-guide.md`: a section for `ley waterfall` and `ley phosphor` (what question each answers,
  from `docs/design-signal-views.md` and `design-band-watching.md`), and the two factual fixes.

### R-2 `[ ]` One version, stamped at build time (S, Opus)

- A root `VERSION` file is the single source of truth (content stays `0.1.0-dev` until the owner
  tags; the release step bumps it).
- Go: the Makefile builds `ley` and `leyfix` with `-ldflags -X …cli.Version=<VERSION>[+<git describe>]`,
  the suffix omitted when `git describe --tags --exact-match` is `v<VERSION>`. When no ldflags were
  given (a `go install …@tag` build) `Version` falls back to `runtime/debug.ReadBuildInfo().Main.Version`
  when that is not `(devel)`, then to the literal. `ley version` and the golden test keep their shape.
- Swift: `scripts/gen-version.sh` writes `engine/Sources/LeylineDaemon/Version.swift` (a single
  `let leylinedVersion = "…"`) from `VERSION`; the file is committed and CI regenerates it and fails
  on drift, exactly like `proto-check`. `Server.swift:12` reads the generated constant.
- A test or `make version-check` asserts `VERSION`, `Version.swift` and the Go fallback literal agree.
- `docs/dev-setup.md` gets a "Cutting a release" paragraph: bump `VERSION`, `make version`, commit,
  tag `v<VERSION>`.

### R-3 `[ ]` CI proves the product on the product's platform (S, Sonnet)

`.github/workflows/ci.yml` `swift-macos` job also runs `make go-test lint e2e` (the e2e target
builds both binaries and the fixtures it needs). Note in the job why: the Go clients and the UDS
contract were previously proven only on Linux.

### R-4 `[ ]` The engine test gate is deterministic (M, Opus)

`RTLTCPDeviceTests.testLinkLossReleasesSocketAndReopenReconnects`
(`engine/Tests/EngineCoreTests/RTLTCPTests.swift:365-392`) fails intermittently in a full `swift test`
run with `DEVICE_IO: not an rtl_tcp server (bad magic)` and passes in isolation (12/12 here). The
test stops `FakeRTLTCPServer` and immediately rebinds the same ephemeral port. Diagnose whether the
old accept loop or a still-open client socket answers the reconnect, whether `stop()` returns before
the listener is closed and joined, or whether the device's reconnect path has a real defect; fix the
harness or the device accordingly, and prove it with ten consecutive full runs. If the fix is in
`RTLTCPDevice`, add the regression test.

### R-5 `[ ]` Every verb answers `--json` or refuses it (M, Opus)

- `ley waterfall --json` prints one NDJSON object per rendered row in the existing bulk-row shape
  (`{seq, sample_index, center_hz, span_hz, bins, floor_db}`) plus `looks` (the look count the daemon
  answered for the accumulation it negotiated); gap lines as `ley fft`. `ley phosphor --json` prints
  one object per persistence frame: `{seq, sample_index, center_hz, span_hz, bins, levels, floor_db,
  range_db, counts}` where `counts` is the daemon's `bins × levels` little-endian uint16 grid,
  base64-encoded like `ley listen`'s `pcm`. Both are documented in `docs/interfaces.md` as members of
  the bulk-row exception.
- `ley help --json` and `ley completion --json` reject the flag with the same usage error (exit 2)
  `ley daemon logs --json` uses, and the doc says so.
- A table-driven test walks the cobra tree from the root and asserts every leaf either emits valid
  JSON on stdout under `--json` (against the fake) or exits 2 with the documented message — so the
  V0 story cannot regress silently again.

### R-6 `[d]` `ley play` for IQ files this project did not write (M, Opus; after D1)

A `.cf32` without a sidecar is refused by the daemon (`DEVICE_IO: cannot stat sidecar`) while
`go/internal/cli/play.go:30` says a missing sidecar is not an error. Additive
`AttachFileDeviceRequest` fields (`sample_rate`, `center_hz`, `format`) used only when no sidecar
exists; `ley play --rate` joins `--freq`; the fake mirrors; the error for a bare file without `--rate`
names the flag. Not required for the cut but it is what "play IQ files back" means to someone with an
`rtl_sdr` capture.

### R-7 `[d]` LICENSE and NOTICE (S; after D2)

`LICENSE` at the root; `NOTICE` listing librtlsdr (GPL-2.0-or-later, dynamically linked by
`leylined`) and the Apache-2.0 Go dependencies; a licence line in README and in `ley version`'s help.

### R-8 `[ ]` README written for a stranger (S)

What it is (a daemon that owns an RTL-SDR and a CLI that drives it, today), what it is not yet (no
app, no MCP adapter, no recording), requirements (macOS 26, Xcode 26, Homebrew, Go 1.25, an RTL-SDR),
install, a quickstart that works from a clean clone (`make go swift-release fixtures`,
`export PATH=$PWD/go/bin:$PATH`, `ley daemon start --bin engine/.build/release/leylined`), console
transcripts that match what the renderers print (record them against the daemon or the fake rather
than paraphrasing), the docs map, a status section that agrees with `docs/build-order.md`, licence
(placeholder until D2), and where to report problems (the module path already names
`github.com/dpup/leysdr`). The GOAWAY/ping note for client authors is linked, not buried.

### R-9 `[ ]` CONTRIBUTING, SECURITY, CHANGELOG (S)

- `CONTRIBUTING.md`: the gate (`make check`, both hosts), the invariants (CLAUDE.md is the review
  checklist), proto additivity, generated code, how fixtures work.
- `SECURITY.md`: the trust model in one page — a local UDS socket with the user's permissions and no
  authentication; anything that can open it controls the radio; no network listener; `--rtltcp` is
  an outbound cleartext connection to a server you name; how to report.
- `CHANGELOG.md` started with an Unreleased section.

### R-10 `[ ]` (folded into R-1: delete the dead launchd template)

### R-11 `[d]` Recording (L, Opus; after D1 — in every cut)

Milestone C.12: a `FileSink` in `EngineCore/Sinks` writing IQ (`.cf32` + sidecar, the `go/pkg/iqfile`
format, with the `CaptureAnchor`) and audio (WAV s16 mono at the channel's rate); `AttachSink(file)`
in the daemon and the fake; `Jobs.StartJob(record)` with `duration_ms` and `start_at_ns == 0`; a
resource store directory (`~/Library/Application Support/Leyline/recordings`) and the minimum of the
`Resources` service that makes `ley://recordings/<id>` real (`ListResources`, `GetResource`,
`ResolveLocalPath`); `ley record <freq> [--iq|--audio] [--for DURATION]`, `ley recordings`, and
`ley play` accepting a `ley://` URI. Design note first (`docs/design-recording.md`, short: what the
sidecar carries, where files go, retention) because the store shape outlives v1.0.

### R-12 `[d]` MCP adapter (L, Opus; after D1 and R-13)

Milestone D.16. Go binary `leymcp` (stdio transport) sharing `go/pkg/leyline`; the six tools the daemon
can back today (`list_devices`, `get_state`, `tune`, `listen_summary`, `scan`, `snapshot` as PNG
plus data); the three that cannot return a typed "not available until Milestone D.15" refusal.
Design note first: tool schemas, refusal semantics, how the don't-disturb refusal reads.

### R-13 `[d]` The client library carries the behaviour, not just the vocabulary (M, Opus; after D1)

LIB-1. Promote from `go/internal/cli/session.go`, `tune.go`, `set.go`, `scan.go` into `go/pkg/leyline`:
the state mirror with event folding (`fold`), bring-up of a capture and channel with the tune decision
logic, the auto-squelch measurement, the live parameter write with confirmation, and following a scan
job to completion. The CLI becomes a renderer over those. Prerequisite for R-12 and for D.14.

### R-14 `[ ]` The fake daemon tells the daemon's story (M, Opus)

The ten divergences listed under "The wire contract". For each: make the fake match the Swift daemon's
semantics, and add the CLI test that could not exist before (a `ley phosphor` run against the fake;
`waterfall`'s `looks > 1` annotation; a gap rendered only when the fake's buffer actually dropped;
`ley tune`'s CTCSS line from a fake channel with a tone; `subaudible_detect` shown; first/last seen
and a real look count on detections; `Scan.gains` printed; a scan refused because of a write in the
last 60 s; the real driver's feature keys — check `RTLSDRDevice.swift` for what it emits and fix
`docs/engine-internals.md` if the doc disagrees; `BLIND_SPOT` from the fake when the request falls in
the DC guard). Split into two commits if it helps: bulk/telemetry parity, then jobs parity.

### R-15 `[ ]` Contract hygiene (S, Opus)

- `go/pkg/leyline/errors.go` gains constants for every code the daemon emits (`BLIND_SPOT`,
  `NO_DEVICE`, `FAILED_PRECONDITION`, `INTERNAL`); `scan.go:274` uses them; a test asserts the Go list
  and the engine's `EngineError` codes are the same set.
- Proto comments say what the daemons do: `ScanConfig.step_hz` is chosen by the daemon and a request
  value is ignored; `Channel.required_hz` is read only by watch jobs, not yet implemented;
  `Transport.SHM_RING` is answered with `GRPC` in v0; `AttachFileDeviceRequest.path` accepts
  filesystem paths only in v0. Comments only — no wire change.
- `go/pkg/leyline` wrappers for `ListJobs` and `DetachSink`, and `ley jobs [cancel <id>]` so that a
  running or finished scan can be listed and stopped from another terminal (the RPCs exist in both
  daemons and are called by nothing).

### R-16 `[ ]` Measurements only the owner can make (owner)

- S2 on an M-series Mac under Instruments against `docs/build-order.md`'s criteria; record the result
  as `docs/decisions/S2-throughput.md`, pass or fail.
- S3's host check (`docs/decisions/S3-usb-posture.md:34-40`).
- The scan settle constant (`docs/design-scan.md` Open questions): one known carrier, several
  `--dwell` values, does the reported frequency drift.
- The audio acceptance run from R-17.

### R-17 `[ ]` A release checklist (S)

`docs/release-checklist.md`: the manual acceptance pass a Mac must complete before a tag — fixture
tone audible, a real station audible, `set` from a second terminal, `scan` of a known band,
record → play, `daemon install` / `status` / `uninstall`, unplug and replug — plus the mechanical
steps (VERSION bump, `make check` on both hosts, tag, release notes).

### R-18 `[d]` Trademark check (owner; D3)
