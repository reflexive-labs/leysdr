# Plan: v1.0 — what a release shared with other people is missing

Status: gap analysis of `main` at `36adcb8`, 2026-09-10. Measured against the documents of record —
`docs/plans/user-stories.md`, `docs/plans/build-order.md`, the `leyline.v1` protos and `docs/reference/cli.md` —
by reading the code and running the suites, not by trusting the status sections of README.md or the
plan files (which disagree with each other). Every claim below has a `path:line` or a
test name behind it; the raw per-item evidence is long and lives in the review run, this file keeps
the conclusions.

The second half of this document is the work list. Items that need no decision are being done now;
items marked **decision** wait for the owner, because different answers lead to materially different
work.

## The short version

What exists is a V0 minus recording, plus one Milestone D feature (`ley scan`), and no app, no TUI
dashboard and no MCP adapter. The engine and CLI are in good shape: seven of the nine V0 stories are
implemented and tested, most against the real daemon; the audio story works but has no automated
proof, and `--json` is broken on two verbs. Both suites pass here, with one flaky engine test and
fixture-gated tests that skip until `make fixtures`. What is not in good shape is everything a
new user meets before the code:

- **No licence.** Two documents call the project open source; no file grants a licence, and
  `leylined` links GPL-2.0 librtlsdr, so binary distribution carries obligations nothing satisfies.
- **No version.** `0.1.0-dev` is hard-coded twice (`go/internal/cli/root.go:30`,
  `engine/Sources/LeylineDaemon/Server.swift:12`), nothing stamps a build, there is no git remote and
  no tag.
- **Three status documents contradict each other.** README.md:76 says Milestone D is not started;
  `docs/plans/build-order.md:36` marks D.13 done (it is: `ley scan`, the detector, the job store all ship
  and pass an e2e against the real daemon); `docs/plans/archive/planning-phase.md:38-40` still has S3 unticked
  while `docs/decisions/S3-usb-posture.md` decides it.
- **The README quickstart does not work as written** from a clean clone: `ley` is not on PATH,
  `leylined` is not found without `--bin`, and `fixtures/nfm_tone.cf32` does not exist until
  `make fixtures`.
- **The CLI is ahead of its documentation.** `ley waterfall` and `ley phosphor` are polished, tested
  verbs that appear in no user-facing document, and both silently ignore `--json`, which breaks the
  V0 story "every verb has `--json`".
- **Two of the three advertised clients do not exist.** README.md:3 and CLAUDE.md describe a SwiftUI
  app and an MCP adapter as peers; there is no app target and `go/cmd` holds only `ley` and `leyfix`.
- **The fake daemon has drifted from the real one** in ten places (listed below), and the only tests
  that would notice — `go/internal/e2e` — skip themselves unless two environment variables name the
  binaries, and CI runs them only on Linux.
- **No authentication, by design.** Anything that can open the socket controls the radio
  (`docs/design/control-plane.md`: local UDS trusts the user account). That is fine for one Mac, but
  it has to be documented where the contract is read, and it bears on any cut that adds an agent.

## Decisions needed

**D1 — What v1.0 is.** The stories define V0 (engine + CLI), V0.5 (TUI), V1a (app), V1b (MCP). The
realistic options for a first public release:

| cut | contains | sizes the unbuilt part at |
|---|---|---|
| (a) engine + `ley` | V0 complete: recording lands (C.12, done 2026-09-18), the docs are accurate, it installs | the release plumbing |
| (a′) = (a) + the terminal dashboard | V0.5; the three live views exist and the rest is composition and an event loop over the client-library move in LIB-1 | + M–L |
| (b) = (a) + MCP adapter | the agent story, which is the positioning (`docs/plans/user-stories.md` "spectrum explorer … agents"); six of the nine MCP tools can be written against today's daemon | + L (adapter, after the client-library move in LIB-1) |
| (c) = (b) + durable watch jobs | the "watch 146.52 for an hour" story; needs the job store, respawn, transcript (D.15) | + XL |
| (d) = (b) + the native app | V1a; needs the app, the shm ring, and spikes S1/S2 run on hardware | + XL, and the architecture gate has not been passed |

