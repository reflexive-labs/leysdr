# Leyline documentation

Start with who you are. The first section is for someone who wants to use Leyline; the rest is for
people and agents working on it. Prose in this directory follows the [writing guide](writing-guide.md).

## Using Leyline

You have an RTL-SDR (or an IQ recording) and a Mac.

| read | when |
|---|---|
| [Installing Leyline](guide/install.md) | building the daemon and `ley`, starting at login, a radio on another machine, uninstalling |
| [Using `ley`](guide/using-ley.md) | the tasks in the order a newcomer meets them: see the radio, hear a station, adjust it, see the band, scan, watch, the waveform, two channels, play a recording, make one, decode packets, scripts |
| [Troubleshooting](guide/troubleshooting.md) | the daemon is not running, no radio listed, a busy dongle, no audio, and every message `ley` prints |
| [`ley` reference](reference/cli.md) | the command tree, input conventions, every `--json` shape, exit status |
| [IQ files and fixtures](reference/iq-files.md) | the `.cf32` + sidecar format `ley play` reads, and the generated signals |
| [Writing a client](reference/clients.md) | a script, agent or program that speaks the contract without `ley` |
| [MCP adapter](reference/mcp.md) | letting an agent drive the radio through `ley mcp`: the tools, their shapes, the trust it hands over, client configuration |
| [Writing a decoder](reference/writing-a-decoder.md) | a plugin that turns a channel's audio into typed records |

`ley help <topic>` carries the same facts at the prompt: `squelch`, `frequencies`, `modes`, `gain`,
`presets`, `glossary`, `scripting`, `roadmap`. What works today and what is next is the "Where
things stand" section of the [README](../README.md) and `ley help roadmap`;
[`plans/build-order.md`](plans/build-order.md) is the order features arrive in.

## Working on Leyline

Contributors and coding agents. Read first, in this order:

1. [`AGENTS.md`](../AGENTS.md): the thirteen invariants, written as instructions to an agent and
   used as the review checklist. Each has its rationale in a design doc below.
2. [`CONTRIBUTING.md`](../CONTRIBUTING.md): the gate (`make check`), tests without hardware,
   commits, the licence of your contribution.
3. [Writing guide](writing-guide.md): the voice, the words, and which kind of document goes where.

### Contracts and setup (`dev/`)

| read | before |
|---|---|
| [Developer setup](dev/setup.md) | building on the Mac, the Linux container, regenerating protos, cutting a release |
| [Engine internals](dev/engine-internals.md) | touching the engine or daemon: threads, the hot path, pipeline math, devices, services, the error-code table, daemon lifecycle |
| [CLI style](dev/cli-style.md) | changing anything a `ley` user sees: colour, streams, glyphs, layout, the frozen contracts |
| [Swift style](dev/swift-style.md) | writing Swift anywhere in the repository: file headers and SPDX, comment and doc-comment voice, naming and unit suffixes, isolation and `Task`, the session, mirror and coalescer patterns, what only the Mac can check |
| [Release checklist](dev/release-checklist.md) | tagging a release: the mechanical gate, licence obligations, the acceptance pass on a real dongle |
| [Agent evals](dev/evals.md) | measuring an agent's use of `ley mcp` against fixtures: running `leyeval`, reading a transcript, adding a scenario and its checks |
| [App internals](dev/app.md) | touching the Mac app: the `app/` package, the client façade (identity, mirror, coalescer, streams), building, bundling and testing it against the daemon |

### Why it is built this way (`design/`)

Each design doc opens with a status line and the question it answers. A change that contradicts one
changes the doc first.

| doc | question | status |
|---|---|---|
| [Control plane](design/control-plane.md) | how clients discover, tune, share and arbitrate; gRPC over UDS; the session model | draft; v0 implements it |
| [Data planes](design/data-planes.md) | telemetry and bulk: the sample timebase, latest-wins and gap-marked delivery, negotiation | draft; v0 implements it |
| [Semantic tier](design/semantic-tier.md) | detections, scans, transcripts, jobs and resources; the MCP surface | draft; scan and the MCP adapter (`ley mcp`) implemented, durable jobs and transcripts not |
| [Scan](design/scan.md) | the sweep geometry and the detector, with every number measured | decided, implemented (D.13) |
| [Signal views](design/signal-views.md) | the waterfall, the channel view, sub-audible (CTCSS) tones, and what honest means | draft; implemented except DCS and the sonogram |
| [Scope](design/scope.md) | the audio waveform and the demod tap under it | draft; `ley scope` implements it |
| [Audio meters](design/audio-meters.md) | `ley levels` and `ley waveform` as instruments | implemented |
| [Band watching](design/band-watching.md) | persistence (`ley phosphor`), burst capture, occupancy | draft; persistence implemented, the rest not |
| [Decoders](design/decoders.md) | turning demodulated signal into typed records: the plugin contract, the record envelope and store, the state boundary, the surfaces | draft; APRS being built (D.17) |
| [Recording](design/recording.md) | recording as a job whose output is a resource: parts, the squelch gate, the manifest, the store, the `Resources` service | implemented (C.12) |
| [App design handoff](design/app-design-handoff.md) | the M1 window read against the code: regions, palette and type tokens, the bands and bookmarks files, tuning gestures, what M1 deliberately leaves out | reconciled 2026-09-18; M1 built |
| [App design handoff, M2](design/app-design-handoff-m2.md) | the inspector panel: identity, the reading, the audio ladder, the log, Measurements, and every decision taken against the code since | landed 2026-09-20; revised through 2026-09-24 |
| [App design handoff, M3](design/app-design-handoff-m3.md) | recording in the window: the owner's 8a–8e and 10a screens read against the prose, then the Library decided with the owner (two places, one switch; rows are parts; a player that pauses) and every decision taken in the build | landed 2026-09-25; unverified on a Mac |
| [Brand](design/brand/README.md) | the mark and the splash as the owner drew them, drawn in code (APP-8); how the icon is made | 2026-09-25 |
| [Bands, channels and bookmarks](design/channels.md) | the three kinds of frequency; plan channels as data in the band table; bands as the sidebar's spine; Scan band over the scan job; tone, note and tags; CHIRP import; the engine and CLI pass | implemented 2026-09-29 (APP-9); views unverified on the Mac |

### Decisions (`decisions/`)

One decision each, dated, with what it costs and what would reopen it.
[D2 licensing](decisions/D2-licensing.md) (everything ships open; engine GPL-3.0-or-later, all else
Apache-2.0), [S3 USB posture](decisions/S3-usb-posture.md) (librtlsdr/libusb now, IOUSBHost later)
and [S2 throughput](decisions/S2-throughput.md) (20 MSPS on one fifth of a core: the all-Swift
engine stands).

### Plans (`plans/`)

What is being built, in what order, and the record of what each step found.

- [Build order](plans/build-order.md): milestones A to E and the spikes, with acceptance criteria,
  and "Closing the core", the gate between the engine milestones and the app.
  [User stories](plans/user-stories.md) are the acceptance tests of record.
- Live plans, with `[ ]` items still open: [v1 release](plans/v1-release.md) (the gap analysis and
  work list for the first shared release), [signal views](plans/signal-views.md) (DCS and the
  sonogram remain), [band watching](plans/band-watching.md) (occupancy and burst capture remain),
  [decoders](plans/decoders.md) (the plugin contract and APRS first; the other four drivers follow),
  [MCP adapter](plans/mcp.md) (where the server lives and the order the tools land; the tools the
  daemon can back landed as `ley mcp`, the rest wait on their milestones),
  [the Mac app](plans/app.md) (Milestone E: the façade and the skeleton window landed as APP-1,
  the spectrum and spike S1 are next), and
  [bands, channels and bookmarks](plans/2026-09-28-2037-feat-bands-channels-bookmarks-plan.md)
  (APP-9 as seven units an agent can run unattended, with the gates and the Mac checklist each
  leaves behind).
- [`plans/archive/`](plans/archive/): finished plans and review records, kept because commit
  messages cite their item ids. Nothing in there is a work list any more.

### For coding agents

`AGENTS.md` is the agent guide (`CLAUDE.md` only points to it, for tools that load that name);
this directory is where its rules come from. The four reads
that prevent the most rework: the design doc for the area before a structural change,
[CLI style](dev/cli-style.md) before changing output, [Engine internals](dev/engine-internals.md)
plus the fixture round-trips in [IQ files and fixtures](reference/iq-files.md) before DSP, and
[Swift style](dev/swift-style.md) before writing Swift — its last two sections say what the Linux
container can verify, what only the Mac catches, and what to say when handing over work that was
never compiled.

Two documents are parsed by tests, so their shape is part of the contract: the "Error codes" table
in `dev/engine-internals.md` (`ErrorTableTests` on the Swift side, the error registry test on the Go
side) and `ley`'s help texts (golden files under `go/internal/cli/testdata/help/`). A page that
moves takes every `docs/` reference in the repository with it.

## Map

```
docs/
├── README.md              this page
├── writing-guide.md       voice, words, document kinds
├── guide/                 using Leyline: install, using-ley, troubleshooting
├── reference/             lookup: cli, iq-files, clients
├── design/                why it is built this way, with the measured numbers
├── decisions/             dated decision records (D2, S3)
├── dev/                   contributor contracts: setup, engine-internals, cli-style, swift-style, app, release-checklist
└── plans/                 build-order, user-stories, live plans; archive/ for finished ones
```