Recommendation: **(b)**, with (a′) and (c) as v1.1 and (d) as v2. The app is the showcase but it is
the part with the most unmeasured risk (S1 and S2 have never been run on target hardware); the
adapter is the differentiator and it is mostly plumbing over RPCs that already work, though not free:
three of its nine tools must refuse, the "generated from one schema" property it is described with
does not exist (the CLI is hand-written, and the adapter's tool prose will be too), and the CLI is the
reference client, so every tool needs a `ley` mirror. The dashboard shares its one prerequisite
(LIB-1) with the adapter and is the cheapest incremental cut; it is left out of v1.0 only because the
adapter is the positioning. Every cut carries the same fixed cost — R-1 to R-5, the fake-daemon
parity in R-14, and an owner's Mac run of the audio story, which no test proves. Recording is in
every cut because it is a V0 story and the MCP "hand a recording to another tool" story depends on
it, so it does not wait on this decision. D2 removed one cost every cut used to carry: with nothing
closed there is no public/private split to build, and the adapter and the app land in this repository
under Apache-2.0 beside `ley`.

**D2 — Licence.** Decided 2026-09-12, `docs/decisions/D2-licensing.md`: everything ships open
source. The engine under `engine/` is GPL-3.0-or-later because it links librtlsdr (GPL-2.0-or-later)
and Apache-2.0 Swift packages, which rules out GPLv2-only; the contract, the generated code, the
client library, `ley`, the adapter and the app are Apache-2.0, so the GPL reaches exactly what links
librtlsdr and every client stays a separate work. Revenue is the notarized build plus a curated
content layer (R-22), not withheld source; no licence keys, no private repo. Contributions are inbound
Apache-2.0 with DCO sign-off (`CONTRIBUTING.md`); the name is what the project protects
(`TRADEMARK.md`, D3). Landed: `LICENSE`, `engine/LICENSE`, `NOTICE`, `third_party/licenses/`, SPDX
headers everywhere, `make license-check` in the gate and CI. REL-1 and REL-2 are closed by it.

**D3 — The name.** `docs/plans/archive/planning-phase.md:32`: "USPTO check on 'Leyline' before first public
release." Not recorded as done. The name is now in the proto package, the launchd label
(`com.leyline.daemon`), the socket path and the URI scheme, so a rename after release is a breaking
change. Owner action, before the repo goes public.

**D4 — Distribution mechanics.** The plan of record is "direct + notarized, no App Store". Nothing
exists: no release workflow, no Homebrew tap, no signing. The minimum that works for strangers is a
tagged release with `go install github.com/dpup/leysdr/go/cmd/ley@<tag>` documented and a
`bootstrap-mac.sh` that builds the daemon; a tap formula is the next step; notarization needs an Apple
developer account. Owner decides how far v1.0 goes.

**D5 — Spikes.** S2 (20 MSPS, zero allocations, ≥50 % headroom on a base M-series) gates the all-Swift
decision and has never been run on a Mac. The harness exists (`swift run s2-throughput`) but its
built-in verdict is only "no overruns and ≥99 % of the offered rate" over a 10 s default, and on Linux
it runs the portable kernels, which `main.swift:78` itself says is not the gate (it passes that weaker
check here: 19.99 MSPS, 0 overruns). The 10-minute, zero-allocation and headroom criteria need an
Instruments run and probably a longer harness option. S3's five-minute host check
(`docs/decisions/S3-usb-posture.md:34-40`) is also outstanding, as is the scan settle-constant
measurement in `docs/design/scan.md` Open questions. All three need the owner's Mac and dongle; the
results should be recorded as `docs/decisions/` notes before tagging.

**D6 — Where bookmarks live.** The V1a stories (bookmarks, CHIRP import, scan lists) have no proto
message. Invariant 7 says state lives in the daemon, which means an additive `Bookmark` message and a
small store; the alternative is app-local data the CLI and agents cannot see. Additive either way, so
not a blocker, but decide before the app starts.

**D7 — Remote radios as daemon state.** Taken: R-20 is built. It replaces the `--rtltcp` flag with an attach RPC and a
remembered device list. It is what the "dongle on another machine" story the README advertises
needs to be usable under launchd. Decide whether it is in v1.0 (recommended if the cut includes
that story) or first after.

Decisions taken here without waiting, because there is one reasonable answer and the work is small:
`ley waterfall --json` and `ley phosphor --json` get row shapes under the existing bulk-row exception
(R-5); the version gets one source of truth stamped at build time (R-2); the dead launchd template goes
(R-10); the container-specific setup text moves out of the shared developer doc (R-1).

## Gap map

### V0 stories (`docs/plans/user-stories.md`)

| # | story | status | what is missing |
|---|---|---|---|
| V0-1 | `ley devices` with capabilities | done | copy still says "RTL-SDR or HackRF"; only rtlsdr, rtl_tcp and file drivers exist |
| V0-2 | second terminal, no device-busy | done | — |
| V0-3 | `ley tune` and hear audio | **partial: no automated proof** | `CoreAudioSink.swift` is entirely inside `#if canImport(AVFoundation)`; every automated run is Linux or `--no-audio`. The headline story has only a hand-written claim (README.md:80) behind it. Needs a Mac acceptance run (R-17) |
| V0-4 | live gain / squelch / filter | done | — |
| V0-5 | `ley record --iq` / `--audio`, play back | **missing** (playback half done) | no FileSink, no record job, no verb (`stubs.go:18`), no sidecar writer in the daemon. `go/pkg/iqfile` already has the writer and sidecar format. Also: a `.cf32` without a sidecar is refused by the daemon (`DEVICE_IO: cannot stat sidecar`) while `play.go:30` says a missing sidecar is not an error — third-party IQ cannot be played |
| V0-6 | `ley fft --rate 10` rows | done | — |
| V0-7 | `ley scan lo..hi` | done | — |
| V0-8 | two channels on one radio | done | — |
| V0-9 | every verb has `--json` | **partial** | `waterfall` and `phosphor` ignore the flag and print the picture (`waterfall.go:98`, `phosphor.go:105`, no reference to `app.JSON` in either file); `help --json` and `completion --json` print prose |

### Build order (`docs/plans/build-order.md`)

| task | status | note |
|---|---|---|
| S1 latency chain | missing | needs the app and the shm ring; V1a |
| S2 throughput | done | measured and passed on an M4 Max, 2026-09-18: `docs/decisions/S2-throughput.md` |
| S3 USB posture | decided, one host check open | `docs/decisions/S3-usb-posture.md:34-40` |
| A.1 scaffold | partial | no App target, no MCP package, no Bubble Tea; the macOS CI job runs the Swift suite and the generation-drift check — Go tests and the e2e run on Linux only |
| A.2 daemon lifecycle, A.3 fixtures | done | |
| B.4 registry + RTL-SDR, B.5 capture engine | done | |
| B.6 FFT ladder + **shm ring** + gRPC stream | partial | the shm ring does not exist: `StreamRegistry.swift:96` always answers `grpc`, `client.go:390` always asks for it, `FrameRing` is process-local. CLAUDE.md invariant 1 calls it "the single documented bypass" |
| B.7 NFM + CoreAudio | done | see V0-3 |
| C.8 – C.11 | done | |
| C.12 recording + Resources + record/play/recordings | done | 2026-09-18; `docs/design/recording.md`. A recording is a job's output rather than an attached sink, which is why the plan's `AttachSink(file)` line below is not what landed |
| D.13 detector + telemetry + `ley scan` | done | `docs/design/scan.md` |
| D.14 TUI dashboard | partial | three live views exist (`spectrum --watch`, `waterfall`, `phosphor`) and negotiate low-rate streams; no dashboard, no event loop, no bubbletea dependency. README, CLAUDE.md and `docs/reference/cli.md` all still say "Bubble Tea TUI" |
| D.15 jobs | one of five pieces | `CaptureAllocator` with don't-disturb landed with scan; the store is in-memory (`JobStore.swift:3`), no respawn, no watch job (`JobsService.swift:22`), no transcript (`:51`) |
| D.16 MCP adapter | done for the tools the daemon can back | `ley mcp`, 2026-09-14 (R-12; `docs/plans/mcp.md` has the blocked remainder) |

Undocumented extras the plan never mentions: `RTLTCPDevice` (a remote dongle over `rtl_tcp`, 504 lines,
tested — it is what made the Linux real-RF verification possible), `ley phosphor`, `ley waterfall`,
`leyfix` (the fixture generator is a substantial second binary with its own FFT and analysis), and
the sub-audible tone detector. None is a problem; all need to be in the docs. Three plan items are
open repo-wide and none is a build-order task — SV-7 (DCS decode; landed 2026-09-24), BW-2 (channel
occupancy), BW-3 (burst capture) — so `docs/plans/` looks nearly finished only because it lists the work that was
chosen, not the milestones. The build order's closing rule, `os_signpost` on any new sample-path
code, has slipped: the six signpost names cover capture ingest, channel processing, the ladder, the
FFT and ring overruns (`Signposts.swift:21-31`), and nothing in `Sinks/` (`AudioSink.write` is a named
hot path), the daemon's `FrameRing`, the persistence accumulator or the sweep. Two local-only facts a
reader of the real-RF claim should know: `rf-captures/` (32 MB of off-air WAVs, gitignored) is the
only artefact of that verification, and a bare `swift test` skips every fixture round-trip until
`make fixtures` has run (`FixtureTests.swift:92`; the Makefile target guards this, the bare command
does not).

### The wire contract in three implementations

Every RPC and behaviour-bearing field was checked in the Swift daemon, the Go fake and the Go client
library. Implemented in the daemon, mirrored by the fake and driven by the CLI: `Control` (captures,
channels, `system_audio` sinks, `WriteParams`, `WatchEvents` with `since_seq`, `GetState`, file
devices), `Telemetry` for meters, squelch transitions, detections and activity, `Bulk` for IQ, FFT
and audio, `Jobs` for scans. Partial in one of the three: `DetachSink` (no client, no Swift test),
`AttachFileDevice`'s URI form, `DeviceDescriptor.features`, `Channel.subaudible_detect`,
`Telemetry.SUB_AUDIBLE`, and `Bulk` PERSISTENCE, which the fake lacks entirely (the divergence list
below has each).

Accepted but ignored (a caller gets no warning):

- `ScanConfig.step_hz` — both daemons overwrite it with their own plan and report it back
  (`JobStore.swift:248`, `fakedaemon/jobs.go:91`); it is an output field with an input's name.
- `Channel.required_hz` — stored and echoed, read by nobody; its consumer is the unbuilt watch job.
- `AttachFileDeviceRequest.path` — the proto says it may be a `ley://recordings/<id>` URI; neither
  daemon parses `ley://`.
- `Bulk.Subscribe.transport = SHM_RING` — silently answered with `GRPC` rather than refused.

Unimplemented, and the proto documents it or should: `StreamPosition.at_sample` / `at_host_time_ns`,
`Sink.file` (`SessionStore.swift:651`), `Sink.stream` via `AttachSink` (deliberate: use
`Bulk.Subscribe`), `StreamKind.DECODED`, `Jobs.StartJob` watch and record, `ScanConfig.recurring`,
`Jobs.GetTranscript`, the entire `Resources` service. `Job.result_uris` carries `ley://scans/<id>`
that nothing can resolve. The Swift daemon never sets `SubAudible.hops_agreeing`, and sets `dcs_inverted`
to false on every lock because the standard list is closed under complement (SV-7, "Landed
(engine)").

Client library (`go/pkg/leyline`): wrappers for 5 of the 25 RPCs; the rest are reachable only as raw
stubs. `Control.DetachSink` and `Jobs.ListJobs` are implemented in both daemons and called by nothing.
Error codes `BLIND_SPOT`, `NO_DEVICE`, `FAILED_PRECONDITION`, `INTERNAL` are emitted by the daemon
and have no constant in `errors.go`; `scan.go:274` matches two of them as bare strings.

**Fake-vs-daemon divergences.** The fake is what every CLI test runs against, so each of these is a
CLI behaviour tested against the wrong response:

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
7. `Scan.gains` is empty in the fake; the proto comment explains at length that a scan without its
   gain is not comparable.
8. Don't-disturb: the fake checks channels and live audio but not a recent interactive write
   (`jobs.go:106-108` notes this); `ley scan` without `--take-over` against a recently-touched radio
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
  shm-ring reader in any language. Bookmarks and CHIRP import have no proto messages, and where
  bookmarks live is undecided (D6). Of the five named newcomer presets only NOAA and Marine VHF exist
  as presets.
- **V1b MCP**: no server, no tool registry, no PNG rendering, no generator. Six of nine tools could be
  written today; `start_job(watch|record)`, `get_transcript`, `find_recordings` cannot. The band
  labelling and scan interpretation the adapter would add exist only in `go/internal/cli`, which
  other modules cannot import.
- **LIB-1**: `go/pkg/leyline` has the transport and the vocabulary (frequency, squelch, gain, band,
  preset, selector parsing; stable codes; socket discovery) but none of the behaviour: bringing a
  capture up, creating a channel, measuring auto squelch, following a job, folding events into a
  state mirror are all unexported methods on `cli.session` wired to `io.Writer`s. An adapter or a
  dashboard would duplicate them. This is the prerequisite for both D.14 and D.16.

### Release readiness

| id | finding | blocker |
|---|---|---|
| REL-1 | no LICENSE — **fixed** (D2: `LICENSE` Apache-2.0, `engine/LICENSE` GPL-3.0, SPDX headers, `make license-check`) | — |
| REL-2 | no NOTICE for librtlsdr (GPL-2.0) and Apache-2.0 Go deps — **fixed** (`NOTICE`, `third_party/licenses/`, release-checklist obligations) | — |
| REL-3 | version hard-coded `0.1.0-dev` in Go and Swift; no ldflags, no tag, no remote | yes |
| REL-4 | no install story beyond clone-and-build; `scripts/bootstrap-mac.sh` is referenced by nothing | yes |
| REL-5 | README quickstart fails from a clean clone (PATH, `--bin`, fixtures) — **fixed** (`aa88c59`) | — |
| REL-6 | README status section a milestone behind — **fixed** (`aa88c59`) | — |
| REL-7 | README promises an app and an MCP adapter — **fixed** (`aa88c59`) | — |
| REL-8 | `docs/reference/cli.md` CLI tree lacks `waterfall`, `phosphor` | |
| REL-9 | `docs/reference/cli.md` opens with an MCP table nothing implements, unlabelled as a design | |
| REL-10 | `docs/dev/engine-internals.md` module map lacks `Jobs/`, `S2Throughput`, four DSP files; says fixture round-trips are macOS-only (CI runs them on Linux) | |
| REL-11 | `RTLTCPDeviceTests.testLinkLossReleasesSocketAndReopenReconnects` fails in roughly half of full `swift test` runs (`bad magic` on reconnect to a rebound ephemeral port), passes in isolation | yes — the gate is red at random |
| REL-12 | no macOS CI job runs `ley`, `make e2e`, or the launchd path | |
| REL-13 | no CONTRIBUTING, CHANGELOG, SECURITY, issue templates — the three files **added** (`9e5d69d`); issue templates remain (R-9) | |
| REL-14 | no contact, repository URL or issues link anywhere — **fixed** in README (`aa88c59`); the repo has no remote yet | |
| REL-15 | `docs/dev/setup.md:118-124` ships one sandbox's `/home/moatuser` paths as instructions; `moat.yaml` at the root | |
| REL-16 | two plan files cite review reports under `/tmp` on one machine; their `#N` references resolve nowhere | |
| REL-17 | trademark check outstanding (D3) | |
| REL-18 | the macOS 26 floor (`Package.swift:18`) is stated only in `docs/dev/setup.md`, not the README — **fixed** (`aa88c59`) | — |
| REL-19 | `engine/launchd/com.leyline.daemon.plist.template` is referenced by nothing and disagrees with the plist `daemon.go:151` writes | |
| REL-20–23, 25 | no secrets; build artefacts gitignored; both halves green from clean; `daemon start` without a binary fails with a clear message; stubs say they are unimplemented | — |
| REL-24 | the repo root is written for an agent (CLAUDE.md, moat.yaml), not a person | |
| REL-26 | S1/S2 never measured on hardware (D5) | |
| REL-27 | the audio path (`CoreAudioSink.swift`, all of it under `canImport(AVFoundation)`) has no automated proof anywhere; the headline story rests on a Mac acceptance run (R-17) | yes |
| REL-28 | `ley phosphor` has never run against any daemon in a test: the fake lacks the PERSISTENCE stream (R-14) | yes |
| REL-29 | no authentication on the socket, stated in SECURITY.md but not where the contract is read (R-1) | |

### Documentation drift (facts, not style)

- README.md before `aa88c59`: the `ley devices` example showed `--wide` columns and `MHz-GHz` ranges
  the default output does not print; the two-line tune banner was collapsed into one sentence with
  "on <model>"; the spectrum header and "loudest bins:" line were shapes the renderer never prints;
  and README.md:43-44 claimed all of it was "recorded against the contract fake daemon". **Fixed**:
  the transcripts are now recorded against the fake, from the module's own test harness.
- `docs/reference/cli.md:33` says spectrum's peak threshold is floor + 6 dB; the code uses 15 dB.
- `docs/guide/using-ley.md:105-106` says `--volume` takes the mode's usual value; it is 100 % for every mode.
  `:446` misquotes the BLIND_SPOT recovery line.
- `docs/dev/engine-internals.md:30` "Jobs/Resources return UNIMPLEMENTED"; `:34` "macOS only, need
  Accelerate" for the whole test target.
- `docs/design/semantic-tier.md`, `docs/design/control-plane.md`, `docs/design/data-planes.md` use `sdr://`
  URIs; the code, CLAUDE.md and `docs/reference/cli.md` use `ley://`.
- `docs/plans/user-stories.md` names every V0 verb `sdr …`; the binary has been `ley` since the naming
  decision in `docs/plans/archive/planning-phase.md` §5.
- `docs/design/semantic-tier.md` and `docs/reference/cli.md` state the CLI verbs are "generated from the
  protos"; `go/internal/cli` is hand-written cobra. Accurate wording: mapped one-to-one, by
  convention.
- CLAUDE.md:9, `docs/plans/archive/planning-phase.md:32`, `docs/reference/cli.md:153`: "Bubble Tea TUI"; no bubbletea.
- `docs/reference/cli.md:174-183` documents the grpc-go ping / swift-nio GOAWAY landmine every third-party
  client will hit; it belongs where a client author looks first, not at the end of the CLI contract.

## Work list

Status legend: `[ ]` pending, `[x]` done, `[-]` dropped with reason, `[d]` waits on a decision above.
Sizes: S under a day, M a few days, L a week or two. "Sonnet"/"Opus"/"owner" shows who does it: the
mechanical items go to the smaller model, the scoped code changes to the larger one, and the
measurements and decisions to the person with the hardware. The review findings from the same pass
get their own list, `docs/plans/archive/v1-review-fixes.md`, written when the review returns; they land first.

### R-1 `[x]` The documents tell the truth (S, Sonnet)

Every item in "Documentation drift" above except README.md, which R-8 rewrites whole. Plus:

- `docs/reference/cli.md`: add `waterfall` and `phosphor` to the CLI tree with their flags; head the MCP
  table with one sentence saying it is the design for Milestone D.16 and nothing implements it yet;
  the peak threshold is 15 dB; move the "Client requirements" (GOAWAY / BDP ping) section to the top
  of the doc under a heading a client author will find, and open it with one sentence that the socket
  has no authentication (link SECURITY.md).
- `docs/plans/user-stories.md`: the persona line says "an RTL-SDR or HackRF"; only RTL-SDR (USB or
  `rtl_tcp`) and IQ files are supported, and there is no HackRF driver.
- `docs/dev/engine-internals.md`: the module map lists `Jobs/` (JobStore, ScanRunner,
  SessionCaptureAllocator), `S2Throughput/`, and every file under `DSP/`; the Services line lists
  what is implemented (scan jobs) and what is not (watch, record, transcript, Resources); the test
  line states which tests need macOS (`KernelParityTests`, anything under `canImport(Accelerate)` or
  `canImport(AVFoundation)`) rather than the whole target.
- `sdr://` → `ley://` in the three design docs; `sdr <verb>` → `ley <verb>` in the user stories;
  "generated from the protos" → "mapped one-to-one from the protos" wherever the CLI is described;
  "Bubble Tea TUI" → "terminal live views today (`spectrum --watch`, `waterfall`, `phosphor`); the
  dashboard is Milestone D.14" in CLAUDE.md, `docs/reference/cli.md` and `docs/plans/archive/planning-phase.md`; tick S3 in
  `docs/plans/archive/planning-phase.md` §6 and point at the decision note.
- `docs/dev/setup.md`: replace the `/home/moatuser` paragraph with the generic recipe (a Swift 6.2
  toolchain, librtlsdr headers or a stub `.so` that reports zero devices, `protoc`; `LD_LIBRARY_PATH`
  at the stub for `make e2e`) with no personal paths; state that a bare `swift test` skips the
  fixture round-trips and a bare `go test ./...` skips the e2e package (both visibly only under
  `-v`), which is why `make swift-test` and `make e2e` are the gate.
- `docs/plans/archive/engine-review-fixes.md` and `docs/plans/archive/cli-review-fixes.md` headers: the review reports were
  ephemeral; the `#N` numbers are kept because the commit messages cite them.
- Delete `engine/launchd/com.leyline.daemon.plist.template` (REL-19): `ley daemon install` writes
  the plist from `go/internal/cli/daemon.go`, and the template disagrees with it.
- `docs/guide/using-ley.md`: a section for `ley waterfall` and `ley phosphor` (what question each answers,
  from `docs/design/signal-views.md` and `docs/design/band-watching.md`), and the two factual fixes.

### R-2 `[x]` One version, stamped at build time (S, Opus)

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
- `go/internal/cli/version.go`'s help example (`ley 0.1.0 (go1.25 darwin/arm64)`) shows what a
  stamped build prints, suffix included.
- `docs/dev/setup.md` gets a "Cutting a release" paragraph: bump `VERSION`, `make version`, commit,
  tag `v<VERSION>`.

### R-3 `[x]` CI proves the product on the product's platform (S, Sonnet)

`.github/workflows/ci.yml` `swift-macos` job also runs `make go-test lint e2e` (the e2e target
builds both binaries and the fixtures it needs). Note in the job why: the Go clients and the UDS
contract were previously proven only on Linux.

### R-4 `[x]` The engine test gate is deterministic (M, Opus)

`RTLTCPDeviceTests.testLinkLossReleasesSocketAndReopenReconnects`
(`engine/Tests/EngineCoreTests/RTLTCPTests.swift:365-392`) fails intermittently in a full `swift test`
run with `DEVICE_IO: not an rtl_tcp server (bad magic)` — the reader saw two failures in four full
runs — and passes in isolation (six consecutive filtered runs here, six by the reader). The
test stops `FakeRTLTCPServer` and immediately rebinds the same ephemeral port. Diagnose whether the
old accept loop or a still-open client socket answers the reconnect, whether `stop()` returns before
the listener is closed and joined, or whether the device's reconnect path has a real defect; fix the
harness or the device accordingly, and prove it with ten consecutive full runs. If the fix is in
`RTLTCPDevice`, add the regression test.

### R-4a `[ ]` One intermittent failure still to catch with its name on (owner, Mac)

The e2e half of this item is closed: `TestCLIAgainstRealDaemon`'s 0.42 s failure was caught with
its message on the fourth logged run — the DB_U8 and DB_F32 spectrum rows' peak bins two apart —
and it was the assertion, not the daemon: the fixture's tone is frequency-modulated at ±2.5 kHz, so
its peak wanders a bin either side between two rows taken at different moments, and the tolerance
was one bin. The tolerance is now the sweep's reach. The Swift failure below has still not been
caught with its message.

Seen on the Linux box after R-4 and never reproduced: one Swift test failed once in a full
`swift test` run that overlapped a `make race` (six later runs, four of them under the same load,
were green; the failure line was filtered out of the log, so the test is unnamed), and
`TestCLIAgainstRealDaemon` failed twice in under half a second, each time seconds after a lint and
a rebuild had loaded the machine (four later runs of the same pair were green; the message was
lost the same way). Both look like start-up races under load rather than product bugs. The gate
now keeps failure lines; the next occurrence will show the test's name. If either shows on the Mac,
keep the whole log and file it against this item.

### R-5 `[x]` Every verb answers `--json` or refuses it (M, Opus)

- `ley waterfall --json` prints one NDJSON object per rendered row in the existing bulk-row shape
  (`{seq, sample_index, center_hz, span_hz, bins, floor_db}`) plus `looks` (the look count the daemon
  answered for the accumulation it negotiated); gap lines as `ley fft`. `ley phosphor --json` prints
  one object per persistence frame: `{seq, sample_index, center_hz, span_hz, bins, levels, floor_db,
  range_db, counts}` where `counts` is the daemon's `bins × levels` little-endian uint16 grid,
  base64-encoded like `ley listen`'s `pcm`. Both are documented in `docs/reference/cli.md` as members of
  the bulk-row exception.
- `ley help --json` and `ley completion --json` reject the flag with the same usage error (exit 2)
  `ley daemon logs --json` uses, and the doc states this.
- A table-driven test walks the cobra tree from the root and asserts every leaf either emits valid
  JSON on stdout under `--json` (against the fake) or exits 2 with the documented message — so the
  V0 story cannot regress silently again.

### R-6 `[d]` `ley play` for IQ files this project did not write (M, Opus; after D1)

A `.cf32` without a sidecar is refused by the daemon (`DEVICE_IO: cannot stat sidecar`) while
`go/internal/cli/play.go:30` says a missing sidecar is not an error. Additive
`AttachFileDeviceRequest` fields (`sample_rate`, `center_hz`, `format`) used only when no sidecar
exists; `ley play --rate` joins `--freq`; the fake mirrors; the error for a bare file without `--rate`
mentions the flag. Not required for the cut but it is what "play IQ files back" means to someone
with an `rtl_sdr` capture.

### R-7 `[d]` LICENSE and NOTICE (S; after D2)

`LICENSE` at the root; `NOTICE` listing librtlsdr (GPL-2.0-or-later, dynamically linked by
`leylined`) and the Apache-2.0 Go dependencies; a licence line in README and in `ley version`'s help.

### R-8 `[x]` README written for a stranger (S)

What it is (a daemon that owns an RTL-SDR and a CLI that drives it, today), what it is not yet (no
app, no MCP adapter, no recording), requirements (macOS 26, Xcode 26, Homebrew, Go 1.25, an RTL-SDR),
install, a quickstart that works from a clean clone (`make go swift-release fixtures`,
`export PATH=$PWD/go/bin:$PATH`, `ley daemon start --bin engine/.build/release/leylined`), console
transcripts that match what the renderers print (record them against the daemon or the fake rather
than paraphrasing), the docs map, a status section that agrees with `docs/plans/build-order.md`, licence
(placeholder until D2), and where to report problems (the module path already names
`github.com/dpup/leysdr`). The GOAWAY/ping note for client authors is linked from the README.

### R-9 `[x]` CONTRIBUTING, SECURITY, CHANGELOG (S)

- `CONTRIBUTING.md`: the gate (`make check`, both hosts), the invariants (CLAUDE.md is the review
  checklist), proto additivity, generated code, how fixtures work.
- `SECURITY.md`: the trust model in one page — a local UDS socket with the user's permissions and no
  authentication; anything that can open it controls the radio; no network listener; `--rtltcp` is
  an outbound cleartext connection to a server you name; how to report.
- `CHANGELOG.md` started with an Unreleased section.
- `.github/ISSUE_TEMPLATE/bug.md` asking for `ley version`, `ley daemon status`, the macOS version and
  the dongle.

### R-10 `[ ]` (folded into R-1: delete the dead launchd template)

### R-11 `[x]` Recording (L, Opus; in every cut, so it waited only on the review fixes)

Landed 2026-09-18 as Milestone C.12, to `docs/design/recording.md`, which the design note this item
asked for grew into. What shipped differs from the sketch here in one decision and gains two
features the design added:

- **Not `AttachSink(file)`.** A recording is a job's output, so `Jobs.StartJob(RecordConfig)` is the
  only way to make one and `AttachSink(file)` stays refused: a sink attached to somebody's channel
  ends with that channel's owner and leaves a file nothing indexes, while a job goes through the
  allocator, outlives its client and produces a resource. There is no `FileSink` in
  `EngineCore/Sinks`; `LeylineDaemon/Recording/` holds the runner, the gate, the part writer and
  the store.
- **The squelch gate and parts.** `--gate squelch` writes one file per exchange and `--part D` cuts
  long recordings on a timer, because both are needed in the first week of use; the manifest states
  the coverage gaps rather than editing silence out of a file.
- As sketched: the store directory with retention, `Resources` (which also answers `RECORDS` and
  `SCAN`, so the service covers every kind, not one), `ley record` / `ley recordings` /
  `ley recordings show` / `ley recordings path`, and `ley play` on a `ley://` URI.

### R-12 `[x]` MCP adapter (L, Opus; after D1 and R-13)

Landed 2026-09-14 as `ley mcp`, a subcommand rather than a `leymcp` binary, per the decision in
`docs/plans/mcp.md` (which superseded this item's shape); the tools the daemon can back are in
`docs/reference/mcp.md`, the blocked ones are named there with their milestones rather than
registered as refusing stubs, and the client-library promotion R-13 asks for was not needed: the
adapter runs the verbs' own session logic in `go/internal/cli`.

Milestone D.16. Go binary `leymcp` (stdio transport) sharing `go/pkg/leyline`; the six tools the daemon
can back today (`list_devices`, `get_state`, `tune`, `listen_summary`, `scan`, `snapshot` as PNG
plus data); the three that cannot return a typed "not available until Milestone D.15" refusal.
Design note first: tool schemas, refusal semantics, how the don't-disturb refusal reads. The CLI is
the reference client (`docs/design/semantic-tier.md`), so every tool ships with its `ley` mirror: `scan`,
`tune`, `listen`, `spectrum` exist, `jobs` arrives with R-15, `recordings` with R-11, and `watch`
stays a stub until D.15 — the adapter's `start_job(watch)` refuses with the same sentence.

### R-13 `[d]` The client library carries the behaviour, not just the vocabulary (M, Opus; after D1)

LIB-1. Promote from `go/internal/cli/session.go`, `tune.go`, `set.go`, `scan.go` into `go/pkg/leyline`:
the state mirror with event folding (`fold`), bring-up of a capture and channel with the tune decision
logic, the auto-squelch measurement, the live parameter write with confirmation, and following a scan
job to completion. The CLI becomes a renderer over those. Prerequisite for R-12 and for D.14.

### R-14 `[x]` The fake daemon tells the daemon's story (M, Opus)

The ten divergences listed under "The wire contract". For each: make the fake match the Swift daemon's
semantics, and add the CLI test that could not exist before (a `ley phosphor` run against the fake;
`waterfall`'s `looks > 1` annotation; a gap rendered only when the fake's buffer actually dropped;
`ley tune`'s CTCSS line from a fake channel with a tone; `subaudible_detect` shown; first/last seen
and a real look count on detections; `Scan.gains` printed; a scan refused because of a write in the
last 60 s; the real driver's feature keys — check `RTLSDRDevice.swift` for what it emits and fix
`docs/dev/engine-internals.md` if the doc disagrees; `BLIND_SPOT` from the fake when the request falls in
the DC guard). Split into two commits if it helps: bulk/telemetry parity, then jobs parity.

### R-15 `[x]` Contract hygiene (S, Opus)

- `go/pkg/leyline/errors.go` gains constants for every code the daemon emits (`BLIND_SPOT`,
  `NO_DEVICE`, `FAILED_PRECONDITION`, `INTERNAL`); `scan.go:274` uses them; a test asserts the Go list
  and the engine's `EngineError` codes are the same set.
- Proto comments document what the daemons do: `ScanConfig.step_hz` is chosen by the daemon and a request
  value is ignored; `Channel.required_hz` is read only by watch jobs, not yet implemented;
  `Transport.SHM_RING` is answered with `GRPC` in v0; `AttachFileDeviceRequest.path` accepts
  filesystem paths only in v0; `Sink.stream` is refused by `AttachSink` in v0 (use `Bulk.Subscribe`);
  `SubAudible.dcs_code`, `dcs_inverted` and `hops_agreeing` are reserved for the DCS decoder and never
  set today. Comments only — no wire change.
- `go/pkg/leyline` wrappers for `ListJobs` and `DetachSink`, and `ley jobs [cancel <id>]` so that a
  running or finished scan can be listed and stopped from another terminal (the RPCs exist in both
  daemons and are called by nothing).

### R-16 `[ ]` Measurements only the owner can make (owner)

- S2 on an M-series Mac under Instruments against `docs/plans/build-order.md`'s criteria; record the result
  as `docs/decisions/S2-throughput.md`, pass or fail.
- S3's host check (`docs/decisions/S3-usb-posture.md:34-40`).
- The scan settle constant (`docs/design/scan.md` Open questions): one known carrier, several
  `--dwell` values, does the reported frequency drift.
- The audio acceptance run from R-17.

### R-17 `[x]` A release checklist (S)

`docs/dev/release-checklist.md`: the manual acceptance pass a Mac must complete before a tag — fixture
tone audible, a real station audible, `set` from a second terminal, `scan` of a known band,
record → play, `daemon install` / `status` / `uninstall`, unplug and replug — plus the mechanical
steps (VERSION bump, `make check` on both hosts, tag, release notes).

### R-18 `[d]` Trademark check (owner; D3)

### R-19 `[x]` Signposts on the sample-path code added since Milestone B (S, Opus)

`Signposts.swift` names six intervals and none covers `AudioSink.write` (`CoreAudioSink`,
`CallbackSink`), the daemon's `FrameRing` writes, the persistence accumulator, or the sweep's row
collection. Add the names and the intervals (the wrappers are already allocation-free and compile to
nothing off macOS), so the S1/S2 Instruments runs in R-16 can see the whole path.

### R-21 `[ ]` Hardware-derived fixtures, optional and local (S, Opus)

`fixtures/ht-narrow.cu8` (ten seconds of a narrow-mode handheld on 147.435 MHz with a 100 Hz PL,
recorded with `rtl_sdr`, gitignored) is the first real capture the views were checked against, and
it pins facts no synthesised fixture carries: the no-carrier noise at 4.8× full scale either side of
a transmission, a 305 Hz PL deviation, speech peaking at the narrow-mode limit. Give such files a
home: a `fixtures/hardware/` directory with sidecars whose `description` records radio, distance,
gain and mode; e2e and engine tests that use one skip with a named reason when it is absent; `docs/
docs/reference/iq-files.md` explains how to record one (`ley daemon stop`, `rtl_sdr -f <100 kHz off
the channel> -s 2400000 -g 0 -n 24000000`, the sidecar, `ley play … --freq`). The first tests: the
waveform's blank-when-squelched rule over a real key-up, and `levels` reading the PL band within 2
dB of the value measured here.

### R-22 `[ ]` The content layer needs a specification before pricing (M, owner + Opus)

D2 makes a curated content layer half of the revenue model and nothing describes it. Write
`docs/design/content-layer.md` before v1 pricing is announced: what a pack is (band plans,
decoder recipe bundles, listening presets, CHIRP mappings, regional frequency databases), how it is
versioned and updated (in-app fetch versus git), which packs are free and which paid, how the
community submits and who curates, and the licence per pack (data, not code: CC-BY-SA or similar,
decided per source). The daemon-side home for the data is D6 (bookmarks live in the daemon), so the
document also specifies which pack contents become daemon state and which stay files.

### R-23 `[ ]` One gain syntax, one gain line (S, Opus)

Asked 2026-09-24 after M2-10 gave `--gain` stage pairs: "let's align all the gain flags." The
inventory found four surfaces still on older shapes and one print form that differs by command.

**One syntax.** `auto`, a bare number (the first stage), or `STAGE=dB,...` in any order, case
matched against the device's elements, parsed by `leyline.ParseGains` everywhere:

- `ley set gain LNA=0,VGA=20` replaces `ley set gain 20 --element VGA`; `--element` goes (there
  is no release to keep it for). The confirm line names every stage set.
- `ley scan --gain` takes the same. `ScanConfig` gains `repeated GainWrite gains` (additive,
  beside `gain`, which stays and loses when both are sent, as `RecordConfig` does); the sweep's
  pin applies each in order through the shared element helper and fails the sweep on the first
  refusal, and `Scan.gains` keeps reporting every stage.
- `ley set gain`, `--gain` on every verb, and the MCP `tune`, `listen_summary`, `record` and
  `scan` tools share one help sentence, "receiver gain: auto, dB such as 30 for the first stage,
  or stages such as LNA=0,VGA=20 (ley help gain)", and `ley help gain` is the one place the
  syntax is explained. `docs/reference/mcp.md` states it once for the four tools, and
  `docs/design/recording.md`'s sketch of `ley record` follows the real flag.

**One line.** A capture's gains print the same way wherever they print: `gain 28 dB` for a
one-stage radio, `gain LNA 0 dB, VGA 20 dB, AMP off` for several, a two-value stage as `on` or
`off`, numbers with a decimal only when the step has one (49.6 dB), element names as the device
spells them. One helper (`stageGainWords`, made to follow this) serves `ley state` (tree and
`--wide`), `ley scan`'s summary (`lna 8.0 dB` today), `ley recordings show` (first stage only
today, the one renderer M2-10 missed), both banners, and `ley set`'s confirm line.
`ley devices`' elements column stays a range (`LNA 0–40 dB`, `TUNER 0–49.6 dB auto`) with the
same names and number form. `--json` is untouched.

Not applicable, and left so: `monitor`, `decode`, `watch` and `track` (the daemon's gain is the
daemon's, as `monitor.go` says), `devices attach`. The app already writes one `GainWrite` per
stage and prints nothing as a string.

### R-20 `[x]` Remote radios become daemon state (M, Opus; after D7)

Today a dongle served by `rtl_tcp` is a daemon flag (`leylined --rtltcp host:port`) or an environment
variable, read once at startup. Under launchd that means editing the plist and restarting the
daemon to add a Pi on the roof, the device is invisible to `ley devices` until then, and
`ley devices detach` refuses it afterwards. Everything else about a device is daemon state a client
drives over the one protocol; this should be too.

- Contract, additive: `Control.AttachDevice(DeviceSource)` and `Control.DetachDevice(device_id)`,
  where `DeviceSource` is a oneof of `file { path, loop }` and `rtl_tcp { host, port }`. The
  existing `AttachFileDevice` stays and becomes sugar over the new RPC; the oneof is where any later
  network source lands without another RPC.
- Persistence follows intent: a file you play is ephemeral, a radio you attach is part of the
  station setup and persists. The daemon writes attached remotes to `devices.json` beside its socket
  and re-attaches them at startup; `DetachDevice` forgets. No flag: attach adds, detach removes, and
  it survives restarts like everything else the daemon owns. `--rtltcp` can stay for foreground dev
  runs but is no longer the documented path.
- CLI: `ley devices attach rtltcp pi.local:1234`, pairing with the `detach` that exists; `--watch`
  sees the arrival because device events exist. Attach connects once with the existing 5 s timeout
  and, if the host cannot be reached, fails with an error naming the host and remembers nothing (a
  radio never reached is usually a typo). A later drop goes `DISCONNECTED` and the registry's
  reconnect-on-poll brings it back, which is already built.
- Fake and e2e: the fake accepts any `rtl_tcp` source and manufactures the descriptor; the e2e
  attaches the engine tests' fake `rtl_tcp` server.
- Attach dedupes on host and port before connecting, which closes the duplicate-attach leak the
  review found (q-swift-control-3).

Remote *control* of the daemon (a TCP listener with authentication) is a separate milestone and
this does not touch it. Discovery (Bonjour) is not worth it yet: `rtl_tcp` does not advertise.
